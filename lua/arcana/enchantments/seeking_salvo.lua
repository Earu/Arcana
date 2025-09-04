-- Arcane Missiles Rounds: On firearm shot, launch three homing arcane missiles toward your aim
-- Adapted from spells/arcane_missiles.lua and existing enchantment hook patterns

local function isMeleeHoldType(wep)
    if not IsValid(wep) then return false end

    local ht = (wep.GetHoldType and wep:GetHoldType()) or wep.HoldType
    if not isstring(ht) then return false end

    ht = string.lower(ht)
    return ht == "melee" or ht == "melee2" or ht == "knife" or ht == "fist"
end

local function selectBestTarget(origin, aim, caster)
    local best, bestDot = nil, -1
    local maxRange = 1600
    for _, ent in ipairs(ents.FindInSphere(origin + aim * (maxRange * 0.6), maxRange)) do
        if not IsValid(ent) or ent == caster then continue end
        if not (ent:IsPlayer() or ent:IsNPC()) then continue end
        if ent:Health() <= 0 then continue end
        local dir = (ent:WorldSpaceCenter() - origin):GetNormalized()
        local d = dir:Dot(aim)
        if d > bestDot then
            bestDot, best = d, ent
        end
    end
    return best
end

local function attachHook(ply, wep, state)
    if not IsValid(ply) or not IsValid(wep) then return end

    state._hookId = string.format("Arcana_Ench_SeekingSalvo_%d_%d", wep:EntIndex(), ply:EntIndex())
    hook.Add("EntityFireBullets", state._hookId, function(ent, data)
        if not IsValid(ent) or not ent:IsPlayer() then return end

        local active = ent:GetActiveWeapon()
        if not IsValid(active) or active ~= wep then return end

        -- Rate limit to avoid excessive missile spam on very high ROF weapons
        local now = CurTime()
        state._next = state._next or 0
        if now < state._next then return end
        state._next = now + 0.6

        local caster = ent
        local origin = caster:GetShootPos()
        local aim = caster:GetAimVector()

        local best = selectBestTarget(origin, aim, caster)

        for i = 1, 3 do
            timer.Simple(0.06 * (i - 1), function()
                if not IsValid(caster) then return end
                local missile = ents.Create("arcana_missile")
                if not IsValid(missile) then return end
                missile:SetPos(origin + aim * 12 + caster:GetRight() * ((i - 2) * 6) + caster:GetUp() * (i == 2 and 0 or 2))
                missile:SetAngles(aim:Angle())
                missile:Spawn()
                missile:SetOwner(caster)

                if missile.SetSpellOwner then missile:SetSpellOwner(caster) end
                if missile.CPPISetOwner then missile:CPPISetOwner(caster) end
                if IsValid(best) and missile.SetHomingTarget then missile:SetHomingTarget(best) end
            end)
        end

        sound.Play("weapons/physcannon/energy_sing_flyby1.wav", origin, 70, 160)
    end)
end

local function detachHook(ply, wep, state)
    if not state or not state._hookId then return end
    hook.Remove("EntityFireBullets", state._hookId)
    state._hookId = nil
end

Arcane:RegisterEnchantment({
    id = "seeking_salvo",
    name = "Seeking Salvo",
    description = "On shot, launches three homing arcane missiles toward your aim.",
    icon = "icon16/wand.png",
    cost_coins = 1500,
    cost_items = {
        { name = "mana_crystal_shard", amount = 60 },
    },
    can_apply = function(ply, wep)
        -- Firearms that can shoot bullets (exclude melee)
        return IsValid(wep) and (wep.Primary ~= nil or wep.FireBullets ~= nil) and not isMeleeHoldType(wep)
    end,
    apply = attachHook,
    remove = detachHook,
})


