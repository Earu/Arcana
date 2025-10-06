-- Arcana Global HUD (casting + cooldown), shared independent of SWEP
-- Reuses styling helpers/colors from the grimoire UI for visual cohesion
if not CLIENT then return end

-- Local reference cache
local function getData()
	local ply = LocalPlayer()
	if not IsValid(ply) then return nil end

	return Arcane:GetPlayerData(ply)
end

-- Colors and helpers copied to keep this module self-contained.
-- If you centralize these later, import from a shared style file instead.
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

-- local decoBg = Color(26, 20, 14, 235)
local decoPanel = Color(32, 24, 18, 235)
local gold = Color(198, 160, 74, 255)
local paleGold = Color(222, 198, 120, 255)
local textBright = Color(236, 230, 220, 255)
-- local textDim = Color(180, 170, 150, 255)
-- reserved for future chips next to titles
-- local chipTextCol = Color(24, 26, 36, 230)
local xpFill = Color(222, 198, 120, 180)

-- Gradient materials (reserved for future use)
-- souls-like banner removed (kept for reference previously)
-- Small Art Deco flourish: center diamond with flanking lines
local function drawDecoFlourish(x, y, w, h, alpha)
	local a = math.Clamp(tonumber(alpha) or 255, 0, 255)
	local cx = x + math.floor(w * 0.5)
	local lineY = y + math.floor(h * 0.48)
	local lineCol = Color(gold.r, gold.g, gold.b, math.floor(80 * (a / 255)))
	surface.SetDrawColor(lineCol)
	surface.DrawLine(cx - 110, lineY, cx - 20, lineY)
	surface.DrawLine(cx + 20, lineY, cx + 110, lineY)
	-- diamond
	draw.NoTexture()
	surface.SetDrawColor(gold.r, gold.g, gold.b, math.floor(110 * (a / 255)))
	local d = 7

	local pts = {
		{
			x = cx,
			y = lineY - d
		},
		{
			x = cx + d,
			y = lineY
		},
		{
			x = cx,
			y = lineY + d
		},
		{
			x = cx - d,
			y = lineY
		},
	}

	surface.DrawPoly(pts)
	-- inner faint diamond
	surface.SetDrawColor(236, 230, 220, math.floor(60 * (a / 255)))
	local d2 = 3

	local pts2 = {
		{
			x = cx,
			y = lineY - d2
		},
		{
			x = cx + d2,
			y = lineY
		},
		{
			x = cx,
			y = lineY + d2
		},
		{
			x = cx - d2,
			y = lineY
		},
	}

	surface.DrawPoly(pts2)
end

-- Hexagon frame (no fill) to encapsulate announcement text
local function drawHexFrame(x, y, w, h, alpha)
	local a = math.Clamp(tonumber(alpha) or 255, 0, 255)
	local m = math.max(10, math.floor(math.min(w, h) * 0.10))
	local cy = y + h * 0.5

	local p1 = {
		x = x + m,
		y = y
	}

	local p2 = {
		x = x + w - m,
		y = y
	}

	local p3 = {
		x = x + w,
		y = cy
	}

	local p4 = {
		x = x + w - m,
		y = y + h
	}

	local p5 = {
		x = x + m,
		y = y + h
	}

	local p6 = {
		x = x,
		y = cy
	}

	local function drawEdge(aPt, bPt, col)
		surface.SetDrawColor(col)
		surface.DrawLine(aPt.x, aPt.y, bPt.x, bPt.y)
	end

	local mainCol = Color(gold.r, gold.g, gold.b, math.floor(140 * (a / 255)))
	local accentCol = Color(236, 230, 220, math.floor(60 * (a / 255)))
	-- outer stroke
	drawEdge(p1, p2, mainCol)
	drawEdge(p2, p3, mainCol)
	drawEdge(p3, p4, mainCol)
	drawEdge(p4, p5, mainCol)
	drawEdge(p5, p6, mainCol)
	drawEdge(p6, p1, mainCol)
	-- second pass for a slightly thicker, highlighted edge
	drawEdge(p1, p2, accentCol)
	drawEdge(p2, p3, accentCol)
	drawEdge(p3, p4, accentCol)
	drawEdge(p4, p5, accentCol)
	drawEdge(p5, p6, accentCol)
	drawEdge(p6, p1, accentCol)
end

-- Hexagon dark background fill (slightly inset so the border stays crisp)
local function drawHexFill(x, y, w, h, alpha)
	local a = math.Clamp(tonumber(alpha) or 255, 0, 255)
	local m = math.max(10, math.floor(math.min(w, h) * 0.10))
	local inset = 1
	local cy = y + h * 0.5

	local pts = {
		{
			x = x + m + inset,
			y = y + inset
		},
		{
			x = x + w - m - inset,
			y = y + inset
		},
		{
			x = x + w - inset,
			y = cy
		},
		{
			x = x + w - m - inset,
			y = y + h - inset
		},
		{
			x = x + m + inset,
			y = y + h - inset
		},
		{
			x = x + inset,
			y = cy
		},
	}

	draw.NoTexture()
	surface.SetDrawColor(20, 16, 12, math.floor(160 * (a / 255)))
	surface.DrawPoly(pts)
end

-- Unlock announcement state
local unlockAnnounce = {
	active = false,
	title = "",
	subtitle = "",
	startedAt = 0,
	endsAt = 0,
}

local function showUnlockAnnouncement(kind, displayName, knowledgeDelta)
	unlockAnnounce.active = true
	unlockAnnounce.title = string.upper(kind == "ritual" and "Ritual Unlocked" or "Spell Unlocked")
	unlockAnnounce.subtitle = tostring(displayName or "")
	unlockAnnounce.startedAt = CurTime()
	unlockAnnounce.endsAt = CurTime() + 4.5
	unlockAnnounce.knowledgeDelta = tonumber(knowledgeDelta or 0) or 0
	-- Play a deep, long sound. Prefer addon sounds; fallback to HL2 ambient if missing.
	local snd = nil

	if file.Exists("sound/arcana/arcane_1.ogg", "GAME") then
		snd = "arcana/arcane_1.ogg"
	elseif file.Exists("sound/arcana/arcane_2.ogg", "GAME") then
		snd = "arcana/arcane_2.ogg"
	elseif file.Exists("sound/arcana/arcane_3.ogg", "GAME") then
		snd = "arcana/arcane_3.ogg"
	else
		snd = "ambient/atmosphere/terrain_rumble1.wav"
	end

	surface.PlaySound(snd)
end

net.Receive("Arcane_SpellUnlocked", function()
	local _id = net.ReadString()
	local name = net.ReadString()
	local cost = 0

	if Arcane.RegisteredSpells[_id] then
		cost = tonumber(Arcane.RegisteredSpells[_id].knowledge_cost or 0) or 0
	end

	showUnlockAnnouncement("spell", name, -cost)
end)

-- Level-up / Knowledge announcement state
local levelAnnounce = {
	active = false,
	startedAt = 0,
	endsAt = 0,
	newLevel = 1,
	knowledgeDelta = 0,
}

hook.Add("Arcana_ClientLevelUp", "ArcanaHUD_LevelAnnounce", function(prevLevel, newLevel, knowledgeDelta)
	levelAnnounce.active = true
	levelAnnounce.startedAt = CurTime()
	levelAnnounce.endsAt = CurTime() + 4.5
	levelAnnounce.newLevel = newLevel or prevLevel
	levelAnnounce.knowledgeDelta = knowledgeDelta or 0
	-- Distinct chime for level-up
	surface.PlaySound("arcana/arcane_1.ogg")
end)

local function DrawDecoFrame(x, y, w, h, col, corner)
	local c = math.max(8, corner or 12)
	surface.SetDrawColor(col.r, col.g, col.b, col.a or 255)
	surface.DrawLine(x + c, y, x + w - c, y)
	surface.DrawLine(x + w, y + c, x + w, y + h - c)
	surface.DrawLine(x + w - c, y + h, x + c, y + h)
	surface.DrawLine(x, y + h - c, x, y + c)
	surface.DrawLine(x, y + c, x + c, y)
	surface.DrawLine(x + w - c, y, x + w, y + c)
	surface.DrawLine(x + w, y + h - c, x + w - c, y + h)
	surface.DrawLine(x + c, y + h, x, y + h - c)
end

local function FillDecoPanel(x, y, w, h, col, corner)
	local c = math.max(8, corner or 12)
	draw.NoTexture()
	surface.SetDrawColor(col.r, col.g, col.b, col.a or 255)

	local pts = {
		{
			x = x + c,
			y = y
		},
		{
			x = x + w - c,
			y = y
		},
		{
			x = x + w,
			y = y + c
		},
		{
			x = x + w,
			y = y + h - c
		},
		{
			x = x + w - c,
			y = y + h
		},
		{
			x = x + c,
			y = y + h
		},
		{
			x = x,
			y = y + h - c
		},
		{
			x = x,
			y = y + c
		},
	}

	surface.DrawPoly(pts)
end

-- Casting state (client-only) fed by Arcane_BeginCasting
local activeCast = {
	spellId = nil,
	startedAt = 0,
	endsAt = 0,
}

hook.Add("Arcana_BeginCastingVisuals", "ArcanaHUD_TrackCast", function(caster, spellId, castTime)
	if not IsValid(caster) or caster ~= LocalPlayer() then return end
	activeCast.spellId = spellId
	activeCast.startedAt = CurTime()
	activeCast.endsAt = CurTime() + (castTime or 0)
end)

local function drawCastingBar(scrW, scrH)
	if not activeCast.spellId then return end
	local now = CurTime()

	if now >= activeCast.endsAt then
		activeCast.spellId = nil

		return
	end

	local progress = math.Clamp((now - activeCast.startedAt) / math.max(0.001, activeCast.endsAt - activeCast.startedAt), 0, 1)
	local barW, barH = math.floor(scrW * 0.36), 5 * (1440 / scrH)
	local x = math.floor((scrW - barW) * 0.5)
	local y = scrH - 150
	FillDecoPanel(x - 10, y - 16, barW + 20, barH + 32, decoPanel, 10)
	DrawDecoFrame(x - 10, y - 16, barW + 20, barH + 32, gold, 10)
	-- Title
	local title = string.upper("Casting")
	draw.SimpleText(title, "Arcana_Ancient", x, y - 14, paleGold)
	-- Bar background
	surface.SetDrawColor(60, 46, 34, 220)
	surface.DrawRect(x, y, barW, barH)
	-- Fill
	surface.SetDrawColor(xpFill)
	surface.DrawRect(x + 2, y + 2, math.floor((barW - 4) * progress), barH - 4)
	-- Label
	local remain = math.max(0, activeCast.endsAt - now)
	local spellName = Arcane.RegisteredSpells[activeCast.spellId] and Arcane.RegisteredSpells[activeCast.spellId].name or activeCast.spellId
	local label = string.format("%s  %.1fs", spellName or "", remain)
	draw.SimpleText(label, "Arcana_AncientSmall", x + barW * 0.5, y + barH + 8, textBright, TEXT_ALIGN_CENTER)
end

local function drawCooldownStack(scrW, scrH)
	local data = getData()
	if not data then return end
	local cds = data.spell_cooldowns or {}
	local now = CurTime()
	local entries = {}

	for sid, untilTs in pairs(cds) do
		if untilTs and untilTs > now and Arcane.RegisteredSpells[sid] then
			local sp = Arcane.RegisteredSpells[sid]
			local remain = untilTs - now

			table.insert(entries, {
				id = sid,
				spell = sp,
				remain = remain,
				total = sp.cooldown or remain
			})
		end
	end

	if #entries == 0 then return end
	table.sort(entries, function(a, b) return a.remain < b.remain end)
	local rowW, rowH = 260, 36
	local gap = 8
	local totalH = (#entries * rowH) + ((#entries - 1) * gap)
	local cy = math.floor(scrH * 0.5)
	local startY = cy - math.floor(totalH * 0.5)
	-- place near center-right; clamp to screen
	local anchorFrac = 0.68 -- tweak to move closer/farther from center
	local x = math.min(math.floor(scrW * anchorFrac), scrW - rowW - 12)
	local y = startY

	for i = 1, #entries do
		local e = entries[i]
		FillDecoPanel(x, y, rowW, rowH, decoPanel, 8)
		DrawDecoFrame(x, y, rowW, rowH, gold, 8)
		draw.SimpleText(e.spell.name, "Arcana_Ancient", x + 10, y + 6, textBright)
		local remainText = string.format("%.1fs", e.remain)
		draw.SimpleText(remainText, "Arcana_AncientSmall", x + rowW - 10, y + 8, paleGold, TEXT_ALIGN_RIGHT)
		-- thin progress bar
		local progress = 1 - math.Clamp(e.remain / math.max(0.001, e.total), 0, 1)
		surface.SetDrawColor(60, 46, 34, 220)
		surface.DrawRect(x + 10, y + rowH - 10, rowW - 20, 6)
		surface.SetDrawColor(xpFill)
		surface.DrawRect(x + 12, y + rowH - 8, math.floor((rowW - 24) * progress), 2)
		y = y + rowH + gap
	end
end

local function drawLevelAnnouncement(scrW, scrH)
	if not levelAnnounce.active then return end
	local now = CurTime()

	if now >= levelAnnounce.endsAt then
		levelAnnounce.active = false

		return
	end

	local total = levelAnnounce.endsAt - levelAnnounce.startedAt
	local t = (now - levelAnnounce.startedAt) / math.max(0.001, total)
	local fadeIn = math.Clamp(t / 0.2, 0, 1)
	local fadeOut = math.Clamp((levelAnnounce.endsAt - now) / 0.4, 0, 1)
	local alpha = math.floor(255 * math.min(fadeIn, fadeOut))
	local panelW = math.floor(scrW * 0.5)
	local panelH = 120
	local x = math.floor((scrW - panelW) * 0.5)
	local y = math.floor(scrH * 0.28)
	local textCol = Color(textBright.r, textBright.g, textBright.b, alpha)
	local subCol = Color(paleGold.r, paleGold.g, paleGold.b, alpha)
	-- Hex background + frame + subtle flourish
	drawHexFill(x, y, panelW, panelH, alpha)
	drawHexFrame(x, y, panelW, panelH, alpha)
	drawDecoFlourish(x, y, panelW, panelH, alpha)
	local title = string.upper("Level Up")
	local levelText = "Level " .. tostring(levelAnnounce.newLevel)
	local knowText = "+" .. tostring(levelAnnounce.knowledgeDelta) .. " Knowledge"
	-- subtle drop shadow for readability
	draw.SimpleText(title, "Arcana_DecoTitle", x + panelW * 0.5 + 1, y + 21, Color(0, 0, 0, alpha), TEXT_ALIGN_CENTER)
	draw.SimpleText(title, "Arcana_DecoTitle", x + panelW * 0.5, y + 20, textCol, TEXT_ALIGN_CENTER)
	draw.SimpleText(levelText, "Arcana_AncientLarge", x + panelW * 0.5 + 1, y + 61, Color(0, 0, 0, alpha), TEXT_ALIGN_CENTER)
	draw.SimpleText(levelText, "Arcana_AncientLarge", x + panelW * 0.5, y + 60, subCol, TEXT_ALIGN_CENTER)

	if levelAnnounce.knowledgeDelta and levelAnnounce.knowledgeDelta > 0 then
		draw.SimpleText(knowText, "Arcana_Ancient", x + panelW * 0.5 + 1, y + 91, Color(0, 0, 0, alpha), TEXT_ALIGN_CENTER)
		draw.SimpleText(knowText, "Arcana_Ancient", x + panelW * 0.5, y + 90, subCol, TEXT_ALIGN_CENTER)
	end
end

local function drawUnlockAnnouncement(scrW, scrH)
	if not unlockAnnounce.active then return end
	local now = CurTime()

	if now >= unlockAnnounce.endsAt then
		unlockAnnounce.active = false

		return
	end

	-- Fade in/out
	local total = unlockAnnounce.endsAt - unlockAnnounce.startedAt
	local t = (now - unlockAnnounce.startedAt) / math.max(0.001, total)
	local fadeIn = math.Clamp(t / 0.2, 0, 1)
	local fadeOut = math.Clamp((unlockAnnounce.endsAt - now) / 0.4, 0, 1)
	local alpha = math.floor(255 * math.min(fadeIn, fadeOut))
	local panelW = math.floor(scrW * 0.5)
	local panelH = 110
	local x = math.floor((scrW - panelW) * 0.5)
	local y = math.floor(scrH * 0.16)
	local textCol = Color(textBright.r, textBright.g, textBright.b, alpha)
	local subCol = Color(paleGold.r, paleGold.g, paleGold.b, alpha)
	-- Hex background + frame + subtle flourish
	drawHexFill(x, y, panelW, panelH, alpha)
	drawHexFrame(x, y, panelW, panelH, alpha)
	drawDecoFlourish(x, y, panelW, panelH, alpha)
	draw.SimpleText(unlockAnnounce.title, "Arcana_DecoTitle", x + panelW * 0.5 + 1, y + 19, Color(0, 0, 0, alpha), TEXT_ALIGN_CENTER)
	draw.SimpleText(unlockAnnounce.title, "Arcana_DecoTitle", x + panelW * 0.5, y + 18, textCol, TEXT_ALIGN_CENTER)
	draw.SimpleText(unlockAnnounce.subtitle, "Arcana_AncientLarge", x + panelW * 0.5 + 1, y + 59, Color(0, 0, 0, alpha), TEXT_ALIGN_CENTER)
	draw.SimpleText(unlockAnnounce.subtitle, "Arcana_AncientLarge", x + panelW * 0.5, y + 58, subCol, TEXT_ALIGN_CENTER)
end

hook.Add("HUDPaint", "Arcana_GlobalHUD", function()
	local scrW, scrH = ScrW(), ScrH()
	drawUnlockAnnouncement(scrW, scrH)
	drawLevelAnnouncement(scrW, scrH)
	drawCastingBar(scrW, scrH)
	drawCooldownStack(scrW, scrH)
end)