-- Spellcraft: element effects. Crafted spells must LOOK like their element,
-- not like tinted generic particles: a fire bolt is a fireball, a lightning
-- beam crackles with arcs. Palettes and sounds are lifted from the authored
-- element spells (arcana_fireball, ring_of_fire, lightning_strike/orb,
-- ice_frost_nova, earth_shatter, wind_blast, poison_cloud, golden_sun).
--
-- SERVER API:
--   P.ImpactFX(element, pos, radius, intensity)  burst at a point (sounds,
--     decals, shakes, tesla server-side; particles client-side)
--   P.BeamFX(element, startPos, endPos)          beam visual + firing sound
--
-- intensity: ~0.35 for ticks (auras, lingering patches), 1 for real impacts.

Arcana = Arcana or {}
Arcana.Spellcraft = Arcana.Spellcraft or {}
local P = Arcana.Spellcraft

----------------------------------------------------------------------
-- SERVER: authoritative sounds/decals/shakes + broadcast to clients
----------------------------------------------------------------------
if SERVER then
	util.AddNetworkString("Arcana_Spellcraft_ImpactFX")
	util.AddNetworkString("Arcana_Spellcraft_BeamFX")
	util.AddNetworkString("Arcana_Spellcraft_AuraFX")
	util.AddNetworkString("Arcana_Spellcraft_ZoneFX")

	local UP = Vector(0, 0, 1)
	local DOWN = Vector(0, 0, -16)

	-- Per-element server-side impact dressing.
	local IMPACT_SV = {
		fire = function(pos, radius, intensity)
			if intensity >= 0.9 then
				local ed = EffectData()
				ed:SetOrigin(pos)
				util.Effect("Explosion", ed, true, true)
				Arcana.Common.ScreenShake(pos, 5, 5, 0.35, 512)
				sound.Play("ambient/explosions/explode_4.wav", pos, 90, 100)
			else
				sound.Play("ambient/fire/ignite.wav", pos, 65, math.random(95, 110))
			end
			util.Decal("Scorch", pos + UP * 8, pos + DOWN)
		end,
		frost = function(pos, radius, intensity)
			local ed = EffectData()
			ed:SetOrigin(pos)
			util.Effect("GlassImpact", ed, true, true)
			if intensity >= 0.9 then
				sound.Play("physics/glass/glass_impact_bullet1.wav", pos, 75, 120)
				Arcana.Common.ScreenShake(pos, 3, 60, 0.25, radius * 1.5)
			end
			sound.Play("ambient/levels/canals/windchime2.wav", pos, 65, math.random(130, 150))
		end,
		lightning = function(pos, radius, intensity)
			Arcana.Common.SpawnTeslaBurst(pos, {
				targetname = "arcana_spellcraft",
				radius = math.max(120, radius),
				beamcount_min = math.floor(4 + 6 * intensity),
				beamcount_max = math.floor(7 + 8 * intensity),
				thick_min = 4, thick_max = 4 + math.floor(6 * intensity),
				lifetime_min = 0.08, lifetime_max = 0.16,
				interval_min = 0.03, interval_max = 0.06,
				kill_delay = 0.5,
			})
			local ed = EffectData()
			ed:SetOrigin(pos)
			util.Effect("ElectricSpark", ed, true, true)
			sound.Play("ambient/levels/labs/electric_explosion" .. math.random(1, 5) .. ".wav", pos, intensity >= 0.9 and 90 or 70, 110)
			if intensity >= 0.9 then
				util.Decal("Scorch", pos + UP * 8, pos + DOWN)
				Arcana.Common.ScreenShake(pos, 6, 90, 0.3, 600)
			end
		end,
		earth = function(pos, radius, intensity)
			local ed = EffectData()
			ed:SetOrigin(pos)
			ed:SetScale(math.max(1, intensity))
			util.Effect("ThumperDust", ed, true, true)
			if intensity >= 0.9 then
				sound.Play("physics/concrete/concrete_break2.wav", pos, 80, 95)
				sound.Play("ambient/materials/rock_impact_hard2.wav", pos, 80, 100)
				Arcana.Common.ScreenShake(pos, 7, 40, 0.4, radius * 2)
				util.Decal("Scorch", pos + UP * 8, pos + DOWN)
			else
				sound.Play("physics/concrete/rock_impact_soft" .. math.random(1, 3) .. ".wav", pos, 65, 100)
			end
		end,
		wind = function(pos, radius, intensity)
			sound.Play("ambient/wind/wind_snippet" .. math.random(1, 5) .. ".wav", pos, intensity >= 0.9 and 85 or 65, math.random(100, 125))
			if intensity >= 0.9 then
				sound.Play("ambient/wind/wind_roar1.wav", pos, 75, 130)
			end
		end,
		poison = function(pos, radius, intensity)
			sound.Play("ambient/levels/canals/toxic_slime_gurgle" .. math.random(1, 8) .. ".wav", pos, intensity >= 0.9 and 80 or 62, 90)
		end,
		arcane = function(pos, radius, intensity)
			local ed = EffectData()
			ed:SetOrigin(pos)
			util.Effect("cball_explode", ed, true, true)
			sound.Play("ambient/energy/zap" .. math.random(1, 9) .. ".wav", pos, intensity >= 0.9 and 85 or 65, 110)
			if intensity >= 0.9 then
				util.Decal("FadingScorch", pos + UP * 8, pos + DOWN)
			end
		end,
		aurum = function(pos, radius, intensity)
			if intensity >= 0.9 then
				local ed = EffectData()
				ed:SetOrigin(pos)
				util.Effect("Explosion", ed, true, true)
				sound.Play("ambient/explosions/explode_4.wav", pos, 88, 115)
			else
				sound.Play("ambient/fire/ignite.wav", pos, 65, 120)
			end
			sound.Play("physics/metal/metal_solid_impact_soft" .. math.random(1, 3) .. ".wav", pos, 70, math.random(160, 220))
			util.Decal("Scorch", pos + UP * 8, pos + DOWN)
		end,
	}

	function P.ImpactFX(element, pos, radius, intensity)
		intensity = intensity or 1
		local dress = IMPACT_SV[element]
		if dress then dress(pos, radius or 120, intensity) end

		net.Start("Arcana_Spellcraft_ImpactFX", true)
		net.WriteString(element or "arcane")
		net.WriteVector(pos)
		net.WriteFloat(radius or 120)
		net.WriteFloat(intensity)
		net.Broadcast()
	end

	local BEAM_SOUND = {
		fire = { "ambient/fire/gascan_ignite1.wav", 78, 105 },
		frost = { "weapons/physcannon/energy_sing_flyby1.wav", 70, 210 },
		lightning = { "weapons/physcannon/superphys_small_zap1.wav", 80, 95 },
		earth = { "physics/concrete/boulder_impact_hard1.wav", 78, 130 },
		wind = { "ambient/wind/wind_snippet3.wav", 75, 130 },
		poison = { "ambient/levels/canals/toxic_slime_gurgle3.wav", 75, 120 },
		arcane = { "weapons/physcannon/energy_sing_flyby1.wav", 75, 150 },
		aurum = { "ambient/fire/gascan_ignite1.wav", 78, 130 },
	}

	function P.BeamFX(element, startPos, endPos)
		local snd = BEAM_SOUND[element]
		if snd then
			sound.Play(snd[1], startPos, snd[2], snd[3])
		end

		net.Start("Arcana_Spellcraft_BeamFX", true)
		net.WriteString(element or "arcane")
		net.WriteVector(startPos)
		net.WriteVector(endPos)
		net.Broadcast()
	end

	-- Continuous element aura around an entity (self form). duration <= 0 stops
	-- an active aura early.
	function P.AuraFX(ent, element, radius, duration)
		if not IsValid(ent) then return end
		net.Start("Arcana_Spellcraft_AuraFX", true)
		net.WriteEntity(ent)
		net.WriteString(element or "arcane")
		net.WriteFloat(radius or 140)
		net.WriteFloat(duration or 0)
		net.Broadcast()
	end

	-- Continuous element zone at a fixed position (lingering patches): a dense,
	-- poison_cloud-style volume of the element for the duration.
	function P.ZoneFX(element, pos, radius, duration)
		net.Start("Arcana_Spellcraft_ZoneFX", true)
		net.WriteString(element or "arcane")
		net.WriteVector(pos)
		net.WriteFloat(radius or 120)
		net.WriteFloat(duration or 4)
		net.Broadcast()
	end
end

----------------------------------------------------------------------
-- CLIENT: per-element particle bursts and beam rendering
----------------------------------------------------------------------
if CLIENT then
	local matBeam = Material("effects/laser1")
	local matGlow = Material("sprites/light_glow02_add")
	local matFlare = Material("effects/blueflare1")
	local matRing = Material("effects/select_ring")
	local matPhysBeam = Material("sprites/physbeam")

	----------------------------------------------------------------
	-- Impact bursts
	----------------------------------------------------------------
	-- Shared visual snippets ------------------------------------------------
	local rings = {}   -- expanding ground rings { pos, radius, col, life, die }
	local spikes = {}  -- frost ice spikes { pos, normal, height, life, die }

	local function addRing(pos, radius, col, life)
		rings[#rings + 1] = { pos = pos, radius = radius, col = col, life = life or 0.5, die = CurTime() + (life or 0.5) }
	end

	local function addIceSpikes(pos, radius, count)
		for i = 1, count do
			local ang = (i / count) * 360 + math.Rand(-10, 10)
			local dir = Angle(0, ang, 0):Forward()
			local start = pos + dir * math.Rand(radius * 0.3, radius * 0.8) + Vector(0, 0, 48)
			local tr = util.TraceLine({ start = start, endpos = start + Vector(0, 0, -200), mask = MASK_SOLID_BRUSHONLY })
			if tr.Hit then
				spikes[#spikes + 1] = {
					pos = tr.HitPos + tr.HitNormal * 2,
					normal = tr.HitNormal,
					height = math.Rand(32, 72),
					life = 0.65,
					die = CurTime() + 0.65,
				}
			end
		end
	end

	local function fireClouds(emitter, pos, dir, count, sizeMul, colOverride)
		for _ = 1, count do
			local mat = (math.random() < 0.5) and "effects/fire_cloud1" or "effects/fire_cloud2"
			local p = emitter:Add(mat, pos + VectorRand() * 6)
			if p then
				p:SetVelocity(dir * (50 + math.random(0, 40)) + VectorRand() * 40)
				p:SetDieTime(0.6 + math.Rand(0.2, 0.5))
				p:SetStartAlpha(190)
				p:SetEndAlpha(0)
				p:SetStartSize((12 + math.random(0, 8)) * sizeMul)
				p:SetEndSize((32 + math.random(0, 14)) * sizeMul)
				p:SetRoll(math.Rand(0, 360))
				p:SetRollDelta(math.Rand(-1, 1))
				if colOverride then
					p:SetColor(colOverride.r, colOverride.g, colOverride.b)
				else
					p:SetColor(255, 120 + math.random(0, 60), 40)
				end
				p:SetLighting(false)
				p:SetAirResistance(70)
				p:SetGravity(Vector(0, 0, 20))
				p:SetCollide(false)
			end
		end
	end

	local function embers(emitter, pos, count, col)
		for _ = 1, count do
			local p = emitter:Add("effects/yellowflare", pos + VectorRand() * 4)
			if p then
				p:SetVelocity(VectorRand() * 140 + Vector(0, 0, 60))
				p:SetDieTime(0.4 + math.Rand(0.1, 0.4))
				p:SetStartAlpha(230)
				p:SetEndAlpha(0)
				p:SetStartSize(4 + math.random(0, 3))
				p:SetEndSize(0)
				p:SetRoll(math.Rand(0, 360))
				p:SetRollDelta(math.Rand(-3, 3))
				p:SetColor(col.r, col.g, col.b)
				p:SetLighting(false)
				p:SetAirResistance(60)
				p:SetGravity(Vector(0, 0, -60))
				p:SetCollide(false)
			end
		end
	end

	local function heatShimmer(emitter, pos)
		local hw = emitter:Add("sprites/heatwave", pos)
		if hw then
			hw:SetVelocity(VectorRand() * 12)
			hw:SetDieTime(0.25)
			hw:SetStartAlpha(180)
			hw:SetEndAlpha(0)
			hw:SetStartSize(18)
			hw:SetEndSize(0)
			hw:SetLighting(false)
		end
	end

	local function dlight(pos, col, size, brightness)
		local dl = DynamicLight(math.random(1, 60000))
		if dl then
			dl.pos = pos
			dl.r, dl.g, dl.b = col.r, col.g, col.b
			dl.brightness = brightness or 2.5
			dl.Size = size
			dl.Decay = 1400
			dl.DieTime = CurTime() + 0.2
		end
	end

	-- Expanding ring sweep (ring_of_fire style): perPoint(emitter, pos, dirOut, frac)
	-- runs at points around the circumference as the ring grows to full radius.
	-- This is what makes an impact READ at its real size.
	local function ringSweep(pos, radius, life, steps, points, perPoint)
		for i = 1, steps do
			local frac = i / steps
			timer.Simple(frac * life, function()
				local emitter = ParticleEmitter(pos)
				if not emitter then return end
				local r = radius * frac
				for pIdx = 1, points do
					local ang = (pIdx / points) * 360 + math.Rand(-8, 8)
					local dir = Angle(0, ang, 0):Forward()
					perPoint(emitter, pos + dir * r, dir, frac)
				end
				emitter:Finish()
			end)
		end
	end

	-- Scatter bursts at random points within the radius (area fill for ticks
	-- and lingering patches).
	local function areaScatter(pos, radius, count, perPoint)
		local emitter = ParticleEmitter(pos)
		if not emitter then return end
		for _ = 1, count do
			local dir = Angle(0, math.Rand(0, 360), 0):Forward()
			perPoint(emitter, pos + dir * math.Rand(0, radius), dir)
		end
		emitter:Finish()
	end

	----------------------------------------------------------------
	-- Earth rocks: clientside models, in the mod's established rock look
	-- (rock001a + rockcliff material, like earth_shatter / stone_volley).
	----------------------------------------------------------------
	local ROCK_MODELS = { "models/props_junk/rock001a.mdl", "models/props_debris/concrete_chunk05g.mdl" }
	local ROCK_MATERIAL = "models/props_wasteland/rockcliff02b"
	local MAX_GROUND_ROCKS = 90

	local groundRocks = {} -- { ent, ground, riseH, spawnAt, riseTime, die, sinkTime }

	local function createRock(scale)
		local ent = ClientsideModel(ROCK_MODELS[math.random(#ROCK_MODELS)], RENDERGROUP_OPAQUE)
		if not IsValid(ent) then return nil end
		ent:SetMaterial(ROCK_MATERIAL)
		ent:SetModelScale(scale)
		return ent
	end

	-- Rocks that erupt from the ground, hold, then sink away.
	-- opts: ring (spawn near the rim), tiltOut (crater lean), minScale/maxScale, stagger
	local function spawnGroundRocks(pos, radius, count, life, opts)
		opts = opts or {}
		for _ = 1, count do
			local delay = math.Rand(0, opts.stagger or 0.35)
			timer.Simple(delay, function()
				if #groundRocks >= MAX_GROUND_ROCKS then return end

				local dir = Angle(0, math.Rand(0, 360), 0):Forward()
				local r = opts.ring and radius * math.Rand(0.75, 1.0) or radius * math.sqrt(math.Rand(0.05, 1))
				local at = pos + dir * r + Vector(0, 0, 40)
				local tr = util.TraceLine({ start = at, endpos = at - Vector(0, 0, 180), mask = MASK_SOLID_BRUSHONLY })
				if not tr.Hit then return end

				local scale = math.Rand(opts.minScale or 0.7, opts.maxScale or 1.6)
				local rock = createRock(scale)
				if not rock then return end

				local riseH = math.Rand(9, 20) * scale
				local ang
				if opts.tiltOut then
					-- Crater rim: rocks lean away from the centre.
					ang = dir:Angle()
					ang.p = math.Rand(-70, -40)
					ang:RotateAroundAxis(dir, math.Rand(-15, 15))
				else
					ang = Angle(math.Rand(-25, 25), math.Rand(0, 360), math.Rand(-25, 25))
				end
				rock:SetAngles(ang)
				rock:SetPos(tr.HitPos - Vector(0, 0, riseH * 1.2))

				groundRocks[#groundRocks + 1] = {
					ent = rock,
					ground = tr.HitPos,
					riseH = riseH,
					spawnAt = CurTime(),
					riseTime = 0.22,
					die = CurTime() + life,
					sinkTime = 0.5,
				}

				-- Dust pop as it breaks the surface.
				local em = ParticleEmitter(tr.HitPos)
				if em then
					for _ = 1, 2 do
						local d = em:Add("particle/particle_smokegrenade", tr.HitPos + Vector(0, 0, 4))
						if d then
							d:SetVelocity(Vector(0, 0, 30) + VectorRand() * 25)
							d:SetDieTime(math.Rand(0.5, 0.8))
							d:SetStartAlpha(90)
							d:SetEndAlpha(0)
							d:SetStartSize(10)
							d:SetEndSize(26)
							d:SetColor(120, 110, 100)
							d:SetAirResistance(70)
						end
					end
					em:Finish()
				end
			end)
		end
	end

	hook.Add("Think", "Arcana_Spellcraft_EarthRocks", function()
		if #groundRocks == 0 then return end
		local now = CurTime()

		for i = #groundRocks, 1, -1 do
			local r = groundRocks[i]
			if not IsValid(r.ent) then
				table.remove(groundRocks, i)
			else
				local overshoot = now - r.die
				if overshoot >= r.sinkTime then
					r.ent:Remove()
					table.remove(groundRocks, i)
				elseif overshoot > 0 then
					-- Sinking back into the earth.
					r.ent:SetPos(r.ground + Vector(0, 0, Lerp(overshoot / r.sinkTime, r.riseH * 0.3, -r.riseH * 1.4)))
				else
					-- Erupting.
					local frac = math.min((now - r.spawnAt) / r.riseTime, 1)
					r.ent:SetPos(r.ground + Vector(0, 0, Lerp(frac, -r.riseH * 1.2, r.riseH * 0.3)))
				end
			end
		end
	end)

	-- Per-element impact bursts. Full impacts (intensity >= 0.9) sweep the whole
	-- radius outward so the effect READS at its real size; low-intensity ticks
	-- scatter across the area instead of puffing at the centre.
	local function impactFire(pos, radius, intensity, goldTint)
		local cloudCol = goldTint and Color(255, 200, 80) or nil
		local emberCol = goldTint and Color(255, 220, 110) or Color(255, 180, 80)
		local lightCol = goldTint and Color(255, 210, 90) or Color(255, 140, 50)

		local emitter = ParticleEmitter(pos)
		if emitter then
			fireClouds(emitter, pos, Vector(0, 0, 1), math.floor(6 + 9 * intensity), 1 + intensity * 0.6, cloudCol)
			embers(emitter, pos, math.floor(8 + 14 * intensity), emberCol)
			heatShimmer(emitter, pos)
			if goldTint then
				for _ = 1, math.floor(4 + 6 * intensity) do
					local p = emitter:Add("sprites/light_glow02_add", pos + VectorRand() * 10)
					if p then
						p:SetVelocity(VectorRand() * 60 + Vector(0, 0, 90))
						p:SetDieTime(math.Rand(0.5, 1.0))
						p:SetStartAlpha(220)
						p:SetEndAlpha(0)
						p:SetStartSize(math.Rand(3, 6))
						p:SetEndSize(0)
						p:SetColor(255, 230, 140)
					end
				end
			end
			emitter:Finish()
		end
		dlight(pos, lightCol, radius * 1.2, 2 + 2 * intensity)

		if intensity >= 0.9 then
			-- Blazing ring racing out to the true blast radius (ring_of_fire).
			ringSweep(pos, radius, 0.45, 6, math.Clamp(math.floor(radius / 24), 10, 26), function(em, ppos, dir)
				embers(em, ppos, 3, emberCol)
				fireClouds(em, ppos, dir, 2, 0.9, cloudCol)
			end)
		else
			areaScatter(pos, radius * 0.85, math.Clamp(math.floor(radius / 55), 3, 8), function(em, ppos)
				fireClouds(em, ppos, Vector(0, 0, 1), 1, 0.6, cloudCol)
				if math.random() < 0.4 then embers(em, ppos, 1, emberCol) end
			end)
		end
	end

	local IMPACT_CL = {
		fire = function(pos, radius, intensity)
			impactFire(pos, radius, intensity, false)
		end,

		aurum = function(pos, radius, intensity)
			impactFire(pos, radius, intensity, true)
		end,

		frost = function(pos, radius, intensity)
			addRing(pos, radius, Color(170, 220, 255), 0.5)
			dlight(pos, Color(170, 220, 255), radius, 1.6 + intensity)

			if intensity >= 0.9 then
				addRing(pos, radius * 1.2, Color(200, 235, 255), 0.65)
				addIceSpikes(pos, radius, math.Clamp(math.floor(radius / 26), 8, 20))
				ringSweep(pos, radius, 0.4, 5, math.Clamp(math.floor(radius / 30), 8, 20), function(em, ppos, dir)
					local mat = (math.random() < 0.5) and "effects/fleck_glass1" or "effects/fleck_glass2"
					local p = em:Add(mat, ppos)
					if p then
						p:SetVelocity(dir * math.Rand(80, 180) + Vector(0, 0, math.Rand(60, 140)))
						p:SetDieTime(math.Rand(0.4, 0.8))
						p:SetStartAlpha(255)
						p:SetEndAlpha(0)
						p:SetStartSize(math.Rand(2, 4))
						p:SetEndSize(0)
						p:SetColor(200, 230, 255)
						p:SetGravity(Vector(0, 0, -220))
						p:SetCollide(true)
						p:SetBounce(0.2)
					end
					local m = em:Add("particle/particle_smokegrenade", ppos)
					if m then
						m:SetVelocity(VectorRand() * 30 + Vector(0, 0, 25))
						m:SetDieTime(0.6)
						m:SetStartAlpha(55)
						m:SetEndAlpha(0)
						m:SetStartSize(12)
						m:SetEndSize(30)
						m:SetColor(215, 235, 255)
						m:SetAirResistance(80)
					end
				end)
			else
				areaScatter(pos, radius * 0.85, math.Clamp(math.floor(radius / 55), 3, 8), function(em, ppos)
					local m = em:Add("particle/particle_smokegrenade", ppos)
					if m then
						m:SetVelocity(VectorRand() * 30 + Vector(0, 0, 25))
						m:SetDieTime(0.6)
						m:SetStartAlpha(45)
						m:SetEndAlpha(0)
						m:SetStartSize(10)
						m:SetEndSize(26)
						m:SetColor(215, 235, 255)
						m:SetAirResistance(80)
					end
				end)
			end
		end,

		lightning = function(pos, radius, intensity)
			local emitter = ParticleEmitter(pos)
			if emitter then
				for _ = 1, math.floor(16 + 30 * intensity) do
					local p = emitter:Add("effects/blueflare1", pos)
					if p then
						p:SetDieTime(math.Rand(0.3, 0.7))
						p:SetStartAlpha(255)
						p:SetEndAlpha(0)
						p:SetStartSize(math.Rand(8, 18) * (0.6 + intensity * 0.6))
						p:SetEndSize(0)
						p:SetColor(150, 200, 255)
						p:SetVelocity(VectorRand() * 320 * intensity)
						p:SetAirResistance(80)
						p:SetGravity(Vector(0, 0, -120))
					end
				end
				emitter:Finish()
			end
			dlight(pos, Color(190, 220, 255), radius * 1.4, 3 + 4 * intensity)

			if intensity >= 0.9 then
				-- Ground current crawling out to the edge: sparks skitter along
				-- the floor to the full radius.
				ringSweep(pos, radius, 0.3, 5, math.Clamp(math.floor(radius / 30), 8, 20), function(em, ppos, dir)
					local p = em:Add("effects/spark", ppos + Vector(0, 0, 5))
					if p then
						p:SetDieTime(math.Rand(0.3, 0.6))
						p:SetStartAlpha(255)
						p:SetEndAlpha(0)
						p:SetStartSize(math.Rand(2, 5))
						p:SetEndSize(0)
						p:SetColor(255, 255, 255)
						p:SetVelocity(dir * math.Rand(120, 240) + Vector(0, 0, math.Rand(20, 80)))
						p:SetGravity(Vector(0, 0, -600))
						p:SetCollide(true)
						p:SetBounce(0.3)
					end
					local f = em:Add("effects/blueflare1", ppos)
					if f then
						f:SetDieTime(math.Rand(0.15, 0.3))
						f:SetStartAlpha(220)
						f:SetEndAlpha(0)
						f:SetStartSize(math.Rand(8, 14))
						f:SetEndSize(0)
						f:SetColor(150, 200, 255)
						f:SetVelocity(dir * 60)
					end
				end)
			else
				areaScatter(pos, radius * 0.8, math.Clamp(math.floor(radius / 60), 2, 6), function(em, ppos)
					local f = em:Add("effects/blueflare1", ppos)
					if f then
						f:SetDieTime(0.25)
						f:SetStartAlpha(200)
						f:SetEndAlpha(0)
						f:SetStartSize(math.Rand(6, 10))
						f:SetEndSize(0)
						f:SetColor(150, 200, 255)
						f:SetVelocity(VectorRand() * 60)
					end
				end)
			end
		end,

		earth = function(pos, radius, intensity)
			local emitter = ParticleEmitter(pos)
			if emitter then
				for _ = 1, math.floor(6 + 8 * intensity) do
					local mat = (math.random() < 0.5) and "effects/fleck_cement1" or "effects/fleck_cement2"
					local p = emitter:Add(mat, pos + VectorRand() * 6)
					if p then
						p:SetVelocity(VectorRand() * 220 + Vector(0, 0, math.Rand(80, 200)))
						p:SetDieTime(math.Rand(0.5, 1.0))
						p:SetStartAlpha(255)
						p:SetEndAlpha(0)
						p:SetStartSize(math.Rand(2, 5))
						p:SetEndSize(0)
						p:SetColor(140, 130, 120)
						p:SetGravity(Vector(0, 0, -500))
						p:SetCollide(true)
						p:SetBounce(0.2)
					end
				end
				emitter:Finish()
			end

			local sweepFn = function(em, ppos, dir, frac)
				local p = em:Add("particle/particle_smokegrenade", ppos)
				if p then
					p:SetVelocity(dir * math.Rand(40, 100) + Vector(0, 0, math.Rand(30, 80)))
					p:SetDieTime(0.8 + math.Rand(0.2, 0.5))
					p:SetStartAlpha(120)
					p:SetEndAlpha(0)
					p:SetStartSize(16)
					p:SetEndSize(46)
					p:SetRoll(math.Rand(0, 360))
					p:SetColor(120, 110, 100)
					p:SetAirResistance(70)
					p:SetGravity(Vector(0, 0, -20))
				end
				if math.random() < 0.5 then
					local mat = (math.random() < 0.5) and "effects/fleck_cement1" or "effects/fleck_cement2"
					local f = em:Add(mat, ppos)
					if f then
						f:SetVelocity(dir * 80 + Vector(0, 0, math.Rand(80, 180)))
						f:SetDieTime(math.Rand(0.5, 0.9))
						f:SetStartAlpha(255)
						f:SetEndAlpha(0)
						f:SetStartSize(math.Rand(2, 5))
						f:SetEndSize(0)
						f:SetColor(140, 130, 120)
						f:SetGravity(Vector(0, 0, -500))
						f:SetCollide(true)
					end
				end
			end

			if intensity >= 0.9 then
				-- Upheaval wave: dust and debris erupting out to the full radius,
				-- with real rocks bursting out of the ground across the area.
				ringSweep(pos, radius, 0.45, 6, math.Clamp(math.floor(radius / 30), 8, 20), sweepFn)
				spawnGroundRocks(pos, radius * 0.85, math.Clamp(math.floor(radius / 36), 5, 12), 2.4, { stagger = 0.4 })
			else
				areaScatter(pos, radius * 0.85, math.Clamp(math.floor(radius / 55), 3, 8), function(em, ppos)
					sweepFn(em, ppos, Vector(0, 0, 1), 1)
				end)
			end
		end,

		wind = function(pos, radius, intensity)
			addRing(pos, radius, Color(220, 245, 240, 160), 0.4)
			if intensity >= 0.9 then
				addRing(pos, radius * 0.65, Color(230, 250, 250, 130), 0.3)
			end

			local gust = function(em, ppos, dir)
				local p = em:Add("effects/splash2", ppos)
				if p then
					p:SetVelocity(dir * math.Rand(200, 340) + Vector(0, 0, math.Rand(20, 80)))
					p:SetDieTime(math.Rand(0.3, 0.5))
					p:SetStartAlpha(90)
					p:SetEndAlpha(0)
					p:SetStartSize(math.Rand(6, 12))
					p:SetEndSize(math.Rand(22, 32))
					p:SetRoll(math.Rand(0, 360))
					p:SetRollDelta(math.Rand(-4, 4))
					p:SetColor(210, 230, 250)
					p:SetAirResistance(60)
				end
				local m = em:Add("particle/particle_smokegrenade", ppos)
				if m then
					m:SetVelocity(dir * math.Rand(150, 260))
					m:SetDieTime(math.Rand(0.4, 0.7))
					m:SetStartAlpha(40)
					m:SetEndAlpha(0)
					m:SetStartSize(12)
					m:SetEndSize(34)
					m:SetColor(230, 245, 245)
					m:SetAirResistance(50)
				end
			end

			if intensity >= 0.9 then
				ringSweep(pos, radius, 0.3, 5, math.Clamp(math.floor(radius / 32), 8, 18), gust)
			else
				areaScatter(pos, radius * 0.8, math.Clamp(math.floor(radius / 60), 2, 6), gust)
			end
		end,

		poison = function(pos, radius, intensity)
			-- Poison FILLS its volume: clouds scattered through the whole area.
			areaScatter(pos, radius * 0.9, math.Clamp(math.floor(radius / 20), 8, 26), function(em, ppos)
				local colorVar = math.Rand(0.8, 1.1)
				local p = em:Add("particle/particle_smokegrenade", ppos + Vector(0, 0, math.Rand(4, 30)))
				if p then
					p:SetVelocity(VectorRand() * 35 + Vector(0, 0, math.Rand(12, 40)))
					p:SetDieTime((1.0 + math.Rand(0.3, 0.9)) * (0.6 + intensity * 0.5))
					p:SetStartAlpha(90)
					p:SetEndAlpha(0)
					p:SetStartSize((16 + math.random(0, 8)) * (0.7 + intensity * 0.5))
					p:SetEndSize((48 + math.random(0, 18)) * (0.7 + intensity * 0.5))
					p:SetRoll(math.Rand(0, 360))
					p:SetColor(100 * colorVar, 180 * colorVar, 50 * colorVar)
					p:SetAirResistance(80)
					p:SetGravity(Vector(0, 0, 8))
				end
				if math.random() < 0.35 then
					local d = em:Add("effects/blueflare1", ppos + Vector(0, 0, 20))
					if d then
						d:SetVelocity(Vector(0, 0, -70) + VectorRand() * 20)
						d:SetDieTime(math.Rand(0.3, 0.6))
						d:SetStartAlpha(160)
						d:SetEndAlpha(0)
						d:SetStartSize(math.Rand(4, 8))
						d:SetEndSize(0)
						d:SetColor(120, 220, 70)
						d:SetGravity(Vector(0, 0, -140))
					end
				end
			end)
		end,

		arcane = function(pos, radius, intensity)
			addRing(pos, radius * 0.95, Color(180, 120, 255), 0.45)
			dlight(pos, Color(180, 120, 255), radius, 2 + 2 * intensity)

			local emitter = ParticleEmitter(pos)
			if emitter then
				for _ = 1, math.floor(10 + 16 * intensity) do
					local p = emitter:Add("effects/blueflare1", pos)
					if p then
						p:SetDieTime(math.Rand(0.3, 0.6))
						p:SetStartAlpha(230)
						p:SetEndAlpha(0)
						p:SetStartSize(math.Rand(8, 16) * (0.7 + intensity * 0.5))
						p:SetEndSize(0)
						p:SetColor(180, 120, 255)
						p:SetVelocity(VectorRand() * 260 * intensity)
						p:SetAirResistance(90)
					end
				end
				emitter:Finish()
			end

			if intensity >= 0.9 then
				ringSweep(pos, radius, 0.35, 5, math.Clamp(math.floor(radius / 34), 8, 18), function(em, ppos, dir)
					local p = em:Add("effects/blueflare1", ppos)
					if p then
						p:SetDieTime(math.Rand(0.25, 0.45))
						p:SetStartAlpha(220)
						p:SetEndAlpha(0)
						p:SetStartSize(math.Rand(8, 14))
						p:SetEndSize(0)
						p:SetColor(180, 120, 255)
						p:SetVelocity(dir * 90 + Vector(0, 0, math.Rand(20, 70)))
						p:SetAirResistance(70)
					end
				end)
			end
		end,
	}

	net.Receive("Arcana_Spellcraft_ImpactFX", function()
		local element = net.ReadString()
		local pos = net.ReadVector()
		local radius = net.ReadFloat()
		local intensity = net.ReadFloat()

		local burst = IMPACT_CL[element] or IMPACT_CL.arcane
		burst(pos, radius, intensity)
	end)

	-- Rings + ice spikes renderer
	hook.Add("PostDrawTranslucentRenderables", "Arcana_Spellcraft_ImpactShapes", function(depth, sky)
		if depth or sky then return end
		local now = CurTime()

		for i = #rings, 1, -1 do
			local r = rings[i]
			if now > r.die then
				table.remove(rings, i)
			else
				local frac = math.Clamp(1 - (r.die - now) / r.life, 0, 1)
				local cur = Lerp(frac, r.radius * 0.15, r.radius)
				local a = 220 * (1 - frac)
				render.SetMaterial(matRing)
				render.DrawQuadEasy(r.pos + Vector(0, 0, 3), Vector(0, 0, 1), cur, cur, Color(r.col.r, r.col.g, r.col.b, a), 0)
				render.SetMaterial(matGlow)
				render.DrawSprite(r.pos + Vector(0, 0, 5), cur * 0.4, cur * 0.4, Color(r.col.r, r.col.g, r.col.b, a * 0.5))
			end
		end

		for i = #spikes, 1, -1 do
			local s = spikes[i]
			if now > s.die then
				table.remove(spikes, i)
			else
				local t = math.Clamp(1 - (s.die - now) / s.life, 0, 1)
				local grow = math.EaseInOut(t, 0.2, 0.6)
				local tip = s.pos + s.normal * (s.height * grow)
				render.SetMaterial(matPhysBeam)
				render.StartBeam(2)
				render.AddBeam(s.pos, 8, 0, Color(200, 230, 255, 230 * (1 - t * 0.6)))
				render.AddBeam(tip, 2, 1, Color(200, 230, 255, 230 * (1 - t * 0.6)))
				render.EndBeam()
				render.SetMaterial(matGlow)
				render.DrawSprite(tip, 10, 10, Color(200, 240, 255, 200 * (1 - t)))
			end
		end
	end)

	----------------------------------------------------------------
	-- Beams
	----------------------------------------------------------------
	-- style: core/outer colors, widths, jagged (lightning-like), life
	local BEAM_STYLE = {
		fire = { core = Color(255, 235, 200), outer = Color(255, 120, 40), width = 14, life = 0.35 },
		frost = { core = Color(240, 250, 255), outer = Color(170, 220, 255), width = 12, life = 0.35 },
		lightning = { core = Color(255, 255, 255), outer = Color(150, 200, 255), width = 14, life = 0.4, jagged = true },
		earth = { core = Color(210, 190, 160), outer = Color(150, 125, 95), width = 16, life = 0.3 },
		wind = { core = Color(240, 250, 250), outer = Color(200, 240, 220), width = 8, life = 0.3, strands = true },
		poison = { core = Color(200, 255, 160), outer = Color(120, 210, 70), width = 13, life = 0.35 },
		arcane = { core = Color(255, 230, 255), outer = Color(180, 120, 255), width = 14, life = 0.35 },
		aurum = { core = Color(255, 245, 210), outer = Color(255, 210, 90), width = 14, life = 0.35 },
	}

	-- Per-element particles salted along the beam once, on receive.
	local function beamParticles(element, startPos, endPos)
		local dir = endPos - startPos
		local len = dir:Length()
		if len < 1 then return end
		dir:Normalize()

		local emitter = ParticleEmitter((startPos + endPos) * 0.5)
		if not emitter then return end

		local steps = math.Clamp(math.floor(len / 70), 4, 24)
		for i = 0, steps do
			local pos = startPos + dir * (len * (i / steps))

			if element == "fire" or element == "aurum" then
				fireClouds(emitter, pos, dir, 1, 0.8, element == "aurum" and Color(255, 200, 80) or nil)
				if i % 3 == 0 then heatShimmer(emitter, pos) end
			elseif element == "frost" then
				local p = emitter:Add("particle/particle_smokegrenade", pos)
				if p then
					p:SetVelocity(VectorRand() * 25)
					p:SetDieTime(0.4)
					p:SetStartAlpha(50)
					p:SetEndAlpha(0)
					p:SetStartSize(8)
					p:SetEndSize(20)
					p:SetColor(215, 235, 255)
				end
			elseif element == "lightning" then
				local p = emitter:Add("effects/blueflare1", pos + VectorRand() * 8)
				if p then
					p:SetVelocity(VectorRand() * 60)
					p:SetDieTime(math.Rand(0.15, 0.3))
					p:SetStartAlpha(220)
					p:SetEndAlpha(0)
					p:SetStartSize(math.Rand(6, 12))
					p:SetEndSize(0)
					p:SetColor(150, 200, 255)
				end
			elseif element == "earth" then
				local mat = (math.random() < 0.5) and "effects/fleck_cement1" or "effects/fleck_cement2"
				local p = emitter:Add(mat, pos)
				if p then
					p:SetVelocity(VectorRand() * 60)
					p:SetDieTime(math.Rand(0.3, 0.6))
					p:SetStartAlpha(255)
					p:SetEndAlpha(0)
					p:SetStartSize(math.Rand(2, 4))
					p:SetEndSize(0)
					p:SetColor(140, 130, 120)
					p:SetGravity(Vector(0, 0, -400))
				end
			elseif element == "wind" then
				local p = emitter:Add("effects/splash2", pos)
				if p then
					p:SetVelocity(dir * 120 + VectorRand() * 30)
					p:SetDieTime(0.3)
					p:SetStartAlpha(70)
					p:SetEndAlpha(0)
					p:SetStartSize(6)
					p:SetEndSize(16)
					p:SetColor(220, 240, 245)
				end
			elseif element == "poison" then
				local p = emitter:Add("particle/particle_smokegrenade", pos)
				if p then
					p:SetVelocity(VectorRand() * 20 + Vector(0, 0, -30))
					p:SetDieTime(0.6)
					p:SetStartAlpha(70)
					p:SetEndAlpha(0)
					p:SetStartSize(8)
					p:SetEndSize(22)
					p:SetColor(110, 190, 60)
				end
			elseif element == "arcane" then
				if i % 2 == 0 then
					local p = emitter:Add("effects/blueflare1", pos + VectorRand() * 4)
					if p then
						p:SetVelocity(VectorRand() * 40)
						p:SetDieTime(0.3)
						p:SetStartAlpha(200)
						p:SetEndAlpha(0)
						p:SetStartSize(8)
						p:SetEndSize(0)
						p:SetColor(180, 120, 255)
					end
				end
			end
		end

		emitter:Finish()
	end

	local activeBeams = {}

	net.Receive("Arcana_Spellcraft_BeamFX", function()
		local element = net.ReadString()
		local startPos = net.ReadVector()
		local endPos = net.ReadVector()

		activeBeams[#activeBeams + 1] = {
			element = element,
			startPos = startPos,
			endPos = endPos,
			startTime = CurTime(),
			die = CurTime() + ((BEAM_STYLE[element] or BEAM_STYLE.arcane).life or 0.35),
		}

		beamParticles(element, startPos, endPos)

		-- Earth beams punch a small crater: a ring of rocks leaning outward
		-- around the impact point.
		if element == "earth" then
			spawnGroundRocks(endPos, 36, 6, 3.5, {
				ring = true,
				tiltOut = true,
				minScale = 0.4,
				maxScale = 0.8,
				stagger = 0.12,
			})
		end
	end)

	hook.Add("PostDrawTranslucentRenderables", "Arcana_Spellcraft_Beams", function(depth, sky)
		if depth or sky then return end
		if #activeBeams == 0 then return end
		local now = CurTime()

		for i = #activeBeams, 1, -1 do
			local b = activeBeams[i]
			if now > b.die then
				table.remove(activeBeams, i)
			else
				local style = BEAM_STYLE[b.element] or BEAM_STYLE.arcane
				local life = style.life or 0.35
				local frac = math.Clamp((b.die - now) / life, 0, 1)
				local age = now - b.startTime
				local fade = math.min(age / 0.06, 1) * frac

				local a, c = b.startPos, b.endPos
				local dir = c - a
				local len = dir:Length()
				if len < 1 then continue end
				dir:Normalize()

				render.SetMaterial(matBeam)

				if style.jagged then
					-- Lightning: flickering jagged path, regenerated per frame,
					-- with side branches (lightning_strike style).
					local flicker = math.sin(now * 70 + b.startTime * 90) * 0.3 + 0.7
					local alpha = 255 * fade * flicker
					local segments = math.Clamp(math.floor(len / 90), 6, 22)
					local path = {}
					for seg = 0, segments do
						local t = seg / segments
						local pos = a + dir * (len * t)
						local jag = math.sin(t * math.pi) * 22
						path[seg] = pos + VectorRand() * jag
					end

					render.StartBeam(segments + 1)
					for seg = 0, segments do
						render.AddBeam(path[seg], style.width * 0.8 * flicker, seg / segments, Color(255, 255, 255, alpha))
					end
					render.EndBeam()

					render.StartBeam(segments + 1)
					for seg = 0, segments do
						render.AddBeam(path[seg], style.width * 1.8 * flicker, seg / segments, Color(style.outer.r, style.outer.g, style.outer.b, alpha * 0.6))
					end
					render.EndBeam()

					-- Branches
					for _ = 1, 3 do
						local si = math.random(1, segments - 1)
						local bp = path[si]
						local be = bp + VectorRand() * 90
						render.StartBeam(4)
						for seg = 0, 3 do
							local t = seg / 3
							local pos = LerpVector(t, bp, be) + VectorRand() * 12
							render.AddBeam(pos, Lerp(t, 8, 1) * flicker, t, Color(style.outer.r, style.outer.g, style.outer.b, alpha * 0.5 * (1 - t)))
						end
						render.EndBeam()
					end
				elseif style.strands then
					-- Wind: three faint offset strands that drift.
					local alpha = 150 * fade
					local right = dir:Angle():Right()
					local up = dir:Angle():Up()
					for strand = -1, 1 do
						local segments = 12
						render.StartBeam(segments + 1)
						for seg = 0, segments do
							local t = seg / segments
							local sway = math.sin(t * math.pi * 3 + now * 12 + strand * 2) * 10
							local pos = a + dir * (len * t) + right * (strand * 8 + sway) + up * math.sin(t * math.pi * 2 + now * 9) * 6
							render.AddBeam(pos, style.width * (1 - t * 0.3), t, Color(style.outer.r, style.outer.g, style.outer.b, alpha * (1 - t * 0.4)))
						end
						render.EndBeam()
					end
				else
					-- Standard layered beam: hot core, tinted body, soft glow.
					local alpha = 255 * fade
					local steps = math.max(6, math.floor(len / 40))
					local function layer(width, col, colAlpha)
						render.StartBeam(steps + 1)
						for j = 0, steps do
							local t = j / steps
							local pulse = 1 + math.sin(age * 20 + t * 3) * 0.12
							render.AddBeam(a + dir * (len * t), width * pulse * fade, t, Color(col.r, col.g, col.b, colAlpha))
						end
						render.EndBeam()
					end

					layer(style.width * 0.7, style.core, alpha)
					layer(style.width * 1.3, style.outer, alpha * 0.8)
					layer(style.width * 2.3, style.outer, alpha * 0.28)
				end

				-- Endpoint glows
				render.SetMaterial(matFlare)
				render.DrawSprite(c, style.width * 4 * fade, style.width * 4 * fade, Color(style.core.r, style.core.g, style.core.b, 220 * fade))
				render.SetMaterial(matGlow)
				render.DrawSprite(c, style.width * 6 * fade, style.width * 6 * fade, Color(style.outer.r, style.outer.g, style.outer.b, 160 * fade))
				render.DrawSprite(a, style.width * 5 * fade, style.width * 5 * fade, Color(style.outer.r, style.outer.g, style.outer.b, 140 * fade))
			end
		end
	end)

	----------------------------------------------------------------
	-- Self auras: continuous element effects around the caster. No magic
	-- circles here; the element itself is the aura.
	----------------------------------------------------------------
	local activeAuras = {}  -- [ent] = { element, radius, die, next }
	local auraArcs = {}     -- lightning arcs { from, to, die, startTime }

	-- Remove an aura's clientside props (earth orbit rocks).
	local function cleanupAuraProps(aura)
		if not aura or not aura.rocks then return end
		for _, rec in ipairs(aura.rocks) do
			if IsValid(rec.ent) then rec.ent:Remove() end
		end
		aura.rocks = nil
	end

	net.Receive("Arcana_Spellcraft_AuraFX", function()
		local ent = net.ReadEntity()
		local element = net.ReadString()
		local radius = net.ReadFloat()
		local duration = net.ReadFloat()
		if not IsValid(ent) then return end

		-- Replacing or stopping an aura always clears its props first.
		cleanupAuraProps(activeAuras[ent])

		if duration <= 0 then
			activeAuras[ent] = nil
			return
		end

		local aura = { element = element, radius = radius, die = CurTime() + duration, next = 0 }

		-- Earth: a tornado of rocks orbiting the caster. All rotate the same
		-- way; orbit widens with height (funnel), each rock tumbles.
		if element == "earth" then
			aura.rocks = {}
			for i = 1, 8 do
				local rock = createRock(math.Rand(0.45, 0.95))
				if rock then
					local height = math.Rand(6, 78)
					aura.rocks[#aura.rocks + 1] = {
						ent = rock,
						ang = (i / 8) * 360 + math.Rand(-20, 20),
						speed = math.Rand(220, 300),
						orbitR = Lerp(height / 80, radius * 0.3, radius * 0.75),
						height = height,
						bob = math.Rand(0, math.pi * 2),
						spin = VectorRand():GetNormalized(),
						spinSpeed = math.Rand(90, 220),
					}
				end
			end
		end

		activeAuras[ent] = aura
	end)

	-- One emission pulse for an aura. base is the entity's feet position.
	local AURA_CL = {
		fire = function(emitter, base, radius, goldTint)
			local cloudCol = goldTint and Color(255, 200, 80) or nil
			local emberCol = goldTint and Color(255, 220, 110) or Color(255, 180, 80)

			-- Inner carpet of flames around the caster.
			for _ = 1, 3 do
				local dir = Angle(0, math.Rand(0, 360), 0):Forward()
				local ppos = base + dir * math.Rand(radius * 0.15, radius * 0.7)
				fireClouds(emitter, ppos, Vector(0, 0, 1), 1, 0.8, cloudCol)
				embers(emitter, ppos, 1, emberCol)
			end

			-- Ring of fire tracing the aura's edge.
			for _ = 1, 3 do
				local ang = math.Rand(0, 360)
				local dir = Angle(0, ang, 0):Forward()
				local ppos = base + dir * math.Rand(radius * 0.85, radius)
				fireClouds(emitter, ppos, dir, 1, 0.7, cloudCol)
				if math.random() < 0.6 then embers(emitter, ppos, 1, emberCol) end
			end

			-- Flame licks jumping upward.
			for _ = 1, 2 do
				local p = emitter:Add("effects/yellowflare", base + Angle(0, math.Rand(0, 360), 0):Forward() * math.Rand(0, radius * 0.8))
				if p then
					p:SetVelocity(Vector(math.Rand(-15, 15), math.Rand(-15, 15), math.Rand(90, 170)))
					p:SetDieTime(math.Rand(0.4, 0.7))
					p:SetStartAlpha(230)
					p:SetEndAlpha(0)
					p:SetStartSize(math.Rand(5, 9))
					p:SetEndSize(0)
					p:SetColor(emberCol.r, emberCol.g, emberCol.b)
					p:SetLighting(false)
					p:SetAirResistance(40)
				end
			end

			if math.random() < 0.6 then heatShimmer(emitter, base + Vector(0, 0, 40)) end
		end,
		frost = function(emitter, base, radius)
			-- Orbiting cold mist at several heights.
			for _ = 1, 4 do
				local ang = math.Rand(0, 360)
				local dir = Angle(0, ang, 0):Forward()
				local tangent = Angle(0, ang + 90, 0):Forward()
				local ppos = base + dir * math.Rand(radius * 0.3, radius * 0.95) + Vector(0, 0, math.Rand(4, 60))
				local m = emitter:Add("particle/particle_smokegrenade", ppos)
				if m then
					m:SetVelocity(tangent * math.Rand(50, 90) + Vector(0, 0, 12))
					m:SetDieTime(math.Rand(0.7, 1.1))
					m:SetStartAlpha(55)
					m:SetEndAlpha(0)
					m:SetStartSize(math.Rand(10, 16))
					m:SetEndSize(math.Rand(26, 36))
					m:SetColor(215, 235, 255)
					m:SetAirResistance(70)
				end
			end

			-- Snowfall glitter drifting down through the aura.
			for _ = 1, 2 do
				local mat = (math.random() < 0.5) and "effects/fleck_glass1" or "effects/fleck_glass2"
				local dir = Angle(0, math.Rand(0, 360), 0):Forward()
				local p = emitter:Add(mat, base + dir * math.Rand(10, radius * 0.9) + Vector(0, 0, math.Rand(30, 80)))
				if p then
					p:SetVelocity(VectorRand() * 30)
					p:SetDieTime(math.Rand(0.6, 1.1))
					p:SetStartAlpha(255)
					p:SetEndAlpha(0)
					p:SetStartSize(math.Rand(2, 3))
					p:SetEndSize(0)
					p:SetColor(200, 230, 255)
					p:SetGravity(Vector(0, 0, -90))
				end
			end

			-- Ground frost fog.
			local g = emitter:Add("particle/particle_smokegrenade", base + Angle(0, math.Rand(0, 360), 0):Forward() * math.Rand(0, radius * 0.8))
			if g then
				g:SetVelocity(Vector(math.Rand(-12, 12), math.Rand(-12, 12), 0))
				g:SetDieTime(math.Rand(1.2, 1.8))
				g:SetStartAlpha(0)
				g:SetEndAlpha(70)
				g:SetStartSize(18)
				g:SetEndSize(38)
				g:SetColor(215, 235, 255)
				g:SetAirResistance(110)
			end
		end,
		lightning = function(emitter, base, radius)
			-- Sparks popping all around the field.
			for _ = 1, 3 do
				local dir = Angle(0, math.Rand(0, 360), 0):Forward()
				local ppos = base + dir * math.Rand(radius * 0.3, radius) + Vector(0, 0, math.Rand(4, 50))
				local p = emitter:Add("effects/spark", ppos)
				if p then
					p:SetVelocity(VectorRand() * 110)
					p:SetDieTime(math.Rand(0.2, 0.4))
					p:SetStartAlpha(255)
					p:SetEndAlpha(0)
					p:SetStartSize(math.Rand(3, 6))
					p:SetEndSize(0)
					p:SetColor(255, 255, 255)
					p:SetGravity(Vector(0, 0, -300))
					p:SetCollide(true)
				end
			end

			-- Crackling glow motes at the rim.
			for _ = 1, 2 do
				local dir = Angle(0, math.Rand(0, 360), 0):Forward()
				local f = emitter:Add("effects/blueflare1", base + dir * math.Rand(radius * 0.7, radius) + Vector(0, 0, math.Rand(4, 30)))
				if f then
					f:SetVelocity(VectorRand() * 60)
					f:SetDieTime(math.Rand(0.15, 0.3))
					f:SetStartAlpha(230)
					f:SetEndAlpha(0)
					f:SetStartSize(math.Rand(7, 12))
					f:SetEndSize(0)
					f:SetColor(150, 200, 255)
				end
			end
		end,
		earth = function(emitter, base, radius)
			-- Dust bed swirling low.
			for _ = 1, 3 do
				local ang = math.Rand(0, 360)
				local dir = Angle(0, ang, 0):Forward()
				local tangent = Angle(0, ang + 90, 0):Forward()
				local ppos = base + dir * math.Rand(radius * 0.3, radius * 0.95)
				local p = emitter:Add("particle/particle_smokegrenade", ppos)
				if p then
					p:SetVelocity(tangent * math.Rand(30, 70) + Vector(0, 0, math.Rand(6, 20)))
					p:SetDieTime(math.Rand(0.9, 1.4))
					p:SetStartAlpha(0)
					p:SetEndAlpha(90)
					p:SetStartSize(math.Rand(12, 18))
					p:SetEndSize(math.Rand(30, 42))
					p:SetColor(120, 110, 100)
					p:SetAirResistance(70)
				end
			end

			-- Orbiting grit and floating pebbles.
			for _ = 1, 2 do
				local mat = (math.random() < 0.5) and "effects/fleck_cement1" or "effects/fleck_cement2"
				local ang = math.Rand(0, 360)
				local dir = Angle(0, ang, 0):Forward()
				local tangent = Angle(0, ang + 90, 0):Forward()
				local f = emitter:Add(mat, base + dir * math.Rand(radius * 0.3, radius * 0.7) + Vector(0, 0, math.Rand(10, 60)))
				if f then
					f:SetVelocity(tangent * math.Rand(60, 110) + Vector(0, 0, math.Rand(-10, 30)))
					f:SetDieTime(math.Rand(0.6, 1.1))
					f:SetStartAlpha(255)
					f:SetEndAlpha(0)
					f:SetStartSize(math.Rand(2, 4))
					f:SetEndSize(0)
					f:SetColor(140, 130, 120)
					f:SetGravity(Vector(0, 0, -120))
				end
			end
		end,
		wind = function(emitter, base, radius)
			-- A personal vortex: streaks spiraling up a cone around the caster.
			local height = math.max(90, radius * 0.9)
			for _ = 1, 5 do
				local h = math.Rand(0, height)
				local frac = h / height
				local r = Lerp(frac, radius * 0.35, radius)
				local ang = math.Rand(0, 360)
				local dir = Angle(0, ang, 0):Forward()
				local tangent = Angle(0, ang + 90, 0):Forward()
				local p = emitter:Add("effects/splash2", base + dir * r + Vector(0, 0, h))
				if p then
					p:SetVelocity(tangent * math.Rand(220, 340) - dir * math.Rand(10, 50) + Vector(0, 0, math.Rand(30, 70)))
					p:SetDieTime(math.Rand(0.3, 0.5))
					p:SetStartAlpha(85)
					p:SetEndAlpha(0)
					p:SetStartSize(math.Rand(5, 9))
					p:SetEndSize(math.Rand(16, 26))
					p:SetRoll(math.Rand(0, 360))
					p:SetRollDelta(math.Rand(-6, 6))
					p:SetColor(220, 240, 245)
					p:SetAirResistance(30)
				end
			end

			-- Haze circulating in the column.
			local ang = math.Rand(0, 360)
			local dir = Angle(0, ang, 0):Forward()
			local tangent = Angle(0, ang + 90, 0):Forward()
			local m = emitter:Add("particle/particle_smokegrenade", base + dir * radius * 0.5 + Vector(0, 0, math.Rand(10, height * 0.7)))
			if m then
				m:SetVelocity(tangent * math.Rand(140, 220) + Vector(0, 0, 40))
				m:SetDieTime(math.Rand(0.5, 0.8))
				m:SetStartAlpha(0)
				m:SetEndAlpha(40)
				m:SetStartSize(14)
				m:SetEndSize(32)
				m:SetColor(225, 240, 240)
				m:SetAirResistance(40)
			end
		end,
		poison = function(emitter, base, radius)
			-- Dense ground fog across the whole aura (poison_cloud style).
			for _ = 1, 3 do
				local rr = radius * math.sqrt(math.Rand(0, 1))
				local a = math.Rand(0, math.pi * 2)
				local ppos = base + Vector(math.cos(a) * rr, math.sin(a) * rr, math.Rand(0, 10))
				local colorVar = math.Rand(0.8, 1.2)
				local p = emitter:Add("particle/particle_smokegrenade", ppos)
				if p then
					p:SetVelocity(Vector(math.Rand(-15, 15), math.Rand(-15, 15), 0))
					p:SetDieTime(math.Rand(2.0, 3.0))
					p:SetStartAlpha(0)
					p:SetEndAlpha(math.Rand(110, 150))
					local sz = math.Rand(26, 40)
					p:SetStartSize(sz)
					p:SetEndSize(sz * 1.5)
					p:SetColor(100 * colorVar, 180 * colorVar, 50 * colorVar)
					p:SetAirResistance(120)
					p:SetGravity(Vector(0, 0, math.Rand(2, 6)))
				end
			end
			-- Rising wisp + bubbling glint
			if math.random() > 0.4 then
				local dir = Angle(0, math.Rand(0, 360), 0):Forward()
				local p = emitter:Add("particle/particle_smokegrenade", base + dir * math.Rand(0, radius * 0.7))
				if p then
					p:SetVelocity(Vector(math.Rand(-8, 8), math.Rand(-8, 8), math.Rand(25, 45)))
					p:SetDieTime(math.Rand(1.4, 2.2))
					p:SetStartAlpha(0)
					p:SetEndAlpha(120)
					p:SetStartSize(16)
					p:SetEndSize(12)
					p:SetColor(120, 220, 70)
					p:SetAirResistance(50)
					p:SetGravity(Vector(0, 0, 40))
				end
			end
			if math.random() > 0.55 then
				local dir = Angle(0, math.Rand(0, 360), 0):Forward()
				local g = emitter:Add("effects/blueflare1", base + dir * math.Rand(0, radius * 0.8))
				if g then
					g:SetVelocity(Vector(0, 0, math.Rand(15, 30)))
					g:SetDieTime(math.Rand(0.8, 1.4))
					g:SetStartAlpha(220)
					g:SetEndAlpha(0)
					g:SetStartSize(math.Rand(8, 13))
					g:SetEndSize(0)
					g:SetColor(140, 220, 80)
					g:SetGravity(Vector(0, 0, 30))
				end
			end
		end,
		arcane = function(emitter, base, radius)
			-- Two counter-rotating rings of motes at different heights.
			local t = CurTime()
			for k = 1, 3 do
				local ang = t * 160 + k * 120
				local dir = Angle(0, ang, 0):Forward()
				local ppos = base + dir * radius * 0.65 + Vector(0, 0, 34 + math.sin(t * 3 + k) * 20)
				local p = emitter:Add("effects/blueflare1", ppos)
				if p then
					p:SetVelocity(Angle(0, ang + 90, 0):Forward() * 90)
					p:SetDieTime(0.35)
					p:SetStartAlpha(220)
					p:SetEndAlpha(0)
					p:SetStartSize(math.Rand(7, 11))
					p:SetEndSize(0)
					p:SetColor(180, 120, 255)
					p:SetAirResistance(60)
				end
			end
			for k = 1, 3 do
				local ang = -t * 120 + k * 120 + 60
				local dir = Angle(0, ang, 0):Forward()
				local ppos = base + dir * radius * 0.4 + Vector(0, 0, 54 + math.cos(t * 2.4 + k) * 14)
				local p = emitter:Add("effects/blueflare1", ppos)
				if p then
					p:SetVelocity(Angle(0, ang - 90, 0):Forward() * 70)
					p:SetDieTime(0.3)
					p:SetStartAlpha(190)
					p:SetEndAlpha(0)
					p:SetStartSize(math.Rand(5, 8))
					p:SetEndSize(0)
					p:SetColor(200, 150, 255)
					p:SetAirResistance(60)
				end
			end

			-- Drifting sparkles filling the field.
			local dir = Angle(0, math.Rand(0, 360), 0):Forward()
			local s = emitter:Add("effects/blueflare1", base + dir * math.Rand(0, radius * 0.9) + Vector(0, 0, math.Rand(4, 70)))
			if s then
				s:SetVelocity(VectorRand() * 30 + Vector(0, 0, 25))
				s:SetDieTime(math.Rand(0.4, 0.8))
				s:SetStartAlpha(160)
				s:SetEndAlpha(0)
				s:SetStartSize(math.Rand(3, 6))
				s:SetEndSize(0)
				s:SetColor(180, 120, 255)
			end
		end,
	}
	AURA_CL.aurum = function(emitter, base, radius)
		AURA_CL.fire(emitter, base, radius, true)
	end

	-- A random bone position on the model (falls back to center mass).
	local function randomBonePos(ent)
		local count = ent:GetBoneCount() or 0
		if count > 0 then
			for _ = 1, 4 do
				local m = ent:GetBoneMatrix(math.random(0, count - 1))
				if m then
					local pos = m:GetTranslation()
					if pos and not pos:IsZero() then return pos end
				end
			end
		end
		return ent:WorldSpaceCenter()
	end

	-- Body layer: the element crawling over the caster's model itself.
	local AURA_BODY = {
		fire = function(emitter, ent)
			for _ = 1, 3 do
				local bp = randomBonePos(ent)
				fireClouds(emitter, bp, Vector(0, 0, 1), 1, 0.5)
				embers(emitter, bp, 1, Color(255, 180, 80))
			end
		end,
		aurum = function(emitter, ent)
			for _ = 1, 3 do
				local bp = randomBonePos(ent)
				fireClouds(emitter, bp, Vector(0, 0, 1), 1, 0.5, Color(255, 200, 80))
				if math.random() < 0.6 then embers(emitter, bp, 1, Color(255, 220, 110)) end
			end
		end,
		lightning = function(emitter, ent)
			-- Electricity arcing between bones.
			if math.random() < 0.85 then
				auraArcs[#auraArcs + 1] = {
					from = randomBonePos(ent),
					to = randomBonePos(ent),
					die = CurTime() + 0.1,
					startTime = CurTime(),
					width = 4,
				}
			end
			for _ = 1, 2 do
				local p = emitter:Add("effects/spark", randomBonePos(ent))
				if p then
					p:SetVelocity(VectorRand() * 60)
					p:SetDieTime(math.Rand(0.15, 0.3))
					p:SetStartAlpha(255)
					p:SetEndAlpha(0)
					p:SetStartSize(math.Rand(2, 4))
					p:SetEndSize(0)
					p:SetColor(200, 225, 255)
					p:SetGravity(Vector(0, 0, -200))
				end
			end
		end,
		frost = function(emitter, ent)
			local bp = randomBonePos(ent)
			local m = emitter:Add("particle/particle_smokegrenade", bp)
			if m then
				m:SetVelocity(VectorRand() * 15 + Vector(0, 0, 8))
				m:SetDieTime(0.6)
				m:SetStartAlpha(40)
				m:SetEndAlpha(0)
				m:SetStartSize(6)
				m:SetEndSize(16)
				m:SetColor(215, 235, 255)
				m:SetAirResistance(60)
			end
			if math.random() < 0.4 then
				local mat = (math.random() < 0.5) and "effects/fleck_glass1" or "effects/fleck_glass2"
				local p = emitter:Add(mat, randomBonePos(ent))
				if p then
					p:SetVelocity(VectorRand() * 25)
					p:SetDieTime(math.Rand(0.3, 0.6))
					p:SetStartAlpha(255)
					p:SetEndAlpha(0)
					p:SetStartSize(math.Rand(1, 3))
					p:SetEndSize(0)
					p:SetColor(200, 230, 255)
					p:SetGravity(Vector(0, 0, -80))
				end
			end
		end,
		earth = function(emitter, ent)
			local bp = randomBonePos(ent)
			local p = emitter:Add("particle/particle_smokegrenade", bp)
			if p then
				p:SetVelocity(VectorRand() * 12)
				p:SetDieTime(0.7)
				p:SetStartAlpha(60)
				p:SetEndAlpha(0)
				p:SetStartSize(7)
				p:SetEndSize(18)
				p:SetColor(120, 110, 100)
				p:SetAirResistance(60)
			end
			if math.random() < 0.35 then
				local mat = (math.random() < 0.5) and "effects/fleck_cement1" or "effects/fleck_cement2"
				local f = emitter:Add(mat, randomBonePos(ent))
				if f then
					f:SetVelocity(VectorRand() * 40)
					f:SetDieTime(math.Rand(0.4, 0.7))
					f:SetStartAlpha(255)
					f:SetEndAlpha(0)
					f:SetStartSize(math.Rand(1, 3))
					f:SetEndSize(0)
					f:SetColor(140, 130, 120)
					f:SetGravity(Vector(0, 0, -180))
				end
			end
		end,
		wind = function(emitter, ent)
			-- Tight streaks swirling around the torso.
			local center = ent:WorldSpaceCenter()
			local ang = math.Rand(0, 360)
			local dir = Angle(0, ang, 0):Forward()
			local tangent = Angle(0, ang + 90, 0):Forward()
			local p = emitter:Add("effects/splash2", center + dir * 24 + Vector(0, 0, math.Rand(-20, 24)))
			if p then
				p:SetVelocity(tangent * math.Rand(140, 220))
				p:SetDieTime(math.Rand(0.2, 0.35))
				p:SetStartAlpha(65)
				p:SetEndAlpha(0)
				p:SetStartSize(4)
				p:SetEndSize(12)
				p:SetRoll(math.Rand(0, 360))
				p:SetRollDelta(math.Rand(-4, 4))
				p:SetColor(220, 240, 245)
				p:SetAirResistance(30)
			end
		end,
		poison = function(emitter, ent)
			local bp = randomBonePos(ent)
			local colorVar = math.Rand(0.8, 1.1)
			local p = emitter:Add("particle/particle_smokegrenade", bp)
			if p then
				p:SetVelocity(VectorRand() * 18 + Vector(0, 0, 14))
				p:SetDieTime(0.8)
				p:SetStartAlpha(55)
				p:SetEndAlpha(0)
				p:SetStartSize(7)
				p:SetEndSize(20)
				p:SetColor(100 * colorVar, 180 * colorVar, 50 * colorVar)
				p:SetAirResistance(70)
			end
			if math.random() < 0.3 then
				local d = emitter:Add("effects/blueflare1", randomBonePos(ent))
				if d then
					d:SetVelocity(Vector(0, 0, -50))
					d:SetDieTime(0.35)
					d:SetStartAlpha(150)
					d:SetEndAlpha(0)
					d:SetStartSize(4)
					d:SetEndSize(0)
					d:SetColor(120, 220, 70)
				end
			end
		end,
		arcane = function(emitter, ent)
			local bp = randomBonePos(ent)
			local p = emitter:Add("effects/blueflare1", bp)
			if p then
				p:SetVelocity(VectorRand() * 35 + Vector(0, 0, 20))
				p:SetDieTime(math.Rand(0.3, 0.5))
				p:SetStartAlpha(190)
				p:SetEndAlpha(0)
				p:SetStartSize(math.Rand(4, 8))
				p:SetEndSize(0)
				p:SetColor(180, 120, 255)
				p:SetAirResistance(50)
			end
		end,
	}

	hook.Add("Think", "Arcana_Spellcraft_Auras", function()
		local now = CurTime()

		for ent, aura in pairs(activeAuras) do
			if not IsValid(ent) or now > aura.die then
				cleanupAuraProps(aura)
				activeAuras[ent] = nil
			elseif aura.rocks then
				-- Earth tornado: rock positions update every frame for smooth orbits.
				local base = ent:GetPos()
				for _, rec in ipairs(aura.rocks) do
					if IsValid(rec.ent) then
						local ang = rec.ang + now * rec.speed
						local dir = Angle(0, ang, 0):Forward()
						local z = rec.height + math.sin(now * 2 + rec.bob) * 9
						rec.ent:SetPos(base + dir * rec.orbitR + Vector(0, 0, z))
						local a = rec.ent:GetAngles()
						a:RotateAroundAxis(rec.spin, rec.spinSpeed * FrameTime())
						rec.ent:SetAngles(a)
					end
				end
			end

			if activeAuras[ent] and now >= (aura.next or 0) then
				aura.next = now + 0.05

				local base = ent:GetPos() + Vector(0, 0, 4)
				local emitter = ParticleEmitter(base)
				if emitter then
					local pulse = AURA_CL[aura.element] or AURA_CL.arcane
					pulse(emitter, base, aura.radius)

					-- Body layer on the model itself: always for other players,
					-- local player only when the model is drawn (third person).
					if ent ~= LocalPlayer() or ent:ShouldDrawLocalPlayer() then
						local bodyFx = AURA_BODY[aura.element] or AURA_BODY.arcane
						bodyFx(emitter, ent)
					end

					emitter:Finish()
				end

				-- Lightning: visible arcs lashing from the caster to the edge.
				if aura.element == "lightning" and math.random() < 0.55 then
					local dir = Angle(0, math.Rand(0, 360), 0):Forward()
					auraArcs[#auraArcs + 1] = {
						from = ent:WorldSpaceCenter(),
						to = base + dir * aura.radius + Vector(0, 0, math.Rand(0, 40)),
						die = now + 0.14,
						startTime = now,
					}
				end
			end
		end
	end)

	hook.Add("PostDrawTranslucentRenderables", "Arcana_Spellcraft_AuraArcs", function(depth, sky)
		if depth or sky then return end
		if #auraArcs == 0 then return end
		local now = CurTime()

		render.SetMaterial(matBeam)
		for i = #auraArcs, 1, -1 do
			local arc = auraArcs[i]
			if now > arc.die then
				table.remove(auraArcs, i)
			else
				local alpha = 255 * math.Clamp((arc.die - now) / 0.14, 0, 1)
				local width = arc.width or 7
				local segments = 6
				local path = {}
				for seg = 0, segments do
					local t = seg / segments
					local jag = math.sin(t * math.pi) * (width * 2)
					path[seg] = LerpVector(t, arc.from, arc.to) + VectorRand() * jag
				end

				render.StartBeam(segments + 1)
				for seg = 0, segments do
					render.AddBeam(path[seg], width, seg / segments, Color(255, 255, 255, alpha))
				end
				render.EndBeam()

				render.StartBeam(segments + 1)
				for seg = 0, segments do
					render.AddBeam(path[seg], width * 2, seg / segments, Color(150, 200, 255, alpha * 0.6))
				end
				render.EndBeam()
			end
		end
	end)

	----------------------------------------------------------------
	-- Zones: dense, continuous element volumes at a fixed spot (lingering
	-- patches). Modeled on poison_cloud's persistent emitter: fog uniformly
	-- distributed over the disc, layered with wisps and glints, ticking fast
	-- for the whole duration.
	----------------------------------------------------------------
	local activeZones = {}

	-- Uniformly distributed point on the zone disc.
	local function discPoint(pos, rad, zMin, zMax)
		local rr = rad * math.sqrt(math.Rand(0, 1))
		local a = math.Rand(0, math.pi * 2)
		return pos + Vector(math.cos(a) * rr, math.sin(a) * rr, math.Rand(zMin or 0, zMax or 8))
	end

	local ZONE_CL = {
		poison = function(em, pos, rad)
			-- Ground-level dense toxic fog (poison_cloud palette).
			for _ = 1, 4 do
				local p = em:Add("particle/particle_smokegrenade", discPoint(pos, rad))
				if p then
					p:SetDieTime(math.Rand(2.5, 3.5))
					p:SetStartAlpha(0)
					p:SetEndAlpha(math.Rand(140, 180))
					local sz = math.Rand(30, 45)
					p:SetStartSize(sz)
					p:SetEndSize(sz * math.Rand(1.4, 1.8))
					p:SetRoll(math.Rand(0, 360))
					p:SetRollDelta(math.Rand(-0.3, 0.3))
					local colorVar = math.Rand(0.8, 1.2)
					p:SetColor(100 * colorVar, 180 * colorVar, 50 * colorVar)
					p:SetAirResistance(120)
					p:SetGravity(Vector(0, 0, math.Rand(2, 6)))
					p:SetVelocity(Vector(math.Rand(-15, 15), math.Rand(-15, 15), 0))
					p:SetCollide(false)
				end
			end

			-- Rising vapor wisps
			if math.random() > 0.3 then
				for _ = 1, 2 do
					local p = em:Add("particle/particle_smokegrenade", discPoint(pos, rad * 0.8, 0, 0))
					if p then
						p:SetDieTime(math.Rand(1.5, 2.5))
						p:SetStartAlpha(0)
						p:SetEndAlpha(math.Rand(100, 140))
						local sz = math.Rand(15, 25)
						p:SetStartSize(sz)
						p:SetEndSize(sz * math.Rand(0.6, 1.0))
						p:SetColor(120, 220, 70)
						p:SetAirResistance(50)
						p:SetGravity(Vector(0, 0, math.Rand(35, 50)))
						p:SetVelocity(Vector(math.Rand(-8, 8), math.Rand(-8, 8), math.Rand(20, 40)))
						p:SetCollide(false)
					end
				end
			end

			-- Bubbling glints
			if math.random() > 0.5 then
				local p = em:Add("effects/blueflare1", discPoint(pos, rad * 0.9, 0, 0))
				if p then
					p:SetDieTime(math.Rand(0.8, 1.5))
					p:SetStartAlpha(math.Rand(200, 255))
					p:SetEndAlpha(0)
					p:SetStartSize(math.Rand(8, 14))
					p:SetEndSize(0)
					p:SetColor(140, 220, 80)
					p:SetAirResistance(30)
					p:SetGravity(Vector(0, 0, math.Rand(25, 40)))
					p:SetVelocity(Vector(math.Rand(-10, 10), math.Rand(-10, 10), math.Rand(15, 30)))
					p:SetCollide(false)
				end
			end
		end,

		fire = function(em, pos, rad, goldTint)
			local cloudCol = goldTint and Color(255, 200, 80) or nil
			local emberCol = goldTint and Color(255, 220, 110) or Color(255, 180, 80)

			-- Burning ground: a carpet of flames licking up across the patch.
			for _ = 1, 5 do
				fireClouds(em, discPoint(pos, rad, 0, 6), Vector(0, 0, 1), 1, 0.85, cloudCol)
			end
			for _ = 1, 4 do
				embers(em, discPoint(pos, rad, 0, 10), 1, emberCol)
			end

			-- Tall flame licks shooting up from the blaze.
			for _ = 1, 2 do
				local p = em:Add("effects/yellowflare", discPoint(pos, rad * 0.85, 0, 6))
				if p then
					p:SetVelocity(Vector(math.Rand(-15, 15), math.Rand(-15, 15), math.Rand(90, 160)))
					p:SetDieTime(math.Rand(0.4, 0.7))
					p:SetStartAlpha(230)
					p:SetEndAlpha(0)
					p:SetStartSize(math.Rand(6, 10))
					p:SetEndSize(0)
					p:SetColor(emberCol.r, emberCol.g, emberCol.b)
					p:SetLighting(false)
					p:SetAirResistance(40)
				end
			end

			if math.random() > 0.3 then
				heatShimmer(em, discPoint(pos, rad * 0.7, 10, 30))
			end
			if goldTint and math.random() > 0.6 then
				local p = em:Add("sprites/light_glow02_add", discPoint(pos, rad * 0.8, 4, 20))
				if p then
					p:SetVelocity(Vector(0, 0, math.Rand(50, 90)))
					p:SetDieTime(math.Rand(0.5, 0.9))
					p:SetStartAlpha(220)
					p:SetEndAlpha(0)
					p:SetStartSize(math.Rand(3, 6))
					p:SetEndSize(0)
					p:SetColor(255, 230, 140)
				end
			end
		end,

		frost = function(em, pos, rad)
			for _ = 1, 3 do
				local p = em:Add("particle/particle_smokegrenade", discPoint(pos, rad))
				if p then
					p:SetDieTime(math.Rand(1.8, 2.8))
					p:SetStartAlpha(0)
					p:SetEndAlpha(math.Rand(70, 100))
					local sz = math.Rand(24, 38)
					p:SetStartSize(sz)
					p:SetEndSize(sz * 1.5)
					p:SetColor(215, 235, 255)
					p:SetAirResistance(120)
					p:SetGravity(Vector(0, 0, 3))
					p:SetVelocity(Vector(math.Rand(-12, 12), math.Rand(-12, 12), 0))
				end
			end
			if math.random() > 0.5 then
				local mat = (math.random() < 0.5) and "effects/fleck_glass1" or "effects/fleck_glass2"
				local p = em:Add(mat, discPoint(pos, rad * 0.8, 4, 40))
				if p then
					p:SetVelocity(VectorRand() * 25)
					p:SetDieTime(math.Rand(0.5, 0.9))
					p:SetStartAlpha(255)
					p:SetEndAlpha(0)
					p:SetStartSize(math.Rand(2, 3))
					p:SetEndSize(0)
					p:SetColor(200, 230, 255)
					p:SetGravity(Vector(0, 0, -60))
				end
			end
		end,

		lightning = function(em, pos, rad)
			for _ = 1, 2 do
				local p = em:Add("effects/blueflare1", discPoint(pos, rad, 0, 20))
				if p then
					p:SetDieTime(math.Rand(0.2, 0.4))
					p:SetStartAlpha(220)
					p:SetEndAlpha(0)
					p:SetStartSize(math.Rand(7, 13))
					p:SetEndSize(0)
					p:SetColor(150, 200, 255)
					p:SetVelocity(VectorRand() * 50)
				end
			end
			if math.random() > 0.55 then
				local p = em:Add("effects/spark", discPoint(pos, rad * 0.9, 2, 8))
				if p then
					p:SetDieTime(math.Rand(0.3, 0.5))
					p:SetStartAlpha(255)
					p:SetEndAlpha(0)
					p:SetStartSize(math.Rand(2, 4))
					p:SetEndSize(0)
					p:SetColor(255, 255, 255)
					p:SetVelocity(VectorRand() * 120 + Vector(0, 0, 60))
					p:SetGravity(Vector(0, 0, -400))
					p:SetCollide(true)
				end
			end
			-- Ground current arcing across the patch.
			if math.random() > 0.7 then
				auraArcs[#auraArcs + 1] = {
					from = discPoint(pos, rad * 0.9, 4, 10),
					to = discPoint(pos, rad * 0.9, 4, 10),
					die = CurTime() + 0.1,
					startTime = CurTime(),
					width = 4,
				}
			end
		end,

		earth = function(em, pos, rad)
			for _ = 1, 3 do
				local p = em:Add("particle/particle_smokegrenade", discPoint(pos, rad))
				if p then
					p:SetDieTime(math.Rand(1.5, 2.5))
					p:SetStartAlpha(0)
					p:SetEndAlpha(math.Rand(70, 110))
					local sz = math.Rand(20, 34)
					p:SetStartSize(sz)
					p:SetEndSize(sz * 1.6)
					p:SetColor(120, 110, 100)
					p:SetAirResistance(110)
					p:SetGravity(Vector(0, 0, 2))
					p:SetVelocity(Vector(math.Rand(-10, 10), math.Rand(-10, 10), 0))
				end
			end
			if math.random() > 0.6 then
				local mat = (math.random() < 0.5) and "effects/fleck_cement1" or "effects/fleck_cement2"
				local p = em:Add(mat, discPoint(pos, rad * 0.8, 2, 10))
				if p then
					p:SetVelocity(VectorRand() * 60 + Vector(0, 0, math.Rand(40, 120)))
					p:SetDieTime(math.Rand(0.5, 0.9))
					p:SetStartAlpha(255)
					p:SetEndAlpha(0)
					p:SetStartSize(math.Rand(2, 4))
					p:SetEndSize(0)
					p:SetColor(140, 130, 120)
					p:SetGravity(Vector(0, 0, -400))
					p:SetCollide(true)
				end
			end
		end,

		wind = function(em, pos, rad)
			-- A churning vortex: streaks spiraling up a funnel that widens with
			-- height, a hazy body, and dust dragged around the base.
			local height = rad * 1.2

			for _ = 1, 8 do
				local h = math.Rand(0, height)
				local frac = h / height
				local r = Lerp(frac, rad * 0.25, rad * 0.85)
				local ang = math.Rand(0, 360)
				local dir = Angle(0, ang, 0):Forward()
				local tangent = Angle(0, ang + 90, 0):Forward()
				local p = em:Add("effects/splash2", pos + dir * r + Vector(0, 0, h))
				if p then
					p:SetVelocity(tangent * math.Rand(240, 380) - dir * math.Rand(20, 60) + Vector(0, 0, math.Rand(40, 90)))
					p:SetDieTime(math.Rand(0.35, 0.6))
					p:SetStartAlpha(90)
					p:SetEndAlpha(0)
					p:SetStartSize(math.Rand(5, 10))
					p:SetEndSize(math.Rand(18, 28))
					p:SetRoll(math.Rand(0, 360))
					p:SetRollDelta(math.Rand(-6, 6))
					p:SetColor(220, 240, 245)
					p:SetAirResistance(30)
				end
			end

			-- Hazy funnel body
			for _ = 1, 3 do
				local h = math.Rand(0, height * 0.9)
				local frac = h / height
				local r = Lerp(frac, rad * 0.2, rad * 0.7)
				local ang = math.Rand(0, 360)
				local dir = Angle(0, ang, 0):Forward()
				local tangent = Angle(0, ang + 90, 0):Forward()
				local m = em:Add("particle/particle_smokegrenade", pos + dir * r + Vector(0, 0, h))
				if m then
					m:SetVelocity(tangent * math.Rand(150, 240) + Vector(0, 0, math.Rand(30, 60)))
					m:SetDieTime(math.Rand(0.5, 0.9))
					m:SetStartAlpha(0)
					m:SetEndAlpha(45)
					m:SetStartSize(math.Rand(14, 22))
					m:SetEndSize(math.Rand(30, 44))
					m:SetColor(225, 240, 240)
					m:SetAirResistance(40)
				end
			end

			-- Dust dragged around the base
			for _ = 1, 2 do
				local ang = math.Rand(0, 360)
				local dir = Angle(0, ang, 0):Forward()
				local tangent = Angle(0, ang + 90, 0):Forward()
				local d = em:Add("particle/particle_smokegrenade", pos + dir * math.Rand(rad * 0.6, rad) + Vector(0, 0, math.Rand(0, 10)))
				if d then
					d:SetVelocity(tangent * math.Rand(120, 200) + dir * 30)
					d:SetDieTime(math.Rand(0.8, 1.3))
					d:SetStartAlpha(0)
					d:SetEndAlpha(60)
					d:SetStartSize(16)
					d:SetEndSize(36)
					d:SetColor(200, 205, 200)
					d:SetAirResistance(70)
				end
			end
		end,

		arcane = function(em, pos, rad)
			for _ = 1, 2 do
				local p = em:Add("effects/blueflare1", discPoint(pos, rad, 2, 26))
				if p then
					p:SetDieTime(math.Rand(0.4, 0.7))
					p:SetStartAlpha(200)
					p:SetEndAlpha(0)
					p:SetStartSize(math.Rand(6, 11))
					p:SetEndSize(0)
					p:SetColor(180, 120, 255)
					p:SetVelocity(VectorRand() * 40 + Vector(0, 0, 30))
					p:SetAirResistance(50)
				end
			end
		end,
	}
	ZONE_CL.aurum = function(em, pos, rad)
		ZONE_CL.fire(em, pos, rad, true)
	end

	net.Receive("Arcana_Spellcraft_ZoneFX", function()
		local element = net.ReadString()
		local pos = net.ReadVector()
		local radius = net.ReadFloat()
		local duration = net.ReadFloat()

		activeZones[#activeZones + 1] = {
			element = element,
			pos = pos,
			radius = radius,
			die = CurTime() + duration,
			next = 0,
		}

		-- Lingering earth: jagged rocks stand out of the ground for the whole
		-- patch lifetime, then sink away with it.
		if element == "earth" then
			spawnGroundRocks(pos, radius * 0.85, math.Clamp(math.floor(radius / 30), 6, 12), duration, { stagger = 0.6 })
		end
	end)

	hook.Add("Think", "Arcana_Spellcraft_Zones", function()
		if #activeZones == 0 then return end
		local now = CurTime()

		for i = #activeZones, 1, -1 do
			local zone = activeZones[i]
			if now > zone.die then
				if zone.emitter then zone.emitter:Finish() end
				table.remove(activeZones, i)
			elseif now >= zone.next then
				zone.next = now + 0.06
				zone.emitter = zone.emitter or ParticleEmitter(zone.pos, false)
				if zone.emitter then
					local tick = ZONE_CL[zone.element] or ZONE_CL.arcane
					tick(zone.emitter, zone.pos, zone.radius)
				end
			end
		end
	end)
end
