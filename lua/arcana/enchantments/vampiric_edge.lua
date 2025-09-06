-- Vampiric Edge: Melee-only enchantment that regenerates health on hit
local function isMeleeHoldType(wep)
    if not IsValid(wep) then return false end

    local ht = (wep.GetHoldType and wep:GetHoldType()) or wep.HoldType
    if not isstring(ht) then return false end

    ht = string.lower(ht)
    return ht == "melee" or ht == "melee2" or ht == "knife" or ht == "fist"
end

local function isMeleeDamage(dmginfo)
    if not dmginfo then return false end
    local dt = dmginfo:GetDamageType()
    -- Consider common melee flags
    return bit.band(dt, DMG_CLUB) ~= 0 or bit.band(dt, DMG_SLASH) ~= 0 or bit.band(dt, DMG_GENERIC) ~= 0
end

local function healAttacker(attacker, amount)
    if not IsValid(attacker) or not attacker:IsPlayer() then return end
    if amount <= 0 then return end
    local max = attacker.GetMaxHealth and attacker:GetMaxHealth() or 100
    local newHealth = math.min(attacker:Health() + amount, max)
    attacker:SetHealth(newHealth)

    -- Brief crimson ring feedback
    if Arcane and Arcane.SendAttachBandVFX then
        Arcane:SendAttachBandVFX(attacker, Color(200, 30, 60, 255), 20, 0.25, {
            { radius = 14, height = 3, spin = { p = 0, y = 300 * 50, r = 0 }, lineWidth = 2 },
        }, "vampiric_heal")
    end
end

local function attachHook(ply, wep, state)
    if not IsValid(ply) or not IsValid(wep) then return end

    state._hookId = string.format("Arcana_Ench_VampiricEdge_%d_%d", wep:EntIndex(), ply:EntIndex())
    state._nextHeal = 0

    hook.Add("EntityTakeDamage", state._hookId, function(target, dmginfo)
        if not IsValid(target) or not dmginfo then return end

        local attacker = dmginfo:GetAttacker()
        if not IsValid(attacker) or not attacker:IsPlayer() then return end

        -- Must be this weapon's wielder and this specific weapon currently active
        if attacker ~= ply then return end

        local active = attacker:GetActiveWeapon()
        if not IsValid(active) or active ~= wep then return end
        if not isMeleeHoldType(wep) then return end
        if not isMeleeDamage(dmginfo) then return end

        local now = CurTime()
        if now < (state._nextHeal or 0) then return end
        -- Small internal cooldown to avoid multiple triggers per swing
        state._nextHeal = now + 0.10

        local dealt = math.max(0, tonumber(dmginfo:GetDamage() or 0) or 0)
        if dealt <= 0 then return end

        -- Heal for 75% of dealt damage, at least 1, capped to 15 per trigger
        local heal = math.floor(math.Clamp(dealt * 0.75, 1, 15))
        healAttacker(attacker, heal)
    end)
end

local function detachHook(ply, wep, state)
    if not state or not state._hookId then return end
    hook.Remove("EntityTakeDamage", state._hookId)
    state._hookId = nil
end

Arcane:RegisterEnchantment({
    id = "vampiric_edge",
    name = "Vampiric Edge",
    description = "Melee hits restore health based on damage dealt.",
    icon = "icon16/heart.png",
    cost_coins = 1200,
    cost_items = {
        { name = "mana_crystal_shard", amount = 40 },
    },
    can_apply = function(ply, wep)
        return IsValid(wep) and isMeleeHoldType(wep)
    end,
    apply = attachHook,
    remove = detachHook,
})


