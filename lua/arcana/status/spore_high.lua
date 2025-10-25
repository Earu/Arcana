-- Shared SporeHigh status: psychedelic trip from consuming solidified spores
Arcane = Arcane or {}
Arcane.Status = Arcane.Status or {}

local SporeHigh = {}

if SERVER then
    util.AddNetworkString("Arcana_SporeHigh_Start")
end

-- options: duration (45), intensity (1.0)
function SporeHigh.Apply(target, options)
    if not IsValid(target) then return end
    options = options or {}
    local duration = tonumber(options.duration) or 45
    local intensity = tonumber(options.intensity) or 1.0

    if target:IsPlayer() then
        target._ArcanaSporeHighUntil = math.max(target._ArcanaSporeHighUntil or 0, CurTime() + duration)

        if SERVER then
            net.Start("Arcana_SporeHigh_Start", true)
            net.WriteFloat(duration)
            net.WriteFloat(intensity)
            net.Send(target)
        end
    end
end

Arcane.Status.SporeHigh = SporeHigh

if CLIENT then
    local active = false
    local endTime = 0
    local startTime = 0
    local mult = 1

    net.Receive("Arcana_SporeHigh_Start", function()
        local dur = net.ReadFloat() or 45
        local k = net.ReadFloat() or 1
        startTime = CurTime()
        endTime = startTime + dur
        mult = math.max(0.1, k)
        active = true

        local lp = LocalPlayer()
        if IsValid(lp) then
            lp:EmitSound("ambient/levels/citadel/weapon_disintegrate3.wav", 70, 150, 0.65)
            lp:SetDSP(33, true)
        end
    end)

    local function frac()
        if not active then return 0 end
        local now = CurTime()
        if now >= endTime then return 0 end
        local total = math.max(0.001, endTime - startTime)
        local tcur = math.Clamp(now - startTime, 0, total)
        local rise = math.Clamp(tcur / math.min(4, total * 0.25), 0, 1)
        local fall = math.Clamp((endTime - now) / math.min(4, total * 0.25), 0, 1)
        return math.min(rise, fall)
    end

    hook.Add("RenderScreenspaceEffects", "Arcana_SporeHigh_SSE", function()
        if not active then return end
        local f = frac()
        if f <= 0 then return end
        local ct = CurTime()
        local m = f * mult
        DrawColorModify({
            ["$pp_colour_addr"] = 0.05 * m + 0.03 * math.sin(ct * 1.0) * m,
            ["$pp_colour_addg"] = 0.08 * m + 0.04 * math.sin(ct * 1.7) * m,
            ["$pp_colour_addb"] = 0.10 * m + 0.05 * math.sin(ct * 2.3) * m,
            ["$pp_colour_brightness"] = 0.04 * m,
            ["$pp_colour_contrast"] = 1.05 + 0.4 * m,
            ["$pp_colour_colour"] = 1.6 + 1.0 * m,
            ["$pp_colour_mulr"] = 0.2 * m,
            ["$pp_colour_mulg"] = 0.2 * m,
            ["$pp_colour_mulb"] = 0.3 * m
        })
        DrawSharpen(0.8 * m, 1.0 * m)
        DrawBloom(0.25, 1.8 + 2.2 * m, 6 + 6 * m, 6 + 6 * m, 1.5 + 1.5 * m, 1, 0.9, 1.0, 0.9)
        DrawSobel(0.15 + 1.2 * m)
        DrawMotionBlur(0.1 + 0.18 * m, 0.85, 0.06 + 0.08 * m)
    end)

    hook.Add("CalcView", "Arcana_SporeHigh_View", function(ply, origin, angles, fov)
        if not active then return end
        local f = frac()
        if f <= 0 then return end
        local t = CurTime()
        local m = f * mult
        local ang = Angle(angles)
        ang:RotateAroundAxis(ang:Forward(), math.sin(t * 0.7) * 3.0 * m)
        ang:RotateAroundAxis(ang:Right(), math.sin(t * 1.4) * 2.5 * m)
        ang:RotateAroundAxis(ang:Up(), math.sin(t * 0.5) * 1.6 * m)
        local off = angles:Forward() * math.sin(t * 1.1) * 2.0 * m
        off = off + angles:Right() * math.sin(t * 0.6) * 1.6 * m
        off = off + angles:Up() * math.sin(t * 1.6) * 1.8 * m
        local newFov = fov + math.sin(t * 0.8) * 6.0 * m
        return {origin = origin + off, angles = ang, fov = newFov}
    end)

    hook.Add("Think", "Arcana_SporeHigh_Tick", function()
        if active and CurTime() >= endTime then
            active = false
            local lp = LocalPlayer()
            if IsValid(lp) then lp:SetDSP(0, false) end
        end
    end)
end


