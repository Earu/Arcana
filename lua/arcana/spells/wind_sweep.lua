Arcane:RegisterSpell({
	id = "wind_sweep",
	name = "Wind Sweep",
	description = "Unleash a violent gust pushing foes away.",
	category = Arcane.CATEGORIES.COMBAT,
	level_required = 1,
	knowledge_cost = 1,
	cooldown = 4.0,
	cost_type = Arcane.COST_TYPES.COINS,
	cost_amount = 12,
	cast_time = 0.6,
	range = 500,
	icon = "icon16/flag_white.png",
	has_target = false,
	cast_anim = "forward",
	cast = function(caster, _, _, ctx)
		if not SERVER then return true end

		local srcEnt = IsValid(ctx.casterEntity) and ctx.casterEntity or caster
		local origin = ctx.circlePos or (srcEnt.EyePos and srcEnt:EyePos() or srcEnt:WorldSpaceCenter())
		local forward = srcEnt.GetAimVector and srcEnt:GetAimVector() or srcEnt:GetForward()
		local cone = math.cos(math.rad(30))
		local strength = 1500
		local radius = 400
		local baseDamage = 40

		for _, ent in ipairs(ents.FindInSphere(origin, radius)) do
			if ent ~= srcEnt and IsValid(ent) and (ent:IsPlayer() or ent:IsNPC() or ent:GetMoveType() == MOVETYPE_VPHYSICS) then
				local dir = (ent:WorldSpaceCenter() - origin):GetNormalized()

				if dir:Dot(forward) >= cone then
					if ent:IsPlayer() or ent:IsNPC() then
						-- Deal damage
						local dmg = DamageInfo()
						dmg:SetDamage(baseDamage)
						dmg:SetDamageType(DMG_SONIC)
						dmg:SetAttacker(IsValid(caster) and caster or game.GetWorld())
						dmg:SetInflictor(IsValid(srcEnt) and srcEnt or game.GetWorld())
						ent:TakeDamageInfo(dmg)

						ent:SetVelocity(forward * strength + Vector(0, 0, 120))
						ent:SetGroundEntity(NULL)
					else
						local phys = ent:GetPhysicsObject()
						if IsValid(phys) then
							phys:ApplyForceCenter(forward * (strength * phys:GetMass() * 0.5))
						end
					end
				end
			end
		end

		sound.Play("ambient/wind/wind_snippet1.wav", srcEnt:GetPos(), 75, 120)

		return true
	end
})