AddCSLuaFile()
ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "Lightning Storm"
ENT.Author = "Earu"
ENT.Spawnable = false
ENT.AdminOnly = false
ENT.Category = "Arcana"

-- Server-side initialization
function ENT:Initialize()
	if SERVER then
		self:SetModel("models/props_junk/watermelon01.mdl") -- Temporary model, will be replaced with effects
		self:SetMoveType(MOVETYPE_NONE)
		self:SetSolid(SOLID_NONE)
		self:DrawShadow(false)
		-- Set up physics
		local phys = self:GetPhysicsObject()

		if IsValid(phys) then
			phys:Wake()
			phys:EnableMotion(false)
		end

		-- Cloud properties
		self:SetNWInt("Radius", 2000) -- Increased radius for larger cloud area
		self:SetNWInt("CloudHeight", 400) -- Height of the cloud
		self:SetNWInt("Damage", 1000) -- Damage per lightning strike
		self:SetNWFloat("MinStrikeInterval", 2) -- Minimum time between strikes
		self:SetNWFloat("MaxStrikeInterval", 8) -- Maximum time between strikes
		self:SetNWFloat("DarknessIntensity", 0.25) -- How dark it gets under the cloud (0-1)
		-- Start the lightning strikes with random interval
		self:SetNextStrikeTime()
		-- Create the cloud effect
		self:CreateCloudEffect()

		-- Precache thunder sounds
		for i = 1, 4 do
			util.PrecacheSound("ambient/atmosphere/thunder" .. i .. ".wav")
		end
	end
end

function ENT:CreateCloudEffect()
	-- Create multiple smoke effects to form a cloud
	local radius = self:GetNWInt("Radius") * 0.6

	-- Add some sparks inside the cloud to simulate electricity
	for i = 1, 3 do
		local sparkPos = self:GetPos() + Vector(math.random(-radius / 2, radius / 2), math.random(-radius / 2, radius / 2), math.random(20, 80))
		local sparkEffect = EffectData()
		sparkEffect:SetOrigin(sparkPos)
		sparkEffect:SetScale(1)
		sparkEffect:SetMagnitude(1)
		sparkEffect:SetRadius(20)
		util.Effect("Sparks", sparkEffect)
	end

	-- Schedule next cloud effect
	timer.Simple(math.random(0.2, 0.8), function()
		if IsValid(self) then
			self:CreateCloudEffect()
		end
	end)
end

-- Helper function to set the next strike time with randomized interval
function ENT:SetNextStrikeTime()
	local minInterval = self:GetNWFloat("MinStrikeInterval")
	local maxInterval = self:GetNWFloat("MaxStrikeInterval")
	self.NextStrike = CurTime() + math.random(minInterval, maxInterval)
end

function ENT:Think()
	if SERVER then
		-- Check if it's time for a lightning strike
		if CurTime() >= self.NextStrike then
			self:CreateLightningStrike()
			-- Set the next strike time with a random interval
			self:SetNextStrikeTime()
		end

		self:NextThink(CurTime() + 0.1)

		return true
	end
end

function ENT:CreateLightningStrike()
	local radius = self:GetNWInt("Radius")
	local cloudCenter = self:GetPos()
	local targetPos = nil
	local targetEnt = nil
	local players = player.GetAll()
	local targetableEntities = {}

	for _, ply in ipairs(players) do
		if ply:Alive() and ply:GetPos():Distance(cloudCenter) <= radius then
			-- Check if player is outdoors (not under a roof)
			local tr = util.TraceLine({
				start = Vector(ply:GetPos().x, ply:GetPos().y, cloudCenter.z),
				endpos = ply:EyePos(),
				filter = { self }
			})

			-- No significant obstacles between cloud and player
			if tr.Fraction >= 0.9 then
				table.insert(targetableEntities, {
					pos = ply:GetPos(),
					ent = ply
				})
			end
		end
	end

	for _, npc in ipairs(ents.FindByClass("npc_*")) do
		local alive = ((npc.Health and npc:Health() > 0) or not npc.Health)
		if alive and npc:GetPos():Distance(cloudCenter) <= radius then
			-- Check if NPC is outdoors
			local tr = util.TraceLine({
				start = Vector(npc:GetPos().x, npc:GetPos().y, cloudCenter.z),
				endpos = npc:EyePos(),
				filter = { self }
			})

			if tr.Fraction >= 0.9 then
				table.insert(targetableEntities, {
					pos = npc:GetPos(),
					ent = npc
				})
			end
		end
	end

	if #targetableEntities > 0 then
		local randomIndex = math.random(1, #targetableEntities)
		targetPos = targetableEntities[randomIndex].pos
		targetEnt = targetableEntities[randomIndex].ent
	end

	-- If no valid targets found, strike at random position
	if not targetPos then
		local angle = math.random(0, 360)
		local distance = math.random(0, radius)
		local randomPos = cloudCenter + Vector(math.cos(math.rad(angle)) * distance, math.sin(math.rad(angle)) * distance, 0)

		-- Trace down to find ground
		local trace = {}
		trace.start = Vector(randomPos.x, randomPos.y, cloudCenter.z)
		trace.endpos = trace.start + Vector(0, 0, -10000)
		trace.filter = self
		local tr = util.TraceLine(trace)

		if tr.Hit then
			targetPos = tr.HitPos
		end
	end

	-- If we found a valid target position, create the lightning strike
	if targetPos then
		-- Random origin point within the cloud for the lightning to start from
		local cloudHeight = self:GetNWInt("CloudHeight")
		local lightningOrigin = cloudCenter + Vector(math.random(-radius * 0.3, radius * 0.3), math.random(-radius * 0.3, radius * 0.3), math.random(cloudHeight * 0.6, cloudHeight * 0.9))

		-- Network the position to clients for additional light effects
		self:SetNWVector("LastStrikePos", targetPos)
		self:SetNWFloat("LastStrikeTime", CurTime())
		self:SetNWVector("LastStrikeOrigin", lightningOrigin)

		-- Create the lightning effect
		local lightning = EffectData()
		lightning:SetEntity(self)
		lightning:SetOrigin(targetPos)
		lightning:SetStart(lightningOrigin)
		lightning:SetScale(1)
		lightning:SetMagnitude(5)
		util.Effect("lightning_strike", lightning)

		-- Create flash effect at strike point
		local lightEffectData = EffectData()
		lightEffectData:SetOrigin(targetPos)
		lightEffectData:SetScale(10) -- Size of the light effect
		lightEffectData:SetMagnitude(4) -- Brightness
		lightEffectData:SetRadius(500) -- Radius of light effect
		util.Effect("lightning_flash", lightEffectData)

		-- Play thunder sound with delay based on distance
		timer.Simple(math.Rand(0.1, 0.5), function()
			if IsValid(self) then
				local soundEnt = IsValid(targetEnt) and targetEnt or self
				-- Play the sound with variance in pitch and volume
				soundEnt:EmitSound("ambient/weather/thunderstorm/thunder_3.wav", 100)
				soundEnt:EmitSound("ambient/weather/thunderstorm/lightning_strike_" .. math.random(1, 4) .. ".wav", 100, math.random(100, 120))

				-- Create a distant rolling thunder effect a bit later
				timer.Simple(math.Rand(1.5, 3.0), function()
					soundEnt = IsValid(targetEnt) and targetEnt or self

					if IsValid(self) then
						soundEnt:EmitSound("ambient/weather/thunderstorm/thunder_3.wav", 85)
						soundEnt:EmitSound("ambient/weather/thunderstorm/distant_thunder_" .. math.random(1, 4) .. ".wav", 85, math.random(100, 120))
					end
				end)
			end
		end)

		-- Deal damage to nearby entities
		self:DamageSurroundingEntities(targetPos, targetEnt)
	end
end

function ENT:DamageSurroundingEntities(strikePos, targetEnt)
	local damage = self:GetNWInt("Damage")
	local damageRadius = 150 -- Area of damage around strike

	-- Apply direct damage to target entity if available (extra damage to primary target)
	if IsValid(targetEnt) then
		local dmgInfo = DamageInfo()
		dmgInfo:SetDamage(damage * 3) -- 3x more damage for direct hit
		dmgInfo:SetDamageType(DMG_DISSOLVE)
		dmgInfo:SetAttacker(self)
		dmgInfo:SetInflictor(self)
		targetEnt:Ignite(1, damageRadius)

		if targetEnt.ForceTakeDamageInfo then
			targetEnt:ForceTakeDamageInfo(dmgInfo)
		else
			targetEnt:TakeDamageInfo(dmgInfo)
		end

		-- Apply force if it's a physics object
		local phys = targetEnt:GetPhysicsObject()

		if IsValid(phys) then
			phys:ApplyForceCenter(Vector(0, 0, damage * 500)) -- Upward force for dramatic effect
		end
	end

	-- Deal AOE damage to surrounding entities
	util.BlastDamage(self, self, strikePos, damageRadius, damage)

	-- Find all entities for physics effects and fire
	for _, ent in pairs(ents.FindInSphere(strikePos, damageRadius)) do
		if IsValid(ent) and ent ~= self and ent ~= targetEnt then
			-- Calculate damage based on distance
			local distance = ent:GetPos():Distance(strikePos)
			local scaledDamage = damage * (1 - distance / damageRadius)

			-- Apply force to physics objects
			local phys = ent:GetPhysicsObject()
			if IsValid(phys) then
				local direction = (ent:GetPos() - strikePos):GetNormalized()
				phys:ApplyForceCenter(direction * scaledDamage * 500)
			end
		end
	end
end

-- Create custom effect for lightning strike
if CLIENT then
	-- Define lightning materials
	local LIGHTNING_MATERIALS = {
		main = Material("effects/beam_generic01"),
		glow = Material("sprites/physbeam"),
		bright = Material("effects/blueflare1"),
		inner = Material("effects/bluemuzzle"),
		electric = Material("trails/electric")
	}

	-- Create a branching lightning bolt
	function ENT:CreateLightningBolt(startPos, endPos, branchChance, width, detail)
		local points = {startPos}

		local mainDist = startPos:Distance(endPos)
		local mainDir = (endPos - startPos):GetNormalized()
		local currentPos = startPos
		local segmentLength = mainDist / detail

		-- Create the main lightning path with realistic jagged pattern
		for i = 1, detail do
			-- Calculate next position with zigzag pattern
			local targetPos = startPos + mainDir * (segmentLength * i)
			local randomOffset = VectorRand() * (segmentLength * 0.5)
			randomOffset.z = randomOffset.z * 0.5 -- Less vertical deviation

			-- Ensure the bolt generally moves toward the end point
			if i == detail then
				currentPos = endPos -- Ensure it ends at target
			else
				currentPos = targetPos + randomOffset
			end

			table.insert(points, currentPos)

			-- Add branching with decreasing probability for each segment
			if math.random() < branchChance * (1 - i / detail) then
				local branchDir = (VectorRand() + Vector(0, 0, -0.8)):GetNormalized()
				local branchEnd = currentPos + branchDir * segmentLength * math.Rand(0.5, 2)
				-- Recursively create smaller branches
				local branchPoints = self:CreateLightningBolt(currentPos, branchEnd, branchChance * 0.5, width * 0.6, math.max(2, math.floor(detail * 0.4))) -- Reduced branch chance for sub-branches -- Smaller width for branches -- Fewer segments for branches

				-- Add branch points to render list
				for _, point in ipairs(branchPoints) do
					table.insert(points, point)
				end
			end
		end

		return points
	end

	-- Render lightning bolts
	function ENT:DrawLightningBolt(points, color, width, fadeFactor, material)
		-- Set lightning material before drawing
		render.SetMaterial(material or LIGHTNING_MATERIALS.main)

		for i = 1, #points - 1 do
			-- Calculate width based on position in bolt
			local currentWidth = width * (1 - (i / #points) * fadeFactor)
			render.DrawBeam(points[i], points[i + 1], currentWidth, 0, 1, color)
		end
	end

	function ENT:Initialize()
		self:SetRenderBounds(Vector(-10000, -10000, -10000), Vector(10000, 10000, 10000))
	end

	-- Override the lightning strike effect with our improved version
	effects.Register({
		Init = function(self, data)
			self.StartPos = data:GetStart()
			self.EndPos = data:GetOrigin()
			self.Scale = data:GetScale() or 1
			self.Magnitude = data:GetMagnitude() or 1
			self.Entity = data:GetEntity() or NULL
			self.Life = 0.5
			self.StartTime = CurTime()
			self.EndTime = CurTime() + self.Life
			-- Add light
			local dlight = DynamicLight(self:EntIndex())

			if dlight then
				dlight.pos = self.EndPos
				dlight.r = 180 -- Blue-white color
				dlight.g = 220
				dlight.b = 255
				dlight.brightness = 5
				dlight.size = 256
				dlight.decay = 10000
				dlight.dieTime = CurTime() + 0.1
			end
		end,
		Think = function(self)
			if CurTime() > self.EndTime then return false end

			return true
		end,
		Render = function(self)
			local progress = math.min((CurTime() - self.StartTime) / self.Life, 1)

			-- Generate lightning bolts only once
			if not self.LightningBolts then
				self.LightningBolts = {}
				local entity = self.Entity

				-- Create main bolt
				if IsValid(entity) then
					local numBranches = math.random(3, 7)

					for i = 1, numBranches do
						local deviation = 100 * self.Scale
						local endPoint = self.EndPos + Vector(math.random(-deviation, deviation), math.random(-deviation, deviation), math.random(-20, 0))

						table.insert(self.LightningBolts, {
							points = entity:CreateLightningBolt(self.StartPos, endPoint, 0.4, 30 * self.Scale, 8),
							alpha = math.random(150, 255)
						})
					end
				end
			end

			-- Render lightning bolts with different colors for better visual effect
			if self.LightningBolts then
				for _, bolt in pairs(self.LightningBolts) do
					local branchAlpha = bolt.alpha * (1 - progress)
					-- Inner electric core
					local innerColor = Color(240, 250, 255, branchAlpha)
					self.Entity:DrawLightningBolt(bolt.points, innerColor, 8 * self.Scale, 0.2, LIGHTNING_MATERIALS.electric)
					-- Main bright core
					local mainColor = Color(220, 240, 255, branchAlpha)
					self.Entity:DrawLightningBolt(bolt.points, mainColor, 12 * self.Scale, 0.3, LIGHTNING_MATERIALS.main)
					-- Inner glow
					local glowColor = Color(180, 220, 255, branchAlpha * 0.6)
					self.Entity:DrawLightningBolt(bolt.points, glowColor, 24 * self.Scale, 0.5, LIGHTNING_MATERIALS.glow)
					-- Outer glow
					local outerGlowColor = Color(150, 180, 255, branchAlpha * 0.4)
					self.Entity:DrawLightningBolt(bolt.points, outerGlowColor, 36 * self.Scale, 0.7, LIGHTNING_MATERIALS.glow)

					-- Add bright flares at some points for extra effect
					if progress < 0.2 then
						render.SetMaterial(LIGHTNING_MATERIALS.bright)

						for i = 1, #bolt.points, 3 do
							local flareSize = (12 - i / 2) * self.Scale * (1 - progress * 5)

							if flareSize > 0 then
								render.DrawSprite(bolt.points[i], flareSize, flareSize, Color(200, 230, 255, branchAlpha))
							end
						end
					end
				end
			end
		end
	}, "lightning_strike")

	-- Hook to render additional lightning effects based on networked strike information
	hook.Add("PostDrawTranslucentRenderables", "LightningStormAdditionalEffects", function()
		for _, ent in pairs(ents.FindByClass("arcana_lightning_storm")) do
			if IsValid(ent) then
				local lastStrikeTime = ent:GetNWFloat("LastStrikeTime", 0)
				local lastStrikePos = ent:GetNWVector("LastStrikePos", Vector(0, 0, 0))
				local lastStrikeOrigin = ent:GetNWVector("LastStrikeOrigin", Vector(0, 0, 0))

				-- Add additional lightning effects for recently struck areas
				if CurTime() - lastStrikeTime < 0.3 and lastStrikePos ~= Vector(0, 0, 0) then
					local strikeAge = CurTime() - lastStrikeTime
					local fadeProgress = strikeAge / 0.3

					-- Create additional branching bolts that weren't part of the main effect
					if fadeProgress < 0.1 and math.random(1, 5) == 1 then
						local strikeScale = math.random(1, 2)
						local branchChance = 0.5
						local detail = 7
						-- Create main lightning bolt
						local mainColor = Color(220, 240, 255, 255 * (1 - fadeProgress * 5))
						local boltPoints = ent:CreateLightningBolt(lastStrikeOrigin + VectorRand() * 100, lastStrikePos + Vector(math.random(-100, 100), math.random(-100, 100), 0), branchChance, 15 * strikeScale, detail)
						-- Draw with different colors for better visual effect
						ent:DrawLightningBolt(boltPoints, mainColor, 12 * strikeScale, 0.3, LIGHTNING_MATERIALS.main)
						ent:DrawLightningBolt(boltPoints, Color(180, 220, 255, 150 * (1 - fadeProgress * 5)), 24 * strikeScale, 0.5, LIGHTNING_MATERIALS.glow)
						ent:DrawLightningBolt(boltPoints, Color(150, 180, 255, 100 * (1 - fadeProgress * 5)), 36 * strikeScale, 0.7, LIGHTNING_MATERIALS.glow)
						-- Add electric core for more realistic effect
						ent:DrawLightningBolt(boltPoints, Color(240, 250, 255, 200 * (1 - fadeProgress * 5)), 6 * strikeScale, 0.2, LIGHTNING_MATERIALS.electric)

						-- Add bright flares at bolt joints
						if fadeProgress < 0.05 then
							render.SetMaterial(LIGHTNING_MATERIALS.bright)

							for i = 1, #boltPoints, 2 do
								local flareSize = 15 * strikeScale * (1 - fadeProgress * 20)

								if flareSize > 0 then
									render.DrawSprite(boltPoints[i], flareSize, flareSize, Color(200, 230, 255, 180 * (1 - fadeProgress * 20)))
								end
							end
						end
					end
				end
			end
		end
	end)

	-- Cloud particles
	function ENT:Draw()
		-- Don't draw the entity model
		-- self:DrawModel()
		-- Add particle emitters for continuous cloud effect
		if not self.Emitter then
			self.Emitter = ParticleEmitter(self:GetPos())
			self.NextParticle = 0
		end

		if self.Emitter and CurTime() > (self.NextParticle or 0) then
			local radius = self:GetNWInt("Radius") or 2000
			local cloudHeight = self:GetNWInt("CloudHeight") or 400

			for i = 1, 10 do
				-- Use different seed for each particle to ensure randomness
				math.randomseed(CurTime() + i * 1000)
				-- Create particle position using circular distribution (polar coordinates)
				-- This makes the cloud truly circular instead of rectangular
				local angle = math.random(0, 360)
				local distance = math.random() * radius * 0.8 -- Random distance from center, max 80% of radius
				-- Convert polar to cartesian coordinates
				local xOffset = math.cos(math.rad(angle)) * distance
				local yOffset = math.sin(math.rad(angle)) * distance
				local zOffset = math.random(cloudHeight * 0.5, cloudHeight)
				-- Create dark cloud particles
				local pos = self:GetPos() + Vector(xOffset, yOffset, zOffset)
				local particle = self.Emitter:Add("particle/smokesprites_000" .. math.random(1, 9), pos)

				if particle then
					-- Slight inward/outward drift for natural cloud movement
					local driftSpeed = math.random(-5, 5)
					local driftDir = Vector(xOffset, yOffset, 0):GetNormalized()
					particle:SetVelocity(driftDir * driftSpeed + Vector(0, 0, math.random(-2, 2)))
					particle:SetDieTime(math.random(5, 10)) -- Longer lifetime for particles
					particle:SetStartAlpha(math.random(180, 220)) -- More opaque
					particle:SetEndAlpha(0)
					-- Particles near edge are smaller to create soft edge effect
					local sizeMultiplier = 1 - (distance / radius) * 0.5
					particle:SetStartSize(math.random(200, 350) * sizeMultiplier) -- Larger particles
					particle:SetEndSize(math.random(300, 450) * sizeMultiplier)
					particle:SetRoll(math.random(0, 360))
					particle:SetRollDelta(math.random(-0.1, 0.1))
					-- Dark cloud color
					local darkness = math.random(20, 45) -- Darker cloud
					particle:SetColor(darkness, darkness, darkness + math.random(0, 10))
					particle:SetAirResistance(5)
					particle:SetGravity(Vector(0, 0, math.random(-5, 5)))
					particle:SetCollide(false)
				end
			end

			-- More frequent particles for a denser cloud
			self.NextParticle = 0 -- CurTime() + 0.01
		end
	end

	function ENT:OnRemove()
		if self.Emitter then
			self.Emitter:Finish()
			self.Emitter = nil
		end
	end

	-- Register a custom effect for the lightning flash
	effects.Register({
		Init = function(self, data)
			self.Position = data:GetOrigin()
			self.Scale = data:GetScale() or 1
			self.Magnitude = data:GetMagnitude() or 1
			self.Radius = data:GetRadius() or 300
			self.Life = 0.1 -- Much shorter flash (was 0.3)
			self.StartTime = CurTime()
			self.EndTime = CurTime() + self.Life
			-- Create the main flash light
			local dlight = DynamicLight(math.random(0, 9999))

			if dlight then
				dlight.pos = self.Position
				dlight.r = 180 -- Blue-white color
				dlight.g = 220
				dlight.b = 255
				dlight.brightness = 5 -- Increased brightness for shorter duration
				dlight.size = self.Radius * 1.5
				dlight.decay = 2000
				dlight.dieTime = CurTime() + 0.07 -- Much shorter light duration (was 0.2)
			end
		end,
		Think = function(self)
			-- Additional secondary flickers
			-- Less chance of flicker
			if math.random(1, 20) == 1 and CurTime() < self.EndTime then
				local dlight = DynamicLight(math.random(0, 9999))

				if dlight then
					dlight.Pos = self.Position + Vector(math.random(-50, 50), math.random(-50, 50), math.random(0, 50))
					dlight.r = 180
					dlight.g = 220
					dlight.b = 255
					dlight.brightness = 5
					dlight.size = self.Radius * 0.8
					dlight.decay = 2000
					dlight.dieTime = CurTime() + 0.05 -- Shorter flicker
				end
			end

			if CurTime() > self.EndTime then return false end

			return true
		end,
		Render = function(self)
			local progress = (CurTime() - self.StartTime) / self.Life
			if progress > 1 then return end
			-- Draw bright flash sprite
			render.SetMaterial(LIGHTNING_MATERIALS.bright)
			local size = self.Radius * 0.2 * (1 - progress)
			render.DrawSprite(self.Position, size, size, Color(220, 240, 255, 255 * (1 - progress)))
			-- Draw larger glow
			render.SetMaterial(LIGHTNING_MATERIALS.glow)
			local glowSize = self.Radius * 0.4 * (1 - progress)
			render.DrawSprite(self.Position, glowSize, glowSize, Color(180, 220, 255, 150 * (1 - progress)))
		end
	}, "lightning_flash")

	-- Add simple environmental darkening without fog
	hook.Add("RenderScreenspaceEffects", "LightningStormDarkness", function()
		local inStormArea = false
		local darkestIntensity = 0
		local playerPos = LocalPlayer():GetPos()

		-- Check if player is under any storm clouds
		for _, ent in pairs(ents.FindByClass("arcana_lightning_storm")) do
			if IsValid(ent) then
				local radius = ent:GetNWInt("Radius") or 2000
				local cloudCenter = ent:GetPos()
				local distFromCenter = Vector(playerPos.x, playerPos.y, 0):Distance(Vector(cloudCenter.x, cloudCenter.y, 0))

				if distFromCenter < radius then
					inStormArea = true
					local distFactor = math.Clamp(1 - (distFromCenter / radius), 0, 1)
					local intensity = ent:GetNWFloat("DarknessIntensity") or 0.7
					darkestIntensity = math.max(darkestIntensity, intensity * distFactor)
				end
			end
		end

		-- Darken the environment if player is in storm area
		if inStormArea then
			local darkFactor = darkestIntensity * 0.3 -- Subtle darkening

			local colorMod = {
				["$pp_colour_addr"] = 0,
				["$pp_colour_addg"] = 0,
				["$pp_colour_addb"] = 0,
				["$pp_colour_brightness"] = -darkFactor,
				["$pp_colour_contrast"] = 1 - darkFactor * 0.2,
				["$pp_colour_colour"] = 1 - darkFactor * 0.3,
				["$pp_colour_mulr"] = 0,
				["$pp_colour_mulg"] = 0,
				["$pp_colour_mulb"] = 0
			}

			DrawColorModify(colorMod)
		end
	end)
end