if SERVER then
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
	AddCSLuaFile("arcana/volumetric_fog.lua")

	resource.AddFile("sound/arcana/arcane_1.ogg")
	resource.AddFile("sound/arcana/arcane_2.ogg")
	resource.AddFile("sound/arcana/arcane_3.ogg")

	resource.AddFile("materials/arcana/pattern.vmt")
end

include("arcana/core.lua")
include("arcana/environments.lua")
include("arcana/mana_network.lua")
include("arcana/astral_vault.lua")
include("arcana/soul_mode.lua")
include("arcana/volumetric_fog.lua")

if SERVER then
	include("arcana/mana_crystals.lua")
end

if CLIENT then
	include("arcana/circles.lua")
	include("arcana/enchant_vfx.lua")
	include("arcana/hud.lua")
	include("arcana/spell_browser.lua")
	include("arcana/voice_activation.lua")
end

-- Load all statuses from arcana/status/*.lua
do
	local files = file.Find("arcana/status/*.lua", "LUA")
	for _, fname in ipairs(files) do
		if SERVER then
			AddCSLuaFile("arcana/status/" .. fname)
		end
		include("arcana/status/" .. fname)
	end
end

-- Load all environments from arcana/environments/*.lua so each environment can live in its own file
do
	local files = file.Find("arcana/environments/*.lua", "LUA")
	for _, fname in ipairs(files) do
		if SERVER then
			AddCSLuaFile("arcana/environments/" .. fname)
		end
		include("arcana/environments/" .. fname)
	end
end

-- Load all spells from arcana/spells/*.lua so each spell can live in its own file
do
	local files = file.Find("arcana/spells/*.lua", "LUA")
	for _, fname in ipairs(files) do
		if SERVER then
			AddCSLuaFile("arcana/spells/" .. fname)
		end

		include("arcana/spells/" .. fname)
	end
end

-- Load all enchantments from arcana/enchantments/*.lua so each enchantment can live in its own file
do
	local files = file.Find("arcana/enchantments/*.lua", "LUA")
	for _, fname in ipairs(files) do
		if SERVER then
			AddCSLuaFile("arcana/enchantments/" .. fname)
		end

		include("arcana/enchantments/" .. fname)
	end
end

local function applyFallback(tbl, name, fallback)
	if not tbl[name] then
		tbl[name] = fallback
	end
end

-- testing
hook.Add("InitPostEntity", "Arcana_Testing", function()
	local PLY = FindMetaTable("Player")

	applyFallback(PLY, "GetCoins", function(amount) return 2e6 end)
	applyFallback(PLY, "TakeCoins", function(amount, reason) end)
	applyFallback(PLY, "GiveCoins", function(amount, reason) end)

	applyFallback(PLY, "GetItemCount", function(itemClass) return 2e6 end)
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