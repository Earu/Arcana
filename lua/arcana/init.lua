if SERVER then
	AddCSLuaFile("arcana/art_deco.lua")
	AddCSLuaFile("arcana/core.lua")
	AddCSLuaFile("arcana/environments.lua")
	AddCSLuaFile("arcana/circles.lua")
	AddCSLuaFile("arcana/enchant_vfx.lua")
	AddCSLuaFile("arcana/hud.lua")
	AddCSLuaFile("arcana/spell_browser.lua")
	AddCSLuaFile("arcana/voice_activation.lua")
	AddCSLuaFile("arcana/mana_network.lua")
	AddCSLuaFile("arcana/mana_crystals.lua")
	AddCSLuaFile("arcana/astral_vault.lua")
	AddCSLuaFile("arcana/soul_mode.lua")

	resource.AddFile("sound/arcana/arcane_1.ogg")
	resource.AddFile("sound/arcana/arcane_2.ogg")
	resource.AddFile("sound/arcana/arcane_3.ogg")

	resource.AddFile("materials/arcana/pattern.vmt")
	resource.AddFile("materials/arcana/pattern_antique_stone.vmt")
end

include("arcana/core.lua")
include("arcana/circles.lua")
include("arcana/environments.lua")
include("arcana/mana_network.lua")
include("arcana/astral_vault.lua")
include("arcana/soul_mode.lua")

if SERVER then
	include("arcana/mana_crystals.lua")
end

if CLIENT then
	include("arcana/art_deco.lua")
	include("arcana/enchant_vfx.lua")
	include("arcana/hud.lua")
	include("arcana/spell_browser.lua")
	include("arcana/voice_activation.lua")
end

local function includePath(path)
	local files = file.Find(path .. "/*.lua", "LUA")
	for _, fname in ipairs(files) do
		if SERVER then
			AddCSLuaFile(path .. "/" .. fname)
		end
		include(path .. "/" .. fname)
	end
end

includePath("arcana/common")
includePath("arcana/status")
includePath("arcana/environments")
includePath("arcana/spells")
includePath("arcana/enchantments")

local function applyFallback(tbl, name, fallback)
	if not tbl[name] then
		tbl[name] = fallback
	end
end

-- testing
hook.Add("InitPostEntity", "Arcana_Testing", function()
	local PLY = FindMetaTable("Player")

	applyFallback(PLY, "GetCoins", function(amount) return 2e99 end)
	applyFallback(PLY, "TakeCoins", function(amount, reason) end)
	applyFallback(PLY, "GiveCoins", function(amount, reason) end)

	applyFallback(PLY, "GetItemCount", function(itemClass) return 2e99 end)
	applyFallback(PLY, "TakeItem", function(itemClass, amount, reason) end)
	applyFallback(PLY, "GiveItem", function(itemClass, amount, reason) end)
end)

if SERVER then
	-- Starter spell for new players
	hook.Add("WeaponEquip", "Arcana_GiveStarterSpell", function(wep, ply)
		if wep:GetClass() == "grimoire" and IsValid(ply) then
			local data = Arcane:GetPlayerData(ply)

			if data and not data.unlocked_spells["fireball"] then
				Arcane:UnlockSpell(ply, "fireball", true)
			end
		end
	end)
end