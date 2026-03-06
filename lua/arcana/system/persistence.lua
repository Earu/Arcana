-- Arcana Persistence — player data storage, retrieval, and network sync.
-- Covers: default data schema, SQL CRUD, in-memory GetPlayerData/SavePlayerData/LoadPlayerData,
--         SyncPlayerData, SendErrorNotification, and related player lifecycle hooks.

Arcana = Arcana or {}
Arcana.PlayerData = Arcana.PlayerData or {}
Arcana.SaveBlockedBySteamID = Arcana.SaveBlockedBySteamID or {}
Arcana.RetryStateBySteamID = Arcana.RetryStateBySteamID or {}

local function CreateDefaultPlayerData()
	return {
		xp = 0,
		level = 1,
		knowledge_points = (Arcana.Config and Arcana.Config.KNOWLEDGE_POINTS_PER_LEVEL) or 1,
		unlocked_spells = {},
		spell_cooldowns = {},
		active_effects = {},
		quickspell_slots = {nil, nil, nil, nil, nil, nil, nil, nil},
		selected_quickslot = 1,
		last_save = os.time()
	}
end

if SERVER then
	local function dbLogError(prefix)
		local err = sql.LastError() or "unknown error"
		MsgC(Color(255, 80, 80), "[Arcana][SQL] ", Color(255, 255, 255), prefix .. ": " .. tostring(err) .. "\n")
	end

	local ensured = false
	local function ensureDatabase()
		if ensured then return ensured end
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

	local function serializeUnlockedSpells(unlocked)
		local arr = {}
		for id, v in pairs(unlocked or {}) do
			if v then arr[#arr + 1] = id end
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
		local out = {}
		for i = 1, 8 do
			out[i] = tostring(slots and slots[i] or "")
			if out[i] == "nil" then out[i] = "" end
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
				if isstring(v) and v ~= "" then slots[i] = v end
			end
		end
		return slots
	end

	function Arcana:SavePlayerDataToSQL(ply, data)
		local handled = Arcana.RunHook("SavePlayerDataToSQL", ply, data)
		if handled == true then return end
		if not ensureDatabase() then return end
		local sid = IsValid(ply) and ply:SteamID64() or nil
		if sid and Arcana.SaveBlockedBySteamID[sid] then return end
		local steamid = sql.SQLStr(ply:SteamID64(), true)
		local incoming_xp = tonumber(data.xp) or 0
		local incoming_level = tonumber(data.level) or 1
		local incoming_kp = tonumber(data.knowledge_points) or 0
		local incoming_unlocked_map = data.unlocked_spells or {}
		local incoming_quickslots = data.quickspell_slots or {nil, nil, nil, nil, nil, nil, nil, nil}
		local incoming_selected = tonumber(data.selected_quickslot) or 1
		local lastsave = tonumber(data.last_save) or os.time()

		-- Merge strategy: xp/level take max, knowledge_points use incoming, unlocked_spells union, quickslots prefer incoming
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

	function Arcana:LoadPlayerDataFromSQL(ply, callback)
		if not IsValid(ply) then return end
		local handled = Arcana.RunHook("LoadPlayerDataFromSQL", ply, callback)
		if handled == true then return end
		if not ensureDatabase() then return nil end
		local rawSid = ply:SteamID64()
		Arcana.SaveBlockedBySteamID[rawSid] = true

		local function hydratePlayerFromRow(row)
			local data = CreateDefaultPlayerData()
			data.xp = tonumber(row.xp) or data.xp
			data.level = tonumber(row.level) or data.level
			data.knowledge_points = tonumber(row.knowledge_points) or data.knowledge_points
			data.unlocked_spells = deserializeUnlockedSpells(row.unlocked_spells)
			data.quickspell_slots = deserializeQuickslots(row.quickspell_slots)
			data.selected_quickslot = tonumber(row.selected_quickslot) or data.selected_quickslot
			data.last_save = tonumber(row.last_save) or data.last_save
			Arcana.SaveBlockedBySteamID[rawSid] = nil
			Arcana.RetryStateBySteamID[rawSid] = nil
			callback(true, data)
		end

		local steamid = sql.SQLStr(rawSid, true)

		local function scheduleRetry()
			local state = Arcana.RetryStateBySteamID[rawSid] or {delay = 1}
			Arcana.RetryStateBySteamID[rawSid] = state
			local tname = "Arcana_RetryLoad_" .. tostring(rawSid)
			timer.Remove(tname)
			timer.Create(tname, state.delay, 1, function()
				if not IsValid(ply) then return end
				state.delay = math.min((state.delay or 1) * 2, 60)
				Arcana:LoadPlayerDataFromSQL(ply, callback)
			end)
		end

		local rows = sql.Query("SELECT * FROM arcane_players WHERE steamid = '" .. steamid .. "' LIMIT 1;")
		if rows == false then
			dbLogError("LoadPlayerDataFromSQL failed")
			scheduleRetry()
			return
		end

		if not rows or not rows[1] then
			Arcana.SaveBlockedBySteamID[rawSid] = nil
			Arcana.RetryStateBySteamID[rawSid] = nil
			local defaults = CreateDefaultPlayerData()
			callback(true, defaults)
			Arcana:SavePlayerDataToSQL(ply, defaults)
			return
		end

		hydratePlayerFromRow(rows[1])
	end
end

function Arcana:GetPlayerData(ply)
	if not IsValid(ply) then return nil end
	local steamid = ply:SteamID64()
	if not self.PlayerData[steamid] then
		self.PlayerData[steamid] = CreateDefaultPlayerData()
	end
	return self.PlayerData[steamid]
end

function Arcana:SavePlayerData(ply)
	if not IsValid(ply) then return end
	local sid = ply:SteamID64()
	if Arcana.SaveBlockedBySteamID[sid] then return end
	local data = self:GetPlayerData(ply)
	data.last_save = os.time()
	if SERVER then
		self:SavePlayerDataToSQL(ply, data)
	end
	Arcana.RunHook("SavedPlayerData", ply, data)
end

-- Loads player data and, on the server, automatically syncs it to the client.
-- Callers do not need to call SyncPlayerData separately after loading.
function Arcana:LoadPlayerData(ply, callback)
	if not IsValid(ply) then return end
	local steamid = ply:SteamID64()
	if SERVER then
		self:LoadPlayerDataFromSQL(ply, function(loaded, data)
			self.PlayerData[steamid] = data
			self:SyncPlayerData(ply)
			callback(data)
		end)
	else
		if not self.PlayerData[steamid] then
			self.PlayerData[steamid] = CreateDefaultPlayerData()
		end
		callback(self.PlayerData[steamid])
	end
end

if SERVER then
	util.AddNetworkString("Arcana_FullSync")
	util.AddNetworkString("Arcana_ErrorNotification")
	util.AddNetworkString("Arcana_SpellUnlocked")

	function Arcana:SyncPlayerData(ply)
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
		net.Start("Arcana_FullSync")
		net.WriteTable(payload)
		net.Send(ply)
		Arcana.RunHook("SyncPlayerData", ply, data)
	end

	function Arcana:SendErrorNotification(ply, msg)
		if not IsValid(ply) then return end
		net.Start("Arcana_ErrorNotification")
		net.WriteString(msg)
		net.Send(ply)
	end

end
-- Player lifecycle hooks (load on SetupMove, save on disconnect) are in arcana/lifecycle.lua

if CLIENT then
	net.Receive("Arcana_ErrorNotification", function()
		local msg = net.ReadString()
		Arcana:Print(msg)
		notification.AddLegacy(msg, NOTIFY_ERROR, 5)
	end)

	net.Receive("Arcana_FullSync", function()
		local payload = net.ReadTable()
		if not payload then return end
		local ply = LocalPlayer()
		if not IsValid(ply) then return end
		local data = Arcana:GetPlayerData(ply)
		if not data then return end
		data.xp = tonumber(payload.xp) or data.xp
		data.level = tonumber(payload.level) or data.level
		data.knowledge_points = tonumber(payload.knowledge_points) or data.knowledge_points
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
end
