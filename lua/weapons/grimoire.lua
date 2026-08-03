if SERVER then
	AddCSLuaFile()
	resource.AddFile("models/arcana/grimoire/grimoire.mdl")
	resource.AddFile("materials/models/arcana/grimoire/catalyst_apprentice.vmt")
	resource.AddFile("materials/models/arcana/grimoire/catalyst_apprentice.vtf")
	resource.AddFile("materials/models/arcana/grimoire/normal.vtf")
	resource.AddFile("materials/models/arcana/grimoire/lightwarptexture.vtf")
	resource.AddFile("materials/models/arcana/grimoire/phong_exp.vtf")
	resource.AddFile("materials/entities/grimoire.png")

	-- Starter spell for new players.
	-- Granted only to a player with no spells at all, rather than to anyone missing
	-- fireball specifically: otherwise forgetting fireball at the altar would be undone
	-- by the next weapon swap. A player who forgets their way down to an empty book
	-- still gets the starter back, which is the case this hook actually exists for.
	-- NPCs equip grimoires too (see Arcana.NPC), and they have no player data at all,
	-- so the starter grant has to stay on the player branch.
	hook.Add("WeaponEquip", "Arcana_GiveStarterSpell", function(wep, ply)
		if wep:GetClass() == "grimoire" and IsValid(ply) and ply:IsPlayer() then
			local data = Arcana:GetPlayerData(ply)

			if data and table.IsEmpty(data.unlocked_spells) then
				Arcana:UnlockSpell(ply, "fireball", true)
			end
		end
	end)

	-- NPCs spawned straight from the menu get their weapon through the engine's
	-- "additionalequipment" keyvalue, so SWEP:Equip is not the only way in. Register
	-- from the gamemode hook as well; Arcana.NPC.Register is idempotent.
	hook.Add("WeaponEquip", "Arcana_GrimoireNPCMage", function(wep, ent)
		if not IsValid(wep) or wep:GetClass() ~= "grimoire" then return end
		if not IsValid(ent) or ent:IsPlayer() then return end

		if wep.SetupNPCOwner then
			wep:SetupNPCOwner(ent)
		end
	end)
end

SWEP.PrintName = "Grimoire"
SWEP.Author = "Earu"
SWEP.Purpose = "A mystical tome containing powerful spells and rituals"
SWEP.Instructions = "LMB: Cast | RMB: Open Grimoire | R: Quick Radial"
SWEP.Spawnable = true
SWEP.AdminOnly = false
SWEP.WorldModel = "models/arcana/grimoire/grimoire.mdl"
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
SWEP.ViewModel = "models/arcana/grimoire/grimoire.mdl"
-- ViewModelFOV controls the FOV of the dedicated viewmodel camera pass.
-- A value of 70 gives a natural book-in-hand appearance at typical screen FOVs.
SWEP.ViewModelFOV = 70
-- Grimoire-specific properties
SWEP.SelectedSpell = "fireball"
SWEP.MenuOpen = false
SWEP.RadialOpen = false
SWEP.RadialHoverSlot = nil
SWEP.RadialOpenTime = 0

-- Offer the grimoire in the NPC weapon dropdown and the NPC menubar. Sandbox validates
-- the chosen equipment against this list before it will hand it to a spawned NPC, so
-- without the entry there is no way to spawn a mage from the menu.
list.Set("NPCUsableWeapons", "grimoire", {
	class = "grimoire",
	title = "Grimoire",
	category = "Arcana",
})

function SWEP:Initialize()
	self:SetHoldType(self.HoldType)
	-- Store active magic circle reference
	self.ActiveMagicCircle = nil
end

function SWEP:Deploy()
	self:SetHoldType(self.HoldType)
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

function SWEP:OnDrop()
	if not SERVER then return end

	SafeRemoveEntity(self)
end

-- ── NPC support ──────────────────────────────────────────────────────────────
-- An NPC given a grimoire becomes an Arcana mage: Arcana.NPC rolls its elemental
-- speciality, generates its spellbook out of the spellcraft catalog, and drives the
-- casting from its own think loop. The engine-facing plumbing here only shapes the
-- NPC's posture — advertising a ranged attack so the AI keeps its distance and faces
-- its enemy instead of closing in to club it.

local function isNPCOwner(ent)
	return IsValid(ent) and (ent:IsNPC() or (ent.IsNextBot and ent:IsNextBot()))
end

function SWEP:SetupNPCOwner(npc)
	if not SERVER or not isNPCOwner(npc) then return end

	-- The player-facing "slam" hold type has no NPC range-attack activity; "smg" does,
	-- so the NPC aims and plays an attack animation with the book in hand.
	self:SetHoldType("smg")
	self._ArcanaNPCOwner = npc

	if Arcana and Arcana.NPC then
		Arcana.NPC.Register(npc, self)
	end
end

function SWEP:Equip(newOwner)
	self:SetupNPCOwner(newOwner)
end

function SWEP:OwnerChanged()
	if not SERVER then return end

	local previous = self._ArcanaNPCOwner
	local current = self:GetOwner()
	if previous == current then return end

	if IsValid(previous) and Arcana and Arcana.NPC then
		Arcana.NPC.Unregister(previous)
	end

	self._ArcanaNPCOwner = isNPCOwner(current) and current or nil
end

function SWEP:OnRemove()
	if not SERVER then return end

	if IsValid(self._ArcanaNPCOwner) and Arcana and Arcana.NPC then
		Arcana.NPC.Unregister(self._ArcanaNPCOwner)
	end
end

function SWEP:GetCapabilities()
	return bit.bor(CAP_WEAPON_RANGE_ATTACK1, CAP_INNATE_RANGE_ATTACK1)
end

function SWEP:GetNPCBulletSpread()
	return 5
end

-- One "shot" per attack, paced slowly: the cast wind-up and per-spell cooldowns in
-- Arcana.NPC are the real rhythm, this just stops the AI asking for more.
function SWEP:GetNPCBurstSettings()
	return 1, 1, 1.5
end

function SWEP:GetNPCRestTimes()
	return 1.5, 3.0
end

-- The engine's fire callback funnels into the same entry point the mage think loop
-- uses, so an engine-elected shot and a loop-elected cast cannot double-cast.
function SWEP:NPCShoot_Primary()
	local owner = self:GetOwner()
	if not isNPCOwner(owner) then return end

	if Arcana and Arcana.NPC then
		Arcana.NPC.TryCast(owner)
	end
end

function SWEP:PrimaryAttack()
	if not Arcana then return end
	local owner = self:GetOwner()
	if not IsValid(owner) or not owner:IsPlayer() then return end
	-- Resolve selected spell from quickslot if present
	local selectedSpellId = self.SelectedSpell
	local pdata = Arcana:GetPlayerData(owner)

	if pdata then
		local qsIndex = math.Clamp(pdata.selected_quickslot or 1, 1, 8)
		selectedSpellId = pdata.quickspell_slots[qsIndex] or selectedSpellId
		self.SelectedSpell = selectedSpellId
	end

	if not selectedSpellId then
		if CLIENT and IsFirstTimePredicted() then
			Arcana:Print("❌ No spell selected!")
		end

		return
	end

	-- Check if spell exists and is unlocked
	local spell = Arcana.RegisteredSpells[selectedSpellId]

	if not spell then
		if CLIENT and IsFirstTimePredicted() then
			Arcana:Print("❌ Unknown spell: " .. tostring(selectedSpellId))
		end

		return
	end

	if not Arcana:HasSpellUnlocked(owner, selectedSpellId) then
		if CLIENT and IsFirstTimePredicted() then
			Arcana:Print("❌ Spell not unlocked: " .. spell.name)
		end

		return
	end

	-- Begin casting (server schedules execution after cast time)
	if SERVER then
		Arcana:StartCasting(owner, selectedSpellId)
		local castTime = math.max(0.1, spell.cast_time or 0)
		-- Only gate firing by cast time; actual per-spell cooldowns are enforced in Arcana core
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
	if not Arcana then return false end
	local owner = self:GetOwner()
	if not IsValid(owner) or not owner:IsPlayer() then return false end

	if CLIENT and IsFirstTimePredicted() then
		self:ToggleRadialMenu()
	end

	return false
end

function SWEP:Think()
end

-- Viewmodel offset table – tune these to taste in-game.
-- pos: forward / right / up offset from the eye origin (world units).
-- ang: pitch / yaw / roll applied after the base eye angle.
-- scale: uniform scale applied to the viewmodel entity.
SWEP.ViewModelOffset = {
	pos   = Vector(12, 9, -9),
	ang   = Angle(-85, 175, 175),
	scale = 0.38,
}

-- Called every frame while this weapon is active; draws the first-person book.
-- The engine has already set up a dedicated viewmodel camera (using ViewModelFOV)
-- before this hook fires, so no manual cam.Start3D / FOV compensation is needed.
function SWEP:DrawViewModel()
	local vm = self:GetOwner():GetViewModel()
	if not IsValid(vm) then return end
	vm:SetModelScale(self.ViewModelOffset.scale, 0)
	vm:DrawModel()
end

-- Positions and orients the viewmodel entity each frame.
-- pos/ang arrive as the eye origin/angle; we shift them by our offset table.
function SWEP:GetViewModelPosition(pos, ang)
	local off = self.ViewModelOffset
	pos = pos
		+ ang:Forward() * off.pos.x
		+ ang:Right()   * off.pos.y
		+ ang:Up()      * off.pos.z

	ang:RotateAroundAxis(ang:Up(),      off.ang.y)
	ang:RotateAroundAxis(ang:Right(),   off.ang.p)
	ang:RotateAroundAxis(ang:Forward(), off.ang.r)

	return pos, ang
end

-- World model attachment to player's right hand
-- Tweak these offsets if the book does not sit perfectly in the hand. They are relative to
-- the hand attachment frame rebuilt below, not to the raw hand bone.
SWEP.WorldModelOffset = {
	-- Solved rather than eyeballed. The hand attachment point is where the engine expects the
	-- grip of a held item to sit, so pos is whatever lands it on the middle of the book's spine
	-- face (mesh Y min, X and Z centred), backed off a unit so the closed fist closes around the
	-- spine instead of sinking into the cover. The old value put the grip 4.5 units inside the
	-- front cover, which is what left the hand clipping through the book. Derived from the mesh
	-- bounds against ang and size below, so re-solve it if either of those changes.
	pos = Vector(-0.5, -6.434, 1.031),
	ang = Angle(-90, 160, 180), -- pitch, yaw, roll adjustments relative to the hand attachment
	size = 0.8 -- size of the world model

}

-- "anim_attachment_RH" is nothing but a fixed transform of the right hand bone: measured
-- identical to five decimals on every ValveBiped playermodel that ships it (kleiner, male_07,
-- alyx, combine_soldier). Plenty of custom playermodels omit the attachment entirely though,
-- so reading it directly meant those models anchored on the raw bone instead — a frame rolled
-- a half turn away from the one WorldModelOffset is tuned against, which is what made the book
-- sit at the wrong angle on them. Rebuilding the attachment from the bone gives every
-- playermodel the same convention whether or not the attachment exists.
local HAND_ATTACHMENT_POS = Vector(2.676, -1.712, 0)
local HAND_ATTACHMENT_ROLL = 180

-- ValveBiped first; the rest cover rigs ported without it.
local HAND_BONE_NAMES = {
	"ValveBiped.Bip01_R_Hand",
	"Bip01 R Hand",
	"bip_hand_R",
	"hand_R",
	"RightHand",
	"mixamorig:RightHand",
}

-- Bone ids are per model, so the cache is keyed by model path.
local handBoneCache = {}

local function getHandBone(owner)
	local model = owner:GetModel()
	local cached = handBoneCache[model]
	if cached ~= nil then return cached or nil end

	for _, name in ipairs(HAND_BONE_NAMES) do
		local boneId = owner:LookupBone(name)

		if boneId then
			handBoneCache[model] = boneId

			return boneId
		end
	end

	-- false, not nil, so a rig with no recognised hand bone is not searched every frame
	handBoneCache[model] = false

	return nil
end

function SWEP:DrawWorldModel()
	local owner = self:GetOwner()
	local boneId = IsValid(owner) and getHandBone(owner) or nil

	if boneId then
		-- Bone matrices can be stale on a player the client has not animated this frame;
		-- the engine no-ops this when they are already fresh.
		owner:SetupBones()
	end

	local matrix = boneId and owner:GetBoneMatrix(boneId) or nil

	-- Fallback if owner/bone is unavailable
	if not matrix then
		self:DrawModel()

		return
	end

	local pos = matrix:GetTranslation()
	local ang = matrix:GetAngles()
	-- Rebuild the hand attachment frame from the bone
	pos = pos + ang:Forward() * HAND_ATTACHMENT_POS.x + ang:Right() * HAND_ATTACHMENT_POS.y + ang:Up() * HAND_ATTACHMENT_POS.z
	ang:RotateAroundAxis(ang:Forward(), HAND_ATTACHMENT_ROLL)
	-- Apply positional offset in the attachment's local space
	local off = self.WorldModelOffset
	pos = pos + ang:Forward() * off.pos.x + ang:Right() * off.pos.y + ang:Up() * off.pos.z
	-- Apply angular offsets
	ang:RotateAroundAxis(ang:Up(), off.ang.y)
	ang:RotateAroundAxis(ang:Right(), off.ang.p)
	ang:RotateAroundAxis(ang:Forward(), off.ang.r)

	self:SetRenderOrigin(pos)
	self:SetRenderAngles(ang)
	self:SetModelScale(off.size or 1.0)
	self:DrawModel()
	self:SetRenderOrigin()
	self:SetRenderAngles()
end

-- Get available spells for the player
function SWEP:GetAvailableSpells()
	if not Arcana then return {} end
	local owner = self:GetOwner()
	if not IsValid(owner) or not owner:IsPlayer() then return {} end
	local availableSpells = {}

	for spellId, spell in pairs(Arcana.RegisteredSpells) do
		if Arcana:HasSpellUnlocked(owner, spellId) then
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
	if not Arcana then return end
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
	function SWEP:OnRemove()
	end

	-- Draws a spell's cost as amount + coin icon (coins) or plain "amount type"
	-- for other cost types. y is the top edge.
	local function drawSpellCost(sp, font, x, y, col, align)
		local ct = tostring(sp.cost_type or "")
		local ca = tonumber(sp.cost_amount or 0) or 0
		local seg
		if ct == Arcana.COST_TYPES.COINS then
			seg = {text = string.Comma(ca), icon = ArtDeco.Icons.coin, color = col}
		else
			seg = {text = string.Comma(ca) .. " " .. ct, color = col}
		end
		ArtDeco.DrawCostLine(font, x, y, {seg}, align)
	end

	local function formatCooldownTime(secs)
		if secs >= 3600 then
			local h = math.floor(secs / 3600)
			local m = math.floor((secs % 3600) / 60)
			return string.format("%dh %dm", h, m)
		elseif secs >= 60 then
			local m = math.floor(secs / 60)
			local s = math.floor(secs % 60)
			return string.format("%dm %ds", m, s)
		end
		return tostring(math.ceil(secs)) .. "s"
	end

	-- Reusable color objects to avoid allocation overhead in draw calls
	local _tempGoldFill = Color(198, 160, 74, 24)

	-- Runic glyphs for subtle face accents
	local runicGlyphs = {"A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z"}

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

	function SWEP:GetSelectedFromQuickslot()
		local owner = self:GetOwner()
		if not IsValid(owner) then return nil end
		local data = Arcana:GetPlayerData(owner)
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


	function SWEP:DrawQuickRadial(scrW, scrH, owner)
		local cx, cy = scrW * 0.5, scrH * 0.5
		local radius = RadialConfig.hud.outerRadius
		local rInner = radius - RadialConfig.hud.innerGap
		local data = Arcana:GetPlayerData(owner)
		if not data then return end

		-- Ensure cursor is enabled while radial is open
		if not vgui.CursorVisible() then
			gui.EnableScreenClicker(true)
		end

		-- Modern blurred backdrop + slight vignette
		ArtDeco.DrawBlurRect(0, 0, scrW, scrH, 5, 8, 255)
		surface.SetDrawColor(ArtDeco.Colors.backDim)
		surface.DrawRect(0, 0, scrW, scrH)
		-- Octagonal background ring (filled between two octagons)
		local sides = 8

		for i = 1, sides do
			_tempGoldFill.a = 24
			ArtDeco.FillPolygonRingSector(cx, cy, rInner, radius, sides, i, _tempGoldFill)
			-- Face center glyphs (Greek)
			local a0 = (i - 1) * 45
			local a1 = i * 45
			local mid = math.rad((a0 + a1) * 0.5)
			local rGlyph = rInner + (radius - rInner) * 0.35
			local gx = math.floor(cx + math.cos(mid) * rGlyph + 0.5)
			local gy = math.floor(cy + math.sin(mid) * rGlyph + 0.5)
			local glyph = runicGlyphs[((i - 1) % #runicGlyphs) + 1]
			draw.SimpleText(glyph, "Arcana_AncientGlyph", gx, gy, Color(21, 20, 14, 190), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		end

		-- Octagonal frame outlines + flourish
		ArtDeco.DrawPolygonOutline(cx, cy, radius, sides, ArtDeco.Colors.gold)
		ArtDeco.DrawPolygonOutline(cx, cy, rInner, sides, ArtDeco.Colors.brassInner)
		ArtDeco.DrawRadialFlourish(cx, cy, rInner, radius, sides, ArtDeco.Colors.gold, ArtDeco.Colors.paleGold)
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
			ArtDeco.FillPolygonRingSector(cx, cy, rInner, radius, sides, i, isHover and ArtDeco.Colors.wedgeHoverFill or ArtDeco.Colors.wedgeIdleFill)
			draw.SimpleText(tostring(i), "Arcana_Ancient", txNum, tyNum, isHover and ArtDeco.Colors.paleGold or ArtDeco.Colors.textDim, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
			local spellId = data.quickspell_slots[i]

			if spellId and Arcana.RegisteredSpells[spellId] then
				local sp = Arcana.RegisteredSpells[spellId]
				draw.SimpleText(string.upper(string.sub(sp.name, 1, 3)), "Arcana_AncientLarge", txAbbr, tyAbbr, isHover and ArtDeco.Colors.textBright or ArtDeco.Colors.paleGold, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
			else
				draw.SimpleText("-", "Arcana_AncientLarge", txAbbr, tyAbbr, ArtDeco.Colors.textDim, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
			end
		end

		-- Center hover details: name and cost for the hovered slot
		local hsId = data.quickspell_slots[hoverSlot]

		if hsId and Arcana.RegisteredSpells[hsId] then
			local sp = Arcana.RegisteredSpells[hsId]
			draw.SimpleText(sp.name, "Arcana_AncientLarge", cx, cy - 10, ArtDeco.Colors.textBright, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
			drawSpellCost(sp, "Arcana_Ancient", cx, cy + 2, ArtDeco.Colors.paleGold, TEXT_ALIGN_CENTER)
		else
			draw.SimpleText("Empty", "Arcana_AncientLarge", cx, cy, ArtDeco.Colors.textDim, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		end

		-- Select on release
		if not input.IsKeyDown(KEY_R) and self.RadialOpen then
			if self.RadialHoverSlot then
				-- Update locally for instant feedback
				local pdata = Arcana:GetPlayerData(owner)
				pdata.selected_quickslot = self.RadialHoverSlot
				net.Start("Arcana_SetSelectedQuickslot")
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
			ArtDeco.DrawBlurRect(x + 6, y + 6, frame:GetWide() - 12, frame:GetTall() - 12, 4, 8, 255)
		end)

		-- XP bar under the title, full width inside the frame. Its top also bounds the
		-- band the title and level chip center themselves in.
		local BAR_X = 18
		local BAR_H = 12
		local BAR_Y = 42

		frame.Paint = function(pnl, w, h)
			-- Full solid fallback to avoid any missing textures from default skin
			ArtDeco.FillDecoPanel(6, 6, w - 12, h - 12, ArtDeco.Colors.decoBg, 14)
			ArtDeco.DrawDecoFrame(6, 6, w - 12, h - 12, ArtDeco.Colors.gold, 14)

			-- Title and level chip share the band between the frame's top line and the
			-- XP bar, so they center on one line with even gaps.
			local bandTop = 6 + 1
			local titleRight = ArtDeco.DrawTitle("Arcana_DecoTitle", string.upper("Grimoire"), bandTop, BAR_Y, ArtDeco.Colors.paleGold)

			local data = Arcana and IsValid(owner) and Arcana:GetPlayerData(owner) or nil

			if data then
				local barX = BAR_X
				local barW = w - 36
				local barH = BAR_H
				local barY = BAR_Y
				local innerPad = 4

				local chipText = "LVL " .. tostring(data.level or 1)
				ArtDeco.DrawChip("Arcana_Ancient", chipText, titleRight + 14, bandTop, barY)

				-- Check if player is at max level
				local isMaxLevel = data.level >= Arcana.Config.MAX_LEVEL
				local progress, xpLabel

				if isMaxLevel then
					-- Max level: fill bar completely and show "MAX."
					progress = 1
					xpLabel = "MAX."
				else
					-- Normal XP progression
					local totalForCurrent = Arcana:GetTotalXPForLevel(data.level)
					local neededForNext = Arcana:GetXPRequiredForLevel(data.level)
					local xpInto = math.max(0, (data.xp or 0) - totalForCurrent)
					progress = neededForNext > 0 and math.Clamp(xpInto / neededForNext, 0, 1) or 1
					xpLabel = string.Comma(xpInto) .. " / " .. string.Comma(neededForNext) .. " XP"
				end

				-- Fill
				local fillW = math.floor((barW - innerPad * 2) * progress)
				draw.NoTexture()
				surface.SetDrawColor(ArtDeco.Colors.xpFill)
				surface.DrawRect(barX + innerPad, barY + innerPad, fillW, barH - innerPad * 2)
				-- XP label
				surface.SetFont("Arcana_Ancient")
				local lx, _ = surface.GetTextSize(xpLabel)
				draw.SimpleText(xpLabel, "Arcana_Ancient", barX + barW - lx, barY - 4, ArtDeco.Colors.textBright)
			end
		end

		-- Hide minimize/maximize and reskin close button
		if IsValid(frame.btnMinim) then
			frame.btnMinim:Hide()
		end

		if IsValid(frame.btnMaxim) then
			frame.btnMaxim:Hide()
		end

		ArtDeco.StyleCloseButton(frame)

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
			ArtDeco.FillDecoPanel(4, 4, w - 8, h - 8, ArtDeco.Colors.decoPanel, 12)
			ArtDeco.DrawDecoFrame(4, 4, w - 8, h - 8, ArtDeco.Colors.gold, 12)
			draw.SimpleText(string.upper("Quick Access"), "Arcana_Ancient", 14, 10, ArtDeco.Colors.paleGold)
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
			local pdata = Arcana:GetPlayerData(owner)
			local mx, my = pnl:LocalCursorPos()
			local ang = (math.deg(math.atan2(my - cy, mx - cx)) + 360) % 360
			local hoverSlot = math.floor(ang / 45) % 8 + 1
			pnl._hoverSlot = hoverSlot

			-- Background ring with Greek glyphs
			for i = 1, 8 do
				_tempGoldFill.a = (i == hoverSlot) and 70 or 24
				ArtDeco.FillPolygonRingSector(cx, cy, rInner, radius, 8, i, _tempGoldFill)
				local a0 = (i - 1) * 45
				local a1 = i * 45
				local mid = math.rad((a0 + a1) * 0.5)
				local rGlyph = rInner + (radius - rInner) * 0.35
				local gx = math.floor(cx + math.cos(mid) * rGlyph + 0.5)
				local gy = math.floor(cy + math.sin(mid) * rGlyph + 0.5)
				local glyph = runicGlyphs[((i - 1) % #runicGlyphs) + 1]
				draw.SimpleText(glyph, "Arcana_AncientGlyph", gx, gy, Color(21, 20, 14, 190), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
			end

			ArtDeco.DrawPolygonOutline(cx, cy, radius, 8, ArtDeco.Colors.gold)
			ArtDeco.DrawPolygonOutline(cx, cy, rInner, 8, ArtDeco.Colors.brassInner)
			ArtDeco.DrawRadialFlourish(cx, cy, rInner, radius, 8, ArtDeco.Colors.gold, ArtDeco.Colors.paleGold)
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
				draw.SimpleText(tostring(i), "Arcana_AncientSmall", tnX, tnY, isHover and ArtDeco.Colors.paleGold or ArtDeco.Colors.textDim, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
				local sid = pdata.quickspell_slots[i]

				if sid and Arcana.RegisteredSpells[sid] then
					local sp = Arcana.RegisteredSpells[sid]
					draw.SimpleText(string.upper(string.sub(sp.name, 1, 3)), "Arcana_AncientLarge", tx, ty, isHover and ArtDeco.Colors.textBright or ArtDeco.Colors.paleGold, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
				else
					draw.SimpleText("-", "Arcana_AncientLarge", tx, ty, ArtDeco.Colors.textDim, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
				end
			end

			-- Center hover details: name and cost for the hovered slot (matching HUD radial functionality)
			local hsId = pdata.quickspell_slots[hoverSlot]

			if hsId and Arcana.RegisteredSpells[hsId] then
				local sp = Arcana.RegisteredSpells[hsId]
				draw.SimpleText(sp.name, "Arcana_AncientLarge", cx, cy - 10, ArtDeco.Colors.textBright, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
				drawSpellCost(sp, "Arcana_Ancient", cx, cy + 2, ArtDeco.Colors.paleGold, TEXT_ALIGN_CENTER)
			else
				draw.SimpleText("Empty", "Arcana_AncientLarge", cx, cy, ArtDeco.Colors.textDim, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
			end
		end

		-- Select quickslot on left click, remove spell on right click
		left.OnMousePressed = function(pnl, mc)
			local slotIndex = pnl._hoverSlot
			if not slotIndex then return end

			if mc == MOUSE_LEFT then
				-- Select the quickslot
				local pdata = Arcana:GetPlayerData(owner)
				pdata.selected_quickslot = slotIndex
				net.Start("Arcana_SetSelectedQuickslot")
				net.WriteUInt(slotIndex, 4)
				net.SendToServer()
			elseif mc == MOUSE_RIGHT then
				-- Remove spell from the quickslot
				local pdata = Arcana:GetPlayerData(owner)
				pdata.quickspell_slots[slotIndex] = nil
				net.Start("Arcana_SetQuickslot")
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
				local pdata2 = Arcana:GetPlayerData(owner)
				pdata2.quickspell_slots[slotIndex] = sid
				net.Start("Arcana_SetQuickslot")
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
			ArtDeco.FillDecoPanel(4, 4, w - 8, h - 8, ArtDeco.Colors.decoPanel, 12)
			ArtDeco.DrawDecoFrame(4, 4, w - 8, h - 8, ArtDeco.Colors.gold, 12)
			draw.SimpleText(string.upper("Learned Spells"), "Arcana_Ancient", 14, 10, ArtDeco.Colors.paleGold)
		end

		local listScroll = vgui.Create("DScrollPanel", middle)
		listScroll:Dock(FILL)
		listScroll:DockMargin(12, 28, 12, 12)
		local vbar = listScroll:GetVBar()
		vbar:SetWide(8)

		vbar.Paint = function(pnl, w, h)
			ArtDeco.FillDecoPanel(0, 0, w, h, ArtDeco.Colors.decoPanel, 8)
			ArtDeco.DrawDecoFrame(0, 0, w, h, ArtDeco.Colors.gold, 8)
		end

		vbar.btnGrip:NoClipping(true)
		vbar.btnGrip.Paint = function(pnl, w, h)
			surface.SetDrawColor(ArtDeco.Colors.gold)
			surface.DrawRect(0, 0, w, h)
		end

		-- Separate spells into categories: regular, divine pacts, and rituals
		local regularSpells = {}
		local divinePacts = {}
		local rituals = {}

		for sid, sp in pairs(Arcana.RegisteredSpells) do
			if Arcana:HasSpellUnlocked(owner, sid) then
				local item = {
					id = sid,
					spell = sp
				}

				if sp.is_divine_pact then
					table.insert(divinePacts, item)
				elseif sp.is_ritual then
					table.insert(rituals, item)
				else
					table.insert(regularSpells, item)
				end
			end
		end

		table.sort(regularSpells, function(a, b) return a.spell.name < b.spell.name end)
		table.sort(divinePacts, function(a, b) return a.spell.level_required < b.spell.level_required end)
		table.sort(rituals, function(a, b) return a.spell.name < b.spell.name end)

		-- Unified Divine Pact color palette - uses normal spell backgrounds with ornate frames
		local divinePactColors = {
			bg = ArtDeco.Colors.cardIdle,
			bgHover = ArtDeco.Colors.cardHover,
			frame1 = Color(220, 180, 100, 255),
			frame2 = Color(255, 215, 140, 255),
			accent = Color(255, 230, 150, 255),
			text = Color(255, 245, 220, 255),
			glow = Color(240, 200, 120, 255),
		}

		-- Ritual uses art deco palette - same backgrounds as normal spells
		local ritualColors = {
			bg = ArtDeco.Colors.cardIdle,
			bgHover = ArtDeco.Colors.cardHover,
			frame1 = ArtDeco.Colors.brassInner,
			frame2 = ArtDeco.Colors.gold,
			accent = ArtDeco.Colors.paleGold,
			text = ArtDeco.Colors.textBright,
			textDim = ArtDeco.Colors.textDim,
		}

		-- Render regular spells first
		for _, item in ipairs(regularSpells) do
			local sp = item.spell
			local row = vgui.Create("DButton", listScroll)
			row:Dock(TOP)
			row:SetTall(56)
			row:DockMargin(0, 0, 8, 6)
			row:SetText("")
			row.SpellId = item.id
			row:Droppable("arcana_spell")
			-- Create info icon for spell description tooltip
			local infoIcon = ArtDeco.CreateInfoIcon(row, sp.description or "No description available", 300)
			infoIcon:SetPos(0, 0) -- Will be positioned in PerformLayout

			row.Paint = function(pnl, w, h)
				local hovered = pnl:IsHovered()
				ArtDeco.FillDecoPanel(2, 2, w - 4, h - 4, hovered and ArtDeco.Colors.cardHover or ArtDeco.Colors.cardIdle, 8)
				ArtDeco.DrawDecoFrame(2, 2, w - 4, h - 4, ArtDeco.Colors.gold, 8)
				draw.SimpleText(sp.name, "Arcana_AncientLarge", 12, 8, ArtDeco.Colors.textBright)
				-- Subline: cost only
				drawSpellCost(sp, "Arcana_AncientSmall", 12, 32, ArtDeco.Colors.textDim)
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
				net.Start("Arcana_ConsoleCastSpell")
				net.WriteString(item.id)
				net.SendToServer()

				-- Close the grimoire unless Control is held
				local ctrlDown = input.IsKeyDown(KEY_LCONTROL) or input.IsKeyDown(KEY_RCONTROL)
				if not ctrlDown then
					frame:Close()
				end
			end

			castBtn.Paint = function(pnl, w, h)
				local disabled = not pnl:IsEnabled()
				local bg = disabled and Color(40, 32, 24, 200) or Color(50, 40, 28, 220)
				local col = disabled and ArtDeco.Colors.textDim or ArtDeco.Colors.paleGold
				local border = ArtDeco.Colors.gold

				if not disabled and pnl:IsHovered() then
					bg = ArtDeco.Colors.cardHover
					col = ArtDeco.Colors.textBright
					border = ArtDeco.Colors.textBright
				end

				ArtDeco.FillDecoPanel(0, 0, w, h, bg, 6)
				ArtDeco.DrawDecoFrame(0, 0, w, h, border, 6)
				pnl:SetTextColor(col)
			end

			-- Reflect cooldown state in button text/enabled
			castBtn.Think = function(pnl)
				local data = Arcana and Arcana:GetPlayerData(owner) or nil
				local cd = data and data.spell_cooldowns and data.spell_cooldowns[item.id] or 0

				if cd and cd > CurTime() then
					local remaining = math.max(0, cd - CurTime())

					if pnl:IsEnabled() then
						pnl:SetEnabled(false)
					end

					pnl:SetText(formatCooldownTime(remaining))
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

		-- Render Divine Pacts section if any are unlocked
		if #divinePacts > 0 then
			-- Spacer before Divine Pacts section
			local spacer = vgui.Create("DPanel", listScroll)
			spacer:Dock(TOP)
			spacer:SetTall(10)
			spacer:DockMargin(0, 0, 0, 0)
			spacer.Paint = function() end

			-- Category header - matching "Learned Spells" style
			local divineHeader = vgui.Create("DPanel", listScroll)
			divineHeader:Dock(TOP)
			divineHeader:SetTall(19)
			divineHeader:DockMargin(0, 0, 8, 0)

			divineHeader.Paint = function(pnl, w, h)
				-- Just text, no frame - matching "Learned Spells" exactly
				draw.SimpleText(string.upper("Divine Pacts"), "Arcana_Ancient", 2, 0, ArtDeco.Colors.paleGold)
			end

			-- Render Divine Pact spells
			for _, item in ipairs(divinePacts) do
				local sp = item.spell
				local row = vgui.Create("DButton", listScroll)
				row:Dock(TOP)
				row:SetTall(64)
				row:DockMargin(0, 0, 8, 6)
				row:SetText("")
				row.SpellId = item.id
				row:Droppable("arcana_spell")

				local infoIcon = ArtDeco.CreateInfoIcon(row, sp.description or "No description available", 300)
				infoIcon:SetPos(0, 0)

				row.Paint = function(pnl, w, h)
					local hovered = pnl:IsHovered()
					local bg = hovered and divinePactColors.bgHover or divinePactColors.bg
					local time = CurTime()

					-- Use consolidated divine pact frame drawing
					local frameColors = {
						bg = bg,
						frame1 = divinePactColors.frame1,
						frame2 = divinePactColors.frame2,
						accent = divinePactColors.accent
					}
					ArtDeco.DrawDivinePactFrame(2, 2, w - 4, h - 4, frameColors, time, 10)

					-- Spell name with glow effect
					local nameY = 10
					draw.SimpleText(sp.name, "Arcana_AncientLarge", 13, nameY + 1, ColorAlpha(divinePactColors.glow, 100))
					draw.SimpleText(sp.name, "Arcana_AncientLarge", 12, nameY, divinePactColors.text)

					-- Level requirement and cost
					local infoY = 38
					local levelText = "⟨ LVL " .. tostring(sp.level_required or 1) .. " ⟩"
					surface.SetFont("Arcana_AncientSmall")
					local levelW, _ = surface.GetTextSize(levelText)

					-- Level badge background
					draw.NoTexture()
					surface.SetDrawColor(ColorAlpha(divinePactColors.frame1, 60))
					surface.DrawRect(10, infoY - 2, levelW + 8, 16)

					draw.SimpleText(levelText, "Arcana_AncientSmall", 12, infoY, divinePactColors.accent)

					-- Cost display
					drawSpellCost(sp, "Arcana_AncientSmall", 12 + levelW + 16, infoY, ColorAlpha(divinePactColors.text, 200))
				end

				-- Cast button
				local castBtn = vgui.Create("DButton", row)
				castBtn:SetText("Cast")
				castBtn:SetFont("Arcana_Ancient")
				castBtn:SetTall(28)
				castBtn:SetWide(72)
				castBtn:SetCursor("hand")

				castBtn.DoClick = function()
					net.Start("Arcana_ConsoleCastSpell")
					net.WriteString(item.id)
					net.SendToServer()

					local ctrlDown = input.IsKeyDown(KEY_LCONTROL) or input.IsKeyDown(KEY_RCONTROL)
					if not ctrlDown then
						frame:Close()
					end
				end

				castBtn.Paint = function(pnl, w, h)
					local disabled = not pnl:IsEnabled()
					local hovered = pnl:IsHovered()
					local time = CurTime()
					local glowIntensity = 0.6 + 0.4 * math.sin(time * 2.5)

					local bg, textCol, frameCol1, frameCol2
					if disabled then
						bg = ColorAlpha(divinePactColors.bg, 150)
						textCol = ColorAlpha(divinePactColors.text, 100)
						frameCol1 = ColorAlpha(divinePactColors.frame1, 100)
						frameCol2 = ColorAlpha(divinePactColors.frame2, 100)
					elseif hovered then
						bg = ColorAlpha(divinePactColors.bgHover, 255)
						textCol = divinePactColors.text
						frameCol1 = ColorAlpha(divinePactColors.accent, 255 * glowIntensity)
						frameCol2 = ColorAlpha(divinePactColors.frame2, 255)
					else
						bg = ColorAlpha(divinePactColors.bg, 230)
						textCol = ColorAlpha(divinePactColors.text, 230)
						frameCol1 = ColorAlpha(divinePactColors.frame1, 200)
						frameCol2 = ColorAlpha(divinePactColors.frame2, 200)
					end

					ArtDeco.FillDecoPanel(0, 0, w, h, bg, 8)
					ArtDeco.DrawDecoFrame(0, 0, w, h, frameCol1, 8)
					ArtDeco.DrawDecoFrame(2, 2, w - 4, h - 4, frameCol2, 8)

					if not disabled then
						local cornerSize = 6
						local pad = 4
						surface.SetDrawColor(ColorAlpha(divinePactColors.accent, 200 * glowIntensity))
						surface.DrawLine(pad, pad, pad + cornerSize, pad)
						surface.DrawLine(pad, pad, pad, pad + cornerSize)
						surface.DrawLine(w - pad - cornerSize, pad, w - pad, pad)
						surface.DrawLine(w - pad, pad, w - pad, pad + cornerSize)
						surface.DrawLine(pad, h - pad, pad + cornerSize, h - pad)
						surface.DrawLine(pad, h - pad - cornerSize, pad, h - pad)
						surface.DrawLine(w - pad - cornerSize, h - pad, w - pad, h - pad)
						surface.DrawLine(w - pad, h - pad - cornerSize, w - pad, h - pad)
					end

					pnl:SetTextColor(textCol)
				end

			castBtn.Think = function(pnl)
				local data = Arcana and Arcana:GetPlayerData(owner) or nil
				local cd = data and data.spell_cooldowns and data.spell_cooldowns[item.id] or 0

				if cd and cd > CurTime() then
					local remaining = math.max(0, cd - CurTime())
					if pnl:IsEnabled() then pnl:SetEnabled(false) end
					pnl:SetText(formatCooldownTime(remaining))
				else
					if not pnl:IsEnabled() then pnl:SetEnabled(true) end
					pnl:SetText("Cast")
				end
			end

				row.PerformLayout = function(pnl, w, h)
					if IsValid(infoIcon) then
						surface.SetFont("Arcana_AncientLarge")
						local nameW, nameH = surface.GetTextSize(sp.name)
						infoIcon:SetPos(16 + nameW, 10 + (nameH - 20) / 2)
					end

					if IsValid(castBtn) then
						local btnW, btnH = castBtn:GetWide(), castBtn:GetTall()
						castBtn:SetPos(w - btnW - 12, (h - btnH) * 0.5)
					end
				end
			end
		end

		-- Render Rituals section if any are unlocked
		if #rituals > 0 then
			-- Spacer before Rituals section
			local spacer = vgui.Create("DPanel", listScroll)
			spacer:Dock(TOP)
			spacer:SetTall(10)
			spacer:DockMargin(0, 0, 0, 0)
			spacer.Paint = function() end

			-- Category header - matching "Learned Spells" style
			local ritualHeader = vgui.Create("DPanel", listScroll)
			ritualHeader:Dock(TOP)
			ritualHeader:SetTall(19)
			ritualHeader:DockMargin(0, 0, 8, 0)

			ritualHeader.Paint = function(pnl, w, h)
				-- Just text, no frame - matching "Learned Spells" exactly
				draw.SimpleText(string.upper("Rituals"), "Arcana_Ancient", 2, 0, ArtDeco.Colors.paleGold)
			end

			-- Render Ritual spells (with unique mystical styling)
			for _, item in ipairs(rituals) do
				local sp = item.spell
				local row = vgui.Create("DButton", listScroll)
				row:Dock(TOP)
				row:SetTall(64)
				row:DockMargin(0, 0, 8, 6)
				row:SetText("")
				row.SpellId = item.id
				row:Droppable("arcana_spell")

				local infoIcon = ArtDeco.CreateInfoIcon(row, sp.description or "No description available", 300)
				infoIcon:SetPos(0, 0)

				row.Paint = function(pnl, w, h)
					local hovered = pnl:IsHovered()
					local bg = hovered and ritualColors.bgHover or ritualColors.bg

					-- Use consolidated ritual frame drawing
					local frameColors = {
						bg = bg,
						frame1 = ritualColors.frame1,
						frame2 = ritualColors.frame2
					}
					ArtDeco.DrawRitualFrame(2, 2, w - 4, h - 4, frameColors)

					-- Strip "Ritual: " prefix from name since it's already in the Rituals category
					local displayName = string.gsub(sp.name, "^Ritual:%s*", "")
					draw.SimpleText(displayName, "Arcana_AncientLarge", 14, 10, ritualColors.text)
					-- Subline: cost only
					drawSpellCost(sp, "Arcana_AncientSmall", 14, 36, ritualColors.textDim)
				end

				row.OnCursorEntered = function(pnl)
					pnl:InvalidateLayout(true)
				end

				row.OnCursorExited = function(pnl)
					pnl:InvalidateLayout(true)
				end

				row.DoClick = function(pnl)
					net.Start("Arcana_ConsoleCastSpell")
					net.WriteString(item.id)
					net.SendToServer()
					local ctrlDown = input.IsKeyDown(KEY_LCONTROL) or input.IsKeyDown(KEY_RCONTROL)
					if not ctrlDown then
						frame:Close()
					end
				end

				local castBtn = vgui.Create("DButton", row)
				castBtn:SetFont("Arcana_Ancient")
				castBtn:SetText("Cast")
				castBtn:SetSize(72, 28)

				castBtn.DoClick = function(pnl)
					net.Start("Arcana_ConsoleCastSpell")
					net.WriteString(item.id)
					net.SendToServer()
					local ctrlDown = input.IsKeyDown(KEY_LCONTROL) or input.IsKeyDown(KEY_RCONTROL)
					if not ctrlDown then
						frame:Close()
					end
				end

				castBtn.Paint = function(pnl, w, h)
					local disabled = not pnl:IsEnabled()
					local bg = disabled and Color(40, 32, 24, 200) or Color(50, 40, 28, 220)
					local col = disabled and ArtDeco.Colors.textDim or ArtDeco.Colors.paleGold
					local border = ArtDeco.Colors.gold

					if not disabled and pnl:IsHovered() then
						bg = ArtDeco.Colors.cardHover
						col = ArtDeco.Colors.textBright
						border = ArtDeco.Colors.textBright
					end

					ArtDeco.FillDecoPanel(0, 0, w, h, bg, 6)
					ArtDeco.DrawDecoFrame(0, 0, w, h, border, 6)
					pnl:SetTextColor(col)
				end

			castBtn.Think = function(pnl)
				local data = Arcana and Arcana:GetPlayerData(owner) or nil
				local cd = data and data.spell_cooldowns and data.spell_cooldowns[item.id] or 0

				if cd and cd > CurTime() then
					local remaining = math.max(0, cd - CurTime())

					if pnl:IsEnabled() then
						pnl:SetEnabled(false)
					end

					pnl:SetText(formatCooldownTime(remaining))
				else
					if not pnl:IsEnabled() then
						pnl:SetEnabled(true)
					end

					pnl:SetText("Cast")
				end
			end

			row.PerformLayout = function(pnl, w, h)
				if IsValid(infoIcon) then
					surface.SetFont("Arcana_AncientLarge")
					local displayName = string.gsub(sp.name, "^Ritual:%s*", "")
						local nameW, nameH = surface.GetTextSize(displayName)
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

end