Arcane:RegisterSpell({
	id = "regeneration",
	name = "Regeneration",
	description = "Gradually heal over time",
	category = Arcane.CATEGORIES.PROTECTION,
	level_required = 1,
	knowledge_cost = 1,
	cooldown = 10.0,
	cost_type = Arcane.COST_TYPES.COINS,
	cost_amount = 15,
	cast_time = 0.5,
	range = 0,
	icon = "icon16/heart.png",
	cast_anim = "becon",

	cast = function(caster, _, _, ctx)
		if not SERVER then return true end

		local duration = 20
		local perTick = 5
		local id = "Arcana_Regeneration_" .. caster:SteamID64()
		local endTime = CurTime() + duration

		timer.Create(id, 1, duration, function()
			if not IsValid(caster) then return end
			local new = math.min(caster:GetMaxHealth(), caster:Health() + perTick)
			caster:SetHealth(new)
			if CurTime() >= endTime or not IsValid(caster) then
				timer.Remove(id)
			end
		end)

		-- Subtle VFX band
		local r = math.max(caster:OBBMaxs():Unpack()) * 0.5
		Arcane:SendAttachBandVFX(caster, Color(120, 255, 140, 255), 32, duration, {
			{ radius = r * 0.9, height = 3, spin = {p = 0, y = 35, r = 0}, lineWidth = 2 },
		})

		caster:EmitSound("items/smallmedkit1.wav", 70, 120)
		return true
	end
})


