-- Arcane Spear Beam
-- Shared server and client logic for arcane spear beam effects
-- Used by both arcane_spear spell and arcane_rounds enchantment

Arcane = Arcane or {}
Arcane.Common = Arcane.Common or {}

if SERVER then
	util.AddNetworkString("Arcana_SpearBeam")

	-- Fire an arcane spear beam from origin in direction
	-- @param attacker: Entity that is attacking (for damage attribution)
	-- @param origin: Vector starting position
	-- @param direction: Vector normalized direction
	-- @param options: Table of optional parameters:
	--   - maxDist: number (default 2000)
	--   - damage: number (default 65)
	--   - splashRadius: number (default 100)
	--   - splashDamage: number (default 18)
	--   - filter: table of entities to ignore (default {attacker})
	function Arcane.Common.SpearBeam(attacker, origin, direction, options)
		if not SERVER then return end
		if not IsValid(attacker) then return end
		if not isvector(origin) or not isvector(direction) then return end

		options = options or {}
		local maxDist = options.maxDist or 2000
		local damage = options.damage or 65
		local splashRadius = options.splashRadius or 100
		local splashDamage = options.splashDamage or 18
		local filter = options.filter or {attacker}

		local dir = direction:GetNormalized()

		-- Single trace - no penetration
		local tr = util.TraceLine({
			start = origin,
			endpos = origin + dir * maxDist,
			filter = filter,
			mask = MASK_SHOT
		})

		local hitPos = tr.HitPos
		local hitEnt = tr.Entity

		-- Impact visuals (only if we hit something)
		if tr.Hit then
			local ed = EffectData()
			ed:SetOrigin(hitPos)
			util.Effect("cball_explode", ed, true, true)
			util.Decal("FadingScorch", hitPos + tr.HitNormal * 8, hitPos - tr.HitNormal * 8)

			-- Direct hit damage
			if IsValid(hitEnt) then
				local dmg = DamageInfo()
				dmg:SetDamage(damage)
				dmg:SetDamageType(bit.bor(DMG_DISSOLVE, DMG_ENERGYBEAM))
				dmg:SetAttacker(attacker)
				dmg:SetInflictor(attacker)
				dmg:SetDamagePosition(hitPos)
				hitEnt:TakeDamageInfo(dmg)
			end

			-- Splash damage around impact
			if splashDamage > 0 and splashRadius > 0 then
				Arcane:BlastDamage(attacker, attacker, hitPos, splashRadius, splashDamage, DMG_DISSOLVE, true)
			end
		end

		-- Broadcast beam for client visuals
		net.Start("Arcana_SpearBeam", true)
		net.WriteVector(origin)
		net.WriteVector(hitPos)
		net.Broadcast()
	end
end

-- CLIENT ONLY BELOW
if CLIENT then
	local matBeam = Material("effects/laser1")
	local matGlow = Material("sprites/light_glow02_add")
	local matFlare = Material("effects/blueflare1")
	local spearBeams = spearBeams or {}

	hook.Add("PostDrawTranslucentRenderables", "Arcana_RenderSpearBeams", function()
		if not spearBeams or #spearBeams == 0 then return end

		local curTime = CurTime()

		for i = #spearBeams, 1, -1 do
			local b = spearBeams[i]

			if not b or curTime > b.dieTime then
				table.remove(spearBeams, i)
			else
				local age = curTime - b.startTime
				local frac = math.Clamp((b.dieTime - curTime) / b.lifeTime, 0, 1)
				local fadeFrac = math.min(age / 0.1, 1) * frac

				local a, c = b.startPos, b.endPos
				local dir = (c - a)
				local len = dir:Length()

				if len < 1 then continue end
				dir:Normalize()

				-- Distance-based scaling
				local distScale = math.Clamp(len / 500, 0.5, 2.5)
				local baseWidth = b.baseWidth * distScale

				-- LAYER 1: Intense core beam (brightest white)
				render.SetMaterial(matBeam)
				local steps = math.max(6, math.floor(len / 40))
				render.StartBeam(steps + 1)
				for j = 0, steps do
					local t = j / steps
					local p = a + dir * (len * t)
					local pulse = 1 + math.sin(age * 20 + t * 3) * 0.15
					local w = baseWidth * 0.7 * pulse * fadeFrac
					render.AddBeam(p, w, t, Color(255, 230, 255, math.floor(255 * fadeFrac)))
				end
				render.EndBeam()

				-- LAYER 2: Main purple beam
				render.StartBeam(steps + 1)
				for j = 0, steps do
					local t = j / steps
					local p = a + dir * (len * t)
					local w = baseWidth * 1.2 * fadeFrac
					render.AddBeam(p, w, t, Color(b.col.r, b.col.g, b.col.b, math.floor(220 * fadeFrac)))
				end
				render.EndBeam()

				-- LAYER 3: Outer glow
				render.StartBeam(steps + 1)
				for j = 0, steps do
					local t = j / steps
					local p = a + dir * (len * t)
					local w = baseWidth * 2.2 * fadeFrac
					render.AddBeam(p, w, t, Color(180, 140, 255, math.floor(70 * fadeFrac)))
				end
				render.EndBeam()

				-- LAYER 4: Sharp spear tip
				render.SetMaterial(matBeam)
				local tipLen = math.min(60, len * 0.35)
				local tipStart = c - dir * tipLen
				render.StartBeam(5)
				for j = 0, 4 do
					local t = j / 4
					local p = tipStart + dir * (tipLen * t)
					local w = Lerp(t * t, baseWidth * 1.3, 0) * fadeFrac
					render.AddBeam(p, w, t, Color(255, 240, 255, math.floor(255 * fadeFrac)))
				end
				render.EndBeam()

				-- Impact sprites
				render.SetMaterial(matFlare)
				render.DrawSprite(c, baseWidth * 4 * fadeFrac, baseWidth * 4 * fadeFrac, Color(255, 240, 255, math.floor(220 * fadeFrac)))
				render.SetMaterial(matGlow)
				render.DrawSprite(c, baseWidth * 6 * fadeFrac, baseWidth * 6 * fadeFrac, Color(b.col.r, b.col.g, b.col.b, math.floor(160 * fadeFrac)))

				-- Muzzle flash
				local muzzleSize = baseWidth * 4 * fadeFrac
				render.SetMaterial(matFlare)
				render.DrawSprite(a, muzzleSize, muzzleSize, Color(255, 240, 255, math.floor(180 * fadeFrac)))
				render.SetMaterial(matGlow)
				render.DrawSprite(a, muzzleSize * 1.8, muzzleSize * 1.8, Color(b.col.r, b.col.g, b.col.b, math.floor(140 * fadeFrac)))
			end
		end
	end)

	net.Receive("Arcana_SpearBeam", function()
		local startPos = net.ReadVector()
		local endPos = net.ReadVector()
		local col = Color(180, 120, 255)

		-- Particle effects
		local center = (startPos + endPos) * 0.5
		local emitter = ParticleEmitter(center)

		if emitter then
			local dir = (endPos - startPos)
			local len = dir:Length()
			if len > 0 then
				dir:Normalize()
			end

			-- Muzzle particles
			for i = 1, 12 do
				local p = emitter:Add("effects/blueflare1", startPos)
				if p then
					p:SetDieTime(math.Rand(0.2, 0.4))
					p:SetStartAlpha(255)
					p:SetEndAlpha(0)
					p:SetStartSize(math.Rand(8, 16))
					p:SetEndSize(0)
					p:SetColor(180, 140, 255)
					local forward = dir or Vector(1, 0, 0)
					p:SetVelocity(forward * math.Rand(80, 150) + VectorRand() * 40)
					p:SetAirResistance(130)
				end
			end

			emitter:Finish()
		end

		-- Store beam for rendering
		spearBeams[#spearBeams + 1] = {
			startPos = startPos,
			endPos = endPos,
			col = col,
			lifeTime = 0.3,
			dieTime = CurTime() + 0.3,
			startTime = CurTime(),
			baseWidth = 14,
		}
	end)
end
