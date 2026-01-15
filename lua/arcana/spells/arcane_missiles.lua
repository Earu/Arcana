-- Arcane Missiles: Launch three homing projectiles that prefer the target closest to the caster's aim
Arcane:RegisterSpell({
	id = "arcane_missiles",
	name = "Arcane Missiles",
	description = "Launch three homing bolts that seek your aimed target.",
	category = Arcane.CATEGORIES.COMBAT,
	level_required = 13,
	knowledge_cost = 4,
	cooldown = 6.0,
	cost_type = Arcane.COST_TYPES.COINS,
	cost_amount = 55,
	cast_time = 0.7,
	range = 1200,
	icon = "icon16/wand.png",
	has_target = true,
	is_projectile = true,
	cast_anim = "forward",
	cast = function(caster, _, _, ctx)
		if not SERVER then return true end

		local srcEnt = IsValid(ctx.casterEntity) and ctx.casterEntity or caster
		local origin = (ctx and ctx.circlePos) or (srcEnt.EyePos and srcEnt:EyePos() or srcEnt:WorldSpaceCenter())
		local aim = srcEnt.GetAimVector and srcEnt:GetAimVector() or srcEnt:GetForward()

		-- Launch missiles using shared API
		Arcane.Common.LaunchMissiles(caster, origin, aim, {
			count = 3,
			delay = 0.06
		})

		return true
	end,
	trigger_phrase_aliases = {
		"missiles",
		"missile",
	}
})