Arcane:RegisterRitualSpell({
	id = "ritual_of_crystal_growth",
	name = "Ritual: Crystal Growth",
	description = "A ritual that manifests a large mana crystal from concentrated arcane energy.",
	category = Arcane.CATEGORIES.UTILITY,
	level_required = 10,
	knowledge_cost = 3,
	cooldown = 60 * 20, -- 20 minutes
	cost_type = Arcane.COST_TYPES.COINS,
	cost_amount = 500,
	cast_time = 10,
	cast_anim = "becon",
	ritual_color = Color(55, 155, 255, 255),
	ritual_lifetime = 300,
	ritual_coin_cost = 10000,
	ritual_items = {
		mana_crystal_shard = 15
	},
	on_activate = function(selfEnt, ply, caster)
		if not SERVER then return end

		local ritualPos = selfEnt:GetPos()
		local tr = util.TraceLine({
			start = ritualPos,
			endpos = ritualPos - Vector(0, 0, 1000),
			mask = MASK_SOLID_BRUSHONLY,
		})

		local groundPos = tr.Hit and tr.HitPos or ritualPos - Vector(0, 0, 80)
		local normal = tr.HitNormal or Vector(0, 0, 1)

		local crystal = ents.Create("arcana_mana_crystal")
		if not IsValid(crystal) then
			Arcane:SendErrorNotification(ply, "Failed to create mana crystal.")
			return
		end

		-- Spawn 4 units above ground, like mana_crystals.lua does
		crystal:SetPos(groundPos + normal * 4)
		crystal:SetAngles(Angle(0, math.random(0, 359), 0))
		crystal:Spawn()
		crystal:DropToFloor()

		-- Set it to a large scale (0.35 to 2.2 range, start at 1.8 for "big")
		if crystal.SetCrystalScale then
			crystal:SetCrystalScale(1.8)
		end

		-- Add some initial growth points so it's well-established
		if crystal.AddCrystalGrowth then
			crystal:AddCrystalGrowth(240) -- Near max growth
		end

		sound.Play("ambient/levels/labs/electric_explosion1.wav", groundPos, 75, 120)

		-- Drop to floor again after 0.5 seconds (like mana_crystals.lua)
		-- This ensures proper positioning after physics/scale settle
		timer.Simple(0.5, function()
			if not IsValid(crystal) then return end
			crystal:DropToFloor()
			util.ScreenShake(crystal:GetPos(), 5, 5, 1, 512)
		end)
	end,
})
