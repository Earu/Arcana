-- Player Lifecycle Hooks — handles player join (data load), death (interrupt spell),
-- and disconnect (save + cleanup). Extracted from core.lua to isolate the lifecycle concern.

assert(Arcana and Arcana.RunHook, "lifecycle.lua requires core.lua to be loaded first")
local Arcana = Arcana

if SERVER then
	-- Load player data on first actual movement (avoids loading during initial spawn limbo)
	local justSpawned = {}

	hook.Add("PlayerInitialSpawn", "Arcana_PlayerJoin", function(ply)
		justSpawned[ply] = true
	end)

	hook.Add("SetupMove", "Arcana_PlayerJoin", function(ply, _, ucmd)
		if justSpawned[ply] and not ucmd:IsForced() then
			justSpawned[ply] = nil

			Arcana:LoadPlayerData(ply, function(data)
				if Arcana.Inventory and Arcana.Inventory.OnPlayerDataLoaded then
					Arcana.Inventory.OnPlayerDataLoaded(ply)
				end
				Arcana.RunHook("LoadedPlayerData", ply, data)
			end)
		end
	end)

	hook.Add("PlayerDeath", "Arcana_InterruptOnDeath", function(victim)
		local pdata = Arcana:GetPlayerData(victim)
		if pdata and pdata.casting_spell then
			Arcana:InterruptSpell(victim, pdata.casting_spell)
		end
	end)

	hook.Add("PlayerDisconnected", "Arcana_PlayerLeave", function(ply)
		local pdata = Arcana:GetPlayerData(ply)
		if pdata and pdata.casting_spell then
			Arcana:InterruptSpell(ply, pdata.casting_spell)
		end

		local sid = IsValid(ply) and ply:SteamID64() or nil
		if sid then
			timer.Remove("Arcana_RetryLoad_" .. tostring(sid))
			Arcana.RetryStateBySteamID[sid] = nil
		end
		Arcana:SavePlayerData(ply)
		if Arcana.Inventory and Arcana.Inventory.OnPlayerDisconnected then
			Arcana.Inventory.OnPlayerDisconnected(ply)
		end
	end)
end
