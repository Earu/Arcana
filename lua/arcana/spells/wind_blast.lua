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

		-- Simple ring VFX via existing frost-style ring but recolored using wind sounds
		local ed = EffectData()
		ed:SetOrigin(origin)
		util.Effect("cball_explode", ed, true, true)
		srcEnt:EmitSound("ambient/wind/wind_hit1.wav", 75, 120)
		sound.Play("ambient/levels/labs/teleport_mechanism_winddown2.wav", origin, 70, 140)
		util.ScreenShake(origin, 7, 80, 0.3, 700)

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


