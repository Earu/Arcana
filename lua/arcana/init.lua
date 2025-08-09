if SERVER then
	AddCSLuaFile("arcana/core.lua")
	AddCSLuaFile("arcana/circles.lua")
	AddCSLuaFile("arcana/hud.lua")

	resource.AddFile("sound/arcana/magic1.ogg")
	resource.AddFile("sound/arcana/magic2.ogg")
	resource.AddFile("sound/arcana/magic3.ogg")
end

include("arcana/core.lua")

if CLIENT then
	include("arcana/circles.lua")
	include("arcana/hud.lua")
end

-- Load all spells from arcana/spells/*.lua so each spell can live in its own file
do
	local files = file.Find("arcana/spells/*.lua", "LUA")
	for _, fname in ipairs(files) do
		if SERVER then AddCSLuaFile("arcana/spells/" .. fname) end
		include("arcana/spells/" .. fname)
	end
end

-- testing
hook.Add("InitPostEntity", "Arcana_Testing", function()
	local PLY = FindMetaTable("Player")

	if not PLY.GetCoins then
		PLY.GetCoins = function() return 1000 end
		PLY.TakeCoins = function() end
		PLY.GiveCoins = function() end
	end

	if not PLY.GetItemCount then
		PLY.GetItemCount = function() return 10 end
	end
end)

-- Starter spell for new players
hook.Add("PlayerInitialSpawn", "Arcana_GiveStarterSpell", function(ply)
	timer.Simple(2, function()
		if IsValid(ply) and Arcane then
			Arcane:UnlockSpell(ply, "fireball")
		end
	end)
end)