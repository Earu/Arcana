Arcane:RegisterSpell({
	id = "wind_sweep",
	name = "Wind Sweep",
	description = "Unleash a violent gust pushing foes away.",
	category = Arcane.CATEGORIES.COMBAT,
	level_required = 1,
	knowledge_cost = 1,
	cooldown = 4.0,
	cost_type = Arcane.COST_TYPES.COINS,
	cost_amount = 12,
	cast_time = 0.6,
	range = 500,
	icon = "icon16/flag_white.png",
	has_target = false,
	cast_anim = "forward",
	cast = function(caster, _, _, ctx)
		if not SERVER then return true end

		local srcEnt = IsValid(ctx.casterEntity) and ctx.casterEntity or caster
		local origin = ctx.circlePos or (srcEnt.EyePos and srcEnt:EyePos() or srcEnt:WorldSpaceCenter())
		local forward = srcEnt.GetAimVector and srcEnt:GetAimVector() or srcEnt:GetForward()
		local cone = math.cos(math.rad(30))
		local strength = 1500
		local radius = 400
		local baseDamage = 40

		-- Network visual effects to clients
		net.Start("Arcana_WindSweep", true)
		net.WriteVector(origin)
		net.WriteVector(forward)
		net.WriteFloat(radius)
		net.Broadcast()

		for _, ent in ipairs(ents.FindInSphere(origin, radius)) do
			if ent ~= srcEnt and IsValid(ent) and (ent:IsPlayer() or ent:IsNPC() or ent:IsNextBot()or ent:GetMoveType() == MOVETYPE_VPHYSICS) then
				local dir = (ent:WorldSpaceCenter() - origin):GetNormalized()

				if dir:Dot(forward) >= cone then
					if ent:IsPlayer() or ent:IsNPC() or ent:IsNextBot() then
						-- Deal damage
						local dmg = DamageInfo()
						dmg:SetDamage(baseDamage)
						dmg:SetDamageType(DMG_SONIC)
						dmg:SetAttacker(IsValid(caster) and caster or game.GetWorld())
						dmg:SetInflictor(IsValid(srcEnt) and srcEnt or game.GetWorld())
						ent:TakeDamageInfo(dmg)

						ent:SetVelocity(forward * strength + Vector(0, 0, 120))
						ent:SetGroundEntity(NULL)
					else
						local phys = ent:GetPhysicsObject()
						if IsValid(phys) then
							phys:ApplyForceCenter(forward * (strength * phys:GetMass() * 0.5))
						end
					end
				end
			end
		end

		-- Powerful wind blast sounds
		sound.Play("ambient/wind/wind_roar1.wav", origin, 95, 100)
		sound.Play("ambient/explosions/explode_" .. math.random(1, 9) .. ".wav", origin, 90, 140)
		sound.Play("physics/concrete/boulder_impact_hard" .. math.random(1, 4) .. ".wav", origin, 85, 60)
		timer.Simple(0.05, function()
			sound.Play("ambient/explosions/exp" .. math.random(1, 3) .. ".wav", origin, 85, 150)
			sound.Play("ambient/wind/wind_snippet" .. math.random(1, 5) .. ".wav", origin, 80, 120)
		end)
		timer.Simple(0.15, function()
			sound.Play("weapons/physcannon/energy_bounce" .. math.random(1, 2) .. ".wav", origin, 75, 80)
		end)

		return true
	end
})

if SERVER then
	util.AddNetworkString("Arcana_WindSweep")
end

if CLIENT then
	local matGlow = Material("sprites/light_glow02_add")
	local matBeam = Material("effects/laser1")
	local matSmoke = Material("particle/particle_smokegrenade")

	net.Receive("Arcana_WindSweep", function()
		local origin = net.ReadVector()
		local forward = net.ReadVector()
		local radius = net.ReadFloat()

		local emitter = ParticleEmitter(origin)
		if not emitter then return end

		-- Calculate perpendicular vectors for cone spread
		local right = forward:Angle():Right()
		local up = forward:Angle():Up()

		-- Main wind blast particles (swirling air)
		for i = 1, 80 do
			-- Create cone spread
			local spreadAngle = math.Rand(-30, 30)
			local spreadAngle2 = math.Rand(-30, 30)
			local spreadDir = (forward + right * math.tan(math.rad(spreadAngle)) + up * math.tan(math.rad(spreadAngle2))):GetNormalized()

			local dist = math.Rand(50, radius)
			local pos = origin + spreadDir * dist

			local p = emitter:Add("effects/splash2", pos)
			if p then
				p:SetDieTime(math.Rand(0.8, 1.4))
				p:SetStartAlpha(math.Rand(180, 220))
				p:SetEndAlpha(0)
				p:SetStartSize(math.Rand(25, 40))
				p:SetEndSize(math.Rand(5, 15))
				p:SetRoll(math.Rand(0, 360))
				p:SetRollDelta(math.Rand(-8, 8))
				p:SetColor(200, 220, 240)
				p:SetVelocity(spreadDir * math.Rand(800, 1200))
				p:SetAirResistance(150)
				p:SetGravity(Vector(0, 0, -100))
			end
		end

		-- Dust and debris being swept up
		for i = 1, 60 do
			local spreadAngle = math.Rand(-30, 30)
			local spreadAngle2 = math.Rand(-30, 30)
			local spreadDir = (forward + right * math.tan(math.rad(spreadAngle)) + up * math.tan(math.rad(spreadAngle2))):GetNormalized()

			local dist = math.Rand(30, radius * 0.8)
			local pos = origin + spreadDir * dist

			local p = emitter:Add("particle/particle_smokegrenade", pos)
			if p then
				p:SetDieTime(math.Rand(1.2, 2.0))
				p:SetStartAlpha(math.Rand(120, 180))
				p:SetEndAlpha(0)
				p:SetStartSize(math.Rand(30, 50))
				p:SetEndSize(math.Rand(60, 90))
				p:SetRoll(math.Rand(0, 360))
				p:SetRollDelta(math.Rand(-3, 3))
				p:SetColor(180, 180, 160)
				p:SetVelocity(spreadDir * math.Rand(600, 1000) + Vector(0, 0, math.Rand(50, 150)))
				p:SetAirResistance(100)
				p:SetGravity(Vector(0, 0, math.Rand(-50, 0)))
			end
		end

		-- Sharp wind streak particles
		for i = 1, 40 do
			local spreadAngle = math.Rand(-25, 25)
			local spreadAngle2 = math.Rand(-25, 25)
			local spreadDir = (forward + right * math.tan(math.rad(spreadAngle)) + up * math.tan(math.rad(spreadAngle2))):GetNormalized()

			local dist = math.Rand(80, radius * 1.2)
			local pos = origin + spreadDir * dist

			local p = emitter:Add("effects/blueflare1", pos)
			if p then
				p:SetDieTime(math.Rand(0.4, 0.8))
				p:SetStartAlpha(255)
				p:SetEndAlpha(0)
				p:SetStartSize(math.Rand(15, 25))
				p:SetEndSize(0)
				p:SetColor(220, 240, 255)
				p:SetVelocity(spreadDir * math.Rand(1200, 1600))
				p:SetAirResistance(80)
				p:SetGravity(Vector(0, 0, 0))
			end
		end

		emitter:Finish()

		-- Ground impact effects
		util.Effect("HelicopterMegaBomb", EffectData())

		local ed = EffectData()
		ed:SetOrigin(origin)
		ed:SetNormal(forward)
		ed:SetScale(radius)
		util.Effect("ManhackSparks", ed)
	end)
end