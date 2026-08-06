if SERVER then
	util.AddNetworkString("Arcana_WindDash")
	util.AddNetworkString("Arcana_WindDashLand")
	util.AddNetworkString("Arcana_WindDash_SkyBurst")
	util.AddNetworkString("Arcana_WindDash_SkyCharge")
end

-- Wind Dash
-- Aim upward while grounded to leap skyward; aim downward while airborne to crash back to earth.
-- Grants fall damage immunity while active. Hard landing deals speed-scaled damage to entities below.
local LEAP_FORCE  = 1250 -- Launch force for the upward leap
local DIVE_FORCE  = 2000 -- Launch force for the downward crash
local EMPOWERED_FORCE = LEAP_FORCE * 6 -- Windborne dash launch force while Sky Walk is active
local EMPOWERED_YIELD = 1.0 -- How long Sky Walk's flight control yields to let this dash carry
local EMPOWERED_CHARGE = 0.4 -- Windup (fake cast) before the windborne dash propels you

-- Sky Walk (wind_sky_walk.lua) stores its state on the player as _ArcanaSkyWalk.
-- The dash is only windborne while actually gliding (elytra deployed), not merely armed.
local function skyWalkActive(ply)
	local st = ply._ArcanaSkyWalk
	return istable(st) and st.gliding == true and st.untilT ~= nil and CurTime() < st.untilT
end
local LEAP_PITCH  = -10  -- Eye pitch threshold: below this = looking "up enough" to leap
local DIVE_PITCH  =  5   -- Eye pitch threshold: above this = looking "down enough" to dive
local LAND_DAMAGE_SPEED = 700 -- Speed at which a heavy landing plays heavy impact sounds

Arcana.RegisterSpell({
	id = "wind_dash",
	name = "Wind Dash",
	description = "Aim upward to launch yourself skyward. Aim downward to crash back to earth.",
	category = Arcana.CATEGORIES.UTILITY,
	level_required = 8,
	knowledge_cost = 2,
	cooldown = 1.0,
	cost_type = Arcana.COST_TYPES.COINS,
	cost_amount = 25,
	cast_time = 0.3,
	range = 0,
	has_target = false,
	cast_anim = "forward",

	can_cast = function(caster)
		if not IsValid(caster) then return false, "Invalid caster" end
		-- Windborne (Sky Walk active): dash freely, no ground check or pitch gate.
		if skyWalkActive(caster) then return true end
		if caster:GetMoveType() ~= MOVETYPE_WALK then return false, "Cannot wind dash in this state" end

		local pitch = caster:EyeAngles().pitch

		if pitch < LEAP_PITCH and not caster.ArcanaWindDashLeaped then
			return true -- aiming up + haven't leaped yet → leap
		end

		if pitch > DIVE_PITCH and not caster:IsOnGround() and not caster.ArcanaWindDashDived then
			return true -- aiming down + airborne + haven't dived yet → dive
		end

		if caster.ArcanaWindDashLeaped and caster.ArcanaWindDashDived then
			return false, "You must land before dashing again"
		end

		if caster.ArcanaWindDashLeaped then
			return false, "Already dashing, aim downward to dive, or land to reset"
		end

		if caster.ArcanaWindDashDived then
			return false, "Already diving, land to reset"
		end

		return false, "Aim upward to dash into the sky, or aim downward to dive back to earth"
	end,

	cast = function(caster, _, _, ctx)
		if not SERVER then return true end

		-- Windborne dash: Sky Walk empowers Wind Dash. It's a "fake cast", a brief charge
		-- where you hover in a crouch and the magic circle + particles gather, then a hard
		-- propel in any direction with no ground/pitch gate. Levitation owns movement, so we
		-- don't set the ArcanaWindDash* land flags (the land hook never fires under FLY).
		if skyWalkActive(caster) then
			local chargeEnd = CurTime() + EMPOWERED_CHARGE

			-- Charge phase: SetupMove hovers the player here while the cast builds.
			caster.ArcanaSkyWalkChargeUntil = chargeEnd
			caster.ArcanaSkyWalkDashVel = nil
			caster.ArcanaSkyWalkDashUntil = nil
			caster:SetNW2Float("ArcanaSkyWalkChargeUntil", chargeEnd)
			caster:SetNW2Float("ArcanaSkyWalkDashUntil", 0)

			local pos = caster:WorldSpaceCenter()
			sound.Play("ambient/wind/wind_snippet" .. math.random(1, 5) .. ".wav", pos, 72, 55)
			sound.Play("weapons/physcannon/physcannon_charge.wav", pos, 78, 105)

			-- Magic circle + gathering particles during the charge.
			net.Start("Arcana_WindDash_SkyCharge", true)
			net.WriteVector(pos)
			net.WriteEntity(caster)
			net.WriteVector(caster:GetAimVector())
			net.WriteFloat(EMPOWERED_CHARGE)
			net.Broadcast()

			-- Release: propel along wherever they're aiming at the end of the charge.
			timer.Simple(EMPOWERED_CHARGE, function()
				if not IsValid(caster) or not skyWalkActive(caster) then return end

				local aim = caster:GetAimVector()
				local dashVel = aim * EMPOWERED_FORCE
				caster:SetVelocity(dashVel)
				caster.ArcanaSkyWalkChargeUntil = nil
				caster.ArcanaSkyWalkDashVel = dashVel
				caster.ArcanaSkyWalkDashUntil = CurTime() + EMPOWERED_YIELD
				caster:SetNW2Float("ArcanaSkyWalkChargeUntil", 0)
				caster:SetNW2Float("ArcanaSkyWalkDashUntil", CurTime() + EMPOWERED_YIELD)

				local rpos = caster:WorldSpaceCenter()
				-- The "bang": a low concussive boom at the release.
				sound.Play("ambient/wind/wind_roar1.wav", rpos, 90, 150)
				sound.Play("ambient/wind/wind_hit1.wav", rpos, 85, 70)

				net.Start("Arcana_WindDash", true)
				net.WriteEntity(caster)
				net.WriteVector(aim)
				net.WriteBool(false)
				net.Broadcast()

				-- Wind explosion + physgun-colored impact disc at the release point.
				net.Start("Arcana_WindDash_SkyBurst", true)
				net.WriteVector(rpos)
				net.WriteEntity(caster)
				net.WriteVector(aim)
				net.Broadcast()
			end)

			return true
		end

		local aimVec   = caster:GetAimVector()
		local pitch    = caster:EyeAngles().pitch
		local isDive   = pitch > DIVE_PITCH and not caster:IsOnGround()
		local startPos = caster:WorldSpaceCenter()

		if isDive then
			caster:SetVelocity(aimVec * DIVE_FORCE)
			caster.ArcanaWindDashActive = true
			caster.ArcanaWindDashDived  = true
			caster.ArcanaWindDashLast   = CurTime() + 0.1

			sound.Play("ambient/wind/wind_roar1.wav", startPos, 85, 80)
			timer.Simple(0.05, function()
				if IsValid(caster) then
					sound.Play("ambient/wind/wind_snippet" .. math.random(1, 5) .. ".wav", startPos, 80, 75)
				end
			end)
		else
			caster:SetVelocity(aimVec * LEAP_FORCE)
			caster:SetGroundEntity(NULL)
			caster.ArcanaWindDashActive  = true
			caster.ArcanaWindDashLeaped  = true
			caster.ArcanaWindDashDived   = false
			caster.ArcanaWindDashLast    = CurTime() + 0.1

			sound.Play("ambient/wind/wind_roar1.wav", startPos, 85, 140)
			sound.Play("ambient/wind/wind_snippet" .. math.random(1, 5) .. ".wav", startPos, 80, 120)
			timer.Simple(0.05, function()
				if IsValid(caster) then
					sound.Play("weapons/physcannon/physcannon_charge.wav", startPos, 75, 150)
				end
			end)
		end

		net.Start("Arcana_WindDash", true)
		net.WriteEntity(caster)
		net.WriteVector(aimVec)
		net.WriteBool(isDive)
		net.Broadcast()

		return true
	end
})

if SERVER then
	-- No fall damage while a wind dash is active
	hook.Add("GetFallDamage", "Arcana_WindDash_FallNegate", function(ply)
		if ply.ArcanaWindDashActive then return 0 end
	end)

	hook.Add("OnPlayerHitGround", "Arcana_WindDash_Land", function(ply, inWater, onFloater, speed)
		if not ply.ArcanaWindDashActive then return end
		-- Small grace window so the hook doesn't fire the same tick as the dash
		if not ply.ArcanaWindDashLast or ply.ArcanaWindDashLast >= CurTime() then return end

		ply.ArcanaWindDashActive = false
		ply.ArcanaWindDashLeaped = false
		ply.ArcanaWindDashDived  = false

		if inWater then return end

		local landPos = ply:GetPos()

		-- Heavy landing: deep thud + wind burst
		sound.Play("physics/concrete/concrete_impact_hard" .. math.random(1, 3) .. ".wav", landPos, 75, math.random(80, 90))
		sound.Play("ambient/wind/wind_snippet" .. math.random(1, 5) .. ".wav",             landPos, 65, math.random(90, 105))

		-- Deal speed-scaled damage to whatever entity was landed on
		local ent = ply:GetGroundEntity()
		if IsValid(ent) and ent.TakeDamage and ent:GetClass() ~= "worldspawn" then
			ent:TakeDamage(speed * 1.5, ply, game.GetWorld())
		end

		net.Start("Arcana_WindDashLand", true)
		net.WriteEntity(ply)
		net.WriteFloat(speed)
		net.Broadcast()
	end)
end

if CLIENT then
	-- While gliding, a windborne dash's charge circle stands in for the cast circle, so hide
	-- the default cast circle in that context (returning true suppresses it).
	hook.Add("Arcana_BeginCastingVisuals", "Arcana_WindDash_HideCast", function(caster, spellId)
		if spellId == "wind_dash" and IsValid(caster) and caster:GetNW2Bool("ArcanaSkyWalkGliding", false) then
			return true
		end
	end)

	-- Launch pose during the windborne-dash charge: pivot the whole body at the feet so its
	-- up-axis points along the aim (head leads, feet planted on the charge circle). Reads as
	-- the player coiled to propel forward off the circle. Render-only; doesn't touch aiming.
	-- No manual reset needed: render angles auto-reset to the player's angles each frame right
	-- after GM:UpdateAnimation, so simply not setting it (when not charging) leaves it normal.
	hook.Add("PrePlayerDraw", "Arcana_WindDash_ChargePose", function(ply)
		if not ply:GetNW2Bool("ArcanaSkyWalkGliding", false) then return end
		if CurTime() >= ply:GetNW2Float("ArcanaSkyWalkChargeUntil", 0) then return end

		-- Lay the body's feet->head axis along the aim (head-first, belly down), so it reads as
		-- pushing off the charge circle. AngleEx uses `belly` as forward and `aim` as the up
		-- reference, so the model's UP (feet->head) ends up along aim at any pitch.
		local aim = ply:GetAimVector()
		local belly = aim:Cross(ply:EyeAngles():Right()) -- ⟂ aim, points "down/belly"
		if belly:LengthSqr() < 1e-6 then belly = ply:EyeAngles():Forward() end
		ply:SetRenderAngles(belly:AngleEx(aim))
	end)

	-- Expanding, fading impact discs from windborne dashes: each faces along the dash
	-- direction and is tinted with the caster's physgun color, so it reads as a surface
	-- the player bounced off of.
	local skyRings = {}
	local RING_GLOW = Material("sprites/light_glow02_add")
	local RING_EDGE = Material("effects/select_ring")

	-- The caster's physgun/weapon color as a Color (falls back to wind-blue).
	local function physgunColor(ply)
		if IsValid(ply) and ply.GetWeaponColor then
			local wc = ply:GetWeaponColor()
			return Color(math.Clamp(wc.x * 255, 0, 255), math.Clamp(wc.y * 255, 0, 255), math.Clamp(wc.z * 255, 0, 255))
		end
		return Color(120, 180, 255)
	end

	hook.Add("PostDrawTranslucentRenderables", "Arcana_WindDash_SkyRing", function(bDepth, bSky)
		if bDepth or bSky then return end
		if #skyRings == 0 then return end

		local now = CurTime()
		for i = #skyRings, 1, -1 do
			local r = skyRings[i]
			local frac = (now - r.start) / r.dur
			if frac >= 1 then
				table.remove(skyRings, i)
				continue
			end

			local a = 255 * (1 - frac)
			local rad = r.size * (0.45 + frac * 1.05)
			local c = r.col

			-- Soft filled disc (both faces so it's visible from either side).
			render.SetMaterial(RING_GLOW)
			render.DrawQuadEasy(r.pos, r.normal, rad * 2, rad * 2, Color(c.r, c.g, c.b, a), 0)
			render.DrawQuadEasy(r.pos, r.normal * -1, rad * 2, rad * 2, Color(c.r, c.g, c.b, a), 0)

			-- Crisp expanding ring edge to sell the "circle".
			render.SetMaterial(RING_EDGE)
			render.DrawQuadEasy(r.pos, r.normal, rad * 2.5, rad * 2.5, Color(c.r, c.g, c.b, a), 0)
			render.DrawQuadEasy(r.pos, r.normal * -1, rad * 2.5, rad * 2.5, Color(c.r, c.g, c.b, a), 0)
		end
	end)

	-- Charge-up of a Sky Walk (windborne) dash: the magic circle forms and wind gathers
	-- inward while the "cast" builds, before the release propels the player.
	net.Receive("Arcana_WindDash_SkyCharge", function()
		local pos    = net.ReadVector()
		local caster = net.ReadEntity()
		local aim    = net.ReadVector()
		local dur    = net.ReadFloat()
		if dur <= 0 then dur = 0.4 end

		local pcol = physgunColor(caster)

		-- Magic circle at the player's feet, standing perpendicular to the dash (face normal =
		-- aim): the launch pad. With the launch pose below, the body lies along the aim with
		-- feet planted on this circle, so it reads as pushing off it. Follows live feet + aim.
		if Arcana.Circle and Arcana.Circle.MagicCircle then
			local function circleAng()
				local a = (IsValid(caster) and caster:GetAimVector()) or aim
				local an = a:Angle()
				an:RotateAroundAxis(an:Right(), 90) -- an:Up() == aim (the circle's face normal)
				return an
			end

			local startPos = IsValid(caster) and caster:GetPos() or pos
			local circle = Arcana.Circle.MagicCircle.CreateMagicCircle(startPos, circleAng(), pcol, 3, 90, dur + 0.15, 2)

			local endT = CurTime() + dur + 0.15
			local fname = "Arcana_WindDash_ChargeCircle_" .. (IsValid(caster) and caster:EntIndex() or 0) .. "_" .. CurTime()
			hook.Add("Think", fname, function()
				if not IsValid(caster) or not circle or (circle.IsActive and not circle:IsActive()) or CurTime() > endT then
					hook.Remove("Think", fname)
					return
				end
				circle.position = caster:GetPos()
				circle.angles = circleAng()
			end)
		end

		-- Gathering wind: wisps spiral inward toward the caster as energy builds.
		local endT = CurTime() + dur
		local hookName = "Arcana_WindDash_Gather_" .. (IsValid(caster) and caster:EntIndex() or 0) .. "_" .. CurTime()
		hook.Add("Think", hookName, function()
			if not IsValid(caster) or CurTime() >= endT then
				hook.Remove("Think", hookName)
				return
			end

			local center = caster:WorldSpaceCenter()
			local em = ParticleEmitter(center, false)
			if not em then return end

			for i = 1, 3 do
				local dir   = VectorRand():GetNormalized()
				local spawn = center + dir * math.Rand(60, 120)
				local p = em:Add("effects/splash2", spawn)
				if p then
					p:SetDieTime(0.35)
					p:SetStartAlpha(math.Rand(160, 210))
					p:SetEndAlpha(0)
					p:SetStartSize(math.Rand(6, 11))
					p:SetEndSize(1)
					p:SetRoll(math.Rand(0, 360))
					p:SetRollDelta(math.Rand(-6, 6))
					p:SetColor(pcol.r, pcol.g, pcol.b)
					p:SetVelocity(-dir * math.Rand(280, 460)) -- inward = converging/charging
					p:SetAirResistance(60)
					p:SetLighting(false)
				end
			end
			em:Finish()
		end)
	end)

	-- Wind explosion at the release point of a Sky Walk (windborne) dash.
	net.Receive("Arcana_WindDash_SkyBurst", function()
		local pos    = net.ReadVector()
		local caster = net.ReadEntity()
		local aim    = net.ReadVector()

		local pcol = physgunColor(caster)

		-- Impact disc, angled to the dash so it looks like a surface they kicked off.
		skyRings[#skyRings + 1] = {
			pos    = pos,
			normal = aim,
			col    = pcol,
			start  = CurTime(),
			dur    = 0.5,
			size   = 130,
		}

		local emitter = ParticleEmitter(pos)
		if not emitter then return end

		-- Radial gust: a dense sphere of wind blasting outward from the start point.
		for i = 1, 140 do
			local rdir = VectorRand():GetNormalized()
			local p = emitter:Add("effects/splash2", pos + rdir * math.Rand(4, 30))
			if p then
				p:SetDieTime(math.Rand(0.4, 1.0))
				p:SetStartAlpha(math.Rand(210, 255))
				p:SetEndAlpha(0)
				p:SetStartSize(math.Rand(22, 42))
				p:SetEndSize(math.Rand(5, 12))
				p:SetRoll(math.Rand(0, 360))
				p:SetRollDelta(math.Rand(-10, 10))
				p:SetColor(200, 228, 255)
				p:SetVelocity(rdir * math.Rand(700, 1700))
				p:SetAirResistance(110)
				p:SetGravity(Vector(0, 0, -15))
				p:SetLighting(false)
			end
		end

		-- Swelling smoke puffs so the blast reads as a gust, not just sparks.
		for i = 1, 34 do
			local rdir = VectorRand():GetNormalized()
			local p = emitter:Add("particle/particle_smokegrenade", pos + rdir * math.Rand(4, 24))
			if p then
				p:SetDieTime(math.Rand(0.6, 1.2))
				p:SetStartAlpha(math.Rand(120, 180))
				p:SetEndAlpha(0)
				p:SetStartSize(math.Rand(26, 44))
				p:SetEndSize(math.Rand(80, 120))
				p:SetRoll(math.Rand(0, 360))
				p:SetRollDelta(math.Rand(-3, 3))
				p:SetColor(206, 222, 242)
				p:SetVelocity(rdir * math.Rand(200, 420))
				p:SetAirResistance(90)
				p:SetGravity(Vector(0, 0, 6))
				p:SetLighting(false)
			end
		end
		emitter:Finish()

		-- Shockwave ring + a brief wind-blue flash.
		local ed = EffectData()
		ed:SetOrigin(pos)
		ed:SetScale(3.4)
		util.Effect("StunEffect", ed)

		local dl = DynamicLight(0)
		if dl then
			dl.pos = pos
			dl.r, dl.g, dl.b = 200, 228, 255
			dl.brightness = 3.0
			dl.Decay = 1400
			dl.Size = 512
			dl.DieTime = CurTime() + 0.15
		end
	end)

	net.Receive("Arcana_WindDash", function()
		local ply    = net.ReadEntity()
		local aimDir = net.ReadVector()
		local isDive = net.ReadBool()

		if not IsValid(ply) then return end

		local startPos = ply:WorldSpaceCenter()
		local emitter  = ParticleEmitter(startPos)
		if not emitter then return end

		-- Burst particles: blue-white for leap, deeper blue-grey for dive
		local r, g, b = isDive and 160 or 200, isDive and 200 or 230, 255
		for i = 1, 40 do
			local spread = VectorRand():GetNormalized()
			local pos    = startPos + spread * math.Rand(10, 30)
			local p      = emitter:Add("effects/splash2", pos)
			if p then
				p:SetDieTime(math.Rand(0.5, 1.0))
				p:SetStartAlpha(math.Rand(200, 240))
				p:SetEndAlpha(0)
				p:SetStartSize(math.Rand(20, 35))
				p:SetEndSize(math.Rand(5, 10))
				p:SetRoll(math.Rand(0, 360))
				p:SetRollDelta(math.Rand(-8, 8))
				p:SetColor(r, g, b)
				p:SetVelocity(spread * math.Rand(200, 400))
				p:SetAirResistance(150)
				p:SetGravity(Vector(0, 0, isDive and 50 or -50))
			end
		end
		emitter:Finish()

		-- Trailing particles during flight
		local trailData = {
			player      = ply,
			direction   = aimDir,
			startTime   = CurTime(),
			duration    = 0.8,
			nextParticle = CurTime(),
		}

		local hookName = "Arcana_WindDash_Trail_" .. ply:EntIndex() .. "_" .. CurTime()
		hook.Add("Think", hookName, function()
			if not IsValid(ply) or CurTime() > trailData.startTime + trailData.duration then
				hook.Remove("Think", hookName)
				return
			end

			if CurTime() < trailData.nextParticle then return end
			trailData.nextParticle = CurTime() + 0.02

			local pos = ply:WorldSpaceCenter()
			local em  = ParticleEmitter(pos, false)
			if not em then return end

			for i = 1, 3 do
				local offset = VectorRand() * 15
				local p      = em:Add("effects/splash2", pos + offset)
				if p then
					p:SetDieTime(math.Rand(0.4, 0.8))
					p:SetStartAlpha(math.Rand(180, 220))
					p:SetEndAlpha(0)
					p:SetStartSize(math.Rand(15, 25))
					p:SetEndSize(math.Rand(3, 8))
					p:SetRoll(math.Rand(0, 360))
					p:SetRollDelta(math.Rand(-10, 10))
					p:SetColor(r, g, b)
					p:SetVelocity(VectorRand() * 80)
					p:SetAirResistance(200)
					p:SetGravity(Vector(0, 0, isDive and 30 or -30))
				end
			end

			if math.random() > 0.3 then
				local p = em:Add("particle/particle_smokegrenade", pos + VectorRand() * 10)
				if p then
					p:SetDieTime(math.Rand(0.5, 1.0))
					p:SetStartAlpha(math.Rand(100, 150))
					p:SetEndAlpha(0)
					p:SetStartSize(math.Rand(20, 30))
					p:SetEndSize(math.Rand(40, 60))
					p:SetRoll(math.Rand(0, 360))
					p:SetRollDelta(math.Rand(-3, 3))
					p:SetColor(200, 200, 190)
					p:SetVelocity(VectorRand() * 50)
					p:SetAirResistance(80)
					p:SetGravity(Vector(0, 0, math.Rand(-20, 10)))
				end
			end

			em:Finish()
		end)

		local ed = EffectData()
		ed:SetOrigin(startPos)
		util.Effect("ManhackSparks", ed)
	end)

	net.Receive("Arcana_WindDashLand", function()
		local ply   = net.ReadEntity()
		local speed = net.ReadFloat()

		if not IsValid(ply) then return end

		local landPos  = ply:GetPos()
		local isHeavy  = speed >= LAND_DAMAGE_SPEED
		local emitter  = ParticleEmitter(landPos)
		if not emitter then return end

		-- Ground-burst: radial outward ring of wind/debris particles
		local count = isHeavy and 60 or 30
		for i = 1, count do
			local angle  = math.Rand(0, 360)
			local radDir = Vector(math.cos(math.rad(angle)), math.sin(math.rad(angle)), math.Rand(0.1, 0.4)):GetNormalized()
			local p      = emitter:Add("effects/splash2", landPos + radDir * math.Rand(5, 20))
			if p then
				p:SetDieTime(math.Rand(0.4, 0.9))
				p:SetStartAlpha(math.Rand(180, 240))
				p:SetEndAlpha(0)
				p:SetStartSize(math.Rand(isHeavy and 20 or 10, isHeavy and 40 or 25))
				p:SetEndSize(math.Rand(2, 8))
				p:SetRoll(math.Rand(0, 360))
				p:SetRollDelta(math.Rand(-6, 6))
				p:SetColor(210, 230, 255)
				p:SetVelocity(radDir * math.Rand(isHeavy and 300 or 150, isHeavy and 600 or 300))
				p:SetAirResistance(180)
				p:SetGravity(Vector(0, 0, -80))
			end
		end
		emitter:Finish()

		-- Shockwave ring effect
		local ed = EffectData()
		ed:SetOrigin(landPos + Vector(0, 0, 5))
		ed:SetScale(isHeavy and 2.0 or 1.0)
		util.Effect("StunEffect", ed)

		if isHeavy then
			local ed2 = EffectData()
			ed2:SetOrigin(landPos)
			util.Effect("ManhackSparks", ed2)
		end
	end)
end
