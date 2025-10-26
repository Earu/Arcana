AddCSLuaFile()

ENT.Type = "nextbot"
ENT.Base = "base_nextbot"
ENT.PrintName = "Skeleton"
ENT.Category = "Arcana"
ENT.Spawnable = false
ENT.AdminOnly = false

local SKELETON_MODEL = "models/player/skeleton.mdl"
local SWORD_MODEL = "models/weapons/c_models/c_scout_sword/c_scout_sword.mdl"
local SWORD_MATERIAL = "models/props_c17/metalladder002"
local SWORD_BONE = "ValveBiped.Bip01_R_Hand"
local SWORD_POS_OFFSET = Vector(4, 0, 5)
local SWORD_ANG_OFFSET = Angle(0, 0, -180)
local SWORD_REFRESH_INTERVAL = 1.0

-- Visuals (client)
local EYE_COLOR = Color(160, 60, 255, 255)
local SMOKE_COLOR = Color(110, 40, 200, 220)
local EYE_SIZE = 6

if CLIENT then
	local matGlow = Material("sprites/light_glow02_add")
	local smokeTex = "particle/particle_smokegrenade"

	-- Cache materials in upvalues
	ENT._matGlow = matGlow
	ENT._smokeTex = smokeTex
end

if SERVER then
	resource.AddFile("sound/arcana/skeleton/death.ogg")
	resource.AddFile(SWORD_MODEL)
end

-- Death gib models (server)
local GIB_MODELS = {
	"models/Gibs/HGIBS.mdl",       -- skull
	"models/Gibs/HGIBS_rib.mdl",
	"models/Gibs/HGIBS_scapula.mdl",
	"models/Gibs/HGIBS_spine.mdl"
}

-- Tuning
local CHASE_RANGE = 2000
local MELEE_RANGE = 50
local MELEE_COOLDOWN = 0.9
local MELEE_DAMAGE = 20
local MOVE_SPEED = 220
local TURN_RATE = 420 -- deg/sec
local XP_REWARD = 35
local FOOTSTEP_MIN_SPEED = 90

function ENT:Initialize()
	if SERVER then
		self:SetModel(SKELETON_MODEL)
		self:SetBloodColor(DONT_BLEED) -- skeleton doesn't bleed
		if self.loco then
			self.loco:SetAcceleration(1200)
			self.loco:SetDeceleration(1400)
			self.loco:SetDesiredSpeed(MOVE_SPEED)
			self.loco:SetStepHeight(22)
			self.loco:SetJumpHeight(0)
		end

		-- Ensure a sensible human hull/collision so nav works and it doesn't float
		self:SetSolid(SOLID_BBOX)
		-- Explicit collision bounds so VPhysics objects and vehicles collide properly
		self:SetCollisionBounds(Vector(-13, -13, 0), Vector(13, 13, 72))
		self:SetHealth(120)
		self:SetMaxHealth(120)
		self:SetCollisionGroup(COLLISION_GROUP_NPC)
		self:DrawShadow(true)

		-- cache activities and sequence fallbacks for this player model
		self._actIdle = self:SelectWeightedSequence(ACT_IDLE) ~= -1 and ACT_IDLE or (self:SelectWeightedSequence(ACT_IDLE_RELAXED) ~= -1 and ACT_IDLE_RELAXED or ACT_IDLE_AGITATED)
		self._actWalk = self:SelectWeightedSequence(ACT_WALK) ~= -1 and ACT_WALK or (self:SelectWeightedSequence(ACT_RUN) ~= -1 and ACT_RUN or ACT_IDLE)
		self._actMelee = (self:SelectWeightedSequence(ACT_MELEE_ATTACK1) ~= -1) and ACT_MELEE_ATTACK1 or (self:SelectWeightedSequence(ACT_GMOD_GESTURE_RANGE_ZOMBIE) ~= -1 and ACT_GMOD_GESTURE_RANGE_ZOMBIE or nil)

		-- Prefer HL2MP melee2 holdtype activities if model supports them
		local function hasAct(act)
			return self:SelectWeightedSequence(act) ~= -1
		end
		self._hl_idle  = hasAct(ACT_HL2MP_IDLE_MELEE2) and ACT_HL2MP_IDLE_MELEE2 or nil
		self._hl_walk  = hasAct(ACT_HL2MP_WALK_MELEE2) and ACT_HL2MP_WALK_MELEE2 or nil
		self._hl_run   = hasAct(ACT_HL2MP_RUN_MELEE2) and ACT_HL2MP_RUN_MELEE2 or nil
		self._hl_attack = hasAct(ACT_HL2MP_GESTURE_RANGE_ATTACK_MELEE2) and ACT_HL2MP_GESTURE_RANGE_ATTACK_MELEE2 or nil

		-- Equip a sword model and attach it to the right hand
		self:EquipSword()

		self:SetAnimState("idle")

		self._nextSwing = 0
		self._lastTargetScan = 0
	else
		-- client visuals
		self._nextSmoke = 0
		self._emitter = ParticleEmitter(self:GetPos())
		-- cache common bone ids for cheaper lookups during rendering
		self._headBone = self:LookupBone("ValveBiped.Bip01_Head1") or self:LookupBone("ValveBiped.Bip01_Neck1")
		self._spineBone = self:LookupBone("ValveBiped.Bip01_Spine2")
		self._pelvisBone = self:LookupBone("ValveBiped.Bip01_Pelvis")
	end
end

-- Creates and parents a visual sword to the skeleton's right hand
function ENT:EquipSword()
	if not SERVER then return end
	if IsValid(self._sword) then self._sword:Remove() end

	local sword = ents.Create("prop_dynamic")
	if not IsValid(sword) then return end
	sword:SetModel(SWORD_MODEL)
	sword:SetMaterial(SWORD_MATERIAL)
	sword:SetModelScale(1, 0)
	sword:SetMoveType(MOVETYPE_NONE)
	sword:SetSolid(SOLID_NONE)
	sword:SetCollisionGroup(COLLISION_GROUP_IN_VEHICLE)
	sword:SetOwner(self)
	sword:Spawn()
	sword:SetParent(self)
	sword:AddEffects(EF_PARENT_ANIMATES)
	sword:SetKeyValue("classname", "Rusted Sword")

	local boneId = self:LookupBone(SWORD_BONE) or 0
	if boneId and boneId > 0 then
		sword:FollowBone(self, boneId)
	else
		-- Fallback to bonemerge if the hand bone isn't found
		sword:AddEffects(EF_BONEMERGE)
	end

	sword:SetLocalPos(SWORD_POS_OFFSET)
	sword:SetLocalAngles(SWORD_ANG_OFFSET)

	self._sword = sword
	self._nextSwordRefresh = CurTime() + SWORD_REFRESH_INTERVAL
end

-- Helper to drive animations for models that lack standard activities
function ENT:SetAnimState(state)
	self._animState = state
	if state == "walk" then
		if self._hl_run or self._hl_walk then
			self:StartActivity(self._hl_run or self._hl_walk)
		else
			local seq = (self._seqRun and self._seqRun >= 0) and self._seqRun or ((self._seqWalk and self._seqWalk >= 0) and self._seqWalk or -1)
			if seq and seq >= 0 then
				self:ResetSequence(seq)
				self:SetCycle(0)
				self:SetPlaybackRate(1)
			elseif self._actWalk and self:SelectWeightedSequence(self._actWalk) ~= -1 then
				self:StartActivity(self._actWalk)
			end
		end
	else -- idle
		if self._hl_idle then
			self:StartActivity(self._hl_idle)
		else
			local seq = (self._seqIdle and self._seqIdle >= 0) and self._seqIdle or -1
			if seq and seq >= 0 then
				self:ResetSequence(seq)
				self:SetCycle(0)
				self:SetPlaybackRate(1)
			elseif self._actIdle and self:SelectWeightedSequence(self._actIdle) ~= -1 then
				self:StartActivity(self._actIdle)
			end
		end
	end
end

-- Fallback Wait helper (base_nextbot usually provides this, but guard just in case)
function ENT:Wait(seconds)
	local untilTime = CurTime() + (tonumber(seconds) or 0)
	repeat
		self:BodyUpdate()
		coroutine.yield()
	until CurTime() >= untilTime
end

-- Advance animations each tick while in behaviours
function ENT:BodyUpdate()
	if self._animState == "walk" then
		self:BodyMoveXY()
		local speed = self:GetVelocity():Length2D()
		local desired = (self.loco and self.loco.GetDesiredSpeed and self.loco:GetDesiredSpeed()) or MOVE_SPEED
		local rate = desired > 1 and math.Clamp(speed / desired, 0, 2) or 1
		self:SetPlaybackRate(rate)
	else
		self:FrameAdvance()
		self:SetPlaybackRate(1)
	end
end

-- Emits footstep sounds based on current ground speed
function ENT:UpdateFootsteps(currentSpeed)
	if not self.loco or not self.loco:IsOnGround() then return end
	if (currentSpeed or 0) < FOOTSTEP_MIN_SPEED then return end

	local now = CurTime()
	local stepInterval = math.Clamp(260 / math.max(currentSpeed, 1), 0.22, 0.45)
	if now < (self._nextStep or 0) then return end

	self._nextStep = now + stepInterval / 2 -- two legs are walking, so we divide by 2
	self:EmitSound("physics/wood/wood_furniture_impact_soft" .. math.random(1, 3) .. ".wav", 60, math.random(95, 105), 1)
end

-- Simple Sandbox spawn helper
function ENT:SpawnFunction(ply, tr, classname)
	if not tr or not tr.Hit then return end
	local pos = tr.HitPos + tr.HitNormal * 2
	local ent = ents.Create(classname or "arcana_skeleton")
	if not IsValid(ent) then return end
	ent:SetPos(pos)
	ent:SetAngles(Angle(0, ply:EyeAngles().y, 0))
	ent:Spawn()
	ent:Activate()
	return ent
end

local function IsEnemy(ply)
	return IsValid(ply) and ply:IsPlayer() and ply:Alive()
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
			if d2 < bestD2 then
				bestD2 = d2
				nearest = ply
			end
		end
	end
	self._target = nearest
	return self._target
end

function ENT:RunBehaviour()
	self:SetAnimState("walk")
	while true do
		local tgt = self:AcquireTarget()
		if IsValid(tgt) then
			self:ChaseTarget(tgt)
		else
			-- idle wander a bit
			self:SetAnimState("idle")
			self:Wait(math.Rand(0.4, 0.8))
		end
		coroutine.yield()
	end
end

function ENT:ChaseTarget(tgt)
	if self.loco then self.loco:SetDesiredSpeed(MOVE_SPEED) end
	self:SetAnimState("walk")
	local lastRepath = 0
	while IsValid(tgt) and tgt:Alive() do
		if self.loco:IsStuck() then self:HandleStuck() end

		local myPos = self:GetPos()
		local to = tgt:WorldSpaceCenter()
		local d = to:Distance(myPos)

		self:FaceTowards(to)
		if self.loco then
			self.loco:FaceTowards(to)
			if d > MELEE_RANGE then
				self.loco:Approach(to, 1)

				-- Footstep cadence while moving on ground
				self:UpdateFootsteps(self.loco:GetVelocity():Length2D())
			end
		end

		if d <= MELEE_RANGE * 2 then
			self:TryMelee(tgt)
			self:Wait(0.05)
		else
			if lastRepath <= CurTime() then
				self:MoveToPos(to, {repath = 0.5, tolerance = MELEE_RANGE * 2})
				lastRepath = CurTime() + 0.5
			end
		end

		if d > CHASE_RANGE then break end
		coroutine.yield()
	end
	self:SetAnimState("idle")
end

function ENT:FaceTowards(pos)
	local ang = (pos - self:GetPos()):Angle()
	ang.p = 0; ang.r = 0
	local cur = self:GetAngles()
	local diff = math.AngleDifference(ang.y, cur.y)
	local step = math.Clamp(diff, -FrameTime() * TURN_RATE, FrameTime() * TURN_RATE)
	self:SetAngles(Angle(0, cur.y + step, 0))
end

function ENT:TryMelee(target)
	local now = CurTime()
	if now < (self._nextSwing or 0) then return end
	self._nextSwing = now + MELEE_COOLDOWN

	if self._hl_attack then
		self:RestartGesture(self._hl_attack)
	elseif self._actMelee then
		self:RestartGesture(self._actMelee)
	end

	self:EmitSound("weapons/iceaxe/iceaxe_swing1.wav", 70, math.random(95,105), 0.7)

	timer.Simple(0.15, function()
		if not IsValid(self) then return end
		local center = IsValid(self._sword) and self._sword:WorldSpaceCenter() or (self:WorldSpaceCenter() + self:GetForward() * 40)
		local hullMins = Vector(-64, -64, -64)
		local hullMaxs = Vector(64, 64, 64)
		for _, ent in ipairs(ents.FindInBox(center + hullMins, center + hullMaxs)) do
			if IsValid(ent) and ent:IsPlayer() and ent:Alive() then
				local startPos = IsValid(self._sword) and (self._sword:GetPos() + self:GetForward() * 6) or self:EyePos()
				local tr = util.TraceLine({
					start = startPos,
					endpos = ent:EyePos(),
					filter = {self, self._sword}
				})

				if tr.Fraction >= 0.8 or tr.Entity == ent then
					local dmg = DamageInfo()
					dmg:SetDamage(MELEE_DAMAGE)
					dmg:SetDamageType(DMG_SLASH)
					dmg:SetAttacker(self)
					dmg:SetInflictor(IsValid(self._sword) and self._sword or self)
					local takeDamageInfo = ent.ForceTakeDamageInfo or ent.TakeDamageInfo
					takeDamageInfo(ent, dmg)

					self:EmitSound("weapons/knife/knife_hit1.wav", 70, math.random(95,105), 0.7)
				end
			end
		end
	end)
end

-- Apply contact damage when hit by physics props or vehicles
function ENT:OnContact(other)
    if not IsValid(other) then return end

    local now = CurTime()
    if now < (self._nextImpactDamage or 0) then return end

    local impactSpeed = 0
    local mass = 0
    local attacker = other
    local inflictor = other

    if other:IsVehicle() then
        impactSpeed = other:GetVelocity():Length()
        mass = 800 -- approximate effective mass for vehicles
        local driver = other:GetDriver()
        if IsValid(driver) then attacker = driver end
    else
		if other:IsPlayer() or other:IsNPC() or other:IsNextBot() then return end

        local phys = other:GetPhysicsObject()
        if IsValid(phys) then
            impactSpeed = (phys:GetVelocity() - self:GetVelocity()):Length()
            mass = phys:GetMass()
        end
    end

    if impactSpeed <= 0 or mass <= 0 then return end

    -- Ignore glancing or slow touches
    if impactSpeed < 140 then return end

    -- Scale damage by momentum with sane clamps
    local damage = math.Clamp((impactSpeed * mass) / 500, 8, 120)

    local dmg = DamageInfo()
    dmg:SetDamage(damage)
    dmg:SetDamageType(other:IsVehicle() and DMG_VEHICLE or DMG_CRUSH)
    dmg:SetAttacker(IsValid(attacker) and attacker or other)
    dmg:SetInflictor(IsValid(inflictor) and inflictor or other)

    self:TakeDamageInfo(dmg)

    -- brief cooldown to prevent multiple rapid applications from the same contact
    self._nextImpactDamage = now + 0.1
end

function ENT:OnTraceAttack(dmg, dir, tr)
end

function ENT:OnInjured(dmginfo)
	local atk = dmginfo:GetAttacker()
	if IsValid(atk) and atk:IsPlayer() then
		self._lastHurtBy = atk
	else
		local inf = dmginfo:GetInflictor()
		local owner = IsValid(inf) and inf.GetOwner and inf:GetOwner() or nil
		if IsValid(owner) and owner:IsPlayer() then
			self._lastHurtBy = owner
		end
	end

	self:EmitSound("physics/wood/wood_strain" .. math.random(1, 8) .. ".wav", 70, math.random(95, 105), 1)
end

function ENT:OnKilled(dmginfo)
	local killer = dmginfo:GetAttacker()
	if not (IsValid(killer) and killer:IsPlayer()) then killer = self._lastHurtBy end
	if IsValid(killer) and killer:IsPlayer() and _G.Arcane and Arcane.GiveXP then
		Arcane:GiveXP(killer, XP_REWARD, "Skeleton defeated")
	end

	local origin = self:WorldSpaceCenter()
	self:EmitSound("arcana/skeleton/death.ogg", 70, math.random(95, 105), 1)

	local ang = self:GetAngles()
	for i, mdl in ipairs(GIB_MODELS) do
		local gib = ents.Create("prop_physics")
		if IsValid(gib) then
			gib:SetModel(mdl)
			gib:SetPos(origin + VectorRand() * 6 + Vector(0, 0, 12))
			gib:SetAngles(AngleRand())
			gib:Spawn()
			gib:SetCollisionGroup(COLLISION_GROUP_DEBRIS)

			local phys = gib:GetPhysicsObject()
			if IsValid(phys) then
				phys:SetVelocity(self:GetVelocity() + ang:Forward() * math.Rand(80, 160) + VectorRand() * math.Rand(60, 120) + Vector(0, 0, math.Rand(60, 140)))
				phys:AddAngleVelocity(VectorRand() * 200)
			end

			SafeRemoveEntityDelayed(gib, math.Rand(8, 14))
		end
	end

	hook.Run("OnNPCKilled", self, IsValid(killer) and killer or dmginfo:GetAttacker(), dmginfo:GetInflictor())
	SafeRemoveEntity(self)
end

function ENT:OnRemove()
	if IsValid(self._sword) then
		self._sword:Remove()
		self._sword = nil
	end

	if CLIENT then
		if self._emitter then
			self._emitter:Finish()
			self._emitter = nil
		end
	end
end

function ENT:Think()
	if SERVER then
		if not IsValid(self._sword) then
			-- In rare cases (e.g. cleanup), recreate the sword
			self:EquipSword()
		else
			-- Periodically reapply FollowBone and offsets to avoid engine desync after gestures
			if CurTime() >= (self._nextSwordRefresh or 0) then
				local boneId = self:LookupBone(SWORD_BONE) or 0
				if boneId and boneId > 0 then
					self._sword:FollowBone(self, boneId)
				end
				self._sword:SetLocalPos(SWORD_POS_OFFSET)
				self._sword:SetLocalAngles(SWORD_ANG_OFFSET)
				self._sword:AddEffects(EF_PARENT_ANIMATES)
				self._nextSwordRefresh = CurTime() + SWORD_REFRESH_INTERVAL
			end
		end
	end

	if CLIENT then
		-- Update emitter position
		if not self._emitter then
			self._emitter = ParticleEmitter(self:GetPos())
		else
			self._emitter:SetPos(self:GetPos())
		end

		-- Emit purple smoke around the body
		if CurTime() >= (self._nextSmoke or 0) and self._emitter then
			self._nextSmoke = CurTime() + 0.03
			local mins, maxs = self:OBBMins(), self:OBBMaxs()
			for i = 1, 2 do
				local lp = Vector(math.Rand(mins.x, maxs.x), math.Rand(mins.y, maxs.y), math.Rand(mins.z, maxs.z))
				local wp = self:LocalToWorld(lp)
				local p = self._emitter:Add(self._smokeTex, wp)
				if p then
					p:SetVelocity(VectorRand() * 12 + Vector(0, 0, 24))
					p:SetDieTime(math.Rand(0.9, 1.6))
					p:SetStartAlpha(70)
					p:SetEndAlpha(0)
					p:SetStartSize(math.Rand(6, 10))
					p:SetEndSize(math.Rand(20, 32))
					p:SetRoll(math.Rand(0, 360))
					p:SetRollDelta(math.Rand(-1, 1))
					p:SetAirResistance(60)
					p:SetGravity(Vector(0, 0, 10))
					p:SetColor(SMOKE_COLOR.r, SMOKE_COLOR.g, SMOKE_COLOR.b)
				end
			end
		end
	end
end

if CLIENT then
	-- Translucent pass for glowing eyes and wisps
	function ENT:Draw()
		self:DrawModel()

		-- Eyes at the head bone based on its local axes
		local headId = self._headBone or self:LookupBone("ValveBiped.Bip01_Head1")
		if headId then
			local m = self:GetBoneMatrix(headId)
			if m then
				local pos = m:GetTranslation()
				local ang = m:GetAngles()
				local right, up, forward = ang:Right(), ang:Up(), ang:Forward()
				local eyeLeft = pos + forward * 4.5 + up * 1.5 + right * 3.5
				local eyeRight = pos + forward * 4.5 - up * 1.5 + right * 3.5

				render.SetMaterial(self._matGlow)
				render.DrawSprite(eyeLeft, EYE_SIZE, EYE_SIZE, EYE_COLOR)
				render.DrawSprite(eyeRight, EYE_SIZE, EYE_SIZE, EYE_COLOR)
			end
		end
	end
end