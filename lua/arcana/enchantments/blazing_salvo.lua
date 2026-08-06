Arcana.RegisterEnchantment({
	id = "blazing_salvo",
	name = "Blazing Salvo",
	description = "Fires a fireball every second while shooting this weapon.",
	cost_coins = 1000,
	cost_items = {
		{ name = "mana_crystal_shard", amount = 30 },
	},
	can_apply = function(ply, wep)
		return Arcana.WeaponClassification.Get(wep) == "HITSCAN"
	end,
	on_shot_fired = function(ply, wep, data, state)
		-- rate limit using state
		local now = CurTime()
		state._next = state._next or 0
		if now < state._next then return end
		state._next = now + 1.0

		local fb = ents.Create("arcana_fireball")
		if not IsValid(fb) then return end

		local pos = ply:WorldSpaceCenter() + ply:GetForward() * 25
		fb:SetPos(pos)
		fb:Spawn()
		Arcana.Common.LaunchProjectile(fb, ply, ply:GetAimVector())

		if Arcana.SendAttachBandVFX then
			Arcana.SendAttachBandVFX(fb, Color(255, 150, 80, 255), 14, 6, {
				{ radius = 15, height = 4, spin = { p = 0, y = 80 * 50, r = 60 * 50 }, lineWidth = 2 },
				{ radius = 13, height = 3, spin = { p = 60 * 50, y = -45 * 50, r = 0 }, lineWidth = 2 },
			})
		end
	end,
})


