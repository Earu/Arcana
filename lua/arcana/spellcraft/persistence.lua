-- Spellcraft — server persistence & authority.
--
-- The clientside file (data/arcana/spellcraft.json) owns the definitions; this
-- server owns activation. Two tables record per-server, per-player state:
--   arcane_essence_unlocks         which essences a player has bought here
--   arcane_spellcraft_activations  which crafted spells (by defhash) are consecrated here
--
-- On join we load that state, ask the client for its definitions, register the
-- structurally-valid ones (locked until eligible), and broadcast them so every
-- client can render each other's crafted spells.

if not SERVER then return end

Arcana = Arcana or {}
Arcana.Spellcraft = Arcana.Spellcraft or {}
local P = Arcana.Spellcraft

util.AddNetworkString("Arcana_OpenSpellcraftMenu")
util.AddNetworkString("Arcana_Spellcraft_RequestSync")
util.AddNetworkString("Arcana_Spellcraft_SyncUp")
util.AddNetworkString("Arcana_Spellcraft_Register")
util.AddNetworkString("Arcana_Spellcraft_Unregister")
util.AddNetworkString("Arcana_Spellcraft_State")
util.AddNetworkString("Arcana_Spellcraft_Submit")
util.AddNetworkString("Arcana_Spellcraft_Consecrate")
util.AddNetworkString("Arcana_Spellcraft_UnlockEssence")
util.AddNetworkString("Arcana_Spellcraft_Dissolve")

-- Per-player caches (source of truth is SQL; these mirror it in memory)
P.EssenceUnlocks = P.EssenceUnlocks or {} -- [sid64] = { [essence]=true }
P.Consecrations  = P.Consecrations  or {} -- [sid64] = { [defhash]=true }
P.Active         = P.Active         or {} -- [sid64] = { [slot] = def }

local BARGAIN_PDATA = "arcana_golden_sun_accepted"

-- SyncUp is only ever a reply to the RequestSync we send on join. Tracking the outstanding
-- request means an unsolicited SyncUp cannot re-broadcast a fresh set of names to every
-- client on demand, which is the one path here that puts player-authored text on other
-- people's screens.
local awaitingSync = {}

----------------------------------------------------------------------
-- SQL
----------------------------------------------------------------------
-- Deferred like every sibling persistence module: creating tables at module scope runs
-- before the map has finished loading and gives nowhere to report a failure to.
local ensured = false
local function ensureTables()
	if ensured then return true end

	local a = Arcana.SQLCheck(sql.Query([[CREATE TABLE IF NOT EXISTS arcane_essence_unlocks (
		steamid TEXT NOT NULL, essence TEXT NOT NULL,
		PRIMARY KEY (steamid, essence));]]), "CREATE TABLE arcane_essence_unlocks")
	local b = Arcana.SQLCheck(sql.Query([[CREATE TABLE IF NOT EXISTS arcane_spellcraft_activations (
		steamid TEXT NOT NULL, defhash TEXT NOT NULL,
		PRIMARY KEY (steamid, defhash));]]), "CREATE TABLE arcane_spellcraft_activations")

	ensured = a ~= false and b ~= false
	return ensured
end

-- Consecrations and essence unlocks are purchases. If the row cannot be written the player
-- has already been charged, so say so out loud rather than leaving them to discover on the
-- next map change that what they bought is gone.
local function persistPurchase(query, context, ply)
	if not ensureTables() then
		Arcana.SendErrorNotification(ply, "Purchase could not be saved, contact an admin")
		return false
	end

	if Arcana.SQLCheck(sql.Query(query), context) == false then
		Arcana.SendErrorNotification(ply, "Purchase could not be saved, contact an admin")
		return false
	end

	return true
end

local function loadPlayerState(sid64)
	P.EssenceUnlocks[sid64] = {}
	P.Consecrations[sid64] = {}
	if not ensureTables() then return end

	local esc = sql.SQLStr(sid64)

	local rows = Arcana.SQLCheck(sql.Query("SELECT essence FROM arcane_essence_unlocks WHERE steamid = " .. esc .. ";"),
		"read essence unlocks for " .. sid64)
	if istable(rows) then
		for _, r in ipairs(rows) do P.EssenceUnlocks[sid64][r.essence] = true end
	end

	rows = Arcana.SQLCheck(sql.Query("SELECT defhash FROM arcane_spellcraft_activations WHERE steamid = " .. esc .. ";"),
		"read consecrations for " .. sid64)
	if istable(rows) then
		for _, r in ipairs(rows) do P.Consecrations[sid64][r.defhash] = true end
	end
end

----------------------------------------------------------------------
-- State accessors used by the cast eligibility check
----------------------------------------------------------------------
function P.IsConsecrated(ply, def)
	local sid = ply:SteamID64()
	local set = P.Consecrations[sid]
	return set ~= nil and set[P.DefHash(def)] == true
end

function P.HasEssence(ply, essenceId)
	local sid = ply:SteamID64()
	local set = P.EssenceUnlocks[sid]
	return set ~= nil and set[essenceId] == true
end

function P.HasBargain(ply)
	local v = ply:GetPData(BARGAIN_PDATA, "0")
	return v == "1" or v == "true"
end

-- Base per-server state for a player, with consecration filled for a given def.
function P.GetServerState(ply, def)
	local sid = ply:SteamID64()
	return {
		level = Arcana.GetLevel(ply),
		essences = P.EssenceUnlocks[sid] or {},
		bargain = P.HasBargain(ply),
		consecrated = def and P.IsConsecrated(ply, def) or false,
	}
end

----------------------------------------------------------------------
-- Sync helpers
----------------------------------------------------------------------
local function writeClauses(clauses)
	clauses = clauses or {}
	local n = math.min(#clauses, 8)
	net.WriteUInt(n, 8)
	for i = 1, n do net.WriteString(clauses[i]) end
end

-- Send the owner their per-server activation state (for the UI + display).
function P.SendState(ply)
	local sid = ply:SteamID64()
	local essences = P.EssenceUnlocks[sid] or {}
	local consecrated = P.Consecrations[sid] or {}

	net.Start("Arcana_Spellcraft_State")
	local ekeys = {}
	for e in pairs(essences) do ekeys[#ekeys + 1] = e end
	net.WriteUInt(math.min(#ekeys, 255), 8)
	for i = 1, math.min(#ekeys, 255) do net.WriteString(ekeys[i]) end

	local ckeys = {}
	for h in pairs(consecrated) do ckeys[#ckeys + 1] = h end
	net.WriteUInt(math.min(#ckeys, 255), 8)
	for i = 1, math.min(#ckeys, 255) do net.WriteString(ckeys[i]) end

	net.WriteBool(P.HasBargain(ply))
	net.WriteUInt(P.Config().maxSlots, 8)
	net.Send(ply)
end

-- Register a crafted spell server-side + broadcast it to everyone.
local function registerAndBroadcast(sid64, slot, name, def)
	local spell = P.BuildSpellData(sid64, slot, def, name)
	if not spell then return false end

	Arcana.RegisteredSpells[spell.id] = spell
	P.Active[sid64] = P.Active[sid64] or {}
	P.Active[sid64][slot] = def

	-- Mark unlocked in-memory for the owner (never persisted to arcane_players;
	-- serializeUnlockedSpells strips spellcraft_ ids on save).
	local owner = player.GetBySteamID64(sid64)
	if IsValid(owner) then
		local data = Arcana.GetPlayerData(owner)
		if data then data.unlocked_spells[spell.id] = true end
	end

	net.Start("Arcana_Spellcraft_Register")
	net.WriteString(sid64)
	net.WriteUInt(slot, 8)
	net.WriteString(string.sub(name or "Crafted Spell", 1, 24))
	net.WriteString(def.form)
	net.WriteString(def.essence)
	writeClauses(def.clauses)
	net.Broadcast()
	return true
end

local function unregisterAndBroadcast(sid64, slot)
	local id = P.SpellId(sid64, slot)
	Arcana.RegisteredSpells[id] = nil
	if P.Active[sid64] then P.Active[sid64][slot] = nil end

	local owner = player.GetBySteamID64(sid64)
	if IsValid(owner) then
		local data = Arcana.GetPlayerData(owner)
		if data then
			data.unlocked_spells[id] = nil
			-- Scrub the crafted spell out of any quickslots it occupied.
			for i = 1, 8 do
				if data.quickspell_slots[i] == id then data.quickspell_slots[i] = nil end
			end
			Arcana.SavePlayerData(owner)
			Arcana.SyncPlayerData(owner)
		end
	end

	net.Start("Arcana_Spellcraft_Unregister")
	net.WriteString(sid64)
	net.WriteUInt(slot, 8)
	net.Broadcast()
end

-- Send the full roster of everyone's active crafted spells to one joining client.
local function sendRoster(ply)
	for sid64, slots in pairs(P.Active) do
		for slot, def in pairs(slots) do
			local spell = Arcana.RegisteredSpells[P.SpellId(sid64, slot)]
			local name = spell and spell.name or "Crafted Spell"
			net.Start("Arcana_Spellcraft_Register")
			net.WriteString(sid64)
			net.WriteUInt(slot, 8)
			net.WriteString(string.sub(name, 1, 24))
			net.WriteString(def.form)
			net.WriteString(def.essence)
			writeClauses(def.clauses)
			net.Send(ply)
		end
	end
end

----------------------------------------------------------------------
-- Join: load state, roster the client, request its definitions
----------------------------------------------------------------------
hook.Add("Arcana_LoadedPlayerData", "Arcana_Spellcraft_Load", function(ply)
	if not IsValid(ply) then return end
	local sid = ply:SteamID64()
	loadPlayerState(sid)
	sendRoster(ply)
	P.SendState(ply)

	awaitingSync[sid] = true
	net.Start("Arcana_Spellcraft_RequestSync")
	net.Send(ply)
end)

hook.Add("PlayerDisconnected", "Arcana_Spellcraft_Cleanup", function(ply)
	local sid = ply:SteamID64()
	if P.Active[sid] then
		for slot in pairs(P.Active[sid]) do
			local id = P.SpellId(sid, slot)
			Arcana.RegisteredSpells[id] = nil
			net.Start("Arcana_Spellcraft_Unregister")
			net.WriteString(sid)
			net.WriteUInt(slot, 8)
			net.Broadcast()
		end
	end
	P.Active[sid] = nil
	P.EssenceUnlocks[sid] = nil
	P.Consecrations[sid] = nil
	awaitingSync[sid] = nil
end)

----------------------------------------------------------------------
-- Rate limiting (shared across the crafted spell actions below)
----------------------------------------------------------------------
local lastAction = {}
local ACTION_COOLDOWN = 1.0
local function rateOk(ply)
	local sid = ply:SteamID64()
	local now = CurTime()
	if (lastAction[sid] or 0) + ACTION_COOLDOWN > now then return false end
	lastAction[sid] = now
	return true
end
hook.Add("PlayerDisconnected", "Arcana_Spellcraft_RateClear", function(ply)
	lastAction[ply:SteamID64()] = nil
end)

local function nameValid(name)
	name = string.Trim(name or "")
	if #name < 3 or #name > 24 then return false end
	if not string.match(name, "^[%w%s%-']+$") then return false end
	return true, name
end

----------------------------------------------------------------------
-- Receiver: the client uploads its definition list on request
----------------------------------------------------------------------
local function readClauses()
	local n = math.min(net.ReadUInt(8), 8)
	local out = {}
	for i = 1, n do out[i] = net.ReadString() end
	return out
end

net.Receive("Arcana_Spellcraft_SyncUp", function(_, ply)
	if not IsValid(ply) then return end
	local sid = ply:SteamID64()
	if not awaitingSync[sid] then return end
	awaitingSync[sid] = nil

	local maxSlots = P.Config().maxSlots

	-- Clear any previous registrations for this player (fresh authoritative set).
	if P.Active[sid] then
		for slot in pairs(P.Active[sid]) do
			unregisterAndBroadcast(sid, slot)
		end
	end
	P.Active[sid] = {}

	local count = math.min(net.ReadUInt(8), 64)
	local seenSlots = {}
	for i = 1, count do
		local slot = net.ReadUInt(8)
		local rawName = net.ReadString()
		local form = net.ReadString()
		local essence = net.ReadString()
		local clauses = readClauses()

		-- Same name rule the craft path enforces. These names are broadcast to every
		-- client, so a name that would be rejected at the bench is not accepted here
		-- either; fall back rather than dropping the player's spell over its label.
		local okName, name = nameValid(rawName)
		if not okName then name = "Crafted Spell" end

		-- Only register up to this server's slot allowance; ignore duplicates.
		if slot >= 1 and slot <= maxSlots and not seenSlots[slot] then
			seenSlots[slot] = true
			local def = { form = form, essence = essence, clauses = clauses }
			local compiled = P.Compile(def)
			if compiled then -- structural validity only; eligibility is checked at cast time
				registerAndBroadcast(sid, slot, name, def)
			end
		end
	end
end)

----------------------------------------------------------------------
-- Receiver: craft (consecrate a new crafted spell into a slot)
----------------------------------------------------------------------
net.Receive("Arcana_Spellcraft_Submit", function(_, ply)
	if not IsValid(ply) then return end
	if not rateOk(ply) then return end
	local cfg = P.Config()
	if not cfg.enabled then
		Arcana.SendErrorNotification(ply, "Spell crafting is disabled here")
		return
	end

	local slot = net.ReadUInt(8)
	local rawName = net.ReadString()
	local form = net.ReadString()
	local essence = net.ReadString()
	local clauses = readClauses()

	if slot < 1 or slot > cfg.maxSlots then return end

	local okName, name = nameValid(rawName)
	if not okName then
		Arcana.SendErrorNotification(ply, "Invalid name, 3 to 24 letters")
		return
	end

	local sid = ply:SteamID64()

	-- Writing over an occupied slot edits that spell in place. The full offering
	-- is charged again below, so reworking a spell costs what making it fresh
	-- would, and the reworked form has to be consecrated on its own merits.
	local previous = P.Active[sid] and P.Active[sid][slot]

	-- No duplicate names among this player's own crafted spells. The slot being
	-- edited is allowed to keep the name it already has.
	for otherSlot in pairs(P.Active[sid] or {}) do
		if otherSlot ~= slot then
			local otherSpell = Arcana.RegisteredSpells[P.SpellId(sid, otherSlot)]
			if otherSpell and string.lower(otherSpell.name) == string.lower(name) then
				Arcana.SendErrorNotification(ply, "You already have a spell with that name")
				return
			end
		end
	end

	local def = { form = form, essence = essence, clauses = clauses }

	-- Never charge for a rework that changes nothing.
	if previous and P.DefHash(previous) == P.DefHash(def) then
		local prevSpell = Arcana.RegisteredSpells[P.SpellId(sid, slot)]
		if prevSpell and prevSpell.name == name then
			Arcana.SendErrorNotification(ply, "That spell is already exactly this")
			return
		end
	end
	local state = P.GetServerState(ply, def)
	state.consecrated = true -- crafting consecrates here; test the rest
	local req = P.Requirements(def, state)
	if not req.castable then
		Arcana.SendErrorNotification(ply, req.firstMissing or "Cannot create this spell")
		return
	end

	local compiled = req.compiled
	local coins = compiled.consecrationCoins
	local shards = compiled.consecrationShards

	if Arcana.GetCoins(ply) < coins then
		Arcana.SendErrorNotification(ply, "Not enough coins (" .. string.Comma(coins) .. " needed)")
		return
	end
	if Arcana.GetItemCount(ply, "mana_crystal_shard") < shards then
		Arcana.SendErrorNotification(ply, "You need " .. shards .. " crystal shards")
		return
	end

	local ledger = (previous and "Reworked spell: " or "Crafted spell: ") .. name
	Arcana.TakeCoins(ply, coins, ledger)
	Arcana.TakeItem(ply, "mana_crystal_shard", shards, ledger)

	-- Consecrate + persist + register.
	local hash = P.DefHash(def)
	P.Consecrations[sid] = P.Consecrations[sid] or {}
	if not P.Consecrations[sid][hash] then
		P.Consecrations[sid][hash] = true
		persistPurchase(string.format("INSERT OR REPLACE INTO arcane_spellcraft_activations (steamid, defhash) VALUES (%s, %s);",
			sql.SQLStr(sid), sql.SQLStr(hash)), "persist consecration " .. hash, ply)
	end

	registerAndBroadcast(sid, slot, name, def)
	P.SendState(ply)

	for _, e in ipairs(ents.FindByClass("arcana_emissary")) do
		if IsValid(e) and e:GetPos():DistToSqr(ply:GetPos()) < (800 * 800) then
			e:EmitSound("ambient/machines/teleport1.wav", 75, 110)
		end
	end
end)

----------------------------------------------------------------------
-- Receiver: consecrate an already-registered (crafted-elsewhere) crafted spell
----------------------------------------------------------------------
net.Receive("Arcana_Spellcraft_Consecrate", function(_, ply)
	if not IsValid(ply) then return end
	if not rateOk(ply) then return end
	local slot = net.ReadUInt(8)
	local sid = ply:SteamID64()

	local def = P.Active[sid] and P.Active[sid][slot]
	if not def then
		Arcana.SendErrorNotification(ply, "No spell in that slot")
		return
	end

	if P.IsConsecrated(ply, def) then return end

	local compiled = P.Compile(def)
	if not compiled then return end

	local coins = compiled.consecrationCoins
	local shards = compiled.consecrationShards

	if Arcana.GetCoins(ply) < coins then
		Arcana.SendErrorNotification(ply, "Not enough coins (" .. string.Comma(coins) .. " needed)")
		return
	end
	if Arcana.GetItemCount(ply, "mana_crystal_shard") < shards then
		Arcana.SendErrorNotification(ply, "You need " .. shards .. " crystal shards")
		return
	end

	Arcana.TakeCoins(ply, coins, "Spell activation")
	Arcana.TakeItem(ply, "mana_crystal_shard", shards, "Spell activation")

	local hash = P.DefHash(def)
	P.Consecrations[sid] = P.Consecrations[sid] or {}
	P.Consecrations[sid][hash] = true
	persistPurchase(string.format("INSERT OR REPLACE INTO arcane_spellcraft_activations (steamid, defhash) VALUES (%s, %s);",
		sql.SQLStr(sid), sql.SQLStr(hash)), "persist consecration " .. hash, ply)

	P.SendState(ply)
end)

----------------------------------------------------------------------
-- Receiver: unlock an essence
----------------------------------------------------------------------
net.Receive("Arcana_Spellcraft_UnlockEssence", function(_, ply)
	if not IsValid(ply) then return end
	if not rateOk(ply) then return end
	local essenceId = net.ReadString()
	local essence = P.Essences[essenceId]
	if not essence then return end
	if essence.bargain then
		Arcana.SendErrorNotification(ply, "That element cannot be bought")
		return
	end

	local sid = ply:SteamID64()
	if P.HasEssence(ply, essenceId) then return end

	local coins = essence.unlock.coins or 0
	local shards = essence.unlock.shards or 0

	if Arcana.GetCoins(ply) < coins then
		Arcana.SendErrorNotification(ply, "Not enough coins for the " .. essence.label .. " element")
		return
	end
	if Arcana.GetItemCount(ply, "mana_crystal_shard") < shards then
		Arcana.SendErrorNotification(ply, "You need " .. shards .. " crystal shards")
		return
	end

	Arcana.TakeCoins(ply, coins, "Element: " .. essence.label)
	Arcana.TakeItem(ply, "mana_crystal_shard", shards, "Element: " .. essence.label)

	P.EssenceUnlocks[sid] = P.EssenceUnlocks[sid] or {}
	P.EssenceUnlocks[sid][essenceId] = true
	persistPurchase(string.format("INSERT OR REPLACE INTO arcane_essence_unlocks (steamid, essence) VALUES (%s, %s);",
		sql.SQLStr(sid), sql.SQLStr(essenceId)), "persist essence unlock " .. essenceId, ply)

	P.SendState(ply)
end)

----------------------------------------------------------------------
-- Receiver: dissolve a crafted spell (frees the slot; no refund)
----------------------------------------------------------------------
-- Machines pointed at a dissolved spell would only ever error on the next
-- pulse, so clear them. Only this deliberate removal does it: re-syncs and
-- reconnects unregister and re-register the very same ids, and wiping
-- selections there would empty every spell caster each time the owner rejoins.
local function clearCasterSelections(id)
	for _, ent in ipairs(ents.FindByClass("arcana_spell_caster")) do
		if IsValid(ent) and ent:GetSelectedSpell() == id then
			ent:SetSelectedSpell("")
			ent:SetCurrentSpell("")
		end
	end
end

net.Receive("Arcana_Spellcraft_Dissolve", function(_, ply)
	if not IsValid(ply) then return end
	if not rateOk(ply) then return end
	local slot = net.ReadUInt(8)
	local sid = ply:SteamID64()
	if not (P.Active[sid] and P.Active[sid][slot]) then return end
	clearCasterSelections(P.SpellId(sid, slot))
	unregisterAndBroadcast(sid, slot)
	-- The consecration row persists by defhash, so re-importing the same build
	-- later stays consecrated ("the gods remember the pact").
end)
