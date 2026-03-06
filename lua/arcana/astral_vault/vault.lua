-- Astral Vault — server-side persistence, SQL schema, and net.Receive handlers.
-- Client UI (panels, galaxy background, slot cards) lives in astral_vault_ui.lua.
local Arcana = _G.Arcana or {}

-- Networking
if SERVER then
	resource.AddFile("materials/arcana/astral_vault.png")

	util.AddNetworkString("Arcana_AstralVault_Open")
	util.AddNetworkString("Arcana_AstralVault_RequestOpen")
	util.AddNetworkString("Arcana_AstralVault_Imprint")
	util.AddNetworkString("Arcana_AstralVault_Summon")
	util.AddNetworkString("Arcana_AstralVault_Delete")
end

-- Cost constants shared with the client UI live in astral_vault_config.lua (Arcana.VaultConfig).
local VAULT_CFG = Arcana.VaultConfig

-- Utility: fetch enchantment ids from a weapon entity, stable order
local function collectEnchantIds(wep)
	local set = Arcana and Arcana.GetEntityEnchantments and Arcana:GetEntityEnchantments(wep) or {}
	local out = {}
	for id, on in pairs(set) do if on then out[#out + 1] = id end end
	table.sort(out)
	return out
end

-- SERVER: persistence layer (separate, compact table)
if SERVER then
	Arcana.AstralVaultCache = Arcana.AstralVaultCache or {}

	local ensured = false
	local function ensureVaultTable()
		if ensured then return true end

		local ok = sql.Query([[CREATE TABLE IF NOT EXISTS arcane_astral_vault (
			steamid	TEXT PRIMARY KEY,
			items	TEXT NOT NULL DEFAULT '[]'
		);]])
		if ok == false then
			MsgC(Color(255, 80, 80), "[Arcana][SQL] ", Color(255,255,255), "CREATE TABLE arcane_astral_vault failed: " .. tostring(sql.LastError() or "?") .. "\n")
			return false
		end

		ensured = true
		return true
	end

	local function deserializeVaultRows(rows)
		local function decodeJSON(json)
			json = (json or "[]"):gsub("^%'", ""):gsub("%'$", "")
			local ok, arr = pcall(util.JSONToTable, json)
			if ok and istable(arr) then return arr end
			return {}
		end
		if not istable(rows) or not rows[1] then return {} end
		return decodeJSON(rows[1].items)
	end

	local function readVault(ply, callback)
		if not IsValid(ply) then return end

		local sid = ply:SteamID64()
		if Arcana.AstralVaultCache[sid] then
			callback(true, Arcana.AstralVaultCache[sid])
			return
		end

		-- Allow third-party override
		local handled = Arcana.RunHook("ReadAstralVault", ply, callback)
		if handled == true then return end

		if not ensureVaultTable() then return end

		local q = string.format("SELECT * FROM arcane_astral_vault WHERE steamid = '%s' LIMIT 1;", sql.SQLStr(sid, true))
		local rows = sql.Query(q)
		if rows == false then callback(false, {}) return end

		local items = deserializeVaultRows(rows)
		Arcana.AstralVaultCache[sid] = items
		callback(true, items)
	end

	local function writeVault(ply, items)
		if not IsValid(ply) then return end

		local sid = ply:SteamID64()
		Arcana.AstralVaultCache[sid] = items or {}

		-- Allow third-party override
		local handled = Arcana.RunHook("WriteAstralVault", ply, items)
		if handled == true then return end

		if not ensureVaultTable() then return end

		local json = sql.SQLStr(util.TableToJSON(items or {}) or "[]")
		local id = sql.SQLStr(sid, true)

		local q = string.format("INSERT OR REPLACE INTO arcane_astral_vault (steamid, items) VALUES ('%s', %s);", id, json)
		local writeOk = sql.Query(q)
		if writeOk == false then
			MsgC(Color(255, 80, 80), "[Arcana][SQL] ", Color(255, 255, 255), "writeVault failed for " .. tostring(sid) .. ": " .. tostring(sql.LastError() or "?") .. "\n")
		end
	end

	local function canAfford(ply, coins, shards)
		local haveCoins = Arcana:GetCoins(ply)
		local haveShards = Arcana:GetItemCount(ply, "mana_crystal_shard")
		if haveCoins < (coins or 0) then return false, "Insufficient coins" end
		if haveShards < (shards or 0) then return false, "Missing item: mana_crystal_shard" end
		return true
	end

	local function charge(ply, coins, shards, reason)
		if coins and coins > 0 then Arcana:TakeCoins(ply, coins, reason or "Astral Vault") end
		if shards and shards > 0 then Arcana:TakeItem(ply, "mana_crystal_shard", shards, reason or "Astral Vault") end
	end

	local function sendOpen(ply, items)
		net.Start("Arcana_AstralVault_Open")
		net.WriteTable(items or {})
		net.Send(ply)
	end

	-- Returns true if the player is a valid, living vault actor; false otherwise.
	local function validateVaultActor(ply)
		return IsValid(ply) and ply:Alive()
	end

	-- Open request (from client)
	net.Receive("Arcana_AstralVault_RequestOpen", function(_, ply)
		if not validateVaultActor(ply) then return end
		readVault(ply, function(ok, items)
			if not ok then return end
			sendOpen(ply, items)
		end)
	end)

	-- Imprint current weapon into vault (consumes weapon)
	net.Receive("Arcana_AstralVault_Imprint", function(_, ply)
		if not validateVaultActor(ply) then return end

		local nickname = tostring(net.ReadString() or "")
		local wep = ply:GetActiveWeapon()
		if not IsValid(wep) then return end

		local cls = wep:GetClass()
		local swep = list.Get("Weapon")[cls]
		local isAdmin = ply:IsAdmin() or game.SinglePlayer()
		if (not swep.Spawnable or swep.AdminOnly) and not isAdmin then return end
		if not gamemode.Call("PlayerGiveSWEP", ply, cls, swep) then return end

		local ids = collectEnchantIds(wep)
		readVault(ply, function(ok, items)
			if not ok then return end
			items = items or {}
			if #items >= VAULT_CFG.MAX_SLOTS then
				if Arcana.SendErrorNotification then Arcana:SendErrorNotification(ply, "Astral vault is full") end
				return
			end

			local canBuy, reason = canAfford(ply, VAULT_CFG.STORE_COINS, VAULT_CFG.STORE_SHARDS)
			if not canBuy then if Arcana.SendErrorNotification then Arcana:SendErrorNotification(ply, reason) end return end

			charge(ply, VAULT_CFG.STORE_COINS, VAULT_CFG.STORE_SHARDS, "Astral Vault Imprint")

			if cls and ply.HasWeapon and ply:HasWeapon(cls) then ply:StripWeapon(cls) end

			local pretty = (swep and (swep.PrintName or swep.Printname)) or cls
			local entry = {
				id = util.CRC(cls .. table.concat(ids) .. os.time()),
				class = cls,
				name = (nickname ~= "" and nickname) or pretty,
				print = pretty,
				enchant_ids = ids,
				time = os.time(),
			}

			table.insert(items, 1, entry)
			writeVault(ply, items)
			sendOpen(ply, items)
		end)
	end)

	-- Summon an entry (give fresh weapon and apply enchants)
	net.Receive("Arcana_AstralVault_Summon", function(_, ply)
		if not validateVaultActor(ply) then return end

		local entryId = tostring(net.ReadString() or "")
		readVault(ply, function(ok, items)
			if not ok then return end
			local entry
			for _, it in ipairs(items or {}) do
				if tostring(it.id) == entryId then entry = it break end
			end
			if not entry then return end

			local canBuy, reason = canAfford(ply, VAULT_CFG.SUMMON_COINS, VAULT_CFG.SUMMON_SHARDS)
			if not canBuy then if Arcana.SendErrorNotification then Arcana:SendErrorNotification(ply, reason) end return end

			local cls = entry.class
			local swep = list.Get("Weapon")[cls]
			if not swep then return end

			local isAdmin = ply:IsAdmin() or game.SinglePlayer()
			if (not swep.Spawnable or swep.AdminOnly) and not isAdmin then return end
			if not gamemode.Call("PlayerGiveSWEP", ply, cls, swep) then return end

			charge(ply, VAULT_CFG.SUMMON_COINS, VAULT_CFG.SUMMON_SHARDS, "Astral Vault Summon")

			if cls and ply.HasWeapon and ply:HasWeapon(cls) then ply:StripWeapon(cls) end
			ply:Give(cls)

			timer.Simple(0, function()
				if not IsValid(ply) then return end

				local newWep = ply.GetWeapon and ply:GetWeapon(cls) or nil
				if not IsValid(newWep) then return end

				for _, id in ipairs(entry.enchant_ids or {}) do
					Arcana:RestoreEnchantmentToWeaponEntity(ply, newWep, id)
				end

				Arcana.SyncWeaponEnchantNW(newWep)
				ply:SelectWeapon(cls)
			end)
		end)
	end)

	-- Delete an entry from the vault
	net.Receive("Arcana_AstralVault_Delete", function(_, ply)
		if not validateVaultActor(ply) then return end
		local entryId = tostring(net.ReadString() or "")
		readVault(ply, function(ok, items)
			if not ok then return end
			local out = {}
			for _, it in ipairs(items or {}) do if tostring(it.id) ~= entryId then out[#out + 1] = it end end
			writeVault(ply, out)
			sendOpen(ply, out)
		end)
	end)
end
