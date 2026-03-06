if SERVER then util.AddNetworkString("Arcana_WindDash") end

-- Wind Dash
-- Propel the caster forward in their aim direction with wind magic, negating fall damage
local DASH_FORCE = 2000 -- Base propulsion force
local UPWARD_LIFT = 300 -- Upward component to help with mobility
local FALL_DAMAGE_IMMUNITY_TIME = 3.0 -- Seconds of fall damage immunity

Arcana:RegisterSpell({
	id = "wind_dash",
	name = "Wind Dash",
	description = "Propel yourself forward with a powerful gust of wind. Grants temporary immunity to fall damage.",
	category = Arcana.CATEGORIES.UTILITY,
	level_required = 8,
	knowledge_cost = 2,
	cooldown = 3.0,
	cost_type = Arcana.COST_TYPES.COINS,
	cost_amount = 25,
	cast_time = 0.3,
	range = 0,
	icon = "icon16/arrow_up.png",
	has_target = false,
	cast_anim = "forward",
	cast = function(caster, _, _, ctx)
		if not SERVER then return true end

		local aimDir = caster:GetAimVector()
		local startPos = caster:WorldSpaceCenter()

		-- UPWARD_LIFT prevents clipping into walls on near-horizontal dashes
		local forceVector = aimDir * DASH_FORCE + Vector(0, 0, UPWARD_LIFT)
		local curVel = caster:GetVelocity()
		caster:SetVelocity(curVel + forceVector)
		caster:SetGroundEntity(NULL)

		net.Start("Arcana_WindDash", true)
		net.WriteEntity(caster)
		net.WriteVector(aimDir)
		net.Broadcast()

		caster.ArcanaWindDashProtection = CurTime() + FALL_DAMAGE_IMMUNITY_TIME

		sound.Play("ambient/wind/wind_roar1.wav", startPos, 85, 140)
		sound.Play("ambient/wind/wind_snippet" .. math.random(1, 5) .. ".wav", startPos, 80, 120)
		timer.Simple(0.05, function()
			sound.Play("weapons/physcannon/physcannon_charge.wav", startPos, 75, 150)
		end)

		return true
	end
})

-- Network string registered in arcana/init.lua

if SERVER then
	hook.Add("EntityTakeDamage", "Arcana_WindDashFallProtection", function(target, dmg)
		if not target:IsPlayer() then return end
		if not target.ArcanaWindDashProtection then return end

		local damageType = dmg:GetDamageType()
		if bit.band(damageType, DMG_FALL) == DMG_FALL then
			if CurTime() < target.ArcanaWindDashProtection then
				dmg:SetDamage(0)
				target:EmitSound("physics/cardboard/cardboard_box_impact_soft" .. math.random(1, 7) .. ".wav", 60, 120)
				target.ArcanaWindDashProtection = nil

				return true
			else
				target.ArcanaWindDashProtection = nil
			end
		end
	end)
end

if CLIENT then
	net.Receive("Arcana_WindDash", function()
		local ply = net.ReadEntity()
		local aimDir = net.ReadVector()

		if not IsValid(ply) then return end

		local startPos = ply:WorldSpaceCenter()
		local emitter = ParticleEmitter(startPos)
		if not emitter then return end

		for i = 1, 40 do
			local spread = VectorRand():GetNormalized()
			local pos = startPos + spread * math.Rand(10, 30)

			local p = emitter:Add("effects/splash2", pos)
			if p then
				p:SetDieTime(math.Rand(0.5, 1.0))
				p:SetStartAlpha(math.Rand(200, 240))
				p:SetEndAlpha(0)
				p:SetStartSize(math.Rand(20, 35))
				p:SetEndSize(math.Rand(5, 10))
				p:SetRoll(math.Rand(0, 360))
				p:SetRollDelta(math.Rand(-8, 8))
				p:SetColor(200, 230, 255)
				p:SetVelocity(spread * math.Rand(200, 400))
				p:SetAirResistance(150)
				p:SetGravity(Vector(0, 0, -50))
			end
		end

		emitter:Finish()

		local trailData = {
			player = ply,
			direction = aimDir,
			startTime = CurTime(),
			duration = 0.8,
			nextParticle = CurTime(),
		}

		-- CurTime() suffix prevents hook name collision when the same player dashes again quickly
		local hookName = "Arcana_WindDash_Trail_" .. ply:EntIndex() .. "_" .. CurTime()

		hook.Add("Think", hookName, function()
			if not IsValid(ply) or CurTime() > trailData.startTime + trailData.duration then
				hook.Remove("Think", hookName)
				return
			end

			if CurTime() < trailData.nextParticle then return end
			trailData.nextParticle = CurTime() + 0.02

			local pos = ply:WorldSpaceCenter()
			local em = ParticleEmitter(pos, false)
			if not em then return end

			for i = 1, 3 do
				local offset = VectorRand() * 15
				local p = em:Add("effects/splash2", pos + offset)
				if p then
					p:SetDieTime(math.Rand(0.4, 0.8))
					p:SetStartAlpha(math.Rand(180, 220))
					p:SetEndAlpha(0)
					p:SetStartSize(math.Rand(15, 25))
					p:SetEndSize(math.Rand(3, 8))
					p:SetRoll(math.Rand(0, 360))
					p:SetRollDelta(math.Rand(-10, 10))
					p:SetColor(210, 235, 255)
					p:SetVelocity(VectorRand() * 80)
					p:SetAirResistance(200)
					p:SetGravity(Vector(0, 0, -30))
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
end