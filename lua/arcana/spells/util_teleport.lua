-- Teleport (Blink)
-- Quickly relocate to the point you're aiming at, clamped to range and validated with a hull trace
-- Find a good destination based on aim and ensure player hull fits there.
local sv_gravity = GetConVar("sv_gravity")
local vec_up = Vector(0, 0, 1)
local trMins, trMaxs = Vector(-16, -16, 0), Vector(16, 16, 72)
-- Common trace mask and small constants for clarity
local TELEPORT_MASK = bit.bor(CONTENTS_PLAYERCLIP, MASK_PLAYERSOLID_BRUSHONLY, MASK_SHOT_HULL)
local SURFACE_OFFSET = 120
local SMALL_NUDGE = 3
local MAX_BACKOFF_DISTANCE = 100
local MIN_TRAVEL_DISTANCE = 4

local function findSafeTeleportDestination(ply)
	local startPos = ply:GetPos() + vec_up
	-- Aim line trace from player
	local playerTrace = util.GetPlayerTrace(ply)
	playerTrace.mask = TELEPORT_MASK
	local lineTrace = util.TraceLine(playerTrace)

	local function isInWorld(pos)
		if SERVER then return util.IsInWorld(pos) end

		return true
	end

	local aimHitPos = lineTrace.HitPos
	local wasInWorld = isInWorld(startPos)
	-- Back off slightly from the hit position in the opposite of the aim direction, clamped
	local backOffVector = startPos - aimHitPos
	local backOffLength = math.min(backOffVector:Length(), MAX_BACKOFF_DISTANCE)

	if backOffLength > 0 then
		backOffVector:Normalize()
		backOffVector = backOffVector * backOffLength
	else
		backOffVector = Vector(0, 0, 0)
	end

	-- If starting outside the world but the opposite side is valid, flip the normal
	if not wasInWorld and isInWorld(aimHitPos - lineTrace.HitNormal * SURFACE_OFFSET) then
		lineTrace.HitNormal = -lineTrace.HitNormal
	end

	-- Start a bit away from the surface we hit
	local start = aimHitPos + lineTrace.HitNormal * SURFACE_OFFSET

	if math.abs(aimHitPos.z - start.z) < 2 then
		aimHitPos.z = start.z
	end

	local tracedata = {
		start = start,
		endpos = aimHitPos,
		filter = ply,
		mins = trMins,
		maxs = trMaxs,
		mask = TELEPORT_MASK
	}

	local function traceHullFrom(newStart)
		tracedata.start = newStart

		return util.TraceHull(tracedata)
	end

	local hullTrace = util.TraceHull(tracedata)

	-- Try a few different candidate starts if the first is invalid
	if hullTrace.StartSolid or (wasInWorld and not isInWorld(hullTrace.HitPos)) then
		hullTrace = traceHullFrom(aimHitPos + lineTrace.HitNormal * SMALL_NUDGE)
	end

	if hullTrace.StartSolid or (wasInWorld and not isInWorld(hullTrace.HitPos)) then
		hullTrace = traceHullFrom(ply:GetPos() + vec_up)
	end

	if hullTrace.StartSolid or (wasInWorld and not isInWorld(hullTrace.HitPos)) then
		hullTrace = traceHullFrom(aimHitPos + backOffVector)
	end

	if hullTrace.StartSolid then return false, "unable to perform teleportation without getting stuck" end
	if not isInWorld(hullTrace.HitPos) and wasInWorld then return false, "couldn't teleport there" end
	-- If falling too fast, counteract vertical speed to avoid damage/stuckness
	local verticalSpeed = math.abs(ply:GetVelocity().z)

	if verticalSpeed > 100 * math.sqrt(sv_gravity:GetInt()) then
		ply:EmitSound("physics/concrete/boulder_impact_hard" .. math.random(1, 4) .. ".wav")
		ply:SetVelocity(-ply:GetVelocity())
	end

	local prev = ply:GetPos()
	local newpos = hullTrace.HitPos
	if newpos:Distance(prev) < MIN_TRAVEL_DISTANCE then return ply:GetPos() end

	return newpos
end

Arcane:RegisterSpell({
	id = "teleport",
	name = "Teleport",
	description = "Teleport to your aim point within range, finding a safe landing spot.",
	category = Arcane.CATEGORIES.UTILITY,
	level_required = 3,
	knowledge_cost = 2,
	cooldown = 0.1,
	cost_type = Arcane.COST_TYPES.COINS,
	cost_amount = 30,
	cast_time = 0.1,
	range = 0,
	icon = "icon16/arrow_right.png",
	has_target = false,
	cast_anim = "becon",
	can_cast = function(caster)
		local ok, reason = hook.Run("CanPlyTeleport", caster)
		if ok == false then return false, reason or "Something is preventing teleporting" end

		return true
	end,
	cast = function(caster, _, _, _)
		if not SERVER then return true end
		local dest = findSafeTeleportDestination(caster)

		if not dest then
			caster:EmitSound("buttons/button8.wav", 70, 100)

			return false
		end

		local oldPos = caster:GetPos()

		-- Departure effects
		do
			local ed = EffectData()
			ed:SetOrigin(oldPos + Vector(0, 0, 4))
			util.Effect("cball_explode", ed, true, true)
		end

		-- Actually move the player, zero their velocity, and ensure not stuck
		caster:SetVelocity(-caster:GetVelocity())
		caster:SetPos(dest)
		caster:SetGroundEntity(NULL)

		if dest:Distance(oldPos) < 128 then
			caster:EmitSound("physics/plaster/drywall_footstep" .. math.random(3) .. ".wav")
		else
			caster:EmitSound("ui/freeze_cam.wav")
		end

		hook.Run("PlayerTeleported", caster, dest, oldPos, {
			teleporting_type = "arcana"
		})

		return true
	end
})

if CLIENT then
	-- Show a small targeting circle at the prospective landing spot while casting
	hook.Add("Arcana_BeginCastingVisuals", "Arcana_Teleport_Circle", function(caster, spellId, castTime, _forwardLike)
		if spellId ~= "teleport" then return end

		return Arcane:CreateFollowingCastCircle(caster, spellId, castTime, {
			color = Color(140, 200, 255, 255),
			size = 18,
			intensity = 3,
			positionResolver = function(c)
				if c:IsPlayer() then
					return findSafeTeleportDestination(c)
				else
					return Arcane:ResolveGroundTarget(c, 1000)
				end
			end
		})
	end)
end