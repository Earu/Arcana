-- Art Deco UI Library
-- Consolidated UI styling and drawing functions for Arcana's art deco aesthetic
local ArtDeco = {}

if CLIENT then
	-- ===========================================================================
	-- FONTS
	-- ===========================================================================
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
		font = Arcana.RUNIC_FONT,
		size = 60,
		weight = 900,
		antialias = true,
		extended = true
	})

	-- ===========================================================================
	-- COLOR PALETTE
	-- ===========================================================================
	ArtDeco.Colors = {
		-- Primary leather/wood tones
		decoBg = Color(26, 20, 14, 235),
		decoPanel = Color(32, 24, 18, 235),

		-- Metallic accents
		gold = Color(198, 160, 74, 255),
		paleGold = Color(222, 198, 120, 255),
		brassInner = Color(160, 130, 60, 220),

		-- Text colors
		textBright = Color(236, 230, 220, 255),
		textDim = Color(180, 170, 150, 255),

		-- Currency colors
		coinGold = Color(222, 198, 120, 255),
		shardBlue = Color(105, 180, 255, 255),

		-- Interactive elements
		cardIdle = Color(46, 36, 26, 235),
		cardHover = Color(58, 44, 32, 235),
		chipTextCol = Color(24, 26, 36, 230),

		-- Overlay effects
		backDim = Color(0, 0, 0, 140),

		-- Radial menu accents
		wedgeIdleFill = Color(198, 160, 74, 24),
		wedgeHoverFill = Color(198, 160, 74, 70),
		xpFill = Color(222, 198, 120, 180),
	}

	-- ===========================================================================
	-- BLUR HELPER
	-- ===========================================================================
	local blurMat = Material("pp/blurscreen")

	--- Draws a blurred rectangle region with clipped corners matching DecoFrame
	-- @param x X position
	-- @param y Y position
	-- @param w Width
	-- @param h Height
	-- @param layers Number of blur layers (default: 4)
	-- @param density Blur density (default: 8)
	-- @param alpha Alpha value (optional, not currently used but kept for API compatibility)
	-- @param corner Corner clip size (default: 12)
	function ArtDeco.DrawBlurRect(x, y, w, h, layers, density, alpha, corner)
		local c = math.max(8, corner or 12)
		local numLayers = layers or 4
		local blurDensity = density or 8

		-- Step 1: Create stencil mask for clipped corners
		render.SetStencilEnable(true)
		render.ClearStencil()
		render.SetStencilReferenceValue(1)
		render.SetStencilCompareFunction(STENCILCOMPARISONFUNCTION_ALWAYS)
		render.SetStencilPassOperation(STENCILOPERATION_REPLACE)
		render.SetStencilWriteMask(1)

		-- Draw the clipped corner shape to the stencil buffer
		draw.NoTexture()
		surface.SetDrawColor(255, 255, 255, 1)
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

		-- Step 2: Set up stencil test to only draw where mask equals 1
		render.SetStencilCompareFunction(STENCILCOMPARISONFUNCTION_EQUAL)
		render.SetStencilPassOperation(STENCILOPERATION_KEEP)

		-- Step 3: Set up scissor rect to limit blur sampling/drawing to our region
		render.SetScissorRect(x, y, x + w, y + h, true)

		-- Step 4: Draw blur layers
		surface.SetMaterial(blurMat)
		surface.SetDrawColor(255, 255, 255, 255)

		for i = 1, numLayers do
			blurMat:SetFloat("$blur", (i / numLayers) * blurDensity)
			blurMat:Recompute()
			render.UpdateScreenEffectTexture()
			surface.DrawTexturedRect(0, 0, ScrW(), ScrH())
		end

		render.SetScissorRect(0, 0, 0, 0, false)
		render.SetStencilEnable(false)
	end

	-- ===========================================================================
	-- DECORATIVE FRAME (CLIPPED CORNERS)
	-- ===========================================================================

	--- Draws a decorative frame with clipped corners
	-- @param x X position
	-- @param y Y position
	-- @param w Width
	-- @param h Height
	-- @param col Color
	-- @param corner Corner clip size (default: 12)
	function ArtDeco.DrawDecoFrame(x, y, w, h, col, corner)
		local c = math.max(8, corner or 12)
		surface.SetDrawColor(col.r, col.g, col.b, col.a or 255)

	-- Outer rectangle with cut corners
	surface.DrawLine(x + c, y, x + w - c, y)
	surface.DrawLine(x + w - 1, y + c, x + w - 1, y + h - c)
	surface.DrawLine(x + w - c, y + h - 1, x + c, y + h - 1)
	surface.DrawLine(x, y + h - c, x, y + c)

	-- Corner slants
	surface.DrawLine(x, y + c, x + c, y)
	surface.DrawLine(x + w - c, y, x + w - 1, y + c)
	surface.DrawLine(x + w - 1, y + h - c, x + w - c, y + h - 1)
	surface.DrawLine(x + c, y + h - 1, x, y + h - c)
	end

	-- ===========================================================================
	-- FILLED PANEL (CLIPPED CORNERS)
	-- ===========================================================================

	--- Fills a panel with clipped corners matching the frame geometry
	-- @param x X position
	-- @param y Y position
	-- @param w Width
	-- @param h Height
	-- @param col Color
	-- @param corner Corner clip size (default: 12)
	function ArtDeco.FillDecoPanel(x, y, w, h, col, corner)
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

	-- ===========================================================================
	-- POLYGON HELPERS
	-- ===========================================================================

	--- Draws a regular polygon outline
	-- @param cx Center X
	-- @param cy Center Y
	-- @param radius Radius
	-- @param sides Number of sides (default: 6)
	-- @param col Color
	function ArtDeco.DrawPolygonOutline(cx, cy, radius, sides, col)
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

	--- Fills a polygon ring sector (between two radii) for a regular N-gon
	-- @param cx Center X
	-- @param cy Center Y
	-- @param rInner Inner radius
	-- @param rOuter Outer radius
	-- @param sides Number of sides (default: 8)
	-- @param index Sector index (1-based)
	-- @param color Fill color
	function ArtDeco.FillPolygonRingSector(cx, cy, rInner, rOuter, sides, index, color)
		local n = math.max(3, math.floor(sides or 8))
		local i = ((index - 1) % n) + 1
		local step = (math.pi * 2) / n
		local a0 = step * (i - 1)
		local a1 = step * i

		local poly = {
			{x = cx + math.cos(a0) * rOuter, y = cy + math.sin(a0) * rOuter},
			{x = cx + math.cos(a1) * rOuter, y = cy + math.sin(a1) * rOuter},
			{x = cx + math.cos(a1) * rInner, y = cy + math.sin(a1) * rInner},
			{x = cx + math.cos(a0) * rInner, y = cy + math.sin(a0) * rInner},
		}

		draw.NoTexture()
		surface.SetDrawColor(color.r, color.g, color.b, color.a or 255)
		surface.DrawPoly(poly)
	end

	--- Draws art-deco flourish accents for radial menus
	-- @param cx Center X
	-- @param cy Center Y
	-- @param rInner Inner radius
	-- @param rOuter Outer radius
	-- @param sides Number of sides (default: 8)
	-- @param baseCol Base color
	-- @param accentCol Accent color
	function ArtDeco.DrawRadialFlourish(cx, cy, rInner, rOuter, sides, baseCol, accentCol)
		local n = math.max(3, math.floor(sides or 8))

		-- Double-outline vibe
		local outlineA = Color(baseCol.r, baseCol.g, baseCol.b, 90)
		local outlineB = Color(baseCol.r, baseCol.g, baseCol.b, 60)
		ArtDeco.DrawPolygonOutline(cx, cy, rOuter - 4, n, outlineA)
		ArtDeco.DrawPolygonOutline(cx, cy, rOuter - 8, n, outlineB)
		ArtDeco.DrawPolygonOutline(cx, cy, rInner + 6, n, outlineB)

		-- Vertex diamonds
		draw.NoTexture()
		surface.SetDrawColor(accentCol.r, accentCol.g, accentCol.b, 40)

		for i = 1, n do
			local a = (i - 1) * (math.pi * 2) / n
			local vx = cx + math.cos(a) * (rOuter - 2)
			local vy = cy + math.sin(a) * (rOuter - 2)
			local d = 5

			local pts = {
				{x = vx, y = vy - d},
				{x = vx + d, y = vy},
				{x = vx, y = vy + d},
				{x = vx - d, y = vy},
			}

			surface.DrawPoly(pts)
		end
	end

	-- ===========================================================================
	-- UTILITY FUNCTIONS
	-- ===========================================================================

	--- Draws text that gets truncated with an ellipsis if too wide
	-- @param font Font name
	-- @param text Text to draw
	-- @param x X position
	-- @param y Y position
	-- @param col Color
	-- @param maxW Maximum width
	function ArtDeco.DrawTruncatedText(font, text, x, y, col, maxW)
		surface.SetFont(font)
		local tw, _ = surface.GetTextSize(text)
		if tw <= maxW then
			draw.SimpleText(text, font, x, y, col)
			return
		end

		local ell = "…"
		local base = text
		while #base > 0 do
			base = string.sub(base, 1, #base - 1)
			local test = base .. ell
			local w2, _ = surface.GetTextSize(test)
			if w2 <= maxW then
				draw.SimpleText(test, font, x, y, col)
				return
			end
		end
	end

	-- ===========================================================================
	-- FRAME CHROME (title, chips, close button)
	-- ===========================================================================

	-- Every station's frame title sits at this inset: clear of the deco frame's corner
	-- slant, and identical from one UI to the next.
	ArtDeco.TITLE_X = 24

	-- The close sigil sits in the frame's cut corner, but well clear of it: a four-bladed
	-- star, each blade tapering from a keystone diamond out to its tip, in the same
	-- tapered-wing language as the tarot frame's corners. Hovering turns the seal a quarter
	-- turn, so the saltire opens into a cross as it warms.
	local CLOSE_SIZE = 30
	local CLOSE_CX = 30 -- sigil's center, in from the frame's right edge
	local CLOSE_CY = 27 -- sigil's center, down from the frame's top edge
	local CLOSE_ARM = 9
	local CLOSE_HOVER = Color(232, 138, 106, 255)
	local CLOSE_SPIN = 45 -- degrees the seal turns under the cursor

	--- Reskins a DFrame's stock close button as an art-deco seal seated in the frame's cut
	-- corner. Replaces frame.PerformLayout, so pass any other layout work as opts.layout.
	-- @param frame The DFrame
	-- @param opts Optional {size, cx, cy, layout}
	function ArtDeco.StyleCloseButton(frame, opts)
		local close = frame.btnClose
		if not IsValid(close) then return end

		opts = opts or {}
		local size = opts.size or CLOSE_SIZE
		local cxIn = opts.cx or CLOSE_CX
		local cyIn = opts.cy or CLOSE_CY

		close:SetText("")
		close:SetSize(size, size)

		local extraLayout = opts.layout
		function frame:PerformLayout(w, h)
			if extraLayout then extraLayout(self, w, h) end
			if IsValid(close) then
				close:SetPos(math.floor(w - cxIn - size * 0.5), math.floor(cyIn - size * 0.5))
			end
		end

		close.Paint = function(pnl, w, h)
			local hovered = pnl:IsHovered()
			local cx, cy = w * 0.5, h * 0.5
			local col = hovered and CLOSE_HOVER or ArtDeco.Colors.paleGold
			local arm = CLOSE_ARM

			-- The turn eases in and out rather than snapping, so a passing cursor
			-- reads as the seal stirring.
			pnl._spin = Lerp(math.min(1, FrameTime() * 12), pnl._spin or 0, hovered and CLOSE_SPIN or 0)

			draw.NoTexture()

			for k = 0, 3 do
				local a = math.rad(45 + k * 90 + pnl._spin)
				local ca, sa = math.cos(a), math.sin(a)
				local function at(px, py)
					return cx + px * ca - py * sa, cy + px * sa + py * ca
				end

				-- A blade: tapered from the crossing out to its tip.
				local bx1, by1 = at(3, -3)
				local bx2, by2 = at(arm, 0)
				local bx3, by3 = at(3, 3)
				surface.SetDrawColor(col)
				surface.DrawPoly({
					{x = bx1, y = by1},
					{x = bx2, y = by2},
					{x = bx3, y = by3},
				})
			end

			-- Keystone diamond at the crossing, which does not turn with the blades.
			surface.SetDrawColor(hovered and ArtDeco.Colors.paleGold or ArtDeco.Colors.brassInner)
			surface.DrawPoly({
				{x = cx, y = cy - 3},
				{x = cx + 3, y = cy},
				{x = cx, y = cy + 3},
				{x = cx - 3, y = cy},
			})
		end

		return close
	end

	--- Draws a frame title, vertically centered in the same free band DrawChip uses, so a
	-- title and any chips beside it land on one center line and their gaps match.
	-- @param font Font name
	-- @param text Title text
	-- @param top First free pixel row (a DrawDecoFrame border at y is a 1px line, so pass y + 1)
	-- @param bottom First row occupied by whatever bounds the title below
	-- @param col Text color
	-- @param x Left edge (defaults to ArtDeco.TITLE_X)
	-- @return the title's right edge, to place a chip after it, and its top y
	function ArtDeco.DrawTitle(font, text, top, bottom, col, x)
		x = x or ArtDeco.TITLE_X
		surface.SetFont(font)
		local tw, th = surface.GetTextSize(text)
		local y = top + math.floor(((bottom - top) - th) * 0.5)
		draw.SimpleText(text, font, x, y, col)

		return x + tw, y
	end

	--- Draws a title-bar chip ("LVL 100", "KP 0"), vertically centered in the free band
	-- between the frame's top line and whatever sits below it, so the gap above the chip
	-- matches the gap below it. Returns the chip's right edge, to place a chip after it.
	-- @param font Font name
	-- @param text Chip text
	-- @param x Left edge
	-- @param top First free pixel row (a DrawDecoFrame border at y is a 1px line, so pass y + 1)
	-- @param bottom First row occupied by whatever bounds the chip below (an inner frame's line, a bar's top)
	-- @param bgCol Chip fill (default paleGold)
	-- @param textCol Chip text color (default chipTextCol)
	-- @param icon Optional Material drawn before the text, tinted with textCol
	-- @param align TEXT_ALIGN_LEFT (default, x is the left edge) or TEXT_ALIGN_RIGHT (x is the right edge)
	function ArtDeco.DrawChip(font, text, x, top, bottom, bgCol, textCol, icon, align)
		surface.SetFont(font)
		local tw, th = surface.GetTextSize(text)
		local iconSize = icon and (th - 2) or 0
		local cw, ch = tw + 18 + (icon and (iconSize + 4) or 0), th + 6

		-- An odd leftover can't split evenly between the two gaps, so spend the odd
		-- pixel on the chip itself: a chip 1px taller reads better than uneven gaps.
		local slack = (bottom - top) - ch
		if slack % 2 == 1 then
			ch = ch + 1
			slack = slack - 1
		end

		if align == TEXT_ALIGN_RIGHT then
			x = x - cw
		end

		local y = top + math.floor(slack * 0.5)
		ArtDeco.FillDecoPanel(x, y, cw, ch, bgCol or ArtDeco.Colors.paleGold, 8)

		local tcol = textCol or ArtDeco.Colors.chipTextCol
		local tx = x + 9
		if icon then
			surface.SetDrawColor(tcol)
			surface.SetMaterial(icon)
			surface.DrawTexturedRect(tx, y + math.floor((ch - iconSize) * 0.5), iconSize, iconSize)
			tx = tx + iconSize + 4
		end
		draw.SimpleText(text, font, tx, y + math.floor((ch - th) * 0.5), tcol)

		return x + cw
	end

	-- ===========================================================================
	-- COST LINES (amounts with currency icons)
	-- ===========================================================================
	-- Flat white silhouettes, tinted at draw time with the segment color
	ArtDeco.Icons = {
		coin = Material("arcana/icons/coin.png", "smooth"),
		shard = Material("arcana/icons/crystal_shard.png", "smooth"),
	}

	local COST_ICON_PAD = 4
	local COST_SEGMENT_GAP = 10
	-- Extra room per gap when a divider diamond sits in it
	local COST_DIVIDER_GAP = 12

	local function costLineMetrics(font, segments, divider)
		surface.SetFont(font)
		local _, th = surface.GetTextSize("0")
		local iconSize = th - 2
		local gap = COST_SEGMENT_GAP + (divider and COST_DIVIDER_GAP or 0)
		local totalW = 0
		for i, seg in ipairs(segments) do
			if i > 1 then
				totalW = totalW + gap
			end
			totalW = totalW + surface.GetTextSize(seg.text)
			if seg.icon then
				totalW = totalW + COST_ICON_PAD + iconSize
			end
		end
		return totalW, th, iconSize, gap
	end

	--- Measures a cost line without drawing it (see DrawCostLine)
	-- @return Total width, height
	function ArtDeco.MeasureCostLine(font, segments, divider)
		local w, h = costLineMetrics(font, segments, divider)
		return w, h
	end

	--- Draws a line of cost segments, each an amount optionally followed by a currency icon
	-- @param font Font name
	-- @param x Left edge (TEXT_ALIGN_LEFT), center (TEXT_ALIGN_CENTER) or right edge (TEXT_ALIGN_RIGHT)
	-- @param y Top edge
	-- @param segments Array of {text = string, icon = Material or nil, color = Color or nil}
	-- @param align TEXT_ALIGN_LEFT (default), TEXT_ALIGN_CENTER or TEXT_ALIGN_RIGHT
	-- @param divider Draw a small diamond between segments
	-- @return Right edge of the drawn line
	function ArtDeco.DrawCostLine(font, x, y, segments, align, divider)
		local totalW, th, iconSize, gap = costLineMetrics(font, segments, divider)

		-- Snap to whole pixels so the divider diamond doesn't split across columns
		local cx = x
		if align == TEXT_ALIGN_CENTER then
			cx = math.floor(x - totalW * 0.5)
		elseif align == TEXT_ALIGN_RIGHT then
			cx = math.floor(x - totalW)
		end

		for i, seg in ipairs(segments) do
			if i > 1 then
				if divider then
					local mx = math.floor(cx + gap * 0.5)
					local my = math.floor(y + th * 0.5)
					surface.SetDrawColor(ArtDeco.Colors.brassInner)
					surface.DrawLine(mx - 3, my, mx, my - 3)
					surface.DrawLine(mx, my - 3, mx + 3, my)
					surface.DrawLine(mx + 3, my, mx, my + 3)
					surface.DrawLine(mx, my + 3, mx - 3, my)
				end
				cx = cx + gap
			end

			local col = seg.color or ArtDeco.Colors.textBright
			draw.SimpleText(seg.text, font, cx, y, col)
			cx = cx + surface.GetTextSize(seg.text)

			if seg.icon then
				cx = cx + COST_ICON_PAD
				surface.SetDrawColor(col)
				surface.SetMaterial(seg.icon)
				surface.DrawTexturedRect(cx, y + math.floor((th - iconSize) * 0.5), iconSize, iconSize)
				cx = cx + iconSize
			end
		end

		return cx
	end

	-- ===========================================================================
	-- HUD NOTIFICATION HELPERS
	-- ===========================================================================

	--- Draws a small Art Deco flourish: center diamond with flanking lines
	-- @param x X position
	-- @param y Y position
	-- @param w Width
	-- @param h Height
	-- @param alpha Alpha value (0-255)
	function ArtDeco.DrawDecoFlourish(x, y, w, h, alpha)
		local a = math.Clamp(tonumber(alpha) or 255, 0, 255)
		local cx = x + math.floor(w * 0.5)
		local lineY = y + math.floor(h * 0.48)
		local lineCol = Color(ArtDeco.Colors.gold.r, ArtDeco.Colors.gold.g, ArtDeco.Colors.gold.b, math.floor(80 * (a / 255)))
		surface.SetDrawColor(lineCol)
		surface.DrawLine(cx - 110, lineY, cx - 20, lineY)
		surface.DrawLine(cx + 20, lineY, cx + 110, lineY)

		-- Diamond
		draw.NoTexture()
		surface.SetDrawColor(ArtDeco.Colors.gold.r, ArtDeco.Colors.gold.g, ArtDeco.Colors.gold.b, math.floor(110 * (a / 255)))
		local d = 7
		local pts = {
			{x = cx, y = lineY - d},
			{x = cx + d, y = lineY},
			{x = cx, y = lineY + d},
			{x = cx - d, y = lineY},
		}
		surface.DrawPoly(pts)

		-- Inner faint diamond
		surface.SetDrawColor(236, 230, 220, math.floor(60 * (a / 255)))
		local d2 = 3
		local pts2 = {
			{x = cx, y = lineY - d2},
			{x = cx + d2, y = lineY},
			{x = cx, y = lineY + d2},
			{x = cx - d2, y = lineY},
		}
		surface.DrawPoly(pts2)
	end

	--- Draws a hexagon frame (no fill) to encapsulate announcement text
	-- @param x X position
	-- @param y Y position
	-- @param w Width
	-- @param h Height
	-- @param alpha Alpha value (0-255)
	function ArtDeco.DrawHexFrame(x, y, w, h, alpha)
		local a = math.Clamp(tonumber(alpha) or 255, 0, 255)
		local m = math.max(10, math.floor(math.min(w, h) * 0.10))
		local cy = y + h * 0.5

		local p1 = {x = x + m, y = y}
		local p2 = {x = x + w - m, y = y}
		local p3 = {x = x + w, y = cy}
		local p4 = {x = x + w - m, y = y + h}
		local p5 = {x = x + m, y = y + h}
		local p6 = {x = x, y = cy}

		local function drawEdge(aPt, bPt, col)
			surface.SetDrawColor(col)
			surface.DrawLine(aPt.x, aPt.y, bPt.x, bPt.y)
		end

		local mainCol = Color(ArtDeco.Colors.gold.r, ArtDeco.Colors.gold.g, ArtDeco.Colors.gold.b, math.floor(140 * (a / 255)))
		local accentCol = Color(236, 230, 220, math.floor(60 * (a / 255)))

		-- Outer stroke
		drawEdge(p1, p2, mainCol)
		drawEdge(p2, p3, mainCol)
		drawEdge(p3, p4, mainCol)
		drawEdge(p4, p5, mainCol)
		drawEdge(p5, p6, mainCol)
		drawEdge(p6, p1, mainCol)

		-- Second pass for a slightly thicker, highlighted edge
		drawEdge(p1, p2, accentCol)
		drawEdge(p2, p3, accentCol)
		drawEdge(p3, p4, accentCol)
		drawEdge(p4, p5, accentCol)
		drawEdge(p5, p6, accentCol)
		drawEdge(p6, p1, accentCol)
	end

	--- Draws a hexagon dark background fill (slightly inset so the border stays crisp)
	-- @param x X position
	-- @param y Y position
	-- @param w Width
	-- @param h Height
	-- @param alpha Alpha value (0-255)
	function ArtDeco.DrawHexFill(x, y, w, h, alpha)
		local a = math.Clamp(tonumber(alpha) or 255, 0, 255)
		local m = math.max(10, math.floor(math.min(w, h) * 0.10))
		local inset = 1
		local cy = y + h * 0.5

		local pts = {
			{x = x + m + inset, y = y + inset},
			{x = x + w - m - inset, y = y + inset},
			{x = x + w - inset, y = cy},
			{x = x + w - m - inset, y = y + h - inset},
			{x = x + m + inset, y = y + h - inset},
			{x = x + inset, y = cy},
		}

		draw.NoTexture()
		surface.SetDrawColor(20, 16, 12, math.floor(160 * (a / 255)))
		surface.DrawPoly(pts)
	end

	--- Draws a compact status flourish (for smaller HUD elements)
	-- @param cx Center X
	-- @param lineY Line Y position
	-- @param w Total width
	function ArtDeco.DrawStatusFlourish(cx, lineY, w)
		local lineLen = math.min(70, w * 0.22)
		local lineGap = math.min(14, w * 0.03)
		local lineCol = Color(ArtDeco.Colors.gold.r, ArtDeco.Colors.gold.g, ArtDeco.Colors.gold.b, 80)
		surface.SetDrawColor(lineCol)
		surface.DrawLine(cx - lineLen - lineGap, lineY, cx - lineGap, lineY)
		surface.DrawLine(cx + lineGap, lineY, cx + lineLen + lineGap, lineY)

		-- Diamond
		draw.NoTexture()
		surface.SetDrawColor(ArtDeco.Colors.gold.r, ArtDeco.Colors.gold.g, ArtDeco.Colors.gold.b, 110)
		local d = 5
		local pts = {
			{x = cx, y = lineY - d},
			{x = cx + d, y = lineY},
			{x = cx, y = lineY + d},
			{x = cx - d, y = lineY},
		}
		surface.DrawPoly(pts)

		-- Inner diamond
		surface.SetDrawColor(236, 230, 220, 60)
		local d2 = 2
		local pts2 = {
			{x = cx, y = lineY - d2},
			{x = cx + d2, y = lineY},
			{x = cx, y = lineY + d2},
			{x = cx - d2, y = lineY},
		}
		surface.DrawPoly(pts2)
	end

	-- ===========================================================================
	-- TOOLTIP COMPONENT
	-- ===========================================================================

	--- Adds tooltip functionality to any panel
	-- @param panel The panel to add tooltip to
	-- @param text The tooltip text to display
	-- @param tooltipWidth Width of tooltip (default: 300)
	-- @param tooltipHeight Height of tooltip (default: 60)
	function ArtDeco.AddTooltip(panel, text, tooltipWidth, tooltipHeight)
		if not IsValid(panel) then return end

		panel.OnCursorEntered = function()
			if IsValid(panel.tooltip) then return end

		local tooltip = vgui.Create("DLabel")
		local width = tooltipWidth or 300
		local vertPadding = 8
		local horzPadding = 8

		tooltip:SetWide(width)
		tooltip:SetTall(9999)
		tooltip:SetWrap(true)
		tooltip:SetText(text or "")
		tooltip:SetFont("Arcana_AncientSmall")
		tooltip:SetTextColor(ArtDeco.Colors.textBright)
		tooltip:SetContentAlignment(7)
		tooltip:SetDrawOnTop(true)
		tooltip:SetMouseInputEnabled(false)
		tooltip:SetKeyboardInputEnabled(false)
		tooltip:NoClipping(true)
		tooltip:SetTextInset(horzPadding, vertPadding)
		tooltip:SizeToContentsY(20)

		local height = tooltip:GetTall()
		tooltip:SetSize(width, height)

		tooltip.Paint = function(pnl, w, h)
			ArtDeco.FillDecoPanel(0, 0, w, h, ArtDeco.Colors.decoBg, 8)
			ArtDeco.DrawDecoFrame(0, 0, w, h, ArtDeco.Colors.gold, 8)
		end

			panel.tooltip = tooltip

			local function updatePos()
				if not IsValid(tooltip) then return end
				local x, y = gui.MousePos()
				tooltip:SetPos(x + 15, y - 60)
			end

			updatePos()

			hook.Add("Think", "ArcanaTooltip_" .. tostring(tooltip), function()
				if not IsValid(tooltip) or not IsValid(panel) then
					hook.Remove("Think", "ArcanaTooltip_" .. tostring(tooltip))
					if IsValid(tooltip) then tooltip:Remove() end
					return
				end
				updatePos()
			end)
		end

		panel.OnCursorExited = function()
			if IsValid(panel.tooltip) then
				hook.Remove("Think", "ArcanaTooltip_" .. tostring(panel.tooltip))
				panel.tooltip:Remove()
				panel.tooltip = nil
			end
		end
	end

	-- ===========================================================================
	-- INFO ICON WITH TOOLTIP COMPONENT
	-- ===========================================================================

	--- Creates an info icon with tooltip functionality
	-- @param parent The parent panel
	-- @param text The tooltip text to display
	-- @param tooltipWidth Width of tooltip (default: 300)
	-- @param tooltipHeight Height of tooltip (default: 60)
	-- @return The info icon panel
	function ArtDeco.CreateInfoIcon(parent, text, tooltipWidth)
		local infoIcon = vgui.Create("DPanel", parent)
		infoIcon:SetSize(20, 20)
		infoIcon:SetCursor("hand")

		-- Draw the "i" in circle icon. The glyph is drawn rather than typeset: centering a
		-- font's "i" centers its text box (advance width, ascender to descender), and the
		-- ink of a lowercase i sits nowhere near the middle of that box.
		infoIcon.Paint = function(pnl, w, h)
			local cx, cy = math.floor(w * 0.5), math.floor(h * 0.5)
			local radius = 8
			surface.SetDrawColor(ArtDeco.Colors.paleGold)

			-- Circle outline. DrawLine lights the pixel right/below its coordinate, so a
			-- circle drawn about (cx, cy) rasterizes half a pixel down-right of it — which
			-- is what threw the glyph off center. Drawing it about (cx, cy) - 0.5 lands its
			-- ink symmetric about (cx, cy), where the glyph below already is.
			local segments = 16
			local ox, oy = cx - 0.5, cy - 0.5
			for i = 0, segments - 1 do
				local a1 = (i / segments) * math.pi * 2
				local a2 = ((i + 1) / segments) * math.pi * 2
				surface.DrawLine(
					ox + math.cos(a1) * radius,
					oy + math.sin(a1) * radius,
					ox + math.cos(a2) * radius,
					oy + math.sin(a2) * radius
				)
			end

			-- The "i": a tittle over a stem. Its ink spans cy - 5 to cy + 5 and its 2px
			-- width straddles cx, so it is centered about (cx, cy) by construction.
			surface.DrawRect(cx - 1, cy - 5, 2, 2)
			surface.DrawRect(cx - 1, cy - 1, 2, 6)
		end

		ArtDeco.AddTooltip(infoIcon, text or "No description available", tooltipWidth)

		return infoIcon
	end

	--- Draws a divine pact frame with triple ornate frames, pulsing glow, and corner ornaments
	-- @param x X position
	-- @param y Y position
	-- @param w Width
	-- @param h Height
	-- @param colors Table with bg, frame1, frame2, accent color definitions
	-- @param time Current time for pulsing animation (CurTime())
	-- @param radius Corner radius (default: 10)
	function ArtDeco.DrawDivinePactFrame(x, y, w, h, colors, time, radius)
		radius = radius or 10

		-- Background
		ArtDeco.FillDecoPanel(x, y, w, h, colors.bg, radius)

		-- Multiple ornate frames with pulsing glow
		local glowIntensity = 0.7 + 0.3 * math.sin(time * 2)
		local frame1 = ColorAlpha(colors.frame1, 255 * glowIntensity)
		local frame2 = ColorAlpha(colors.frame2, 255 * glowIntensity)

		ArtDeco.DrawDecoFrame(x, y, w, h, frame1, radius)
		ArtDeco.DrawDecoFrame(x + 2, y + 2, w - 4, h - 4, colors.accent, radius)
		ArtDeco.DrawDecoFrame(x + 4, y + 4, w - 8, h - 8, frame2, radius)

		-- Decorative corner ornaments (L-shaped brackets)
		local cornerSize = 12
		local cornerPad = 8
		surface.SetDrawColor(colors.accent)

		-- Top-left
		surface.DrawLine(x + cornerPad, y + cornerPad, x + cornerPad + cornerSize, y + cornerPad)
		surface.DrawLine(x + cornerPad, y + cornerPad, x + cornerPad, y + cornerPad + cornerSize)
		surface.DrawLine(x + cornerPad + 1, y + cornerPad, x + cornerPad + cornerSize, y + cornerPad)
		surface.DrawLine(x + cornerPad, y + cornerPad + 1, x + cornerPad, y + cornerPad + cornerSize)

		-- Top-right
		surface.DrawLine(x + w - cornerPad - cornerSize - 1, y + cornerPad, x + w - cornerPad - 1, y + cornerPad)
		surface.DrawLine(x + w - cornerPad - 1, y + cornerPad, x + w - cornerPad - 1, y + cornerPad + cornerSize)
		surface.DrawLine(x + w - cornerPad - cornerSize - 1, y + cornerPad, x + w - cornerPad - 1, y + cornerPad)
		surface.DrawLine(x + w - cornerPad - 1, y + cornerPad + 1, x + w - cornerPad - 1, y + cornerPad + cornerSize)

		-- Bottom-left
		surface.DrawLine(x + cornerPad, y + h - cornerPad - 1, x + cornerPad + cornerSize, y + h - cornerPad - 1)
		surface.DrawLine(x + cornerPad, y + h - cornerPad - cornerSize - 1, x + cornerPad, y + h - cornerPad - 1)
		surface.DrawLine(x + cornerPad + 1, y + h - cornerPad - 1, x + cornerPad + cornerSize, y + h - cornerPad - 1)
		surface.DrawLine(x + cornerPad, y + h - cornerPad - cornerSize - 1, x + cornerPad, y + h - cornerPad - 1)

		-- Bottom-right
		surface.DrawLine(x + w - cornerPad - cornerSize - 1, y + h - cornerPad - 1, x + w - cornerPad - 1, y + h - cornerPad - 1)
		surface.DrawLine(x + w - cornerPad - 1, y + h - cornerPad - cornerSize - 1, x + w - cornerPad - 1, y + h - cornerPad - 1)
		surface.DrawLine(x + w - cornerPad - cornerSize - 1, y + h - cornerPad - 1, x + w - cornerPad - 1, y + h - cornerPad - 1)
		surface.DrawLine(x + w - cornerPad - 1, y + h - cornerPad - cornerSize - 1, x + w - cornerPad - 1, y + h - cornerPad - 1)
	end

	--- Draws a ritual frame with double frames for mystical effect
	-- @param x X position
	-- @param y Y position
	-- @param w Width
	-- @param h Height
	-- @param colors Table with bg, frame1, frame2 color definitions
	function ArtDeco.DrawRitualFrame(x, y, w, h, colors)
		-- Background
		draw.NoTexture()
		surface.SetDrawColor(colors.bg.r, colors.bg.g, colors.bg.b, colors.bg.a)
		surface.DrawRect(x, y, w, h)

		-- Double frame for mystical effect
		surface.SetDrawColor(colors.frame1.r, colors.frame1.g, colors.frame1.b, 255)
		surface.DrawOutlinedRect(x, y, w, h, 2)

		surface.SetDrawColor(colors.frame2.r, colors.frame2.g, colors.frame2.b, 200)
		surface.DrawOutlinedRect(x + 3, y + 3, w - 6, h - 6, 1)
	end

	-- ===========================================================================
	-- MODEL PANELS
	-- ===========================================================================

	local MODEL_PANEL_DIR = Vector(1, 1, 0.5)

	--- Spins a model panel's entity around its geometry instead of its model origin.
	-- Weapon world models put their origin at the grip or attachment point, which can sit
	-- far from the geometry (the RPG's is 20 units out, most of its own radius), so a bare
	-- SetAngles swings the model in an arc around the camera's look-at point. Offsetting
	-- the entity by its rotated bounds center pins that center on the world origin, where
	-- ArtDeco.FitModelPanel aims the camera — the model turns in place.
	-- @param ent Model panel entity
	-- @param ang Angle to spin to
	function ArtDeco.SpinModelPanelEntity(ent, ang)
		if not IsValid(ent) then return end

		ent:SetAngles(ang)

		-- Render bounds are model space: they do not rotate with the entity.
		local mn, mx = ent:GetRenderBounds()
		local center = (mn + mx) * 0.5
		center:Rotate(ang)
		ent:SetPos(-center)
	end

	--- Frames a model panel's camera on a model pinned at the origin by SpinModelPanelEntity.
	-- The framing radius is yaw-invariant — the model's XY diagonal, or its height, whichever
	-- is larger — so a long weapon keeps a constant size and never clips the panel as it turns.
	-- @param panel The DModelPanel
	-- @param fov Camera FOV (default 30)
	-- @param dir Direction the camera sits in, from the model (default 1, 1, 0.5)
	-- @param padding Fraction of slack around the model (default 1.15)
	function ArtDeco.FitModelPanel(panel, fov, dir, padding)
		if not IsValid(panel) then return end

		local ent = panel:GetEntity()
		if not IsValid(ent) then return end

		local mn, mx = ent:GetRenderBounds()
		local size = mx - mn
		local radius = math.max(math.sqrt(size.x * size.x + size.y * size.y), math.abs(size.z)) * 0.5
		if radius < 1 then radius = 1 end

		fov = fov or 30
		local tanHalf = math.tan(math.rad(fov * 0.5))
		if tanHalf <= 0 then tanHalf = 0.5 end

		panel:SetFOV(fov)
		panel:SetCamPos((dir or MODEL_PANEL_DIR):GetNormalized() * (radius / tanHalf) * (padding or 1.15))
		panel:SetLookAt(vector_origin)
	end
end

-- Store in global scope
_G.ArtDeco = ArtDeco

return ArtDeco
