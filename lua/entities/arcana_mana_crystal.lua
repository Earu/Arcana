AddCSLuaFile()

ENT.Type = "anim"
ENT.Base = "base_gmodentity"
ENT.PrintName = "Mana Crystal"
ENT.Author = "Earu"
ENT.Spawnable = false
ENT.AdminOnly = false
ENT.Category = "Arcana"
ENT.RenderGroup = RENDERGROUP_BOTH

function ENT:SetupDataTables()
	self:NetworkVar("Float", 0, "AbsorbRadius")

	if SERVER then
		self:SetAbsorbRadius(520)
	end
end

if SERVER then
	function ENT:Initialize()
		self:SetModel("models/props_abandoned/crystals/crystal_damaged/crystal_cluster_huge_damaged_a.mdl")
		self:SetMaterial("models/mspropp/light_blue001")
		self:PhysicsInit(SOLID_VPHYSICS)
		self:SetMoveType(MOVETYPE_VPHYSICS)
		self:SetSolid(SOLID_VPHYSICS)
		self:SetUseType(SIMPLE_USE)

		local phys = self:GetPhysicsObject()
		if IsValid(phys) then
			phys:Wake()
			phys:EnableMotion(false)
		end

		self:SetCollisionGroup(COLLISION_GROUP_WEAPON)
		self:DrawShadow(true)
	end
end

if CLIENT then
	function ENT:Initialize()
	end

	function ENT:OnRemove()
	end

	local function getCorePos(self)
		return self:LocalToWorld(self:OBBCenter())
	end

	function ENT:Think()
	end

	function ENT:Draw()
		self:DrawModel()

		local dl = DynamicLight(self:EntIndex())
		if dl then
			local center = getCorePos(self)
			dl.pos = center
			dl.r = 80
			dl.g = 180
			dl.b = 255
			dl.brightness = 6
			dl.Decay = 100
			dl.Size = math.max(160, self:GetAbsorbRadius() * 0.3)
			dl.DieTime = CurTime() + 0.1
		end
	end

	function ENT:DrawTranslucent()
	end
end


