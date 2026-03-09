-- Arcana Ring PNG Exporter — developer one-shot tool.
-- Renders every ring type and 8 rune glyphs to high-resolution PNGs in the DATA folder.
--
-- Usage (from a client Lua console or developer autorun):
--   include("arcana/tools/export_ring_pngs.lua")
--
-- Output:  garrysmod/data/arcana/ring_exports/
--   ring_simple_line.png
--   ring_pattern_lines.png
--   ring_rune_star.png
--   ring_star_ring.png
--   ring_band.png                 (4096×256 horizontal strip)
--   glyphs/glyph_<charcode>.png   (8 files, A–H)

if SERVER then return end

-- ── Configuration ─────────────────────────────────────────────────────────────

local RING_SIZE      = 4096   -- ring PNG canvas size (square)
local GLYPH_SIZE     = 1024   -- standalone glyph PNG canvas size
local LINE_THICK     = 16     -- line / circle stroke thickness in pixels at RING_SIZE
local OUTPUT         = "arcana/ring_exports"

-- Phrases baked into the three PATTERN_LINES ring variants
local PATTERN_PHRASE   = "ABRAXASABRAXASABRAXASABRAXASABRAXASABRAXASABRAXASABRAXAS"
local PATTERN_PHRASE_2 = "ARCANUMARCANUMARCANUMARCANUMARCANUMARCANUMARCANUMARCANUM"
local PATTERN_PHRASE_3 = "ANIMAVITAEANIMAVITAEANIMAVITAEANIMAVITAEANIMAVITAE"

-- Phrases baked into the three BAND_RING variants
local BAND_PHRASE   = PATTERN_PHRASE
local BAND_PHRASE_2 = "IGNISAQUATERRACAELUMIGNISAQUATERRACAELUMIGNISAQUATERRACAELUM"
local BAND_PHRASE_3 = "VINCULUMAETERNUMVINCULUMAETERNUMVINCULUMAETERNUMVINCULUM"

-- 8 rune characters exported as individual glyph PNGs (composited at runtime).
local EXPORT_GLYPHS = { "A", "B", "C", "D", "E", "F", "G", "H" }

-- ── Main export routine ────────────────────────────────────────────────────────

local function run()
	if not (Arcana and Arcana.RUNIC_FONT) then
		MsgC(Color(255, 80, 80), "[ArcanaExport] Arcana circle system not ready — aborting.\n")
		return
	end

	local RUNIC_FONT = Arcana.RUNIC_FONT

	file.CreateDir(OUTPUT)
	file.CreateDir(OUTPUT .. "/glyphs")

	-- Dedicated fonts sized for the 4 K canvas.
	-- TEXT_FONT: fills the ~5 % text band on PATTERN_LINES  (R * 0.05 ≈ 96 px at R ≈ 1925)
	-- GLYPH_FONT: fills ~70 % of the standalone 1024 × 1024 glyph canvas
	surface.CreateFont("ArcanaEx_Text",  { font = RUNIC_FONT, size = 96,  weight = 500, antialias = true })
	surface.CreateFont("ArcanaEx_Glyph", { font = RUNIC_FONT, size = 700, weight = 800, antialias = true })

	-- Geometry constants for the ring canvas
	local cx = RING_SIZE * 0.5
	local cy = RING_SIZE * 0.5
	local R  = math.floor(RING_SIZE * 0.47)   -- ring radius — ~3 % margin around the edge

	-- ── Drawing primitives ───────────────────────────────────────────────────

	local function thickCircle(x, y, r, t)
		t = math.floor(t or LINE_THICK)
		for i = 0, t - 1 do
			local rr = r - (t - 1) * 0.5 + i
			surface.DrawCircle(x, y, math.max(1, math.floor(rr)), 255, 255, 255, 255)
		end
	end

	local function thickLine(x1, y1, x2, y2, t)
		t = math.floor(t or LINE_THICK)
		if t <= 1 then
			surface.DrawLine(math.floor(x1), math.floor(y1), math.floor(x2), math.floor(y2))
			return
		end
		local dx, dy = x2 - x1, y2 - y1
		local len = math.sqrt(dx * dx + dy * dy)
		if len < 0.001 then return end
		local nx, ny = -dy / len, dx / len
		for i = 0, t - 1 do
			local off = i - (t - 1) * 0.5
			surface.DrawLine(
				math.floor(x1 + nx * off), math.floor(y1 + ny * off),
				math.floor(x2 + nx * off), math.floor(y2 + ny * off)
			)
		end
	end

	-- ── Per-character glyph materials (for circular text rotation) ───────────
	-- Each unique font+char gets its own tiny RT rendered once here.
	-- At 4 K with TEXT_FONT size 96, each glyph RT is roughly 60–90 px wide.

	local glyphMats = {}

	local function getGlyphMat(fontName, char)
		local key = fontName .. "\0" .. char
		if glyphMats[key] then return glyphMats[key] end

		surface.SetFont(fontName)
		local gw, gh = surface.GetTextSize(char)
		gw = math.max(4, math.floor(gw + 2))
		gh = math.max(4, math.floor(gh + 2))

		local crc = util.CRC(key)
		local tex = GetRenderTarget("arcana_ex_g_" .. crc, gw, gh, false)
		local mat = CreateMaterial("arcana_ex_gm_" .. crc, "UnlitGeneric", {
			["$basetexture"] = tex:GetName(),
			["$translucent"] = 1,
			["$vertexalpha"] = 1,
			["$vertexcolor"] = 1,
			["$nolod"] = 1,
		})

		render.PushRenderTarget(tex, 0, 0, gw, gh)
		render.Clear(0, 0, 0, 0, true, true)
		cam.Start2D()
		surface.SetFont(fontName)
		surface.SetTextColor(255, 255, 255, 255)
		surface.SetTextPos(1, 1)
		surface.DrawText(char)
		cam.End2D()
		render.PopRenderTarget()

		local entry = { mat = mat, w = gw, h = gh }
		glyphMats[key] = entry
		return entry
	end

	-- Draws each character of `phrase` around a circle of `radius` pixels.
	-- `charHeight` is the desired rendered height of each character in pixels.
	local function circularText(pcx, pcy, radius, phrase, fontName, charHeight)
		surface.SetFont(fontName)
		local _, sh = surface.GetTextSize("M")
		local scale   = charHeight / math.max(1, sh)
		local sw      = surface.GetTextSize("M") * scale
		local spacing = sw * 0.88   -- slight kerning tighten for a denser ring
		local nChars  = math.max(1, math.floor((2 * math.pi * radius) / spacing))

		for i = 1, nChars do
			local idx = ((i - 1) % #phrase) + 1
			local ch  = phrase:sub(idx, idx)
			local ang = -((i - 1) / nChars) * 2 * math.pi
			local px  = pcx + math.cos(ang) * radius
			local py  = pcy + math.sin(ang) * radius
			local rot = math.deg(ang + math.pi * 0.5)

			local g = getGlyphMat(fontName, ch)
			surface.SetMaterial(g.mat)
			surface.SetDrawColor(255, 255, 255, 255)
			surface.DrawTexturedRectRotated(px, py, g.w * scale, g.h * scale, rot)
		end
	end

	-- ── Glyph pre-warm ───────────────────────────────────────────────────────
	-- All per-character RTs must be created and rendered BEFORE we enter any
	-- exportRing call. Doing it lazily inside cam.Start2D() causes a nested
	-- PushRenderTarget that resets the 2D projection, silently dropping the text.

	local function prewarmGlyphs(fontName, chars)
		for i = 1, #chars do
			getGlyphMat(fontName, chars:sub(i, i))
		end
	end

	-- Collect every unique character across all ring and band phrase variants.
	local uniqueChars = ""
	for _, phrase in ipairs({ PATTERN_PHRASE, PATTERN_PHRASE_2, PATTERN_PHRASE_3,
	                           BAND_PHRASE, BAND_PHRASE_2, BAND_PHRASE_3 }) do
		for i = 1, #phrase do
			local ch = phrase:sub(i, i)
			if not uniqueChars:find(ch, 1, true) then
				uniqueChars = uniqueChars .. ch
			end
		end
	end
	prewarmGlyphs("ArcanaEx_Text", uniqueChars)

	-- ── Capture helper ───────────────────────────────────────────────────────

	local mainRT = GetRenderTarget("arcana_export_main_rt", RING_SIZE, RING_SIZE, false)

	local function exportRing(filename, drawFunc)
		render.PushRenderTarget(mainRT, 0, 0, RING_SIZE, RING_SIZE)
		render.Clear(0, 0, 0, 0, true, true)
		cam.Start2D()
		surface.SetDrawColor(255, 255, 255, 255)
		drawFunc()
		cam.End2D()
		-- render.Capture reads from the currently pushed render target
		local png = render.Capture({ format = "png", x = 0, y = 0, w = RING_SIZE, h = RING_SIZE, alpha = true })
		render.PopRenderTarget()

		local path = OUTPUT .. "/" .. filename
		file.Write(path, png)
		MsgC(Color(120, 230, 120), string.format("[ArcanaExport]  %-45s  %d KB\n", path, math.floor(#png / 1024)))
	end

	-- ── Ring exports ──────────────────────────────────────────────────────────

	-- 1. SIMPLE_LINE — single circle outline
	exportRing("ring_simple_line.png", function()
		thickCircle(cx, cy, R)
	end)

	-- 2. PATTERN_LINES — three variants with different baked phrases
	local function exportPatternRing(filename, phrase)
		exportRing(filename, function()
			local gap    = math.max(5, math.floor(R * 0.05))
			local outerR = R
			local innerR = outerR - gap
			thickCircle(cx, cy, outerR)
			thickCircle(cx, cy, innerR)
			circularText(cx, cy, (outerR + innerR) * 0.5, phrase, "ArcanaEx_Text", gap * 0.82)
		end)
	end

	exportPatternRing("ring_pattern_lines.png",   PATTERN_PHRASE)
	exportPatternRing("ring_pattern_lines_2.png", PATTERN_PHRASE_2)
	exportPatternRing("ring_pattern_lines_3.png", PATTERN_PHRASE_3)

	-- 3. RUNE_STAR — main circle + 4 sub-circles at diagonals + cross-connections.
	-- Glyphs are NOT baked in: they are composited from the separate glyph PNGs at runtime
	-- so they can be randomised per-cast.
	exportRing("ring_rune_star.png", function()
		local runeCircleR = math.floor(R * 0.15)
		thickCircle(cx, cy, R)

		local pts = {}
		for i = 1, 4 do
			local a = (i - 1) * math.pi * 0.5 + math.pi * 0.25   -- 45°, 135°, 225°, 315°
			pts[i] = { x = cx + math.cos(a) * R, y = cy + math.sin(a) * R }
			thickCircle(pts[i].x, pts[i].y, runeCircleR)
		end

		-- All-pairs connections (star / cross pattern)
		for i = 1, 4 do
			for j = i + 1, 4 do
				thickLine(pts[i].x, pts[i].y, pts[j].x, pts[j].y)
			end
		end
	end)

	-- 4. STAR_RING — 6-point star with spokes to centre (canonical variant)
	exportRing("ring_star_ring.png", function()
		local starPoints = 6
		local innerR     = math.floor(R * 0.45)
		local pts = {}

		for i = 0, starPoints * 2 - 1 do
			local a = (i / (starPoints * 2)) * math.pi * 2
			local r = (i % 2 == 0) and R or innerR
			pts[i + 1] = { x = cx + math.cos(a) * r, y = cy + math.sin(a) * r }
		end

		-- Star outline
		for i = 1, #pts do
			local ni = (i % #pts) + 1
			thickLine(pts[i].x, pts[i].y, pts[ni].x, pts[ni].y)
		end

		-- Spokes from each outer tip to the centre
		for i = 1, starPoints do
			local oi = (i - 1) * 2 + 1
			thickLine(pts[oi].x, pts[oi].y, cx, cy)
		end
	end)

	-- 5. BAND_RING — three 4096×256 horizontal strips: line / text / line
	-- The strip wraps around the cylindrical band mesh via UV repeat; all glyphs are
	-- pre-warmed above so getGlyphMat is a cache-only lookup here (no nested RT push).
	do
		local BW     = 4096
		local BH     = 256
		local bandRT = GetRenderTarget("arcana_export_band_rt", BW, BH, false)

		-- Measure once; scale / layout is the same for all three variants.
		surface.SetFont("ArcanaEx_Text")
		local sampleW, sampleH = surface.GetTextSize("M")
		local scale     = math.max(0.25, math.min(2.5, (BH * 0.7) / math.max(1, sampleH)))
		local lineThick = math.max(1, math.floor(BH * 0.06))
		local drawHRef  = math.max(1, sampleH * scale)
		local yText     = math.floor((BH - drawHRef) * 0.5)
		local pad       = math.max(1, math.floor(lineThick * 1.2))
		local yTop      = math.max(0, yText - pad - math.floor(lineThick * 0.5))
		local yBot      = math.min(BH - lineThick, yText + drawHRef + pad - math.floor(lineThick * 0.5))

		local function exportBand(filename, phrase)
			render.PushRenderTarget(bandRT, 0, 0, BW, BH)
			render.Clear(0, 0, 0, 0, true, true)
			cam.Start2D()
			surface.SetDrawColor(255, 255, 255, 255)

			surface.DrawRect(0, yTop, BW, lineThick)
			surface.DrawRect(0, yBot, BW, lineThick)

			local x   = 0
			local idx = 1
			while x < BW do
				local ch = phrase:sub(((idx - 1) % #phrase) + 1, ((idx - 1) % #phrase) + 1)
				local g  = getGlyphMat("ArcanaEx_Text", ch)
				local dw = math.max(1, g.w * scale)
				local dh = math.max(1, g.h * scale)
				local y  = math.floor((BH - dh) * 0.5)
				surface.SetMaterial(g.mat)
				surface.SetDrawColor(255, 255, 255, 255)
				surface.DrawTexturedRect(x, y, dw, dh)
				x   = x + math.max(1, dw * 0.9)
				idx = idx + 1
			end

			cam.End2D()
			local png = render.Capture({ format = "png", x = 0, y = 0, w = BW, h = BH, alpha = true })
			render.PopRenderTarget()

			local path = OUTPUT .. "/" .. filename
			file.Write(path, png)
			MsgC(Color(120, 230, 120), string.format("[ArcanaExport]  %-45s  %d KB\n", path, math.floor(#png / 1024)))
		end

		exportBand("ring_band.png",   BAND_PHRASE)
		exportBand("ring_band_2.png", BAND_PHRASE_2)
		exportBand("ring_band_3.png", BAND_PHRASE_3)
	end

	-- ── Glyph exports ─────────────────────────────────────────────────────────
	-- One 1024 × 1024 PNG per glyph — white character on transparent background.

	local glyphRT = GetRenderTarget("arcana_export_glyph_rt", GLYPH_SIZE, GLYPH_SIZE, false)

	for _, glyph in ipairs(EXPORT_GLYPHS) do
		render.PushRenderTarget(glyphRT, 0, 0, GLYPH_SIZE, GLYPH_SIZE)
		render.Clear(0, 0, 0, 0, true, true)
		cam.Start2D()
		surface.SetFont("ArcanaEx_Glyph")
		surface.SetTextColor(255, 255, 255, 255)
		local gw, gh = surface.GetTextSize(glyph)
		surface.SetTextPos(GLYPH_SIZE * 0.5 - gw * 0.5, GLYPH_SIZE * 0.5 - gh * 0.5)
		surface.DrawText(glyph)
		cam.End2D()
		local png = render.Capture({ format = "png", x = 0, y = 0, w = GLYPH_SIZE, h = GLYPH_SIZE, alpha = true })
		render.PopRenderTarget()

		-- Name by ASCII code so filenames are unambiguous (A=65 … H=72)
		local path = OUTPUT .. "/glyphs/glyph_" .. string.byte(glyph) .. ".png"
		file.Write(path, png)
		MsgC(Color(120, 230, 120), string.format("[ArcanaExport]  %-45s  %d KB\n", path, math.floor(#png / 1024)))
	end

	MsgC(Color(180, 255, 180), "[ArcanaExport] Done — files written to data/" .. OUTPUT .. "/\n")
end

-- ── Entry point ───────────────────────────────────────────────────────────────
-- Defers one frame so Arcana is fully initialised and we are in a valid rendering
-- context (PostRender fires after the full scene + HUD, render targets are safe to use).

local exported = false
hook.Add("PostRender", "ArcanaExportRingPNGs", function()
	if exported then return end
	exported = true
	hook.Remove("PostRender", "ArcanaExportRingPNGs")

	local ok, err = pcall(run)
	if not ok then
		MsgC(Color(255, 80, 80), "[ArcanaExport] Error: " .. tostring(err) .. "\n")
	end
end)
