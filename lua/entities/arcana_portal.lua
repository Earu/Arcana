AddCSLuaFile()

ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "Arcana Portal"
ENT.Spawnable = false
ENT.AdminSpawnable = false

ENT.DefaultRadius = 96

function ENT:SetupDataTables()
	self:NetworkVar("Vector", 0, "Destination")
	self:NetworkVar("Float", 0, "Radius")
	self:NetworkVar("Angle", 0, "DestinationAngles")

	if SERVER then
		self:SetRadius(self.DefaultRadius)
		self:SetDestination(self:GetPos())
		self:SetDestinationAngles(Angle(0, 0, 0))
	end
end

-- Server logic
if SERVER then
	local TELEPORT_COOLDOWN = 1.25
	local TELEPORT_SOUND = "ambient/energy/whiteflash.wav"

	function ENT:Initialize()
		self:SetModel("models/hunter/plates/plate2x2.mdl")
		self:SetMoveType(MOVETYPE_NONE)
		self:SetSolid(SOLID_VPHYSICS)
		self:PhysicsInit(SOLID_VPHYSICS)
		self:SetCollisionGroup(COLLISION_GROUP_WEAPON)
		self:SetTrigger(true)
		self:SetNoDraw(true)
		self._nextEligible = {}
	end

	function ENT:SpawnFunction(ply, tr, classname)
		if not tr or not tr.Hit then return end
		local pos = tr.HitPos + tr.HitNormal * 2
		local ent = ents.Create(classname or "arcana_portal")
		if not IsValid(ent) then return end
		ent:SetPos(pos)
		local ang = tr.HitNormal:Angle()
		ang:RotateAroundAxis(ang:Right(), 90)
		ent:SetAngles(Angle(0, ply:EyeAngles().y, 0))
		ent:Spawn()
		ent:Activate()
		return ent
	end

	local function isAbovePortal(ent, portal)
		if not IsValid(ent) then return false end
		local portalPos = portal:GetPos()
		local up = portal:GetUp()
		local entPos = ent:WorldSpaceCenter()
		local vertical = up:Dot(entPos - portalPos)
		return vertical >= -8 and vertical <= 128
	end

	local function shouldTeleportEntity(ent)
		if not IsValid(ent) then return false end
		if ent:IsPlayer() then return ent:Alive() end
		if ent:IsNPC() then return true end
		if ent:GetMoveType() == MOVETYPE_VPHYSICS then return true end
		if ent:GetClass() == "arcana_portal" then return false end
		return false
	end

	function ENT:StartTouch(ent)
		self:TryTeleport(ent)
	end

	function ENT:Touch(ent)
		self:TryTeleport(ent)
	end

	function ENT:EndTouch(ent)
		if IsValid(ent) then
			self._nextEligible[ent] = 0
		end
	end

	function ENT:Think()
		local radius = math.max(16, self:GetRadius())
		local center = self:GetPos()
		for _, ent in ipairs(ents.FindInSphere(center, radius)) do
			if shouldTeleportEntity(ent) and isAbovePortal(ent, self) then
				self:TryTeleport(ent)
			end
		end
		self:NextThink(CurTime() + 0.1)
		return true
	end

	util.AddNetworkString("Arcana_Portal_Teleported")

	function ENT:_PlayTeleportVFX(ent)
		if not IsValid(self) or not IsValid(ent) then return end
		net.Start("Arcana_Portal_Teleported")
			net.WriteEntity(self)
			net.WriteEntity(ent)
		net.Broadcast()
	end

	function ENT:TryTeleport(ent)
		if not shouldTeleportEntity(ent) then return end
		if not isAbovePortal(ent, self) then return end
		if ent == self or ent:GetClass() == "arcana_portal" then return end

		local now = CurTime()
		if ent._arcanaNextTeleport and now < ent._arcanaNextTeleport then return end
		local nextOk = self._nextEligible[ent] or 0
		if now < nextOk then return end

		local dest = self:GetDestination() or self:GetPos()
		local destAng = self:GetDestinationAngles() or Angle(0, 0, 0)
		local exitPos = dest + Vector(0, 0, 4)

		if ent:IsPlayer() then
			local vel = ent:GetVelocity()
			ent:SetPos(exitPos)
			ent:SetEyeAngles(destAng)
			ent:SetLocalVelocity(vel)
			ent:EmitSound(TELEPORT_SOUND, 70, 100)
		elseif ent:IsNPC() then
			ent:SetPos(exitPos)
			ent:SetAngles(destAng)
			ent:EmitSound(TELEPORT_SOUND, 70, 95)
		else
			if ent.GetPhysicsObject then
				local phys = ent:GetPhysicsObject()
				if IsValid(phys) then
					local vel = phys:GetVelocity()
					ent:SetPos(exitPos)
					ent:SetAngles(destAng)
					phys:SetVelocity(vel)
				else
					ent:SetPos(exitPos)
					ent:SetAngles(destAng)
				end
			else
				ent:SetPos(exitPos)
				ent:SetAngles(destAng)
			end
			sound.Play(TELEPORT_SOUND, exitPos, 70, 105)
		end

		self:_PlayTeleportVFX(ent)
		self._nextEligible[ent] = now + TELEPORT_COOLDOWN
		ent._arcanaNextTeleport = now + TELEPORT_COOLDOWN
	end
end

-- Client visuals
if CLIENT then
	local circleColor = Color(120, 200, 255, 255)

	function ENT:Initialize()
		self._circle = nil
	end

	function ENT:OnRemove()
		if self._circle and self._circle.Destroy then self._circle:Destroy() end
		self._circle = nil
	end

	local function ensureCircle(self)
		if not MagicCircle or not MagicCircle.new then return end
		if self._circle and self._circle.IsActive and self._circle:IsActive() then return end

		local pos = self:GetPos() + self:GetUp() * 2
		local ang = self:GetAngles()
		ang:RotateAroundAxis(ang:Forward(), 180)
		local size = math.max(24, self:GetRadius())

		self._circle = MagicCircle.new(pos, ang, circleColor, 3, size, 2.0)
		MagicCircleManager:Add(self._circle)
	end

	function ENT:Think()
		ensureCircle(self)
		self:NextThink(CurTime() + 0.2)
		return true
	end

	net.Receive("Arcana_Portal_Teleported", function()
		local portal = net.ReadEntity()
		local ent = net.ReadEntity()
		if not IsValid(portal) then return end

		local baseAng = portal:GetAngles()
		local flatAng = Angle(baseAng)
		flatAng:RotateAroundAxis(flatAng:Up(), 90)

		if IsValid(ent) then
			local ed = EffectData()
			ed:SetOrigin(ent:WorldSpaceCenter())
			util.Effect("cball_explode", ed)
		end
	end)
end