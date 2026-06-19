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

local LUNGE_DISTANCE  = 48     -- how far ahead of its center the swarm lunges on a charge

local CHASE_RANGE     = 1400
local CHARGE_RANGE    = 500
local CHASE_SPEED     = 200
local CHARGE_SPEED    = 540
local CHARGE_DURATION = 1.1
local CHARGE_DAMAGE   = 45     -- full damage at the swarm's core
local CHARGE_RADIUS   = 100    -- horizontal reach of the charge slam
local CHARGE_MIN_FRAC = 0.55   -- damage floor so side hits still bite
local STUN_DURATION   = 2.2
local TURN_RATE       = 300

-- Continuous gnawing damage while the swarm is pressed against a player
local CONTACT_DAMAGE   = 9
local CONTACT_RADIUS   = 62
local CONTACT_INTERVAL = 0.45
local VERTICAL_REACH   = 96    -- skulls crawl low; only bite within this height band

local HEALTH          = 80
local XP_REWARD       = 28

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

	-- During a charge the swarm lunges forward, converging on a point ahead of its
	-- center so the skulls (and the impact) land where the target actually is — the
	-- collision box otherwise holds the controller's origin well short of the player.
	if isCharging then
		local fwd = ctrlAng:Forward()
		fwd.z = 0
		pos = pos + fwd:GetNormalized() * LUNGE_DISTANCE
	end

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

	-- The swarm crawls along the ground while players are tall and get shoved to the
	-- collision-box edge, so a spherical blast (centered low, 3D falloff) barely scratches
	-- them. Damage players with a horizontal (cylinder) check plus a damage floor instead,
	-- so a hit anywhere around the swarm — including the sides — lands meaningfully.
	local function DamagePlayersAround(attacker, center, radius, baseDamage, minFrac, dmgType)
		local r2 = radius * radius
		for _, ply in ipairs(player.GetAll()) do
			if not (IsValid(ply) and ply:Alive()) then continue end

			local pp = ply:WorldSpaceCenter()
			if math.abs(pp.z - center.z) > VERTICAL_REACH then continue end

			local dx, dy = pp.x - center.x, pp.y - center.y
			local d2 = dx * dx + dy * dy
			if d2 > r2 then continue end

			local frac = math.max(minFrac, 1 - math.sqrt(d2) / radius)

			local dmg = DamageInfo()
			dmg:SetDamage(baseDamage * frac)
			dmg:SetDamageType(dmgType or DMG_CRUSH)
			dmg:SetAttacker(attacker)
			dmg:SetInflictor(attacker)
			dmg:SetDamagePosition(pp)
			Arcana:TakeDamageInfo(ply, dmg)
		end
	end

	function ENT:Initialize()
		-- Use a minimal model; Draw() never calls DrawModel() so it stays invisible.
		-- Do NOT scale the model — model scale can override SetCollisionBounds.
		self:SetModel("models/hunter/misc/sphere025x025.mdl")
		self:SetSolid(SOLID_BBOX)
		-- Tighter box so the low-crawling swarm can actually press up against players
		-- (the old 96-wide box held them at arm's length and gutted charge damage).
		self:SetCollisionBounds(Vector(-28, -28, 0), Vector(28, 28, 28))
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
		self._lastScan    = 0
		self._nextClick   = 0
		self._nextContact = 0
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

		-- The swarm's skulls visually converge on a point LUNGE_DISTANCE ahead of the
		-- controller's origin (see SkullState). Damage and the impact FX must use that
		-- same point so they land where the player sees the skulls slam together.
		local function LungePoint()
			local fwd = self:GetForward()
			fwd.z = 0
			return self:GetPos() + fwd:GetNormalized() * LUNGE_DISTANCE
		end

		local chargeEnd = CurTime() + CHARGE_DURATION
		local chargeHit = false
		while not chargeHit and CurTime() < chargeEnd do
			if self.loco then
				self.loco:Approach(chargeTarget, 1)
				self.loco:FaceTowards(chargeTarget)
			end
			local lungePos = LungePoint()
			if self:GetPos():DistToSqr(chargeTarget) < 50 * 50 then break end
			for _, ply in ipairs(player.GetAll()) do
				if not IsEnemy(ply) then continue end
				local pp = ply:WorldSpaceCenter()
				if math.abs(pp.z - lungePos.z) > VERTICAL_REACH then continue end
				local dx, dy = pp.x - lungePos.x, pp.y - lungePos.y
				if (dx * dx + dy * dy) <= CHARGE_RADIUS * CHARGE_RADIUS then
					chargeHit = true
					break
				end
			end
			if not chargeHit then coroutine.yield() end
		end

		local impactPos = LungePoint()
		self:EmitSound("physics/concrete/concrete_impact_hard" .. math.random(1, 3) .. ".wav", 78, math.random(85, 105), 1)

		DamagePlayersAround(self, impactPos, CHARGE_RADIUS, CHARGE_DAMAGE, CHARGE_MIN_FRAC, DMG_CRUSH)

		-- Reset the contact-damage timer so the slam and the gnaw don't stack on the same frame
		self._nextContact = CurTime() + CONTACT_INTERVAL

		-- Raise the FX to the skulls' crawl height so the burst reads as coming from them
		net.Start("Arcana_CrawlSkullImpact")
		net.WriteVector(impactPos + Vector(0, 0, SKULL_Z + 6))
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

		-- Gnawing contact damage: the swarm hurts anyone it's pressed against, so
		-- players can't just facetank it between charges (stun is a safe recovery window).
		if not self:GetCharging() and not self:GetStunned() and now >= self._nextContact then
			self._nextContact = now + CONTACT_INTERVAL
			DamagePlayersAround(self, self:GetPos(), CONTACT_RADIUS, CONTACT_DAMAGE, 1, DMG_SLASH)
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
	local matGlow  = Material("sprites/light_glow02_add")
	local matCore  = Material("sprites/light_glow02_add")
	local EMBER_MAT = "particle/particle_smokegrenade"

	-- Cursed-bone color modulation so the gibs read as desaturated, necrotic skulls
	local BONE_TINT      = { 0.42, 0.40, 0.50 }
	local BONE_TINT_CHRG = { 0.70, 0.46, 0.90 }
	local HALO_COLOR     = Color(150, 70, 255)
	local CORE_COLOR     = Color(225, 195, 255)

	-- Per-skull flicker so eyes pulse independently (deterministic, like SkullState)
	local function EyeFlicker(i, t)
		local p = SKULL_PARAMS[i]
		local base = 0.78 + 0.22 * math.sin(t * (5.0 + i * 0.7) + p.phaseX)
		-- Occasional sharp dip — a guttering candle / dying soul
		local dip = math.sin(t * (1.7 + i * 0.31) + p.phaseY)
		if dip > 0.92 then base = base * 0.35 end
		return math.Clamp(base, 0.2, 1.0)
	end

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
		self._nextEmber   = 0
		self._lightGlow   = 0       -- smoothed intensity for the group dynamic light
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
		local myPos = self:GetPos()
		local close = EyePos():DistToSqr(myPos) <= DRAW_DISTANCE

		local isCharging = self:GetCharging()
		local isStunned  = self:GetStunned()

		-- Rolling rattle
		if speed > 30 and not isStunned and now >= self._nextRattle then
			local interval   = isCharging and 0.06 or math.Clamp(0.25 * (CHASE_SPEED / math.max(speed, 1)), 0.08, 0.3)
			self._nextRattle = now + interval
			self:EmitSound("physics/stone/stone_box_impact_hard" .. math.random(1, 3) .. ".wav", 48, math.random(110, 135), 0.5)
		end

		-- Group dynamic light: a pulsing purple glow that flares while charging
		-- and dims (but keeps an unsettling smoulder) while stunned.
		local target = isStunned and 0.35 or (isCharging and 1.5 or 1.0)
		local flicker = 0.9 + 0.1 * math.sin(now * 11 + self:EntIndex())
		self._lightGlow = Lerp(FrameTime() * 6, self._lightGlow, target * flicker)

		if close then
			local dl = DynamicLight(self:EntIndex())
			if dl then
				dl.pos       = myPos + Vector(0, 0, 10)
				dl.r         = 150
				dl.g         = 50
				dl.b         = 255
				dl.brightness = 1.3 * self._lightGlow
				dl.decay     = 1000
				dl.size      = 150 + 90 * self._lightGlow
				dl.dietime   = now + 0.1
			end
		end

		-- Soul embers: small purple sparks rise off the swarm while it moves,
		-- intensifying into a comet-like wake during a charge.
		if close and self._emitter and now >= self._nextEmber and (speed > 30 or isCharging) then
			self._nextEmber = now + (isCharging and 0.012 or 0.04)
			local t        = CurTime()
			local myAng    = self:GetAngles()
			local count    = isCharging and 3 or 1
			for _ = 1, count do
				local i        = math.random(1, SKULL_COUNT)
				local sPos     = SkullState(myPos, myAng, i, isCharging, isStunned, t)
				local p = self._emitter:Add(EMBER_MAT, sPos + VectorRand() * 3 + Vector(0, 0, 2))
				if p then
					p:SetVelocity(VectorRand() * 8 + Vector(0, 0, isCharging and 26 or 16))
					p:SetDieTime(math.Rand(0.35, 0.7))
					p:SetStartAlpha(isCharging and 220 or 150)
					p:SetEndAlpha(0)
					p:SetStartSize(math.Rand(2.5, 5))
					p:SetEndSize(0)
					p:SetColor(170, 80, 255)
					p:SetAirResistance(40)
					p:SetGravity(Vector(0, 0, 14))
					p:SetLighting(false)
				end
			end
		end

		-- Dark miasma: low-lying cursed smoke that envelops the whole group,
		-- making them read as one corrupted mass rather than separate skulls.
		if close and now >= self._nextMiasma and self._emitter then
			self._nextMiasma = now + 0.045
			self._emitter:SetPos(myPos)
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
		local tint      = isCharging and BONE_TINT_CHRG or BONE_TINT

		-- Pass 1: the skulls themselves, tinted to a cursed necrotic bone hue
		render.SetColorModulation(tint[1], tint[2], tint[3])
		for i = 1, SKULL_COUNT do
			local targetPos, skullAng = SkullState(myPos, myAng, i, isCharging, isStunned, t)

			if not self._smoothPos[i] then self._smoothPos[i] = targetPos end
			self._smoothPos[i] = LerpVector(alpha, self._smoothPos[i], targetPos)

			render.Model({ model = SKULL_MODEL, pos = self._smoothPos[i], angle = skullAng })
		end
		render.SetColorModulation(1, 1, 1)

		-- Pass 2: additive glows (ground halo + layered eyes) drawn over the bones
		render.SetMaterial(matGlow)
		for i = 1, SKULL_COUNT do
			local skullPos = self._smoothPos[i]
			-- Soft underglow pooling on the ground beneath each skull
			render.DrawSprite(skullPos - Vector(0, 0, SKULL_Z + 1), 34, 34, Color(110, 45, 200, 60))
		end

		for i = 1, SKULL_COUNT do
			local _, skullAng = SkullState(myPos, myAng, i, isCharging, isStunned, t)
			local skullPos = self._smoothPos[i]

			local fwd   = skullAng:Forward()
			local right = skullAng:Right()
			local up    = skullAng:Up()

			local fl     = EyeFlicker(i, t)
			local eMul   = isCharging and 1.6 or 1.0
			local lEye   = skullPos + fwd * 2 + right * 1.5 + up * 0.5
			local rEye   = skullPos + fwd * 2 - right * 1.5 + up * 0.5
			local haloSz = 16 * fl * eMul
			local coreSz = 6 * fl * eMul
			local haloA  = 235 * fl
			local coreA  = 255 * fl

			-- Outer halo
			render.SetMaterial(matGlow)
			render.DrawSprite(lEye, haloSz, haloSz, Color(HALO_COLOR.r, HALO_COLOR.g, HALO_COLOR.b, haloA))
			render.DrawSprite(rEye, haloSz, haloSz, Color(HALO_COLOR.r, HALO_COLOR.g, HALO_COLOR.b, haloA))
			-- Bright inner core
			render.SetMaterial(matCore)
			render.DrawSprite(lEye, coreSz, coreSz, Color(CORE_COLOR.r, CORE_COLOR.g, CORE_COLOR.b, coreA))
			render.DrawSprite(rEye, coreSz, coreSz, Color(CORE_COLOR.r, CORE_COLOR.g, CORE_COLOR.b, coreA))
		end
	end
end
