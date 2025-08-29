Arcane:RegisterRitualSpell({
	id = "purification_ritual",
	name = "Ritual: Purification",
	description = "Perform a ritual to cleanse corruption in the area.",
	category = Arcane.CATEGORIES.PROTECTION,
	level_required = 5,
	knowledge_cost = 3,
	cooldown = 25,
	cost_type = Arcane.COST_TYPES.COINS,
	cost_amount = 6000,
	cast_time = 10.0,
	on_activate = function(selfEnt, activatingPly, caster)
		if not SERVER then return end
		local center = selfEnt:GetPos()
		local radius = 2000
		local entsInRange = ents.FindInSphere(center, radius)
		local reduced = 0
		for _, e in ipairs(entsInRange) do
			if IsValid(e) and e:GetClass() == "arcana_corrupted_area" then
				local cur = e.GetIntensity and (e:GetIntensity() or 0) or 0
				if cur > 0 then
					local newI = math.max(0, cur - 0.5)
					e:SetIntensity(math.Clamp(newI, 0, 2))
					reduced = reduced + (cur - newI)
				end
			end
		end
		-- Small visual feedback
		if reduced > 0 then
			selfEnt:EmitSound("ambient/levels/citadel/strange_talk5.wav", 70, 110)
		else
			selfEnt:EmitSound("buttons/button8.wav", 60, 120)
		end
	end,
})
