Arcane:RegisterSpell({
	id = "wind_sweep",
	name = "Wind Sweep",
	description = "Unleash a violent gust pushing foes away.",
	category = Arcane.CATEGORIES.COMBAT,
	level_required = 1,
	knowledge_cost = 1,
	cooldown = 5.0,
	cost_type = Arcane.COST_TYPES.COINS,
	cost_amount = 10,
	cast_time = 0.6,
	range = 500,
	icon = "icon16/flag_white.png",
	has_target = false,
	cast_anim = "forward",
	cast = function(caster, _, _, ctx)
		if not SERVER then return true end
		local origin = (ctx and ctx.circlePos) or caster:GetShootPos()
		local forward = caster:GetAimVector()
		local cone = math.cos(math.rad(30))
		local strength = 1500
		local radius = 400

		for _, ent in ipairs(ents.FindInSphere(origin, radius)) do
			if ent ~= caster and IsValid(ent) and (ent:IsPlayer() or ent:IsNPC() or ent:GetMoveType() == MOVETYPE_VPHYSICS) then
				local dir = (ent:WorldSpaceCenter() - origin):GetNormalized()

				if dir:Dot(forward) >= cone then
					if ent:IsPlayer() or ent:IsNPC() then
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

		sound.Play("ambient/wind/wind_snippet1.wav", caster:GetPos(), 75, 120)

		return true
	end
})