-- Arcana Damage utilities — server-side.
-- Provides Arcana:BlastDamage (radius damage with ForceTakeDamageInfo support),
-- Arcana:TakeDamageInfo (invulnerability-aware damage wrapper),
-- and bad-entity tracking for Arcana:IsPotentialCheater.

Arcana = Arcana or {}

if SERVER then
	--- Apply radius blast damage centred on `center`.
	-- @param attacker  Entity  Damage source (defaults to world)
	-- @param center    Vector  World-space center of explosion
	-- @param radius    number  Blast radius in units
	-- @param baseDamage number Maximum damage at ground zero
	-- @param opts      table   Optional: damageType, inflictor, ignoreAttacker (bool), onChecked (function)
	function Arcana:BlastDamage(attacker, center, radius, baseDamage, opts)
		opts = opts or {}
		attacker = IsValid(attacker) and attacker or game.GetWorld()
		local inflictor = IsValid(opts.inflictor) and opts.inflictor or attacker
		radius = math.max(1, tonumber(radius) or 0)
		baseDamage = math.max(0, tonumber(baseDamage) or 0)
		local damageType = opts.damageType or DMG_BLAST
		local ignoreAttacker = opts.ignoreAttacker
		local onChecked = opts.onChecked

		for _, ent in ipairs(ents.FindInSphere(center, radius)) do
			if not IsValid(ent) or ent == inflictor then continue end
			if ignoreAttacker and ent == attacker then continue end
			if ent:IsPlayer() and not ent:Alive() then continue end

			local dist = ent:WorldSpaceCenter():Distance(center)
			local frac = 1 - (dist / radius)
			if frac <= 0 then continue end

			local dmgAmt = baseDamage * frac
			if dmgAmt <= 0 then continue end

			local dmg = DamageInfo()
			dmg:SetDamage(dmgAmt)
			dmg:SetDamageType(damageType)
			dmg:SetAttacker(attacker)
			dmg:SetInflictor(inflictor)
			dmg:SetDamagePosition(ent:WorldSpaceCenter())
			Arcana:TakeDamageInfo(ent, dmg, onChecked)
		end
	end

	-- Wrapper that detects invulnerability
	function Arcana:TakeDamageInfo(ent, dmginfo, onChecked)
		if not IsValid(ent) then return end
		if not ent:IsPlayer() then
			return ent:TakeDamageInfo(dmginfo)
		end

		local healthBefore = ent:Health()
		local damageAmount = dmginfo:GetDamage()

		ent:TakeDamageInfo(dmginfo)

		-- Defer health check: invulnerability plugins absorb damage without Health() changing,
		-- so we compare before/after health one tick later to detect whether damage landed.
		timer.Simple(0.01, function()
			if not IsValid(ent) or not ent:Alive() then return end

			local healthAfter = ent:Health()
			local actualDamageTaken = healthBefore - healthAfter

			if actualDamageTaken <= 0 then
				ent.ArcanaInvulnerable = true
				return
			end

			local damageRatio = actualDamageTaken / healthBefore
			-- Clamp denominator to 255 so players with artificially high max-health (e.g. 9999)
			-- are still classified as invulnerable when they absorb normal damage amounts.
			local intendedRatio = damageAmount / math.min(healthBefore, 255)

			if damageRatio < (intendedRatio * 0.5) then
				ent.ArcanaInvulnerable = true
				return
			end

			if ent.ArcanaInvulnerable then
				ent.ArcanaInvulnerable = nil
			end

			if isfunction(onChecked) then
				onChecked(ent, healthBefore, healthAfter, damageAmount, actualDamageTaken)
			end
		end)
	end

	local BAD_ENT_CLASSES = {
		gmod_wire_teleporter = true,
		starfall_processor = true,
		gmod_wire_expression2 = true,
	}

	local badEntities = {}
	local badEntitiesOwnership = {}
	local function assignBadEntity(ent)
		if not IsValid(ent) then return end
		if not BAD_ENT_CLASSES[ent:GetClass()] then return end
		if not ent.CPPIGetOwner then return end

		local owner = ent:CPPIGetOwner()
		if not IsValid(owner) then return end

		badEntities[owner] = (badEntities[owner] or 0) + 1
		badEntitiesOwnership[ent] = owner

		local timerName = "Arcana_BadEntityCheck_Timer_" .. tostring(owner)
		timer.Remove(timerName)
	end

	local function removeBadEntity(ent)
		if not IsValid(ent) then return end
		if not BAD_ENT_CLASSES[ent:GetClass()] then return end

		local owner = badEntitiesOwnership[ent] -- we're forced to do that because CPPIGetOwner is not reliable when entities are removed
		if not IsValid(owner) then return end

		badEntities[owner] = math.max(0, (badEntities[owner] or 0) - 1)

		local timerName = "Arcana_BadEntityCheck_Timer_" .. tostring(owner)
		timer.Create(timerName, 60, 1, function()
			timer.Remove(timerName)

			if IsValid(owner) and badEntities[owner] and badEntities[owner] == 0 then
				badEntities[owner] = nil
			end
		end)
	end

	hook.Add("OnEntityCreated", "Arcana_BadEntityCheck", function(ent)
		if not BAD_ENT_CLASSES[ent:GetClass()] then return end
		if not ent.CPPIGetOwner then return end

		timer.Simple(0.1, function()
			assignBadEntity(ent)
		end)
	end)

	hook.Add("EntityRemoved", "Arcana_BadEntityCheck", function(ent)
		removeBadEntity(ent)
	end)

	hook.Add("PlayerInitialSpawn", "Arcana_BadEntityCheck", function(ply)
		timer.Simple(0.1, function()
			for className in pairs(BAD_ENT_CLASSES) do
				for _, ent in ipairs(ents.FindByClass(className)) do
					assignBadEntity(ent)
				end
			end
		end)
	end)

	hook.Add("PlayerDisconnected", "Arcana_BadEntityCheck", function(ply)
		if badEntities[ply] then
			badEntities[ply] = nil
		end

		for ent, owner in pairs(badEntitiesOwnership) do
			if owner == ply then
				badEntitiesOwnership[ent] = nil
			end
		end
	end)

	function Arcana:IsPotentialCheater(ply)
		if not IsValid(ply) then return true end
		if ply.ArcanaInvulnerable then return true end
		if badEntities[ply] and badEntities[ply] > 0 then return true end
		return false
	end
end