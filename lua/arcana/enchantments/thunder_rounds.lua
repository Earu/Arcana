-- Spawns a brief tesla burst for visual feedback
local function spawnTeslaBurst(pos)
	local tesla = ents.Create("point_tesla")
	if not IsValid(tesla) then return end
	tesla:SetPos(pos)
	tesla:SetKeyValue("targetname", "arcana_lightning")
	tesla:SetKeyValue("m_SoundName", "DoSpark")
	tesla:SetKeyValue("texture", "sprites/physbeam.vmt")
	tesla:SetKeyValue("m_Color", "170 200 255")
	tesla:SetKeyValue("m_flRadius", "220")
	tesla:SetKeyValue("beamcount_min", "6")
	tesla:SetKeyValue("beamcount_max", "10")
	tesla:SetKeyValue("thick_min", "6")
	tesla:SetKeyValue("thick_max", "10")
	tesla:SetKeyValue("lifetime_min", "0.12")
	tesla:SetKeyValue("lifetime_max", "0.18")
	tesla:SetKeyValue("interval_min", "0.05")
	tesla:SetKeyValue("interval_max", "0.10")
	tesla:Spawn()
	tesla:Fire("DoSpark", "", 0)
	tesla:Fire("Kill", "", 0.6)

	return tesla
end

-- Impact visual/sound feedback similar to lightning_strike
local function impactVFX(pos, normal)
	local ed = EffectData()
	ed:SetOrigin(pos)
	util.Effect("cball_explode", ed, true, true)
	util.Effect("ManhackSparks", ed, true, true)
	util.Decal("Scorch", pos + normal * 8, pos - normal * 8)
	util.ScreenShake(pos, 6, 90, 0.35, 600)
	sound.Play("ambient/energy/zap" .. math.random(1, 9) .. ".wav", pos, 95, 100)
end

-- Apply shock damage in a radius and chain to nearby targets
local function applyLightningDamage(attacker, hitPos, normal)
	local radius = 180
	local baseDamage = 60
	util.BlastDamage(attacker, attacker, hitPos, radius, baseDamage)

	local candidates = {}
	for _, ent in ipairs(ents.FindInSphere(hitPos, 380)) do
		if IsValid(ent) and (ent:IsPlayer() or ent:IsNPC()) and ent:Health() > 0 and ent:VisibleVec(hitPos) then
			table.insert(candidates, ent)
		end
	end

	table.sort(candidates, function(a, b)
		return a:GetPos():DistToSqr(hitPos) < b:GetPos():DistToSqr(hitPos)
	end)

	local maxChains = 3
	for i = 1, math.min(maxChains, #candidates) do
		local tgt = candidates[i]
		local tpos = tgt:WorldSpaceCenter()

		timer.Simple(0.03 * i, function()
			if not IsValid(tgt) then return end
			local tesla = spawnTeslaBurst(tpos)
			if IsValid(tesla) and tesla.CPPISetOwner then
				tesla:CPPISetOwner(attacker)
			end

			local dmg = DamageInfo()
			dmg:SetDamage(24)
			dmg:SetDamageType(bit.bor(DMG_SHOCK, DMG_ENERGYBEAM))
			dmg:SetAttacker(IsValid(attacker) and attacker or game.GetWorld())
			dmg:SetInflictor(IsValid(attacker) and attacker or game.GetWorld())
			dmg:SetDamagePosition(tpos)
			tgt:TakeDamageInfo(dmg)
		end)
	end
end

local function attachHook(ply, wep, state)
	if not IsValid(ply) or not IsValid(wep) then return end

	state._hookId = string.format("Arcana_Ench_ThunderRounds_%d_%d", wep:EntIndex(), ply:EntIndex())
	hook.Add("EntityFireBullets", state._hookId, function(ent, data)
		if not IsValid(ent) or not ent:IsPlayer() then return end

		local active = ent:GetActiveWeapon()
		if not IsValid(active) or active ~= wep then return end

		-- Wrap any existing bullet callback to inject our lightning AoE on hit
		local existingCallback = data.Callback
		data.Callback = function(attacker, tr, dmginfo)
			if isfunction(existingCallback) then
				local ok, err = pcall(existingCallback, attacker, tr, dmginfo)
				if not ok then ErrorNoHalt("ThunderRounds existing callback error: " .. tostring(err) .. "\n") end
			end

			if not tr or not tr.HitPos then return end
			local hitPos = tr.HitPos
			local normal = tr.HitNormal or Vector(0, 0, 1)

			local tesla = spawnTeslaBurst(hitPos)
			if IsValid(tesla) and tesla.CPPISetOwner then
				tesla:CPPISetOwner(attacker)
			end

			impactVFX(hitPos, normal)
			applyLightningDamage(attacker, hitPos, normal)
		end
	end)
end

local function detachHook(ply, wep, state)
	if not state or not state._hookId then return end
	hook.Remove("EntityFireBullets", state._hookId)
	state._hookId = nil
end

local function isMeleeHoldType(wep)
	if not IsValid(wep) then return false end

	local ht = (wep.GetHoldType and wep:GetHoldType()) or wep.HoldType
	if not isstring(ht) then return false end

	ht = string.lower(ht)
	return ht == "melee" or ht == "melee2" or ht == "knife" or ht == "fist"
end

Arcane:RegisterEnchantment({
	id = "thunder_rounds",
	name = "Thunder Rounds",
	description = "Each bullet impact calls a lightning AoE, chaining to nearby foes.",
	icon = "icon16/weather_lightning.png",
	cost_coins = 600,
	cost_items = {
		{ name = "mana_crystal_shard", amount = 25 },
	},
	can_apply = function(ply, wep)
		-- Only firearms that can shoot bullets
		return IsValid(wep) and (wep.Primary ~= nil or wep.FireBullets ~= nil) and not isMeleeHoldType(wep)
	end,
	apply = attachHook,
	remove = detachHook,
})
