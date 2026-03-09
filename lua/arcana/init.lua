-- Recursively includes all .lua files under a directory path (LUA search path).
local function includePath(path)
	local files, dirs = file.Find(path .. "/*", "LUA")
	for _, fname in ipairs(files or {}) do
		if fname:EndsWith(".lua") then
			if SERVER then AddCSLuaFile(path .. "/" .. fname) end
			include(path .. "/" .. fname)
		end
	end
	for _, dname in ipairs(dirs or {}) do
		includePath(path .. "/" .. dname)
	end
end

local function addRingTextures()
	local files, dirs = file.Find("materials/arcana/rings/*.png", "GAME")
	for _, fname in ipairs(files) do
		resource.AddFile("materials/arcana/rings/" .. fname)
	end

	files, dirs = file.Find("materials/arcana/glyphs/*.png", "GAME")
	for _, fname in ipairs(files) do
		resource.AddFile("materials/arcana/glyphs/" .. fname)
	end
end

if SERVER then
	AddCSLuaFile("arcana/system/art_deco.lua")
	AddCSLuaFile("arcana/system/core.lua")
	AddCSLuaFile("arcana/system/persistence.lua")
	AddCSLuaFile("arcana/system/xp.lua")
	AddCSLuaFile("arcana/system/enchantments.lua")
	AddCSLuaFile("arcana/system/damage.lua")
	AddCSLuaFile("arcana/system/environments.lua")
	AddCSLuaFile("arcana/system/circles.lua")
	AddCSLuaFile("arcana/system/quickslots.lua")
	AddCSLuaFile("arcana/system/lifecycle.lua")
	AddCSLuaFile("arcana/system/hud.lua")
	AddCSLuaFile("arcana/system/mana_network.lua")
	AddCSLuaFile("arcana/system/mana_crystals.lua")
	AddCSLuaFile("arcana/system/tutorial.lua")
	AddCSLuaFile("arcana/system/default_inventory.lua")

	AddCSLuaFile("arcana/system/vfx/casting.lua")
	AddCSLuaFile("arcana/system/vfx/enchants.lua")

	AddCSLuaFile("arcana/astral_vault/config.lua")
	AddCSLuaFile("arcana/astral_vault/vault.lua")
	AddCSLuaFile("arcana/astral_vault/ui.lua")

	AddCSLuaFile("arcana/spell_browser.lua")
	AddCSLuaFile("arcana/soul_mode.lua")
	AddCSLuaFile("arcana/voice_activation.lua")

	resource.AddFile("resource/fonts/pulsian.ttf")

	resource.AddFile("sound/arcana/arcane_1.ogg")
	resource.AddFile("sound/arcana/arcane_2.ogg")
	resource.AddFile("sound/arcana/arcane_3.ogg")

	resource.AddFile("materials/arcana/pattern.vmt")
	resource.AddFile("materials/arcana/pattern_antique_stone.vmt")

	addRingTextures()
end

include("arcana/system/core.lua")
include("arcana/system/persistence.lua")
include("arcana/system/xp.lua")
include("arcana/system/enchantments.lua")
include("arcana/system/damage.lua")
include("arcana/system/circles.lua")
include("arcana/system/quickslots.lua")
include("arcana/system/lifecycle.lua")
include("arcana/system/environments.lua")
include("arcana/system/mana_network.lua")
include("arcana/system/tutorial.lua")

include("arcana/system/vfx/casting.lua")

include("arcana/astral_vault/config.lua")
include("arcana/astral_vault/vault.lua")
include("arcana/astral_vault/ui.lua")

include("arcana/soul_mode.lua")

includePath("arcana/common")

if SERVER then
	include("arcana/system/mana_crystals.lua")
	include("arcana/system/default_inventory.lua")
end

if CLIENT then
	include("arcana/system/art_deco.lua")
	include("arcana/system/hud.lua")
	include("arcana/system/default_inventory.lua")

	include("arcana/system/vfx/enchants.lua")

	include("arcana/spell_browser.lua")
	include("arcana/voice_activation.lua")
end

includePath("arcana/status")
includePath("arcana/environments")
includePath("arcana/spells")
includePath("arcana/enchantments")