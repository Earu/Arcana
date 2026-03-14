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
			if spell and not spell.is_divine_pact then
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

	local lastUnlockAttempt = {}
	local UNLOCK_COOLDOWN = 1.0

	hook.Add("PlayerDisconnected", "Arcana_ClearUnlockCooldown", function(ply)
		lastUnlockAttempt[ply:SteamID64()] = nil
	end)

	net.Receive("Arcana_UnlockSpell", function(len, ply)
		local sid = ply:SteamID64()
		local now = CurTime()
		if (lastUnlockAttempt[sid] or 0) + UNLOCK_COOLDOWN > now then return end
		lastUnlockAttempt[sid] = now
		local spellId = net.ReadString()
		Arcana:UnlockSpell(ply, spellId)
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
