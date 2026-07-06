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

Arcana:RegisterEnchantment({
	id = "thunder_rounds",
	name = "Thunder Rounds",
	description = "Each bullet impact calls a lightning AoE, chaining to nearby foes.",
	cost_coins = 2000,
	cost_items = {
		{ name = "mana_crystal_shard", amount = 80 },
	},
	can_apply = function(ply, wep)
		-- Ranged hitscan firearms, with or without real bullets
		return Arcana.WeaponClassification.Get(wep) == "HITSCAN"
	end,
	on_shot_fired = function(ply, wep, data, state)
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
	end,
})
