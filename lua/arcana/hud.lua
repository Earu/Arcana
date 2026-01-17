-- Arcana Global HUD (casting + cooldown), shared independent of SWEP
-- Reuses styling helpers/colors from the Art Deco library for visual cohesion
if not CLIENT then return end

-- Local reference cache
local function getData()
	local ply = LocalPlayer()
	if not IsValid(ply) then return nil end

	return Arcane:GetPlayerData(ply)
end

-- Reusable color objects to avoid allocation overhead in draw calls
local _tempTextCol = Color(236, 230, 220, 255)
local _tempSubCol = Color(222, 198, 120, 255)
local _tempShadowCol = Color(0, 0, 0, 255)

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

-- XP gain announcement stack (multiple notifications can be active)
local xpAnnounceStack = {}

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

-- XP gain hook
hook.Add("Arcana_PlayerGainedXP", "ArcanaHUD_XPAnnounce", function(ply, amount, reason)
	if not IsValid(ply) or ply ~= LocalPlayer() then return end

	-- Add new notification to the stack
	table.insert(xpAnnounceStack, {
		startedAt = CurTime(),
		endsAt = CurTime() + 2.5,
		amount = amount or 0,
		reason = reason or ""
	})
end)

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

hook.Add("Arcana_CastSpellFailure", "ArcanaHUD_TrackFail", function(caster, spellId, castTime)
	if not IsValid(caster) or caster ~= LocalPlayer() then return end

	-- reset the casting bar if spail fails
	activeCast.spellId = nil
	activeCast.startedAt = 0
	activeCast.endsAt = 0
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
	ArtDeco.FillDecoPanel(x - 10, y - 16, barW + 20, barH + 32, ArtDeco.Colors.decoPanel, 10)
	ArtDeco.DrawDecoFrame(x - 10, y - 16, barW + 20, barH + 32, ArtDeco.Colors.gold, 10)
	-- Title
	local title = string.upper("Casting")
	draw.SimpleText(title, "Arcana_Ancient", x, y - 14, ArtDeco.Colors.paleGold)
	-- Bar background
	surface.SetDrawColor(60, 46, 34, 220)
	surface.DrawRect(x, y, barW, barH)
	-- Fill
	surface.SetDrawColor(ArtDeco.Colors.xpFill)
	surface.DrawRect(x + 2, y + 2, math.floor((barW - 4) * progress), barH - 4)
	-- Label
	local remain = math.max(0, activeCast.endsAt - now)
	local spellName = Arcane.RegisteredSpells[activeCast.spellId] and Arcane.RegisteredSpells[activeCast.spellId].name or activeCast.spellId
	local label = string.format("%s  %.1fs", spellName or "", remain)
	draw.SimpleText(label, "Arcana_AncientSmall", x + barW * 0.5, y + barH + 8, ArtDeco.Colors.textBright, TEXT_ALIGN_CENTER)
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
		ArtDeco.FillDecoPanel(x, y, rowW, rowH, ArtDeco.Colors.decoPanel, 8)
		ArtDeco.DrawDecoFrame(x, y, rowW, rowH, ArtDeco.Colors.gold, 8)
		draw.SimpleText(e.spell.name, "Arcana_Ancient", x + 10, y + 6, ArtDeco.Colors.textBright)
		local remainText = string.format("%.1fs", e.remain)
		draw.SimpleText(remainText, "Arcana_AncientSmall", x + rowW - 10, y + 8, ArtDeco.Colors.paleGold, TEXT_ALIGN_RIGHT)
		-- thin progress bar
		local progress = 1 - math.Clamp(e.remain / math.max(0.001, e.total), 0, 1)
		surface.SetDrawColor(60, 46, 34, 220)
		surface.DrawRect(x + 10, y + rowH - 10, rowW - 20, 6)
		surface.SetDrawColor(ArtDeco.Colors.xpFill)
		surface.DrawRect(x + 12, y + rowH - 8, math.floor((rowW - 24) * progress), 2)
		y = y + rowH + gap
	end
end

local function drawXPAnnouncement(scrW, scrH)
	if #xpAnnounceStack == 0 then return end
	local now = CurTime()

	-- Remove expired notifications
	for i = #xpAnnounceStack, 1, -1 do
		if now >= xpAnnounceStack[i].endsAt then
			table.remove(xpAnnounceStack, i)
		end
	end

	if #xpAnnounceStack == 0 then return end

	-- Position in middle-right
	local baseX = scrW - 30
	local baseY = scrH * 0.5
	local rowHeight = 30
	local startY = baseY - ((#xpAnnounceStack - 1) * rowHeight * 0.5)

	-- Draw each notification in the stack
	for i, notify in ipairs(xpAnnounceStack) do
		local y = startY + ((i - 1) * rowHeight)

		-- Fade in/out
		local total = notify.endsAt - notify.startedAt
		local t = (now - notify.startedAt) / math.max(0.001, total)
		local fadeIn = math.Clamp(t / 0.15, 0, 1)
		local fadeOut = math.Clamp((notify.endsAt - now) / 0.3, 0, 1)

		-- Text alpha: fades in/out
		local textAlpha = math.floor(255 * math.min(fadeIn, fadeOut))

		-- Calculate text widths for dynamic sizing
		surface.SetFont("Arcana_Ancient")
		local xpText = "+" .. string.Comma(notify.amount) .. " XP"
		local xpTextW, _ = surface.GetTextSize(xpText)

		local reasonText = (notify.reason and notify.reason ~= "") and notify.reason or ""
		local reasonTextW, _ = surface.GetTextSize(reasonText)

		-- Diamond spacing
		local diamondSpace = 20

		-- Set text colors with proper alpha
		_tempTextCol.a = textAlpha
		_tempSubCol.a = textAlpha
		_tempShadowCol.a = textAlpha

		-- XP amount (right side) with stronger shadow
		draw.SimpleText(xpText, "Arcana_Ancient", baseX + 2, y + 2, _tempShadowCol, TEXT_ALIGN_RIGHT)
		draw.SimpleText(xpText, "Arcana_Ancient", baseX, y, _tempSubCol, TEXT_ALIGN_RIGHT)

		-- Diamond separator position
		local diamondX = baseX - xpTextW - (diamondSpace / 2)
		local diamondY = y + 10

		if reasonTextW > 0 then
			-- Diamond shadow (stronger)
			draw.NoTexture()
			surface.SetDrawColor(0, 0, 0, textAlpha)
			local d = 4
			local pts = {
				{x = diamondX + 2, y = diamondY - d + 2},
				{x = diamondX + d + 2, y = diamondY + 2},
				{x = diamondX + 2, y = diamondY + d + 2},
				{x = diamondX - d + 2, y = diamondY + 2},
			}
			surface.DrawPoly(pts)

			-- Diamond
			surface.SetDrawColor(ArtDeco.Colors.gold.r, ArtDeco.Colors.gold.g, ArtDeco.Colors.gold.b, textAlpha)
			local pts2 = {
				{x = diamondX, y = diamondY - d},
				{x = diamondX + d, y = diamondY},
				{x = diamondX, y = diamondY + d},
				{x = diamondX - d, y = diamondY},
			}
			surface.DrawPoly(pts2)

			-- Inner diamond
			surface.SetDrawColor(236, 230, 220, textAlpha)
			local d2 = 2
			local pts3 = {
				{x = diamondX, y = diamondY - d2},
				{x = diamondX + d2, y = diamondY},
				{x = diamondX, y = diamondY + d2},
				{x = diamondX - d2, y = diamondY},
			}
			surface.DrawPoly(pts3)

			-- Reason (left side) with stronger shadow
			draw.SimpleText(reasonText, "Arcana_Ancient", diamondX - (diamondSpace / 2) + 2, y + 2, _tempShadowCol, TEXT_ALIGN_RIGHT)
			draw.SimpleText(reasonText, "Arcana_Ancient", diamondX - (diamondSpace / 2), y, _tempTextCol, TEXT_ALIGN_RIGHT)
		end
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

	-- Reuse temp color objects to avoid allocations
	_tempTextCol.a = alpha
	_tempSubCol.a = alpha
	_tempShadowCol.a = alpha

	-- Hex background + frame + subtle flourish
	ArtDeco.DrawHexFill(x, y, panelW, panelH, alpha)
	ArtDeco.DrawHexFrame(x, y, panelW, panelH, alpha)
	ArtDeco.DrawDecoFlourish(x, y, panelW, panelH, alpha)
	local title = string.upper("Level Up")
	local levelText = "Level " .. tostring(levelAnnounce.newLevel)
	local knowText = "+" .. tostring(levelAnnounce.knowledgeDelta) .. " Knowledge"
	-- subtle drop shadow for readability
	draw.SimpleText(title, "Arcana_DecoTitle", x + panelW * 0.5 + 1, y + 21, _tempShadowCol, TEXT_ALIGN_CENTER)
	draw.SimpleText(title, "Arcana_DecoTitle", x + panelW * 0.5, y + 20, _tempTextCol, TEXT_ALIGN_CENTER)
	draw.SimpleText(levelText, "Arcana_AncientLarge", x + panelW * 0.5 + 1, y + 61, _tempShadowCol, TEXT_ALIGN_CENTER)
	draw.SimpleText(levelText, "Arcana_AncientLarge", x + panelW * 0.5, y + 60, _tempSubCol, TEXT_ALIGN_CENTER)

	if levelAnnounce.knowledgeDelta and levelAnnounce.knowledgeDelta > 0 then
		draw.SimpleText(knowText, "Arcana_Ancient", x + panelW * 0.5 + 1, y + 91, _tempShadowCol, TEXT_ALIGN_CENTER)
		draw.SimpleText(knowText, "Arcana_Ancient", x + panelW * 0.5, y + 90, _tempSubCol, TEXT_ALIGN_CENTER)
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

	-- Reuse temp color objects to avoid allocations
	_tempTextCol.a = alpha
	_tempSubCol.a = alpha
	_tempShadowCol.a = alpha

	-- Hex background + frame + subtle flourish
	ArtDeco.DrawHexFill(x, y, panelW, panelH, alpha)
	ArtDeco.DrawHexFrame(x, y, panelW, panelH, alpha)
	ArtDeco.DrawDecoFlourish(x, y, panelW, panelH, alpha)
	draw.SimpleText(unlockAnnounce.title, "Arcana_DecoTitle", x + panelW * 0.5 + 1, y + 19, _tempShadowCol, TEXT_ALIGN_CENTER)
	draw.SimpleText(unlockAnnounce.title, "Arcana_DecoTitle", x + panelW * 0.5, y + 18, _tempTextCol, TEXT_ALIGN_CENTER)
	draw.SimpleText(unlockAnnounce.subtitle, "Arcana_AncientLarge", x + panelW * 0.5 + 1, y + 59, _tempShadowCol, TEXT_ALIGN_CENTER)
	draw.SimpleText(unlockAnnounce.subtitle, "Arcana_AncientLarge", x + panelW * 0.5, y + 58, _tempSubCol, TEXT_ALIGN_CENTER)
end

hook.Add("HUDPaint", "Arcana_GlobalHUD", function()
	local scrW, scrH = ScrW(), ScrH()
	drawUnlockAnnouncement(scrW, scrH)
	drawLevelAnnouncement(scrW, scrH)
	drawXPAnnouncement(scrW, scrH)
	drawCastingBar(scrW, scrH)
	drawCooldownStack(scrW, scrH)
end)