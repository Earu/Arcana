Arcana:RegisterRitualSpell({
	id = "ritual_of_ward",
	name = "Ritual: Ward",
	description = "Erect an invisible magical ward that repels anything not already within the protected area. Bullets, props, creatures, and players are all turned away at the boundary.",
	category = Arcana.CATEGORIES.PROTECTION,
	level_required = 18,
	knowledge_cost = 5,
	cooldown = 60 * 15,
	cost_type = Arcana.COST_TYPES.COINS,
	cost_amount = 5000,
	cast_time = 10.0,
	cast_anim = "becon",
	ritual_color = Color(160, 100, 240, 255),
	ritual_lifetime = 300,
	ritual_coin_cost = 8000,
	ritual_items = {
		mana_crystal_shard = 20,
		battery = 5,
	},
	ritual_replenishable = true,
	ritual_replenish_cost = 2000,
	on_activate = function(selfEnt, ply, caster)
		if not SERVER then return end

		local ward = ents.Create("arcana_ward")
		if not IsValid(ward) then return end

		ward:SetPos(selfEnt:GetPos())
		ward:Spawn()
		ward:Activate()

		-- CaptureAllowed does a one-shot FindInSphere to snapshot who is inside
		ward:CaptureAllowed()

		selfEnt._ward = ward
		selfEnt:DeleteOnRemove(ward)

		selfEnt:EmitSound("ambient/levels/citadel/strange_talk5.wav", 70, 130)
	end,
	on_replenish = function(selfEnt, ply, caster)
		-- The ward entity is tied to the ritual via DeleteOnRemove;
		-- its protection continues automatically as long as the ritual lives.
	end,
})
