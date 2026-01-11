AddCSLuaFile()
ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "Brazier"
ENT.Category = "Arcana"
ENT.Spawnable = true
ENT.RenderGroup = RENDERGROUP_BOTH
ENT.Author = "Earu"

function ENT:SetupDataTables()
	self:NetworkVar("Float", 0, "FloatHeight")
	self:NetworkVar("Float", 1, "CircleSize")

	if SERVER then
		-- Random float height between 80 and 150 units
		self:SetFloatHeight(math.Rand(100, 250))
		self:SetCircleSize(40)
	end
end

if SERVER then
	function ENT:Initialize()
		-- Use the shell model inverted
		self:SetModel("models/hunter/misc/shell2x2a.mdl")
		self:SetMaterial("arcana/pattern_antique_stone")

		self:PhysicsInit(SOLID_VPHYSICS)
		self:SetMoveType(MOVETYPE_VPHYSICS)
		self:SetSolid(SOLID_VPHYSICS)

		local phys = self:GetPhysicsObject()
		if IsValid(phys) then
			phys:Wake()
			phys:EnableMotion(false)
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

	function ENT:SpawnFunction(ply, tr, className)
		if not tr or not tr.Hit then return end

		local pos = tr.HitPos + tr.HitNormal * 100
		local ent = ents.Create(classname or "arcana_brazier")
		if not IsValid(ent) then return end

		ent:SetPos(pos + Vector(0, 0, 100))
		ent:SetAngles(Angle(0, ply:EyeAngles().y, 0))
		ent:Spawn()
		ent:Activate()

		return ent
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

	function ENT:Initialize()
		self._circle = nil
		self._emitter = ParticleEmitter(self:GetPos(), false)
		self._nextMagicParticle = 0
		self._nextEmber = 0
	end

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
		})

		if not tr.Hit then return end

		-- Position circle on the ground surface
		local pos = tr.HitPos + tr.HitNormal * 2

		-- Align circle with ground surface
		local ang = tr.HitNormal:Angle()
		ang:RotateAroundAxis(ang:Right(), 90)

		-- Fire magic color for levitation (orange/red)
		local circleColor = Color(255, 140, 50, 220)
		local size = 70
		local intensity = 5

		self._circle = MagicCircle.new(pos, ang, circleColor, intensity, size, 2.5)
		if self._circle then
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

			-- Fire magic colors (orange/red/yellow)
			local colorChoice = math.random(1, 3)
			if colorChoice == 1 then
				p:SetColor(255, 160, 50) -- Orange
			elseif colorChoice == 2 then
				p:SetColor(255, 100, 30) -- Red-orange
			else
				p:SetColor(255, 200, 80) -- Yellow
			end
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

			-- Intense fire colors
			local colorChoice = math.random(1, 4)
			if colorChoice == 1 then
				p:SetColor(255, 180, 50) -- Orange
			elseif colorChoice == 2 then
				p:SetColor(255, 240, 100) -- Bright yellow
			elseif colorChoice == 3 then
				p:SetColor(255, 100, 20) -- Deep red-orange
			else
				p:SetColor(255, 200, 80) -- Golden fire
			end
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

		-- Massive fire glow from inside brazier
		local pulse = 0.7 + 0.3 * math.sin(t * 2.5)
		local glowSize = 140 + 60 * pulse -- Much larger

		render.SetMaterial(glowMat)
		-- Outer orange fire glow
		render.DrawSprite(center, glowSize, glowSize, Color(255, 160, 60, 220 * pulse))
		-- Mid yellow-orange glow
		render.DrawSprite(center, glowSize * 0.7, glowSize * 0.7, Color(255, 200, 80, 200 * pulse))
		-- Inner bright yellow core
		render.DrawSprite(center, glowSize * 0.4, glowSize * 0.4, Color(255, 240, 140, 240 * pulse))

		-- Fire magic levitation glow from below (on ground)
		local tr = util.TraceLine({
			start = center,
			endpos = center - Vector(0, 0, 2000),
			mask = MASK_SOLID,
			filter = self,
		})

		if tr.Hit then
			local magicPos = tr.HitPos + tr.HitNormal * 5
			local magicPulse = 0.6 + 0.4 * math.sin(t * 2.2)
			local magicSize = 140 + 50 * magicPulse

			render.DrawSprite(magicPos, magicSize, magicSize, Color(255, 140, 50, 150 * magicPulse))
		end

		-- Dynamic light (intense fire from above)
		local dl = DynamicLight(self:EntIndex())
		if dl then
			dl.pos = center
			dl.r = 255
			dl.g = 180
			dl.b = 60
			dl.brightness = 6 + pulse * 3
			dl.Decay = 400
			dl.Size = 400 -- Much larger light
			dl.DieTime = t + 0.1
		end

		-- Secondary light for fire levitation magic (below on ground)
		if tr.Hit then
			local dl2 = DynamicLight(self:EntIndex() + 1)
			if dl2 then
				local magicPulse = 0.6 + 0.4 * math.sin(t * 2.2)
				dl2.pos = tr.HitPos + tr.HitNormal * 5
				dl2.r = 255
				dl2.g = 140
				dl2.b = 50
				dl2.brightness = 3 + magicPulse * 2
				dl2.Decay = 300
				dl2.Size = 280
				dl2.DieTime = t + 0.1
			end
		end
	end
end
