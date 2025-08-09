if SERVER then return end

local render_DrawLine = _G.render.DrawLine
local render_PushRenderTarget = _G.render.PushRenderTarget
local render_PopRenderTarget = _G.render.PopRenderTarget
local render_Clear = _G.render.Clear
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
local surface_SetDrawColor = _G.surface.SetDrawColor
local surface_DrawTexturedRectRotated = _G.surface.DrawTexturedRectRotated
local surface_DrawLine = _G.surface.DrawLine
local surface_DrawCircle = _G.surface.DrawCircle
local util_CRC = _G.util and _G.util.CRC
local Matrix = _G.Matrix
local math_random = _G.math.random

local math_pi = _G.math.pi
local math_sin = _G.math.sin
local math_cos = _G.math.cos
local math_deg = _G.math.deg
local math_rad = _G.math.rad
local math_acos = _G.math.acos
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

local MagicCircle = {}
MagicCircle.__index = MagicCircle

-- Ring class definition
local Ring = {}
Ring.__index = Ring

-- Ancient Greek symbols/runes for type 2 rings
local GREEK_RUNES = {
	"Α", "Β", "Γ", "Δ", "Ε", "Ζ", "Η", "Θ", "Ι", "Κ", "Λ", "Μ",
	"Ν", "Ξ", "Ο", "Π", "Ρ", "Σ", "Τ", "Υ", "Φ", "Χ", "Ψ", "Ω",
	"α", "β", "γ", "δ", "ε", "ζ", "η", "θ", "ι", "κ", "λ", "μ",
	"ν", "ξ", "ο", "π", "ρ", "σ", "τ", "υ", "φ", "χ", "ψ", "ω"
}

-- Ancient Greek magical phrases and words for circular text
local GREEK_PHRASES = {
	"αβραξασαβραξασαβραξασαβραξασαβραξασαβραξασαβραξασαβραξας",
	"αγιοσαγιοσαγιοσισχυροσισχυροσισχυροσαθανατοσαθανατοσαθανατοσ",
	"αλφαωμεγααλφαωμεγααλφαωμεγααλφαωμεγααλφαωμεγααλφαωμεγα",
	"θεοσφιλοσσοφιαγνωσιςθεοσφιλοσσοφιαγνωσιςθεοσφιλοσσοφιαγνωσις",
	"κοσμοςλογοςψυχηπνευμακοσμοςλογοςψυχηπνευμακοσμοςλογοςψυχηπνευμα",
	"φωςζωηαληθειαφωςζωηαληθειαφωςζωηαληθειαφωςζωηαληθειαφωςζωηαληθεια",
	"αρχηκαιτελοςαρχηκαιτελοςαρχηκαιτελοςαρχηκαιτελοςαρχηκαιτελος",
	"ουρανοςγηθαλασσαπυραηρουρανοςγηθαλασσαπυραηρουρανοςγηθαλασσα"
}

-- Arabic mystical phrases and words for circular text
local ARABIC_PHRASES = {
	"بسمالله الرحمن الرحيم بسمالله الرحمن الرحيم بسمالله الرحمن الرحيم",
	"لاإلهإلاالله محمدرسولالله لاإلهإلاالله محمدرسولالله لاإلهإلاالله",
	"الله نور السماوات والأرض الله نور السماوات والأرض الله نور",
	"سبحان الله وبحمده سبحان الله العظيم سبحان الله وبحمده سبحان الله",
	"أستغفرالله أستغفرالله أستغفرالله أستغفرالله أستغفرالله أستغفرالله",
	"الحمدلله رب العالمين الحمدلله رب العالمين الحمدلله رب العالمين",
	"قل هو الله أحد الله الصمد قل هو الله أحد الله الصمد قل هو الله",
	"وما توفيقي إلا بالله عليه توكلت وإليه أنيب وما توفيقي إلا بالله"
}

-- Combined phrases array for random selection
local ALL_MYSTICAL_PHRASES = {}
for _, phrase in ipairs(GREEK_PHRASES) do
	table_insert(ALL_MYSTICAL_PHRASES, phrase)
end
for _, phrase in ipairs(ARABIC_PHRASES) do
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
	for _, rune in ipairs(GREEK_RUNES) do
		table_insert(allSymbols, rune)
	end
	return allSymbols[math_random(#allSymbols)]
end

local function LocalToWorld3D(localPos, centerPos, angles)
	local forward = angles:Forward()
	local right = angles:Right()
	local up = angles:Up()

	return centerPos +
		   right * localPos.x +
		   forward * localPos.y +
		   up * localPos.z
end

-- Helper function to draw thick lines using multiple parallel lines
local function DrawThickLine(startPos, endPos, color, thickness, angles)
	if thickness <= 1 then
		render_DrawLine(startPos, endPos, color, true)
		return
	end

	-- Calculate the direction vector and perpendicular vectors
	local direction = (endPos - startPos):GetNormalized()
	local up = angles and angles:Up() or Vector(0, 0, 1)
	local perpendicular = direction:Cross(up):GetNormalized()

	-- If the perpendicular is zero (parallel to up), use right vector
	if perpendicular:Length() < 0.01 then
		local right = angles and angles:Right() or Vector(1, 0, 0)
		perpendicular = direction:Cross(right):GetNormalized()
	end

	-- Draw multiple parallel lines to create thickness
	local lineCount = math_max(1, math_floor(thickness))
	for i = 0, lineCount - 1 do
		local offset = (i / math_max(1, lineCount - 1) - 0.5) * 0.25
		local offsetVector = perpendicular * offset

		local start = startPos + offsetVector
		local endPoint = endPos + offsetVector

		render_DrawLine(start, endPoint, color, true)
	end
end

-- Ring class implementation
function Ring.new(ringType, radius, height, rotationSpeed, rotationDirection)
	local ring = setmetatable({}, Ring)

	ring.type = ringType or RING_TYPES.SIMPLE_LINE
	ring.radius = radius or 50
	ring.height = height or 0
	ring.rotationSpeed = rotationSpeed or (math_random() * 2 - 1) * 45 -- -45 to 45 degrees per second
	ring.rotationDirection = rotationDirection or (math_random() > 0.5 and 1 or -1)
	ring.currentRotation = math_random() * 360 -- Start at random rotation
	ring.segments = 64
	ring.opacity = 1.0
	ring.pulseSpeed = math_random() * 2 + 1 -- 1-3 Hz
	ring.pulseOffset = math_random() * math_pi * 2
	ring.lineWidth = 2.0 -- Default line thickness

	-- Render target cache (only for non-band rings)
	ring.useRTCache = (ring.type ~= RING_TYPES.BAND_RING)
	ring.rtBuilt = false
	ring.rtSize = nil
	ring.rt = nil
	ring.rtMat = nil
	ring.rtRadiusPx = nil
	ring.unitToPx = nil

	-- Type-specific properties
	if ring.type == RING_TYPES.PATTERN_LINES then
		ring.mysticalPhrase = ALL_MYSTICAL_PHRASES[math_random(#ALL_MYSTICAL_PHRASES)]
		ring.outerTextRadius = ring.radius
		ring.innerTextRadius = ring.radius - 5
		ring.textFont = "MagicCircle_Medium"
		-- Cache text processing for performance
		ring.cachedTextData = ring:CacheTextProcessing()
	elseif ring.type == RING_TYPES.RUNE_STAR then
		ring.runes = {}
		for i = 1, 4 do
			ring.runes[i] = GetRandomRune()
		end
		ring.runeRadiusRatio = 0.15
		ring.starConnections = true
	elseif ring.type == RING_TYPES.STAR_RING then
		ring.starPoints = math_random(5, 8) -- 5-8 pointed star
		ring.starType = math_random(1, 2) -- Different star patterns
		ring.innerRadius = ring.radius * (0.3 + math_random() * 0.3) -- 0.3-0.6
		ring.outerRadius = ring.radius
	elseif ring.type == RING_TYPES.BAND_RING then
		-- Vertical band with outward-facing text
		ring.bandHeight = 1
		ring.mysticalPhrase = ALL_MYSTICAL_PHRASES[math_random(#ALL_MYSTICAL_PHRASES)]
		ring.textFont = "MagicCircle_Medium"
		ring.cachedTextData = ring:CacheTextProcessing()
	end

	return ring
end

-- Build an Angle from a forward vector and a desired up vector
local function AngleFromForwardUp(forward, desiredUp)
	local f = forward:GetNormalized()
	local up = desiredUp:GetNormalized()

	local ang = f:Angle()

	-- Project vectors onto plane perpendicular to forward and align roll
	local currentUp = ang:Up()
	local projDesired = (up - f * up:Dot(f))
	local projCurrent = (currentUp - f * currentUp:Dot(f))

	local lenD = projDesired:Length()
	local lenC = projCurrent:Length()
	if lenD < 1e-6 or lenC < 1e-6 then
		return ang
	end

	projDesired:Normalize()
	projCurrent:Normalize()

	local dot = math.Clamp(projCurrent:Dot(projDesired), -1, 1)
	local angleRad = math_acos(dot)
	local cross = projCurrent:Cross(projDesired)
	local sign = (cross:Dot(f) < 0) and -1 or 1
	ang:RotateAroundAxis(ang:Forward(), math_deg(sign * angleRad))
	return ang
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
end

function Ring:GetCurrentOpacity(baseOpacity, time)
	local pulse = math_sin(time * self.pulseSpeed + self.pulseOffset) * 0.3 + 0.7
	return baseOpacity * self.opacity * pulse
end

function Ring:Draw(centerPos, angles, color, time)
	local ringPos = centerPos + angles:Up() * self.height
	local currentOpacity = self:GetCurrentOpacity(color.a, time)
	local ringColor = self.color or Color(color.r, color.g, color.b, currentOpacity)
	ringColor.a = currentOpacity

	-- Pass the rotation angle directly to drawing functions instead of modifying angles
	if self.type == RING_TYPES.PATTERN_LINES
		or self.type == RING_TYPES.RUNE_STAR
		or self.type == RING_TYPES.SIMPLE_LINE
		or self.type == RING_TYPES.STAR_RING then
		-- Non-band rings use RT-only rendering now
		self:DrawCachedRTQuad(ringPos, angles, ringColor, self.currentRotation)
	elseif self.type == RING_TYPES.BAND_RING then
		local oriented = Angle(angles.p, angles.y, angles.r)
		if self.axisAngles then
			-- Apply local orientation offsets to allow arbitrary band axes
			oriented:RotateAroundAxis(oriented:Right(), self.axisAngles.p or 0)
			oriented:RotateAroundAxis(oriented:Up(), self.axisAngles.y or 0)
			oriented:RotateAroundAxis(oriented:Forward(), self.axisAngles.r or 0)
		end
		self:DrawBandRing(ringPos, oriented, ringColor, angles, self.currentRotation)
	end
end

-- Create and fill an RT for this ring if needed, return true if RT-based draw succeeds
function Ring:DrawCachedRTQuad(centerPos, angles, color, rotationAngle)
	if not self.useRTCache then return false end

	if not self.rtBuilt then
		self:BuildRingRT()
	end
	if not self.rt or not self.rtMat then return false end

	-- 3D2D: map texture pixels to world units so that rtRadiusPx maps to self.radius
	local pxToWorld = 1 / (self.unitToPx or 1)
	local drawAngles = Angle(angles.p + 180, angles.y, angles.r)
	cam_Start3D2D(centerPos, drawAngles, pxToWorld)
		surface_SetMaterial(self.rtMat)
		surface_SetDrawColor(color.r, color.g, color.b, color.a)
		surface_DrawTexturedRectRotated(0, 0, self.rtSize, self.rtSize, rotationAngle or 0)
	cam_End3D2D()
	return true
end

function Ring:BuildRingRT()
	-- Select RT size based on radius for decent quality, with margins
	local scale = 10
	local size = math.Clamp(math_floor((self.radius or 128) * 2 * scale), 256, 4096)
	self.rtSize = size
	self.rtRadiusPx = math_floor(size * 0.48) -- keep a small border to avoid clipping
	self.unitToPx = self.rtRadiusPx / math_max(1, self.radius)

	local rtName = "arcana_ring_rt_" .. tostring(self):gsub("%W", "") .. "_r" .. tostring(self.radius) .. "_s" .. tostring(size)
	local tex = GetRenderTarget(rtName, size, size, true)
	self.rt = tex

	-- Create a material bound to this RT
	local matName = "arcana_ring_mat_" .. tostring(self):gsub("%W", "")
	self.rtMat = CreateMaterial(matName, "UnlitGeneric", {
		["$basetexture"] = tex:GetName(),
		["$translucent"] = 1,
		["$vertexalpha"] = 1,
		["$vertexcolor"] = 1,
		["$nolod"] = 1,
		["$nocull"] = 1,
		["$additive"] = 0,
	})

	-- Pre-cache any glyphs needed so we don't allocate RTs while drawing into the ring RT
	if self.type == RING_TYPES.PATTERN_LINES then
		self:RT_PrecacheCircularTextGlyphs()
	elseif self.type == RING_TYPES.RUNE_STAR then
		self:RT_PrecacheRuneGlyphs()
	end

	-- Draw geometry for this ring into the RT (white on transparent)
	render_PushRenderTarget(self.rt)
		render_Clear(0, 0, 0, 0, true, true)
		cam_Start2D()
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
		cam_End2D()
	render_PopRenderTarget()

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
	local mat = CreateMaterial(matName, "UnlitGeneric", {
		["$basetexture"] = tex:GetName(),
		["$translucent"] = 1,
		["$vertexalpha"] = 1,
		["$vertexcolor"] = 1,
		["$nolod"] = 1,
	})

	-- Render the glyph (white) onto its RT
	render_PushRenderTarget(tex)
		render_Clear(0, 0, 0, 0, true, true)
		cam_Start2D()
			surface_SetFont(fontName or "DermaDefault")
			surface_SetTextColor(255, 255, 255, 255)
			surface_SetTextPos(1, 1)
			surface_DrawText(char)
		cam_End2D()
	render_PopRenderTarget()

	GLYPH_CACHE[key] = { mat = mat, w = w, h = h }
	return mat, w, h
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
	local thicknessWorld = 0.6 -- world units
	return math_max(1, math_floor((self.unitToPx or 1) * thicknessWorld))
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
			pts[i] = { x = x, y = y }
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
	surface_SetTextColor(255,255,255,255)
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
		pts[i + 1] = { x = cx + math_cos(a) * r, y = cy + math_sin(a) * r }
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

-- Draw a vertical band (wall ring) with outward-facing text
function Ring:DrawBandRing(centerPos, angles, color, originalAngles, rotationAngle)
	local halfH = (self.bandHeight or (self.radius * 0.15)) * 0.5
	local rotRad = math_rad(rotationAngle or 0)

	-- Top and bottom edge circles
	self:DrawSimpleRingAtRadius(centerPos + angles:Up() * halfH, angles, color, self.radius, rotationAngle)
	self:DrawSimpleRingAtRadius(centerPos - angles:Up() * halfH, angles, color, self.radius, rotationAngle)

	-- Vertical segments to imply a glowing band
	local step = math_max(1, math_floor(self.segments / 16))
	for i = 0, self.segments - 1, step do
		local a = (i / self.segments) * math_pi * 2 + rotRad
		local x = math_cos(a) * self.radius
		local y = math_sin(a) * self.radius
		local top = LocalToWorld3D(Vector(x, y, halfH), centerPos, angles)
		local bottom = LocalToWorld3D(Vector(x, y, -halfH), centerPos, angles)
		DrawThickLine(bottom, top, color, self.lineWidth, angles)
	end

	-- Outward-facing text around the band
	self:DrawBandText(centerPos, angles, color, originalAngles, rotationAngle, halfH)
end

-- Text wrapped around the outward face of a 3D band
function Ring:DrawBandText(centerPos, angles, color, originalAngles, rotationAngle, halfH)
	local textData = self.cachedTextData
	if not textData or not textData.chars or textData.charCount == 0 then return end

	local fontSize = math_max(32, (self.bandHeight or (self.radius * 0.15)) * 2)
	local circumference = 2 * math_pi * self.radius
	local charWidth = fontSize * 0.1
	local maxCharacters = math_floor(circumference / charWidth)

	local chars = {}
	local sourceChars = textData.chars
	local sourceCount = textData.charCount
	local currentLength = 0
	while currentLength < maxCharacters do
		for i = 1, sourceCount do
			if currentLength >= maxCharacters then break end
			table_insert(chars, sourceChars[i])
			currentLength = currentLength + 1
		end
		if sourceCount == 0 then break end
	end

	local finalLength = #chars
	if finalLength == 0 then return end

	local scale = fontSize / 512
	local rotRad = math_rad(rotationAngle or 0)
	local upVec = angles:Up()

	for i = 1, finalLength do
		local char = chars[i]
		local t = (i - 1) / finalLength
		local a = t * math_pi * 2 + rotRad

		local cosA = math_cos(a)
		local sinA = math_sin(a)
		local radial = angles:Right() * cosA + angles:Forward() * sinA
		local worldPos = centerPos + radial * self.radius

		-- Slightly outwards to avoid z-fighting
		worldPos = worldPos + radial * 0.5

		-- Build orientation: forward points outward, up follows circle up
		local textAng = AngleFromForwardUp(radial, upVec)
		-- Rotate so text planes face outward rather than toward band top/bottom
		textAng:RotateAroundAxis(textAng:Right(), -90)

		cam_Start3D2D(worldPos, textAng, scale)
			surface_SetFont(self.textFont or "MagicCircle_Small")
			surface_SetTextColor(color.r, color.g, color.b, color.a)
			local w, h = surface_GetTextSize(char)
			-- center vertically in the band
			surface_SetTextPos(-w * 0.5, -h * 0.5)
			surface_DrawText(char)
		cam_End3D2D()
	end
end

function Ring:DrawSimpleRingAtRadius(centerPos, angles, color, radius, rotationAngle)
	local points = {}
	local rotRad = math_rad(rotationAngle or 0)

	for i = 0, self.segments - 1 do
		local angle = (i / self.segments) * math_pi * 2 + rotRad
		local x = math_cos(angle) * radius
		local y = math_sin(angle) * radius
		local localPos = Vector(x, y, 0)
		table_insert(points, LocalToWorld3D(localPos, centerPos, angles))
	end

	for i = 1, #points do
		local nextI = (i % #points) + 1
		DrawThickLine(points[i], points[nextI], color, self.lineWidth, angles)
	end
end

-- MagicCircle class implementation
function MagicCircle.new(pos, ang, color, intensity, size, lineWidth)
	local circle = setmetatable({}, MagicCircle)

	-- Core properties
	circle.position = pos or Vector(0, 0, 0)
	circle.angles = ang or Angle(0, 0, 0)
	circle.color = color or Color(255, 100, 255, 255)
	circle.intensity = math_max(1, intensity or 3)
	circle.size = math_max(10, size or 100)
	circle.lineWidth = math_max(1, lineWidth or 2)

	-- Animation properties
	circle.isAnimated = false
	circle.startTime = CurTime()
	circle.duration = 0
	circle.isActive = true

	-- Evolving-cast state
	circle.isEvolving = false
	circle.evolveStart = 0
	circle.evolveDuration = 0
	circle.baseVisible = 2
	circle.lastVisible = 0
	circle.kLog = 9 -- control for logarithmic growth
	circle.enableRingSounds = false

	-- Generate rings
	circle.rings = {}
	circle:GenerateRings()

	return circle
end

function MagicCircle:GenerateRings()
	self.rings = {}

	-- Calculate number of rings based on intensity
	local ringCount = math_max(4, math_min(self.intensity + math_random(1, 3), 8))

	-- Standard magic circles should NOT include band rings (reserved for VFX)
	local allTypes = {
		RING_TYPES.PATTERN_LINES,
		RING_TYPES.RUNE_STAR,
		RING_TYPES.SIMPLE_LINE,
		RING_TYPES.STAR_RING,
	}

	-- Create a list to track which ring types we need to place (one of each first)
	local requiredTypes = {}
	for _, t in ipairs(allTypes) do
		table_insert(requiredTypes, t)
	end

	-- Shuffle the required types for random order
	for i = #requiredTypes, 2, -1 do
		local j = math_random(i)
		requiredTypes[i], requiredTypes[j] = requiredTypes[j], requiredTypes[i]
	end

	-- First, place one of each required ring type
	for i = 1, math_min(#requiredTypes, ringCount) do
		local ringType = requiredTypes[i]
		local radius = self.size * (0.2 + (i - 1) * 0.8 / (ringCount - 1))
		local height = 0
		local rotationSpeed = (math_random() * 60 - 30) -- -30 to 30 degrees per second
		local rotationDirection = math_random() > 0.5 and 1 or -1

		local ring = Ring.new(ringType, radius, height, rotationSpeed, rotationDirection)
		ring.lineWidth = self.lineWidth -- Apply the magic circle's line width
		table_insert(self.rings, ring)
	end

	-- Fill remaining slots with random types (excluding star ring to keep it special)
	for i = #requiredTypes + 1, ringCount do
		-- pool excludes STAR_RING
		local pool = {
			RING_TYPES.PATTERN_LINES,
			RING_TYPES.RUNE_STAR,
			RING_TYPES.SIMPLE_LINE,
		}
		local ringType = pool[math_random(#pool)]

		local radius = self.size * (0.2 + (i - 1) * 0.8 / (ringCount - 1))
		local height = 0
		local rotationSpeed = (math_random() * 60 - 30) -- -30 to 30 degrees per second
		local rotationDirection = math_random() > 0.5 and 1 or -1

		local ring = Ring.new(ringType, radius, height, rotationSpeed, rotationDirection)
		ring.lineWidth = self.lineWidth -- Apply the magic circle's line width
		table_insert(self.rings, ring)
	end

	-- Sort rings by radius (largest first) for proper layering
	table_sort(self.rings, function(a, b) return a.radius > b.radius end)

	-- Add central glow ring
	local glowRing = Ring.new(RING_TYPES.SIMPLE_LINE, self.size * 0.1, 0, math_random() * 120 - 60, math_random() > 0.5 and 1 or -1)
	glowRing.pulseSpeed = 4 -- Faster pulse for glow effect
	glowRing.lineWidth = self.lineWidth -- Apply the magic circle's line width
	table_insert(self.rings, glowRing)
end

function MagicCircle:Update(deltaTime)
	if not self.isActive then return end

	-- Update all rings
	for _, ring in ipairs(self.rings) do
		ring:Update(deltaTime)
	end

	-- Check if animation should end
	if self.isAnimated and (CurTime() - self.startTime) > self.duration then
		self.isActive = false
	end

	-- Update evolving behavior
	if self.isEvolving then
		local now = CurTime()
		local p = math.Clamp((now - self.evolveStart) / math.max(0.01, self.evolveDuration), 0, 1)
		local maxVisible = math.max(2, #self.rings)
		local logp = math.log(1 + self.kLog * p) / math.log(1 + self.kLog)
		local shouldVisible = self.baseVisible + math.floor((maxVisible - self.baseVisible) * logp + 0.0001)
		shouldVisible = math.Clamp(shouldVisible, self.baseVisible, maxVisible)

		if shouldVisible > self.lastVisible then
			-- Play subtle mystical chime(s) when adding ring(s)
			if self.enableRingSounds then
				local addCount = shouldVisible - self.lastVisible
				for i = 1, addCount do
					local pitch = 100 + math.random(-8, 10)
					local vol = 0.45
					local posJitter = self.position + Vector(math.random(-2,2), math.random(-2,2), math.random(-1,1))
					sound.Play("arcana/magic" .. math.random(1, 4) .. ".ogg", posJitter, 70, pitch, vol)
				end
			end
			self.lastVisible = shouldVisible
		end

		-- Move ring heights to create depth evolution
		for i, ring in ipairs(self.rings) do
			local target = 0
			if i > 2 and i <= self.lastVisible then
				local sign = (i % 2 == 0) and 1 or -1
				local span = math.max(1, self.lastVisible - 2)
				local fraction = math.Clamp((i - 2) / span, 0, 1)
				-- Larger depth range proportional to circle size
				local depthAmplitude = self.size * 0.35
				target = sign * depthAmplitude * fraction * logp
			end
			ring.height = ring.height + (target - ring.height) * math.min(1, deltaTime * 6)
		end
	end
end

function MagicCircle:Draw()
	if not self.isActive then return end

	render.SetColorMaterial()

	local currentTime = CurTime()

	-- Draw all rings
	local count = #self.rings
	local maxToDraw = self.isEvolving and math.max(self.baseVisible, self.lastVisible) or count
	for i = 1, math.min(count, maxToDraw) do
		local ring = self.rings[i]
		ring:Draw(self.position, self.angles, self.color, currentTime)
	end
end

function MagicCircle:SetAnimated(duration)
	self.isAnimated = true
	self.duration = duration or 5
	self.startTime = CurTime()
end

-- Start evolving the circle over the given duration.
-- This progressively reveals rings (logarithmically) and animates their height (depth).
function MagicCircle:StartEvolving(duration, enableSounds)
	self.isEvolving = true
	self.evolveStart = CurTime()
	self.evolveDuration = math.max(0.1, duration or 1)
	self.baseVisible = 2
	self.lastVisible = 2
	self.enableRingSounds = enableSounds == true
	-- Initialize first two rings to baseline
	for i, ring in ipairs(self.rings) do
		ring.height = (i <= 2) and 0 or ring.height
	end
end

function MagicCircle:IsActive()
	return self.isActive
end

function MagicCircle:Destroy()
	self.isActive = false
end

function MagicCircle:GetRingCount()
	return #self.rings
end

function MagicCircle:GetRing(index)
	return self.rings[index]
end

function MagicCircle:SetRingProperty(index, property, value)
	if self.rings[index] then
		self.rings[index][property] = value
	end
end

-- Global magic circle manager
local MagicCircleManager = {
	circles = {},
	lastUpdate = CurTime()
}

function MagicCircleManager:Add(circle)
	table_insert(self.circles, circle)
end

function MagicCircleManager:Update()
	local currentTime = CurTime()
	local deltaTime = currentTime - self.lastUpdate
	self.lastUpdate = currentTime

	-- Update all circles and remove inactive ones
	for i = #self.circles, 1, -1 do
		local circle = self.circles[i]
		if circle.Update then circle:Update(deltaTime) end

		if circle.IsActive and not circle:IsActive() then
			table_remove(self.circles, i)
		end
	end
end

function MagicCircleManager:Draw()
	for _, circle in ipairs(self.circles) do
		if circle.Draw then circle:Draw() end
	end
end

function MagicCircleManager:Clear()
	self.circles = {}
end

-- Hook for automatic updates
hook.Add("Think", "MagicCircleManager_Update", function()
	MagicCircleManager:Update()
end)

hook.Add("PostDrawOpaqueRenderables", "MagicCircleManager_Draw", function()
	MagicCircleManager:Draw()
end)

-- Client receiver for particle attachments
net.Receive("Arcana_AttachParticles", function()
	local ent = net.ReadEntity()
	local effectName = net.ReadString()
	local duration = net.ReadFloat()
	if not IsValid(ent) then return end
	if not effectName or effectName == "" then return end
	if not ent.ParticleEmitters then ent.ParticleEmitters = {} end

	-- Attempt to use ParticleEffectAttach if available
	if ParticleEffectAttach then
		local attached = pcall(function()
			ParticleEffectAttach(effectName, PATTACH_ABSORIGIN_FOLLOW, ent, 0)
		end)
		if attached then
			timer.Simple(duration or 5, function()
				if IsValid(ent) and ent.StopParticles then ent:StopParticles() end
			end)
			return
		end
	end
end)

-- Convenience functions (maintaining backward compatibility)
function MagicCircle.DrawMagicCircle(pos, ang, color, intensity, size, lineWidth)
	local circle = MagicCircle.new(pos, ang, color, intensity, size, lineWidth)
	circle:Draw()
end

function MagicCircle.CreateMagicCircle(pos, ang, color, intensity, size, duration, lineWidth)
	local circle = MagicCircle.new(pos, ang, color, intensity, size, lineWidth)
	circle:SetAnimated(duration or 5)
	MagicCircleManager:Add(circle)
	return circle
end

-- Create custom fonts for magic circles (high resolution)
surface.CreateFont("MagicCircle_Small", {
	font = "Arial",
	size = 64,
	weight = 500,
	antialias = true,
})

surface.CreateFont("MagicCircle_Medium", {
	font = "Arial",
	size = 96,
	weight = 600,
	antialias = true,
})

surface.CreateFont("MagicCircle_Large", {
	font = "Arial",
	size = 128,
	weight = 700,
	antialias = true,
})

surface.CreateFont("MagicCircle_Rune", {
	font = "Arial",
	size = 80,
	weight = 800,
	antialias = true,
})

--
-- Dedicated BandCircle for VFX (not used for spell casting)
--
local BandCircle = {}
BandCircle.__index = BandCircle

function BandCircle.new(pos, ang, color, size)
	local bc = setmetatable({}, BandCircle)
	bc.position = pos or Vector(0, 0, 0)
	bc.angles = ang or Angle(0, 0, 0)
	bc.color = color or Color(255, 150, 255, 255)
	bc.size = math_max(10, size or 80)
	bc.rings = {}
	bc.isActive = true
	bc.isAnimated = false
	bc.startTime = CurTime()
	bc.duration = 0
	return bc
end

function BandCircle:AddBand(radius, height, axisSpin, lineWidth, phrase)
	local ring = Ring.new(RING_TYPES.BAND_RING, radius or (self.size * 0.6), 0, 30, 1)
	ring.bandHeight = height or (radius and radius * 0.2 or self.size * 0.12)
	ring.axisSpin = axisSpin -- table: {p=,y=,r=} degrees/sec
	ring.lineWidth = math_max(1, lineWidth or 2)
	if phrase then
		ring.mysticalPhrase = phrase
		ring.cachedTextData = ring:CacheTextProcessing()
	end
	table_insert(self.rings, ring)
	return ring
end

function BandCircle:Update(dt)
	for _, r in ipairs(self.rings) do r:Update(dt) end
	if self.isAnimated and (CurTime() - self.startTime) > (self.duration or 0) then
		self.isActive = false
	end
end

function BandCircle:Draw()
	if not self.isActive then return end
	render.SetColorMaterial()
	local t = CurTime()
	for _, r in ipairs(self.rings) do
		r:Draw(self.position, self.angles, self.color, t)
	end
end

function BandCircle:IsActive()
	return self.isActive
end

function BandCircle:Remove()
	self.isActive = false
end

function BandCircle:SetAnimated(duration)
	self.isAnimated = true
	self.duration = duration or 5
	self.startTime = CurTime()
end

function BandCircle.Create(pos, ang, color, size, duration)
	local bc = BandCircle.new(pos, ang, color, size)
	if duration and duration > 0 then
		bc:SetAnimated(duration)
	end
	if MagicCircleManager and MagicCircleManager.Add then
		MagicCircleManager:Add(bc)
	end
	return bc
end

-- Console commands for testing
concommand.Add("magic_circle_test", function(ply, cmd, args)
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

concommand.Add("magic_circle_clear", function(ply, cmd, args)
	MagicCircleManager:Clear()
	if IsValid(ply) then
		print("All magic circles cleared!")
	end
end)

-- Simple console helper to preview band circles
concommand.Add("band_circle_test", function(ply, cmd, args)
	if not IsValid(ply) then return end
	local tr = ply:GetEyeTrace()
	local pos = tr.HitPos + tr.HitNormal * 8
	local ang = Angle(0, 0, 0)
	ang:RotateAroundAxis(tr.HitNormal:Angle():Right(), 0)
	local bc = BandCircle.Create(pos, tr.HitNormal:Angle(), Color(100, 200, 255, 255), tonumber(args[1]) or 80, tonumber(args[2]) or 8)
	if bc then
		-- Add a few bands spinning on different axes
		bc:AddBand(tonumber(args[3]) or 60, tonumber(args[4]) or 4, {p = 0, y = 35, r = 0}, 2)
		bc:AddBand((tonumber(args[3]) or 60) * 0.8, (tonumber(args[4]) or 4) * 0.8, {p = 25, y = -20, r = 0}, 2)
		bc:AddBand((tonumber(args[3]) or 60) * 1.1, (tonumber(args[4]) or 4) * 0.6, {p = 0, y = 0, r = 45}, 2)
		bc:AddBand((tonumber(args[3]) or 60) * 1.25, (tonumber(args[4]) or 4) * 0.6, {p = 0, y = 45, r = 45}, 2)
		bc:AddBand((tonumber(args[3]) or 60) * 1.9, (tonumber(args[4]) or 4) * 0.6, {p = -45, y = 0, r = 45}, 2)
	end
end)

-- Export the library
_G.MagicCircle = MagicCircle
_G.MagicCircleManager = MagicCircleManager
_G.BandCircle = BandCircle

return MagicCircle