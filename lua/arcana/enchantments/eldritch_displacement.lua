local function isMeleeHoldType(wep)
	if not IsValid(wep) then return false end

	local ht = (wep.GetHoldType and wep:GetHoldType()) or wep.HoldType
	if not isstring(ht) then return false end

	ht = string.lower(ht)
	return ht == "melee" or ht == "melee2" or ht == "knife" or ht == "fist"
end

local function findSafeTeleportPos(ply, origin, radius)
	-- Try multiple candidates in a circle around origin
	local hullMins = Vector(-16, -16, 0)
	local hullMaxs = Vector(16, 16, 72)
	for i = 1, 12 do
		local ang = math.rad(math.Rand(0, 360))
		local dist = math.Rand(radius * 0.4, radius)
		local offset = Vector(math.cos(ang) * dist, math.sin(ang) * dist, 0)
		local base = origin + offset

		-- Trace down to ground
		local trDown = util.TraceHull({
			start = base + Vector(0, 0, 64),
			endpos = base - Vector(0, 0, 160),
			mins = hullMins,
			maxs = hullMaxs,
			filter = ply,
			mask = MASK_PLAYERSOLID
		})
		if trDown.Hit and not trDown.StartSolid and not trDown.AllSolid then
			local candidate = trDown.HitPos

			-- Final clearance check at candidate
			local trClear = util.TraceHull({
				start = candidate + Vector(0, 0, 1),
				endpos = candidate + Vector(0, 0, 1),
				mins = hullMins,
				maxs = hullMaxs,
				filter = ply,
				mask = MASK_PLAYERSOLID
			})
			if not trClear.Hit and not trClear.StartSolid and not trClear.AllSolid then
				return candidate
			end
		end
	end
	return nil
end

local function blinkVFX(fromPos, toPos, ply)
	-- Origin effect
	local ed1 = EffectData()
	ed1:SetOrigin(fromPos)
	util.Effect("cball_explode", ed1, true, true)
	sound.Play("weapons/physcannon/energy_bounce1.wav", fromPos, 70, 120)

	-- Destination effect
	local ed2 = EffectData()
	ed2:SetOrigin(toPos)
	util.Effect("cball_bounce", ed2, true, true)
	sound.Play("weapons/physcannon/energy_bounce2.wav", toPos, 70, 120)

	-- Brief band ring
	if Arcane and Arcane.SendAttachBandVFX and IsValid(ply) then
		local r = math.max(ply:OBBMaxs():Unpack()) * 0.55
		Arcane:SendAttachBandVFX(ply, Color(196, 160, 255), 26, 0.4, {
			{ radius = r * 0.9, height = 4, spin = { p = 0, y = 180, r = 0 }, lineWidth = 2 },
			{ radius = r * 0.7, height = 3, spin = { p = 0, y = -220, r = 0 }, lineWidth = 2 },
		}, "eldritch_displacement_fx")
	end
end

local function attachHook(ply, wep, state)
	if not IsValid(ply) or not IsValid(wep) then return end

	state._hookId = string.format("Arcana_Ench_EldritchDisplacement_%d_%d", wep:EntIndex(), ply:EntIndex())
	state._nextAllowed = 0

	-- When the wielder takes damage from others, blink to a random safe spot, keep aim
	hook.Add("EntityTakeDamage", state._hookId, function(victim, dmginfo)
		if not IsValid(victim) or victim ~= ply then return end
		local now = CurTime()
		if now < (state._nextAllowed or 0) then return end

		-- Must be wielding this melee weapon
		local active = ply:GetActiveWeapon()
		if not IsValid(active) or active ~= wep or not isMeleeHoldType(wep) then return end

		-- Ignore self-damage only; trigger on any non-self source (including world)
		local attacker = dmginfo:GetAttacker()
		if IsValid(attacker) and attacker == ply then return end

		-- Compute destination
		local origin = ply:GetPos()
		local radius = 280
		local dest = findSafeTeleportPos(ply, origin, radius)
		if not dest then return end

		-- Preserve the world look target: compute a far point along current view, then aim at it after teleport
		local shootPos = ply:EyePos()
		local aimDir = ply:EyeAngles():Forward()
		local trLook = util.TraceLine({
			start = shootPos,
			endpos = shootPos + aimDir * 8192,
			filter = ply,
			mask = MASK_SHOT
		})
		local lookPoint = trLook.Hit and trLook.HitPos or (shootPos + aimDir * 8192)

		-- Teleport and stop residual velocity
		ply:SetPos(dest + Vector(0, 0, 2))
		ply:SetLocalVelocity(vector_origin)

		-- Re-aim towards the same world point we were looking at pre-blink
		local newShootPos = ply:EyePos()
		local toPoint = (lookPoint - newShootPos)
		local targetAng = toPoint:Angle()
		targetAng.r = 0
		ply:SetEyeAngles(targetAng)

		-- Reassert next tick to fight view punch/prediction adjustments
		timer.Simple(0, function()
			if IsValid(ply) then
				ply:SetEyeAngles(targetAng)
			end
		end)

		blinkVFX(origin, dest, ply)
		state._nextAllowed = now + 1.25
	end)
end

local function detachHook(ply, wep, state)
	if not state or not state._hookId then return end
	hook.Remove("EntityTakeDamage", state._hookId)
	state._hookId = nil
end

Arcane:RegisterEnchantment({
	id = "eldritch_displacement",
	name = "Eldritch Displacement",
	description = "On taking damage from others, blink to a random nearby spot and keep your aim.",
	icon = "icon16/arrow_refresh.png",
	cost_coins = 1100,
	cost_items = {
		{ name = "mana_crystal_shard", amount = 45 },
	},
	can_apply = function(ply, wep)
		return IsValid(wep) and isMeleeHoldType(wep)
	end,
	apply = attachHook,
	remove = detachHook,
})