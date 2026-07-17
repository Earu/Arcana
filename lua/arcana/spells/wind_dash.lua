if SERVER then
	util.AddNetworkString("Arcana_WindDash")
	util.AddNetworkString("Arcana_WindDashLand")
	util.AddNetworkString("Arcana_WindDash_SkyBurst")
end

-- Wind Dash
-- Aim upward while grounded to leap skyward; aim downward while airborne to crash back to earth.
-- Grants fall damage immunity while active. Hard landing deals speed-scaled damage to entities below.
local LEAP_FORCE  = 1250 -- Launch force for the upward leap
local DIVE_FORCE  = 2000 -- Launch force for the downward crash
local EMPOWERED_FORCE = LEAP_FORCE * 6 -- Windborne dash launch force while Sky Walk is active
local EMPOWERED_YIELD = 1.0 -- How long Sky Walk's flight control yields to let this dash carry

-- Sky Walk (wind_sky_walk.lua) stores its state on the player as _ArcanaSkyWalk.
-- Reading the field directly keeps the coupling on the player-field convention.
local function skyWalkActive(ply)
	local st = ply._ArcanaSkyWalk
	return istable(st) and st.untilT ~= nil and CurTime() < st.untilT
end
local LEAP_PITCH  = -10  -- Eye pitch threshold: below this = looking "up enough" to leap
local DIVE_PITCH  =  5   -- Eye pitch threshold: above this = looking "down enough" to dive
local LAND_DAMAGE_SPEED = 700 -- Speed at which a heavy landing plays heavy impact sounds

Arcana:RegisterSpell({
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

		-- Windborne dash: Sky Walk empowers Wind Dash into an any-direction, double-force
		-- surge with no ground/pitch gate. Levitation owns movement, so we don't set the
		-- ArcanaWindDash* land flags here (the land hook never fires under MOVETYPE_FLY).
		if skyWalkActive(caster) then
			local aim = caster:GetAimVector()
			local dashVel = aim * EMPOWERED_FORCE
			caster:SetVelocity(dashVel)
			-- Sky Walk's SetupMove reads these to sustain the dash at full speed for the
			-- window (MOVETYPE_FLY would otherwise clamp/friction the impulse away).
			caster.ArcanaSkyWalkDashVel = dashVel
			caster.ArcanaSkyWalkDashUntil = CurTime() + EMPOWERED_YIELD

			local pos = caster:WorldSpaceCenter()
			sound.Play("ambient/wind/wind_roar1.wav", pos, 90, 150)
			sound.Play("weapons/physcannon/physcannon_charge.wav", pos, 78, 160)
			-- The "bang": a low concussive boom everyone hears at the launch point.
			sound.Play("ambient/explosions/explode_4.wav", pos, 92, math.random(125, 140))
			sound.Play("ambient/wind/wind_hit1.wav", pos, 85, 70)

			net.Start("Arcana_WindDash", true)
			net.WriteEntity(caster)
			net.WriteVector(aim)
			net.WriteBool(false)
			net.Broadcast()

			-- Wind explosion + physgun-colored impact disc at the launch point.
			net.Start("Arcana_WindDash_SkyBurst", true)
			net.WriteVector(pos)
			net.WriteEntity(caster)
			net.WriteVector(aim)
			net.Broadcast()

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

	-- Wind explosion at the launch point of a Sky Walk (windborne) dash.
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

		-- Arcana magic circle standing in the same plane, facing along the dash.
		if Arcana.Circle and Arcana.Circle.MagicCircle then
			local ang = aim:Angle()
			ang:RotateAroundAxis(ang:Right(), 90)
			Arcana.Circle.MagicCircle.CreateMagicCircle(pos, ang, pcol, 3, 140, 1.2, 2)
		end

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
