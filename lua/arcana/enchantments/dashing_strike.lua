local function isMeleeHoldType(wep)
	if not IsValid(wep) then return false end

	local ht = (wep.GetHoldType and wep:GetHoldType()) or wep.HoldType
	if not isstring(ht) then return false end

	ht = string.lower(ht)
	return ht == "melee" or ht == "melee2" or ht == "knife" or ht == "fist"
end

local function attachDashHook(ply, wep, state)
	if not IsValid(ply) or not IsValid(wep) then return end

	state._hookId = string.format("Arcana_Ench_DashingStrikes_%d_%d", wep:EntIndex(), ply:EntIndex())
	state._nextAllowed = 0
	state._thinkId = state._hookId .. "_Think"
	state._landHookId = state._hookId .. "_Land"
	state._impact = nil

	-- Server-only: impact after a short delay, on landing (or immediately if already grounded)
	if SERVER then
		local function applyImpact()
			if not state._impact or state._impact.applied then return end
			local impactPos = ply:GetPos()
			local radius = 110
			local baseDamage = 20
			if istable(wep.Primary) and isnumber(wep.Primary.Damage) then
				baseDamage = math.Clamp(wep.Primary.Damage, 10, 40)
			end
			if ply.LagCompensation then ply:LagCompensation(true) end
			for _, ent in ipairs(ents.FindInSphere(impactPos, radius)) do
				if IsValid(ent) and ent ~= ply and (ent:IsPlayer() or ent:IsNPC() or ent:IsNextBot()) then
					local dmg = DamageInfo()
					dmg:SetDamage(baseDamage)
					dmg:SetDamageType(bit.bor(DMG_CLUB, DMG_CRUSH))
					dmg:SetAttacker(ply)
					dmg:SetInflictor(IsValid(wep) and wep or ply)
					dmg:SetDamagePosition(ent:WorldSpaceCenter())
					ent:TakeDamageInfo(dmg)
				end
			end
			if ply.LagCompensation then ply:LagCompensation(false) end
			local ed = EffectData()
			ed:SetOrigin(impactPos)
			util.Effect("cball_explode", ed, true, true)
			util.Effect("ManhackSparks", ed, true, true)
			sound.Play("npc/fast_zombie/claw_strike" .. math.random(1, 3) .. ".wav", impactPos, 85, 110)
			if Arcane and Arcane.SendAttachBandVFX then
				Arcane:SendAttachBandVFX(ply, Color(180, 240, 255, 255), 24, 0.4, {
					{ radius = 18, height = 4, spin = { p = 0, y = 360 * 40, r = 0 }, lineWidth = 2 },
					{ radius = 12, height = 3, spin = { p = 0, y = -300 * 40, r = 0 }, lineWidth = 2 },
				}, "dash_land_fx")
			end
			state._impact.applied = true
			state._impact = nil
		end

		hook.Add("Think", state._thinkId, function()
			if not IsValid(ply) or not IsValid(wep) then return end
			local imp = state._impact
			if not imp or imp.applied then return end
			if CurTime() < (imp.readyAt or 0) then return end
			if ply:OnGround() then
				applyImpact()
			end
		end)

		hook.Add("OnPlayerHitGround", state._landHookId, function(p, inWater, onFloater, speed)
			if p ~= ply then return end
			local imp = state._impact
			if not imp or imp.applied then return end
			if CurTime() < (imp.readyAt or 0) then return end
			applyImpact()
		end)
	end

	hook.Add("KeyPress", state._hookId, function(p, key)
		if not IsValid(p) then return end
		if key ~= IN_ATTACK then return end

		local active = p:GetActiveWeapon()
		if not IsValid(active) or active ~= wep then return end

		-- Only allow for melee weapons
		if not isMeleeHoldType(wep) then return end

		local now = CurTime()
		if now < (state._nextAllowed or 0) then return end

		-- Cooldown 1.5 seconds
		state._nextAllowed = now + 1.5

		-- Dash towards aim direction (mostly horizontal)
		local aim = p:EyeAngles():Forward()
		aim.z = aim.z * 0.1
		aim:Normalize()

		local dashSpeed = 1024
		local push = aim * dashSpeed + Vector(0, 0, 100)
		p:SetVelocity(push)
		p:SetGroundEntity(NULL)

		-- Quick visual feedback
		if Arcane and Arcane.SendAttachBandVFX then
			Arcane:SendAttachBandVFX(p, Color(180, 240, 255, 255), 28, 0.35, {
				{ radius = 18, height = 4, spin = { p = 0, y = 360 * 50, r = 0 }, lineWidth = 2 },
				{ radius = 14, height = 3, spin = { p = 0, y = -300 * 50, r = 0 }, lineWidth = 2 },
			}, "dash_fx")
		end

		sound.Play("npc/fast_zombie/leap1.wav", p:GetPos(), 65, 120)

		-- Start impact window: 0.5s after dash; apply on landing after this time
		if SERVER then
			state._impact = { readyAt = now + 0.5, applied = false }
		end
	end)
end

local function detachDashHook(ply, wep, state)
	if not state or not state._hookId then return end

	hook.Remove("KeyPress", state._hookId)
	state._hookId = nil

	if state._impactHookId then
		hook.Remove("Think", state._impactHookId)
		state._impactHookId = nil
	end
end

Arcane:RegisterEnchantment({
	id = "dashing_strikes",
	name = "Dashing Strikes",
	description = "On melee attack, dash forward toward your aim (1.5s cooldown).",
	icon = "icon16/arrow_right.png",
	cost_coins = 350,
	cost_items = {
		{ name = "mana_crystal_shard", amount = 20 },
	},
	can_apply = function(ply, wep)
		return IsValid(wep) and isMeleeHoldType(wep)
	end,
	apply = attachDashHook,
	remove = detachDashHook,
})