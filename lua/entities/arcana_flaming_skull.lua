AddCSLuaFile()

ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "Flaming Skull"
ENT.Category = "Arcana"
ENT.Spawnable = false
ENT.AdminOnly = false
ENT.RenderGroup = RENDERGROUP_BOTH
ENT.PhysgunDisabled = true

local SKULL_MODEL = "models/Gibs/HGIBS.mdl"

-- Visuals (client) - Purple theme like the skeleton
local EYE_COLOR = Color(160, 60, 255, 255)
local FLAME_COLOR = Color(110, 40, 200, 220)
local SMOKE_COLOR = Color(80, 40, 140, 180)
local EYE_SIZE = 30

if CLIENT then
	local matGlow = Material("sprites/light_glow02_add")
	local flameTex = "effects/fire_cloud1"
	local smokeTex = "particle/particle_smokegrenade"

	-- Cache materials in upvalues
	ENT._matGlow = matGlow
	ENT._flameTex = flameTex
	ENT._smokeTex = smokeTex
end

if SERVER then
	resource.AddFile("sound/arcana/skeleton/death.ogg")
end

-- Tuning
local CHASE_RANGE = 2500
local FIRE_RANGE = 1800
local FIRE_COOLDOWN = 4
local FIRE_INTERVAL = 2.0
local PROJECTILE_SPEED = 580
local HOVER_HEIGHT = 180
local MOVE_SPEED = 140
local TURN_RATE = 360 -- deg/sec (faster turn rate for always looking at target)
local XP_REWARD = 45
local STANDOFF_DISTANCE = 400 -- prefer to keep this far from target

function ENT:Initialize()
	if SERVER then
		self:SetModel(SKULL_MODEL)
		self:SetModelScale(3, 0)
		self:SetMoveType(MOVETYPE_FLY)
		self:SetSolid(SOLID_BBOX)
		self:PhysicsInit(SOLID_BBOX)
		self:SetCollisionBounds(Vector(-18, -18, -18), Vector(18, 18, 18))
		self:SetCollisionGroup(COLLISION_GROUP_DEBRIS)
		self:DrawShadow(true)

		self:SetHealth(80)
		self:SetMaxHealth(80)
		self:Activate()

		local phys = self:GetPhysicsObject()
		if IsValid(phys) then
			phys:SetMass(0.2)
			phys:EnableGravity(false)
			phys:Wake()
		end

		self._lastThink = CurTime()
		self._nextFireball = 0
		self._lastTargetScan = 0
	else
		-- client visuals
		self._nextFlame = 0
		self._nextSmoke = 0
		self._emitter = ParticleEmitter(self:GetPos())
	end
end

-- Simple Sandbox spawn helper
function ENT:SpawnFunction(ply, tr, classname)
	if not tr or not tr.Hit then return end
	local pos = tr.HitPos + tr.HitNormal * 2
	local ent = ents.Create(classname or "arcana_flaming_skull")
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

function ENT:_PickTarget()
	local now = CurTime()
	if now < (self._lastTargetScan or 0) then return end
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
end

function ENT:_Chase(dt)
	local myPos = self:GetPos()

	-- Idle hover when no target
	if not IsValid(self._target) then
		local tr = util.TraceLine({
			start = myPos + Vector(0, 0, 200),
			endpos = myPos + Vector(0, 0, -10000),
			filter = self
		})
		local desired = Vector(myPos)
		desired.z = (tr.HitPos.z or myPos.z) + HOVER_HEIGHT
		local dz = desired.z - myPos.z
		local vz = math.Clamp(dz, -1, 1) * (MOVE_SPEED * 0.5)
		self:SetPos(myPos + Vector(0, 0, vz * dt))
		return
	end

	-- Chase/combat behavior
	local targetPos = self._target:WorldSpaceCenter()
	local trGround = util.TraceLine({
		start = targetPos + Vector(0, 0, 600),
		endpos = targetPos + Vector(0, 0, -10000),
		filter = self
	})
	local desiredZ = (trGround.HitPos.z or targetPos.z) + HOVER_HEIGHT

	local toTarget = targetPos - myPos
	local horiz = Vector(toTarget.x, toTarget.y, 0)
	local distH = horiz:Length()
	local move = Vector(0, 0, 0)
	local speed = MOVE_SPEED

	if distH > 1 then horiz:Mul(1 / distH) end

	-- Horizontal control: maintain standoff distance
	if distH < (STANDOFF_DISTANCE - 50) then
		move = move - horiz * speed -- move away
	elseif distH > (FIRE_RANGE - 100) then
		move = move + horiz * (speed * 0.8) -- approach
	else
		-- Strafe around target
		local right = horiz:Cross(Vector(0, 0, 1))
		local strafeDir = math.sin(CurTime() * 0.6) > 0 and right or -right
		move = move + strafeDir * (speed * 0.4)
	end

	-- Vertical control
	local dz = desiredZ - myPos.z
	if math.abs(dz) > 6 then
		move = move + Vector(0, 0, math.Clamp(dz, -1, 1) * speed)
	end

	-- Apply movement
	local mvLen = move:Length()
	if mvLen > 0 then
		move:Mul(1 / mvLen)
		self:SetPos(myPos + move * speed * dt)
	end

	-- Face towards the target
	local face = (self._target:WorldSpaceCenter() - self:WorldSpaceCenter()):GetNormalized()
	self:SetAngles(face:Angle())
end

function ENT:_FireAtTarget()
	if not IsValid(self._target) then return end

	local myPos = self:WorldSpaceCenter()
	local targetPos = self._target:WorldSpaceCenter()
	local dir = (targetPos - myPos):GetNormalized()

	-- Create purple fireball
	local fireball = ents.Create("arcana_fireball_purple")
	if not IsValid(fireball) then return end

	fireball:SetPos(myPos + dir * 20)
	fireball:SetAngles(dir:Angle())
	fireball:SetOwner(self)
	fireball:SetSpellOwner(self)
	fireball:Spawn()
	fireball:Activate()

	-- Set velocity
	local phys = fireball:GetPhysicsObject()
	if IsValid(phys) then
		phys:SetVelocity(dir * PROJECTILE_SPEED)
	end

	self:EmitSound("ambient/fire/gascan_ignite1.wav", 70, math.random(90, 110), 0.8)
end

function ENT:OnTakeDamage(dmginfo)
	local cur = self:Health()
	local new = math.max(0, cur - (dmginfo:GetDamage() or 0))
	self:SetHealth(new)

	-- Track last player who hurt the skull
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

	self:EmitSound("physics/wood/wood_strain" .. math.random(1, 8) .. ".wav", 65, math.random(120, 140), 1)

	if new <= 0 and not self._arcanaDead then
		self._arcanaDead = true

		local killer = atk
		if not (IsValid(killer) and killer:IsPlayer()) then
			killer = self._lastHurtBy
		end

		if IsValid(killer) and killer:IsPlayer() and Arcane and Arcane.GiveXP then
			Arcane:GiveXP(killer, XP_REWARD, "Flaming Skull defeated")
		end

		-- Fire explosion effect
		local ed = EffectData()
		ed:SetOrigin(self:GetPos())
		ed:SetScale(2)
		util.Effect("Explosion", ed, true, true)

		hook.Run("OnNPCKilled", self, IsValid(killer) and killer or atk, dmginfo:GetInflictor())
		SafeRemoveEntityDelayed(self, 0.1)
	end
end

function ENT:OnRemove()
	if CLIENT then
		if self._emitter then
			self._emitter:Finish()
			self._emitter = nil
		end
	end
end

local DRAW_DISTANCE = 1800 * 1800
function ENT:Think()
	if SERVER then
		local now = CurTime()
		local dt = math.Clamp(now - (self._lastThink or now), 0, 0.2)
		self._lastThink = now

		self:_PickTarget()
		self:_Chase(dt)

		if now >= (self._nextFireball or 0) and IsValid(self._target) then
			self:_FireAtTarget()
			self._nextFireball = now + FIRE_COOLDOWN
		end

		self:NextThink(now + 0.03)
		return true
	end

	if CLIENT and EyePos():DistToSqr(self:GetPos()) <= DRAW_DISTANCE then
		-- Update emitter position
		if not self._emitter then
			self._emitter = ParticleEmitter(self:GetPos())
		else
			self._emitter:SetPos(self:GetPos())
		end

		-- Emit flames
		if CurTime() >= (self._nextFlame or 0) and self._emitter then
			self._nextFlame = CurTime() + 0.02
			for i = 1, 3 do
				local offset = VectorRand() * 8
				local wp = self:GetPos() + offset
				local p = self._emitter:Add(self._flameTex, wp)
				if p then
					p:SetVelocity(VectorRand() * 15 + Vector(0, 0, 30))
					p:SetDieTime(math.Rand(0.3, 0.6))
					p:SetStartAlpha(200)
					p:SetEndAlpha(0)
					p:SetStartSize(math.Rand(10, 16))
					p:SetEndSize(math.Rand(2, 6))
					p:SetRoll(math.Rand(0, 360))
					p:SetRollDelta(math.Rand(-2, 2))
					p:SetAirResistance(40)
					p:SetGravity(Vector(0, 0, 40))
					p:SetColor(FLAME_COLOR.r, FLAME_COLOR.g, FLAME_COLOR.b)
					p:SetLighting(false)
				end
			end
		end

		-- Emit smoke
		if CurTime() >= (self._nextSmoke or 0) and self._emitter then
			self._nextSmoke = CurTime() + 0.04
			local offset = VectorRand() * 6
			local wp = self:GetPos() + offset + Vector(0, 0, 12)
			local p = self._emitter:Add(self._smokeTex, wp)
			if p then
				p:SetVelocity(VectorRand() * 8 + Vector(0, 0, 35))
				p:SetDieTime(math.Rand(0.8, 1.4))
				p:SetStartAlpha(100)
				p:SetEndAlpha(0)
				p:SetStartSize(math.Rand(8, 12))
				p:SetEndSize(math.Rand(24, 36))
				p:SetRoll(math.Rand(0, 360))
				p:SetRollDelta(math.Rand(-1, 1))
				p:SetAirResistance(50)
				p:SetGravity(Vector(0, 0, 20))
				p:SetColor(SMOKE_COLOR.r, SMOKE_COLOR.g, SMOKE_COLOR.b)
			end
		end
	end

	self:NextThink(CurTime())
	return true
end

if CLIENT then
	-- Draw glowing eyes and flame effects
	function ENT:Draw()
		self:DrawModel()

		if EyePos():DistToSqr(self:GetPos()) > DRAW_DISTANCE then return end

		local pos = self:GetPos()
		local ang = self:GetAngles()
		local forward = ang:Forward()
		local right = ang:Right()
		local up = ang:Up()

		-- Position eyes on the skull
		local eyeLeft = pos + forward * 6 + right * 4 + up * 2
		local eyeRight = pos + forward * 6 - right * 4 + up * 2

		render.SetMaterial(self._matGlow)
		render.DrawSprite(eyeLeft, EYE_SIZE, EYE_SIZE, EYE_COLOR)
		render.DrawSprite(eyeRight, EYE_SIZE, EYE_SIZE, EYE_COLOR)

		-- Add a central purple flame glow
		local glowSize = 50 + math.sin(CurTime() * 4) * 10
		render.DrawSprite(pos, glowSize, glowSize, Color(140, 60, 220, 150))

		-- Dynamic light (purple)
		local d = DynamicLight(self:EntIndex())
		if d then
			d.pos = pos
			d.r = 160
			d.g = 60
			d.b = 255
			d.brightness = 2
			d.Decay = 800
			d.Size = 220
			d.DieTime = CurTime() + 0.1
		end
	end
end

