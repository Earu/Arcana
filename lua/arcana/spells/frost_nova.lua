if SERVER then
	util.AddNetworkString("Arcana_FrostNovaBurst")
end

Arcane:RegisterSpell({
	id = "frost_nova",
	name = "Frost Nova",
	description = "Release a burst of freezing air around you, damaging and slowing nearby foes.",
	category = Arcane.CATEGORIES.COMBAT,
	level_required = 16,
	knowledge_cost = 3,
	cooldown = 14.0,
	cost_type = Arcane.COST_TYPES.COINS,
	cost_amount = 180,
	cast_time = 0.9,
	range = 0,
	icon = "icon16/weather_snow.png",
	is_projectile = false,
	has_target = false,
	cast_anim = "becon",
	can_cast = function(caster)
		if caster:InVehicle() then return false, "Cannot cast while in a vehicle" end

		return true
	end,
	cast = function(caster, _, _, ctx)
		if not SERVER then return true end
		local pos = caster:WorldSpaceCenter()
		local radius = 360
		local baseDamage = 45
		local slowMult = 0.5
		local slowDuration = 3.5

		-- VFX: bands around caster
		Arcane:SendAttachBandVFX(caster, Color(170, 220, 255, 255), radius * 0.7, 0.8, {
			{
				radius = radius * 0.35,
				height = 18,
				spin = {
					p = 0,
					y = -30,
					r = 0
				},
				lineWidth = 3
			},
			{
				radius = radius * 0.22,
				height = 10,
				spin = {
					p = 0,
					y = 30,
					r = 0
				},
				lineWidth = 2
			},
		}, "frost_nova")

		-- Damage and slow
		for _, ent in ipairs(ents.FindInSphere(pos, radius)) do
			if not IsValid(ent) then continue end
			if ent == caster then continue end

			local isActor = ent:IsPlayer() or ent:IsNPC() or (ent.IsNextBot and ent:IsNextBot())
			if not isActor then continue end

			-- Deal damage
			local dmg = DamageInfo()
			dmg:SetDamage(baseDamage)
			dmg:SetDamageType(bit.bor(DMG_GENERIC, DMG_SONIC))
			dmg:SetAttacker(IsValid(caster) and caster or game.GetWorld())
			dmg:SetInflictor(IsValid(caster) and caster or game.GetWorld())
			ent:TakeDamageInfo(dmg)
			-- Knockback
			local pushDir = (ent:WorldSpaceCenter() - pos):GetNormalized()

			if ent:IsPlayer() then
				ent:SetVelocity(pushDir * 220)
			else
				local phys = ent:GetPhysicsObject()

				if IsValid(phys) then
					phys:ApplyForceCenter(pushDir * 20000)
				end
			end

			-- Apply slow via shared Frost status
			Arcane.Status.Frost.Apply(ent, {
				slowMult = slowMult,
				duration = slowDuration,
				vfxTag = "frost_slow",
				sendClientFX = ent:IsPlayer()
			})
		end

		-- Impact visuals and audio
		local ed = EffectData()
		ed:SetOrigin(pos)
		util.Effect("GlassImpact", ed, true, true)
		util.ScreenShake(pos, 4, 60, 0.25, 512)
		caster:EmitSound("physics/glass/glass_impact_bullet1.wav", 75, 120)
		caster:EmitSound("ambient/levels/canals/windchime2.wav", 70, 140)
		-- Tell clients to render a frosty shock ring
		net.Start("Arcana_FrostNovaBurst", true)
		net.WriteEntity(caster)
		net.WriteFloat(radius)
		net.Broadcast()

		return true
	end
})

if CLIENT then
	-- Customize the casting circle during channel
	hook.Add("Arcane_BeginCastingVisuals", "Arcana_FrostNova_Circle", function(caster, spellId, castTime, forwardLike) end)
	-- One-shot frosty shock ring at cast moment
	local matGlow = Material("sprites/light_glow02_add")
	local matRing = Material("effects/select_ring")
	local matBeam = Material("sprites/physbeam")
	local bursts = {}
	local iceSpikes = {}
	local frostOverlayMat = Material("particle/particle_smokegrenade")

	hook.Add("PostDrawTranslucentRenderables", "Arcana_FrostNova_Render", function()
		-- Rings
		for i = #bursts, 1, -1 do
			local b = bursts[i]

			if CurTime() > b.die then
				table.remove(bursts, i)
			end
		end

		for i = 1, #bursts do
			local b = bursts[i]
			local frac = 1 - (b.die - CurTime()) / b.life
			frac = math.Clamp(frac, 0, 1)
			local curr = Lerp(frac, 10, b.radius)
			local alpha = 220 * (1 - frac)
			render.SetMaterial(matRing)
			render.DrawQuadEasy(b.pos + Vector(0, 0, 2), Vector(0, 0, 1), curr, curr, Color(170, 220, 255, math.floor(alpha)), 0)
			render.SetMaterial(matGlow)
			render.DrawSprite(b.pos + Vector(0, 0, 4), curr * 0.4, curr * 0.4, Color(180, 230, 255, math.floor(alpha * 0.6)))
		end

		-- Ice spikes
		for i = #iceSpikes, 1, -1 do
			local s = iceSpikes[i]

			if CurTime() > s.die then
				table.remove(iceSpikes, i)
			end
		end

		for i = 1, #iceSpikes do
			local s = iceSpikes[i]
			local t = 1 - (s.die - CurTime()) / s.life
			t = math.Clamp(t, 0, 1)
			local grow = math.EaseInOut(t, 0.2, 0.6)
			local tip = s.pos + s.normal * (s.height * grow)
			local coreCol = Color(200, 230, 255, 230 * (1 - t * 0.6))
			local auraCol = Color(180, 220, 255, 140 * (1 - t))
			render.SetMaterial(matBeam)
			-- core narrow beam
			render.StartBeam(2)
			render.AddBeam(s.pos, 8, 0, coreCol)
			render.AddBeam(tip, 2, 1, coreCol)
			render.EndBeam()
			-- soft aura
			render.StartBeam(2)
			render.AddBeam(s.pos, 14, 0, auraCol)
			render.AddBeam(tip, 4, 1, auraCol)
			render.EndBeam()
			-- tip glow
			render.SetMaterial(matGlow)
			render.DrawSprite(tip, 12, 12, Color(200, 240, 255, 200 * (1 - t)))
		end
	end)

	net.Receive("Arcana_FrostNovaBurst", function()
		local caster = net.ReadEntity()
		local radius = net.ReadFloat()
		local pos = IsValid(caster) and caster:WorldSpaceCenter() or net.ReadVector() or Vector(0, 0, 0)
		-- Add visual entries (double ring)
		local r1 = math.max(140, radius * 0.8)
		local r2 = math.max(180, radius)

		bursts[#bursts + 1] = {
			pos = pos,
			radius = r1,
			life = 0.5,
			die = CurTime() + 0.5
		}

		bursts[#bursts + 1] = {
			pos = pos,
			radius = r2,
			life = 0.65,
			die = CurTime() + 0.65
		}

		-- Cold dynamic light
		local dl = DynamicLight(math.random(0, 9999))

		if dl then
			dl.pos = pos
			dl.r = 170
			dl.g = 220
			dl.b = 255
			dl.brightness = 2.5
			dl.Size = radius * 0.6
			dl.Decay = 1500
			dl.DieTime = CurTime() + 0.2
		end

		-- Light snow puff + generate ice spikes
		local emitter = ParticleEmitter(pos)

		if emitter then
			-- fine snow mist
			for i = 1, 26 do
				local p = emitter:Add("particle/particle_smokegrenade", pos + VectorRand() * 6)

				if p then
					p:SetVelocity(VectorRand() * 60 + Vector(0, 0, 30))
					p:SetDieTime(0.6 + math.Rand(0.1, 0.3))
					p:SetStartAlpha(60)
					p:SetEndAlpha(0)
					p:SetStartSize(10)
					p:SetEndSize(26)
					p:SetColor(210, 230, 255)
					p:SetAirResistance(80)
				end
			end

			-- icy shard flecks
			for i = 1, 34 do
				local mat = (math.random() < 0.5) and "effects/fleck_glass1" or "effects/fleck_glass2"
				local p = emitter.Add and emitter:Add(mat, pos)

				if p then
					local dir = Angle(0, (i / 34) * 360, 0):Forward()
					p:SetVelocity(dir * math.Rand(200, 320) + Vector(0, 0, math.Rand(80, 140)))
					p:SetDieTime(math.Rand(0.5, 0.9))
					p:SetStartAlpha(255)
					p:SetEndAlpha(0)
					p:SetStartSize(math.Rand(2, 4))
					p:SetEndSize(0)
					p:SetRoll(math.Rand(0, 360))
					p:SetRollDelta(math.Rand(-8, 8))
					p:SetColor(200, 230, 255)
					p:SetAirResistance(40)
					p:SetGravity(Vector(0, 0, -200))
					p:SetCollide(true)
					p:SetBounce(0.2)
				end
			end

			emitter:Finish()
		end

		-- Spawn ice spikes by tracing to ground around the caster
		local num = 14

		for i = 1, num do
			local ang = (i / num) * 360 + math.Rand(-8, 8)
			local dir = Angle(0, ang, 0):Forward()
			local dist = math.Rand(r1 * 0.6, r2 * 0.9)
			local start = pos + dir * dist + Vector(0, 0, 64)

			local tr = util.TraceLine({
				start = start,
				endpos = start + Vector(0, 0, -256),
				mask = MASK_SOLID_BRUSHONLY
			})

			if tr.Hit then
				iceSpikes[#iceSpikes + 1] = {
					pos = tr.HitPos + tr.HitNormal * 2,
					normal = tr.HitNormal,
					height = math.Rand(48, 96),
					life = 0.65,
					die = CurTime() + 0.65,
				}
			end
		end
	end)
end