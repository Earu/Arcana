local function isMeleeHoldType(wep)
	if not IsValid(wep) then return false end

	local ht = (wep.GetHoldType and wep:GetHoldType()) or wep.HoldType
	if not isstring(ht) then return false end

	ht = string.lower(ht)
	return ht == "melee" or ht == "melee2" or ht == "knife" or ht == "fist"
end

-- Brief tesla burst for lightning feedback
local function spawnTeslaBurst(pos)
	local tesla = ents.Create("point_tesla")
	if not IsValid(tesla) then return end
	tesla:SetPos(pos)
	tesla:SetKeyValue("targetname", "arcana_thundering_reach")
	tesla:SetKeyValue("m_SoundName", "DoSpark")
	tesla:SetKeyValue("texture", "sprites/physbeam.vmt")
	tesla:SetKeyValue("m_Color", "170 200 255")
	tesla:SetKeyValue("m_flRadius", "180")
	tesla:SetKeyValue("beamcount_min", "5")
	tesla:SetKeyValue("beamcount_max", "8")
	tesla:SetKeyValue("thick_min", "5")
	tesla:SetKeyValue("thick_max", "8")
	tesla:SetKeyValue("lifetime_min", "0.10")
	tesla:SetKeyValue("lifetime_max", "0.16")
	tesla:SetKeyValue("interval_min", "0.05")
	tesla:SetKeyValue("interval_max", "0.10")
	tesla:Spawn()
	tesla:Fire("DoSpark", "", 0)
	tesla:Fire("Kill", "", 0.5)

	return tesla
end

local function impactVFX(pos, normal)
	local ed = EffectData()
	ed:SetOrigin(pos)
	util.Effect("cball_explode", ed, true, true)
	util.Effect("ManhackSparks", ed, true, true)
	util.Decal("Scorch", pos + (normal or Vector(0,0,1)) * 8, pos - (normal or Vector(0,0,1)) * 8)
	sound.Play("ambient/energy/zap" .. math.random(1, 9) .. ".wav", pos, 90, 100)
end

-- Attempt to strike an extra target slightly beyond normal melee reach
local function fireThunderLine(attacker, wep, baseDamage)
	if not IsValid(attacker) or not IsValid(wep) then return end
	if not attacker:IsPlayer() then return end

	local start = attacker:GetShootPos() or attacker:EyePos()
	local dir = attacker:EyeAngles():Forward()
	local length = 200
	local endpos = start + dir * length
	local spacing = 28
	local steps = math.max(1, math.floor(length / spacing))

	-- Visual tesla bursts along the line
	for i = 1, steps do
		local p = start + dir * (i * spacing)
		local tesla = spawnTeslaBurst(p)
		if IsValid(tesla) and tesla.CPPISetOwner then
			tesla:CPPISetOwner(attacker)
		end
	end
	impactVFX(endpos, dir)

	-- Collect targets along a narrow corridor (use lag compensation for accuracy)
	local hitMap = {}
	local radius = 24
	if attacker.LagCompensation then attacker:LagCompensation(true) end
	for i = 1, steps do
		local p = start + dir * (i * spacing)
		for _, ent in ipairs(ents.FindInSphere(p, radius + 8)) do
			if IsValid(ent) and ent ~= attacker and (ent:IsPlayer() or ent:IsNPC() or ent:IsNextBot()) then
				-- Ensure the entity lies roughly in front within the segment range
				local toEnt = ent:WorldSpaceCenter() - start
				local proj = toEnt:Dot(dir)
				if proj > 0 and proj < length + 8 then
					-- Perpendicular distance test (approximate)
					local closest = start + dir * proj
					if ent:WorldSpaceCenter():Distance(closest) <= (radius + 16) then
						hitMap[ent] = true
					end
				end
			end
		end
	end
	if attacker.LagCompensation then attacker:LagCompensation(false) end

	local dmgAmt = math.max(12, baseDamage)
	for ent, _ in pairs(hitMap) do
		local dmg = DamageInfo()
		dmg:SetDamage(dmgAmt)
		dmg:SetDamageType(bit.bor(DMG_SHOCK, DMG_ENERGYBEAM))
		dmg:SetAttacker(IsValid(attacker) and attacker or game.GetWorld())
		dmg:SetInflictor(IsValid(wep) and wep or attacker)
		dmg:SetDamagePosition(ent:WorldSpaceCenter())
		ent:TakeDamageInfo(dmg)
	end
end

local function attachHook(ply, wep, state)
	if not IsValid(ply) or not IsValid(wep) then return end

	state._hookId = string.format("Arcana_Ench_ThunderingReach_%d_%d", wep:EntIndex(), ply:EntIndex())
	state._lastNPF = (wep.GetNextPrimaryFire and wep:GetNextPrimaryFire()) or 0
	state._lastFireAt = 0
	-- Server-only: spawning entities and applying damage
	if SERVER then
		hook.Add("StartCommand", state._hookId, function(attacker, ucmd)
			if not IsValid(attacker) or not attacker:IsPlayer() then return end
			local active = attacker:GetActiveWeapon()
			if not IsValid(active) or active ~= wep then return end
			if not isMeleeHoldType(wep) then return end

			local now = CurTime()
			local function performThunder()
				if (state._lastFireAt or 0) > now - 0.005 then return end
				local baseDamage = 18
				if istable(wep.Primary) and isnumber(wep.Primary.Damage) then
					baseDamage = math.Clamp(wep.Primary.Damage, 8, 45)
				end
				fireThunderLine(attacker, wep, baseDamage)
				state._lastFireAt = now
			end

			-- Fire exactly when the weapon schedules a new primary swing (NextPrimaryFire jumps forward)
			local curNPF = (wep.GetNextPrimaryFire and wep:GetNextPrimaryFire()) or 0
			local prevNPF = state._lastNPF or 0
			if curNPF > prevNPF + 0.0001 then
				performThunder()
			end
			state._lastNPF = curNPF

			-- Fallback: for SWEPs that don't advance NPF, also trigger on initial press
			if attacker:KeyPressed(IN_ATTACK) then
				performThunder()
			end
		end)
	end
end

local function detachHook(ply, wep, state)
	if not state or not state._hookId then return end
	hook.Remove("StartCommand", state._hookId)
	state._hookId = nil
end

Arcane:RegisterEnchantment({
	id = "thundering_reach",
	name = "Thundering Reach",
	description = "Unleash a line of thunder on melee swing, damaging foes ahead.",
	icon = "icon16/weather_lightning.png",
	cost_coins = 1200,
	cost_items = {
		{ name = "mana_crystal_shard", amount = 60 },
	},
	can_apply = function(ply, wep)
		return IsValid(wep) and isMeleeHoldType(wep)
	end,
	apply = attachHook,
	remove = detachHook,
})


