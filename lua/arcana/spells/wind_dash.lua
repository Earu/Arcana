if SERVER then
	util.AddNetworkString("Arcana_WindDash")
	util.AddNetworkString("Arcana_WindDashLand")
end

-- Wind Dash
-- Aim upward while grounded to leap skyward; aim downward while airborne to crash back to earth.
-- Grants fall damage immunity while active. Hard landing deals speed-scaled damage to entities below.
local LEAP_FORCE  = 1250 -- Launch force for the upward leap
local DIVE_FORCE  = 2000 -- Launch force for the downward crash
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
