-- Flame Wave: A sweeping cone of fire that ignites and damages enemies
Arcane:RegisterSpell({
	id = "flame_wave",
	name = "Flame Wave",
	description = "Unleash a sweeping cone of flame, burning enemies ahead.",
	category = Arcane.CATEGORIES.COMBAT,
	level_required = 9,
	knowledge_cost = 3,
	cooldown = 6.0,
	cost_type = Arcane.COST_TYPES.COINS,
	cost_amount = 40,
	cast_time = 0.7,
	range = 900,
	icon = "icon16/fire.png",
	has_target = false,
	cast_anim = "forward",
	cast = function(caster, _, _, ctx)
		if not SERVER then return true end
		local origin = (ctx and ctx.circlePos) or caster:GetShootPos()
		local forward = caster:GetAimVector()
		local cosHalfAngle = math.cos(math.rad(45))
		local maxRange = 900
		local baseDamage = 48
		local igniteTime = 6

		for _, ent in ipairs(ents.FindInSphere(origin, maxRange)) do
			if not IsValid(ent) or ent == caster then continue end
			local toTarget = (ent:WorldSpaceCenter() - origin)
			local dist = toTarget:Length()
			if dist > maxRange then continue end
			local dir = toTarget:GetNormalized()
			if dir:Dot(forward) < cosHalfAngle then continue end
			-- Scale damage by angle tightness and distance within the cone
			local angleFactor = math.Clamp((dir:Dot(forward) - cosHalfAngle) / (1 - cosHalfAngle), 0, 1)
			local distanceFactor = 1 - math.Clamp(dist / maxRange, 0, 1) * 0.4 -- 1 near, 0.6 far
			local finalDamage = math.floor(baseDamage * (0.7 + 0.3 * angleFactor) * (0.8 + 0.2 * distanceFactor))

			if ent:IsPlayer() or ent:IsNPC() then
				local dmg = DamageInfo()
				dmg:SetDamage(finalDamage)
				dmg:SetDamageType(bit.bor(DMG_BURN, DMG_SLOWBURN))
				dmg:SetAttacker(IsValid(caster) and caster or game.GetWorld())
				dmg:SetInflictor(IsValid(caster) and caster or game.GetWorld())
				ent:TakeDamageInfo(dmg)

				if ent.Ignite then
					ent:Ignite(igniteTime, 0)
				end

				-- Knockback for characters
				if ent.SetVelocity then
					ent:SetVelocity(forward * 220)
				end
			else
				local phys = ent:GetPhysicsObject()

				if IsValid(phys) then
					phys:ApplyForceCenter(forward * (700 * phys:GetMass()))
				end
			end
		end

		return true
	end,
	trigger_phrase_aliases = {
		"flame",
		"flames",
	}
})

if CLIENT then
	-- Client visuals for Flame Wave. Runs when casting begins; schedules the wave marker at completion.
	hook.Add("Arcana_BeginCastingVisuals", "Arcane_FlameWave_Visuals", function(caster, spellId, castTime, forwardLike)
		if spellId ~= "flame_wave" then return end
		if not IsValid(caster) then return end

		local function spawnWaveVisuals()
			if not IsValid(caster) then return end
			local origin
			local forward = caster:GetAimVector()

			if forwardLike then
				local maxs = caster:OBBMaxs()
				origin = caster:GetPos() + caster:GetForward() * maxs.x * 1.5 + caster:GetUp() * maxs.z / 2
			else
				origin = caster:GetShootPos()
			end

			local maxRange = 900
			local ed = EffectData()
			ed:SetOrigin(origin + forward * 40)
			util.Effect("cball_explode", ed, true, true)
			sound.Play("ambient/fire/ignite.wav", caster:GetPos(), 75, 110)
			caster:EmitSound("ambient/fire/gascan_ignite1.wav", 75, 100)
			util.ScreenShake(caster:GetPos(), 2, 2, 0.4, 256)

			for i = 1, 5 do
				local t = i / 5
				local p = origin + forward * (maxRange * t)
				local fx = EffectData()
				fx:SetOrigin(p)
				util.Effect("cball_explode", fx, true, true)

				local tr = util.TraceLine({
					start = p + Vector(0, 0, 32),
					endpos = p - Vector(0, 0, 96),
					filter = caster
				})

				if tr.Hit then
					util.Decal("Scorch", tr.HitPos + tr.HitNormal * 4, tr.HitPos - tr.HitNormal * 8)
				end
			end

			local right = forward:Angle():Right()

			local function spawnWaveMarker(side)
				local life, steps = 0.6, 18
				local emitter = ParticleEmitter(origin)
				local jitterSeed = math.Rand(0, 1000)

				for i = 1, steps do
					local frac = i / steps

					timer.Simple(frac * life, function()
						if not emitter then return end
						local dist = maxRange * frac
						local wave = math.sin((dist * 0.02) + jitterSeed) * 8
						local rise = math.sin(frac * math.pi) * 14
						local lateral = side * (dist * 0.30 + wave)
						local ppos = origin + forward * dist + right * lateral + Vector(0, 0, rise)

						-- Embers (match fireball style)
						for j = 1, 3 do
							local p = emitter:Add("effects/yellowflare", ppos + VectorRand() * 2)

							if p then
								p:SetVelocity(-forward * (60 + math.random(0, 40)) + VectorRand() * 20)
								p:SetDieTime(0.4 + math.Rand(0.1, 0.3))
								p:SetStartAlpha(220)
								p:SetEndAlpha(0)
								p:SetStartSize(4 + math.random(0, 2))
								p:SetEndSize(0)
								p:SetRoll(math.Rand(0, 360))
								p:SetRollDelta(math.Rand(-3, 3))
								p:SetColor(255, 160 + math.random(0, 40), 60)
								p:SetLighting(false)
								p:SetAirResistance(60)
								p:SetGravity(Vector(0, 0, -50))
								p:SetCollide(false)
							end
						end

						-- Fire cloud/smoke puffs
						for j = 1, 2 do
							local mat = (math.random() < 0.5) and "effects/fire_cloud1" or "effects/fire_cloud2"
							local p = emitter.Add and emitter:Add(mat, ppos)

							if p then
								p:SetVelocity(-forward * (40 + math.random(0, 30)) + VectorRand() * 10)
								p:SetDieTime(0.6 + math.Rand(0.2, 0.5))
								p:SetStartAlpha(180)
								p:SetEndAlpha(0)
								p:SetStartSize(10 + math.random(0, 8))
								p:SetEndSize(30 + math.random(0, 12))
								p:SetRoll(math.Rand(0, 360))
								p:SetRollDelta(math.Rand(-1, 1))
								p:SetColor(255, 120 + math.random(0, 60), 40)
								p:SetLighting(false)
								p:SetAirResistance(70)
								p:SetGravity(Vector(0, 0, 20))
								p:SetCollide(false)
							end
						end

						-- Heat shimmer
						local hw = emitter:Add("sprites/heatwave", ppos)

						if hw then
							hw:SetVelocity(VectorRand() * 10)
							hw:SetDieTime(0.25)
							hw:SetStartAlpha(180)
							hw:SetEndAlpha(0)
							hw:SetStartSize(14)
							hw:SetEndSize(0)
							hw:SetRoll(math.Rand(0, 360))
							hw:SetRollDelta(math.Rand(-1, 1))
							hw:SetLighting(false)
						end
					end)
				end

				timer.Simple(life + 0.6, function()
					if emitter then
						emitter:Finish()
					end

					emitter = nil
				end)
			end

			spawnWaveMarker(0)
			spawnWaveMarker(1)
			spawnWaveMarker(-1)
		end

		timer.Simple(math.max(0.01, castTime or 0.7), spawnWaveVisuals)
	end)
end