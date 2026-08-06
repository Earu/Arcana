AddCSLuaFile()
ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "Brazier"
ENT.Category = "Arcana"
ENT.Spawnable = true
ENT.RenderGroup = RENDERGROUP_BOTH
ENT.Author = "Earu"

-- Ground traces stop on world/props but pass through players and NPCs
local GROUND_COLLISION_GROUP = COLLISION_GROUP_WEAPON

-- Ranges for the player-adjustable properties (see the properties block at the bottom)
ENT.DefaultFlameColor = Color(255, 160, 50)
ENT.MinFloatHeight = 0
ENT.MaxFloatHeight = 600
ENT.MaxLightScale = 3

-- Offered in the context menu, and one is picked at random when a player spawns
-- one so a row of braziers is not a row of identical fires.
ENT.ColorPresets = {
	{name = "Ember", color = Color(255, 160, 50)},
	{name = "Crimson", color = Color(255, 70, 45)},
	{name = "Gold", color = Color(255, 210, 95)},
	{name = "Witchfire", color = Color(140, 255, 90)},
	{name = "Emerald", color = Color(90, 255, 150)},
	{name = "Azure", color = Color(80, 170, 255)},
	{name = "Frost", color = Color(160, 230, 255)},
	{name = "Violet", color = Color(180, 110, 255)},
	{name = "Bone", color = Color(235, 230, 205)},
}

-- The flame color travels as a packed 24bit int: networked vectors lose too much
-- precision on 0-1 components to round-trip a color cleanly.
function ENT:SetFlameColor(col)
	self:SetFlameColorPacked(Arcana.Common.PackColor(col))
end

function ENT:GetFlameColor()
	return Arcana.Common.UnpackColor(self:GetFlameColorPacked())
end

function ENT:SetupDataTables()
	self:NetworkVar("Float", 0, "FloatHeight")
	self:NetworkVar("Float", 1, "CircleSize")
	self:NetworkVar("Float", 2, "LightScale")
	self:NetworkVar("Int", 0, "FlameColorPacked")

	if SERVER then
		-- Random float height between 100 and 250 units
		self:SetFloatHeight(math.Rand(100, 250))
		self:SetCircleSize(40)
		self:SetLightScale(1)
		self:SetFlameColor(self.DefaultFlameColor)
	end
end

if SERVER then
	resource.AddFile("materials/entities/arcana_brazier.png")

	function ENT:Initialize()
		-- Use the shell model inverted
		self:SetModel("models/hunter/misc/shell2x2a.mdl")
		self:SetMaterial("arcana/pattern_antique_stone")

		self:PhysicsInit(SOLID_VPHYSICS)
		self:SetMoveType(MOVETYPE_VPHYSICS)
		self:SetSolid(SOLID_VPHYSICS)

		-- Motion stays enabled: the brazier hovers, and PhysicsSimulate below drives it with
		-- ComputeShadowControl. Freezing the physics object here leaves it sitting on the
		-- ground with the motion controller unable to move it.
		local phys = self:GetPhysicsObject()
		if IsValid(phys) then
			phys:Wake()
		end

		-- Start motion controller for floating
		self:StartMotionController()
		self.ShadowParams = {}

		-- Initialize rotation angle
		self._rotationAngle = 0

		-- Initialize fire effect timer
		self._nextFireEffect = 0

		-- Start looping fire sound
		self._fireSound = CreateSound(self, "ambient/fire/fire_med_loop1.wav")
		if self._fireSound then
			self._fireSound:Play()
			self._fireSound:SetSoundLevel(65)
		end
	end

	local TRACE_OFFSET = Vector(0, 0, 1000)
	local VECTOR_UP = Vector(0, 0, 1)

	function ENT:PhysicsSimulate(phys, deltatime)
		if not IsValid(phys) then return end

		phys:Wake()

		-- Trace down to find ground
		local currentPos = self.PositionOverride or self:GetPos()
		local tr = util.TraceLine({
			start = currentPos,
			endpos = currentPos - TRACE_OFFSET,
			mask = MASK_SOLID,
			filter = self,
			collisiongroup = GROUND_COLLISION_GROUP,
		})

		-- Calculate target position from ground with gentle bobbing
		local bobOffset = math.sin(CurTime() * 0.8) * 8 + math.cos(CurTime() * 0.5) * 4
		local floatPos = tr.HitPos + (self:GetFloatHeight() + bobOffset) * VECTOR_UP

		-- Add extremely slow rotation
		self._rotationAngle = (self._rotationAngle + deltatime * 3) % 360
		local targetAng = Angle(180, self._rotationAngle, 0)

		-- Set shadow parameters for smooth floating
		self.ShadowParams.secondstoarrive = 0.15
		self.ShadowParams.pos = floatPos
		self.ShadowParams.angle = targetAng
		self.ShadowParams.maxangular = 3000
		self.ShadowParams.maxangulardamp = 8000
		self.ShadowParams.maxspeed = 100000
		self.ShadowParams.maxspeeddamp = 10000
		self.ShadowParams.dampfactor = 0.8
		self.ShadowParams.teleportdistance = 0
		self.ShadowParams.delta = deltatime

		phys:ComputeShadowControl(self.ShadowParams)
	end

	function ENT:SpawnFunction(ply, tr, classname)
		if not tr or not tr.Hit then return end

		local pos = tr.HitPos + tr.HitNormal * 4
		local ent = ents.Create(classname or "arcana_brazier")
		if not IsValid(ent) then return end

		-- Spawn at ground level, will float up
		ent:SetPos(pos)
		ent:SetAngles(Angle(180, ply:EyeAngles().y, 0))
		ent:Spawn()
		ent:Activate()

		-- Player-spawned braziers come in a random preset color; ones created in
		-- code keep the default
		local preset = ent.ColorPresets[math.random(#ent.ColorPresets)]
		ent:SetFlameColor(preset.color)

		return ent
	end

	function ENT:Think()
		local now = CurTime()

		-- Create fire effects periodically
		if not self._nextFireEffect or now >= self._nextFireEffect then
			self:CreateFireEffect()
			self._nextFireEffect = now + 0.1
		end

		self:NextThink(now + 0.05)
		return true
	end

	function ENT:CreateFireEffect()
		local center = self:GetPos()
		local offset = VectorRand() * 15
		offset.z = math.abs(offset.z) + 10

		local ed = EffectData()
		ed:SetOrigin(center + offset)
		ed:SetMagnitude(2)
		ed:SetScale(math.Rand(0.5, 1.2))
		ed:SetRadius(2)
		util.Effect("fire_embers", ed)
	end

	function ENT:OnRemove()
		-- Stop the looping fire sound cleanly
		if self._fireSound then
			self._fireSound:Stop()
			self._fireSound = nil
		end
	end
end

if CLIENT then
	-- Magical glow material
	local glowMat = Material("sprites/light_glow02_add")

	-- Create global material with scaled texture (4x larger) - shared by all braziers
	local BRAZIER_MATERIAL_NAME = "arcana_brazier_scaled_" .. FrameNumber()
	local BRAZIER_MATERIAL = CreateMaterial(BRAZIER_MATERIAL_NAME, "VertexLitGeneric", {
		["$basetexture"] = "arcana/pattern_antique_stone",
		["$basetexturetransform"] = "center 0 0 scale 0.25 0.25 rotate 0 translate 0 0",
		["$model"] = 1,
	})

	-- Every flame tone is derived from the networked base color so a recolored
	-- brazier keeps the same hot-core/deep-ember relationship the default had.
	local function shade(col, hueShift, satMul, valMul)
		local h, s, v = ColorToHSV(col)

		return HSVToColor((h + hueShift) % 360, math.Clamp(s * satMul, 0, 1), math.Clamp(v * valMul, 0, 1))
	end

	function ENT:GetPalette()
		local packed = self:GetFlameColorPacked()
		local pal = self._palette
		if pal and pal.packed == packed then return pal end

		local base = self:GetFlameColor()
		pal = {
			packed = packed,
			base = base,
			-- Shifts chosen so a default-orange brazier reproduces the original
			-- hardcoded fire tones (deep 255,100,20 / gold 255,200,80 / bright
			-- 255,240,100 / core 255,240,140) to within a few units.
			deep = shade(base, -6, 1.15, 1), -- ember tones at the edges
			gold = shade(base, 15, 0.85, 1),
			bright = shade(base, 22, 0.76, 1),
			core = shade(base, 18, 0.56, 1), -- near white-hot center
		}
		self._palette = pal

		if self._circle then
			self._circle.color = Color(base.r, base.g, base.b, 220)
		end

		return pal
	end

	function ENT:Initialize()
		self._circle = nil
		self._emitter = ParticleEmitter(self:GetPos(), false)
		self._nextMagicParticle = 0
		self._nextEmber = 0

		-- Set large render bounds to account for:
		-- - Dynamic lights (up to 400 unit radius)
		-- - Fire particles rising high above
		-- - Magic circle potentially far below
		self:SetRenderBounds(Vector(-450, -450, -300), Vector(450, 450, 500))
	end

	local MagicCircle = Arcana.Circle.MagicCircle
	local MagicCircleManager = Arcana.Circle.MagicCircleManager

	-- Create magic circle on ground underneath showing fire levitation
	function ENT:CreateLevitationCircle()
		if not MagicCircle or not MagicCircle.new then return end
		if self._circle and self._circle.IsActive and self._circle:IsActive() then return end

		-- Trace down to ground to get proper position and normal
		local center = self:GetPos()
		local tr = util.TraceLine({
			start = center,
			endpos = center - Vector(0, 0, 2000),
			mask = MASK_SOLID,
			filter = self,
			collisiongroup = GROUND_COLLISION_GROUP,
		})

		if not tr.Hit then return end

		-- Position circle on the ground surface
		local pos = tr.HitPos + tr.HitNormal * 2

		-- Align circle with ground surface
		local ang = tr.HitNormal:Angle()
		ang:RotateAroundAxis(ang:Right(), 90)

		-- Levitation circle takes the flame color
		local base = self:GetPalette().base
		local circleColor = Color(base.r, base.g, base.b, 220)
		local size = 70
		local intensity = 5

		self._circle = MagicCircle.new(pos, ang, circleColor, intensity, size, 2.5)
		if self._circle then
			self._circle:SetReferenceEntity(self)
			MagicCircleManager:Add(self._circle)
		end
	end

	function ENT:OnRemove()
		-- Clean up magic circle
		if self._circle and self._circle.Destroy then
			self._circle:Destroy()
		end
		self._circle = nil

		-- Clean up particle emitter
		if self._emitter then
			self._emitter:Finish()
			self._emitter = nil
		end
	end

	function ENT:Think()
		local now = CurTime()

		-- Ensure levitation circle exists below
		self:CreateLevitationCircle()

		-- Update circle position to stay on ground below brazier
		if self._circle and self._circle.IsActive and self._circle:IsActive() then
			local center = self:GetPos()
			local tr = util.TraceLine({
				start = center,
				endpos = center - Vector(0, 0, 2000),
				mask = MASK_SOLID,
				filter = self,
				collisiongroup = GROUND_COLLISION_GROUP,
			})

			if tr.Hit then
				self._circle.position = tr.HitPos + tr.HitNormal * 2
				local ang = tr.HitNormal:Angle()
				ang:RotateAroundAxis(ang:Right(), 90)
				self._circle.angles = ang
			end
		end

		-- Spawn fire levitation particles from below
		if now >= self._nextMagicParticle then
			self:SpawnLevitationParticle()
			self:SpawnLevitationParticle() -- Extra particles
			self._nextMagicParticle = now + 0.08
		end

		-- Spawn massive fire from inside the brazier
		if now >= self._nextEmber then
			self:SpawnFireParticle()
			self:SpawnFireParticle()
			self:SpawnFireParticle() -- Triple the fire
			self._nextEmber = now + 0.015
		end

		self:SetNextClientThink(now + 0.02)
		return true
	end

	-- Fire magic particles rising from below showing levitation force
	function ENT:SpawnLevitationParticle()
		if not self._emitter then return end

		local center = self:GetPos()
		local floatHeight = self:GetFloatHeight()

		-- Spawn from below, around the magic circle area
		local radius = 60
		local angle = math.Rand(0, math.pi * 2)
		local r = math.Rand(radius * 0.2, radius)

		local pos = center + Vector(
			math.cos(angle) * r,
			math.sin(angle) * r,
			-floatHeight * 0.8 -- Start from below
		)

		local p = self._emitter:Add("sprites/light_glow02_add", pos)
		if p then
			p:SetStartAlpha(220)
			p:SetEndAlpha(0)
			p:SetStartSize(math.Rand(4, 9))
			p:SetEndSize(0)
			p:SetDieTime(math.Rand(1.5, 2.5))

			-- Rise up toward the brazier with some spiral motion
			local vel = Vector(0, 0, math.Rand(60, 100))
			vel.x = math.Rand(-15, 15)
			vel.y = math.Rand(-15, 15)
			p:SetVelocity(vel)

			p:SetAirResistance(25)
			p:SetGravity(Vector(0, 0, 0))
			p:SetRoll(math.Rand(-180, 180))
			p:SetRollDelta(math.Rand(-2, 2))

			-- Flame tones: base, deep ember, bright tip
			local pal = self:GetPalette()
			local colorChoice = math.random(1, 3)
			local col = colorChoice == 1 and pal.base or colorChoice == 2 and pal.deep or pal.bright
			p:SetColor(col.r, col.g, col.b)
		end
	end

	-- Massive fire particles from inside the brazier
	function ENT:SpawnFireParticle()
		if not self._emitter then return end

		local center = self:GetPos()
		local offset = VectorRand() * 25
		offset.z = math.Rand(-12, 5) -- Inside and above the bowl

		local p = self._emitter:Add("effects/fire_cloud" .. math.random(1, 2), center + offset)
		if p then
			p:SetStartAlpha(255)
			p:SetEndAlpha(0)
			p:SetStartSize(math.Rand(20, 40)) -- Much larger
			p:SetEndSize(math.Rand(5, 12))
			p:SetDieTime(math.Rand(1.2, 2.5)) -- Longer life

			-- Vigorous rise from intense fire
			local vel = VectorRand() * 25
			vel.z = math.Rand(80, 160)
			p:SetVelocity(vel)

			p:SetAirResistance(40)
			p:SetGravity(Vector(0, 0, 15))
			p:SetRoll(math.Rand(-180, 180))
			p:SetRollDelta(math.Rand(-8, 8))

			-- Intense fire colors, all pulled from the flame palette
			local pal = self:GetPalette()
			local colorChoice = math.random(1, 4)
			local col = colorChoice == 1 and pal.base or colorChoice == 2 and pal.bright or colorChoice == 3 and pal.deep or pal.gold
			p:SetColor(col.r, col.g, col.b)
		end
	end

	function ENT:Draw()
		-- Draw the brazier model with scaled material
		render.MaterialOverride(BRAZIER_MATERIAL)
		self:DrawModel()
		render.MaterialOverride()
	end

	function ENT:DrawTranslucent()
		local center = self:GetPos()
		local t = CurTime()
		local pal = self:GetPalette()

		-- Massive fire glow from inside brazier
		local pulse = 0.7 + 0.3 * math.sin(t * 2.5)
		local glowSize = 140 + 60 * pulse -- Much larger

		render.SetMaterial(glowMat)
		-- Outer flame glow
		render.DrawSprite(center, glowSize, glowSize, Color(pal.base.r, pal.base.g, pal.base.b, 220 * pulse))
		-- Mid glow
		render.DrawSprite(center, glowSize * 0.7, glowSize * 0.7, Color(pal.gold.r, pal.gold.g, pal.gold.b, 200 * pulse))
		-- Inner hot core
		render.DrawSprite(center, glowSize * 0.4, glowSize * 0.4, Color(pal.core.r, pal.core.g, pal.core.b, 240 * pulse))

		-- Fire magic levitation glow from below (on ground)
		local tr = util.TraceLine({
			start = center,
			endpos = center - Vector(0, 0, 2000),
			mask = MASK_SOLID,
			filter = self,
			collisiongroup = GROUND_COLLISION_GROUP,
		})

		if tr.Hit then
			local magicPos = tr.HitPos + tr.HitNormal * 5
			local magicPulse = 0.6 + 0.4 * math.sin(t * 2.2)
			local magicSize = 140 + 50 * magicPulse

			render.DrawSprite(magicPos, magicSize, magicSize, Color(pal.base.r, pal.base.g, pal.base.b, 150 * magicPulse))
		end

		-- Light output is player-adjustable; 0 means the brazier lights nothing
		local lightScale = math.Clamp(self:GetLightScale(), 0, self.MaxLightScale)
		if lightScale <= 0 then return end

		local sizeScale = 0.6 + 0.4 * lightScale

		-- Both lights are steady: no decay (they are re-created every frame, so any
		-- decay ramps down and snaps back as a fast flicker) and no sine pulse on
		-- brightness. The glow sprites above still breathe, so the fire keeps its
		-- life without the light it casts wobbling.
		local dl = DynamicLight(self:EntIndex())
		if dl then
			dl.pos = center
			dl.r = pal.gold.r
			dl.g = pal.gold.g
			dl.b = pal.gold.b
			dl.brightness = 7.5 * lightScale
			dl.Decay = 0
			dl.Size = 400 * sizeScale -- Much larger light
			dl.DieTime = t + 0.1
		end

		-- Secondary light for fire levitation magic (below on ground)
		if tr.Hit then
			local dl2 = DynamicLight(self:EntIndex() + 1)
			if dl2 then
				dl2.pos = tr.HitPos + tr.HitNormal * 5
				dl2.r = pal.base.r
				dl2.g = pal.base.g
				dl2.b = pal.base.b
				dl2.brightness = 4 * lightScale
				dl2.Decay = 0
				dl2.Size = 280 * sizeScale
				dl2.DieTime = t + 0.1
			end
		end
	end
end

-- Context-menu properties (see arcana/common/entity_properties.lua). That file and
-- this one can load in either order, so register now if it is already there and
-- otherwise wait for it to announce itself.
-- Read off ENT here rather than inside the function: registration can be deferred
-- to the hook, by which point the ENT global belongs to whatever entity file the
-- loader reached next.
local COLOR_PRESETS = ENT.ColorPresets
local MIN_FLOAT_HEIGHT = ENT.MinFloatHeight
local MAX_FLOAT_HEIGHT = ENT.MaxFloatHeight
local MAX_LIGHT_SCALE = ENT.MaxLightScale

local function registerProperties()
	Arcana.Common.AddColorProperty("arcana_brazier_flame_color", {
		class = "arcana_brazier",
		label = "Flame Color",
		title = "Flame Color",
		order = 900,
		icon = "icon16/paintcan.png",
		presets = COLOR_PRESETS,
		get = function(ent) return ent:GetFlameColor() end,
		set = function(ent, col) ent:SetFlameColor(col) end,
	})

	Arcana.Common.AddScalarProperty("arcana_brazier_float_height", {
		class = "arcana_brazier",
		label = "Float Height",
		sliderLabel = "Units",
		order = 901,
		icon = "icon16/arrow_up.png",
		min = MIN_FLOAT_HEIGHT,
		max = MAX_FLOAT_HEIGHT,
		decimals = 0,
		presets = {
			{name = "Resting", value = 20},
			{name = "Low", value = 80},
			{name = "Standard", value = 150},
			{name = "High", value = 280},
			{name = "Soaring", value = 450},
		},
		get = function(ent) return ent:GetFloatHeight() end,
		set = function(ent, value) ent:SetFloatHeight(value) end,
	})

	Arcana.Common.AddScalarProperty("arcana_brazier_light", {
		class = "arcana_brazier",
		label = "Light Output",
		sliderLabel = "Intensity",
		order = 902,
		icon = "icon16/lightbulb.png",
		min = 0,
		max = MAX_LIGHT_SCALE,
		decimals = 1,
		presets = {
			{name = "Off", value = 0},
			{name = "Dim", value = 0.4},
			{name = "Normal", value = 1},
			{name = "Bright", value = 1.8},
		},
		get = function(ent) return ent:GetLightScale() end,
		set = function(ent, value) ent:SetLightScale(value) end,
	})
end

if Arcana.Common.AddColorProperty then
	registerProperties()
else
	hook.Add("Arcana_EntityPropertiesReady", "arcana_brazier_properties", registerProperties)
end
