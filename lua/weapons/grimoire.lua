if SERVER then
    AddCSLuaFile()
    resource.AddFile("models/arcana/models/arcana/Grimoire.mdl")
    resource.AddFile("materials/models/arcana/catalyst_apprentice.vmt")
    resource.AddFile("materials/entities/grimoire.png")
end

SWEP.PrintName = "Grimoire"
SWEP.Author = "Earu"
SWEP.Purpose = "A mystical tome containing powerful spells and rituals"
SWEP.Instructions = "LMB: Cast | RMB: Open Grimoire | R: Quick Radial"

SWEP.Spawnable = true
SWEP.AdminOnly = false

-- Use the default citizen arms as the first-person viewmodel and draw the
-- grimoire ourselves attached to the right hand. Using the world model as a
-- viewmodel makes it float in the camera.
SWEP.ViewModel = "models/weapons/c_arms_citizen.mdl"
SWEP.WorldModel = "models/arcana/models/arcana/Grimoire.mdl"
SWEP.ViewModelFOV = 62
SWEP.UseHands = true

SWEP.Primary.ClipSize = -1
SWEP.Primary.DefaultClip = -1
SWEP.Primary.Automatic = false
SWEP.Primary.Ammo = "none"

SWEP.Secondary.ClipSize = -1
SWEP.Secondary.DefaultClip = -1
SWEP.Secondary.Automatic = false
SWEP.Secondary.Ammo = "none"

SWEP.Weight = 3
SWEP.AutoSwitchTo = false
SWEP.AutoSwitchFrom = false

SWEP.Slot = 0
SWEP.SlotPos = 1
SWEP.DrawAmmo = false
SWEP.DrawCrosshair = true

SWEP.HoldType = "slam"

-- Grimoire-specific properties
SWEP.SelectedSpell = "fireball"
SWEP.MenuOpen = false
SWEP.RadialOpen = false
SWEP.RadialHoverSlot = nil
SWEP.RadialOpenTime = 0

function SWEP:Initialize()
    self:SetWeaponHoldType(self.HoldType)

    -- Store active magic circle reference
    self.ActiveMagicCircle = nil
end

function SWEP:Deploy()
    return true
end

function SWEP:Holster()
    if CLIENT then
        self.MenuOpen = false
        if self.RadialOpen then
            gui.EnableScreenClicker(false)
            self.RadialOpen = false
            self.RadialHoverSlot = nil
        end
        -- Clean up any active magic circle
        if self.ActiveMagicCircle and IsValid(self.ActiveMagicCircle) then
            self.ActiveMagicCircle:Destroy()
            self.ActiveMagicCircle = nil
        end
    end
    return true
end

function SWEP:PrimaryAttack()
    if not Arcane then return end

    local owner = self:GetOwner()
    if not IsValid(owner) or not owner:IsPlayer() then return end

    -- Resolve selected spell from quickslot if present
    local selectedSpellId = self.SelectedSpell
    local pdata = Arcane:GetPlayerData(owner)
    if pdata then
        local qsIndex = math.Clamp(pdata.selected_quickslot or 1, 1, 8)
        selectedSpellId = pdata.quickspell_slots[qsIndex] or selectedSpellId
        self.SelectedSpell = selectedSpellId
    end

    if not selectedSpellId then
        if CLIENT and IsFirstTimePredicted() then
            owner:ChatPrint("❌ No spell selected!")
        end
        return
    end

    -- Check if spell exists and is unlocked
    local spell = Arcane.RegisteredSpells[selectedSpellId]
    if not spell then
        if CLIENT and IsFirstTimePredicted() then
            owner:ChatPrint("❌ Unknown spell: " .. tostring(selectedSpellId))
        end
        return
    end

    if not owner:HasSpellUnlocked(selectedSpellId) then
        if CLIENT and IsFirstTimePredicted() then
            owner:ChatPrint("❌ Spell not unlocked: " .. spell.name)
        end
        return
    end

    -- Begin casting (server schedules execution after cast time)
    if SERVER then
        Arcane:StartCasting(owner, selectedSpellId)
        local castTime = math.max(1, spell.cast_time or 0)
        local totalDelay = castTime + (spell.cooldown or 1.0)
        self:SetNextPrimaryFire(CurTime() + totalDelay)
    else
        -- Client prediction: throttle based on minimum cast time
        local castTime = math.max(1, spell.cast_time or 0)
        self:SetNextPrimaryFire(CurTime() + castTime)
    end

    -- Magic circle visuals now handled via networked casting in core
end

function SWEP:SecondaryAttack()
    if CLIENT and IsFirstTimePredicted() then
        self:OpenGrimoireMenu()
    end

    self:SetNextSecondaryFire(CurTime() + 0.5)
end

function SWEP:Reload()
    if not Arcane then return false end

    local owner = self:GetOwner()
    if not IsValid(owner) or not owner:IsPlayer() then return false end

    if CLIENT and IsFirstTimePredicted() then
        self:ToggleRadialMenu()
    end

    return false
end

function SWEP:Think()
    -- Continuous grimoire effects could go here
    -- For example, subtle magical particles or glowing effects
end

-- World model attachment to player's right hand
-- Tweak these offsets if the book does not sit perfectly in the hand
SWEP.WorldModelOffset = {
    pos = Vector(-1, -2, 0),
    ang = Angle(-90, 180, 180), -- pitch, yaw, roll adjustments relative to the hand bone
    size = 0.8 -- size of the world model
}

-- First-person (viewmodel) placement for the clientside grimoire model
SWEP.ViewModelOffset = {
    -- tweak these to taste; units are in viewmodel local space
    pos = Vector(3.2, 1.2, -2.0),
    -- rotate so the book sits naturally in the palm
    ang = Angle(0, -90, 0),
    size = 0.85
}

function SWEP:DrawWorldModel()
    local owner = self:GetOwner()

    if IsValid(owner) then
        -- Prefer a hand attachment if available, fall back to the hand bone
        local attId = owner:LookupAttachment("anim_attachment_RH") or owner:LookupAttachment("Anim_Attachment_RH")
        if attId and attId > 0 then
            local att = owner:GetAttachment(attId)
            if att then
                local pos = att.Pos
                local ang = att.Ang

                -- Apply positional offset in the bone's local space
                pos = pos
                    + ang:Forward() * (self.WorldModelOffset.pos.x or 0)
                    + ang:Right()   * (self.WorldModelOffset.pos.y or 0)
                    + ang:Up()      * (self.WorldModelOffset.pos.z or 0)

                -- Apply angular offsets
                local a = self.WorldModelOffset.ang or angle_zero
                if a then
                    ang:RotateAroundAxis(ang:Up(), a.y or 0)
                    ang:RotateAroundAxis(ang:Right(), a.p or 0)
                    ang:RotateAroundAxis(ang:Forward(), a.r or 0)
                end

                self:SetRenderOrigin(pos)
                self:SetRenderAngles(ang)
                self:SetModelScale(self.WorldModelOffset.size or 1.0)
                self:DrawModel()
                self:SetRenderOrigin()
                self:SetRenderAngles()
                return
            end
        end

        local boneId = owner:LookupBone("ValveBiped.Bip01_R_Hand")
        if boneId then
            local matrix = owner:GetBoneMatrix(boneId)
            if matrix then
                local pos = matrix:GetTranslation()
                local ang = matrix:GetAngles()

                -- Apply positional offset in the bone's local space
                pos = pos
                    + ang:Forward() * (self.WorldModelOffset.pos.x or 0)
                    + ang:Right()   * (self.WorldModelOffset.pos.y or 0)
                    + ang:Up()      * (self.WorldModelOffset.pos.z or 0)

                -- Apply angular offsets
                local a = self.WorldModelOffset.ang or angle_zero
                if a then
                    ang:RotateAroundAxis(ang:Up(), a.y or 0)
                    ang:RotateAroundAxis(ang:Right(), a.p or 0)
                    ang:RotateAroundAxis(ang:Forward(), a.r or 0)
                end

                self:SetRenderOrigin(pos)
                self:SetRenderAngles(ang)
                self:SetModelScale(self.WorldModelOffset.size or 1.0)
                self:DrawModel()
                self:SetRenderOrigin()
                self:SetRenderAngles()
                return
            end
        end
    end

    -- Fallback if owner/bone is unavailable
    self:DrawModel()
end

-- Get available spells for the player
function SWEP:GetAvailableSpells()
    if not Arcane then return {} end

    local owner = self:GetOwner()
    if not IsValid(owner) or not owner:IsPlayer() then return {} end

    local availableSpells = {}

    for spellId, spell in pairs(Arcane.RegisteredSpells) do
        if owner:HasSpellUnlocked(spellId) then
            table.insert(availableSpells, {
                id = spellId,
                spell = spell
            })
        end
    end

    -- Sort by level requirement
    table.sort(availableSpells, function(a, b)
        return a.spell.level_required < b.spell.level_required
    end)

    return availableSpells
end

-- Cycle through available spells
function SWEP:CycleSpells()
    local availableSpells = self:GetAvailableSpells()
    if #availableSpells == 0 then return end

    local currentIndex = 1
    for i, spellData in ipairs(availableSpells) do
        if spellData.id == self.SelectedSpell then
            currentIndex = i
            break
        end
    end

    local nextIndex = (currentIndex % #availableSpells) + 1
    self.SelectedSpell = availableSpells[nextIndex].id
end

function SWEP:DrawHUD()
    if not Arcane then return end

    local owner = self:GetOwner()
    if not IsValid(owner) or not owner:IsPlayer() then return end

    local scrW, scrH = ScrW(), ScrH()

    -- Radial quickslot menu
    if self.RadialOpen then
        self:DrawQuickRadial(scrW, scrH, owner)
    end
end

-- Client-side grimoire menu
if CLIENT then
    ---------------------------------------------------------------------------
    -- First-person rendering of the grimoire attached to the right hand
    ---------------------------------------------------------------------------
    function SWEP:EnsureViewModelBook()
        if IsValid(self.VMBook) then return end
        self.VMBook = ClientsideModel(self.WorldModel)
        if not IsValid(self.VMBook) then return end
        self.VMBook:SetNoDraw(true)
    end

    function SWEP:PostDrawViewModel(vm, weapon, ply)
        -- Ensure we have a book model to draw
        self:EnsureViewModelBook()
        if not IsValid(self.VMBook) then return end

        local boneId = vm:LookupBone("ValveBiped.Bip01_R_Hand")
        if not boneId then return end

        local matrix = vm:GetBoneMatrix(boneId)
        if not matrix then return end

        local pos = matrix:GetTranslation()
        local ang = matrix:GetAngles()

        -- Apply positional offset in the hand's local space
        pos = pos
            + ang:Forward() * (self.ViewModelOffset.pos.x or 0)
            + ang:Right()   * (self.ViewModelOffset.pos.y or 0)
            + ang:Up()      * (self.ViewModelOffset.pos.z or 0)

        -- Apply angular offsets
        local a = self.ViewModelOffset.ang or angle_zero
        if a then
            ang:RotateAroundAxis(ang:Up(), a.y or 0)
            ang:RotateAroundAxis(ang:Right(), a.p or 0)
            ang:RotateAroundAxis(ang:Forward(), a.r or 0)
        end

        self.VMBook:SetRenderOrigin(pos)
        self.VMBook:SetRenderAngles(ang)
        self.VMBook:SetModelScale(self.ViewModelOffset.size or 1.0, 0)
        self.VMBook:DrawModel()
        self.VMBook:SetRenderOrigin()
        self.VMBook:SetRenderAngles()
    end

    -- Clean up clientside book when the weapon is hidden/removed
    function SWEP:OnRemove()
        if IsValid(self.VMBook) then
            self.VMBook:Remove()
            self.VMBook = nil
        end
    end

    function SWEP:ViewModelDrawn(vm)
        -- Explicitly keep default vm drawing (hands) enabled; book is drawn
        -- in PostDrawViewModel above.
    end

    -- Fonts (Art-Deco / Fantasy inspired). Falls back if font not available.
    surface.CreateFont("Arcana_AncientSmall", {font = "Georgia", size = 16, weight = 600, antialias = true, extended = true})
    surface.CreateFont("Arcana_Ancient", {font = "Georgia", size = 20, weight = 700, antialias = true, extended = true})
    surface.CreateFont("Arcana_AncientLarge", {font = "Georgia", size = 24, weight = 800, antialias = true, extended = true})
    surface.CreateFont("Arcana_DecoTitle", {font = "Georgia", size = 26, weight = 900, antialias = true, extended = true})

    -- Palette tuned to the grimoire model (warm leather + brass)
    local decoBg = Color(26, 20, 14, 235)          -- deep leather brown
    local decoPanel = Color(32, 24, 18, 235)       -- panel leather
    local gold = Color(198, 160, 74, 255)          -- brass gold
    local paleGold = Color(222, 198, 120, 255)     -- soft brass
    local textBright = Color(236, 230, 220, 255)   -- parchment white
    local textDim = Color(180, 170, 150, 255)      -- muted parchment

    -- Derived colors (centralize all manual Color usage)
    local brassInner = Color(160, 130, 60, 220)
    local backDim = Color(0, 0, 0, 140)
    -- Card/row leather tones (reduce any purple cast)
    local cardIdle = Color(46, 36, 26, 235)
    local cardHover = Color(58, 44, 32, 235)
    local chipTextCol = Color(24, 26, 36, 230)
    local wedgeIdleFill = Color(gold.r, gold.g, gold.b, 24)
    local wedgeHoverFill = Color(gold.r, gold.g, gold.b, 70)
    local xpFill = Color(paleGold.r, paleGold.g, paleGold.b, 180)

    -- Modern blur helper (robust, with fallback if material missing)
    local blurMat = Material("pp/blurscreen")
    local function Arcana_DrawBlurRect(x, y, w, h, layers, density, alpha)
        surface.SetMaterial(blurMat)
        surface.SetDrawColor(255, 255, 255)

        render.SetScissorRect(x, y, x + w, y + h, true)
            for i = 1, layers do
                blurMat:SetFloat("$blur", (i / layers) * density)
                blurMat:Recompute()

                render.UpdateScreenEffectTexture()
                surface.DrawTexturedRect(0, 0, ScrW(), ScrH())
            end
        render.SetScissorRect(0, 0, 0, 0, false)
    end

    -- Thin gold deco frame with clipped corners + center diamond accents
    local function Arcana_DrawDecoFrame(x, y, w, h, col, corner)
        local c = math.max(8, corner or 12)
        surface.SetDrawColor(col.r, col.g, col.b, col.a or 255)
        -- Outer rectangle with cut corners
        surface.DrawLine(x + c, y, x + w - c, y)
        surface.DrawLine(x + w, y + c, x + w, y + h - c)
        surface.DrawLine(x + w - c, y + h, x + c, y + h)
        surface.DrawLine(x, y + h - c, x, y + c)
        -- Corner slants
        surface.DrawLine(x, y + c, x + c, y)
        surface.DrawLine(x + w - c, y, x + w, y + c)
        surface.DrawLine(x + w, y + h - c, x + w - c, y + h)
        surface.DrawLine(x + c, y + h, x, y + h - c)
        -- Small center diamond accents mid-top and mid-bottom
        local mx = x + w * 0.5
        local dy = 6
        surface.DisableClipping(true)
        surface.DrawLine(mx - dy, y, mx, y - dy)
        surface.DrawLine(mx, y - dy, mx + dy, y)
        surface.DrawLine(mx - dy, y + h, mx, y + h + dy)
        surface.DrawLine(mx, y + h + dy, mx + dy, y + h)
        surface.DisableClipping(false)
    end

    -- Filled panel that matches the clipped-corner frame geometry
    local function Arcana_FillDecoPanel(x, y, w, h, col, corner)
        local c = math.max(8, corner or 12)
        draw.NoTexture()
        surface.SetDrawColor(col.r, col.g, col.b, col.a or 255)
        local pts = {
            { x = x + c, y = y },
            { x = x + w - c, y = y },
            { x = x + w, y = y + c },
            { x = x + w, y = y + h - c },
            { x = x + w - c, y = y + h },
            { x = x + c, y = y + h },
            { x = x, y = y + h - c },
            { x = x, y = y + c },
        }
        surface.DrawPoly(pts)
    end

    -- Simple circle outline helper
    local function Arcana_DrawCircle(cx, cy, radius, thickness, col)
        surface.SetDrawColor(col.r, col.g, col.b, col.a or 255)
        for r = radius - (thickness or 1), radius + (thickness or 1) do
            surface.DrawCircle(cx, cy, r, col.r, col.g, col.b, col.a or 255)
        end
    end

    -- Donut wedge fill helper for radial highlight
    local function Arcana_DrawWedge(cx, cy, rInner, rOuter, ang0Deg, ang1Deg, color, segments)
        local seg = math.max(4, segments or 12)
        local ang0 = math.rad(ang0Deg)
        local ang1 = math.rad(ang1Deg)
        local step = (ang1 - ang0) / seg
        local poly = {}
        -- Outer arc
        for i = 0, seg do
            local a = ang0 + step * i
            table.insert(poly, { x = cx + math.cos(a) * rOuter, y = cy + math.sin(a) * rOuter })
        end
        -- Inner arc (reverse)
        for i = seg, 0, -1 do
            local a = ang0 + step * i
            table.insert(poly, { x = cx + math.cos(a) * rInner, y = cy + math.sin(a) * rInner })
        end
        draw.NoTexture()
        surface.SetDrawColor(color.r, color.g, color.b, color.a or 255)
        surface.DrawPoly(poly)
    end

    function SWEP:GetSelectedFromQuickslot()
        local owner = self:GetOwner()
        if not IsValid(owner) then return nil end
        local data = Arcane:GetPlayerData(owner)
        local index = math.Clamp(data.selected_quickslot or 1, 1, 8)
        return data.quickspell_slots[index]
    end

    function SWEP:ToggleRadialMenu()
        -- Open on key press; will close on key release check
        self.RadialOpen = true
        self.RadialOpenTime = CurTime()
        self.RadialHoverSlot = nil
        gui.EnableScreenClicker(true)
    end

    function SWEP:DrawOldSchoolHUD(scrW, scrH, owner)
        local data = Arcane:GetPlayerData(owner)
        if not data then return end

        -- Quickslot parchment bar
        local barW, barH = 420, 64
        local barX, barY = (scrW - barW) * 0.5, scrH - barH - 20
        draw.RoundedBox(8, barX, barY, barW, barH, parchment)
        surface.SetDrawColor(parchmentDark)
        surface.DrawOutlinedRect(barX, barY, barW, barH, 2)

        local slotW, slotGap = 44, 8
        local selected = math.Clamp(data.selected_quickslot or 1, 1, 8)
        for i = 1, 8 do
            local x = barX + 10 + (i - 1) * (slotW + slotGap)
            local y = barY + 10
            local isSel = (i == selected)
            draw.RoundedBox(6, x, y, slotW, slotW, isSel and Color(235, 215, 160, 240) or Color(225, 210, 180, 220))
            surface.SetDrawColor(isSel and gold or ink)
            surface.DrawOutlinedRect(x, y, slotW, slotW, isSel and 3 or 2)

            local spellId = data.quickspell_slots[i]
            if spellId and Arcane.RegisteredSpells[spellId] then
                local sp = Arcane.RegisteredSpells[spellId]
                draw.SimpleText(string.upper(string.sub(sp.name, 1, 2)), "Arcana_Ancient", x + slotW * 0.5, y + slotW * 0.5, ink, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            else
                draw.SimpleText("-", "Arcana_Ancient", x + slotW * 0.5, y + slotW * 0.5, Color(120, 100, 80), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            end

            draw.SimpleText(tostring(i), "Arcana_AncientSmall", x + slotW * 0.5, y + slotW + 10, ink, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        end

        -- Selected spell parchment card
        local curSpellId = data.quickspell_slots[selected] or self.SelectedSpell
        local spell = curSpellId and Arcane.RegisteredSpells[curSpellId] or Arcane.RegisteredSpells[self.SelectedSpell]
        if spell then
            local cardW, cardH = 300, 110
            local x, y = scrW - cardW - 20, scrH - cardH - 20
            draw.RoundedBox(10, x, y, cardW, cardH, parchment)
            surface.SetDrawColor(parchmentDark)
            surface.DrawOutlinedRect(x, y, cardW, cardH, 2)
            draw.SimpleText(spell.name, "Arcana_AncientLarge", x + 12, y + 10, ink)
            draw.SimpleText("Lvl " .. spell.level_required .. "  Cost " .. spell.cost_amount .. " " .. spell.cost_type, "Arcana_Ancient", x + 12, y + 40, ink)

            local cdText = "Ready"
            local cdCol = Color(32, 120, 48)
            local cd = data.spell_cooldowns[curSpellId or self.SelectedSpell]
            if cd and cd > CurTime() then
                cdText = tostring(math.ceil(cd - CurTime())) .. "s"
                cdCol = Color(140, 40, 40)
            end
            draw.SimpleText("Cooldown: " .. cdText, "Arcana_Ancient", x + 12, y + 64, cdCol)
        end
    end

    function SWEP:DrawQuickRadial(scrW, scrH, owner)
        local cx, cy = scrW * 0.5, scrH * 0.5
        local radius = 140
    local data = Arcane:GetPlayerData(owner)
        if not data then return end

        -- Ensure cursor is enabled while radial is open
        if not vgui.CursorVisible() then gui.EnableScreenClicker(true) end

        -- Modern blurred backdrop + slight vignette
        Arcana_DrawBlurRect(0, 0, scrW, scrH, 5, 8, 255)
        surface.SetDrawColor(backDim)
        surface.DrawRect(0, 0, scrW, scrH)

        -- Base ring and inner ring (brass tones)
        Arcana_DrawCircle(cx, cy, radius, 2, gold)
        Arcana_DrawCircle(cx, cy, radius - 60, 1, brassInner)

        -- Compute hover slot
        local mx, my = gui.MousePos()
        local ang = math.deg(math.atan2(my - cy, mx - cx))
        ang = (ang + 360) % 360
        local slot = math.floor((ang + 360 / 16) / (360 / 8)) % 8 + 1
        self.RadialHoverSlot = slot

        for i = 1, 8 do
            local a0 = (i - 1) * (360 / 8)
            local a1 = i * (360 / 8)
            local mid = math.rad((a0 + a1) * 0.5)
            local txAbbr = math.floor(cx + math.cos(mid) * (radius - 32) + 0.5)
            local tyAbbr = math.floor(cy + math.sin(mid) * (radius - 32) + 0.5)
            local txNum = math.floor(cx + math.cos(mid) * (radius - 14) + 0.5)
            local tyNum = math.floor(cy + math.sin(mid) * (radius - 14) + 0.5)

            local isHover = (i == slot)

            -- Wedge background (subtle parchment; brighter gold when hovered)
            Arcana_DrawWedge(cx, cy, radius - 60, radius, a0, a1, isHover and wedgeHoverFill or wedgeIdleFill, isHover and 18 or 14)

            draw.SimpleText(tostring(i), "Arcana_Ancient", txNum, tyNum, isHover and paleGold or textDim, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)

            local spellId = data.quickspell_slots[i]
            if spellId and Arcane.RegisteredSpells[spellId] then
                local sp = Arcane.RegisteredSpells[spellId]
                draw.SimpleText(string.upper(string.sub(sp.name, 1, 3)), "Arcana_AncientLarge", txAbbr, tyAbbr, isHover and textBright or paleGold, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            else
                draw.SimpleText("-", "Arcana_AncientLarge", txAbbr, tyAbbr, textDim, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            end
        end

        -- Select on release
        if not input.IsKeyDown(KEY_R) and self.RadialOpen then
            if self.RadialHoverSlot then
                -- Update locally for instant feedback
                local pdata = Arcane:GetPlayerData(owner)
                pdata.selected_quickslot = self.RadialHoverSlot

                net.Start("Arcane_SetSelectedQuickslot")
                net.WriteUInt(self.RadialHoverSlot, 4)
                net.SendToServer()
            end
            self.RadialOpen = false
            gui.EnableScreenClicker(false)
        end
    end
    function SWEP:OpenGrimoireMenu()
        if self.MenuOpen then return end

        local owner = self:GetOwner()
        if not IsValid(owner) or not owner:IsPlayer() then return end

        self.MenuOpen = true

        -- Create the menu frame
        local frame = vgui.Create("DFrame")
        frame:SetSize(820, 560)
        frame:Center()
        frame:SetTitle("")
        frame:SetVisible(true)
        frame:SetDraggable(true)
        frame:ShowCloseButton(true)
        frame:MakePopup()

        hook.Add("HUDPaint", frame, function()
            local x, y = frame:LocalToScreen(0, 0)
            Arcana_DrawBlurRect(x, y, frame:GetWide(), frame:GetTall(), 4, 8, 255)
        end)

        frame.Paint = function(pnl, w, h)
            -- Full solid fallback to avoid any missing textures from default skin
            Arcana_FillDecoPanel(6, 6, w - 12, h - 12, decoBg, 14)
            Arcana_DrawDecoFrame(6, 6, w - 12, h - 12, gold, 14)
            -- Title
            local titleText = string.upper("Grimoire")
            surface.SetFont("Arcana_DecoTitle")
            local tw = surface.GetTextSize(titleText)
            draw.SimpleText(titleText, "Arcana_DecoTitle", 18, 10, paleGold)

            -- Level chip next to title
            local data = Arcane and IsValid(owner) and Arcane:GetPlayerData(owner) or nil
            if data then
                local chipText = "LVL " .. tostring(data.level or 1)
                surface.SetFont("Arcana_Ancient")
                local cw, ch = surface.GetTextSize(chipText)
                local chipX = 18 + tw + 14
                local chipY = 10
                local chipW = cw + 18
                local chipH = ch + 6
                Arcana_FillDecoPanel(chipX, chipY, chipW, chipH, paleGold, 8)
                draw.SimpleText(chipText, "Arcana_Ancient", chipX + (chipW - cw) * 0.5, chipY + (chipH - ch) * 0.5, chipTextCol, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)

                -- XP bar under title, full width inside the frame
                local totalForCurrent = Arcane:GetTotalXPForLevel(data.level)
                local neededForNext = Arcane:GetXPRequiredForLevel(data.level)
                local xpInto = math.max(0, (data.xp or 0) - totalForCurrent)
                local progress = neededForNext > 0 and math.Clamp(xpInto / neededForNext, 0, 1) or 1

                local barX = 18
                local barW = w - 36
                local barH = 12
                local barY = 42

                -- Fill
                local innerPad = 4
                local fillW = math.floor((barW - innerPad * 2) * progress)
                draw.NoTexture()
                surface.SetDrawColor(xpFill)
                surface.DrawRect(barX + innerPad, barY + innerPad, fillW, barH - innerPad * 2)

                -- XP label centered over the bar
                local xpLabel = tostring(xpInto) .. " / " .. tostring(neededForNext)
                surface.SetFont("Arcana_Ancient")
                local lx = select(1, surface.GetTextSize(xpLabel))
                draw.SimpleText(xpLabel, "Arcana_Ancient", barX + barW - lx, barY - 4, textBright)
            end
        end

        -- Hide minimize/maximize and reskin close button
        if IsValid(frame.btnMinim) then frame.btnMinim:Hide() end
        if IsValid(frame.btnMaxim) then frame.btnMaxim:Hide() end
        if IsValid(frame.btnClose) then
            local close = frame.btnClose
            close:SetText("")
            close:SetSize(26, 26)
            function frame:PerformLayout(w, h)
                if IsValid(close) then
                    close:SetPos(w - 26 - 10, 8)
                end
            end
            close.Paint = function(pnl, w, h)
                --local hovered = pnl:IsHovered()
                --Arcana_FillDecoPanel(0, 0, w, h, hovered and Color(40, 32, 24, 220) or Color(26, 22, 18, 220), 6)
                --Arcana_DrawDecoFrame(0, 0, w, h, gold, 6)
                -- Stylized "X"
                surface.SetDrawColor(paleGold)
                local pad = 8
                surface.DrawLine(pad, pad, w - pad, h - pad)
                surface.DrawLine(w - pad, pad, pad, h - pad)
            end
        end

        frame.OnClose = function()
            self.MenuOpen = false
        end

        -- Modern split layout: left quickslots, right learned spells list (drag to assign)
        local content = vgui.Create("DPanel", frame)
        content:Dock(FILL)
        -- Leave space for the XP bar under the title
        content:DockMargin(12, 32, 12, 12)
        content.Paint = function(pnl, w, h)
            -- section separator
        end

        -- Left: quick slots
        local left = vgui.Create("DPanel", content)
        left:Dock(LEFT)
        left:SetWide(440)
        left:DockMargin(0, 0, 8, 0)
        left.Paint = function(pnl, w, h)
            Arcana_FillDecoPanel(4, 4, w - 8, h - 8, decoPanel, 12)
            Arcana_DrawDecoFrame(4, 4, w - 8, h - 8, gold, 12)
            draw.SimpleText(string.upper("Quick Access"), "Arcana_Ancient", 14, 10, paleGold)
        end

        local grid = vgui.Create("DGrid", left)
        grid:Dock(FILL)
        grid:DockMargin(12, 36, 12, 12)
        grid:SetCols(2)
        grid:SetColWide(195)
        grid:SetRowHeight(90)

        local function rebuildSlots()
            grid:Clear()
            local pdata = Arcane:GetPlayerData(owner)
            for i = 1, 8 do
                local slot = vgui.Create("DButton")
                slot:SetText("")
                slot:SetSize(185, 78)
                slot._index = i
                slot.ReceiverName = "arcana_spell"
                slot.Paint = function(pnl, w, h)
                    local hovered = pnl:IsHovered()
                    Arcana_FillDecoPanel(3, 3, w - 6, h - 6, hovered and cardHover or cardIdle, 10)
                    Arcana_DrawDecoFrame(3, 3, w - 6, h - 6, gold, 10)
                    draw.SimpleText("Slot " .. i, "Arcana_AncientSmall", 12, 8, textDim)
                    local sid = pdata.quickspell_slots[i]
                    if sid and Arcane.RegisteredSpells[sid] then
                        local sp = Arcane.RegisteredSpells[sid]
                        draw.SimpleText(sp.name, "Arcana_AncientLarge", 12, 34, textBright)
                    else
                        draw.SimpleText("Empty", "Arcana_AncientLarge", 12, 34, textDim)
                    end
                end
                slot:Receiver("arcana_spell", function(pnl, panels, dropped)
                    if dropped and panels and panels[1] and panels[1].SpellId then
                        local sid = panels[1].SpellId
                        local pdata2 = Arcane:GetPlayerData(owner)
                        pdata2.quickspell_slots[i] = sid
                        net.Start("Arcane_SetQuickslot")
                        net.WriteUInt(i, 4)
                        net.WriteString(sid)
                        net.SendToServer()
                        timer.Simple(0.01, rebuildSlots)
                    end
                end)
                grid:AddItem(slot)
            end
        end
        rebuildSlots()

        -- Middle: learned spells list with drag sources
        local middle = vgui.Create("DPanel", content)
        middle:Dock(FILL)
        middle:DockMargin(0, 0, 0, 0)
        middle.Paint = function(pnl, w, h)
            Arcana_FillDecoPanel(4, 4, w - 8, h - 8, decoPanel, 12)
            Arcana_DrawDecoFrame(4, 4, w - 8, h - 8, gold, 12)
            draw.SimpleText(string.upper("Learned Spells"), "Arcana_Ancient", 14, 10, paleGold)
        end

        local listScroll = vgui.Create("DScrollPanel", middle)
        listScroll:Dock(FILL)
        listScroll:DockMargin(12, 36, 12, 12)

        local unlocked = {}
        for sid, sp in pairs(Arcane.RegisteredSpells) do
            if owner:HasSpellUnlocked(sid) then
                table.insert(unlocked, { id = sid, spell = sp })
            end
        end
        table.sort(unlocked, function(a, b) return a.spell.name < b.spell.name end)

        for _, item in ipairs(unlocked) do
            local sp = item.spell
            local row = vgui.Create("DButton", listScroll)
            row:Dock(TOP)
            row:SetTall(46)
            row:DockMargin(0, 0, 0, 6)
            row:SetText("")
            row.SpellId = item.id
            row:Droppable("arcana_spell")
            row.Paint = function(pnl, w, h)
                local hovered = pnl:IsHovered()
                Arcana_FillDecoPanel(2, 2, w - 4, h - 4, hovered and cardHover or cardIdle, 8)
                Arcana_DrawDecoFrame(2, 2, w - 4, h - 4, gold, 8)
                draw.SimpleText(sp.name, "Arcana_AncientLarge", 12, 12, textBright)
            end
        end

        -- Removed right-side stats panel; stats are now in title chip and global XP bar
    end
end
