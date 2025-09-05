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
	target:TakeDamageInfo(dmg)

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
	local isActor = target:IsPlayer() or target:IsNPC() or (target.IsNextBot and target:IsNextBot())
	if isActor then
		Arcane.Status.Frost.Apply(target, {
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
	util.ScreenShake(impact, 2, 40, 0.15, 256)
	sound.Play("physics/glass/glass_impact_bullet1.wav", impact, 70, 130)
end

local function attachHook(ply, wep, state)
	if not IsValid(ply) or not IsValid(wep) then return end

	state._hookId = string.format("Arcana_Ench_FrostbiteRounds_%d_%d", wep:EntIndex(), ply:EntIndex())
	hook.Add("EntityFireBullets", state._hookId, function(ent, data)
		if not IsValid(ent) or not ent:IsPlayer() then return end

		local active = ent:GetActiveWeapon()
		if not IsValid(active) or active ~= wep then return end

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
			local isActor = hitEnt:IsPlayer() or hitEnt:IsNPC() or (hitEnt.IsNextBot and hitEnt:IsNextBot())
			if not isActor then return end

			applyFrostbite(attacker, hitEnt, tr.HitPos)
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
	id = "frostbite_rounds",
	name = "Frostbite Rounds",
	description = "Bullets freeze the struck target with chilling slow and cold VFX.",
	icon = "icon16/weather_snow.png",
	cost_coins = 1000,
	cost_items = {
		{ name = "mana_crystal_shard", amount = 50 },
	},
	can_apply = function(ply, wep)
		-- Only firearms that can shoot bullets
		return IsValid(wep) and (wep.Primary ~= nil or wep.FireBullets ~= nil) and not isMeleeHoldType(wep)
	end,
	apply = attachHook,
	remove = detachHook,
})


