-- Spore Seeding: on detonation the projectile bursts into a lingering spore cloud.
-- Enemies inside are poisoned each tick; players who linger are hit with a diluted
-- SporeHigh (view wobble, DSP audio) every SPORE_COOLDOWN seconds.

if SERVER then util.AddNetworkString("Arcana_SporeCloud") end

local CLOUD_DURATION  = 8
local CLOUD_RADIUS    = 180
local TICK_INTERVAL   = 0.5
local TICK_COUNT      = math.floor(CLOUD_DURATION / TICK_INTERVAL)
local TICK_DAMAGE     = 6
local SPORE_DURATION  = 5
local SPORE_INTENSITY = 0.4
local SPORE_COOLDOWN  = 1.5

local function spawnCloud(attacker, pos)
	-- Invisible marker entity: anchors the tick timer and the client particle system.
	-- Mirrors the same pattern used by the Poison Cloud spell.
	local marker = ents.Create("prop_physics")
	if not IsValid(marker) then return end

	marker:SetModel("models/props_junk/garbage_glassbottle002a.mdl")
	marker:SetPos(pos)
	marker:Spawn()
	marker:SetMoveType(MOVETYPE_NONE)
	marker:SetCollisionGroup(COLLISION_GROUP_WORLD)
	marker:SetModelScale(0)
	marker:SetNotSolid(true)
	marker:SetHealth(999999)
	marker:SetMaxHealth(999999)
	if marker.CPPISetOwner then marker:CPPISetOwner(attacker) end

	local phys = marker:GetPhysicsObject()
	if IsValid(phys) then
		phys:Wake()
		phys:EnableMotion(false)
		phys:EnableCollisions(false)
	end

	net.Start("Arcana_SporeCloud", true)
	net.WriteEntity(marker)
	net.WriteFloat(CLOUD_DURATION)
	net.WriteFloat(CLOUD_RADIUS)
	net.Broadcast()

	sound.Play("ambient/levels/canals/toxic_slime_gurgle" .. math.random(1, 8) .. ".wav", pos, 75, 75)

	local tid = "Arcana_SporeCloud_" .. marker:EntIndex()
	timer.Create(tid, TICK_INTERVAL, TICK_COUNT, function()
		if not IsValid(marker) then timer.Remove(tid) return end

		for _, ent in ipairs(ents.FindInSphere(marker:GetPos(), CLOUD_RADIUS)) do
			if not IsValid(ent) or ent == attacker then continue end
			if not (ent:IsPlayer() or ent:IsNPC() or ent:IsNextBot()) then continue end
			if ent:IsPlayer() and not ent:Alive() then continue end
			if ent:IsNPC() and ent:Health() <= 0 then continue end

			local dmg = DamageInfo()
			dmg:SetDamage(TICK_DAMAGE)
			dmg:SetDamageType(DMG_POISON)
			dmg:SetAttacker(IsValid(attacker) and attacker or game.GetWorld())
			dmg:SetInflictor(IsValid(marker) and marker or game.GetWorld())
			dmg:SetDamagePosition(ent:WorldSpaceCenter())
			ent:TakeDamageInfo(dmg)

			if ent:IsPlayer() then
				local now = CurTime()
				if (ent._arcanaSporeSeededAt or 0) + SPORE_COOLDOWN <= now then
					ent._arcanaSporeSeededAt = now
					Arcana.Status.SporeHigh.Apply(ent, {
						duration  = SPORE_DURATION,
						intensity = SPORE_INTENSITY,
					})
				end
			end
		end
	end)

	timer.Simple(CLOUD_DURATION + 0.25, function()
		if IsValid(marker) then SafeRemoveEntity(marker) end
	end)
end

Arcana:RegisterEnchantment({
	id = "spore_seeding",
	name = "Spore Seeding",
	description = "On impact, your projectile bursts into a lingering spore cloud. Enemies inside are poisoned each tick, and any player who lingers is overcome with disorienting hallucinations.",
	cost_coins = 1100,
	cost_items = {
		{ name = "mana_crystal_shard", amount = 45 },
	},
	can_apply = function(ply, wep)
		return Arcana.Common.GetWeaponClassification(wep) == "PROJECTILE"
	end,
	on_projectile_fired = function(ply, wep, proj, state)
		proj:CallOnRemove("Arcana_SporeSeeding_Detonate", function(e)
			if not IsValid(ply) then return end
			spawnCloud(ply, e:GetPos())
		end)
	end,
})

if CLIENT then
	local activeEmitters = {}
	local nextScanAt = 0

	net.Receive("Arcana_SporeCloud", function()
		local marker = net.ReadEntity()
		if not IsValid(marker) then return end
		activeEmitters[marker] = {
			duration     = CurTime() + net.ReadFloat(),
			radius       = net.ReadFloat(),
			birthTime    = CurTime(),
			nextParticle = CurTime(),
		}
	end)

	-- Particle system copied verbatim from poison_cloud.lua: same materials, colors,
	-- sizes, and throttle pattern so spore clouds look identical to the base spell.
	hook.Add("Think", "Arcana_SporeCloud_ClientFX", function()
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
			local em  = data.emitter

			if not em then
				em = ParticleEmitter(pos, false)
				data.emitter = em
			end

			if not em then continue end
			em:SetPos(pos)

			-- Ground-level dense toxic fog
			for i = 1, 4 do
				local rr  = rad * math.sqrt(math.Rand(0, 1))
				local a   = math.Rand(0, math.pi * 2)
				local off = Vector(math.cos(a) * rr, math.sin(a) * rr, math.Rand(0, 8))
				local p   = em:Add("particle/particle_smokegrenade", pos + off)
				if p then
					p:SetDieTime(math.Rand(2.5, 3.5))
					p:SetStartAlpha(0)
					p:SetEndAlpha(math.Rand(140, 180))
					local sz = math.Rand(30, 45)
					p:SetStartSize(sz)
					p:SetEndSize(sz * math.Rand(1.4, 1.8))
					p:SetRoll(math.Rand(0, 360))
					p:SetRollDelta(math.Rand(-0.3, 0.3))
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
					local rr  = rad * math.Rand(0.3, 0.8)
					local a   = math.Rand(0, math.pi * 2)
					local off = Vector(math.cos(a) * rr, math.sin(a) * rr, 0)
					local p   = em:Add("particle/particle_smokegrenade", pos + off)
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
				local rr  = rad * math.Rand(0.2, 0.9)
				local a   = math.Rand(0, math.pi * 2)
				local off = Vector(math.cos(a) * rr, math.sin(a) * rr, 0)
				local p   = em:Add("effects/blueflare1", pos + off)
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
