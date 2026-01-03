local COOLDOWN_TIME = (20 * 60)

if Arcane then
        local ACCEPTABLE_SURFACE_TYPES = {
                [MAT_GRASS] = true,
                [MAT_DIRT] = true,
                [MAT_SAND] = true,
                [MAT_SNOW] = true,
        }

        Arcane:RegisterRitualSpell({
                id = "ritual_magical_mushroom",
                name = "Ritual: Magical Mushroom",
                description = "Summons a magical mushroom.",
                category = Arcane.CATEGORIES.UTILITY,
                level_required = 15,
                knowledge_cost = 3,
                cooldown = COOLDOWN_TIME,
                cost_type = Arcane.COST_TYPES.COINS,
                cost_amount = 3000,
                cast_time = 4.0,
                ritual_color = Color(50, 130, 50),
                ritual_items = {
                        solidified_spores = 3
                },
                can_cast = function(caster)
                        local tr = caster:GetEyeTrace()
                        if not tr.Hit or not ACCEPTABLE_SURFACE_TYPES[tr.MatType] then
                                return false,
                                    "This ritual may only be cast on grass, dirt, sand, or snow terrain."
                        end

                        return true
                end,
                on_activate = function(selfEnt, activatingPly, caster)
                        if not SERVER then return end

                        local ok = false
                        local mushroom = ents.Create("arcana_magical_mushroom")
                        if IsValid(mushroom) and IsValid(caster) then
                                mushroom:SetPos(selfEnt:GetPos() - Vector(0, 0, 80))
                                mushroom:CPPISetOwner(caster)
                                mushroom:Spawn()
                                ok = true
                                timer.Simple(COOLDOWN_TIME, function()
                                        if IsValid(mushroom) then
                                                mushroom:Remove()
                                        end
                                end)
                        end

                        if not ok then
                                Arcane:SendErrorNotification(activatingPly, "Ritual failed: Mushroom was not summoned")
                                return
                        end

                        selfEnt:EmitSound("ambient/levels/citadel/strange_talk5.wav", 70, 110)
                end,
        })
end
