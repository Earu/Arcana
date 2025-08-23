Arcane:RegisterSpell({
	id = "lightning_orb",
	name = "Lightning Orb",
	description = "Launch a slow-moving orb of electricity that zaps nearby foes and detonates on impact.",
	category = Arcane.CATEGORIES.COMBAT,
	level_required = 15,
	knowledge_cost = 3,
	cooldown = 10.0,
	cost_type = Arcane.COST_TYPES.COINS,
	cost_amount = 200,
	cast_time = 1.2,
	range = 1400,
	icon = "icon16/weather_lightning.png",
	is_projectile = true,
	has_target = true,
	cast_anim = "forward",
	can_cast = function(caster)
		if caster:InVehicle() then return false, "Cannot cast while in a vehicle" end

		return true
	end,
	cast = function(caster, _, _, ctx)
		if not SERVER then return true end
		local startPos

		if ctx and ctx.circlePos then
			startPos = ctx.circlePos + caster:GetForward() * 8
		else
			startPos = caster:WorldSpaceCenter() + caster:GetForward() * 28
		end

		local ent = ents.Create("arcana_lightning_orb")
		if not IsValid(ent) then return false end
		ent:SetPos(startPos)
		ent:SetSpellOwner(caster)
		ent:Spawn()
		ent:Activate()

		if ent.CPPISetOwner then
			ent:CPPISetOwner(caster)
		end

		if ent.LaunchTowards then
			ent:LaunchTowards(caster:GetAimVector())
		end

		-- Brief casting VFX on the caster
		Arcane:SendAttachBandVFX(caster, Color(170, 210, 255, 255), 26, 0.8, {
			{
				radius = 20,
				height = 6,
				spin = {
					p = 0,
					y = 45,
					r = 0
				},
				lineWidth = 2
			},
		})

		caster:EmitSound("ambient/energy/zap" .. math.random(1, 9) .. ".wav", 75, math.random(110, 130))

		return true
	end
})