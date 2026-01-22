if SERVER then
	util.AddNetworkString("Arcana_MeteorStorm_Climax")
	util.AddNetworkString("Arcana_MeteorStorm_InitialVFX")
	util.AddNetworkString("Arcana_MeteorStorm_MeteorStrike")
	util.AddNetworkString("Arcana_MeteorStorm_FinalImpact")
	util.AddNetworkString("Arcana_MeteorStorm_Fissure")
end

-- Meteor Storm: A divine pact granted at level 30 - call down a prolonged meteor storm while the earth ruptures
Arcane:RegisterSpell({
	id = "meteor_storm",
	name = "Meteor Storm",
	description = "Channel divine power to call down a devastating meteor storm while the earth ruptures beneath your enemies.",
	category = Arcane.CATEGORIES.COMBAT,
	level_required = 30,
	knowledge_cost = 8, -- It doesnt cost KPs, but XP scales off this value
	cooldown = 120.0,
	cost_type = Arcane.COST_TYPES.COINS,
	cost_amount = 500000,
	cast_time = 12,
	range = 0,
	icon = "icon16/weather_clouds.png",
	is_divine_pact = true,
	is_projectile = false,
	has_target = true,
	cast_anim = "becon",
	cast = function(caster, _, _, ctx)
		if not SERVER then return true end
		if not IsValid(caster) then return false end

		local srcEnt = IsValid(ctx.casterEntity) and ctx.casterEntity or caster
		local center, normal = Arcane:ResolveGroundTarget(srcEnt, 1500)
		center = center or (srcEnt:GetPos() + Vector(0, 0, 2))
		normal = normal or Vector(0, 0, 1)

	local baseRadius = 1400 -- Larger area of effect
	local duration = 34 -- Total spell duration (must be long enough for final meteor)
	local meteorCount = 35 -- Number of smaller meteors
	local meteorInterval = 0.7 -- Time between meteor impacts

	-- CLIMAX MOMENT: Cast complete, dramatic transition
	util.ScreenShake(center, 20, 200, 1.5, baseRadius * 2.5)

	-- Dramatic climax sounds
	sound.Play("ambient/explosions/explode_9.wav", center, 135, 50)
	sound.Play("weapons/physcannon/energy_sing_explosion2.wav", center, 130, 60)
	sound.Play("ambient/energy/whiteflash.wav", center, 128, 75)

	timer.Simple(0.15, function()
		sound.Play("ambient/levels/labs/electric_explosion" .. math.random(1, 5) .. ".wav", center, 125, 55)
		sound.Play("ambient/atmosphere/thunder" .. math.random(1, 4) .. ".wav", center, 120, 40)
	end)

	-- Broadcast climax VFX (circles explode, flash, etc.)
	net.Start("Arcana_MeteorStorm_Climax", true)
	net.WriteVector(center)
	net.WriteFloat(baseRadius)
	net.WriteEntity(caster)
	net.Broadcast()

	-- Brief pause (0.5s) before the storm begins
	timer.Simple(0.5, function()
		if not IsValid(caster) then return end

		-- PHASE 1: Initial darkening and rumble
		util.ScreenShake(center, 12, 100, 2.0, baseRadius * 2)
		sound.Play("ambient/atmosphere/thunder1.wav", center, 100, 60)
		sound.Play("ambient/atmosphere/terrain_rumble1.wav", center, 95, 90)

		-- Broadcast initial VFX
		net.Start("Arcana_MeteorStorm_InitialVFX", true)
		net.WriteVector(center)
		net.WriteFloat(baseRadius)
		net.WriteFloat(duration)
		net.Broadcast()

		-- Create continuous rumble
		local rumbleAnchor = ents.Create("info_target")
		if IsValid(rumbleAnchor) then
			rumbleAnchor:SetPos(center)
			rumbleAnchor:Spawn()
			local rumbleTimer = "Arcana_MeteorStorm_Rumble_" .. tostring(rumbleAnchor)
			local rumbleCount = 0
			local maxRumbles = math.ceil(duration / 1.5)

			timer.Create(rumbleTimer, 1.5, maxRumbles, function()
				if IsValid(rumbleAnchor) then
					rumbleAnchor:EmitSound("ambient/atmosphere/terrain_rumble1.wav", 92, math.random(85, 95), 0.8, CHAN_STATIC)
					rumbleCount = rumbleCount + 1

					-- Stop if we've reached the end
					if rumbleCount >= maxRumbles then
						timer.Remove(rumbleTimer)
						rumbleAnchor:StopSound("ambient/atmosphere/terrain_rumble1.wav")
						rumbleAnchor:Remove()
					end
				else
					timer.Remove(rumbleTimer)
				end
			end)

			-- Safety cleanup at duration end
			timer.Simple(duration + 0.5, function()
				timer.Remove(rumbleTimer)
				if IsValid(rumbleAnchor) then
					rumbleAnchor:StopSound("ambient/atmosphere/terrain_rumble1.wav")
					rumbleAnchor:Remove()
				end
			end)
		end

		-- Track spawned debris for cleanup
		local spawnedDebris = {}

		-- Helper: Spawn meteor impact
		local function spawnMeteorImpact(impactPos, radius, damage, isFinal)
			-- Final meteor starts much higher and travels slower
			local skyHeight = isFinal and 8000 or 5000
			local travelTime = isFinal and 2.5 or 0.6

			local tr = util.TraceLine({
				start = impactPos + Vector(0, 0, skyHeight),
				endpos = impactPos - Vector(0, 0, 500),
				mask = MASK_SOLID_BRUSHONLY
			})

			if not tr.Hit then return end
			local groundPos = tr.HitPos
			local skyStartPos = impactPos + Vector(0, 0, skyHeight)

			-- Broadcast meteor strike VFX immediately (meteor starts falling)
			net.Start("Arcana_MeteorStorm_MeteorStrike", true)
			net.WriteVector(skyStartPos) -- Actual sky position (varies by meteor type)
			net.WriteVector(groundPos)
			net.WriteFloat(radius)
			net.WriteBool(isFinal or false)
			net.Broadcast()

			-- Delay all impact effects to match travel time
			timer.Simple(travelTime, function()
				if not IsValid(caster) then return end

				-- Impact effects
				local ed = EffectData()
				ed:SetOrigin(groundPos)
				ed:SetScale(radius / 100)
				util.Effect("Explosion", ed, true, true)
				util.Effect("ThumperDust", ed, true, true)

				-- Sounds - much more dramatic for final meteor
				if isFinal then
					-- Layered explosions for massive impact
					sound.Play("ambient/explosions/explode_9.wav", groundPos, 130, 35)
					sound.Play("ambient/explosions/explode_8.wav", groundPos, 128, 40)
					sound.Play("ambient/explosions/explode_7.wav", groundPos, 125, 45)
					sound.Play("physics/concrete/boulder_impact_hard4.wav", groundPos, 120, 50)

					timer.Simple(0.1, function()
						sound.Play("ambient/atmosphere/thunder" .. math.random(1, 4) .. ".wav", groundPos, 125, 35)
						sound.Play("weapons/physcannon/energy_disintegrate5.wav", groundPos, 120, 60)
					end)

					timer.Simple(0.2, function()
						sound.Play("ambient/energy/whiteflash.wav", groundPos, 120, 70)
					end)
				else
					sound.Play("ambient/explosions/explode_" .. math.random(5, 9) .. ".wav", groundPos, 105, math.random(50, 70))
					sound.Play("physics/concrete/boulder_impact_hard" .. math.random(1, 4) .. ".wav", groundPos, 100, math.random(60, 80))
				end

				-- Screen shake - much more intense for final meteor
				local shakeAmp = isFinal and 40 or 15
				local shakeFreq = isFinal and 220 or 120
				local shakeDur = isFinal and 3.5 or 0.8
				util.ScreenShake(groundPos, shakeAmp, shakeFreq, shakeDur, radius * (isFinal and 3.5 or 2.5))

				-- Create crater decal
				util.Decal("Scorch", groundPos + tr.HitNormal * 2, groundPos - tr.HitNormal * 8)

				-- Damage and knockback
				for _, ent in ipairs(ents.FindInSphere(groundPos, radius)) do
					if not IsValid(ent) or ent == caster then continue end

					local dist = ent:WorldSpaceCenter():Distance(groundPos)
					local falloff = 1 - (dist / radius)
					local actualDamage = damage * falloff

					if ent:IsPlayer() or ent:IsNPC() or (ent.IsNextBot and ent:IsNextBot()) then
						local dmg = DamageInfo()
						dmg:SetDamage(actualDamage)
						dmg:SetDamageType(bit.bor(DMG_BLAST, DMG_BURN))
						dmg:SetAttacker(IsValid(caster) and caster or game.GetWorld())
						dmg:SetInflictor(IsValid(caster) and caster or game.GetWorld())
						Arcane:TakeDamageInfo(ent, dmg)

						-- Knockback
						local dir = (ent:WorldSpaceCenter() - groundPos):GetNormalized()
						if ent.SetVelocity then
							local force = isFinal and 1200 or 800
							ent:SetVelocity(dir * force * falloff + Vector(0, 0, 400 * falloff))
						end
						if ent.SetGroundEntity then
							ent:SetGroundEntity(NULL)
						end
					else
						-- Physics objects
						local phys = ent:GetPhysicsObject()
						if IsValid(phys) then
							local dir = (ent:WorldSpaceCenter() - groundPos):GetNormalized()
							phys:Wake()
							local force = isFinal and 200000 or 120000
							phys:ApplyForceCenter(dir * force * falloff + Vector(0, 0, 50000 * falloff))
						end

						-- Ignite objects
						if not ent:IsOnFire() and falloff > 0.3 then
							ent:Ignite(math.random(5, 10), 0)
						end
					end
				end

				-- Spawn earth fissures and pillars around impact
				local fissureCount = isFinal and 12 or 4
			for i = 1, fissureCount do
				local angle = (i / fissureCount) * math.pi * 2 + math.Rand(-0.3, 0.3)
				local fissureDist = math.Rand(radius * 0.3, radius * 0.9)
				local fissurePos = groundPos + Vector(math.cos(angle) * fissureDist, math.sin(angle) * fissureDist, 0)

				timer.Simple(math.Rand(0.1, 0.4), function()
					local trFissure = util.TraceLine({
						start = fissurePos + Vector(0, 0, 200),
						endpos = fissurePos - Vector(0, 0, 500),
						mask = MASK_SOLID_BRUSHONLY
					})

					if not trFissure.Hit then return end

					-- Spawn earth pillar
					local pillar = ents.Create("prop_physics")
					if not IsValid(pillar) then return end

					local models = {
						"models/props_wasteland/rockcliff01b.mdl",
						"models/props_wasteland/rockcliff01c.mdl",
						"models/props_wasteland/rockcliff01f.mdl",
						"models/props_wasteland/rockcliff01j.mdl",
						"models/props_wasteland/rockcliff01k.mdl"
					}
					pillar:SetModel(models[math.random(#models)])

					local spawnPos = trFissure.HitPos - trFissure.HitNormal * 80
					local targetPos = trFissure.HitPos + trFissure.HitNormal * 10

					pillar:SetPos(spawnPos)
					pillar:SetAngles(Angle(0, math.random(0, 360), 0))
					pillar:Spawn()
					pillar:SetCollisionGroup(COLLISION_GROUP_PASSABLE_DOOR)

					if pillar.CPPISetOwner then
						pillar:CPPISetOwner(caster)
					end

					local phys = pillar:GetPhysicsObject()
					if IsValid(phys) then
						phys:EnableMotion(false)
					end

					spawnedDebris[#spawnedDebris + 1] = pillar

					-- Animate rising
					local riseTime = 0.5
					local startTime = CurTime()
					local riseTimer = "Arcana_MeteorStorm_Rise_" .. tostring(pillar)
					timer.Create(riseTimer, 0.02, math.ceil(riseTime / 0.02), function()
						if not IsValid(pillar) then timer.Remove(riseTimer) return end
						local progress = math.Clamp((CurTime() - startTime) / riseTime, 0, 1)
						pillar:SetPos(LerpVector(progress, spawnPos, targetPos))
						if progress >= 1 then timer.Remove(riseTimer) end
					end)

					-- Effects
					sound.Play("physics/concrete/concrete_break" .. math.random(2, 3) .. ".wav", trFissure.HitPos, 90, math.random(80, 100))
					local dustEd = EffectData()
					dustEd:SetOrigin(trFissure.HitPos)
					util.Effect("ThumperDust", dustEd, true, true)

					-- Broadcast fissure VFX
					net.Start("Arcana_MeteorStorm_Fissure", true)
					net.WriteVector(trFissure.HitPos)
					net.WriteFloat(math.Rand(150, 250))
					net.Broadcast()

					-- Damage nearby entities
					for _, e in ipairs(ents.FindInSphere(trFissure.HitPos, 220)) do
						if not IsValid(e) or e == caster or e == pillar then continue end
						if e:IsPlayer() or e:IsNPC() or (e.IsNextBot and e:IsNextBot()) then
							local dmg = DamageInfo()
							dmg:SetDamage(isFinal and 150 or 80)
							dmg:SetDamageType(DMG_CRUSH)
							dmg:SetAttacker(IsValid(caster) and caster or game.GetWorld())
							dmg:SetInflictor(IsValid(caster) and caster or game.GetWorld())
							e:TakeDamageInfo(dmg)
							if e.SetVelocity then
								e:SetVelocity(Vector(0, 0, 600))
							end
						end
					end

					-- Remove pillar after duration
					timer.Simple(duration - (CurTime() - startTime), function()
						if IsValid(pillar) then pillar:Remove() end
					end)
				end)
			end

			-- Spawn meteor debris
			local debrisCount = isFinal and 24 or 6
			for i = 1, debrisCount do
				local debris = ents.Create("prop_physics")
				if not IsValid(debris) then continue end

				local debrisModels = {
					"models/props_debris/concrete_chunk05g.mdl",
					"models/props_junk/rock001a.mdl"
				}
				debris:SetModel(debrisModels[math.random(#debrisModels)])
				debris:SetMaterial("models/props_wasteland/rockcliff02b")

				local angle = math.Rand(0, math.pi * 2)
				local dist = math.Rand(radius * 0.2, radius * 0.8)
				local debrisPos = groundPos + Vector(math.cos(angle) * dist, math.sin(angle) * dist, math.Rand(50, 150))

				debris:SetPos(debrisPos)
				debris:SetAngles(AngleRand())
				debris:Spawn()
				debris:SetModelScale(math.Rand(2.5, 4.5), 0)
				debris:Ignite(math.random(8, 15), 0)

				if debris.CPPISetOwner then
					debris:CPPISetOwner(caster)
				end

				local phys = debris:GetPhysicsObject()
				if IsValid(phys) then
					phys:Wake()
					phys:SetMass(math.Rand(150, 300))
					local dir = VectorRand()
					dir.z = math.abs(dir.z) * 0.5
					phys:ApplyForceCenter(dir * math.Rand(80000, 150000))
				end

				spawnedDebris[#spawnedDebris + 1] = debris

				timer.Simple(duration, function()
					if IsValid(debris) then debris:Remove() end
				end)
			end
			end) -- Close the timer.Simple for impact delay
		end

		-- PHASE 2: Meteor storm (smaller meteors)
		for i = 1, meteorCount do
			local delay = i * meteorInterval
			timer.Simple(delay, function()
				if not IsValid(caster) then return end

				-- Random position within radius
				local angle = math.Rand(0, math.pi * 2)
				local dist = math.Rand(baseRadius * 0.2, baseRadius * 0.95)
				local meteorPos = center + Vector(math.cos(angle) * dist, math.sin(angle) * dist, 0)

				-- Warning whistle sound as meteor begins descent
				sound.Play("weapons/mortar/mortar_shell_incomming1.wav", meteorPos, 95, math.random(90, 110))

				spawnMeteorImpact(meteorPos, 450, 120, false)
			end)
		end

		-- PHASE 3: Final massive central meteor - slow and imposing
		local finalMeteorDelay = (meteorCount + 2) * meteorInterval -- Give more time after last small meteor
		timer.Simple(finalMeteorDelay, function()
			if not IsValid(caster) then return end

			-- First warning - distant rumble
			sound.Play("ambient/atmosphere/thunder" .. math.random(1, 4) .. ".wav", center, 110, 35)
			util.ScreenShake(center, 5, 80, 1.5, baseRadius * 2)

			-- Second warning after pause
			timer.Simple(1.5, function()
				if not IsValid(caster) then return end
				sound.Play("ambient/wind/wind_rooftop1.wav", center, 105, 50)
				sound.Play("ambient/atmosphere/terrain_rumble1.wav", center, 100, 70)
				util.ScreenShake(center, 8, 100, 2.0, baseRadius * 2)
			end)

			-- Broadcast final impact warning (visual cue in sky)
			timer.Simple(2.5, function()
				if not IsValid(caster) then return end

				net.Start("Arcana_MeteorStorm_FinalImpact", true)
				net.WriteVector(center)
				net.Broadcast()

				-- Deep, ominous incoming sound
				sound.Play("weapons/mortar/mortar_shell_incomming1.wav", center, 115, 40)
				sound.Play("ambient/atmosphere/thunder" .. math.random(1, 4) .. ".wav", center, 110, 30)

				-- Spawn the massive meteor with longer travel time
				spawnMeteorImpact(center, 1100, 400, true)
			end)
		end)

		-- Cleanup at end
		timer.Simple(duration, function()
			for _, debris in ipairs(spawnedDebris) do
				if IsValid(debris) then debris:Remove() end
			end

			-- Stop any lingering sounds in the area (safety measure)
			for _, ent in ipairs(ents.FindInSphere(center, baseRadius * 2)) do
				if IsValid(ent) and ent:GetClass() == "info_target" then
					ent:StopSound("ambient/atmosphere/terrain_rumble1.wav")
					ent:StopSound("ambient/atmosphere/city_rumble_loop1.wav")
					ent:StopSound("ambient/wind/wind_rooftop1.wav")
				end
			end
		end)
	end) -- End of 0.5s pause timer

	return true
	end,
	trigger_phrase_aliases = {
		"meteor storm",
		"meteors",
		"meteor",
		"storm",
	}
})

if CLIENT then
	local matBeam = Material("effects/laser1")
	local matGlow = Material("sprites/light_glow02_add")
	local matRing = Material("effects/select_ring")
	local matFlare = Material("effects/blueflare1")

	local activeMeteors = {} -- Active meteor trails being rendered
	local impactRings = {} -- Ground impact ring effects
	local fissureEffects = {} -- Fissure crack effects
	local darkeningData = {} -- Sky darkening effect per spell instance
	local meteorStormCastingData = {} -- Casting phase circle/particle data

	-- Climax VFX: Dramatic cast completion moment
	net.Receive("Arcana_MeteorStorm_Climax", function()
		local center = net.ReadVector()
		local radius = net.ReadFloat()
		local caster = net.ReadEntity()

		-- Massive energy burst flash
		local emitter = ParticleEmitter(center)
		if emitter then
			-- Central explosion burst
			for i = 1, 80 do
				local angle = (i / 80) * math.pi * 2
				local p = emitter:Add("sprites/light_glow02_add", center + Vector(0, 0, 100))
				if p then
					local speed = math.Rand(500, 1200)
					p:SetVelocity(Vector(math.cos(angle) * speed, math.sin(angle) * speed, math.Rand(-200, 400)))
					p:SetDieTime(math.Rand(0.8, 1.5))
					p:SetStartAlpha(255)
					p:SetEndAlpha(0)
					p:SetStartSize(math.Rand(40, 90))
					p:SetEndSize(0)
					p:SetColor(255, 220, 180)
					p:SetGravity(Vector(0, 0, -200))
				end
			end

			-- Expanding ring blast
			for i = 1, 60 do
				local angle = (i / 60) * math.pi * 2
				local dist = math.Rand(50, 200)
				local pos = center + Vector(math.cos(angle) * dist, math.sin(angle) * dist, 20)
				local p = emitter:Add("effects/yellowflare", pos)
				if p then
					local dir = Vector(math.cos(angle), math.sin(angle), 0)
					p:SetVelocity(dir * math.Rand(800, 1500))
					p:SetDieTime(math.Rand(0.5, 1.0))
					p:SetStartAlpha(255)
					p:SetEndAlpha(0)
					p:SetStartSize(math.Rand(60, 120))
					p:SetEndSize(math.Rand(150, 250))
					p:SetColor(255, 200, 150)
				end
			end

			-- Upward energy pillars
			for i = 1, 12 do
				local angle = (i / 12) * math.pi * 2
				local dist = math.Rand(100, radius * 0.5)
				local pos = center + Vector(math.cos(angle) * dist, math.sin(angle) * dist, 0)
				local p = emitter:Add("sprites/light_glow02_add", pos)
				if p then
					p:SetVelocity(Vector(0, 0, math.Rand(600, 1000)))
					p:SetDieTime(math.Rand(0.8, 1.2))
					p:SetStartAlpha(255)
					p:SetEndAlpha(0)
					p:SetStartSize(math.Rand(80, 150))
					p:SetEndSize(math.Rand(40, 80))
					p:SetColor(255, 230, 200)
					p:SetAirResistance(50)
				end
			end

			emitter:Finish()
		end

		-- Make all charging circles pulse outward and fade
		if IsValid(caster) and meteorStormCastingData[caster] then
			local data = meteorStormCastingData[caster]

			-- Pulse all circles
			for _, circle in ipairs(data.circles) do
				if circle and circle.IsActive and circle:IsActive() then
					-- Make them grow and fade out quickly
					timer.Create("Arcana_MeteorStorm_CirclePulse_" .. tostring(circle), 0, 0, function()
						if not circle or not circle.IsActive or not circle:IsActive() then
							timer.Remove("Arcana_MeteorStorm_CirclePulse_" .. tostring(circle))
							return
						end
						local elapsed = CurTime() - (circle.climaxStart or CurTime())
						if not circle.climaxStart then
							circle.climaxStart = CurTime()
							circle.originalRadius = circle.radius or 80
						end

						if elapsed < 0.5 then
							-- Grow and fade
							local progress = elapsed / 0.5
							circle.radius = circle.originalRadius * (1 + progress * 0.5)
							circle.alpha = 255 * (1 - progress)
						else
							-- Done, remove timer
							timer.Remove("Arcana_MeteorStorm_CirclePulse_" .. tostring(circle))
						end
					end)
				end
			end

			-- Pulse satellites
			for _, satData in ipairs(data.satellites) do
				if satData.circle and satData.circle.IsActive and satData.circle:IsActive() then
					local circle = satData.circle
					timer.Create("Arcana_MeteorStorm_CirclePulse_" .. tostring(circle), 0, 0, function()
						if not circle or not circle.IsActive or not circle:IsActive() then
							timer.Remove("Arcana_MeteorStorm_CirclePulse_" .. tostring(circle))
							return
						end
						local elapsed = CurTime() - (circle.climaxStart or CurTime())
						if not circle.climaxStart then
							circle.climaxStart = CurTime()
							circle.originalRadius = circle.radius or 60
						end

						if elapsed < 0.5 then
							local progress = elapsed / 0.5
							circle.radius = circle.originalRadius * (1 + progress * 0.5)
							circle.alpha = 255 * (1 - progress)
						else
							-- Done, remove timer
							timer.Remove("Arcana_MeteorStorm_CirclePulse_" .. tostring(circle))
						end
					end)
				end
			end

			-- Clean up the charging data after climax completes
			timer.Simple(0.6, function()
				meteorStormCastingData[caster] = nil
			end)
		end

		-- Brief whiteout flash effect (only for players looking at the impact area or caster)
		local climaxFlashData = {
			startTime = CurTime(),
			center = center,
			radius = radius,
			caster = caster
		}

		hook.Add("RenderScreenspaceEffects", "Arcana_MeteorStorm_ClimaxFlash", function()
			local ply = LocalPlayer()
			if not IsValid(ply) then return end

			local elapsed = CurTime() - climaxFlashData.startTime

			if elapsed < 0.4 then
				-- Caster always sees full effect
				local viewFalloff = 1

				if ply ~= climaxFlashData.caster then
					-- Check if player is looking towards the impact area
					local eyePos = ply:EyePos()
					local dirToCenter = (climaxFlashData.center - eyePos):GetNormalized()
					local viewDir = ply:GetAimVector()

					-- Dot product: 1 = looking directly at, 0 = perpendicular, -1 = looking away
					local dot = viewDir:Dot(dirToCenter)

					-- Only show effect if looking somewhat towards it (within ~90 degree cone)
					if dot < 0.2 then return end -- Not looking at it

					-- Smooth falloff based on how directly they're looking at it
					-- 1.0 at center of view, fades to 0 at edges
					viewFalloff = math.Clamp((dot - 0.2) / 0.8, 0, 1)
				end

				-- Flash intensity over time
				local alpha = 1
				if elapsed < 0.1 then
					alpha = elapsed / 0.1 -- Fade in
				else
					alpha = 1 - ((elapsed - 0.1) / 0.3) -- Fade out
				end

				-- Apply view-based falloff
				alpha = alpha * viewFalloff

				DrawColorModify({
					["$pp_colour_addr"] = 0.3 * alpha,
					["$pp_colour_addg"] = 0.2 * alpha,
					["$pp_colour_addb"] = 0.1 * alpha,
					["$pp_colour_brightness"] = 0.2 * alpha,
					["$pp_colour_contrast"] = 1 + (0.3 * alpha),
					["$pp_colour_colour"] = 1,
					["$pp_colour_mulr"] = 0,
					["$pp_colour_mulg"] = 0,
					["$pp_colour_mulb"] = 0
				})
			else
				hook.Remove("RenderScreenspaceEffects", "Arcana_MeteorStorm_ClimaxFlash")
			end
		end)
	end)

	-- Initial VFX: Sky darkening and warning circles
	net.Receive("Arcana_MeteorStorm_InitialVFX", function()
		local center = net.ReadVector()
		local radius = net.ReadFloat()
		local duration = net.ReadFloat()

		-- Store darkening data for this spell instance
		local instanceId = tostring(center) .. "_" .. tostring(CurTime())
		darkeningData[instanceId] = {
			center = center,
			radius = radius,
			startTime = CurTime(),
			endTime = CurTime() + duration,
			intensity = 0
		}

		-- Dust rising from ground as reality warps
		local emitter = ParticleEmitter(center)
		if emitter then
			for i = 1, 120 do
				local angle = (i / 60) * math.pi * 2
				local dist = math.Rand(radius * 0.3, radius)
				local pos = center + Vector(math.cos(angle) * dist, math.sin(angle) * dist, 0)

				local p = emitter:Add("particle/particle_smokegrenade", pos)
				if p then
					p:SetVelocity(Vector(0, 0, math.Rand(80, 180)))
					p:SetDieTime(math.Rand(2.5, 4.0))
					p:SetStartAlpha(120)
					p:SetEndAlpha(0)
					p:SetStartSize(math.Rand(30, 50))
					p:SetEndSize(math.Rand(90, 150))
					p:SetColor(90, 80, 70)
					p:SetAirResistance(100)
					p:SetGravity(Vector(0, 0, 20))
				end
			end
			emitter:Finish()
		end

		-- Remove darkening data when spell ends
		timer.Simple(duration, function()
			darkeningData[instanceId] = nil
		end)
	end)

	-- Meteor strike trail and impact
	net.Receive("Arcana_MeteorStorm_MeteorStrike", function()
		local skyPos = net.ReadVector()
		local groundPos = net.ReadVector()
		local radius = net.ReadFloat()
		local isFinal = net.ReadBool()

		local travelTime = isFinal and 2.5 or 0.6 -- Final meteor is much slower and more imposing

		-- Create meteor trail effect
		local meteorData = {
			startPos = skyPos,
			endPos = groundPos,
			startTime = CurTime(),
			impactTime = CurTime() + travelTime,
			radius = isFinal and 120 or 40, -- Final meteor is much larger
			isFinal = isFinal,
			trailAlpha = 255,
			travelTime = travelTime
		}
		table.insert(activeMeteors, meteorData)

		-- Sky flash at meteor spawn point
		local flashEmitter = ParticleEmitter(skyPos)
		if flashEmitter then
			for i = 1, (isFinal and 15 or 5) do
				local p = flashEmitter:Add("sprites/light_glow02_add", skyPos + VectorRand() * (isFinal and 300 or 150))
				if p then
					p:SetVelocity(Vector(0, 0, 0))
					p:SetDieTime(0.3)
					p:SetStartAlpha(255)
					p:SetEndAlpha(0)
					p:SetStartSize(isFinal and math.Rand(100, 200) or math.Rand(40, 80))
					p:SetEndSize(0)
					p:SetColor(255, 200, 150)
				end
			end
			flashEmitter:Finish()
		end

		-- Spawn trail particles progressively as meteor falls
		local particleSpawnSteps = isFinal and 40 or 12 -- Many more steps for final meteor
		for step = 0, particleSpawnSteps do
			timer.Simple(step * (travelTime / particleSpawnSteps), function()
				local progress = step / particleSpawnSteps
				local currentPos = LerpVector(progress, skyPos, groundPos)
				local dir = (groundPos - skyPos):GetNormalized()

				local emitter = ParticleEmitter(currentPos)
				if not emitter then return end

				-- Fire trail particles - more intense for final meteor
				local particleCount = isFinal and 15 or 4
				for i = 1, particleCount do
					local spread = isFinal and 50 or 20
					local p = emitter:Add("effects/fire_cloud" .. math.random(1, 2), currentPos + VectorRand() * spread)
					if p then
						p:SetVelocity(dir * math.Rand(100, 300) + VectorRand() * (isFinal and 120 or 80))
						p:SetDieTime(math.Rand(isFinal and 1.5 or 0.6, isFinal and 2.5 or 1.2))
						p:SetStartAlpha(255)
						p:SetEndAlpha(0)
						p:SetStartSize(isFinal and math.Rand(80, 130) or math.Rand(25, 40))
						p:SetEndSize(isFinal and math.Rand(180, 260) or math.Rand(50, 75))
						p:SetColor(255, math.random(150, 200), 80)
						p:SetAirResistance(60)
						p:SetGravity(Vector(0, 0, -100))
					end
				end

				-- Smoke trail - thicker for final meteor
				local smokeCount = isFinal and 3 or 1
				for i = 1, smokeCount do
					local s = emitter:Add("particle/particle_smokegrenade", currentPos + VectorRand() * (isFinal and 40 or 15))
					if s then
						s:SetVelocity(VectorRand() * (isFinal and 100 or 60))
						s:SetDieTime(math.Rand(isFinal and 2.0 or 1.0, isFinal and 3.5 or 1.8))
						s:SetStartAlpha(180)
						s:SetEndAlpha(0)
						s:SetStartSize(isFinal and math.Rand(60, 100) or math.Rand(18, 30))
						s:SetEndSize(isFinal and math.Rand(150, 220) or math.Rand(40, 60))
						s:SetColor(70, 60, 50)
						s:SetAirResistance(80)
					end
				end

				emitter:Finish()
			end)
		end

		-- Impact ring effect (when meteor actually hits)
		timer.Simple(travelTime, function()
			local ringData = {
				pos = groundPos,
				radius = radius,
				maxRadius = radius,
				startTime = CurTime(),
				duration = isFinal and 1.5 or 1.0,
				isFinal = isFinal
			}
			table.insert(impactRings, ringData)

			-- Impact particles
			local impactEmitter = ParticleEmitter(groundPos)
			if impactEmitter then
				local particleCount = isFinal and 350 or 100

				-- Fire explosion - much more intense for final meteor
				for i = 1, particleCount do
					local angle = math.Rand(0, math.pi * 2)
					local speed = math.Rand(isFinal and 400 or 300, isFinal and 1200 or 800)
					local vel = Vector(math.cos(angle) * speed, math.sin(angle) * speed, math.Rand(isFinal and 300 or 200, isFinal and 900 or 600))

					local p = impactEmitter:Add("effects/fire_cloud" .. math.random(1, 2), groundPos)
					if p then
						p:SetVelocity(vel)
						p:SetDieTime(math.Rand(isFinal and 2.0 or 1.0, isFinal and 4.0 or 2.5))
						p:SetStartAlpha(255)
						p:SetEndAlpha(0)
						p:SetStartSize(isFinal and math.Rand(120, 200) or math.Rand(40, 70))
						p:SetEndSize(isFinal and math.Rand(280, 420) or math.Rand(90, 140))
						p:SetColor(255, math.random(100, 180), 50)
						p:SetAirResistance(40)
						p:SetGravity(Vector(0, 0, -300))
					end
				end

				-- Rocks and debris - much more for final meteor
				for i = 1, particleCount / (isFinal and 1.5 or 2) do
					local angle = math.Rand(0, math.pi * 2)
					local speed = math.Rand(isFinal and 600 or 400, isFinal and 1400 or 1000)
					local vel = Vector(math.cos(angle) * speed, math.sin(angle) * speed, math.Rand(isFinal and 600 or 400, isFinal and 1200 or 900))

					local mat = (math.random() < 0.5) and "effects/fleck_cement1" or "effects/fleck_cement2"
					local d = impactEmitter:Add(mat, groundPos)
					if d then
						d:SetVelocity(vel)
						d:SetDieTime(math.Rand(2.0, 4.5))
						d:SetStartAlpha(255)
						d:SetEndAlpha(0)
						d:SetStartSize(math.Rand(isFinal and 8 or 5, isFinal and 18 or 12))
						d:SetEndSize(0)
						d:SetRoll(math.Rand(0, 360))
						d:SetRollDelta(math.Rand(-15, 15))
						d:SetColor(140, 120, 100)
						d:SetAirResistance(20)
						d:SetGravity(Vector(0, 0, -600))
						d:SetCollide(true)
						d:SetBounce(0.4)
					end
				end

				-- Dust cloud - massive for final meteor
				for i = 1, particleCount / (isFinal and 2 or 3) do
					local p = impactEmitter:Add("particle/particle_smokegrenade", groundPos + VectorRand() * radius * 0.5)
					if p then
						p:SetVelocity(VectorRand() * math.Rand(isFinal and 300 or 200, isFinal and 700 or 500) + Vector(0, 0, math.Rand(isFinal and 200 or 100, isFinal and 500 or 300)))
						p:SetDieTime(math.Rand(isFinal and 3.0 or 2.0, isFinal and 6.0 or 4.0))
						p:SetStartAlpha(200)
						p:SetEndAlpha(0)
						p:SetStartSize(math.Rand(isFinal and 90 or 60, isFinal and 150 or 100))
						p:SetEndSize(math.Rand(isFinal and 250 or 150, isFinal and 400 or 250))
						p:SetColor(100, 90, 80)
						p:SetAirResistance(100)
						p:SetGravity(Vector(0, 0, 50))
					end
				end

				impactEmitter:Finish()
			end
		end)
	end)

	-- Final impact warning
	net.Receive("Arcana_MeteorStorm_FinalImpact", function()
		local center = net.ReadVector()

		-- Massive flash warning effect in the sky
		local emitter = ParticleEmitter(center)
		if emitter then
			-- Bright expanding ring in sky
			for i = 1, 80 do
				local angle = (i / 80) * math.pi * 2
				local dist = math.Rand(300, 800)
				local skyPos = center + Vector(math.cos(angle) * dist, math.sin(angle) * dist, 5000)

				local p = emitter:Add("sprites/light_glow02_add", skyPos)
				if p then
					p:SetVelocity(Vector(0, 0, 0))
					p:SetDieTime(1.5)
					p:SetStartAlpha(255)
					p:SetEndAlpha(0)
					p:SetStartSize(math.Rand(120, 200))
					p:SetEndSize(0)
					p:SetColor(255, 220, 150)
				end
			end

			-- Central bright spot
			for i = 1, 30 do
				local p = emitter:Add("sprites/light_glow02_add", center + Vector(0, 0, 5000) + VectorRand() * 200)
				if p then
					p:SetVelocity(Vector(0, 0, 0))
					p:SetDieTime(2.0)
					p:SetStartAlpha(255)
					p:SetEndAlpha(0)
					p:SetStartSize(math.Rand(150, 250))
					p:SetEndSize(0)
					p:SetColor(255, 240, 200)
				end
			end
			emitter:Finish()
		end

		-- Continuous ominous rumble during descent (2.5s) using non-looping alternatives
		-- Use short rumbles instead of loop sounds to avoid lingering
		sound.Play("ambient/atmosphere/terrain_rumble1.wav", center, 110, 60)
		sound.Play("ambient/wind/wind_hit1.wav", center, 105, 50)

		-- Play additional rumble layers over time
		timer.Simple(0.8, function()
			sound.Play("ambient/atmosphere/terrain_rumble1.wav", center, 105, 65)
			sound.Play("ambient/atmosphere/thunder" .. math.random(1, 4) .. ".wav", center, 100, 40)
		end)

		timer.Simple(1.6, function()
			sound.Play("ambient/wind/wind_hit2.wav", center, 100, 55)
			sound.Play("ambient/atmosphere/terrain_rumble1.wav", center, 100, 70)
		end)
	end)

	-- Fissure/crack effect
	net.Receive("Arcana_MeteorStorm_Fissure", function()
		local pos = net.ReadVector()
		local radius = net.ReadFloat()

		local fissureData = {
			pos = pos,
			radius = radius,
			startTime = CurTime(),
			duration = 0.8
		}
		table.insert(fissureEffects, fissureData)

		-- Fissure dust
		local emitter = ParticleEmitter(pos)
		if emitter then
			for i = 1, 40 do
				local p = emitter:Add("particle/particle_smokegrenade", pos + VectorRand() * radius * 0.3)
				if p then
					p:SetVelocity(VectorRand() * 150 + Vector(0, 0, math.Rand(100, 250)))
					p:SetDieTime(math.Rand(1.0, 2.0))
					p:SetStartAlpha(180)
					p:SetEndAlpha(0)
					p:SetStartSize(math.Rand(25, 45))
					p:SetEndSize(math.Rand(70, 120))
					p:SetColor(110, 100, 90)
					p:SetAirResistance(90)
				end
			end
			emitter:Finish()
		end
	end)

	-- Render meteor trails
	hook.Add("PostDrawTranslucentRenderables", "Arcana_MeteorStorm_RenderMeteors", function()
		-- Clean up expired meteors
		for i = #activeMeteors, 1, -1 do
			if CurTime() > activeMeteors[i].impactTime + 0.1 then
				table.remove(activeMeteors, i)
			end
		end

		-- Render active meteors
		for _, meteor in ipairs(activeMeteors) do
			local elapsed = CurTime() - meteor.startTime
			local travelDuration = meteor.travelTime or 0.6
			local progress = math.Clamp(elapsed / travelDuration, 0, 1)

			if progress <= 1 then
				local currentPos = LerpVector(progress, meteor.startPos, meteor.endPos)
				local dir = (meteor.endPos - meteor.startPos):GetNormalized()

				-- Draw glowing meteor core
				render.SetMaterial(matGlow)
				local glowSize = meteor.radius * (meteor.isFinal and 3.5 or 1.2)
				render.DrawSprite(currentPos, glowSize, glowSize, Color(255, 200, 120, 255))

				-- Inner bright core (extra bright for final meteor)
				local coreSize = glowSize * (meteor.isFinal and 0.6 or 0.5)
				render.DrawSprite(currentPos, coreSize, coreSize, Color(255, 240, 200, 255))

				-- Innermost white-hot core for final meteor
				if meteor.isFinal then
					render.DrawSprite(currentPos, coreSize * 0.4, coreSize * 0.4, Color(255, 255, 255, 255))
				end

				-- Draw trailing beam
				local trailLength = meteor.isFinal and 2000 or 600
				local trailEnd = currentPos - dir * trailLength
				local segments = meteor.isFinal and 24 or 10

				for i = 0, segments do
					local segProgress = i / segments
					local segPos = LerpVector(segProgress, currentPos, trailEnd)
					local segAlpha = (1 - segProgress) * (meteor.isFinal and 240 or 220)
					local segSize = meteor.radius * (1 - segProgress * 0.8)

					render.SetMaterial(matGlow)
					render.DrawSprite(segPos, segSize, segSize, Color(255, 180 - (segProgress * 50), 100 - (segProgress * 30), segAlpha))
				end

				-- Add multiple flare effects for final meteor
				render.SetMaterial(matFlare)
				if meteor.isFinal then
					-- Large outer flare
					render.DrawSprite(currentPos, glowSize * 2.5, glowSize * 2.5, Color(255, 150, 80, 150))
					-- Medium flare with rotation effect
					render.DrawSprite(currentPos, glowSize * 1.8, glowSize * 1.8, Color(255, 180, 100, 180))
					-- Inner intense flare
					render.DrawSprite(currentPos, glowSize * 1.2, glowSize * 1.2, Color(255, 200, 120, 220))
				else
					render.DrawSprite(currentPos, glowSize * 1.5, glowSize * 1.5, Color(255, 150, 80, 180))
				end
			end
		end

		-- Clean up expired impact rings
		for i = #impactRings, 1, -1 do
			local ring = impactRings[i]
			if CurTime() > ring.startTime + ring.duration then
				table.remove(impactRings, i)
			end
		end

		-- Render impact rings
		for _, ring in ipairs(impactRings) do
			local elapsed = CurTime() - ring.startTime
			local progress = math.Clamp(elapsed / ring.duration, 0, 1)
			local currentRadius = Lerp(progress, ring.maxRadius * 0.1, ring.maxRadius)
			local alpha = (1 - progress) * (ring.isFinal and 255 or 200)

			render.SetMaterial(matRing)
			render.DrawQuadEasy(ring.pos + Vector(0, 0, 2), Vector(0, 0, 1), currentRadius, currentRadius, Color(255, 120, 40, alpha), 0)

			render.SetMaterial(matGlow)
			render.DrawSprite(ring.pos + Vector(0, 0, 4), currentRadius * 0.5, currentRadius * 0.5, Color(255, 150, 60, alpha * 0.6))
		end

		-- Clean up expired fissures
		for i = #fissureEffects, 1, -1 do
			local fissure = fissureEffects[i]
			if CurTime() > fissure.startTime + fissure.duration then
				table.remove(fissureEffects, i)
			end
		end

		-- Render fissure cracks
		for _, fissure in ipairs(fissureEffects) do
			local elapsed = CurTime() - fissure.startTime
			local progress = math.Clamp(elapsed / fissure.duration, 0, 1)
			local currentRadius = Lerp(progress, 0, fissure.radius)
			local alpha = (1 - progress) * 180

			render.SetMaterial(matRing)
			render.DrawQuadEasy(fissure.pos + Vector(0, 0, 1), Vector(0, 0, 1), currentRadius, currentRadius, Color(180, 90, 30, alpha), 0)
		end
	end)

	-- Sky darkening effect (only for players looking at the impact area)
	hook.Add("RenderScreenspaceEffects", "Arcana_MeteorStorm_Darken", function()
		local ply = LocalPlayer()
		if not IsValid(ply) then return end

		for instanceId, data in pairs(darkeningData) do
			local elapsed = CurTime() - data.startTime
			local totalDuration = data.endTime - data.startTime

			-- Gradual darkening in first 3 seconds, then maintain, then fade out in last 2 seconds
			local fadeInDur = 3
			local fadeOutStart = totalDuration - 2

			local targetIntensity = 0
			if elapsed < fadeInDur then
				targetIntensity = (elapsed / fadeInDur) * 0.4
			elseif elapsed < fadeOutStart then
				targetIntensity = 0.4
			else
				local fadeOutProgress = (elapsed - fadeOutStart) / 2
				targetIntensity = 0.4 * (1 - fadeOutProgress)
			end

			-- View-based falloff: only darken sky if looking towards the impact
			local eyePos = ply:EyePos()
			local dirToCenter = (data.center - eyePos):GetNormalized()
			local viewDir = ply:GetAimVector()

			-- Dot product: 1 = looking directly at, 0 = perpendicular, -1 = looking away
			local dot = viewDir:Dot(dirToCenter)

			-- Only show darkening if looking somewhat upward/towards it
			if dot < 0.1 then continue end -- Not looking at it

			-- Smooth falloff based on how directly they're looking at it
			local viewFalloff = math.Clamp((dot - 0.1) / 0.9, 0, 1)
			targetIntensity = targetIntensity * viewFalloff

			data.intensity = Lerp(0.1, data.intensity, targetIntensity)

			-- Apply darkening
			if data.intensity > 0.01 then
				local tab = {
					["$pp_colour_addr"] = 0,
					["$pp_colour_addg"] = 0,
					["$pp_colour_addb"] = 0,
					["$pp_colour_brightness"] = -data.intensity,
					["$pp_colour_contrast"] = 1 + data.intensity * 0.3,
					["$pp_colour_colour"] = 1 - data.intensity * 0.2,
					["$pp_colour_mulr"] = 0,
					["$pp_colour_mulg"] = 0,
					["$pp_colour_mulb"] = 0
				}
				DrawColorModify(tab)

				-- Orange tint
				DrawBloom(0.3 * data.intensity, data.intensity * 2, 3, 3, 2, 0.8, 0.5, 0.3, 0.2)
			end
		end
	end)

	-- Casting-time effects around caster and ground target
	hook.Add("Arcana_BeginCastingVisuals", "Arcana_MeteorStorm_CastCharge", function(caster, spellId, castTime)
		if spellId ~= "meteor_storm" then return end
		if not IsValid(caster) then return end

		local color = Color(200, 120, 60, 255)
		local startTime = CurTime()

		-- Store casting data for cleanup
		meteorStormCastingData[caster] = {
			startTime = startTime,
			circles = {},
			satellites = {}
		}

		-- Ground target indicator (follows aim)
		Arcane:CreateFollowingCastCircle(caster, spellId, castTime, {
			color = color,
			size = 1400,
			intensity = 100,
			positionResolver = function(c)
				return Arcane:ResolveGroundTarget(c, 1500)
			end
		})

		-- PHASE 1: Initial ground circle at caster's feet (0s)
		local groundCircle = MagicCircle.CreateMagicCircle(caster:GetPos() + Vector(0, 0, 2), Angle(0, 0, 0), color, 4, 80, castTime, 2)
		if groundCircle and groundCircle.StartEvolving then
			groundCircle:StartEvolving(castTime, true)
			table.insert(meteorStormCastingData[caster].circles, groundCircle)

			-- Initial thump
			sound.Play("weapons/physcannon/energy_sing_explosion2.wav", caster:GetPos(), 88, 80)
			sound.Play("ambient/energy/newspark0" .. math.random(4, 8) .. ".wav", caster:GetPos(), 85, 75)
			util.ScreenShake(caster:GetPos(), 3, 80, 0.3, 300)
		end

		-- PHASE 2: Stacked vertical circles appear progressively (0-4s)
		local stackHeights = {60, 120, 200}
		local stackSizes = {100, 140, 100}

		for i, height in ipairs(stackHeights) do
			timer.Simple(i * 1.3, function()
				if not IsValid(caster) or not meteorStormCastingData[caster] then return end

				local circle = MagicCircle.CreateMagicCircle(
					caster:GetPos() + Vector(0, 0, height),
					Angle(0, 0, 0),
					color,
					3 + i,
					stackSizes[i],
					castTime - (i * 1.3),
					2
				)

				if circle and circle.StartEvolving then
					circle:StartEvolving(castTime - (i * 1.3), true)
					table.insert(meteorStormCastingData[caster].circles, circle)

					-- Thump sound for each stacked circle (increasing intensity)
					local pitch = 75 + (i * 3) -- Deeper for lower circles
					local volume = 88 + (i * 2) -- Louder for higher circles
					sound.Play("weapons/physcannon/energy_sing_explosion2.wav", caster:GetPos(), volume - 10, pitch - 10)
					sound.Play("ambient/levels/labs/electric_explosion" .. math.random(1, 5) .. ".wav", caster:GetPos(), volume - 5, pitch)
					util.ScreenShake(caster:GetPos(), 3 + i, 90 + (i * 10), 0.4, 350 + (i * 50))
				end
			end)
		end

		-- PHASE 3: Orbiting satellite circles (appear at 3s, orbit for remaining time)
		timer.Simple(3, function()
			if not IsValid(caster) or not meteorStormCastingData[caster] then return end

			local numSatellites = 3
			local orbitRadius = 120
			local orbitHeight = 100

			-- Big thump for satellite spawn
			sound.Play("weapons/physcannon/energy_sing_explosion2.wav", caster:GetPos(), 95, 70)
			sound.Play("ambient/levels/labs/electric_explosion" .. math.random(1, 5) .. ".wav", caster:GetPos(), 93, 65)
			sound.Play("ambient/energy/newspark0" .. math.random(4, 8) .. ".wav", caster:GetPos(), 90, 80)
			util.ScreenShake(caster:GetPos(), 6, 120, 0.6, 500)

			for i = 1, numSatellites do
				local baseAngle = (i / numSatellites) * math.pi * 2

				-- Calculate initial position
				local offsetX = math.cos(baseAngle) * orbitRadius
				local offsetY = math.sin(baseAngle) * orbitRadius
				local initialPos = caster:GetPos() + Vector(offsetX, offsetY, orbitHeight)

				-- Calculate angle to face outward from center (perpendicular to orbit)
				local facingAngle = Angle(90, math.deg(baseAngle), 0)

				local satData = {
					radius = orbitRadius,
					height = orbitHeight,
					baseAngle = baseAngle,
					startTime = CurTime(),
					circle = nil
				}

				local satCircle = MagicCircle.CreateMagicCircle(
					initialPos,
					facingAngle,
					color,
					3,
					40,
					castTime - 3,
					1
				)

				if satCircle and satCircle.StartEvolving then
					satCircle:StartEvolving(castTime - 3, true)
					satData.circle = satCircle
					table.insert(meteorStormCastingData[caster].satellites, satData)
				end
			end
		end)

		-- Update loop for stacked circles and satellites to follow caster
		local updateHook = "Arcana_MeteorStorm_CastUpdate_" .. tostring(caster)
		hook.Add("Think", updateHook, function()
			if not IsValid(caster) or not meteorStormCastingData[caster] then
				hook.Remove("Think", updateHook)
				return
			end

			local data = meteorStormCastingData[caster]
			local casterPos = caster:GetPos()

			-- Update stacked circles
			for i, circleData in ipairs(data.circles) do
				if circleData and circleData.IsActive and circleData:IsActive() then
					circleData.position = casterPos + Vector(0, 0, i == 1 and 2 or stackHeights[i - 1])
				end
			end

			-- Update orbiting satellites
			for _, satData in ipairs(data.satellites) do
				if satData.circle and satData.circle.IsActive and satData.circle:IsActive() then
					local elapsed = CurTime() - satData.startTime
					local spinSpeed = (math.pi * 2) / 6 -- Full rotation every 6 seconds
					local currentAngle = satData.baseAngle + (elapsed * spinSpeed)

					local offsetX = math.cos(currentAngle) * satData.radius
					local offsetY = math.sin(currentAngle) * satData.radius
					local pos = casterPos + Vector(offsetX, offsetY, satData.height)

					satData.circle.position = pos
					-- Update angle to always face outward from center
					satData.circle.angles = Angle(90, math.deg(currentAngle), 0)
				end
			end
		end)

		-- Particle effects during charge
		local particleSteps = math.floor(castTime / 0.5)
		for step = 0, particleSteps do
			timer.Simple(step * 0.5, function()
				if not IsValid(caster) or not meteorStormCastingData[caster] then return end

				local progress = step / particleSteps
				local emitter = ParticleEmitter(caster:GetPos())
				if not emitter then return end

				-- Rising dust/earth particles
				for i = 1, 8 do
					local angle = math.Rand(0, math.pi * 2)
					local dist = math.Rand(20, 80)
					local pos = caster:GetPos() + Vector(math.cos(angle) * dist, math.sin(angle) * dist, 0)

					local p = emitter:Add("particle/particle_smokegrenade", pos)
					if p then
						p:SetVelocity(Vector(0, 0, math.Rand(40, 100)))
						p:SetDieTime(math.Rand(1.5, 2.5))
						p:SetStartAlpha(120)
						p:SetEndAlpha(0)
						p:SetStartSize(math.Rand(15, 25))
						p:SetEndSize(math.Rand(40, 70))
						p:SetColor(100, 90, 80)
						p:SetAirResistance(100)
					end
				end

				-- Floating rock debris (more as charge progresses)
				if progress > 0.3 then
					for i = 1, math.floor(progress * 6) do
						local angle = math.Rand(0, math.pi * 2)
						local dist = math.Rand(30, 100)
						local height = math.Rand(20, 150)
						local pos = caster:GetPos() + Vector(math.cos(angle) * dist, math.sin(angle) * dist, height)

						local mat = (math.random() < 0.5) and "effects/fleck_cement1" or "effects/fleck_cement2"
						local d = emitter:Add(mat, pos)
						if d then
							-- Orbit around caster
							local orbitVel = Vector(-math.sin(angle), math.cos(angle), 0) * 30
							d:SetVelocity(orbitVel + Vector(0, 0, math.Rand(-20, 40)))
							d:SetDieTime(math.Rand(1.0, 2.0))
							d:SetStartAlpha(255)
							d:SetEndAlpha(0)
							d:SetStartSize(math.Rand(3, 6))
							d:SetEndSize(0)
							d:SetRoll(math.Rand(0, 360))
							d:SetRollDelta(math.Rand(-20, 20))
							d:SetColor(130, 120, 110)
							d:SetGravity(Vector(0, 0, -50))
						end
					end
				end

				emitter:Finish()
			end)
		end

		-- Sound effects that build tension (adjusted to work with circle thumps)
		-- Note: Circle thumps at 0s, 1.3s, 2.6s, 3s, 3.9s

		timer.Simple(0, function()
			if not IsValid(caster) then return end
			sound.Play("ambient/atmosphere/terrain_rumble1.wav", caster:GetPos(), 85, 80)
		end)

		timer.Simple(castTime * 0.5, function()
			if not IsValid(caster) then return end
			sound.Play("ambient/atmosphere/thunder" .. math.random(1, 4) .. ".wav", caster:GetPos(), 95, 50)
			util.ScreenShake(caster:GetPos(), 5, 100, 1.0, 400)
		end)

		timer.Simple(castTime * 0.75, function()
			if not IsValid(caster) then return end
			sound.Play("ambient/energy/whiteflash.wav", caster:GetPos(), 90, 90)
			sound.Play("ambient/atmosphere/thunder" .. math.random(1, 4) .. ".wav", caster:GetPos(), 95, 45)
			util.ScreenShake(caster:GetPos(), 8, 120, 1.5, 500)
		end)

		-- Final buildup at 90% charge
		timer.Simple(castTime * 0.9, function()
			if not IsValid(caster) then return end
			sound.Play("ambient/atmosphere/thunder" .. math.random(1, 4) .. ".wav", caster:GetPos(), 100, 38)
			sound.Play("weapons/physcannon/energy_sing_explosion2.wav", caster:GetPos(), 95, 70)
			util.ScreenShake(caster:GetPos(), 10, 140, 2.0, 600)
		end)

		-- Cleanup when cast completes or fails
		timer.Simple(castTime + 0.5, function()
			meteorStormCastingData[caster] = nil
			hook.Remove("Think", updateHook)
		end)

		return true -- We've handled the visuals
	end)

	-- Cleanup on spell failure
	hook.Add("Arcana_CastSpellFailure", "Arcana_MeteorStorm_CastCleanup", function(caster, spellId)
		if spellId ~= "meteor_storm" then return end
		if not meteorStormCastingData[caster] then return end

		local updateHook = "Arcana_MeteorStorm_CastUpdate_" .. tostring(caster)
		hook.Remove("Think", updateHook)
		meteorStormCastingData[caster] = nil
	end)
end