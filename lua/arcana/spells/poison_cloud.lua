local function applyOrRefreshPoisonSlow(ply, duration)
	if not IsValid(ply) or not ply:IsPlayer() then return end

	if not ply._arcanaPoisonSlow then
		ply._arcanaPoisonSlow = {
			oldWalk = ply:GetWalkSpeed(),
			oldRun = ply:GetRunSpeed()
		}

		ply:SetWalkSpeed(math.max(100, ply._arcanaPoisonSlow.oldWalk * 0.7))
		ply:SetRunSpeed(math.max(140, ply._arcanaPoisonSlow.oldRun * 0.7))
	end

	ply._arcanaPoisonSlowExpire = CurTime() + duration
	local tid = "Arcana_PoisonSlow_" .. ply:EntIndex()

	if not timer.Exists(tid) then
		timer.Create(tid, 0.2, 0, function()
			if not IsValid(ply) then
				timer.Remove(tid)

				return
			end

			if not ply._arcanaPoisonSlow or CurTime() > (ply._arcanaPoisonSlowExpire or 0) then
				local rec = ply._arcanaPoisonSlow

				if rec then
					if rec.oldWalk then
						ply:SetWalkSpeed(rec.oldWalk)
					end

					if rec.oldRun then
						ply:SetRunSpeed(rec.oldRun)
					end
				end

				ply._arcanaPoisonSlow = nil
				timer.Remove(tid)
			end
		end)
	end
end

Arcane:RegisterSpell({
	id = "poison_cloud",
	name = "Poison Cloud",
	description = "Deploy a lingering toxic cloud that poisons and slows enemies inside.",
	category = Arcane.CATEGORIES.COMBAT,
	level_required = 6,
	knowledge_cost = 3,
	cooldown = 12.0,
	cost_type = Arcane.COST_TYPES.COINS,
	cost_amount = 35,
	cast_time = 1.0,
	range = 900,
	icon = "icon16/bug.png",
	has_target = true,
	cast_anim = "forward",
	cast = function(caster, _, _, ctx)
		if not SERVER then return true end

		local duration = 12
		local tickInterval = 0.5
		local radius = 220
		local perTickDamage = 8
		local slowRefresh = 1.2
		local srcEnt = IsValid(ctx.casterEntity) and ctx.casterEntity or caster
		local pos = Arcane:ResolveGroundTarget(srcEnt, 900) + Vector(0, 0, 8)

		local cloud = ents.Create("prop_physics")
		if not IsValid(cloud) then return false end

		cloud:SetModel("models/props_junk/garbage_glassbottle002a.mdl")
		cloud:SetPos(pos)
		cloud:Spawn()
		cloud:SetMoveType(MOVETYPE_NONE)
		cloud:SetCollisionGroup(COLLISION_GROUP_WORLD)
		cloud:SetModelScale(0)
		cloud:SetNotSolid(true)

		-- Make it indestructible
		cloud:SetHealth(999999)
		cloud:SetMaxHealth(999999)

		if cloud.CPPISetOwner then
			cloud:CPPISetOwner(caster)
		end

		local phys = cloud:GetPhysicsObject()
		if IsValid(phys) then
			phys:Wake()
			phys:EnableMotion(false)
			phys:EnableCollisions(false)
		end

		net.Start("Arcana_PoisonCloud", true)
		net.WriteEntity(cloud)
		net.WriteFloat(duration)
		net.WriteFloat(radius)
		net.Broadcast()

		-- Toxic cloud spawn sounds
		sound.Play("ambient/levels/canals/toxic_slime_gurgle" .. math.random(1, 8) .. ".wav", pos, 75, 90)
		sound.Play("ambient/atmosphere/cave_hit" .. math.random(1, 6) .. ".wav", pos, 70, 70)
		timer.Simple(0.1, function()
			sound.Play("npc/barnacle/barnacle_gulp" .. math.random(1, 2) .. ".wav", pos, 70, 70)
		end)
		local tid = "Arcana_PoisonCloud_" .. cloud:EntIndex()

		timer.Create(tid, tickInterval, math.floor(duration / tickInterval), function()
			if not IsValid(cloud) then
				timer.Remove(tid)

				return
			end

			for _, ent in ipairs(ents.FindInSphere(cloud:GetPos(), radius)) do
				if not IsValid(ent) or ent == caster then continue end

				if ent:IsPlayer() or ent:IsNPC() or ent:IsNextBot() then
					local dmg = DamageInfo()
					dmg:SetDamage(perTickDamage)
					dmg:SetDamageType(DMG_POISON)
					dmg:SetAttacker(IsValid(caster) and caster or game.GetWorld())
					dmg:SetInflictor(IsValid(caster) and caster or game.GetWorld())
					ent:TakeDamageInfo(dmg)

					if ent:IsPlayer() then
						applyOrRefreshPoisonSlow(ent, slowRefresh)
					end
				end
			end
		end)

		timer.Simple(duration + 0.25, function()
			if IsValid(cloud) then
				for _, child in ipairs(cloud:GetChildren()) do
					SafeRemoveEntity(child)
				end

				cloud:Remove()
			end
		end)

		return true
	end,
	trigger_phrase_aliases = {
		"poison",
		"fart", -- because thats funny
		"fart cloud",
	}
})

if SERVER then
	util.AddNetworkString("Arcana_PoisonCloud")
end

if CLIENT then
	local activeEmitters = {}
	local matGlow = Material("sprites/light_glow02_add")
	local matFlare = Material("effects/blueflare1")

	net.Receive("Arcana_PoisonCloud", function()
		local cloud = net.ReadEntity()
		if not IsValid(cloud) then return end

		activeEmitters[cloud] = {
			duration = CurTime() + net.ReadFloat(),
			radius = net.ReadFloat(),
			birthTime = CurTime(),
			nextParticle = CurTime(),
		}
	end)

	-- Custom casting circle for poison cloud on ground
	hook.Add("Arcana_BeginCastingVisuals", "Arcana_PoisonCloud_Circle", function(caster, spellId, castTime, _forwardLike)
		if spellId ~= "poison_cloud" then return end

		Arcane:CreateFollowingCastCircle(caster, spellId, castTime, {
			color = Color(140, 220, 80, 255),
			size = 24,
			intensity = 3,
			positionResolver = function(c)
				return Arcane:ResolveGroundTarget(c, 900)
			end
		})
	end)


	-- Enhanced particle system for toxic cloud
	local nextScanAt = 0

	hook.Add("Think", "Arcana_PoisonCloud_ClientFX", function()
		local now = CurTime()
		if now < nextScanAt then return end
		nextScanAt = now + 0.05

		for ent, data in pairs(activeEmitters) do
			if not IsValid(ent) or now > data.duration then
				if data.emitter and data.emitter.Finish then
					data.emitter:Finish()
				end
				activeEmitters[ent] = nil
				continue
			end

			if now < data.nextParticle then continue end
			data.nextParticle = now + 0.06

			local pos = ent:GetPos()
			local rad = data.radius
			local em = data.emitter

			if not em then
				em = ParticleEmitter(pos, false)
				data.emitter = em
			end

			if not em then continue end
			em:SetPos(pos)

			-- Ground-level dense toxic fog
			for i = 1, 4 do
				local rr = rad * math.sqrt(math.Rand(0, 1))
				local a = math.Rand(0, math.pi * 2)
				local off = Vector(math.cos(a) * rr, math.sin(a) * rr, math.Rand(0, 8))
				local p = em:Add("particle/particle_smokegrenade", pos + off)

				if p then
					p:SetDieTime(math.Rand(2.5, 3.5))
					p:SetStartAlpha(0)
					p:SetEndAlpha(math.Rand(140, 180))
					local sz = math.Rand(30, 45)
					p:SetStartSize(sz)
					p:SetEndSize(sz * math.Rand(1.4, 1.8))
					p:SetRoll(math.Rand(0, 360))
					p:SetRollDelta(math.Rand(-0.3, 0.3))

					-- Toxic yellow-green color
					local colorVar = math.Rand(0.8, 1.2)
					p:SetColor(100 * colorVar, 180 * colorVar, 50 * colorVar)

					p:SetAirResistance(120)
					p:SetGravity(Vector(0, 0, math.Rand(2, 6)))
					p:SetVelocity(Vector(math.Rand(-15, 15), math.Rand(-15, 15), 0))
					p:SetCollide(false)
				end
			end

			-- Rising toxic vapor wisps
			if math.random() > 0.3 then
				for i = 1, 2 do
					local rr = rad * math.Rand(0.3, 0.8)
					local a = math.Rand(0, math.pi * 2)
					local off = Vector(math.cos(a) * rr, math.sin(a) * rr, 0)
					local p = em:Add("particle/particle_smokegrenade", pos + off)

					if p then
						p:SetDieTime(math.Rand(1.5, 2.5))
						p:SetStartAlpha(0)
						p:SetEndAlpha(math.Rand(100, 140))
						local sz = math.Rand(15, 25)
						p:SetStartSize(sz)
						p:SetEndSize(sz * math.Rand(0.6, 1.0))
						p:SetRoll(math.Rand(0, 360))
						p:SetRollDelta(math.Rand(-1, 1))
						p:SetColor(120, 220, 70)
						p:SetAirResistance(50)
						p:SetGravity(Vector(0, 0, math.Rand(35, 50)))
						p:SetVelocity(Vector(math.Rand(-8, 8), math.Rand(-8, 8), math.Rand(20, 40)))
						p:SetCollide(false)
					end
				end
			end

			-- Toxic glow particles (bubbling effect)
			if math.random() > 0.5 then
				local rr = rad * math.Rand(0.2, 0.9)
				local a = math.Rand(0, math.pi * 2)
				local off = Vector(math.cos(a) * rr, math.sin(a) * rr, 0)
				local p = em:Add("effects/blueflare1", pos + off)

				if p then
					p:SetDieTime(math.Rand(0.8, 1.5))
					p:SetStartAlpha(math.Rand(200, 255))
					p:SetEndAlpha(0)
					p:SetStartSize(math.Rand(8, 14))
					p:SetEndSize(0)
					p:SetColor(140, 220, 80)
					p:SetAirResistance(30)
					p:SetGravity(Vector(0, 0, math.Rand(25, 40)))
					p:SetVelocity(Vector(math.Rand(-10, 10), math.Rand(-10, 10), math.Rand(15, 30)))
					p:SetCollide(false)
				end
			end
		end
	end)
end