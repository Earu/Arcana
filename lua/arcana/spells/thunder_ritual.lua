Arcane:RegisterSpell({
	id = "ritual_of_thunder",
	name = "Ritual: Thunder",
	description = "A ritual that summons a thunder cloud.",
	category = Arcane.CATEGORIES.UTILITY,
	level_required = 5,
	knowledge_cost = 1,
	cooldown = 60 * 10, -- 10 minutes
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
		ent:SetColor(Color(170, 200, 255, 255))
		ent:Spawn()
		ent:Activate()

		if ent.CPPISetOwner then
			ent:CPPISetOwner(caster)
		end

		ent:Configure({
			id = "ritual_of_thunder",
			owner = caster,
			lifetime = 300,
			coin_cost = 1000,
			items = {
				battery = 10,
			},
			on_activate = function(selfEnt, ply)
				local tr = util.TraceLine({
					start = selfEnt:GetPos(),
					endpos = selfEnt:GetPos() + Vector(0, 0, 500),
					mask = MASK_PLAYERSOLID_BRUSHONLY,
					filter = selfEnt
				})

				local thunder = ents.Create("arcana_lightning_storm")
				thunder:SetPos(tr.HitPos)
				thunder:Spawn()

				SafeRemoveEntityDelayed(thunder, 60 * 5)
			end,
		})

		return true
	end,
})
