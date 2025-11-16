if SERVER then
    AddCSLuaFile()
    util.AddNetworkString("Arcana_Phoenix_FlameFX")
end

SWEP.PrintName = "Phoenix Talons"
SWEP.Author = "Arcana"
SWEP.Instructions = "LMB: Fireball salvo | RMB: Flamethrower"
SWEP.Spawnable = false
SWEP.AdminOnly = false
SWEP.DrawAmmo = false
SWEP.DrawCrosshair = true
SWEP.ViewModel = "models/weapons/c_arms_citizen.mdl"
SWEP.WorldModel = "models/props_junk/PopCan01a.mdl" -- dummy
SWEP.UseHands = true
SWEP.Primary.ClipSize = -1
SWEP.Primary.DefaultClip = -1
SWEP.Primary.Automatic = true
SWEP.Primary.Ammo = "none"
SWEP.Secondary.ClipSize = -1
SWEP.Secondary.DefaultClip = -1
SWEP.Secondary.Automatic = true
SWEP.Secondary.Ammo = "none"
SWEP.HoldType = "fist"

local PHX_PRIMARY_COOLDOWN = 0.8
local PHX_SECONDARY_TICK = 0.1

function SWEP:Initialize()
    self:SetWeaponHoldType(self.HoldType)
    self._nextPrimary = 0
    self._nextFlame = 0
end

local function getPhoenixBird(ply)
    local st = ply and ply._ArcanaPhoenix
    return st and st.bird
end

function SWEP:Deploy()
    return true
end

function SWEP:Holster()
    return true
end

function SWEP:PrimaryAttack()
    local owner = self:GetOwner()
    if not IsValid(owner) then return end
    local now = CurTime()
    if now < (self._nextPrimary or 0) then return end
    self._nextPrimary = now + PHX_PRIMARY_COOLDOWN

    if SERVER then
        local bird = getPhoenixBird(owner)
        local basePos = IsValid(bird) and bird:WorldSpaceCenter() or owner:GetShootPos()
        local aim = owner:EyeAngles()
        local yaws = {-8, 0, 8}
        for i = 1, #yaws do
            local a = Angle(aim.p, aim.y + yaws[i], 0)
            local dir = a:Forward()
            local ent = ents.Create("arcana_fireball")
            if IsValid(ent) then
                ent:SetPos(basePos + dir * 24 + Vector(0, 0, 8))
                ent:SetSpellOwner(owner)
                ent.FireballDamage = 95 -- Reduced damage for Phoenix mode
                ent:Spawn()
                ent:LaunchTowards(dir)
            end
        end
        owner:EmitSound("ambient/fire/gascan_ignite1.wav", 70, 110)
    end

    self:SetNextPrimaryFire(CurTime() + 0.05)
end

function SWEP:SecondaryAttack()
    local owner = self:GetOwner()
    if not IsValid(owner) then return end
    local now = CurTime()
    if now < (self._nextFlame or 0) then return end
    self._nextFlame = now + PHX_SECONDARY_TICK

    if SERVER then
        local bird = getPhoenixBird(owner)
        local origin = IsValid(bird) and bird:WorldSpaceCenter() or owner:GetShootPos()
        local forward = owner:EyeAngles():Forward()
        local cosHalfAngle = math.cos(math.rad(35))
        local maxRange = 1100
        local baseDamage = 8
        local igniteTime = 2
        for _, ent in ipairs(ents.FindInSphere(origin, maxRange)) do
            if not IsValid(ent) or ent == owner then continue end
            local toTarget = (ent:WorldSpaceCenter() - origin)
            local dist = toTarget:Length()
            if dist > maxRange then continue end
            local dir = toTarget:GetNormalized()
            if dir:Dot(forward) < cosHalfAngle then continue end
            if ent:IsPlayer() or ent:IsNPC() or (ent.IsNextBot and ent:IsNextBot()) then
                local dmg = DamageInfo()
                dmg:SetDamage(baseDamage)
                dmg:SetDamageType(bit.bor(DMG_BURN, DMG_SLOWBURN))
                dmg:SetAttacker(IsValid(owner) and owner or game.GetWorld())
                dmg:SetInflictor(IsValid(owner) and owner or game.GetWorld())
                ent:TakeDamageInfo(dmg)
                if ent.Ignite then ent:Ignite(igniteTime, 0) end
            else
                local phys = ent:GetPhysicsObject()
                if IsValid(phys) then
                    phys:ApplyForceCenter(forward * (400 * phys:GetMass()))
                end
            end
        end
        net.Start("Arcana_Phoenix_FlameFX", true)
        net.WriteVector(origin)
        net.WriteVector(forward)
        net.WriteFloat(maxRange)
        net.Broadcast()
        owner:EmitSound("ambient/fire/ignite.wav", 65, 120, 0.6)
    end

    self:SetNextSecondaryFire(CurTime() + 0.01)
end

function SWEP:ShouldDropOnDie()
    return false
end

function SWEP:Equip()
    -- Hide viewmodel when in phoenix form; we already handle camera externally
    if CLIENT then
        local owner = self:GetOwner()
        if IsValid(owner) and owner == LocalPlayer() and self.DrawViewModel ~= nil then
            self:DrawViewModel(false)
        end
    end
end

-- Client: flame VFX
if CLIENT then
    net.Receive("Arcana_Phoenix_FlameFX", function()
        local origin = net.ReadVector()
        local forward = net.ReadVector()
        local maxRange = net.ReadFloat() or 1100
        local emitter = ParticleEmitter(origin)
        if not emitter then return end
        local points = 20
        for i = 1, points do
            local t = i / points
            local radial = 20 + 60 * t
            local ppos = origin + forward * (maxRange * (0.10 + 0.80 * t)) + VectorRand() * radial
            local p1 = emitter:Add("effects/yellowflare", ppos)
            if p1 then
                p1:SetVelocity(forward * (140 + math.random(0, 100)) + VectorRand() * 40)
                p1:SetDieTime(0.35 + math.Rand(0.1, 0.25))
                p1:SetStartAlpha(220)
                p1:SetEndAlpha(0)
                p1:SetStartSize(6 + math.random(0, 3))
                p1:SetEndSize(0)
                p1:SetRoll(math.Rand(0, 360))
                p1:SetRollDelta(math.Rand(-3, 3))
                p1:SetColor(255, 160 + math.random(0, 40), 60)
                p1:SetLighting(false)
                p1:SetAirResistance(60)
                p1:SetGravity(Vector(0, 0, -30))
                p1:SetCollide(false)
            end
            local mat = (math.random() < 0.5) and "effects/fire_cloud1" or "effects/fire_cloud2"
            local p2 = emitter:Add(mat, ppos)
            if p2 then
                p2:SetVelocity(forward * (120 + math.random(0, 60)) + VectorRand() * 30)
                p2:SetDieTime(0.5 + math.Rand(0.2, 0.3))
                p2:SetStartAlpha(180)
                p2:SetEndAlpha(0)
                p2:SetStartSize(16 + math.random(0, 12))
                p2:SetEndSize(48 + math.random(0, 18))
                p2:SetRoll(math.Rand(0, 360))
                p2:SetRollDelta(math.Rand(-1, 1))
                p2:SetColor(255, 120 + math.random(0, 60), 40)
                p2:SetLighting(false)
                p2:SetAirResistance(70)
                p2:SetGravity(Vector(0, 0, 20))
                p2:SetCollide(false)
            end
        end
        local hw = emitter:Add("sprites/heatwave", origin + forward * 80)
        if hw then
            hw:SetVelocity(forward * 120)
            hw:SetDieTime(0.3)
            hw:SetStartAlpha(180)
            hw:SetEndAlpha(0)
            hw:SetStartSize(22)
            hw:SetEndSize(0)
            hw:SetRoll(math.Rand(0, 360))
            hw:SetRollDelta(math.Rand(-1, 1))
            hw:SetLighting(false)
        end
        timer.Simple(0.06, function()
            if emitter then emitter:Finish() end
        end)
    end)
end


