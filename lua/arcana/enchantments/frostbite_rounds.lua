-- Single-target frost effect inspired by frost_nova (no AoE)
local function applyFrostbite(attacker, target, hitPos)
	if not IsValid(target) then return end
	local pos = target:WorldSpaceCenter()
	local baseDamage = 45
	local slowMult = 0.5
	local slowDuration = 3.5

	-- Damage
	local dmg = DamageInfo()
	dmg:SetDamage(baseDamage)
	dmg:SetDamageType(bit.bor(DMG_GENERIC, DMG_SONIC))
	dmg:SetAttacker(IsValid(attacker) and attacker or game.GetWorld())
	dmg:SetInflictor(IsValid(attacker) and attacker or game.GetWorld())
	Arcana.TakeDamageInfo(target, dmg)

	-- Light knockback away from impact/caster
	local pushDir = (pos - ((IsValid(attacker) and attacker:WorldSpaceCenter()) or (hitPos or pos))):GetNormalized()
	if target:IsPlayer() then
		target:SetVelocity(pushDir * 180)
	else
		local phys = target:GetPhysicsObject()
		if IsValid(phys) then
			phys:ApplyForceCenter(pushDir * 16000)
		end
	end

	-- Apply slow via shared Frost status
	local isActor =Arcana.Common.IsActor(target)
	if isActor then
		Arcana.Status.Frost.Apply(target, {
			slowMult = slowMult,
			duration = slowDuration,
			vfxTag = "frost_slow",
			sendClientFX = true
		})
	end

	-- Impact visuals and audio at hit position
	local impact = hitPos or pos
	local ed = EffectData()
	ed:SetOrigin(impact)
	util.Effect("GlassImpact", ed, true, true)
	Arcana.Common.ScreenShake(impact, 2, 40, 0.15, 256)
	sound.Play("physics/glass/glass_impact_bullet1.wav", impact, 70, 130)
end

Arcana.RegisterEnchantment({
	id = "frostbite_rounds",
	name = "Frostbite Rounds",
	description = "Bullets freeze the struck target with chilling slow and cold VFX.",
	cost_coins = 1000,
	cost_items = {
		{ name = "mana_crystal_shard", amount = 50 },
	},
	can_apply = function(ply, wep)
		-- Ranged hitscan firearms, with or without real bullets
		return Arcana.WeaponClassification.Get(wep) == "HITSCAN"
	end,
	on_shot_fired = function(ply, wep, data, state)
		local existingCallback = data.Callback
		data.Callback = function(attacker, tr, dmginfo)
			if isfunction(existingCallback) then
				local ok, err = pcall(existingCallback, attacker, tr, dmginfo)
				if not ok then ErrorNoHalt("FrostbiteRounds existing callback error: " .. tostring(err) .. "\n") end
			end

			if not tr then return end
			local hitEnt = tr.Entity
			if not IsValid(hitEnt) then return end
			-- Only actors: players, NPCs, NextBots
			local isActor =Arcana.Common.IsActor(hitEnt)
			if not isActor then return end

			applyFrostbite(attacker, hitEnt, tr.HitPos)
		end
	end,
})


