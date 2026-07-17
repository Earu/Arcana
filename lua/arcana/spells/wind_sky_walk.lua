if SERVER then
	util.AddNetworkString("Arcana_SkyWalk_Start")
	util.AddNetworkString("Arcana_SkyWalk_Stop")
end

-- Sky Walk
-- Sustained wind levitation: fly freely in any direction at 2x run speed with real
-- collision (not noclip) for a fixed window. While aloft, Wind Dash turns windborne —
-- no ground check, any direction, double launch force (handled in wind_dash.lua).
local DURATION   = 45 -- Seconds of levitation
local SPEED_MULT = 4  -- Flight speed = run speed * this
-- The windborne-dash yield window is owned by wind_dash.lua, which sets
-- ply.ArcanaSkyWalkDashUntil; SetupMove below simply honors that timestamp.

-- Levitation state lives on the player (ply._ArcanaSkyWalk = { untilT, oldMoveType,
-- oldGravity }), matching the ArcanaWindDash* player-field convention. wind_dash.lua
-- reads the same field to know when to empower a dash — no shared globals involved.
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
	ply.ArcanaSkyWalkDashUntil = nil
	ply.ArcanaSkyWalkDashVel = nil
	-- Drop any windborne-dash flags so fall-damage immunity can't leak past the levitation
	ply.ArcanaWindDashActive = false
	ply.ArcanaWindDashLeaped = false
	ply.ArcanaWindDashDived  = false

	if SERVER then
		ply:SetNW2Bool("ArcanaSkyWalk", false)
		timer.Remove("Arcana_SkyWalk_Expire_" .. ply:EntIndex())
		net.Start("Arcana_SkyWalk_Stop", true)
		net.WriteEntity(ply)
		net.Broadcast()
	end
end

-- Pose the levitating player as if swimming. Shared so remote players animate too.
-- Reads a networked flag (not the server-only state field) because animation is
-- resolved clientside. Registered unconditionally; hook.Add replaces by name.
hook.Add("CalcMainActivity", "Arcana_SkyWalk_Anim", function(ply)
	if not ply:GetNW2Bool("ArcanaSkyWalk", false) then return end
	return ACT_MP_SWIM, -1
end)

-- Keep the swim cycle calm. The default UpdateAnimation scales playback rate with
-- velocity (up to 2x), so at flight/dash speeds the arms thrash. Force a gentle,
-- steady rate and suppress the default calc (returning a value skips GM:UpdateAnimation).
hook.Add("UpdateAnimation", "Arcana_SkyWalk_AnimRate", function(ply)
	if not ply:GetNW2Bool("ArcanaSkyWalk", false) then return end
	ply:SetPlaybackRate(0.75)
	return true
end)

if SERVER then
	hook.Add("SetupMove", "Arcana_SkyWalk_Move", function(ply, mv, cmd)
		local st = ply._ArcanaSkyWalk
		if not istable(st) then return end

		if not st.untilT or CurTime() >= st.untilT then
			endSkyWalk(ply)
			return
		end

		if ply:GetMoveType() ~= MOVETYPE_FLY then
			ply:SetMoveType(MOVETYPE_FLY)
		end
		ply:SetGroundEntity(NULL)

		-- Windborne dash in progress: force the stored dash velocity and raise the speed
		-- cap so MOVETYPE_FLY's per-tick clamp/friction can't crush the impulse. This keeps
		-- the dash carrying at full speed for its window, then normal flight resumes.
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

		local speed = ply:GetRunSpeed() * SPEED_MULT
		mv:SetMaxClientSpeed(speed)
		mv:SetMaxSpeed(speed)

		-- Wish direction from WASD (relative to view, including pitch) + Space/Ctrl vertical.
		local ang  = mv.GetMoveAngles and mv:GetMoveAngles() or mv:GetAngles()
		local wish = ang:Forward() * mv:GetForwardSpeed() + ang:Right() * mv:GetSideSpeed()

		local climb = 0
		if cmd:KeyDown(IN_JUMP) then climb = climb + 1 end
		if cmd:KeyDown(IN_DUCK) then climb = climb - 1 end
		wish.z = wish.z + climb * speed

		local cur = mv:GetVelocity()
		local dt  = engine.TickInterval()

		if wish:LengthSqr() > 0 then
			wish:Normalize()
			wish:Mul(speed)
			mv:SetVelocity(cur + (wish - cur) * math.Clamp(10 * dt, 0, 1))
		else
			-- Gentle drift-to-stop when there's no input, so hovering feels controlled.
			mv:SetVelocity(cur * (1 - math.Clamp(8 * dt, 0, 1)))
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
	description = "Levitate and fly freely in any direction for 45s. While aloft, Wind Dash surges in any direction with no need for solid ground.",
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
		if caster:GetMoveType() ~= MOVETYPE_WALK then return false, "Must be on solid footing to take flight" end
		return true
	end,

	cast = function(caster)
		if CLIENT then return true end
		if not IsValid(caster) then return false end

		caster._ArcanaSkyWalk = {
			untilT      = CurTime() + DURATION,
			oldMoveType = caster:GetMoveType(),
			oldGravity  = caster:GetGravity(),
		}

		caster:SetMoveType(MOVETYPE_FLY)
		caster:SetGravity(0)
		caster:SetGroundEntity(NULL)
		caster:SetNW2Bool("ArcanaSkyWalk", true) -- drives the swim pose clientside

		-- Fallback in case SetupMove stops running (no inputs) before expiry.
		local key = "Arcana_SkyWalk_Expire_" .. caster:EntIndex()
		timer.Remove(key)
		timer.Create(key, DURATION + 0.05, 1, function()
			if IsValid(caster) then endSkyWalk(caster) end
		end)

		local pos = caster:WorldSpaceCenter()
		sound.Play("ambient/wind/wind_hit1.wav", pos, 72, 90)
		caster:EmitSound("ambient/wind/wind_snippet" .. math.random(1, 5) .. ".wav", 75, 110)

		net.Start("Arcana_SkyWalk_Start", true)
		net.WriteEntity(caster)
		net.WriteFloat(DURATION)
		net.Broadcast()

		return true
	end,

	trigger_phrase_aliases = {
		"sky walk",
		"levitate",
		"take flight",
	},
})

if CLIENT then
	local active = {}

	net.Receive("Arcana_SkyWalk_Start", function()
		local ply  = net.ReadEntity()
		local life = net.ReadFloat() or DURATION
		if not IsValid(ply) then return end

		active[ply] = {
			untilT  = CurTime() + life,
			emitter = ParticleEmitter(ply:WorldSpaceCenter()),
			nextP   = 0,
		}
	end)

	net.Receive("Arcana_SkyWalk_Stop", function()
		local ply = net.ReadEntity()
		local st  = active[ply]
		if st and st.emitter then st.emitter:Finish() end
		active[ply] = nil
	end)

	-- Pale wind wisps swirling up around the levitating player.
	hook.Add("Think", "Arcana_SkyWalk_FX", function()
		local now = CurTime()

		for ply, st in pairs(active) do
			if not IsValid(ply) or now >= st.untilT then
				if st.emitter then st.emitter:Finish() end
				active[ply] = nil
				continue
			end

			if now < st.nextP then continue end
			st.nextP = now + 0.03

			local em = st.emitter
			if not em then continue end

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
					-- Swirl tangentially and drift upward to sell the levitation.
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
