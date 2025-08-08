AddCSLuaFile("shared.lua")
AddCSLuaFile("cl_init.lua")
include("shared.lua")

function ENT:Initialize()
    self:SetModel("models/hunter/misc/sphere025x025.mdl")
    self:SetMoveType(MOVETYPE_VPHYSICS)
    self:SetSolid(SOLID_VPHYSICS)
    self:PhysicsInit(SOLID_VPHYSICS)
    self:SetCollisionGroup(COLLISION_GROUP_PROJECTILE)

    local phys = self:GetPhysicsObject()
    if IsValid(phys) then
        phys:EnableGravity(false)
        phys:Wake()
    end

    self:SetColor(Color(255, 120, 40, 255))
    self:SetMaterial("models/debug/debugwhite")

    -- VFX
    util.SpriteTrail(self, 0, Color(255, 140, 60, 220), true, 18, 2, 0.45, 1 / 128, "trails/smoke.vmt")

    -- Glow sprites
    local function addSprite(parent, model, color, scale, name)
        local spr = ents.Create("env_sprite")
        if not IsValid(spr) then return end
        spr:SetKeyValue("model", model)
        spr:SetKeyValue("rendercolor", string.format("%d %d %d", color.r, color.g, color.b))
        spr:SetKeyValue("rendermode", "9")
        spr:SetKeyValue("scale", tostring(scale))
        spr:SetParent(parent)
        spr:Spawn()
        spr:Activate()
        parent:CallOnRemove(name or ("ArcanaFireballSprite_" .. model), function(_, s) if IsValid(s) then s:Remove() end end, spr)
    end
    addSprite(self, "sprites/orangecore1.vmt", Color(255, 180, 80), 0.35, "ArcanaFB_S1")
    addSprite(self, "sprites/light_glow02_add.vmt", Color(255, 140, 60), 0.6, "ArcanaFB_S2")

    self.Created = CurTime()

    timer.Simple(self.MaxLifetime or 6, function()
        if IsValid(self) and not self._detonated then
            self:Detonate()
        end
    end)
end

function ENT:LaunchTowards(dir)
    local phys = self:GetPhysicsObject()
    if IsValid(phys) then
        phys:SetVelocity(dir:GetNormalized() * (self.FireballSpeed or 900))
    end
end

function ENT:PhysicsCollide(data, phys)
    self:Detonate()
end

function ENT:Touch(ent)
    if ent == self:GetSpellOwner() then return end
    self:Detonate()
end

function ENT:Detonate()
    if self._detonated then return end
    self._detonated = true

    local owner = self:GetSpellOwner() or self
    local pos = self:GetPos()

    util.BlastDamage(self, IsValid(owner) and owner or self, pos, self.FireballRadius or 180, self.FireballDamage or 60)
    for _, v in ipairs(ents.FindInSphere(pos, self.FireballRadius or 180)) do
        if IsValid(v) and (v:IsPlayer() or v:IsNPC()) then
            v:Ignite(self.FireballIgniteTime or 5)
        end
    end

    local ed = EffectData()
    ed:SetOrigin(pos)
    util.Effect("Explosion", ed, true, true)
    util.ScreenShake(pos, 5, 5, 0.35, 512)
    util.Decal("Scorch", pos + Vector(0, 0, 8), pos - Vector(0, 0, 16))
    sound.Play("ambient/explosions/explode_4.wav", pos, 90, 100)

    self:Remove()
end


