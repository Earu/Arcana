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
		font = "Arial",
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

	--- Draws a blurred rectangle region
	-- @param x X position
	-- @param y Y position
	-- @param w Width
	-- @param h Height
	-- @param layers Number of blur layers (default: 4)
	-- @param density Blur density (default: 8)
	-- @param alpha Alpha value (optional, not currently used but kept for API compatibility)
	function ArtDeco.DrawBlurRect(x, y, w, h, layers, density, alpha)
		surface.SetMaterial(blurMat)
		surface.SetDrawColor(255, 255, 255)
		render.SetScissorRect(x, y, x + w, y + h, true)

		for i = 1, (layers or 4) do
			blurMat:SetFloat("$blur", (i / (layers or 4)) * (density or 8))
			blurMat:Recompute()
			render.UpdateScreenEffectTexture()
			surface.DrawTexturedRect(0, 0, ScrW(), ScrH())
		end

		render.SetScissorRect(0, 0, 0, 0, false)
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
	-- INFO ICON WITH TOOLTIP COMPONENT
	-- ===========================================================================

	--- Creates an info icon with tooltip functionality
	-- @param parent The parent panel
	-- @param text The tooltip text to display
	-- @param tooltipWidth Width of tooltip (default: 300)
	-- @param tooltipHeight Height of tooltip (default: 60)
	-- @return The info icon panel
	function ArtDeco.CreateInfoIcon(parent, text, tooltipWidth, tooltipHeight)
		local infoIcon = vgui.Create("DPanel", parent)
		infoIcon:SetSize(20, 20)
		infoIcon:SetCursor("hand")

		-- Draw the "i" in circle icon
		infoIcon.Paint = function(pnl, w, h)
			local cx, cy = w * 0.5, h * 0.5
			local radius = 8
			surface.SetDrawColor(ArtDeco.Colors.paleGold)

			-- Circle outline
			local segments = 16
			for i = 0, segments - 1 do
				local a1 = (i / segments) * math.pi * 2
				local a2 = ((i + 1) / segments) * math.pi * 2
				surface.DrawLine(
					cx + math.cos(a1) * radius,
					cy + math.sin(a1) * radius,
					cx + math.cos(a2) * radius,
					cy + math.sin(a2) * radius
				)
			end

			-- "i" text
			draw.SimpleText("i", "Arcana_Ancient", cx, cy, ArtDeco.Colors.paleGold, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		end

		-- Tooltip on hover
		infoIcon.OnCursorEntered = function()
			if IsValid(infoIcon.tooltip) then return end

			local tooltip = vgui.Create("DLabel")
			tooltip:SetSize(tooltipWidth or 300, tooltipHeight or 60)
			tooltip:SetWrap(true)
			tooltip:SetText(text or "No description available")
			tooltip:SetFont("Arcana_AncientSmall")
			tooltip:SetTextColor(ArtDeco.Colors.textBright)
			tooltip:SetDrawOnTop(true)
			tooltip:SetMouseInputEnabled(false)
			tooltip:SetKeyboardInputEnabled(false)
			tooltip:NoClipping(true)

			tooltip.Paint = function(pnl, w, h)
				ArtDeco.FillDecoPanel(-10, 0, w, h, ArtDeco.Colors.decoBg, 8)
				ArtDeco.DrawDecoFrame(-10, 0, w, h, ArtDeco.Colors.gold, 8)
			end

			infoIcon.tooltip = tooltip

			-- Position tooltip near cursor
			local function updatePos()
				if not IsValid(tooltip) then return end
				local x, y = gui.MousePos()
				tooltip:SetPos(x + 15, y - 30)
			end

			updatePos()

			-- Track cursor movement
			hook.Add("Think", "ArcanaTooltip_" .. tostring(tooltip), function()
				if not IsValid(tooltip) or not IsValid(infoIcon) then
					hook.Remove("Think", "ArcanaTooltip_" .. tostring(tooltip))
					if IsValid(tooltip) then tooltip:Remove() end
					return
				end
				updatePos()
			end)
		end

		infoIcon.OnCursorExited = function()
			if IsValid(infoIcon.tooltip) then
				hook.Remove("Think", "ArcanaTooltip_" .. tostring(infoIcon.tooltip))
				infoIcon.tooltip:Remove()
				infoIcon.tooltip = nil
			end
		end

		return infoIcon
	end
end

-- Store in global scope
_G.ArtDeco = ArtDeco

return ArtDeco
