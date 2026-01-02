Arcane:RegisterSpell({
	id = "blackhole",
	name = "Blackhole",
	description = "Summons a very dangerous blackhole.",
	category = Arcane.CATEGORIES.COMBAT,
	level_required = 25,
	knowledge_cost = 10,
	cooldown = 60,
	cost_type = Arcane.COST_TYPES.COINS,
	cost_amount = 600000,
	cast_time = 6,
	range = 0,
	icon = "icon16/brick.png",
	cast_anim = "becon",
	has_target = false,
	is_projectile = false,
	cast = function(caster, _, _, ctx)
		if not SERVER then return true end

		local srcEnt = IsValid(ctx.casterEntity) and ctx.casterEntity or caster
		local targetPos = Arcane:ResolveGroundTarget(srcEnt, 1000)

		local blackhole = ents.Create("arcana_blackhole")
		blackhole:SetPos(targetPos + Vector(0, 0, 200))
		blackhole:Spawn()
		srcEnt:EmitSound("ambient/levels/citadel/portal_beam_shoot" .. math.random(1, 6) .. ".wav", 100, 80)

		if blackhole.CPPISetOwner then
			blackhole:CPPISetOwner(caster)
		end

		SafeRemoveEntityDelayed(blackhole, 20)

		return true
	end
})

if CLIENT then
	hook.Add("Arcana_BeginCastingVisuals", "Arcana_Blackhole_Circle", function(caster, spellId, castTime, _forwardLike)
		if spellId ~= "blackhole" then return end

		return Arcane:CreateFollowingCastCircle(caster, spellId, castTime, {
			color = Color(100, 50, 200, 255),
			size = 300,
			intensity = 100,
			positionResolver = function(c)
				return Arcane:ResolveGroundTarget(c, 1000)
			end
		})
	end)
end