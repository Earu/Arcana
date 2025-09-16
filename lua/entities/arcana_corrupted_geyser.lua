AddCSLuaFile()
ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "Corrupted Geyser"
ENT.Category = "Arcana"
ENT.Spawnable = false
ENT.AdminOnly = false
ENT.RenderGroup = RENDERGROUP_BOTH
ENT.PhysgunDisabled = true

function ENT:SetupDataTables()
    self:NetworkVar("Float", 0, "Radius")
    self:NetworkVar("Float", 1, "Duration")
    self:NetworkVar("Float", 2, "Damage")
end

-- Accessor wrappers to guarantee existence and replication
function ENT:SetTelegraphTime(t)
    self._telegraphEnd = t
    self:SetNWFloat("Arcana_Geyser_TelegraphEnd", t)
end

function ENT:GetTelegraphTime()
    return self._telegraphEnd or self:GetNWFloat("Arcana_Geyser_TelegraphEnd", 0)
end

function ENT:SetEruptTime(t)
    self._eruptAt = t
    self:SetNWFloat("Arcana_Geyser_EruptTime", t)
end

function ENT:GetEruptTime()
    return self._eruptAt or self:GetNWFloat("Arcana_Geyser_EruptTime", 0)
end

if SERVER then
    local TELEGRAPH_DURATION = 1.2
    local ERUPTION_DURATION = 10
    local DEFAULT_RADIUS = 240
    local DEFAULT_DAMAGE = 40

    function ENT:Initialize()
        self:SetModel("models/props_junk/watermelon01.mdl")
        self:SetMoveType(MOVETYPE_NONE)
        self:SetSolid(SOLID_NONE)
        self:DrawShadow(false)
        self:SetRadius(self:GetRadius() > 0 and self:GetRadius() or DEFAULT_RADIUS)
        self:SetDuration(self:GetDuration() > 0 and self:GetDuration() or ERUPTION_DURATION)
        self:SetDamage(self:GetDamage() > 0 and self:GetDamage() or DEFAULT_DAMAGE)

        local now = CurTime()
        local telegraphEnd = now + TELEGRAPH_DURATION
        self:SetTelegraphTime(telegraphEnd)
        self:SetEruptTime(telegraphEnd)

        -- schedule self removal after eruption
        self._dieAt = now + TELEGRAPH_DURATION + self:GetDuration()

        self._didBoom = false
        self._lastThink = now
    end

    local function blast(self)
        local pos = self:GetPos()
        local r = math.max(24, self:GetRadius() or DEFAULT_RADIUS)
        local dmg = self:GetDamage() or DEFAULT_DAMAGE

        -- Damage pulse (custom blast for ForceTakeDamageInfo support)
        if Arcane and Arcane.BlastDamage then
            Arcane:BlastDamage(self, self, pos, r, dmg, DMG_DISSOLVE, true)
        else
            util.BlastDamage(self, self, pos, r, dmg)
        end

        -- Knockback for physics objects
        for _, ent in ipairs(ents.FindInSphere(pos, r)) do
            if not IsValid(ent) then continue end
            if ent == self then continue end
            local dir = (ent:WorldSpaceCenter() - pos)
            local dist = dir:Length()
            if dist <= 0 then dir = Vector(0,0,1) else dir:Mul(1 / dist) end
            local force = 60000 * math.max(0, 1 - dist / r)
            local phys = ent.GetPhysicsObject and ent:GetPhysicsObject() or nil
            if IsValid(phys) then
                phys:ApplyForceCenter(dir * force)
            end

            if ent:IsPlayer() or ent:IsNPC() then
                ent:SetVelocity(dir * 450)
            end
        end

        -- Effects (grayscale-friendly)
        local ed = EffectData()
        ed:SetOrigin(pos)
        ed:SetScale(r / 64)
        util.Effect("ThumperDust", ed, true, true)
        sound.Play("ambient/levels/labs/electric_explosion5.wav", pos, 70, math.random(90,105))
    end

    function ENT:Think()
        local now = CurTime()
        local eruptAt = self:GetEruptTime()
        if not self._didBoom and now >= eruptAt then
            self._didBoom = true
            blast(self)
            self._eruptionEnd = eruptAt + (self:GetDuration() or ERUPTION_DURATION)
        end

        -- During eruption: apply periodic upward force and damage to entities standing in the geyser
        if self._didBoom and now < (self._eruptionEnd or 0) then
            local tick = 0.2
            if now >= (self._nextTick or 0) then
                self._nextTick = now + tick
                local pos = self:GetPos()
                local r = math.max(24, self:GetRadius() or DEFAULT_RADIUS)
                local dps = self:GetDamage() or DEFAULT_DAMAGE
                local perTickDamage = dps * tick

                for _, ent in ipairs(ents.FindInSphere(pos, r)) do
                    if not IsValid(ent) or ent == self then continue end
                    local entPos = ent:WorldSpaceCenter()
                    local dist = entPos:Distance(pos)
                    local falloff = math.Clamp(1 - dist / r, 0, 1)

                    -- Apply damage (players/NPCs prioritized) using ForceTakeDamageInfo if available
                    if ent:IsPlayer() or ent:IsNPC() then
                        local dmginfo = DamageInfo()
                        dmginfo:SetDamage(perTickDamage * (0.6 + 0.4 * falloff))
                        dmginfo:SetDamageType(DMG_DISSOLVE)
                        dmginfo:SetAttacker(self)
                        dmginfo:SetInflictor(self)
                        local tdi = ent.ForceTakeDamageInfo or ent.TakeDamageInfo
                        if isfunction(tdi) then tdi(ent, dmginfo) end
                    end

                    -- Upward push
                    local upPush = 300 + 400 * falloff
                    if ent:IsPlayer() or ent:IsNPC() then
                        ent:SetVelocity(Vector(0, 0, upPush))
                    else
                        local phys = ent.GetPhysicsObject and ent:GetPhysicsObject() or nil
                        if IsValid(phys) then
                            phys:ApplyForceCenter(Vector(0, 0, upPush * phys:GetMass()))
                        end
                    end
                end
            end
        end

        if now >= (self._dieAt or now) then
            self:Remove()
            return
        end

        self:NextThink(now + 0.05)
        return true
    end
end

if CLIENT then
    local MAT_RING = Material("sprites/light_glow02_add")

    function ENT:Initialize()
        self._made = CurTime()
        self._smokeNext = 0
    end

    function ENT:Draw()
        local pos = self:GetPos()
        local base = pos + Vector(0, 0, 6)
        local telegraphEnd = self:GetTelegraphTime()
        local now = CurTime()
        local r = math.max(24, self:GetRadius() or 240)

        -- Telegraph: growing, pulsing grayscale ring
        local tRemain = math.max(0, telegraphEnd - now)
        local telegraphFrac = math.Clamp(1 - tRemain / 1.2, 0, 1)
        local size = r * (0.7 + telegraphFrac * 1.0)
        local alpha = 200 * (0.4 + 0.6 * math.abs(math.sin(now * 9)))
        render.SetMaterial(MAT_RING)
        render.DrawSprite(pos + Vector(0,0,4), size * 2.2, size * 2.2, Color(220, 220, 220, alpha))

        -- After eruption: fast rising smoke (grayscale)
        if now > telegraphEnd then
            if now > (self._smokeNext or 0) then
                self._smokeNext = now + 0.04
                local emitter = ParticleEmitter(pos)
                if emitter then
                    for i = 1, 10 do
                        local p = emitter:Add("particle/smokesprites_000" .. math.random(1,9), base + VectorRand() * (r * 0.15))
                        if p then
                            p:SetVelocity(VectorRand() * 60 + Vector(0,0,220))
                            p:SetDieTime(math.Rand(0.5, 1.0))
                            p:SetStartAlpha(180)
                            p:SetEndAlpha(0)
                            p:SetStartSize(math.Rand(18, 32))
                            p:SetEndSize(math.Rand(80, 140))
                            p:SetRoll(math.Rand(0, 360))
                            p:SetRollDelta(math.Rand(-1.5, 1.5))
                            local g = math.random(140, 220)
                            p:SetColor(g, g, g)
                            p:SetAirResistance(24)
                            p:SetGravity(Vector(0,0,40))
                        end
                    end
                    emitter:Finish()
                end
            end
        end
    end
end