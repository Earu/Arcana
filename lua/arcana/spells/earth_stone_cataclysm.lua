if SERVER then
	util.AddNetworkString("Arcana_StoneCataclysm_VFX")
	util.AddNetworkString("Arcana_StoneCataclysm_SpikeVFX")
end

-- Stone Cataclysm: A multi-wave tectonic devastation centered at aimed ground
Arcane:RegisterSpell({
	id = "stone_cataclysm",
	name = "Stone Cataclysm",
	description = "Rend the earth with cataclysmic force, unleashing multiple shockwaves and boulder eruptions.",
	category = Arcane.CATEGORIES.COMBAT,
	level_required = 30,
	knowledge_cost = 8,
	cooldown = 45.0,
	cost_type = Arcane.COST_TYPES.COINS,
	cost_amount = 350000,
	cast_time = 6,
	range = 0,
	icon = "icon16/brick.png",
	is_projectile = false,
	has_target = true,
	cast_anim = "forward",
	can_cast = function(caster)
		if caster:InVehicle() then return false, "Cannot cast while in a vehicle" end

		return true
	end,
	cast = function(caster, _, _, ctx)
		if not SERVER then return true end
		if not IsValid(caster) then return false end
		local tr = caster:GetEyeTrace()
		local center = (tr and tr.HitPos) or (caster:GetPos() + Vector(0, 0, 2))
		local normal = (tr and tr.HitNormal) or Vector(0, 0, 1)
		local baseRadius = 1040
		local bandWidth = 160
		local duration = 20
		local tick = 0.6
		local columnsPerTick = 4

		-- Global rumble and opening crack
		util.ScreenShake(center, 10, 90, 1.0, 1200)
		sound.Play("physics/concrete/concrete_break2.wav", center, 90, 95)
		sound.Play("ambient/materials/rock_impact_hard2.wav", center, 90, 95)

		local ed0 = EffectData()
		ed0:SetOrigin(center)
		util.Effect("ThumperDust", ed0, true, true)
		util.Effect("cball_explode", ed0, true, true)

		-- Broadcast VFX once with center, base radius, and duration
		net.Start("Arcana_StoneCataclysm_VFX", true)
		net.WriteVector(center)
		-- MagicCircle expects diameter-like size; send radius, and client will scale appropriately
		net.WriteFloat(baseRadius)
		net.WriteFloat(duration)
		net.Broadcast()

		-- Continuous rumble anchored at the epicenter for the full duration (retrigger to cover non-looping samples)
		local rumbleAnchor = ents.Create("info_target")
		if IsValid(rumbleAnchor) then
			rumbleAnchor:SetPos(center)
			rumbleAnchor:Spawn()
			local snd = "ambient/atmosphere/terrain_rumble1.wav"
			local interval = 1.5 -- retrigger cadence; adjust to sample length
			local tname = "Arcana_StoneCata_Rumble_" .. tostring(rumbleAnchor) .. "_" .. tostring(math.floor(RealTime() * 1000))
			local function playOnce()
				if not IsValid(rumbleAnchor) then return end
				rumbleAnchor:EmitSound(snd, 90, 100, 1, CHAN_STATIC)
			end
			-- start immediately then repeat until end
			playOnce()
			timer.Create(tname, interval, math.ceil(duration / interval), function()
				playOnce()
			end)
			timer.Simple(duration, function()
				timer.Remove(tname)
				if IsValid(rumbleAnchor) then rumbleAnchor:StopSound(snd) rumbleAnchor:Remove() end
			end)
		end

		-- Active hazard helpers
		local endTime = CurTime() + duration
		local spawnedSpikes = {}
		local dmgTick = 1.0
		local dmgPerTick = 25

		local function explodeRock(rock)
			if not IsValid(rock) then return end
			local origin = rock:GetPos()

			sound.Play("ambient/materials/rock_impact_hard2.wav", origin, 88, 100)
			sound.Play("physics/concrete/concrete_break2.wav", origin, 88, 95)

			rock:Remove()
		end

		local function spawnSpikeAt(pos)
			local tr2 = util.TraceLine({
				start = pos + Vector(0, 0, 96),
				endpos = pos - Vector(0, 0, 256),
				mask = MASK_SOLID_BRUSHONLY
			})

			if not tr2.Hit then return end
			local rock = ents.Create("prop_physics")
			if not IsValid(rock) then return end

			-- Use HL2 concrete debris chunks as stone columns
			local hl2Models = {
				"models/props_wasteland/rockcliff01b.mdl",
				"models/props_wasteland/rockcliff01c.mdl",
				"models/props_wasteland/rockcliff01f.mdl",
				"models/props_wasteland/rockcliff01j.mdl",
				"models/props_wasteland/rockcliff01k.mdl"
			}

			local model = hl2Models[math.random(#hl2Models)]
			rock:SetModel(model)

			-- Emergence: start below ground and rise to target
			local targetPos = tr2.HitPos + tr2.HitNormal * 8
			local startPos = tr2.HitPos - tr2.HitNormal * 64
			rock:SetPos(startPos)
			rock:SetAngles(Angle(0, math.random(0, 360), 0))
			rock:Spawn()

			-- Scale up debris chunks to sell big stone columns
			rock:PhysicsInit(SOLID_VPHYSICS)
			rock:SetMoveType(MOVETYPE_VPHYSICS)
			rock:SetSolid(SOLID_VPHYSICS)
			-- Do not block players/NPCs to avoid sticking; allow clean upward propulsion
			rock:SetCollisionGroup(COLLISION_GROUP_PASSABLE_DOOR)

			if rock.CPPISetOwner then
				rock:CPPISetOwner(caster)
			end

			local phys = rock:GetPhysicsObject()

			if IsValid(phys) then
				phys:Wake()
				phys:SetMass(math.max(phys:GetMass() * 2.2, 220))
				phys:EnableMotion(false)
			end

			-- Track for guaranteed cleanup at end
			spawnedSpikes[#spawnedSpikes + 1] = rock

			local ed = EffectData()
			ed:SetOrigin(tr2.HitPos)
			util.Effect("ThumperDust", ed, true, true)
			util.Decal("Scorch", tr2.HitPos + tr2.HitNormal * 4, tr2.HitPos - tr2.HitNormal * 8)

			-- Spawn heavy stone impact sounds
			sound.Play("physics/concrete/concrete_break2.wav", tr2.HitPos, 85, 95)
			sound.Play("ambient/materials/rock_impact_hard2.wav", tr2.HitPos, 80, 100)

			-- Ring VFX for each spike (raise slightly along surface normal so it renders above ground)
			net.Start("Arcana_StoneCataclysm_SpikeVFX", true)
			net.WriteVector(tr2.HitPos + tr2.HitNormal * 10)
			net.WriteFloat(math.Rand(180, 260))
			net.Broadcast()

			-- Animate the column rising out of the ground over a short duration
			local riseDur = 0.6
			local t0 = CurTime()
			local tname = "Arcana_StoneCata_Rise_" .. tostring(rock)
			timer.Create(tname, 0.02, math.ceil(riseDur / 0.02), function()
				if not IsValid(rock) then return end

				local t = math.Clamp((CurTime() - t0) / riseDur, 0, 1)
				local newPos = LerpVector(t, startPos, targetPos)
				rock:SetPos(newPos)

				if t >= 1 then
					rock:SetPos(targetPos)
					timer.Remove(tname)
				end
			end)

			-- Upward blast at spike base
			local spikeRadius = 200
			for _, e in ipairs(ents.FindInSphere(tr2.HitPos, spikeRadius)) do
				if not IsValid(e) then continue end
				if e == caster then continue end

				local ec = e:WorldSpaceCenter()
				local up = Vector(0, 0, 1)
				if e:IsPlayer() or e:IsNPC() or (e.IsNextBot and e:IsNextBot()) then
					local dmg = DamageInfo()
					dmg:SetDamage(90)
					dmg:SetDamageType(DMG_CLUB)
					dmg:SetAttacker(IsValid(caster) and caster or game.GetWorld())
					dmg:SetInflictor(IsValid(caster) and caster or game.GetWorld())
					dmg:SetDamagePosition(ec)
					e:TakeDamageInfo(dmg)
					if e.SetVelocity then
						e:SetVelocity(up * 760)
					end
				else
					local ph = e:GetPhysicsObject()
					if IsValid(ph) then
						ph:Wake()
						ph:ApplyForceCenter(up * 140000)
					end
				end
			end

			-- Schedule explosion 2 seconds after spawn, or removal at end if sooner
			local timeLeft = math.max(0, endTime - CurTime())
			if timeLeft > 2 then
				timer.Simple(2, function()
					if IsValid(rock) then explodeRock(rock) end
				end)
			else
				timer.Simple(timeLeft, function()
					if IsValid(rock) then explodeRock(rock) end
				end)
			end
		end

		local function applyWave(wi, cfg)
			if not IsValid(caster) then return end
			local radius = baseRadius * cfg.scale
			-- Damage + knockback within band [radius - bandWidth, radius]
			local inner = math.max(0, radius - bandWidth)
			for _, ent in ipairs(ents.FindInSphere(center, radius + 24)) do
				if not IsValid(ent) then continue end
				if ent == caster then continue end

				local c = ent:WorldSpaceCenter()
				local dist = c:Distance(center)
				if dist < inner or dist > radius then continue end

				local dir = (c - center):GetNormalized()
				if ent:IsPlayer() or ent:IsNPC() or (ent.IsNextBot and ent:IsNextBot()) then
					local dmg = DamageInfo()
					dmg:SetDamage(cfg.dmg)
					dmg:SetDamageType(DMG_CLUB)
					dmg:SetAttacker(IsValid(caster) and caster or game.GetWorld())
					dmg:SetInflictor(IsValid(caster) and caster or game.GetWorld())
					dmg:SetDamagePosition(c)
					ent:TakeDamageInfo(dmg)

					-- Strong outward/upward impulse
					if ent.SetVelocity then
						ent:SetVelocity(dir * 820 + Vector(0, 0, 350))
					end

					if ent.SetGroundEntity then
						ent:SetGroundEntity(NULL)
					end
				else
					local phys = ent:GetPhysicsObject()
					if IsValid(phys) then
						phys:Wake()
						phys:ApplyForceCenter(dir * 68000 + Vector(0, 0, 24000))
					end
				end
			end

			-- Erupt boulders along the ring
			local columns = cfg.columns
			for i = 1, columns do
				local a = (i / columns) * math.pi * 2 + math.rad(math.Rand(-8, 8))
				local p = center + Vector(math.cos(a) * (radius - bandWidth * 0.4), math.sin(a) * (radius - bandWidth * 0.4), 0)
				local tr2 = util.TraceLine({
					start = p + Vector(0, 0, 96),
					endpos = p - Vector(0, 0, 256),
					mask = MASK_SOLID_BRUSHONLY
				})

				if tr2.Hit then
					local rock = ents.Create("prop_physics")
					if IsValid(rock) then
						local model = (math.random() < 0.5) and "models/props_debris/concrete_chunk05g.mdl" or "models/props_junk/rock001a.mdl"
						rock:SetModel(model)
						rock:SetMaterial("models/props_wasteland/rockcliff02b")
						rock:SetPos(tr2.HitPos + tr2.HitNormal * 8)
						local ang = tr2.HitNormal:Angle()
						ang:RotateAroundAxis(ang:Forward(), math.Rand(-12, 12))
						rock:SetAngles(ang)
						rock:Spawn()
						local scale = math.Rand(3.2, 5.0)
						rock:SetModelScale(scale, 0)
						rock:PhysicsInit(SOLID_VPHYSICS)
						rock:SetMoveType(MOVETYPE_VPHYSICS)
						rock:SetSolid(SOLID_VPHYSICS)
						rock:SetCollisionGroup(COLLISION_GROUP_PASSABLE_DOOR)

						if rock.CPPISetOwner then
							rock:CPPISetOwner(caster)
						end

						local phys = rock:GetPhysicsObject()

						if IsValid(phys) then
							phys:Wake()
							phys:SetMass(math.max(phys:GetMass() * 2.2, 220))
							-- Freeze to create a persistent spike for the duration
							phys:EnableMotion(false)
						end

						local ed = EffectData()
						ed:SetOrigin(tr2.HitPos)
						util.Effect("ThumperDust", ed, true, true)
						util.Decal("Scorch", tr2.HitPos + tr2.HitNormal * 4, tr2.HitPos - tr2.HitNormal * 8)

						-- One-time eruption damage + upward launch at spike origin
						local spikeRadius = 180
						for _, e in ipairs(ents.FindInSphere(tr2.HitPos, spikeRadius)) do
							if not IsValid(e) then continue end
							if e == caster then continue end
							local ec = e:WorldSpaceCenter()
							local up = Vector(0, 0, 1)
							if e:IsPlayer() or e:IsNPC() or (e.IsNextBot and e:IsNextBot()) then
								local dmg = DamageInfo()
								dmg:SetDamage(cfg.dmg)
								dmg:SetDamageType(DMG_CLUB)
								dmg:SetAttacker(IsValid(caster) and caster or game.GetWorld())
								dmg:SetInflictor(IsValid(caster) and caster or game.GetWorld())
								dmg:SetDamagePosition(ec)
								e:TakeDamageInfo(dmg)
								if e.SetVelocity then
									e:SetVelocity(up * 720)
								end
							else
								local ph = e:GetPhysicsObject()

								if IsValid(ph) then
									ph:Wake()
									ph:ApplyForceCenter(up * 120000)
								end
							end
						end

						-- Heavy local dust burst at spike
						local emitter = ParticleEmitter(tr2.HitPos)
						if emitter then
							for di = 1, 28 do
								local dp = emitter:Add("particle/particle_smokegrenade", tr2.HitPos + VectorRand() * 12)
								if dp then
									dp:SetVelocity(VectorRand() * 80 + Vector(0, 0, math.Rand(120, 220)))
									dp:SetDieTime(math.Rand(1.2, 1.8))
									dp:SetStartAlpha(160)
									dp:SetEndAlpha(0)
									dp:SetStartSize(math.Rand(18, 28))
									dp:SetEndSize(math.Rand(60, 100))
									dp:SetColor(120, 110, 100)
									dp:SetAirResistance(90)
									dp:SetCollide(false)
								end
							end

							emitter:Finish()
						end

						timer.Simple(20, function()
							if IsValid(rock) then rock:Remove() end
						end)
					end
				end
			end
		end

		-- Drive the active hazard for the full duration
		local iterations = math.floor(duration / tick)
		for n = 0, iterations do
			local delay = n * tick
			timer.Simple(delay, function()
				if not IsValid(caster) then return end

				-- Ring-based spawning: expanding ring radius over time
				local frac = math.Clamp((CurTime() + 0.001 - (endTime - duration)) / math.max(duration, 0.001), 0, 1)
				local ringR = Lerp(frac, baseRadius * 0.2, baseRadius)
				local jitter = bandWidth * 0.25

				-- Prioritize spawning under actors in area; then fall back to ring/random
				local spawned = 0
				local candidates = ents.FindInSphere(center, baseRadius)
				for _, ent in ipairs(candidates) do
					if spawned >= columnsPerTick then break end
					if not IsValid(ent) or ent == caster then continue end
					if not (ent:IsPlayer() or ent:IsNPC() or (ent.IsNextBot and ent:IsNextBot())) then continue end
					if not ent:IsOnGround() then continue end

					local pos = ent:WorldSpaceCenter()
					spawnSpikeAt(pos)
					spawned = spawned + 1
				end

				for j = spawned + 1, columnsPerTick do
					local useRing = (math.random() < 0.5)
					local a = math.Rand(0, math.pi * 2)
					local r
					if useRing then
						-- Spawn near the expanding ring
						r = math.Clamp(ringR + math.Rand(-bandWidth * 0.5, bandWidth * 0.5), baseRadius * 0.15, baseRadius)
					else
						-- Fully random within the area
						r = math.Rand(baseRadius * 0.15, baseRadius)
					end
					local pos = center + Vector(math.cos(a) * r, math.sin(a) * r, 0)
					spawnSpikeAt(pos)
				end

				-- Per-tick ambient dust columns around perimeter
				for i = 1, 6 do
					local aa = math.Rand(0, math.pi * 2)
					local p = center + Vector(math.cos(aa) * baseRadius, math.sin(aa) * baseRadius, 0)
					local ed2 = EffectData()
					ed2:SetOrigin(p)
					util.Effect("ThumperDust", ed2, true, true)
				end

				-- Ongoing area rumble
				util.ScreenShake(center, 6, 60, 0.35, baseRadius * 2)
			end)
		end

		-- Periodic area damage to actors within the hazard radius
		local dmgIters = math.floor(duration / dmgTick)
		for k = 0, dmgIters do
			local d = k * dmgTick
			timer.Simple(d, function()
				if not IsValid(caster) then return end
				for _, ent in ipairs(ents.FindInSphere(center, baseRadius)) do
					if not IsValid(ent) then continue end
					if ent == caster then continue end
					local isActor = ent:IsPlayer() or ent:IsNPC() or (ent.IsNextBot and ent:IsNextBot())
					if not isActor then continue end
					local dmg = DamageInfo()
					dmg:SetDamage(dmgPerTick)
					dmg:SetDamageType(DMG_CLUB)
					dmg:SetAttacker(IsValid(caster) and caster or game.GetWorld())
					dmg:SetInflictor(IsValid(caster) and caster or game.GetWorld())
					dmg:SetDamagePosition(ent:WorldSpaceCenter())
					ent:TakeDamageInfo(dmg)
					if ent.SetVelocity then
						ent:SetVelocity(Vector(0, 0, 120))
					end
				end
			end)
		end

		-- Hard cleanup pass at the end of duration (guarantee removal)
		timer.Simple(duration + 0.05, function()
			for i = #spawnedSpikes, 1, -1 do
				local sp = spawnedSpikes[i]
				if IsValid(sp) then explodeRock(sp) end
				spawnedSpikes[i] = nil
			end
		end)

		return true
	end,
	trigger_phrase_aliases = {
		"cataclysm",
		"earth cataclysm",
	}
})

if CLIENT then
	local matGlow = Material("sprites/light_glow02_add")
	local matRing = Material("effects/select_ring")
	local bursts = {}
	local activeMagicCircles = {}

	local function addBurst(pos, radius, life)
		bursts[#bursts + 1] = { pos = pos, radius = radius, life = life, die = CurTime() + life }
	end

	net.Receive("Arcana_StoneCataclysm_VFX", function()
		local pos = net.ReadVector()
		local base = net.ReadFloat()
		local dur = net.ReadFloat() or 20

		-- Three large earthy rings
		addBurst(pos, math.max(260, base * 0.9), 0.7)
		addBurst(pos, math.max(360, base * 1.5), 0.9)
		addBurst(pos, math.max(520, base * 2.2), 1.1)

		-- Persistent MAGIC CIRCLE for duration
		if MagicCircle then
			-- Ensure the circle visually matches the area radius (use diameter)
			local circle = MagicCircle.CreateMagicCircle(pos + Vector(0, 0, 2), Angle(0, 0, 0), Color(120, 90, 40, 255), 90, base, dur, 2)
			if circle then
				activeMagicCircles[#activeMagicCircles + 1] = circle
				-- Breakdown at end
				timer.Simple(dur, function()
					if circle.Destroy then circle:Destroy() end
				end)
			end
		end

		-- Massive dust storm from center
		local emitter = ParticleEmitter(pos)
		if emitter then
			for i = 1, 96 do
				local ang = (i / 48) * 360
				local dir = Angle(0, ang, 0):Forward()
				local p = emitter:Add("particle/particle_smokegrenade", pos + dir * math.Rand(12, 36) + Vector(0, 0, math.Rand(0, 24)))

				if p then
					p:SetVelocity(dir * math.Rand(220, 380) + Vector(0, 0, math.Rand(120, 220)))
					p:SetDieTime(math.Rand(1.3, 2.2))
					p:SetStartAlpha(180)
					p:SetEndAlpha(0)
					p:SetStartSize(math.Rand(22, 36))
					p:SetEndSize(math.Rand(72, 128))
					p:SetColor(120, 110, 100)
					p:SetAirResistance(90)
					p:SetGravity(Vector(0, 0, 80))
					p:SetCollide(false)
				end
			end

			for i = 1, 72 do
				local mat = (math.random() < 0.5) and "effects/fleck_cement1" or "effects/fleck_cement2"
				local p = emitter.Add and emitter:Add(mat, pos + VectorRand() * 10)
				if p then
					local dir = Angle(0, (i / 72) * 360, 0):Forward()
					p:SetVelocity(dir * math.Rand(300, 520) + Vector(0, 0, math.Rand(180, 260)))
					p:SetDieTime(math.Rand(0.9, 1.4))
					p:SetStartAlpha(255)
					p:SetEndAlpha(0)
					p:SetStartSize(math.Rand(3, 6))
					p:SetEndSize(0)
					p:SetRoll(math.Rand(0, 360))
					p:SetRollDelta(math.Rand(-14, 14))
					p:SetColor(140, 130, 120)
					p:SetAirResistance(40)
					p:SetGravity(Vector(0, 0, -320))
					p:SetCollide(true)
					p:SetBounce(0.25)
				end
			end

			emitter:Finish()
		end

		-- Schedule sustained area dust for duration
		local steps = math.floor(dur / 0.35)
		for k = 0, steps do
			timer.Simple(k * 0.35, function()
				local em = ParticleEmitter(pos)
				if not em then return end

				for i = 1, 32 do
					local r = math.Rand(base * 0.2, base)
					local a = math.Rand(0, math.pi * 2)
					local p = pos + Vector(math.cos(a) * r, math.sin(a) * r, math.Rand(0, 18))
					local d = em:Add("particle/particle_smokegrenade", p)
					if d then
						d:SetVelocity(VectorRand() * 60 + Vector(0, 0, math.Rand(40, 90)))
						d:SetDieTime(math.Rand(1.0, 1.6))
						d:SetStartAlpha(130)
						d:SetEndAlpha(0)
						d:SetStartSize(math.Rand(16, 26))
						d:SetEndSize(math.Rand(42, 78))
						d:SetColor(120, 110, 100)
						d:SetAirResistance(80)
						d:SetCollide(false)
					end
				end

				em:Finish()
			end)
		end
	end)

	-- Per-spike ring burst VFX
	net.Receive("Arcana_StoneCataclysm_SpikeVFX", function()
		local pos = net.ReadVector()
		local radius = net.ReadFloat() or 220
		addBurst(pos, radius, 0.6)
	end)

	hook.Add("PostDrawTranslucentRenderables", "Arcana_StoneCataclysm_Render", function()
		for i = #bursts, 1, -1 do
			if CurTime() > bursts[i].die then table.remove(bursts, i) end
		end

		for i = 1, #bursts do
			local b = bursts[i]
			local frac = 1 - (b.die - CurTime()) / b.life
			frac = math.Clamp(frac, 0, 1)
			local curr = Lerp(frac, 30, b.radius)
			local alpha = 220 * (1 - frac)
			render.SetMaterial(matRing)
			render.DrawQuadEasy(b.pos + Vector(0, 0, 2), Vector(0, 0, 1), curr, curr, Color(140, 120, 90, math.floor(alpha)), 0)
			render.SetMaterial(matGlow)
			render.DrawSprite(b.pos + Vector(0, 0, 4), curr * 0.42, curr * 0.42, Color(200, 160, 90, math.floor(alpha * 0.5)))
		end
	end)

	-- Casting-time magic circle at aimed ground, like blackhole
	hook.Add("Arcana_BeginCastingVisuals", "Arcana_StoneCataclysm_Circle", function(caster, spellId, castTime, _forwardLike)
		if spellId ~= "stone_cataclysm" then return end
		if not MagicCircle then return end
		if not IsValid(caster) then return end

		local tr = caster:GetEyeTrace()
		local pos = (tr and tr.HitPos) or (caster:GetPos() + Vector(0, 0, 2))
		local ang = Angle(0, 0, 0)
		local size = 360
		local intensity = 80
		local circle = MagicCircle.CreateMagicCircle(pos, ang, Color(120, 90, 40, 255), intensity, size, castTime, 2)
		if not circle then return end

		if circle.StartEvolving then circle:StartEvolving(castTime, true) end
		local hookName = "Arcana_SC_CircleFollow_" .. tostring(circle)
		local endTime = CurTime() + castTime + 0.05
		hook.Add("Think", hookName, function()
			if not IsValid(caster) or not circle or (circle.IsActive and not circle:IsActive()) or CurTime() > endTime then
				hook.Remove("Think", hookName)
				return
			end

			local tr2 = caster:GetEyeTrace()
			if tr2 and tr2.HitPos then
				circle.position = tr2.HitPos + Vector(0, 0, 0.5)
				circle.angles = Angle(0, 0, 0)
			end
		end)
	end)
end