if SERVER then
	AddCSLuaFile()
	resource.AddFile("models/arcana/models/arcana/Grimoire.mdl")
	resource.AddFile("materials/models/arcana/catalyst_apprentice.vmt")
	resource.AddFile("materials/models/arcana/catalyst_apprentice.vtf")
	resource.AddFile("materials/models/arcana/normal.vtf")
	resource.AddFile("materials/models/arcana/lightwarptexture.vtf")
	resource.AddFile("materials/models/arcana/phong_exp.vtf")
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
			Arcane:Print("❌ No spell selected!")
		end

		return
	end

	-- Check if spell exists and is unlocked
	local spell = Arcane.RegisteredSpells[selectedSpellId]

	if not spell then
		if CLIENT and IsFirstTimePredicted() then
			Arcane:Print("❌ Unknown spell: " .. tostring(selectedSpellId))
		end

		return
	end

	if not owner:HasSpellUnlocked(selectedSpellId) then
		if CLIENT and IsFirstTimePredicted() then
			Arcane:Print("❌ Spell not unlocked: " .. spell.name)
		end

		return
	end

	-- Begin casting (server schedules execution after cast time)
	if SERVER then
		Arcane:StartCasting(owner, selectedSpellId)
		local castTime = math.max(0.1, spell.cast_time or 0)
		-- Only gate firing by cast time; actual per-spell cooldowns are enforced in Arcane core
		self:SetNextPrimaryFire(CurTime() + castTime)
	else
		-- Client prediction: throttle based on minimum cast time
		local castTime = math.max(0.1, spell.cast_time or 0)
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
				pos = pos + ang:Forward() * (self.WorldModelOffset.pos.x or 0) + ang:Right() * (self.WorldModelOffset.pos.y or 0) + ang:Up() * (self.WorldModelOffset.pos.z or 0)
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
				pos = pos + ang:Forward() * (self.WorldModelOffset.pos.x or 0) + ang:Right() * (self.WorldModelOffset.pos.y or 0) + ang:Up() * (self.WorldModelOffset.pos.z or 0)
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
	table.sort(availableSpells, function(a, b) return a.spell.level_required < b.spell.level_required end)

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
		pos = pos + ang:Forward() * (self.ViewModelOffset.pos.x or 0) + ang:Right() * (self.ViewModelOffset.pos.y or 0) + ang:Up() * (self.ViewModelOffset.pos.z or 0)
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
	surface.CreateFont("Arcana_AncientSmall", {
		font = "Georgia",
		size = 16,
		weight = 600,
		antialias = true,
		extended = true
	})

	surface.CreateFont("Arcana_Ancient", {
		font = "Georgia",
		size = 20,
		weight = 700,
		antialias = true,
		extended = true
	})

	surface.CreateFont("Arcana_AncientLarge", {
		font = "Georgia",
		size = 24,
		weight = 800,
		antialias = true,
		extended = true
	})

	surface.CreateFont("Arcana_DecoTitle", {
		font = "Georgia",
		size = 26,
		weight = 900,
		antialias = true,
		extended = true
	})

	surface.CreateFont("Arcana_AncientGlyph", {
		font = "Arial",
		size = 60,
		weight = 900,
		antialias = true,
		extended = true
	})

	-- Palette tuned to the grimoire model (warm leather + brass)
	local decoBg = Color(26, 20, 14, 235) -- deep leather brown
	local decoPanel = Color(32, 24, 18, 235) -- panel leather
	local gold = Color(198, 160, 74, 255) -- brass gold
	local paleGold = Color(222, 198, 120, 255) -- soft brass
	local textBright = Color(236, 230, 220, 255) -- parchment white
	local textDim = Color(180, 170, 150, 255) -- muted parchment
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

	-- Greek glyphs for subtle face accents
	local greekGlyphs = {"Α", "Β", "Γ", "Δ", "Ε", "Ζ", "Η", "Θ", "Ι", "Κ", "Λ", "Μ", "Ν", "Ξ", "Ο", "Π", "Ρ", "Σ", "Τ", "Υ", "Φ", "Χ", "Ψ", "Ω"}

	-- Shared radial layout config
	local RadialConfig = {
		hud = {
			outerRadius = 180,
			innerGap = 70,
			numberOffset = 14,
			labelBias = 0.7,
		},
		menu = {
			outerRadius = 180,
			innerGap = 70,
			numberOffset = 14,
			labelBias = 0.7,
		}
	}

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
	local function Arcana_DrawDecoFrame(x, y, w, h, col, corner, drawAccents)
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

		-- Small center diamond accents mid-top and mid-bottom (optional)
		if drawAccents ~= false then
			local mx = x + w * 0.5
			local dy = 6
			surface.DisableClipping(true)
			surface.DrawLine(mx - dy, y, mx, y - dy)
			surface.DrawLine(mx, y - dy, mx + dy, y)
			surface.DrawLine(mx - dy, y + h, mx, y + h + dy)
			surface.DrawLine(mx, y + h + dy, mx + dy, y + h)
			surface.DisableClipping(false)
		end
	end

	-- Filled panel that matches the clipped-corner frame geometry
	local function Arcana_FillDecoPanel(x, y, w, h, col, corner)
		local c = math.max(8, corner or 12)
		draw.NoTexture()
		surface.SetDrawColor(col.r, col.g, col.b, col.a or 255)

		local pts = {
			{
				x = x + c,
				y = y
			},
			{
				x = x + w - c,
				y = y
			},
			{
				x = x + w,
				y = y + c
			},
			{
				x = x + w,
				y = y + h - c
			},
			{
				x = x + w - c,
				y = y + h
			},
			{
				x = x + c,
				y = y + h
			},
			{
				x = x,
				y = y + h - c
			},
			{
				x = x,
				y = y + c
			},
		}

		surface.DrawPoly(pts)
	end

	-- Regular polygon outline helper (e.g., octagon)
	local function Arcana_DrawPolygonOutline(cx, cy, radius, sides, col)
		local n = math.max(3, math.floor(sides or 6))
		surface.SetDrawColor(col.r, col.g, col.b, col.a or 255)
		local prevX, prevY

		for i = 0, n do
			local a = (math.pi * 2) * (i % n) / n
			local x = math.floor(cx + math.cos(a) * radius + 0.5)
			local y = math.floor(cy + math.sin(a) * radius + 0.5)

			if prevX ~= nil then
				surface.DrawLine(prevX, prevY, x, y)
			end

			prevX, prevY = x, y
		end
	end

	-- Filled polygon ring sector (between two vertices) for regular N-gon
	local function Arcana_FillPolygonRingSector(cx, cy, rInner, rOuter, sides, index, color)
		local n = math.max(3, math.floor(sides or 8))
		local i = ((index - 1) % n) + 1
		local step = (math.pi * 2) / n
		local a0 = step * (i - 1)
		local a1 = step * i

		local poly = {
			{
				x = cx + math.cos(a0) * rOuter,
				y = cy + math.sin(a0) * rOuter
			},
			{
				x = cx + math.cos(a1) * rOuter,
				y = cy + math.sin(a1) * rOuter
			},
			{
				x = cx + math.cos(a1) * rInner,
				y = cy + math.sin(a1) * rInner
			},
			{
				x = cx + math.cos(a0) * rInner,
				y = cy + math.sin(a0) * rInner
			},
		}

		draw.NoTexture()
		surface.SetDrawColor(color.r, color.g, color.b, color.a or 255)
		surface.DrawPoly(poly)
	end

	-- Art-deco flourish accents for the radial
	local function Arcana_DrawRadialFlourish(cx, cy, rInner, rOuter, sides, baseCol, accentCol)
		local n = math.max(3, math.floor(sides or 8))
		-- Double-outline vibe
		local outlineA = Color(baseCol.r, baseCol.g, baseCol.b, 90)
		local outlineB = Color(baseCol.r, baseCol.g, baseCol.b, 60)
		Arcana_DrawPolygonOutline(cx, cy, rOuter - 4, n, outlineA)
		Arcana_DrawPolygonOutline(cx, cy, rOuter - 8, n, outlineB)
		Arcana_DrawPolygonOutline(cx, cy, rInner + 6, n, outlineB)
		-- Vertex diamonds
		draw.NoTexture()
		surface.SetDrawColor(accentCol.r, accentCol.g, accentCol.b, 40)

		for i = 1, n do
			local a = (i - 1) * (math.pi * 2) / n
			local vx = cx + math.cos(a) * (rOuter - 2)
			local vy = cy + math.sin(a) * (rOuter - 2)
			local d = 5

			local pts = {
				{
					x = vx,
					y = vy - d
				},
				{
					x = vx + d,
					y = vy
				},
				{
					x = vx,
					y = vy + d
				},
				{
					x = vx - d,
					y = vy
				},
			}

			surface.DrawPoly(pts)
		end
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
			draw.SimpleText("Lvl " .. spell.level_required .. "  Cost " .. string.Comma(spell.cost_amount) .. " " .. spell.cost_type, "Arcana_Ancient", x + 12, y + 40, ink)
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
		local radius = RadialConfig.hud.outerRadius
		local rInner = radius - RadialConfig.hud.innerGap
		local data = Arcane:GetPlayerData(owner)
		if not data then return end

		-- Ensure cursor is enabled while radial is open
		if not vgui.CursorVisible() then
			gui.EnableScreenClicker(true)
		end

		-- Modern blurred backdrop + slight vignette
		Arcana_DrawBlurRect(0, 0, scrW, scrH, 5, 8, 255)
		surface.SetDrawColor(backDim)
		surface.DrawRect(0, 0, scrW, scrH)
		-- Octagonal background ring (filled between two octagons)
		local sides = 8

		for i = 1, sides do
			local col = Color(gold.r, gold.g, gold.b, 24)
			Arcana_FillPolygonRingSector(cx, cy, rInner, radius, sides, i, col)
			-- Face center glyphs (Greek)
			local a0 = (i - 1) * 45
			local a1 = i * 45
			local mid = math.rad((a0 + a1) * 0.5)
			local rGlyph = rInner + (radius - rInner) * 0.35
			local gx = math.floor(cx + math.cos(mid) * rGlyph + 0.5)
			local gy = math.floor(cy + math.sin(mid) * rGlyph + 0.5)
			local glyph = greekGlyphs[((i - 1) % #greekGlyphs) + 1]
			draw.SimpleText(glyph, "Arcana_AncientGlyph", gx, gy, Color(21, 20, 14, 190), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		end

		-- Octagonal frame outlines + flourish
		Arcana_DrawPolygonOutline(cx, cy, radius, sides, gold)
		Arcana_DrawPolygonOutline(cx, cy, rInner, sides, brassInner)
		Arcana_DrawRadialFlourish(cx, cy, rInner, radius, sides, gold, paleGold)
		-- Precompute label radius using trapezoid centroid along face normal
		local sinTerm = math.sin(math.pi / sides)
		local baseOut = 2 * radius * sinTerm
		local baseIn = 2 * rInner * sinTerm
		local h = radius - rInner
		local yFromOuter = h * (2 * baseOut + baseIn) / (3 * (baseOut + baseIn))
		local rLabelCentroid = radius - yFromOuter
		-- Pull text closer to center than the geometric centroid for legibility
		local rLabelText = rInner + (rLabelCentroid - rInner) * RadialConfig.hud.labelBias
		-- Compute hover slot
		local mx, my = gui.MousePos()
		-- Use screen-space angle with clockwise increase (y grows downward in screen space)
		local ang = (math.deg(math.atan2(my - cy, mx - cx)) + 360) % 360
		-- Map to 8 faces with boundaries aligned to vertices (every 45°)
		local hoverSlot = math.floor(ang / 45) % 8 + 1
		self.RadialHoverSlot = hoverSlot

		for i = 1, 8 do
			local a0 = (i - 1) * 45
			local a1 = i * 45
			local mid = math.rad((a0 + a1) * 0.5)
			local txAbbr = math.floor(cx + math.cos(mid) * rLabelText + 0.5)
			local tyAbbr = math.floor(cy + math.sin(mid) * rLabelText + 0.5)
			local rNum = radius + RadialConfig.hud.numberOffset
			local txNum = math.floor(cx + math.cos(mid) * rNum + 0.5)
			local tyNum = math.floor(cy + math.sin(mid) * rNum + 0.5)
			local isHover = (i == hoverSlot)
			-- Octagonal sector highlight (flat sides)
			Arcana_FillPolygonRingSector(cx, cy, rInner, radius, sides, i, isHover and wedgeHoverFill or wedgeIdleFill)
			draw.SimpleText(tostring(i), "Arcana_Ancient", txNum, tyNum, isHover and paleGold or textDim, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
			local spellId = data.quickspell_slots[i]

			if spellId and Arcane.RegisteredSpells[spellId] then
				local sp = Arcane.RegisteredSpells[spellId]
				draw.SimpleText(string.upper(string.sub(sp.name, 1, 3)), "Arcana_AncientLarge", txAbbr, tyAbbr, isHover and textBright or paleGold, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
			else
				draw.SimpleText("-", "Arcana_AncientLarge", txAbbr, tyAbbr, textDim, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
			end
		end

		-- Center hover details: name and cost for the hovered slot
		local hsId = data.quickspell_slots[hoverSlot]

		if hsId and Arcane.RegisteredSpells[hsId] then
			local sp = Arcane.RegisteredSpells[hsId]
			draw.SimpleText(sp.name, "Arcana_AncientLarge", cx, cy - 10, textBright, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
			local ct = tostring(sp.cost_type or "")
			local ca = tonumber(sp.cost_amount or 0) or 0
			draw.SimpleText("Cost " .. string.Comma(ca) .. " " .. ct, "Arcana_Ancient", cx, cy + 12, paleGold, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		else
			draw.SimpleText("Empty", "Arcana_AncientLarge", cx, cy, textDim, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
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
		frame:SetSize(980, 600)
		frame:Center()
		frame:SetTitle("")
		frame:SetVisible(true)
		frame:SetDraggable(true)
		frame:ShowCloseButton(true)
		frame:MakePopup()

		-- Track tooltip panels for cleanup on close/remove
		frame._arcanaTooltips = {}

		hook.Add("HUDPaint", frame, function()
			local x, y = frame:LocalToScreen(0, 0)
			Arcana_DrawBlurRect(x, y, frame:GetWide(), frame:GetTall(), 4, 8, 255)
		end)

		frame.Paint = function(pnl, w, h)
			-- Full solid fallback to avoid any missing textures from default skin
			Arcana_FillDecoPanel(6, 6, w - 12, h - 12, decoBg, 14)
			Arcana_DrawDecoFrame(6, 6, w - 12, h - 12, gold, 14, false)
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
				local xpLabel = string.Comma(xpInto) .. " / " .. string.Comma(neededForNext)
				surface.SetFont("Arcana_Ancient")
				local lx = select(1, surface.GetTextSize(xpLabel))
				draw.SimpleText(xpLabel, "Arcana_Ancient", barX + barW - lx, barY - 4, textBright)
			end
		end

		-- Hide minimize/maximize and reskin close button
		if IsValid(frame.btnMinim) then
			frame.btnMinim:Hide()
		end

		if IsValid(frame.btnMaxim) then
			frame.btnMaxim:Hide()
		end

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
			-- Cleanup any leftover tooltips and Think hooks
			if frame._arcanaTooltips then
				for pnl, _ in pairs(frame._arcanaTooltips) do
					if IsValid(pnl) then pnl:Remove() end
					hook.Remove("Think", "ArcanaTooltipPos_" .. tostring(pnl))
				end
				frame._arcanaTooltips = {}
			end
		end

		-- Ensure cleanup if removed without calling OnClose
		frame.OnRemove = frame.OnClose

		-- Modern split layout: left quickslots, right learned spells list (drag to assign)
		local content = vgui.Create("DPanel", frame)
		content:Dock(FILL)
		-- Leave space for the XP bar under the title
		content:DockMargin(12, 32, 12, 12)
		content.Paint = function(pnl, w, h) end -- section separator
		-- Left: radial quick access (drag and drop onto faces)
		local left = vgui.Create("DPanel", content)
		left:Dock(LEFT)
		left:SetWide(440)
		left:DockMargin(0, 0, 4, 0)
		left._hoverSlot = nil

		left.Paint = function(pnl, w, h)
			Arcana_FillDecoPanel(4, 4, w - 8, h - 8, decoPanel, 12)
			Arcana_DrawDecoFrame(4, 4, w - 8, h - 8, gold, 12, false)
			draw.SimpleText(string.upper("Quick Access"), "Arcana_Ancient", 14, 10, paleGold)
			-- Center the wheel within the left panel using a content box (account for title area)
			local titlePadTop = 32
			local padSide = 16
			local padBottom = 12
			local contentW = w - padSide * 2
			local contentH = h - titlePadTop - padBottom
			local cx = padSide + contentW * 0.5
			local cy = titlePadTop + contentH * 0.5
			-- Fit radius to available space while keeping configured preference
			local maxR = math.min(contentW, contentH) * 0.5 - RadialConfig.menu.numberOffset - 6
			local radius = math.min(RadialConfig.menu.outerRadius, math.max(80, math.floor(maxR)))
			local rInner = radius - RadialConfig.menu.innerGap
			local pdata = Arcane:GetPlayerData(owner)
			local mx, my = pnl:LocalCursorPos()
			local ang = (math.deg(math.atan2(my - cy, mx - cx)) + 360) % 360
			local hoverSlot = math.floor(ang / 45) % 8 + 1
			pnl._hoverSlot = hoverSlot

			-- Background ring with Greek glyphs
			for i = 1, 8 do
				local col = Color(gold.r, gold.g, gold.b, (i == hoverSlot) and 70 or 24)
				Arcana_FillPolygonRingSector(cx, cy, rInner, radius, 8, i, col)
				local a0 = (i - 1) * 45
				local a1 = i * 45
				local mid = math.rad((a0 + a1) * 0.5)
				local rGlyph = rInner + (radius - rInner) * 0.35
				local gx = math.floor(cx + math.cos(mid) * rGlyph + 0.5)
				local gy = math.floor(cy + math.sin(mid) * rGlyph + 0.5)
				local glyph = greekGlyphs[((i - 1) % #greekGlyphs) + 1]
				draw.SimpleText(glyph, "Arcana_AncientGlyph", gx, gy, Color(21, 20, 14, 190), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
			end

			Arcana_DrawPolygonOutline(cx, cy, radius, 8, gold)
			Arcana_DrawPolygonOutline(cx, cy, rInner, 8, brassInner)
			Arcana_DrawRadialFlourish(cx, cy, rInner, radius, 8, gold, paleGold)
			-- Label radius (towards center for readability)
			local sinTerm = math.sin(math.pi / 8)
			local baseOut = 2 * radius * sinTerm
			local baseIn = 2 * rInner * sinTerm
			local hth = radius - rInner
			local yFromOuter = hth * (2 * baseOut + baseIn) / (3 * (baseOut + baseIn))
			local rCentroid = radius - yFromOuter
			local rLabel = rInner + (rCentroid - rInner) * RadialConfig.menu.labelBias

			for i = 1, 8 do
				local a0 = (i - 1) * 45
				local a1 = i * 45
				local mid = math.rad((a0 + a1) * 0.5)
				local tx = math.floor(cx + math.cos(mid) * rLabel + 0.5)
				local ty = math.floor(cy + math.sin(mid) * rLabel + 0.5)
				local rNum = radius + RadialConfig.menu.numberOffset
				local tnX = math.floor(cx + math.cos(mid) * rNum + 0.5)
				local tnY = math.floor(cy + math.sin(mid) * rNum + 0.5)
				local isHover = (i == hoverSlot)
				draw.SimpleText(tostring(i), "Arcana_AncientSmall", tnX, tnY, isHover and paleGold or textDim, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
				local sid = pdata.quickspell_slots[i]

				if sid and Arcane.RegisteredSpells[sid] then
					local sp = Arcane.RegisteredSpells[sid]
					draw.SimpleText(string.upper(string.sub(sp.name, 1, 3)), "Arcana_AncientLarge", tx, ty, isHover and textBright or paleGold, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
				else
					draw.SimpleText("-", "Arcana_AncientLarge", tx, ty, textDim, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
				end
			end

			-- Center hover details: name and cost for the hovered slot (matching HUD radial functionality)
			local hsId = pdata.quickspell_slots[hoverSlot]

			if hsId and Arcane.RegisteredSpells[hsId] then
				local sp = Arcane.RegisteredSpells[hsId]
				draw.SimpleText(sp.name, "Arcana_AncientLarge", cx, cy - 10, textBright, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
				local ct = tostring(sp.cost_type or "")
				local ca = tonumber(sp.cost_amount or 0) or 0
				draw.SimpleText("Cost " .. string.Comma(ca) .. " " .. ct, "Arcana_Ancient", cx, cy + 12, paleGold, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
			else
				draw.SimpleText("Empty", "Arcana_AncientLarge", cx, cy, textDim, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
			end
		end

		-- Select quickslot on left click, remove spell on right click
		left.OnMousePressed = function(pnl, mc)
			local slotIndex = pnl._hoverSlot
			if not slotIndex then return end

			if mc == MOUSE_LEFT then
				-- Select the quickslot
				local pdata = Arcane:GetPlayerData(owner)
				pdata.selected_quickslot = slotIndex
				net.Start("Arcane_SetSelectedQuickslot")
				net.WriteUInt(slotIndex, 4)
				net.SendToServer()
			elseif mc == MOUSE_RIGHT then
				-- Remove spell from the quickslot
				local pdata = Arcane:GetPlayerData(owner)
				pdata.quickspell_slots[slotIndex] = nil
				net.Start("Arcane_SetQuickslot")
				net.WriteUInt(slotIndex, 4)
				net.WriteString("") -- Empty string clears the slot
				net.SendToServer()
			end
		end

		-- Accept drops from learned spells
		left:Receiver("arcana_spell", function(pnl, panels, dropped)
			if dropped and panels and panels[1] and panels[1].SpellId then
				local sid = panels[1].SpellId
				local slotIndex = pnl._hoverSlot or 1
				local pdata2 = Arcane:GetPlayerData(owner)
				pdata2.quickspell_slots[slotIndex] = sid
				net.Start("Arcane_SetQuickslot")
				net.WriteUInt(slotIndex, 4)
				net.WriteString(sid)
				net.SendToServer()
				pnl:InvalidateLayout(true)
			end
		end)

		-- Middle: learned spells list with drag sources
		local middle = vgui.Create("DPanel", content)
		middle:Dock(FILL)
		middle:DockMargin(0, 0, 0, 0)

		middle.Paint = function(pnl, w, h)
			Arcana_FillDecoPanel(4, 4, w - 8, h - 8, decoPanel, 12)
			Arcana_DrawDecoFrame(4, 4, w - 8, h - 8, gold, 12, false)
			draw.SimpleText(string.upper("Learned Spells"), "Arcana_Ancient", 14, 10, paleGold)
		end

		local listScroll = vgui.Create("DScrollPanel", middle)
		listScroll:Dock(FILL)
		listScroll:DockMargin(12, 28, 12, 12)
		local vbar = listScroll:GetVBar()
		vbar:SetWide(8)

		vbar.Paint = function(pnl, w, h)
			surface.DisableClipping(true)
			Arcana_FillDecoPanel(0, 0, w, h, decoPanel, 8)
			Arcana_DrawDecoFrame(0, 0, w, h, gold, 8, false)
			surface.DisableClipping(false)
		end

		vbar.btnGrip.Paint = function(pnl, w, h)
			surface.DisableClipping(true)
			surface.SetDrawColor(gold)
			surface.DrawRect(0, 0, w, h)
			surface.DisableClipping(false)
		end

		local unlocked = {}

		for sid, sp in pairs(Arcane.RegisteredSpells) do
			if owner:HasSpellUnlocked(sid) then
				table.insert(unlocked, {
					id = sid,
					spell = sp
				})
			end
		end

		table.sort(unlocked, function(a, b) return a.spell.name < b.spell.name end)

		for _, item in ipairs(unlocked) do
			local sp = item.spell
			local row = vgui.Create("DButton", listScroll)
			row:Dock(TOP)
			row:SetTall(56)
			row:DockMargin(0, 0, 8, 6)
			row:SetText("")
			row.SpellId = item.id
			row:Droppable("arcana_spell")
			-- Create info icon for spell description tooltip
			local infoIcon = vgui.Create("DPanel", row)
			infoIcon:SetSize(20, 20)
			infoIcon:SetPos(0, 0) -- Will be positioned in PerformLayout
			infoIcon:SetCursor("hand")
			infoIcon.SpellDescription = sp.description or "No description available"

			infoIcon.Paint = function(pnl, w, h)
				-- Draw a simple "i" icon in a circle using lines to create outline
				local cx, cy = w / 2, h / 2
				local radius = 8
				surface.SetDrawColor(paleGold)
				-- Draw circle outline by drawing lines in a circle pattern
				local segments = 16

				for i = 0, segments - 1 do
					local angle1 = (i / segments) * math.pi * 2
					local angle2 = ((i + 1) / segments) * math.pi * 2
					local x1 = cx + math.cos(angle1) * radius
					local y1 = cy + math.sin(angle1) * radius
					local x2 = cx + math.cos(angle2) * radius
					local y2 = cy + math.sin(angle2) * radius
					surface.DrawLine(x1, y1, x2, y2)
				end

				draw.SimpleText("i", "Arcana_Ancient", w / 2, h / 2, paleGold, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
			end

			-- Tooltip functionality
			infoIcon.OnCursorEntered = function()
				if IsValid(infoIcon.tooltip) then return end
				local tooltip = vgui.Create("DLabel")
				tooltip:SetSize(300, 60)
				tooltip:SetWrap(true)
				tooltip:SetText(infoIcon.SpellDescription)
				tooltip:SetFont("Arcana_AncientSmall")
				tooltip:SetTextColor(textBright)
				tooltip:SetDrawOnTop(true)
				tooltip:SetMouseInputEnabled(false)
				tooltip:SetKeyboardInputEnabled(false)

				tooltip.Paint = function(pnl, w, h)
					surface.DisableClipping(true)
					Arcana_FillDecoPanel(-10, 0, w, h, Color(26, 20, 14, 245), 8)
					Arcana_DrawDecoFrame(-10, 0, w, h, gold, 8)
					surface.DisableClipping(false)
				end

				infoIcon.tooltip = tooltip
				-- Register for cleanup on frame close
				frame._arcanaTooltips[tooltip] = true

				-- Position tooltip near cursor
				local function updateTooltipPos()
					if not IsValid(tooltip) then return end
					local x, y = gui.MousePos()
					tooltip:SetPos(x + 15, y - 30)
				end

				updateTooltipPos()

				-- Update position if mouse moves
				hook.Add("Think", "ArcanaTooltipPos_" .. tostring(tooltip), function()
					if not IsValid(tooltip) then
						hook.Remove("Think", "ArcanaTooltipPos_" .. tostring(tooltip))

						return
					end

					updateTooltipPos()
				end)
			end

			infoIcon.OnCursorExited = function()
				local t = infoIcon.tooltip
				if IsValid(t) then
					hook.Remove("Think", "ArcanaTooltipPos_" .. tostring(t))
					t:Remove()
					frame._arcanaTooltips[t] = nil
					infoIcon.tooltip = nil
				end
			end

			row.Paint = function(pnl, w, h)
				local hovered = pnl:IsHovered()
				Arcana_FillDecoPanel(2, 2, w - 4, h - 4, hovered and cardHover or cardIdle, 8)
				Arcana_DrawDecoFrame(2, 2, w - 4, h - 4, gold, 8, false)
				draw.SimpleText(sp.name, "Arcana_AncientLarge", 12, 8, textBright)
				-- Subline: cost only
				local ca = tonumber(sp.cost_amount or 0) or 0
				local ct = tostring(sp.cost_type or "")
				local sub = string.format("Cost %s %s", string.Comma(ca), ct)
				draw.SimpleText(sub, "Arcana_AncientSmall", 12, 32, textDim)
			end

			-- Cast button on the right side of the row
			local castBtn = vgui.Create("DButton", row)
			castBtn:SetText("Cast")
			castBtn:SetFont("Arcana_Ancient")
			castBtn:SetTall(28)
			castBtn:SetWide(72)
			castBtn:SetCursor("hand")

			castBtn.DoClick = function()
				-- Request server to cast this spell
				net.Start("Arcane_ConsoleCastSpell")
				net.WriteString(item.id)
				net.SendToServer()

				frame:Close()
			end

			castBtn.Paint = function(pnl, w, h)
				local disabled = not pnl:IsEnabled()
				local bg = disabled and Color(40, 32, 24, 200) or Color(50, 40, 28, 220)
				local col = disabled and textDim or paleGold
				local border = gold

				if not disabled and pnl:IsHovered() then
					bg = cardHover
					col = textBright
					border = textBright
				end

				surface.DisableClipping(true)
				Arcana_FillDecoPanel(0, 0, w, h, bg, 6)
				Arcana_DrawDecoFrame(0, 0, w, h, border, 6, false)
				surface.DisableClipping(false)
				pnl:SetTextColor(col)
			end

			-- Reflect cooldown state in button text/enabled
			castBtn.Think = function(pnl)
				local data = Arcane and Arcane:GetPlayerData(owner) or nil
				local cd = data and data.spell_cooldowns and data.spell_cooldowns[item.id] or 0

				if cd and cd > CurTime() then
					local remaining = math.max(0, math.ceil(cd - CurTime()))

					if pnl:IsEnabled() then
						pnl:SetEnabled(false)
					end

					pnl:SetText(tostring(remaining) .. "s")
				else
					if not pnl:IsEnabled() then
						pnl:SetEnabled(true)
					end

					pnl:SetText("Cast")
				end
			end

			-- Position the info icon next to the spell name
			row.PerformLayout = function(pnl, w, h)
				if IsValid(infoIcon) then
					-- Get the width of the spell name to position icon after it
					surface.SetFont("Arcana_AncientLarge")
					local nameW, nameH = surface.GetTextSize(sp.name)
					infoIcon:SetPos(16 + nameW, 8 + (nameH - 20) / 2)
				end

				if IsValid(castBtn) then
					local btnW, btnH = castBtn:GetWide(), castBtn:GetTall()
					castBtn:SetPos(w - btnW - 12, (h - btnH) * 0.5)
				end
			end
		end
	end
end