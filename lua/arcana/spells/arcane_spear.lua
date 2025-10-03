if SERVER then
	util.AddNetworkString("Arcana_SpearBeam")
end

Arcane:RegisterSpell({
	id = "arcane_spear",
	name = "Arcane Spear",
	description = "Project a piercing lance of arcane energy that penetrates multiple targets.",
	category = Arcane.CATEGORIES.COMBAT,
	level_required = 12,
	knowledge_cost = 3,
	cooldown = 7.5,
	cost_type = Arcane.COST_TYPES.COINS,
	cost_amount = 120,
	cast_time = 0.8,
	range = 2000,
	icon = "icon16/bullet_blue.png",
	is_projectile = false,
	has_target = true,
	cast_anim = "forward",
	cast = function(caster, _, _, ctx)
		if not SERVER then return true end
		local startPos = caster:GetShootPos()
		local dir = caster:GetAimVector()
		local maxDist = 2000
		local penetrations = 4
		local damagePerHit = 55
		local falloff = 0.8
		local traveled = 0

		local filter = {caster}

		local segments = {}

		for i = 1, penetrations do
			local segStart = startPos

			local tr = util.TraceLine({
				start = startPos,
				endpos = startPos + dir * (maxDist - traveled),
				filter = filter,
				mask = MASK_SHOT
			})

			if not tr.Hit then break end
			local hitPos = tr.HitPos
			local hitEnt = tr.Entity

			table.insert(segments, {segStart, hitPos})

			-- Impact visuals
			local ed = EffectData()
			ed:SetOrigin(hitPos)
			util.Effect("cball_explode", ed, true, true)
			util.Decal("FadingScorch", hitPos + tr.HitNormal * 8, hitPos - tr.HitNormal * 8)

			-- Direct hit damage
			if IsValid(hitEnt) then
				local dmg = DamageInfo()
				dmg:SetDamage(damagePerHit)
				dmg:SetDamageType(bit.bor(DMG_DISSOLVE, DMG_ENERGYBEAM))
				dmg:SetAttacker(IsValid(caster) and caster or game.GetWorld())
				dmg:SetInflictor(IsValid(caster) and caster or game.GetWorld())
				dmg:SetDamagePosition(hitPos)
				hitEnt:TakeDamageInfo(dmg)
			end

			-- Small splash along the lance for feedback
			Arcane:BlastDamage(caster, caster, hitPos, 80, 18, DMG_DISSOLVE, false, true)

			-- Prepare for next penetration
			table.insert(filter, hitEnt or tr.Entity)
			startPos = hitPos + dir * 6
			traveled = traveled + tr.Fraction * (maxDist - traveled)
			damagePerHit = math.max(15, math.floor(damagePerHit * falloff))
		end

		-- Broadcast beam segments for client visuals
		if #segments > 0 then
			net.Start("Arcana_SpearBeam", true)
			net.WriteEntity(caster)
			net.WriteUInt(#segments, 8)

			for i = 1, #segments do
				net.WriteVector(segments[i][1])
				net.WriteVector(segments[i][2])
			end

			net.Broadcast()
		end

		caster:EmitSound("arcana/arcane_1.ogg", 80, 120)
		caster:EmitSound("arcana/arcane_2.ogg", 80, 120)
		caster:EmitSound("weapons/physcannon/superphys_launch1.wav", 80, 120)

		return true
	end,
	trigger_phrase_aliases = {
		"spear",
	}
})

if CLIENT then
	local matBeam = Material("sprites/physbeam")
	local matGlow = Material("sprites/light_glow02_add")
	local spearBeams = spearBeams or {}

	hook.Add("PostDrawTranslucentRenderables", "Arcana_RenderSpearBeams", function()
		if not spearBeams or #spearBeams == 0 then return end

		for i = #spearBeams, 1, -1 do
			local b = spearBeams[i]

			if not b or CurTime() > b.dieTime then
				table.remove(spearBeams, i)
			else
				local frac = math.Clamp((b.dieTime - CurTime()) / b.lifeTime, 0, 1)
				local coreStartW = b.baseWidth * 1.4
				local coreEndW = b.baseWidth * 0.6
				local auraStartW = coreStartW * 1.6
				local auraEndW = coreEndW * 1.2
				local coreAlpha = 220 * frac
				local auraAlpha = 90 * frac

				-- Muzzle flash at the very start
				if b.startPos then
					render.SetMaterial(matGlow)
					render.DrawSprite(b.startPos, coreStartW * 3, coreStartW * 3, Color(b.col.r, b.col.g, b.col.b, math.floor(200 * frac)))
				end

				for _, seg in ipairs(b.segments) do
					local a, c = seg[1], seg[2]
					local dir = (c - a)
					local len = dir:Length()

					if len > 0 then
						dir:Normalize()
					end

					-- Core tapered beam
					render.SetMaterial(matBeam)
					local steps = 8
					render.StartBeam(steps + 1)

					for j = 0, steps do
						local t = j / steps
						local p = a + dir * (len * t)
						local w = Lerp(t, coreStartW, coreEndW)
						render.AddBeam(p, w, t, Color(b.col.r, b.col.g, b.col.b, math.floor(coreAlpha)))
					end

					render.EndBeam()
					-- Outer aura beam
					render.StartBeam(steps + 1)

					for j = 0, steps do
						local t = j / steps
						local p = a + dir * (len * t)
						local w = Lerp(t, auraStartW, auraEndW)
						render.AddBeam(p, w, t, Color(220, 200, 255, math.floor(auraAlpha)))
					end

					render.EndBeam()
					-- Spear tip: pointed end
					local tipLen = math.min(36, len * 0.35)
					local tipStart = c - dir * tipLen
					render.StartBeam(5)

					for j = 0, 4 do
						local t = j / 4
						local p = tipStart + dir * (tipLen * t)
						local w = Lerp(t, coreStartW * 1.1, 0)
						render.AddBeam(p, w, t, Color(b.col.r, b.col.g, b.col.b, math.floor(coreAlpha)))
					end

					render.EndBeam()
					-- Endpoint glow
					render.SetMaterial(matGlow)
					render.DrawSprite(c, coreStartW * 1.3, coreStartW * 1.3, Color(b.col.r, b.col.g, b.col.b, math.floor(230 * frac)))
				end
			end
		end
	end)

	net.Receive("Arcana_SpearBeam", function()
		local _ = net.ReadEntity()
		local count = net.ReadUInt(8)
		local col = Color(180, 120, 255)
		local segments = {}

		for i = 1, count do
			local a = net.ReadVector()
			local b = net.ReadVector()

			segments[#segments + 1] = {a, b}
		end

		local startPos = segments[1] and segments[1][1] or nil

		-- Quick shimmer particles along path to sell energy
		if startPos then
			local last = segments[#segments] and segments[#segments][2] or startPos
			local center = (startPos + last) * 0.5
			local emitter = ParticleEmitter(center)

			if emitter then
				for _, seg in ipairs(segments) do
					local a, c = seg[1], seg[2]
					local segMid = (a + c) * 0.5
					local p = emitter:Add("effects/spark", segMid)

					if p then
						p:SetDieTime(0.12)
						p:SetStartAlpha(220)
						p:SetEndAlpha(0)
						p:SetStartSize(10)
						p:SetEndSize(0)
						p:SetColor(col.r, col.g, col.b)
						p:SetVelocity(VectorRand() * 20)
						p:SetAirResistance(120)
					end
				end

				emitter:Finish()
			end
		end

		spearBeams[#spearBeams + 1] = {
			segments = segments,
			startPos = startPos,
			col = col,
			lifeTime = 0.28,
			dieTime = CurTime() + 0.28,
			baseWidth = 12,
		}
	end)
end