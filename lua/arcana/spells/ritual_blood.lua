hook.Add("InitPostEntity", "arcana_blood_ritual", function()
	local ores = _G.ms and _G.ms.Ores
	if not ores then return end

	Arcane:RegisterRitualSpell({
		id = "ritual_of_blood",
		name = "Ritual: Blood",
		description = "A ritual that summons a dark entity.",
		category = Arcane.CATEGORIES.UTILITY,
		level_required = 12,
		knowledge_cost = 5,
		cooldown = 60 * 60,
		cost_type = Arcane.COST_TYPES.COINS,
		cost_amount = 100,
		cast_time = 10,
		cast_anim = "becon",
		ritual_color = Color(255, 0, 0),
		ritual_lifetime = 300,
		ritual_coin_cost = 5000,
		ritual_items = {
			poison = 20
		},
		on_activate = function(selfEnt, ply)
			ores.GivePlayerOre(ply, 666, 99)

			timer.Simple(0.5, function()
				if not IsValid(ply) then return end
				ores.GivePlayerOre(ply, 666, 1)
			end)

			sound.Play("ambient/halloween/female_scream_0" .. math.random(1, 9) .. ".wav", selfEnt:GetPos(), 100)
		end,
	})
end)