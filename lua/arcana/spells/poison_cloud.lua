local function getAimPointWithinRange(ply, maxRange)
	local tr = ply:GetEyeTrace()
	local hitPos = tr.HitPos or (ply:GetShootPos() + ply:GetAimVector() * maxRange)
	if hitPos:DistToSqr(ply:GetPos()) > (maxRange * maxRange) then
		hitPos = ply:GetShootPos() + ply:GetAimVector() * maxRange
	end
	return hitPos
end

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
					if rec.oldWalk then ply:SetWalkSpeed(rec.oldWalk) end
					if rec.oldRun then ply:SetRunSpeed(rec.oldRun) end
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
	description = "Deploy a lingering toxic cloud that poisons and slows enemies inside",
	category = Arcane.CATEGORIES.COMBAT,
	level_required = 4,
	knowledge_cost = 1,
	cooldown = 10.0,
	cost_type = Arcane.COST_TYPES.COINS,
	cost_amount = 25,
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
		local perTickDamage = 5
		local slowRefresh = 1.2

		local pos
		if ctx and ctx.circlePos then
			pos = ctx.circlePos
		else
			pos = getAimPointWithinRange(caster, 900)
		end
		pos = pos + Vector(0, 0, 8)

		local cloud = ents.Create("prop_physics")
		if not IsValid(cloud) then return false end

		cloud:SetModel("models/props_junk/garbage_glassbottle002a.mdl")
		cloud:SetPos(pos)
		cloud:Spawn()
		cloud:SetMoveType(MOVETYPE_NONE)
		if cloud.CPPISetOwner then cloud:CPPISetOwner(caster) end

		local phys = cloud:GetPhysicsObject()
		if IsValid(phys) then
			phys:Wake()
			phys:EnableMotion(false)
			phys:EnableCollisions(false)
		end

		-- Mark for client visuals
		cloud:SetNWBool("ArcanaPoisonCloud", true)
		cloud:SetNWFloat("ArcanaPoisonCloudEnd", CurTime() + duration)
		cloud:SetNWFloat("ArcanaPoisonCloudRadius", radius)

		Arcane:SendAttachBandVFX(cloud, Color(110, 200, 110, 255), radius * 0.9, duration, {
			{ radius = radius * 0.9, height = 6,  spin = { p = 0.2, y = 0.4, r = 0.1 }, lineWidth = 2 },
			{ radius = radius * 0.6, height = 10, spin = { p = -0.3, y = -0.2, r = 0.0 }, lineWidth = 2 },
		})

		-- Add volumetric smoke using env_smokestack clusters (server-side)
		do
			local stackCount = 10
			local discR = math.min(200, radius * 0.8)
			for i = 1, stackCount do
				local rr = discR * math.sqrt(math.Rand(0.2, 1.0))
				local ang = math.Rand(0, math.pi * 2)
				local spos = pos + Vector(math.cos(ang) * rr, math.sin(ang) * rr, math.Rand(0, 12))
				local stack = ents.Create("env_smokestack")
				if IsValid(stack) then
					stack:SetPos(spos)
					stack:SetKeyValue("InitialState", "1")
					stack:SetKeyValue("BaseSpread", "35")
					stack:SetKeyValue("SpreadSpeed", "25")
					stack:SetKeyValue("Speed", "45")
					stack:SetKeyValue("StartSize", "22")
					stack:SetKeyValue("EndSize", "100")
					stack:SetKeyValue("Rate", "50")
					stack:SetKeyValue("JetLength", "240")
					stack:SetKeyValue("Twist", "8")
					stack:SetKeyValue("RenderColor", "110 200 110")
					stack:SetKeyValue("RenderAmt", "140")
					stack:SetKeyValue("SmokeMaterial", "particle/particle_smokegrenade")
					stack:Spawn()
					stack:Activate()
					stack:SetParent(cloud)
					stack:Fire("TurnOn", "", 0)
					SafeRemoveEntityDelayed(stack, duration + 0.2)
				end
			end
		end

		-- Client visuals handled in this file (CLIENT block below)

		sound.Play("ambient/levels/canals/toxic_slime_gurgle5.wav", pos, 70, 100, 0.6)

		local tid = "Arcana_PoisonCloud_" .. cloud:EntIndex()
		timer.Create(tid, tickInterval, math.floor(duration / tickInterval), function()
			if not IsValid(cloud) then
				timer.Remove(tid)
				return
			end

			for _, ent in ipairs(ents.FindInSphere(cloud:GetPos(), radius)) do
				if not IsValid(ent) or ent == caster then continue end

				if ent:IsPlayer() or ent:IsNPC() then
					local dmg = DamageInfo()
					dmg:SetDamage(perTickDamage)
					dmg:SetDamageType(DMG_POISON)
					dmg:SetAttacker(IsValid(caster) and caster or game.GetWorld())
					dmg:SetInflictor(IsValid(caster) and caster or game.GetWorld())
					dmg:SetDamagePosition(ent:WorldSpaceCenter())
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

		caster:EmitSound("npc/antlion/idle2.wav", 65, 120, 0.6)
		return true
	end
})


if CLIENT then
	-- Client-only soft green smoke for poison clouds, handled entirely in this file
	local activeEmitters = setmetatable({}, { __mode = "k" })
	local nextScanAt = 0

	hook.Add("Think", "Arcana_PoisonCloud_ClientFX", function()
		local now = CurTime()
		if now < nextScanAt then return end
		nextScanAt = now + 0.05

		-- Cleanup first
		for ent, em in pairs(activeEmitters) do
			if (not IsValid(ent)) or ent:GetNWFloat("ArcanaPoisonCloudEnd", 0) <= now or (not ent:GetNWBool("ArcanaPoisonCloud", false)) then
				if em and em.Finish then em:Finish() end
				activeEmitters[ent] = nil
			end
		end

		-- Discover/emit
		for _, ent in ipairs(ents.GetAll()) do
			if IsValid(ent) and ent:GetNWBool("ArcanaPoisonCloud", false) then
				local endT = ent:GetNWFloat("ArcanaPoisonCloudEnd", 0)
				if endT > now then
					local rad = ent:GetNWFloat("ArcanaPoisonCloudRadius", 200)
					local em = activeEmitters[ent]
					if not em then
						em = ParticleEmitter(ent:GetPos(), false)
						activeEmitters[ent] = em
					end
					if em then
						em:SetPos(ent:GetPos())
						for i = 1, 3 do
							local rr = rad * math.sqrt(math.Rand(0, 1))
							local a = math.Rand(0, math.pi * 2)
							local off = Vector(math.cos(a) * rr, math.sin(a) * rr, math.Rand(0, 10))
							local p = em:Add("particle/particle_smokegrenade", ent:GetPos() + off)
							if p then
								local life = math.Rand(1.4, 2.4)
								p:SetDieTime(life)
								p:SetStartAlpha(0)
								p:SetEndAlpha(140)
								local sz = math.Rand(18, 30)
								p:SetStartSize(sz)
								p:SetEndSize(sz * math.Rand(3.4, 4.6))
								p:SetRoll(math.Rand(0, 360))
								p:SetRollDelta(math.Rand(-0.5, 0.5))
								p:SetColor(110, 200, 110)
								p:SetAirResistance(70)
								p:SetGravity(Vector(0, 0, math.Rand(22, 38)))
								p:SetVelocity(VectorRand():GetNormalized() * math.Rand(10, 32))
								p:SetCollide(false)
							end
						end
					end
				end
			end
		end
	end)
end

