local Arcane = _G.Arcane or {}
_G.Arcane = Arcane

-- OVERRIDE THESE FUNCTIONS TO IMPLEMENT COMPATIBILITY WITH OTHER PLUGINS
-- THIS SHOULD BE DONE IN A "Initialize" HOOK!

if SERVER then
	function Arcane:TakeCoins(ply, amount, reason)
	end

	function Arcane:GiveCoins(ply, amount, reason)
	end

	function Arcane:TakeItem(ply, itemClass, amount, reason)
	end

	function Arcane:GiveItem(ply, itemClass, amount, reason)
	end
end

function Arcane:GetCoins(ply)
	return 2e99
end

function Arcane:GetItemCount(ply, itemClass)
	return 2e99
end

-- OVERRIDE DATA PERSISTENCE
-- To use custom storage (e.g., MySQL, MongoDB, etc.), override these hooks

--[[
	Example: Override saving player data

	hook.Add("SavePlayerDataToSQL", "YourAddonName", function(ply, data)
		-- Your custom save logic here
		-- data contains: xp, level, knowledge_points, unlocked_spells, quickspell_slots, selected_quickslot, last_save

		-- Return true to prevent Arcana's default SQL save
		return true
	end)
]]

--[[
	Example: Override loading player data

	hook.Add("LoadPlayerDataFromSQL", "YourAddonName", function(ply, callback)
		-- Your custom load logic here
		-- When done, call: callback(success, data)
		-- where data should contain: xp, level, knowledge_points, unlocked_spells, quickspell_slots, selected_quickslot, last_save

		-- Example:
		-- YourDatabase:LoadPlayerData(ply:SteamID64(), function(loadedData)
		-- 	callback(true, loadedData)
		-- end)

		-- Return true to prevent Arcana's default SQL load
		return true
	end)
]]

--[[
	Example: Override reading Astral Vault data

	hook.Add("ReadAstralVault", "YourAddonName", function(ply, callback)
		-- Your custom vault read logic here
		-- When done, call: callback(success, items)
		-- where items is an array of vault items (each item contains weapon info and enchantments)

		-- Example:
		-- YourDatabase:LoadVaultData(ply:SteamID64(), function(vaultItems)
		-- 	Arcane.AstralVaultCache[ply:SteamID64()] = vaultItems
		-- 	callback(true, vaultItems)
		-- end)

		-- Return true to prevent Arcana's default SQL read
		return true
	end)
]]

--[[
	Example: Override writing Astral Vault data

	hook.Add("WriteAstralVault", "YourAddonName", function(ply, items)
		-- Your custom vault write logic here
		-- items is an array of vault items to save

		-- Example:
		-- YourDatabase:SaveVaultData(ply:SteamID64(), items)

		-- Return true to prevent Arcana's default SQL write
		return true
	end)
]]