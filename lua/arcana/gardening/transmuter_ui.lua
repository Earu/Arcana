-- Transmuter menu: what you lay out on one side, what comes back on the other.

if not CLIENT then return end

local C

-- Using the station again while its menu is up would otherwise stack a second
-- copy on top of the first.
local activeFrame

----------------------------------------------------------------------
-- Layout
----------------------------------------------------------------------
local FRAME_W, FRAME_H = 940, 520
-- The circles are sized off the slots rather than the other way round: at any
-- less than this the chord across the top and bottom slots is too short to
-- spell out "Radioactive Material" without an ellipsis.
local RADIUS = 146
-- Dead centre of the frame, not of the body below the title: the label goes in
-- the room left above and the controls in the room left below.
local CIRCLE_CY = FRAME_H * 0.5
local LEFT_CX, RIGHT_CX = 236, 704
local SLOT_W, SLOT_H = 236, 46
local ROW_Y = 425

----------------------------------------------------------------------
-- Background motif: engine turned metal
----------------------------------------------------------------------
-- Guilloche, the rose engine work found on instrument faces and struck plate:
-- overlapping circles cut into a field, which is what the back of a device
-- like this would actually look like.  It does not move; a slow band of light
-- crosses it instead, the way it would over engraved brass.
local ENGRAVE_R = 150
local ENGRAVE_STEP = 240
local ENGRAVE_PETALS = 8
local ENGRAVE_SEGS = 16
local SWEEP_TIME = 14
local BAND = 190

local ENGRAVE_BASE = Color(96, 78, 46)
local ENGRAVE_LIT = Color(216, 186, 118)

local engraveCache = {}

local function buildEngraving(w, h)
	local key = w .. "_" .. h
	local cached = engraveCache[key]
	if cached then return cached end

	local segs = {}
	-- Anything under a working circle is covered by it, so it is thrown away
	-- here rather than drawn every frame and painted over
	local discs = {
		{x = LEFT_CX - 6, y = CIRCLE_CY - 6, r = RADIUS - 2},
		{x = RIGHT_CX - 6, y = CIRCLE_CY - 6, r = RADIUS - 2},
	}

	local function hidden(x, y)
		for _, d in ipairs(discs) do
			local dx, dy = x - d.x, y - d.y
			if dx * dx + dy * dy < d.r * d.r then return true end
		end

		return false
	end

	local ring = ENGRAVE_R * 0.5

	for i = 0, math.ceil(w / ENGRAVE_STEP) do
		for j = 0, math.ceil(h / ENGRAVE_STEP) do
			local cx = i * ENGRAVE_STEP
			local cy = j * ENGRAVE_STEP
			-- Alternate rows offset so the field interlocks rather than
			-- reading as a grid of separate flowers
			if j % 2 == 1 then cx = cx + ENGRAVE_STEP * 0.5 end

			for k = 0, ENGRAVE_PETALS - 1 do
				local a = (k / ENGRAVE_PETALS) * math.pi * 2
				local ox, oy = cx + math.cos(a) * ring, cy + math.sin(a) * ring
				local px, py

				for s = 0, ENGRAVE_SEGS do
					local sa = (s / ENGRAVE_SEGS) * math.pi * 2
					local nx, ny = ox + math.cos(sa) * ring, oy + math.sin(sa) * ring

					if px then
						local offPanel = (px < -4 and nx < -4) or (px > w + 4 and nx > w + 4) or (py < -4 and ny < -4) or (py > h + 4 and ny > h + 4)

						if not offPanel and not (hidden(px, py) and hidden(nx, ny)) then
							segs[#segs + 1] = {x1 = px, y1 = py, x2 = nx, y2 = ny, s = (px + nx + py + ny) * 0.5}
						end
					end

					px, py = nx, ny
				end
			end
		end
	end

	engraveCache[key] = segs

	return segs
end

local function drawTransmuterBackground(w, h)
	local x, y = 6, 6
	local ww, hh = w - 12, h - 12
	ArtDeco.BeginOctagonClip(x, y, ww, hh, 14)

	surface.SetDrawColor(14, 12, 10, 247)
	surface.DrawRect(x, y, ww, hh)

	local segs = buildEngraving(ww, hh)
	local span = ww + hh
	local front = -BAND + ((RealTime() % SWEEP_TIME) / SWEEP_TIME) * (span + BAND * 2)

	for _, e in ipairs(segs) do
		local d = math.abs(e.s - front)
		local f = d < BAND and 1 - d / BAND or 0
		-- Eased, so the light has a soft edge instead of a moving hard line
		f = f * f

		surface.SetDrawColor(Lerp(f, ENGRAVE_BASE.r, ENGRAVE_LIT.r), Lerp(f, ENGRAVE_BASE.g, ENGRAVE_LIT.g), Lerp(f, ENGRAVE_BASE.b, ENGRAVE_LIT.b), 24 + f * 68)
		surface.DrawLine(x + e.x1, y + e.y1, x + e.x2, y + e.y2)
	end

	ArtDeco.EndOctagonClip()
end

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------
local EMPTY_IDLE = Color(12, 12, 14, 168)
local EMPTY_HOVER = Color(28, 28, 32, 205)
local EMPTY_OUTLINE = Color(132, 124, 104, 175)
local DENIED = Color(224, 118, 96)

local function itemLabel(item)
	local data = Arcana.Inventory and Arcana.Inventory.Items and Arcana.Inventory.Items[item]

	return data and data.name or item
end

local function itemColor(item)
	local G = Arcana.Gardening
	local dust = G.DustColors[item]
	if dust then return dust end

	local data = Arcana.Inventory and Arcana.Inventory.Items and Arcana.Inventory.Items[item]

	return data and data.color or C.textDim
end

local function held(item)
	return Arcana.GetItemCount(LocalPlayer(), item)
end

-- Cuts a string to fit rather than letting it run out of its panel
local function fitText(font, text, maxW)
	surface.SetFont(font)
	if surface.GetTextSize(text) <= maxW then return text end

	local trimmed = text

	while #trimmed > 0 do
		trimmed = string.sub(trimmed, 1, #trimmed - 1)
		if surface.GetTextSize(trimmed .. "…") <= maxW then break end
	end

	return trimmed .. "…"
end

local function drawRing(cx, cy, r, col, alpha, segments)
	segments = segments or 76
	surface.SetDrawColor(col.r, col.g, col.b, alpha)

	local px, py

	for i = 0, segments do
		local a = (i / segments) * math.pi * 2
		local nx, ny = cx + math.cos(a) * r, cy + math.sin(a) * r
		if px then surface.DrawLine(px, py, nx, ny) end
		px, py = nx, ny
	end
end

local function drawDisc(cx, cy, r, col, alpha)
	local poly = {}

	for i = 0, 47 do
		local a = (i / 48) * math.pi * 2
		poly[#poly + 1] = {x = cx + math.cos(a) * r, y = cy + math.sin(a) * r}
	end

	draw.NoTexture()
	surface.SetDrawColor(col.r, col.g, col.b, alpha)
	surface.DrawPoly(poly)
end

-- The two working circles: a dark disc to lift them off the engraving, a brass
-- rim, and ticks around it so they read as instruments rather than portals.
local function drawCircle(cx, cy, r, rimCol)
	drawDisc(cx, cy, r, Color(9, 9, 12), 238)
	drawRing(cx, cy, r, rimCol, 190)
	drawRing(cx, cy, r - 7, rimCol, 70)

	surface.SetDrawColor(rimCol.r, rimCol.g, rimCol.b, 150)

	for i = 0, 11 do
		local a = (i / 12) * math.pi * 2
		local c, s = math.cos(a), math.sin(a)
		surface.DrawLine(cx + c * (r - 7), cy + s * (r - 7), cx + c * (r - 15), cy + s * (r - 15))
	end
end

-- The run between the circles, drawn as a piece of the panel rather than as a
-- readout: twin rails broken by a lozenge, stops at the tail and a struck head.
-- It is brass whatever is being made, so it never competes with the result.
local function drawConnector(x1, x2, y, col)
	local mid = math.floor((x1 + x2) * 0.5)
	local head = 15

	surface.SetDrawColor(col.r, col.g, col.b, 150)
	surface.DrawRect(x1 + 12, y - 3, mid - 13 - x1, 1)
	surface.DrawRect(x1 + 12, y + 2, mid - 13 - x1, 1)
	surface.DrawRect(mid + 11, y - 3, x2 - head - mid - 11, 1)
	surface.DrawRect(mid + 11, y + 2, x2 - head - mid - 11, 1)

	-- Stepped stops at the tail, the way a deco border shoulders in
	surface.SetDrawColor(col.r, col.g, col.b, 215)
	surface.DrawRect(x1, y - 9, 2, 19)
	surface.DrawRect(x1 + 5, y - 6, 1, 13)
	surface.DrawRect(x1 + 9, y - 3, 1, 7)

	draw.NoTexture()
	surface.SetDrawColor(col.r, col.g, col.b, 235)

	-- Lozenge at the middle
	surface.DrawPoly({
		{x = mid, y = y - 9},
		{x = mid + 9, y = y},
		{x = mid, y = y + 9},
		{x = mid - 9, y = y},
	})

	-- Head
	surface.DrawPoly({
		{x = x2 - head, y = y - 9},
		{x = x2, y = y},
		{x = x2 - head, y = y + 9},
	})

	-- Notch behind the head, so it reads as struck rather than drawn
	surface.SetDrawColor(col.r, col.g, col.b, 150)
	surface.DrawRect(x2 - head - 5, y - 5, 1, 11)
end

----------------------------------------------------------------------
-- Menu
----------------------------------------------------------------------
local function OpenTransmuterMenu(station)
	local ply = LocalPlayer()
	if not IsValid(ply) or not IsValid(station) then return end

	C = ArtDeco.Colors

	if IsValid(activeFrame) then activeFrame:Remove() end

	local G = Arcana.Gardening
	local frame = vgui.Create("DFrame")
	activeFrame = frame
	frame:SetSize(math.min(FRAME_W, ScrW()), math.min(FRAME_H, ScrH()))
	frame:Center()
	frame:SetTitle("")
	frame:MakePopup()

	ArtDeco.MakeDraggableByBand(frame, 44)

	hook.Add("HUDPaint", frame, function()
		local x, y = frame:LocalToScreen(0, 0)
		ArtDeco.DrawBlurRect(x + 6, y + 6, frame:GetWide() - 12, frame:GetTall() - 12, 4, 8)
	end)

	ArtDeco.StyleCloseButton(frame)
	if IsValid(frame.btnMinim) then frame.btnMinim:Hide() end
	if IsValid(frame.btnMaxim) then frame.btnMaxim:Hide() end

	frame.Think = function()
		if not IsValid(station) or ply:GetPos():DistToSqr(station:GetPos()) > (G.USE_RANGE * 1.5) ^ 2 then
			frame:Close()
		end
	end

	----------------------------------------------------------------------
	-- State
	----------------------------------------------------------------------
	-- What is laid out, by slot, and how many times to repeat the exchange.
	-- 0 means as many as the offering will bear.
	local slots = {}
	local batch = 1
	local cache, cacheFrame

	local function resolve()
		if cacheFrame == FrameNumber() and cache then return cache end

		local inputs = {}

		for i = 1, G.MAX_INPUTS do
			if slots[i] then inputs[#inputs + 1] = slots[i] end
		end

		local result = G.ResolveExchange(inputs)
		local most = result and G.MaxRepeats(result.cost, held) or 0

		cache = {
			inputs = inputs,
			result = result,
			-- What pressing the button would actually do, which is never more
			-- than the offering can pay for
			reps = result and (batch == 0 and most or math.min(batch, most)) or 0,
		}
		cacheFrame = FrameNumber()

		return cache
	end

	-- A refused exchange still has to show its price, so the figures fall back
	-- to a single pass when nothing is affordable
	local function shownReps()
		return math.max(1, resolve().reps)
	end

	----------------------------------------------------------------------
	-- Chrome
	----------------------------------------------------------------------
	frame.Paint = function(_, w, h)
		drawTransmuterBackground(w, h)
		ArtDeco.DrawDecoFrame(6, 6, w - 12, h - 12, C.gold, 14)
		ArtDeco.DrawTitle("Arcana_AncientLarge", "TRANSMUTER", 7, 46, C.paleGold)

		local labelY = CIRCLE_CY - RADIUS - 15
		draw.SimpleText("OFFERING", "Arcana_AncientSmall", LEFT_CX, labelY, C.textDim, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		draw.SimpleText("RETURN", "Arcana_AncientSmall", RIGHT_CX, labelY, C.textDim, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)

		drawCircle(LEFT_CX, CIRCLE_CY, RADIUS, C.brassInner)
		drawCircle(RIGHT_CX, CIRCLE_CY, RADIUS, C.brassInner)

		local x1 = LEFT_CX + RADIUS + 10
		local x2 = RIGHT_CX - RADIUS - 10
		drawConnector(x1, x2, CIRCLE_CY, C.brassInner)

		local r = resolve()

		-- Something crossing the run is the only sign of a live trade: the
		-- fitting itself never changes colour
		if r.result then
			local now = RealTime()

			for i = 1, 6 do
				local t = ((now * 0.45) + i / 6) % 1
				local mx = Lerp(t, x1 + 14, x2 - 20)
				surface.SetDrawColor(C.paleGold.r, C.paleGold.g, C.paleGold.b, math.sin(t * math.pi) * 230)
				surface.DrawRect(math.Round(mx), CIRCLE_CY - 1, 2, 2)
			end
		end

		----------------------------------------------------------------------
		-- What comes back
		----------------------------------------------------------------------
		local cy = CIRCLE_CY - 6

		if not r.result then
			local text = #r.inputs == 0 and "Lay something out" or "Nothing comes of this"
			draw.SimpleText(text, "Arcana_AncientSmall", RIGHT_CX, cy, C.textDim, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)

			return
		end

		local reps = shownReps()

		if r.result.kind == "coins" then
			drawDisc(RIGHT_CX, cy - 26, 20, C.coinGold, 45)

			-- A bare glow disc reads as a hole, so the coin sits on it the way
			-- the dust swatch sits on its own
			surface.SetDrawColor(C.coinGold)
			surface.SetMaterial(ArtDeco.Icons.coin)
			surface.DrawTexturedRect(RIGHT_CX - 11, cy - 37, 22, 22)

			ArtDeco.DrawCostLine("Arcana_Ancient", RIGHT_CX, cy - 4, {
				{text = string.Comma(r.result.coins * reps), icon = ArtDeco.Icons.coin, color = C.coinGold},
			}, TEXT_ALIGN_CENTER)
		else
			local out = r.result.recipe
			local amount = (out.output[out.id] or 0) * reps

			drawDisc(RIGHT_CX, cy - 26, 20, out.color, 60)
			surface.SetDrawColor(out.color.r, out.color.g, out.color.b, 240)
			surface.DrawRect(RIGHT_CX - 9, cy - 35, 18, 18)

			draw.SimpleText(amount .. "x " .. out.label, "Arcana_Ancient", RIGHT_CX, cy + 4, C.textBright, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		end

		-- The price of what is shown, so the return is never quoted alone
		local segs = {}

		for item, per in pairs(r.result.cost) do
			segs[#segs + 1] = {
				text = (per * reps) .. " " .. itemLabel(item),
				color = held(item) >= per * reps and itemColor(item) or DENIED,
				order = item == "crystal_dust" and 1 or 2,
			}
		end

		table.sort(segs, function(a, b) return a.order < b.order end)
		ArtDeco.DrawCostLine("Arcana_AncientSmall", RIGHT_CX, cy + 28, segs, TEXT_ALIGN_CENTER)
	end

	----------------------------------------------------------------------
	-- Offering slots
	----------------------------------------------------------------------
	local showPicker

	for i = 1, G.MAX_INPUTS do
		local slot = vgui.Create("DButton", frame)
		slot:SetText("")
		slot:SetSize(SLOT_W, SLOT_H)
		slot:SetPos(LEFT_CX - SLOT_W * 0.5, CIRCLE_CY + (i - 2) * 54 - SLOT_H * 0.5)

		slot.Paint = function(pnl, w, h)
			local id = slots[i]
			local hovered = pnl:IsHovered()

			if not id then
				ArtDeco.FillDecoPanel(0, 0, w, h, hovered and EMPTY_HOVER or EMPTY_IDLE, 8)
				ArtDeco.DrawDecoFrame(0, 0, w, h, hovered and C.paleGold or EMPTY_OUTLINE, 8)

				local cx, cy = w * 0.5, h * 0.5
				surface.SetDrawColor(C.gold.r, C.gold.g, C.gold.b, hovered and 165 or 70)
				surface.DrawRect(cx - 9, cy - 2, 18, 3)
				surface.DrawRect(cx - 2, cy - 9, 3, 18)

				return
			end

			ArtDeco.FillDecoPanel(0, 0, w, h, hovered and C.cardHover or C.cardIdle, 8)
			ArtDeco.DrawDecoFrame(0, 0, w, h, hovered and C.paleGold or C.brassInner, 8)

			local col = itemColor(id)
			surface.SetDrawColor(col.r, col.g, col.b, 235)
			surface.DrawRect(12, h * 0.5 - 8, 16, 16)

			local r = resolve()
			local per = r.result and r.result.cost[id]
			local mine = held(id)
			local text, textCol

			if per then
				-- What it costs, not what is in the pack: the colour already
				-- says whether that is covered, and the pair of figures ate the
				-- room the longer item names need
				local need = per * shownReps()
				text = tostring(need)
				textCol = mine >= need and C.textDim or DENIED
			else
				text = "x" .. mine
				textCol = C.textDim
			end

			surface.SetFont("Arcana_AncientSmall")
			local countW = surface.GetTextSize(text)
			draw.SimpleText(fitText("Arcana_AncientSmall", itemLabel(id), w - 52 - countW), "Arcana_AncientSmall", 36, h * 0.5, C.textBright, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
			draw.SimpleText(text, "Arcana_AncientSmall", w - 12, h * 0.5, textCol, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
		end

		slot.DoClick = function()
			if slots[i] then
				slots[i] = nil
				cacheFrame = nil
				surface.PlaySound("buttons/button15.wav")

				return
			end

			showPicker(i)
		end
	end

	----------------------------------------------------------------------
	-- What may be laid out
	----------------------------------------------------------------------
	showPicker = function(index)
		local picker = vgui.Create("DPanel", frame)
		picker:SetPos(LEFT_CX - RADIUS - 20, 56)
		-- Tall enough to hold nearly everything it accepts without scrolling
		picker:SetSize(RADIUS * 2 + 40, 380)
		picker:MoveToFront()

		picker.Paint = function(_, w, h)
			ArtDeco.FillDecoPanel(0, 0, w, h, Color(20, 16, 12, 251), 10)
			ArtDeco.DrawDecoFrame(0, 0, w, h, C.gold, 10)
			draw.SimpleText("Lay out", "Arcana_Ancient", w * 0.5, 12, C.paleGold, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
		end

		local list = vgui.Create("DScrollPanel", picker)
		list:SetPos(12, 44)
		list:SetSize(picker:GetWide() - 24, picker:GetTall() - 56)
		ArtDeco.StyleScrollBar(list, 6)

		for _, item in ipairs(G.Accepted) do
			-- Already on the table, so it cannot be laid out twice
			local taken = false

			for k = 1, G.MAX_INPUTS do
				if slots[k] == item then taken = true end
			end

			if taken then continue end

			local row = vgui.Create("DButton", list)
			row:SetText("")
			row:Dock(TOP)
			row:DockMargin(0, 0, 0, 4)
			row:SetTall(30)

			row.Paint = function(pnl, w, h)
				local mine = held(item)
				ArtDeco.FillDecoPanel(0, 0, w, h, pnl:IsHovered() and C.cardHover or C.cardIdle, 6)

				local col = itemColor(item)
				local dim = mine <= 0
				surface.SetDrawColor(col.r, col.g, col.b, dim and 90 or 235)
				surface.DrawRect(10, h * 0.5 - 6, 12, 12)

				draw.SimpleText(fitText("Arcana_AncientSmall", itemLabel(item), w - 90), "Arcana_AncientSmall", 30, h * 0.5, dim and C.textDim or C.textBright, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
				draw.SimpleText("x" .. mine, "Arcana_AncientSmall", w - 12, h * 0.5, C.textDim, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
			end

			row.DoClick = function()
				slots[index] = item
				cacheFrame = nil
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
	-- The act itself, with the passes stacked under it, both on the panel's
	-- centre line
	----------------------------------------------------------------------
	local BATCHES = {
		{label = "x1", value = 1},
		{label = "x10", value = 10},
		{label = "All", value = 0},
	}

	local CHIP_W, CHIP_GAP, GO_W = 66, 8, 168
	local chipsW = #BATCHES * CHIP_W + (#BATCHES - 1) * CHIP_GAP
	local chipsX = (FRAME_W - chipsW) * 0.5

	for i, b in ipairs(BATCHES) do
		local chip = vgui.Create("DButton", frame)
		chip:SetText("")
		chip:SetSize(CHIP_W, 28)
		chip:SetPos(chipsX + (i - 1) * (CHIP_W + CHIP_GAP), ROW_Y + 48)

		chip.Paint = function(pnl, w, h)
			local on = batch == b.value
			local hovered = pnl:IsHovered()
			ArtDeco.FillDecoPanel(0, 0, w, h, on and C.cardHover or C.cardIdle, 6)
			ArtDeco.DrawDecoFrame(0, 0, w, h, (on or hovered) and C.paleGold or C.brassInner, 6)
			draw.SimpleText(b.label, "Arcana_AncientSmall", w * 0.5, h * 0.5, on and C.paleGold or C.textBright, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		end

		chip.DoClick = function()
			batch = b.value
			cacheFrame = nil
			surface.PlaySound("buttons/button15.wav")
		end
	end

	local go = vgui.Create("DButton", frame)
	go:SetText("")
	go:SetSize(GO_W, 40)
	go:SetPos((FRAME_W - GO_W) * 0.5, ROW_Y)

	go.Paint = function(pnl, w, h)
		local live = resolve().reps >= 1
		local hovered = live and pnl:IsHovered()

		ArtDeco.FillDecoPanel(0, 0, w, h, hovered and C.cardHover or C.cardIdle, 8)
		ArtDeco.DrawDecoFrame(0, 0, w, h, hovered and C.paleGold or (live and C.brassInner or EMPTY_OUTLINE), 8)
		draw.SimpleText("Exchange", "Arcana_Ancient", w * 0.5, h * 0.5, live and (hovered and C.paleGold or C.textBright) or C.textDim, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
	end

	go.DoClick = function()
		local r = resolve()

		if r.reps < 1 then
			surface.PlaySound("buttons/button10.wav")

			return
		end

		net.Start("Arcana_Transmuter_Exchange")
		net.WriteEntity(station)
		net.WriteUInt(#r.inputs, 4)

		for _, id in ipairs(r.inputs) do
			net.WriteString(id)
		end

		net.WriteUInt(batch, 8)
		net.SendToServer()

		cacheFrame = nil
		surface.PlaySound("buttons/button15.wav")
	end
end

net.Receive("Arcana_Transmuter_Open", function()
	local station = net.ReadEntity()
	if not IsValid(station) then return end

	OpenTransmuterMenu(station)
end)
