-- Glacial Wake: the projectile records its entire flight path; on detonation frost
-- energy surges backward through every point traveled, slowing all entities within
-- reach. The frozen scar in the air dissolves from origin to impact over ~1.8 seconds.

if SERVER then
	util.AddNetworkString("Arcana_GlacialWake")
end

local PATH_INTERVAL   = 0.08   -- sample every 80ms for a dense trail
local MAX_PATH_POINTS = 35
local WAKE_RADIUS     = 120
local WAKE_DAMAGE     = 18

local function fireWake(owner, impactPos, path)
	table.insert(path, impactPos)

	local seenEnts = {}
	for _, pathPos in ipairs(path) do
		for _, ent in ipairs(ents.FindInSphere(pathPos, WAKE_RADIUS)) do
			if not IsValid(ent) then continue end
			if seenEnts[ent] then continue end
			if ent == owner then continue end
			seenEnts[ent] = true

			local isActor = ent:IsPlayer() or ent:IsNPC() or (ent.IsNextBot and ent:IsNextBot())
			if not isActor then continue end

			local dmg = DamageInfo()
			dmg:SetDamage(WAKE_DAMAGE)
			dmg:SetDamageType(bit.bor(DMG_GENERIC, DMG_SONIC))
			dmg:SetAttacker(IsValid(owner) and owner or game.GetWorld())
			dmg:SetInflictor(IsValid(owner) and owner or game.GetWorld())
			dmg:SetDamagePosition(ent:WorldSpaceCenter())
			ent:TakeDamageInfo(dmg)

			Arcana.Status.Frost.Apply(ent, {
				slowMult     = 0.45,
				duration     = 3,
				vfxTag       = "glacial_wake",
				sendClientFX = ent:IsPlayer(),
			})
		end
	end

	local ed = EffectData()
	ed:SetOrigin(impactPos)
	util.Effect("GlassImpact", ed, true, true)
	sound.Play("physics/glass/glass_impact_bullet1.wav", impactPos, 75, 80)
	sound.Play("physics/glass/glass_impact_bullet3.wav", impactPos, 70, 70)

	net.Start("Arcana_GlacialWake", true)
	net.WriteUInt(#path, 8)
	for _, pos in ipairs(path) do
		net.WriteVector(pos)
	end
	net.Broadcast()
end

Arcana:RegisterEnchantment({
	id = "glacial_wake",
	name = "Glacial Wake",
	description = "Your projectile leaves a frost scar through the air. On impact the entire flight path erupts with ice, chilling and slowing every entity it passed near.",
	cost_coins = 1800,
	cost_items = {
		{ name = "mana_crystal_shard", amount = 75 },
	},
	can_apply = function(ply, wep)
		return Arcana.Common.GetWeaponClassification(wep) == "PROJECTILE"
	end,
	on_projectile_fired = function(ply, wep, proj, state)
		local path      = {}
		local timerName = string.format("Arcana_GlacialWake_%d", proj:EntIndex())

		timer.Create(timerName, PATH_INTERVAL, MAX_PATH_POINTS, function()
			if not IsValid(proj) then timer.Remove(timerName); return end
			path[#path + 1] = proj:GetPos()
		end)

		proj:CallOnRemove("Arcana_GlacialWake_Stop", function()
			timer.Remove(timerName)
		end)

		proj:CallOnRemove("Arcana_GlacialWake_Fire", function(e)
			if not IsValid(ply) then return end
			fireWake(ply, e:GetPos(), path)
		end)
	end,
})

if CLIENT then
	local WAKE_DURATION = 1.8

	-- Soft physbeam for the frosted crack line; glow for nodes and atmospheric haze.
	-- physbeam is hazy/solid rather than the sharp energy glow of laser1.
	local crackMat = Material("sprites/physbeam")
	local glowMat  = Material("sprites/light_glow02_add")

	local activeWakes = {}

	-- Build a single-kink angular fracture path between two world positions.
	-- Called ONCE per segment and stored — ice is frozen, the geometry never shifts.
	local function buildCrackSegment(a, b)
		local dir = b - a
		local len = dir:Length()
		if len < 1 then return {a, b} end
		local norm  = dir / len
		local right = norm:Cross(Vector(0, 0, 1)):GetNormalized()
		if right:LengthSqr() < 0.01 then
			right = norm:Cross(Vector(1, 0, 0)):GetNormalized()
		end
		local up = right:Cross(norm)

		-- One angular kink: position along the segment varies slightly so
		-- consecutive segments don't all kink at the same fractional point.
		local kinkT = 0.35 + math.random() * 0.3
		local amt   = math.Clamp(len * 0.20, 3, 22)
		local r     = (math.random() * 2 - 1) * amt
		local u     = (math.random() * 2 - 1) * amt * 0.5  -- flatter vertically = more natural ice crack
		local kink  = a + norm * (len * kinkT) + right * r + up * u

		return {a, kink, b}
	end

	-- Burst particles fired once when the net message arrives.
	-- Two distance throttles: burst effects at 40u, snowflakes at 20u for denser coverage.
	local function spawnWakeParticles(points)
		local n = #points
		if n == 0 then return end

		local emitter = ParticleEmitter(points[n])
		if not emitter then return end

		local lastBurst    = nil  -- throttle for shards + mist
		local lastSnowflake = nil  -- tighter throttle for the floating snowflakes

		for i, pos in ipairs(points) do
			local tNorm = (i - 1) / math.max(n - 1, 1)  -- 0=origin, 1=impact

			-- Snowflakes: tiny floating ice sparkles that linger for the full wake duration.
			-- Spawned at every ~20u along the path for continuous trail coverage.
			if not lastSnowflake or pos:DistToSqr(lastSnowflake) >= 20 * 20 then
				lastSnowflake = pos
				for _ = 1, 4 do
					local sp = emitter:Add("effects/blueflare1", pos + VectorRand() * 10)
					if sp then
						-- Almost no velocity — they drift rather than fly
						sp:SetVelocity(VectorRand() * 8 + Vector(0, 0, 3 + math.random(0, 5)))
						sp:SetDieTime(2.0 + math.Rand(0, 1.5))
						sp:SetStartAlpha(140 + math.floor(tNorm * 40))
						sp:SetEndAlpha(0)
						sp:SetStartSize(3 + math.random(0, 2))
						sp:SetEndSize(1)
						sp:SetColor(215, 238, 255)
						sp:SetGravity(Vector(0, 0, -6))  -- barely any — they float
						sp:SetAirResistance(25)
						sp:SetRoll(math.Rand(0, 360))
						sp:SetRollDelta(math.Rand(-1.5, 1.5))
					end
				end
			end

			-- Burst effects (shards, mist): throttled at 40u to avoid over-spawning
			if lastBurst and pos:DistToSqr(lastBurst) < 40 * 40 then continue end
			lastBurst = pos

			-- Glass / ice shards tumbling outward with gravity
			local shardCount = math.max(1, math.floor(2 + tNorm * 5))
			for _ = 1, shardCount do
				local mat = math.random() > 0.5 and "effects/fleck_glass1" or "effects/fleck_glass2"
				local p   = emitter:Add(mat, pos + VectorRand() * 5)
				if p then
					local speed = 50 + math.random(0, math.floor(80 * tNorm + 10))
					p:SetVelocity(VectorRand() * speed + Vector(0, 0, 20 + tNorm * 40))
					p:SetDieTime(0.5 + math.Rand(0, 0.8))
					p:SetStartAlpha(210)
					p:SetEndAlpha(0)
					p:SetStartSize(2 + tNorm * 3)
					p:SetEndSize(0)
					p:SetColor(200, 230, 255)
					p:SetGravity(Vector(0, 0, -280))
					p:SetRoll(math.Rand(0, 360))
					p:SetRollDelta(math.Rand(-8, 8))
				end
			end

			-- Cold mist billowing upward along the trail
			local mp = emitter:Add("particle/particle_smokegrenade", pos + VectorRand() * 6)
			if mp then
				mp:SetVelocity(VectorRand() * 14 + Vector(0, 0, 10 + math.random(0, 16)))
				mp:SetDieTime(0.7 + math.Rand(0, 0.6) + tNorm * 0.4)
				mp:SetStartAlpha(40 + math.floor(tNorm * 40))
				mp:SetEndAlpha(0)
				mp:SetStartSize(14 + math.random(0, 10))
				mp:SetEndSize(38 + math.random(0, 16))
				mp:SetColor(195, 220, 255)
				mp:SetAirResistance(20)
			end
		end

		emitter:Finish()
	end

	net.Receive("Arcana_GlacialWake", function()
		local count = net.ReadUInt(8)
		if count == 0 then return end
		local points = {}
		for i = 1, count do
			points[i] = net.ReadVector()
		end

		-- Pre-build all crack geometry (locked in place — ice fractures don't animate)
		local arcs = {}
		for i = 1, #points - 1 do
			arcs[i] = buildCrackSegment(points[i], points[i + 1])
		end

		spawnWakeParticles(points)

		table.insert(activeWakes, {
			points  = points,
			arcs    = arcs,
			birth   = CurTime(),
			dieTime = CurTime() + WAKE_DURATION,
		})
	end)

	-- Render one pre-built crack segment using two passes:
	--   1. Wide, very soft atmospheric haze (frosted air)
	--   2. Narrow bright-white crack line
	local function drawCrackSegment(segPts, alphaFrac, tNorm)
		local hazeA  = math.floor(alphaFrac * 55)
		local crackA = math.floor(alphaFrac * 200)

		-- Haze grows slightly wider toward impact (more frost build-up)
		local hazeWidth  = 10 + tNorm * 8

		render.SetMaterial(crackMat)
		-- Atmospheric ice-blue haze — wide, nearly transparent
		for i = 1, #segPts - 1 do
			render.DrawBeam(segPts[i], segPts[i + 1], hazeWidth, 0, 1, Color(190, 220, 255, hazeA))
		end
		-- Bright frosted crack — thin, white-dominant
		for i = 1, #segPts - 1 do
			render.DrawBeam(segPts[i], segPts[i + 1], 2.2, 0, 1, Color(230, 245, 255, crackA))
		end
	end

	hook.Add("PostDrawTranslucentRenderables", "Arcana_GlacialWake_Render", function()
		local now      = CurTime()
		local toRemove = {}

		for idx, wake in ipairs(activeWakes) do
			if now >= wake.dieTime then
				toRemove[#toRemove + 1] = idx
				continue
			end

			local pts     = wake.points
			local arcs    = wake.arcs
			local n       = #pts
			local elapsed = now - wake.birth
			local halfDur = WAKE_DURATION * 0.5

			-- Crack segments: origin fades first, impact segment lasts the full duration
			for i = 1, n - 1 do
				local segNorm   = (i - 1) / math.max(n - 2, 1)  -- 0=origin, 1=impact
				local fadeStart = segNorm * halfDur
				local alphaFrac = math.Clamp(1 - (elapsed - fadeStart) / halfDur, 0, 1)
				if alphaFrac < 0.01 then continue end
				if not arcs[i] then continue end

				drawCrackSegment(arcs[i], alphaFrac, segNorm)
			end

			render.SetMaterial(glowMat)

			-- Large glow at impact point — lingers longest, cold white-blue
			local impAlpha = math.Clamp(1 - (elapsed - halfDur) / halfDur, 0, 1)
			if impAlpha > 0.01 then
				local sz = 100 * impAlpha
				render.DrawSprite(pts[n], sz, sz, Color(200, 230, 255, math.floor(impAlpha * 180)))
			end

			-- Smaller ice-node glows along every other intermediate point
			-- (every point for sparse paths, every 2nd for dense ones)
			local step = n > 20 and 2 or 1
			for i = 2, n - 1, step do
				local segNorm   = (i - 1) / math.max(n - 2, 1)
				local fadeStart = segNorm * halfDur
				local a         = math.Clamp(1 - (elapsed - fadeStart) / halfDur, 0, 1)
				if a < 0.01 then continue end
				local sz = (10 + segNorm * 14) * a
				render.DrawSprite(pts[i], sz, sz, Color(200, 225, 255, math.floor(a * 70)))
			end
		end

		for i = #toRemove, 1, -1 do
			table.remove(activeWakes, toRemove[i])
		end
	end)

	-- Dynamic light at the impact point: cold white, bright flash that fades quickly
	hook.Add("PostDrawOpaqueRenderables", "Arcana_GlacialWake_DLight", function()
		local now = CurTime()
		for i, wake in ipairs(activeWakes) do
			if now >= wake.dieTime then continue end
			local elapsed    = now - wake.birth
			local brightness = math.Clamp(1 - elapsed / (WAKE_DURATION * 0.35), 0, 1) * 3.0
			if brightness < 0.05 then continue end

			local dlight = DynamicLight(200 + ((i - 1) % 8))
			if dlight then
				dlight.pos        = wake.points[#wake.points]
				dlight.r          = 140
				dlight.g          = 200
				dlight.b          = 255
				dlight.brightness = brightness
				dlight.Decay      = 1000
				dlight.Size       = 340
				dlight.DieTime    = now + 0.1
			end
		end
	end)
end
