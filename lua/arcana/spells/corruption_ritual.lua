Arcane:RegisterRitualSpell({
	id = "corruption_ritual",
	name = "Ritual: Corruption",
	description = "Perform a ritual that increases corruption nearby or creates a new corrupted area.",
	category = Arcane.CATEGORIES.UTILITY,
	level_required = 17,
	knowledge_cost = 6,
	cooldown = 60 * 20,
	cost_type = Arcane.COST_TYPES.COINS,
	cost_amount = 100,
	cast_time = 10.0,
	cast_anim = "becon",
	ritual_color = Color(0, 0, 0, 255),
	ritual_lifetime = 300,
	ritual_coin_cost = 4000,
	ritual_items = {
		poison = 20,
		radioactive = 10,
	},
	on_activate = function(selfEnt, activatingPly, caster)
		if not SERVER then return end
		local center = selfEnt:GetPos()
		local searchRadius = 4000
		local best
		local bestDist
		for _, e in ipairs(ents.FindInSphere(center, searchRadius)) do
			if IsValid(e) and e:GetClass() == "arcana_corrupted_area" then
				local d = e:GetPos():DistToSqr(center)
				if not best or d < bestDist then
					best = e
					bestDist = d
				end
			end
		end

		if IsValid(best) then
			best:SetIntensity(2)
			selfEnt:EmitSound("ambient/levels/citadel/strange_talk5.wav", 70, 90)
			return
		end

		-- None found nearby, create a new corrupted area on the ground under the ritual
		local tr = util.TraceLine({
			start = center + Vector(0, 0, 256),
			endpos = center - Vector(0, 0, 2048),
			mask = MASK_SOLID_BRUSHONLY,
			filter = selfEnt
		})

		local pos = tr.Hit and tr.HitPos + Vector(0, 0, 2) or (center + Vector(0, 0, 2))
		local area = ents.Create("arcana_corrupted_area")
		if not IsValid(area) then return end

		area:SetPos(pos)
		area:Spawn()
		area:SetRadius(2000)
		area:SetIntensity(2)

		selfEnt:EmitSound("ambient/levels/citadel/strange_talk5.wav", 70, 90)
	end,
})


