local function isMeleeHoldType(wep)
	if not IsValid(wep) then return false end

	local ht = (wep.GetHoldType and wep:GetHoldType()) or wep.HoldType
	if not isstring(ht) then return false end

	ht = string.lower(ht)
	return ht == "melee" or ht == "melee2" or ht == "knife" or ht == "fist"
end

local function isMeleeDamage(dmginfo)
	if not dmginfo then return false end
	local dt = dmginfo:GetDamageType()

	-- Common melee flags across various SWEPs
	return bit.band(dt, DMG_CLUB) ~= 0
		or bit.band(dt, DMG_SLASH) ~= 0
		or bit.band(dt, DMG_NEVERGIB) ~= 0 -- some knives
		or bit.band(dt, DMG_GENERIC) ~= 0 -- some melee mods use generic
end

local function playAegisVFX(ply)
	if not IsValid(ply) then return end

	-- Multi-ring band similar to arcane_barrier, scaled to player bounds
	Arcane:ClearBandVFX(ply, "duelist_aegis_fx")
	local r = math.max(ply:OBBMaxs():Unpack()) * 0.6
	Arcane:SendAttachBandVFX(ply, Color(120, 200, 255, 255), 28, 2, {
		{
			radius = r * 0.95,
			height = 6,
			spin = { p = 0, y = 60 * 3, r = 20 * 3 },
			lineWidth = 2
		},
		{
			radius = r * 0.95,
			height = 6,
			spin = { p = -30 * 3, y = -40 * 3, r = 10 * 3 },
			lineWidth = 2
		},
		{
			radius = r * 0.95,
			height = 6,
			spin = { p = 30 * 3, y = -50 * 3, r = -15 * 3 },
			lineWidth = 2
		},
		{
			radius = r * 0.95,
			height = 6,
			spin = { p = -45 * 3, y = 35 * 3, r = -25 * 3 },
			lineWidth = 2
		},
		{
			radius = r * 0.95,
			height = 6,
			spin = { p = 15 * 3, y = -70 * 3, r = 30 * 3 },
			lineWidth = 2
		},
		{
			radius = r * 0.95,
			height = 6,
			spin = { p = -20 * 3, y = 45 * 3, r = -35 * 3 },
			lineWidth = 2
		}
	}, "duelist_aegis_fx")

	local ed = EffectData()
	ed:SetOrigin(ply:WorldSpaceCenter())
	util.Effect("cball_bounce", ed, true, true)
	sound.Play("ambient/energy/zap1.wav", ply:GetPos(), 70, 110)
end

local function attachHook(ply, wep, state)
	if not IsValid(ply) or not IsValid(wep) then return end

	state._hookId = string.format("Arcana_Ench_DuelistAegis_%d_%d", wep:EntIndex(), ply:EntIndex())
	state._aegisUntil = 0
	state._lastBlockFxAt = 0

	hook.Add("EntityTakeDamage", state._hookId, function(victim, dmginfo)
		if not IsValid(dmginfo) then return end
		local now = CurTime()

		-- Grant Aegis when this player deals melee damage with this weapon
		local attacker = dmginfo:GetAttacker()
		if IsValid(attacker) and attacker == ply then
			local active = ply:GetActiveWeapon()
			if IsValid(active) and active == wep and isMeleeHoldType(wep) and isMeleeDamage(dmginfo) then
				state._aegisUntil = now + 2.0
				playAegisVFX(ply)
			end
		end

		-- While Aegis is active, ignore non-melee damage to this player (only while wielding this melee)
		if IsValid(victim) and victim == ply and now <= (state._aegisUntil or 0) then
			local active = ply:GetActiveWeapon()
			if IsValid(active) and active == wep and isMeleeHoldType(wep) then
				if not isMeleeDamage(dmginfo) then
					-- Block non-melee damage
					dmginfo:SetDamage(0)
					dmginfo:ScaleDamage(0)
					-- Small block VFX with cooldown to avoid spam
					if now > (state._lastBlockFxAt or 0) + 0.15 then
						local ed = EffectData()
						ed:SetOrigin(ply:WorldSpaceCenter())
						util.Effect("cball_bounce", ed, true, true)
						sound.Play("ambient/energy/zap2.wav", ply:GetPos(), 65, 120)
						state._lastBlockFxAt = now
					end
				end
			end
		end
	end)
end

local function detachHook(ply, wep, state)
	if not state or not state._hookId then return end

	hook.Remove("EntityTakeDamage", state._hookId)
	state._hookId = nil
	state._aegisUntil = 0
end

Arcane:RegisterEnchantment({
	id = "duelist_aegis",
	name = "Duelist's Aegis",
	description = "After dealing melee damage, ignore non-melee damage for 2s while wielding this weapon.",
	icon = "icon16/shield.png",
	cost_coins = 1200,
	cost_items = {
		{ name = "mana_crystal_shard", amount = 50 },
	},
	can_apply = function(ply, wep)
		return IsValid(wep) and isMeleeHoldType(wep)
	end,
	apply = attachHook,
	remove = detachHook,
})


