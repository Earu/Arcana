-- Conductive Shell: while in flight the projectile arcs electricity to the nearest
-- visible enemy every 0.1s. On detonation it fully discharges via ApplyLightningChain.
-- Client visuals mirror arcana_lightning_orb: band rings, spark trail, blueflare cloud,
-- dynamic light, and jagged arc beams via the existing Arcana_LightningOrbZap renderer.

if SERVER then
	util.AddNetworkString("Arcana_ConductiveShell_Track")
end

local ZAP_INTERVAL = 0.1
local ZAP_RADIUS   = 300
local ZAP_DAMAGE   = 15

local function spawnZapTesla(pos)
	return Arcana.Common.SpawnTeslaBurst(pos, {
		targetname    = "arcana_lightning_orb",
		color         = "170 210 255",
		radius        = 80,
		beamcount_min = 3,  beamcount_max = 6,
		thick_min     = 3,  thick_max     = 5,
		lifetime_min  = 0.08, lifetime_max = 0.12,
		interval_min  = 0.03, interval_max = 0.06,
		kill_delay    = 0.3,
	})
end

local function spawnDischargeTesla(pos)
	return Arcana.Common.SpawnTeslaBurst(pos, {
		targetname    = "arcana_lightning_orb",
		color         = "170 210 255",
		radius        = 200,
		beamcount_min = 8,  beamcount_max = 14,
		thick_min     = 6,  thick_max     = 10,
		lifetime_min  = 0.12, lifetime_max = 0.18,
		interval_min  = 0.05, interval_max = 0.10,
		kill_delay    = 0.8,
	})
end

local function zapNearestTarget(proj, attacker)
	if not IsValid(proj) or not IsValid(attacker) then return end

	local pos = proj:GetPos()
	local best, bestDistSq = nil, ZAP_RADIUS * ZAP_RADIUS

	for _, ent in ipairs(ents.FindInSphere(pos, ZAP_RADIUS)) do
		if not IsValid(ent) then continue end
		if ent == attacker or ent == proj then continue end
		if not (ent:IsPlayer() or ent:IsNPC() or ent:IsNextBot()) then continue end
		if ent:IsPlayer() and not ent:Alive() then continue end
		if ent:IsNPC() and ent:Health() <= 0 then continue end

		local dSq = ent:GetPos():DistToSqr(pos)
		if dSq >= bestDistSq then continue end

		local tr = util.TraceLine({
			start  = pos,
			endpos = ent:WorldSpaceCenter(),
			filter = { proj, attacker },
			mask   = MASK_SOLID_BRUSHONLY,
		})
		if tr.Fraction < 1.0 then continue end

		bestDistSq = dSq
		best = ent
	end

	if not IsValid(best) then return end

	local tpos = best:WorldSpaceCenter()

	local dmg = DamageInfo()
	dmg:SetDamage(ZAP_DAMAGE)
	dmg:SetDamageType(bit.bor(DMG_SHOCK, DMG_ENERGYBEAM))
	dmg:SetAttacker(attacker)
	dmg:SetInflictor(attacker)
	dmg:SetDamagePosition(tpos)
	best:TakeDamageInfo(dmg)

	-- Arc visual: reuses arcana_lightning_orb's existing client-side jagged beam renderer
	net.Start("Arcana_LightningOrbZap", true)
	net.WriteVector(pos)
	net.WriteVector(tpos)
	net.Broadcast()

	local tesla = spawnZapTesla(tpos)
	if IsValid(tesla) and tesla.CPPISetOwner then
		tesla:CPPISetOwner(attacker)
	end
end

local function augmentProjectile(proj, owner)
	-- Tell clients to start emitting particles from this projectile
	net.Start("Arcana_ConductiveShell_Track", true)
	net.WriteEntity(proj)
	net.Broadcast()

	-- Band rings identical to the lightning orb spell
	Arcana:SendAttachBandVFX(proj, Color(170, 210, 255, 255), 14, 6, {
		{ radius = 15, height = 4, spin = { p = 0,      y = 80 * 50, r = 60 * 50 }, lineWidth = 2 },
		{ radius = 13, height = 3, spin = { p = 60 * 50, y = -45 * 50, r = 0    }, lineWidth = 2 },
	})

	local timerName = string.format("Arcana_ConductiveShell_%d", proj:EntIndex())

	timer.Create(timerName, ZAP_INTERVAL, 0, function()
		if not IsValid(proj) then
			timer.Remove(timerName)
			return
		end
		zapNearestTarget(proj, owner)
	end)

	proj:CallOnRemove("Arcana_ConductiveShell_Stop", function()
		timer.Remove(timerName)
	end)

	proj:CallOnRemove("Arcana_ConductiveShell_Discharge", function(e)
		if not IsValid(owner) then return end
		local pos = e:GetPos()

		Arcana.Common.ApplyLightningChain(owner, pos, {
			baseDamage  = 55,
			chainDamage = 20,
			spawnTesla  = spawnDischargeTesla,
		})
		spawnDischargeTesla(pos)
		Arcana.Common.LightningImpactVFX(pos, Vector(0, 0, 1), { power = 1 })
	end)
end

Arcana:RegisterEnchantment({
	id = "conductive_shell",
	name = "Conductive Shell",
	description = "Your projectile crackles with electricity in flight, zapping the nearest enemy every 0.1s. On detonation it fully discharges into a chained lightning burst.",
	cost_coins = 1800,
	cost_items = {
		{ name = "mana_crystal_shard", amount = 75 },
	},
	can_apply = function(ply, wep)
		return Arcana.Common.GetWeaponClassification(wep) == "PROJECTILE"
	end,
	on_projectile_fired = function(ply, wep, proj, state)
		augmentProjectile(proj, ply)
	end,
})

if CLIENT then
	local trackedEntities = {}

	-- Register an entity for per-frame particle emission
	net.Receive("Arcana_ConductiveShell_Track", function()
		local ent = net.ReadEntity()
		if not IsValid(ent) then return end
		trackedEntities[ent] = {
			lastPos = ent:GetPos(),
			nextPFX = 0,
		}
	end)

	-- Spark trail + blueflare cloud: same materials, colors, and sizes as ENT:Think
	-- in arcana_lightning_orb.lua, applied per-frame to tracked projectiles.
	hook.Add("Think", "Arcana_ConductiveShell_ClientFX", function()
		local now  = CurTime()
		local ft   = math.max(FrameTime(), 0.001)

		for ent, data in pairs(trackedEntities) do
			if not IsValid(ent) then
				if data.emitter then data.emitter:Finish() end
				trackedEntities[ent] = nil
				continue
			end

			if now < data.nextPFX then continue end
			data.nextPFX = now + 1 / 90

			local pos  = ent:GetPos()
			local vel  = (pos - data.lastPos) / ft
			data.lastPos = pos
			local back = -vel:GetNormalized()

			local em = data.emitter
			if not em then
				em = ParticleEmitter(pos)
				data.emitter = em
			end
			if not em then continue end
			em:SetPos(pos)

			-- Electric sparks trailing behind the projectile
			for i = 1, 5 do
				local p = em:Add("effects/spark", pos + VectorRand() * 4)
				if p then
					p:SetVelocity(back * (60 + math.random(0, 60)) + VectorRand() * 50)
					p:SetDieTime(0.3 + math.Rand(0.1, 0.2))
					p:SetStartAlpha(255)
					p:SetEndAlpha(0)
					p:SetStartSize(8 + math.random(0, 4))
					p:SetEndSize(0)
					p:SetRoll(math.Rand(0, 360))
					p:SetRollDelta(math.Rand(-8, 8))
					p:SetColor(180, 220, 255)
					p:SetAirResistance(80)
					p:SetCollide(false)
				end
			end

			-- Soft electric cloud puff
			local p2 = em:Add("effects/blueflare1", pos)
			if p2 then
				p2:SetVelocity(back * (50 + math.random(0, 40)) + VectorRand() * 15)
				p2:SetDieTime(0.5 + math.Rand(0.1, 0.3))
				p2:SetStartAlpha(180)
				p2:SetEndAlpha(0)
				p2:SetStartSize(22 + math.random(0, 10))
				p2:SetEndSize(40 + math.random(0, 15))
				p2:SetRoll(math.Rand(0, 360))
				p2:SetRollDelta(math.Rand(-1, 1))
				p2:SetColor(170, 210, 255)
				p2:SetAirResistance(70)
				p2:SetCollide(false)
			end
		end
	end)

	-- Dynamic light on each tracked projectile, matching arcana_lightning_orb ENT:Draw
	hook.Add("PostDrawOpaqueRenderables", "Arcana_ConductiveShell_DLight", function()
		local now = CurTime()
		for ent in pairs(trackedEntities) do
			if not IsValid(ent) then continue end
			local dlight = DynamicLight(ent:EntIndex())
			if dlight then
				dlight.pos        = ent:GetPos()
				dlight.r          = 170
				dlight.g          = 210
				dlight.b          = 255
				dlight.brightness = 3.2
				dlight.Decay      = 1200
				dlight.Size       = 250
				dlight.DieTime    = now + 0.1
			end
		end
	end)
end
