if SERVER then
	hook.Add("Arcana_BeginCasting", "Healing_TargetScan", function(caster, spellId)
		if spellId ~= "healing" then return end
		Arcana.Common.TargetScan(caster, function(ent)
			return IsValid(ent) and ent:IsPlayer() and ent:Alive()
		end, 400)
	end)
end

Arcana:RegisterSpell({
	id = "healing",
	name = "Healing",
	description = "Restore a player's health.",
	category = Arcana.CATEGORIES.PROTECTION,
	level_required = 6,
	knowledge_cost = 2,
	cooldown = 8.0,
	cost_type = Arcana.COST_TYPES.COINS,
	cost_amount = 25,
	cast_time = 1.2,
	range = 400,
	has_target = true,
	cast_anim = "forward",
	cast = function(caster, _, _, ctx)
		if not IsValid(caster) then return false end

		local target = Arcana.Common.GetLockedTarget(caster)
		if not IsValid(target) or not target:IsPlayer() or not target:Alive() then return false end
		if target:Health() >= target:GetMaxHealth() then return false end
		if not SERVER then return true end

		-- Apply healing
		target:SetHealth(math.min(target:GetMaxHealth(), target:Health() + 40))

		local healColor = Color(120, 255, 140, 255)
		local r = math.max(caster:OBBMaxs():Unpack()) * 0.5

		Arcana:SendAttachBandVFX(target, healColor, 26, 2.5, {
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
	end,
	trigger_phrase_aliases = {
		"heal",
	}
})
