-- Astral Vault UI — client-side panel, slot cards, galaxy background renderer.
-- Server-side persistence, SQL schema, and net.Receive handlers live in vault.lua.
if not CLIENT then return end

local Arcana = Arcana

-- Cost constants come from config.lua (loaded before this file via init.lua).
local VAULT_CFG = Arcana.VaultConfig

local HL2_MODELS = {
	weapon_357 = "models/weapons/w_357.mdl",
	weapon_ar2 = "models/weapons/w_irifle.mdl",
	weapon_bugbait = "models/weapons/w_bugbait.mdl",
	weapon_crossbow = "models/weapons/w_crossbow.mdl",
	weapon_crowbar = "models/weapons/w_crowbar.mdl",
	weapon_frag = "models/weapons/w_grenade.mdl",
	weapon_physcannon = "models/weapons/w_physics.mdl",
	weapon_pistol = "models/weapons/w_pistol.mdl",
	weapon_rpg = "models/weapons/w_rocket_launcher.mdl",
	weapon_shotgun = "models/weapons/w_shotgun.mdl",
	weapon_slam = "models/weapons/w_slam.mdl",
	weapon_smg = "models/weapons/w_smg1.mdl",
	weapon_stunstick = "models/weapons/w_stunbaton.mdl",
}

-- Command to open the vault
concommand.Add("arcana_vault", function()
	net.Start("Arcana_AstralVault_RequestOpen")
	net.SendToServer()
end, nil, "Open the Arcana Astral Vault")

list.Set("DesktopWindows", "ArcanaAstralVault", {
	title = "Astral Vault",
	icon = "arcana/astral_vault.png",
	init = function(icon, window)
		RunConsoleCommand("arcana_vault")
	end
})

local function drawGalaxyBackground(pnl, w, h, starSeed)
	-- Galaxy clipped to an art-deco octagon using the stencil buffer
	local x, y = 6, 6
	local ww, hh = w - 12, h - 12
	local c = 14
	ArtDeco.BeginOctagonClip(x, y, ww, hh, c)

	-- Background base
	surface.SetDrawColor(8, 10, 22, 240)
	surface.DrawRect(x, y, ww, hh)

	local t = CurTime()

	-- Nebulas, each breathing slowly on its own phase
	local function nebula(cx, cy, r, cr, cg, cb, a, phase)
		local pulse = 0.85 + 0.15 * math.sin(t * 0.35 + (phase or 0))
		for k = r, 0, -6 do
			local alpha = (a or 90) * (k / r) * pulse
			surface.DrawCircle(x + cx, y + cy, k, cr, cg, cb, alpha)
		end
	end

	nebula(ww * 0.25, hh * 0.35, math.min(ww, hh) * 0.35, 58, 84, 150, 90, 0)
	nebula(ww * 0.68, hh * 0.62, math.min(ww, hh) * 0.42, 40, 60, 120, 70, 2.1)
	nebula(ww * 0.55, hh * 0.25, math.min(ww, hh) * 0.25, 80, 80, 140, 60, 4.2)

	-- Stars (stable per-seed layout, gently twinkling out of phase)
	math.randomseed(starSeed or 12345)
	for i = 1, 220 do
		local sx = x + math.random(6, ww - 6)
		local sy = y + math.random(6, hh - 6)
		local tw = 0.5 + 0.5 * math.sin(t * (0.6 + (i % 7) * 0.25) + i * 1.7)
		surface.SetDrawColor(240, 220, 170, 90 + 165 * tw * tw)
		surface.DrawRect(sx, sy, 1, 1)
		if i % 9 == 0 then surface.DrawRect(sx, sy, 2, 1) end
	end

	ArtDeco.EndOctagonClip()
end

-- Global-ish state for live refresh
local VAULT = {frame = nil, items = {}, rebuild = nil}

-- Resolve a weapon's display name: the stored name (nickname or PrintName),
-- falling back to the SWEP's PrintName, with "#token" localization phrases
-- translated through language.GetPhrase.
local function getWeaponDisplayName(it)
	local name = it.name or it.print

	if not name or name == "" or name == it.class then
		local cls = it.class or ""
		local swep = weapons.GetStored(cls) or list.Get("Weapon")[cls]
		name = (swep and (swep.PrintName or swep.Printname)) or cls
	end

	if isstring(name) and string.sub(name, 1, 1) == "#" then
		local translated = language.GetPhrase(string.sub(name, 2))
		if translated and translated ~= "" then
			name = translated
		end
	end

	if not name or name == "" then
		name = it.class or "Weapon"
	end

	return name
end

-- Greedy word wrap at the current surface font. Returns nil when a single word
-- is wider than maxW, since no amount of wrapping will make that fit.
local function wrapLines(text, maxW)
	local lines, cur = {}, nil

	for word in string.gmatch(text, "%S+") do
		local test = cur and (cur .. " " .. word) or word
		if surface.GetTextSize(test) <= maxW then
			cur = test
		else
			if not cur or surface.GetTextSize(word) > maxW then return nil end
			lines[#lines + 1] = cur
			cur = word
		end
	end

	if cur then lines[#lines + 1] = cur end

	return lines
end

-- Fit a weapon name into a card's title strip. Cards keep the large title font so
-- their headings all read at one size: a long name wraps onto a second line rather
-- than shrinking. Smaller fonts, then an ellipsis, are last resorts for a name too
-- long to wrap into two large lines.
local TITLE_FONTS = {"Arcana_AncientLarge", "Arcana_Ancient", "Arcana_AncientSmall"}
local TITLE_MAX_LINES = 2
local function fitTitle(text, maxW)
	for _, font in ipairs(TITLE_FONTS) do
		surface.SetFont(font)
		local lines = wrapLines(text, maxW)
		if lines and #lines <= TITLE_MAX_LINES then return font, lines, false end
	end

	return TITLE_FONTS[#TITLE_FONTS], {text}, true
end

local function getEnchantDisplayList(ids)
	local out = {}
	for _, id in ipairs(ids or {}) do
		local e = Arcana and Arcana.RegisteredEnchantments and Arcana.RegisteredEnchantments[id]
		out[#out + 1] = (e and e.name) or tostring(id)
	end
	table.sort(out)
	return out
end

local MODEL_FOV = 30
local MODEL_DIR = Vector(1, 1, 0.5)

local function openVault(items)
	-- If already open, just refresh contents
	if VAULT.frame and IsValid(VAULT.frame) then
		VAULT.items = items or {}
		if VAULT.rebuild then VAULT.rebuild() end
		return
	end

	local ply = LocalPlayer()
	if not IsValid(ply) then return end
	local frame = vgui.Create("DFrame")
	frame:SetSize(1280, 720)
	frame:Center()
	frame:SetTitle("")
	frame:MakePopup()
	VAULT.frame = frame
	VAULT.items = items or {}
	VAULT.seed = math.random(1, 10^9)

	hook.Add("HUDPaint", frame, function()
		local x, y = frame:LocalToScreen(0, 0)
		ArtDeco.DrawBlurRect(x + 6, y + 6, frame:GetWide() - 12, frame:GetTall() - 12, 4, 8)
	end)

	-- Declared here so the title can measure the band down to the cards' frames.
	local container

	frame.Paint = function(pnl, w, h)
		drawGalaxyBackground(pnl, w, h, VAULT.seed)
		ArtDeco.DrawDecoFrame(6, 6, w - 12, h - 12, ArtDeco.Colors.gold, 14)

		-- The title centers in the band between the frame's top line and the slot
		-- cards below: cards sit 8px into the container and frame themselves at +2.
		local bandTop = 6 + 1
		local bandBottom = IsValid(container) and (container:GetY() + 10) or (bandTop + 38)
		ArtDeco.DrawTitle("Arcana_AncientLarge", string.upper("Astral Vault"), bandTop, bandBottom, ArtDeco.Colors.paleGold)
	end

	ArtDeco.StyleCloseButton(frame)

	-- Hide minimize/maximize buttons
	if IsValid(frame.btnMinim) then frame.btnMinim:Hide() end
	if IsValid(frame.btnMaxim) then frame.btnMaxim:Hide() end

	-- Single row of slot cards (max 6)
	container = vgui.Create("DPanel", frame)
	container:Dock(FILL)
	container:DockMargin(8, 8, 8, 0)
	container.Paint = function(pnl, w, h) end

	local cards = {}

	local COLOR_DECO_BG = Color(10, 10, 18, 210)
	local COLOR_EMPTY_TEXT = Color(200, 190, 170)
	local COLOR_COST_TEXT = Color(210, 200, 185)
	local COLOR_GOLD = Color(198, 160, 74, 255)
	local COLOR_BUTTON_BG = Color(46, 36, 26, 235)
	local COLOR_BUTTON_BG_HOVER = Color(58, 44, 32, 235)
	local COLOR_BUTTON_FRAME_DISABLED = Color(140, 120, 90, 255)
	local COLOR_BUTTON_TEXT_DISABLED = Color(200, 190, 170, 255)
	local function buildModelPanel(card, it)
		local model = vgui.Create("DModelPanel", card)
		model:SetMouseInputEnabled(false)
		function model:LayoutEntity(ent)
			ArtDeco.SpinModelPanelEntity(ent, Angle(0, CurTime() * 15 % 360, 0))
			ArtDeco.FitModelPanel(self, MODEL_FOV, MODEL_DIR)
		end
		function model:PostDrawModel(ent)
			if Arcana and Arcana.RenderEnchantBandsForEntity then
				Arcana:RenderEnchantBandsForEntity(ent, self._EnchantCount or 3,
					(LocalPlayer().GetWeaponColor and LocalPlayer():GetWeaponColor():ToColor()) or COLOR_GOLD,
					self._BandStyle or "axis", {isMelee = self._BandIsMelee})
			end
		end
		if it then
			local cls = it.class or ""
			local swep = weapons.GetStored(cls) or list.Get("Weapon")[cls]
			-- The world model is what the rings are resolved against in the world,
			-- and geometry is cached per model, so the preview reuses that exact box
			model:SetModel((swep and (swep.WorldModel or swep.ViewModel)) or HL2_MODELS[cls] or "models/weapons/w_pistol.mdl")
			ArtDeco.FitModelPanel(model, MODEL_FOV, MODEL_DIR)
			model._EnchantCount = math.max(1, #(it.enchant_ids or {}))
			model._BandStyle, model._BandIsMelee = Arcana:GetEnchantBandPreviewInfo(cls)
		else
			model:SetVisible(false)
		end
		return model
	end

	-- Below the model: the weapon class as a fancy centered heading with
	-- flanking strokes, a wide diamond divider, then the enchantments as
	-- tarot captions — a pale-gold numeral over the name in small caps,
	-- slim diamond dividers between them.
	local ROMAN = {"I", "II", "III", "IV", "V"}
	local COLOR_SEP = Color(160, 130, 60, 180)

	-- Ornaments and captions must share one integer center, or a half-pixel x
	-- rounds the two halves of a divider onto different columns.
	local function drawDiamondDivider(mx, my, arm)
		surface.SetDrawColor(COLOR_SEP)
		surface.DrawRect(mx - 7 - arm, my, arm, 1)
		surface.DrawRect(mx + 8, my, arm, 1)
		surface.DrawLine(mx - 3, my, mx, my - 3)
		surface.DrawLine(mx, my - 3, mx + 3, my)
		surface.DrawLine(mx + 3, my, mx, my + 3)
		surface.DrawLine(mx, my + 3, mx - 3, my)
	end

	-- draw.SimpleText's TEXT_ALIGN_CENTER lands odd-width text half a pixel left
	-- of center; snapping the left edge ourselves keeps it on the same axis as the
	-- diamonds. Returns the drawn text's left and right edges.
	local function drawCenteredText(text, font, cx, y, col)
		surface.SetFont(font)
		local tw = surface.GetTextSize(text)
		local tx = cx - math.floor(tw * 0.5)
		draw.SimpleText(text, font, tx, y, col)

		return tx, tx + tw
	end

	local function buildEnchantList(card, it)
		local enchList = vgui.Create("DPanel", card)
		enchList:SetPaintBackground(false)
		enchList.names = it and getEnchantDisplayList(it.enchant_ids) or {}
		enchList.Paint = function(pnl, w, h)
			if not it then return end
			local y = 0
			local cx = math.floor(w * 0.5)

			-- Class heading: pale gold, flanked by short brass strokes.
			-- Truncated so long class names never clip at the card edges.
			local cls = string.upper(it.class or "")
			surface.SetFont("Arcana_AncientSmall")
			local maxW = w - 60
			local cw = surface.GetTextSize(cls)
			if cw > maxW then
				repeat
					cls = string.sub(cls, 1, #cls - 1)
					cw = surface.GetTextSize(cls .. "...")
				until cw <= maxW or #cls <= 4
				cls = cls .. "..."
			end

			-- Strokes hang off the heading's drawn edges, so both gaps are 8px
			-- wide whatever the text width rounds to.
			local clsLeft, clsRight = drawCenteredText(cls, "Arcana_AncientSmall", cx, y, ArtDeco.Colors.paleGold)
			surface.SetDrawColor(COLOR_SEP)
			surface.DrawRect(clsLeft - 26, y + 8, 18, 1)
			surface.DrawRect(clsRight + 8, y + 8, 18, 1)
			y = y + 19

			-- Wide divider between the heading and the enchantments.
			drawDiamondDivider(cx, y, 34)
			y = y + 12

			for i, name in ipairs(pnl.names or {}) do
				if y > h - 26 then break end
				drawCenteredText(ROMAN[i] or tostring(i), "Arcana_AncientSmall", cx, y, ArtDeco.Colors.paleGold)
				y = y + 14
				drawCenteredText(string.upper(name), "Arcana_AncientSmall", cx, y, COLOR_COST_TEXT)
				y = y + 17

				if i < #pnl.names then
					drawDiamondDivider(cx, y + 4, 17)
					y = y + 11
				end
			end
		end
		if not it then enchList:SetVisible(false) end
		return enchList
	end

	-- Hover hint for the summon button: "Summon weapon" with the have/need
	-- costs underneath, coins in gold and shards in crystal blue, matching
	-- the enchanter's cost readout.
	local function attachSummonHint(btn)
		btn.OnCursorEntered = function(pnl)
			if IsValid(pnl._hint) then return end

			local tip = vgui.Create("DPanel")
			tip:SetSize(220, 72)
			tip:SetDrawOnTop(true)
			tip:SetMouseInputEnabled(false)
			tip.Paint = function(_, w, h)
				ArtDeco.FillDecoPanel(0, 0, w, h, ArtDeco.Colors.decoBg, 8)
				ArtDeco.DrawDecoFrame(0, 0, w, h, ArtDeco.Colors.gold, 8)
				local lp = LocalPlayer()
				local needCoins = tonumber(VAULT_CFG.SUMMON_COINS) or 0
				local needShards = tonumber(VAULT_CFG.SUMMON_SHARDS) or 0
				draw.SimpleText("Summon weapon", "Arcana_AncientSmall", w * 0.5, 8, ArtDeco.Colors.textBright, TEXT_ALIGN_CENTER)
				ArtDeco.DrawCostLine("Arcana_AncientSmall", w * 0.5, 27, {
					{text = string.Comma(Arcana:GetCoins(lp)) .. " / " .. string.Comma(needCoins), icon = ArtDeco.Icons.coin, color = ArtDeco.Colors.coinGold},
				}, TEXT_ALIGN_CENTER)
				ArtDeco.DrawCostLine("Arcana_AncientSmall", w * 0.5, 45, {
					{text = string.Comma(Arcana:GetItemCount(lp, "mana_crystal_shard")) .. " / " .. string.Comma(needShards), icon = ArtDeco.Icons.shard, color = ArtDeco.Colors.shardBlue},
				}, TEXT_ALIGN_CENTER)
			end
			pnl._hint = tip

			local function place()
				if not IsValid(tip) then return end
				local mx, my = gui.MousePos()
				tip:SetPos(math.Clamp(mx + 16, 0, ScrW() - tip:GetWide()), math.Clamp(my - 80, 0, ScrH() - tip:GetTall()))
			end

			place()
			hook.Add("Think", "ArcanaVaultHint_" .. tostring(tip), function()
				if not IsValid(tip) or not IsValid(pnl) or not pnl:IsHovered() then
					hook.Remove("Think", "ArcanaVaultHint_" .. tostring(tip))
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

	-- Round summon button: filled disc, double ring, and a sparkle sigil.
	-- The label lives in a hover tooltip instead of on the button.
	local function buildSummonButton(card, it)
		local summon = vgui.Create("DButton", card)
		summon:SetText("")
		summon.Paint = function(pnl, w, h)
			local enabled = pnl:IsEnabled()
			local hovered = enabled and pnl:IsHovered()
			local cx, cy = w * 0.5, h * 0.5
			local r = math.min(w, h) * 0.5 - 2

			draw.NoTexture()
			local bg = hovered and COLOR_BUTTON_BG_HOVER or COLOR_BUTTON_BG
			surface.SetDrawColor(bg)
			local pts = {}
			local seg = 28
			for k = 0, seg - 1 do
				local a = (k / seg) * math.pi * 2
				pts[#pts + 1] = {x = cx + math.cos(a) * r, y = cy + math.sin(a) * r}
			end
			surface.DrawPoly(pts)

			local ring = enabled and (hovered and ArtDeco.Colors.paleGold or ArtDeco.Colors.gold) or COLOR_BUTTON_FRAME_DISABLED
			surface.DrawCircle(cx, cy, r, ring.r, ring.g, ring.b, 255)
			local inner = ArtDeco.Colors.brassInner
			surface.DrawCircle(cx, cy, r - 3, inner.r, inner.g, inner.b, enabled and 200 or 90)

			-- Sparkle sigil: long cross, short diagonals.
			local sig = enabled and ArtDeco.Colors.paleGold or COLOR_BUTTON_TEXT_DISABLED
			surface.SetDrawColor(sig)
			surface.DrawLine(cx, cy - 9, cx, cy + 9)
			surface.DrawLine(cx - 9, cy, cx + 9, cy)
			surface.DrawLine(cx - 4, cy - 4, cx + 4, cy + 4)
			surface.DrawLine(cx - 4, cy + 4, cx + 4, cy - 4)
		end

		attachSummonHint(summon)
		summon.Think = function(pnl)
			if not it then pnl:SetEnabled(false) return end
			local lp = LocalPlayer()
			pnl:SetEnabled(Arcana:GetCoins(lp) >= (tonumber(VAULT_CFG.SUMMON_COINS) or 0)
				and Arcana:GetItemCount(lp, "mana_crystal_shard") >= (tonumber(VAULT_CFG.SUMMON_SHARDS) or 0))
		end
		if it then
			summon.DoClick = function()
				net.Start("Arcana_AstralVault_Summon")
				net.WriteString(tostring(it.id))
				net.SendToServer()
				surface.PlaySound("buttons/button15.wav")
				local ctrlDown = input.IsKeyDown(KEY_LCONTROL) or input.IsKeyDown(KEY_RCONTROL)
				if not ctrlDown and VAULT and IsValid(VAULT.frame) then VAULT.frame:Close() end
			end
		else
			summon:SetVisible(false)
		end
		return summon
	end

	local function buildDeleteButton(card, it)
		local delBtn = vgui.Create("DButton", card)
		delBtn:SetText("")
		delBtn:SetSize(22, 22)
		delBtn.Paint = function(pnl, w, h)
			if not it then return end
			surface.SetDrawColor(160, 100, 90, 255)
			local pad = 6
			surface.DrawLine(pad, pad, w - pad, h - pad)
			surface.DrawLine(w - pad, pad, pad, h - pad)
		end
		if it then
			delBtn.DoClick = function()
				net.Start("Arcana_AstralVault_Delete")
				net.WriteString(tostring(it.id))
				net.SendToServer()
				surface.PlaySound("buttons/button8.wav")
			end
		else
			delBtn:SetVisible(false)
		end
		return delBtn
	end

	-- Tarot-style luxury frame: gold outline, an inner brass frame, and
	-- gilded corners — the band between the outlines filled at the corner
	-- cut, extended by a wing along each edge that tapers with a slant
	-- toward the outer outline.
	local TAROT_CORNER_MIRRORS = {{0, 0}, {1, 0}, {1, 1}, {0, 1}}
	local function drawTarotFrame(w, h)
		ArtDeco.DrawDecoFrame(2, 2, w - 4, h - 4, ArtDeco.Colors.gold, 8)
		ArtDeco.DrawDecoFrame(7, 7, w - 14, h - 14, ArtDeco.Colors.brassInner, 8)

		-- Wings shrink on short/narrow panels so opposite corners never
		-- collide; below a minimum reach a wing is dropped entirely.
		local wingX = math.min(34, math.floor(w * 0.5) - 8)
		local wingY = math.min(34, math.floor(h * 0.5) - 8)
		local shapes = {
			{{10, 2}, {15, 7}, {7, 15}, {2, 10}}, -- corner-cut quad
		}
		if wingX >= 26 then
			shapes[#shapes + 1] = {{10, 2}, {wingX, 2}, {wingX - 8, 7}, {15, 7}}
		end
		if wingY >= 26 then
			shapes[#shapes + 1] = {{2, 10}, {7, 15}, {7, wingY - 8}, {2, wingY}}
		end

		draw.NoTexture()
		surface.SetDrawColor(ArtDeco.Colors.gold)
		for _, m in ipairs(TAROT_CORNER_MIRRORS) do
			for _, shape in ipairs(shapes) do
				local pts = {}
				for _, p in ipairs(shape) do
					pts[#pts + 1] = {
						x = m[1] == 0 and p[1] or (w - p[1]),
						y = m[2] == 0 and p[2] or (h - p[2]),
					}
				end

				-- Mirroring across one axis flips the winding; DrawPoly
				-- needs clockwise, so reverse those.
				if (m[1] + m[2]) == 1 then
					local rev = {}
					for k = #pts, 1, -1 do
						rev[#rev + 1] = pts[k]
					end
					pts = rev
				end

				surface.DrawPoly(pts)
			end
		end
	end

	local TITLE_X = 22
	local function buildSlot(parent, it, slotIndex)
		local card = vgui.Create("DPanel", parent)
		local displayName = it and getWeaponDisplayName(it) or ""

		-- The fitted title is recomputed only when the card's usable title width
		-- changes; the delete button eats the right side of the strip.
		local function titleLayout(w)
			local maxW = w - TITLE_X - 34
			if card._titleMaxW ~= maxW then
				card._titleMaxW = maxW
				card._titleFont, card._titleLines, card._titleClipped = fitTitle(displayName, maxW)
				card._titleLineH = draw.GetFontHeight(card._titleFont)
			end

			return card._titleFont, card._titleLines, card._titleLineH, card._titleClipped, maxW
		end

		card.Paint = function(pnl, w, h)
			ArtDeco.FillDecoPanel(2, 2, w - 4, h - 4, COLOR_DECO_BG, 8)
			drawTarotFrame(w, h)
			if it then
				local font, lines, lineH, clipped, maxW = titleLayout(w)
				if clipped then
					ArtDeco.DrawTruncatedText(font, displayName, TITLE_X, 11, ArtDeco.Colors.textBright, maxW)
				else
					for i, line in ipairs(lines) do
						draw.SimpleText(line, font, TITLE_X, 11 + (i - 1) * lineH, ArtDeco.Colors.textBright)
					end
				end
			else
				draw.SimpleText("EMPTY", "Arcana_AncientLarge", w * 0.5, h * 0.5, COLOR_EMPTY_TEXT, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
			end
		end

		local model    = buildModelPanel(card, it)
		local enchList = buildEnchantList(card, it)
		local summon   = buildSummonButton(card, it)
		local delBtn   = buildDeleteButton(card, it)

		card.PerformLayout = function(pnl, w, h)
			local pad = 10
			local titleH = 24
			-- A title that wrapped to a second line takes its extra height out of
			-- the model panel, so the enchant list and summon button stay put.
			local _, lines, lineH = titleLayout(w)
			local extraTitleH = math.max(0, #lines - 1) * lineH
			local modelTop = titleH + 4 + extraTitleH
			local mH = math.max(60, math.floor(h * 0.52) - extraTitleH)
			model:SetPos(pad, modelTop)
			model:SetSize(w - pad * 2, mH)
			enchList:SetPos(pad, modelTop + mH + 6)
			enchList:SetSize(w - pad * 2, h - (modelTop + mH + 6) - 76)
			summon:SetSize(48, 48)
			summon:SetPos(math.floor((w - 48) * 0.5), h - 68)
			delBtn:SetPos(w - delBtn:GetWide() - 11, 11)
		end

		return card
	end

	local function layoutCards()
		local w = container:GetWide()
		local h = container:GetTall()
		local gap = 8
		local cols = VAULT_CFG.MAX_SLOTS
		local cw = math.max(160, math.floor((w - gap * (cols - 1) - 16) / cols))
		local ch = math.max(180, h - 16)
		for i, card in ipairs(cards) do
			local col = (i - 1)
			card:SetSize(cw, ch)
			card:SetPos(8 + col * (cw + gap), 8)
		end
	end

	local function rebuild()
		for _, c in ipairs(cards) do if IsValid(c) then c:Remove() end end
		cards = {}
		local items = VAULT.items or {}
		for i = 1, VAULT_CFG.MAX_SLOTS do
			local it = items[i]
			cards[#cards + 1] = buildSlot(container, it, i)
		end
		layoutCards()
	end

	container.PerformLayout = function() layoutCards() end

	-- Bottom imprint button spanning full width. Two lines like the spellcraft
	-- CREATE SPELL button: label above, cost below, no overlap.
	local imprintBtn = vgui.Create("DButton", frame)
	imprintBtn:Dock(BOTTOM)
	imprintBtn:SetTall(58)
	imprintBtn:DockMargin(12, 4, 12, 12)
	imprintBtn:SetText("")
	imprintBtn.Paint = function(pnl, w, h)
		local enabled = pnl:IsEnabled()
		local hovered = enabled and pnl:IsHovered()
		local bgCol = hovered and COLOR_BUTTON_BG_HOVER or COLOR_BUTTON_BG
		ArtDeco.FillDecoPanel(0, 0, w, h, bgCol, 8)

		-- Double frame, no corner ornaments: they crowd a bar this size.
		local frameCol = enabled and ArtDeco.Colors.gold or COLOR_BUTTON_FRAME_DISABLED
		ArtDeco.DrawDecoFrame(2, 2, w - 4, h - 4, frameCol, 8)
		ArtDeco.DrawDecoFrame(7, 7, w - 14, h - 14, ArtDeco.Colors.brassInner, 8)

		local txtCol = enabled and ArtDeco.Colors.textBright or COLOR_BUTTON_TEXT_DISABLED
		draw.SimpleText("Imprint Current Weapon", "Arcana_Ancient", w * 0.5, h * 0.5 - 8, txtCol, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)

		-- Costs, have / need, coins in gold and shards in crystal blue
		-- around a small diamond, matching the summon hint.
		local lp = LocalPlayer()
		ArtDeco.DrawCostLine("Arcana_AncientSmall", w * 0.5, h * 0.5 + 2, {
			{text = string.Comma(Arcana:GetCoins(lp)) .. " / " .. string.Comma(tonumber(VAULT_CFG.STORE_COINS) or 0), icon = ArtDeco.Icons.coin, color = ArtDeco.Colors.coinGold},
			{text = string.Comma(Arcana:GetItemCount(lp, "mana_crystal_shard")) .. " / " .. string.Comma(tonumber(VAULT_CFG.STORE_SHARDS) or 0), icon = ArtDeco.Icons.shard, color = ArtDeco.Colors.shardBlue},
		}, TEXT_ALIGN_CENTER, true)
	end
	-- Enable/disable imprint based on weapon presence, vault space and affordability
	imprintBtn.Think = function(pnl)
		local lp = LocalPlayer()
		local hasWeapon = IsValid(lp) and IsValid(lp:GetActiveWeapon())
		local items = VAULT.items or {}
		local hasRoom = (#items) < (tonumber(VAULT_CFG.MAX_SLOTS) or 0)
		local haveCoins = Arcana:GetCoins(lp)
		local haveShards = Arcana:GetItemCount(lp, "mana_crystal_shard")
		local needCoins = tonumber(VAULT_CFG.STORE_COINS) or 0
		local needShards = tonumber(VAULT_CFG.STORE_SHARDS) or 0
		local ok = hasWeapon and hasRoom and (haveCoins >= needCoins) and (haveShards >= needShards)
		pnl:SetEnabled(ok)
	end

	imprintBtn.DoClick = function()
		if not imprintBtn:IsEnabled() then
			surface.PlaySound("buttons/button8.wav")
			return
		end
		net.Start("Arcana_AstralVault_Imprint")
		net.WriteString("")
		net.SendToServer()
		surface.PlaySound("buttons/button14.wav")
	end

	rebuild()
	VAULT.rebuild = rebuild
end

-- Receive open payload
net.Receive("Arcana_AstralVault_Open", function()
	local items = net.ReadTable() or {}
	openVault(items)
end)
