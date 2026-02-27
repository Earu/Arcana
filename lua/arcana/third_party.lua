local Arcana = _G.Arcana or {}
_G.Arcana = Arcana

-- ============================================================================
-- THIRD-PARTY INTEGRATION GUIDE
-- ============================================================================
-- This file defines the core economy functions used by Arcana for coins and items.
-- By default, Arcana includes a simple inventory system (see default_inventory.lua).
--
-- To integrate Arcana with your own economy system (e.g., DarkRP money, custom
-- inventory addons, etc.), override these functions in your addon's Initialize hook.
--
-- IMPORTANT: Override these functions AFTER Arcana has loaded!
-- ============================================================================

--[[
	==========================================================================
	COINS - Used for spell costs, enchantments, and rituals
	ITEMS - Used for rituals and enchantments
	==========================================================================
]]

if SERVER then
	--[[
		Give coins to a player
		@param ply Player - The player to give coins to
		@param amount number - Amount of coins to give (must be positive)
		@param reason string - Reason for the transaction (for logging/hooks)
		@return boolean - true if successful, false otherwise

		Example override:
		function Arcana:GiveCoins(ply, amount, reason)
			if not IsValid(ply) or amount <= 0 then return false end
			ply:addMoney(amount) -- DarkRP example
			return true
		end
	]]
	function Arcana:GiveCoins(ply, amount, reason)
		-- Default implementation in default_inventory.lua
	end

	--[[
		Take coins from a player
		@param ply Player - The player to take coins from
		@param amount number - Amount of coins to take (must be positive)
		@param reason string - Reason for the transaction (for logging/hooks)
		@return boolean - true if successful, false if insufficient coins

		Example override:
		function Arcana:TakeCoins(ply, amount, reason)
			if not IsValid(ply) or amount <= 0 then return false end
			if ply:getDarkRPVar("money") < amount then return false end
			ply:addMoney(-amount) -- DarkRP example
			return true
		end
	]]
	function Arcana:TakeCoins(ply, amount, reason)
		-- Default implementation in default_inventory.lua
	end

	--[[
		Give items to a player
		@param ply Player - The player to give items to
		@param itemClass string - The item class/ID (e.g., "mana_crystal_shard")
		@param amount number - Amount to give (must be positive)
		@param reason string - Reason for the transaction (for logging/hooks)
		@return boolean - true if successful, false otherwise

		Example override:
		function Arcana:GiveItem(ply, itemClass, amount, reason)
			if not IsValid(ply) or amount <= 0 then return false end
			ply:PS2_AddItem(itemClass, amount) -- PointShop 2 example
			return true
		end
	]]
	function Arcana:GiveItem(ply, itemClass, amount, reason)
		-- Default implementation in default_inventory.lua
	end

	--[[
		Take items from a player
		@param ply Player - The player to take items from
		@param itemClass string - The item class/ID (e.g., "mana_crystal_shard")
		@param amount number - Amount to take (must be positive)
		@param reason string - Reason for the transaction (for logging/hooks)
		@return boolean - true if successful, false if insufficient items

		Example override:
		function Arcana:TakeItem(ply, itemClass, amount, reason)
			if not IsValid(ply) or amount <= 0 then return false end
			if ply:PS2_GetItemCount(itemClass) < amount then return false end
			ply:PS2_RemoveItem(itemClass, amount) -- PointShop 2 example
			return true
		end
	]]
	function Arcana:TakeItem(ply, itemClass, amount, reason)
		-- Default implementation in default_inventory.lua
	end
end

--[[
	==========================================================================
	GETTERS - Used to check if player can afford costs
	==========================================================================
]]

--[[
	Get the number of coins a player has
	@param ply Player - The player to check
	@return number - Amount of coins (or 0 if none)

	Example override:
	function Arcana:GetCoins(ply)
		if SERVER then
			return ply:getDarkRPVar("money") or 0 -- DarkRP example
		else
			return LocalPlayer():getDarkRPVar("money") or 0
		end
	end
]]
function Arcana:GetCoins(ply)
	-- Default implementation in default_inventory.lua
	return 0
end

--[[
	Get the number of a specific item a player has
	@param ply Player - The player to check
	@param itemClass string - The item class/ID (e.g., "mana_crystal_shard")
	@return number - Amount of items (or 0 if none)

	Example override:
	function Arcana:GetItemCount(ply, itemClass)
		if SERVER then
			return ply:PS2_GetItemCount(itemClass) or 0 -- PointShop 2 example
		else
			return LocalPlayer():PS2_GetItemCount(itemClass) or 0
		end
	end
]]
function Arcana:GetItemCount(ply, itemClass)
	-- Default implementation in default_inventory.lua
	return 0
end

--[[
	==========================================================================
	OVERRIDE EXAMPLES FOR COMMON SYSTEMS
	==========================================================================

	--- DarkRP Integration ---
	hook.Add("Initialize", "YourAddon_ArcanaCompat", function()
		function Arcana:GiveCoins(ply, amount, reason)
			if not IsValid(ply) or amount <= 0 then return false end
			ply:addMoney(amount)
			return true
		end

		function Arcana:TakeCoins(ply, amount, reason)
			if not IsValid(ply) or amount <= 0 then return false end
			if ply:getDarkRPVar("money") < amount then return false end
			ply:addMoney(-amount)
			return true
		end

		function Arcana:GetCoins(ply)
			if SERVER then
				return IsValid(ply) and ply:getDarkRPVar("money") or 0
			else
				return LocalPlayer():getDarkRPVar("money") or 0
			end
		end
	end)

	--- Custom MySQL/Database System ---
	hook.Add("Initialize", "YourAddon_ArcanaCompat", function()
		function Arcana:GiveCoins(ply, amount, reason)
			if not IsValid(ply) or amount <= 0 then return false end
			YourDB:AddCoins(ply:SteamID64(), amount)
			return true
		end

		-- ... implement other functions similarly
	end)
]]

-- ============================================================================
-- ASTRAL VAULT DATA PERSISTENCE HOOKS
-- ============================================================================
-- Override these hooks to use custom storage for the Astral Vault weapon storage system

--[[
	Example: Override saving player data (XP, level, spells, etc.)

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
		-- 	Arcana.AstralVaultCache[ply:SteamID64()] = vaultItems
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
