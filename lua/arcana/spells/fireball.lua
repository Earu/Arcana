Arcane:RegisterSpell({
    id = "fireball",
    name = "Fireball",
    description = "Launch a blazing orb that explodes and ignites on impact",
    category = Arcane.CATEGORIES.COMBAT,
    level_required = 1,
    knowledge_cost = 1,
    cooldown = 3.0,
    cost_type = Arcane.COST_TYPES.COINS,
    cost_amount = 20,
    cast_time = 1.0,
    range = 1200,
    icon = "icon16/fire.png",
    is_projectile = true,
    has_target = true,

    cast = function(caster, _, _, ctx)
        if not SERVER then return true end

        local startPos
        if ctx and ctx.circlePos then
            startPos = ctx.circlePos + caster:GetForward() * 5
        else
            startPos = caster:WorldSpaceCenter() + caster:GetForward() * 25
        end

        local ent = ents.Create("arcana_fireball")
        if not IsValid(ent) then return false end
        ent:SetPos(startPos)
        ent:Spawn()
        ent:SetOwner(caster)
        if ent.SetSpellOwner then ent:SetSpellOwner(caster) end
        if ent.CPPISetOwner then ent:CPPISetOwner(caster) end

        if ent.LaunchTowards then ent:LaunchTowards(caster:GetAimVector()) end

        Arcane:SendAttachBandVFX(ent, Color(255, 150, 80, 255), 14, 6, {
            { radius = 15, height = 4, spin = {p = 0, y = 80 * 50, r = 60 * 50}, lineWidth = 2 },
            { radius = 13, height = 3, spin = {p = 60 * 50, y = -45 * 50, r = 0}, lineWidth = 2 },
        })

        caster:EmitSound("weapons/gauss/fire1.wav", 70, 90)
        return true
    end
})


