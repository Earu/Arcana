-- Spellcraft: the Emissary menu.
--
-- Composing happens on one screen: the star map (graph.lua), a chart of every
-- form, element and modifier drawn against the Elysion nebula. Take stars by
-- clicking them, name the spell in the bar underneath, and pay the one-time
-- cost. Clicking the star at the centre opens the review card.
--
-- Selecting an occupied slot on the left shows that crafted spell's
-- details/requirements instead of the map.
--
-- Nothing is hidden on the map: stars you cannot take stay visible, dimmed, and
-- say WHY when hovered, no unexplained denials.
--
-- All numbers come from the shared Arcana.Spellcraft.Compile/.Requirements; the
-- server revalidates everything on submit. ACTIVATE uses an inline second-click
-- confirm; DELETE opens a red warning modal (enchanter style).

if not CLIENT then return end

Arcana = Arcana or {}
local P = Arcana.Spellcraft

-- Assigned when the menu opens; ArtDeco loads after this file (init.lua order),
-- so it must not be touched at include time.
local C

local function playDeny() surface.PlaySound("buttons/button8.wav") end
local function playClick() surface.PlaySound("buttons/button6.wav") end

----------------------------------------------------------------------
-- Themed background: dark stone, a divine glow descending from above,
-- and faint runes drifting upward, prayers rising to the gods.
----------------------------------------------------------------------
local GLYPH_MATS
local function getGlyphMats()
	if GLYPH_MATS then return GLYPH_MATS end
	GLYPH_MATS = {}

	-- DXT5 VTF rather than the PNG: a third of the VRAM, and it shares the upload
	-- with the ring glyph materials instead of adding a second BGRA8888 copy of
	-- all eight. Regenerate with tools/png_to_vtf.py.
	for i = 65, 72 do
		GLYPH_MATS[#GLYPH_MATS + 1] = CreateMaterial("arcana_spellcraft_glyph_" .. i, "UnlitGeneric", {
			["$basetexture"] = "arcana/glyphs/glyph_" .. i,
			["$translucent"] = 1,
			["$vertexalpha"] = 1,
			["$vertexcolor"] = 1,
		})
	end

	return GLYPH_MATS
end

local function drawEmissaryBackground(w, h, seed)
	-- Clip everything to the art-deco octagon using the stencil buffer.
	local x, y = 6, 6
	local ww, hh = w - 12, h - 12
	local corner = 14
	local pts = {
		{ x = x + corner, y = y },
		{ x = x + ww - corner, y = y },
		{ x = x + ww, y = y + corner },
		{ x = x + ww, y = y + hh - corner },
		{ x = x + ww - corner, y = y + hh },
		{ x = x + corner, y = y + hh },
		{ x = x, y = y + hh - corner },
		{ x = x, y = y + corner },
	}

	render.ClearStencil()
	render.SetStencilEnable(true)
	render.SetStencilWriteMask(0xFF)
	render.SetStencilTestMask(0xFF)
	render.SetStencilReferenceValue(1)
	render.SetStencilCompareFunction(STENCIL_NEVER)
	render.SetStencilFailOperation(STENCIL_REPLACE)
	render.SetStencilPassOperation(STENCIL_KEEP)
	render.SetStencilZFailOperation(STENCIL_KEEP)

	draw.NoTexture()
	surface.SetDrawColor(255, 255, 255, 255)
	surface.DrawPoly(pts)

	render.SetStencilCompareFunction(STENCIL_EQUAL)
	render.SetStencilFailOperation(STENCIL_KEEP)
	render.SetStencilPassOperation(STENCIL_REPLACE)

	-- Deep warm stone base
	surface.SetDrawColor(15, 11, 8, 245)
	surface.DrawRect(x, y, ww, hh)

	-- Divine glow bleeding down from above the frame
	local gx = x + ww * 0.5
	local gy = y - hh * 0.25
	local maxR = hh * 1.05
	for k = math.floor(maxR), 8, -10 do
		local a = 16 * (1 - k / maxR)
		surface.DrawCircle(gx, gy, k, 222, 180, 100, a)
	end

	-- Rising runes (stable per-seed layout, animated by time)
	local mats = getGlyphMats()
	math.randomseed(seed or 1)
	for i = 1, 12 do
		local mat = mats[math.random(1, #mats)]
		local rx = x + math.random(24, ww - 24)
		local baseY = math.random(0, hh)
		local speed = math.Rand(5, 12)
		local size = math.random(36, 84)
		local rot = math.Rand(-10, 10)
		local ry = y + ((baseY - RealTime() * speed) % (hh + size)) - size * 0.5
		surface.SetDrawColor(222, 185, 110, 9 + (i % 3) * 4)
		surface.SetMaterial(mat)
		surface.DrawTexturedRectRotated(rx, ry, size, size, rot)
	end

	-- Restore the global RNG: leaving it seeded makes every math.random
	-- caller this frame (world VFX included) repeat the same sequence
	math.randomseed(SysTime())

	render.SetStencilEnable(false)
end

-- The deco frame's octagon, laid out as dots instead of a solid line. Walks the
-- same eight edges as ArtDeco.DrawDecoFrame so the two read as the same shape.
--
-- Dots rather than short DrawLine dashes: at icon size a dash is two pixels
-- long, and DrawLine renders those unevenly once the ends land off the pixel
-- grid. Square dots snapped to whole pixels come out identical every time.
--
-- Each edge is spaced on its own and skips its end point, so the corners get
-- exactly one dot. Equal-length edges then get equal counts, which is what
-- keeps the ring symmetric. Spacing it around the perimeter as one continuous
-- run divides more evenly but lands the dots in a pinwheel.
--
-- Positions are rounded, not truncated: truncating biases every dot up and to
-- the left, which shows up as the two halves of the ring not matching.
local DOTTED_PTS = {}
for i = 1, 8 do DOTTED_PTS[i] = { 0, 0 } end

local function drawDottedDecoFrame(x, y, w, h, col, corner, spacing, dot)
	local c = math.max(4, corner or 12)
	spacing = spacing or 4.4
	dot = dot or 2

	local p = DOTTED_PTS
	p[1][1], p[1][2] = x + c, y
	p[2][1], p[2][2] = x + w - c, y
	p[3][1], p[3][2] = x + w, y + c
	p[4][1], p[4][2] = x + w, y + h - c
	p[5][1], p[5][2] = x + w - c, y + h
	p[6][1], p[6][2] = x + c, y + h
	p[7][1], p[7][2] = x, y + h - c
	p[8][1], p[8][2] = x, y + c

	surface.SetDrawColor(col.r, col.g, col.b, col.a or 255)

	local half = dot * 0.5
	for i = 1, 8 do
		local a, b = p[i], p[i % 8 + 1]
		local dx, dy = b[1] - a[1], b[2] - a[2]
		local len = math.sqrt(dx * dx + dy * dy)
		if len > 0.5 then
			local n = math.max(2, math.Round(len / spacing))
			for k = 0, n - 1 do
				local t = k / n
				surface.DrawRect(math.Round(a[1] + dx * t - half), math.Round(a[2] + dy * t - half), dot, dot)
			end
		end
	end
end

-- Wrap text into lines that fit maxW (for descriptions).
local function wrapText(font, text, maxW)
	surface.SetFont(font)
	local lines, cur = {}, ""
	for word in string.gmatch(text or "", "%S+") do
		local trial = cur == "" and word or (cur .. " " .. word)
		local tw = surface.GetTextSize(trial)
		if tw > maxW and cur ~= "" then
			lines[#lines + 1] = cur
			cur = word
		else
			cur = trial
		end
	end
	if cur ~= "" then lines[#lines + 1] = cur end
	return lines
end

local function sid()
	local ply = LocalPlayer()
	return IsValid(ply) and ply:SteamID64() or ""
end

local function activeDefForSlot(slot)
	local mine = P.ClientActive[sid()]
	return mine and mine[slot] or nil
end

local function activeNameForSlot(slot)
	local spell = Arcana.RegisteredSpells[P.SpellId(sid(), slot)]
	return spell and spell.name or "Crafted Spell"
end

local function isConsecrated(def)
	return P.GetClientState().consecrated[P.DefHash(def)] == true
end

-- Composer state -> definition table (clause ranks become a repetition list).
local function buildDef(state)
	local clauses = {}
	for _, clause in ipairs(P.SortedClauses()) do
		for _ = 1, (state.clauseRanks[clause.id] or 0) do
			clauses[#clauses + 1] = clause.id
		end
	end
	return { form = state.form, essence = state.essence, clauses = clauses }
end

----------------------------------------------------------------------
-- Small building blocks
----------------------------------------------------------------------
local function clearChildren(pnl)
	for _, child in ipairs(pnl:GetChildren()) do
		child:Remove()
	end
end

local function decoButton(parent, opts)
	local b = vgui.Create("DButton", parent)
	b:SetText("")
	b.Paint = function(pnl, w, h)
		local enabled = opts.enabled == nil or opts.enabled()
		local hovered = enabled and pnl:IsHovered()
		local bg = hovered and Color(58, 44, 32, 235) or Color(46, 36, 26, 235)
		ArtDeco.FillDecoPanel(0, 0, w, h, bg, 6)
		local frameCol = opts.frameColor and opts.frameColor() or (enabled and C.gold or Color(120, 105, 80))
		ArtDeco.DrawDecoFrame(0, 0, w, h, frameCol, 6)
		local label = isfunction(opts.label) and opts.label() or opts.label
		draw.SimpleText(label, opts.font or "Arcana_Ancient", w * 0.5, h * 0.5, enabled and C.textBright or Color(160, 150, 135), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
	end
	b.DoClick = function()
		if opts.enabled ~= nil and not opts.enabled() then playDeny() return end
		opts.onClick()
	end
	return b
end

-- A button that requires a second click within 4s to fire (spending actions).
local function confirmButton(parent, label, confirmLabel, onConfirm, frameColor)
	local armedUntil = 0
	return decoButton(parent, {
		label = function()
			return CurTime() < armedUntil and confirmLabel or label
		end,
		frameColor = function()
			return CurTime() < armedUntil and Color(220, 120, 80) or (frameColor or C.gold)
		end,
		onClick = function()
			if CurTime() < armedUntil then
				armedUntil = 0
				playClick()
				onConfirm()
			else
				armedUntil = CurTime() + 4
				playClick()
			end
		end,
	})
end

-- Small drawn status marker (custom fonts may not carry check glyphs).
local function drawMark(x, y, ok)
	if ok then
		surface.SetDrawColor(110, 210, 110, 255)
	else
		surface.SetDrawColor(220, 100, 80, 255)
	end
	surface.DrawRect(x, y + 4, 10, 10)
	surface.SetDrawColor(C.gold)
	surface.DrawOutlinedRect(x, y + 4, 10, 10)
end

-- Red warning modal (adapted from the enchanter's classification warning):
-- dim overlay, pulsing red frame, explicit DELETE / CANCEL buttons.
local function showDeleteModal(parent, spellName, onConfirm)
	local overlay = vgui.Create("DPanel", parent)
	overlay:SetPos(0, 0)
	overlay:SetSize(parent:GetWide(), parent:GetTall())
	overlay:SetZPos(9999)
	overlay:MoveToFront()
	overlay:SetMouseInputEnabled(true)
	overlay.Paint = function(_, w, h)
		surface.SetDrawColor(0, 0, 0, 170)
		surface.DrawRect(0, 0, w, h)
	end

	local inner = vgui.Create("DPanel", overlay)
	inner:SetSize(480, 210)
	inner:Center()
	inner.Paint = function(_, w, h)
		ArtDeco.FillDecoPanel(0, 0, w, h, Color(20, 10, 10, 245), 10)

		local pulse = math.abs(math.sin(CurTime() * 3.5))
		local edgeR = math.floor(200 + pulse * 55)
		surface.SetDrawColor(edgeR, 20, 20, math.floor(60 + pulse * 80))
		surface.DrawOutlinedRect(0, 0, w, h, 4)
		surface.DrawOutlinedRect(3, 3, w - 6, h - 6, 2)

		draw.SimpleText("DELETE SPELL", "Arcana_AncientLarge", w * 0.5, 22, Color(edgeR, 60, 60), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		surface.SetDrawColor(edgeR, 40, 40, 160)
		surface.DrawRect(20, 42, w - 40, 1)

		draw.SimpleText(spellName, "Arcana_Ancient", w * 0.5, 62, C.textBright, TEXT_ALIGN_CENTER)
		draw.SimpleText("This spell will be destroyed. There is no refund.", "Arcana_Ancient", w * 0.5, 92, Color(230, 200, 200), TEXT_ALIGN_CENTER)
	end

	local function modalButton(label, red, onClick)
		local b = vgui.Create("DButton", inner)
		b:SetText("")
		b:SetSize(190, 36)
		b.Paint = function(pnl, w, h)
			local hovered = pnl:IsHovered()
			local bg = red and (hovered and Color(80, 20, 20, 245) or Color(50, 15, 15, 245))
				or (hovered and Color(58, 44, 32, 235) or Color(46, 36, 26, 235))
			ArtDeco.FillDecoPanel(0, 0, w, h, bg, 8)
			ArtDeco.DrawDecoFrame(0, 0, w, h, red and Color(200, 60, 60) or C.gold, 8)
			draw.SimpleText(label, "Arcana_Ancient", w * 0.5, h * 0.5, red and Color(255, 200, 200) or C.textBright, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		end
		b.DoClick = onClick
		return b
	end

	local cancel = modalButton("CANCEL", false, function()
		playClick()
		overlay:Remove()
	end)

	local del = modalButton("DELETE", true, function()
		surface.PlaySound("buttons/button6.wav")
		overlay:Remove()
		onConfirm()
	end)

	inner.PerformLayout = function(_, w, h)
		cancel:SetPos(math.floor(w * 0.5 - 190 - 8), h - 52)
		del:SetPos(math.floor(w * 0.5 + 8), h - 52)
	end

	parent.OnSizeChanged = function(_, w, h)
		overlay:SetSize(w, h)
		inner:Center()
	end
end

-- Gold sibling of the delete modal: confirms buying an element off the map.
local function showUnlockModal(parent, essence, onConfirm)
	local overlay = vgui.Create("DPanel", parent)
	overlay:SetPos(0, 0)
	overlay:SetSize(parent:GetWide(), parent:GetTall())
	overlay:SetZPos(9999)
	overlay:MoveToFront()
	overlay:SetMouseInputEnabled(true)
	overlay.Paint = function(_, w, h)
		surface.SetDrawColor(0, 0, 0, 170)
		surface.DrawRect(0, 0, w, h)
	end

	local ec = essence.color
	local inner = vgui.Create("DPanel", overlay)
	inner:SetSize(480, 230)
	inner:Center()
	inner.Paint = function(_, w, h)
		ArtDeco.FillDecoPanel(0, 0, w, h, Color(20, 15, 10, 245), 10)
		ArtDeco.DrawDecoFrame(0, 0, w, h, C.gold, 10)

		draw.SimpleText("BUY AN ELEMENT", "Arcana_AncientLarge", w * 0.5, 22, C.paleGold, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		surface.SetDrawColor(C.gold.r, C.gold.g, C.gold.b, 160)
		surface.DrawRect(20, 42, w - 40, 1)

		local cx = w * 0.5 - 70
		P.Graph.DrawElementOrnament(essence.id, cx, 68, Color(ec.r, ec.g, ec.b), 1.4)
		draw.SimpleText(essence.label, "Arcana_Ancient", cx + 20, 68, Color(ec.r, ec.g, ec.b), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		draw.SimpleText(essence.desc or "", "Arcana_AncientSmall", w * 0.5, 96, C.textDim, TEXT_ALIGN_CENTER)
		draw.SimpleText("You keep it for good, on every spell you make.", "Arcana_AncientSmall", w * 0.5, 116, C.textDim, TEXT_ALIGN_CENTER)

		ArtDeco.DrawCostLine("Arcana_Ancient", w * 0.5, 140, {
			{ text = string.Comma(essence.unlock.coins), icon = ArtDeco.Icons.coin, color = C.coinGold },
			{ text = string.Comma(essence.unlock.shards), icon = ArtDeco.Icons.shard, color = C.shardBlue },
		}, TEXT_ALIGN_CENTER)
	end

	local function modalButton(label, onClick)
		local b = vgui.Create("DButton", inner)
		b:SetText("")
		b:SetSize(190, 36)
		b.Paint = function(pnl, w, h)
			local hovered = pnl:IsHovered()
			ArtDeco.FillDecoPanel(0, 0, w, h, hovered and Color(58, 44, 32, 235) or Color(46, 36, 26, 235), 8)
			ArtDeco.DrawDecoFrame(0, 0, w, h, C.gold, 8)
			draw.SimpleText(label, "Arcana_Ancient", w * 0.5, h * 0.5, C.textBright, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		end
		b.DoClick = onClick
		return b
	end

	local cancel = modalButton("CANCEL", function()
		playClick()
		overlay:Remove()
	end)

	local buy = modalButton("BUY", function()
		playClick()
		overlay:Remove()
		onConfirm()
	end)

	inner.PerformLayout = function(_, w, h)
		cancel:SetPos(math.floor(w * 0.5 - 190 - 8), h - 52)
		buy:SetPos(math.floor(w * 0.5 + 8), h - 52)
	end

	parent.OnSizeChanged = function(_, w, h)
		overlay:SetSize(w, h)
		inner:Center()
	end
end

----------------------------------------------------------------------
-- The menu
----------------------------------------------------------------------
local function OpenSpellcraftMenu(machine)
	local ply = LocalPlayer()
	if not IsValid(ply) then return end
	C = ArtDeco.Colors

	-- rev is bumped by the star map whenever the composition changes, so the
	-- map's derived node state and the compiled preview refresh without a
	-- full VGUI rebuild. view is the map's camera, kept across refreshes.
	local state = {
		selSlot = 1,
		form = nil,
		essence = nil,
		clauseRanks = {},
		name = "",
		rev = 0,
		view = nil,
	}

	-- Capped at 720p, and smaller than that only if the screen is.
	local frame = vgui.Create("DFrame")
	frame:SetSize(math.min(1280, ScrW()), math.min(720, ScrH()))
	frame:Center()
	frame:SetTitle("")
	frame:MakePopup()

	-- Draggable by the whole header band (the stock strip is too thin).
	-- The cursor signals the band on hover and the drag while it lasts.
	frame:SetDraggable(false)
	frame.OnMousePressed = function(pnl, code)
		if code ~= MOUSE_LEFT then return end
		local mx, my = pnl:ScreenToLocal(gui.MouseX(), gui.MouseY())
		if my <= 44 then
			pnl._dragOffset = {mx, my}
			pnl:MouseCapture(true)
			pnl:SetCursor("sizeall")
		end
	end
	frame.OnMouseReleased = function(pnl)
		pnl._dragOffset = nil
		pnl:MouseCapture(false)
		local _, my = pnl:ScreenToLocal(gui.MouseX(), gui.MouseY())
		pnl:SetCursor(my <= 44 and "sizeall" or "arrow")
	end
	frame.OnCursorMoved = function(pnl)
		if pnl._dragOffset then
			local mx, my = gui.MousePos()
			pnl:SetPos(
				math.Clamp(mx - pnl._dragOffset[1], 0, ScrW() - pnl:GetWide()),
				math.Clamp(my - pnl._dragOffset[2], 0, ScrH() - pnl:GetTall()))

			return
		end

		local _, my = pnl:ScreenToLocal(gui.MouseX(), gui.MouseY())
		pnl:SetCursor(my <= 44 and "sizeall" or "arrow")
	end

	local bgSeed = math.random(1, 10 ^ 9)

	hook.Add("HUDPaint", frame, function()
		local x, y = frame:LocalToScreen(0, 0)
		ArtDeco.DrawBlurRect(x + 6, y + 6, frame:GetWide() - 12, frame:GetTall() - 12, 4, 8)
	end)

	ArtDeco.StyleCloseButton(frame)
	if IsValid(frame.btnMinim) then frame.btnMinim:Hide() end
	if IsValid(frame.btnMaxim) then frame.btnMaxim:Hide() end

	-- Tell the station its menu closed so it can wind down its ceremony
	frame.OnClose = function()
		if IsValid(machine) then
			net.Start("Arcana_CloseEmissaryMenu")
			net.WriteEntity(machine)
			net.SendToServer()
		end
	end

	frame.OnRemove = frame.OnClose

	-- Declared here so the title can measure the band down to the panels' frames.
	local content

	frame.Paint = function(_, w, h)
		drawEmissaryBackground(w, h, bgSeed)
		ArtDeco.DrawDecoFrame(6, 6, w - 12, h - 12, C.gold, 14)

		-- The title centers in the band between the frame's top line and the map
		-- below, which frames itself at the content's top edge. The controls ride
		-- along the far end of the same band: one strip of chrome, not two.
		local bandTop = 6 + 1
		local bandBottom = IsValid(content) and content:GetY() or (bandTop + 38)
		local titleRight = ArtDeco.DrawTitle("Arcana_AncientLarge", "THE EMISSARY", bandTop, bandBottom, C.paleGold)

		-- Dropped rather than crammed if the frame is too narrow to hold both.
		local hint = "Drag to look around  ·  Scroll to zoom  ·  Left-click takes, right-click gives back"
		surface.SetFont("Arcana_AncientSmall")
		local hintW = surface.GetTextSize(hint)
		if w - 46 - hintW > titleRight + 24 then
			draw.SimpleText(hint, "Arcana_AncientSmall", w - 46, (bandTop + bandBottom) * 0.5, C.textDim, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
		end
	end

	content = vgui.Create("DPanel", frame)
	content:Dock(FILL)
	content:DockMargin(12, 12, 12, 12)
	content.Paint = nil

	local refresh -- forward declaration; single rebuild entry point

	----------------------------------------------------------------
	-- Slot bookkeeping. Selecting a slot loads whatever is in it onto the
	-- map, so an existing spell opens up as an editable chart rather than a
	-- read-only card. baseHash/baseName record what was saved, which is how
	-- we know whether anything has actually been reworked.
	----------------------------------------------------------------
	local function loadSlot(slot)
		state.selSlot = slot
		state.clauseRanks = {}
		state.lastDefaultName = nil

		local def = activeDefForSlot(slot)
		if def then
			state.form = def.form
			state.essence = def.essence
			for _, id in ipairs(def.clauses or {}) do
				state.clauseRanks[id] = (state.clauseRanks[id] or 0) + 1
			end
			state.name = activeNameForSlot(slot)
			state.baseHash = P.DefHash(def)
			state.baseName = state.name
		else
			state.form = nil
			state.essence = nil
			state.name = ""
			state.baseHash = nil
			state.baseName = nil
		end

		state.rev = (state.rev or 0) + 1
	end

	local function currentName()
		if IsValid(state.nameEntry) then return string.Trim(state.nameEntry:GetValue() or "") end
		return string.Trim(state.name or "")
	end

	-- True when the chart no longer matches the spell saved in this slot.
	local function isModified()
		if not state.baseHash then return true end -- an empty slot is always "new"
		if currentName() ~= state.baseName then return true end
		if not (state.form and state.essence) then return true end
		return P.DefHash(buildDef(state)) ~= state.baseHash
	end

	local function currentPoints()
		local pts = 0
		local form = P.Forms[state.form]
		if form then pts = pts + form.points end
		local essence = P.Essences[state.essence]
		if essence then pts = pts + essence.points end
		for id, rank in pairs(state.clauseRanks) do
			local cl = P.Clauses[id]
			if cl then pts = pts + cl.points * rank end
		end
		return pts
	end

	local function slotCount()
		local n = 0
		for _, r in pairs(state.clauseRanks) do n = n + r end
		return n
	end

	----------------------------------------------------------------
	-- Slot strip: one octagon per slot, sitting over the top-left of the
	-- map. Filled means a spell lives there, hollow means the slot is free.
	----------------------------------------------------------------
	local function buildSlotStrip(host)
		local maxSlots = P.GetClientState().maxSlots or 3
		-- Odd size on purpose: the icon spans pixels 0..34, so its centre is a
		-- whole pixel and the number lands dead centre instead of on a half.
		local size, gap = 35, 8

		local strip = vgui.Create("DPanel", host)
		strip:SetZPos(400)
		strip:SetSize(maxSlots * (size + gap) - gap, size)
		strip:SetPos(10, 10)
		strip.Paint = nil

		for i = 1, maxSlots do
			local btn = vgui.Create("DButton", strip)
			btn:SetPos((i - 1) * (size + gap), 0)
			btn:SetSize(size, size)
			btn:SetText("")
			btn:SetCursor("hand")

			local occupied = activeDefForSlot(i) ~= nil
			local label = occupied and activeNameForSlot(i) or "Empty slot"
			ArtDeco.AddTooltip(btn, label .. (occupied and "" or ".  Pick it to start a new spell."), 240)

			-- Centred by measuring the number and placing it on whole pixels.
			-- TEXT_ALIGN_CENTER lands on a half pixel whenever the glyph width is
			-- odd, and the digit then renders a pixel off inside a 35px icon.
			local numeral = tostring(i)
			local function drawNumber(w, h, col)
				surface.SetFont("Arcana_Ancient")
				local tw, th = surface.GetTextSize(numeral)
				draw.SimpleText(numeral, "Arcana_Ancient",
					math.floor((w - tw) * 0.5), math.floor((h - th) * 0.5), col)
			end

			btn.Paint = function(pnl, w, h)
				local sel = state.selSlot == i
				local hovered = pnl:IsHovered()
				-- 0.2071 is the cut that turns a square into a regular octagon.
				-- Anything larger reads as a rounded blob at this size.
				local corner = math.Round(w * 0.2071)

				-- Filled when the slot holds a spell, hollow when it is free.
				if occupied then
					local fill = sel and C.paleGold or (hovered and C.gold or Color(150, 120, 56))
					ArtDeco.FillDecoPanel(0, 0, w, h, fill, corner)
					ArtDeco.DrawDecoFrame(0, 0, w, h, sel and Color(255, 255, 255) or C.gold, corner)
					drawNumber(w, h, Color(24, 18, 10))
				else
					-- Free slots wear a dotted outline: an open space, not a thing.
					-- Inset by one so the dots, which straddle the path they sit on,
					-- land inside the icon instead of hanging off its left and top.
					ArtDeco.FillDecoPanel(0, 0, w, h, Color(20, 15, 10, 200), corner)
					drawDottedDecoFrame(1, 1, w - 2, h - 2, sel and Color(255, 255, 255) or (hovered and C.paleGold or Color(130, 112, 74)), corner)
					drawNumber(w, h, sel and C.paleGold or C.textDim)
				end
			end

			btn.DoClick = function()
				if state.selSlot == i then return end
				playClick()
				loadSlot(i)
				refresh()
			end
		end

		return strip
	end

	----------------------------------------------------------------
	-- Sidebar: everything about the spell you are looking at, floating over
	-- the right of the map and rebuilt from the live selection every frame.
	----------------------------------------------------------------
	local SIDEBAR_W = 340

	local function buildSidebar(host)
		local pad = 14
		local innerW = SIDEBAR_W - pad * 2

		local bar = vgui.Create("DPanel", host)
		bar:SetZPos(400)

		-- Compiled only when the composition actually changes. The column paints
		-- every frame, so nothing here may recompile on a whim.
		local compiled, liveDef, req, compiledRev
		local function currentCompiled()
			if compiledRev ~= state.rev then
				compiledRev = state.rev
				liveDef = buildDef(state)
				compiled = (state.form and state.essence) and P.Compile(liveDef) or nil

				if compiled then
					local cs = P.GetClientState()
					cs.consecrated = isConsecrated(liveDef)
					req = P.Requirements(liveDef, cs)
				else
					req = nil
				end

				-- Default name follows the composition until the player types
				-- their own, and never overwrites a saved spell's name.
				local defaultName = compiled and (P.Essences[compiled.essence].label .. " " .. P.Forms[compiled.form].label) or ""
				if defaultName ~= "" and not state.baseHash then
					if state.name == "" or state.name == state.lastDefaultName then
						state.name = defaultName
						if IsValid(state.nameEntry) and not state.nameEntry:HasFocus() then
							state.nameEntry:SetValue(defaultName)
						end
					end
					state.lastDefaultName = defaultName
				end
			end
			return compiled
		end

		local function canSubmit()
			local c = currentCompiled()
			if not c then return false end
			if c.points > P.Budget(P.GetClientState().level) then return false end
			if #currentName() < 3 then return false end
			return isModified()
		end

		----------------------------------------------------------------
		-- Name entry lives at the top of the column
		----------------------------------------------------------------
		local nameEntry = vgui.Create("DTextEntry", bar)
		state.nameEntry = nameEntry
		nameEntry:SetFont("Arcana_Ancient")
		nameEntry:SetMaximumCharCount(24)
		nameEntry:SetValue(state.name)
		nameEntry:SetTextColor(C.textBright)
		nameEntry:SetCursorColor(C.paleGold)
		nameEntry:SetHighlightColor(Color(198, 160, 74, 120))
		nameEntry:SetPaintBackground(false)
		nameEntry:SetTextInset(10, 0)
		nameEntry.OnChange = function(pnl) state.name = pnl:GetValue() or "" end
		nameEntry.Paint = function(pnl, w, h)
			ArtDeco.FillDecoPanel(0, 0, w, h, Color(32, 24, 17, 235), 6)
			ArtDeco.DrawDecoFrame(0, 0, w, h, pnl:HasFocus() and C.paleGold or C.gold, 6)
			pnl:DrawTextEntryText(C.textBright, C.paleGold, C.textBright)
		end

		----------------------------------------------------------------
		-- Buttons, stacked up from the bottom
		----------------------------------------------------------------
		local wasOccupied = activeDefForSlot(state.selSlot) ~= nil

		local submit = vgui.Create("DButton", bar)
		submit:SetText("")
		submit.Paint = function(pnl, w, h)
			local c = currentCompiled()
			local enabled = canSubmit()
			local hovered = enabled and pnl:IsHovered()
			ArtDeco.FillDecoPanel(0, 0, w, h, hovered and Color(58, 44, 32, 235) or Color(46, 36, 26, 235), 6)
			ArtDeco.DrawDecoFrame(0, 0, w, h, enabled and C.gold or Color(120, 105, 80), 6)

			local txtCol = enabled and C.textBright or Color(160, 150, 135)
			draw.SimpleText(wasOccupied and "SAVE CHANGES" or "CREATE SPELL", "Arcana_Ancient", w * 0.5, h * 0.5 - 9, txtCol, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)

			if not c then
				draw.SimpleText("Pick a form and an element", "Arcana_AncientSmall", w * 0.5, h * 0.5 + 9, C.textDim, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
			elseif wasOccupied and not isModified() then
				draw.SimpleText("No changes yet", "Arcana_AncientSmall", w * 0.5, h * 0.5 + 9, C.textDim, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
			else
				ArtDeco.DrawCostLine("Arcana_AncientSmall", w * 0.5, h * 0.5 + 2, {
					{text = string.Comma(c.consecrationCoins), icon = ArtDeco.Icons.coin, color = enabled and C.coinGold or C.textDim},
					{text = string.Comma(c.consecrationShards), icon = ArtDeco.Icons.shard, color = enabled and C.shardBlue or C.textDim},
				}, TEXT_ALIGN_CENTER)
			end
		end
		submit.DoClick = function()
			if not canSubmit() then playDeny() return end
			state.name = currentName()
			local def = buildDef(state)
			net.Start("Arcana_Spellcraft_Submit")
			net.WriteUInt(state.selSlot, 8)
			net.WriteString(state.name)
			net.WriteString(def.form)
			net.WriteString(def.essence)
			net.WriteUInt(#def.clauses, 8)
			for _, id in ipairs(def.clauses) do net.WriteString(id) end
			net.SendToServer()
			playClick()
		end

		local activate, deleteBtn
		if wasOccupied then
			activate = confirmButton(bar, "ACTIVATE", "CONFIRM PAYMENT?", function()
				net.Start("Arcana_Spellcraft_Consecrate")
				net.WriteUInt(state.selSlot, 8)
				net.SendToServer()
			end)

			deleteBtn = decoButton(bar, {
				label = "DELETE",
				font = "Arcana_AncientSmall",
				frameColor = function() return Color(170, 80, 60) end,
				onClick = function()
					playClick()
					local slot = state.selSlot
					showDeleteModal(frame, activeNameForSlot(slot), function()
						net.Start("Arcana_Spellcraft_Dissolve")
						net.WriteUInt(slot, 8)
						net.SendToServer()
					end)
				end,
			})
		end

		-- ACTIVATE only makes sense while the chart matches what is saved:
		-- once you rework it, saving is what pays for the new form.
		local function activateVisible()
			if not wasOccupied then return false end
			if isModified() then return false end
			local def = activeDefForSlot(state.selSlot)
			return def ~= nil and not isConsecrated(def)
		end

		local function layoutButtons()
			local w, h = bar:GetSize()
			local y = h - pad

			local function place(btn, tall)
				if not IsValid(btn) or not btn:IsVisible() then return end
				y = y - tall
				btn:SetPos(pad, y)
				btn:SetSize(w - pad * 2, tall)
				y = y - 8
			end

			place(deleteBtn, 30)
			place(activate, 34)
			place(submit, 48)

			bar._buttonsTop = y
		end

		bar.PerformLayout = function(pnl, w)
			nameEntry:SetPos(pad, 34)
			nameEntry:SetSize(w - pad * 2, 32)
			layoutButtons()
		end

		-- ACTIVATE comes and goes as the chart is reworked, so re-stack when it
		-- does. This runs through _extraThink because anchor() owns Think.
		bar._extraThink = function()
			if not activate then return end
			local want = activateVisible()
			if activate:IsVisible() ~= want then
				activate:SetVisible(want)
				layoutButtons()
			end
		end
		if activate then activate:SetVisible(activateVisible()) end

		----------------------------------------------------------------
		-- The column itself
		----------------------------------------------------------------
		bar.Paint = function(pnl, w, h)
			ArtDeco.FillDecoPanel(0, 0, w, h, Color(16, 12, 8, 232), 10)
			ArtDeco.DrawDecoFrame(0, 0, w, h, C.gold, 10)

			local c = currentCompiled()
			local essence = c and P.Essences[c.essence]
			local tint = essence and Color(essence.color.r, essence.color.g, essence.color.b) or C.paleGold

			draw.SimpleText("NAME", "Arcana_AncientSmall", pad, 14, C.paleGold)

			local y = 78

			if not c then
				-- The button below already says what to go and pick, so this only
				-- explains what the column is for.
				draw.SimpleText("Nothing composed yet.", "Arcana_Ancient", pad, y, C.textDim)
				y = y + 26
				for _, lineTxt in ipairs(wrapText("Arcana_AncientSmall", "This column fills in as you take nodes off the map.", innerW)) do
					draw.SimpleText(lineTxt, "Arcana_AncientSmall", pad, y, C.textDim)
					y = y + 17
				end
				return
			end

			-- Composition line
			local form = P.Forms[c.form]
			draw.SimpleText(essence.label .. " " .. form.label, "Arcana_Ancient", pad, y, tint)
			y = y + 26

			for _, lineTxt in ipairs(wrapText("Arcana_AncientSmall", form.desc .. " " .. (essence.desc or ""), innerW)) do
				draw.SimpleText(lineTxt, "Arcana_AncientSmall", pad, y, C.textDim)
				y = y + 16
			end
			y = y + 10

			-- Modifier chips
			draw.SimpleText("MODIFIERS", "Arcana_AncientSmall", pad, y, C.paleGold)
			draw.SimpleText(slotCount() .. "/" .. P.MAX_CLAUSE_SLOTS, "Arcana_AncientSmall", w - pad, y, C.textDim, TEXT_ALIGN_RIGHT)
			y = y + 20

			local chipX, anyMod = pad, false
			surface.SetFont("Arcana_AncientSmall")
			for _, clause in ipairs(P.SortedClauses()) do
				local rank = c.ranks[clause.id]
				if rank then
					anyMod = true
					local label = clause.label .. (rank > 1 and (" " .. rank) or "")
					local tw = surface.GetTextSize(label)
					if chipX + tw + 18 > w - pad then
						chipX = pad
						y = y + 26
					end
					ArtDeco.FillDecoPanel(chipX, y, tw + 18, 22, C.cardIdle, 4)
					ArtDeco.DrawDecoFrame(chipX, y, tw + 18, 22, C.gold, 4)
					draw.SimpleText(label, "Arcana_AncientSmall", chipX + 9, y + 3, C.paleGold)
					chipX = chipX + tw + 24
				end
			end
			if not anyMod then
				draw.SimpleText("None", "Arcana_AncientSmall", pad, y + 3, C.textDim)
			end
			y = y + 34

			-- Stats, one per row: label left, value right.
			local function stat(label, value, gold, icon)
				draw.SimpleText(label, "Arcana_AncientSmall", pad, y, C.textDim)
				if icon then
					ArtDeco.DrawCostLine("Arcana_AncientSmall", w - pad, y, {
						{text = value, icon = icon, color = gold and C.coinGold or C.textBright},
					}, TEXT_ALIGN_RIGHT)
				else
					draw.SimpleText(value, "Arcana_AncientSmall", w - pad, y, gold and C.paleGold or C.textBright, TEXT_ALIGN_RIGHT)
				end
				y = y + 19
			end

			if c.isSelf then
				stat("DAMAGE", math.Round(c.damage) .. "/s")
				stat("RADIUS", tostring(math.Round(c.radius)))
				stat("DURATION", c.duration .. "s")
			else
				local dmg = math.Round(c.damage * (c.projectiles or 1))
				stat("DAMAGE", dmg .. ((c.projectiles or 1) > 1 and (" x" .. c.projectiles) or ""))
				stat("RADIUS", tostring(math.Round(c.radius)))
				stat("RANGE", tostring(math.Round(c.range)))
			end
			stat("COOLDOWN", ("%.1fs"):format(c.cooldown))
			stat("CAST", ("%.1fs"):format(c.castTime))
			stat("PER CAST", string.Comma(c.perCastCost), true, ArtDeco.Icons.coin)
			y = y + 10

			-- Power gauge
			local budget = P.Budget(P.GetClientState().level)
			local points = currentPoints()
			local over = points > budget
			draw.SimpleText("POWER", "Arcana_AncientSmall", pad, y, C.paleGold)
			draw.SimpleText(points .. " / " .. budget, "Arcana_AncientSmall", w - pad, y, over and Color(220, 110, 90) or C.textBright, TEXT_ALIGN_RIGHT)
			y = y + 19
			surface.SetDrawColor(46, 36, 26, 235)
			surface.DrawRect(pad, y, innerW, 12)
			surface.SetDrawColor(over and Color(200, 80, 60, 220) or C.xpFill)
			surface.DrawRect(pad + 2, y + 2, math.floor((innerW - 4) * math.Clamp(points / math.max(1, budget), 0, 1)), 8)
			surface.SetDrawColor(C.gold)
			surface.DrawOutlinedRect(pad, y, innerW, 12)
			y = y + 22

			if over then
				draw.SimpleText("Over your power limit.", "Arcana_AncientSmall", pad, y, Color(220, 110, 90))
				y = y + 19
			end

			----------------------------------------------------------------
			-- What still stands between this spell and casting it
			----------------------------------------------------------------
			-- Stop before the buttons rather than drawing underneath them.
			local limit = (pnl._buttonsTop or h) - 8

			if not req then return end

			if req.castable then
				if y < limit then
					drawMark(pad, y, true)
					draw.SimpleText("Ready to cast.", "Arcana_AncientSmall", pad + 20, y + 1, Color(150, 220, 150))
				end
				return
			end

			y = y + 4
			draw.SimpleText("STILL NEEDED", "Arcana_AncientSmall", pad, y, C.paleGold)
			y = y + 20

			local function line(ok, text)
				if ok or y >= limit then return end
				drawMark(pad, y, false)
				ArtDeco.DrawTruncatedText("Arcana_AncientSmall", text, pad + 20, y + 1, C.textDim, innerW - 20)
				y = y + 20
			end

			line(req.checks.level.ok, "Level " .. req.checks.level.need)

			local ess = req.checks.essence
			if not ess.ok then
				line(false, ess.label .. (ess.bargain and " (the Golden Sun's bargain)" or " (buy it on the map)"))
			end

			for _, cl in ipairs(req.checks.clauses) do
				line(cl.ok, cl.label .. (cl.rank > 1 and (" " .. cl.rank) or "") .. " (level " .. cl.need .. ")")
			end

			line(req.checks.budget.ok, "Power " .. req.checks.budget.need .. " / " .. req.checks.budget.have)

			if not req.checks.consecrated.ok and y < limit then
				drawMark(pad, y, false)
				local textW = draw.SimpleText("Activation:", "Arcana_AncientSmall", pad + 20, y + 1, C.textDim)
				ArtDeco.DrawCostLine("Arcana_AncientSmall", pad + 20 + textW + 8, y + 1, {
					{text = string.Comma(req.checks.consecrated.coins), icon = ArtDeco.Icons.coin, color = C.coinGold},
					{text = string.Comma(req.checks.consecrated.shards), icon = ArtDeco.Icons.shard, color = C.shardBlue},
				})
			end
		end

		return bar
	end

	----------------------------------------------------------------
	-- Keeps a floating panel pinned to its parent as the parent resizes.
	----------------------------------------------------------------
	local function anchor(pnl, place)
		local function sync(p)
			local pw, ph = p:GetParent():GetSize()
			if p._lw ~= pw or p._lh ~= ph then
				p._lw, p._lh = pw, ph
				place(p, pw, ph)
			end
			if p._extraThink then p._extraThink(p) end
		end

		pnl.Think = sync
		sync(pnl) -- place it now if the parent is already laid out
	end

	----------------------------------------------------------------
	-- Composer: the star map, with the slot strip over its top-left and
	-- the spell column over its right.
	----------------------------------------------------------------
	local function buildComposer()
		-- No header strip: the frame is already titled, and the controls sit in
		-- that same band. Dropping it hands 50px of height back to the map.
		local host = vgui.Create("DPanel", content)
		host:Dock(FILL)
		host.Paint = nil

		-- Level gate up front: no point composing a spell you cannot create.
		-- Slots you already carry still open, so their details stay reachable.
		local cs = P.GetClientState()
		local minLevel = P.Config().minLevel
		if (cs.level or 0) < minLevel and not activeDefForSlot(state.selSlot) then
			host.Paint = function(_, w, h)
				local cx, cy = w * 0.5, h * 0.5
				local t = CurTime()
				local dim = Color(150, 132, 100)
				Arcana.Circle.Draw2DPatternRing(2, cx, cy - 40, 70, t * 3, dim, 120)
				Arcana.Circle.Draw2DRing(Arcana.Circle.RING_TYPES.SIMPLE_LINE, cx, cy - 40, 52, -t * 2, dim, 100)
				draw.SimpleText("SPELL CRAFTING LOCKED", "Arcana_AncientLarge", cx, cy + 60, C.paleGold, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
				draw.SimpleText("Requires level " .. minLevel .. ". You are level " .. (cs.level or 0) .. ".", "Arcana_Ancient", cx, cy + 92, C.textDim, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
			end
			buildSlotStrip(host)
			return
		end

		local canvas = P.Graph.CreateCanvas(host, {
			state = state,
			seed = bgSeed,
			playClick = playClick,
			playDeny = playDeny,
			bumpRev = function() state.rev = (state.rev or 0) + 1 end,
			rightInset = function() return SIDEBAR_W + 16 end,
			requestUnlock = function(essence)
				showUnlockModal(frame, essence, function()
					net.Start("Arcana_Spellcraft_UnlockEssence")
					net.WriteString(essence.id)
					net.SendToServer()
				end)
			end,
		})
		canvas:Dock(FILL)

		buildSlotStrip(host)

		local sidebar = buildSidebar(host)
		anchor(sidebar, function(pnl, pw, ph)
			pnl:SetSize(SIDEBAR_W, ph - 16)
			pnl:SetPos(pw - SIDEBAR_W - 8, 8)
		end)
	end

	----------------------------------------------------------------
	-- refresh: single rebuild entry point
	----------------------------------------------------------------
	refresh = function()
		if not IsValid(content) then return end
		state.nameEntry = nil
		clearChildren(content)
		buildComposer()
	end

	loadSlot(state.selSlot)
	refresh()

	-- A cheap fingerprint of everything about this player that the menu draws.
	local function clientSignature()
		local cs = P.GetClientState()
		local essences, consecrated = 0, 0
		for _ in pairs(cs.essences) do essences = essences + 1 end
		for _ in pairs(cs.consecrated) do consecrated = consecrated + 1 end
		return table.concat({ cs.level or 0, essences, consecrated, cs.bargain and 1 or 0, cs.maxSlots or 0 }, "|")
	end

	local lastSignature = clientSignature()

	-- Arcana_Spellcraft_Register is broadcast to everyone, so this hook also
	-- fires when a stranger across the map finishes a spell. Rebuilding on that
	-- would throw away work in progress and steal focus from the name box, so
	-- nothing happens unless this player's own slot or standing actually moved.
	hook.Add("Arcana_Spellcraft_StateChanged", frame, function()
		if not IsValid(frame) then return end

		local def = activeDefForSlot(state.selSlot)
		local hash = def and P.DefHash(def) or nil
		local storedName = def and activeNameForSlot(state.selSlot) or nil
		local slotChanged = hash ~= state.baseHash or storedName ~= state.baseName

		local signature = clientSignature()
		if not slotChanged and signature == lastSignature then return end
		lastSignature = signature

		if slotChanged then
			-- This slot was saved, reworked or dissolved: show what is stored now.
			loadSlot(state.selSlot)
		else
			state.rev = (state.rev or 0) + 1
		end

		refresh()
	end)

	frame.Think = function()
		if not IsValid(machine) then frame:Close() end
	end
end

net.Receive("Arcana_OpenSpellcraftMenu", function()
	local ent = net.ReadEntity()
	if IsValid(ent) then OpenSpellcraftMenu(ent) end
end)
