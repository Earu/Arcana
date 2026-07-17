-- Sky Walk
-- Wear the wind for 45s. Like an elytra: leaving the ground (a jump or stepping off a ledge)
-- opens the glide — steer by looking, dive to build speed, climb to trade it back (real collision,
-- not noclip). Touch ground and it retracts — you land and it redeploys next time you're airborne,
-- until the window runs out. While gliding, Wind Dash is windborne: a brief charge (fake cast),
-- then a hard propel in any direction — your "firework rocket". (Dash logic lives in wind_dash.lua.)
local DURATION = 45 -- Seconds the spell stays armed

-- Elytra-style glide. You don't thrust with WASD; you steer by looking and trade altitude
-- for speed: dive to accelerate, level out to glide, pull up to zoom-climb (bleeding speed).
-- The windborne dash is your boost (like a firework rocket).
local GLIDE_GRAVITY = 500  -- Constant downward pull (u/s^2); lower = floatier
local GLIDE_TURN    = 3.0  -- How fast your heading swings toward where you look
local GLIDE_PITCH   = 900  -- Dive acceleration / climb deceleration along the look axis
local GLIDE_DRAG    = 0.2  -- Air resistance bleed
local DEPLOY_SPEED  = 500  -- Minimum forward speed granted when you deploy the glide

-- The windborne-dash windows are owned by wind_dash.lua, which sets ply.ArcanaSkyWalkChargeUntil
-- (charge/hold) and ply.ArcanaSkyWalkDashUntil (propel); SetupMove below honors those timestamps.

-- State lives on the player: ply._ArcanaSkyWalk = { untilT, oldMoveType, oldGravity,
-- gliding, deployAt }. `gliding` is the elytra-deployed flag; wind_dash.lua reads it to
-- know when a dash is windborne. Matches the ArcanaWindDash* player-field convention.
local function isActive(ply)
	if not IsValid(ply) then return false end
	local st = ply._ArcanaSkyWalk
	return istable(st) and st.untilT ~= nil and CurTime() < st.untilT
end

-- End levitation and restore normal movement. Server-authoritative.
local function endSkyWalk(ply)
	if not IsValid(ply) then return end

	local st = ply._ArcanaSkyWalk
	if not istable(st) then return end

	if st.oldMoveType ~= nil then ply:SetMoveType(st.oldMoveType) end
	if st.oldGravity ~= nil then ply:SetGravity(st.oldGravity) end

	ply._ArcanaSkyWalk = nil
	ply.ArcanaSkyWalkChargeUntil = nil
	ply.ArcanaSkyWalkDashUntil = nil
	ply.ArcanaSkyWalkDashVel = nil
	-- Drop any windborne-dash flags so fall-damage immunity can't leak past the levitation
	ply.ArcanaWindDashActive = false
	ply.ArcanaWindDashLeaped = false
	ply.ArcanaWindDashDived  = false

	if SERVER then
		ply:SetNW2Bool("ArcanaSkyWalkGliding", false)
		ply:SetNW2Float("ArcanaSkyWalkChargeUntil", 0)
		ply:SetNW2Float("ArcanaSkyWalkDashUntil", 0)
		timer.Remove("Arcana_SkyWalk_Expire_" .. ply:EntIndex())
	end
end

-- Retract the glide but keep Sky Walk armed: land the player and let them redeploy.
local function retractGlide(ply, st)
	st.gliding = false
	if st.oldMoveType ~= nil then ply:SetMoveType(st.oldMoveType) end
	if st.oldGravity ~= nil then ply:SetGravity(st.oldGravity) end

	ply.ArcanaSkyWalkChargeUntil = nil
	ply.ArcanaSkyWalkDashUntil = nil
	ply.ArcanaSkyWalkDashVel = nil

	if SERVER then
		ply:SetNW2Bool("ArcanaSkyWalkGliding", false)
		ply:SetNW2Float("ArcanaSkyWalkChargeUntil", 0)
		ply:SetNW2Float("ArcanaSkyWalkDashUntil", 0)
	end
end

-- Pose the levitating player. Normally swimming; during a windborne dash, tuck into a
-- crouch angled along travel (SetAllowFullRotation lets the model pitch to the aim/dash
-- direction), then return to swimming. Reads networked flags because animation is resolved
-- clientside. Shared so remote players animate too; registered unconditionally.
hook.Add("CalcMainActivity", "Arcana_SkyWalk_Anim", function(ply)
	if not ply:GetNW2Bool("ArcanaSkyWalkGliding", false) then
		-- Restore normal yaw-only rotation if we had toggled full rotation for this player.
		if CLIENT and ply._arcanaSkyWalkFullRot then
			ply:SetAllowFullRotation(false)
			ply._arcanaSkyWalkFullRot = false
		end
		return
	end

	-- Crouch during the charge/windup (the fake cast), then swim once propelled.
	local charging = CurTime() < ply:GetNW2Float("ArcanaSkyWalkChargeUntil", 0)

	-- Full rotation only while charging, so the tucked body pitches toward the aim.
	if CLIENT and ply._arcanaSkyWalkFullRot ~= charging then
		ply:SetAllowFullRotation(charging)
		ply._arcanaSkyWalkFullRot = charging
	end

	if charging then
		return ACT_MP_CROUCH_IDLE, -1
	end

	return ACT_MP_SWIM, -1
end)

-- Keep the swim cycle calm. The default UpdateAnimation scales playback rate with
-- velocity (up to 2x), so at flight/dash speeds the arms thrash. Force a gentle,
-- steady rate and suppress the default calc (returning a value skips GM:UpdateAnimation).
hook.Add("UpdateAnimation", "Arcana_SkyWalk_AnimRate", function(ply)
	if not ply:GetNW2Bool("ArcanaSkyWalkGliding", false) then return end
	ply:SetPlaybackRate(0.01)
	return true
end)

if SERVER then
	hook.Add("SetupMove", "Arcana_SkyWalk_Move", function(ply, mv, cmd)
		local st = ply._ArcanaSkyWalk
		if not istable(st) then return end

		-- Expire the whole armed window.
		if not st.untilT or CurTime() >= st.untilT then
			endSkyWalk(ply)
			return
		end

		-- Armed but not deployed: auto-deploy the glide the moment we're airborne (clear of the
		-- ground). No key needed — while Sky Walk is armed you're "wearing wings", so a jump or
		-- stepping off a ledge opens the glide. Checked EVERY tick, which is why it works where a
		-- jump-press check didn't: the press was always grounded and the engine hides IN_JUMP mid-air.
		if not st.gliding then
			local grounded = util.TraceLine({
				start  = ply:GetPos(),
				endpos = ply:GetPos() - Vector(0, 0, 24),
				filter = ply,
				mask   = MASK_PLAYERSOLID,
			}).Hit

			if grounded then return end -- still on the ground; not gliding yet

			st.gliding = true
			st.deployAt = CurTime()
			st.justDeployed = true
			ply:SetMoveType(MOVETYPE_FLY)
			ply:SetGravity(0)
			ply:SetGroundEntity(NULL)
			ply:SetNW2Bool("ArcanaSkyWalkGliding", true)
			sound.Play("ambient/wind/wind_hit1.wav", ply:WorldSpaceCenter(), 72, 105)
		end

		if ply:GetMoveType() ~= MOVETYPE_FLY then
			ply:SetMoveType(MOVETYPE_FLY)
		end
		ply:SetGroundEntity(NULL)

		-- We drive velocity directly; stop the engine adding its own WASD acceleration
		-- (no thrust — steering is purely by looking, elytra-style).
		mv:SetForwardSpeed(0)
		mv:SetSideSpeed(0)
		mv:SetUpSpeed(0)

		local dt = engine.TickInterval()

		-- First tick after deploy: launch along the look at a minimum speed.
		if st.justDeployed then
			st.justDeployed = nil
			local aim = ply:GetAimVector()
			mv:SetVelocity(aim * math.max(mv:GetVelocity():Length(), DEPLOY_SPEED))
		end

		-- Charging a windborne dash: hover in place while the "cast" builds, then propel.
		if ply.ArcanaSkyWalkChargeUntil and CurTime() < ply.ArcanaSkyWalkChargeUntil then
			mv:SetVelocity(mv:GetVelocity() * math.Clamp(1 - 12 * dt, 0, 1))
			return
		end

		-- Propelling: force the stored dash velocity and raise the speed cap so MOVETYPE_FLY's
		-- per-tick clamp/friction can't crush the impulse. Carries at full speed for its window.
		if ply.ArcanaSkyWalkDashUntil and CurTime() < ply.ArcanaSkyWalkDashUntil then
			local dv = ply.ArcanaSkyWalkDashVel
			if dv then
				local s = dv:Length()
				mv:SetMaxClientSpeed(s)
				mv:SetMaxSpeed(s)
				mv:SetVelocity(dv)
			end
			return
		end

		-- Base movement: elytra glide. Steer by looking; dive for speed, climb to trade it.
		local vel = mv:GetVelocity()
		local aim = ply:GetAimVector()

		-- Swing heading toward where you look, preserving speed (converts dive <-> forward).
		local spd = vel:Length()
		if spd > 1 then
			local dir = vel / spd
			dir = (dir + (aim - dir) * math.Clamp(GLIDE_TURN * dt, 0, 1)):GetNormalized()
			vel = dir * spd
		end

		-- Look down (aim.z < 0) to accelerate along the look axis; look up to bleed speed.
		vel = vel + aim * (-aim.z * GLIDE_PITCH * dt)
		-- Gravity always pulls down, independent of heading — you sink unless you keep diving.
		vel.z = vel.z - GLIDE_GRAVITY * dt
		-- Air drag — this alone sets a natural terminal speed. No hard cap.
		vel = vel * (1 - GLIDE_DRAG * dt)

		-- Keep the engine's speed clamp far out of the way so MOVETYPE_FLY never limits velocity.
		mv:SetMaxClientSpeed(100000)
		mv:SetMaxSpeed(100000)
		mv:SetVelocity(vel)

		-- Landing: touching ground retracts the glide (Sky Walk stays armed to redeploy).
		local foot = ply:GetPos()
		local tr = util.TraceLine({
			start  = foot + Vector(0, 0, 10),
			endpos = foot - Vector(0, 0, 8),
			filter = ply,
			mask   = MASK_PLAYERSOLID,
		})
		if tr.Hit and (not st.deployAt or CurTime() > st.deployAt + 0.2) then
			retractGlide(ply, st)
			sound.Play("physics/body/body_medium_impact_soft" .. math.random(1, 7) .. ".wav", foot, 62, 105)
		end
	end)

	hook.Add("PlayerDeath", "Arcana_SkyWalk_Cleanup", function(ply)
		if ply._ArcanaSkyWalk then endSkyWalk(ply) end
	end)

	hook.Add("PlayerSpawn", "Arcana_SkyWalk_Cleanup", function(ply)
		if ply._ArcanaSkyWalk then endSkyWalk(ply) end
	end)

	hook.Add("PlayerDisconnected", "Arcana_SkyWalk_Cleanup", function(ply)
		if ply and ply._ArcanaSkyWalk then endSkyWalk(ply) end
	end)
end

Arcana:RegisterSpell({
	id = "wind_sky_walk",
	name = "Sky Walk",
	description = "Take to the sky and glide for 45s — steer by looking, dive to build speed. While aloft, Wind Dash charges, then hurls you in any direction with no need for solid ground.",
	category = Arcana.CATEGORIES.UTILITY,
	level_required = 35,
	knowledge_cost = 3,
	cooldown = 25,
	cost_type = Arcana.COST_TYPES.COINS,
	cost_amount = 150,
	cast_time = 1.0,
	range = 0,
	has_target = false,

	can_cast = function(caster)
		if not IsValid(caster) then return false, "Invalid caster" end
		if isActive(caster) then return false, "You are already sky walking" end
		return true
	end,

	cast = function(caster)
		if CLIENT then return true end
		if not IsValid(caster) then return false end

		-- Arm the elytra. The glide auto-deploys once airborne (handled in SetupMove).
		caster._ArcanaSkyWalk = {
			untilT      = CurTime() + DURATION,
			oldMoveType = caster:GetMoveType(),
			oldGravity  = caster:GetGravity(),
			gliding     = false,
		}

		-- Fallback to end the armed window even if SetupMove stops running.
		local key = "Arcana_SkyWalk_Expire_" .. caster:EntIndex()
		timer.Remove(key)
		timer.Create(key, DURATION + 0.05, 1, function()
			if IsValid(caster) then endSkyWalk(caster) end
		end)

		sound.Play("ambient/wind/wind_hit1.wav", caster:WorldSpaceCenter(), 72, 90)
		caster:EmitSound("ambient/wind/wind_snippet" .. math.random(1, 5) .. ".wav", 75, 110)

		return true
	end,

	trigger_phrase_aliases = {
		"sky walk",
		"levitate",
		"take flight",
	},
})

if CLIENT then
	-- Pale wind wisps trailing anyone currently gliding. Driven by the networked flag so
	-- the trail appears on deploy and clears on land/expiry without extra messages.
	local emitters = {}
	local nextP    = {}

	hook.Add("Think", "Arcana_SkyWalk_FX", function()
		local now = CurTime()

		-- Drop emitters for players who left.
		for ply, em in pairs(emitters) do
			if not IsValid(ply) then
				if em then em:Finish() end
				emitters[ply] = nil
			end
		end

		for _, ply in ipairs(player.GetAll()) do
			if not ply:GetNW2Bool("ArcanaSkyWalkGliding", false) then
				if emitters[ply] then emitters[ply]:Finish() emitters[ply] = nil end
				continue
			end

			emitters[ply] = emitters[ply] or ParticleEmitter(ply:WorldSpaceCenter())
			local em = emitters[ply]
			if not em then continue end

			if (nextP[ply] or 0) > now then continue end
			nextP[ply] = now + 0.03

			local mins, maxs = ply:OBBMins(), ply:OBBMaxs()
			local base = ply:GetPos()
			local radius = math.max(maxs.x - mins.x, maxs.y - mins.y) * 0.6

			for i = 1, 2 do
				local ang  = math.Rand(0, 360)
				local rvec = Vector(math.cos(math.rad(ang)), math.sin(math.rad(ang)), 0)
				local spawn = base + rvec * radius + Vector(0, 0, math.Rand(0, maxs.z))
				local p = em:Add("particle/particle_smokegrenade", spawn)
				if p then
					p:SetDieTime(math.Rand(0.5, 0.9))
					p:SetStartAlpha(math.Rand(40, 80))
					p:SetEndAlpha(0)
					p:SetStartSize(math.Rand(6, 12))
					p:SetEndSize(math.Rand(14, 22))
					p:SetRoll(math.Rand(0, 360))
					p:SetRollDelta(math.Rand(-2, 2))
					p:SetColor(200, 225, 255)
					-- Swirl tangentially and drift with the glide.
					local tangent = rvec:Cross(Vector(0, 0, 1)) * math.Rand(20, 45)
					p:SetVelocity(tangent + Vector(0, 0, math.Rand(15, 40)))
					p:SetAirResistance(90)
					p:SetGravity(Vector(0, 0, 6))
					p:SetLighting(false)
					p:SetCollide(false)
				end
			end
		end
	end)
end
