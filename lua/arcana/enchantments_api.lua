-- Arcana Enchantment API
-- Manages registration, querying, application, and removal of weapon enchantments.

Arcana = Arcana or {}

-- Store enchantments on weapon entities directly
local function ensureEntityEnchantTable(wep)
	if not IsValid(wep) then return {} end
	wep.ArcanaEnchantments = wep.ArcanaEnchantments or {}
	return wep.ArcanaEnchantments
end

local function syncWeaponEnchantNW(wep)
	if not IsValid(wep) then return end
	local list = ensureEntityEnchantTable(wep)
	local ids = {}
	for id, v in pairs(list) do if v then ids[#ids + 1] = id end end
	local json = util.TableToJSON(ids) or "[]"
	if wep.SetNWString then
		wep:SetNWString("Arcana_EnchantIds", json)
	end
end
-- Enchantment API
-- RegisterEnchantment(def) — registers an enchantment with the following fields:
--   id (string): unique identifier
--   name (string): display name
--   description (string): tooltip text
--   icon (string): icon path
--   cost_coins (number): coin cost to apply via enchanter
--   cost_items (array): [{name, amount}] items required
--   can_apply(ply, wep) -> (bool, reason?): pre-apply validation
--   apply(ply, wep, state): attach runtime behavior (hooks, etc.) to the weapon
--   remove(ply, wep, state): remove runtime behavior when enchantment is stripped
--   max_stacks (number, default 1): max simultaneous applications
--   grants_xp (bool, default true): whether a successful apply awards XP via GiveXP.
--     Set to false for system-applied enchantments (e.g., vault restore) that should not grant XP.
function Arcana:RegisterEnchantment(def)
	if not istable(def) then
		ErrorNoHalt("RegisterEnchantment requires a table definition\n")
		return false
	end

	local id = tostring(def.id or "")
	local name = def.name or id
	if id == "" then
		ErrorNoHalt("RegisterEnchantment missing id\n")
		return false
	end

	-- defaults
	local ench = {
		id = id,
		name = name,
		description = def.description or "Mystic modification to a weapon",
		icon = def.icon or "icon16/wand.png",
		-- Requirements/costs
		cost_coins = tonumber(def.cost_coins or 0) or 0,
		cost_items = istable(def.cost_items) and def.cost_items or { -- array of {name="mana_crystal_shard", amount=5}
			{name = "mana_crystal_shard", amount = 1}
		},
		-- Applicability: return (bool, reason) — reason is a human-readable string on failure, matching can_cast contract
		can_apply = def.can_apply, -- function(ply, wep) -> (bool, reason?)
		-- Apply/remove: attach runtime behavior (e.g., hooks) to the weapon
		apply = def.apply,   -- function(ply, wep, state)
		remove = def.remove, -- function(ply, wep, state)
		-- Optional: maximum stacks or config
		max_stacks = tonumber(def.max_stacks or 1) or 1,
		-- Whether a successful apply grants XP (default true); set false for system-applied enchantments
		grants_xp = (def.grants_xp ~= false),
	}

	Arcana.RegisteredEnchantments[id] = ench
	Arcana:Print("Registered enchantment '" .. name .. "' (ID: " .. id .. ")")
	return true
end

function Arcana:GetEntityEnchantments(wep)
	if not IsValid(wep) then return {} end

	if SERVER then
		return ensureEntityEnchantTable(wep)
	end

	if CLIENT then
		if istable(wep.ArcanaEnchantments) and wep.ArcanaEnchantmentsNextUpdate and wep.ArcanaEnchantmentsNextUpdate > CurTime() then
			return wep.ArcanaEnchantments
		end

		wep.ArcanaEnchantmentsNextUpdate = CurTime() + 0.5

		local appliedSet = {}
		local json = wep:GetNWString("Arcana_EnchantIds", "[]")
		local ok, arr = pcall(util.JSONToTable, json)
		if ok and istable(arr) then
			for _, id in ipairs(arr) do
				appliedSet[id] = true
			end
		end

		wep.ArcanaEnchantments = appliedSet
		return wep.ArcanaEnchantments
	end
end

function Arcana:HasEntityEnchantment(wep, enchId)
	local list = self:GetEntityEnchantments(wep)
	return list[enchId] ~= nil
end

-- Apply/remove on a specific weapon entity instance.
-- skipXP: if true, overrides the enchantment's grants_xp field and suppresses XP award (e.g., vault restore).
function Arcana:ApplyEnchantmentToWeaponEntity(ply, wep, enchId, skipXP)
	if not IsValid(ply) then return false, "Invalid player" end
	if not IsValid(wep) then return false, "Invalid weapon" end

	local ench = (Arcana.RegisteredEnchantments or {})[enchId]
	if not ench then return false, "Unknown enchantment" end

	local list = ensureEntityEnchantTable(wep)
	if list[enchId] then return false, "Already enchanted" end

	local count = 0
	for _ in pairs(list) do count = count + 1 end
	if count >= 3 then return false, "Max enchantments reached" end

	local ok, reason = Arcana.RunHook("CanApplyEnchantment", ply, wep, enchId)
	if ok == false then return false, reason or "Enchantment not allowed" end

	list[enchId] = { stacks = 1, applied_at = os.time() }
	syncWeaponEnchantNW(wep)

	if ench.apply then
		local ok, err = pcall(ench.apply, ply, wep, list[enchId])
		if not ok then ErrorNoHalt("Enchantment apply error: " .. tostring(err) .. "\n") end
	end

	-- Award XP if allowed by both the enchantment definition and the call site
	if SERVER and not skipXP and ench.grants_xp then
		local amount = tonumber(self.Config.XP_PER_ENCHANT_SUCCESS) or 20
		self:GiveXP(ply, amount, "Enchantment: " .. (ench.name or enchId))
	end

	Arcana.RunHook("AppliedEnchantment", ply, wep, enchId)
	return true
end

-- Restores an enchantment to a weapon without awarding XP.
-- Use for system operations (e.g. vault restore) where XP should not be granted.
-- Semantically distinct from ApplyEnchantmentToWeaponEntity which awards XP by default.
function Arcana:RestoreEnchantmentToWeaponEntity(ply, wep, enchId)
	return self:ApplyEnchantmentToWeaponEntity(ply, wep, enchId, true)
end

function Arcana:RemoveEnchantmentFromWeaponEntity(ply, wep, enchId)
	if not IsValid(ply) then return false, "Invalid player" end
	if not IsValid(wep) then return false, "Invalid weapon" end

	local ench = (Arcana.RegisteredEnchantments or {})[enchId]
	local list = ensureEntityEnchantTable(wep)
	if not list[enchId] then return false, "Not applied" end

	if ench and ench.remove then
		local ok, err = pcall(ench.remove, ply, wep, list[enchId])
		if not ok then ErrorNoHalt("Enchantment remove error: " .. tostring(err) .. "\n") end
	end

	list[enchId] = nil
	syncWeaponEnchantNW(wep)

	Arcana.RunHook("RemovedEnchantment", ply, wep, enchId)
	return true
end

Arcana.SyncWeaponEnchantNW = syncWeaponEnchantNW

if SERVER then
	hook.Add("EntityRemoved", "Arcana_CleanupWeaponEnchantments", function(ent)
		if not ent or not ent.ArcanaEnchantments then return end
		local list = ent.ArcanaEnchantments
		local owner = (ent.GetOwner and ent:GetOwner()) or nil
		for enchId, state in pairs(list) do
			local ench = (Arcana.RegisteredEnchantments or {})[enchId]
			if ench and ench.remove then
				local ok, err = pcall(ench.remove, (IsValid(owner) and owner) or game.GetWorld(), ent, state)
				if not ok then ErrorNoHalt("Enchantment remove error on entity removal: " .. tostring(err) .. "\n") end
			end
		end
		ent.ArcanaEnchantments = nil
	end)
end