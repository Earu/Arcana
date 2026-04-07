AddCSLuaFile()
ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "Ward"
ENT.Author = "Earu"
ENT.Category = "Arcana"
ENT.Spawnable = false
ENT.AdminOnly = false
ENT.RenderGroup = RENDERGROUP_TRANSLUCENT
ENT.PhysgunDisabled = true
ENT.ms_notouch = true

local WARD_RADIUS     = 2000
local FLASH_ALPHA     = 220
local FLASH_HOLD      = 0.5
local FLASH_FADE_OUT  = 2.5
local BAND_COLOR      = Color(160, 100, 240)
local PLATE_LIFETIME = 2.0
local PLATE_MODEL    = "models/hunter/plates/plate2x2.mdl"
local PLATE_SCALE    = 6
local PLATE_CIRCLE_SIZE = 80

local function RaySphereIntersect(origin, dir, center, radius)
	local oc = origin - center
	local b  = oc:Dot(dir)
	local c  = oc:Dot(oc) - radius * radius
	local disc = b * b - c
	if disc < 0 then return nil end
	local t = -b - math.sqrt(disc)
	if t < 0 then t = -b + math.sqrt(disc) end
	if t < 0 then return nil end
	return origin + dir * t, t
end

function ENT:SetupDataTables()
	self:NetworkVar("Float", 0, "Radius")
	self:NetworkVar("Float", 1, "HitTime")

	if CLIENT then
		self:NetworkVarNotify("HitTime", function(ent, _, old, new)
			if new <= old then return end
			ent._flashStart = CurTime()
			ent:EmitSound("physics/glass/glass_impact_bullet4.wav", 70, 180, 0.6)
		end)
	end
end

function ENT:UpdateTransmitState()
	return TRANSMIT_ALWAYS
end

if SERVER then
	util.AddNetworkString("Arcana_Ward_Plate")

	function ENT:Initialize()
		self:SetModel("models/props_junk/PopCan01a.mdl")
		self:DrawShadow(false)
		self:SetMoveType(MOVETYPE_NONE)
		self:SetSolid(SOLID_OBB)
		self:SetTrigger(true)
		self:SetNotSolid(true)

		self:SetRadius(WARD_RADIUS)
		self:SetCollisionBounds(
			Vector(-WARD_RADIUS, -WARD_RADIUS, -WARD_RADIUS),
			Vector(WARD_RADIUS,  WARD_RADIUS,  WARD_RADIUS)
		)

		self._allowed   = {}
		self._plates    = {}
		self._lastFlash = 0
		self:_RegisterHooks()
	end

	function ENT:_RegisterHooks()
		local idx     = self:EntIndex()
		local hookKey = "Arcana_Ward_" .. idx

		hook.Add("EntityFireBullets", self, function(_, shooter, data)
			local center = self:GetPos()
			local radius = self:GetRadius()
			local src    = data.Src

			if src:Distance(center) <= radius then return end

			local hitPos = RaySphereIntersect(src, data.Dir, center, radius)
			if not hitPos then return end

			local dist = (hitPos - src):Length()
			if data.Distance and dist > data.Distance then return end

			self:_SpawnPlate(hitPos)
			self:_TriggerFlash()
		end)

		hook.Add("EntityTakeDamage", self, function(_, target, dmginfo)
			if not IsValid(target) then return end

			-- Only protect entities that were inside at activation or owned by allowed players
			if not self._allowed[target:EntIndex()] and not self:_IsOwnerAllowed(target) then return end

			local center = self:GetPos()
			local radius = self:GetRadius()

			-- Target must still be inside the sphere
			if target:GetPos():Distance(center) > radius then return end

			-- Check whether both attacker and inflictor are outside
			local attacker  = dmginfo:GetAttacker()
			local inflictor = dmginfo:GetInflictor()

			local attackerOutside = true
			if IsValid(attacker) and attacker ~= target then
				attackerOutside = attacker:GetPos():Distance(center) > radius
			end

			local inflictorOutside = true
			if IsValid(inflictor) and inflictor ~= target and inflictor ~= attacker then
				inflictorOutside = inflictor:GetPos():Distance(center) > radius
			end

			if attackerOutside and inflictorOutside then
				dmginfo:SetDamage(0)
				self:_TriggerFlash()
			end
		end)

	end

	function ENT:Think()
		self:_CheckCastingPlayers()
		self:NextThink(CurTime() + 0.2)
		return true
	end

	function ENT:_CheckCastingPlayers()
		local center = self:GetPos()
		local radius = self:GetRadius()

		for _, ply in pairs(player.GetAll()) do
			if not IsValid(ply) then continue end
			if self._allowed[ply:EntIndex()] then continue end

			local pdata = Arcana:GetPlayerData(ply)
			if not pdata or not pdata.casting_spell then continue end

			local spellId = pdata.casting_spell
			local spell = Arcana.RegisteredSpells and Arcana.RegisteredSpells[spellId]
			if not spell then continue end

			local eyePos = ply:EyePos()
			if eyePos:Distance(center) <= radius then continue end

			local eyeDir = ply:GetAimVector()
			if RaySphereIntersect(eyePos, eyeDir, center, radius) then
				Arcana:InterruptSpell(ply, spellId)
				self:_TriggerFlash()
			end
		end
	end

	function ENT:CaptureAllowed()
		self._allowed = {}
		local center = self:GetPos()
		local radius = self:GetRadius()

		for _, e in ipairs(ents.FindInSphere(center, radius)) do
			if IsValid(e) then
				self._allowed[e:EntIndex()] = true
			end
		end
	end

	function ENT:_IsOwnerAllowed(ent)
		if not ent.CPPIGetOwner then return false end
		local owner = ent:CPPIGetOwner()
		return IsValid(owner) and self._allowed[owner:EntIndex()] == true
	end

	function ENT:_Disintegrate(ent)
		local diss = ents.Create("env_entity_dissolver")
		if not IsValid(diss) then
			ent:Remove()
			return
		end

		diss:SetPos(ent:GetPos())
		diss:Spawn()
		diss:Activate()
		diss:SetKeyValue("dissolvetype", "0")

		local entName = "ward_dissolve_" .. ent:EntIndex() .. "_" .. CurTime()
		ent:SetName(entName)
		diss:Fire("Dissolve", entName, 0)
		diss:Fire("Kill", "", 0.5)
	end

	function ENT:Touch(ent)
		if not IsValid(ent) then return end
		if ent == self then return end
		if ent:IsWorld() then return end
		if ent:GetClass() == "arcana_ward" then return end

		-- Ignore entities that were present when the ward activated
		if self._allowed and self._allowed[ent:EntIndex()] then return end

		-- Props/entities owned by an allowed player get a pass
		if self:_IsOwnerAllowed(ent) then return end

		local isPlayer  = ent:IsPlayer()
		local isNPC     = ent:IsNPC()
		local isNextBot = ent.IsNextBot and ent:IsNextBot()
		local phys      = ent:GetPhysicsObject()
		local hasPhys   = IsValid(phys)
		local moveType  = ent:GetMoveType()
		local isFly     = moveType == MOVETYPE_FLY or moveType == MOVETYPE_FLYGRAVITY

		if not (isPlayer or isNPC or isNextBot or hasPhys or isFly) then return end

		local center = self:GetPos()
		local radius = self:GetRadius()
		local diff   = ent:GetPos() - center
		local dist   = diff:Length()

		-- The trigger is a bounding box; ignore entities in the box corners outside the sphere
		if dist > radius + 50 then return end

		local dir
		if dist < 1 then
			dir = Vector(math.random() * 2 - 1, math.random() * 2 - 1, 0):GetNormalized()
		else
			dir = diff / dist
		end

		if dist < radius then
			-- Props/physics deep inside the ward get disintegrated
			if not isPlayer and not isNPC and not isNextBot and dist < radius * 0.85 then
				self:_Disintegrate(ent)
			end

			ent:SetPos(center + dir * (radius + 4))
		end

		if isPlayer then
			if ent:GetMoveType() == MOVETYPE_NOCLIP then
				ent:SetMoveType(MOVETYPE_WALK)
			end
			ent:SetVelocity(dir * 1200)
		elseif isNPC or isNextBot then
			ent:SetVelocity(dir * 1200)
		elseif hasPhys then
			phys:ApplyForceCenter(dir * phys:GetMass() * 3000)
		elseif isFly then
			ent:SetVelocity(dir * 1500)
		end

		self:_TriggerFlash()
	end

	function ENT:EndTouch(ent)
	end

	function ENT:_TriggerFlash()
		local now = CurTime()
		if (self._lastFlash or 0) + 0.3 > now then return end
		self._lastFlash = now
		self:SetHitTime(now)
	end

	function ENT:_SpawnPlate(hitPos)
		local center  = self:GetPos()
		local outward = (hitPos - center):GetNormalized()

		local plate = ents.Create("prop_physics")
		if not IsValid(plate) then return end

		-- Orient the plate so its flat face (model Z-up) points outward along the sphere normal
		local ang = outward:Angle()
		ang:RotateAroundAxis(ang:Right(), 90)

		plate:SetModel(PLATE_MODEL)
		plate:SetPos(hitPos)
		plate:SetAngles(ang)
		plate:Spawn()
		plate:SetModelScale(PLATE_SCALE, 0)
		plate:Activate()

		plate:SetRenderMode(RENDERMODE_TRANSCOLOR)
		plate:SetColor(Color(255, 255, 255, 0))
		plate:DrawShadow(false)
		plate:SetMoveType(MOVETYPE_NONE)

		local phys = plate:GetPhysicsObject()
		if IsValid(phys) then
			phys:EnableMotion(false)
		end

		-- Tell clients to draw a magic circle matching the plate's orientation
		net.Start("Arcana_Ward_Plate", true)
		net.WriteVector(hitPos)
		net.WriteAngle(ang)
		net.WriteFloat(PLATE_LIFETIME)
		net.Broadcast()

		SafeRemoveEntityDelayed(plate, PLATE_LIFETIME)
		self._plates[#self._plates + 1] = plate
	end

	function ENT:OnRemove()
		for _, plate in ipairs(self._plates or {}) do
			if IsValid(plate) then plate:Remove() end
		end
	end
end

if CLIENT then
	net.Receive("Arcana_Ward_Plate", function()
		local pos      = net.ReadVector()
		local ang      = net.ReadAngle()
		local lifetime = net.ReadFloat()

		local MagicCircle = Arcana.Circle.MagicCircle
		if not MagicCircle then return end

		MagicCircle.CreateMagicCircle(
			pos, ang,
			Color(BAND_COLOR.r, BAND_COLOR.g, BAND_COLOR.b, FLASH_ALPHA),
			3, PLATE_CIRCLE_SIZE, lifetime, 2, 42
		)
	end)

	function ENT:Initialize()
		local r = self:GetRadius()
		if r <= 0 then r = WARD_RADIUS end
		self:SetRenderBounds(Vector(-r, -r, -r), Vector(r, r, r))
		self:SetNextClientThink(CurTime())
	end

	function ENT:_ComputeAlpha()
		if not self._flashStart then return 0 end

		local sinceFlash = CurTime() - self._flashStart
		if sinceFlash < FLASH_HOLD then
			return FLASH_ALPHA
		end

		local fadeElapsed = sinceFlash - FLASH_HOLD
		if fadeElapsed >= FLASH_FADE_OUT then
			self._flashStart = nil
			return 0
		end

		return FLASH_ALPHA * (1 - fadeElapsed / FLASH_FADE_OUT)
	end

	function ENT:Think()
		-- Lazy band creation — deferred so BandCircle is guaranteed to be loaded
		if not self._bands then
			local BandCircle = Arcana.Circle.BandCircle
			if BandCircle then
				local r = self:GetRadius()
				if r <= 0 then r = WARD_RADIUS end
				local color = Color(BAND_COLOR.r, BAND_COLOR.g, BAND_COLOR.b, 0)
				self._bands = BandCircle.Create(self:GetPos(), self:GetAngles(), color, r, 0)
				self._bands:AddBand(r * 0.95, 120, { p = 0,   y = 12,  r = 3  }, 6)
				self._bands:AddBand(r * 0.95, 120, { p = -6,  y = -9,  r = 2  }, 6)
				self._bands:AddBand(r * 0.95, 120, { p = 6,   y = -11, r = -2 }, 6)
				self._bands:AddBand(r * 0.95, 120, { p = -9,  y = 7,   r = -3 }, 6)
				self._bands:AddBand(r * 0.95, 120, { p = 3,   y = -14, r = 5  }, 6)
				self._bands:AddBand(r * 0.95, 120, { p = -4,  y = 9,   r = -5 }, 6)
			else
				self:SetNextClientThink(CurTime() + 0.1)
				return true
			end
		end

		self._bands.color.a = self:_ComputeAlpha()
		self:SetNextClientThink(CurTime())
		return true
	end

	local SPHERE_MAT = CreateMaterial("arcana_ward_sphere_" .. tostring(SysTime()), "UnlitGeneric", {
		["$basetexture"] = "color/white",
		["$translucent"] = 1,
		["$vertexalpha"] = 1,
		["$vertexcolor"] = 1,
		["$nocull"]      = 1,
		["$additive"]    = 1,
	})

	function ENT:DrawTranslucent()
		local a = self:_ComputeAlpha()
		local r = self:GetRadius()
		local color = Color(BAND_COLOR.r, BAND_COLOR.g, BAND_COLOR.b, a * 0.15)
		local sphereAlpha = a * 0.15

		render.SetMaterial(SPHERE_MAT)
		render.DrawSphere(self:GetPos(), r * 0.94, 32, 32, color)
	end

	function ENT:OnRemove()
		if self._bands then
			self._bands:Remove()
			self._bands = nil
		end
	end
end
