-- Arcana Target Lock — per-frame crosshair scanner that latches onto the first entity
-- passing a spell's filter function during a cast wind-up.
--
-- API (server-side):
--   Arcana.Common.TargetScan(caster, filter, range)
--     Begin scanning the caster's crosshair every server frame.
--     filter : function(entity) -> bool  — return true to accept the entity as the target.
--              Defaults to accepting any valid non-caster entity.
--     range  : number (optional) — max trace distance, defaults to 1000.
--     The scan stops automatically once a valid target is found.
--     The lock and the client indicator are cleared automatically when the spell
--     succeeds or fails — spells do not need to do any cleanup.
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

	-- steamid64 → Entity  (locked target, once acquired)
	local lockedTargets = {}

	-- steamid64 → { filter, range }
	local activeScanners = {}

	--- Returns the entity locked during the cast wind-up, or nil if none yet.
	-- The spell's cast() is responsible for validating the returned entity further.
	-- @param caster Entity
	-- @return Entity|nil
	function Arcana.Common.GetLockedTarget(caster)
		if not IsValid(caster) then return nil end

		local target = lockedTargets[caster:SteamID64()]
		if not IsValid(target) then
			lockedTargets[caster:SteamID64()] = nil
			return nil
		end

		return target
	end

	--- Begin scanning the caster's crosshair each server frame.
	-- The first entity for which filter(entity) returns true becomes the locked target.
	-- The scan stops automatically on the first hit. The lock and client indicator are
	-- cleared automatically when the spell succeeds or fails.
	-- Derives spellId and remaining cast time from the caster's active player data.
	-- @param caster Entity  The casting player.
	-- @param filter function(entity)->bool  Acceptance predicate (nil = accept any valid non-caster).
	-- @param range  number  Max eye-trace distance (nil = 1000).
	function Arcana.Common.TargetScan(caster, filter, range)
		if not IsValid(caster) then return end

		local sid = caster:SteamID64()

		-- Clear any previous scan/lock before starting fresh.
		activeScanners[sid] = nil
		lockedTargets[sid] = nil

		activeScanners[sid] = {
			filter = isfunction(filter) and filter or nil,
			range = range or 1000,
		}
	end

	local function clearLock(caster)
		if not IsValid(caster) then return end

		local sid = caster:SteamID64()
		activeScanners[sid] = nil

		if not lockedTargets[sid] then return end

		lockedTargets[sid] = nil
		net.Start("Arcana_TargetUnlocked")
		net.Send(caster)
	end

	-- Single Think hook — runs every server frame, scans all active casters at once.
	hook.Add("Think", "ArcanaTargetLock_Scan", function()
		for sid, scanner in pairs(activeScanners) do
			local caster = player.GetBySteamID64(sid)
			if not IsValid(caster) then
				activeScanners[sid] = nil
				lockedTargets[sid] = nil
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

			-- First accepted entity — lock and stop scanning.
			lockedTargets[sid] = target
			activeScanners[sid] = nil

			-- Derive remaining cast time and spellId from player data so the
			-- indicator circle matches the cast wind-up duration exactly.
			local pdata = Arcana:GetPlayerData(caster)
			local spellId = (pdata and pdata.casting_spell) or ""
			local remaining = math.max(0.05, ((pdata and pdata.casting_until) or CurTime()) - CurTime())

			net.Start("Arcana_TargetLocked")
			net.WriteEntity(target)
			net.WriteFloat(remaining)
			net.WriteString(spellId)
			net.Send(caster)
		end
	end)

	-- Automatically clear lock and indicator when the spell resolves.
	hook.Add("Arcana_CastSpell", "ArcanaTargetLock_Clear", function(caster)
		clearLock(caster)
	end)

	hook.Add("Arcana_CastSpellFailure", "ArcanaTargetLock_Clear", function(caster)
		clearLock(caster)
	end)

	-- Clear stale entries on disconnect.
	hook.Add("PlayerDisconnected", "ArcanaTargetLock_Cleanup", function(ply)
		if IsValid(ply) then
			local sid = ply:SteamID64()
			activeScanners[sid] = nil
			lockedTargets[sid] = nil
		end
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

		-- Ground circle at target's feet, facing upward — same transform as the
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