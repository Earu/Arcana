AddCSLuaFile()

ENT.Type         = "nextbot"
ENT.Base         = "base_nextbot"
ENT.PrintName    = "Lich"
ENT.Category     = "Arcana"
ENT.Spawnable    = false
ENT.AdminOnly    = false
ENT.RenderGroup  = RENDERGROUP_BOTH

local LICH_MODEL  = "models/player/skeleton.mdl"

-- Visual theme: all purple
local EYE_COLOR   = Color(160, 60, 255, 255)
local SMOKE_COLOR = Color(15, 8, 25, 220)
local ORB_COLOR   = Color(180, 80, 255, 255)
local ARC_COLOR   = Color(180, 80, 255)
local EYE_SIZE    = 6

if CLIENT then
	ENT._matGlow  = Material("sprites/light_glow02_add")
	ENT._smokeTex = "particle/particle_smokegrenade"

	-- Lightning rendering tables (initialised here so they survive map cleanup)
	Arcana.LichBolts  = Arcana.LichBolts  or {}
	Arcana.LichFlashes = Arcana.LichFlashes or {}
	Arcana.LichChains = Arcana.LichChains  or {}
end

if SERVER then
	util.AddNetworkString("Arcana_LichCastStart")
	util.AddNetworkString("Arcana_LichStrike")
	util.AddNetworkString("Arcana_LichChain")
	resource.AddFile("sound/arcana/skeleton/death.ogg")
end

local GIB_MODELS = {
	"models/Gibs/HGIBS.mdl",
	"models/Gibs/HGIBS_rib.mdl",
	"models/Gibs/HGIBS_scapula.mdl",
	"models/Gibs/HGIBS_spine.mdl",
}

-- Movement / combat tuning
local MOVE_SPEED    = 90
local TURN_RATE     = 160
local CHASE_RANGE   = 2500
local FIRE_RANGE    = 1350
local STANDOFF_DIST = 550
local XP_REWARD     = 150
local FOOTSTEP_MIN_SPEED = 60

-- Spell definitions — cast times are 3× their player counterparts, cooldowns are halved
local SPELLS = {
	lightning_strike = { castTime = 3.0, cooldown = 7.0 },
	lightning_orb    = { castTime = 3.6, cooldown = 11.0 },
}

-- Leg bones to visually suppress on the client
local LEG_BONES = {
	"ValveBiped.Bip01_L_Thigh", "ValveBiped.Bip01_L_Calf",
	"ValveBiped.Bip01_L_Foot",  "ValveBiped.Bip01_L_Toe0",
	"ValveBiped.Bip01_R_Thigh", "ValveBiped.Bip01_R_Calf",
	"ValveBiped.Bip01_R_Foot",  "ValveBiped.Bip01_R_Toe0",
}

-- Upper-body bones used as endpoints for electricity arcs during casting
local ARC_BONE_NAMES = {
	"ValveBiped.Bip01_Head1",
	"ValveBiped.Bip01_Spine4",
	"ValveBiped.Bip01_Spine2",
	"ValveBiped.Bip01_L_UpperArm",
	"ValveBiped.Bip01_R_UpperArm",
	"ValveBiped.Bip01_L_Hand",
	"ValveBiped.Bip01_R_Hand",
}

-- ── Initialisation ────────────────────────────────────────────────────────────

function ENT:Initialize()
	if SERVER then
		self:SetModel(LICH_MODEL)
		self:SetBloodColor(DONT_BLEED)

		if self.loco then
			self.loco:SetAcceleration(800)
			self.loco:SetDeceleration(1000)
			self.loco:SetDesiredSpeed(MOVE_SPEED)
			self.loco:SetStepHeight(22)
			self.loco:SetJumpHeight(0)
		end

		self:SetSolid(SOLID_BBOX)
		self:SetCollisionBounds(Vector(-13, -13, 0), Vector(13, 13, 72))
		self:SetHealth(150)
		self:SetMaxHealth(150)
		self:SetCollisionGroup(COLLISION_GROUP_NPC)
		self:DrawShadow(true)

		local function has(act)
			return act ~= nil and self:SelectWeightedSequence(act) ~= -1
		end

		-- Normal (neutral/unarmed) holdtype for idle and walking
		self._actIdle = has(ACT_HL2MP_IDLE) and ACT_HL2MP_IDLE
		            or  has(ACT_IDLE_RELAXED) and ACT_IDLE_RELAXED
		            or  ACT_IDLE

		self._actWalk = has(ACT_HL2MP_WALK) and ACT_HL2MP_WALK
		            or  has(ACT_HL2MP_RUN)   and ACT_HL2MP_RUN
		            or  ACT_WALK

		-- Magic holdtype, only active while casting
		self._actCastIdle = has(ACT_HL2MP_IDLE_MAGIC)  and ACT_HL2MP_IDLE_MAGIC
		                or  has(ACT_HL2MP_IDLE_MELEE2) and ACT_HL2MP_IDLE_MELEE2
		                or  nil

		self._actGesture  = has(ACT_HL2MP_GESTURE_RANGE_ATTACK_MAGIC) and ACT_HL2MP_GESTURE_RANGE_ATTACK_MAGIC
		                or  has(ACT_GMOD_GESTURE_BECON)               and ACT_GMOD_GESTURE_BECON
		                or  nil

		self._cdTable        = {}
		self._lastTargetScan = 0
		self:SetNWBool("Casting", false)
		self:SetAnimState("idle")
	else
		self._nextSmoke = 0
		self._emitter   = ParticleEmitter(self:GetPos())
		self._headBone  = self:LookupBone("ValveBiped.Bip01_Head1") or self:LookupBone("ValveBiped.Bip01_Neck1")
		self._spineBone = self:LookupBone("ValveBiped.Bip01_Spine4") or self:LookupBone("ValveBiped.Bip01_Spine2")

		self._legBoneIds = {}
		for _, name in ipairs(LEG_BONES) do
			local id = self:LookupBone(name)
			if id then self._legBoneIds[#self._legBoneIds + 1] = id end
		end

		self._arcBoneIds = {}
		for _, name in ipairs(ARC_BONE_NAMES) do
			local id = self:LookupBone(name)
			if id then self._arcBoneIds[#self._arcBoneIds + 1] = id end
		end
	end
end

function ENT:SpawnFunction(ply, tr, classname)
	if not tr or not tr.Hit then return end
	local ent = ents.Create(classname or "arcana_lich")
	if not IsValid(ent) then return end
	ent:SetPos(tr.HitPos + tr.HitNormal * 2)
	ent:SetAngles(Angle(0, ply:EyeAngles().y, 0))
	ent:Spawn()
	ent:Activate()
	return ent
end

-- ── Animation helpers ─────────────────────────────────────────────────────────

function ENT:SetAnimState(state)
	self._animState = state
	if state == "walk" then
		if self._actWalk then self:StartActivity(self._actWalk) end
	else
		if self._actIdle then self:StartActivity(self._actIdle) end
	end
end

function ENT:BodyUpdate()
	if self._animState == "walk" then
		self:BodyMoveXY()
		local speed   = self:GetVelocity():Length2D()
		local desired = (self.loco and self.loco.GetDesiredSpeed and self.loco:GetDesiredSpeed()) or MOVE_SPEED
		self:SetPlaybackRate(desired > 1 and math.Clamp(speed / desired, 0, 2) or 1)
	else
		self:FrameAdvance()
		self:SetPlaybackRate(1)
	end
end

-- Coroutine-safe wait: keeps animating while paused
function ENT:Wait(seconds)
	local endTime = CurTime() + (tonumber(seconds) or 0)
	repeat
		self:BodyUpdate()
		coroutine.yield()
	until CurTime() >= endTime
end

function ENT:FaceTowards(pos)
	local ang  = (pos - self:GetPos()):Angle()
	ang.p = 0; ang.r = 0
	local cur  = self:GetAngles()
	local diff = math.AngleDifference(ang.y, cur.y)
	local step = math.Clamp(diff, -FrameTime() * TURN_RATE, FrameTime() * TURN_RATE)
	self:SetAngles(Angle(0, cur.y + step, 0))
end

function ENT:UpdateFootsteps(speed)
	if not self.loco or not self.loco:IsOnGround() then return end
	if (speed or 0) < FOOTSTEP_MIN_SPEED then return end
	local now = CurTime()
	local interval = math.Clamp(260 / math.max(speed, 1), 0.22, 0.45)
	if now < (self._nextStep or 0) then return end
	self._nextStep = now + interval / 2
	self:EmitSound("physics/wood/wood_furniture_impact_soft" .. math.random(1, 3) .. ".wav", 55, math.random(95, 105), 1)
end

-- ── Target acquisition ────────────────────────────────────────────────────────

local function IsEnemy(e)
	return IsValid(e) and e:IsPlayer() and e:Alive()
end

function ENT:AcquireTarget()
	local now = CurTime()
	if now < (self._lastTargetScan or 0) then return self._target end
	self._lastTargetScan = now + 0.4

	local myPos = self:GetPos()
	local nearest, bestD2 = nil, CHASE_RANGE * CHASE_RANGE
	for _, ply in ipairs(player.GetAll()) do
		if IsEnemy(ply) then
			local d2 = myPos:DistToSqr(ply:GetPos())
			if d2 < bestD2 then bestD2, nearest = d2, ply end
		end
	end

	self._target = nearest
	return self._target
end

-- ── Spell management ──────────────────────────────────────────────────────────

function ENT:_NextSpell()
	local now = CurTime()
	local order = math.random() > 0.45
		and { "lightning_orb",    "lightning_strike" }
		or  { "lightning_strike", "lightning_orb" }
	for _, id in ipairs(order) do
		if now >= (self._cdTable[id] or 0) then return id end
	end
end

-- Called inside the RunBehaviour coroutine — yields internally for the cast duration
function ENT:_DoCast(spellId, tgt)
	-- Snapshot where the player is standing RIGHT NOW so they can dodge during the cast
	local strikePos = (spellId == "lightning_strike" and IsValid(tgt)) and tgt:GetPos() or nil

	-- Switch to magic holdtype while casting
	if self._actCastIdle then self:StartActivity(self._actCastIdle) end
	self:SetNWBool("Casting", true)

	if self._actGesture then self:RestartGesture(self._actGesture) end

	net.Start("Arcana_LichCastStart")
	net.WriteEntity(self)
	net.WriteFloat(SPELLS[spellId].castTime)
	net.Broadcast()

	self:EmitSound("ambient/levels/labs/electric_explosion" .. math.random(1, 3) .. ".wav", 65, math.random(80, 95), 0.7)

	-- Stand still but keep facing the target throughout the cast
	local endTime = CurTime() + SPELLS[spellId].castTime
	repeat
		self:BodyUpdate()
		if IsValid(tgt) then
			local tPos = tgt:WorldSpaceCenter()
			self:FaceTowards(tPos)
			if self.loco then self.loco:FaceTowards(tPos) end
		end
		coroutine.yield()
	until CurTime() >= endTime

	-- Deliver the spell
	if IsValid(tgt) then
		if spellId == "lightning_strike" then
			self:_FireLightningStrike(strikePos or tgt:GetPos())
		elseif spellId == "lightning_orb" then
			self:_FireLightningOrb(tgt)
		end
	end

	self._cdTable[spellId] = CurTime() + SPELLS[spellId].cooldown
	self:SetNWBool("Casting", false)
	self:SetAnimState("idle") -- back to normal holdtype
end

-- targetPos is snapshotted at cast-start (feet position), not live — players can dodge by moving
function ENT:_FireLightningStrike(targetPos)
	local strikes = {
		{ delay = 0.00, offset = Vector(0, 0, 0),                                   power = 1.0 },
		{ delay = 0.10, offset = Vector(math.Rand(-70, 70), math.Rand(-70, 70), 0), power = 0.5 },
		{ delay = 0.18, offset = Vector(math.Rand(-70, 70), math.Rand(-70, 70), 0), power = 0.5 },
	}

	for _, s in ipairs(strikes) do
		timer.Simple(s.delay, function()
			if not IsValid(self) then return end
			local pos = targetPos + s.offset

			Arcana.Common.SpawnTeslaBurst(pos, {
				targetname   = "arcana_lich",
				color        = "160 60 255",
				radius       = 280, beamcount_min = 10, beamcount_max = 16,
				thick_min    = 8,   thick_max     = 14,
				lifetime_min = 0.15, lifetime_max = 0.25,
				interval_min = 0.03, interval_max = 0.08,
				kill_delay   = 0.8,
			})

			Arcana.Common.LightningImpactVFX(pos, Vector(0, 0, 1), {
				power      = s.power,
				shakePower = 6, shakeHz = 100, shakeDur = 0.3, shakeRadius = 600,
				soundLvl   = 90,
			})

			net.Start("Arcana_LichStrike", true)
			net.WriteVector(pos)
			net.WriteFloat(s.power)
			net.Broadcast()

			if s.power >= 1.0 then
				local lastPos = pos
				Arcana.Common.ApplyLightningChain(self, pos, {
					baseDamage  = 25,
					blastRadius = 80,
					chainDamage = 10,
					chainDelay  = 0.05,
					onChain     = function(_, tpos)
						sound.Play("ambient/levels/labs/electric_explosion" .. math.random(1, 3) .. ".wav", tpos, 80, 110)
						net.Start("Arcana_LichChain", true)
						net.WriteVector(lastPos)
						net.WriteVector(tpos)
						net.Broadcast()
						lastPos = tpos
					end,
				})
			else
				Arcana:BlastDamage(self, pos, 60, 10, { damageType = DMG_SHOCK })
			end
		end)
	end
end

function ENT:_FireLightningOrb(tgt)
	local myPos = self:WorldSpaceCenter()
	local dir   = (tgt:WorldSpaceCenter() - myPos):GetNormalized()

	local orb = ents.Create("arcana_lightning_orb")
	if not IsValid(orb) then return end

	orb.OrbColor = Color(160, 60, 255, 255)
	orb:SetPos(myPos + dir * 24)
	orb:SetAngles(dir:Angle())
	orb:Spawn()
	orb:Activate()
	Arcana.Common.LaunchProjectile(orb, self, dir)

	self:EmitSound("weapons/physcannon/energy_sing_flyby1.wav", 70, math.random(100, 120), 0.8)
end

-- ── Behaviour coroutine ───────────────────────────────────────────────────────

function ENT:RunBehaviour()
	while true do
		if self:Health() <= 0 then
			local dmg = DamageInfo()
			dmg:SetDamage(self:Health())
			dmg:SetDamageType(DMG_SLASH)
			dmg:SetAttacker(self)
			dmg:SetInflictor(self)
			self:OnKilled(dmg)
			return
		end

		local tgt = self:AcquireTarget()
		if IsValid(tgt) then
			self:_CombatBehaviour(tgt)
		else
			self:SetAnimState("idle")
			self:Wait(math.Rand(0.5, 1.0))
		end

		coroutine.yield()
	end
end

function ENT:_CombatBehaviour(tgt)
	self:SetAnimState("walk")
	local lastRepath = 0

	while IsValid(tgt) and tgt:Alive() do
		self:BodyUpdate()

		if self.loco:IsStuck() then self:HandleStuck() end

		local myPos = self:GetPos()
		local tPos  = tgt:WorldSpaceCenter()
		local d     = myPos:Distance(tPos)

		self:FaceTowards(tPos)
		if self.loco then self.loco:FaceTowards(tPos) end

		if d > CHASE_RANGE then break end

		if not self:GetNWBool("Casting") then
			if d > FIRE_RANGE then
				if lastRepath <= CurTime() then
					self:MoveToPos(tPos, { repath = 0.5, tolerance = FIRE_RANGE * 0.8 })
					lastRepath = CurTime() + 0.5
				end
				self:UpdateFootsteps(self.loco:GetVelocity():Length2D())
			elseif d < STANDOFF_DIST - 60 then
				local away = myPos + (myPos - tPos):GetNormalized() * 300
				self.loco:Approach(away, 1)
				self:UpdateFootsteps(self.loco:GetVelocity():Length2D())
			else
				local toTarget = (tPos - myPos):GetNormalized()
				local right    = toTarget:Cross(Vector(0, 0, 1)):GetNormalized()
				local strafe   = math.sin(CurTime() * 0.55) > 0 and right or -right
				self.loco:Approach(myPos + strafe * 200, 1)
			end

			if d <= FIRE_RANGE then
				local spell = self:_NextSpell()
				if spell then
					self:_DoCast(spell, tgt)
				end
			end
		end

		coroutine.yield()
	end

	self:SetAnimState("idle")
	self:SetNWBool("Casting", false)
end

-- ── Damage callbacks (nextbot style) ─────────────────────────────────────────

function ENT:OnTraceAttack(dmginfo, dir, tr)
end

function ENT:OnInjured(dmginfo)
	local atk = dmginfo:GetAttacker()
	if IsValid(atk) and atk:IsPlayer() then
		self._lastHurtBy = atk
	else
		local inf = dmginfo:GetInflictor()
		local own = IsValid(inf) and inf.GetOwner and inf:GetOwner()
		if IsValid(own) and own:IsPlayer() then self._lastHurtBy = own end
	end
	self:EmitSound("physics/wood/wood_strain" .. math.random(1, 8) .. ".wav", 65, math.random(120, 140), 1)
end

function ENT:OnKilled(dmginfo)
	local killer = dmginfo:GetAttacker()
	if not (IsValid(killer) and killer:IsPlayer()) then killer = self._lastHurtBy end
	if IsValid(killer) and killer:IsPlayer() and not Arcana:IsPotentialCheater(killer) then
		Arcana:GiveXP(killer, XP_REWARD, "Lich defeated")
	end

	self:EmitSound("arcana/skeleton/death.ogg", 75, math.random(80, 95), 1)

	local origin = self:WorldSpaceCenter()
	local ed = EffectData()
	ed:SetOrigin(origin)
	ed:SetScale(3)
	util.Effect("Explosion", ed, true, true)
	util.Effect("cball_explode", ed, true, true)

	for _, mdl in ipairs(GIB_MODELS) do
		local gib = ents.Create("prop_physics")
		if IsValid(gib) then
			gib:SetModel(mdl)
			gib:SetPos(origin + VectorRand() * 8 + Vector(0, 0, 12))
			gib:SetAngles(AngleRand())
			gib:Spawn()
			gib:SetCollisionGroup(COLLISION_GROUP_DEBRIS)
			local phys = gib:GetPhysicsObject()
			if IsValid(phys) then
				phys:SetVelocity(VectorRand() * math.Rand(80, 160) + Vector(0, 0, math.Rand(60, 140)))
				phys:AddAngleVelocity(VectorRand() * 200)
			end
			SafeRemoveEntityDelayed(gib, math.Rand(8, 14))
		end
	end

	hook.Run("OnNPCKilled", self, IsValid(killer) and killer or dmginfo:GetAttacker(), dmginfo:GetInflictor())
	SafeRemoveEntity(self)
end

function ENT:OnRemove()
	if CLIENT and self._emitter then
		self._emitter:Finish()
		self._emitter = nil
	end
end

-- ── Think (client visuals only — nextbot calls this automatically) ────────────

local DRAW_DISTANCE = 2000 * 2000

function ENT:Think()
	if CLIENT and EyePos():DistToSqr(self:GetPos()) <= DRAW_DISTANCE then
		if not self._emitter then
			self._emitter = ParticleEmitter(self:GetPos())
		else
			self._emitter:SetPos(self:GetPos())
		end

		if CurTime() >= self._nextSmoke and self._emitter then
			self._nextSmoke = CurTime() + 0.03
			local worldPos = self:GetPos()
			for i = 1, 4 do
				local spawnPos = worldPos + Vector(
					math.Rand(-10, 10),
					math.Rand(-10, 10),
					math.Rand(28, 48) -- waist height in world Z
				)
				local p = self._emitter:Add(self._smokeTex, spawnPos)
				if p then
					p:SetVelocity(Vector(math.Rand(-6, 6), math.Rand(-6, 6), -38))
					p:SetDieTime(math.Rand(0.35, 0.65))
					p:SetStartAlpha(160)
					p:SetEndAlpha(0)
					p:SetStartSize(math.Rand(20, 30))
					p:SetEndSize(math.Rand(8, 16)) -- shrink as they fall (not grow)
					p:SetRoll(math.Rand(0, 360))
					p:SetRollDelta(math.Rand(-1, 1))
					p:SetAirResistance(0)
					p:SetGravity(Vector(0, 0, -400))
					p:SetLighting(false)
					p:SetColor(SMOKE_COLOR.r, SMOKE_COLOR.g, SMOKE_COLOR.b)
				end
			end
		end
	end
end

-- ── Draw ──────────────────────────────────────────────────────────────────────

if CLIENT then
	local matBeam = Material("effects/laser1")

	function ENT:Draw()
		for _, id in ipairs(self._legBoneIds or {}) do
			self:ManipulateBoneScale(id, Vector(0, 0, 0))
		end

		self:DrawModel()

		if EyePos():DistToSqr(self:GetPos()) > DRAW_DISTANCE then return end

		-- Glowing purple eyes
		local headId = self._headBone
		if headId then
			local m = self:GetBoneMatrix(headId)
			if m then
				local pos = m:GetTranslation()
				local ang = m:GetAngles()
				local fwd, right, up = ang:Forward(), ang:Right(), ang:Up()
				render.SetMaterial(self._matGlow)
				render.DrawSprite(pos + fwd * 4.5 + up * 1.5 + right * 3.5, EYE_SIZE, EYE_SIZE, EYE_COLOR)
				render.DrawSprite(pos + fwd * 4.5 - up * 1.5 + right * 3.5, EYE_SIZE, EYE_SIZE, EYE_COLOR)
			end
		end

		-- Pulsing arcane orb in the chest
		local spineId = self._spineBone
		if spineId then
			local m = self:GetBoneMatrix(spineId)
			if m then
				local orbPos = m:GetTranslation()
				local pulse  = 0.7 + math.sin(CurTime() * 4.2) * 0.3
				local sz     = 14 * pulse
				render.SetMaterial(self._matGlow)
				render.DrawSprite(orbPos, sz * 2.8, sz * 2.8, Color(ORB_COLOR.r, ORB_COLOR.g, ORB_COLOR.b, 140))
				render.DrawSprite(orbPos, sz,       sz,       Color(255, 220, 255, 210))

				local dlt = DynamicLight(self:EntIndex())
				if dlt then
					dlt.pos        = orbPos
					dlt.r          = 160
					dlt.g          = 60
					dlt.b          = 255
					dlt.brightness = 1.5 * pulse
					dlt.Decay      = 1200
					dlt.Size       = 150
					dlt.DieTime    = CurTime() + 0.1
				end
			end
		end

		-- Electricity arcs between upper-body bones while casting
		if self:GetNWBool("Casting") then
			local boneIds = self._arcBoneIds
			if boneIds and #boneIds >= 2 then
				local positions = {}
				for _, id in ipairs(boneIds) do
					local bm = self:GetBoneMatrix(id)
					if bm then positions[#positions + 1] = bm:GetTranslation() end
				end

				if #positions >= 2 then
					render.SetMaterial(matBeam)
					for i = 1, 3 do
						local posA = positions[math.random(#positions)]
						local posB = positions[math.random(#positions)]
						if posA ~= posB then
							local segs = 6
							render.StartBeam(segs + 1)
							for s = 0, segs do
								local t   = s / segs
								local p   = LerpVector(t, posA, posB)
								p = p + VectorRand() * math.sin(t * math.pi) * 5
								render.AddBeam(p,
									Lerp(math.sin(t * math.pi), 1, 3),
									t,
									Color(ARC_COLOR.r, ARC_COLOR.g, ARC_COLOR.b, math.random(120, 210))
								)
							end
							render.EndBeam()
						end
					end
				end
			end
		end
	end

	-- ── Purple lightning rendering ────────────────────────────────────────────

	local BOLT_INNER = Color(220, 120, 255) -- bright violet core
	local BOLT_OUTER = Color(120, 40, 200)  -- deep purple glow
	local CHAIN_COL  = Color(180, 80, 255)
	local matGlow    = Material("sprites/light_glow02_add")
	local matBeamGlobal = Material("effects/laser1")

	net.Receive("Arcana_LichStrike", function()
		local pos   = net.ReadVector()
		local power = net.ReadFloat()

		-- Impact particles
		local emitter = ParticleEmitter(pos)
		if emitter then
			for i = 1, 30 * power do
				local p = emitter:Add("effects/blueflare1", pos)
				if p then
					p:SetDieTime(math.Rand(0.3, 0.6))
					p:SetStartAlpha(255)
					p:SetEndAlpha(0)
					p:SetStartSize(math.Rand(10, 18) * power)
					p:SetEndSize(0)
					p:SetColor(160, 60, 255)
					p:SetVelocity(VectorRand() * 280 * power)
					p:SetAirResistance(100)
					p:SetGravity(Vector(0, 0, -100))
				end
			end
			emitter:Finish()
		end

		-- Purple flash dynamic light
		local dlt = DynamicLight(math.random(30000, 39999))
		if dlt then
			dlt.pos        = pos
			dlt.r          = 160; dlt.g = 60; dlt.b = 255
			dlt.brightness = 7 * power
			dlt.Decay      = 4000
			dlt.Size       = 500 * power
			dlt.DieTime    = CurTime() + 0.2
		end

		table.insert(Arcana.LichFlashes, { pos = pos, dieTime = CurTime() + 0.12, startTime = CurTime(), power = power })
		table.insert(Arcana.LichBolts,   { startPos = pos + Vector(0, 0, 2000), endPos = pos, dieTime = CurTime() + 0.35, startTime = CurTime(), power = power })
	end)

	net.Receive("Arcana_LichChain", function()
		local sPos = net.ReadVector()
		local ePos = net.ReadVector()
		table.insert(Arcana.LichChains, { startPos = sPos, endPos = ePos, dieTime = CurTime() + 0.25, startTime = CurTime() })
	end)

	hook.Add("PostDrawTranslucentRenderables", "Arcana_RenderLichLightning", function(_, isSkybox)
		if isSkybox then return end
		local now = CurTime()

		-- Flashes
		for i = #Arcana.LichFlashes, 1, -1 do
			local f = Arcana.LichFlashes[i]
			if now > f.dieTime then
				table.remove(Arcana.LichFlashes, i)
			else
				local frac  = math.Clamp((now - f.startTime) / 0.12, 0, 1)
				local alpha = (1 - frac) * 255
				local size  = Lerp(frac, 700, 1100) * f.power
				render.SetMaterial(matGlow)
				render.DrawSprite(f.pos, size,       size,       Color(160, 60, 255,  alpha * 0.8))
				render.DrawSprite(f.pos, size * 0.5, size * 0.5, Color(220, 140, 255, alpha))
			end
		end

		-- Main bolts
		for i = #Arcana.LichBolts, 1, -1 do
			local bolt = Arcana.LichBolts[i]
			if now > bolt.dieTime then
				table.remove(Arcana.LichBolts, i)
			else
				local frac    = 1 - math.Clamp((bolt.dieTime - now) / 0.35, 0, 1)
				local flicker = math.sin(now * 80 + bolt.startTime * 100) * 0.3 + 0.7
				local alpha   = (1 - frac) * 255 * flicker

				local segs = 18
				local path = {}
				for s = 0, segs do
					local t = s / segs
					local p = LerpVector(t, bolt.startPos, bolt.endPos)
					p = p + VectorRand() * math.sin(t * math.pi) * 55 * bolt.power
					path[s] = p
				end

				render.SetMaterial(matBeamGlobal)

				-- Bright violet core
				render.StartBeam(segs + 1)
				for s = 0, segs do
					render.AddBeam(path[s], Lerp(s / segs, 16, 24) * bolt.power * flicker, s / segs, Color(BOLT_INNER.r, BOLT_INNER.g, BOLT_INNER.b, alpha))
				end
				render.EndBeam()

				-- Deep purple outer glow
				render.StartBeam(segs + 1)
				for s = 0, segs do
					render.AddBeam(path[s], Lerp(s / segs, 40, 65) * bolt.power * flicker, s / segs, Color(BOLT_OUTER.r, BOLT_OUTER.g, BOLT_OUTER.b, alpha * 0.55))
				end
				render.EndBeam()
			end
		end

		-- Chain arcs
		for i = #Arcana.LichChains, 1, -1 do
			local chain = Arcana.LichChains[i]
			if now > chain.dieTime then
				table.remove(Arcana.LichChains, i)
			else
				local frac    = 1 - math.Clamp((chain.dieTime - now) / 0.25, 0, 1)
				local flicker = math.sin(now * 60 + chain.startTime * 80) * 0.3 + 0.7
				local alpha   = (1 - frac) * 255 * flicker
				local segs    = 8
				render.SetMaterial(matBeamGlobal)
				render.StartBeam(segs + 1)
				for s = 0, segs do
					local t = s / segs
					local p = LerpVector(t, chain.startPos, chain.endPos)
					p = p + VectorRand() * math.sin(t * math.pi) * 20
					render.AddBeam(p, 12 * flicker, t, Color(CHAIN_COL.r, CHAIN_COL.g, CHAIN_COL.b, alpha))
				end
				render.EndBeam()
			end
		end
	end)

	-- Magic circle: purple, follows the lich for the cast duration
	net.Receive("Arcana_LichCastStart", function()
		local lich     = net.ReadEntity()
		local castTime = net.ReadFloat()
		if not IsValid(lich) then return end
		if not (Arcana.Circle and Arcana.Circle.MagicCircle) then return end

		local fwd = lich:GetForward()
		local ang = fwd:Angle()
		ang:RotateAroundAxis(ang:Right(), 90)

		local seed   = tonumber(util.CRC("arcana_lich"))
		local circle = Arcana.Circle.MagicCircle.CreateMagicCircle(
			lich:WorldSpaceCenter() + fwd * 30, ang,
			Color(160, 60, 255, 255), 4, 38, castTime, 2, seed
		)
		if not circle then return end

		if circle.StartEvolving then circle:StartEvolving(castTime, nil) end

		local hookId = "Arcana_LichCircle_" .. lich:EntIndex()
		hook.Add("PostDrawOpaqueRenderables", hookId, function()
			if not IsValid(lich) or not circle.IsActive or not circle:IsActive() then
				hook.Remove("PostDrawOpaqueRenderables", hookId)
				return
			end
			local newFwd = lich:GetForward()
			local newAng = newFwd:Angle()
			newAng:RotateAroundAxis(newAng:Right(), 90)
			circle.position = lich:WorldSpaceCenter() + newFwd * 30
			circle.angles   = newAng
		end)
	end)
end
