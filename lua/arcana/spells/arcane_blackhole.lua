if SERVER then util.AddNetworkString("Arcana_Blackhole_Climax") end

-- Server-side dark star tracking for vaporization (file-scope so on_register closures can access it)
local darkStarServerData = {}

local function registerBlackholeServerHooks(spell)
	-- Hook into casting start to begin dark star vaporization
	hook.Add("Arcana_BeginCasting", "Arcana_Blackhole_ServerDarkStar", function(caster, spellId)
		if spellId ~= "blackhole" then return end
		if not IsValid(caster) then return end

		-- Get spell data to retrieve cast time
		local spell = Arcana.RegisteredSpells[spellId]
		if not spell then return end
		local castTime = spell.cast_time or 25

		-- Dark star appears at 8 seconds
		timer.Simple(8, function()
			if not IsValid(caster) then return end

			local targetPos = Arcana:ResolveGroundTarget(caster, 1000)
			if not targetPos then return end

			darkStarServerData[caster] = {
				pos = targetPos + Vector(0, 0, 200),
				lerpedPos = targetPos,
				startTime = CurTime(),
				radius = 20,
				targetRadius = 900,
				growthDuration = castTime - 8,
				active = true
			}

			-- Vaporization check timer
			local vaporizeTimer = "Arcana_Blackhole_Vaporize_" .. caster:EntIndex()
			timer.Create(vaporizeTimer, 0.1, 0, function()
				if not IsValid(caster) or not darkStarServerData[caster] then
					timer.Remove(vaporizeTimer)
					return
				end

				local data = darkStarServerData[caster]
				if not data.active then
					timer.Remove(vaporizeTimer)
					return
				end

			-- Update dark star position with lerp so it drags toward the aim
			local currentTargetPos = Arcana:ResolveGroundTarget(caster, 1000)
			if currentTargetPos then
				local lerpedGroundPos = data.lerpedPos or currentTargetPos
				lerpedGroundPos = LerpVector(0.006, lerpedGroundPos, currentTargetPos)
				data.lerpedPos = lerpedGroundPos
				data.pos = lerpedGroundPos + Vector(0, 0, 200)
			end

				-- Calculate current radius based on growth
				local elapsed = CurTime() - data.startTime
				local growthProgress = math.Clamp(elapsed / data.growthDuration, 0, 1)
				local smoothGrowth = math.pow(growthProgress, 2.5)
				local currentRadius = Lerp(smoothGrowth, data.radius, data.targetRadius)

				local nearbyEnts = ents.FindInSphere(data.pos, currentRadius)
				for _, ent in ipairs(nearbyEnts) do
					if IsValid(ent) and ent ~= caster then
						local isValidTarget = false

						-- Check if it's a player
						if ent:IsPlayer() and ent:Alive() then
							isValidTarget = true
						end

						-- Check if it's an NPC
						if ent:IsNPC() and ent:Health() > 0 then
							isValidTarget = true
						end

						-- Check if it's a NextBot
						if ent:IsNextBot() and ent:Health() > 0 then
							isValidTarget = true
						end

						if isValidTarget then
							-- Instant vaporization damage
							local dmgInfo = DamageInfo()
							dmgInfo:SetDamage(ent:Health() + 100)
							dmgInfo:SetAttacker(caster)
							dmgInfo:SetInflictor(caster)
							dmgInfo:SetDamageType(DMG_DISSOLVE)
							dmgInfo:SetDamagePosition(data.pos)
							ent:TakeDamageInfo(dmgInfo)

							-- Vaporization effect
							local ed = EffectData()
							ed:SetOrigin(ent:GetPos() + Vector(0, 0, 40))
							ed:SetScale(2)
							util.Effect("cball_explode", ed, true, true)

							-- Sound effect
							sound.Play("ambient/energy/zap" .. math.random(1, 9) .. ".wav", ent:GetPos(), 80, 150)
							sound.Play("ambient/energy/weld" .. math.random(1, 2) .. ".wav", ent:GetPos(), 75, 80)
						end
					end
				end
			end)

			-- Stop vaporization when dark star collapses (at cast completion)
			timer.Simple(castTime - 8, function()
				if darkStarServerData[caster] then
					darkStarServerData[caster].active = false
					darkStarServerData[caster] = nil
				end
				timer.Remove(vaporizeTimer)
			end)
		end)
	end)

	-- Cleanup on spell failure
	hook.Add("Arcana_CastSpellFailure", "Arcana_Blackhole_ServerCleanup", function(caster, spellId)
		if spellId ~= "blackhole" then return end

		if darkStarServerData[caster] then
			darkStarServerData[caster] = nil
		end

		timer.Remove("Arcana_Blackhole_Vaporize_" .. caster:EntIndex())
	end)
end

Arcana:RegisterSpell({
	id = "blackhole",
	on_register = function(spell)
		if not SERVER then return end
		registerBlackholeServerHooks(spell)
	end,
	name = "Blackhole",
	description = "Channel void energy to summon a gravitational singularity that consumes all matter.",
	category = Arcana.CATEGORIES.COMBAT,
	level_required = 50,
	knowledge_cost = 10,
	cooldown = 60,
	cost_type = Arcana.COST_TYPES.COINS,
	cost_amount = 600000,
	cast_time = 25,
	range = 0,
	is_divine_pact = true,
	cast_anim = "becon",
	has_target = false,
	is_projectile = false,
	cast = function(caster, _, _, ctx)
		if not SERVER then return true end

		local srcEnt = IsValid(ctx.casterEntity) and ctx.casterEntity or caster
		local targetPos = Arcana:ResolveGroundTarget(srcEnt, 1000)

		-- Climax moment: Multi-stage collapse with building screen shakes
		-- Stage 1: Initial compression
		util.ScreenShake(targetPos, 15, 150, 0.8, 2500)

		-- Stage 2: Intensifying (0.3s)
		timer.Simple(0.3, function()
			util.ScreenShake(targetPos, 25, 200, 0.6, 2500)
		end)

		-- Stage 3: Violent final implosion (0.9s)
		timer.Simple(0.9, function()
			util.ScreenShake(targetPos, 50, 255, 0.4, 3000)
		end)

		-- Final collapse impact (1.1s)
		timer.Simple(1.1, function()
			util.ScreenShake(targetPos, 45, 240, 0.3, 2500)
		end)

		-- Climax sounds - multi-stage collapse with intense layering
		-- Stage 1: Initial compression (0.0s)
		sound.Play("ambient/atmosphere/hole_hit" .. math.random(1, 5) .. ".wav", targetPos, 115, 40)
		sound.Play("ambient/atmosphere/cave_hit" .. math.random(1, 6) .. ".wav", targetPos, 110, 55)
		sound.Play("ambient/levels/labs/teleport_preblast_suckin1.wav", targetPos, 108, 50)

		-- Stage 2: Intensifying (0.3s)
		timer.Simple(0.3, function()
			sound.Play("ambient/levels/labs/teleport_preblast_suckin1.wav", targetPos, 118, 45)
			sound.Play("weapons/physcannon/energy_sing_explosion2.wav", targetPos, 115, 40)
			--sound.Play("ambient/machines/machine_whine1.wav", targetPos, 110, 180)
		end)

		-- Stage 3: Building tension (0.5s)
		timer.Simple(0.5, function()
			sound.Play("ambient/energy/newspark" .. (math.random(0, 11) == 0 and "0" or math.random(1, 11)) .. ".wav", targetPos, 115, 60)
			sound.Play("ambient/machines/thumper_hit.wav", targetPos, 112, 90)
			sound.Play("ambient/energy/zap" .. math.random(1, 9) .. ".wav", targetPos, 110, 120)
		end)

		-- Stage 4: Critical point (0.7s)
		timer.Simple(0.7, function()
			sound.Play("ambient/atmosphere/cave_hit" .. math.random(1, 6) .. ".wav", targetPos, 120, 30)
			--sound.Play("ambient/machines/machine_whine1.wav", targetPos, 118, 200)
			sound.Play("weapons/physcannon/physcannon_charge.wav", targetPos, 115, 80)
			sound.Play("ambient/energy/weld" .. math.random(1, 2) .. ".wav", targetPos, 112, 50)
		end)

		-- Stage 4.5: Lightning arcs moment (0.8s)
		timer.Simple(0.8, function()
			sound.Play("ambient/energy/zap" .. math.random(1, 9) .. ".wav", targetPos, 122, 100)
			sound.Play("ambient/energy/spark" .. math.random(1, 6) .. ".wav", targetPos, 118, 90)
			sound.Play("ambient/machines/thumper_hit.wav", targetPos, 115, 85)
		end)

		-- Stage 5: Violent final implosion (0.9s)
		timer.Simple(0.9, function()
			sound.Play("ambient/energy/whiteflash.wav", targetPos, 130, 70)
			sound.Play("weapons/physcannon/energy_sing_explosion2.wav", targetPos, 125, 35)
			sound.Play("ambient/explosions/explode_" .. math.random(1, 9) .. ".wav", targetPos, 125, 80)
			sound.Play("ambient/levels/citadel/strange_talk" .. math.random(1, 11) .. ".wav", targetPos, 120, 50)
			sound.Play("ambient/machines/thumper_shutdown1.wav", targetPos, 120, 70)
		end)

		-- Pre-explosion buildup (1.0s)
		timer.Simple(1.0, function()
			sound.Play("ambient/energy/weld" .. math.random(1, 2) .. ".wav", targetPos, 122, 40)
			sound.Play("weapons/physcannon/superphys_small_zap" .. math.random(1, 4) .. ".wav", targetPos, 120, 90)
		end)

		-- Final collapse explosion (1.1s)
		timer.Simple(1.1, function()
			sound.Play("ambient/explosions/explode_" .. math.random(1, 9) .. ".wav", targetPos, 130, 50)
			sound.Play("weapons/physcannon/physcannon_claws_close.wav", targetPos, 125, 30)
			sound.Play("ambient/explosions/explode_" .. math.random(1, 9) .. ".wav", targetPos, 128, 70)
			sound.Play("ambient/atmosphere/thunder" .. math.random(1, 6) .. ".wav", targetPos, 125, 85)
			sound.Play("ambient/energy/zap" .. math.random(1, 9) .. ".wav", targetPos, 122, 110)
			sound.Play("physics/concrete/concrete_break" .. math.random(2, 3) .. ".wav", targetPos, 120, 50)
		end)

		-- Impact aftershock (1.15s)
		timer.Simple(1.15, function()
			sound.Play("ambient/levels/citadel/citadel_hit" .. math.random(1, 6) .. ".wav", targetPos, 125, 60)
			sound.Play("ambient/machines/thumper_dust.wav", targetPos, 120, 80)
		end)

		-- Broadcast climax VFX (dark star violent shrinking)
		net.Start("Arcana_Blackhole_Climax", true)
		net.WriteVector(targetPos)
		net.WriteEntity(caster)
		net.Broadcast()

		-- Spawn blackhole after violent collapse completes
		timer.Simple(1.2, function()
			if not IsValid(caster) then return end

			local blackhole = ents.Create("arcana_blackhole")
			blackhole:SetPos(targetPos + Vector(0, 0, 200))
			blackhole:Spawn()

			-- Spawn sounds
			sound.Play("ambient/levels/citadel/portal_beam_shoot" .. math.random(1, 6) .. ".wav", targetPos, 110, 45)
			sound.Play("ambient/explosions/explode_" .. math.random(1, 3) .. ".wav", targetPos, 105, 70)

			-- Visual effects at spawn
			local ed = EffectData()
			ed:SetOrigin(targetPos + Vector(0, 0, 200))
			util.Effect("cball_explode", ed, true, true)
			util.Effect("ManhackSparks", ed, true, true)

			if blackhole.CPPISetOwner then
				blackhole:CPPISetOwner(caster)
			end

			SafeRemoveEntityDelayed(blackhole, 20)
		end)

		return true
	end,
	trigger_phrase_aliases = {"blackhole", "black hole"}
})

if CLIENT then
	local matGlow = Material("sprites/light_glow02_add")
	local matFlare = Material("effects/blueflare1")
	local matBeam = Material("effects/laser1")
	local matVortex = Material("effects/combinemuzzle2_dark")
	local blackholeCastingData = {}
	local darkStarData = {}
	local blackholeLightningArcs = {}

	-- Function to spawn lightning arc from dark star to ground
	local function spawnDarkStarLightning(caster)
		if not IsValid(caster) or not darkStarData[caster] then return end

		local data = darkStarData[caster]
		local startPos = data.pos

		-- Random angle and distance
		local angle = math.Rand(0, math.pi * 2)
		local dist = math.Rand(200, 800)

		-- Trace to ground
		local targetPos = data.pos + Vector(math.cos(angle) * dist, math.sin(angle) * dist, 0)
		local tr = util.TraceLine({
			start = targetPos + Vector(0, 0, 5000),
			endpos = targetPos - Vector(0, 0, 5000),
			mask = MASK_SOLID_BRUSHONLY
		})

		local endPos = tr.HitPos + Vector(0, 0, 5)

		-- Create lightning arc
		table.insert(blackholeLightningArcs, {
			startPos = startPos,
			endPos = endPos,
			dieTime = CurTime() + 0.25,
			startTime = CurTime()
		})

		-- Impact effect at ground
		local ed = EffectData()
		ed:SetOrigin(endPos)
		util.Effect("cball_explode", ed)
	end

	-- Render lightning arcs from dark star
	hook.Add("PostDrawTranslucentRenderables", "Arcana_Blackhole_RenderLightning", function()
		local curTime = CurTime()

		for i = #blackholeLightningArcs, 1, -1 do
			local arc = blackholeLightningArcs[i]

			if curTime > arc.dieTime then
				table.remove(blackholeLightningArcs, i)
			else
				local age = curTime - arc.startTime
				local lifetime = arc.dieTime - arc.startTime
				local frac = age / lifetime
				local flicker = math.sin(curTime * 50 + arc.startTime * 70) * 0.3 + 0.7
				local alpha = (1 - frac) * 255 * flicker

				render.SetMaterial(matBeam)

				-- Generate jagged lightning path
				local segments = 8
				local arcPath = {}

				for seg = 0, segments do
					local t = seg / segments
					local pos = LerpVector(t, arc.startPos, arc.endPos)
					local jaggedAmount = math.sin(t * math.pi) * 25
					pos = pos + VectorRand() * jaggedAmount
					arcPath[seg] = pos
				end

				-- Purple-white core
				render.StartBeam(segments + 1)
				for seg = 0, segments do
					local t = seg / segments
					local width = 10 * flicker
					render.AddBeam(arcPath[seg], width, t, Color(255, 240, 255, alpha))
				end
				render.EndBeam()

				-- Purple outer glow
				render.StartBeam(segments + 1)
				for seg = 0, segments do
					local t = seg / segments
					local width = 18 * flicker
					render.AddBeam(arcPath[seg], width, t, Color(200, 120, 240, alpha * 0.7))
				end
				render.EndBeam()

				-- Dark purple outer layer
				render.StartBeam(segments + 1)
				for seg = 0, segments do
					local t = seg / segments
					local width = 25 * flicker
					render.AddBeam(arcPath[seg], width, t, Color(140, 60, 200, alpha * 0.4))
				end
				render.EndBeam()
			end
		end
	end)

	-- Render dark star (fiery growing orb)
	local darkStarRenderHook = "Arcana_Blackhole_RenderDarkStar"
	hook.Add("PostDrawTranslucentRenderables", darkStarRenderHook, function()
		for caster, data in pairs(darkStarData) do
			if not IsValid(caster) or not data.active then
				darkStarData[caster] = nil
				continue
			end

			local elapsed = CurTime() - data.startTime
			local growthProgress = math.Clamp(elapsed / data.growthDuration, 0, 1)

			-- Accelerating growth (slow start, explosive growth toward climax)
			local smoothGrowth = math.pow(growthProgress, 2.5)
			local currentRadius = Lerp(smoothGrowth, data.radius, data.targetRadius)

			local pos = data.pos
			local time = CurTime()

			-- Collapse intensity effect (subtle shaking during implosion)
			local collapseIntensity = data.collapseIntensity or 0
			local shakeMagnitude = 0
			if collapseIntensity > 0 and collapseIntensity < 0.85 then
				-- Subtle shake during compression, stops before final violent collapse
				shakeMagnitude = collapseIntensity * currentRadius * 0.03

				-- Apply random shake to position
				pos = pos + Vector(
					math.Rand(-shakeMagnitude, shakeMagnitude),
					math.Rand(-shakeMagnitude, shakeMagnitude),
					math.Rand(-shakeMagnitude * 0.5, shakeMagnitude * 0.5)
				)
			end

			-- Intensity increases dramatically as it grows
			local intensity = Lerp(smoothGrowth, 0.3, 1.0)
			local pulseSpeed = Lerp(smoothGrowth, 1.5, 5.0)

			-- Faster, more erratic pulsing during collapse
			if collapseIntensity > 0 then
				pulseSpeed = pulseSpeed + collapseIntensity * 15
			end

			local pulse = math.sin(time * pulseSpeed) * 0.2 * intensity + (0.8 + 0.2 * intensity)
			local fastPulse = math.sin(time * pulseSpeed * 2) * 0.15 * intensity + (0.85 + 0.15 * intensity)

			-- Fiery core sphere - darker, more subdued, compresses during collapse
			render.SetColorMaterial()
			local coreColor = Color(
				Lerp(smoothGrowth, 80, 140),
				Lerp(smoothGrowth, 40, 70),
				Lerp(smoothGrowth, 120, 180),
				255
			)

			-- Visual compression during collapse
			local coreRadius = currentRadius * 0.75
			if collapseIntensity > 0 then
				-- Make it appear to compress inward more dramatically
				coreRadius = currentRadius * Lerp(collapseIntensity, 0.75, 0.3)

				-- Brighten core as it compresses (like nuclear compression)
				coreColor = Color(
					math.min(200, coreColor.r + collapseIntensity * 80),
					math.min(160, coreColor.g + collapseIntensity * 100),
					math.min(220, coreColor.b + collapseIntensity * 60),
					255
				)
			end

			render.DrawSphere(pos, coreRadius, 32, 32, coreColor)

			-- Darker inner glow - contracts violently during collapse
			render.SetMaterial(matGlow)
			local innerGlowColor = Color(
				Lerp(smoothGrowth, 120, 180),
				Lerp(smoothGrowth, 60, 100),
				Lerp(smoothGrowth, 140, 200),
				200
			)

			-- Collapse makes the glow contract inward and brighten
			local glowScale1 = 2.0
			local glowScale2 = 2.8
			if collapseIntensity > 0 then
				glowScale1 = Lerp(collapseIntensity, 2.0, 0.8)
				glowScale2 = Lerp(collapseIntensity, 2.8, 1.2)

				-- Brighten during collapse but not as extreme
				innerGlowColor = Color(
					math.min(220, innerGlowColor.r + collapseIntensity * 60),
					math.min(180, innerGlowColor.g + collapseIntensity * 80),
					math.min(240, innerGlowColor.b + collapseIntensity * 50),
					200
				)
			end

			render.DrawSprite(pos, currentRadius * glowScale1 * fastPulse, currentRadius * glowScale1 * fastPulse, innerGlowColor)
			render.DrawSprite(pos, currentRadius * glowScale2 * pulse, currentRadius * glowScale2 * pulse, Color(160, 100, 200, 180 * intensity))

			-- Outer radiant layers - darker, get sucked in during collapse
			local outerScale1 = collapseIntensity > 0 and Lerp(collapseIntensity, 3.8, 1.5) or 3.8
			local outerScale2 = collapseIntensity > 0 and Lerp(collapseIntensity, 5.2, 2.0) or 5.2
			local outerScale3 = collapseIntensity > 0 and Lerp(collapseIntensity, 6.8, 2.5) or 6.8
			local outerScale4 = collapseIntensity > 0 and Lerp(collapseIntensity, 8.5, 3.0) or 8.5

			render.DrawSprite(pos, currentRadius * outerScale1 * pulse, currentRadius * outerScale1 * pulse, Color(120, 70, 160, 150 * intensity))
			render.DrawSprite(pos, currentRadius * outerScale2 * fastPulse, currentRadius * outerScale2 * fastPulse, Color(100, 60, 140, 120 * intensity))
			render.DrawSprite(pos, currentRadius * outerScale3 * pulse, currentRadius * outerScale3 * pulse, Color(90, 50, 120, 90 * intensity))
			render.DrawSprite(pos, currentRadius * outerScale4 * fastPulse, currentRadius * outerScale4 * fastPulse, Color(80, 40, 100, 60 * intensity))

			-- Solar flares/prominences - more violent as it grows, darker tones
			render.SetMaterial(matFlare)
			local flareCount = math.floor(Lerp(smoothGrowth, 4, 12))
			for i = 1, flareCount do
				local angle = (i / flareCount) * math.pi * 2 + time * (0.3 + intensity * 0.7)
				local flareIntensity = math.sin(time * 2.5 + i * 0.7) * 0.4 + 0.6
				local flareSize = currentRadius * (1.8 + math.sin(time * 3 + i) * 0.5) * flareIntensity * intensity
				local flareOffset = math.sin(time * 1.8 + i * 0.5) * currentRadius * (0.3 + 0.4 * intensity)
				local flarePos = pos + Vector(math.cos(angle) * flareOffset, math.sin(angle) * flareOffset, 0)
				local flareAlpha = math.floor(100 + 80 * intensity * flareIntensity)
				render.DrawSprite(flarePos, flareSize, flareSize, Color(160, 90, 200, flareAlpha))
			end

			-- Atmospheric distortion/heat waves - intensifies dramatically during collapse
			if smoothGrowth > 0.3 or collapseIntensity > 0 then
				render.SetMaterial(matVortex)
				local distortionAlpha = math.floor(80 * (smoothGrowth - 0.3) / 0.7)

				-- Massive distortion during collapse
				if collapseIntensity > 0 then
					distortionAlpha = math.floor(Lerp(collapseIntensity, distortionAlpha, 255))

					-- Multiple distortion layers during violent collapse
					render.DrawSprite(pos, currentRadius * 8 * pulse, currentRadius * 8 * pulse, Color(120, 60, 180, distortionAlpha * 0.8))
					render.DrawSprite(pos, currentRadius * 6 * fastPulse, currentRadius * 6 * fastPulse, Color(100, 40, 160, distortionAlpha * 0.6))
					render.DrawSprite(pos, currentRadius * 4 * pulse, currentRadius * 4 * pulse, Color(140, 80, 200, distortionAlpha * 0.4))
				else
					render.DrawSprite(pos, currentRadius * 6 * pulse, currentRadius * 6 * pulse, Color(120, 60, 180, distortionAlpha))
				end
			end
		end
	end)

	-- Climax VFX: Violent dark star collapse
	net.Receive("Arcana_Blackhole_Climax", function()
		local targetPos = net.ReadVector()
		local caster = net.ReadEntity()

		-- Trigger violent shrinking of dark star with multi-stage implosion
		if darkStarData[caster] then
			local data = darkStarData[caster]
			local collapseStartRadius = data.radius or data.targetRadius
			local collapseStartTime = CurTime()
			local collapseDuration = 1.2  -- Longer for dramatic effect

			-- Shrink dark star violently with multi-stage collapse
			local collapseHook = "Arcana_Blackhole_Collapse_" .. tostring(caster)
			hook.Add("Think", collapseHook, function()
				if not data.active then
					hook.Remove("Think", collapseHook)
					return
				end

				local elapsed = CurTime() - collapseStartTime
				local progress = math.Clamp(elapsed / collapseDuration, 0, 1)

				-- Multi-stage collapse: slow start, sudden violent collapse at the end
				local collapseProgress
				if progress < 0.4 then
					-- Slow compression phase (40% of time)
					collapseProgress = math.pow(progress / 0.4, 2) * 0.2
				elseif progress < 0.75 then
					-- Hold/tension phase (35% of time)
					collapseProgress = 0.2 + math.pow((progress - 0.4) / 0.35, 1.5) * 0.2
				else
					-- Violent implosion (final 25%)
					local finalProgress = (progress - 0.75) / 0.25
					collapseProgress = 0.4 + math.pow(finalProgress, 5) * 0.6
				end

				data.radius = Lerp(collapseProgress, collapseStartRadius, 5)
				data.collapseIntensity = progress

				if progress >= 1 then
					data.active = false
					darkStarData[caster] = nil
					hook.Remove("Think", collapseHook)
				end
			end)

			-- Staged particle effects during implosion
			local implosionPos = targetPos + Vector(0, 0, 200)

			-- Stage 1: Initial compression waves (0.0s)
			timer.Simple(0, function()
				local emit = ParticleEmitter(implosionPos)
				if emit then
					for i = 1, 60 do
						local angle = (i / 60) * math.pi * 2
						local dist = math.Rand(800, 1200)
						local startPos = implosionPos + Vector(math.cos(angle) * dist, math.sin(angle) * dist, math.Rand(-200, 200))
						local p = emit:Add("sprites/light_glow02_add", startPos)
						if p then
							local dir = (implosionPos - startPos):GetNormalized()
							p:SetVelocity(dir * math.Rand(600, 900))
							p:SetDieTime(0.8)
							p:SetStartAlpha(255)
							p:SetEndAlpha(0)
							p:SetStartSize(math.Rand(60, 100))
							p:SetEndSize(0)
							p:SetColor(180, 100, 220)
							p:SetGravity(Vector(0, 0, 0))
						end
					end
					emit:Finish()
				end
			end)

			-- Stage 2: Intensifying pull (0.3s)
			timer.Simple(0.3, function()
				local emit = ParticleEmitter(implosionPos)
				if emit then
					for i = 1, 80 do
						local angle = math.Rand(0, math.pi * 2)
						local vertAngle = math.Rand(-math.pi * 0.5, math.pi * 0.5)
						local dist = math.Rand(600, 1000)
						local startPos = implosionPos + Vector(
							math.cos(angle) * math.cos(vertAngle) * dist,
							math.sin(angle) * math.cos(vertAngle) * dist,
							math.sin(vertAngle) * dist
						)
						local p = emit:Add("effects/blueflare1", startPos)
						if p then
							local dir = (implosionPos - startPos):GetNormalized()
							p:SetVelocity(dir * math.Rand(1000, 1500))
							p:SetDieTime(0.6)
							p:SetStartAlpha(255)
							p:SetEndAlpha(0)
							p:SetStartSize(math.Rand(40, 80))
							p:SetEndSize(0)
							p:SetColor(160, 80, 200)
							p:SetGravity(Vector(0, 0, 0))
						end
					end
					emit:Finish()
				end
			end)

			-- Stage 2.5: Energy pulse wave (0.5s)
			timer.Simple(0.5, function()
				local pulseData = {
					pos = implosionPos,
					startTime = CurTime(),
					duration = 0.4
				}

				local pulseHook = "Arcana_Blackhole_EnergyPulse1_" .. tostring(caster)
				hook.Add("PostDrawTranslucentRenderables", pulseHook, function()
					if not pulseData then
						hook.Remove("PostDrawTranslucentRenderables", pulseHook)
						return
					end

					local elapsed = CurTime() - pulseData.startTime
					local progress = math.Clamp(elapsed / pulseData.duration, 0, 1)

					if progress >= 1 then
						pulseData = nil
						hook.Remove("PostDrawTranslucentRenderables", pulseHook)
						return
					end

					-- Compression wave collapsing inward
					local radius = Lerp(progress, 600, 100)
					local alpha = math.floor(200 * math.sin(progress * math.pi))
					render.SetMaterial(matGlow)
					render.DrawSprite(pulseData.pos, radius, radius, Color(200, 120, 240, alpha * 0.7))
					render.DrawSprite(pulseData.pos, radius * 1.2, radius * 1.2, Color(180, 100, 220, alpha * 0.5))
				end)

				-- Compression wave particles
				local emit = ParticleEmitter(implosionPos)
				if emit then
					for i = 1, 50 do
						local angle = (i / 50) * math.pi * 2
						local startPos = implosionPos + Vector(math.cos(angle) * 600, math.sin(angle) * 600, math.Rand(-50, 150))
						local p = emit:Add("sprites/light_glow02_add", startPos)
						if p then
							local dir = (implosionPos - startPos):GetNormalized()
							p:SetVelocity(dir * math.Rand(1200, 1800))
							p:SetDieTime(0.4)
							p:SetStartAlpha(220)
							p:SetEndAlpha(0)
							p:SetStartSize(math.Rand(40, 70))
							p:SetEndSize(0)
							p:SetColor(200, 120, 240)
							p:SetGravity(Vector(0, 0, 0))
						end
					end
					emit:Finish()
				end
			end)

			-- Stage 2.75: Second energy pulse (0.7s)
			timer.Simple(0.7, function()
				local pulseData = {
					pos = implosionPos,
					startTime = CurTime(),
					duration = 0.3
				}

				local pulseHook = "Arcana_Blackhole_EnergyPulse2_" .. tostring(caster)
				hook.Add("PostDrawTranslucentRenderables", pulseHook, function()
					if not pulseData then
						hook.Remove("PostDrawTranslucentRenderables", pulseHook)
						return
					end

					local elapsed = CurTime() - pulseData.startTime
					local progress = math.Clamp(elapsed / pulseData.duration, 0, 1)

					if progress >= 1 then
						pulseData = nil
						hook.Remove("PostDrawTranslucentRenderables", pulseHook)
						return
					end

					-- Faster compression wave
					local radius = Lerp(progress, 500, 80)
					local alpha = math.floor(240 * math.sin(progress * math.pi))
					render.SetMaterial(matGlow)
					render.DrawSprite(pulseData.pos, radius, radius, Color(220, 140, 255, alpha))
					render.DrawSprite(pulseData.pos, radius * 1.15, radius * 1.15, Color(200, 120, 240, alpha * 0.6))

					-- Distortion layer
					render.SetMaterial(matVortex)
					render.DrawSprite(pulseData.pos, radius * 1.3, radius * 1.3, Color(140, 80, 200, alpha * 0.4))
				end)
			end)

			-- Stage 2.9: Critical moment - energy arcs (0.8s)
			timer.Simple(0.8, function()
				local emit = ParticleEmitter(implosionPos)
				if emit then
					-- Lightning bolts from ground to dark star
					for i = 1, 25 do
						local angle = (i / 25) * math.pi * 2
						local dist = math.Rand(300, 600)
						local groundPos = targetPos + Vector(math.cos(angle) * dist, math.sin(angle) * dist, 0)

						-- Chain of particles creating arc effect
						for j = 0, 15 do
							local arcProgress = j / 15
							local arcPos = LerpVector(arcProgress, groundPos, implosionPos)
							-- Add random displacement for lightning arc effect
							arcPos = arcPos + Vector(math.Rand(-30, 30), math.Rand(-30, 30), 0)

							local p = emit:Add("effects/spark", arcPos)
							if p then
								p:SetVelocity(Vector(0, 0, math.Rand(50, 150)))
								p:SetDieTime(0.15)
								p:SetStartAlpha(255)
								p:SetEndAlpha(0)
								p:SetStartSize(math.Rand(15, 30))
								p:SetEndSize(math.Rand(5, 10))
								p:SetColor(220, 180, 255)
								p:SetGravity(Vector(0, 0, 0))
							end
						end
					end

					-- Ground energy eruptions
					for i = 1, 40 do
						local angle = math.Rand(0, math.pi * 2)
						local dist = math.Rand(100, 700)
						local groundPos = targetPos + Vector(math.cos(angle) * dist, math.sin(angle) * dist, 0)
						local p = emit:Add("sprites/light_glow02_add", groundPos)
						if p then
							p:SetVelocity(Vector(0, 0, math.Rand(300, 600)))
							p:SetDieTime(math.Rand(0.3, 0.5))
							p:SetStartAlpha(220)
							p:SetEndAlpha(0)
							p:SetStartSize(math.Rand(40, 80))
							p:SetEndSize(0)
							p:SetColor(200, 140, 240)
							p:SetGravity(Vector(0, 0, -400))
						end
					end

					emit:Finish()
				end
			end)

			-- Stage 3: Violent final implosion (0.9s - right before complete collapse)
			timer.Simple(0.9, function()
				local emit = ParticleEmitter(implosionPos)
				if emit then
					-- Massive inward rush from all directions
					for i = 1, 250 do
						local angle = math.Rand(0, math.pi * 2)
						local vertAngle = math.Rand(-math.pi * 0.5, math.pi * 0.5)
						local dist = math.Rand(400, 800)
						local startPos = implosionPos + Vector(
							math.cos(angle) * math.cos(vertAngle) * dist,
							math.sin(angle) * math.cos(vertAngle) * dist,
							math.sin(vertAngle) * dist
						)
						local p = emit:Add("sprites/light_glow02_add", startPos)
						if p then
							local dir = (implosionPos - startPos):GetNormalized()
							p:SetVelocity(dir * math.Rand(2500, 4000))
							p:SetDieTime(math.Rand(0.2, 0.35))
							p:SetStartAlpha(255)
							p:SetEndAlpha(0)
							p:SetStartSize(math.Rand(30, 60))
							p:SetEndSize(0)
							p:SetColor(220, 140, 255)
							p:SetGravity(Vector(0, 0, 0))
						end
					end

					-- Spiraling energy streams
					for i = 1, 150 do
						local angle = (i / 150) * math.pi * 2
						local dist = math.Rand(500, 900)
						local startPos = implosionPos + Vector(math.cos(angle) * dist, math.sin(angle) * dist, math.Rand(-100, 200))
						local p = emit:Add("effects/blueflare1", startPos)
						if p then
							local dir = (implosionPos - startPos):GetNormalized()
							local tangent = Vector(-dir.y, dir.x, 0) * 0.5
							p:SetVelocity((dir + tangent) * math.Rand(2000, 3500))
							p:SetDieTime(math.Rand(0.25, 0.4))
							p:SetStartAlpha(255)
							p:SetEndAlpha(0)
							p:SetStartSize(math.Rand(50, 100))
							p:SetEndSize(0)
							p:SetColor(140, 60, 200)
							p:SetGravity(Vector(0, 0, 0))
						end
					end

					-- Energy arcs/lightning streaking toward center
					for i = 1, 80 do
						local angle = math.Rand(0, math.pi * 2)
						local dist = math.Rand(600, 1000)
						local startPos = implosionPos + Vector(math.cos(angle) * dist, math.sin(angle) * dist, math.Rand(-100, 300))
						local p = emit:Add("effects/spark", startPos)
						if p then
							local dir = (implosionPos - startPos):GetNormalized()
							p:SetVelocity(dir * math.Rand(3000, 5000))
							p:SetDieTime(math.Rand(0.15, 0.25))
							p:SetStartAlpha(255)
							p:SetEndAlpha(0)
							p:SetStartSize(math.Rand(8, 18))
							p:SetEndSize(0)
							p:SetColor(255, 220, 255)
							p:SetGravity(Vector(0, 0, 0))
						end
					end

					emit:Finish()
				end
			end)

			-- Shockwave ring and explosion burst at final collapse moment (1.1s)
			timer.Simple(1.1, function()
				-- Explosion burst particles
				local explosionEmit = ParticleEmitter(implosionPos)
				if explosionEmit then
					-- Outward explosion burst
					for i = 1, 180 do
						local angle = (i / 180) * math.pi * 2
						local vertAngle = math.Rand(-math.pi * 0.4, math.pi * 0.4)
						local dir = Vector(
							math.cos(angle) * math.cos(vertAngle),
							math.sin(angle) * math.cos(vertAngle),
							math.sin(vertAngle)
						)
						local p = explosionEmit:Add("effects/blueflare1", implosionPos)
						if p then
							p:SetVelocity(dir * math.Rand(1000, 2000))
							p:SetDieTime(math.Rand(0.5, 1.0))
							p:SetStartAlpha(255)
							p:SetEndAlpha(0)
							p:SetStartSize(math.Rand(50, 100))
							p:SetEndSize(math.Rand(15, 30))
							p:SetColor(200, 120, 240)
							p:SetGravity(Vector(0, 0, -150))
						end
					end

					-- Bright flash explosion core
					for i = 1, 60 do
						local angle = math.Rand(0, math.pi * 2)
						local vertAngle = math.Rand(-math.pi * 0.5, math.pi * 0.5)
						local dir = Vector(
							math.cos(angle) * math.cos(vertAngle),
							math.sin(angle) * math.cos(vertAngle),
							math.sin(vertAngle)
						)
						local p = explosionEmit:Add("sprites/light_glow02_add", implosionPos)
						if p then
							p:SetVelocity(dir * math.Rand(600, 1200))
							p:SetDieTime(math.Rand(0.4, 0.8))
							p:SetStartAlpha(255)
							p:SetEndAlpha(0)
							p:SetStartSize(math.Rand(80, 150))
							p:SetEndSize(0)
							p:SetColor(255, 200, 255)
							p:SetGravity(Vector(0, 0, 0))
						end
					end

					-- Energy debris/shrapnel
					for i = 1, 100 do
						local angle = math.Rand(0, math.pi * 2)
						local vertAngle = math.Rand(-math.pi * 0.6, math.pi * 0.6)
						local dir = Vector(
							math.cos(angle) * math.cos(vertAngle),
							math.sin(angle) * math.cos(vertAngle),
							math.sin(vertAngle)
						)
						local p = explosionEmit:Add("effects/spark", implosionPos)
						if p then
							p:SetVelocity(dir * math.Rand(1200, 2200))
							p:SetDieTime(math.Rand(0.6, 1.2))
							p:SetStartAlpha(255)
							p:SetEndAlpha(0)
							p:SetStartSize(math.Rand(12, 25))
							p:SetEndSize(math.Rand(2, 6))
							p:SetColor(180, 100, 220)
							p:SetGravity(Vector(0, 0, -300))
						end
					end

					-- Smoke/void tendrils
					for i = 1, 60 do
						local angle = math.Rand(0, math.pi * 2)
						local dir = Vector(math.cos(angle), math.sin(angle), math.Rand(-0.3, 0.5))
						dir:Normalize()
						local p = explosionEmit:Add("particle/smokesprites_000" .. math.random(1, 9), implosionPos)
						if p then
							p:SetVelocity(dir * math.Rand(300, 700))
							p:SetDieTime(math.Rand(1.5, 2.5))
							p:SetStartAlpha(180)
							p:SetEndAlpha(0)
							p:SetStartSize(math.Rand(80, 150))
							p:SetEndSize(math.Rand(200, 350))
							p:SetColor(80, 40, 120)
							p:SetGravity(Vector(0, 0, 20))
							p:SetAirResistance(50)
						end
					end

					-- Energy pillars erupting from ground
					for i = 1, 30 do
						local angle = (i / 30) * math.pi * 2
						local dist = math.Rand(200, 500)
						local groundPos = targetPos + Vector(math.cos(angle) * dist, math.sin(angle) * dist, 0)

						for j = 1, 10 do
							local p = explosionEmit:Add("effects/blueflare1", groundPos + Vector(0, 0, j * 30))
							if p then
								p:SetVelocity(Vector(0, 0, math.Rand(400, 800)))
								p:SetDieTime(math.Rand(0.5, 0.9))
								p:SetStartAlpha(255)
								p:SetEndAlpha(0)
								p:SetStartSize(math.Rand(25, 50))
								p:SetEndSize(math.Rand(5, 15))
								p:SetColor(180, 100, 220)
								p:SetGravity(Vector(0, 0, -100))
							end
						end
					end

					explosionEmit:Finish()
				end

				-- Ground impact effects
				local groundEmit = ParticleEmitter(targetPos)
				if groundEmit then
					-- Ground debris/dust explosion
					for i = 1, 80 do
						local angle = math.Rand(0, math.pi * 2)
						local dist = math.Rand(50, 300)
						local p = groundEmit:Add("particle/smokesprites_000" .. math.random(1, 9), targetPos + Vector(math.cos(angle) * dist, math.sin(angle) * dist, 10))
						if p then
							local dir = Vector(math.cos(angle), math.sin(angle), math.Rand(0.2, 0.8))
							dir:Normalize()
							p:SetVelocity(dir * math.Rand(400, 800))
							p:SetDieTime(math.Rand(1.0, 2.0))
							p:SetStartAlpha(150)
							p:SetEndAlpha(0)
							p:SetStartSize(math.Rand(60, 120))
							p:SetEndSize(math.Rand(150, 250))
							p:SetColor(60, 30, 90)
							p:SetGravity(Vector(0, 0, -50))
							p:SetAirResistance(100)
						end
					end

					-- Ground crack energy
					for i = 1, 60 do
						local angle = (i / 60) * math.pi * 2
						local dist = math.Rand(200, 800)
						local p = groundEmit:Add("effects/blueflare1", targetPos + Vector(math.cos(angle) * dist, math.sin(angle) * dist, 5))
						if p then
							p:SetVelocity(Vector(0, 0, math.Rand(200, 500)))
							p:SetDieTime(math.Rand(0.4, 0.7))
							p:SetStartAlpha(255)
							p:SetEndAlpha(0)
							p:SetStartSize(math.Rand(30, 60))
							p:SetEndSize(0)
							p:SetColor(160, 80, 200)
							p:SetGravity(Vector(0, 0, -300))
						end
					end

					groundEmit:Finish()
				end

				-- Radial energy beams exploding outward at moment of impact
				timer.Simple(0.05, function()
					local beamData = {
						pos = implosionPos,
						startTime = CurTime(),
						duration = 0.4
					}

					local beamHook = "Arcana_Blackhole_RadialBeams_" .. tostring(caster)
					hook.Add("PostDrawTranslucentRenderables", beamHook, function()
						if not beamData then
							hook.Remove("PostDrawTranslucentRenderables", beamHook)
							return
						end

						local elapsed = CurTime() - beamData.startTime
						local progress = math.Clamp(elapsed / beamData.duration, 0, 1)

						if progress >= 1 then
							beamData = nil
							hook.Remove("PostDrawTranslucentRenderables", beamHook)
							return
						end

						-- Radial energy beams from center
						render.SetMaterial(matBeam)
						local beamLength = Lerp(progress, 100, 1000)
						local beamAlpha = math.floor(255 * (1 - math.pow(progress, 2)))

						for i = 1, 16 do
							local angle = (i / 16) * math.pi * 2
							local endPos = beamData.pos + Vector(math.cos(angle) * beamLength, math.sin(angle) * beamLength, 0)

							render.DrawBeam(beamData.pos, endPos, 40, 0, 1, Color(220, 140, 255, beamAlpha * 0.8))
							render.DrawBeam(beamData.pos, endPos, 25, 0, 1, Color(255, 200, 255, beamAlpha))
						end

						-- Ground energy rings
						local groundRingRadius = Lerp(progress, 50, 1100)
						local ringAlpha = math.floor(200 * (1 - progress))
						render.SetMaterial(matGlow)
						render.DrawSprite(targetPos + Vector(0, 0, 10), groundRingRadius * 2, groundRingRadius * 0.5, Color(180, 100, 220, ringAlpha * 0.7))
						render.DrawSprite(targetPos + Vector(0, 0, 5), groundRingRadius * 2.2, groundRingRadius * 0.6, Color(140, 60, 180, ringAlpha * 0.5))
					end)
				end)

				local shockwaveData = {
					pos = implosionPos,
					startTime = CurTime(),
					duration = 0.8
				}

				local shockwaveHook = "Arcana_Blackhole_Shockwave_" .. tostring(caster)
				hook.Add("PostDrawTranslucentRenderables", shockwaveHook, function()
					if not shockwaveData then
						hook.Remove("PostDrawTranslucentRenderables", shockwaveHook)
						return
					end

					local elapsed = CurTime() - shockwaveData.startTime
					local progress = math.Clamp(elapsed / shockwaveData.duration, 0, 1)

					if progress >= 1 then
						shockwaveData = nil
						hook.Remove("PostDrawTranslucentRenderables", shockwaveHook)
						return
					end

					-- Bright initial flash (first 20% of shockwave)
					if progress < 0.2 then
						local flashAlpha = math.floor(255 * (1 - progress / 0.2))
						render.SetMaterial(matGlow)
						render.DrawSprite(shockwaveData.pos, 800, 800, Color(255, 240, 255, flashAlpha))
						render.DrawSprite(shockwaveData.pos, 1200, 1200, Color(220, 160, 255, flashAlpha * 0.6))
					end

					-- Expanding shockwave ring
					local radius = Lerp(progress, 50, 1200)
					local alpha = math.floor(255 * (1 - math.pow(progress, 2)))
					local thickness = Lerp(progress, 80, 200)

					render.SetMaterial(matGlow)

					-- Main shockwave ring
					render.DrawSprite(shockwaveData.pos, radius, radius, Color(220, 140, 255, alpha * 0.8))
					render.DrawSprite(shockwaveData.pos, radius * 0.9, radius * 0.9, Color(180, 100, 220, alpha))
					render.DrawSprite(shockwaveData.pos, radius * 1.1, radius * 1.1, Color(140, 60, 200, alpha * 0.6))

					-- Secondary ring
					local radius2 = Lerp(progress, 100, 1400)
					local alpha2 = math.floor(180 * (1 - math.pow(progress, 1.5)))
					render.DrawSprite(shockwaveData.pos, radius2, radius2, Color(160, 80, 200, alpha2 * 0.5))

					-- Tertiary distortion ring
					local radius3 = Lerp(progress, 150, 1600)
					local alpha3 = math.floor(120 * (1 - progress))
					render.SetMaterial(matVortex)
					render.DrawSprite(shockwaveData.pos, radius3, radius3, Color(100, 40, 160, alpha3))
				end)
			end)
		end


		-- Pulse and destroy all circles
		if IsValid(caster) and blackholeCastingData[caster] then
			local data = blackholeCastingData[caster]

			-- Pulse all vertical circles inward and fade
			for _, circle in ipairs(data.circles) do
				if circle and circle.IsActive and circle:IsActive() then
					timer.Create("Arcana_Blackhole_CirclePulse_" .. tostring(circle), 0, 0, function()
						if not circle or not circle.IsActive or not circle:IsActive() then
							timer.Remove("Arcana_Blackhole_CirclePulse_" .. tostring(circle))
							return
						end

						local elapsed = CurTime() - (circle.climaxStart or CurTime())
						if not circle.climaxStart then
							circle.climaxStart = CurTime()
							circle.originalRadius = circle.radius or 80
						end

						if elapsed < 0.8 then
							local progress = elapsed / 0.8
							circle.radius = circle.originalRadius * (1 - progress * 0.6)
							circle.alpha = 255 * (1 - progress)
						else
							timer.Remove("Arcana_Blackhole_CirclePulse_" .. tostring(circle))
						end
					end)
				end
			end

			-- Pulse satellites
			for _, satData in ipairs(data.satellites) do
				if satData.circle and satData.circle.IsActive and satData.circle:IsActive() then
					local circle = satData.circle
					timer.Create("Arcana_Blackhole_CirclePulse_" .. tostring(circle), 0, 0, function()
						if not circle or not circle.IsActive or not circle:IsActive() then
							timer.Remove("Arcana_Blackhole_CirclePulse_" .. tostring(circle))
							return
						end

						local elapsed = CurTime() - (circle.climaxStart or CurTime())
						if not circle.climaxStart then
							circle.climaxStart = CurTime()
							circle.originalRadius = circle.radius or 50
						end

						if elapsed < 0.8 then
							local progress = elapsed / 0.8
							circle.radius = circle.originalRadius * (1 - progress * 0.6)
							circle.alpha = 255 * (1 - progress)
						else
							timer.Remove("Arcana_Blackhole_CirclePulse_" .. tostring(circle))
						end
					end)
				end
			end

			-- Cleanup
			timer.Simple(1.0, function()
				blackholeCastingData[caster] = nil
			end)
		end
	end)

	local MagicCircle = Arcana.Circle.MagicCircle
	hook.Add("Arcana_BeginCastingVisuals", "Arcana_Blackhole_CastCharge", function(caster, spellId, castTime)
		if spellId ~= "blackhole" then return end
		if not IsValid(caster) then return end

		local color = Color(120, 50, 200, 255)
		local startTime = CurTime()

		-- Store casting data
		local initialTargetPos = Arcana:ResolveGroundTarget(caster, 1000) or caster:GetPos()
		blackholeCastingData[caster] = {
			startTime = startTime,
			circles = {},
			satellites = {},
			lerpedPos = initialTargetPos
		}

		-- Ground target indicator (follows aim) using lerped position
		Arcana:CreateFollowingCastCircle(caster, spellId, castTime, {
			color = color,
			size = 1000,
			intensity = 100,
			positionResolver = function(c)
				if not blackholeCastingData[c] then
					return Arcana:ResolveGroundTarget(c, 1000)
				end
				return blackholeCastingData[c].lerpedPos
			end
		})

		-- PHASE 1: Initial void formation (0s) - Ground circle
		local groundCircle = MagicCircle.CreateMagicCircle(
			caster:GetPos() + Vector(0, 0, 2),
			Angle(0, 0, 0),
			color,
			5,
			100,
			castTime,
			3
		)

		if groundCircle and groundCircle.StartEvolving then
			groundCircle:StartEvolving(castTime, 1) -- upward
			table.insert(blackholeCastingData[caster].circles, groundCircle)

			-- Initial void opening sound
			sound.Play("ambient/atmosphere/hole_hit" .. math.random(1, 5) .. ".wav", caster:GetPos(), 90, 60)
			util.ScreenShake(caster:GetPos(), 4, 90, 0.5, 400)
		end

		-- Stacked vertical circles appear progressively
		local stackHeights = {70, 150, 250, 370, 510, 670}
		local stackSizes = {120, 150, 140, 120, 100, 80}

		for i, height in ipairs(stackHeights) do
			local delay = i * 3.5
			timer.Simple(delay, function()
				if not IsValid(caster) or not blackholeCastingData[caster] then return end

				local circle = MagicCircle.CreateMagicCircle(
					caster:GetPos() + Vector(0, 0, height),
					Angle(0, 0, 0),
					color,
					4 + i,
					stackSizes[i],
					castTime - delay,
					2
				)

				if circle and circle.StartEvolving then
					circle:StartEvolving(castTime - delay)
					table.insert(blackholeCastingData[caster].circles, circle)

					-- Void distortion sound per circle
					local pitch = 80 - (i * 3)
					local volume = 92 + (i * 1)
					sound.Play("ambient/atmosphere/hole_hit" .. math.random(1, 5) .. ".wav", caster:GetPos(), volume, pitch)
					sound.Play("weapons/physcannon/energy_sing_explosion2.wav", caster:GetPos(), volume - 5, pitch - 5)
					util.ScreenShake(caster:GetPos(), 4 + i, 100 + (i * 8), 0.5, 450 + (i * 50))
				end
			end)
		end

		-- PHASE 2: Gravitational field (8s) - 6 orbiting satellites + dark star spawn
		timer.Simple(8, function()
			if not IsValid(caster) or not blackholeCastingData[caster] then return end

			local numSatellites = 6
			local orbitRadius = 150
			local orbitHeight = 300

			-- Gravitational distortion sound
			sound.Play("ambient/atmosphere/hole_hit" .. math.random(1, 5) .. ".wav", caster:GetPos(), 98, 50)
			sound.Play("ambient/atmosphere/cave_hit" .. math.random(1, 6) .. ".wav", caster:GetPos(), 95, 45)
			sound.Play("weapons/physcannon/energy_sing_explosion2.wav", caster:GetPos(), 93, 50)
			util.ScreenShake(caster:GetPos(), 7, 130, 0.8, 600)

			for i = 1, numSatellites do
				local baseAngle = (i / numSatellites) * math.pi * 2
				local offsetX = math.cos(baseAngle) * orbitRadius
				local offsetY = math.sin(baseAngle) * orbitRadius
				local initialPos = caster:GetPos() + Vector(offsetX, offsetY, orbitHeight)
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
					50,
					castTime - 8,
					2
				)

				if satCircle and satCircle.StartEvolving then
					satCircle:StartEvolving(castTime - 8)
					satData.circle = satCircle
					table.insert(blackholeCastingData[caster].satellites, satData)
				end
			end

			-- Create dark star visual above target position (grows until climax)
			local targetPos = blackholeCastingData[caster] and blackholeCastingData[caster].lerpedPos or Arcana:ResolveGroundTarget(caster, 1000)
			if targetPos then
				darkStarData[caster] = {
					pos = targetPos + Vector(0, 0, 200),
					startTime = CurTime(),
					radius = 20,
					targetRadius = 900,  -- 90% of the 1000 radius following circle
					growthDuration = castTime - 8,  -- Grows for remaining duration until climax
					active = true
				}

				-- Dark star charging sounds
				timer.Simple(0, function()
					if not IsValid(caster) then return end
					caster:EmitSound("ambient/energy/zap1.wav", 88, 100, 0.5)
				end)

				timer.Simple(3, function()
					if not IsValid(caster) or not darkStarData[caster] then return end
					caster:EmitSound("weapons/physcannon/physcannon_charge.wav", 92, 90, 0.7)
				end)

				timer.Simple(6, function()
					if not IsValid(caster) or not darkStarData[caster] then return end
					caster:EmitSound("ambient/energy/weld1.wav", 90, 50, 0.7)
				end)

				-- Energy particles streaming into the dark star as it grows
				local darkStarPos = targetPos + Vector(0, 0, 200)
				local growthParticleSteps = 40
				for step = 0, growthParticleSteps do
					timer.Simple(step * 0.42, function()
						if not darkStarData[caster] or not darkStarData[caster].active then return end

						local progress = step / growthParticleSteps
						local emitter = ParticleEmitter(darkStarData[caster].pos)
						if not emitter then return end

						-- Fiery energy streaming into the dark star (increases with growth)
						local particleCount = math.floor(Lerp(progress, 8, 25))
						for i = 1, particleCount do
							local angle = math.Rand(0, math.pi * 2)
							local vertAngle = math.Rand(-math.pi * 0.5, math.pi * 0.5)
							local dist = math.Rand(300, 700)
							local startPos = darkStarData[caster].pos + Vector(
								math.cos(angle) * math.cos(vertAngle) * dist,
								math.sin(angle) * math.cos(vertAngle) * dist,
								math.sin(vertAngle) * dist
							)

							local p = emitter:Add("effects/blueflare1", startPos)
							if p then
								local dir = (darkStarData[caster].pos - startPos):GetNormalized()
								local speed = Lerp(progress, 100, 250)
								p:SetVelocity(dir * math.Rand(speed * 0.8, speed * 1.2))
								p:SetDieTime(math.Rand(1.2, 2.0))
								p:SetStartAlpha(math.Rand(180, 220))
								p:SetEndAlpha(0)
								p:SetStartSize(math.Rand(15, 30) * (1 + progress * 0.5))
								p:SetEndSize(math.Rand(5, 10))
								p:SetColor(200, 120, 230)
								p:SetGravity(Vector(0, 0, 0))
								p:SetCollide(false)
							end
						end

						emitter:Finish()
					end)
				end

				-- Periodic lightning from dark star (every 1.5-2.5s)
				local lightningTimer = "Arcana_Blackhole_Lightning_" .. tostring(caster)
				local numLightningBursts = math.floor((castTime - 8) / 2)
				for burst = 1, numLightningBursts do
					timer.Simple(burst * 2, function()
						if not IsValid(caster) or not darkStarData[caster] or not darkStarData[caster].active then return end

						local elapsed = CurTime() - darkStarData[caster].startTime
						local progress = math.Clamp(elapsed / darkStarData[caster].growthDuration, 0, 1)

						-- More lightning as it grows
						local numArcs = math.floor(Lerp(progress, 1, 4))

						for i = 1, numArcs do
							spawnDarkStarLightning(caster)
						end

						-- Lightning sound
						caster:EmitSound("ambient/levels/labs/electric_explosion" .. math.random(1, 5) .. ".wav", 70 + progress * 15, 70, 0.6)
					end)
				end
			end
		end)

		-- Update loop: Follow caster and animate satellites
		local updateHook = "Arcana_Blackhole_CastUpdate_" .. tostring(caster)

		hook.Add("Think", updateHook, function()
			if not IsValid(caster) or not blackholeCastingData[caster] then
				hook.Remove("Think", updateHook)
				return
			end

			local data = blackholeCastingData[caster]
			local casterPos = caster:GetPos()

			-- Update vertical circles
			for i, circleData in ipairs(data.circles) do
				if circleData and circleData.IsActive and circleData:IsActive() then
					local height = (i == 1) and 2 or stackHeights[i - 1]
					circleData.position = casterPos + Vector(0, 0, height)
				end
			end

			-- Update orbiting satellites (spin slowly, creating gravitational field)
			for _, satData in ipairs(data.satellites) do
				if satData.circle and satData.circle.IsActive and satData.circle:IsActive() then
					local elapsed = CurTime() - satData.startTime
					local spinSpeed = (math.pi * 2) / 10
					local currentAngle = satData.baseAngle + (elapsed * spinSpeed)
					local offsetX = math.cos(currentAngle) * satData.radius
					local offsetY = math.sin(currentAngle) * satData.radius
					local pos = casterPos + Vector(offsetX, offsetY, satData.height)
					satData.circle.position = pos
					satData.circle.angles = Angle(90, math.deg(currentAngle), 0)
				end
			end

			-- Update lerped ground position (used by following circle and dark star)
			local rawTargetPos = Arcana:ResolveGroundTarget(caster, 1000)
			if rawTargetPos then
				data.lerpedPos = LerpVector(FrameTime() * 0.4, data.lerpedPos or rawTargetPos, rawTargetPos)
			end

			-- Update dark star to follow lerped position
			if darkStarData[caster] and darkStarData[caster].active then
				if data.lerpedPos then
					darkStarData[caster].pos = data.lerpedPos + Vector(0, 0, 200)
				end
			end
		end)

		-- Gravitational particle effects - particles pulled INWARD
		local particleSteps = math.floor(castTime / 0.4)

		for step = 0, particleSteps do
			timer.Simple(step * 0.4, function()
				if not IsValid(caster) or not blackholeCastingData[caster] then return end

				local progress = step / particleSteps
				local emitter = ParticleEmitter(caster:GetPos())
				if not emitter then return end

				-- Void particles being pulled toward caster (gravitational)
				local particleCount = math.floor(10 + progress * 15)
				for i = 1, particleCount do
					local angle = math.Rand(0, math.pi * 2)
					local dist = math.Rand(150, 400)
					local height = math.Rand(50, 400)
					local startPos = caster:GetPos() + Vector(math.cos(angle) * dist, math.sin(angle) * dist, height)
					local targetPos = caster:GetPos() + Vector(0, 0, 200)
					local dir = (targetPos - startPos):GetNormalized()

					local p = emitter:Add("effects/blueflare1", startPos)
					if p then
						p:SetVelocity(dir * math.Rand(80, 150))
						p:SetDieTime(math.Rand(1.5, 2.5))
						p:SetStartAlpha(200)
						p:SetEndAlpha(0)
						p:SetStartSize(math.Rand(8, 15))
						p:SetEndSize(math.Rand(2, 5))
						p:SetColor(120, 50, 180)
						p:SetGravity(Vector(0, 0, 0))
						p:SetCollide(false)
					end
				end

				-- Void energy wisps (more intense as casting progresses)
				if progress > 0.3 then
					for i = 1, math.floor(progress * 8) do
						local angle = math.Rand(0, math.pi * 2)
						local dist = math.Rand(100, 250)
						local height = math.Rand(100, 300)
						local startPos = caster:GetPos() + Vector(math.cos(angle) * dist, math.sin(angle) * dist, height)

						local w = emitter:Add("sprites/light_glow02_add", startPos)
						if w then
							local dir = (caster:GetPos() + Vector(0, 0, 200) - startPos):GetNormalized()
							w:SetVelocity(dir * math.Rand(60, 120))
							w:SetDieTime(math.Rand(1.0, 2.0))
							w:SetStartAlpha(180)
							w:SetEndAlpha(0)
							w:SetStartSize(math.Rand(20, 35))
							w:SetEndSize(0)
							w:SetColor(140, 60, 200)
							w:SetGravity(Vector(0, 0, 0))
						end
					end
				end

				emitter:Finish()
			end)
		end

		-- Sound design: Build tension with void/gravitational theme
		timer.Simple(0, function()
			if not IsValid(caster) then return end
			sound.Play("ambient/atmosphere/cave_hit1.wav", caster:GetPos(), 85, 60)
		end)

		timer.Simple(castTime * 0.35, function()
			if not IsValid(caster) then return end
			sound.Play("ambient/atmosphere/hole_hit" .. math.random(1, 5) .. ".wav", caster:GetPos(), 95, 45)
			sound.Play("ambient/atmosphere/cave_hit" .. math.random(1, 6) .. ".wav", caster:GetPos(), 93, 50)
			util.ScreenShake(caster:GetPos(), 6, 110, 1.2, 500)
		end)

		timer.Simple(castTime * 0.6, function()
			if not IsValid(caster) then return end
			sound.Play("weapons/physcannon/energy_sing_explosion2.wav", caster:GetPos(), 98, 40)
			sound.Play("ambient/atmosphere/thunder1.wav", caster:GetPos(), 96, 95)
			util.ScreenShake(caster:GetPos(), 9, 130, 1.5, 600)
		end)

		timer.Simple(castTime * 0.8, function()
			if not IsValid(caster) then return end
			sound.Play("ambient/atmosphere/hole_hit" .. math.random(1, 5) .. ".wav", caster:GetPos(), 102, 35)
			sound.Play("ambient/energy/whiteflash.wav", caster:GetPos(), 100, 80)
			sound.Play("weapons/physcannon/energy_sing_explosion2.wav", caster:GetPos(), 98, 45)
			util.ScreenShake(caster:GetPos(), 12, 150, 2.0, 700)
		end)

		-- Final buildup at 92%
		timer.Simple(castTime * 0.92, function()
			if not IsValid(caster) then return end
			sound.Play("ambient/atmosphere/cave_hit" .. math.random(1, 6) .. ".wav", caster:GetPos(), 105, 30)
			sound.Play("weapons/physcannon/energy_sing_explosion2.wav", caster:GetPos(), 103, 40)
			util.ScreenShake(caster:GetPos(), 15, 170, 2.5, 800)
		end)

		-- Cleanup when cast completes or fails
		timer.Simple(castTime + 2.0, function()
			-- Stop any lingering sounds
			if IsValid(caster) then
				caster:StopSound("ambient/atmosphere/cave_hit1.wav")
				caster:StopSound("ambient/atmosphere/cave_hit2.wav")
				caster:StopSound("ambient/atmosphere/cave_hit3.wav")
				caster:StopSound("ambient/atmosphere/cave_hit4.wav")
				caster:StopSound("ambient/atmosphere/cave_hit5.wav")
				caster:StopSound("ambient/atmosphere/cave_hit6.wav")
				caster:StopSound("ambient/atmosphere/hole_hit1.wav")
				caster:StopSound("ambient/atmosphere/hole_hit2.wav")
				caster:StopSound("ambient/atmosphere/hole_hit3.wav")
				caster:StopSound("ambient/atmosphere/hole_hit4.wav")
				caster:StopSound("ambient/atmosphere/hole_hit5.wav")
				caster:StopSound("ambient/levels/citadel/portal_close1.wav")
				caster:StopSound("weapons/physcannon/energy_sing_explosion2.wav")
				caster:StopSound("weapons/physcannon/physcannon_charge.wav")
				caster:StopSound("ambient/energy/weld1.wav")
				caster:StopSound("ambient/energy/weld2.wav")
				caster:StopSound("ambient/energy/zap1.wav")
				for i = 1, 5 do
					caster:StopSound("ambient/levels/labs/electric_explosion" .. i .. ".wav")
				end
			end

			blackholeCastingData[caster] = nil
			darkStarData[caster] = nil
			hook.Remove("Think", updateHook)

			-- Cleanup any lingering visual effect hooks
			hook.Remove("PostDrawTranslucentRenderables", "Arcana_Blackhole_EnergyPulse1_" .. tostring(caster))
			hook.Remove("PostDrawTranslucentRenderables", "Arcana_Blackhole_EnergyPulse2_" .. tostring(caster))
			hook.Remove("PostDrawTranslucentRenderables", "Arcana_Blackhole_RadialBeams_" .. tostring(caster))
			hook.Remove("PostDrawTranslucentRenderables", "Arcana_Blackhole_Shockwave_" .. tostring(caster))
			hook.Remove("Think", "Arcana_Blackhole_Collapse_" .. tostring(caster))

			-- Clear lightning arcs
			table.Empty(blackholeLightningArcs)
			timer.Remove("Arcana_Blackhole_Lightning_" .. tostring(caster))
		end)

		return true
	end)

	-- Cleanup on spell failure
	hook.Add("Arcana_CastSpellFailure", "Arcana_Blackhole_CastCleanup", function(caster, spellId)
		if spellId ~= "blackhole" then return end
		if not blackholeCastingData[caster] then return end

		-- Stop any lingering sounds
		if IsValid(caster) then
			caster:StopSound("ambient/atmosphere/cave_hit1.wav")
			caster:StopSound("ambient/atmosphere/cave_hit2.wav")
			caster:StopSound("ambient/atmosphere/cave_hit3.wav")
			caster:StopSound("ambient/atmosphere/cave_hit4.wav")
			caster:StopSound("ambient/atmosphere/cave_hit5.wav")
			caster:StopSound("ambient/atmosphere/cave_hit6.wav")
			caster:StopSound("ambient/atmosphere/hole_hit1.wav")
			caster:StopSound("ambient/atmosphere/hole_hit2.wav")
			caster:StopSound("ambient/atmosphere/hole_hit3.wav")
			caster:StopSound("ambient/atmosphere/hole_hit4.wav")
			caster:StopSound("ambient/atmosphere/hole_hit5.wav")
			caster:StopSound("ambient/levels/citadel/portal_close1.wav")
			caster:StopSound("weapons/physcannon/energy_sing_explosion2.wav")
			caster:StopSound("weapons/physcannon/physcannon_charge.wav")
			caster:StopSound("ambient/energy/weld1.wav")
			caster:StopSound("ambient/energy/weld2.wav")
			caster:StopSound("ambient/energy/zap1.wav")
			for i = 1, 5 do
				caster:StopSound("ambient/levels/labs/electric_explosion" .. i .. ".wav")
			end
		end

		local updateHook = "Arcana_Blackhole_CastUpdate_" .. tostring(caster)
		hook.Remove("Think", updateHook)
		blackholeCastingData[caster] = nil
		darkStarData[caster] = nil

		-- Cleanup any lingering visual effect hooks
		hook.Remove("PostDrawTranslucentRenderables", "Arcana_Blackhole_EnergyPulse1_" .. tostring(caster))
		hook.Remove("PostDrawTranslucentRenderables", "Arcana_Blackhole_EnergyPulse2_" .. tostring(caster))
		hook.Remove("PostDrawTranslucentRenderables", "Arcana_Blackhole_RadialBeams_" .. tostring(caster))
		hook.Remove("PostDrawTranslucentRenderables", "Arcana_Blackhole_Shockwave_" .. tostring(caster))
		hook.Remove("Think", "Arcana_Blackhole_Collapse_" .. tostring(caster))

		-- Clear lightning arcs
		table.Empty(blackholeLightningArcs)
		timer.Remove("Arcana_Blackhole_Lightning_" .. tostring(caster))
	end)
end