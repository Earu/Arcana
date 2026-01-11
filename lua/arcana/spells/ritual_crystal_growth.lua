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

		local targetPos = tr.Hit and tr.HitPos or ritualPos - Vector(0, 0, 80)
		local crystal = ents.Create("arcana_mana_crystal")
		if not IsValid(crystal) then
			Arcane:SendErrorNotification(ply, "Failed to create mana crystal.")
			return
		end

		crystal:Spawn()
		crystal:SetPos(targetPos)
		crystal:DropToFloor()
		crystal:PhysWake()

		-- Set it to a large scale (0.35 to 2.2 range, start at 1.8 for "big")
		if crystal.SetCrystalScale then
			crystal:SetCrystalScale(1.8)
		end

		-- Add some initial growth points so it's well-established
		if crystal.AddCrystalGrowth then
			crystal:AddCrystalGrowth(240) -- Near max growth
		end

		sound.Play("ambient/levels/labs/electric_explosion1.wav", spawnPos, 75, 120)

		-- Create a small shockwave effect
		timer.Simple(0.1, function()
			if IsValid(crystal) then
				util.ScreenShake(crystal:GetPos(), 5, 5, 1, 512)

				local tr = util.TraceLine({
					start = crystal:GetPos(),
					endpos = crystal:GetPos() - Vector(0, 0, 1000),
					mask = MASK_SOLID_BRUSHONLY,
				})

				if tr.Hit then
					crystal:SetPos(tr.HitPos) -- drop to floor after resizing properly
				end
			end
		end)
	end,
})
