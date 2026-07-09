-- The Emissary — a stone statue that carries prayers to the gods. Players
-- compose crafted spells here (Form + Essence + Clauses), buy essences, and
-- activate spells carried from other servers.

AddCSLuaFile()

ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "The Emissary"
ENT.Category = "Arcana"
ENT.Spawnable = true
ENT.AdminSpawnable = true
ENT.AdminOnly = true
ENT.RenderGroup = RENDERGROUP_BOTH
ENT.UseCooldown = 0.75

local EMISSARY_MODEL = "models/props_c17/gravestone_statue001a.mdl"

if SERVER then
	function ENT:Initialize()
		self:SetModel(EMISSARY_MODEL)
		self:PhysicsInit(SOLID_VPHYSICS)
		self:SetMoveType(MOVETYPE_VPHYSICS)
		self:SetSolid(SOLID_VPHYSICS)
		self:SetUseType(SIMPLE_USE)

		local phys = self:GetPhysicsObject()
		if IsValid(phys) then
			phys:Wake()
			phys:EnableMotion(false)
		end

		self._nextUse = 0
	end

	function ENT:SpawnFunction(ply, tr, classname)
		if not tr or not tr.Hit then return end
		local ent = ents.Create(classname or "arcana_emissary")
		if not IsValid(ent) then return end
		ent:SetPos(tr.HitPos + tr.HitNormal * 2)
		ent:SetAngles(Angle(0, ply:EyeAngles().y, 0))
		ent:Spawn()
		ent:Activate()
		return ent
	end

	function ENT:Use(ply)
		if not IsValid(ply) or not ply:IsPlayer() then return end
		local now = CurTime()
		if now < (self._nextUse or 0) then return end
		self._nextUse = now + self.UseCooldown
		net.Start("Arcana_OpenSpellcraftMenu")
		net.WriteEntity(self)
		net.Send(ply)
		self:EmitSound("buttons/button9.wav", 60, 100)
	end

end

if CLIENT then
	function ENT:Draw()
		self:DrawModel()
	end
end
