-- Arcana Ring primitive renderer.
-- Provides the Ring class used by MagicCircle and BandCircle for all low-level
-- PNG-based ring and glyph rendering. Exports: Arcana.Circle.Ring, Arcana.Circle.RING_TYPES

Arcana = Arcana or {}
Arcana.Circle = Arcana.Circle or {}

local render_SetMaterial = _G.render.SetMaterial
local render_SetColorModulation = _G.render.SetColorModulation
local render_SetBlend = _G.render.SetBlend
local render_SetLightingMode = _G.render.SetLightingMode
local render_OverrideDepthEnable = _G.render.OverrideDepthEnable
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
local Color = _G.Color

local COLOR_WHITE = Color(255, 255, 255, 255)
local VECTOR_ZERO = Vector(0, 0, 0)
local VECTOR_X1   = Vector(1, 0, 0)
local ANGLE_ZERO  = Angle(0, 0, 0)

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

local shader_available = false
if system.IsWindows() then -- dont load shader on non-windows platforms because it causes weirdness
	shader_available = file.Exists("shaders/fxc/arcana_circle_ps30.vcs", "GAME")
	hook.Add("ShaderMounted", "MagicCircle_ShaderMounted", function()
		shader_available = true
	end)
end

local loadedTextures = {}

-- Helper: create a circle material wrapping a texture (custom shader when available)
local function CreateCircleMaterial(name, textureName)
	local baseTexture
	if not loadedTextures[textureName] then
		loadedTextures[textureName] = Material(textureName, "noclamp smooth"):GetName()
		baseTexture = loadedTextures[textureName]
	else
		baseTexture = loadedTextures[textureName]
	end

	if not shader_available then
		return CreateMaterial(name, textureName:match("band") and "VertexLitGeneric" or "UnlitGeneric", {
			["$basetexture"] = baseTexture,
			["$translucent"] = 1,
			["$vertexalpha"] = 1,
			["$vertexcolor"] = 1,
			["$nolod"]       = 1,
			["$nocull"]      = 1,
			["$additive"]    = 0,
		})
	end

	return CreateShaderMaterial(name, {
		["$pixshader"]   = "arcana_circle_ps30",
		["$vertexshader"] = "arcana_circle_vs30",
		["$basetexture"] = baseTexture,
		["$translucent"] = 1,
		["$vertexalpha"] = 1,
		["$vertexcolor"] = 1,
		["$nolod"]       = 1,
		["$nocull"]      = 1,
		["$additive"]    = 0,
		["$ignorez"]     = 0,
		["$c0_x"]        = 0.0,
		["$c1_x"]        = 1.0,
		["$c1_y"]        = 1.0,
		["$c1_z"]        = 1.0,
	})
end

-- ── PNG material system ───────────────────────────────────────────────────────
-- Ring PNGs are 4096×4096; the ring circle sits at 47% from the canvas centre.
local PNG_RING_SIZE      = 4096
local PNG_RING_HALF      = PNG_RING_SIZE * 0.5
local PNG_RING_RADIUS_PX = math_floor(PNG_RING_SIZE * 0.47)   -- 1925 px, matches export script

-- The 8 glyph character codes exported by export_glyphs.py (A=65 … H=72)
local EXPORTED_GLYPH_CODES = { 65, 66, 67, 68, 69, 70, 71, 72 }

local PNG_RING_MATS         = nil   -- keyed by RING_TYPES value; nil until first Draw
local PNG_PATTERN_LINE_MATS = nil   -- array of 3 PATTERN_LINES variant materials
local PNG_BAND_MATS         = nil   -- array of 3 BAND_RING variant materials
local PNG_GLYPH_MATS        = {}    -- keyed by char code 65-72

local function ensurePNGMatsLoaded()
	if PNG_RING_MATS then return end

	PNG_PATTERN_LINE_MATS = {
		CreateCircleMaterial("arcana_png_pattern_1", "arcana/rings/ring_pattern_lines.png"),
		CreateCircleMaterial("arcana_png_pattern_2", "arcana/rings/ring_pattern_lines_2.png"),
		CreateCircleMaterial("arcana_png_pattern_3", "arcana/rings/ring_pattern_lines_3.png"),
	}

	PNG_BAND_MATS = {
		CreateCircleMaterial("arcana_png_band_1", "arcana/rings/ring_band.png"),
		CreateCircleMaterial("arcana_png_band_2", "arcana/rings/ring_band_2.png"),
		CreateCircleMaterial("arcana_png_band_3", "arcana/rings/ring_band_3.png"),
	}

	PNG_RING_MATS = {
		[RING_TYPES.SIMPLE_LINE]   = CreateCircleMaterial("arcana_png_simple",    "arcana/rings/ring_simple_line.png"),
		[RING_TYPES.PATTERN_LINES] = PNG_PATTERN_LINE_MATS[1],   -- overridden per-ring via ring.patternVariant
		[RING_TYPES.RUNE_STAR]     = CreateCircleMaterial("arcana_png_rune_star", "arcana/rings/ring_rune_star.png"),
		[RING_TYPES.STAR_RING]     = CreateCircleMaterial("arcana_png_star",      "arcana/rings/ring_star_ring.png"),
	}

	for i = 65, 72 do
		PNG_GLYPH_MATS[i] = CreateCircleMaterial("arcana_png_glyph_" .. i, "arcana/glyphs/glyph_" .. i .. ".png")
	end
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
		-- Pick one of the 3 exported phrase variants at random; stored so DrawPNGQuad
		-- can look up the correct material (PNG_PATTERN_LINE_MATS is indexed 1-3).
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
			-- Pick 4 random glyphs from the 8 exported PNG glyphs (char codes A-H)
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
		self:DrawPNGQuad(ringPos, angles, color, self.currentRotation)
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

-- Draw the ring as a 3D2D quad using the pre-baked PNG material.
-- pxToWorld = radius / PNG_RING_RADIUS_PX ensures the ring circle in the 4096 PNG
-- lands exactly at self.radius world units from the centre.
function Ring:DrawPNGQuad(centerPos, angles, color, rotationAngle)
	ensurePNGMatsLoaded()

	local pngMat
	if self.type == RING_TYPES.PATTERN_LINES and self.patternVariant then
		pngMat = PNG_PATTERN_LINE_MATS[self.patternVariant]
	else
		pngMat = PNG_RING_MATS[self.type]
	end
	if not pngMat then return false end

	-- Update custom shader colour parameters when available
	if pngMat.SetFloat then
		pngMat:SetFloat("$c0_x", CurTime())
		pngMat:SetFloat("$c1_x", color.r / 255)
		pngMat:SetFloat("$c1_y", color.g / 255)
		pngMat:SetFloat("$c1_z", color.b / 255)
	end

	local pxToWorld  = self.radius / PNG_RING_RADIUS_PX
	local drawAngles = Angle(angles.p + 180, angles.y, angles.r)

	cam_Start3D2D(centerPos, drawAngles, pxToWorld)

	if self.type == RING_TYPES.RUNE_STAR and self.runes then
		-- Base ring, rotated the same way as every other flat type.
		-- cam.PushModelMatrix has no effect on surface.* inside cam.Start3D2D,
		-- so rotation is handled through DrawTexturedRectRotated + manual position math.
		surface_SetMaterial(pngMat)
		surface_SetDrawColor(255, 255, 255, color.a)
		surface_DrawTexturedRectRotated(0, 0, PNG_RING_SIZE, PNG_RING_SIZE, rotationAngle or 0)

		-- Glyph PNGs overlaid at the four sub-circle positions, co-rotated with the ring.
		-- The sub-circles sit at 45°/135°/225°/315° on PNG_RING_RADIUS_PX.
		local glyphDraw = PNG_RING_RADIUS_PX * 0.35
		-- DrawTexturedRectRotated rotates counterclockwise for positive angles (screen space),
		-- while cos/sin in Y-down traces clockwise — negate to keep glyphs locked to the PNG sub-circles.
		local rot = -math.rad(rotationAngle or 0)
		for i = 1, 4 do
			local a  = (i - 1) * math_pi * 0.5 + math_pi * 0.25 + rot
			local gx = math_cos(a) * PNG_RING_RADIUS_PX
			local gy = math_sin(a) * PNG_RING_RADIUS_PX
			local gm = PNG_GLYPH_MATS[self.runes[i]]

			if gm then
				-- Drive the same shader parameters as the ring material so the
				-- custom shader outputs the correct colour (not the time=0 default).
				if gm.SetFloat then
					gm:SetFloat("$c0_x", CurTime())
					gm:SetFloat("$c1_x", color.r / 255)
					gm:SetFloat("$c1_y", color.g / 255)
					gm:SetFloat("$c1_z", color.b / 255)
				end
				surface_SetMaterial(gm)
				surface_SetDrawColor(255, 255, 255, color.a)
				surface_DrawTexturedRect(gx - glyphDraw * 0.5, gy - glyphDraw * 0.5, glyphDraw, glyphDraw)
			end
		end
	else
		-- All other types: simple centred quad with direct rotation.
		surface_SetMaterial(pngMat)
		surface_SetDrawColor(255, 255, 255, color.a)
		surface_DrawTexturedRectRotated(0, 0, PNG_RING_SIZE, PNG_RING_SIZE, rotationAngle or 0)
	end

	cam_End3D2D()
	return true
end

-- Build the cylindrical mesh for a band ring and bind the PNG band material.
-- The mesh is shared across all bands with the same radius/height/segment bucket.
function Ring:BuildBandMesh()
	ensurePNGMatsLoaded()

	self.bandMat = PNG_BAND_MATS[self.bandVariant or 1]

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

	self.bandMesh    = meshEntry
	self.bandRTBuilt = true   -- kept for legacy flag checks in BandCircle
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
		self.bandMat:SetFloat("$c1_x", color.r / 255)
		self.bandMat:SetFloat("$c1_y", color.g / 255)
		self.bandMat:SetFloat("$c1_z", color.b / 255)
	end

	render_SetMaterial(self.bandMat)
	render_SetColorModulation(color.r / 255 * 3, color.g / 255 * 3, color.b / 255 * 3)
	render_SetBlend((color.a or 255) / 255)
	render_SetLightingMode(2)
	render_OverrideDepthEnable(true, true)
	self.bandMesh:Draw()
	render_OverrideDepthEnable(false, false)
	render_SetLightingMode(0)
	render_SetColorModulation(1, 1, 1)
	render_SetBlend(1)
	cam_PopModelMatrix()
end

-- Export
Arcana.Circle.Ring       = Ring
Arcana.Circle.RING_TYPES = RING_TYPES
