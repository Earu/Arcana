-- Arcana BandCircle - enchantment/VFX-oriented ring container.
-- Depends on Arcana.Circle.Ring and Arcana.Circle.MagicCircleManager (for lifecycle).
-- Exports: Arcana.Circle.BandCircle

Arcana = Arcana or {}
Arcana.Circle = Arcana.Circle or {}

local Ring = Arcana.Circle.Ring
local RING_TYPES = Arcana.Circle.RING_TYPES
local MagicCircleManager = Arcana.Circle.MagicCircleManager

local math_max = _G.math.max
local math_floor = _G.math.floor
local table_insert = _G.table.insert
local table_sort = _G.table.sort
local COLOR_WHITE = Color(255, 255, 255, 255)

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
	bc._drawnManually = false
	bc.isAnimated = false
	bc.startTime = CurTime()
	bc.duration = 0
	-- Fade-out state
	bc.isFading = false
	bc.fadeStart = 0
	bc.fadeDuration = 0.3

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

-- Smoothly animate all band rings' scale similar to Entity:SetModelScale(scale, deltaTime)
-- If duration is 0 or nil, the scale is applied immediately.
function BandCircle:SetScale(scale, duration)
	scale = tonumber(scale) or 1
	duration = tonumber(duration) or 0

	for _, r in ipairs(self.rings) do
		if r and r.type == RING_TYPES.BAND_RING then
			r.scaleFrom = r.currentScale or 1
			r.scaleTarget = scale
			r.scaleStart = CurTime()
			r.scaleDuration = math_max(0, duration)

			if duration <= 0 then
				r.currentScale = scale
				r.scaleDuration = 0
			end
		end
	end
end

function BandCircle:Update(dt)
	for _, r in ipairs(self.rings) do
		r:Update(dt)
	end

	if self.isAnimated and (CurTime() - self.startTime) > (self.duration or 0) and not self.isFading then
		self:StartFadeOut(self.fadeDuration)
	end

	if self.isFading then
		local t = (CurTime() - self.fadeStart) / math_max(0.01, self.fadeDuration)

		if t >= 1 then
			self.isActive = false
		end
	end
end

function BandCircle:Draw()
	if not self.isActive then return end
	render.SetColorMaterial()
	local t = CurTime()
	local fadeMul = 1

	if self.isFading then
		fadeMul = math_max(0, 1 - (t - self.fadeStart) / math_max(0.01, self.fadeDuration))
	end

	-- Stable back-to-front ordering by radius for translucent blending
	local ordered = {}

	for i = 1, #self.rings do
		ordered[i] = self.rings[i]
	end

	table_sort(ordered, function(a, b) return (a.radius or 0) > (b.radius or 0) end)

	for _, r in ipairs(ordered) do
		local baseCol = self.color or COLOR_WHITE
		local a = math_floor((baseCol.a or 255) * fadeMul)

		if a > 0 then
			r:Draw(self.position, self.angles, Color(baseCol.r, baseCol.g, baseCol.b, a), t)
		end
	end
end

function BandCircle:SetDrawnManually(b)
	self._drawnManually = b and true or false
end

function BandCircle:IsDrawnManually()
	return self._drawnManually == true
end

function BandCircle:IsActive()
	return self.isActive
end

function BandCircle:Remove()
	self:StartFadeOut(self.fadeDuration)
end
BandCircle.Destroy = BandCircle.Remove

function BandCircle:StartFadeOut(duration)
	if self.isFading then return end
	self.isFading = true
	self.fadeStart = CurTime()
	self.fadeDuration = math_max(0.05, duration or 0.3)
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

-- Export
Arcana.Circle.BandCircle = BandCircle