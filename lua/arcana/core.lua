AddCSLuaFile()
-- Arcane Magic System Core
-- A comprehensive magic system for Garry's Mod featuring spells, rituals, and progression
local Arcane = _G.Arcane or {}
_G.Arcane = Arcane

function Arcane:Print(...)
	MsgC(Color(147, 112, 219), "[Arcana] ", Color(255, 255, 255), table.concat({...}, " "), "\n")
end

-- Client-side stub for autocomplete and help so players see the command
if CLIENT then
	local function arcanaAutoComplete(cmd, stringargs)
		local input = string.lower(string.Trim(stringargs or ""))
		local out = {}

		for id, sp in pairs(Arcane and Arcane.RegisteredSpells or {}) do
			local idLower = string.lower(id)
			local nameLower = string.lower(sp.name or id)

			if input == "" or string.find(idLower, input, 1, true) or string.find(nameLower, input, 1, true) then
				out[#out + 1] = cmd .. " " .. id
			end
		end

		table.sort(out)

		return out
	end

	-- Forward to server so typing in client console still works
	concommand.Add("arcana", function(_, _, args)
		local raw = tostring(args and args[1] or "")
		local spellId = string.lower(string.Trim(raw))

		if spellId == "" then
			Arcane:Print("Usage: arcana <spellId>")

			return
		end

		net.Start("Arcane_ConsoleCastSpell")
		net.WriteString(spellId)
		net.SendToServer()
	end, arcanaAutoComplete, "Cast an Arcana spell: arcana <spellId>")
end

-- Configuration
Arcane.Config = {
	-- XP and Leveling
	BASE_XP_REQUIRED = 75,
	XP_MULTIPLIER = 1.25,
	KNOWLEDGE_POINTS_PER_LEVEL = 1,
	MAX_LEVEL = 100,
	-- Full XP is awarded at this cast time; shorter casts scale down, longer casts scale up (clamped)
	XP_BASE_CAST_TIME = 1.0,
	-- XP gained per successful enchantment application (applied per enchant)
	XP_PER_ENCHANT_SUCCESS = 20,
	-- Spell Configuration
	DEFAULT_SPELL_COOLDOWN = 1.0,
	RITUAL_CASTING_TIME = 10.0,
	-- Database
	DATABASE_FILE = "arcane_data.txt"
}

-- Storage for registered spells
Arcane.RegisteredSpells = Arcane.RegisteredSpells or {}
Arcane.PlayerData = Arcane.PlayerData or {}
-- Storage for registered weapon enchantments
Arcane.RegisteredEnchantments = Arcane.RegisteredEnchantments or {}

-- Spell cost types
Arcane.COST_TYPES = {
	COINS = "coins",
	HEALTH = "health",
	ITEMS = "items"
}

-- Spell/Ritual categories
Arcane.CATEGORIES = {
	COMBAT = "combat",
	UTILITY = "utility",
	PROTECTION = "protection",
	SUMMONING = "summoning",
	DIVINATION = "divination",
	ENCHANTMENT = "enchantment"
}

-- Enchantment API
function Arcane:RegisterEnchantment(def)
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
		-- Applicability: return true if weapon can accept this enchantment
		can_apply = def.can_apply, -- function(ply, wep)
		-- Apply/remove: attach runtime behavior (e.g., hooks) to the weapon
		apply = def.apply,   -- function(ply, wep, state)
		remove = def.remove, -- function(ply, wep, state)
		-- Optional: maximum stacks or config
		max_stacks = tonumber(def.max_stacks or 1) or 1,
	}

	Arcane.RegisteredEnchantments[id] = ench
	Arcane:Print("Registered enchantment '" .. name .. "' (ID: " .. id .. ")")
	return true
end

function Arcane:GetEnchantments()
	return Arcane.RegisteredEnchantments or {}
end

-- Store enchantments on weapon entities directly
local function ensureEntityEnchantTable(wep)
	if not IsValid(wep) then return {} end

	wep.ArcanaEnchantments = wep.ArcanaEnchantments or {}
	return wep.ArcanaEnchantments
end

function Arcane:GetEntityEnchantments(wep)
	if not IsValid(wep) then return {} end
	return ensureEntityEnchantTable(wep)
end

function Arcane:HasEntityEnchantment(wep, enchId)
	local list = self:GetEntityEnchantments(wep)
	return list[enchId] ~= nil
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

-- Apply/remove on a specific weapon entity instance
function Arcane:ApplyEnchantmentToWeaponEntity(ply, wep, enchId, skipXP)
	if not IsValid(ply) then return false, "Invalid player" end
	if not IsValid(wep) then return false, "Invalid weapon" end

	local ench = (Arcane.RegisteredEnchantments or {})[enchId]
	if not ench then return false, "Unknown enchantment" end

	local list = ensureEntityEnchantTable(wep)
	if list[enchId] then return false, "Already enchanted" end

	local count = 0
	for _ in pairs(list) do count = count + 1 end
	if count >= 3 then return false, "Max enchantments reached" end

	list[enchId] = { stacks = 1, applied_at = os.time() }
	syncWeaponEnchantNW(wep)

	if ench.apply then
		local ok, err = pcall(ench.apply, ply, wep, list[enchId])
		if not ok then ErrorNoHalt("Enchantment apply error: " .. tostring(err) .. "\n") end
	end

	if self.UpdateWeaponEnchantmentVFX then
		self:UpdateWeaponEnchantmentVFX(ply, wep)
	end

	-- Award XP for a successful enchantment application
	if SERVER and not skipXP then
		local amount = tonumber(self.Config.XP_PER_ENCHANT_SUCCESS) or 20
		self:GiveXP(ply, amount, "Enchantment: " .. (ench.name or enchId))
	end

	return true
end

function Arcane:RemoveEnchantmentFromWeaponEntity(ply, wep, enchId)
	if not IsValid(ply) then return false, "Invalid player" end
	if not IsValid(wep) then return false, "Invalid weapon" end

	local ench = (Arcane.RegisteredEnchantments or {})[enchId]
	local list = ensureEntityEnchantTable(wep)
	if not list[enchId] then return false, "Not applied" end

	if ench and ench.remove then
		local ok, err = pcall(ench.remove, ply, wep, list[enchId])
		if not ok then ErrorNoHalt("Enchantment remove error: " .. tostring(err) .. "\n") end
	end

	list[enchId] = nil
	syncWeaponEnchantNW(wep)

	if self.UpdateWeaponEnchantmentVFX then
		self:UpdateWeaponEnchantmentVFX(ply, wep)
	end

	return true
end

-- Player data structure
local function CreateDefaultPlayerData()
	-- Note: coins are managed by your existing system
	-- Quickspell system
	return {
		xp = 0,
		level = 1,
		knowledge_points = Arcane.Config.KNOWLEDGE_POINTS_PER_LEVEL,
		unlocked_spells = {},
		spell_cooldowns = {},
		active_effects = {},
		quickspell_slots = {nil, nil, nil, nil, nil, nil, nil, nil},
		selected_quickslot = 1,
		last_save = os.time()
	}
end

-- Server-side persistence
if SERVER then
	local function dbLogError(prefix)
		local err = sql.LastError() or "unknown error"
		MsgC(Color(255, 80, 80), "[Arcana][SQL] ", Color(255, 255, 255), prefix .. ": " .. tostring(err) .. "\n")
	end

	local ensured = false
	-- Per-player gating to prevent saving until a successful initial DB load
	Arcane.SaveBlockedBySteamID = Arcane.SaveBlockedBySteamID or {}
	Arcane.RetryStateBySteamID = Arcane.RetryStateBySteamID or {}

	local function ensureDatabase()
		if ensured then return ensured end

		if _G.co and _G.db then
			-- if we have postgres use it
			_G.co(function()
				_G.db.Query([[CREATE TABLE IF NOT EXISTS arcane_players (
					steamid	VARCHAR(255) PRIMARY KEY,
					xp BIGINT NOT NULL DEFAULT 0,
					level BIGINT NOT NULL DEFAULT 1,
					knowledge_points BIGINT NOT NULL DEFAULT 1,
					unlocked_spells TEXT NOT NULL DEFAULT '[]',
					quickspell_slots TEXT NOT NULL DEFAULT '[]',
					selected_quickslot INTEGER NOT NULL DEFAULT 1,
					last_save BIGINT NOT NULL DEFAULT 0
				)]])
			end)

			ensured = true

			return ensured
		else
			-- fallback to sqlite
			if sql.TableExists("arcane_players") then
				ensured = true

				return ensured
			end

			local ok = sql.Query([[CREATE TABLE IF NOT EXISTS arcane_players (
				steamid	TEXT PRIMARY KEY,
				xp INTEGER NOT NULL DEFAULT 0,
				level INTEGER NOT NULL DEFAULT 1,
				knowledge_points INTEGER NOT NULL DEFAULT 1,
				unlocked_spells TEXT NOT NULL DEFAULT '[]',
				quickspell_slots TEXT NOT NULL DEFAULT '[]',
				selected_quickslot INTEGER NOT NULL DEFAULT 1,
				last_save INTEGER NOT NULL DEFAULT 0
			);]])

			if ok == false then
				dbLogError("CREATE TABLE arcane_players failed")
				ensured = false

				return ensured
			end

			ensured = true

			return ensured
		end
	end

	local function serializeUnlockedSpells(unlocked)
		-- store as array of ids for compactness
		local arr = {}

		for id, v in pairs(unlocked or {}) do
			if v then
				arr[#arr + 1] = id
			end
		end

		return util.TableToJSON(arr or {}) or "[]"
	end

	local function deserializeUnlockedSpells(json)
		json = json or "[]"
		json = json:gsub("^\'", ""):gsub("\'$", "")
		local ok, data = pcall(util.JSONToTable, json)
		local map = {}

		if ok and istable(data) then
			for _, id in ipairs(data) do
				map[tostring(id)] = true
			end
		end

		return map
	end

	local function serializeQuickslots(slots)
		-- preserve 8 positions; encode as array of strings with empty string for nil
		local out = {}

		for i = 1, 8 do
			out[i] = tostring(slots and slots[i] or "")

			if out[i] == "nil" then
				out[i] = ""
			end
		end

		return util.TableToJSON(out) or "[]"
	end

	local function deserializeQuickslots(json)
		json = json or "[]"
		json = json:gsub("^\'", ""):gsub("\'$", "")
		local ok, arr = pcall(util.JSONToTable, json)

		local slots = {nil, nil, nil, nil, nil, nil, nil, nil}

		if ok and istable(arr) then
			for i = 1, 8 do
				local v = arr[i]

				if isstring(v) and v ~= "" then
					slots[i] = v
				end
			end
		end

		return slots
	end

	function Arcane:SavePlayerDataToSQL(ply, data)
		if not ensureDatabase() then return end

		local sid = IsValid(ply) and ply:SteamID64() or nil
		if sid and Arcane.SaveBlockedBySteamID[sid] then return end

		local steamid = sql.SQLStr(ply:SteamID64(), true)
		local incoming_xp = tonumber(data.xp) or 0
		local incoming_level = tonumber(data.level) or 1
		local incoming_kp = tonumber(data.knowledge_points) or 0
		local incoming_unlocked_map = data.unlocked_spells or {}
		local incoming_quickslots = data.quickspell_slots or {nil, nil, nil, nil, nil, nil, nil, nil}
		local incoming_selected = tonumber(data.selected_quickslot) or 1
		local lastsave = tonumber(data.last_save) or os.time()

		-- Merge strategy to prevent data loss if an earlier load failed:
		-- - xp/level: take max(existing, incoming)
		-- - knowledge_points: ignore existing and use incoming
		-- - unlocked_spells: union
		-- - quickslots: prefer incoming when set, otherwise keep existing
		-- - selected_quickslot: prefer incoming if valid
		local function mergeWithExistingRow(row)
			if not istable(row) then
				return incoming_xp, incoming_level, incoming_unlocked_map, incoming_quickslots, incoming_selected
			end

			local existing_xp = tonumber(row.xp) or 0
			local existing_level = tonumber(row.level) or 1
			local existing_unlocked = deserializeUnlockedSpells(row.unlocked_spells)
			local existing_quick = deserializeQuickslots(row.quickspell_slots)
			local existing_selected = tonumber(row.selected_quickslot) or 1

			local merged_xp = math.max(existing_xp, incoming_xp)
			local merged_level = math.max(existing_level, incoming_level)

			local merged_unlocked = {}
			for id, v in pairs(existing_unlocked or {}) do if v then merged_unlocked[id] = true end end
			for id, v in pairs(incoming_unlocked_map or {}) do if v then merged_unlocked[id] = true end end

			local merged_quick = {nil, nil, nil, nil, nil, nil, nil, nil}
			for i = 1, 8 do
				merged_quick[i] = incoming_quickslots and incoming_quickslots[i] or nil
				if not merged_quick[i] or merged_quick[i] == "" then
					merged_quick[i] = existing_quick and existing_quick[i] or nil
				end
			end

			local merged_selected = (incoming_selected >= 1 and incoming_selected <= 8) and incoming_selected or existing_selected

			return merged_xp, merged_level, merged_unlocked, merged_quick, merged_selected
		end

		if _G.co and _G.db then
			-- if we have postgres use it
			_G.co(function()
				-- Read existing row to merge conservatively
				local existing = _G.db.Query("SELECT * FROM arcane_players WHERE steamid = $1 LIMIT 1", steamid)
				local mxp, mlevel, munlocked_map, mquick, mselected = mergeWithExistingRow(istable(existing) and existing[1] or nil)
				local unlocked = sql.SQLStr(serializeUnlockedSpells(munlocked_map))
				local quick = sql.SQLStr(serializeQuickslots(mquick))
				local upsert = [[
					INSERT INTO arcane_players(steamid, xp, level, knowledge_points, unlocked_spells, quickspell_slots, selected_quickslot, last_save)
					VALUES($1, $2, $3, $4, $5, $6, $7, $8)
					ON CONFLICT (steamid) DO UPDATE SET
						xp = EXCLUDED.xp,
						level = EXCLUDED.level,
						knowledge_points = EXCLUDED.knowledge_points,
						unlocked_spells = EXCLUDED.unlocked_spells,
						quickspell_slots = EXCLUDED.quickspell_slots,
						selected_quickslot = EXCLUDED.selected_quickslot,
						last_save = EXCLUDED.last_save
				]]
				_G.db.Query(upsert, steamid, mxp, mlevel, incoming_kp, unlocked, quick, mselected, lastsave)
			end)

			return
		else
			-- fallback to sqlite
			local rows = sql.Query("SELECT * FROM arcane_players WHERE steamid = '" .. steamid .. "' LIMIT 1;")
			local mxp, mlevel, munlocked_map, mquick, mselected = mergeWithExistingRow(istable(rows) and rows[1] or nil)
			local unlocked = sql.SQLStr(serializeUnlockedSpells(munlocked_map))
			local quick = sql.SQLStr(serializeQuickslots(mquick))
			local q = string.format("INSERT OR REPLACE INTO arcane_players (steamid, xp, level, knowledge_points, unlocked_spells, quickspell_slots, selected_quickslot, last_save) VALUES ('%s', %d, %d, %d, %s, %s, %d, %d);", steamid, mxp, mlevel, incoming_kp, unlocked, quick, mselected, lastsave)
			local ok = sql.Query(q)

			if ok == false then
				dbLogError("SavePlayerDataToSQL failed")
			end
		end
	end

	function Arcane:LoadPlayerDataFromSQL(ply, callback)
		if not ensureDatabase() then return nil end
		if not IsValid(ply) then return end

		local rawSid = ply:SteamID64()
		Arcane.SaveBlockedBySteamID[rawSid] = true

		local function processData(row)
			local data = CreateDefaultPlayerData()
			data.xp = tonumber(row.xp) or data.xp
			data.level = tonumber(row.level) or data.level
			data.knowledge_points = tonumber(row.knowledge_points) or data.knowledge_points
			data.unlocked_spells = deserializeUnlockedSpells(row.unlocked_spells)
			data.quickspell_slots = deserializeQuickslots(row.quickspell_slots)
			data.selected_quickslot = tonumber(row.selected_quickslot) or data.selected_quickslot
			data.last_save = tonumber(row.last_save) or data.last_save
			Arcane.SaveBlockedBySteamID[rawSid] = nil
			Arcane.RetryStateBySteamID[rawSid] = nil
			callback(true, data)
		end

		local steamid = sql.SQLStr(rawSid, true)

		local function scheduleRetry()
			local state = Arcane.RetryStateBySteamID[rawSid] or {delay = 1}
			Arcane.RetryStateBySteamID[rawSid] = state

			local tname = "Arcana_RetryLoad_" .. tostring(rawSid)
			timer.Remove(tname)
			timer.Create(tname, state.delay, 1, function()
				if not IsValid(ply) then return end
				state.delay = math.min((state.delay or 1) * 2, 60)
				Arcane:LoadPlayerDataFromSQL(ply, callback)
			end)
		end

		if _G.co and _G.db then
			-- if we have postgres use it
			_G.co(function()
				local rows = _G.db.Query("SELECT * FROM arcane_players WHERE steamid = $1 LIMIT 1", steamid)
				if rows == false or rows == nil then
					scheduleRetry()
					return
				end

				if istable(rows) and #rows < 1 then
					-- No existing row: treat as success with defaults and allow saving
					Arcane.SaveBlockedBySteamID[rawSid] = nil
					Arcane.RetryStateBySteamID[rawSid] = nil

					local defaults = CreateDefaultPlayerData()
					callback(true, defaults)

					Arcane:SavePlayerDataToSQL(ply, defaults)
					return
				end

				processData(rows[1])
			end)
		else
			-- fallback to sqlite
			rows = sql.Query("SELECT * FROM arcane_players WHERE steamid = '" .. steamid .. "' LIMIT 1;")
			if rows == false then
				dbLogError("LoadPlayerDataFromSQL failed")
				scheduleRetry()
				return
			end

			if not rows or not rows[1] then
				Arcane.SaveBlockedBySteamID[rawSid] = nil
				Arcane.RetryStateBySteamID[rawSid] = nil

				local defaults = CreateDefaultPlayerData()
				callback(true, defaults)

				Arcane:SavePlayerDataToSQL(ply, defaults)
				return
			end

			processData(rows[1])
		end
	end
end

-- Utility Functions
function Arcane:GetXPRequiredForLevel(level)
	return math.floor(Arcane.Config.BASE_XP_REQUIRED * (Arcane.Config.XP_MULTIPLIER ^ (level - 1)))
end

function Arcane:GetTotalXPForLevel(level)
	local total = 0

	for i = 1, level - 1 do
		total = total + self:GetXPRequiredForLevel(i)
	end

	return total
end

-- Player Data Management
function Arcane:GetPlayerData(ply)
	local steamid = ply:SteamID64()

	if not self.PlayerData[steamid] then
		self.PlayerData[steamid] = CreateDefaultPlayerData()
	end

	return self.PlayerData[steamid]
end

function Arcane:SavePlayerData(ply)
	if not IsValid(ply) then return end

	local sid = ply:SteamID64()
	if Arcane.SaveBlockedBySteamID[sid] then return end

	local data = self:GetPlayerData(ply)
	data.last_save = os.time()

	if SERVER then
		self:SavePlayerDataToSQL(ply, data)
	end
end

function Arcane:LoadPlayerData(ply, callback)
	if not IsValid(ply) then return end
	local steamid = ply:SteamID64()

	if SERVER then
		self:LoadPlayerDataFromSQL(ply, function(loaded, data)
			self.PlayerData[steamid] = data
			callback()
		end)
	else
		if not self.PlayerData[steamid] then
			self.PlayerData[steamid] = CreateDefaultPlayerData()
		end

		callback()
	end
end

-- Networking helpers
if SERVER then
	util.AddNetworkString("Arcane_FullSync")
	util.AddNetworkString("Arcane_SetQuickslot")
	util.AddNetworkString("Arcane_SetSelectedQuickslot")
	util.AddNetworkString("Arcane_BeginCasting")
	util.AddNetworkString("Arcane_PlayCastGesture")
	util.AddNetworkString("Arcane_SpellFailed")
	util.AddNetworkString("Arcana_AttachBandVFX")
	util.AddNetworkString("Arcana_ClearBandVFX")
	util.AddNetworkString("Arcana_AttachParticles")
	util.AddNetworkString("Arcane_ConsoleCastSpell")
	util.AddNetworkString("Arcane_ErrorNotification")
	util.AddNetworkString("Arcane_SpellUnlocked")

	function Arcane:SyncPlayerData(ply)
		if not IsValid(ply) then return end
		local data = self:GetPlayerData(ply)

		local payload = {
			xp = data.xp,
			level = data.level,
			knowledge_points = data.knowledge_points,
			unlocked_spells = table.Copy(data.unlocked_spells),
			spell_cooldowns = table.Copy(data.spell_cooldowns),
			quickspell_slots = table.Copy(data.quickspell_slots),
			selected_quickslot = data.selected_quickslot,
		}

		net.Start("Arcane_FullSync")
		net.WriteTable(payload)
		net.Send(ply)
	end
end

if SERVER then
	function Arcane:SendErrorNotification(ply, msg)
		if not IsValid(ply) then return end
		ply:EmitSound("buttons/button8.wav", 100, 120)
		net.Start("Arcane_ErrorNotification")
		net.WriteString(msg)
		net.Send(ply)
	end
end

if CLIENT then
	net.Receive("Arcane_ErrorNotification", function()
		local msg = net.ReadString()
		Arcane:Print(msg)
		notification.AddLegacy(msg, NOTIFY_ERROR, 5)
	end)
end

-- Begin casting with a minimum cast time and broadcast evolving circle
function Arcane:StartCasting(ply, spellId)
	if not IsValid(ply) then return false end
	local canCast, reason = self:CanCastSpell(ply, spellId)

	if not canCast then
		if SERVER then
			Arcane:SendErrorNotification(ply, "Cannot cast spell \"" .. spellId .. "\": " .. reason)
		end

		return false
	end

	local spell = self.RegisteredSpells[spellId]
	local castTime = math.max(0.1, spell.cast_time or 0)

	local pdata = self:GetPlayerData(ply)
	if pdata then
		pdata.casting_until = CurTime() + castTime
		pdata.casting_spell = spellId
	end

	-- Decide gesture and broadcast to clients to play locally
	if SERVER then
		local forwardLike = spell.cast_anim == "forward" or spell.is_projectile or spell.has_target or ((spell.range or 0) > 0)
		local gesture = forwardLike and ACT_SIGNAL_FORWARD or ACT_GMOD_GESTURE_BECON

		if gesture then
			net.Start("Arcane_PlayCastGesture", true)
			net.WriteEntity(ply)
			net.WriteInt(gesture, 16)
			net.Broadcast()
		end

		-- Tell clients to show evolving circle for this cast
		net.Start("Arcane_BeginCasting", true)
		net.WriteEntity(ply)
		net.WriteString(spellId)
		net.WriteFloat(castTime)
		net.WriteBool(forwardLike)
		net.Broadcast()

		-- Schedule execution after cast time
		timer.Simple(castTime, function()
			if not IsValid(ply) then return end
			-- Clear casting lock before final validation and execution
			local d = self:GetPlayerData(ply)
			if d then
				d.casting_until = nil
				d.casting_spell = nil
			end
			-- Re-check basic conditions before executing
			local ok, _ = self:CanCastSpell(ply, spellId)
			if not ok then
				net.Start("Arcane_SpellFailed", true)
				net.WriteEntity(ply)
				net.WriteFloat(castTime)
				net.Broadcast()

				return
			end
			-- Recompute circle context at actual cast moment so it follows the player
			local ctxPos = ply:GetPos() + Vector(0, 0, 2)
			local ctxAng = Angle(0, 180, 180)
			local ctxSize = 60

			if forwardLike then
				local maxsNow = ply:OBBMaxs()
				ctxPos = ply:GetPos() + ply:GetForward() * maxsNow.x * 1.5 + ply:GetUp() * maxsNow.z / 2
				ctxAng = ply:EyeAngles()
				ctxAng:RotateAroundAxis(ctxAng:Right(), 90)
				ctxSize = 30
			end

			self:CastSpell(ply, spellId, nil, {
				circlePos = ctxPos,
				circleAng = ctxAng,
				circleSize = ctxSize,
				forwardLike = forwardLike,
				castTime = castTime,
			})
		end)
	end

	return true
end

-- XP and Leveling System
function Arcane:GiveXP(ply, amount, reason)
	if not IsValid(ply) or amount <= 0 then return false end
	local data = self:GetPlayerData(ply)
	local oldLevel = data.level
	data.xp = data.xp + amount
	-- Check for level up
	local newLevel = self:CalculateLevel(data.xp)

	if newLevel > oldLevel then
		self:LevelUp(ply, oldLevel, newLevel)
	end

	-- Network update
	if SERVER then
		net.Start("Arcane_XPUpdate")
		net.WriteUInt(data.xp, 32)
		net.WriteUInt(data.level, 16)
		net.WriteString(reason or "Unknown")
		net.Send(ply)
	end

	self:SavePlayerData(ply)

	return true
end

function Arcane:CalculateLevel(totalXP)
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

function Arcane:LevelUp(ply, oldLevel, newLevel)
	local data = self:GetPlayerData(ply)
	local levelsGained = newLevel - oldLevel
	data.level = newLevel
	data.knowledge_points = data.knowledge_points + (levelsGained * Arcane.Config.KNOWLEDGE_POINTS_PER_LEVEL)

	-- Notify player
	if SERVER then
		-- Network level up notification
		net.Start("Arcane_LevelUp")
		net.WriteUInt(newLevel, 16)
		net.WriteUInt(data.knowledge_points, 16)
		net.Send(ply)
		-- Ensure client has up-to-date totals
		self:SyncPlayerData(ply)
	end

	-- Hook for other addons
	hook.Run("Arcane_PlayerLevelUp", ply, oldLevel, newLevel, data.knowledge_points)
end

-- Spell Registration API
function Arcane:RegisterSpell(spellData)
	if not spellData.id or not spellData.name or not spellData.cast then
		ErrorNoHalt("Spell registration requires id, name, and cast function")

		return false
	end

	-- Default values
	local spell = {
		id = spellData.id,
		name = spellData.name,
		description = spellData.description or "A mysterious spell",
		category = spellData.category or Arcane.CATEGORIES.UTILITY,
		level_required = spellData.level_required or 1,
		knowledge_cost = spellData.knowledge_cost or 1,
		cooldown = spellData.cooldown or Arcane.Config.DEFAULT_SPELL_COOLDOWN,
		cost_type = spellData.cost_type or Arcane.COST_TYPES.COINS,
		cost_amount = spellData.cost_amount or 10,
		cast_time = spellData.cast_time or 0, -- Instant by default
		range = spellData.range or 500,
		icon = spellData.icon or "icon16/wand.png",
		-- Functions
		cast = spellData.cast, -- function(caster, target, data)
		can_cast = spellData.can_cast, -- function(caster, target, data) - optional validation
		on_success = spellData.on_success, -- function(caster, target, data) - optional callback
		on_failure = spellData.on_failure, -- function(caster, target, data) - optional callback
		-- Animation hints -- If provided, these help decide which player gesture to play during casting
		is_projectile = spellData.is_projectile, -- boolean
		has_target = spellData.has_target, -- boolean (clear aimed target/point)
		cast_anim = spellData.cast_anim -- optional explicit act name, e.g., "forward" or "becon"

	}

	self.RegisteredSpells[spell.id] = spell
	if CLIENT and Arcane.AddTriggerPhrase then
		Arcane:AddTriggerPhrase(spell.name, spell.id)

		if istable(spellData.trigger_phrase_aliases) then
			for _, phrase in ipairs(spellData.trigger_phrase_aliases) do
				Arcane:AddTriggerPhrase(phrase, spell.id)
			end
		end
	end

	self:Print("Registered spell '" .. spell.name .. "' (ID: " .. spell.id .. "')\n")

	return true
end

function Arcane:RegisterRitualSpell(opts)
	if not istable(opts) then
		ErrorNoHalt("RegisterRitualSpell requires an options table\n")

		return false
	end

	local id = opts.id
	local name = opts.name

	if not id or not name then
		ErrorNoHalt("RegisterRitualSpell requires id and name\n")

		return false
	end

	local function defaultCanCast(caster)
		if not IsValid(caster) then return false, "Invalid caster" end

		return true
	end

	local function ritualCast(caster)
		if CLIENT then return true end
		if not IsValid(caster) then return false end
		local eye = caster:EyeAngles()
		local pos = caster:GetEyeTrace().HitPos
		local ent = ents.Create("arcana_ritual")
		if not IsValid(ent) then return false end
		ent:SetPos(pos)
		ent:SetAngles(Angle(0, eye.y, 0))

		if IsColor(opts.ritual_color) then
			ent:SetColor(opts.ritual_color)
		end

		ent:Spawn()
		ent:Activate()

		if ent.CPPISetOwner then
			ent:CPPISetOwner(caster)
		end

		local cfg = {
			id = id,
			owner = caster,
			lifetime = tonumber(opts.ritual_lifetime) or 300,
			coin_cost = tonumber(opts.ritual_coin_cost) or 1000,
			items = istable(opts.ritual_items) and opts.ritual_items or {},
			on_activate = nil,
		}

		-- Wrap on_activate to provide a stable signature and access to caster
		if isfunction(opts.on_activate) then
			local userFn = opts.on_activate

			cfg.on_activate = function(selfEnt, activatingPly)
				userFn(selfEnt, activatingPly, caster)
			end
		end

		-- Allow caller to mutate/replace the config before applying
		if isfunction(opts.build_config) then
			local ok, newCfg = pcall(opts.build_config, cfg, caster)

			if ok and istable(newCfg) then
				cfg = newCfg
			end
		end

		if ent.Configure then
			ent:Configure(cfg)
		end

		return true
	end
	-- Animation hints for casting visuals

	return self:RegisterSpell({
		id = id,
		name = name,
		description = opts.description or "A powerful ritual",
		category = opts.category or self.CATEGORIES.UTILITY,
		level_required = tonumber(opts.level_required) or 1,
		knowledge_cost = tonumber(opts.knowledge_cost) or 1,
		cooldown = tonumber(opts.cooldown) or self.Config.DEFAULT_SPELL_COOLDOWN,
		cost_type = opts.cost_type or self.COST_TYPES.COINS,
		cost_amount = tonumber(opts.cost_amount) or 100,
		cast_time = tonumber(opts.cast_time) or 10,
		has_target = opts.has_target == true and true or false,
		cast_anim = opts.cast_anim or "becon",
		can_cast = opts.can_cast or defaultCanCast,
		cast = ritualCast,
		is_projectile = false,
	})
end

-- Spell Casting System
function Arcane:CanCastSpell(ply, spellId)
	if not ply:Alive() then return false, "You are dead" end
	local spell = self.RegisteredSpells[spellId]
	if not spell then return false, "Spell not found" end
	local data = self:GetPlayerData(ply)
	-- Block re-casting while a previous cast is still winding up
	if data.casting_until and data.casting_until > CurTime() then
		return false, "Already casting"
	end
	-- Check if spell is unlocked
	if not data.unlocked_spells[spellId] then return false, "Spell not unlocked" end
	-- Check level requirement
	if data.level < spell.level_required then return false, "Insufficient level" end
	-- Check cooldown
	local cooldownKey = spellId
	if data.spell_cooldowns[cooldownKey] and data.spell_cooldowns[cooldownKey] > CurTime() then return false, "Spell on cooldown" end

	-- Cost checks no longer block casting:
	-- - If coins are insufficient or unavailable, the equivalent amount is taken as health damage on cast
	-- - If health is insufficient, the player will take lethal damage on cast
	-- Custom validation
	if spell.can_cast then
		local canCast, reason = spell.can_cast(ply, nil, data)
		if not canCast then return false, reason or "Cannot cast spell" end
	end

	return true
end

-- Public helper: Attach BandCircle VFX to an entity (server-side entry)
if SERVER then
	function Arcane:SendAttachBandVFX(ent, color, size, duration, bandConfigs, tag)
		if not IsValid(ent) then return end
		net.Start("Arcana_AttachBandVFX", true)
		net.WriteEntity(ent)
		net.WriteColor(color or Color(120, 200, 255, 255), true)
		net.WriteFloat(size or 80)
		net.WriteFloat(duration or 5)
		local count = istable(bandConfigs) and #bandConfigs or 0
		net.WriteUInt(count, 8)

		for i = 1, count do
			local c = bandConfigs[i]
			net.WriteFloat(c.radius or (size or 80) * 0.6)
			net.WriteFloat(c.height or 16)
			net.WriteFloat((c.spin and c.spin.p) or 0)
			net.WriteFloat((c.spin and c.spin.y) or 0)
			net.WriteFloat((c.spin and c.spin.r) or 0)
			net.WriteFloat(c.lineWidth or 2)
		end

		net.WriteString(tostring(tag or ""))
		net.Broadcast()
	end

	function Arcane:ClearBandVFX(ent, tag)
		if not IsValid(ent) then return end
		net.Start("Arcana_ClearBandVFX", true)
		net.WriteEntity(ent)
		net.WriteString(tostring(tag or ""))
		net.Broadcast()
	end

	-- Attach rotating BandCircle rings to a weapon, one per enchantment, rotating around the longest axis
	function Arcane:UpdateWeaponEnchantmentVFX(ply, wep, clearOnly)
		--[[if not IsValid(ply) or not IsValid(wep) then return end
		-- Clear any previous VFX for this weapon
		self:ClearBandVFX(wep, "ArcanaWeaponEnchants")
		if clearOnly then return end

		-- Count applied enchantments for this weapon class
		local list = self:GetWeaponEnchantments(ply, wep:GetClass())
		local count = 0
		for _ in pairs(list) do count = count + 1 end
		if count <= 0 then return end

		-- Determine weapon's longest axis using its OBB
		local mins, maxs = wep:OBBMins(), wep:OBBMaxs()
		local size = maxs - mins
		local lenX, lenY, lenZ = math.abs(size.x), math.abs(size.y), math.abs(size.z)
		local axis = "x"
		if lenY >= lenX and lenY >= lenZ then
			axis = "y"
		elseif lenZ >= lenX and lenZ >= lenY then
			axis = "z"
		end

		-- Use player's physgun color (weapon color) for the bands
		local color = ply.GetWeaponColor and ply:GetWeaponColor():ToColor() or Color(120, 200, 255, 255)

		-- Build band configurations
		local bandConfigs = {}
		local smallest = math.max(4, math.min(lenX, math.min(lenY, lenZ)))
		local baseRadius = smallest * 0.6
		local spinSpeed = 90 * 50 -- baseline spin around chosen axis

		for i = 1, count do
			local r = baseRadius + (i - 1) * 4
			local spin = { p = 0, y = 0, r = 0 }
			-- Alternate spin direction for visual variety
			local dir = (i % 2 == 0) and 1 or -1
			if axis == "x" then
				spin.p = dir * spinSpeed
			elseif axis == "y" then
				spin.y = dir * spinSpeed
			else
				spin.r = dir * spinSpeed
			end

			bandConfigs[#bandConfigs + 1] = {
				radius = r,
				height = 2,
				spin = spin,
				lineWidth = 2,
			}
		end

		-- Attach for a long duration; the follow hook will keep it aligned
		local overallSize = math.max(12, baseRadius + count * 4)
		self:SendAttachBandVFX(wep, color, overallSize, 3600, bandConfigs, "ArcanaWeaponEnchants")]]
	end
end

function Arcane:CastSpell(ply, spellId, has_target, context)
	if not IsValid(ply) then return false end
	local canCast, reason = self:CanCastSpell(ply, spellId)

	if not canCast then
		if SERVER then
			Arcane:SendErrorNotification(ply, "Cannot cast spell \"" .. spellId .. "\": " .. reason)
		end

		return false
	end

	local spell = self.RegisteredSpells[spellId]
	local data = self:GetPlayerData(ply)
	local takeDamageInfo = ply.ForceTakeDamageInfo or ply.TakeDamageInfo

	-- Apply costs
	if spell.cost_type == Arcane.COST_TYPES.COINS then
		local canPayWithCoins = ply.GetCoins and ply.TakeCoins and (ply:GetCoins() >= spell.cost_amount)

		if canPayWithCoins then
			ply:TakeCoins(spell.cost_amount, "Spell: " .. spell.name)
		else
			-- Fallback: pay with health as real damage
			local dmg = DamageInfo()
			dmg:SetDamage(spell.cost_amount)
			dmg:SetAttacker(IsValid(ply) and ply or game.GetWorld())
			dmg:SetInflictor(IsValid(ply:GetActiveWeapon()) and ply:GetActiveWeapon() or ply)
			-- Use DMG_DIRECT so armor is ignored by Source damage rules
			dmg:SetDamageType(bit.bor(DMG_GENERIC, DMG_DIRECT))
			takeDamageInfo(ply, dmg)
			if spell.cost_amount > 100 then return false, "Insufficient coins" end
		end
	elseif spell.cost_type == Arcane.COST_TYPES.HEALTH then
		-- Health costs are applied as real damage, which can be lethal
		local dmg = DamageInfo()
		dmg:SetDamage(spell.cost_amount)
		dmg:SetAttacker(IsValid(ply) and ply or game.GetWorld())
		dmg:SetInflictor(IsValid(ply:GetActiveWeapon()) and ply:GetActiveWeapon() or ply)
		-- Use DMG_DIRECT so armor is ignored by Source damage rules
		dmg:SetDamageType(bit.bor(DMG_GENERIC, DMG_DIRECT))
		takeDamageInfo(ply, dmg)
	end

	-- Set cooldown
	data.spell_cooldowns[spellId] = CurTime() + spell.cooldown
	-- Cast the spell
	local success = true
	local result = spell.cast(ply, has_target, data, context)

	if result == false then
		success = false
	end

	-- Handle success/failure
	if success then
		-- Give XP
		local baseCast = math.max(0.1, Arcane.Config.XP_BASE_CAST_TIME or 1.0)
		local castTime = math.max(0.05, tonumber(spell.cast_time) or 0)
		local ratio = castTime / baseCast
		-- Clamp ratio to avoid extreme values
		ratio = math.Clamp(ratio, 0.001, 2.0)
		local baseXP = math.max(5, (tonumber(spell.knowledge_cost) or 1) * 10)
		local xpGain = math.floor(baseXP * ratio)
		self:GiveXP(ply, xpGain, "Cast " .. spell.name)

		if spell.on_success then
			spell.on_success(ply, has_target, data)
		end

		-- Report magic usage location for mana crystals
		if SERVER and Arcane.ManaCrystals and Arcane.ManaCrystals.ReportMagicUse then
			local ctxPos = (context and context.circlePos) or (IsValid(ply) and (ply:GetPos() + Vector(0, 0, 2))) or nil
			if ctxPos then
				Arcane.ManaCrystals:ReportMagicUse(ply, ctxPos, spellId, context)
			end
		end
	else
		if spell.on_failure then
			spell.on_failure(ply, has_target, data)
		end

		-- Notify clients to break down the casting circle visuals
		if SERVER then
			net.Start("Arcane_SpellFailed", true)
			net.WriteEntity(ply)
			net.WriteFloat((context and context.castTime) or 0)
			net.Broadcast()
		end
	end

	self:SavePlayerData(ply)

	if SERVER then
		-- Sync cooldowns and any derived changes
		self:SyncPlayerData(ply)
	end

	return success
end

-- Knowledge System
function Arcane:CanUnlockSpell(ply, spellId)
	local spell = self.RegisteredSpells[spellId]
	if not spell then return false, "Spell not found" end
	local data = self:GetPlayerData(ply)
	if data.unlocked_spells[spellId] then return false, "Already unlocked" end
	if data.level < spell.level_required then return false, "Insufficient level" end
	if data.knowledge_points < spell.knowledge_cost then return false, "Insufficient knowledge points" end

	return true
end

function Arcane:UnlockSpell(ply, spellId, force)
	if not force then
		local canUnlock, reason = self:CanUnlockSpell(ply, spellId)

		if not canUnlock then
			if SERVER then
				Arcane:SendErrorNotification(ply, "Cannot unlock spell \"" .. spellId .. "\": " .. reason)
			end

			return false
		end
	end

	local spell = self.RegisteredSpells[spellId]
	local data = self:GetPlayerData(ply)
	data.knowledge_points = data.knowledge_points - spell.knowledge_cost
	data.unlocked_spells[spellId] = true

	-- Auto-assign to first empty quickslot
	for i = 1, 8 do
		if not data.quickspell_slots[i] then
			data.quickspell_slots[i] = spellId
			break
		end
	end

	if SERVER then
		self:SyncPlayerData(ply)
		-- Tell the unlocking client to show an on-screen announcement & play a sound
		net.Start("Arcane_SpellUnlocked")
		net.WriteString(spellId)
		net.WriteString(spell.name or spellId)
		net.Send(ply)
	end

	self:SavePlayerData(ply)

	return true
end

-- Player Meta Extensions for Arcane-specific data only
local PLAYER = FindMetaTable("Player")

-- Note: This system assumes you already have:
-- PLAYER:GetCoins(), PLAYER:TakeCoins(amount, reason), PLAYER:GiveCoins(amount, reason)
-- PLAYER:GetItemCount(itemName), PLAYER:TakeItem(itemName, amount, reason), PLAYER:GiveItem(itemName, amount, reason)
-- If your methods have different names, you'll need to update the calls in the spell/ritual casting functions
function PLAYER:GetArcaneLevel()
	return Arcane:GetPlayerData(self).level
end

function PLAYER:GetArcaneXP()
	return Arcane:GetPlayerData(self).xp
end

function PLAYER:GetKnowledgePoints()
	return Arcane:GetPlayerData(self).knowledge_points
end

function PLAYER:HasSpellUnlocked(spellId)
	return Arcane:GetPlayerData(self).unlocked_spells[spellId] == true
end

-- Networking
if SERVER then
	util.AddNetworkString("Arcane_XPUpdate")
	util.AddNetworkString("Arcane_LevelUp")
	util.AddNetworkString("Arcane_UnlockSpell")

	-- Handle spell unlocking
	net.Receive("Arcane_UnlockSpell", function(len, ply)
		local spellId = net.ReadString()
		Arcane:UnlockSpell(ply, spellId)
	end)

	-- Handle client-forwarded console cast: "arcana <spellId>"
	net.Receive("Arcane_ConsoleCastSpell", function(_, ply)
		if not IsValid(ply) then return end
		local raw = net.ReadString() or ""
		local spellId = string.lower(string.Trim(raw))
		if spellId == "" then return end
		local canCast, reason = Arcane:CanCastSpell(ply, spellId)

		if not canCast then
			Arcane:SendErrorNotification(ply, "Cannot cast spell \"" .. spellId .. "\": " .. reason)

			return
		end

		Arcane:StartCasting(ply, spellId)
	end)

	-- Assign a spell to a quickslot
	net.Receive("Arcane_SetQuickslot", function(_, ply)
		local slotIndex = math.Clamp(net.ReadUInt(4), 1, 8)
		local spellId = net.ReadString()
		local data = Arcane:GetPlayerData(ply)
		if not Arcane.RegisteredSpells[spellId] then return end
		if not data.unlocked_spells[spellId] then return end
		data.quickspell_slots[slotIndex] = spellId
		Arcane:SavePlayerData(ply)
		Arcane:SyncPlayerData(ply)
	end)

	-- Select the active quickslot
	net.Receive("Arcane_SetSelectedQuickslot", function(_, ply)
		local slotIndex = math.Clamp(net.ReadUInt(4), 1, 8)
		local data = Arcane:GetPlayerData(ply)
		data.selected_quickslot = slotIndex
		Arcane:SavePlayerData(ply)
		Arcane:SyncPlayerData(ply)
	end)
end

-- Client-side receivers to keep local state in sync
if CLIENT then
	net.Receive("Arcane_XPUpdate", function()
		local xp = net.ReadUInt(32)
		local level = net.ReadUInt(16)
		local _reason = net.ReadString()
		local ply = LocalPlayer()
		if not IsValid(ply) then return end
		local data = Arcane:GetPlayerData(ply)
		data.xp = xp
		data.level = level
	end)

	net.Receive("Arcane_LevelUp", function()
		local newLevel = net.ReadUInt(16)
		local newKnowledgeTotal = net.ReadUInt(16)
		local ply = LocalPlayer()
		if not IsValid(ply) then return end
		local data = Arcane:GetPlayerData(ply)
		local prevLevel = data.level or 1
		local prevKnowledge = data.knowledge_points or 0
		data.level = newLevel
		data.knowledge_points = newKnowledgeTotal
		-- Notify UI (HUD) with deltas
		hook.Run("Arcane_ClientLevelUp", prevLevel, newLevel, math.max(0, newKnowledgeTotal - prevKnowledge))
	end)

	net.Receive("Arcane_FullSync", function()
		local payload = net.ReadTable()
		if not payload then return end
		local ply = LocalPlayer()
		if not IsValid(ply) then return end
		local data = Arcane:GetPlayerData(ply)
		data.xp = payload.xp or data.xp
		data.level = payload.level or data.level
		data.knowledge_points = payload.knowledge_points or data.knowledge_points

		if istable(payload.unlocked_spells) then
			data.unlocked_spells = payload.unlocked_spells
		end

		if istable(payload.spell_cooldowns) then
			data.spell_cooldowns = payload.spell_cooldowns
		end

		if istable(payload.quickspell_slots) then
			data.quickspell_slots = payload.quickspell_slots
		end

		if payload.selected_quickslot then
			data.selected_quickslot = payload.selected_quickslot
		end
	end)

	-- Show evolving circle while a spell is being cast
	net.Receive("Arcane_BeginCasting", function()
		local caster = net.ReadEntity()
		local spellId = net.ReadString()
		local castTime = net.ReadFloat()
		local forwardLike = net.ReadBool()
		if not IsValid(caster) then return end
		if not MagicCircle then return end
		-- Allow spells to override the default casting circle. If a hook returns true, stop.
		local handled = hook.Run("Arcane_BeginCastingVisuals", caster, spellId, castTime, forwardLike)
		if handled == true then return end
		local pos = caster:GetPos() + Vector(0, 0, 2)
		local ang = Angle(0, 180, 180)
		local size = 60

		if forwardLike then
			local maxs = caster:OBBMaxs()
			pos = caster:GetPos() + caster:GetForward() * maxs.x * 1.5 + caster:GetUp() * maxs.z / 2
			ang = caster:EyeAngles()
			ang:RotateAroundAxis(ang:Right(), 90)
			size = 30
		end

		local color = caster.GetWeaponColor and caster:GetWeaponColor():ToColor() or Color(150, 100, 255, 255)
		local intensity = 3

		if isstring(spellId) and #spellId > 0 then
			intensity = 2 + (#spellId % 3)
		end

		local circle = MagicCircle.CreateMagicCircle(pos, ang, color, intensity, size, castTime, 2)

		if circle and circle.StartEvolving then
			circle:StartEvolving(castTime, true)
		end

		-- Track as the current casting circle for this caster
		caster._ArcanaCastingCircle = circle
		-- While casting, continuously follow the caster so visuals stay attached
		local followHook = "Arcane_FollowCasting_" .. tostring(caster)
		hook.Remove("Think", followHook)

		hook.Add("Think", followHook, function()
			if not IsValid(caster) then
				hook.Remove("Think", followHook)

				return
			end

			local c = caster._ArcanaCastingCircle

			if not c or not c.IsActive or not c:IsActive() then
				hook.Remove("Think", followHook)

				return
			end

			-- Update circle position/orientation to follow current caster transform
			local newPos = caster:GetPos() + Vector(0, 0, 2)
			local newAng = Angle(0, 180, 180)
			local newSize = size

			if forwardLike then
				local maxsF = caster:OBBMaxs()
				newPos = caster:GetPos() + caster:GetForward() * maxsF.x * 1.5 + caster:GetUp() * maxsF.z / 2
				newAng = caster:EyeAngles()
				newAng:RotateAroundAxis(newAng:Right(), 90)
				newSize = 30
			end

			c.position = newPos
			c.angles = newAng
			c.size = newSize
		end)
	end)

	-- On spell failure, break down the tracked circle for the caster
	net.Receive("Arcane_SpellFailed", function()
		local caster = net.ReadEntity()
		local castTime = net.ReadFloat() or 0
		if not IsValid(caster) then return end
		local circle = caster._ArcanaCastingCircle

		if circle and circle.StartBreakdown then
			local d = math.max(0.1, castTime)
			circle:StartBreakdown(d)
			caster._ArcanaCastingCircle = nil
		end
	end)

	-- Play cast gesture locally for a given player
	net.Receive("Arcane_PlayCastGesture", function()
		local ply = net.ReadEntity()
		local gesture = net.ReadInt(16)
		if not IsValid(ply) or not gesture then return end
		local slot = GESTURE_SLOT_CUSTOM

		-- Prefer playing by sequence for better compatibility with player models
		if gesture == ACT_SIGNAL_FORWARD then
			local seq = ply:LookupSequence("gesture_signal_forward")

			if seq and seq >= 0 then
				ply:AddVCDSequenceToGestureSlot(slot, seq, 0, true)

				return
			end
		elseif gesture == ACT_GMOD_GESTURE_BECON then
			local seq = ply:LookupSequence("gesture_becon")

			if seq and seq >= 0 then
				ply:AddVCDSequenceToGestureSlot(slot, seq, 0, true)

				return
			end
		end

		-- Fallback to ACT-based gesture
		ply:AnimRestartGesture(slot, gesture, true)
	end)

	-- Track active BandCircle VFX by entity and optional tag for early clearing
	local activeBandVFX = {}

	-- Client-only: receive BandCircle VFX attachments
	net.Receive("Arcana_AttachBandVFX", function()
		local ent = net.ReadEntity()
		local color = net.ReadColor(true)
		local size = net.ReadFloat()
		local duration = net.ReadFloat()
		local count = net.ReadUInt(8)
		if not IsValid(ent) or not BandCircle then return end

		local bc = BandCircle.Create(ent:WorldSpaceCenter(), ent:GetAngles(), color, size, duration)
		if not bc then return end

		for i = 1, count do
			local radius = net.ReadFloat()
			local height = net.ReadFloat()
			local sp = net.ReadFloat()
			local sy = net.ReadFloat()
			local sr = net.ReadFloat()
			local lw = net.ReadFloat()

			bc:AddBand(radius, height, {
				p = sp,
				y = sy,
				r = sr
			}, lw)
		end

		-- Read optional tag after band list
		local tag = net.ReadString() or ""

		-- Follow entity for duration
		local hookName = "BandCircleFollow_" .. tostring(bc)
		hook.Add("PostDrawOpaqueRenderables", hookName, function()
			if not IsValid(ent) or not bc or not bc.isActive then
				bc:Remove()
				hook.Remove("Think", hookName)

				return
			end

			bc.position = ent:WorldSpaceCenter()
			bc.angles = ent:GetAngles()
		end)

		-- Store by entity and tag for later clearing
		activeBandVFX[ent] = activeBandVFX[ent] or {}
		local key = tag ~= "" and tag or "__untagged__"
		activeBandVFX[ent][key] = activeBandVFX[ent][key] or {}
		table.insert(activeBandVFX[ent][key], bc)
	end)

	-- Clear previously attached band VFX by tag
	net.Receive("Arcana_ClearBandVFX", function()
		local ent = net.ReadEntity()
		local tag = net.ReadString() or ""
		if not IsValid(ent) then return end
		local key = tag ~= "" and tag or "__untagged__"

		if activeBandVFX[ent] and activeBandVFX[ent][key] then
			for _, bc in ipairs(activeBandVFX[ent][key]) do
				if bc and bc.Remove then
					bc:Remove()
				end
			end

			activeBandVFX[ent][key] = nil

			if next(activeBandVFX[ent]) == nil then
				activeBandVFX[ent] = nil
			end
		end
	end)
end

if SERVER then
	-- Hooks
	local justSpawned = {}

	hook.Add("PlayerInitialSpawn", "Arcane_PlayerJoin", function(ply)
		justSpawned[ply] = true
	end)

	hook.Add("SetupMove", "Arcane_PlayerJoin", function(ply, _, ucmd)
		if justSpawned[ply] and not ucmd:IsForced() then
			justSpawned[ply] = nil

			Arcane:LoadPlayerData(ply, function()
				Arcane:SyncPlayerData(ply)
			end)
		end
	end)

	hook.Add("PlayerDisconnected", "Arcane_PlayerLeave", function(ply)
		local sid = IsValid(ply) and ply:SteamID64() or nil
		if sid then
			timer.Remove("Arcana_RetryLoad_" .. tostring(sid))
			Arcane.RetryStateBySteamID[sid] = nil
			-- Leave SaveBlockedBySteamID as-is; SavePlayerData will respect it and no-op
		end
		Arcane:SavePlayerData(ply)
	end)

	local function SpawnAltar()
		if not _G.landmark then return end
		local pos = _G.landmark.get("slight")
		if not pos then return end
		local ent = ents.Create("arcana_altar")
		if not IsValid(ent) then return end
		ent:SetPos(pos)
		ent:Spawn()
		ent:Activate()
		ent.ms_notouch = true
		-- Mark this altar so clients can treat it as the core-spawned one (for ambient loop, etc.)
		ent:SetNWBool("ArcanaCoreSpawned", true)
		local phys = ent:GetPhysicsObject()

		if IsValid(phys) then
			phys:EnableMotion(false)
		end

		return ent
	end

	local LOBBY3_OFFSET = Vector(-522, 285, 14)

	local function SpawnPortalToAltar(altar)
		if not IsValid(altar) then return end
		if not _G.landmark then return end
		local pos = _G.landmark.get("lobby_3")
		if not pos then return end
		local ent = ents.Create("arcana_portal")
		if not IsValid(ent) then return end
		ent:SetPos(pos + LOBBY3_OFFSET)
		ent:Spawn()
		ent:Activate()
		ent:SetDestination(altar:WorldSpaceCenter() + altar:GetForward() * 200)
		ent.ms_notouch = true
		local phys = ent:GetPhysicsObject()

		if IsValid(phys) then
			phys:EnableMotion(false)
		end
	end

	local function SpawnMapEntities()
		local altar = SpawnAltar()
		SpawnPortalToAltar(altar)

		if _G.aowl and _G.aowl.GotoLocations then
			local aliases = {"altar", "magic", "arcane", "arcana"}

			for _, alias in ipairs(aliases) do
				_G.aowl.GotoLocations[alias] = altar:WorldSpaceCenter() + altar:GetForward() * 200
			end
		end
	end

	hook.Add("InitPostEntity", "Arcane_SpawnAltar", SpawnMapEntities)
	hook.Add("PostCleanupMap", "Arcane_SpawnAltar", SpawnMapEntities)
end

-- Public helper to sync a weapon's applied enchantment IDs to clients via NWString
function Arcane:SyncWeaponEnchantNW(wep)
	return syncWeaponEnchantNW(wep)
end

-- Cleanup: when a weapon entity is removed, ensure all enchantments detach their hooks
if SERVER then
	hook.Add("EntityRemoved", "Arcana_CleanupWeaponEnchantments", function(ent)
		if not ent or not ent.ArcanaEnchantments then return end
		local list = ent.ArcanaEnchantments
		local owner = (ent.GetOwner and ent:GetOwner()) or nil
		for enchId, state in pairs(list) do
			local ench = (Arcane.RegisteredEnchantments or {})[enchId]
			if ench and ench.remove then
				local ok, err = pcall(ench.remove, (IsValid(owner) and owner) or game.GetWorld(), ent, state)
				if not ok then ErrorNoHalt("Enchantment remove error on entity removal: " .. tostring(err) .. "\n") end
			end
		end
		ent.ArcanaEnchantments = nil
	end)
end

-- Custom BlastDamage that prefers ForceTakeDamageInfo when available
function Arcane:BlastDamage(attacker, inflictor, center, radius, baseDamage, damageType, force)
	attacker = IsValid(attacker) and attacker or game.GetWorld()
	inflictor = IsValid(inflictor) and inflictor or attacker
	radius = math.max(1, tonumber(radius) or 0)
	baseDamage = math.max(0, tonumber(baseDamage) or 0)
	damageType = damageType or DMG_BLAST
	force = force or false

	for _, ent in ipairs(ents.FindInSphere(center, radius)) do
		if not IsValid(ent) or ent == inflictor then continue end

		-- Compute linear falloff
		local dist = ent:WorldSpaceCenter():Distance(center)
		local frac = 1 - (dist / radius)
		if frac <= 0 then continue end

		local dmgAmt = baseDamage * frac
		if dmgAmt <= 0 then continue end

		local dmg = DamageInfo()
		dmg:SetDamage(dmgAmt)
		dmg:SetDamageType(damageType)
		dmg:SetAttacker(attacker)
		dmg:SetInflictor(inflictor)
		dmg:SetDamagePosition(ent:WorldSpaceCenter())

		local takeDamageInfo = force and ent.ForceTakeDamageInfo or ent.TakeDamageInfo
		if isfunction(takeDamageInfo) then
			takeDamageInfo(ent, dmg)
		end
	end
end

return Arcane