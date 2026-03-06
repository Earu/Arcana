local LIGHTNING_COLOR = Color(170, 200, 255)

if SERVER then
	util.AddNetworkString("Arcana_LightningStrike")
	util.AddNetworkString("Arcana_LightningChain")
end

local function spawnTeslaBurst(pos)
	return Arcana.Common.SpawnTeslaBurst(pos, {
		targetname = "arcana_lightning",
		radius = 280, beamcount_min = 10, beamcount_max = 16,
		thick_min = 8, thick_max = 14,
		lifetime_min = 0.15, lifetime_max = 0.25,
		interval_min = 0.03, interval_max = 0.08,
		kill_delay = 0.8,
	})
end

-- Draw a few quick effects at the impact point
local function impactVFX(pos, normal, power)
	Arcana.Common.LightningImpactVFX(pos, normal, {
		power = power,
		shakePower = 8, shakeHz = 120, shakeDur = 0.4, shakeRadius = 800,
		soundLvl = 95,
	})
	-- Additional spell-specific effects beyond the shared base
	local ed = EffectData()
	ed:SetOrigin(pos)
	ed:SetNormal(normal or Vector(0, 0, 1))
	util.Effect("ElectricSpark", ed, true, true)
	sound.Play("ambient/levels/labs/electric_explosion" .. math.random(1, 5) .. ".wav", pos, 100, 100)
	timer.Simple(0.1, function()
		sound.Play("ambient/atmosphere/thunder" .. math.random(1, 4) .. ".wav", pos, 95, 120)
	end)
	if SERVER then
		net.Start("Arcana_LightningStrike", true)
		net.WriteVector(pos)
		net.WriteFloat(power or 1.0)
		net.Broadcast()
	end
end

-- Apply shock damage in a radius and optionally chain to a few nearby targets
local function applyLightningDamage(attacker, hitPos)
	local lastPos = hitPos
	Arcana.Common.ApplyLightningChain(attacker, hitPos, {
		baseDamage = 75, chainDamage = 28, chainDelay = 0.05,
		spawnTesla = spawnTeslaBurst,
		onChain = function(tgt, tpos, i)
			sound.Play("ambient/levels/labs/electric_explosion" .. math.random(1, 5) .. ".wav", tpos, 85, 110)
			sound.Play("weapons/physcannon/superphys_small_zap" .. math.random(1, 4) .. ".wav", tpos, 80, 100)
			if SERVER then
				net.Start("Arcana_LightningChain", true)
				net.WriteVector(lastPos)
				net.WriteVector(tpos)
				net.Broadcast()
			end
			lastPos = tpos
		end,
	})
end

Arcana:RegisterSpell({
	id = "lightning_strike",
	name = "Lightning Strike",
	description = "Call a focused lightning bolt at your aim point, chaining to nearby foes.",
	category = Arcana.CATEGORIES.COMBAT,
	level_required = 2,
	knowledge_cost = 2,
	cooldown = 5.5,
	cost_type = Arcana.COST_TYPES.COINS,
	cost_amount = 30,
	cast_time = 1.0,
	range = 1500,
	icon = "icon16/weather_lightning.png",
	has_target = true,
	cast = function(caster, _, _, ctx)
		if not SERVER then return true end

		local srcEnt = IsValid(ctx.casterEntity) and ctx.casterEntity or caster
		local targetPos = Arcana:ResolveGroundTarget(srcEnt, 1500)

		-- Perform 1 strong strike and 2 lighter offset strikes for style
		local strikes = {
			{
				delay = 0.00,
				offset = Vector(0, 0, 0),
				power = 1.0
			},
			{
				delay = 0.10,
				offset = Vector(math.Rand(-60, 60), math.Rand(-60, 60), 0),
				power = 0.5
			},
			{
				delay = 0.18,
				offset = Vector(math.Rand(-60, 60), math.Rand(-60, 60), 0),
				power = 0.5
			},
		}

		for _, s in ipairs(strikes) do
			timer.Simple(s.delay, function()
				if not IsValid(caster) then return end
				-- Tesla burst at impact, plus supporting effects
				local normal = Vector(0, 0, 1)
				local tesla = spawnTeslaBurst(targetPos + s.offset)

				if IsValid(tesla) and tesla.CPPISetOwner then
					tesla:CPPISetOwner(caster)
				end

				impactVFX(targetPos + s.offset, normal, s.power)

				-- Damage and short chains for the main strike only
				if s.power >= 1.0 then
					applyLightningDamage(caster, targetPos + s.offset, normal)
				else
					Arcana:BlastDamage(caster, targetPos + s.offset, 120, 30, { damageType = DMG_SHOCK, ignoreAttacker = true })
				end
			end)
		end

		return true
	end,
	trigger_phrase_aliases = {
		"lightning",
	}
})

if CLIENT then
	local matBeam = Material("effects/laser1")
	local matFlare = Material("effects/blueflare1")
	local matGlow = Material("sprites/light_glow02_add")

	Arcana.LightningBolts  = {}
	Arcana.LightningFlashes = {}
	Arcana.LightningChains  = {}

	-- Main lightning bolt from sky
	net.Receive("Arcana_LightningStrike", function()
		local pos = net.ReadVector()
		local power = net.ReadFloat()

		-- Sky position (high above impact point)
		local skyPos = pos + Vector(0, 0, 2000)

		-- Particle explosion at impact
		local emitter = ParticleEmitter(pos)
		if emitter then
			-- Electric burst
			for i = 1, 40 * power do
				local p = emitter:Add("effects/blueflare1", pos)
				if p then
					p:SetDieTime(math.Rand(0.3, 0.6))
					p:SetStartAlpha(255)
					p:SetEndAlpha(0)
					p:SetStartSize(math.Rand(10, 20) * power)
					p:SetEndSize(0)
					p:SetColor(LIGHTNING_COLOR.r, LIGHTNING_COLOR.g, LIGHTNING_COLOR.b)
					p:SetVelocity(VectorRand() * 300 * power)
					p:SetAirResistance(100)
					p:SetGravity(Vector(0, 0, -100))
				end
			end

			-- Ground sparks
			for i = 1, 20 * power do
				local p = emitter:Add("effects/spark", pos + Vector(0, 0, 5))
				if p then
					p:SetDieTime(math.Rand(0.4, 0.8))
					p:SetStartAlpha(255)
					p:SetEndAlpha(0)
					p:SetStartSize(math.Rand(2, 4))
					p:SetEndSize(0)
					p:SetColor(255, 255, 255)
					local vel = VectorRand()
					vel.z = math.abs(vel.z) * 0.5
					p:SetVelocity(vel * 250)
					p:SetGravity(Vector(0, 0, -600))
					p:SetCollide(true)
					p:SetBounce(0.3)
				end
			end

			emitter:Finish()
		end

		-- Store lightning bolt for rendering
		table.insert(Arcana.LightningBolts, {
			startPos = skyPos,
			endPos = pos,
			dieTime = CurTime() + 0.4,
			startTime = CurTime(),
			power = power
		})

		-- Store bright flash sprite
		table.insert(Arcana.LightningFlashes, {
			pos = pos,
			dieTime = CurTime() + 0.15,
			startTime = CurTime(),
			power = power
		})

		-- Dynamic light with initial bright flash
		local dlight = DynamicLight(math.random(10000, 99999))
		if dlight then
			dlight.pos = pos
			dlight.r = 255
			dlight.g = 255
			dlight.b = 255
			dlight.brightness = 8 * power
			dlight.Decay = 4000
			dlight.Size = 600 * power
			dlight.DieTime = CurTime() + 0.25
		end
	end)

	-- Chain lightning between targets
	net.Receive("Arcana_LightningChain", function()
		local startPos = net.ReadVector()
		local endPos = net.ReadVector()

		-- Store chain for rendering
		table.insert(Arcana.LightningChains, {
			startPos = startPos,
			endPos = endPos,
			dieTime = CurTime() + 0.3,
			startTime = CurTime()
		})

		-- Particles along chain
		local emitter = ParticleEmitter((startPos + endPos) * 0.5)
		if emitter then
			for i = 1, 10 do
				local frac = i / 10
				local p = emitter:Add("effects/blueflare1", LerpVector(frac, startPos, endPos))
				if p then
					p:SetDieTime(math.Rand(0.2, 0.4))
					p:SetStartAlpha(200)
					p:SetEndAlpha(0)
					p:SetStartSize(math.Rand(6, 12))
					p:SetEndSize(0)
					p:SetColor(LIGHTNING_COLOR.r, LIGHTNING_COLOR.g, LIGHTNING_COLOR.b)
					p:SetVelocity(VectorRand() * 50)
				end
			end
			emitter:Finish()
		end
	end)

	-- Render lightning bolts
	hook.Add("PostDrawTranslucentRenderables", "Arcana_RenderLightning", function()
		local curTime = CurTime()

		-- Render bright flash sprites
		for i = #Arcana.LightningFlashes, 1, -1 do
			local flash = Arcana.LightningFlashes[i]

			if curTime > flash.dieTime then
				table.remove(Arcana.LightningFlashes, i)
			else
				local age = curTime - flash.startTime
				local frac = math.Clamp(age / 0.15, 0, 1)
				local alpha = (1 - frac) * 255
				local size = Lerp(frac, 800, 1200) * flash.power

				-- Ultra bright white flash
				render.SetMaterial(matGlow)
				render.DrawSprite(flash.pos, size, size, Color(255, 255, 255, alpha * 0.9))

				render.SetMaterial(matFlare)
				render.DrawSprite(flash.pos, size * 0.7, size * 0.7, Color(255, 255, 255, alpha))

				-- Blue tint outer flash
				render.SetMaterial(matGlow)
				render.DrawSprite(flash.pos, size * 1.5, size * 1.5, Color(LIGHTNING_COLOR.r, LIGHTNING_COLOR.g, LIGHTNING_COLOR.b, alpha * 0.4))
			end
		end

		-- Main lightning bolts
		for i = #Arcana.LightningBolts, 1, -1 do
			local bolt = Arcana.LightningBolts[i]

			if curTime > bolt.dieTime then
				table.remove(Arcana.LightningBolts, i)
			else
				local age = curTime - bolt.startTime
				local frac = 1 - math.Clamp((bolt.dieTime - curTime) / 0.4, 0, 1)

				-- Flickering effect
				local flicker = math.sin(curTime * 80 + bolt.startTime * 100) * 0.3 + 0.7
				local alpha = (1 - frac) * 255 * flicker

				-- Generate main bolt path once and store positions
				local segments = 20
				local mainPath = {}
				for seg = 0, segments do
					local t = seg / segments
					local pos = LerpVector(t, bolt.startPos, bolt.endPos)

					-- Add jagged offset (more offset in middle)
					local jaggedAmount = math.sin(t * math.pi) * 60 * bolt.power
					pos = pos + VectorRand() * jaggedAmount
					mainPath[seg] = pos
				end

				render.SetMaterial(matBeam)

				-- Draw THICK main bolt with multiple layers
				-- Layer 1: Ultra bright white core
				render.StartBeam(segments + 1)
				for seg = 0, segments do
					local t = seg / segments
					local width = Lerp(t, 20, 30) * bolt.power * flicker
					render.AddBeam(mainPath[seg], width, t, Color(255, 255, 255, alpha))
				end
				render.EndBeam()

				-- Layer 2: Bright blue-white inner
				render.StartBeam(segments + 1)
				for seg = 0, segments do
					local t = seg / segments
					local width = Lerp(t, 35, 50) * bolt.power * flicker
					render.AddBeam(mainPath[seg], width, t, Color(220, 230, 255, alpha * 0.8))
				end
				render.EndBeam()

				-- Layer 3: Purple-blue outer glow
				render.StartBeam(segments + 1)
				for seg = 0, segments do
					local t = seg / segments
					local width = Lerp(t, 55, 80) * bolt.power * flicker
					render.AddBeam(mainPath[seg], width, t, Color(LIGHTNING_COLOR.r, LIGHTNING_COLOR.g, LIGHTNING_COLOR.b, alpha * 0.5))
				end
				render.EndBeam()

				-- Draw arcing side branches
				for branch = 1, 6 do
					local branchStart = math.random(3, segments - 3)
					local branchStartPos = mainPath[branchStart]

					-- Random arc direction perpendicular to main bolt
					local boltDir = (bolt.endPos - bolt.startPos):GetNormalized()
					local perpDir = Vector(-boltDir.y, boltDir.x, 0):GetNormalized()
					if math.random() > 0.5 then perpDir = -perpDir end

					local arcLength = math.Rand(150, 400) * bolt.power
					local arcEnd = branchStartPos + perpDir * arcLength + Vector(0, 0, math.Rand(-100, 100))

					-- Draw the arc with fewer segments
					local arcSegs = 6
					render.StartBeam(arcSegs + 1)
					for seg = 0, arcSegs do
						local t = seg / arcSegs
						local pos = LerpVector(t, branchStartPos, arcEnd)

						-- Add jaggedness to arc
						pos = pos + VectorRand() * 30 * (1 - t)

						local width = Lerp(t, 15, 3) * bolt.power * flicker
						render.AddBeam(pos, width, t, Color(LIGHTNING_COLOR.r, LIGHTNING_COLOR.g, LIGHTNING_COLOR.b, alpha * 0.7 * (1 - t * 0.5)))
					end
					render.EndBeam()
				end

				-- Extra flickering branches shooting off
				if flicker > 0.8 then
					for extraBranch = 1, 4 do
						local branchStart = math.random(2, segments - 2)
						local branchStartPos = mainPath[branchStart]
						local branchEnd = branchStartPos + VectorRand() * 250 * bolt.power

						render.StartBeam(4)
						for seg = 0, 3 do
							local t = seg / 3
							local pos = LerpVector(t, branchStartPos, branchEnd)
							pos = pos + VectorRand() * 20
							local width = Lerp(t, 12, 2) * bolt.power
							render.AddBeam(pos, width, t, Color(255, 255, 255, alpha * 0.6 * (1 - t)))
						end
						render.EndBeam()
					end
				end
			end
		end

		-- Chain lightning with thicker beams
		for i = #Arcana.LightningChains, 1, -1 do
			local chain = Arcana.LightningChains[i]

			if curTime > chain.dieTime then
				table.remove(Arcana.LightningChains, i)
			else
				local frac = 1 - math.Clamp((chain.dieTime - curTime) / 0.3, 0, 1)
				local flicker = math.sin(curTime * 60 + chain.startTime * 80) * 0.3 + 0.7
				local alpha = (1 - frac) * 255 * flicker

				render.SetMaterial(matBeam)

				-- Main chain bolt
				local segments = 10
				local chainPath = {}
				for seg = 0, segments do
					local t = seg / segments
					local pos = LerpVector(t, chain.startPos, chain.endPos)
					local jaggedAmount = math.sin(t * math.pi) * 30
					pos = pos + VectorRand() * jaggedAmount
					chainPath[seg] = pos
				end

				-- White core
				render.StartBeam(segments + 1)
				for seg = 0, segments do
					local t = seg / segments
					local width = 12 * flicker
					render.AddBeam(chainPath[seg], width, t, Color(255, 255, 255, alpha))
				end
				render.EndBeam()

				-- Blue outer
				render.StartBeam(segments + 1)
				for seg = 0, segments do
					local t = seg / segments
					local width = 20 * flicker
					render.AddBeam(chainPath[seg], width, t, Color(LIGHTNING_COLOR.r, LIGHTNING_COLOR.g, LIGHTNING_COLOR.b, alpha * 0.7))
				end
				render.EndBeam()
			end
		end
	end)

	-- Custom moving magic circle for lightning_strike that follows the player's aim on the ground
	hook.Add("Arcana_BeginCastingVisuals", "Arcana_LightningStrike_Circle", function(caster, spellId, castTime, _forwardLike)
		if spellId ~= "lightning_strike" then return end

		Arcana:CreateFollowingCastCircle(caster, spellId, castTime, {
			color = Color(170, 200, 255, 255),
			size = 26,
			intensity = 4,
			positionResolver = function(c)
				return Arcana:ResolveGroundTarget(c, 1500)
			end
		})
	end)
end