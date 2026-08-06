-- Arcana Target Lock: per-frame crosshair scanner that latches onto the first entity
-- passing a spell's filter function during a cast wind-up.
--
-- API (server-side):
--   Arcana.Common.TargetScan(caster, filter, range)
--     Begin scanning the caster's crosshair every server frame.
--     filter : function(entity) -> bool, return true to accept the entity as the target.
--              Defaults to accepting any valid non-caster entity.
--     range  : number (optional), max trace distance, defaults to 1000.
--     The scan stops automatically once a valid target is found.
--     The lock and the client indicator are cleared automatically when the spell
--     succeeds or fails: spells do not need to do any cleanup.
--
--   Arcana.Common.GetLockedTarget(caster) -> Entity|nil
--     Returns the locked entity once acquired, or nil.
--
-- Client: once locked, shows a MagicCircle at the target's feet using the same
--         color/seed/intensity as the caster's own casting circle.
Arcana = Arcana or {}
Arcana.Common = Arcana.Common or {}

-- ── Server ────────────────────────────────────────────────────────────────────
if SERVER then
	util.AddNetworkString("Arcana_TargetLocked")
	util.AddNetworkString("Arcana_TargetUnlocked")

	-- caster Entity → Entity  (locked target, once acquired)
	local lockedTargets = {}

	-- caster Entity → { filter, range }
	local activeScanners = {}

	-- The player who should see the lock indicator: the caster itself, or the
	-- caster's owner when the caster is an entity (e.g. arcana_spell_caster).
	local function getViewer(caster)
		if caster:IsPlayer() then return caster end

		local owner = caster.CPPIGetOwner and caster:CPPIGetOwner()
		if not IsValid(owner) then owner = caster:GetNWEntity("FallbackOwner") end
		if IsValid(owner) and owner:IsPlayer() then return owner end

		return nil
	end

	--- Returns the entity locked during the cast wind-up, or nil if none yet.
	-- The spell's cast() is responsible for validating the returned entity further.
	-- @param caster Entity  The scanning caster (player or casting entity).
	-- @return Entity|nil
	function Arcana.Common.GetLockedTarget(caster)
		if not IsValid(caster) then return nil end

		local target = lockedTargets[caster]
		if not IsValid(target) then
			lockedTargets[caster] = nil
			return nil
		end

		return target
	end

	--- Begin scanning the caster's crosshair each server frame.
	-- The first entity for which filter(entity) returns true becomes the locked target.
	-- The scan stops automatically on the first hit. The lock and client indicator are
	-- cleared automatically when the spell succeeds or fails.
	-- Players scan along their eye trace; other entities scan along their forward axis.
	-- @param caster Entity  The casting player or entity (e.g. arcana_spell_caster).
	-- @param filter function(entity)->bool  Acceptance predicate (nil = accept any valid non-caster).
	-- @param range  number  Max eye-trace distance (nil = 1000).
	function Arcana.Common.TargetScan(caster, filter, range)
		if not IsValid(caster) then return end

		-- Clear any previous scan/lock before starting fresh.
		lockedTargets[caster] = nil

		activeScanners[caster] = {
			filter = isfunction(filter) and filter or nil,
			range = range or 1000,
		}
	end

	local function clearLock(caster)
		if not IsValid(caster) then return end

		activeScanners[caster] = nil

		if not lockedTargets[caster] then return end

		lockedTargets[caster] = nil

		local viewer = getViewer(caster)
		if viewer then
			net.Start("Arcana_TargetUnlocked")
			net.Send(viewer)
		end
	end

	--- Cancel an in-progress scan and drop any acquired lock for this caster.
	-- Spells never need this; entity casters use it on their abort paths.
	Arcana.Common.ClearTargetLock = clearLock

	-- Single Think hook: runs every server frame, scans all active casters at once.
	hook.Add("Think", "ArcanaTargetLock_Scan", function()
		for caster, scanner in pairs(activeScanners) do
			if not IsValid(caster) then
				activeScanners[caster] = nil
				lockedTargets[caster] = nil
				continue
			end

			local tr
			if caster.GetEyeTrace then
				tr = caster:GetEyeTrace()
			else
				local src = caster:WorldSpaceCenter()
				tr = util.TraceLine({
					start = src,
					endpos = src + caster:GetForward() * scanner.range,
					filter = caster,
				})
			end

			if not tr then continue end

			local target = tr.Entity
			if not IsValid(target) or target == caster then continue end
			if scanner.filter and not scanner.filter(target) then continue end

			-- First accepted entity: lock and stop scanning.
			lockedTargets[caster] = target
			activeScanners[caster] = nil

			-- Derive remaining cast time and spellId so the indicator circle
			-- matches the cast wind-up duration exactly.
			local spellId, remaining
			if caster:IsPlayer() then
				local pdata = Arcana.GetPlayerData(caster)
				spellId = (pdata and pdata.casting_spell) or ""
				remaining = math.max(0.05, ((pdata and pdata.casting_until) or CurTime()) - CurTime())
			else
				spellId = caster.QueuedSpell or ""
				remaining = math.max(0.05, (caster.CastingUntil or CurTime()) - CurTime())
			end

			local viewer = getViewer(caster)
			if viewer then
				net.Start("Arcana_TargetLocked")
				net.WriteEntity(target)
				net.WriteFloat(remaining)
				net.WriteString(spellId)
				net.Send(viewer)
			end
		end
	end)

	-- Automatically clear lock and indicator when the spell resolves.
	-- Entity casts run these hooks with the owner player as caster, so also
	-- clear by the context's casterEntity.
	local function onSpellResolved(caster, _, _, _, context)
		if context and IsValid(context.casterEntity) and context.casterEntity ~= caster then
			clearLock(context.casterEntity)
		end

		clearLock(caster)
	end

	hook.Add("Arcana_CastSpell", "ArcanaTargetLock_Clear", onSpellResolved)
	hook.Add("Arcana_CastSpellFailure", "ArcanaTargetLock_Clear", onSpellResolved)

	-- Clear stale entries when a caster (player or entity) leaves the world.
	hook.Add("EntityRemoved", "ArcanaTargetLock_Cleanup", function(ent)
		activeScanners[ent] = nil
		lockedTargets[ent] = nil
	end)
end

-- ── Client ────────────────────────────────────────────────────────────────────
if CLIENT then
	-- Stub so spells with client-side validation paths (if not SERVER then return true end)
	-- don't error when they call GetLockedTarget before the SERVER guard is reached.
	function Arcana.Common.GetLockedTarget(_caster)
		return nil
	end

	local lockCircle = nil -- active MagicCircle indicator

	local function clearIndicator()
		if lockCircle then
			lockCircle:Remove()
			lockCircle = nil
		end

		hook.Remove("Think", "ArcanaTargetLock_FollowTarget")
	end

	net.Receive("Arcana_TargetLocked", function()
		local target = net.ReadEntity()
		local remainingTime = net.ReadFloat()
		local spellId = net.ReadString()

		clearIndicator()

		if not (Arcana.Circle and Arcana.Circle.MagicCircle) then return end
		if not IsValid(target) then return end

		-- Mirror the exact color/seed/intensity logic from vfx/casting.lua so this
		-- circle looks like a natural extension of the caster's own casting circle.
		local caster = LocalPlayer()
		local color = caster.GetWeaponColor and caster:GetWeaponColor():ToColor() or Color(150, 100, 255, 255)
		local intensity = 3
		local seed

		if isstring(spellId) and #spellId > 0 then
			intensity = 2 + (#spellId % 3)
			seed = tonumber(util.CRC(spellId))
		end

		-- Ground circle at target's feet, facing upward, same transform as the
		-- player's own ground casting circle in computeCastCircleTransform.
		local pos = target:GetPos() + Vector(0, 0, 2)
		local ang = Angle(0, 180, 180)
		local circle = Arcana.Circle.MagicCircle.CreateMagicCircle(pos, ang, color, intensity, 60, remainingTime, 2, seed)
		if not circle then return end

		circle:StartEvolving(remainingTime, -1)
		lockCircle = circle

		hook.Add("Think", "ArcanaTargetLock_FollowTarget", function()
			if not IsValid(target) or not lockCircle or not lockCircle:IsActive() then
				clearIndicator()
				return
			end

			lockCircle.position = target:GetPos() + Vector(0, 0, 2)
		end)
	end)

	net.Receive("Arcana_TargetUnlocked", function()
		clearIndicator()
	end)
end