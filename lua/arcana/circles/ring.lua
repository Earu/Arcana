-- Arcana Ring primitive renderer.
-- Provides the Ring class used by MagicCircle and BandCircle for all low-level
-- ring and glyph rendering. Exports: Arcana.Circle.Ring, Arcana.Circle.RING_TYPES

Arcana = Arcana or {}
Arcana.Circle = Arcana.Circle or {}

local render_SetMaterial = _G.render.SetMaterial
local render_SetColorModulation = _G.render.SetColorModulation
local render_SetBlend = _G.render.SetBlend
local render_SetLightingMode = _G.render.SetLightingMode
local CreateMaterial = _G.CreateMaterial
local cam_Start3D2D = _G.cam.Start3D2D
local cam_End3D2D = _G.cam.End3D2D
local cam_PushModelMatrix = _G.cam.PushModelMatrix
local cam_PopModelMatrix = _G.cam.PopModelMatrix
local surface_SetMaterial = _G.surface.SetMaterial
local surface_DrawTexturedRect = _G.surface.DrawTexturedRect
local surface_SetDrawColor = _G.surface.SetDrawColor
local surface_DrawTexturedRectRotated = _G.surface.DrawTexturedRectRotated
local Mesh = _G.Mesh
local math_random = _G.math.random
local math_pi = _G.math.pi
local math_sin = _G.math.sin
local math_cos = _G.math.cos
local math_floor = _G.math.floor
local math_max = _G.math.max
local math_min = _G.math.min
local table_insert = _G.table.insert
local Angle = _G.Angle
local Vector = _G.Vector

local VECTOR_ZERO = Vector(0, 0, 0)
local VECTOR_X1   = Vector(1, 0, 0)

local Ring = {}
Ring.__index = Ring

-- Ring type definitions
local RING_TYPES = {
	PATTERN_LINES = 1,
	RUNE_STAR     = 2,
	SIMPLE_LINE   = 3,
	STAR_RING     = 4,
	BAND_RING     = 5,
}

-- Default ring ejection sound candidates
local MAGIC_EJECT_SOUNDS = { "ambient/energy/zap1.wav", "ambient/energy/zap2.wav", "ambient/energy/zap3.wav" }

local SHADER_AVAILABLE = false

-- Helper: create a circle material wrapping a texture (custom shader when available)
--
-- Textures are DXT5 VTFs, not the PNGs they were authored from. Material("x.png")
-- uploads BGRA8888 with no mips - 4 bytes/px, 16 MB for one 2048x2048 ring - while
-- DXT5 is 1 byte/px and carries both the greyscale RGB the shaderless path needs
-- and the 8-bit alpha the shader reads, so a single file serves both: 16 MB ->
-- 5.33 MB per ring. Regenerate them with tools/png_to_vtf.py.
--
-- A8 (1 byte/px, alpha only) looks like the better fit since arcana_circle_ps30
-- samples nothing but .a - it is not. The engine expands A8 and IA88 to BGRA8888
-- on load, measured at 21,844 kb per ring against the PNG's 16,384 kb, so both
-- cost MORE than doing nothing. See the note in tools/png_to_vtf.py before
-- reaching for them again.
--
-- No $nolod: these have a real mip chain, so players who turn texture quality
-- down should be allowed to drop a level.
local function CreateCircleMaterial(name, textureName)
	local isBand = textureName:match("band") ~= nil

	if not SHADER_AVAILABLE then
		return CreateMaterial(name .. "_" .. FrameNumber(), isBand and "VertexLitGeneric" or "UnlitGeneric", {
			["$basetexture"] = textureName,
			["$translucent"] = 1,
			["$vertexalpha"] = 1,
			["$vertexcolor"] = 1,
			["$nocull"]      = 1,
			["$additive"]    = 0,
			["$model"]       = isBand and 1 or 0,
		})
	end

	return CreateShaderMaterial(name .. "_" .. FrameNumber(), {
		["$pixshader"]   = "arcana_circle_ps30",
		["$vertexshader"] = "arcana_passthrough_vs30",
		["$basetexture"] = textureName,
		["$translucent"] = 1,
		["$vertexalpha"] = 1,
		["$vertexcolor"] = 1,
		["$nocull"]      = 1,
		["$additive"]    = 0,
		["$ignorez"]     = 0,
		-- Band meshes live in the 3D scene: they must z-test against world and
		-- viewmodel depth but never write their own (translucent VFX). Unlike
		-- stock shaders, screenspace_general defaults to NO depth test at all,
		-- so it has to be enabled explicitly. Do NOT replace this with
		-- render.OverrideDepthEnable(true, true): that forces depth WRITES too,
		-- which breaks SWEPs that custom-draw their viewmodel after our hooks
		-- (e.g. TF2 packs) - the gun fails the z-test against the rings' stamped
		-- depth and the rings show through it.
		["$depthtest"]   = isBand and 1 or 0,
		["$writedepth"]  = 0,
		["$c0_x"]        = 0.0,
		["$c0_y"]        = 1.0,
		["$c1_x"]        = 1.0,
		["$c1_y"]        = 1.0,
		["$c1_z"]        = 1.0,
	})
end

-- ── Ring material system ──────────────────────────────────────────────────────
-- Ring textures are 2048×2048; the ring circle sits at 47% from the canvas centre.
local RING_TEXTURE_SIZE = 2048
local RING_RADIUS_PX    = math_floor(RING_TEXTURE_SIZE * 0.47)   -- 962 px, matches export script

-- The 8 glyph character codes exported by export_glyphs.py (A=65 … H=72)
local EXPORTED_GLYPH_CODES = { 65, 66, 67, 68, 69, 70, 71, 72 }

local RING_MATS         = nil   -- keyed by RING_TYPES value; nil until first Draw
local PATTERN_LINE_MATS = nil   -- array of 3 PATTERN_LINES variant materials
local BAND_MATS         = nil   -- array of 3 BAND_RING variant materials
local GLYPH_MATS        = {}    -- keyed by char code 65-72

local function initRingMaterials()
	PATTERN_LINE_MATS = {
		CreateCircleMaterial("arcana_ring_pattern_1", "arcana/rings/ring_pattern_lines"),
		CreateCircleMaterial("arcana_ring_pattern_2", "arcana/rings/ring_pattern_lines_2"),
		CreateCircleMaterial("arcana_ring_pattern_3", "arcana/rings/ring_pattern_lines_3"),
	}

	BAND_MATS = {
		CreateCircleMaterial("arcana_ring_band_1", "arcana/rings/ring_band"),
		CreateCircleMaterial("arcana_ring_band_2", "arcana/rings/ring_band_2"),
		CreateCircleMaterial("arcana_ring_band_3", "arcana/rings/ring_band_3"),
	}

	RING_MATS = {
		[RING_TYPES.SIMPLE_LINE]   = CreateCircleMaterial("arcana_ring_simple",    "arcana/rings/ring_simple_line"),
		[RING_TYPES.PATTERN_LINES] = PATTERN_LINE_MATS[1],   -- overridden per-ring via ring.patternVariant
		[RING_TYPES.RUNE_STAR]     = CreateCircleMaterial("arcana_ring_rune_star", "arcana/rings/ring_rune_star"),
		[RING_TYPES.STAR_RING]     = CreateCircleMaterial("arcana_ring_star",      "arcana/rings/ring_star_ring"),
	}

	for i = 65, 72 do
		GLYPH_MATS[i] = CreateCircleMaterial("arcana_ring_glyph_" .. i, "arcana/glyphs/glyph_" .. i)
	end

	Arcana.RunHook("CircleMaterialsLoaded", SHADER_AVAILABLE)
end

local function beginMaterialInit()
	WaitForShaderMounted({"arcana_circle_ps30", "arcana_passthrough_vs30"}, function(available)
		SHADER_AVAILABLE = available
		timer.Simple(1, initRingMaterials)
	end)
end

hook.Add("Initialize", "MagicCircle_Initialize", beginMaterialInit)

-- Hot reload: re-running this file resets the material tables above to nil, but
-- Initialize has already fired and will not fire again, so every draw path would
-- hit its `if not RING_MATS` guard and the rings would silently stay gone until
-- the next map change. Arcana.Circle.Ring is still set from the previous run at
-- this point (it is assigned at the bottom of the file), which is what tells a
-- reload apart from a cold start.
if Arcana.Circle.Ring then
	beginMaterialInit()
end

-- ── Shared mesh cache for cylindrical band geometry ───────────────────────────
local BAND_MESH_CACHE = {}

-- ── Ring class ────────────────────────────────────────────────────────────────

function Ring.new(ringType, radius, height, rotationSpeed, rotationDirection)
	local ring = setmetatable({}, Ring)
	ring.type             = ringType or RING_TYPES.SIMPLE_LINE
	ring.radius           = radius or 50
	ring.height           = height or 0
	ring.rotationSpeed    = rotationSpeed or (math_random() * 2 - 1) * 45
	ring.rotationDirection = rotationDirection or (math_random() > 0.5 and 1 or -1)
	ring.currentRotation  = math_random() * 360
	ring.segments         = 64
	ring.opacity          = 1.0
	ring.lineWidth        = 2.0
	ring.removed          = false

	if ring.type == RING_TYPES.PATTERN_LINES then
		-- Pick one of the 3 exported phrase variants at random; stored so DrawTexturedQuad
		-- can look up the correct material (PATTERN_LINE_MATS is indexed 1-3).
		ring.patternVariant = math_random(3)
	end

	if ring.type == RING_TYPES.BAND_RING then
		-- Band-specific state
		ring.bandMeshBuilt = false
		ring.bandHeight    = 1
		ring.bandVariant   = math_random(3)
		-- Scaling animation
		ring.currentScale  = 1
		ring.scaleFrom     = 1
		ring.scaleTarget   = 1
		ring.scaleStart    = 0
		ring.scaleDuration = 0
	else
		-- Breakdown / ejection animation state (non-band rings)
		ring.breaking          = false
		ring.breakStart        = 0
		ring.breakDuration     = 0
		ring.breakOffset       = Vector(0, 0, 0)
		ring.breakVelocity     = Vector(0, 0, 0)
		ring.breakSpinBoost    = 0
		ring.breakDelay        = 0
		ring.ejectStarted      = false
		ring.ejectDirXY        = Vector(1, 0, 0)
		ring.breakRemoveDistance = 0
		ring.ejectSoundPlayed  = false

		if ring.type == RING_TYPES.RUNE_STAR then
			-- Pick 4 random glyphs from the 8 exported glyphs (char codes A-H)
			ring.runes = {}
			for i = 1, 4 do
				ring.runes[i] = EXPORTED_GLYPH_CODES[math_random(#EXPORTED_GLYPH_CODES)]
			end
		end
	end

	return ring
end

function Ring:Update(deltaTime)
	-- Update rotation
	self.currentRotation = self.currentRotation + (self.rotationSpeed * self.rotationDirection * deltaTime)
	self.currentRotation = self.currentRotation % 360

	-- Optional per-axis spinning (band rings)
	if self.axisSpin then
		self.axisAngles = self.axisAngles or Angle(0, 0, 0)
		self.axisAngles.p = (self.axisAngles.p + (self.axisSpin.p or 0) * deltaTime) % 360
		self.axisAngles.y = (self.axisAngles.y + (self.axisSpin.y or 0) * deltaTime) % 360
		self.axisAngles.r = (self.axisAngles.r + (self.axisSpin.r or 0) * deltaTime) % 360
	end

	-- Scaling animation (band rings)
	if self.scaleDuration and self.scaleDuration > 0 then
		local elapsed = CurTime() - (self.scaleStart or 0)
		local t = math_min(1, math_max(0, elapsed / math_max(0.000001, self.scaleDuration)))
		local from = self.scaleFrom or 1
		local to   = self.scaleTarget or 1
		self.currentScale = from + (to - from) * t

		if t >= 1 then
			self.scaleDuration = 0
			self.currentScale  = to
		end
	end

	-- Breakdown motion (non-band rings)
	if self.breaking and not self.removed then
		local tNow = CurTime()

		if not self.ejectStarted then
			if (tNow - (self.breakStart or 0)) >= (self.breakDelay or 0) then
				self.ejectStarted = true

				if not self.ejectSoundPlayed then
					local pitch = 115 + math_random(-8, 12)
					sound.Play(MAGIC_EJECT_SOUNDS[math_random(1, #MAGIC_EJECT_SOUNDS)], self._lastDrawCenter or VECTOR_ZERO, 70, pitch, 0.6)
					self.ejectSoundPlayed = true
				end
			end

			return
		end

		local accel = 320 + math_random() * 240
		local dir   = self.ejectDirXY or VECTOR_X1
		local len   = math.sqrt(dir.x * dir.x + dir.y * dir.y)

		if len > 0 then
			dir = Vector(dir.x / len, dir.y / len, 0)
		else
			dir = VECTOR_X1
		end

		self.breakVelocity.x = (self.breakVelocity.x or 0) + dir.x * accel * deltaTime
		self.breakVelocity.y = (self.breakVelocity.y or 0) + dir.y * accel * deltaTime
		self.breakVelocity.z = (self.breakVelocity.z or 0) + (math_random() * 18 - 9) * deltaTime
		self.breakOffset.x   = (self.breakOffset.x or 0) + (self.breakVelocity.x or 0) * deltaTime
		self.breakOffset.y   = (self.breakOffset.y or 0) + (self.breakVelocity.y or 0) * deltaTime
		self.breakOffset.z   = (self.breakOffset.z or 0) + (self.breakVelocity.z or 0) * deltaTime
		self.currentRotation = self.currentRotation + self.breakSpinBoost * deltaTime

		local dist2     = (self.breakOffset.x or 0) ^ 2 + (self.breakOffset.y or 0) ^ 2 + (self.breakOffset.z or 0) ^ 2
		local threshold = self.breakRemoveDistance or (self.radius * 3)

		if dist2 >= threshold * threshold then
			self.removed = true
		end
	end
end

function Ring:Draw(centerPos, angles, color, time)
	local ringPos = centerPos + angles:Up() * self.height
	self._lastDrawCenter = centerPos

	if self.breaking and not self.removed and self.type ~= RING_TYPES.BAND_RING then
		local off     = self.breakOffset or VECTOR_ZERO
		local oriented = Angle(angles.p, angles.y, angles.r)
		local f = oriented:Forward()
		local r = oriented:Right()
		local u = oriented:Up()
		ringPos = ringPos + f * (off.x or 0) + r * (off.y or 0) + u * (off.z or 0)
	end

	if self.type == RING_TYPES.PATTERN_LINES or self.type == RING_TYPES.RUNE_STAR
	or self.type == RING_TYPES.SIMPLE_LINE   or self.type == RING_TYPES.STAR_RING then
		self:DrawTexturedQuad(ringPos, angles, color, self.currentRotation)
	elseif self.type == RING_TYPES.BAND_RING then
		local oriented = Angle(angles.p, angles.y, angles.r)

		if self.axisAngles then
			oriented:RotateAroundAxis(oriented:Right(),   self.axisAngles.p or 0)
			oriented:RotateAroundAxis(oriented:Up(),      self.axisAngles.y or 0)
			oriented:RotateAroundAxis(oriented:Forward(), self.axisAngles.r or 0)
		end

		if not self.bandMesh then
			self:BuildBandMesh()
		end

		if self.bandMesh and self.bandMat then
			self:DrawBandMesh(ringPos, oriented, color, self.currentRotation)
		end
	end
end

-- Draw the ring as a 3D2D quad using the pre-baked ring material.
-- pxToWorld = radius / RING_RADIUS_PX ensures the ring circle in the 2048 texture
-- lands exactly at self.radius world units from the centre.
function Ring:DrawTexturedQuad(centerPos, angles, color, rotationAngle)
	if not RING_MATS then return false end

	local ringMat
	if self.type == RING_TYPES.PATTERN_LINES and self.patternVariant then
		ringMat = PATTERN_LINE_MATS[self.patternVariant]
	else
		ringMat = RING_MATS[self.type]
	end
	if not ringMat then return false end

	-- Update custom shader colour parameters when available
	if ringMat.SetFloat then
		ringMat:SetFloat("$c0_x", CurTime())
		ringMat:SetFloat("$c0_y", (color.a or 255) / 255)
		ringMat:SetFloat("$c1_x", color.r / 255)
		ringMat:SetFloat("$c1_y", color.g / 255)
		ringMat:SetFloat("$c1_z", color.b / 255)
	end

	local pxToWorld  = self.radius / RING_RADIUS_PX
	local drawAngles = Angle(angles.p + 180, angles.y, angles.r)

	cam_Start3D2D(centerPos, drawAngles, pxToWorld)

	if self.type == RING_TYPES.RUNE_STAR and self.runes then
		-- Base ring, rotated the same way as every other flat type.
		-- cam.PushModelMatrix has no effect on surface.* inside cam.Start3D2D,
		-- so rotation is handled through DrawTexturedRectRotated + manual position math.
		surface_SetMaterial(ringMat)
		if SHADER_AVAILABLE then
			surface_SetDrawColor(255, 255, 255, color.a)
		else
			surface_SetDrawColor(color.r, color.g, color.b, color.a)
		end
		surface_DrawTexturedRectRotated(0, 0, RING_TEXTURE_SIZE, RING_TEXTURE_SIZE, rotationAngle or 0)

		-- Glyph textures overlaid at the four sub-circle positions, co-rotated with the ring.
		-- The sub-circles sit at 45°/135°/225°/315° on RING_RADIUS_PX.
		local glyphDraw = RING_RADIUS_PX * 0.35
		-- DrawTexturedRectRotated rotates counterclockwise for positive angles (screen space),
		-- while cos/sin in Y-down traces clockwise: negate to keep glyphs locked to the texture's sub-circles.
		local rot = -math.rad(rotationAngle or 0)
		for i = 1, 4 do
			local a  = (i - 1) * math_pi * 0.5 + math_pi * 0.25 + rot
			local gx = math_cos(a) * RING_RADIUS_PX
			local gy = math_sin(a) * RING_RADIUS_PX
			local gm = GLYPH_MATS[self.runes[i]]

			if gm then
				-- Drive the same shader parameters as the ring material so the
				-- custom shader outputs the correct colour (not the time=0 default).
				if gm.SetFloat then
					gm:SetFloat("$c0_x", CurTime())
					gm:SetFloat("$c0_y", (color.a or 255) / 255)
					gm:SetFloat("$c1_x", color.r / 255)
					gm:SetFloat("$c1_y", color.g / 255)
					gm:SetFloat("$c1_z", color.b / 255)
				end
				surface_SetMaterial(gm)
				if SHADER_AVAILABLE then
					surface_SetDrawColor(255, 255, 255, color.a)
				else
					surface_SetDrawColor(color.r, color.g, color.b, color.a)
				end
				surface_DrawTexturedRect(gx - glyphDraw * 0.5, gy - glyphDraw * 0.5, glyphDraw, glyphDraw)
			end
		end
	else
		-- All other types: simple centred quad with direct rotation.
		surface_SetMaterial(ringMat)
		if SHADER_AVAILABLE then
			surface_SetDrawColor(255, 255, 255, color.a)
		else
			surface_SetDrawColor(color.r, color.g, color.b, color.a)
		end
		surface_DrawTexturedRectRotated(0, 0, RING_TEXTURE_SIZE, RING_TEXTURE_SIZE, rotationAngle or 0)
	end

	cam_End3D2D()
	return true
end

-- Build the cylindrical mesh for a band ring and bind the band material.
-- The mesh is shared across all bands with the same radius/height/segment bucket.
function Ring:BuildBandMesh()
	if not BAND_MATS then return false end

	self.bandMat = BAND_MATS[self.bandVariant or 1]

	local height      = math_max(1, self.bandHeight or (self.radius * 0.15))
	-- Round to nearest int / nearest 0.25 for cache key stability
	local radiusBucket = math_floor((self.radius or 1) + 0.5)
	local heightBucket = math_floor(height / 0.25 + 0.5) * 0.25
	local segments     = math_max(24, math_min(128, self.segments or 64))
	local meshKey      = string.format("r%d_h%.2f_s%d", radiusBucket, heightBucket, segments)
	local meshEntry    = BAND_MESH_CACHE[meshKey]

	if not meshEntry then
		local vertices = {}
		local radius   = math_max(1, radiusBucket)
		local halfH    = heightBucket * 0.5

		for i = 0, segments do
			local t   = i / segments
			local ang = t * math_pi * 2
			local cx  = math_cos(ang) * radius
			local cy  = math_sin(ang) * radius
			local nrm = Vector(cx, cy, 0):GetNormalized()

			table_insert(vertices, { pos = Vector(cx, cy, -halfH), u = t, v = 1, normal = nrm })
			table_insert(vertices, { pos = Vector(cx, cy,  halfH), u = t, v = 0, normal = nrm })
		end

		local meshBuilder = Mesh()
		meshBuilder:BuildFromTriangles((function()
			local tris = {}

			for i = 0, segments - 1 do
				local i0 = i * 2 + 1
				local i1 = i0 + 1
				local i2 = i0 + 2
				local i3 = i0 + 3

				table_insert(tris, { pos = vertices[i0].pos, u = vertices[i0].u, v = vertices[i0].v, normal = vertices[i0].normal })
				table_insert(tris, { pos = vertices[i2].pos, u = vertices[i2].u, v = vertices[i2].v, normal = vertices[i2].normal })
				table_insert(tris, { pos = vertices[i1].pos, u = vertices[i1].u, v = vertices[i1].v, normal = vertices[i1].normal })
				table_insert(tris, { pos = vertices[i2].pos, u = vertices[i2].u, v = vertices[i2].v, normal = vertices[i2].normal })
				table_insert(tris, { pos = vertices[i3].pos, u = vertices[i3].u, v = vertices[i3].v, normal = vertices[i3].normal })
				table_insert(tris, { pos = vertices[i1].pos, u = vertices[i1].u, v = vertices[i1].v, normal = vertices[i1].normal })
			end

			return tris
		end)())

		meshEntry = meshBuilder
		BAND_MESH_CACHE[meshKey] = meshEntry
	end

	self.bandMesh = meshEntry
end

function Ring:DrawBandMesh(centerPos, angles, color, rotationAngle)
	if not (self.bandMesh and self.bandMat) then return end

	local oriented = Angle(angles.p, angles.y, angles.r)
	oriented:RotateAroundAxis(oriented:Up(), rotationAngle or 0)

	local m = Matrix()
	m:SetAngles(oriented)
	local s = self.currentScale or 1
	m:Scale(Vector(s, s, s))
	local bias = self.zBias or 0
	m:SetTranslation(centerPos + oriented:Up() * bias)
	cam_PushModelMatrix(m)

	if self.bandMat.SetVector then
		self.bandMat:SetVector("$color", Vector((color.r or 255) / 255, (color.g or 255) / 255, (color.b or 255) / 255))
	end

	if self.bandMat.SetFloat then
		self.bandMat:SetFloat("$alpha", (color.a or 255) / 255)
		self.bandMat:SetFloat("$c0_x", CurTime())
		self.bandMat:SetFloat("$c0_y", (color.a or 255) / 255)
		self.bandMat:SetFloat("$c1_x", color.r / 255)
		self.bandMat:SetFloat("$c1_y", color.g / 255)
		self.bandMat:SetFloat("$c1_z", color.b / 255)
	end

	render_SetMaterial(self.bandMat)
	if SHADER_AVAILABLE then
		render_SetColorModulation(1, 1, 1)
	else
		render_SetColorModulation(color.r / 255, color.g / 255, color.b / 255)
	end
	render_SetBlend((color.a or 255) / 255)
	render_SetLightingMode(1)
	-- Depth behavior comes from the material itself ($depthtest 1/$writedepth 0
	-- on the custom shader, standard translucent shadow state on the fallback):
	-- z-test against the scene, no depth writes. See CreateCircleMaterial.
	self.bandMesh:Draw()
	render_SetLightingMode(0)
	render_SetColorModulation(1, 1, 1)
	render_SetBlend(1)
	cam_PopModelMatrix()
end

-- ── 2D surface drawing API ────────────────────────────────────────────────────
-- Draw ring textures inside Paint hooks / vgui without exposing internal material tables.

local RING_2D_SCALE  -- RING_TEXTURE_SIZE / RING_RADIUS_PX, set on first draw call.

-- Sets material + draw colour, handling both the custom shader and fallback paths.
local function apply2DColor(mat, color, alpha)
	local r = color and color.r or 255
	local g = color and color.g or 255
	local b = color and color.b or 255
	local a = alpha or (color and color.a) or 255
	if mat.SetFloat then
		mat:SetFloat("$c0_x", CurTime())
		-- Materials are shared with the 3D ring renderer, which writes its fade
		-- alpha into $c0_y (see Ring draw). Reset it here or UI circles inherit
		-- whatever alpha the last fading world circle left behind.
		mat:SetFloat("$c0_y", a / 255)
		mat:SetFloat("$c1_x", r / 255)
		mat:SetFloat("$c1_y", g / 255)
		mat:SetFloat("$c1_z", b / 255)
	end
	surface_SetMaterial(mat)
	if SHADER_AVAILABLE then
		surface_SetDrawColor(255, 255, 255, a)
	else
		surface_SetDrawColor(r, g, b, a)
	end
end

-- Draws a ring (by RING_TYPES value) centred at (cx, cy) in screen space.
function Arcana.Circle.Draw2DRing(ringType, cx, cy, radius, angle, color, alpha)
	if not RING_MATS then return end

	local mat = RING_MATS[ringType]
	if not mat then return end
	RING_2D_SCALE = RING_2D_SCALE or (RING_TEXTURE_SIZE / RING_RADIUS_PX)
	apply2DColor(mat, color, alpha)
	local s = radius * RING_2D_SCALE
	surface_DrawTexturedRectRotated(cx, cy, s, s, angle or 0)
end

-- Draws a pattern-lines ring (variant 1-3) centred at (cx, cy) in screen space.
function Arcana.Circle.Draw2DPatternRing(variant, cx, cy, radius, angle, color, alpha)
	if not RING_MATS then return end

	local mat = PATTERN_LINE_MATS[variant or 1]
	if not mat then return end
	RING_2D_SCALE = RING_2D_SCALE or (RING_TEXTURE_SIZE / RING_RADIUS_PX)
	apply2DColor(mat, color, alpha)
	local s = radius * RING_2D_SCALE
	surface_DrawTexturedRectRotated(cx, cy, s, s, angle or 0)
end

-- Draws a RUNE_STAR ring with four co-rotating glyph overlays in screen space.
-- glyphs: array of 4 char codes from EXPORTED_GLYPH_CODES (65-72 = 'A', 'H').
function Arcana.Circle.Draw2DRuneStar(cx, cy, radius, angle, glyphs, color, alpha)
	if not RING_MATS then return end

	local mat = RING_MATS[RING_TYPES.RUNE_STAR]
	if not mat then return end

	RING_2D_SCALE = RING_2D_SCALE or (RING_TEXTURE_SIZE / RING_RADIUS_PX)
	local s = radius * RING_2D_SCALE

	apply2DColor(mat, color, alpha)
	surface_DrawTexturedRectRotated(cx, cy, s, s, angle or 0)

	if not glyphs then return end

	local glyphSize = radius * 0.35
	local rot = -math_pi / 180 * (angle or 0)
	for i = 1, 4 do
		local a  = (i - 1) * math_pi * 0.5 + math_pi * 0.25 + rot
		local gm = GLYPH_MATS[glyphs[i]]
		if gm then
			apply2DColor(gm, color, alpha)
			surface_DrawTexturedRect(
				cx + math_cos(a) * radius - glyphSize * 0.5,
				cy + math_sin(a) * radius - glyphSize * 0.5,
				glyphSize, glyphSize)
		end
	end
end

-- Export
Arcana.Circle.Ring       = Ring
Arcana.Circle.RING_TYPES = RING_TYPES