-- Arcana Ring primitive renderer.
-- Provides the Ring class used by MagicCircle and BandCircle for all low-level
-- glyph/RT/mesh rendering. Exports: Arcana.Circle.Ring, Arcana.Circle.RING_TYPES

Arcana = Arcana or {}
Arcana.Circle = Arcana.Circle or {}

local render_SetMaterial = _G.render.SetMaterial
local render_PushRenderTarget = _G.render.PushRenderTarget
local render_PopRenderTarget = _G.render.PopRenderTarget
local render_Clear = _G.render.Clear
local render_SetColorModulation = _G.render.SetColorModulation
local render_SetBlend = _G.render.SetBlend
local render_SetLightingMode = _G.render.SetLightingMode
local render_OverrideDepthEnable = _G.render.OverrideDepthEnable
local GetRenderTarget = _G.GetRenderTarget
local CreateMaterial = _G.CreateMaterial
local cam_Start3D2D = _G.cam.Start3D2D
local cam_End3D2D = _G.cam.End3D2D
local cam_Start2D = _G.cam.Start2D
local cam_End2D = _G.cam.End2D
local cam_PushModelMatrix = _G.cam.PushModelMatrix
local cam_PopModelMatrix = _G.cam.PopModelMatrix
local surface_SetFont = _G.surface.SetFont
local surface_SetTextColor = _G.surface.SetTextColor
local surface_GetTextSize = _G.surface.GetTextSize
local surface_SetTextPos = _G.surface.SetTextPos
local surface_DrawText = _G.surface.DrawText
local surface_SetMaterial = _G.surface.SetMaterial
local surface_DrawTexturedRect = _G.surface.DrawTexturedRect
local surface_DrawRect = _G.surface.DrawRect
local surface_SetDrawColor = _G.surface.SetDrawColor
local surface_DrawTexturedRectRotated = _G.surface.DrawTexturedRectRotated
local surface_DrawLine = _G.surface.DrawLine
local surface_DrawCircle = _G.surface.DrawCircle
local util_CRC = _G.util and _G.util.CRC
local Matrix = _G.Matrix
local Mesh = _G.Mesh
local math_random = _G.math.random
local math_pi = _G.math.pi
local math_sin = _G.math.sin
local math_cos = _G.math.cos
local math_deg = _G.math.deg
local math_floor = _G.math.floor
local math_max = _G.math.max
local math_min = _G.math.min
local table_insert = _G.table.insert
local table_remove = _G.table.remove
local table_sort = _G.table.sort
local utf8_len = _G.utf8.len
local utf8_codes = _G.utf8.codes
local utf8_char = _G.utf8.char
local Angle = _G.Angle
local Vector = _G.Vector
local Color = _G.Color

local COLOR_WHITE = Color(255, 255, 255, 255)
local VECTOR_ZERO = Vector(0, 0, 0)
local VECTOR_X1 = Vector(1, 0, 0)
local ANGLE_ZERO = Angle(0, 0, 0)

local RT_BUILD_PASSES = 4

local Ring = {}
Ring.__index = Ring

-- Runic symbols for type 2 rings
local RUNIC_GLYPHS = {
	"A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T",
	"U", "V", "W", "X", "Y", "Z", "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n",
	"o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z"
}

-- Runic magical phrases and words for circular text
local RUNIC_PHRASES = {
	"ABRAXAS ABRAXAS ABRAXAS ABRAXAS ABRAXAS ABRAXAS ABRAXAS ABRAXAS",
	"HOLY HOLY HOLY MIGHTY MIGHTY MIGHTY IMMORTAL IMMORTAL IMMORTAL",
	"ALPHA OMEGA ALPHA OMEGA ALPHA OMEGA ALPHA OMEGA ALPHA OMEGA",
	"DIVINE LOVE WISDOM KNOWLEDGE DIVINE LOVE WISDOM KNOWLEDGE DIVINE",
	"COSMOS WORD SOUL SPIRIT COSMOS WORD SOUL SPIRIT COSMOS WORD SOUL",
	"LIGHT LIFE TRUTH LIGHT LIFE TRUTH LIGHT LIFE TRUTH LIGHT LIFE",
	"BEGINNING AND END BEGINNING AND END BEGINNING AND END BEGINNING",
	"HEAVEN EARTH SEA FIRE AIR HEAVEN EARTH SEA FIRE AIR HEAVEN EARTH"
}

-- Combined phrases array for random selection
local ALL_MYSTICAL_PHRASES = {}

for _, phrase in ipairs(RUNIC_PHRASES) do
	table_insert(ALL_MYSTICAL_PHRASES, phrase)
end

-- Ring type definitions
local RING_TYPES = {
	PATTERN_LINES = 1,
	RUNE_STAR = 2,
	SIMPLE_LINE = 3,
	STAR_RING = 4,
	BAND_RING = 5,
}

-- Utility functions
local function GetRandomRune()
	local allSymbols = {}

	for _, rune in ipairs(RUNIC_GLYPHS) do
		table_insert(allSymbols, rune)
	end

	return allSymbols[math_random(#allSymbols)]
end

-- Shared cache for ring render targets/materials to avoid per-instance VRAM growth
local RING_RT_CACHE = {}
local BAND_RT_CACHE = {}
local BAND_MESH_CACHE = {}

-- Default ring ejection sound candidates (short, energetic)
local MAGIC_EJECT_SOUNDS = {"ambient/energy/zap1.wav", "ambient/energy/zap2.wav", "ambient/energy/zap3.wav"}

local shader_available = file.Exists("shaders/fxc/arcana_circle_ps30.vcs", "GAME")
hook.Add("ShaderMounted", "MagicCircle_ShaderMounted", function()
	shader_available = true
end)

-- Helper function to create circle materials with custom shader
local function CreateCircleMaterial(name, textureName)
	if not shader_available then
		return CreateMaterial(name, "UnlitGeneric", {
			["$basetexture"] = textureName,
			["$translucent"] = 1,
			["$vertexalpha"] = 1,
			["$vertexcolor"] = 1,
			["$nolod"] = 1,
			["$nocull"] = 1,
			["$additive"] = 0,
		})
	end

	-- Use custom fullbright shader
	return CreateShaderMaterial(name, {
		["$pixshader"] = "arcana_circle_ps30",
		["$vertexshader"] = "arcana_circle_vs30",
		["$basetexture"] = textureName,
		["$translucent"] = 1,
		["$vertexalpha"] = 1,
		["$vertexcolor"] = 1,
		["$nolod"] = 1,
		["$nocull"] = 1,
		["$additive"] = 0,
		["$ignorez"] = 0,
		-- Time for animated noise (will be updated each frame)
		["$c0_x"] = 0.0,
		-- Color tint will be set dynamically per circle (RGB)
		["$c1_x"] = 1.0,
		["$c1_y"] = 1.0,
		["$c1_z"] = 1.0,
	})
end

-- Quantize a numeric value to limit the number of RT variants produced
local function quantize(value, step)
	step = step or 1

	return math_floor((value or 0) / step + 0.5) * step
end

-- Build a deterministic cache key for a ring RT based on the visual parameters
-- that affect the RT contents. The function returns (key, sizeBucket)
local function ringRTKey(r)
	local ringType = r.type or 0
	local radius = tonumber(r.radius or 128) or 128
	-- Derive intended RT size (as before), then bucket to reduce permutations
	local baseSize = math.Clamp(math_floor(radius * 2 * 10), 256, 4096)
	local sizeBucket = math.min(4096, math.max(256, quantize(baseSize, 64)))
	local radiusBucket = quantize(radius, 1)
	local lineWidthBucket = quantize(r.lineWidth or 2, 0.5)
	local fontName = r.textFont or "MagicCircle_Medium"
	local phrase = r.mysticalPhrase or ""
	local phraseId = (util_CRC and util_CRC(phrase)) or tostring(phrase)
	local inner = quantize(r.innerTextRadius or (radius - 5), 1)
	local outer = quantize(r.outerTextRadius or radius, 1)
	local key = string.format("t%d_s%d_r%d_lw%.1f_f%s_p%s_in%d_out%d", ringType, sizeBucket, radiusBucket, lineWidthBucket, fontName, tostring(phraseId), inner, outer)

	return key, sizeBucket, radiusBucket
end

-- Build a deterministic cache key for band rings' rectangular RT
-- Returns (key, wBucket, hBucket)
local function bandRTKey(r)
	local radius = math_max(1, r.radius or 64)
	local height = math_max(1, r.bandHeight or (radius * 0.15))
	local pxPerUnit = math_max(8, math_min(64, r.bandPxPerUnit or 32))
	local pxPerUnitBucket = quantize(pxPerUnit, 4)
	local circumference = 2 * math_pi * radius
	local texW = math_max(256, math_floor(circumference * pxPerUnitBucket))
	texW = math_min(texW, 4096)
	local wBucket = math_min(4096, math_max(256, quantize(texW, 128)))
	local texH = math_max(64, math_min(1024, math_floor(height * pxPerUnitBucket)))
	local hBucket = math_min(1024, math_max(64, quantize(texH, 16)))
	local fontName = r.textFont or "MagicCircle_Medium"
	local phrase = r.mysticalPhrase or ""
	local phraseId = (util_CRC and util_CRC(phrase)) or tostring(phrase)
	local key = string.format("w%d_h%d_px%d_f%s_p%s", wBucket, hBucket, pxPerUnitBucket, fontName, tostring(phraseId))

	return key, wBucket, hBucket
end

-- Ring class implementation
function Ring.new(ringType, radius, height, rotationSpeed, rotationDirection)
	local ring = setmetatable({}, Ring)
	ring.type = ringType or RING_TYPES.SIMPLE_LINE
	ring.radius = radius or 50
	ring.height = height or 0
	ring.rotationSpeed = rotationSpeed or (math_random() * 2 - 1) * 45
	ring.rotationDirection = rotationDirection or (math_random() > 0.5 and 1 or -1)
	ring.currentRotation = math_random() * 360
	ring.segments = 64
	ring.opacity = 1.0
	ring.lineWidth = 2.0
	ring.removed = false

	if ring.type == RING_TYPES.BAND_RING then
		ring.useRTCache = false
		-- Band-specific RT + mesh
		ring.bandRTBuilt = false
		ring.bandPxPerUnit = 32
		-- Scaling animation state
		ring.currentScale = 1
		ring.scaleFrom = 1
		ring.scaleTarget = 1
		ring.scaleStart = 0
		ring.scaleDuration = 0
		-- Band appearance
		ring.bandHeight = 1
		ring.mysticalPhrase = ALL_MYSTICAL_PHRASES[math_random(#ALL_MYSTICAL_PHRASES)]
		ring.textFont = "MagicCircle_Medium"
		ring.cachedTextData = ring:CacheTextProcessing()
	else
		-- Render target cache for non-band rings
		ring.useRTCache = true
		ring.rtBuilt = false
		-- Breakdown / ejection animation state
		ring.breaking = false
		ring.breakStart = 0
		ring.breakDuration = 0
		ring.breakOffset = Vector(0, 0, 0)
		ring.breakVelocity = Vector(0, 0, 0)
		ring.breakSpinBoost = 0
		ring.breakDelay = 0
		ring.ejectStarted = false
		ring.ejectDirXY = Vector(1, 0, 0)
		ring.breakRemoveDistance = 0
		ring.ejectSoundPlayed = false

		if ring.type == RING_TYPES.PATTERN_LINES then
			ring.mysticalPhrase = ALL_MYSTICAL_PHRASES[math_random(#ALL_MYSTICAL_PHRASES)]
			ring.outerTextRadius = ring.radius
			ring.innerTextRadius = ring.radius - math_max(5, ring.radius * 0.05)
			ring.textFont = "MagicCircle_Medium"
			ring.cachedTextData = ring:CacheTextProcessing()
		elseif ring.type == RING_TYPES.RUNE_STAR then
			ring.runes = {}
			for i = 1, 4 do
				ring.runes[i] = GetRandomRune()
			end
			ring.runeRadiusRatio = 0.15
			ring.starConnections = true
		elseif ring.type == RING_TYPES.STAR_RING then
			ring.starPoints = math_random(5, 8)
			ring.starType = math_random(1, 2)
			ring.innerRadius = ring.radius * (0.3 + math_random() * 0.3)
			ring.outerRadius = ring.radius
		end
	end

	return ring
end

-- Cache text processing to avoid repeated UTF-8 operations
function Ring:CacheTextProcessing()
	if not self.mysticalPhrase then return nil end
	local textLength = utf8_len(self.mysticalPhrase)
	if not textLength or textLength == 0 then return nil end
	-- Pre-process the mystical phrase into characters
	local chars = {}

	for pos, code in utf8_codes(self.mysticalPhrase) do
		table_insert(chars, utf8_char(code))
	end

	return {
		originalText = self.mysticalPhrase,
		originalLength = textLength,
		chars = chars,
		charCount = #chars
	}
end

function Ring:Update(deltaTime)
	-- Update rotation
	self.currentRotation = self.currentRotation + (self.rotationSpeed * self.rotationDirection * deltaTime)
	self.currentRotation = self.currentRotation % 360

	-- Optional per-axis spinning for band rings or specialty rings
	if self.axisSpin then
		self.axisAngles = self.axisAngles or Angle(0, 0, 0)
		self.axisAngles.p = (self.axisAngles.p + (self.axisSpin.p or 0) * deltaTime) % 360
		self.axisAngles.y = (self.axisAngles.y + (self.axisSpin.y or 0) * deltaTime) % 360
		self.axisAngles.r = (self.axisAngles.r + (self.axisSpin.r or 0) * deltaTime) % 360
	end

	-- Scaling animation (for band rings)
	if self.scaleDuration and self.scaleDuration > 0 then
		local elapsed = CurTime() - (self.scaleStart or 0)
		local t = math_min(1, math_max(0, elapsed / math_max(0.000001, self.scaleDuration)))
		local from = self.scaleFrom or 1
		local to = self.scaleTarget or 1
		self.currentScale = from + (to - from) * t

		if t >= 1 then
			self.scaleDuration = 0
			self.currentScale = to
		end
	end

	-- Breakdown motion (for non-band rings)
	if self.breaking and not self.removed then
		local tNow = CurTime()

		-- Wait for per-ring eject delay to spread out
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

		-- Stronger, directed acceleration outward
		local accel = 320 + math_random() * 240
		local dir = self.ejectDirXY or VECTOR_X1
		-- Normalize in-plane dir
		local len = math.sqrt(dir.x * dir.x + dir.y * dir.y)

		if len > 0 then
			dir = Vector(dir.x / len, dir.y / len, 0)
		else
			dir = VECTOR_X1
		end

		self.breakVelocity.x = (self.breakVelocity.x or 0) + dir.x * accel * deltaTime
		self.breakVelocity.y = (self.breakVelocity.y or 0) + dir.y * accel * deltaTime
		self.breakVelocity.z = (self.breakVelocity.z or 0) + (math_random() * 18 - 9) * deltaTime
		-- Integrate velocity
		self.breakOffset.x = (self.breakOffset.x or 0) + (self.breakVelocity.x or 0) * deltaTime
		self.breakOffset.y = (self.breakOffset.y or 0) + (self.breakVelocity.y or 0) * deltaTime
		self.breakOffset.z = (self.breakOffset.z or 0) + (self.breakVelocity.z or 0) * deltaTime
		-- add spin boost
		self.currentRotation = self.currentRotation + self.breakSpinBoost * deltaTime
		-- removal when far enough
		local dist2 = (self.breakOffset.x or 0) ^ 2 + (self.breakOffset.y or 0) ^ 2 + (self.breakOffset.z or 0) ^ 2
		local threshold = (self.breakRemoveDistance or (self.radius * 3))

		if dist2 >= (threshold * threshold) then
			self.removed = true
		end
	end
end

function Ring:Draw(centerPos, angles, color, time)
	local ringPos = centerPos + angles:Up() * self.height
	-- remember last center for delayed ejection sounds
	self._lastDrawCenter = centerPos

	-- Apply breakdown offset in local ring plane (non-band rings)
	if self.breaking and not self.removed and self.type ~= RING_TYPES.BAND_RING then
		local off = self.breakOffset or VECTOR_ZERO
		local oriented = Angle(angles.p, angles.y, angles.r)
		local f = oriented:Forward()
		local r = oriented:Right()
		local u = oriented:Up()
		ringPos = ringPos + f * (off.x or 0) + r * (off.y or 0) + u * (off.z or 0)
	end

	-- Pass the rotation angle directly to drawing functions instead of modifying angles
	if self.type == RING_TYPES.PATTERN_LINES or self.type == RING_TYPES.RUNE_STAR or self.type == RING_TYPES.SIMPLE_LINE or self.type == RING_TYPES.STAR_RING then
		-- Non-band rings use RT-only rendering now
		self:DrawCachedRTQuad(ringPos, angles, color, self.currentRotation)
	elseif self.type == RING_TYPES.BAND_RING then
		local oriented = Angle(angles.p, angles.y, angles.r)

		if self.axisAngles then
			oriented:RotateAroundAxis(oriented:Right(), self.axisAngles.p or 0)
			oriented:RotateAroundAxis(oriented:Up(), self.axisAngles.y or 0)
			oriented:RotateAroundAxis(oriented:Forward(), self.axisAngles.r or 0)
		end

		-- RT + mesh-only path
		if not self.bandRTBuilt then
			self:BuildBandRTAndMesh()
		end

		if self.bandRTBuilt and self.bandMat and self.bandMesh then
			self:DrawBandMesh(ringPos, oriented, color, self.currentRotation)
		end
	end
end

-- Create and fill an RT for this ring if needed, return true if RT-based draw succeeds
function Ring:DrawCachedRTQuad(centerPos, angles, color, rotationAngle)
	if not self.useRTCache then return false end

	if not self.rtBuilt then
		self:BuildRingRT()
	end

	if not self.rt or not self.rtMat then return false end

	-- Update shader color parameters if using custom shader
	if self.rtMat and self.rtMat.SetFloat then
		-- Set time for animated noise
		self.rtMat:SetFloat("$c0_x", CurTime())
		-- Set color tint (normalized 0-1)
		self.rtMat:SetFloat("$c1_x", color.r / 255)
		self.rtMat:SetFloat("$c1_y", color.g / 255)
		self.rtMat:SetFloat("$c1_z", color.b / 255)
		-- Force material refresh
		self.rtMat:Recompute()
	end

	-- 3D2D: map texture pixels to world units so that rtRadiusPx maps to self.radius
	local pxToWorld = 1 / (self.unitToPx or 1)
	local drawAngles = Angle(angles.p + 180, angles.y, angles.r)
	cam_Start3D2D(centerPos, drawAngles, pxToWorld)
	surface_SetMaterial(self.rtMat)
	surface_SetDrawColor(255, 255, 255, color.a)  -- Use white to let shader control color
	surface_DrawTexturedRectRotated(0, 0, self.rtSize, self.rtSize, rotationAngle or 0)
	cam_End3D2D()

	return true
end

function Ring:BuildRingRT()
	-- Resolve a shared cache entry or create one if missing
	local key, size, radiusBucket = ringRTKey(self)
	local entry = RING_RT_CACHE[key]

	if not entry then
		local rtName = "arcana_ring_rt_" .. key
		local tex = GetRenderTarget(rtName, size, size, true)
		local matName = "arcana_ring_mat_" .. key

		local mat = CreateCircleMaterial(matName, tex:GetName())

		entry = {
			tex = tex,
			mat = mat,
			size = size,
			rtRadiusPx = math_floor(size * 0.48),
			radiusBucket = radiusBucket,
			built = false,
		}

		RING_RT_CACHE[key] = entry
	end

	-- Bind shared RT/material to this instance
	self.rtSize = entry.size
	self.rtRadiusPx = entry.rtRadiusPx
	self.unitToPx = self.rtRadiusPx / math_max(1, self.radius)
	self.rt = entry.tex
	self.rtMat = entry.mat

	-- Pre-cache glyphs before first draw to avoid mid-draw allocations
	if not entry.built then
		if self.type == RING_TYPES.PATTERN_LINES then
			self:RT_PrecacheCircularTextGlyphs()
		elseif self.type == RING_TYPES.RUNE_STAR then
			self:RT_PrecacheRuneGlyphs()
		end

		-- Render geometry for this ring variant once
		render_PushRenderTarget(entry.tex, 0, 0, entry.size, entry.size)
		render_Clear(0, 0, 0, 0, true, true)
		cam_Start2D()
		surface_SetDrawColor(255, 255, 255, 255)
		-- Build using a canonical unit-to-pixel mapping so all rings sharing
		-- this cache key produce identical RT contents
		local oldUnitToPx = self.unitToPx
		local oldRtSize = self.rtSize
		local oldRtRadiusPx = self.rtRadiusPx
		self.rtSize = entry.size
		self.rtRadiusPx = entry.rtRadiusPx
		self.unitToPx = entry.rtRadiusPx / math_max(1, entry.radiusBucket)
		local passes = RT_BUILD_PASSES

		for _pass = 1, passes do
			surface_SetDrawColor(255, 255, 255, 255)

			if self.type == RING_TYPES.PATTERN_LINES then
				self:RT_DrawPatternLines2D()
				self:RT_DrawCircularText2D()
			elseif self.type == RING_TYPES.RUNE_STAR then
				self:RT_DrawRuneStar2D()
				self:RT_DrawRuneSymbols2D()
			elseif self.type == RING_TYPES.SIMPLE_LINE then
				self:RT_DrawSimpleLine2D()
			elseif self.type == RING_TYPES.STAR_RING then
				self:RT_DrawStarRing2D()
			end
		end

		cam_End2D()
		render_PopRenderTarget()
		-- Restore instance mapping
		self.unitToPx = oldUnitToPx
		self.rtSize = oldRtSize
		self.rtRadiusPx = oldRtRadiusPx
		entry.built = true
	end

	self.rtBuilt = true
end

-- 2D helpers for drawing into the RT
local function RT_DrawThickCircle(cx, cy, radiusPx, thicknessPx)
	thicknessPx = math_max(1, math_floor(thicknessPx or 1))

	for i = 0, thicknessPx - 1 do
		local r = radiusPx - (thicknessPx - 1) * 0.5 + i
		surface_DrawCircle(cx, cy, math_max(1, math_floor(r)), 255, 255, 255, 255)
	end
end

-- Simple glyph cache for rotated 2D text drawing into RTs
local GLYPH_CACHE = {}

local function GetGlyphMaterial(fontName, char)
	local key = (fontName or "") .. ":" .. (char or "")
	local cached = GLYPH_CACHE[key]
	if cached then return cached.mat, cached.w, cached.h end
	surface_SetFont(fontName or "DermaDefault")
	local w, h = surface_GetTextSize(char)
	w = math.max(1, math.floor(w + 2))
	h = math.max(1, math.floor(h + 2))
	-- Unique RT/material names per glyph
	local id = util_CRC and util_CRC(key) or tostring(key):gsub("%W", "")
	local rtName = "arcana_glyph_rt_" .. id
	local tex = GetRenderTarget(rtName, w, h, true)
	local matName = "arcana_glyph_mat_" .. id

	local mat = CreateCircleMaterial(matName, tex:GetName())

	-- Render the glyph (white) onto its RT
	render_PushRenderTarget(tex, 0, 0, w, h)
	render_Clear(0, 0, 0, 0, true, true)
	cam_Start2D()
	surface_SetFont(fontName or "DermaDefault")
	surface_SetTextColor(255, 255, 255, 255)
	local passes = RT_BUILD_PASSES

	for _pass = 1, passes do
		surface_SetTextPos(1, 1)
		surface_DrawText(char)
	end

	cam_End2D()
	render_PopRenderTarget()

	GLYPH_CACHE[key] = {
		mat = mat,
		w = w,
		h = h
	}

	return mat, w, h
end

-- Build rectangular RT and cylindrical mesh for band rings
function Ring:BuildBandRTAndMesh()
	-- Shared band RT/material
	local rtKey, texW, texH = bandRTKey(self)
	local rtEntry = BAND_RT_CACHE[rtKey]

	if not rtEntry then
		local rtName = "arcana_band_rt_" .. rtKey
		local tex = GetRenderTarget(rtName, texW, texH, true)
		local matName = "arcana_band_mat_" .. rtKey

		local mat = CreateCircleMaterial(matName, tex:GetName())

		self:RT_PrecacheCircularTextGlyphs()
		render_PushRenderTarget(tex, 0, 0, texW, texH)
		render_Clear(0, 0, 0, 0, true, true)
		cam_Start2D()
		surface_SetDrawColor(255, 255, 255, 255)
		local textData = self.cachedTextData

		if textData and textData.chars and textData.charCount > 0 then
			local fontName = self.textFont or "MagicCircle_Medium"
			surface_SetFont(fontName)
			local sampleChar = textData.chars[1]
			local cw, ch = surface_GetTextSize(sampleChar)

			if cw <= 0 then
				cw = 16
			end

			if ch <= 0 then
				ch = 32
			end

			local scale = math_max(0.25, math_min(2.5, (texH * 0.7) / ch))
			local passes = RT_BUILD_PASSES

			for _pass = 1, passes do
				do
					local lineThickness = math_max(1, math_floor(texH * 0.06))
					local drawHRef = math_max(1, ch * scale)
					local yText = math_floor((texH - drawHRef) * 0.5)
					local pad = math_max(1, math_floor(lineThickness * 1.2))
					local yTop = math_max(0, yText - pad - math_floor(lineThickness * 0.5))
					local yBot = math_min(texH - lineThickness, yText + drawHRef + pad - math_floor(lineThickness * 0.5))
					surface_SetDrawColor(255, 255, 255, 255)
					surface_DrawRect(0, yTop, texW, lineThickness)
					surface_DrawRect(0, yBot, texW, lineThickness)
				end

				local x = 0
				local idx = 1

				while x < texW + cw * scale do
					local char = textData.chars[((idx - 1) % textData.charCount) + 1]
					local gm, gw, gh = GetGlyphMaterial(fontName, char)
					local drawW = math_max(1, gw * scale)
					local drawH = math_max(1, gh * scale)
					local y = math_floor((texH - drawH) * 0.5)
					surface_SetMaterial(gm)
					surface_DrawTexturedRect(x, y, drawW, drawH)
					x = x + math_max(1, drawW * 0.9)
					idx = idx + 1
				end
			end
		end

		cam_End2D()
		render_PopRenderTarget()

		rtEntry = {
			tex = tex,
			mat = mat,
			w = texW,
			h = texH
		}

		BAND_RT_CACHE[rtKey] = rtEntry
	end

	self.bandRT = rtEntry.tex
	self.bandMat = rtEntry.mat
	self.bandRTW = rtEntry.w
	self.bandRTH = rtEntry.h
	-- Shared mesh for the cylindrical strip
	local height = math_max(1, self.bandHeight or (self.radius * 0.15))
	local radiusBucket = quantize(self.radius or 1, 1)
	local heightBucket = quantize(height, 0.25)
	local segments = math_max(24, math_min(128, self.segments or 64))
	local meshKey = string.format("r%d_h%.2f_s%d", radiusBucket, heightBucket, segments)
	local meshEntry = BAND_MESH_CACHE[meshKey]

	if not meshEntry then
		local vertices = {}
		local radius = math_max(1, radiusBucket)
		local halfH = heightBucket * 0.5

		for i = 0, segments do
			local t = i / segments
			local ang = t * math_pi * 2
			local cx = math_cos(ang) * radius
			local cy = math_sin(ang) * radius

			table_insert(vertices, {
				pos = Vector(cx, cy, -halfH),
				u = t,
				v = 1,
				normal = Vector(cx, cy, 0):GetNormalized()
			})

			table_insert(vertices, {
				pos = Vector(cx, cy, halfH),
				u = t,
				v = 0,
				normal = Vector(cx, cy, 0):GetNormalized()
			})
		end

		local meshBuilder = Mesh()

		meshBuilder:BuildFromTriangles((function()
			local tris = {}

			for i = 0, segments - 1 do
				local i0 = i * 2 + 1
				local i1 = i0 + 1
				local i2 = i0 + 2
				local i3 = i0 + 3

				table_insert(tris, {
					pos = vertices[i0].pos,
					u = vertices[i0].u,
					v = vertices[i0].v,
					normal = vertices[i0].normal
				})

				table_insert(tris, {
					pos = vertices[i2].pos,
					u = vertices[i2].u,
					v = vertices[i2].v,
					normal = vertices[i2].normal
				})

				table_insert(tris, {
					pos = vertices[i1].pos,
					u = vertices[i1].u,
					v = vertices[i1].v,
					normal = vertices[i1].normal
				})

				table_insert(tris, {
					pos = vertices[i2].pos,
					u = vertices[i2].u,
					v = vertices[i2].v,
					normal = vertices[i2].normal
				})

				table_insert(tris, {
					pos = vertices[i3].pos,
					u = vertices[i3].u,
					v = vertices[i3].v,
					normal = vertices[i3].normal
				})

				table_insert(tris, {
					pos = vertices[i1].pos,
					u = vertices[i1].u,
					v = vertices[i1].v,
					normal = vertices[i1].normal
				})
			end

			return tris
		end)())

		meshEntry = meshBuilder
		BAND_MESH_CACHE[meshKey] = meshEntry
	end

	self.bandMesh = meshEntry
	self.bandRTBuilt = true
end

function Ring:DrawBandMesh(centerPos, angles, color, rotationAngle)
	if not (self.bandMesh and self.bandMat) then return end
	local oriented = Angle(angles.p, angles.y, angles.r)
	-- Apply rotation around band axis for spinning
	oriented:RotateAroundAxis(oriented:Up(), rotationAngle or 0)
	local m = Matrix()
	m:SetAngles(oriented)
	-- Apply uniform scaling for band ring (animated)
	local s = self.currentScale or 1
	m:Scale(Vector(s, s, s))
	-- Nudge along local Up to reduce co-planar depth fighting between multiple bands
	local bias = self.zBias or 0
	m:SetTranslation(centerPos + oriented:Up() * bias)
	cam_PushModelMatrix(m)

	-- Apply color/alpha to the material so the band adopts ring color
	if self.bandMat.SetVector then
		self.bandMat:SetVector("$color", Vector((color.r or 255) / 255, (color.g or 255) / 255, (color.b or 255) / 255))
	end

	if self.bandMat.SetFloat then
		self.bandMat:SetFloat("$alpha", (color.a or 255) / 255)
		-- Set time for animated noise
		self.bandMat:SetFloat("$c0_x", CurTime())
		-- Set shader color parameters for fullbright rendering
		self.bandMat:SetFloat("$c1_x", color.r / 255)
		self.bandMat:SetFloat("$c1_y", color.g / 255)
		self.bandMat:SetFloat("$c1_z", color.b / 255)
	end

	render_SetMaterial(self.bandMat)
	render_SetColorModulation(color.r / 255 * 3, color.g / 255 * 3, color.b / 255 * 3)
	render_SetBlend((color.a or 255) / 255)
	render_SetLightingMode(2)

	-- Enable depth testing so band doesn't draw over objects in front
	render_OverrideDepthEnable(true, true)
	self.bandMesh:Draw()
	render_OverrideDepthEnable(false, false)

	render_SetLightingMode(0)
	render_SetColorModulation(1, 1, 1)
	render_SetBlend(1)
	cam_PopModelMatrix()
end

local function RT_DrawThickLine2D(x1, y1, x2, y2, thicknessPx)
	thicknessPx = math_max(1, math_floor(thicknessPx or 1))

	if thicknessPx <= 1 then
		surface_DrawLine(x1, y1, x2, y2)

		return
	end

	local dx, dy = x2 - x1, y2 - y1
	local len = math.sqrt(dx * dx + dy * dy)
	if len == 0 then return end
	local nx = -dy / len
	local ny = dx / len

	for i = 0, thicknessPx - 1 do
		local off = (i - (thicknessPx - 1) * 0.5)
		local ox = nx * off
		local oy = ny * off
		surface_DrawLine(x1 + ox, y1 + oy, x2 + ox, y2 + oy)
	end
end

-- map ring line thickness to a fixed world width so cache matches old look
function Ring:GetRTThicknessPx()
	-- Scale thickness with the radius of the circle
	local baseRadius = 150 -- reference radius
	local scaleFactor = math_max(1, self.radius / baseRadius)
	return math_max(3, math_floor(scaleFactor))
end

function Ring:RT_DrawSimpleLine2D()
	local cx, cy = self.rtSize * 0.5, self.rtSize * 0.5
	local rad = self.rtRadiusPx
	local thick = self:GetRTThicknessPx()
	RT_DrawThickCircle(cx, cy, rad, thick)
end

function Ring:RT_DrawPatternLines2D()
	local cx, cy = self.rtSize * 0.5, self.rtSize * 0.5
	local thick = self:GetRTThicknessPx()
	local outer = math_floor((self.outerTextRadius or self.radius) * self.unitToPx)
	local inner = math_floor((self.innerTextRadius or (self.radius - 5)) * self.unitToPx)
	RT_DrawThickCircle(cx, cy, outer, thick)
	RT_DrawThickCircle(cx, cy, inner, thick)
	-- text is drawn at runtime on top
end

-- Draw cached circular mystical text into the RT using 2D transforms.
-- We render the same cached characters but via matrix rotations around the RT center.
function Ring:RT_DrawCircularText2D()
	local textData = self.cachedTextData
	if not textData or not textData.chars or textData.charCount == 0 then return end
	local cx, cy = self.rtSize * 0.5, self.rtSize * 0.5
	local fontName = self.textFont or "MagicCircle_Small"
	local fontSizeWorld = math_max(32, self.radius * 0.32)
	local pixelScale = (fontSizeWorld / 512) * (self.unitToPx or 1)
	local inner = (self.innerTextRadius or (self.radius - 5))
	local outer = (self.outerTextRadius or self.radius)
	local radiusPx = math_floor((inner + (outer - inner) * 0.5) * (self.unitToPx or 1))
	-- Estimate spacing using a constant proportion of font size to match previous look
	local approxCharWidthPx = math_max(1, 0.1 * fontSizeWorld * (self.unitToPx or 1))
	local circumferencePx = 2 * math_pi * radiusPx
	local maxCharacters = math_max(1, math_floor(circumferencePx / approxCharWidthPx))
	local sourceChars = textData.chars
	local sourceCount = textData.charCount
	if sourceCount == 0 then return end
	surface_SetDrawColor(255, 255, 255, 255)

	for i = 1, maxCharacters do
		local char = sourceChars[((i - 1) % sourceCount) + 1]
		local t = (i - 1) / maxCharacters
		local angleRad = -t * math_pi * 2 -- reversed
		local px = cx + math_cos(angleRad) * radiusPx
		local py = cy + math_sin(angleRad) * radiusPx
		local rotDeg = math_deg(angleRad + math_pi * 0.5)
		local mat, gw, gh = GetGlyphMaterial(fontName, char)
		local drawW = math_max(1, gw * pixelScale)
		local drawH = math_max(1, gh * pixelScale)
		surface_SetMaterial(mat)
		surface_DrawTexturedRectRotated(px, py, drawW, drawH, rotDeg)
	end
end

function Ring:RT_DrawRuneStar2D()
	local cx, cy = self.rtSize * 0.5, self.rtSize * 0.5
	local thick = self:GetRTThicknessPx()
	local mainR = math_floor(self.radius * self.unitToPx)
	RT_DrawThickCircle(cx, cy, mainR, thick)
	-- 4 rune circles positions
	local runeR = math_floor((self.radius * (self.runeRadiusRatio or 0.15)) * self.unitToPx)

	for i = 1, 4 do
		local a = (i - 1) * math_pi * 0.5 + math_pi * 0.25
		local x = cx + math_cos(a) * mainR
		local y = cy + math_sin(a) * mainR
		RT_DrawThickCircle(x, y, runeR, thick)
	end

	if self.starConnections then
		local pts = {}

		for i = 1, 4 do
			local a = (i - 1) * math_pi * 0.5 + math_pi * 0.25
			local x = cx + math_cos(a) * mainR
			local y = cy + math_sin(a) * mainR

			pts[i] = {
				x = x,
				y = y
			}
		end

		for i = 1, 4 do
			for j = i + 1, 4 do
				RT_DrawThickLine2D(pts[i].x, pts[i].y, pts[j].x, pts[j].y, thick)
			end
		end
	end
end

-- Draw rune symbols into RT (white) at rune positions
function Ring:RT_DrawRuneSymbols2D()
	if not self.runes then return end
	local cx, cy = self.rtSize * 0.5, self.rtSize * 0.5
	local mainR = math_floor(self.radius * self.unitToPx)
	local runeRadius = self.radius * (self.runeRadiusRatio or 0.15)
	local fontSize = math_max(48, runeRadius * 16)
	local scale = (fontSize / 512) * (self.unitToPx or 1)
	surface_SetFont("MagicCircle_Rune")
	surface_SetTextColor(255, 255, 255, 255)

	for i = 1, 4 do
		local a = (i - 1) * math_pi * 0.5 + math_pi * 0.25
		local x = cx + math_cos(a) * mainR
		local y = cy + math_sin(a) * mainR
		local m = Matrix()
		m:Translate(Vector(x, y, 0))
		m:Scale(Vector(scale, scale, 1))
		cam_PushModelMatrix(m, true)
		local ch = self.runes[i]
		local w, h = surface_GetTextSize(ch)
		surface_SetTextPos(-w * 0.5, -h * 0.5)
		surface_DrawText(ch)
		cam_PopModelMatrix()
	end
end

-- Precache rune glyphs used by this ring
function Ring:RT_PrecacheRuneGlyphs()
	if not self.runes then return end
	surface_SetFont("MagicCircle_Rune")

	for i = 1, 4 do
		GetGlyphMaterial("MagicCircle_Rune", self.runes[i])
	end
end

-- Precache all glyphs needed to fill the circular text once
function Ring:RT_PrecacheCircularTextGlyphs()
	local textData = self.cachedTextData
	if not textData or not textData.chars or textData.charCount == 0 then return end
	local fontName = self.textFont or "MagicCircle_Small"
	surface_SetFont(fontName)
	-- Precache the unique characters set to avoid duplicate work
	local seen = {}

	for _, ch in ipairs(textData.chars) do
		if not seen[ch] then
			GetGlyphMaterial(fontName, ch)
			seen[ch] = true
		end
	end
end

function Ring:RT_DrawStarRing2D()
	local cx, cy = self.rtSize * 0.5, self.rtSize * 0.5
	local thick = self:GetRTThicknessPx()
	local innerR = math_floor(self.innerRadius * self.unitToPx)
	local outerR = math_floor(self.outerRadius * self.unitToPx)
	local starPoints = math_max(5, self.starPoints or 5)
	local pts = {}

	for i = 0, starPoints * 2 - 1 do
		local a = (i / (starPoints * 2)) * math_pi * 2
		local r = (i % 2 == 0) and outerR or innerR

		pts[i + 1] = {
			x = cx + math_cos(a) * r,
			y = cy + math_sin(a) * r
		}
	end

	for i = 1, #pts do
		local ni = (i % #pts) + 1
		RT_DrawThickLine2D(pts[i].x, pts[i].y, pts[ni].x, pts[ni].y, thick)
	end

	-- Inner spokes
	for i = 1, starPoints do
		local outerIndex = (i - 1) * 2 + 1
		RT_DrawThickLine2D(pts[outerIndex].x, pts[outerIndex].y, cx, cy, thick)
	end
end

-- Export for consumption by magic_circle.lua and band_circle.lua
Arcana.Circle.Ring = Ring
Arcana.Circle.RING_TYPES = RING_TYPES