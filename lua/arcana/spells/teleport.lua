-- Teleport (Blink)
-- Quickly relocate to the point you're aiming at, clamped to range and validated with a hull trace

-- Find a good destination based on aim and ensure player hull fits there.
local function findSafeTeleportDestination(ply, maxRange)
    local eyePos = ply:EyePos()
    local aimDir = ply:GetAimVector()

    -- First, trace along aim to find a candidate point
    local trAim = util.TraceLine({
        start = eyePos,
        endpos = eyePos + aimDir * maxRange,
        mask = MASK_SHOT,
        filter = ply
    })

    local hitPos = trAim.Hit and trAim.HitPos or (eyePos + aimDir * math.min(maxRange, 1000))
    local hitNormal = trAim.Hit and trAim.HitNormal or Vector(0, 0, 1)

    -- Project down to ground to avoid hovering in air
    local trDown = util.TraceLine({
        start = hitPos + Vector(0, 0, 256),
        endpos = hitPos - Vector(0, 0, 1024),
        mask = MASK_PLAYERSOLID_BRUSHONLY,
        filter = ply
    })

    local groundPos = trDown.Hit and trDown.HitPos or hitPos
    local groundNormal = trDown.Hit and trDown.HitNormal or hitNormal

    -- Slightly offset upward and away from the surface
    local desired = groundPos + groundNormal * 2

    -- Use player collision bounds for a hull fit test
    local mins, maxs = ply:OBBMins(), ply:OBBMaxs()
    -- Clamp mins to not go below feet too much
    mins = Vector(mins.x, mins.y, math.max(mins.z, 0))

    local function hullClearAt(pos)
        local tr = util.TraceHull({
            start = pos,
            endpos = pos,
            mins = mins,
            maxs = maxs,
            mask = MASK_PLAYERSOLID,
            filter = ply
        })
        return not tr.Hit
    end

    -- Try a few adjustments to find a clear spot
    local attempts = {}
    attempts[#attempts + 1] = desired
    attempts[#attempts + 1] = desired + aimDir * 12
    attempts[#attempts + 1] = desired - aimDir * 12
    attempts[#attempts + 1] = desired + Vector(0, 0, 12)
    attempts[#attempts + 1] = desired + Vector(0, 0, 24)

    -- Radial nudge attempts around the aim direction
    for i = 1, 8 do
        local ang = (i / 8) * math.pi * 2
        local offset = Vector(math.cos(ang), math.sin(ang), 0) * 16
        attempts[#attempts + 1] = desired + offset
        attempts[#attempts + 1] = desired + offset + Vector(0, 0, 12)
    end

    for _, pos in ipairs(attempts) do
        if hullClearAt(pos) then
            return pos
        end
    end

    return nil
end

Arcane:RegisterSpell({
    id = "teleport",
    name = "Teleport",
    description = "Blink to your aim point within range, finding a safe landing spot",
    category = Arcane.CATEGORIES.UTILITY,
    level_required = 2,
    knowledge_cost = 1,
    cooldown = 0.1,
    cost_type = Arcane.COST_TYPES.COINS,
    cost_amount = 30,
    cast_time = 0.1,
    range = 0,
    icon = "icon16/arrow_right.png",
    has_target = false,
    cast_anim = "becon",

    can_cast = function(caster)
        if caster:InVehicle() then
            return false, "Cannot teleport while in a vehicle"
        end
        return true
    end,

    cast = function(caster, _, _, _)
        if not SERVER then return true end

        local dest = findSafeTeleportDestination(caster, 1200)
        if not dest then
            caster:EmitSound("buttons/button8.wav", 70, 100)
            return false
        end

        local oldPos = caster:GetPos()

        -- Departure effects
        do
            local ed = EffectData()
            ed:SetOrigin(oldPos + Vector(0, 0, 4))
            util.Effect("cball_explode", ed, true, true)
            sound.Play("ambient/machines/teleport3.wav", oldPos, 80, 110)
        end

        -- Actually move the player, zero their velocity, and ensure not stuck
        caster:SetVelocity(-caster:GetVelocity())
        caster:SetPos(dest)
        caster:SetGroundEntity(NULL)

        -- Arrival effects
        do
            local ed = EffectData()
            ed:SetOrigin(dest + Vector(0, 0, 4))
            util.Effect("cball_explode", ed, true, true)
            util.ScreenShake(dest, 2, 40, 0.25, 256)
            sound.Play("ambient/machines/teleport1.wav", dest, 80, 100)
        end

        -- Brief protective shimmer using band VFX
        Arcane:SendAttachBandVFX(caster, Color(140, 200, 255, 255), 26, 1.2, {
            { radius = 20, height = 3, spin = {p = 0, y = 140, r = 0}, lineWidth = 2 },
        })

        return true
    end
})

if CLIENT then
    -- Show a small targeting circle at the prospective landing spot while casting
    hook.Add("Arcane_BeginCastingVisuals", "Arcana_Teleport_Circle", function(caster, spellId, castTime, _forwardLike)
        if spellId ~= "teleport" then return end
        if not MagicCircle then return end

        local pos = findSafeTeleportDestination(caster, 1200) or (caster:GetPos() + Vector(0, 0, 2))
        local ang = Angle(0, 0, 0)
        local color = Color(140, 200, 255, 255)
        local size = 18
        local intensity = 3

        local circle = MagicCircle.CreateMagicCircle(pos, ang, color, intensity, size, castTime, 2)
        if not circle then return end
        if circle.StartEvolving then circle:StartEvolving(castTime, true) end

        local hookName = "Arcana_TP_CircleFollow_" .. tostring(circle)
        local endTime = CurTime() + castTime + 0.05
        hook.Add("Think", hookName, function()
            if not IsValid(caster) or not circle or (circle.IsActive and not circle:IsActive()) or CurTime() > endTime then
                hook.Remove("Think", hookName)
                return
            end
            local p = findSafeTeleportDestination(caster, 1200)
            if p then
                circle.position = p + Vector(0, 0, 0.5)
                circle.angles = Angle(0, 0, 0)
            end
        end)
    end)
end


