-- Arcana XP & Leveling — XP accumulation, level-up logic, and spell unlocking.
-- Depends on: Arcana.Config, Arcana.RegisteredSpells, Arcana:GetPlayerData,
--             Arcana:SavePlayerData, Arcana:SyncPlayerData, Arcana.RunHook

Arcana = Arcana or {}

function Arcana:GetXPRequiredForLevel(level)
	return math.floor(1.25 * level * level + 12.5 * level)
end

function Arcana:GetTotalXPForLevel(level)
	local total = 0
	for i = 1, level - 1 do
		total = total + self:GetXPRequiredForLevel(i)
	end
	return total
end

function Arcana:GiveXP(ply, amount, reason)
	if not IsValid(ply) or amount <= 0 then return false end

	if amount > 0xFFFFFFFF then
		amount = 0xFFFFFFFF
	end

	local data = self:GetPlayerData(ply)
	if not data then return false end
	local oldLevel = data.level

	local maxXP = self:GetTotalXPForLevel(Arcana.Config.MAX_LEVEL)
	if data.xp >= maxXP then
		return false
	end

	data.xp = math.min(data.xp + amount, maxXP)
	reason = reason or "Unknown"

	Arcana.RunHook("PlayerGainedXP", ply, amount, reason)

	local newLevel = self:CalculateLevel(data.xp)
	if newLevel > oldLevel then
		self:LevelUp(ply, oldLevel, newLevel)
	end

	if SERVER then
		net.Start("Arcana_XPUpdate")
		net.WriteUInt(data.xp, 32)
		net.WriteUInt(data.level, 16)
		net.WriteUInt(amount, 32)
		net.WriteString(reason)
		net.Send(ply)
	end

	self:SavePlayerData(ply)
	return true
end

function Arcana:CalculateLevel(totalXP)
	local level = 1
	local xpUsed = 0
	while level < self.Config.MAX_LEVEL do
		local xpNeeded = self:GetXPRequiredForLevel(level)
		if xpUsed + xpNeeded > totalXP then break end
		xpUsed = xpUsed + xpNeeded
		level = level + 1
	end
	return level
end

function Arcana:LevelUp(ply, oldLevel, newLevel)
	local data = self:GetPlayerData(ply)
	if not data then return end
	local levelsGained = newLevel - oldLevel
	data.level = newLevel
	data.knowledge_points = data.knowledge_points + (levelsGained * Arcana.Config.KNOWLEDGE_POINTS_PER_LEVEL)

	if SERVER then
		for spellId, spell in pairs(self.RegisteredSpells) do
			if spell.is_divine_pact and not data.unlocked_spells[spellId] and newLevel >= spell.level_required then
				self:UnlockSpell(ply, spellId, true)
			end
		end
	end

	if SERVER then
		net.Start("Arcana_LevelUp")
		net.WriteUInt(newLevel, 16)
		net.WriteUInt(data.knowledge_points, 16)
		net.Send(ply)
		self:SyncPlayerData(ply)
	end

	Arcana.RunHook("PlayerLevelUp", ply, oldLevel, newLevel, data.knowledge_points)
end

function Arcana:CanUnlockSpell(ply, spellId)
	local spell = self.RegisteredSpells[spellId]
	if not spell then return false, "Spell not found" end
	-- Crafted spells are per-player and managed by the spellcraft system; they
	-- can never be unlocked through the knowledge system.
	if spell.is_crafted then return false, "This spell cannot be unlocked here" end
	local data = self:GetPlayerData(ply)
	if not data then return false, "Player data not loaded" end
	if data.unlocked_spells[spellId] then return false, "Already unlocked" end
	if data.level < spell.level_required then return false, "Insufficient level" end
	if data.knowledge_points < spell.knowledge_cost then return false, "Insufficient knowledge points" end

	local ok, reason = Arcana.RunHook("CanUnlockSpell", ply, spellId)
	if ok == false then return false, reason or "Cannot unlock spell" end

	return true
end

function Arcana:UnlockSpell(ply, spellId, force)
	if not force then
		local canUnlock, reason = self:CanUnlockSpell(ply, spellId)
		if not canUnlock then
			if SERVER then
				Arcana:SendErrorNotification(ply, "Cannot unlock spell \"" .. spellId .. "\": " .. reason)
			end
			return false
		end
	end

	local spell = self.RegisteredSpells[spellId]
	local data = self:GetPlayerData(ply)
	if not data then return false end
	if not force then
		data.knowledge_points = data.knowledge_points - spell.knowledge_cost
	end
	data.unlocked_spells[spellId] = true

	-- Stamp the learn time so the altar can offer a brief free undo (see IsForgetFree).
	-- Forced grants — divine pacts, the starter spell — cost nothing and are not
	-- undoable, so they are deliberately left unstamped.
	if not force then
		data.unlock_times = data.unlock_times or {}
		data.unlock_times[spellId] = CurTime()
	end

	for i = 1, 8 do
		if not data.quickspell_slots[i] then
			data.quickspell_slots[i] = spellId
			break
		end
	end

	if SERVER then
		self:SyncPlayerData(ply)
		net.Start("Arcana_SpellUnlocked")
		net.WriteString(spellId)
		net.WriteString(spell.name or spellId)
		net.Send(ply)
	end

	self:SavePlayerData(ply)
	Arcana.RunHook("SpellUnlocked", ply, spellId, spell.name or spellId)
	return true
end

-- ============================================================================
-- FORGETTING SPELLS
-- ============================================================================
-- Forgetting is the inverse of unlocking. Because KP is derived rather than stored
-- (see CalculateExpectedKnowledgePoints), removing a spell from unlocked_spells IS
-- the refund — no arithmetic, no drift. The price is therefore paid in coins and
-- mana crystal shards, the resources a mid-game player is actually short of.

Arcana.FORGET_ITEM = "mana_crystal_shard"

-- Returns coins, shards.
function Arcana:GetForgetCost(spellId)
	local spell = self.RegisteredSpells[spellId]
	if not spell then return 0, 0 end
	local kc = math.max(1, tonumber(spell.knowledge_cost) or 1)
	local coins = math.floor((self.Config.FORGET_COIN_BASE or 2000) * kc ^ (self.Config.FORGET_COIN_EXPONENT or 1.3))
	local shards = math.ceil((self.Config.FORGET_SHARDS_PER_KP or 2) * kc)
	return coins, shards
end

-- Seconds of free-undo left on a freshly learned spell, or 0.
function Arcana:GetForgetGraceRemaining(ply, spellId)
	local data = self:GetPlayerData(ply)
	local learnedAt = data and data.unlock_times and data.unlock_times[spellId]
	if not learnedAt then return 0 end
	local remaining = (learnedAt + (self.Config.FORGET_GRACE_PERIOD or 300)) - CurTime()
	return math.max(0, remaining)
end

function Arcana:IsForgetFree(ply, spellId)
	return self:GetForgetGraceRemaining(ply, spellId) > 0
end

-- Returns ok, reason, coins, shards, isFree.
function Arcana:CanForgetSpell(ply, spellId)
	local spell = self.RegisteredSpells[spellId]
	if not spell then return false, "Spell not found" end
	if SERVER and Arcana.SaveBlockedBySteamID[ply:SteamID64()] then return false, "Player data is still loading" end
	local data = self:GetPlayerData(ply)
	if not data then return false, "Player data not loaded" end
	if not data.unlocked_spells[spellId] then return false, "Spell not learned" end
	-- Divine pacts are granted free by levelling, so forgetting one refunds nothing and
	-- it would return on the next level anyway. Crafted spells are the Emissary's.
	if spell.is_divine_pact then return false, "This spell was granted, not learned" end
	if spell.is_crafted then return false, "This spell cannot be forgotten here" end
	if data.casting_until and data.casting_until > CurTime() then return false, "You are casting" end

	local isFree = self:IsForgetFree(ply, spellId)
	local coins, shards = self:GetForgetCost(spellId)

	if not isFree then
		if self:GetCoins(ply) < coins then return false, "Not enough coins" end
		if shards > 0 and self:GetItemCount(ply, self.FORGET_ITEM) < shards then return false, "Not enough mana crystal shards" end
	end

	local ok, reason = Arcana.RunHook("CanForgetSpell", ply, spellId)
	if ok == false then return false, reason or "Cannot forget spell" end

	return true, nil, coins, shards, isFree
end

if SERVER then
	function Arcana:ForgetSpell(ply, spellId)
		local canForget, reason, coins, shards, isFree = self:CanForgetSpell(ply, spellId)
		if not canForget then
			Arcana:SendErrorNotification(ply, "Cannot forget spell: " .. tostring(reason))
			return false
		end

		local spell = self.RegisteredSpells[spellId]
		local data = self:GetPlayerData(ply)
		local spellName = spell.name or spellId

		if not isFree then
			if coins > 0 and not self:TakeCoins(ply, coins, "Forgetting " .. spellName) then
				Arcana:SendErrorNotification(ply, "Cannot forget spell: Not enough coins")
				return false
			end

			if shards > 0 and not self:TakeItem(ply, self.FORGET_ITEM, shards, "Forgetting " .. spellName) then
				-- Hand back the coins so a half-paid price cannot swallow them.
				if coins > 0 then self:GiveCoins(ply, coins, "Refund") end
				Arcana:SendErrorNotification(ply, "Cannot forget spell: Not enough mana crystal shards")
				return false
			end
		end

		data.unlocked_spells[spellId] = nil
		if data.unlock_times then data.unlock_times[spellId] = nil end

		for i = 1, 8 do
			if data.quickspell_slots[i] == spellId then
				data.quickspell_slots[i] = nil
			end
		end

		-- Re-derived, never incremented: the formula is the only ground truth.
		data.knowledge_points = self:CalculateExpectedKnowledgePoints(ply)

		-- Authoritative, because an ordinary save unions the spell list with the stored
		-- row and would put the spell straight back.
		self:SavePlayerData(ply, true)
		self:SyncPlayerData(ply)

		net.Start("Arcana_SpellForgotten")
		net.WriteString(spellId)
		net.WriteString(spellName)
		net.Send(ply)

		Arcana.RunHook("SpellForgotten", ply, spellId, spellName)
		return true
	end
end

function Arcana:GetLevel(ply)
	local data = self:GetPlayerData(ply)
	return data and data.level or 1
end

function Arcana:GetXP(ply)
	local data = self:GetPlayerData(ply)
	return data and data.xp or 0
end

function Arcana:GetKnowledgePoints(ply)
	local data = self:GetPlayerData(ply)
	return data and data.knowledge_points or 0
end

function Arcana:HasSpellUnlocked(ply, spellId)
	local data = self:GetPlayerData(ply)
	return data ~= nil and data.unlocked_spells[spellId] == true
end

-- Returns the total KP a player earns purely from levelling.
-- One batch of KNOWLEDGE_POINTS_PER_LEVEL is granted via CreateDefaultPlayerData at
-- level 1, and then again on every subsequent LevelUp, so the lifetime total is:
--   level × KNOWLEDGE_POINTS_PER_LEVEL
function Arcana:GetTotalEarnedKnowledgePoints(level)
	return (tonumber(level) or 1) * (Arcana.Config.KNOWLEDGE_POINTS_PER_LEVEL or 1)
end

-- Returns the total KP spent across a set of unlocked spells.
-- Divine-pact spells are always granted for free, so they are excluded from the sum.
function Arcana:GetTotalSpentKnowledgePoints(unlockedSpells)
	local spent = 0
	for spellId, unlocked in pairs(unlockedSpells or {}) do
		if unlocked then
			local spell = self.RegisteredSpells[spellId]
			if spell and not spell.is_divine_pact and not spell.is_crafted then
				spent = spent + (tonumber(spell.knowledge_cost) or 0)
			end
		end
	end
	return spent
end

-- Returns the KP a player should currently have, derived from their level and spells.
-- Formula: (level × KP_PER_LEVEL) − Σ knowledge_cost for each non-divine-pact unlocked spell
-- This is the canonical "ground truth" value and can be used to detect or correct drift.
function Arcana:CalculateExpectedKnowledgePoints(ply)
	local data = self:GetPlayerData(ply)
	if not data then return 0 end
	local earned = self:GetTotalEarnedKnowledgePoints(data.level)
	local spent  = self:GetTotalSpentKnowledgePoints(data.unlocked_spells)
	return math.max(0, earned - spent)
end

if SERVER then
	-- Recalculates a player's KP from first principles and overwrites the stored value.
	-- Useful as an admin repair tool or a post-load integrity check.
	-- Returns the corrected KP amount.
	function Arcana:RecalculateAndRepairKnowledgePoints(ply)
		local data = self:GetPlayerData(ply)
		if not data then return 0 end
		local corrected = self:CalculateExpectedKnowledgePoints(ply)
		data.knowledge_points = corrected
		self:SavePlayerData(ply)
		self:SyncPlayerData(ply)
		return corrected
	end
end

if SERVER then
	util.AddNetworkString("Arcana_XPUpdate")
	util.AddNetworkString("Arcana_LevelUp")
	util.AddNetworkString("Arcana_UnlockSpell")
	util.AddNetworkString("Arcana_ForgetSpell")
	util.AddNetworkString("Arcana_SpellForgotten")

	local lastUnlockAttempt = {}
	local lastForgetAttempt = {}
	local UNLOCK_COOLDOWN = 1.0
	local FORGET_COOLDOWN = 1.0

	hook.Add("PlayerDisconnected", "Arcana_ClearUnlockCooldown", function(ply)
		lastUnlockAttempt[ply:SteamID64()] = nil
		lastForgetAttempt[ply:SteamID64()] = nil
	end)

	net.Receive("Arcana_UnlockSpell", function(len, ply)
		local sid = ply:SteamID64()
		local now = CurTime()
		if (lastUnlockAttempt[sid] or 0) + UNLOCK_COOLDOWN > now then return end
		lastUnlockAttempt[sid] = now
		local spellId = net.ReadString()
		Arcana:UnlockSpell(ply, spellId)
	end)

	net.Receive("Arcana_ForgetSpell", function(len, ply)
		local sid = ply:SteamID64()
		local now = CurTime()
		if (lastForgetAttempt[sid] or 0) + FORGET_COOLDOWN > now then return end
		lastForgetAttempt[sid] = now
		local spellId = net.ReadString()
		Arcana:ForgetSpell(ply, spellId)
	end)
end

if CLIENT then
	net.Receive("Arcana_XPUpdate", function()
		local xp = net.ReadUInt(32)
		local level = net.ReadUInt(16)
		local xpGained = net.ReadUInt(32)
		local reason = net.ReadString()
		local ply = LocalPlayer()
		if not IsValid(ply) then return end
		local data = Arcana:GetPlayerData(ply)
		if not data then return end
		data.xp = xp
		data.level = level
		if xpGained > 0 then
			if Arcana.HUD and Arcana.HUD.ShowXPAnnouncement then
				Arcana.HUD.ShowXPAnnouncement(ply, xpGained, reason)
			end
			Arcana.RunHook("PlayerGainedXP", ply, xpGained, reason)
		end
	end)

	net.Receive("Arcana_LevelUp", function()
		local newLevel = net.ReadUInt(16)
		local newKnowledgeTotal = net.ReadUInt(16)
		local ply = LocalPlayer()
		if not IsValid(ply) then return end
		local data = Arcana:GetPlayerData(ply)
		if not data then return end
		local prevLevel = data.level or 1
		local prevKnowledge = data.knowledge_points or 0
		data.level = newLevel
		data.knowledge_points = newKnowledgeTotal
		local knowledgeDelta = math.max(0, newKnowledgeTotal - prevKnowledge)
		if Arcana.HUD and Arcana.HUD.ShowLevelUpAnnouncement then
			Arcana.HUD.ShowLevelUpAnnouncement(prevLevel, newLevel, knowledgeDelta)
		end
		Arcana.RunHook("ClientLevelUp", prevLevel, newLevel, knowledgeDelta)
	end)
end
