-- Wind Blast: A powerful radial burst that pushes everything away from the caster
Arcane:RegisterSpell({
	id = "wind_blast",
	name = "Wind Blast",
	description = "Emit a powerful shock of wind, hurling nearby foes and objects away.",
	category = Arcane.CATEGORIES.COMBAT,
	level_required = 10,
	knowledge_cost = 3,
	cooldown = 8.0,
	cost_type = Arcane.COST_TYPES.COINS,
	cost_amount = 50,
	cast_time = 0.7,
	range = 0,
	icon = "icon16/flag_white.png",
	is_projectile = false,
	has_target = false,
	cast_anim = "becon",
	cast = function(caster, _, _, ctx)
		if not SERVER then return true end
		if not IsValid(caster) then return false end

		local srcEnt = IsValid(ctx.casterEntity) and ctx.casterEntity or caster
		local origin = srcEnt:WorldSpaceCenter()
		local radius = 720
		local strengthPlayer = 2000
		local strengthProp = 100000
		local upBoost = 500
		local baseDamage = 55

		-- Network visual effects to clients
		net.Start("Arcana_WindBlast", true)
		net.WriteVector(origin)
		net.WriteFloat(radius)
		net.Broadcast()

		-- Powerful radial blast sounds
		sound.Play("ambient/wind/wind_roar1.wav", origin, 100, 90)
		sound.Play("ambient/explosions/explode_" .. math.random(1, 9) .. ".wav", origin, 95, 130)
		sound.Play("physics/concrete/boulder_impact_hard" .. math.random(1, 4) .. ".wav", origin, 90, 50)
		timer.Simple(0.05, function()
			sound.Play("ambient/explosions/exp" .. math.random(1, 3) .. ".wav", origin, 90, 140)
			sound.Play("ambient/wind/wind_snippet" .. math.random(1, 5) .. ".wav", origin, 85, 110)
		end)
		timer.Simple(0.15, function()
			sound.Play("weapons/physcannon/energy_disintegrate4.wav", origin, 80, 70)
		end)
		
		util.ScreenShake(origin, 10, 120, 0.5, radius * 1.2)

		for _, ent in ipairs(ents.FindInSphere(origin, radius)) do
			if not IsValid(ent) then continue end
			if ent == srcEnt then continue end

			local c = ent:WorldSpaceCenter()
			local dir = (c - origin):GetNormalized()
			local dist = c:Distance(origin)

			-- Reduced falloff so the push feels impactful at range
			local falloff = 0.75 + 0.25 * (1 - math.Clamp(dist / radius, 0, 1))
			if ent:IsPlayer() or ent:IsNPC() or (ent.IsNextBot and ent:IsNextBot()) then
				-- Deal damage
				local dmg = DamageInfo()
				dmg:SetDamage(baseDamage * falloff)
				dmg:SetDamageType(DMG_SONIC)
				dmg:SetAttacker(IsValid(caster) and caster or game.GetWorld())
				dmg:SetInflictor(IsValid(srcEnt) and srcEnt or game.GetWorld())
				ent:TakeDamageInfo(dmg)

				local vel = dir * (strengthPlayer * falloff) + Vector(0, 0, upBoost)
				if ent.SetGroundEntity then ent:SetGroundEntity(NULL) end
				if ent.SetVelocity then ent:SetVelocity(vel) end
			else
				local phys = ent:GetPhysicsObject()
				if IsValid(phys) then
					phys:Wake()
					phys:ApplyForceCenter((dir * (strengthProp * falloff)) + Vector(0, 0, upBoost * 50))
				end
			end
		end

		return true
	end,
	trigger_phrase_aliases = {
		"air blast",
	}
})

if SERVER then
	util.AddNetworkString("Arcana_WindBlast")
end

if CLIENT then
	net.Receive("Arcana_WindBlast", function()
		local origin = net.ReadVector()
		local radius = net.ReadFloat()
		
		local emitter = ParticleEmitter(origin)
		if not emitter then return end
		
		-- Omnidirectional wind burst particles (spherical expansion)
		for i = 1, 120 do
			-- Random direction in all directions
			local dir = VectorRand():GetNormalized()
			local dist = math.Rand(100, radius)
			local pos = origin + dir * dist
			
			local p = emitter:Add("effects/splash2", pos)
			if p then
				p:SetDieTime(math.Rand(1.0, 1.6))
				p:SetStartAlpha(math.Rand(200, 240))
				p:SetEndAlpha(0)
				p:SetStartSize(math.Rand(30, 50))
				p:SetEndSize(math.Rand(5, 15))
				p:SetRoll(math.Rand(0, 360))
				p:SetRollDelta(math.Rand(-10, 10))
				p:SetColor(210, 230, 250)
				p:SetVelocity(dir * math.Rand(1000, 1400))
				p:SetAirResistance(180)
				p:SetGravity(Vector(0, 0, -80))
			end
		end
		
		-- Dense dust cloud expanding outward
		for i = 1, 80 do
			local dir = VectorRand():GetNormalized()
			local dist = math.Rand(50, radius * 0.7)
			local pos = origin + dir * dist
			
			local p = emitter:Add("particle/particle_smokegrenade", pos)
			if p then
				p:SetDieTime(math.Rand(1.5, 2.5))
				p:SetStartAlpha(math.Rand(140, 200))
				p:SetEndAlpha(0)
				p:SetStartSize(math.Rand(40, 60))
				p:SetEndSize(math.Rand(80, 120))
				p:SetRoll(math.Rand(0, 360))
				p:SetRollDelta(math.Rand(-4, 4))
				p:SetColor(190, 190, 170)
				p:SetVelocity(dir * math.Rand(700, 1100) + Vector(0, 0, math.Rand(100, 200)))
				p:SetAirResistance(120)
				p:SetGravity(Vector(0, 0, math.Rand(-30, 10)))
			end
		end
		
		-- Sharp wind pressure waves
		for i = 1, 60 do
			local dir = VectorRand():GetNormalized()
			local dist = math.Rand(120, radius * 1.1)
			local pos = origin + dir * dist
			
			local p = emitter:Add("effects/blueflare1", pos)
			if p then
				p:SetDieTime(math.Rand(0.5, 1.0))
				p:SetStartAlpha(255)
				p:SetEndAlpha(0)
				p:SetStartSize(math.Rand(20, 35))
				p:SetEndSize(0)
				p:SetColor(230, 250, 255)
				p:SetVelocity(dir * math.Rand(1400, 1800))
				p:SetAirResistance(100)
				p:SetGravity(Vector(0, 0, 0))
			end
		end
		
		emitter:Finish()
		
		-- Central explosion effects
		local ed = EffectData()
		ed:SetOrigin(origin)
		ed:SetScale(radius * 0.5)
		util.Effect("cball_explode", ed, true, true)
		util.Effect("HelicopterMegaBomb", ed, true, true)
		
		-- Multiple expanding shockwave rings
		for i = 1, 3 do
			local ed2 = EffectData()
			ed2:SetOrigin(origin + Vector(0, 0, i * 20 - 20))
			ed2:SetNormal(Vector(0, 0, 1))
			ed2:SetScale(radius)
			util.Effect("ManhackSparks", ed2)
		end
	end)
end


