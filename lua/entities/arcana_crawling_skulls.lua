AddCSLuaFile()

ENT.Type        = "nextbot"
ENT.Base        = "base_nextbot"
ENT.PrintName   = "Crawling Skulls"
ENT.Author      = "Earu"
ENT.Category    = "Arcana"
ENT.Spawnable   = false
ENT.AdminOnly   = false
ENT.RenderGroup = RENDERGROUP_BOTH

-- ── Tuning ────────────────────────────────────────────────────────────────────

local SKULL_MODEL    = "models/Gibs/HGIBS.mdl"
local SKULL_COUNT     = 5
local WANDER_RADIUS   = 32     -- max offset from controller each skull wanders
local SKULL_Z         = 4      -- base height above ground
local SKULL_R         = 5.5    -- approximate skull model radius (for rolling calc)

local CHASE_RANGE     = 1400
local CHARGE_RANGE    = 500
local CHASE_SPEED     = 200
local CHARGE_SPEED    = 540
local CHARGE_DURATION = 1.1
local CHARGE_DAMAGE   = 25
local CHARGE_RADIUS   = 85
local STUN_DURATION   = 2.2
local TURN_RATE       = 300

local HEALTH          = 80
local XP_REWARD       = 28

local EYE_COLOR       = Color(160, 60, 255, 255)
local DRAW_DISTANCE   = 1500 * 1500

local RAD2DEG = 180 / math.pi
local TWO_PI  = math.pi * 2

-- Per-skull unique parameters (deterministic from index)
local SKULL_PARAMS = {}
for i = 1, SKULL_COUNT do
	local seed = i * 1.618033
	SKULL_PARAMS[i] = {
		freqX  = 0.7 + (i * 0.37) % 0.7,   -- 0.7 – 1.4 Hz wander
		freqY  = 0.8 + (i * 0.53) % 0.6,   -- 0.8 – 1.4 Hz
		phaseX = seed * TWO_PI * 0.41,
		phaseY = seed * TWO_PI * 0.67,
		rollOff = i * 72,                   -- unique starting roll per skull
	}
end

-- Returns world pos and angles for skull i at time t.
-- Fully deterministic — server uses this for death gibs, client for rendering.
local function SkullState(ctrlPos, ctrlAng, i, isCharging, isStunned, t)
	local p = SKULL_PARAMS[i]

	-- Each skull independently wanders via two-axis sine waves
	local radius = isCharging and 12 or (isStunned and (WANDER_RADIUS * (1.6 + (i % 3) * 0.4)) or WANDER_RADIUS)

	local sx = math.sin(t * p.freqX + p.phaseX)
	local cy = math.cos(t * p.freqY + p.phaseY)
	local offsetX = sx * radius
	local offsetY = cy * radius

	-- Instantaneous velocity of this skull's wander (derivative of the above)
	local velX = p.freqX * math.cos(t * p.freqX + p.phaseX) * radius
	local velY = -p.freqY * math.sin(t * p.freqY + p.phaseY) * radius

	local skullSpeed, moveYaw
	if isCharging then
		-- Rush with the controller
		local fwd = ctrlAng:Forward()
		velX, velY = fwd.x * CHARGE_SPEED, fwd.y * CHARGE_SPEED
		skullSpeed = CHARGE_SPEED
		moveYaw    = ctrlAng.y
	else
		skullSpeed = math.sqrt(velX * velX + velY * velY)
		moveYaw    = (skullSpeed > 0.5) and (math.atan2(velY, velX) * RAD2DEG) or 0
	end

	-- Ground bounce: absolute-value of a fast sine — skull bounces off the floor
	local bounce = math.abs(math.sin(t * p.freqX * 3.1 + p.phaseY)) * 3

	local pos = ctrlPos + Vector(offsetX, offsetY, SKULL_Z + bounce)

	-- Roll: angle = (distance_traveled / circumference) * 360
	-- Approximate distance_traveled as t * average_speed
	local avgSpeed  = radius * (p.freqX + p.freqY) * 0.5 * math.sqrt(2) * 0.5
	local effective = isCharging and CHARGE_SPEED or avgSpeed
	local rollAngle = (t * effective / SKULL_R * RAD2DEG + p.rollOff) % 360

	-- Yaw from velocity direction; pitch = roll
	local ang = Angle(rollAngle, moveYaw, 0)

	return pos, ang
end

-- ── Network ───────────────────────────────────────────────────────────────────

function ENT:SetupDataTables()
	self:NetworkVar("Bool", 0, "Charging")
	self:NetworkVar("Bool", 1, "Stunned")
end

-- ── Server ────────────────────────────────────────────────────────────────────

if SERVER then
	util.AddNetworkString("Arcana_CrawlSkullImpact")

	function ENT:Initialize()
		-- Use a minimal model; Draw() never calls DrawModel() so it stays invisible.
		-- Do NOT scale the model — model scale can override SetCollisionBounds.
		self:SetModel("models/hunter/misc/sphere025x025.mdl")
		self:SetSolid(SOLID_BBOX)
		self:SetCollisionBounds(Vector(-48, -48, 0), Vector(48, 48, 26))
		self:SetHealth(HEALTH)
		self:SetMaxHealth(HEALTH)
		self:SetCollisionGroup(COLLISION_GROUP_NPC)
		self:DrawShadow(false)
		self:SetBloodColor(DONT_BLEED)

		if self.loco then
			self.loco:SetAcceleration(1400)
			self.loco:SetDeceleration(1800)
			self.loco:SetDesiredSpeed(CHASE_SPEED)
			self.loco:SetStepHeight(12)
			self.loco:SetJumpHeight(0)
		end

		self:SetCharging(false)
		self:SetStunned(false)
		self._lastScan  = 0
		self._nextClick = 0
	end

	function ENT:Wait(seconds)
		local endTime = CurTime() + (tonumber(seconds) or 0)
		repeat self:BodyUpdate(); coroutine.yield() until CurTime() >= endTime
	end

	function ENT:BodyUpdate()
		self:FrameAdvance()
	end

	local function IsEnemy(ply)
		return IsValid(ply) and ply:IsPlayer() and ply:Alive()
	end

	function ENT:AcquireTarget()
		local now = CurTime()
		if now < self._lastScan then return self._target end
		self._lastScan = now + 0.35
		local myPos = self:GetPos()
		local nearest, bestD2 = nil, CHASE_RANGE * CHASE_RANGE
		for _, ply in ipairs(player.GetAll()) do
			if IsEnemy(ply) then
				local d2 = myPos:DistToSqr(ply:GetPos())
				if d2 < bestD2 then bestD2 = d2; nearest = ply end
			end
		end
		self._target = nearest
		return nearest
	end

	function ENT:FaceTowards(pos)
		local ang  = (pos - self:GetPos()):Angle()
		ang.p = 0; ang.r = 0
		local cur  = self:GetAngles()
		local diff = math.AngleDifference(ang.y, cur.y)
		local step = math.Clamp(diff, -FrameTime() * TURN_RATE, FrameTime() * TURN_RATE)
		self:SetAngles(Angle(0, cur.y + step, 0))
	end

	function ENT:RunBehaviour()
		while true do
			if self:Health() <= 0 then return end
			local tgt = self:AcquireTarget()
			if IsValid(tgt) then
				if self:GetPos():Distance(tgt:GetPos()) <= CHARGE_RANGE then
					self:DoCharge(tgt)
				else
					self:ChaseTarget(tgt)
				end
			else
				self:Wait(math.Rand(0.3, 0.7))
			end
			coroutine.yield()
		end
	end

	function ENT:ChaseTarget(tgt)
		if self.loco then self.loco:SetDesiredSpeed(CHASE_SPEED) end
		local lastRepath = 0
		while IsValid(tgt) and tgt:Alive() do
			if self.loco and self.loco:IsStuck() then self:HandleStuck() end
			local myPos = self:GetPos()
			local dist  = myPos:Distance(tgt:GetPos())
			if dist > CHASE_RANGE or dist <= CHARGE_RANGE then break end
			self:FaceTowards(tgt:GetPos())
			if self.loco then
				self.loco:FaceTowards(tgt:GetPos())
				if lastRepath <= CurTime() then
					self:MoveToPos(tgt:GetPos(), { repath = 0.4, tolerance = CHARGE_RANGE * 0.8 })
					lastRepath = CurTime() + 0.4
				end
			end
			coroutine.yield()
		end
	end

	function ENT:DoCharge(tgt)
		if not IsValid(tgt) then return end

		local chargeTarget = tgt:GetPos() -- snapshot NOW; charge is dodgeable

		self:FaceTowards(chargeTarget)
		if self.loco then
			self.loco:FaceTowards(chargeTarget)
			self.loco:SetDesiredSpeed(CHARGE_SPEED)
		end

		self:SetCharging(true)
		self:EmitSound("physics/stone/stone_box_impact_hard2.wav", 72, math.random(90, 110), 1)

		local chargeEnd = CurTime() + CHARGE_DURATION
		local chargeHit = false
		while not chargeHit and CurTime() < chargeEnd do
			if self.loco then
				self.loco:Approach(chargeTarget, 1)
				self.loco:FaceTowards(chargeTarget)
			end
			local myPos = self:GetPos()
			if myPos:DistToSqr(chargeTarget) < 50 * 50 then break end
			for _, ply in ipairs(player.GetAll()) do
				if IsEnemy(ply) and myPos:DistToSqr(ply:GetPos()) <= (CHARGE_RADIUS * 1.2)^2 then
					chargeHit = true
					break
				end
			end
			if not chargeHit then coroutine.yield() end
		end

		local impactPos = self:GetPos()
		self:EmitSound("physics/concrete/concrete_impact_hard" .. math.random(1, 3) .. ".wav", 78, math.random(85, 105), 1)

		Arcana:BlastDamage(self, impactPos, CHARGE_RADIUS, CHARGE_DAMAGE, {
			damageType     = DMG_CRUSH,
			ignoreAttacker = true,
		})

		net.Start("Arcana_CrawlSkullImpact")
		net.WriteVector(impactPos)
		net.Broadcast()

		self:SetCharging(false)
		self:SetStunned(true)
		self:Wait(STUN_DURATION)
		self:SetStunned(false)
		if self.loco then self.loco:SetDesiredSpeed(CHASE_SPEED) end
	end

	function ENT:OnTraceAttack(dmginfo, dir, tr)
		self:TakeDamageInfo(dmginfo)
	end

	function ENT:OnInjured(dmginfo)
		local atk = dmginfo:GetAttacker()
		if IsValid(atk) and atk:IsPlayer() then self._lastHurtBy = atk end
		self:EmitSound("physics/stone/stone_box_impact_hard" .. math.random(1, 3) .. ".wav", 62, math.random(95, 110), 1)
	end

	function ENT:OnKilled(dmginfo)
		local killer = dmginfo:GetAttacker()
		if not (IsValid(killer) and killer:IsPlayer()) then killer = self._lastHurtBy end
		if IsValid(killer) and killer:IsPlayer() and not Arcana:IsPotentialCheater(killer) then
			Arcana:GiveXP(killer, XP_REWARD, "Crawling Skulls defeated")
		end

		-- Scatter gibs from each skull's visual position at death
		local t          = CurTime()
		local myPos      = self:GetPos()
		local myAng      = self:GetAngles()
		local isCharging = self:GetCharging()
		local isStunned  = self:GetStunned()

		for i = 1, SKULL_COUNT do
			local skullPos = SkullState(myPos, myAng, i, isCharging, isStunned, t)
			local gib      = ents.Create("prop_physics")
			if IsValid(gib) then
				gib:SetModel(SKULL_MODEL)
				gib:SetPos(skullPos)
				gib:SetAngles(AngleRand())
				gib:Spawn()
				gib:SetCollisionGroup(COLLISION_GROUP_DEBRIS)
				local phys = gib:GetPhysicsObject()
				if IsValid(phys) then
					phys:SetVelocity(VectorRand() * math.Rand(130, 240) + Vector(0, 0, math.Rand(90, 180)))
					phys:AddAngleVelocity(VectorRand() * 360)
				end
				SafeRemoveEntityDelayed(gib, math.Rand(6, 10))
			end
		end

		hook.Run("OnNPCKilled", self, IsValid(killer) and killer or dmginfo:GetAttacker(), dmginfo:GetInflictor())
		SafeRemoveEntity(self)
	end

	function ENT:Think()
		local now   = CurTime()
		local speed = self:GetVelocity():Length2D()
		-- Rattle sounds while moving
		if speed > 30 and not self:GetStunned() then
			if now >= self._nextClick then
				local interval   = self:GetCharging() and 0.07 or math.Clamp(0.28 * (CHASE_SPEED / math.max(speed, 1)), 0.1, 0.35)
				self._nextClick  = now + interval
				self:EmitSound("physics/stone/stone_box_impact_hard" .. math.random(1, 3) .. ".wav", 52, math.random(105, 130), 0.6)
			end
		end
		self:NextThink(now)
		return true
	end

	function ENT:SpawnFunction(ply, tr, classname)
		if not tr or not tr.Hit then return end
		local ent = ents.Create(classname or "arcana_crawling_skulls")
		if not IsValid(ent) then return end
		ent:SetPos(tr.HitPos + tr.HitNormal * 2)
		ent:SetAngles(Angle(0, ply:EyeAngles().y, 0))
		ent:Spawn()
		ent:Activate()
		return ent
	end
end

-- ── Client ────────────────────────────────────────────────────────────────────

if CLIENT then
	local matGlow = Material("sprites/light_glow02_add")

	Arcana.CrawlSkullImpacts = Arcana.CrawlSkullImpacts or {}

	net.Receive("Arcana_CrawlSkullImpact", function()
		local pos = net.ReadVector()
		util.ScreenShake(pos, 7, 90, 0.45, 650)

		local emitter = ParticleEmitter(pos)
		if emitter then
			for i = 1, 28 do
				local p = emitter:Add("effects/spark", pos)
				if p then
					p:SetVelocity(VectorRand() * 220)
					p:SetDieTime(math.Rand(0.3, 0.7))
					p:SetStartAlpha(255)
					p:SetEndAlpha(0)
					p:SetStartSize(math.Rand(4, 7))
					p:SetEndSize(0)
					p:SetColor(160, 60, 255)
					p:SetGravity(Vector(0, 0, -600))
					p:SetCollide(true)
					p:SetBounce(0.3)
				end
			end
			for i = 1, 10 do
				local p = emitter:Add("particle/particle_smokegrenade", pos + VectorRand() * 8)
				if p then
					p:SetVelocity(VectorRand() * 50 + Vector(0, 0, 15))
					p:SetDieTime(math.Rand(0.4, 0.7))
					p:SetStartAlpha(110)
					p:SetEndAlpha(0)
					p:SetStartSize(math.Rand(14, 22))
					p:SetEndSize(math.Rand(30, 50))
					p:SetColor(60, 30, 80)
					p:SetRoll(math.Rand(0, 360))
					p:SetAirResistance(80)
				end
			end
			emitter:Finish()
		end

		table.insert(Arcana.CrawlSkullImpacts, { pos = pos, startTime = CurTime(), dieTime = CurTime() + 0.35 })
	end)

	hook.Add("PostDrawTranslucentRenderables", "Arcana_CrawlSkullImpactRender", function(_, isSkybox)
		if isSkybox then return end
		local curTime = CurTime()
		for i = #Arcana.CrawlSkullImpacts, 1, -1 do
			local imp = Arcana.CrawlSkullImpacts[i]
			if curTime > imp.dieTime then
				table.remove(Arcana.CrawlSkullImpacts, i)
			else
				local frac  = (curTime - imp.startTime) / 0.35
				local alpha = (1 - frac) * 210
				local size  = Lerp(frac, 60, 200)
				render.SetMaterial(matGlow)
				render.DrawSprite(imp.pos, size, size, Color(160, 60, 255, alpha))
			end
		end
	end)

	function ENT:Initialize()
		self._smoothPos   = {}
		self._nextRattle  = 0
		self._nextMiasma  = 0
		self._emitter     = ParticleEmitter(self:GetPos())
		for i = 1, SKULL_COUNT do
			self._smoothPos[i] = self:GetPos()
		end
	end

	function ENT:OnRemove()
		if self._emitter then
			self._emitter:Finish()
			self._emitter = nil
		end
	end

	function ENT:Think()
		local now   = CurTime()
		local speed = self:GetVelocity():Length2D()

		-- Rolling rattle
		if speed > 30 and not self:GetStunned() and now >= self._nextRattle then
			local interval   = self:GetCharging() and 0.06 or math.Clamp(0.25 * (CHASE_SPEED / math.max(speed, 1)), 0.08, 0.3)
			self._nextRattle = now + interval
			self:EmitSound("physics/stone/stone_box_impact_hard" .. math.random(1, 3) .. ".wav", 48, math.random(110, 135), 0.5)
		end

		-- Dark miasma: low-lying cursed smoke that envelops the whole group,
		-- making them read as one corrupted mass rather than separate skulls.
		if EyePos():DistToSqr(self:GetPos()) <= DRAW_DISTANCE and now >= self._nextMiasma and self._emitter then
			self._nextMiasma = now + 0.045
			self._emitter:SetPos(self:GetPos())
			local myPos      = self:GetPos()
			local isStunned  = self:GetStunned()
			local spreadMul  = isStunned and 2.0 or 1.0

			for j = 1, 3 do
				local spread  = VectorRand() * (WANDER_RADIUS * spreadMul)
				spread.z = 0
				local spawnZ  = math.Rand(0, 14)
				local p = self._emitter:Add("particle/particle_smokegrenade", myPos + spread + Vector(0, 0, spawnZ))
				if p then
					p:SetVelocity(VectorRand() * 5 + Vector(0, 0, 9))
					p:SetDieTime(math.Rand(1.0, 1.8))
					p:SetStartAlpha(55)
					p:SetEndAlpha(0)
					p:SetStartSize(math.Rand(18, 30))
					p:SetEndSize(math.Rand(40, 60))
					p:SetColor(10, 4, 22) -- near-black dark purple
					p:SetRoll(math.Rand(0, 360))
					p:SetRollDelta(math.Rand(-0.4, 0.4))
					p:SetAirResistance(18)
					p:SetGravity(Vector(0, 0, 5))
					p:SetLighting(false)
				end
			end
		end

		self:NextThink(now)
		return true
	end

	function ENT:Draw()
		if EyePos():DistToSqr(self:GetPos()) > DRAW_DISTANCE then return end

		local t          = CurTime()
		local ft         = FrameTime()
		local myPos      = self:GetPos()
		local myAng      = self:GetAngles()
		local isCharging = self:GetCharging()
		local isStunned  = self:GetStunned()

		local lerpSpeed = isCharging and 10 or 5
		local alpha     = math.min(1, lerpSpeed * ft)

		for i = 1, SKULL_COUNT do
			local targetPos, skullAng = SkullState(myPos, myAng, i, isCharging, isStunned, t)

			if not self._smoothPos[i] then self._smoothPos[i] = targetPos end
			self._smoothPos[i] = LerpVector(alpha, self._smoothPos[i], targetPos)

			local skullPos = self._smoothPos[i]

			render.Model({ model = SKULL_MODEL, pos = skullPos, angle = skullAng })

			local fwd   = skullAng:Forward()
			local right = skullAng:Right()
			local up    = skullAng:Up()
			render.SetMaterial(matGlow)
			render.DrawSprite(skullPos + fwd * 2 + right * 1.5 + up * 0.5, 12, 12, EYE_COLOR)
			render.DrawSprite(skullPos + fwd * 2 - right * 1.5 + up * 0.5, 12, 12, EYE_COLOR)
		end
	end
end
