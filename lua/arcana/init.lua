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

if SERVER then
	AddCSLuaFile("arcana/art_deco.lua")
	AddCSLuaFile("arcana/core.lua")
	AddCSLuaFile("arcana/persistence.lua")
	AddCSLuaFile("arcana/xp.lua")
	AddCSLuaFile("arcana/enchantments_api.lua")
	AddCSLuaFile("arcana/damage.lua")
	AddCSLuaFile("arcana/environments.lua")
	AddCSLuaFile("arcana/circles.lua")
	AddCSLuaFile("arcana/vfx_network.lua")
	AddCSLuaFile("arcana/quickslots.lua")
	AddCSLuaFile("arcana/lifecycle.lua")
	AddCSLuaFile("arcana/enchant_vfx.lua")
	AddCSLuaFile("arcana/hud.lua")
	AddCSLuaFile("arcana/spell_browser.lua")
	AddCSLuaFile("arcana/voice_activation.lua")
	AddCSLuaFile("arcana/mana_network.lua")
	AddCSLuaFile("arcana/mana_crystals.lua")
	AddCSLuaFile("arcana/astral_vault_config.lua")
	AddCSLuaFile("arcana/astral_vault.lua")
	AddCSLuaFile("arcana/astral_vault_ui.lua")
	AddCSLuaFile("arcana/soul_mode.lua")
	AddCSLuaFile("arcana/tutorial.lua")
	AddCSLuaFile("arcana/default_inventory.lua")

	resource.AddFile("resource/fonts/pulsian.ttf")

	resource.AddFile("sound/arcana/arcane_1.ogg")
	resource.AddFile("sound/arcana/arcane_2.ogg")
	resource.AddFile("sound/arcana/arcane_3.ogg")

	resource.AddFile("materials/arcana/pattern.vmt")
	resource.AddFile("materials/arcana/pattern_antique_stone.vmt")
end

include("arcana/core.lua")
include("arcana/persistence.lua")
include("arcana/xp.lua")
include("arcana/enchantments_api.lua")
include("arcana/damage.lua")
include("arcana/circles.lua")
include("arcana/vfx_network.lua")
include("arcana/quickslots.lua")
include("arcana/lifecycle.lua")
include("arcana/environments.lua")
include("arcana/mana_network.lua")
include("arcana/astral_vault_config.lua")
include("arcana/astral_vault.lua")
include("arcana/astral_vault_ui.lua")
include("arcana/soul_mode.lua")
include("arcana/tutorial.lua")

includePath("arcana/common")

if SERVER then
	include("arcana/mana_crystals.lua")
	include("arcana/default_inventory.lua")
	include("arcana/map_setup.lua")
end

if CLIENT then
	include("arcana/art_deco.lua")
	include("arcana/enchant_vfx.lua")
	include("arcana/hud.lua")
	include("arcana/spell_browser.lua")
	include("arcana/voice_activation.lua")
	include("arcana/default_inventory.lua")
end

includePath("arcana/status")
includePath("arcana/environments")
includePath("arcana/spells/elemental")
includePath("arcana/spells/rituals")
includePath("arcana/spells/utility")
includePath("arcana/enchantments")

if SERVER then
	-- Spell-specific network strings centralized here so auditing is easy.
	util.AddNetworkString("Arcana_PoisonCloud")
	util.AddNetworkString("Arcana_WindSweep")
	util.AddNetworkString("Arcana_WindDash")
	util.AddNetworkString("Arcana_FrostNovaBurst")
	util.AddNetworkString("Arcana_FallenDown_BeamStart")
	util.AddNetworkString("Arcana_FallenDown_BeamTick")
	util.AddNetworkString("Arcana_FallenDown_ImpactWave")
	util.AddNetworkString("Arcana_FallenDown_VacuumImplosion")
	util.AddNetworkString("Arcana_FallenDown_VacuumCollapse")
	util.AddNetworkString("Arcana_FallenDown_BGM")
	util.AddNetworkString("Arcana_Blackhole_Climax")
	util.AddNetworkString("Arcana_MeteorStorm_Climax")
	util.AddNetworkString("Arcana_MeteorStorm_InitialVFX")
	util.AddNetworkString("Arcana_MeteorStorm_MeteorStrike")
	util.AddNetworkString("Arcana_MeteorStorm_FinalImpact")
	util.AddNetworkString("Arcana_MeteorStorm_Fissure")
	util.AddNetworkString("Arcana_Phoenix_Start")
	util.AddNetworkString("Arcana_Phoenix_Stop")
	util.AddNetworkString("Arcana_EarthShatter_VFX")
	util.AddNetworkString("Arcana_WindBlast")
	util.AddNetworkString("Arcana_LightningStrike")
	util.AddNetworkString("Arcana_LightningChain")
	util.AddNetworkString("Arcana_RingOfFire_VFX")

	-- Starter spell for new players
	hook.Add("WeaponEquip", "Arcana_GiveStarterSpell", function(wep, ply)
		if wep:GetClass() == "grimoire" and IsValid(ply) then
			local data = Arcana:GetPlayerData(ply)

			if data and not data.unlocked_spells["fireball"] then
				Arcana:UnlockSpell(ply, "fireball", true)
			end
		end
	end)
end