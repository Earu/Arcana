AddCSLuaFile()
ENT.Type = "anim"
ENT.Base = "base_gmodentity"
ENT.PrintName = "Blackhole"
ENT.Author = "Earu"
ENT.Spawnable = false
ENT.AdminOnly = false
ENT.Category = "Arcana"

-- Server-side initialization
function ENT:Initialize()
	if SERVER then
		self:SetModel("models/props_junk/watermelon01.mdl") -- Base model, will be invisible
		self:PhysicsInit(SOLID_VPHYSICS)
		self:SetMoveType(MOVETYPE_VPHYSICS)
		self:SetSolid(SOLID_VPHYSICS)
		self:SetRenderMode(RENDERMODE_TRANSALPHA)

		local phys = self:GetPhysicsObject()
		if IsValid(phys) then
			phys:EnableMotion(false) -- Make it static
			phys:EnableCollisions(false)
			phys:EnableGravity(false)
			phys:SetMass(0)
			phys:Wake()
		end

		-- Setup initial properties
		self:SetNWFloat("Radius", 2000) -- Effective radius
		self:SetNWFloat("Force", 1500) -- Pulling force
		-- Start the pull effect
		self.NextPull = 0

		self.PreviousCollisionGroups = {}
	end
end

-- Pull nearby entities toward the black hole
function ENT:Think()
	if SERVER then
		if CurTime() > self.NextPull then
			self.NextPull = CurTime() + 0.1 -- Pull every 0.1 seconds
			local radius = self:GetNWFloat("Radius")
			local force = self:GetNWFloat("Force")
			local pos = self:GetPos()

			-- Find all entities within radius
			for _, ent in pairs(ents.FindInSphere(pos, radius)) do
				if IsValid(ent) and ent ~= self and not ent:CreatedByMap() then
					local physObj = ent:GetPhysicsObject()
					local entPos = ent:GetPos()
					local direction = (pos - entPos):GetNormalized()
					local distance = pos:Distance(entPos)
					local pullStrength = math.Clamp((1 - distance / radius) * force, 0, force)

					-- Apply force to physics objects
					if IsValid(physObj) then
						physObj:ApplyForceCenter(direction * pullStrength * physObj:GetMass())

						if not ent:IsPlayer() and ent:GetClass():match("^prop%_") and physObj:IsMotionEnabled() then
							if not ent:GetCollisionGroup() ~= COLLISION_GROUP_DEBRIS and not ent.ArcanaBlackhole then
								self.PreviousCollisionGroups[ent] = ent:GetCollisionGroup()
								ent:SetCollisionGroup(COLLISION_GROUP_DEBRIS)
								ent.ArcanaBlackhole = true
							end
						end
					end

					-- For players and NPCs
					if ent:IsPlayer() or ent:IsNPC() or ent:IsNextBot() then
						local velocity = direction * pullStrength * 0.5
						ent:SetVelocity(velocity)
						ent:SetGroundEntity(NULL)
					end

					-- Scaled damage based on distance from center
					if (ent:IsPlayer() or ent:IsNPC() or ent:IsNextBot()) and distance < 400 then
						-- Damage scales from 120/tick at center to 20% at edge (400 units)
						local distanceFactor = math.Clamp(1 - (distance / 400), 0, 1)
						local tickDamage = 120 * (0.2 + 0.8 * distanceFactor)

						local dmg = DamageInfo()
						dmg:SetDamage(tickDamage)
						dmg:SetDamageType(DMG_DISSOLVE)
						dmg:SetAttacker(self.CPPIGetOwner and IsValid(self:CPPIGetOwner()) and self:CPPIGetOwner() or self)
						dmg:SetInflictor(self)
						ent:TakeDamageInfo(dmg)
					end
				end
			end
		end

		self:NextThink(CurTime())

		return true
	end
end

function ENT:OnRemove()
	if SERVER then
		-- Network explosion to clients
		net.Start("Arcana_BlackholeExplode", true)
		net.WriteVector(self:GetPos())
		net.Broadcast()

		-- Explosion sounds
		sound.Play("ambient/explosions/explode_" .. math.random(1, 3) .. ".wav", self:GetPos(), 100, 70)
		sound.Play("ambient/levels/labs/electric_explosion" .. math.random(1, 5) .. ".wav", self:GetPos(), 100, 90)
		sound.Play("ambient/atmosphere/thunder" .. math.random(1, 4) .. ".wav", self:GetPos(), 95, 110)

		-- Screen shake
		util.ScreenShake(self:GetPos(), 15, 150, 1.0, 2000)

		local grps = table.Copy(self.PreviousCollisionGroups)
		timer.Simple(1, function() -- give time to entities to be pulled apart
			for ent, group in pairs(grps) do
				if IsValid(ent) then
					ent:SetCollisionGroup(group)
					ent.ArcanaBlackhole = nil
				end
			end
		end)
	end

	if CLIENT then
		if self.Emitter then
			self.Emitter:Finish()
		end
		self:StopSound("ambient/atmosphere/tone_quiet.wav")
	end
end

if SERVER then
	util.AddNetworkString("Arcana_BlackholeExplode")
end

-- Client-side rendering
if CLIENT then
	local matGlow = Material("sprites/light_glow02_add")
	local matBeam = Material("effects/laser1")
	local matFlare = Material("effects/blueflare1")
	local matVortex = Material("effects/combinemuzzle2_dark")

	function ENT:Initialize()
		self.Emitter = ParticleEmitter(self:GetPos())
		self.NextParticle = 0
		self.Rotation = 0
		self.PulseTime = 0
		self.NextRumble = CurTime() + 2
		self.BirthTime = CurTime()
		self.GrowthScale = 0.5  -- Start small

		-- Ambient drone
		self:EmitSound("ambient/atmosphere/tone_quiet.wav", 75, 50)
	end

	function ENT:Think()
		if CurTime() > self.NextRumble then
			self.NextRumble = CurTime() + math.Rand(3, 6)
			self:EmitSound("ambient/levels/citadel/portal_close" .. math.random(1, 3) .. ".wav", 80, 80)
		end

		-- Grow over time (reaches full size at 20 seconds, max lifetime)
		local age = CurTime() - self.BirthTime
		self.GrowthScale = math.Clamp(0.5 + (age / 20) * 0.5, 0.5, 1.0)
	end

	function ENT:Draw()
		local pos = self:GetPos()
		local radius = self:GetNWFloat("Radius") * 0.15
		local dist = pos:Distance(EyePos())

		if dist > radius * 25 then return end

		-- Apply growth scale to visual size
		local coreRadius = radius * 0.4 * self.GrowthScale
		local diskRadius = radius * 2.5 * self.GrowthScale

		self.Rotation = (self.Rotation + FrameTime() * 30) % 360
		self.PulseTime = self.PulseTime + FrameTime()

		-- 1. Dark void core
		self:DrawVoidCore(pos, coreRadius)

		-- 2. Heavy gravitational distortion
		self:DrawDistortionRing(pos, coreRadius, diskRadius)

		-- 3. Energy arcs around the void
		self:DrawEnergyArcs(pos, coreRadius)

		-- 4. Particles being pulled in
		self:DrawParticles(pos, coreRadius, diskRadius)
	end

	-- Draw the dark void core with pulsing size
	function ENT:DrawVoidCore(pos, radius)
		-- Pulsing event horizon
		local sizePulse = math.sin(self.PulseTime * 1.5) * 0.1 + 1.0
		local pulsedRadius = radius * sizePulse

		-- Pure black sphere for event horizon
		render.SetColorMaterial()
		render.DrawSphere(pos, pulsedRadius, 30, 30, Color(0, 0, 0, 255))

		-- Intense purple/violet glow around the void
		render.SetMaterial(matGlow)
		local glowPulse = math.sin(self.PulseTime * 2.5) * 0.3 + 0.7

		-- Multiple layered glows for intensity
		render.DrawSprite(pos, pulsedRadius * 4 * glowPulse, pulsedRadius * 4 * glowPulse, Color(140, 60, 200, 200))
		render.DrawSprite(pos, pulsedRadius * 6 * glowPulse, pulsedRadius * 6 * glowPulse, Color(100, 40, 180, 140))
		render.DrawSprite(pos, pulsedRadius * 8 * glowPulse, pulsedRadius * 8 * glowPulse, Color(80, 30, 140, 80))
	end

	-- Draw heavy gravitational distortion
	function ENT:DrawDistortionRing(pos, coreRadius, diskRadius)
		render.SetMaterial(matGlow)

		-- Intense pulsing distortion waves (more layers)
		for i = 1, 8 do
			local ringRadius = coreRadius * (1.3 + i * 0.4)
			local pulse = math.sin(self.PulseTime * 3 - i * 0.5) * 0.4 + 0.6
			local alpha = (200 - i * 18) * pulse
			render.DrawSprite(pos, ringRadius * 2.5, ringRadius * 2.5, Color(120, 50, 180, alpha))
		end

		-- Warping lensing effect (rotating hotspots)
		render.SetMaterial(matFlare)
		for i = 1, 12 do
			local angle = math.rad(i * 30 + self.Rotation * 2.5)
			local distortRadius = coreRadius * (2.2 + math.sin(self.PulseTime * 2 + i) * 0.4)
			local ringPos = pos + Vector(math.cos(angle) * distortRadius, math.sin(angle) * distortRadius, math.sin(self.PulseTime * 1.5 + i) * 30)
			local pulseSize = coreRadius * 0.5 * (0.7 + 0.3 * math.sin(self.PulseTime * 4 + i))
			render.DrawSprite(ringPos, pulseSize, pulseSize, Color(160, 80, 220, 180))
		end

		-- Outer distortion field
		render.SetMaterial(matVortex)
		local outerPulse = math.sin(self.PulseTime * 1.8) * 0.3 + 0.7
		render.DrawSprite(pos, diskRadius * 1.8 * outerPulse, diskRadius * 1.8 * outerPulse, Color(80, 40, 120, 60))
	end

	-- Draw thick dramatic energy arcs crackling around the void
	function ENT:DrawEnergyArcs(pos, coreRadius)
		render.SetMaterial(matBeam)

		-- Fewer but MUCH thicker and more dramatic arcs
		for i = 1, 6 do
			if math.sin(self.PulseTime * 8 + i * 2.5) > -0.2 then
				local angle1 = math.rad(i * 60 + self.Rotation * 3)
				local angle2 = math.rad(i * 60 + math.random(30, 60) + self.Rotation * 3)

				local startPos = pos + Vector(math.cos(angle1) * coreRadius * 1.3, math.sin(angle1) * coreRadius * 1.3, math.Rand(-40, 40))
				local endPos = pos + Vector(math.cos(angle2) * coreRadius * 2.5, math.sin(angle2) * coreRadius * 2.5, math.Rand(-70, 70))

				-- Thick jagged arc
				local segments = 6
				local prevPos = startPos
				for seg = 1, segments do
					local t = seg / segments
					local nextPos = LerpVector(t, startPos, endPos) + VectorRand() * coreRadius * 0.5

					local flicker = 0.7 + 0.3 * math.sin(self.PulseTime * 12 + i + seg)
					local width = coreRadius * 0.35 * flicker  -- Much thicker

					-- Draw multiple layers for thickness
					render.DrawBeam(prevPos, nextPos, width, 0, 1, Color(255, 200, 255, 240 * flicker))
					render.DrawBeam(prevPos, nextPos, width * 0.6, 0, 1, Color(220, 160, 255, 255 * flicker))
					prevPos = nextPos
				end
			end
		end

		-- Add massive reaching arcs
		for i = 1, 3 do
			if math.sin(self.PulseTime * 5 + i * 4) > 0.3 then
				local angle = math.rad(i * 120 + self.Rotation * 2.5)
				local startPos = pos + Vector(math.cos(angle) * coreRadius * 1.2, math.sin(angle) * coreRadius * 1.2, 0)
				local endPos = pos + Vector(math.cos(angle) * coreRadius * 3.5, math.sin(angle) * coreRadius * 3.5, math.Rand(-80, 80))

				local segments = 7
				local prevPos = startPos
				for seg = 1, segments do
					local t = seg / segments
					local nextPos = LerpVector(t, startPos, endPos) + VectorRand() * coreRadius * 0.6

					local flicker = 0.8 + 0.2 * math.sin(self.PulseTime * 10 + i * 3 + seg)
					local width = coreRadius * 0.45 * flicker * (1 - t * 0.3)  -- Taper towards end

					-- Super thick with multiple layers
					render.DrawBeam(prevPos, nextPos, width, 0, 1, Color(255, 220, 255, 200 * flicker))
					render.DrawBeam(prevPos, nextPos, width * 0.7, 0, 1, Color(240, 180, 255, 255 * flicker))
					render.DrawBeam(prevPos, nextPos, width * 0.4, 0, 1, Color(255, 255, 255, 220 * flicker))
					prevPos = nextPos
				end
			end
		end
	end

	-- Draw minimal particle streams being pulled in
	function ENT:DrawParticles(pos, coreRadius, diskRadius)
		if CurTime() > self.NextParticle then
			self.NextParticle = CurTime() + 0.08

			local dist = pos:Distance(EyePos())
			local particleCount = math.Clamp(5 - math.floor(dist / (coreRadius * 20)), 2, 5)

			for i = 1, particleCount do
				local angle = math.random(0, 360)
				local rad = math.rad(angle)
				local distance = math.Rand(coreRadius * 2.8, diskRadius * 1.6)
				local particlePos = pos + Vector(math.cos(rad) * distance, math.sin(rad) * distance, math.Rand(-distance * 0.2, distance * 0.2))

				local particle = self.Emitter:Add("effects/blueflare1", particlePos)
				if particle then
					local dir = (pos - particlePos):GetNormalized()
					local tangent = Vector(-dir.y, dir.x, 0):GetNormalized()
					local speed = 150 * (coreRadius * 3 / distance)

					particle:SetVelocity(dir * speed + tangent * (speed * 0.3))
					particle:SetDieTime(math.Rand(1.2, 2.8))
					particle:SetStartAlpha(180)
					particle:SetEndAlpha(0)
					particle:SetStartSize(math.Rand(20, 30))
					particle:SetEndSize(0)

					-- Bright purple-magenta palette
					local t = distance / (diskRadius * 2)
					local r = Lerp(t, 220, 120)
					local g = Lerp(t, 120, 50)
					local b = Lerp(t, 255, 180)

					particle:SetColor(r, g, b)
					particle:SetGravity(Vector(0, 0, 0))
					particle:SetCollide(false)
					particle:SetAirResistance(5)
				end
			end
		end
	end

	-- Receive explosion event
	net.Receive("Arcana_BlackholeExplode", function()
		local pos = net.ReadVector()

		-- Massive particle explosion
		local emitter = ParticleEmitter(pos)
		if emitter then
			-- Electric burst explosion
			for i = 1, 100 do
				local p = emitter:Add("effects/blueflare1", pos)
				if p then
					p:SetDieTime(math.Rand(1.0, 2.5))
					p:SetStartAlpha(255)
					p:SetEndAlpha(0)
					p:SetStartSize(math.Rand(30, 60))
					p:SetEndSize(0)
					p:SetColor(200, 140, 255)
					p:SetVelocity(VectorRand() * 800)
					p:SetAirResistance(50)
					p:SetGravity(Vector(0, 0, -200))
				end
			end

			-- Energy sparks
			for i = 1, 80 do
				local p = emitter:Add("sprites/light_glow02_add", pos)
				if p then
					p:SetDieTime(math.Rand(0.8, 2.0))
					p:SetStartAlpha(255)
					p:SetEndAlpha(0)
					p:SetStartSize(math.Rand(40, 70))
					p:SetEndSize(0)
					p:SetColor(240, 180, 255)
					p:SetVelocity(VectorRand() * 600)
					p:SetAirResistance(30)
				end
			end

			emitter:Finish()
		end

		-- Flash effects
		local ed = EffectData()
		ed:SetOrigin(pos)
		util.Effect("cball_explode", ed, true, true)
		util.Effect("ElectricSpark", ed, true, true)
	end)
end