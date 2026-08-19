-- Crystal Garden menu.

if not CLIENT then return end

local C

local PENDING_ELEM = {}

-- Using a station again while its menu is up would otherwise stack a second
-- copy on top of the first.
local activeFrame

----------------------------------------------------------------------
-- Background motif: a root system seen in cross section
----------------------------------------------------------------------
-- Deliberately not the house pattern of a glow source with things drifting
-- past it: this is a branching structure with sap climbing it, which is the
-- one shape a garden owns and no other station does.
local rootCache = {}

-- Major roots enter beyond one edge and leave beyond another, so what shows is
-- a slice of something much larger rather than a shrub standing in the panel.
local STEP = 16
local SEG_BUDGET = 620

local function buildRoots(w, h, seed)
	local key = string.format("%d_%d_%d", seed, w, h)
	local cached = rootCache[key]
	if cached then return cached end

	local segs = {}
	local leaves = {}
	math.randomseed(seed)

	-- Walks a root across the panel, the heading drifting by a curl that
	-- itself drifts, which is what gives a long sweep instead of a jitter.
	local function grow(x, y, ang, thickness, depth, life)
		local curl = math.Rand(-0.05, 0.05)

		for _ = 1, life do
			if #segs >= SEG_BUDGET then return end

			curl = math.Clamp(curl + math.Rand(-0.035, 0.035), -0.12, 0.12)
			ang = ang + curl

			local step = STEP * (1 - depth * 0.16)
			local nx = x + math.cos(ang) * step
			local ny = y + math.sin(ang) * step
			segs[#segs + 1] = {x1 = x, y1 = y, x2 = nx, y2 = ny, t = thickness, depth = depth}
			x, y = nx, ny

			-- Run well past the edge before stopping: the root should read as
			-- leaving the frame, not as ending at it
			if x < -90 or x > w + 90 or y < -90 or y > h + 90 then return end

			if depth < 3 and math.random() < 0.05 then
				local side = math.random() < 0.5 and 1 or -1
				grow(x, y, ang + side * math.Rand(0.45, 1.05), math.max(1, thickness - 1), depth + 1, math.ceil(life * 0.55))
			end

			if depth >= 2 and math.random() < 0.05 then
				leaves[#leaves + 1] = {x = x, y = y, ang = ang + math.Rand(-1.1, 1.1), size = math.Rand(5, 9)}
			end
		end
	end

	-- Enough life to clear the long axis even after wandering
	local life = math.ceil((math.max(w, h) + 240) / STEP)
	local majors = 5

	for i = 1, majors do
		if i <= 3 then
			-- Crossing the long axis, alternating sides
			local fromLeft = (i % 2 == 1)
			grow(fromLeft and -70 or w + 70, math.Rand(-30, h + 30), (fromLeft and 0 or math.pi) + math.Rand(-0.55, 0.55), 3, 1, life)
		else
			-- A couple climbing in from below and out through the top or side
			grow(math.Rand(0, w), h + 70, math.rad(-90) + math.Rand(-0.7, 0.7), 3, 1, life)
		end
	end

	-- Thinned at build time so the draw cost is fixed rather than scaling with
	-- however many tips the branching happened to produce
	local thinned = {}

	for i = 1, #leaves, 2 do
		thinned[#thinned + 1] = leaves[i]
	end

	-- Leaving the RNG seeded would make every other math.random caller this
	-- frame repeat the same sequence.
	math.randomseed(SysTime())

	local built = {segs = segs, leaves = thinned}
	rootCache[key] = built

	return built
end

-- Woody at the rooted end, greening as it climbs, so the panel reads as living
-- growth rather than bare root
local ROOT_BASE_COL = Color(126, 96, 58)
local ROOT_TIP_COL = Color(104, 148, 78)
local LEAF_COL = Color(118, 168, 88)
local SAP_COL = Color(226, 214, 150)

local function drawLeaf(cx, cy, ang, size, alpha)
	local fx, fy = math.cos(ang), math.sin(ang)
	local px, py = -fy, fx

	draw.NoTexture()
	surface.SetDrawColor(LEAF_COL.r, LEAF_COL.g, LEAF_COL.b, alpha)
	surface.DrawPoly({
		{x = cx, y = cy},
		{x = cx + fx * size * 0.55 + px * size * 0.42, y = cy + fy * size * 0.55 + py * size * 0.42},
		{x = cx + fx * size, y = cy + fy * size},
		{x = cx + fx * size * 0.55 - px * size * 0.42, y = cy + fy * size * 0.55 - py * size * 0.42},
	})
end

local function drawGardenBackground(w, h, seed)
	local x, y = 6, 6
	local ww, hh = w - 12, h - 12
	ArtDeco.BeginOctagonClip(x, y, ww, hh, 14)

	-- Damp earth, darkening with depth rather than glowing from a light source
	surface.SetDrawColor(17, 14, 10, 246)
	surface.DrawRect(x, y, ww, hh)

	local built = buildRoots(ww, hh, seed)
	local segs = built.segs

	for _, s in ipairs(segs) do
		local a = math.max(30, 78 - s.depth * 14)
		-- Woody brown on the trunks easing to green out at the fine branches
		local f = math.min(1, (s.depth - 1) / 2)
		surface.SetDrawColor(Lerp(f, ROOT_BASE_COL.r, ROOT_TIP_COL.r), Lerp(f, ROOT_BASE_COL.g, ROOT_TIP_COL.g), Lerp(f, ROOT_BASE_COL.b, ROOT_TIP_COL.b), a)

		-- Thickness without a line-width call: parallel strokes offset along
		-- the segment's own perpendicular, so a corner does not fan open
		local dx, dy = s.x2 - s.x1, s.y2 - s.y1
		local len = math.sqrt(dx * dx + dy * dy)

		if len < 0.01 then continue end

		local px, py = -dy / len, dx / len

		for k = 0, s.t - 1 do
			local o = k - (s.t - 1) * 0.5
			surface.DrawLine(x + s.x1 + px * o, y + s.y1 + py * o, x + s.x2 + px * o, y + s.y2 + py * o)
		end
	end

	for _, l in ipairs(built.leaves) do
		drawLeaf(x + l.x, y + l.y, l.ang, l.size, 72)
	end

	-- Sap climbing back toward the surface, one mote per chosen segment
	local now = RealTime()
	local count = math.min(#segs, 44)

	for i = 1, count do
		local s = segs[((i * 7) % #segs) + 1]
		local t = ((now * 0.22) + i * 0.13) % 1
		-- Climbs from the rooted end out toward the tip
		local px = x + Lerp(t, s.x1, s.x2)
		local py = y + Lerp(t, s.y1, s.y2)
		local a = math.sin(t * math.pi) * 105

		surface.SetDrawColor(SAP_COL.r, SAP_COL.g, SAP_COL.b, a)
		surface.DrawRect(math.Round(px), math.Round(py), 2, 2)
	end

	ArtDeco.EndOctagonClip()
end

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------
local function itemLabel(item)
	local data = Arcana.Inventory and Arcana.Inventory.Items and Arcana.Inventory.Items[item]

	return data and data.name or item
end

-- ArtDeco.DrawTruncatedText draws left aligned from x, so feeding it a centre
-- point runs the text off the right edge.  This fits first, then centres.
local function drawFitted(font, text, cx, y, col, maxW, align)
	surface.SetFont(font)

	if surface.GetTextSize(text) > maxW then
		local trimmed = text

		while #trimmed > 0 do
			trimmed = string.sub(trimmed, 1, #trimmed - 1)

			if surface.GetTextSize(trimmed .. "…") <= maxW then break end
		end

		text = trimmed .. "…"
	end

	draw.SimpleText(text, font, cx, y, col, align or TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
end

-- The card's flower stands in for a wall of text: its size carries growth and
-- its colour carries both the element and how sick the plant is.
local WILT_COL = Color(122, 112, 94)

-- Empty beds read as unlit ground, so they take a neutral dark instead of the
-- warm card tone the planted ones use
local EMPTY_IDLE = Color(12, 12, 14, 168)
local EMPTY_HOVER = Color(28, 28, 32, 205)
-- Brass pulled most of the way toward its own luminance: still reads as the
-- same metal as the planted beds, just gone cold
local EMPTY_OUTLINE = Color(132, 124, 104, 175)

-- Shared by the condition caption and its progress bar, so the two always
-- agree about how bad things are
local WITHERING_COL = Color(224, 168, 96)
local DYING_COL = Color(224, 118, 96)

local function drawRosette(cx, cy, r, col, petals)
	draw.NoTexture()
	surface.SetDrawColor(col.r, col.g, col.b, col.a or 255)

	for i = 1, petals do
		local a = (i / petals) * math.pi * 2
		local inner = r * 0.5

		surface.DrawPoly({
			{x = cx, y = cy},
			{x = cx + math.cos(a - 0.38) * inner, y = cy + math.sin(a - 0.38) * inner},
			{x = cx + math.cos(a) * r, y = cy + math.sin(a) * r},
			{x = cx + math.cos(a + 0.38) * inner, y = cy + math.sin(a + 0.38) * inner},
		})
	end

	surface.SetDrawColor(255, 245, 215, 210)
	surface.DrawRect(math.Round(cx - r * 0.14), math.Round(cy - r * 0.14), math.max(2, r * 0.28), math.max(2, r * 0.28))
end

local function costSegments(cost)
	local G = Arcana.Gardening
	local segs = {}

	for item, amount in pairs(cost) do
		segs[#segs + 1] = {
			text = amount .. " " .. itemLabel(item),
			color = G.DustColors[item] or C.textDim,
			order = item == "crystal_dust" and 1 or 2,
		}
	end

	table.sort(segs, function(a, b) return a.order < b.order end)

	return segs
end

local function canAfford(cost)
	local ply = LocalPlayer()

	for item, amount in pairs(cost) do
		if Arcana.GetItemCount(ply, item) < amount then return false end
	end

	return true
end

-- Detail lives in a hover tooltip rather than on the button, the way the
-- astral vault's summon buttons carry their cost (astral_vault/ui.lua).
local function attachHint(btn, buildFn)
	btn.OnCursorEntered = function(pnl)
		if IsValid(pnl._hint) then return end
		-- Nothing to say, so no panel at all
		if #buildFn() == 0 then return end

		local tip = vgui.Create("DPanel")
		tip:SetDrawOnTop(true)
		tip:SetMouseInputEnabled(false)

		tip.Paint = function(_, w, h)
			ArtDeco.FillDecoPanel(0, 0, w, h, C.decoBg, 8)
			ArtDeco.DrawDecoFrame(0, 0, w, h, C.gold, 8)

			for i, l in ipairs(buildFn()) do
				ArtDeco.DrawCostLine("Arcana_AncientSmall", w * 0.5, 9 + (i - 1) * 18, {l}, TEXT_ALIGN_CENTER)
			end
		end

		pnl._hint = tip

		local function place()
			if not IsValid(tip) then return end

			-- Sized every tick: the yield gains a line as each elemental dust
			-- starts accruing
			tip:SetSize(200, 14 + 18 * math.max(1, #buildFn()))

			local mx, my = gui.MousePos()
			tip:SetPos(math.Clamp(mx + 16, 0, ScrW() - tip:GetWide()), math.Clamp(my - 60, 0, ScrH() - tip:GetTall()))
		end

		place()

		local id = "ArcanaGardenHint_" .. tostring(tip)

		hook.Add("Think", id, function()
			if not IsValid(tip) or not IsValid(pnl) or not pnl:IsHovered() then
				hook.Remove("Think", id)
				if IsValid(tip) then tip:Remove() end

				return
			end

			place()
		end)
	end

	btn.OnCursorExited = function(pnl)
		if IsValid(pnl._hint) then pnl._hint:Remove() end
		pnl._hint = nil
	end
end

-- A button with nothing to do goes cold rather than explaining itself
local function makeButton(parent, x, y, w, h, labelFn, fn, enabledFn)
	local btn = vgui.Create("DButton", parent)
	btn:SetText("")
	btn:SetPos(x, y)
	btn:SetSize(w, h)

	btn.Paint = function(pnl, bw, bh)
		local on = not enabledFn or enabledFn()
		local hovered = on and pnl:IsHovered()

		ArtDeco.FillDecoPanel(0, 0, bw, bh, hovered and C.cardHover or C.cardIdle, 6)
		ArtDeco.DrawDecoFrame(0, 0, bw, bh, hovered and C.paleGold or (on and C.brassInner or EMPTY_OUTLINE), 6)
		drawFitted("Arcana_AncientSmall", labelFn(), bw * 0.5, bh * 0.5 - 8, on and (hovered and C.paleGold or C.textBright) or C.textDim, bw - 12)
	end

	btn.DoClick = function()
		if enabledFn and not enabledFn() then
			surface.PlaySound("buttons/button10.wav")

			return
		end

		fn()
	end

	return btn
end

----------------------------------------------------------------------
-- Menu
----------------------------------------------------------------------
-- No footer and no stat strip: the actions ride the title band and the reserve
-- is a gauge down the left edge, which leaves the body to the beds alone.
-- The grid starts directly under the title band: the gauge's percentage sits
-- below the bar, so nothing needs a gap up here.
local FRAME_W, FRAME_H = 900, 428
local GRID_TOP = 58
local CARD_H = 152
local GAUGE_X, GAUGE_W = 24, 26
local GRID_LEFT = GAUGE_X + GAUGE_W + 16

local function OpenGardenMenu(garden)
	local ply = LocalPlayer()
	if not IsValid(ply) or not IsValid(garden) then return end

	C = ArtDeco.Colors

	if IsValid(activeFrame) then activeFrame:Remove() end

	local G = Arcana.Gardening
	-- Declared up here because frame.Paint repositions the icon off the chip's
	-- measured right edge, and both are created further down
	local info, lastChipRight
	local frame = vgui.Create("DFrame")
	activeFrame = frame
	frame:SetSize(math.min(FRAME_W, ScrW()), math.min(FRAME_H, ScrH()))
	frame:Center()
	frame:SetTitle("")
	frame:MakePopup()

	ArtDeco.MakeDraggableByBand(frame, 44)

	-- Keyed to the garden itself rather than rolled per opening, so a given bed
	-- keeps the same root pattern every time you walk up to it.
	local bgSeed = garden:EntIndex() * 7919

	hook.Add("HUDPaint", frame, function()
		local x, y = frame:LocalToScreen(0, 0)
		ArtDeco.DrawBlurRect(x + 6, y + 6, frame:GetWide() - 12, frame:GetTall() - 12, 4, 8)
	end)

	ArtDeco.StyleCloseButton(frame)
	if IsValid(frame.btnMinim) then frame.btnMinim:Hide() end
	if IsValid(frame.btnMaxim) then frame.btnMaxim:Hide() end

	frame.OnClose = function()
		if IsValid(garden) then
			net.Start("Arcana_Garden_Close")
			net.WriteEntity(garden)
			net.SendToServer()
		end
	end

	frame.OnRemove = frame.OnClose

	frame.Think = function()
		if not IsValid(garden) or ply:GetPos():DistToSqr(garden:GetPos()) > (G.USE_RANGE * 1.5) ^ 2 then
			frame:Close()
		end
	end

	frame.Paint = function(_, w, h)
		drawGardenBackground(w, h, bgSeed)
		ArtDeco.DrawDecoFrame(6, 6, w - 12, h - 12, C.gold, 14)

		local titleRight = ArtDeco.DrawTitle("Arcana_AncientLarge", "CRYSTAL GARDEN", 7, 50, C.paleGold)

		if not IsValid(garden) then return end

		local slots = G.UnpackSlots(garden:GetGardenSlots())
		local planted = 0

		for i = 1, G.MAX_SLOTS do
			if slots[i] then planted = planted + 1 end
		end

		-- The bed count rides beside the title as a chip, the way the other
		-- stations carry their title-bar readouts
		local chipRight = ArtDeco.DrawChip("Arcana_AncientSmall", planted .. " / " .. G.MAX_SLOTS .. " FLOWERS", titleRight + 14, 7, 50, C.paleGold, C.chipTextCol)

		-- The chip's width moves with the count, so the icon follows it rather
		-- than sitting at a hardcoded offset
		if IsValid(info) and lastChipRight ~= chipRight then
			lastChipRight = chipRight
			info:SetPos(chipRight + 10, 18)
		end

		-- Reserve gauge down the left edge, filling bottom up like anything that
		-- holds a liquid, in the dust's own crystal blue.  Square outline: the
		-- deco octagon does not sit on a straight-sided fill.
		local reserve = garden:GetDustReserve()
		local frac = math.Clamp(reserve / G.RESERVE_CAP, 0, 1)
		local gaugeY = GRID_TOP
		-- Squared off with the two rows of beds, so the gauge and the grid read
		-- as one block with the action row sitting under both
		local gaugeH = CARD_H * 2 + 10
		local dust = G.DustColors.crystal_dust
		local fillH = (gaugeH - 8) * frac

		surface.SetDrawColor(12, 10, 8, 235)
		surface.DrawRect(GAUGE_X, gaugeY, GAUGE_W, gaugeH)

		surface.SetDrawColor(dust.r, dust.g, dust.b, 232)
		surface.DrawRect(GAUGE_X + 4, gaugeY + gaugeH - 4 - fillH, GAUGE_W - 8, fillH)

		surface.SetDrawColor(C.brassInner.r, C.brassInner.g, C.brassInner.b, 255)
		surface.DrawOutlinedRect(GAUGE_X, gaugeY, GAUGE_W, gaugeH, 1)

		draw.SimpleText(math.Round(frac * 100) .. "%", "Arcana_AncientSmall", GAUGE_X + GAUGE_W * 0.5, gaugeY + gaugeH + 6, dust, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
	end

	----------------------------------------------------------------------
	-- Slot grid
	----------------------------------------------------------------------
	local grid = vgui.Create("DPanel", frame)
	grid:SetPos(GRID_LEFT, GRID_TOP)
	grid:SetSize(frame:GetWide() - GRID_LEFT - 24, CARD_H * 2 + 10)
	grid.Paint = nil

	local cols = 5
	local cardW = (grid:GetWide() - (cols - 1) * 10) / cols
	local showPicker

	for i = 1, G.MAX_SLOTS do
		local col = (i - 1) % cols
		local row = math.floor((i - 1) / cols)
		local card = vgui.Create("DButton", grid)
		card:SetText("")
		card:SetPos(col * (cardW + 10), row * (CARD_H + 10))
		card:SetSize(cardW, CARD_H)

		card.Paint = function(pnl, w, h)
			local slots = IsValid(garden) and G.UnpackSlots(garden:GetGardenSlots()) or {}
			local slot = slots[i]
			local hovered = pnl:IsHovered()

			if not slot then
				-- An empty bed is a hole in the panel, not a card: neutral dark
				-- rather than the planted cards' warm tone, and nothing in it
				-- but the mark.
				ArtDeco.FillDecoPanel(0, 0, w, h, hovered and EMPTY_HOVER or EMPTY_IDLE, 10)
				ArtDeco.DrawDecoFrame(0, 0, w, h, hovered and C.paleGold or EMPTY_OUTLINE, 10)

				local cx, cy = w * 0.5, h * 0.5
				surface.SetDrawColor(C.gold.r, C.gold.g, C.gold.b, hovered and 165 or 70)
				surface.DrawRect(cx - 11, cy - 2, 22, 3)
				surface.DrawRect(cx - 2, cy - 11, 3, 22)

				return
			end

			local def = G.Flowers[slot.id]
			if not def then return end

			ArtDeco.FillDecoPanel(0, 0, w, h, hovered and C.cardHover or C.cardIdle, 10)
			ArtDeco.DrawDecoFrame(0, 0, w, h, hovered and C.paleGold or C.brassInner, 10)

			local base = def.color
			local tint = Color(Lerp(slot.wither, base.r, WILT_COL.r), Lerp(slot.wither, base.g, WILT_COL.g), Lerp(slot.wither, base.b, WILT_COL.b))

			-- Bud to bloom: the icon itself is the growth readout
			local r = Lerp(slot.growth, 9, 27)
			drawRosette(w * 0.5, h * 0.34, r, tint, def.petals or 6)

			drawFitted("Arcana_AncientSmall", def.short or def.label, w * 0.5, h * 0.62, C.textBright, w - 16)

			-- Wither takes the same colours as its caption, and outranks growth:
			-- a plant that is both growing and dying has one thing worth saying.
			-- A mature plant with dust in the reserve has nothing left to track,
			-- so it gets no bar at all.
			local barFrac, barCol

			if slot.wither > 0 then
				barFrac = slot.wither
				barCol = slot.wither >= 0.7 and DYING_COL or WITHERING_COL
			elseif slot.growth < 1 then
				barFrac = slot.growth
				barCol = tint
			end

			if barFrac then
				local barW = w - 40
				surface.SetDrawColor(0, 0, 0, 120)
				surface.DrawRect(20, h * 0.62 + 24, barW, 4)
				surface.SetDrawColor(barCol.r, barCol.g, barCol.b, 225)
				surface.DrawRect(20, h * 0.62 + 24, barW * barFrac, 4)
			end

			-- Only says something when there is something to say: a healthy
			-- growing plant needs no caption
			local note, noteCol

			-- Same thresholds ConditionLabel uses, so the card turns the moment
			-- the wording does
			if slot.wither >= 0.2 then
				note = G.ConditionLabel(slot.wither)
				noteCol = slot.wither >= 0.7 and DYING_COL or WITHERING_COL
			elseif slot.growth >= 1 then
				note = "Mature"
				noteCol = C.paleGold
			elseif hovered then
				note = math.floor(slot.growth * 100) .. "%"
				noteCol = C.textDim
			end

			if note then
				draw.SimpleText(note, "Arcana_AncientSmall", w * 0.5, h * 0.62 + 34, noteCol, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
			end
		end

		card.DoClick = function()
			if not IsValid(garden) then return end

			local slots = G.UnpackSlots(garden:GetGardenSlots())

			if slots[i] then
				net.Start("Arcana_Garden_Uproot")
				net.WriteEntity(garden)
				net.WriteUInt(i, 8)
				net.SendToServer()
			else
				showPicker(i)
			end

			surface.PlaySound("buttons/button15.wav")
		end

	end

	----------------------------------------------------------------------
	-- Flower picker
	----------------------------------------------------------------------
	showPicker = function(slot)
		local picker = vgui.Create("DPanel", frame)
		picker:SetPos(GRID_LEFT, GRID_TOP)
		picker:SetSize(frame:GetWide() - GRID_LEFT - 24, CARD_H * 2 + 10)
		picker:MoveToFront()

		picker.Paint = function(_, w, h)
			ArtDeco.FillDecoPanel(0, 0, w, h, Color(20, 16, 12, 251), 10)
			ArtDeco.DrawDecoFrame(0, 0, w, h, C.gold, 10)
			draw.SimpleText("Choose a flower", "Arcana_Ancient", w * 0.5, 12, C.paleGold, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
		end

		local list = vgui.Create("DScrollPanel", picker)
		list:SetPos(12, 44)
		list:SetSize(picker:GetWide() - 24, picker:GetTall() - 56)
		ArtDeco.StyleScrollBar(list, 6)

		for _, def in ipairs(G.FlowerOrder) do
			local row = vgui.Create("DButton", list)
			row:SetText("")
			row:Dock(TOP)
			row:DockMargin(0, 0, 0, 6)
			row:SetTall(42)

			row.Paint = function(pnl, w, h)
				local afford = canAfford(def.plantCost)
				ArtDeco.FillDecoPanel(0, 0, w, h, pnl:IsHovered() and C.cardHover or C.cardIdle, 8)

				local col = def.color
				drawRosette(26, h * 0.5, 11, afford and col or Color(col.r * 0.45, col.g * 0.45, col.b * 0.45), def.petals or 6)

				draw.SimpleText(def.label, "Arcana_AncientSmall", 48, h * 0.5, afford and C.textBright or C.textDim, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)

				local segs = costSegments(def.plantCost)

				if not afford then
					for _, s in ipairs(segs) do
						s.color = C.textDim
					end
				end

				ArtDeco.DrawCostLine("Arcana_AncientSmall", w - 14, h * 0.5 - 8, segs, TEXT_ALIGN_RIGHT)
			end

			row.DoClick = function()
				if not canAfford(def.plantCost) then
					surface.PlaySound("buttons/button10.wav")

					return
				end

				net.Start("Arcana_Garden_Plant")
				net.WriteEntity(garden)
				net.WriteUInt(slot, 8)
				net.WriteString(def.id)
				net.SendToServer()

				surface.PlaySound("buttons/button15.wav")
				picker:Remove()
			end
		end

		local cancel = vgui.Create("DButton", picker)
		cancel:SetText("")
		cancel:SetSize(90, 24)
		cancel:SetPos(picker:GetWide() - 102, 10)

		cancel.Paint = function(pnl, w, h)
			draw.SimpleText("Cancel", "Arcana_AncientSmall", w * 0.5, h * 0.5, pnl:IsHovered() and C.paleGold or C.textDim, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		end

		cancel.DoClick = function()
			picker:Remove()
		end
	end

	----------------------------------------------------------------------
	-- Actions
	----------------------------------------------------------------------
	-- One pair of equal buttons centred on the frame. Refill tops the reserve
	-- up from what the player is carrying: an amount box for it was a row of
	-- chrome to answer a question nobody asks.
	local BUTTON_W, BUTTON_H, GAP = 168, 32, 12
	-- Centred in the band under the beds, measured off the grid's real bottom.
	-- A guessed offset had it sitting 2px under the grid with 16px of dead air
	-- beneath, which read as the row floating off the frame's foot.
	local gridBottom = GRID_TOP + CARD_H * 2 + 10
	local ROW_Y = gridBottom + math.floor((frame:GetTall() - 6 - gridBottom - BUTTON_H) * 0.5)
	local rowX = (frame:GetWide() - (BUTTON_W * 2 + GAP)) * 0.5

	-- Both amounts drive their button's cost hint and whether it is live at all
	local function refillAmount()
		if not IsValid(garden) then return 0 end

		return math.min(Arcana.GetItemCount(LocalPlayer(), "crystal_dust"), G.RESERVE_CAP - garden:GetDustReserve())
	end

	local function harvestTotal()
		local n = IsValid(garden) and garden:GetPendingDust() or 0

		for _, amount in pairs(PENDING_ELEM) do
			n = n + amount
		end

		return n
	end

	local harvest = makeButton(frame, rowX + BUTTON_W + GAP, ROW_Y, BUTTON_W, BUTTON_H, function() return "Harvest" end, function()
		if not IsValid(garden) then return end

		net.Start("Arcana_Garden_Harvest")
		net.WriteEntity(garden)
		net.SendToServer()

		surface.PlaySound("buttons/button15.wav")
	end, function() return harvestTotal() > 0 end)

	local refill = makeButton(frame, rowX, ROW_Y, BUTTON_W, BUTTON_H, function() return "Refill" end, function()
		if not IsValid(garden) then return end

		net.Start("Arcana_Garden_Deposit")
		net.WriteEntity(garden)
		net.WriteUInt(math.Clamp(refillAmount(), 1, 65535), 16)
		net.SendToServer()

		surface.PlaySound("buttons/button15.wav")
	end, function() return refillAmount() > 0 end)

	-- The upkeep rule lives here rather than as a standing line of body text
	-- Just the cost. The button already says what it does.
	attachHint(refill, function()
		local amount = refillAmount()
		if amount <= 0 then return {} end

		return {{text = "-" .. amount .. " " .. itemLabel("crystal_dust"), color = G.DustColors.crystal_dust}}
	end)

	attachHint(harvest, function()
		local lines = {}

		if IsValid(garden) and garden:GetPendingDust() > 0 then
			lines[#lines + 1] = {text = "+" .. garden:GetPendingDust() .. " " .. itemLabel("crystal_dust"), color = G.DustColors.crystal_dust}
		end

		-- Sorted, because pairs order would reshuffle the list every frame
		local elems = {}

		for item, amount in pairs(PENDING_ELEM) do
			if amount >= 1 then elems[#elems + 1] = item end
		end

		table.sort(elems)

		for _, item in ipairs(elems) do
			lines[#lines + 1] = {text = "+" .. PENDING_ELEM[item] .. " " .. itemLabel(item), color = G.DustColors[item] or C.textDim}
		end

		return lines
	end)

	-- Sits beside the chip; frame.Paint moves it as the chip's width changes
	info = ArtDeco.CreateInfoIcon(frame, "Flowers use crystal dust to grow, if nothing is provided they will wither.", 300)
	info:SetPos(260, 18)
end

net.Receive("Arcana_Garden_Open", function()
	local garden = net.ReadEntity()
	if not IsValid(garden) then return end

	OpenGardenMenu(garden)
end)

-- Only the elemental trickle travels here: the reserve, pending dust and slot
-- layout are all networked vars already.
net.Receive("Arcana_Garden_State", function()
	net.ReadEntity()

	local count = net.ReadUInt(4)

	table.Empty(PENDING_ELEM)

	for _ = 1, count do
		local item = net.ReadString()
		PENDING_ELEM[item] = net.ReadUInt(16)
	end
end)
