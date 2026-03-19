-- Arcana MagicCircle class and lifecycle manager.
-- Depends on Arcana.Circle.Ring (from circles/ring.lua).
-- Exports: Arcana.Circle.MagicCircle, Arcana.Circle.MagicCircleManager

Arcana = Arcana or {}
Arcana.Circle = Arcana.Circle or {}

local Ring = Arcana.Circle.Ring
local RING_TYPES = Arcana.Circle.RING_TYPES

local math_max = _G.math.max
local math_min = _G.math.min
local math_floor = _G.math.floor
local math_random = _G.math.random
local math_pi = _G.math.pi
local math_cos = _G.math.cos
local math_sin = _G.math.sin
local table_insert = _G.table.insert
local table_remove = _G.table.remove
local table_sort = _G.table.sort
local COLOR_WHITE = Color(255, 255, 255, 255)

local tempColorCache = Color(255, 255, 255, 255)
local function tempColor(r, g, b, a)
	tempColorCache.r = math.min(r, 255)
	tempColorCache.g = math.min(g, 255)
	tempColorCache.b = math.min(b, 255)
	tempColorCache.a = a

	return tempColorCache
end

local MagicCircle = {}
MagicCircle.__index = MagicCircle

function MagicCircle.new(pos, ang, color, intensity, size, lineWidth, seed)
	local circle = setmetatable({}, MagicCircle)
	-- Core properties
	circle.position = pos or Vector(0, 0, 0)
	circle.angles = ang or Angle(0, 0, 0)
	circle.color = color or Color(255, 100, 255, 255)
	circle.intensity = math_max(1, intensity or 3)
	circle.size = math_max(10, size or 100)
	circle.lineWidth = math_max(1, lineWidth or 2)
	circle.seed = seed
	-- Animation properties
	circle.isAnimated = false
	circle.startTime = CurTime()
	circle.duration = 0
	circle.isActive = true
	circle._drawnManually = false
	-- Fade-out state
	circle.isFading = false
	circle.fadeStart = 0
	circle.fadeDuration = 0.3
	-- Set to true on the first Draw call; used by StartEvolving to decide whether
	-- to preserve current ring visibility or start the ring-by-ring appearance animation
	circle._hasBeenDrawn = false
	-- When true, all rings are always drawn regardless of lastVisible (which only
	-- controls the staggered height animation, not visibility)
	circle._preserveVisibility = false
	-- Evolving-cast state
	circle.isEvolving = false
	circle.evolveStart = 0
	circle.evolveDuration = 0
	circle.baseVisible = 2
	circle.lastVisible = 0
	circle.kLog = 9 -- control for logarithmic growth
	circle.enableRingSounds = false
	-- Breakdown state
	circle.isBreaking = false
	-- Generate rings
	circle.rings = {}
	circle:GenerateRings()

	return circle
end

function MagicCircle:GenerateRings()
	self.rings = self.rings or {}

	if self.seed then
		math.randomseed(self.seed)
	end

	-- Calculate number of rings based on intensity
	local ringCount = math_max(4, math_min(self.intensity + math_random(1, 3), 8))

	-- Standard magic circles should NOT include band rings (reserved for VFX)
	local allTypes = {RING_TYPES.PATTERN_LINES, RING_TYPES.RUNE_STAR, RING_TYPES.SIMPLE_LINE, RING_TYPES.STAR_RING,}

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
		local pool = {RING_TYPES.PATTERN_LINES, RING_TYPES.RUNE_STAR, RING_TYPES.SIMPLE_LINE,}

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
	glowRing.lineWidth = self.lineWidth -- Apply the magic circle's line width
	table_insert(self.rings, glowRing)

	if self.seed then
		math.randomseed(SysTime())
	end
end

function MagicCircle:Update(deltaTime)
	if not self.isActive then return end

	-- Update all rings
	for _, ring in ipairs(self.rings) do
		ring:Update(deltaTime)
	end

	-- Cull rings removed by breakdown
	for i = #self.rings, 1, -1 do
		local r = self.rings[i]

		if r and r.removed then
			table_remove(self.rings, i)
		end
	end

	-- Check if animation should end (skip while breaking)
	if self.isAnimated and not self.isBreaking and (CurTime() - self.startTime) > self.duration and not self.isFading then
		self:StartFadeOut(self.fadeDuration)
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
					local posJitter = self.position + Vector(math.random(-2, 2), math.random(-2, 2), math.random(-1, 1))
					sound.Play("arcana/arcane_" .. math.random(1, 3) .. ".ogg", posJitter, 70, pitch, vol)
				end
			end

			self.lastVisible = shouldVisible
		end

		-- Move ring heights to create depth evolution
		for i, ring in ipairs(self.rings) do
			local target = 0

			if i > 2 and i <= self.lastVisible then
				local sign = self.evolveDirection or ((i % 2 == 0) and 1 or -1)
				local span = math.max(1, self.lastVisible - 2)
				local fraction = math.Clamp((i - 2) / span, 0, 1)
				-- Larger depth range proportional to circle size
				local depthAmplitude = self.size * 0.35
				target = sign * depthAmplitude * fraction * logp
			end

			ring.height = ring.height + (target - ring.height) * math.min(1, deltaTime * 6)
		end

		-- Handle fade-out completion
		if self.isFading then
			local t = (CurTime() - self.fadeStart) / math_max(0.01, self.fadeDuration)

			if t >= 1 then
				self:FinalizeDeactivate()
				self.isActive = false
			end
		end
	end
end

function MagicCircle:Draw()
	if not self.isActive then return end
	self._hasBeenDrawn = true
	render.SetColorMaterial()
	local currentTime = CurTime()
	-- Apply fade alpha if fading
	local fadeMul = 1

	if self.isFading then
		fadeMul = math_max(0, 1 - (currentTime - self.fadeStart) / math_max(0.01, self.fadeDuration))
	end

	-- Draw all rings
	local count = #self.rings
	-- _preserveVisibility: rings were already on screen when evolving started; keep them
	-- all visible while lastVisible still gates the staggered height animation
	local maxToDraw = (self.isEvolving and not self._preserveVisibility) and math.max(self.baseVisible, self.lastVisible) or count

	for i = 1, math.min(count, maxToDraw) do
		local ring = self.rings[i]
		local baseCol = self.color or COLOR_WHITE
		local a = math_floor((baseCol.a or 255) * fadeMul)
		if a > 0 then
			ring:Draw(self.position, self.angles, tempColor(baseCol.r, baseCol.g, baseCol.b, a), currentTime)
		end
	end
end

function MagicCircle:SetDrawnManually(b)
	self._drawnManually = b and true or false
end

function MagicCircle:IsDrawnManually()
	return self._drawnManually == true
end

function MagicCircle:SetAnimated(duration)
	self.isAnimated = true
	self.duration = duration or 5
	self.startTime = CurTime()
end

-- Trigger a breakdown animation: fling non-band rings outward with extra spin and sparks
function MagicCircle:StartBreakdown(duration)
	if self.isFading then return end -- don't conflict with fade
	self.isBreaking = true
	self.isAnimated = false
	self.isEvolving = false
	local d = math_max(0.1, tonumber(duration) or 0.6)
	local num = #self.rings
	local idx = 0

	for _, r in ipairs(self.rings) do
		idx = idx + 1

		if r and r.type ~= RING_TYPES.BAND_RING then
			r.breaking = true
			r.breakStart = CurTime()
			r.breakDuration = d * (0.7 + math_random() * 0.6)
			r.breakOffset = Vector(0, 0, 0)
			r.breakVelocity = Vector(0, 0, 0)
			r.breakSpinBoost = 360 + math_random() * 360
			-- Spread ejections: set per-ring delay and evenly distributed directions
			r.breakDelay = (idx - 1) * (d / math_max(1, num)) * 0.5
			local angle = ((idx - 1) / math_max(1, num)) * math_pi * 2 + math_random() * 0.35
			r.ejectDirXY = Vector(math_cos(angle), math_sin(angle), 0)
			r.breakRemoveDistance = self.size * 4
			-- slight vertical stagger for variety
			r.height = r.height + (math_random() * 2 - 1) * (self.size * 0.05)
			-- sound cue will play when ejection actually starts in Update
		end
	end

	-- Optional: schedule final cleanup if all rings gone
	timer.Simple(d + 0.2, function()
		if not self.isActive then return end

		if #self.rings <= 0 then
			-- No fade here; breakdown fully removes rings already
			self.isActive = false
			self:FinalizeDeactivate()
		end
	end)
end

-- Start evolving the circle over the given duration.
-- This progressively reveals rings (logarithmically) and animates their height (depth).
function MagicCircle:StartEvolving(duration, direction)
	self.isEvolving = true
	self.evolveStart = CurTime()
	self.evolveDuration = math.max(0.1, duration or 1)
	self.baseVisible = 2
	self.enableRingSounds = true

	-- Allow the caller to override the upOnly flag set at construction time
	if isnumber(direction) then
		self.evolveDirection = direction
	end

	-- If the circle has already been drawn (it was showing all rings in static mode),
	-- set _preserveVisibility so Draw always renders the full ring set. lastVisible
	-- still starts at 2 and grows normally, so the height animation is staggered
	-- ring-by-ring just like it is for freshly created circles — but no ring ever
	-- disappears because Draw ignores lastVisible for the visibility count.
	if self._hasBeenDrawn then
		self._preserveVisibility = true
	end
	self.lastVisible = 2

	-- Reset all ring heights to 0 so the staggered height animation starts from a
	-- clean baseline for every ring (including ones that were already on screen)
	for _, ring in ipairs(self.rings) do
		ring.height = 0
	end
end

function MagicCircle:IsActive()
	return self.isActive
end

function MagicCircle:Remove()
	-- Trigger a quick fade-out instead of instant disappearance
	self:StartFadeOut(self.fadeDuration)
end
MagicCircle.Destroy = MagicCircle.Remove

function MagicCircle:StartFadeOut(duration)
	if self.isFading then return end
	self.isFading = true
	self.fadeStart = CurTime()
	self.fadeDuration = math_max(0.05, duration or 0.3)
end

function MagicCircle:FinalizeDeactivate()
	-- Nil out ring list to release mesh references and encourage GC
	self.rings = {}
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

		if circle.Update then
			circle:Update(deltaTime)
		end

		if circle.IsActive and not circle:IsActive() then
			table_remove(self.circles, i)
		end
	end
end

function MagicCircleManager:Draw()
	for _, circle in ipairs(self.circles) do
		if circle.Draw then
			local manual = (circle.IsDrawnManually and circle:IsDrawnManually()) or false
			if not manual then
				circle:Draw()
			end
		end
	end
end

function MagicCircleManager:Clear()
	-- Trigger fade-out on all circles instead of instant removal
	for _, circle in ipairs(self.circles) do
		if circle and circle.StartFadeOut then
			circle:StartFadeOut(0.25)
		end
	end
end

-- Hook for automatic updates
hook.Add("Think", "MagicCircleManager_Update", function()
	MagicCircleManager:Update()
end)

hook.Add("PostDrawTranslucentRenderables", "MagicCircleManager_Draw", function(_, isSkybox)
	if isSkybox then return end

	--[[local bloom = Arcana.Circle.Bloom
	if bloom then
		render.PushRenderTarget(bloom.CIRCLE_RT)
		render.Clear(0, 0, 0, 0, true, false) -- colour only; depth is shared with the screen
		MagicCircleManager:Draw()
		render.PopRenderTarget()
	end]]

	MagicCircleManager:Draw()

	--[[if bloom and bloom.DoBloom then
		bloom.DoBloom()
	end]]
end)

-- Convenience functions (maintaining backward compatibility)
function MagicCircle.DrawMagicCircle(pos, ang, color, intensity, size, lineWidth)
	local circle = MagicCircle.new(pos, ang, color, intensity, size, lineWidth)
	circle:Draw()
end

function MagicCircle.CreateMagicCircle(pos, ang, color, intensity, size, duration, lineWidth, seed)
	local circle = MagicCircle.new(pos, ang, color, intensity, size, lineWidth, seed)
	circle:SetAnimated(duration or 5)
	MagicCircleManager:Add(circle)

	return circle
end

local function registerMagicCircleFonts()
	assert(Arcana.RUNIC_FONT, "[Arcana] circles.lua requires core.lua (Arcana.RUNIC_FONT) to be loaded first")
	surface.CreateFont("MagicCircle_Small",  { font = Arcana.RUNIC_FONT, size = 64,  weight = 500, antialias = true })
	surface.CreateFont("MagicCircle_Medium", { font = Arcana.RUNIC_FONT, size = 96,  weight = 600, antialias = true })
	surface.CreateFont("MagicCircle_Large",  { font = Arcana.RUNIC_FONT, size = 128, weight = 700, antialias = true })
	surface.CreateFont("MagicCircle_Rune",   { font = Arcana.RUNIC_FONT, size = 80,  weight = 800, antialias = true })
end

registerMagicCircleFonts()

-- Export
Arcana.Circle.MagicCircle = MagicCircle
Arcana.Circle.MagicCircleManager = MagicCircleManager