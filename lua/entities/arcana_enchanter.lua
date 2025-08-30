AddCSLuaFile()
ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "Enchanter"
ENT.Category = "Arcana"
ENT.Spawnable = true
ENT.AdminSpawnable = true
ENT.RenderGroup = RENDERGROUP_BOTH
ENT.UseCooldown = 0.75
ENT.HintDistance = 140

function ENT:SetupDataTables()
	self:NetworkVar("Entity", 0, "ContainedWeapon") -- weapon entity stored inside machine
	self:NetworkVar("String", 0, "ContainedClass") -- class name for persistence on client
end

if SERVER then
	util.AddNetworkString("Arcana_OpenEnchanterMenu")
	util.AddNetworkString("Arcana_Enchanter_Deposit")
	util.AddNetworkString("Arcana_Enchanter_Withdraw")
	util.AddNetworkString("Arcana_Enchanter_Apply")

	function ENT:Initialize()
		self:SetModel("models/props_lab/reciever01b.mdl")
		self:SetMaterial("models/props_c17/metalladder001")
		self:PhysicsInit(SOLID_VPHYSICS)
		self:SetMoveType(MOVETYPE_VPHYSICS)
		self:SetSolid(SOLID_VPHYSICS)
		self:SetUseType(SIMPLE_USE)
		local phys = self:GetPhysicsObject()
		if IsValid(phys) then
			phys:Wake()
			phys:EnableMotion(false)
		end
		self._nextUse = 0
	end

	function ENT:SpawnFunction(ply, tr, classname)
		if not tr or not tr.Hit then return end
		local pos = tr.HitPos + tr.HitNormal * 8
		local ent = ents.Create(classname or "arcana_enchanter")
		if not IsValid(ent) then return end
		ent:SetPos(pos)
		local ang = Angle(0, ply:EyeAngles().y, 0)
		ent:SetAngles(ang)
		ent:Spawn()
		ent:Activate()
		return ent
	end

	function ENT:Use(ply)
		if not IsValid(ply) or not ply:IsPlayer() then return end
		local now = CurTime()
		if now < (self._nextUse or 0) then return end
		self._nextUse = now + self.UseCooldown
		net.Start("Arcana_OpenEnchanterMenu")
		net.WriteEntity(self)
		net.Send(ply)
		self:EmitSound("buttons/button9.wav", 60, 110)
	end

	local function canAffordEnchantment(ply, ench)
		if not Arcane or not ench then return false, "Invalid enchantment" end
		local coins = (ply.GetCoins and ply:GetCoins()) or 0
		if coins < (ench.cost_coins or 0) then return false, "Insufficient coins" end
		for _, it in ipairs(ench.cost_items or {}) do
			local name = tostring(it.name or "")
			local amt = math.max(1, math.floor(tonumber(it.amount or 1) or 1))
			if name ~= "" then
				local have = (ply.GetItemCount and ply:GetItemCount(name)) or 0
				if have < amt then
					return false, "Missing item: " .. name
				end
			end
		end
		return true
	end

	local function takeEnchantmentCost(ply, ench)
		if ench.cost_coins and ench.cost_coins > 0 and ply.TakeCoins then
			ply:TakeCoins(ench.cost_coins)
		end
		for _, it in ipairs(ench.cost_items or {}) do
			local name = tostring(it.name or "")
			local amt = math.max(1, math.floor(tonumber(it.amount or 1) or 1))
			if name ~= "" and ply.TakeItem then
				ply:TakeItem(name, amt)
			end
		end
	end

	net.Receive("Arcana_Enchanter_Deposit", function(_, ply)
		local ent = net.ReadEntity()
		if not IsValid(ent) or ent:GetClass() ~= "arcana_enchanter" then return end
		local hasCls = tostring(ent:GetContainedClass() or "")
		if hasCls ~= "" then return end -- already holding a weapon
		local wep = ply:GetActiveWeapon()
		if not IsValid(wep) then return end
		-- Store class and drop weapon from player
		local cls = wep:GetClass()
		ent:SetContainedClass(cls)
		ply:StripWeapon(cls)
		ent:SetContainedWeapon(NULL)
		ent:EmitSound("items/suitchargeok1.wav", 70, 120)
	end)

	net.Receive("Arcana_Enchanter_Withdraw", function(_, ply)
		local ent = net.ReadEntity()
		if not IsValid(ent) or ent:GetClass() ~= "arcana_enchanter" then return end
		local cls = ent:GetContainedClass()
		if not cls or cls == "" then return end
		ent:SetContainedClass("")
		if ply.Give then ply:Give(cls) end
		ent:EmitSound("items/smallmedkit1.wav", 70, 115)
	end)

	net.Receive("Arcana_Enchanter_Apply", function(_, ply)
		local ent = net.ReadEntity()
		local enchId = net.ReadString()
		if not IsValid(ent) or ent:GetClass() ~= "arcana_enchanter" then return end
		local cls = ent:GetContainedClass()
		if not cls or cls == "" then return end
		local ench = (Arcane and Arcane.RegisteredEnchantments and Arcane.RegisteredEnchantments[enchId]) or nil
		if not ench then return end
		-- Check applicability
		if ench.can_apply then
			local dummy = ents.Create(cls)
			if IsValid(dummy) then dummy:Remove() end
			local ok, reason = pcall(ench.can_apply, ply, dummy)
			if not ok or reason == false then
				if Arcane and Arcane.SendErrorNotification then
					Arcane:SendErrorNotification(ply, "Cannot apply: " .. tostring(reason or "invalid"))
				end
				return
			end
		end

		local ok, reason = canAffordEnchantment(ply, ench)
		if not ok then
			if Arcane and Arcane.SendErrorNotification then
				Arcane:SendErrorNotification(ply, tostring(reason or "Insufficient resources"))
			end
			return
		end

		takeEnchantmentCost(ply, ench)
		local success, err = Arcane:ApplyEnchantmentToWeapon(ply, cls, enchId)
		if not success then
			if Arcane and Arcane.SendErrorNotification then
				Arcane:SendErrorNotification(ply, tostring(err or "Failed to apply enchantment"))
			end
			return
		end
		ent:EmitSound("ambient/machines/teleport1.wav", 70, 110)
	end)
end

if CLIENT then
	-- Minimal styling reuse from altar
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

	local decoBg = Color(26, 20, 14, 235)
	local decoPanel = Color(32, 24, 18, 235)
	local gold = Color(198, 160, 74, 255)
	local textBright = Color(236, 230, 220, 255)
	local textDim = Color(180, 170, 150, 255)

	-- UI-only glyph helpers to enrich the circle visuals (standalone from circles.lua)
	local GREEK_PHRASES = {
		"αβραξαςαβραξαςαβραξαςαβραξαςαβραξαςαβραξας",
		"θεοσγνωσιςφωςζωηαληθειακοσμοςψυχηπνευμα",
		"αρχηκαιτελοςαρχηκαιτελοςαρχηκαιτελος",
	}

	local ARABIC_PHRASES = {
		"بسماللهالرحمنالرحيمبسماللهالرحمنالرحيم",
		"اللهنورسماواتوالارضاللهنورسماواتوالارض",
		"سبحاناللهوبحمدهسبحاناللهالعظيمسبحانالله",
	}

	local GLYPH_PHRASES = {}
	for _, p in ipairs(GREEK_PHRASES) do table.insert(GLYPH_PHRASES, p) end
	for _, p in ipairs(ARABIC_PHRASES) do table.insert(GLYPH_PHRASES, p) end

	local UI_GLYPH_CACHE = {}

	local function UI_GetGlyphMaterial(fontName, char)
		local key = (fontName or "") .. ":" .. (char or "")
		local cached = UI_GLYPH_CACHE[key]
		if cached then return cached.mat, cached.w, cached.h end
		surface.SetFont(fontName or "DermaDefault")
		local w, h = surface.GetTextSize(char)
		w = math.max(1, math.floor(w + 2))
		h = math.max(1, math.floor(h + 2))
		local id = util.CRC and util.CRC(key) or tostring(key):gsub("%W", "")
		local rtName = "arcana_ui_glyph_rt_" .. id
		local tex = GetRenderTarget(rtName, w, h, true)
		local matName = "arcana_ui_glyph_mat_" .. id
		local mat = CreateMaterial(matName, "UnlitGeneric", {
			["$basetexture"] = tex:GetName(),
			["$translucent"] = 1,
			["$vertexalpha"] = 1,
			["$vertexcolor"] = 1,
			["$nolod"] = 1,
		})
		render.PushRenderTarget(tex)
		render.Clear(0, 0, 0, 0, true, true)
		cam.Start2D()
		surface.SetFont(fontName or "DermaDefault")
		surface.SetTextColor(255, 255, 255, 255)
		surface.SetTextPos(1, 1)
		surface.DrawText(char)
		cam.End2D()
		render.PopRenderTarget()
		UI_GLYPH_CACHE[key] = { mat = mat, w = w, h = h }
		return mat, w, h
	end

	local function UI_DrawGlyphRing(cx, cy, radius, fontName, phrase, scaleMul, count, col, rotOffset)
		phrase = tostring(phrase or "MAGIC")
		local chars = {}
		for _, code in utf8.codes(phrase) do chars[#chars + 1] = utf8.char(code) end
		if #chars == 0 then chars = {"*"} end
		local num = math.max(12, count or 36)
		local step = (math.pi * 2) / num
		local drawCol = col or Color(220, 200, 150, 235)
		surface.SetDrawColor(drawCol.r, drawCol.g, drawCol.b, drawCol.a)
		local ro = tonumber(rotOffset) or 0
		for i = 1, num do
			local ch = chars[((i - 1) % #chars) + 1]
			local mat, gw, gh = UI_GetGlyphMaterial(fontName or "DermaDefault", ch)
			local ang = -math.pi / 2 + i * step + ro
			local px = cx + math.cos(ang) * radius
			local py = cy + math.sin(ang) * radius
			local rot = math.deg(ang + math.pi * 0.5)
			local s = (scaleMul or 0.6)
			local w = math.max(1, gw * s)
			local h = math.max(1, gh * s)
			surface.SetMaterial(mat)
			surface.DrawTexturedRectRotated(px, py, w, h, rot)
		end
	end

	local function UI_DrawMinorTicks(cx, cy, radiusOuter, radiusInner, count, col)
		surface.SetDrawColor((col and col.r) or 200, (col and col.g) or 180, (col and col.b) or 140, (col and col.a) or 220)
		local n = math.max(1, count or 32)
		local step = (math.pi * 2) / n
		for i = 0, n - 1 do
			local a = -math.pi / 2 + i * step
			local x1 = cx + math.cos(a) * radiusOuter
			local y1 = cy + math.sin(a) * radiusOuter
			local x2 = cx + math.cos(a) * radiusInner
			local y2 = cy + math.sin(a) * radiusInner
			surface.DrawLine(x1, y1, x2, y2)
		end
	end

	local function Arcana_FillDecoPanel(x, y, w, h, col, corner)
		local c = math.max(8, corner or 12)
		draw.NoTexture()
		surface.SetDrawColor(col.r, col.g, col.b, col.a or 255)
		local pts = {
			{x = x + c, y = y},
			{x = x + w - c, y = y},
			{x = x + w, y = y + c},
			{x = x + w, y = y + h - c},
			{x = x + w - c, y = y + h},
			{x = x + c, y = y + h},
			{x = x, y = y + h - c},
			{x = x, y = y + c},
		}
		surface.DrawPoly(pts)
	end

	local function Arcana_DrawDecoFrame(x, y, w, h, col, corner)
		local c = math.max(8, corner or 12)
		surface.SetDrawColor(col.r, col.g, col.b, col.a or 255)
		surface.DisableClipping(true)
		surface.DrawLine(x + c, y, x + w - c, y)
		surface.DrawLine(x + w, y + c, x + w, y + h - c)
		surface.DrawLine(x + w - c, y + h, x + c, y + h)
		surface.DrawLine(x, y + h - c, x, y + c)
		surface.DrawLine(x, y + c, x + c, y)
		surface.DrawLine(x + w - c, y, x + w, y + c)
		surface.DrawLine(x + w, y + h - c, x + w - c, y + h)
		surface.DrawLine(x + c, y + h, x, y + h - c)
		surface.DisableClipping(false)
	end

	local function getEnchantmentsList()
		return Arcane and Arcane.GetEnchantments and Arcane:GetEnchantments() or {}
	end

	local function OpenEnchanterMenu(machine)
		local ply = LocalPlayer()
		if not IsValid(ply) then return end
		local frame = vgui.Create("DFrame")
		frame:SetSize(980, 600)
		frame:Center()
		frame:SetTitle("")
		frame:MakePopup()
		-- Style close button like the rest of the UI
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
				surface.SetDrawColor(gold)
				local pad = 8
				surface.DrawLine(pad, pad, w - pad, h - pad)
				surface.DrawLine(w - pad, pad, pad, h - pad)
			end
		end

		frame.Paint = function(pnl, w, h)
			Arcana_FillDecoPanel(6, 6, w - 12, h - 12, decoBg, 14)
			Arcana_DrawDecoFrame(6, 6, w - 12, h - 12, gold, 14)
			draw.SimpleText("ENCHANTER", "Arcana_AncientLarge", 18, 10, textBright)
		end

		if IsValid(frame.btnMinim) then frame.btnMinim:Hide() end
		if IsValid(frame.btnMaxim) then frame.btnMaxim:Hide() end

		local content = vgui.Create("DPanel", frame)
		content:Dock(FILL)
		content:DockMargin(12, 34, 12, 12)
		content.Paint = nil

		-- Left: Engraved circle with weapon model/name + controls
		local left = vgui.Create("DPanel", content)
		left:Dock(LEFT)
		left:SetWide(520)
		left.Paint = function(pnl, w, h)
			Arcana_FillDecoPanel(4, 4, w - 8, h - 8, decoPanel, 12)
			Arcana_DrawDecoFrame(4, 4, w - 8, h - 8, gold, 12)
			-- Engraved circle background (non-pentagram)
			local cx, cy = w * 0.5, h * 0.44
			local radius = math.min(w, h) * 0.36
			-- Stone base
			draw.NoTexture()
			surface.DisableClipping(true)
			surface.SetDrawColor(36, 28, 22, 240)
			surface.DrawCircle(cx, cy, radius, 80, 70, 60, 245)
			-- Soft inner disc for contrast
			for r = radius, radius - 6, -1 do
				surface.DrawCircle(cx, cy, r, 90, 80, 70, 200)
			end
			-- Outer engraved rings
			local function thickCircle(r, t)
				for i = 0, t do
					surface.DrawCircle(cx, cy, r - i, 200, 180, 140, 255)
				end
			end
			thickCircle(radius - 8, 2)
			thickCircle(radius * 0.82, 2)
			thickCircle(radius * 0.64, 2)
			-- Helpers
			local function pnt(a, r) return cx + math.cos(a) * r, cy + math.sin(a) * r end
			-- Radial ticks
			surface.SetDrawColor(180, 160, 120, 200)
			for i = 0, 11 do
				local ang = i * (math.pi * 2 / 12)
				local x1, y1 = pnt(ang, radius * 0.90)
				local x2, y2 = pnt(ang, radius * 0.84)
				surface.DrawLine(x1, y1, x2, y2)
			end
			-- Fine ticks between main ticks (keep within outer band)
			UI_DrawMinorTicks(cx, cy, radius * 0.89, radius * 0.865, 48, Color(200, 180, 140, 160))
			-- Engraved glyph rings (slow counter-rotation)
			local t = CurTime()
			-- Outer glyph band (slightly larger for breathing room)
			local bandOuterMid = radius * 0.755
			local bandOuterIn = radius * 0.72
			local bandOuterOut = radius * 0.79
			thickCircle(bandOuterOut, 1)
			thickCircle(bandOuterIn, 1)
			local phraseOuter = GREEK_PHRASES[1 + (math.floor(t * 0.02) % #GREEK_PHRASES)]
			UI_DrawGlyphRing(cx, cy, bandOuterMid, "MagicCircle_Small", phraseOuter, 0.30, 64, Color(220, 200, 150, 235), t * 0.08)
			-- Inner glyph band (slightly larger)
			local bandInnerMid = radius * 0.585
			local bandInnerIn = radius * 0.56
			local bandInnerOut = radius * 0.61
			thickCircle(bandInnerOut, 1)
			thickCircle(bandInnerIn, 1)
			local phraseInner = ARABIC_PHRASES[1 + (math.floor(t * 0.015 + 1) % #ARABIC_PHRASES)]
			UI_DrawGlyphRing(cx, cy, bandInnerMid, "MagicCircle_Small", phraseInner, 0.26, 48, Color(220, 200, 150, 210), -t * 0.06)
			surface.DisableClipping(false)
		end

		-- Weapon model preview centered in the circle
		local modelPanel = vgui.Create("DModelPanel", left)
		modelPanel:SetSize(360, 360)
		modelPanel:SetMouseInputEnabled(false)
		function modelPanel:LayoutEntity(ent) ent:SetAngles(Angle(0, CurTime() * 15 % 360, 0)) end

		local nameLabel = vgui.Create("DLabel", left)
		nameLabel:SetText("")
		nameLabel:SetFont("Arcana_Ancient")
		nameLabel:SetTextColor(textBright)
		nameLabel:SetContentAlignment(5)

		-- Controls area
		local controls = vgui.Create("DPanel", left)
		controls:Dock(BOTTOM)
		controls:SetTall(70)
		controls.Paint = function(pnl, w, h)
			Arcana_FillDecoPanel(8, h - 60, w - 16, 52, Color(46, 36, 26, 235), 10)
			Arcana_DrawDecoFrame(8, h - 60, w - 16, 52, gold, 10)
		end

		-- Forward declaration for preview setter used below
		local setPreviewForClass

		-- One toggle button: Deposit / Withdraw
		local toggleBtn = vgui.Create("DButton", controls)
		toggleBtn:SetSize(220, 36)
		toggleBtn:SetPos(20, 16)
		toggleBtn:SetText("")
		local function updateToggle()
			local cls = IsValid(machine) and machine:GetContainedClass() or ""
			toggleBtn._mode = (cls == "" and "deposit") or "withdraw"
		end
		function toggleBtn:Paint(w, h)
			updateToggle()
			local hovered = self:IsHovered()
			local bgCol = hovered and Color(58, 44, 32, 235) or Color(46, 36, 26, 235)
			Arcana_FillDecoPanel(0, 0, w, h, bgCol, 8)
			Arcana_DrawDecoFrame(0, 0, w, h, gold, 8)
			local label = (self._mode == "deposit") and "Deposit" or "Withdraw"
			draw.SimpleText(label, "Arcana_AncientLarge", w * 0.5, h * 0.5, textBright, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		end
		function toggleBtn:DoClick()
			updateToggle()
			if self._mode == "deposit" then
				net.Start("Arcana_Enchanter_Deposit")
				net.WriteEntity(machine)
				net.SendToServer()
			else
				net.Start("Arcana_Enchanter_Withdraw")
				net.WriteEntity(machine)
				net.SendToServer()
			end
			surface.PlaySound("buttons/button6.wav")
			timer.Simple(0.05, function()
				if IsValid(machine) then
					setPreviewForClass(machine:GetContainedClass() or "")
				end
			end)
		end

		-- Helper to derive model and name from weapon class
		setPreviewForClass = function(cls)
			if not cls or cls == "" then
				modelPanel:SetVisible(false)
				nameLabel:SetText("No weapon")
				return
			end

			modelPanel:SetVisible(true)
			local swep = weapons.GetStored(cls)
			local model = (swep and (swep.WorldModel or swep.ViewModel)) or "models/weapons/w_pistol.mdl"
			local nice = (swep and (swep.PrintName or swep.Printname)) or cls
			modelPanel:SetModel(model)
			nameLabel:SetText(nice)
			-- Camera setup
			local ent = modelPanel:GetEntity()
			if IsValid(ent) then
				local mn, mx = ent:GetRenderBounds()
				local size = (mx - mn):Length()
				modelPanel:SetFOV(32)
				modelPanel:SetCamPos(Vector(size, size, size * 0.5))
				modelPanel:SetLookAt((mn + mx) * 0.5)
			end
		end

		-- Position the model and name inside left panel (centered in the circle)
		left.PerformLayout = function(pnl, w, h)
			local cx, cy = w * 0.5, h * 0.44
			local radius = math.min(w, h) * 0.36
			local s = math.floor(radius * 1.5)
			modelPanel:SetSize(s, s)
			modelPanel:SetPos(math.floor(cx - s * 0.5), math.floor(cy - s * 0.5))
			nameLabel:SetSize(math.floor(w * 0.6), 24)
			nameLabel:SetPos(math.floor(cx - nameLabel:GetWide() * 0.5), math.floor(cy + radius + 8))
		end

		-- Initialize preview and keep it updated
		setPreviewForClass(IsValid(machine) and machine:GetContainedClass() or "")
		frame.Think = function()
			if not IsValid(machine) then frame:Close() return end
			local cls = machine:GetContainedClass() or ""
			if (modelPanel._cls or "") ~= cls then
				modelPanel._cls = cls
				setPreviewForClass(cls)
			end
		end

		-- Right: enchantment list
		local right = vgui.Create("DPanel", content)
		right:Dock(FILL)
		right.Paint = function(pnl, w, h)
			Arcana_FillDecoPanel(4, 4, w - 8, h - 8, decoPanel, 12)
			Arcana_DrawDecoFrame(4, 4, w - 8, h - 8, gold, 12)
			draw.SimpleText("Enchantments", "Arcana_Ancient", 14, 10, textBright)
		end

		local scroll = vgui.Create("DScrollPanel", right)
		scroll:Dock(FILL)
		scroll:DockMargin(12, 36, 12, 12)
		local vbar = scroll:GetVBar()
		vbar:SetWide(8)
		vbar.Paint = function(pnl, w, h)
			Arcana_FillDecoPanel(0, 0, w, h, decoPanel, 8)
			Arcana_DrawDecoFrame(0, 0, w, h, gold, 8)
		end
		vbar.btnGrip.Paint = function(pnl, w, h)
			surface.SetDrawColor(gold)
			surface.DrawRect(0, 0, w, h)
		end

		local function rebuild()
			scroll:Clear()
			local cls = IsValid(machine) and machine:GetContainedClass() or ""
			for enchId, ench in pairs(getEnchantmentsList()) do
				local row = vgui.Create("DPanel", scroll)
				row:Dock(TOP)
				row:SetTall(60)
				row:DockMargin(0, 0, 0, 8)
				row.Paint = function(pnl, w, h)
					Arcana_FillDecoPanel(2, 2, w - 4, h - 4, Color(46, 36, 26, 235), 8)
					Arcana_DrawDecoFrame(2, 2, w - 4, h - 4, gold, 8)
					draw.SimpleText(ench.name or enchId, "Arcana_AncientLarge", 12, 8, textBright)
					draw.SimpleText(ench.description or "", "Arcana_AncientSmall", 12, 34, textDim)
				end

				local apply = vgui.Create("DButton", row)
				apply:Dock(RIGHT)
				apply:DockMargin(6, 10, 10, 10)
				apply:SetWide(120)
				apply:SetText("")
				apply.Paint = function(pnl, w, h)
					local hovered = pnl:IsHovered()
					local bgCol = hovered and Color(58, 44, 32, 235) or Color(46, 36, 26, 235)
					Arcana_FillDecoPanel(0, 0, w, h, bgCol, 8)
					Arcana_DrawDecoFrame(0, 0, w, h, gold, 8)
					draw.SimpleText("Apply", "Arcana_AncientLarge", w * 0.5, h * 0.5, textBright, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
				end
				function apply:DoClick()
					if cls == "" then surface.PlaySound("buttons/button8.wav") return end
					net.Start("Arcana_Enchanter_Apply")
					net.WriteEntity(machine)
					net.WriteString(enchId)
					net.SendToServer()
					surface.PlaySound("buttons/button14.wav")
				end
				-- Cost chips
				local cost = vgui.Create("DLabel", row)
				cost:Dock(RIGHT)
				cost:DockMargin(6, 18, 6, 18)
				cost:SetWide(160)
				cost:SetFont("Arcana_AncientSmall")
				cost:SetTextColor(textDim)
				local items = {}
				if ench.cost_coins and ench.cost_coins > 0 then table.insert(items, tostring(ench.cost_coins) .. "c") end
				for _, it in ipairs(ench.cost_items or {}) do
					table.insert(items, string.format("%dx %s", it.amount or 1, it.name or "item"))
				end
				cost:SetText(table.concat(items, "  •  "))
			end
		end

		rebuild()

		-- frame.Think is defined above to live-update preview
	end

	net.Receive("Arcana_OpenEnchanterMenu", function()
		local ent = net.ReadEntity()
		if IsValid(ent) then OpenEnchanterMenu(ent) end
	end)
end


