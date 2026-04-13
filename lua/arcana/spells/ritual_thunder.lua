Arcana:RegisterRitualSpell({
	id = "ritual_of_thunder",
	name = "Ritual: Thunder",
	description = "A ritual that summons a thunder cloud.",
	category = Arcana.CATEGORIES.UTILITY,
	level_required = 5,
	knowledge_cost = 1,
	cooldown = 60 * 10,
	cost_type = Arcana.COST_TYPES.COINS,
	cost_amount = 100,
	cast_time = 10,
	cast_anim = "becon",
	ritual_color = Color(170, 200, 255, 255),
	ritual_lifetime = 300,
	ritual_coin_cost = 1000,
	ritual_items = {
		battery = 10
	},
	ritual_replenishable = true,
	ritual_replenish_cost = 500,
	on_activate = function(selfEnt, ply, caster)
		local tr = util.TraceLine({
			start = selfEnt:GetPos(),
			endpos = selfEnt:GetPos() + Vector(0, 0, 500),
			mask = MASK_PLAYERSOLID_BRUSHONLY,
			filter = selfEnt
		})

		local thunder = ents.Create("arcana_lightning_storm")
		thunder:SetPos(tr.HitPos)
		thunder:Spawn()

		if thunder.CPPISetOwner then
			local owner = IsValid(caster) and caster or ply

			if IsValid(owner) and owner:IsPlayer() then
				thunder:CPPISetOwner(owner)
			end
		end

		selfEnt._stormEntity = thunder
		selfEnt:DeleteOnRemove(thunder)
	end,
	on_replenish = function(selfEnt, ply, caster)
	end,
})