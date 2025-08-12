hook.Add("InitPostEntity", "arcana_blood_ritual", function()
	local ores = _G.ms and _G.ms.Ores
	if not ores then return end

	Arcane:RegisterSpell({
		id = "blood_ritual",
		name = "Ritual: Blood",
		description = "A ritual that summons a dark entity.",
		category = Arcane.CATEGORIES.UTILITY,
		level_required = 15,
		knowledge_cost = 1,
		cooldown = 60 * 60, -- 1 hour
		cost_type = Arcane.COST_TYPES.COINS,
		cost_amount = 100, -- cost is in the ritual requirements itself
		cast_time = 10,
		has_target = false,
		cast_anim = "becon",
		can_cast = function(caster)
			if not IsValid(caster) then return false, "Invalid caster" end
			return true
		end,
		cast = function(caster)
			if CLIENT then return true end
			local pos = caster:GetEyeTrace().HitPos
			local ent = ents.Create("arcana_ritual")
			if not IsValid(ent) then return false end

			ent:SetPos(pos)
			ent:SetAngles(Angle(0, caster:EyeAngles().y, 0))
			ent:SetColor(Color(255, 0, 0))
			ent:Spawn()
			ent:Activate()

			ent:Configure({
				id = "ritual_of_blood",
				owner = caster,
				lifetime = 300,
				coin_cost = 5000,
				items = {
					poison = 20,
				},
				on_activate = function(_, ply)
					ores.GivePlayerOre(ply, 666, 100)
					ply:EmitSound("ambient/halloween/female_scream_0" .. math.random(1, 10) .. ".wav", 100)
				end,
			})

			return true
		end,
	})
end)