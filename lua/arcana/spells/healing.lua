Arcane:RegisterSpell({
	id = "healing",
	name = "Healing",
	description = "Restore a player's health.",
	category = Arcane.CATEGORIES.PROTECTION,
	level_required = 2,
	knowledge_cost = 2,
	cooldown = 8.0,
	cost_type = Arcane.COST_TYPES.COINS,
	cost_amount = 25,
	cast_time = 1.2,
	range = 400,
	icon = "icon16/heart_add.png",
	has_target = true,
	cast_anim = "forward",
	cast = function(caster, _, _, ctx)
		local target = caster:GetEyeTrace().Entity
		if not IsValid(target) or not target:IsPlayer() or not target:Alive() then return false end
		if target:Health() >= target:GetMaxHealth() then return false end
		if not SERVER then return true end
		-- Apply healing
		target:SetHealth(math.min(target:GetMaxHealth(), target:Health() + 40))
		-- Beautiful healing aura effect
		local healColor = Color(120, 255, 140, 255) -- Golden healing light
		local r = math.max(caster:OBBMaxs():Unpack()) * 0.5

		Arcane:SendAttachBandVFX(target, healColor, 26, 2.5, {
			{
				radius = r * 0.9,
				height = 3,
				spin = {
					p = 0,
					y = 35,
					r = 0
				},
				lineWidth = 2
			},
		})

		return true
	end
})