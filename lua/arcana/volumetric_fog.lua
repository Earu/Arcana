-- Volumetric Fog System for Arcana
-- Ported from merc_fog2 by ZH-Hristov
-- https://github.com/ZH-Hristov/merc_fog2

if SERVER then
	require("shader_to_gma")
	resource.AddShader("fog_volume_3dnoise_ps20b")
	resource.AddFile("materials/arcana/mercfog3dnoise.vtf")
	return
end

Arcane = Arcane or {}
Arcane.VolumetricFog = Arcane.VolumetricFog or {}

local mat_SetFloat = FindMetaTable("IMaterial").SetFloat
local mat_SetMatrix = FindMetaTable("IMaterial").SetMatrix
local render_OverrideBlend = _G.render.OverrideBlend
local render_DrawScreenQuad = _G.render.DrawScreenQuad
local render_SetMaterial = _G.render.SetMaterial
local BLEND_ONE, BLEND_ONE_MINUS_SRC_ALPHA, BLENDFUNC_ADD = _G.BLEND_ONE, _G.BLEND_ONE_MINUS_SRC_ALPHA, _G.BLENDFUNC_ADD
local emtx = {0, 0, 0, 0}

-- Material reference
local FOG_MAT
if file.Exists("shaders/fxc/fog_volume_3dnoise_ps20.fxc", "GAME") then
	FOG_MAT = CreateShaderMaterial("fog_volume_3dnoise", {
		["$pixshader"] = "fog_volume_3dnoise_ps20",

		["$basetexture"] = "_rt_fullframefb",
		["$texture1"] = "_rt_WPDepth",
		["$texture2"] = "arcana/mercfog3dnoise",

		["$linearread_texture1"] = "1",
		["$linearread_texture2"] = "1",

		["$vertextransform"] = "1",
		["$alphablend"] = "0",
	})
else
	hook.Add("ShaderMounted", "Arcana_VolumetricFog", function()
		FOG_MAT = CreateShaderMaterial("fog_volume_3dnoise", {
			["$pixshader"] = "fog_volume_3dnoise_ps20",

			["$basetexture"] = "_rt_fullframefb",
			["$texture1"] = "_rt_WPDepth",
			["$texture2"] = "arcana/mercfog3dnoise",

			["$linearread_texture1"] = "1",
			["$linearread_texture2"] = "1",

			["$vertextransform"] = "1",
			["$alphablend"] = "0",
		})
	end)
end

-- Active fog volumes
local activeVolumes = {}

-- Draw a volumetric fog volume with 3D noise
-- @param pos Vector - Center position of the fog volume
-- @param aabb Vector - Size of the fog volume (width x, width y, height z)
-- @param density Number - Fog density (0-3)
-- @param fogstart Number - Distance at which fog starts
-- @param fogend Number - Distance at which fog ends
-- @param color Vector - Fog color (0-1)
-- @param edgefade Number - Edge fade distance
-- @param noisesize Number - Size of the noise pattern
-- @param noisemininfluence Number - Minimum noise influence (0-1)
-- @param noisemaxinfluence Number - Maximum noise influence (0-1)
-- @param scrollx Number - X-axis scroll speed
-- @param scrolly Number - Y-axis scroll speed
-- @param scrollz Number - Z-axis scroll speed
function Arcane.VolumetricFog.Draw3DNoise(pos, aabb, density, fogstart, fogend, color, edgefade, noisesize, noisemininfluence, noisemaxinfluence, scrollx, scrolly, scrollz)
	if not FOG_MAT then return end

	local mat = FOG_MAT
	local ep = LocalPlayer():EyePos()

	-- Eye position
	mat_SetFloat(mat, "$c0_x", ep.x)
	mat_SetFloat(mat, "$c0_y", ep.y)
	mat_SetFloat(mat, "$c0_z", ep.z)
	mat_SetFloat(mat, "$c0_w", edgefade)

	-- Fog color and density
	mat_SetFloat(mat, "$c1_x", color.x)
	mat_SetFloat(mat, "$c1_y", color.y)
	mat_SetFloat(mat, "$c1_z", color.z)
	mat_SetFloat(mat, "$c1_w", density)

	-- Volume size (half extents)
	mat_SetFloat(mat, "$c2_x", aabb.x * 0.5)
	mat_SetFloat(mat, "$c2_y", aabb.y * 0.5)
	mat_SetFloat(mat, "$c2_z", aabb.z * 0.5)
	mat_SetFloat(mat, "$c2_w", fogstart)

	-- Volume position and fog end
	mat_SetFloat(mat, "$c3_x", pos.x)
	mat_SetFloat(mat, "$c3_y", pos.y)
	mat_SetFloat(mat, "$c3_z", pos.z)
	mat_SetFloat(mat, "$c3_w", fogend)

	-- Noise parameters via matrix
	mat_SetMatrix(mat, "$viewprojmat", Matrix({
		{CurTime(), noisesize, noisemininfluence, noisemaxinfluence},
		{scrollx, scrolly, scrollz, 0},
		emtx,
		emtx
	}))

	render_SetMaterial(mat)
	render_OverrideBlend(true, BLEND_ONE, BLEND_ONE_MINUS_SRC_ALPHA, BLENDFUNC_ADD, BLEND_ONE, BLEND_ONE_MINUS_SRC_ALPHA, BLENDFUNC_ADD)
	render_DrawScreenQuad()
	render_OverrideBlend(false)
end

-- Register a fog volume
-- @param id String - Unique identifier for this fog volume
-- @param params Table - Fog parameters
function Arcane.VolumetricFog.RegisterVolume(id, params)
	local rgb = params.color or Color(153, 179, 204) -- Default bluish fog
	local colorVec = Vector(rgb.r / 255, rgb.g / 255, rgb.b / 255)
	activeVolumes[id] = {
		pos = params.pos or Vector(0, 0, 0),
		aabb = params.aabb or Vector(1000, 1000, 500),
		density = params.density or 0.4,
		fogstart = params.fogstart or 0,
		fogend = params.fogend or 100,
		color = colorVec,
		edgefade = params.edgefade or 30,
		noisesize = params.noisesize or 1000,
		noisemininfluence = params.noisemininfluence or 0,
		noisemaxinfluence = params.noisemaxinfluence or 1,
		scrollx = params.scrollx or 0.02,
		scrolly = params.scrolly or 0.02,
		scrollz = params.scrollz or 0.02,
		enabled = params.enabled ~= false,
	}
end

-- Update a fog volume
-- @param id String - Volume identifier
-- @param params Table - Parameters to update
function Arcane.VolumetricFog.UpdateVolume(id, params)
	if not activeVolumes[id] then return end

	if params.color then
		local rgb = params.color
		rgb = Color(rgb.r / 255, rgb.g / 255, rgb.b / 255)
		params.color = Vector(rgb.r / 255, rgb.g / 255, rgb.b / 255)
	end

	for k, v in pairs(params) do
		activeVolumes[id][k] = v
	end
end

-- Remove a fog volume
-- @param id String - Volume identifier
function Arcane.VolumetricFog.RemoveVolume(id)
	activeVolumes[id] = nil
end

-- Clear all fog volumes
function Arcane.VolumetricFog.ClearAll()
	activeVolumes = {}
end

-- Get a fog volume
-- @param id String - Volume identifier
function Arcane.VolumetricFog.GetVolume(id)
	return activeVolumes[id]
end

local CVAR_DRAW_VOLUMETRIC_FOG = CreateConVar("arcana_draw_volumetric_fog", "1", FCVAR_ARCHIVE, "Draw the volumetric fog effect")

-- Render all active fog volumes
local hasGShader = file.Exists("materials/pp/wp_reconstruction.vmt", "GAME")
local hasNoiseTexture = file.Exists("materials/arcana/mercfog3dnoise.vtf", "GAME")
hook.Add("PostDrawReconstruction", "Arcana_VolumetricFog", function(isDrawingDepth, isDrawSkybox, isDraw3DSkybox)
	if not CVAR_DRAW_VOLUMETRIC_FOG:GetBool() then return end
	if not hasGShader or not hasNoiseTexture then return end

	for id, vol in pairs(activeVolumes) do
		if vol.enabled then
			Arcane.VolumetricFog.Draw3DNoise(
				vol.pos,
				vol.aabb,
				vol.density,
				vol.fogstart,
				vol.fogend,
				vol.color,
				vol.edgefade,
				vol.noisesize,
				vol.noisemininfluence,
				vol.noisemaxinfluence,
				vol.scrollx,
				vol.scrolly,
				vol.scrollz
			)
		end
	end
end)