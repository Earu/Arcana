-- Arcana Global HUD (casting + cooldown), shared independent of SWEP
-- Reuses styling helpers/colors from the grimoire UI for visual cohesion

if not CLIENT then return end

-- Local reference cache
local function getData()
	if not Arcane then return nil end
	local ply = LocalPlayer()
	if not IsValid(ply) then return nil end
	return Arcane:GetPlayerData(ply)
end

-- Colors and helpers copied to keep this module self-contained.
-- If you centralize these later, import from a shared style file instead.
surface.CreateFont("Arcana_AncientSmall", {font = "Georgia", size = 16, weight = 600, antialias = true, extended = true})
surface.CreateFont("Arcana_Ancient", {font = "Georgia", size = 20, weight = 700, antialias = true, extended = true})
surface.CreateFont("Arcana_AncientLarge", {font = "Georgia", size = 24, weight = 800, antialias = true, extended = true})
surface.CreateFont("Arcana_DecoTitle", {font = "Georgia", size = 26, weight = 900, antialias = true, extended = true})

-- local decoBg = Color(26, 20, 14, 235)
local decoPanel = Color(32, 24, 18, 235)
local gold = Color(198, 160, 74, 255)
local paleGold = Color(222, 198, 120, 255)
local textBright = Color(236, 230, 220, 255)
-- local textDim = Color(180, 170, 150, 255)
-- reserved for future chips next to titles
-- local chipTextCol = Color(24, 26, 36, 230)
local xpFill = Color(222, 198, 120, 180)

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
		{ x = x + c, y = y }, { x = x + w - c, y = y },
		{ x = x + w, y = y + c }, { x = x + w, y = y + h - c },
		{ x = x + w - c, y = y + h }, { x = x + c, y = y + h },
		{ x = x, y = y + h - c }, { x = x, y = y + c },
	}
	surface.DrawPoly(pts)
end

-- Casting state (client-only) fed by Arcane_BeginCasting
local activeCast = {
	spellId = nil,
	startedAt = 0,
	endsAt = 0,
}

hook.Add("Arcane_BeginCastingVisuals", "ArcanaHUD_TrackCast", function(caster, spellId, castTime)
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
	if not Arcane or not Arcane.RegisteredSpells then return end

	local now = CurTime()
	local entries = {}
	for sid, untilTs in pairs(cds) do
		if untilTs and untilTs > now and Arcane.RegisteredSpells[sid] then
			local sp = Arcane.RegisteredSpells[sid]
			local remain = untilTs - now
			table.insert(entries, { id = sid, spell = sp, remain = remain, total = sp.cooldown or remain })
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

hook.Add("HUDPaint", "Arcana_GlobalHUD", function()
	if not Arcane then return end
	local scrW, scrH = ScrW(), ScrH()
	drawCastingBar(scrW, scrH)
	drawCooldownStack(scrW, scrH)
end)