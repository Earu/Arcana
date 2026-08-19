-- Arcana Missiles Rounds: On firearm shot, launch three homing arcane missiles toward your aim
-- Adapted from spells/arcane_missiles.lua
Arcana.RegisterEnchantment({
	id = "seeking_salvo",
	name = "Seeking Salvo",
	description = "On shot, launches three homing arcane missiles toward your aim.",
	cost_coins = 1500,
	cost_items = {
		{ name = "mana_crystal_shard", amount = 60 },
		{ name = "arcane_dust", amount = 10 },
	},
	can_apply = function(ply, wep)
		-- Ranged hitscan firearms, with or without real bullets (exclude melee)
		return Arcana.WeaponClassification.Get(wep) == "HITSCAN"
	end,
	on_shot_fired = function(ply, wep, data, state)
		-- Rate limit to avoid excessive missile spam on very high ROF weapons
		local now = CurTime()
		state._next = state._next or 0
		if now < state._next then return end
		state._next = now + 0.6

		local origin = ply:GetShootPos()
		local aim = ply:GetAimVector()

		-- Launch missiles using shared API
		Arcana.Common.LaunchMissiles(ply, origin, aim, {
			count = 3,
			delay = 0.06
		})
	end,
})


