-- Arcana Missiles Rounds: On firearm shot, launch three homing arcane missiles toward your aim
-- Adapted from spells/arcane_missiles.lua and existing enchantment hook patterns
local function attachHook(ply, wep, state)
	if not IsValid(ply) or not IsValid(wep) then return end

	state._hookId = string.format("Arcana_Ench_SeekingSalvo_%d_%d", wep:EntIndex(), ply:EntIndex())
	hook.Add("EntityFireBullets", state._hookId, function(ent, data)
		if not IsValid(ent) or not ent:IsPlayer() then return end

		local active = ent:GetActiveWeapon()
		if not IsValid(active) or active ~= wep then return end

		-- Rate limit to avoid excessive missile spam on very high ROF weapons
		local now = CurTime()
		state._next = state._next or 0
		if now < state._next then return end
		state._next = now + 0.6

		local caster = ent
		local origin = caster:GetShootPos()
		local aim = caster:GetAimVector()

		-- Launch missiles using shared API
		Arcana.Common.LaunchMissiles(caster, origin, aim, {
			count = 3,
			delay = 0.06
		})
	end)
end

local function detachHook(ply, wep, state)
	if not state or not state._hookId then return end
	hook.Remove("EntityFireBullets", state._hookId)
	state._hookId = nil
end

Arcana:RegisterEnchantment({
	id = "seeking_salvo",
	name = "Seeking Salvo",
	description = "On shot, launches three homing arcane missiles toward your aim.",
	cost_coins = 1500,
	cost_items = {
		{ name = "mana_crystal_shard", amount = 60 },
	},
	can_apply = function(ply, wep)
		-- Firearms that can shoot bullets (exclude melee)
		return Arcana.Common.GetWeaponClassification(wep) == "HITSCAN"
	end,
	apply = attachHook,
	remove = detachHook,
})


