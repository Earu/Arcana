-- Ring of Fire: A rapidly expanding ring that scorches and ignites nearby foes
if SERVER then
	util.AddNetworkString("Arcana_RingOfFire_VFX")
end

Arcane:RegisterSpell({
	id = "ring_of_fire",
	name = "Ring of Fire",
	description = "Summon a blazing ring that rapidly expands, scorching and igniting foes around you.",
	category = Arcane.CATEGORIES.COMBAT,
	level_required = 12,
	knowledge_cost = 3,
	cooldown = 10.0,
	cost_type = Arcane.COST_TYPES.COINS,
	cost_amount = 80,
	cast_time = 0.8,
	range = 0,
	icon = "icon16/fire.png",
	is_projectile = false,
	has_target = false,
	cast_anim = "becon",
	cast = function(caster, _, _, ctx)
		if not SERVER then return true end
		if not IsValid(caster) then return false end
		local origin = caster:WorldSpaceCenter()
		local maxRadius = 620
		local duration = 0.8
		local steps = 8
		local bandWidth = 120 -- thickness of the ring shell that applies effects
		local baseDamage = 18
		local igniteTime = 4
		local pushPlayer = 220
		local pushProp = 16000
		local processed = {}

		-- Broadcast client visuals (expanding fiery ring)
		net.Start("Arcana_RingOfFire_VFX", true)
		net.WriteVector(origin)
		net.WriteFloat(maxRadius)
		net.WriteFloat(duration)
		net.Broadcast()

		-- Audio/impact
		caster:EmitSound("ambient/fire/gascan_ignite1.wav", 75, 100)
		sound.Play("ambient/fire/mtov_flame2.wav", origin, 70, 100)
		util.ScreenShake(origin, 4, 40, 0.4, 512)

		for i = 1, steps do
			local t = (i / steps) * duration
			timer.Simple(t, function()
				if not IsValid(caster) then return end
				local r = (i / steps) * maxRadius
				local inner = math.max(0, r - bandWidth * 0.5)
				local outer = r + bandWidth * 0.5
				for _, ent in ipairs(ents.FindInSphere(origin, outer + 24)) do
					if not IsValid(ent) then continue end
					if ent == caster then continue end
					if ent:IsWeapon() then continue end
					if processed[ent] then continue end

					local parent = ent:GetParent()
					if IsValid(parent) then
						if parent == caster then continue end
						if parent:IsWeapon() then continue end
						if processed[parent] then continue end
					end

					local c = ent:WorldSpaceCenter()
					local dist = c:Distance(origin)
					if dist < inner or dist > outer then continue end

					processed[ent] = true

					-- Actors take light burn damage and ignite briefly
					local isActor = ent:IsPlayer() or ent:IsNPC() or (ent.IsNextBot and ent:IsNextBot())
					local pushDir = (c - origin):GetNormalized()
					if isActor then
						local dmg = DamageInfo()
						dmg:SetDamage(baseDamage)
						dmg:SetDamagePosition(c)
						dmg:SetDamageType(bit.bor(DMG_BURN, DMG_SLOWBURN))
						dmg:SetAttacker(IsValid(caster) and caster or game.GetWorld())
						dmg:SetInflictor(IsValid(caster) and caster or game.GetWorld())
						ent:TakeDamageInfo(dmg)

						if ent.Ignite then
							ent:Ignite(igniteTime, 0)
						end

						if ent.SetVelocity then
							ent:SetVelocity(pushDir * pushPlayer)
						end
					else
						if ent.Ignite then
							ent:Ignite(igniteTime, 0)
						end

						local phys = ent:GetPhysicsObject()
						if IsValid(phys) then
							phys:ApplyForceCenter(pushDir * (pushProp * math.max(1, phys:GetMass() * 0.6)))
						end
					end
				end
			end)
		end

		return true
	end,
	trigger_phrase_aliases = {
		"fire ring",
		"circle of fire",
	}
})

if CLIENT then
	net.Receive("Arcana_RingOfFire_VFX", function()
		local pos = net.ReadVector()
		local radius = net.ReadFloat() or 600
		local life = net.ReadFloat() or 0.8
		-- Expanding particle ring: spawn bursts around the circumference over time
		local steps = 14
		local points = 28
		local startR = 40
		local emitter = ParticleEmitter(pos)
		local ed = EffectData()
		ed:SetOrigin(pos)
		util.Effect("cball_explode", ed, true, true)
		sound.Play("ambient/fire/ignite.wav", pos, 70, 110)

		for i = 1, steps do
			local frac = i / steps
			local delay = frac * life
			timer.Simple(delay, function()
				local rNow = Lerp(frac, startR, radius)
				for p = 1, points do
					local ang = (p / points) * 360
					local dir = Angle(0, ang, 0):Forward()
					local ppos = pos + dir * rNow
					-- Occasional micro-spark pop
					if (p % 7) == 0 then
						local fx = EffectData()
						fx:SetOrigin(ppos)
						util.Effect("cball_explode", fx, true, true)
					end

					-- Ground scorch pass
					if i == steps then
						local tr = util.TraceLine({
							start = ppos + Vector(0, 0, 48),
							endpos = ppos - Vector(0, 0, 128),
							mask = MASK_SOLID_BRUSHONLY
						})

						if tr.Hit then
							util.Decal("Scorch", tr.HitPos + tr.HitNormal * 4, tr.HitPos - tr.HitNormal * 8)
						end
					end

					-- Embers (match fireball style)
					for j = 1, 3 do
						local ptl = emitter and emitter:Add("effects/yellowflare", ppos + VectorRand() * 2)

						if ptl then
							ptl:SetVelocity(dir * (70 + math.random(0, 40)) + VectorRand() * 20)
							ptl:SetDieTime(0.4 + math.Rand(0.1, 0.3))
							ptl:SetStartAlpha(220)
							ptl:SetEndAlpha(0)
							ptl:SetStartSize(4 + math.random(0, 2))
							ptl:SetEndSize(0)
							ptl:SetRoll(math.Rand(0, 360))
							ptl:SetRollDelta(math.Rand(-3, 3))
							ptl:SetColor(255, 160 + math.random(0, 40), 60)
							ptl:SetLighting(false)
							ptl:SetAirResistance(60)
							ptl:SetGravity(Vector(0, 0, -50))
							ptl:SetCollide(false)
						end
					end

					-- Fire cloud/smoke puffs
					for j = 1, 2 do
						local mat = (math.random() < 0.5) and "effects/fire_cloud1" or "effects/fire_cloud2"
						local ptl = emitter and emitter:Add(mat, ppos)

						if ptl then
							ptl:SetVelocity(dir * (50 + math.random(0, 30)) + VectorRand() * 10)
							ptl:SetDieTime(0.6 + math.Rand(0.2, 0.5))
							ptl:SetStartAlpha(180)
							ptl:SetEndAlpha(0)
							ptl:SetStartSize(10 + math.random(0, 8))
							ptl:SetEndSize(30 + math.random(0, 12))
							ptl:SetRoll(math.Rand(0, 360))
							ptl:SetRollDelta(math.Rand(-1, 1))
							ptl:SetColor(255, 120 + math.random(0, 60), 40)
							ptl:SetLighting(false)
							ptl:SetAirResistance(70)
							ptl:SetGravity(Vector(0, 0, 20))
							ptl:SetCollide(false)
						end
					end
				end
			end)
		end

		timer.Simple(life + 0.5, function()
			if emitter then
				emitter:Finish()
				emitter = nil
			end
		end)
	end)
end


