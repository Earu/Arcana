local function spawnTeslaBurst(pos)
	return Arcana.Common.SpawnTeslaBurst(pos, {
		targetname = "arcana_lightning",
		radius = 220, beamcount_min = 6, beamcount_max = 10,
		thick_min = 6, thick_max = 10,
		lifetime_min = 0.12, lifetime_max = 0.18,
		interval_min = 0.05, interval_max = 0.10,
		kill_delay = 0.6,
	})
end

local function impactVFX(pos, normal, power)
	Arcana.Common.LightningImpactVFX(pos, normal, {
		power = power,
		shakePower = 6, shakeHz = 90, shakeDur = 0.35, shakeRadius = 600,
		soundLvl = 95,
	})
end

local function applyLightningDamage(attacker, hitPos)
	Arcana.Common.ApplyLightningChain(attacker, hitPos, {
		baseDamage = 60, chainDamage = 24, chainDelay = 0.03,
		spawnTesla = spawnTeslaBurst,
	})
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
			if IsValid(tesla) and tesla.CPPISetOwner and attacker:IsPlayer() then
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

Arcana:RegisterEnchantment({
	id = "thunder_rounds",
	name = "Thunder Rounds",
	description = "Each bullet impact calls a lightning AoE, chaining to nearby foes.",
	cost_coins = 2000,
	cost_items = {
		{ name = "mana_crystal_shard", amount = 80 },
	},
	can_apply = function(ply, wep)
		-- Only firearms that can shoot bullets
		return Arcana.WeaponClassification.Get(wep) == "HITSCAN"
	end,
	apply = attachHook,
	remove = detachHook,
})
