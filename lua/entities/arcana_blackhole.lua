AddCSLuaFile()

ENT.Type = "anim"
ENT.Base = "base_gmodentity"
ENT.PrintName = "Black Hole"
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
		--self:SetColor(Color(0, 0, 0, 0)) -- Invisible, just for physics

		local phys = self:GetPhysicsObject()
		if IsValid(phys) then
			phys:EnableMotion(false) -- Make it static
			phys:Wake()
		end

		-- Setup initial properties
		self:SetNWFloat("Radius", 2000) -- Effective radius
		self:SetNWFloat("Force", 1500) -- Pulling force

		-- Start the pull effect
		self.NextPull = 0
		self.NextVortexEffect = 0
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
				if IsValid(ent) and ent != self and not ent:CreatedByMap() then
					local physObj = ent:GetPhysicsObject()
					local entPos = ent:GetPos()
					local direction = (pos - entPos):GetNormalized()
					local distance = pos:Distance(entPos)
					local pullStrength = math.Clamp((1 - distance / radius) * force, 0, force)

					-- Apply force to physics objects
					if IsValid(physObj) then
						physObj:ApplyForceCenter(direction * pullStrength * physObj:GetMass())
						if not ent:IsPlayer() then
							ent:SetCollisionGroup(COLLISION_GROUP_DEBRIS)
						end
					end

					-- For players and NPCs
					if ent:IsPlayer() or ent:IsNPC() then
						local velocity = direction * pullStrength * 0.5
						ent:SetVelocity(velocity)
						ent:SetGroundEntity(NULL)
					end

					-- If too close to center, remove/kill the entity
					if distance < 20 and (ent:IsPlayer() or ent:IsNPC()) then
						local dmg = DamageInfo()
						dmg:SetDamage(2e6)
						dmg:SetDamageType(DMG_BLAST)
						dmg:SetAttacker(self.CPPIGetOwner and IsValid(self.CPPIGetOwner()) and self.CPPIGetOwner() or self)
						dmg:SetInflictor(self)

						local takeDamage = ent.ForceTakeDamageInfo or ent.TakeDamageInfo
						takeDamage(ent, dmg)
					end
				end
			end
		end

		-- Create the vortex effect
		if CurTime() > self.NextVortexEffect then
			self.NextVortexEffect = CurTime() + 0.2

			-- Emit effects for the vortex swirl
			local effectData = EffectData()
			effectData:SetOrigin(self:GetPos())
			effectData:SetScale(self:GetNWFloat("Radius") / 50)
			util.Effect("arcana_blackhole_effect", effectData)
		end

		self:NextThink(CurTime())
		return true
	end
end

function ENT:OnRemove()
	-- Cleanup on removal if needed
end

-- Client-side rendering
if CLIENT then
	-- Define the materials we'll use - using proven, existing materials
	--local BLACK_DISK_MATERIAL = Material("models/debug/debugwhite")
	local ACCRETION_DISK_MATERIAL = Material("effects/blueflare1") -- Better accretion material
	local FLARE_MATERIAL = Material("sprites/light_glow02_add")
	local DISTORTION_MATERIAL = Material("effects/water_warp") -- Heat wave distortion
	local STREAK_MATERIAL = Material("effects/beam001_white")
	local DUST_MATERIAL = Material("particle/particle_smoke_dust")
	local ENERGY_MATERIAL = Material("effects/combinemuzzle2_dark")

	-- Limit how often we create new particles for performance
	local PARTICLE_FREQUENCY = 0.05

	function ENT:Initialize()
		if CLIENT then
			self.Emitter = ParticleEmitter(self:GetPos())
			self.NextParticle = 0
			self.DiskRotation = 0
		end
	end

	function ENT:Draw()
		self:DrawModel() -- Note: Model is invisible due to alpha 0

		local pos = self:GetPos()
		local radius = self:GetNWFloat("Radius") * 0.15
		local eyePos = EyePos()
		local dist = pos:Distance(eyePos)

		-- Don't render if too far away (performance)
		if dist > radius * 25 then return end

		-- Event horizon radius (the actual black hole)
		local eventHorizonRadius = radius * 0.7

		-- Update disk rotation
		self.DiskRotation = (self.DiskRotation + FrameTime() * 15) % 360

		-- 1. Draw the distortion ring around the event horizon (3D distortion)
		--self:DrawDistortionRing(pos, eventHorizonRadius * 1.2, radius * 2)

		-- 2. Draw the black hole event horizon (totally black)
		render.SetColorMaterial()
		render.DrawSphere(pos, eventHorizonRadius, 30, 30, Color(0, 0, 0, 255))

		-- 3. Draw the accretion disk
		self:DrawAccretionDisk(pos, radius, eventHorizonRadius)

		-- 4. Draw particle effects for matter falling in
		self:DrawParticles(pos, radius, eventHorizonRadius)
	end

	-- Draw a visible distortion ring around the black hole
	function ENT:DrawDistortionRing(pos, innerRadius, outerRadius)
		-- Draw the heat distortion around the black hole
		render.SetMaterial(DISTORTION_MATERIAL)

		-- Draw distortion as repeating shells with varying alpha for better visibility
		for i = 1, 3 do
			local radius = innerRadius * (1 + i * 0.3)
			local alpha = 180 - i * 40
			render.DrawSphere(pos, radius, 30, 30, Color(255, 255, 255, alpha))
		end

		-- Draw additional bright spots around the distortion edge for better visibility
		render.SetMaterial(FLARE_MATERIAL)

		for i = 1, 12 do
			local angle = math.rad(i * 30 + self.DiskRotation * 0.1)
			local distortionPos = pos + Vector(
				math.cos(angle) * innerRadius * 1.3,
				math.sin(angle) * innerRadius * 1.3,
				0
			)

			-- Size pulses over time for more dynamic effect
			local pulseSize = innerRadius * 0.2 * (0.8 + 0.2 * math.sin(CurTime() * 2 + i))
			render.DrawSprite(distortionPos, pulseSize, pulseSize, Color(70, 120, 255, 70))
		end
	end

	-- Draw the accretion disk with dynamic animation
	function ENT:DrawAccretionDisk(pos, radius, eventHorizonRadius)
		-- Simpler, more reliable approach to the accretion disk
		local innerRadius = eventHorizonRadius * 1.2
		local outerRadius = radius * 2

		-- Additional visual fluff elements
		self:DrawEnergyJets(pos, radius, eventHorizonRadius)
		self:DrawDustClouds(pos, radius, eventHorizonRadius)
		self:DrawLightStreaks(pos, radius, eventHorizonRadius)

		-- Calculate super fast rotation for dramatic effect
		local baseRotation = CurTime() * 200 -- Much faster rotation

		-- The thickness of the disk
		local diskThickness = radius * 0.2 -- Thicker for better visibility

		-- Draw a continuous accretion disk with trails
		render.SetMaterial(STREAK_MATERIAL)

		-- Create multiple rings using beams
		for i = 0, 8 do
			local t = i / 8
			local currentRadius = innerRadius + (outerRadius - innerRadius) * t

			-- Color gradient from blue to purple
			local ringColor
			if t < 0.3 then
				-- Bright blue inner
				ringColor = Color(150, 180, 255, 180 - t * 100)
			elseif t < 0.7 then
				-- Purple middle
				ringColor = Color(120, 60, 220, 150 - t * 70)
			else
				-- Deep purple outer
				ringColor = Color(80, 30, 180, 120 - t * 50)
			end

			-- Create a full 360-degree trail ring
			local segments = 36 -- More segments for smoother curves
			local rotationOffset = baseRotation * (1 - t * 0.5) -- Different rotation speeds
			local points = {}

			-- Calculate points around the circle
			for j = 0, segments do
				local angle = (j / segments) * math.pi * 2 + math.rad(rotationOffset % 360)
				points[j + 1] = pos + Vector(
					math.cos(angle) * currentRadius,
					math.sin(angle) * currentRadius,
					math.sin(CurTime() + i * 0.3) * diskThickness * 0.2 -- Small z-variation
				)
			end

			-- Draw connected beam segments to form a continuous ring
			local width = diskThickness * (1 - t * 0.3) -- Width varies by radius
			for j = 1, segments do
				render.DrawBeam(
					points[j],
					points[j + 1],
					width,
					0,
					1,
					ringColor
				)
			end

			-- Connect the last point back to the first to complete the circle
			render.DrawBeam(
				points[segments + 1],
				points[1],
				width,
				0,
				1,
				ringColor
			)
		end

		-- Create offset overlapping rings for a thicker appearance
		for i = 0, 5 do
			local t = i / 5
			local currentRadius = innerRadius * 1.1 + (outerRadius - innerRadius) * t

			-- Alternate color for more visual interest
			local offsetColor = Color(130, 100, 240, 100 - t * 50)

			local offsetRotation = baseRotation * 0.7 * (1 - t * 0.3) + 30 -- Different rotation
			local segments = 24 -- Fewer segments for performance
			local points = {}

			-- Calculate offset points
			for j = 0, segments do
				local angle = (j / segments) * math.pi * 2 + math.rad(offsetRotation % 360)
				points[j + 1] = pos + Vector(
					math.cos(angle) * currentRadius,
					math.sin(angle) * currentRadius,
					math.cos(CurTime() * 1.3 + i) * diskThickness * 0.15 -- Different z-variation
				)
			end

			-- Draw connected beams for offset rings
			local width = diskThickness * 0.8 * (1 - t * 0.4)
			for j = 1, segments do
				render.DrawBeam(
					points[j],
					points[j + 1],
					width,
					0,
					1,
					offsetColor
				)
			end

			render.DrawBeam(
				points[segments + 1],
				points[1],
				width,
				0,
				1,
				offsetColor
			)
		end

		-- Add counter-rotating rings for more complexity
		for i = 0, 3 do
			local t = i / 3
			local currentRadius = innerRadius + (outerRadius - innerRadius) * (0.2 + t * 0.6)

			local counterRotation = -baseRotation * 0.6 * (1 - t * 0.5) + 15 -- Counter rotation
			local counterColor = Color(160, 170, 255, 130 - t * 80)

			local segments = 18 -- Even fewer segments
			local points = {}

			-- Calculate counter-rotating points
			for j = 0, segments do
				local angle = (j / segments) * math.pi * 2 + math.rad(counterRotation % 360)
				points[j + 1] = pos + Vector(
					math.cos(angle) * currentRadius,
					math.sin(angle) * currentRadius,
					math.sin(CurTime() * 0.7 - i) * diskThickness * 0.25 -- Different pattern
				)
			end

			-- Draw beams for counter-rotating rings
			local width = diskThickness * 0.6 * (1 - t * 0.3)
			for j = 1, segments do
				render.DrawBeam(
					points[j],
					points[j + 1],
					width,
					0,
					1,
					counterColor
				)
			end

			render.DrawBeam(
				points[segments + 1],
				points[1],
				width,
				0,
				1,
				counterColor
			)
		end

		-- Draw bright core for the center
		render.SetMaterial(ACCRETION_DISK_MATERIAL)
		render.DrawSprite(pos, innerRadius * 3, innerRadius * 3, Color(150, 180, 255, 150))

		-- Add bright flares around the disk for highlights
		for i = 1, 8 do
			local flareAngle = math.rad(i * 45 + CurTime() * 40)
			local flareRadius = innerRadius * 1.5 + math.sin(CurTime() * 2 + i) * radius * 0.3

			local flarePos = pos + Vector(
				math.cos(flareAngle) * flareRadius,
				math.sin(flareAngle) * flareRadius,
				math.sin(CurTime() + i) * diskThickness * 0.3
			)

			-- Bright pulsing flares
			local flareSize = radius * 0.3 * (0.8 + 0.2 * math.sin(CurTime() * 3 + i))
			local flareColor = i % 2 == 0
				and Color(170, 200, 255, 150) -- Blue
				or Color(140, 80, 240, 150)   -- Purple

			render.SetMaterial(FLARE_MATERIAL)
			render.DrawSprite(flarePos, flareSize, flareSize, flareColor)
		end

		-- Add radial beams extending from the center for more disk-like structure
		for i = 1, 12 do
			local beamAngle = math.rad(i * 30 + CurTime() * 15)
			local startPos = pos + Vector(
				math.cos(beamAngle) * innerRadius * 1.2,
				math.sin(beamAngle) * innerRadius * 1.2,
				0
			)

			local endPos = pos + Vector(
				math.cos(beamAngle) * outerRadius * (0.8 + 0.2 * math.sin(CurTime() + i)),
				math.sin(beamAngle) * outerRadius * (0.8 + 0.2 * math.sin(CurTime() + i)),
				math.sin(CurTime() * 1.5 + i) * diskThickness * 0.4
			)

			-- Draw radial beam
			render.SetMaterial(STREAK_MATERIAL)
			local beamWidth = radius * 0.12 * (0.7 + 0.3 * math.sin(CurTime() * 2 + i))
			local beamColor = i % 3 == 0
				and Color(160, 190, 255, 100) -- Blue
				or Color(130, 70, 230, 100)   -- Purple

			render.DrawBeam(
				startPos,
				endPos,
				beamWidth,
				0,
				1,
				beamColor
			)
		end

		-- Draw larger overall glow
		render.DrawSprite(pos, outerRadius * 3, outerRadius * 0.6, Color(80, 50, 180, 80))

		-- Add floating debris particles being pulled into the black hole
		self:DrawDebris(pos, radius, eventHorizonRadius)
	end

	-- Draw dramatic energy jets perpendicular to the disk
	function ENT:DrawEnergyJets(pos, radius, eventHorizonRadius)
		-- Energy jets extending from the poles
		local jetLength = radius * 4
		local jetWidth = radius * 0.5

		-- Draw upward jet
		render.SetMaterial(ENERGY_MATERIAL)
		local jetColor = Color(120, 100, 255, 120)

		-- Create pulsing effect
		local pulseScale = 0.8 + 0.2 * math.sin(CurTime() * 2)

		-- Jet base positions (north and south poles)
		local jetBaseUp = pos + Vector(0, 0, eventHorizonRadius * 0.5)
		local jetBaseDown = pos + Vector(0, 0, -eventHorizonRadius * 0.5)

		-- Draw main jet beams
		render.DrawBeam(
			jetBaseUp,
			jetBaseUp + Vector(0, 0, jetLength),
			jetWidth * pulseScale,
			0,
			1,
			jetColor
		)

		render.DrawBeam(
			jetBaseDown,
			jetBaseDown + Vector(0, 0, -jetLength),
			jetWidth * pulseScale,
			0,
			1,
			jetColor
		)

		-- Add glowing points along the jets
		for i = 1, 5 do
			local t = i / 5
			local upPos = jetBaseUp + Vector(0, 0, jetLength * t)
			local downPos = jetBaseDown + Vector(0, 0, -jetLength * t)

			-- Add some random oscillation to positions
			local offsetX = math.sin(CurTime() * 3 + i * 0.5) * (jetWidth * 0.2 * t)
			local offsetY = math.cos(CurTime() * 3 + i * 0.5) * (jetWidth * 0.2 * t)

			upPos = upPos + Vector(offsetX, offsetY, 0)
			downPos = downPos + Vector(offsetX, offsetY, 0)

			-- Draw glowing points
			local pointSize = jetWidth * (1.2 - t * 0.8) * pulseScale
			render.DrawSprite(upPos, pointSize, pointSize, jetColor)
			render.DrawSprite(downPos, pointSize, pointSize, jetColor)
		end

		-- Add dramatic flares at jet origins
		render.DrawSprite(jetBaseUp, jetWidth * 1.5, jetWidth * 1.5, Color(150, 150, 255, 180))
		render.DrawSprite(jetBaseDown, jetWidth * 1.5, jetWidth * 1.5, Color(150, 150, 255, 180))
	end

	-- Draw dust clouds and nebula effects around the black hole
	function ENT:DrawDustClouds(pos, radius, eventHorizonRadius)
		render.SetMaterial(DUST_MATERIAL)

		-- Create multiple dust clouds at different distances
		for i = 1, 10 do
			local angle = math.rad(i * 36 + CurTime() * 5)
			local cloudDist = radius * (2 + i * 0.3)
			local cloudPos = pos + Vector(
				math.cos(angle) * cloudDist,
				math.sin(angle) * cloudDist,
				math.sin(CurTime() + i) * radius * 0.5
			)

			-- Varied cloud colors
			local cloudColor
			if i % 3 == 0 then
				cloudColor = Color(80, 40, 150, 70) -- Purple
			elseif i % 3 == 1 then
				cloudColor = Color(30, 60, 150, 60) -- Blue
			else
				cloudColor = Color(100, 50, 200, 80) -- Bright purple
			end

			-- Draw large dust clouds
			local cloudSize = radius * (0.8 + 0.4 * (i % 3))
			render.DrawSprite(cloudPos, cloudSize, cloudSize, cloudColor)
		end
	end

	-- Draw dramatic light streaks around the black hole
	function ENT:DrawLightStreaks(pos, radius, eventHorizonRadius)
		render.SetMaterial(STREAK_MATERIAL)

		-- Draw curved light streaks
		for i = 1, 12 do
			local angle1 = math.rad(i * 30 + CurTime() * 15)
			local angle2 = math.rad(i * 30 + 15 + CurTime() * 15)

			local startRadius = radius * (1.5 + 0.5 * math.sin(CurTime() + i))
			local endRadius = radius * (2.2 + 0.3 * math.sin(CurTime() * 0.5 + i))

			local startPos = pos + Vector(
				math.cos(angle1) * startRadius,
				math.sin(angle1) * startRadius,
				math.sin(CurTime() + i) * radius * 0.2
			)

			local endPos = pos + Vector(
				math.cos(angle2) * endRadius,
				math.sin(angle2) * endRadius,
				math.cos(CurTime() + i) * radius * 0.3
			)

			-- Streak color
			local streakColor
			if i % 3 == 0 then
				streakColor = Color(180, 200, 255, 150) -- Blue
			elseif i % 3 == 1 then
				streakColor = Color(150, 80, 255, 150) -- Purple
			else
				streakColor = Color(100, 120, 255, 120) -- Light blue
			end

			-- Draw curved streak
			local width = radius * 0.06 * (0.8 + 0.2 * math.sin(CurTime() * 2 + i))
			render.DrawBeam(startPos, endPos, width, 0, 1, streakColor)
		end
	end

	-- Draw debris being pulled into the black hole
	function ENT:DrawDebris(pos, radius, eventHorizonRadius)
		-- We'll use the NextParticle timer for performance
		if self.NextDebris and CurTime() > self.NextDebris then
			self.NextDebris = CurTime() + 0.1

			-- Create spiraling debris
			for i = 1, 3 do
				local angle = math.random(0, 360)
				local rad = math.rad(angle)
				local distance = math.Rand(radius * 1.5, radius * 3)

				local debrisPos = pos + Vector(
					math.cos(rad) * distance,
					math.sin(rad) * distance,
					math.Rand(-radius, radius) * 0.5
				)

				-- Create the particle
				local particle = self.Emitter:Add("particle/particle_noisesphere", debrisPos)

				if particle then
					-- Direction toward center with spiral motion
					local dir = (pos - debrisPos):GetNormalized()
					local tangent = Vector(-dir.y, dir.x, 0):GetNormalized()
					local speed = 80 + math.random(0, 40)

					-- Spiraling motion toward the center
					particle:SetVelocity(dir * speed + tangent * (speed * 0.4))
					particle:SetDieTime(math.Rand(1, 2))
					particle:SetStartAlpha(200)
					particle:SetEndAlpha(0)
					particle:SetStartSize(math.random(5, 15))
					particle:SetEndSize(0)
					particle:SetRoll(math.random(0, 360))
					particle:SetRollDelta(math.random(-2, 2))

					-- Random colors
					local colors = {
						{170, 200, 255}, -- Blue
						{140, 80, 240},  -- Purple
						{130, 130, 255}  -- Light blue
					}

					local color = colors[math.random(1, #colors)]
					particle:SetColor(color[1], color[2], color[3])
					particle:SetGravity(Vector(0, 0, 0))
					particle:SetCollide(false)
					particle:SetAirResistance(1)
				end
			end
		end
	end

	-- Draw particles being pulled into the black hole
	function ENT:DrawParticles(pos, radius, eventHorizonRadius)
		-- Only generate new particles occasionally
		if CurTime() > self.NextParticle then
			self.NextParticle = CurTime() + PARTICLE_FREQUENCY
			self.NextDebris = self.NextDebris or 0 -- Initialize debris timer

			-- Calculate the number of particles based on distance
			local dist = pos:Distance(EyePos())
			local particleCount = math.Clamp(5 - math.floor(dist / (radius * 5)), 1, 5)

			for i = 1, particleCount do
				-- Create a spiral pattern
				local angle = math.random(0, 360)
				local rad = math.rad(angle)

				-- Random distance from center, outside the event horizon
				local distance = math.Rand(eventHorizonRadius * 1.5, radius * 3)

				-- Calculate position
				local particlePos = pos + Vector(
					math.cos(rad) * distance,
					math.sin(rad) * distance,
					math.Rand(-distance * 0.1, distance * 0.1) -- Small z variation
				)

				-- Create the particle
				local particle = self.Emitter:Add("sprites/light_glow02_add", particlePos)

				if particle then
					-- Direction toward center with orbital component
					local dir = (pos - particlePos):GetNormalized()
					local tangent = Vector(-dir.y, dir.x, 0):GetNormalized()

					-- Speed increases as it gets closer to the event horizon
					local speed = 50 * (eventHorizonRadius * 2 / distance)
					particle:SetVelocity(dir * speed + tangent * (speed * 0.2))

					-- Longer lifetime for outer particles
					local lifetime = math.Clamp(distance / (eventHorizonRadius * 5), 0.3, 1.5)
					particle:SetDieTime(lifetime)

					-- Fade out as it approaches the event horizon
					particle:SetStartAlpha(150)
					particle:SetEndAlpha(0)

					-- Size based on distance from center
					local size = math.Clamp(radius * 0.05 * (eventHorizonRadius / distance), 1, radius * 0.1)
					particle:SetStartSize(size)
					particle:SetEndSize(0)

					-- Color based on distance - only blue and purple shades
					local colorRatio = math.Clamp((distance - eventHorizonRadius) / (radius * 3), 0, 1)

					local r, g, b
					if colorRatio < 0.3 then
						-- Bright blue (inner)
						r = Lerp(colorRatio / 0.3, 180, 120)
						g = Lerp(colorRatio / 0.3, 180, 90)
						b = 255
					elseif colorRatio < 0.7 then
						-- Medium purple (middle)
						local t = (colorRatio - 0.3) / 0.4
						r = Lerp(t, 120, 100)
						g = Lerp(t, 90, 40)
						b = Lerp(t, 255, 200)
					else
						-- Deep purple (outer)
						r = Lerp((colorRatio - 0.7) / 0.3, 100, 80)
						g = Lerp((colorRatio - 0.7) / 0.3, 40, 20)
						b = Lerp((colorRatio - 0.7) / 0.3, 200, 160)
					end

					particle:SetColor(r, g, b)
					particle:SetGravity(Vector(0, 0, 0))
					particle:SetCollide(false)
					particle:SetAirResistance(0)
				end
			end
		end

		self.Emitter:Draw()
	end

	-- Screen effects when near the black hole - just slight color modification, no distortion
	hook.Add("RenderScreenspaceEffects", "BlackHoleScreenEffects", function()
		local player = LocalPlayer()
		if not IsValid(player) then return end

		for _, ent in ipairs(ents.FindByClass("arcana_blackhole")) do
			if IsValid(ent) then
				local pos = ent:GetPos()
				local dist = pos:Distance(player:GetPos())
				local radius = ent:GetNWFloat("Radius")

				-- Only apply effects when very near the black hole
				if dist < radius * 0.6 then
					local strength = math.Clamp((1 - dist / (radius * 0.6)) * 0.5, 0, 0.5)

					-- Darken and add contrast when approaching
					local colorMod = {
						["$pp_colour_addr"] = 0,
						["$pp_colour_addg"] = 0,
						["$pp_colour_addb"] = 0,
						["$pp_colour_brightness"] = -strength * 0.3,
						["$pp_colour_contrast"] = 1 + strength * 0.2,
						["$pp_colour_colour"] = 1 - strength * 0.2,
						["$pp_colour_mulr"] = 0,
						["$pp_colour_mulg"] = 0,
						["$pp_colour_mulb"] = 0
					}
					DrawColorModify(colorMod)

					-- Add motion blur as you approach the event horizon
					if dist < radius * 0.3 then
						local blurStrength = math.Clamp((1 - dist / (radius * 0.3)) * 0.6, 0, 0.6)
						DrawMotionBlur(0.1, blurStrength, 0.01)
					end
				end
			end
		end
	end)
end

-- Create effect for matter being pulled into the black hole
if CLIENT then
	local EFFECT = {}

	function EFFECT:Init(data)
		self.Position = data:GetOrigin()
		self.Scale = data:GetScale() or 1
		self.Time = 0
		self.LifeTime = 0.5

		self.Emitter = ParticleEmitter(self.Position)
	end

	function EFFECT:Think()
		self.Time = self.Time + FrameTime()

		-- Add a few particles for the ambient effect
		for i = 1, 2 do
			-- Random position around the black hole
			local angle = math.random(0, 360)
			local rad = math.rad(angle)
			local distance = math.random(30, 60) * self.Scale
			local height = math.random(-10, 10)

			local startPos = self.Position + Vector(
				math.cos(rad) * distance,
				math.sin(rad) * distance,
				height
			)

			-- Create the particle
			local particle = self.Emitter:Add("sprites/light_glow02_add", startPos)

			if particle then
				-- Direction toward center with slight orbital motion
				local dir = (self.Position - startPos):GetNormalized()
				local tangent = Vector(-dir.y, dir.x, 0):GetNormalized()
				particle:SetVelocity(dir * 80 * self.Scale + tangent * 20 * self.Scale)

				particle:SetDieTime(0.5)
				particle:SetStartAlpha(180)
				particle:SetEndAlpha(0)
				particle:SetStartSize(3 * self.Scale)
				particle:SetEndSize(0)

				-- Use only blue/purple colors
				local colors = {
					{180, 190, 255},  -- Bright blue
					{100, 50, 200},   -- Medium purple
					{70, 30, 180}     -- Deep purple
				}

				local color = colors[math.random(1, #colors)]
				particle:SetColor(color[1], color[2], color[3])

				particle:SetGravity(Vector(0, 0, 0))
				particle:SetCollide(false)
			end
		end

		return self.Time < self.LifeTime
	end

	function EFFECT:Render()
		-- Nothing additional to render
	end

	effects.Register(EFFECT, "arcana_blackhole_effect")
end