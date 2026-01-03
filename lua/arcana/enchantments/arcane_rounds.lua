if SERVER then
	util.AddNetworkString("Arcana_SpearBeam")
end

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

	local startPos = origin
	local maxDist = 2000
	local penetrations = 4
	local damagePerHit = 55
	local falloff = 0.8
	local traveled = 0

	local filter = {caster}
	local segments = {}

	for _ = 1, penetrations do
		local segStart = startPos
		local tr = util.TraceLine({
			start = startPos,
			endpos = startPos + dir * (maxDist - traveled),
			filter = filter,
			mask = MASK_SHOT
		})

		if not tr.Hit then break end
		local hitPos = tr.HitPos
		local hitEnt = tr.Entity

		table.insert(segments, {segStart, hitPos})

		-- Impact visuals
		local ed = EffectData()
		ed:SetOrigin(hitPos)
		util.Effect("cball_explode", ed, true, true)
		util.Decal("FadingScorch", hitPos + tr.HitNormal * 8, hitPos - tr.HitNormal * 8)

		-- Direct hit damage
		if IsValid(hitEnt) then
			local dmg = DamageInfo()
			dmg:SetDamage(damagePerHit)
			dmg:SetDamageType(bit.bor(DMG_DISSOLVE, DMG_ENERGYBEAM))
			dmg:SetAttacker(IsValid(caster) and caster or game.GetWorld())
			dmg:SetInflictor(IsValid(caster) and caster or game.GetWorld())
			dmg:SetDamagePosition(hitPos)
			hitEnt:TakeDamageInfo(dmg)
		end

		-- Small splash along the lance for feedback
		Arcane:BlastDamage(caster, caster, hitPos, 80, 18, DMG_DISSOLVE, true)

		-- Prepare for next penetration
		table.insert(filter, hitEnt or tr.Entity)
		startPos = hitPos + dir * 6
		traveled = traveled + tr.Fraction * (maxDist - traveled)
		damagePerHit = math.max(15, math.floor(damagePerHit * falloff))
	end

	-- Broadcast beam segments for client visuals
	if #segments > 0 then
		net.Start("Arcana_SpearBeam", true)
		net.WriteEntity(caster)
		net.WriteUInt(#segments, 8)
		for i = 1, #segments do
			net.WriteVector(segments[i][1])
			net.WriteVector(segments[i][2])
		end
		net.Broadcast()
	end

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


