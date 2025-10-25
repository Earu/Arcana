AddCSLuaFile()

ENT.Type = "anim"
ENT.Base = "base_gmodentity"
ENT.PrintName = "Solidified Spores"
ENT.Author = "Arcana"
ENT.Spawnable = false
ENT.AdminOnly = false
ENT.Category = "Arcana"
ENT.PhysgunDisabled = true
ENT.ms_notouch = true

-- Green-tinted larval essence model
local SPORE_MODEL = "models/props_hive/larval_essence.mdl"
local SPORE_COLOR = Color(120, 200, 120)

if SERVER then
    function ENT:Initialize()
        self:SetModel("models/Gibs/HGIBS.mdl") -- for physics
        self:PhysicsInit(SOLID_VPHYSICS)
        self:SetMoveType(MOVETYPE_VPHYSICS)
        self:SetSolid(SOLID_VPHYSICS)
        self:SetUseType(SIMPLE_USE)
        self:SetTrigger(true)

        self:SetColor(SPORE_COLOR)

        local phys = self:GetPhysicsObject()
        if IsValid(phys) then
            phys:Wake()
            phys:SetMaterial("gmod_ice")
            phys:SetBuoyancyRatio(0.2)
        end

        SafeRemoveEntityDelayed(self, 300) -- 5 minutes
    end

    function ENT:OnRemove()
    end

    local function tryPickup(self, ply)
        if not IsValid(self) or not IsValid(ply) or not ply:IsPlayer() then return false end
        if not ply.GiveItem then return false end

        ply:GiveItem("solidified_spores", 1)
        self:EmitSound("physics/flesh/flesh_bloody_break.wav", 60, 180, 0.6)

        local ed = EffectData()
        ed:SetOrigin(self:WorldSpaceCenter())
        util.Effect("GlassImpact", ed, true, true)

        SafeRemoveEntity(self)
        return true
    end

    function ENT:Use(activator)
        if not IsValid(activator) or not activator:IsPlayer() then return end
        tryPickup(self, activator)
    end

    function ENT:PhysicsCollide(data, phys)
        if data.Speed > 60 then
            self:EmitSound("physics/flesh/flesh_impact_bullet1.wav", 60, math.random(170, 200), 0.55)
        end

        if IsValid(phys) and data.Speed > 150 then
            phys:SetVelocity(phys:GetVelocity() * 0.6)
        end

        if IsValid(data.Entity) and data.Entity:IsPlayer() then
            tryPickup(self, data.Entity)

            return
        end
    end

    function ENT:StartTouch(ent)
        if ent:IsPlayer() then
            tryPickup(self, ent)
        end
    end
end

if CLIENT then
    local MAX_RENDER_DIST = 1500 * 1500
    local GLARE_MAT = Material("sprites/light_ignorez")
    local WARP_MAT = Material("particle/warp2_warp")

    local GLOW_MAT = CreateMaterial(tostring{}, "UnlitGeneric", {
        ["$BaseTexture"] = "particle/fire",
        ["$Additive"] = 1,
        ["$VertexColor"] = 1,
        ["$VertexAlpha"] = 1,
    })

    function ENT:Initialize()
        self:SetModel(SPORE_MODEL) -- for physics
        self:SetColor(SPORE_COLOR)
        self._fxEmitter = ParticleEmitter(self:GetPos(), false)
        self._fxNext = 0
    end

    function ENT:OnRemove()
        if self._fxEmitter then
            self._fxEmitter:Finish()
            self._fxEmitter = nil
        end
    end

    function ENT:Think()
        if self._fxEmitter then
            self._fxEmitter:SetPos(self:GetPos())
        end

        if EyePos():DistToSqr(self:GetPos()) > MAX_RENDER_DIST then return end

        local now = CurTime()
        if now >= (self._fxNext or 0) and self._fxEmitter then
            self._fxNext = now + 0.12
            local origin = self:WorldSpaceCenter()

            -- small bright motes
            for i = 1, 1 do
                local p = self._fxEmitter:Add("sprites/light_glow02_add", origin + VectorRand() * math.Rand(1, 6))
                if p then
                    p:SetStartAlpha(150)
                    p:SetEndAlpha(0)
                    p:SetStartSize(math.Rand(2, 4))
                    p:SetEndSize(0)
                    p:SetDieTime(math.Rand(0.5, 0.8))
                    p:SetVelocity(Vector(0, 0, math.Rand(8, 16)))
                    p:SetAirResistance(40)
                    p:SetGravity(Vector(0, 0, 0))
                    p:SetRoll(math.Rand(-180, 180))
                    p:SetRollDelta(math.Rand(-1, 1))
                    p:SetColor(SPORE_COLOR.r, SPORE_COLOR.g, SPORE_COLOR.b)
                end
            end
        end

        self:SetNextClientThink(CurTime())
        return true
    end

    function ENT:Draw()
        self:DrawModel()

        -- extra glow layers
        local pos = self:WorldSpaceCenter()
        local dist = EyePos():DistToSqr(pos)
        if dist <= MAX_RENDER_DIST then
            render.SetMaterial(WARP_MAT)
            render.DrawSprite(pos, 36, 36, Color(SPORE_COLOR.r, SPORE_COLOR.g, SPORE_COLOR.b, 40))
            render.SetMaterial(GLARE_MAT)
            render.DrawSprite(pos, 64, 32, Color(SPORE_COLOR.r, SPORE_COLOR.g, SPORE_COLOR.b, 24))
        end
    end
end