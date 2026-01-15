Arcane:RegisterSpell({
	id = "lightning_orb",
	name = "Lightning Orb",
	description = "Launch a slow-moving orb of electricity that zaps nearby foes and detonates on impact.",
	category = Arcane.CATEGORIES.COMBAT,
	level_required = 15,
	knowledge_cost = 3,
	cooldown = 10.0,
	cost_type = Arcane.COST_TYPES.COINS,
	cost_amount = 160,
	cast_time = 1.2,
	range = 1400,
	icon = "icon16/weather_lightning.png",
	is_projectile = true,
	has_target = true,
	cast_anim = "forward",
	cast = function(caster, _, _, ctx)
		if not SERVER then return true end

		local srcEnt = IsValid(ctx.casterEntity) and ctx.casterEntity or caster
		local startPos
		if ctx.circlePos then
			startPos = ctx.circlePos + srcEnt:GetForward() * 8
		else
			startPos = srcEnt:WorldSpaceCenter() + srcEnt:GetForward() * 28
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
			ent:LaunchTowards(srcEnt.GetAimVector and srcEnt:GetAimVector() or srcEnt:GetForward())
		end

		-- Brief casting VFX on the caster
		Arcane:SendAttachBandVFX(srcEnt, Color(170, 210, 255, 255), 26, 0.8, {
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

		sound.Play("ambient/levels/labs/electric_explosion" .. math.random(1, 5) .. ".wav", srcEnt:GetPos(), 80, 110)
		sound.Play("weapons/physcannon/physcannon_charge.wav", srcEnt:GetPos(), 75, 140)

		timer.Simple(0.05, function()
			sound.Play("weapons/physcannon/energy_sing_flyby1.wav", srcEnt:GetPos(), 70, 120)
		end)

		return true
	end
})