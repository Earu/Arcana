local function isMeleeHoldType(wep)
	if not IsValid(wep) then return false end

	local ht = (wep.GetHoldType and wep:GetHoldType()) or wep.HoldType
	if not isstring(ht) then return false end

	ht = string.lower(ht)
	return ht == "melee" or ht == "melee2" or ht == "knife" or ht == "fist"
end

local function igniteTarget(attacker, target)
	if not IsValid(target) then return end

	-- Ignite for 3 seconds; scale low to avoid griefing players too much
	local dur = 3
	if target.Ignite then
		target:Ignite(dur, 8)
	end

	-- Brief visual ring on target
	if Arcane and Arcane.SendAttachBandVFX then
		Arcane:SendAttachBandVFX(target, Color(255, 140, 80, 255), 20, 0.5, {
			{ radius = 14, height = 4, spin = { p = 0, y = 120 * 50, r = 0 }, lineWidth = 2 },
		}, "ignite_fx")
	end
end

local function attachIgniteHook(ply, wep, state)
	if not IsValid(ply) or not IsValid(wep) then return end

	state._hookId = string.format("Arcana_Ench_SearingStrikes_%d_%d", wep:EntIndex(), ply:EntIndex())
	hook.Add("EntityTakeDamage", state._hookId, function(victim, dmginfo)
		if not IsValid(victim) then return end

		local attacker = dmginfo and dmginfo:GetAttacker()
		if not IsValid(attacker) or not attacker:IsPlayer() then return end

		local active = attacker:GetActiveWeapon()
		if not IsValid(active) or active ~= wep then return end

		-- Only for melee weapons
		if not isMeleeHoldType(wep) then return end

		-- Filter out bullet/projectile damage: prefer club/slash or generic close-range
		-- some weird knives use DMG_NEVERGIB
		local dtype = dmginfo:GetDamageType()
		local isMelee = bit.band(dtype, DMG_CLUB) ~= 0 or bit.band(dtype, DMG_SLASH) ~= 0 or bit.band(dtype, DMG_BURN) ~= 0 or bit.band(dtype, DMG_NEVERGIB) ~= 0
		if not isMelee then return end

		igniteTarget(attacker, victim)
	end)
end

local function detachIgniteHook(ply, wep, state)
	if not state or not state._hookId then return end

	hook.Remove("EntityTakeDamage", state._hookId)
	state._hookId = nil
end

Arcane:RegisterEnchantment({
	id = "searing_strikes",
	name = "Searing Strikes",
	description = "Melee hits ignite targets for 3 seconds.",
	icon = "icon16/fire.png",
	cost_coins = 300,
	cost_items = {
		{ name = "mana_crystal_shard", amount = 12 },
	},
	can_apply = function(ply, wep)
		return IsValid(wep) and isMeleeHoldType(wep)
	end,
	apply = attachIgniteHook,
	remove = detachIgniteHook,
})
