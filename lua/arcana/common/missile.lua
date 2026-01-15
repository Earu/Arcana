-- Arcane Missile System
-- Shared logic for launching arcane missiles
-- Used by both arcane_missiles spell and seeking_salvo enchantment

Arcane = Arcane or {}
Arcane.Common = Arcane.Common or {}

if SERVER then
	-- Select best target for homing missiles
	-- @param origin: Vector starting position
	-- @param aim: Vector aim direction
	-- @param caster: Entity to exclude from targeting
	-- @return Entity or nil
	local function selectBestTarget(origin, aim, caster)
		local best, bestDot = nil, -1
		local maxRange = 1600
		for _, ent in ipairs(ents.FindInSphere(origin + aim * (maxRange * 0.6), maxRange)) do
			if not IsValid(ent) or ent == caster then continue end
			if not (ent:IsPlayer() or ent:IsNPC() or ent:IsNextBot()) then continue end
			if not ent:IsNextBot() and ent:Health() <= 0 then continue end
			local dir = (ent:WorldSpaceCenter() - origin):GetNormalized()
			local d = dir:Dot(aim)
			if d > bestDot then
				bestDot, best = d, ent
			end
		end
		return best
	end

	-- Launch three homing arcane missiles
	-- @param caster: Entity that is casting (for ownership and damage attribution)
	-- @param origin: Vector starting position
	-- @param aim: Vector aim direction (normalized)
	-- @param options: Table of optional parameters:
	--   - count: number of missiles (default 3)
	--   - delay: delay between each missile spawn (default 0.06)
	function Arcane.Common.LaunchMissiles(caster, origin, aim, options)
		if not SERVER then return end
		if not IsValid(caster) then return end
		if not isvector(origin) or not isvector(aim) then return end

		options = options or {}
		local count = options.count or 3
		local delay = options.delay or 0.06

		aim = aim:GetNormalized()

		-- Select homing target once for all missiles
		local target = selectBestTarget(origin, aim, caster)

		-- Launch missiles with staggered timing
		for i = 1, count do
			timer.Simple(delay * (i - 1), function()
				if not IsValid(caster) then return end

				-- Calculate spawn position (spread horizontally)
				local spawnPos = origin + aim * 12 + caster:GetRight() * ((i - 2) * 6) + caster:GetUp() * (i == 2 and 0 or 2)

				local missile = ents.Create("arcana_missile")
				if not IsValid(missile) then return end

				missile:SetPos(spawnPos)
				missile:SetAngles(aim:Angle())
				missile:Spawn()
				missile:SetOwner(caster)

				if missile.SetSpellOwner then
					missile:SetSpellOwner(caster)
				end

				if missile.CPPISetOwner then
					missile:CPPISetOwner(caster)
				end

				if IsValid(target) and missile.SetHomingTarget then
					missile:SetHomingTarget(target)
				end

				-- Launch flash effect
				local ed = EffectData()
				ed:SetOrigin(spawnPos)
				ed:SetNormal(aim)
				util.Effect("ManhackSparks", ed, true, true)

				sound.Play("weapons/physcannon/superphys_launch" .. math.random(1, 4) .. ".wav", spawnPos, 70, 150)
			end)
		end

		-- Initial launch sound
		sound.Play("weapons/physcannon/energy_sing_flyby1.wav", origin, 70, 160)
	end
end
