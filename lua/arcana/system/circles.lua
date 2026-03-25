-- Arcana Circles — orchestrator module.
-- Loads ring.lua → magic_circle.lua → band_circle.lua in order,
-- then re-exports the public API to _G for backward compatibility.

require("shader_to_gma")

if SERVER then
	local files, dirs = file.Find("materials/arcana/rings/*.png", "GAME")
	for _, fname in ipairs(files) do
		resource.AddFile("materials/arcana/rings/" .. fname)
	end

	files, dirs = file.Find("materials/arcana/glyphs/*.png", "GAME")
	for _, fname in ipairs(files) do
		resource.AddFile("materials/arcana/glyphs/" .. fname)
	end

	resource.AddShader("arcana_circle_ps30")
	resource.AddShader("arcana_passthrough_vs30")

	AddCSLuaFile("arcana/circles/ring.lua")
	AddCSLuaFile("arcana/circles/magic_circle.lua")
	AddCSLuaFile("arcana/circles/band_circle.lua")
	return
end

Arcana = Arcana or {}
Arcana.Circle = Arcana.Circle or {}

include("arcana/circles/ring.lua")
include("arcana/circles/magic_circle.lua")
include("arcana/circles/band_circle.lua")

local MagicCircle = Arcana.Circle.MagicCircle
local MagicCircleManager = Arcana.Circle.MagicCircleManager
local BandCircle = Arcana.Circle.BandCircle

-- Console commands for in-game testing
concommand.Add("arcana_circle_test", function(ply, cmd, args)
	if not IsValid(ply) then return end
	local tr = ply:GetEyeTrace()
	local pos = tr.HitPos + tr.HitNormal * 5
	local ang = tr.HitNormal:Angle()
	ang:RotateAroundAxis(ang:Right(), 90)
	local intensity = tonumber(args[1]) or 3
	local size = tonumber(args[2]) or 100
	local r = tonumber(args[3]) or 255
	local g = tonumber(args[4]) or 0
	local b = tonumber(args[5]) or 0
	local duration = tonumber(args[6]) or 10
	local lineWidth = tonumber(args[7]) or 3
	local circle = MagicCircle.CreateMagicCircle(pos, ang, Color(r, g, b, 255), intensity, size, duration, lineWidth)
	print("Magic circle created! ID: " .. tostring(circle) .. " Rings: " .. circle:GetRingCount() .. " Line Width: " .. lineWidth)
end)

concommand.Add("arcana_circle_clear", function()
	MagicCircleManager:Clear()
	print("All magic circles cleared!")
end)

concommand.Add("arcana_band_circle_test", function(ply, cmd, args)
	if not IsValid(ply) then return end
	local tr = ply:GetEyeTrace()
	local pos = tr.HitPos + tr.HitNormal * 8
	local ang = Angle(0, 0, 0)
	ang:RotateAroundAxis(tr.HitNormal:Angle():Right(), 0)
	local bc = BandCircle.Create(pos, tr.HitNormal:Angle(), Color(100, 200, 255, 255), tonumber(args[1]) or 80, tonumber(args[2]) or 8)

	if bc then
		bc:AddBand(tonumber(args[3]) or 60, tonumber(args[4]) or 4, { p = 0, y = 35, r = 0 }, 2)
		bc:AddBand((tonumber(args[3]) or 60) * 0.8, (tonumber(args[4]) or 4) * 0.8, { p = 25, y = -20, r = 0 }, 2)
		bc:AddBand((tonumber(args[3]) or 60) * 1.1, (tonumber(args[4]) or 4) * 0.6, { p = 0, y = 0, r = 45 }, 2)
		bc:AddBand((tonumber(args[3]) or 60) * 1.25, (tonumber(args[4]) or 4) * 0.6, { p = 0, y = 45, r = 45 }, 2)
		bc:AddBand((tonumber(args[3]) or 60) * 1.9, (tonumber(args[4]) or 4) * 0.6, { p = -45, y = 0, r = 45 }, 2)
	end
end)

return MagicCircle
