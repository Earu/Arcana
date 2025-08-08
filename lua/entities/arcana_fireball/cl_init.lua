include("shared.lua")

function ENT:Initialize()
    self._lastPos = self:GetPos()
    self._nextPFX = 0
    self.Emitter = ParticleEmitter(self:GetPos())
end

function ENT:OnRemove()
    if self.Emitter then
        self.Emitter:Finish()
        self.Emitter = nil
    end
end

function ENT:Think()
    if not self.Emitter then
        self.Emitter = ParticleEmitter(self:GetPos())
    end

    local now = CurTime()
    if now >= (self._nextPFX or 0) and self.Emitter then
        self._nextPFX = now + 1 / 90 -- emission rate

        local pos = self:GetPos()
        local vel = (pos - (self._lastPos or pos)) / math.max(FrameTime(), 0.001)
        self._lastPos = pos
        local back = -vel:GetNormalized()

        -- Embers
        for i = 1, 3 do
            local p = self.Emitter:Add("effects/yellowflare", pos + VectorRand() * 2)
            if p then
                p:SetVelocity(back * (60 + math.random(0, 40)) + VectorRand() * 20)
                p:SetDieTime(0.4 + math.Rand(0.1, 0.3))
                p:SetStartAlpha(220)
                p:SetEndAlpha(0)
                p:SetStartSize(4 + math.random(0, 2))
                p:SetEndSize(0)
                p:SetRoll(math.Rand(0, 360))
                p:SetRollDelta(math.Rand(-3, 3))
                p:SetColor(255, 160 + math.random(0, 40), 60)
                p:SetLighting(false)
                p:SetAirResistance(60)
                p:SetGravity(Vector(0, 0, -50))
                p:SetCollide(false)
            end
        end

        -- Fire cloud/smoke
        for i = 1, 2 do
            local mat = (math.random() < 0.5) and "effects/fire_cloud1" or "effects/fire_cloud2"
            local p = self.Emitter:Add(mat, pos)
            if p then
                p:SetVelocity(back * (40 + math.random(0, 30)) + VectorRand() * 10)
                p:SetDieTime(0.6 + math.Rand(0.2, 0.5))
                p:SetStartAlpha(180)
                p:SetEndAlpha(0)
                p:SetStartSize(10 + math.random(0, 8))
                p:SetEndSize(30 + math.random(0, 12))
                p:SetRoll(math.Rand(0, 360))
                p:SetRollDelta(math.Rand(-1, 1))
                p:SetColor(255, 120 + math.random(0, 60), 40)
                p:SetLighting(false)
                p:SetAirResistance(70)
                p:SetGravity(Vector(0, 0, 20))
                p:SetCollide(false)
            end
        end

        -- Heat shimmer
        local hw = self.Emitter:Add("sprites/heatwave", pos)
        if hw then
            hw:SetVelocity(VectorRand() * 10)
            hw:SetDieTime(0.25)
            hw:SetStartAlpha(180)
            hw:SetEndAlpha(0)
            hw:SetStartSize(14)
            hw:SetEndSize(0)
            hw:SetRoll(math.Rand(0, 360))
            hw:SetRollDelta(math.Rand(-1, 1))
            hw:SetLighting(false)
        end
    end

    self:NextThink(now)
    return true
end

function ENT:Draw()
    -- Dynamic light for fireball glow (flicker)
    local dlight = DynamicLight(self:EntIndex())
    if dlight then
        local c = self:GetColor()
        dlight.pos = self:GetPos()
        dlight.r = c.r or 255
        dlight.g = math.max(80, c.g or 140)
        dlight.b = 40
        dlight.brightness = 2.6 + math.Rand(0, 0.6)
        dlight.Decay = 900
        dlight.Size = 180
        dlight.DieTime = CurTime() + 0.1
    end
end


