-- Spellcraft — the Emissary menu.
--
-- Composing is a 4-step wizard, one minimal view at a time:
--   1. FORM       how the spell is delivered
--   2. ESSENCE    the nature of the magic (buy locked ones here)
--   3. MODIFIERS  optional clauses, up to five ranks
--   4. RECAP      full summary, name it, pay the cost
-- BACK/NEXT navigate; the breadcrumb jumps to any completed step. Selecting an
-- occupied slot on the left shows that crafted spell's details/requirements instead.
--
-- Modifiers incompatible with the chosen form/essence are hidden outright, and
-- anything unavailable says WHY on the row — no unexplained denials.
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

local STEPS = { "FORM", "ELEMENT", "MODIFIERS", "REVIEW" }

-- Semi-transparent warm panel fills so the themed background shows through.
local PANEL_BG = Color(20, 15, 10, 200)

local function playDeny() surface.PlaySound("buttons/button8.wav") end
local function playClick() surface.PlaySound("buttons/button6.wav") end

----------------------------------------------------------------------
-- Themed background: dark stone, a divine glow descending from above,
-- and faint runes drifting upward — prayers rising to the gods.
----------------------------------------------------------------------
local GLYPH_MATS
local function getGlyphMats()
	if GLYPH_MATS then return GLYPH_MATS end
	GLYPH_MATS = {}
	for i = 65, 72 do
		GLYPH_MATS[#GLYPH_MATS + 1] = Material("arcana/glyphs/glyph_" .. i .. ".png", "smooth")
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

	render.SetStencilEnable(false)
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

-- A small hand-drawn ornament per element, centred at (cx, cy).
local function drawElementOrnament(id, cx, cy, col)
	surface.SetDrawColor(col)
	if id == "fire" then
		-- Flame: nested upward strokes
		surface.DrawLine(cx - 5, cy + 5, cx, cy - 6)
		surface.DrawLine(cx, cy - 6, cx + 5, cy + 5)
		surface.DrawLine(cx + 5, cy + 5, cx - 5, cy + 5)
		surface.DrawLine(cx - 2, cy + 3, cx, cy - 1)
		surface.DrawLine(cx, cy - 1, cx + 2, cy + 3)
	elseif id == "frost" then
		-- Snowflake: six spokes
		surface.DrawLine(cx, cy - 6, cx, cy + 6)
		surface.DrawLine(cx - 5, cy - 3, cx + 5, cy + 3)
		surface.DrawLine(cx - 5, cy + 3, cx + 5, cy - 3)
	elseif id == "earth" then
		-- Stone: a core within an outline
		surface.DrawOutlinedRect(cx - 5, cy - 5, 10, 10)
		surface.DrawRect(cx - 2, cy - 2, 4, 4)
	elseif id == "wind" then
		-- Gusts: three staggered strokes
		surface.DrawLine(cx - 6, cy - 4, cx + 4, cy - 4)
		surface.DrawLine(cx - 4, cy, cx + 6, cy)
		surface.DrawLine(cx - 6, cy + 4, cx + 2, cy + 4)
	elseif id == "poison" then
		-- Droplet
		surface.DrawLine(cx, cy - 6, cx - 4, cy + 2)
		surface.DrawLine(cx, cy - 6, cx + 4, cy + 2)
		surface.DrawLine(cx - 4, cy + 2, cx, cy + 6)
		surface.DrawLine(cx + 4, cy + 2, cx, cy + 6)
	elseif id == "lightning" then
		-- Bolt zigzag
		surface.DrawLine(cx + 3, cy - 6, cx - 3, cy + 1)
		surface.DrawLine(cx - 3, cy + 1, cx + 1, cy + 1)
		surface.DrawLine(cx + 1, cy + 1, cx - 3, cy + 6)
	elseif id == "arcane" then
		-- Sparkle: four-point star
		surface.DrawLine(cx, cy - 6, cx, cy + 6)
		surface.DrawLine(cx - 6, cy, cx + 6, cy)
		surface.DrawLine(cx - 3, cy - 3, cx + 3, cy + 3)
		surface.DrawLine(cx - 3, cy + 3, cx + 3, cy - 3)
	elseif id == "aurum" then
		-- Sun: disc and rays
		surface.DrawCircle(cx, cy, 4, col.r, col.g, col.b, col.a or 255)
		surface.DrawLine(cx, cy - 7, cx, cy - 5)
		surface.DrawLine(cx, cy + 5, cx, cy + 7)
		surface.DrawLine(cx - 7, cy, cx - 5, cy)
		surface.DrawLine(cx + 5, cy, cx + 7, cy)
	else
		-- Fallback diamond
		surface.DrawLine(cx, cy - 5, cx + 5, cy)
		surface.DrawLine(cx + 5, cy, cx, cy + 5)
		surface.DrawLine(cx, cy + 5, cx - 5, cy)
		surface.DrawLine(cx - 5, cy, cx, cy - 5)
	end
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

----------------------------------------------------------------------
-- The menu
----------------------------------------------------------------------
local function OpenSpellcraftMenu(machine)
	local ply = LocalPlayer()
	if not IsValid(ply) then return end
	C = ArtDeco.Colors

	local state = {
		selSlot = 1,
		step = 1,
		form = nil,
		essence = nil,
		clauseRanks = {},
		name = "",
	}

	local frame = vgui.Create("DFrame")
	frame:SetSize(math.min(1180, ScrW() - 60), math.min(720, ScrH() - 60))
	frame:Center()
	frame:SetTitle("")
	frame:MakePopup()

	local bgSeed = math.random(1, 10 ^ 9)

	hook.Add("HUDPaint", frame, function()
		local x, y = frame:LocalToScreen(0, 0)
		ArtDeco.DrawBlurRect(x + 6, y + 6, frame:GetWide() - 12, frame:GetTall() - 12, 4, 8)
	end)

	ArtDeco.StyleCloseButton(frame)
	if IsValid(frame.btnMinim) then frame.btnMinim:Hide() end
	if IsValid(frame.btnMaxim) then frame.btnMaxim:Hide() end

	-- Declared here so the title can measure the band down to the panels' frames.
	local content

	frame.Paint = function(_, w, h)
		drawEmissaryBackground(w, h, bgSeed)
		ArtDeco.DrawDecoFrame(6, 6, w - 12, h - 12, C.gold, 14)

		-- The title centers in the band between the frame's top line and the slot
		-- list / right pane below, which frame themselves at the content's top edge.
		local bandTop = 6 + 1
		local bandBottom = IsValid(content) and content:GetY() or (bandTop + 38)
		ArtDeco.DrawTitle("Arcana_AncientLarge", "THE EMISSARY", bandTop, bandBottom, C.paleGold)
	end

	content = vgui.Create("DPanel", frame)
	content:Dock(FILL)
	content:DockMargin(12, 12, 12, 12)
	content.Paint = nil

	local refresh -- forward declaration; single rebuild entry point

	----------------------------------------------------------------
	-- Left: slot list
	----------------------------------------------------------------
	local left = vgui.Create("DPanel", content)
	left:Dock(LEFT)
	left:SetWide(260)
	left.Paint = function(_, w, h)
		ArtDeco.FillDecoPanel(0, 0, w - 4, h, PANEL_BG, 10)
		ArtDeco.DrawDecoFrame(0, 0, w - 4, h, C.gold, 10)
		draw.SimpleText("YOUR SPELLS", "Arcana_Ancient", 12, 10, C.paleGold)
	end

	local slotList = vgui.Create("DPanel", left)
	slotList:Dock(FILL)
	slotList:DockMargin(8, 36, 12, 8)
	slotList.Paint = nil

	local function buildSlotList()
		clearChildren(slotList)
		local maxSlots = P.GetClientState().maxSlots or 3

		for i = 1, maxSlots do
			local row = vgui.Create("DButton", slotList)
			row:Dock(TOP)
			row:SetTall(56)
			row:DockMargin(0, 0, 0, 6)
			row:SetText("")
			row.Paint = function(_, w, h)
				local def = activeDefForSlot(i)
				local sel = state.selSlot == i
				ArtDeco.FillDecoPanel(0, 0, w, h, sel and Color(58, 44, 32, 235) or C.cardIdle, 8)
				ArtDeco.DrawDecoFrame(0, 0, w, h, sel and C.paleGold or C.gold, 8)

				if def then
					draw.SimpleText(activeNameForSlot(i), "Arcana_Ancient", 12, 8, C.textBright)
					local st = P.GetClientState()
					st.consecrated = isConsecrated(def)
					local req = P.Requirements(def, st)
					if req.castable then
						draw.SimpleText("Ready", "Arcana_AncientSmall", 12, 31, Color(120, 220, 120))
					else
						draw.SimpleText(req.firstMissing or "Locked", "Arcana_AncientSmall", 12, 31, Color(220, 130, 90))
					end
				else
					draw.SimpleText("Empty slot", "Arcana_Ancient", 12, h * 0.5, C.textDim, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
				end
			end
			row.DoClick = function()
				state.selSlot = i
				playClick()
				refresh()
			end
		end
	end

	----------------------------------------------------------------
	-- Right pane
	----------------------------------------------------------------
	local right = vgui.Create("DPanel", content)
	right:Dock(FILL)
	right:DockMargin(8, 0, 0, 0)
	right.Paint = function(_, w, h)
		ArtDeco.FillDecoPanel(0, 0, w, h, PANEL_BG, 10)
		ArtDeco.DrawDecoFrame(0, 0, w, h, C.gold, 10)
	end

	-- Wizard chrome: step title + breadcrumb, docked TOP of the right pane.
	local function stepDone(k)
		if k == 1 then return state.form ~= nil end
		if k == 2 then return state.essence ~= nil end
		if k == 3 then return true end -- modifiers are optional
		return false
	end

	local function canEnterStep(k)
		for j = 1, k - 1 do
			if not stepDone(j) then return false end
		end
		return true
	end

	local function buildWizardHeader(title, subtitle)
		local hd = vgui.Create("DPanel", right)
		hd:Dock(TOP)
		hd:SetTall(80)
		hd:DockMargin(16, 8, 16, 0)
		hd._crumbs = {}
		hd.Paint = function(pnl, w, h)
			draw.SimpleText(title, "Arcana_AncientLarge", 0, 0, C.paleGold)
			draw.SimpleText(subtitle, "Arcana_AncientSmall", 0, 30, C.textDim)

			-- Breadcrumb on its own row; every segment is measured so nothing overlaps.
			local y = 58
			local x = 0
			pnl._crumbs = {}
			surface.SetFont("Arcana_AncientSmall")

			for k = 1, 4 do
				local cur = state.step == k
				local done = stepDone(k) and k < state.step
				local dotCol = cur and C.paleGold or (done and Color(120, 220, 120) or Color(120, 106, 84))

				local cxp, cyp, r = x + 6, y + 9, 5
				surface.SetDrawColor(dotCol)
				surface.DrawLine(cxp, cyp - r, cxp + r, cyp)
				surface.DrawLine(cxp + r, cyp, cxp, cyp + r)
				surface.DrawLine(cxp, cyp + r, cxp - r, cyp)
				surface.DrawLine(cxp - r, cyp, cxp, cyp - r)

				local label = STEPS[k]
				local tw = surface.GetTextSize(label)
				draw.SimpleText(label, "Arcana_AncientSmall", x + 16, y, cur and C.textBright or (done and Color(150, 220, 150) or C.textDim))
				pnl._crumbs[k] = { x0 = x, x1 = x + 16 + tw }
				x = x + 16 + tw

				if k < 4 then
					surface.SetDrawColor(110, 96, 74, 255)
					surface.DrawRect(x + 10, y + 8, 14, 1)
					x = x + 34
				end
			end
		end
		hd.OnMousePressed = function(pnl, code)
			if code ~= MOUSE_LEFT then return end
			local mx, my = pnl:ScreenToLocal(gui.MousePos())
			if my < 52 then return end
			for k, crumb in ipairs(pnl._crumbs or {}) do
				if mx >= crumb.x0 and mx <= crumb.x1 and k ~= state.step and canEnterStep(k) then
					state.step = k
					playClick()
					refresh()
					return
				end
			end
		end
	end

	-- Wizard nav: BACK (left) + NEXT (right), docked BOTTOM.
	local function buildWizardNav(nextEnabled)
		local nav = vgui.Create("DPanel", right)
		nav:Dock(BOTTOM)
		nav:SetTall(34)
		nav:DockMargin(16, 6, 16, 12)
		nav.Paint = nil

		if state.step > 1 then
			local back = decoButton(nav, {
				label = "< BACK",
				onClick = function()
					state.step = state.step - 1
					refresh()
				end,
			})
			back:Dock(LEFT)
			back:SetWide(100)
		end

		if state.step < 4 then
			local nxt = decoButton(nav, {
				label = "NEXT >",
				enabled = nextEnabled,
				onClick = function()
					state.step = state.step + 1
					refresh()
				end,
			})
			nxt:Dock(RIGHT)
			nxt:SetWide(140)
		end

		return nav
	end

	----------------------------------------------------------------
	-- Power gauge, shared by every composer step. Sums points directly so it
	-- works mid-composition, before a full Compile is possible.
	----------------------------------------------------------------
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

	local function buildPowerBar(extraTextFn)
		local power = vgui.Create("DPanel", right)
		power:Dock(TOP)
		power:SetTall(24)
		power:DockMargin(16, 6, 16, 0)
		power.Paint = function(_, w, h)
			local budget = P.Budget(P.GetClientState().level)
			local points = currentPoints()
			local over = points > budget
			local txt = points .. " / " .. budget
			if extraTextFn then txt = txt .. "   ·   " .. extraTextFn() end

			draw.SimpleText("POWER", "Arcana_AncientSmall", 0, 4, C.paleGold)
			surface.SetFont("Arcana_AncientSmall")
			local tw = surface.GetTextSize(txt)
			local barX = 64
			local barW = math.max(40, w - barX - tw - 14)
			surface.SetDrawColor(46, 36, 26, 235)
			surface.DrawRect(barX, 6, barW, 12)
			surface.SetDrawColor(over and Color(200, 80, 60, 220) or C.xpFill)
			surface.DrawRect(barX + 2, 8, math.floor((barW - 4) * math.Clamp(points / math.max(1, budget), 0, 1)), 8)
			surface.SetDrawColor(C.gold)
			surface.DrawOutlinedRect(barX, 6, barW, 12)
			draw.SimpleText(txt, "Arcana_AncientSmall", w, 4, over and Color(220, 110, 90) or C.textBright, TEXT_ALIGN_RIGHT)
		end
		return power
	end

	----------------------------------------------------------------
	-- Shared spell overview (review + details): element-tinted magic
	-- circle, title, description, modifier chips, and the stat rows.
	-- Returns ix, infoW and the y to continue drawing at.
	----------------------------------------------------------------
	-- extraH: expected height of whatever the caller draws below the overview,
	-- so the whole block centers vertically alongside the circle.
	local function drawSpellOverview(w, h, compiled, title, extraH)
		local form = P.Forms[compiled.form]
		local essence = P.Essences[compiled.essence]
		local ec = essence.color
		local t = CurTime()

		-- The full magic circle, identical for every form.
		local ccx, ccy = 128, h * 0.5
		local radius = math.min(112, math.max(84, h * 0.42))
		local circleCol = Color(ec.r, ec.g, ec.b)
		Arcana.Circle.Draw2DRuneStar(ccx, ccy, radius, t * 2, { 66, 68, 70, 72 }, circleCol, 255)
		Arcana.Circle.Draw2DPatternRing(2, ccx, ccy, radius * 0.82, -t * 4, circleCol, 255)
		Arcana.Circle.Draw2DRing(Arcana.Circle.RING_TYPES.SIMPLE_LINE, ccx, ccy, radius * 0.66, t * 2, circleCol, 230)
		Arcana.Circle.Draw2DPatternRing(1, ccx, ccy, radius * 0.52, -t * 9, circleCol, 255)
		Arcana.Circle.Draw2DRuneStar(ccx, ccy, radius * 0.4, -t * 3, { 65, 67, 69, 71 }, circleCol, 255)

		local ix = 272
		local infoW = w - ix - 8

		-- Measure the block so it centers vertically like the circle.
		local descLines = wrapText("Arcana_AncientSmall", form.desc .. " " .. (essence.desc or ""), infoW)
		local blockH = 32 + #descLines * 17 + 10 + 36 + 118 + (extraH or 0)
		local y = math.max(2, math.floor((h - blockH) * 0.5))

		-- Title in the element colour; the composition shows as a suffix
		-- when a custom name replaces it.
		local composition = essence.label .. " " .. form.label
		title = (title and title ~= "") and title or composition
		ArtDeco.DrawTruncatedText("Arcana_AncientLarge", title, ix, y, circleCol, infoW)
		if title ~= composition then
			surface.SetFont("Arcana_AncientLarge")
			local titleW = surface.GetTextSize(title)
			if titleW + 100 < infoW then
				draw.SimpleText(composition, "Arcana_AncientSmall", ix + titleW + 12, y + 8, C.textDim)
			end
		end
		y = y + 32

		for _, lineTxt in ipairs(descLines) do
			draw.SimpleText(lineTxt, "Arcana_AncientSmall", ix, y, C.textDim)
			y = y + 17
		end
		y = y + 10

		-- Modifier chips
		local chipX = ix
		surface.SetFont("Arcana_AncientSmall")
		local anyMod = false
		for _, clause in ipairs(P.SortedClauses()) do
			local rank = compiled.ranks[clause.id]
			if rank then
				anyMod = true
				local label = clause.label .. (rank > 1 and (" " .. rank) or "")
				local tw = surface.GetTextSize(label)
				ArtDeco.FillDecoPanel(chipX, y, tw + 18, 22, C.cardIdle, 4)
				ArtDeco.DrawDecoFrame(chipX, y, tw + 18, 22, C.gold, 4)
				draw.SimpleText(label, "Arcana_AncientSmall", chipX + 9, y + 3, C.paleGold)
				chipX = chipX + tw + 26
			end
		end
		if not anyMod then
			draw.SimpleText("No modifiers", "Arcana_AncientSmall", ix, y + 3, C.textDim)
		end
		y = y + 36

		-- Stat strip: two rows of three, big values over small labels.
		local statRow1
		if compiled.isSelf then
			statRow1 = {
				{ v = tostring(math.Round(compiled.damage)) .. "/s", l = "DAMAGE" },
				{ v = tostring(math.Round(compiled.radius)), l = "RADIUS" },
				{ v = compiled.duration .. "s", l = "DURATION" },
			}
		else
			local dmg = math.Round(compiled.damage * (compiled.projectiles or 1))
			statRow1 = {
				{ v = tostring(dmg) .. ((compiled.projectiles or 1) > 1 and (" x" .. compiled.projectiles) or ""), l = "DAMAGE" },
				{ v = tostring(math.Round(compiled.radius)), l = "RADIUS" },
				{ v = tostring(math.Round(compiled.range)), l = "RANGE" },
			}
		end
		local statRow2 = {
			{ v = ("%.1fs"):format(compiled.cooldown), l = "COOLDOWN" },
			{ v = ("%.1fs"):format(compiled.castTime), l = "CAST" },
			{ v = string.Comma(compiled.perCastCost) .. " coins", l = "PER CAST", gold = true },
		}

		local colW = math.floor(infoW / 3)
		local function drawStatRow(cols)
			for i, s in ipairs(cols) do
				local sx = ix + (i - 1) * colW
				draw.SimpleText(s.v, "Arcana_AncientLarge", sx, y, s.gold and C.paleGold or C.textBright)
				draw.SimpleText(s.l, "Arcana_AncientSmall", sx, y + 28, C.textDim)
			end
			y = y + 56
		end
		drawStatRow(statRow1)
		drawStatRow(statRow2)
		y = y + 6

		return ix, infoW, y
	end

	----------------------------------------------------------------
	-- Step 1: FORM
	----------------------------------------------------------------
	local function buildStepForm()
		buildWizardHeader("CHOOSE A FORM", "How your spell is delivered. Pick one.")
		buildWizardNav(function() return state.form ~= nil end)
		buildPowerBar()

		local list = vgui.Create("DPanel", right)
		list:Dock(FILL)
		list:DockMargin(16, 8, 16, 4)
		list.Paint = nil

		for _, form in ipairs(P.SortedForms()) do
			local row = vgui.Create("DButton", list)
			row:Dock(TOP)
			row:SetTall(58)
			row:DockMargin(0, 0, 0, 6)
			row:SetText("")
			row.Paint = function(_, w, h)
				local sel = state.form == form.id
				ArtDeco.FillDecoPanel(0, 0, w, h, sel and Color(58, 44, 32, 235) or C.cardIdle, 8)
				ArtDeco.DrawDecoFrame(0, 0, w, h, sel and Color(255, 255, 255, 255) or C.gold, 8)
				draw.SimpleText(form.label, "Arcana_AncientLarge", 16, 4, sel and C.paleGold or C.textBright)
				draw.SimpleText(form.desc, "Arcana_AncientSmall", 16, 34, C.textDim)

				-- Structured mini stats, value over label, like the review strip.
				local cols = {
					{ v = form.id == "self" and (form.tickDamage .. "/s") or tostring(form.baseDamage), l = "DMG" },
					{ v = ("%.0fs"):format(form.baseCooldown), l = "COOLDOWN" },
				}
				local colW = 104
				local baseX = w - 340
				for i, s in ipairs(cols) do
					local sx = baseX + (i - 1) * colW
					draw.SimpleText(s.v, "Arcana_Ancient", sx, 7, C.textBright)
					draw.SimpleText(s.l, "Arcana_AncientSmall", sx, 32, C.textDim)
				end

				-- Points sit apart on the far right, in gold.
				draw.SimpleText(tostring(form.points), "Arcana_Ancient", w - 64, 7, C.paleGold)
				draw.SimpleText("PTS", "Arcana_AncientSmall", w - 64, 32, C.paleGold)
			end
			row.DoClick = function()
				state.form = form.id
				-- Drop modifiers that no longer fit the new form.
				for id in pairs(state.clauseRanks) do
					local cl = P.Clauses[id]
					if (cl.onlyForm and not cl.onlyForm[form.id]) or (cl.denyForm and cl.denyForm[form.id]) then
						state.clauseRanks[id] = nil
					end
				end
				playClick()
				refresh()
			end
		end
	end

	----------------------------------------------------------------
	-- Step 2: ESSENCE
	----------------------------------------------------------------
	local function buildStepEssence()
		buildWizardHeader("CHOOSE AN ELEMENT", "What your spell's damage does. Locked elements can be bought with a one-time payment.")
		buildWizardNav(function() return state.essence ~= nil end)
		buildPowerBar()

		-- Price footer under the rows: shows the cost of the hovered locked
		-- element, right-aligned with the UNLOCK buttons.
		local hoveredLocked
		local footer = vgui.Create("DPanel", right)
		footer:Dock(BOTTOM)
		footer:SetTall(22)
		footer:DockMargin(16, 0, 16, 0)
		footer.Paint = function(_, w, h)
			local e = hoveredLocked
			if not e then return end
			draw.SimpleText("Unlock " .. e.label .. ":  " .. string.Comma(e.unlock.coins) .. " coins, " .. e.unlock.shards .. " shards",
				"Arcana_AncientSmall", w - 9, 4, C.paleGold, TEXT_ALIGN_RIGHT)
		end

		local list = vgui.Create("DScrollPanel", right)
		list:Dock(FILL)
		list:DockMargin(16, 8, 12, 4)
		local vbar = list:GetVBar()
		vbar:SetWide(6)
		vbar.Paint = nil
		vbar.btnGrip.Paint = function(_, w, h)
			surface.SetDrawColor(C.gold)
			surface.DrawRect(0, 0, w, h)
		end

		local gradMat = Material("vgui/gradient-l")
		local st = P.GetClientState()
		for _, essence in ipairs(P.SortedEssences()) do
			local hidden = essence.bargain and not st.bargain
			local unlocked = (essence.bargain and st.bargain) or st.essences[essence.id] == true
			local ec = essence.color

			local row = vgui.Create("DPanel", list)
			row:Dock(TOP)
			row:SetTall(46)
			row:DockMargin(0, 0, 0, 5)
			row.Paint = function(_, w, h)
				local sel = state.essence == essence.id

				if hidden then
					ArtDeco.FillDecoPanel(0, 0, w, h, C.cardIdle, 6)
					ArtDeco.DrawDecoFrame(0, 0, w, h, Color(120, 105, 80), 6)
					draw.SimpleText("???", "Arcana_Ancient", 34, 4, Color(160, 150, 135))
					draw.SimpleText("A hidden element.", "Arcana_AncientSmall", 34, 26, C.textDim)
					return
				end

				-- Card washed with the element color from the left.
				ArtDeco.FillDecoPanel(0, 0, w, h, sel and Color(58, 44, 32, 235) or C.cardIdle, 6)
				surface.SetDrawColor(ec.r, ec.g, ec.b, sel and 48 or (unlocked and 30 or 12))
				surface.SetMaterial(gradMat)
				surface.DrawTexturedRect(2, 2, math.floor(w * 0.55), h - 4)

				-- Frame: a white outline marks the selection; otherwise the frame
				-- is tinted by the element (dim when locked).
				if sel then
					ArtDeco.DrawDecoFrame(0, 0, w, h, Color(255, 255, 255, 255), 6)
				else
					local mul = unlocked and 0.65 or 0.35
					ArtDeco.DrawDecoFrame(0, 0, w, h, Color(ec.r * mul, ec.g * mul, ec.b * mul), 6)
				end

				-- Per-element ornament on the left rail.
				local ornMul = (sel or unlocked) and 1 or 0.45
				drawElementOrnament(essence.id, 16, h * 0.5, Color(ec.r * ornMul, ec.g * ornMul, ec.b * ornMul))

				draw.SimpleText(essence.label, "Arcana_Ancient", 34, 4, sel and Color(ec.r, ec.g, ec.b) or (unlocked and C.textBright or Color(170, 158, 140)))
				draw.SimpleText(essence.desc or "", "Arcana_AncientSmall", 34, 26, C.textDim)
			end

			if not hidden then
				if unlocked then
					local pick = vgui.Create("DButton", row)
					pick:Dock(FILL)
					pick:SetText("")
					pick.Paint = nil
					pick.DoClick = function()
						state.essence = essence.id
						-- Drop modifiers that clash with the new essence.
						for id in pairs(state.clauseRanks) do
							local cl = P.Clauses[id]
							if cl.denyEssence and cl.denyEssence[essence.id] then
								state.clauseRanks[id] = nil
							end
						end
						playClick()
						refresh()
					end
				else
					local unlock = decoButton(row, {
						label = "UNLOCK",
						onClick = function()
							net.Start("Arcana_Spellcraft_UnlockEssence")
							net.WriteString(essence.id)
							net.SendToServer()
							playClick()
						end,
					})
					unlock:Dock(RIGHT)
					unlock:SetWide(110)
					unlock:DockMargin(4, 9, 9, 9)
					unlock.OnCursorEntered = function() hoveredLocked = essence end

					row.OnCursorEntered = function() hoveredLocked = essence end
					row.OnCursorExited = function(pnl)
						if hoveredLocked == essence and not pnl:IsChildHovered() then
							hoveredLocked = nil
						end
					end
				end
			end
		end
	end

	----------------------------------------------------------------
	-- Step 3: MODIFIERS
	----------------------------------------------------------------
	local function buildStepModifiers()
		local function slotCount()
			local n = 0
			for _, r in pairs(state.clauseRanks) do n = n + r end
			return n
		end

		buildWizardHeader("ADD MODIFIERS", "Optional. Each rank costs power and raises the price. Skip ahead if you want none.")
		buildWizardNav(function() return true end)
		buildPowerBar(function() return slotCount() .. "/" .. P.MAX_CLAUSE_SLOTS .. " modifiers" end)

		local scroll = vgui.Create("DScrollPanel", right)
		scroll:Dock(FILL)
		scroll:DockMargin(16, 6, 12, 4)
		local vbar = scroll:GetVBar()
		vbar:SetWide(6)
		vbar.Paint = nil
		vbar.btnGrip.Paint = function(_, w, h)
			surface.SetDrawColor(C.gold)
			surface.DrawRect(0, 0, w, h)
		end

		local level = P.GetClientState().level or 0

		for _, clause in ipairs(P.SortedClauses()) do
			-- Incompatible modifiers are hidden outright: less noise, no dead rows.
			local formOk = (not clause.onlyForm or clause.onlyForm[state.form]) and (not clause.denyForm or not clause.denyForm[state.form])
			local essenceOk = not (clause.denyEssence and state.essence and clause.denyEssence[state.essence])

			if formOk and essenceOk then
				-- The reason the next rank cannot be added right now, or nil if it can.
				local function blockReason()
					local rank = state.clauseRanks[clause.id] or 0
					local nextRank = rank + 1
					if nextRank > clause.maxRank then return nil end -- maxed; +' is just inert
					if level < clause.levels[nextRank] then return "Unlocks at level " .. clause.levels[nextRank] end
					if slotCount() >= P.MAX_CLAUSE_SLOTS then return "Modifier limit reached (" .. P.MAX_CLAUSE_SLOTS .. ")" end
					if clause.id == "homing" and (state.clauseRanks.widen or 0) >= 2 then return "Conflicts with Widen II" end
					if clause.id == "widen" and nextRank >= 2 and state.clauseRanks.homing then return "Rank II conflicts with Homing" end

					-- Generic pairwise conflicts (mirrors Compile), both directions.
					for other in pairs(clause.conflicts or {}) do
						if state.clauseRanks[other] then
							return "Conflicts with " .. (P.Clauses[other] and P.Clauses[other].label or other)
						end
					end
					for otherId, rank2 in pairs(state.clauseRanks) do
						if rank2 > 0 then
							local other = P.Clauses[otherId]
							if other and other.conflicts and other.conflicts[clause.id] then
								return "Conflicts with " .. other.label
							end
						end
					end

					return nil
				end

				local row = vgui.Create("DPanel", scroll)
				row:Dock(TOP)
				row:SetTall(52)
				row:DockMargin(0, 0, 0, 5)
				row.Paint = function(_, w, h)
					local rank = state.clauseRanks[clause.id] or 0
					ArtDeco.FillDecoPanel(0, 0, w, h, rank > 0 and Color(58, 44, 32, 235) or C.cardIdle, 6)
					ArtDeco.DrawDecoFrame(0, 0, w, h, rank > 0 and C.paleGold or C.gold, 6)

					draw.SimpleText(clause.label, "Arcana_Ancient", 12, 5, rank > 0 and C.paleGold or C.textBright)

					-- Rank pips
					if clause.maxRank > 1 then
						surface.SetFont("Arcana_Ancient")
						local nameW = surface.GetTextSize(clause.label)
						for r = 1, clause.maxRank do
							local px = 12 + nameW + 10 + (r - 1) * 14
							if r <= rank then
								surface.SetDrawColor(C.paleGold)
								surface.DrawRect(px, 11, 9, 9)
							else
								surface.SetDrawColor(110, 96, 74, 255)
								surface.DrawOutlinedRect(px, 11, 9, 9)
							end
						end
					end

					draw.SimpleText(clause.desc, "Arcana_AncientSmall", 12, 30, C.textDim)

					-- Points sit apart, left of the -/+ buttons, in gold.
					draw.SimpleText(tostring(clause.points), "Arcana_Ancient", w - 92, 7, C.paleGold, TEXT_ALIGN_RIGHT)
					draw.SimpleText("PTS" .. (clause.maxRank > 1 and "/RANK" or ""), "Arcana_AncientSmall", w - 92, 29, C.paleGold, TEXT_ALIGN_RIGHT)

					local reason = blockReason()
					if reason then
						surface.SetFont("Arcana_AncientSmall")
						local rw = surface.GetTextSize(reason)
						draw.SimpleText(reason, "Arcana_AncientSmall", w - 175 - rw, 30, Color(220, 170, 110))
					end
				end

				local plus = vgui.Create("DButton", row)
				plus:Dock(RIGHT)
				plus:SetWide(34)
				plus:DockMargin(2, 9, 9, 9)
				plus:SetText("")
				plus.Paint = function(_, w, h)
					local rank = state.clauseRanks[clause.id] or 0
					local usable = rank < clause.maxRank and blockReason() == nil
					ArtDeco.FillDecoPanel(0, 0, w, h, C.cardIdle, 4)
					ArtDeco.DrawDecoFrame(0, 0, w, h, usable and C.gold or Color(110, 96, 74), 4)
					draw.SimpleText("+", "Arcana_Ancient", w * 0.5, h * 0.5, usable and C.textBright or Color(140, 128, 108), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
				end
				plus.DoClick = function()
					local rank = state.clauseRanks[clause.id] or 0
					if rank >= clause.maxRank or blockReason() ~= nil then playDeny() return end
					state.clauseRanks[clause.id] = rank + 1
					playClick()
					refresh()
				end

				local minus = vgui.Create("DButton", row)
				minus:Dock(RIGHT)
				minus:SetWide(34)
				minus:DockMargin(2, 9, 2, 9)
				minus:SetText("")
				minus.Paint = function(_, w, h)
					local rank = state.clauseRanks[clause.id] or 0
					ArtDeco.FillDecoPanel(0, 0, w, h, C.cardIdle, 4)
					ArtDeco.DrawDecoFrame(0, 0, w, h, rank > 0 and C.gold or Color(110, 96, 74), 4)
					draw.SimpleText("-", "Arcana_Ancient", w * 0.5, h * 0.5, rank > 0 and C.textBright or Color(140, 128, 108), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
				end
				minus.DoClick = function()
					local rank = state.clauseRanks[clause.id] or 0
					if rank <= 0 then playDeny() return end
					state.clauseRanks[clause.id] = rank > 1 and (rank - 1) or nil
					playClick()
					refresh()
				end
			end
		end
	end

	----------------------------------------------------------------
	-- Step 4: RECAP
	----------------------------------------------------------------
	local function buildStepRecap()
		buildWizardHeader("REVIEW YOUR SPELL", "Check the numbers, name it, and pay the one-time cost.")

		local compiled = state.essence and P.Compile(buildDef(state)) or nil
		local budget = P.Budget(P.GetClientState().level)

		-- Nav with BACK + submit. The name check reads the entry live: a DTextEntry
		-- only fires OnValueChange on enter/focus-loss, so we poll GetValue instead.
		local nameEntry

		local nav = vgui.Create("DPanel", right)
		nav:Dock(BOTTOM)
		nav:SetTall(44)
		nav:DockMargin(16, 6, 16, 12)
		nav.Paint = nil

		local back = decoButton(nav, {
			label = "< BACK",
			onClick = function()
				state.step = 3
				refresh()
			end,
		})
		back:Dock(LEFT)
		back:SetWide(100)

		local function currentName()
			if IsValid(nameEntry) then return string.Trim(nameEntry:GetValue() or "") end
			return string.Trim(state.name or "")
		end

		local function canSubmit()
			if not compiled then return false end
			if compiled.points > budget then return false end
			return #currentName() >= 3
		end

		-- Two-line submit: the one-time creation cost lives under the label,
		-- vault-imprint style.
		local submit = vgui.Create("DButton", nav)
		submit:Dock(RIGHT)
		submit:SetWide(340)
		submit:SetText("")
		submit.Paint = function(pnl, w, h)
			local enabled = canSubmit()
			local hovered = enabled and pnl:IsHovered()
			ArtDeco.FillDecoPanel(0, 0, w, h, hovered and Color(58, 44, 32, 235) or Color(46, 36, 26, 235), 6)
			ArtDeco.DrawDecoFrame(0, 0, w, h, enabled and C.gold or Color(120, 105, 80), 6)
			local txtCol = enabled and C.textBright or Color(160, 150, 135)
			draw.SimpleText("CREATE SPELL", "Arcana_Ancient", w * 0.5, h * 0.5 - 8, txtCol, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
			if compiled then
				local cost = ("%s coins, %d shards"):format(
					string.Comma(compiled.consecrationCoins), compiled.consecrationShards)
				draw.SimpleText(cost, "Arcana_AncientSmall", w * 0.5, h * 0.5 + 9, C.textDim, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
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

		-- Name entry above the nav.
		local nameRow = vgui.Create("DPanel", right)
		nameRow:Dock(BOTTOM)
		nameRow:SetTall(40)
		nameRow:DockMargin(16, 0, 16, 0)
		nameRow.Paint = function(_, _, h)
			draw.SimpleText("NAME", "Arcana_Ancient", 0, h * 0.5, C.paleGold, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		end

		-- Default name: the composition ("Poison Area"). Replaced when the
		-- composition changes, unless the player typed their own.
		local defaultName = compiled and (P.Essences[compiled.essence].label .. " " .. P.Forms[compiled.form].label) or ""
		if state.name == "" or state.name == state.lastDefaultName then
			state.name = defaultName
		end
		state.lastDefaultName = defaultName

		nameEntry = vgui.Create("DTextEntry", nameRow)
		nameEntry:Dock(FILL)
		nameEntry:DockMargin(70, 3, 0, 3)
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

		-- Recap body: animated essence circle on the left, info column on the right.
		local body = vgui.Create("DPanel", right)
		body:Dock(FILL)
		body:DockMargin(16, 8, 16, 8)
		body.Paint = function(_, w, h)
			if not compiled then
				draw.SimpleText("Incomplete spell. Go back and choose a form and an element.", "Arcana_Ancient", 0, 8, Color(220, 130, 90))
				return
			end

			local over = compiled.points > budget
			local name = string.Trim(state.name or "")
			local ix, infoW, y = drawSpellOverview(w, h, compiled, #name >= 1 and name or nil, over and 46 or 26)
			draw.SimpleText("POWER", "Arcana_AncientSmall", ix, y + 1, C.paleGold)
			local barX, barW = ix + 64, infoW - 64 - 110
			surface.SetDrawColor(46, 36, 26, 235)
			surface.DrawRect(barX, y + 2, barW, 12)
			surface.SetDrawColor(over and Color(200, 80, 60, 220) or C.xpFill)
			surface.DrawRect(barX + 2, y + 4, math.floor((barW - 4) * math.Clamp(compiled.points / math.max(1, budget), 0, 1)), 8)
			surface.SetDrawColor(C.gold)
			surface.DrawOutlinedRect(barX, y + 2, barW, 12)
			draw.SimpleText(compiled.points .. " / " .. budget, "Arcana_AncientSmall", barX + barW + 10, y + 1, over and Color(220, 110, 90) or C.textBright)
			if over then
				y = y + 20
				draw.SimpleText("Over your power limit. Remove modifiers.", "Arcana_AncientSmall", ix, y, Color(220, 110, 90))
			end
		end
	end

	----------------------------------------------------------------
	-- Details view (occupied slot)
	----------------------------------------------------------------
	local function buildDetails(slot)
		local def = activeDefForSlot(slot)
		if not def then return end
		local compiled = P.Compile(def)

		local actions = vgui.Create("DPanel", right)
		actions:Dock(BOTTOM)
		actions:SetTall(34)
		actions:DockMargin(16, 4, 16, 12)
		actions.Paint = nil

		if not isConsecrated(def) then
			local activate = confirmButton(actions, "ACTIVATE", "CONFIRM PAYMENT?", function()
				net.Start("Arcana_Spellcraft_Consecrate")
				net.WriteUInt(slot, 8)
				net.SendToServer()
			end)
			activate:Dock(LEFT)
			activate:SetWide(220)
		end

		local deleteBtn = decoButton(actions, {
			label = "DELETE",
			frameColor = function() return Color(170, 80, 60) end,
			onClick = function()
				playClick()
				showDeleteModal(frame, activeNameForSlot(slot), function()
					net.Start("Arcana_Spellcraft_Dissolve")
					net.WriteUInt(slot, 8)
					net.SendToServer()
				end)
			end,
		})
		deleteBtn:Dock(RIGHT)
		deleteBtn:SetWide(160)

		-- Same overview as the review step, then a live status underneath: a
		-- single "ready" line, or the requirements checklist when locked.
		local body = vgui.Create("DPanel", right)
		body:Dock(FILL)
		body:DockMargin(16, 12, 16, 4)
		body.Paint = function(_, w, h)
			if not compiled then
				draw.SimpleText("Invalid spell", "Arcana_Ancient", 0, 8, Color(220, 110, 90))
				return
			end

			local st = P.GetClientState()
			st.consecrated = isConsecrated(def)
			local req = P.Requirements(def, st)

			local extraH = req.castable and 32 or (34 + (4 + table.Count(compiled.ranks)) * 26)
			local ix, _, y = drawSpellOverview(w, h, compiled, activeNameForSlot(slot), extraH)
			y = y + 6

			if req.castable then
				drawMark(ix, y, true)
				draw.SimpleText("Ready to cast. Assign it to a quickslot in your grimoire.", "Arcana_Ancient", ix + 22, y, Color(150, 220, 150))
				return
			end

			draw.SimpleText("REQUIREMENTS ON THIS SERVER", "Arcana_Ancient", ix, y, C.paleGold)
			y = y + 28

			local function line(ok, text)
				drawMark(ix, y, ok)
				draw.SimpleText(text, "Arcana_Ancient", ix + 22, y, ok and C.textBright or C.textDim)
				y = y + 26
			end

			line(req.checks.level.ok, "Level " .. req.checks.level.need)
			local ess = req.checks.essence
			local essText = ess.label .. " element"
			if not ess.ok then
				essText = essText .. (ess.bargain and "  (the Golden Sun's bargain)" or
					("  (buy in the ELEMENT step: " .. string.Comma(ess.unlock.coins) .. " coins, " .. ess.unlock.shards .. " shards)"))
			end
			line(ess.ok, essText)
			for _, cl in ipairs(req.checks.clauses) do
				line(cl.ok, cl.label .. (cl.rank > 1 and (" " .. cl.rank) or "") .. (cl.ok and "" or ("  (level " .. cl.need .. ")")))
			end
			line(req.checks.budget.ok, "Power " .. req.checks.budget.need .. " / " .. req.checks.budget.have)
			local con = req.checks.consecrated
			line(con.ok, con.ok and "Activated" or ("Activation cost: " .. string.Comma(con.coins) .. " coins, " .. con.shards .. " shards"))
		end
	end

	----------------------------------------------------------------
	-- refresh: single rebuild entry point
	----------------------------------------------------------------
	refresh = function()
		if not IsValid(right) then return end
		clearChildren(right)
		buildSlotList()

		-- Level gate up front: no point composing a spell you cannot create.
		-- Carried spells still show their status in the slot list and details.
		local st = P.GetClientState()
		local minLevel = P.Config().minLevel
		if (st.level or 0) < minLevel and not activeDefForSlot(state.selSlot) then
			local locked = vgui.Create("DPanel", right)
			locked:Dock(FILL)
			locked.Paint = function(_, w, h)
				local cx, cy = w * 0.5, h * 0.5
				local t = CurTime()
				local dim = Color(150, 132, 100)
				Arcana.Circle.Draw2DPatternRing(2, cx, cy - 40, 70, t * 3, dim, 120)
				Arcana.Circle.Draw2DRing(Arcana.Circle.RING_TYPES.SIMPLE_LINE, cx, cy - 40, 52, -t * 2, dim, 100)
				draw.SimpleText("SPELL CRAFTING LOCKED", "Arcana_AncientLarge", cx, cy + 60, C.paleGold, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
				draw.SimpleText("Requires level " .. minLevel .. ". You are level " .. (st.level or 0) .. ".", "Arcana_Ancient", cx, cy + 92, C.textDim, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
			end
			return
		end

		if activeDefForSlot(state.selSlot) then
			buildDetails(state.selSlot)
		else
			if state.step == 1 then
				buildStepForm()
			elseif state.step == 2 then
				buildStepEssence()
			elseif state.step == 3 then
				buildStepModifiers()
			else
				buildStepRecap()
			end
		end
	end

	refresh()

	-- Server pushed new state (essence bought, consecrated, register/unregister).
	hook.Add("Arcana_Spellcraft_StateChanged", frame, function()
		if IsValid(frame) then
			-- A successful craft turns the selected slot occupied: reset the wizard.
			if activeDefForSlot(state.selSlot) and state.step == 4 then
				state.step = 1
				state.form = nil
				state.essence = nil
				state.clauseRanks = {}
				state.name = ""
			end
			refresh()
		end
	end)

	frame.Think = function()
		if not IsValid(machine) then frame:Close() end
	end
end

net.Receive("Arcana_OpenSpellcraftMenu", function()
	local ent = net.ReadEntity()
	if IsValid(ent) then OpenSpellcraftMenu(ent) end
end)
