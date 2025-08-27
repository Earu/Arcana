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
	self:NetworkVar("Float", 1, "CrystalScale")
	self:NetworkVar("Float", 2, "StoredMana")

	if SERVER then
		self:SetAbsorbRadius(520)
		self:SetCrystalScale(0.35)
		self:SetStoredMana(0)
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

		self._growth = 0
		self._maxScale = 2.2
		self._minScale = 0.35
		self:_ApplyScale(self:GetCrystalScale())
	end

	function ENT:_ApplyScale(scale)
		local s = math.Clamp(tonumber(scale) or 1, self._minScale, self._maxScale)
		self:SetModelScale(s, 0)
		-- adjust absorb radius with size subtly
		self:SetAbsorbRadius(520 * (0.6 + (s - self._minScale) / (self._maxScale - self._minScale + 0.0001) * 0.8))
	end

	function ENT:SetCrystalScale(scale)
		self:SetDTFloat(1, scale)
		self:_ApplyScale(scale)
	end

	function ENT:AddCrystalGrowth(points)
		self._growth = math.max(0, (self._growth or 0) + (tonumber(points) or 0))
		local frac = math.Clamp(self._growth / 300, 0, 1)
		local target = self._minScale + (self._maxScale - self._minScale) * frac
		self:SetCrystalScale(target)
		self:EmitSound("buttons/blip1.wav", 55, 140)
	end

	-- Capacity and absorption helpers (computed from scale)
	function ENT:GetMaxMana()
		local s = math.Clamp(self:GetCrystalScale() or 1, self._minScale, self._maxScale)
		local t = (s - self._minScale) / math.max(0.0001, self._maxScale - self._minScale)
		local minCap = 200
		local maxCap = 2000
		return minCap + (maxCap - minCap) * t
	end

	function ENT:GetAbsorbRate()
		local s = math.Clamp(self:GetCrystalScale() or 1, self._minScale, self._maxScale)
		local t = (s - self._minScale) / math.max(0.0001, self._maxScale - self._minScale)
		local minRate = 6 -- mana/sec
		local maxRate = 30
		return minRate + (maxRate - minRate) * t
	end

	function ENT:AddStoredMana(amount)
		amount = tonumber(amount) or 0
		if amount <= 0 then return 0 end
		local cap = self:GetMaxMana()
		local cur = math.max(0, self:GetStoredMana() or 0)
		local add = math.min(amount, math.max(0, cap - cur))
		if add > 0 then
			self:SetStoredMana(cur + add)
		end
		return add
	end

	function ENT:IsFull()
		return (self:GetStoredMana() or 0) >= self:GetMaxMana() - 0.001
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


