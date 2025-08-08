AddCSLuaFile()

if not Arcane then return end

local function getAimGround(ply, maxRange)
    local tr = ply:GetEyeTrace()
    if tr.Hit and tr.HitPos:DistToSqr(ply:GetPos()) <= (maxRange * maxRange) then
        return tr.HitPos, tr.HitNormal
    end
    return ply:GetPos() + ply:GetForward() * math.min(maxRange, 1000), Vector(0, 0, 1)
end

Arcane:RegisterSpell({
    id = "lightning_strike",
    name = "Lightning Strike",
    description = "Call a storm cloud that smites below",
    category = Arcane.CATEGORIES.COMBAT,
    level_required = 2,
    knowledge_cost = 1,
    cooldown = 6.0,
    cost_type = Arcane.COST_TYPES.COINS,
    cost_amount = 25,
    cast_time = 1.0,
    range = 1500,
    icon = "icon16/weather_lightning.png",
    has_target = true,

    cast = function(caster, _, _, ctx)
        if not SERVER then return true end

        local pos = (ctx and ctx.circlePos) or getAimGround(caster, 1500)
        local cloud = ents.Create("prop_physics")
        if not IsValid(cloud) then return false end
        cloud:SetModel("models/hunter/misc/sphere075x075.mdl")
        cloud:SetPos(pos + Vector(0, 0, 300))
        cloud:Spawn()
        cloud:SetColor(Color(160, 160, 180, 140))
        cloud:SetRenderMode(RENDERMODE_TRANSALPHA)
        local phys = cloud:GetPhysicsObject()
        if IsValid(phys) then phys:EnableMotion(false) end

        local strikes = 3
        local function doStrike()
            if not IsValid(cloud) then return end
            local strikePos = pos
            -- Trace down to find hit point
            local tr = util.TraceLine({ start = cloud:GetPos(), endpos = strikePos, filter = caster })
            local hitPos = tr.Hit and tr.HitPos or (pos + Vector(0, 0, 8))

            -- Damage beam area
            util.BlastDamage(cloud, caster, hitPos, 140, 45)
            for _, v in ipairs(ents.FindInSphere(hitPos, 140)) do
                if IsValid(v) and (v:IsPlayer() or v:IsNPC()) then
                    v:TakeDamage(15, caster, cloud)
                end
            end

            -- Visual: beam
            local ed = EffectData()
            ed:SetOrigin(hitPos)
            util.Effect("cball_explode", ed, true, true)
            sound.Play("ambient/energy/zap" .. math.random(1, 9) .. ".wav", hitPos, 90, 100)
        end

        for i = 0, strikes - 1 do
            timer.Simple(0.25 * i, doStrike)
        end

        -- VFX halo life
        timer.Simple(1.2, function()
            if IsValid(cloud) then cloud:Remove() end
        end)

        return true
    end
})


