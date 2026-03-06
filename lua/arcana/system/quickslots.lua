-- Quickslot Network — Server-side handlers for player quickslot assignment
-- and selection, with debounced SQL saves to prevent write spam.
-- Extracted from core.lua to isolate the quickslot networking concern.

local Arcana = Arcana

if SERVER then
	util.AddNetworkString("Arcana_SetQuickslot")
	util.AddNetworkString("Arcana_SetSelectedQuickslot")

	local lastQuickslotSave = {}
	local QUICKSLOT_SAVE_DEBOUNCE = 0.5

	local function debouncedQuickslotSave(ply)
		local sid = ply:SteamID64()
		local now = CurTime()
		if (lastQuickslotSave[sid] or 0) + QUICKSLOT_SAVE_DEBOUNCE > now then
			return
		end
		lastQuickslotSave[sid] = now
		Arcana:SavePlayerData(ply)
		Arcana:SyncPlayerData(ply)
	end

	hook.Add("PlayerDisconnected", "Arcana_ClearQuickslotDebounce", function(ply)
		lastQuickslotSave[ply:SteamID64()] = nil
	end)

	-- Assign a spell to a quickslot
	net.Receive("Arcana_SetQuickslot", function(_, ply)
		local slotIndex = math.Clamp(net.ReadUInt(4), 1, 8)
		local spellId = net.ReadString()
		local data = Arcana:GetPlayerData(ply)
		if not data then return end
		if not Arcana.RegisteredSpells[spellId] then return end
		if not data.unlocked_spells[spellId] then return end
		data.quickspell_slots[slotIndex] = spellId
		debouncedQuickslotSave(ply)
	end)

	-- Select the active quickslot
	net.Receive("Arcana_SetSelectedQuickslot", function(_, ply)
		local slotIndex = math.Clamp(net.ReadUInt(4), 1, 8)
		local data = Arcana:GetPlayerData(ply)
		if not data then return end
		data.selected_quickslot = slotIndex
		debouncedQuickslotSave(ply)
	end)
end
