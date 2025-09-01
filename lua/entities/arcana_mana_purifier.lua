AddCSLuaFile()
ENT.Type = "anim"
ENT.Base = "base_gmodentity"
ENT.PrintName = "Mana Purifier"
ENT.Author = "Earu"
ENT.Spawnable = true
ENT.AdminOnly = true
ENT.Category = "Arcana"
ENT.RenderGroup = RENDERGROUP_BOTH

function ENT:SetupDataTables()
end

if SERVER then
    function ENT:Initialize()
        self:SetModel("models/props_combine/combine_smallmonitor001.mdl")
        self:SetMaterial("models/props_c17/metalladder001")
        self:PhysicsInit(SOLID_VPHYSICS)
        self:SetMoveType(MOVETYPE_VPHYSICS)
        self:SetSolid(SOLID_VPHYSICS)
        self:SetUseType(SIMPLE_USE)
        local phys = self:GetPhysicsObject()
        if IsValid(phys) then
            phys:Wake()
            phys:EnableMotion(false)
        end

        local Arcane = _G.Arcane or {}
        if Arcane.ManaNetwork and Arcane.ManaNetwork.RegisterNode then
            Arcane.ManaNetwork:RegisterNode(self, {type = "purifier", range = 700})
        end
    end

    function ENT:OnRemove()
        local Arcane = _G.Arcane or {}
        if Arcane.ManaNetwork and Arcane.ManaNetwork.UnregisterNode then
            Arcane.ManaNetwork:UnregisterNode(self)
        end
    end
end


