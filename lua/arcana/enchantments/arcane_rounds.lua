local function isMeleeHoldType(wep)
	if not IsValid(wep) then return false end

	local ht = (wep.GetHoldType and wep:GetHoldType()) or wep.HoldType
	if not isstring(ht) then return false end

	ht = string.lower(ht)
	return ht == "melee" or ht == "melee2" or ht == "knife" or ht == "fist"
end

-- Fire an arcane spear beam starting from a given origin and along a direction
local function fireArcaneSpear(caster, origin, dir)
	if not SERVER then return end
	if not IsValid(caster) then return end

	-- Use the shared spear beam API
	Arcane.Common.SpearBeam(caster, origin, dir, {
		maxDist = 2000,
		damage = 55,
		splashRadius = 80,
		splashDamage = 18,
		filter = {caster}
	})

	caster:EmitSound("arcana/arcane_1.ogg", 70, 120)
end

local function attachHook(ply, wep, state)
	if not IsValid(ply) or not IsValid(wep) then return end

	-- Angle accumulator to place spear origins around the player in a ring
	state._angle = math.Rand(0, math.pi * 2)
	state._hookId = string.format("Arcana_Ench_ArcaneRounds_%d_%d", wep:EntIndex(), ply:EntIndex())
	hook.Add("EntityFireBullets", state._hookId, function(ent, data)
		if not IsValid(ent) or not ent:IsPlayer() then return end

		local active = ent:GetActiveWeapon()
		if not IsValid(active) or active ~= wep then return end

		local num = math.max(1, tonumber(data.Num or 1) or 1)
		local caster = ent
		local forward = caster:GetAimVector()
		local right = caster:GetRight()
		local up = caster:GetUp()
		local center = caster:WorldSpaceCenter()
		local ringRadius = 26

		for i = 1, num do
			state._angle = (state._angle or 0) + math.pi * 0.38 -- ~68.4° step to distribute
			local ca = math.cos(state._angle)
			local sa = math.sin(state._angle)
			local origin = center + right * (ca * ringRadius) + forward * (sa * ringRadius) + up * 8
			fireArcaneSpear(caster, origin, forward)
		end
	end)
end

local function detachHook(ply, wep, state)
	if not state or not state._hookId then return end
	hook.Remove("EntityFireBullets", state._hookId)
	state._hookId = nil
end

Arcane:RegisterEnchantment({
	id = "arcane_rounds",
	name = "Arcane Rounds",
	description = "Each bullet also launches an arcane spear from around you.",
	icon = "icon16/bullet_blue.png",
	cost_coins = 1800,
	cost_items = {
		{ name = "mana_crystal_shard", amount = 70 },
	},
	can_apply = function(ply, wep)
		-- Only firearms that can shoot bullets
		return IsValid(wep) and (wep.Primary ~= nil or wep.FireBullets ~= nil) and not isMeleeHoldType(wep)
	end,
	apply = attachHook,
	remove = detachHook,
})


