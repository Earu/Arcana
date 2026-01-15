Arcane:RegisterSpell({
	id = "arcane_spear",
	name = "Arcane Spear",
	description = "Project a powerful lance of arcane energy that deals massive damage.",
	category = Arcane.CATEGORIES.COMBAT,
	level_required = 12,
	knowledge_cost = 3,
	cooldown = 3.0,
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

		local srcEnt = IsValid(ctx.casterEntity) and ctx.casterEntity or caster
		local startPos = srcEnt:WorldSpaceCenter() -- because eyepos is weird
		local dir = srcEnt.GetAimVector and srcEnt:GetAimVector() or srcEnt:GetForward()

		-- Fire the arcane spear beam
		Arcane.Common.SpearBeam(caster, startPos, dir, {
			maxDist = 2000,
			damage = 65,
			splashRadius = 100,
			splashDamage = 18,
			filter = {srcEnt, caster}
		})

		-- Play sound effects
		caster:EmitSound("arcana/arcane_1.ogg", 80, 120)
		caster:EmitSound("arcana/arcane_2.ogg", 80, 120)
		caster:EmitSound("weapons/physcannon/superphys_launch1.wav", 80, 120)

		return true
	end,
	trigger_phrase_aliases = {
		"spear",
	}
})