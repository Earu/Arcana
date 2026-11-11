Arcana = Arcana or {}
Arcana.CondensatorExchange = Arcana.CondensatorExchange or {}

local X = Arcana.CondensatorExchange

local DUST = "crystal_dust"
local MAX_TIMES = 10000
local SUCCESS_BONUS = 40
local FAIL_PENALTY = -50

X.Recipes = {
	{label = "Crystallize", cost = 20, give = "mana_crystal_shard"},
	{label = "Exchange", cost = 1, give = "coins"},
}

function X.BonusAmount(times, pct)
	local raw = times * pct / 100
	if pct >= SUCCESS_BONUS then return math.ceil(raw) end

	return math.floor(raw)
end

if SERVER then
	util.AddNetworkString("Arcana_Condensator_OpenExchange")
	util.AddNetworkString("Arcana_Condensator_Convert")
	util.AddNetworkString("Arcana_Condensator_Game")
	util.AddNetworkString("Arcana_Condensator_Ack")
	util.AddNetworkString("Arcana_Condensator_Input")
	util.AddNetworkString("Arcana_Condensator_Converted")

	local INPUTS_PER_SECOND = 40
	local nextId = 0

	function X.Open(ply)
		net.Start("Arcana_Condensator_OpenExchange")
		net.Send(ply)
	end

	local function timerName(ply)
		return "Arcana_CondensatorGame_" .. ply:EntIndex()
	end

	local function latency(ply, st)
		return st.rtt or ply:Ping() / 1000
	end

	local function payout(ply, recipe, amount)
		if amount <= 0 then return true end
		if recipe.give == "coins" then
			return Arcana.GiveCoins(ply, amount, "Condensator")
		end

		return Arcana.GiveItem(ply, recipe.give, amount, "Condensator")
	end

	local function resolve(ply, st, success, now)
		if ply._arcanaExchange ~= st then return end
		ply._arcanaExchange = nil
		timer.Remove(timerName(ply))

		local pct = FAIL_PENALTY
		if success then
			local t = (now - st.start) - st.timing.lead - latency(ply, st)
			pct = math.Round(SUCCESS_BONUS * X.SpeedFrac(st.timing, t))
		end

		local raw = st.times * (1 + pct / 100)
		local gained = math.floor(raw)
		if pct == SUCCESS_BONUS then
			gained = math.ceil(raw)
		elseif math.random() < raw - gained then
			gained = gained + 1
		end

		if not payout(ply, X.Recipes[st.recipe], gained) then
			Arcana.GiveItem(ply, DUST, st.spent, "Condensator refund")
			gained = 0
		end

		net.Start("Arcana_Condensator_Converted")
		net.WriteUInt(st.recipe, 2)
		net.WriteUInt(st.times, 14)
		net.WriteBool(success)
		net.WriteInt(pct, 8)
		net.WriteUInt(gained, 16)
		net.Send(ply)
	end

	net.Receive("Arcana_Condensator_Convert", function(_, ply)
		if not IsValid(ply) or not ply:Alive() or ply._arcanaExchange then return end

		local now = CurTime()
		if (ply._arcanaExchangeNext or 0) > now then return end
		ply._arcanaExchangeNext = now + 0.5

		local wep = ply:GetActiveWeapon()
		if not IsValid(wep) or wep:GetClass() ~= "arcana_condensator" then return end

		local index = net.ReadUInt(2)
		local recipe = X.Recipes[index]
		if not recipe then return end

		local affordable = math.floor((Arcana.GetItemCount(ply, DUST) or 0) / recipe.cost)
		local times = math.min(net.ReadUInt(14), MAX_TIMES, affordable)
		if times < 1 then return end

		local spent = recipe.cost * times
		if not Arcana.TakeItem(ply, DUST, spent, "Condensator") then return end

		local last = ply._arcanaExchangeLast
		local gameIndex = math.random(last and #X.Games - 1 or #X.Games)
		if last and gameIndex >= last then gameIndex = gameIndex + 1 end
		ply._arcanaExchangeLast = gameIndex
		local def = X.Games[gameIndex]
		local secret, public = def.generate()
		nextId = (nextId + 1) % 65536

		local st = {
			id = nextId,
			recipe = index,
			times = times,
			spent = spent,
			game = gameIndex,
			secret = secret,
			public = public,
			timing = def.timing(public),
			start = SysTime(),
			inputs = 0,
		}
		ply._arcanaExchange = st

		timer.Create(timerName(ply), st.timing.timeout + 2, 1, function()
			if IsValid(ply) then resolve(ply, st, false, SysTime()) end
		end)

		net.Start("Arcana_Condensator_Game")
		net.WriteUInt(st.id, 16)
		net.WriteUInt(gameIndex, 3)
		net.WriteUInt(index, 2)
		net.WriteUInt(times, 14)
		net.WriteTable(public)
		net.Send(ply)
	end)

	net.Receive("Arcana_Condensator_Ack", function(_, ply)
		local st = ply._arcanaExchange
		if not st or st.rtt or net.ReadUInt(16) ~= st.id then return end

		st.rtt = math.min(SysTime() - st.start, 1)
	end)

	net.Receive("Arcana_Condensator_Input", function(_, ply)
		local st = ply._arcanaExchange
		if not st or net.ReadUInt(16) ~= st.id then return end

		local now = SysTime()
		st.inputs = st.inputs + 1
		if st.inputs > INPUTS_PER_SECOND * (now - st.start + 1) then return end

		if net.ReadBool() or now - st.start > st.timing.timeout + 1 then
			resolve(ply, st, false, now)
			return
		end

		local values = {}
		for i = 1, net.ReadUInt(3) do values[i] = net.ReadInt(16) end

		local result = X.Games[st.game].input(st, values, now, latency(ply, st))

		if result == "success" then
			resolve(ply, st, true, now)
		elseif result == "fail" then
			resolve(ply, st, false, now)
		end
	end)

	hook.Add("PlayerDisconnected", "Arcana_CondensatorExchange", function(ply)
		timer.Remove(timerName(ply))
	end)

	return
end

local STAGE_X, STAGE_Y, STAGE_H = 22, 54, 520
local CARD_GAP = 8
local ROW_H = 50
local FRAME_W = STAGE_H + STAGE_X * 2
local FRAME_H = STAGE_Y + STAGE_H + (CARD_GAP + ROW_H) * 2 + STAGE_X
local BUTTON_W, BUTTON_H, BUTTON_GAP = 66, 32, 8
local BACK_SCALE = 0.42

local GATHER_TIME = 0.55
local REVEAL_TIME = 1.8

local COLOR_MANA = Color(226, 192, 110)
local COLOR_DUST = Color(120, 200, 255)
local COLOR_FAIL = Color(232, 110, 90)
local COLOR_INTERIOR = Color(14, 11, 8, 245)
local COLOR_BACKWALL = Color(30, 23, 15, 220)
local GLOW = Material("sprites/light_glow02_add")

local frameRef

local function dustCount()
	return Arcana.GetItemCount(LocalPlayer(), DUST) or 0
end

local function heldCount(recipe)
	if recipe.give == "coins" then
		return Arcana.GetCoins(LocalPlayer()) or 0
	end

	return Arcana.GetItemCount(LocalPlayer(), recipe.give) or 0
end

local function isBusy(state)
	return state.game ~= nil or RealTime() < (state.busyUntil or 0)
end

local function newMote(atBack)
	return {
		u = math.Rand(-0.9, 0.9),
		v = math.Rand(-0.9, 0.9),
		d = atBack and math.Rand(0.85, 1) or math.Rand(0, 1),
		du = math.Rand(-0.06, 0.06),
		dv = math.Rand(-0.07, -0.01),
		dd = math.Rand(-0.04, 0.04),
		phase = math.Rand(0, 6.28),
		size = math.Rand(5, 11),
		born = RealTime(),
	}
end

local function depthScale(d)
	return 1 / (1 + (1 / BACK_SCALE - 1) * d)
end

local function drawGlow(x, y, size, col, alpha)
	surface.SetMaterial(GLOW)
	surface.SetDrawColor(col.r, col.g, col.b, alpha)
	surface.DrawTexturedRect(x - size * 0.5, y - size * 0.5, size, size)
end

local function easeIn(t)
	return t * t * t
end

local function easeOut(t)
	return 1 - (1 - t) * (1 - t)
end

local function drawChevron(cx, cy, col)
	surface.SetDrawColor(col)
	for i = 0, 1 do
		local ox = cx - 4 + i * 7
		surface.DrawLine(ox - 3, cy - 5, ox + 2, cy)
		surface.DrawLine(ox + 2, cy, ox - 3, cy + 5)
	end
end

local function drawReveal(anim, t, cx, cy, now)
	local k = (t - GATHER_TIME) / REVEAL_TIME
	local grow = easeOut(math.min(1, k * 3))
	local alpha = 255 * (1 - math.Clamp((k - 0.7) / 0.3, 0, 1))
	local recipe = X.Recipes[anim.recipe]
	local isCoin = recipe.give == "coins"
	local icon = isCoin and ArtDeco.Icons.coin or ArtDeco.Icons.shard
	local col = isCoin and ArtDeco.Colors.coinGold or ArtDeco.Colors.shardBlue
	local rise = 60 * easeOut(k)

	local count = anim.gained > 0 and (isCoin and math.min(anim.gained, 7) or 1) or 0
	for i = 1, count do
		local spread = count > 1 and ((i - 1) / (count - 1) - 0.5) or 0
		local ix = cx + spread * 150 * grow
		local iy = cy - rise + math.abs(spread) * 30 * grow
		local size = 52 * grow * (count > 1 and 0.7 or 1)
		drawGlow(ix, iy, size * 2.4, col, alpha * 0.5)
		surface.SetMaterial(icon)
		surface.SetDrawColor(col.r, col.g, col.b, alpha)
		surface.DrawTexturedRectRotated(ix, iy, size, size, isCoin and 0 or math.sin(now * 2) * 8)
	end

	local shadow = Color(0, 0, 0, alpha * 0.8)
	draw.SimpleTextOutlined("+" .. string.Comma(anim.gained), "Arcana_AncientLarge", cx, cy - rise + 46 * grow, ColorAlpha(anim.gained > 0 and col or ArtDeco.Colors.textDim, alpha), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, 1, shadow)

	local diff = anim.gained - anim.times
	local segments
	if not anim.success then
		segments = {{text = "FAILED"}, {text = "-" .. string.Comma(-diff), icon = icon}}
		segments[1].color, segments[2].color = ColorAlpha(COLOR_FAIL, alpha), ColorAlpha(COLOR_FAIL, alpha)
	elseif diff > 0 then
		segments = {{text = "PERFECT", color = ColorAlpha(ArtDeco.Colors.paleGold, alpha)}, {text = "+" .. string.Comma(diff), icon = icon, color = ColorAlpha(col, alpha)}}
	else
		segments = {{text = "NO BONUS", color = ColorAlpha(ArtDeco.Colors.textDim, alpha)}}
	end
	local _, th = ArtDeco.MeasureCostLine("Arcana_Ancient", segments)
	ArtDeco.DrawCostLine("Arcana_Ancient", cx, cy - rise + 80 * grow - th * 0.5, segments, TEXT_ALIGN_CENTER)
end

local function drawStage(state, x, y, w, h)
	local now = RealTime()
	local dt = math.min(RealFrameTime(), 0.1)
	local cx, cy = x + w * 0.5, y + h * 0.5
	local playing = state.game ~= nil
	local dim = playing and 0.35 or 1

	local bw, bh = w * BACK_SCALE, h * BACK_SCALE
	local bx, by = cx - bw * 0.5, cy - bh * 0.5

	ArtDeco.FillDecoPanel(x, y, w, h, COLOR_INTERIOR, 14)
	ArtDeco.FillDecoPanel(bx, by, bw, bh, COLOR_BACKWALL, 8)

	local anim = state.anim
	local t = anim and (now - anim.start) or math.huge
	if t > GATHER_TIME + REVEAL_TIME then
		state.anim = nil
		anim = nil
	end

	local pulse = 0.85 + 0.15 * math.sin(now * 2.2)
	local flash = 0
	if anim and t >= GATHER_TIME then
		flash = math.max(0, 1 - (t - GATHER_TIME) / 0.4)
	end
	local charge = anim and t < GATHER_TIME and easeIn(t / GATHER_TIME) or 0
	local core = anim and not anim.success and COLOR_FAIL or COLOR_MANA

	drawGlow(cx, cy, bw * 2.2 * pulse + 260 * flash, core, (60 + 80 * charge + 120 * flash) * dim)
	drawGlow(cx, cy, bw * 0.9 * pulse + 120 * flash, core, (150 + 100 * charge + 105 * flash) * dim)

	for k = 1, 3 do
		local s = 1 - (1 - BACK_SCALE) * (k / 4)
		local rw, rh = w * s, h * s
		ArtDeco.DrawDecoFrame(cx - rw * 0.5, cy - rh * 0.5, rw, rh, ColorAlpha(ArtDeco.Colors.gold, (30 + 15 * k) * dim), math.max(8, 14 * s))
	end

	ArtDeco.DrawDecoFrame(bx, by, bw, bh, ColorAlpha(ArtDeco.Colors.gold, 150 * dim), 8)

	local inset = 5
	local front = {{x + inset, y + inset}, {x + w - inset, y + inset}, {x + w - inset, y + h - inset}, {x + inset, y + h - inset}}
	local back = {{bx + 3, by + 3}, {bx + bw - 3, by + 3}, {bx + bw - 3, by + bh - 3}, {bx + 3, by + bh - 3}}
	for i = 1, 4 do
		surface.SetDrawColor(ArtDeco.Colors.brassInner.r, ArtDeco.Colors.brassInner.g, ArtDeco.Colors.brassInner.b, 220 * dim)
		surface.DrawLine(front[i][1], front[i][2], back[i][1], back[i][2])
		surface.SetDrawColor(ArtDeco.Colors.gold.r, ArtDeco.Colors.gold.g, ArtDeco.Colors.gold.b, 70 * dim)
		local ny = i <= 2 and 1 or -1
		surface.DrawLine(front[i][1], front[i][2] + ny, back[i][1], back[i][2] + ny)
	end

	local want = math.Clamp(6 + math.floor(dustCount() / 4), 6, 70)
	local motes = state.motes
	while #motes < want do motes[#motes + 1] = newMote(true) end
	while #motes > want do motes[#motes] = nil end

	for _, m in ipairs(motes) do
		m.u = m.u + (m.du + math.sin(now * 0.7 + m.phase) * 0.02) * dt
		m.v = m.v + m.dv * dt
		m.d = m.d + m.dd * dt
		if m.u < -0.95 or m.u > 0.95 then m.du = -m.du m.u = math.Clamp(m.u, -0.95, 0.95) end
		if m.d < 0 or m.d > 1 then m.dd = -m.dd m.d = math.Clamp(m.d, 0, 1) end
		if m.v < -0.95 then
			m.v = 0.95
			m.born = now
		end

		local s = depthScale(m.d)
		local px = cx + m.u * w * 0.5 * s
		local py = cy + m.v * h * 0.5 * s
		local fade = math.min(1, (now - m.born) / 0.8)
		local alpha = (90 + 140 * s) * fade * dim

		if anim then
			if t < GATHER_TIME then
				local pull = easeIn(t / GATHER_TIME)
				local ox, oy = px - cx, py - cy
				local ang = pull * 4
				local c, sn = math.cos(ang), math.sin(ang)
				px = cx + (ox * c - oy * sn) * (1 - pull)
				py = cy + (ox * sn + oy * c) * (1 - pull)
				alpha = alpha * (1 - pull * 0.5)
			else
				alpha = alpha * math.Clamp((t - GATHER_TIME) / 0.6, 0, 1)
			end
		end

		local twinkle = 0.75 + 0.25 * math.sin(now * 3 + m.phase)
		drawGlow(px, py, m.size * s * 2.2 * twinkle, COLOR_DUST, alpha * 0.5)
		drawGlow(px, py, m.size * s * twinkle, color_white, alpha * 0.6)
	end

	if anim and t >= GATHER_TIME then
		drawReveal(anim, t, cx, cy, now)
	end

	draw.NoTexture()
	surface.SetDrawColor(255, 240, 210, 10)
	surface.DrawPoly({{x = x + 30, y = y + 6}, {x = x + 150, y = y + 6}, {x = x + 6, y = y + 150}, {x = x + 6, y = y + 30}})
	surface.DrawPoly({{x = x + 180, y = y + 6}, {x = x + 210, y = y + 6}, {x = x + 6, y = y + 210}, {x = x + 6, y = y + 180}})

	ArtDeco.DrawDecoFrame(x, y, w, h, ArtDeco.Colors.gold, 14)
	ArtDeco.DrawDecoFrame(x + 4, y + 4, w - 8, h - 8, ColorAlpha(ArtDeco.Colors.brassInner, 160), 11)

	if not playing then
		draw.SimpleText("CRYSTAL DUST", "Arcana_AncientSmall", cx, y + h - 46, ColorAlpha(ArtDeco.Colors.textDim, 220), TEXT_ALIGN_CENTER)
		draw.SimpleTextOutlined(string.Comma(dustCount()), "Arcana_AncientLarge", cx, y + h - 30, COLOR_DUST, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP, 1, Color(0, 0, 0, 180))
	end
end

local function sendInput(id, abort, values)
	net.Start("Arcana_Condensator_Input")
	net.WriteUInt(id, 16)
	net.WriteBool(abort)
	if not abort then
		net.WriteUInt(#values, 3)
		for _, v in ipairs(values) do net.WriteInt(v, 16) end
	end
	net.SendToServer()
end

local function drawGameChrome(g, w, h, now)
	draw.SimpleText(string.upper(g.def.name), "Arcana_Ancient", w * 0.5, 14, ArtDeco.Colors.paleGold, TEXT_ALIGN_CENTER)
	draw.SimpleText(g.def.hint, "Arcana_AncientSmall", w * 0.5, 36, ArtDeco.Colors.textDim, TEXT_ALIGN_CENTER)

	local elapsed = now - g.start
	local barW, barH = math.floor(w * 0.46), 4
	local bx, by = math.floor((w - barW) * 0.5), h - 26
	local lead = g.timing.lead
	local remain = elapsed < lead and 1 or math.Clamp(1 - (elapsed - lead) / (g.timing.timeout - lead), 0, 1)

	surface.SetDrawColor(60, 46, 34, 220)
	surface.DrawRect(bx, by, barW, barH)
	surface.SetDrawColor(ArtDeco.Colors.xpFill)
	surface.DrawRect(bx, by, math.floor(barW * remain), barH)

	if g.done then
		draw.SimpleText("SETTLING", "Arcana_AncientSmall", w * 0.5, by - 16, ColorAlpha(ArtDeco.Colors.paleGold, 150 + 100 * math.sin(now * 6)), TEXT_ALIGN_CENTER)
	elseif elapsed >= lead then
		local pct = math.Round(SUCCESS_BONUS * X.SpeedFrac(g.timing, elapsed - lead))
		local bonus = X.BonusAmount(g.times, pct)
		local isCoin = X.Recipes[g.recipe].give == "coins"
		local col = bonus > 0 and (isCoin and ArtDeco.Colors.coinGold or ArtDeco.Colors.shardBlue) or ArtDeco.Colors.textDim
		local seg = {{text = "+" .. string.Comma(bonus), icon = isCoin and ArtDeco.Icons.coin or ArtDeco.Icons.shard, color = col}}
		local _, th = ArtDeco.MeasureCostLine("Arcana_AncientSmall", seg)
		ArtDeco.DrawCostLine("Arcana_AncientSmall", bx + barW + 12, by + barH * 0.5 - th * 0.5, seg, TEXT_ALIGN_LEFT)
	end
end

local function endGame(state)
	local g = state.game
	if not g then return end
	if IsValid(g.panel) then g.panel:Remove() end
	state.game = nil
end

local function startGame(frame, id, gameIndex, recipe, times, public)
	local state = frame._state
	local def = X.Games[gameIndex]
	local sw = frame:GetWide() - STAGE_X * 2

	endGame(state)

	local g = {
		id = id,
		recipe = recipe,
		times = times,
		def = def,
		params = public,
		timing = def.timing(public),
		start = RealTime(),
		w = sw,
		h = STAGE_H,
	}
	g.send = function(values)
		if g.done then return end
		sendInput(g.id, false, values)
	end
	g.settle = function()
		g.done = true
	end

	def.client.init(g)
	state.game = g

	local pnl = vgui.Create("DPanel", frame)
	pnl:SetPos(STAGE_X, STAGE_Y)
	pnl:SetSize(sw, STAGE_H)
	g.panel = pnl

	pnl.Paint = function(p, w, h)
		local mx, my = p:CursorPos()
		local now = RealTime()
		def.client.draw(g, now, mx, my)
		drawGameChrome(g, w, h, now)
	end

	pnl.OnMousePressed = function(p, code)
		if g.done or not def.client.press then return end
		local mx, my = p:CursorPos()
		def.client.press(g, code, mx, my, RealTime())
	end

	local last = RealTime()
	pnl.Think = function(p)
		local now = RealTime()
		local dt = math.min(now - last, 0.1)
		last = now
		if g.done then return end

		if now - g.start > g.timing.timeout then
			sendInput(g.id, true)
			g.settle()
			return
		end

		if def.client.think then
			local mx, my = p:CursorPos()
			def.client.think(g, now, dt, mx, my, p:IsHovered() and input.IsMouseDown(MOUSE_LEFT))
		end
	end
end

local function requestConvert(state, index, times)
	if times < 1 or isBusy(state) then return end

	net.Start("Arcana_Condensator_Convert")
	net.WriteUInt(index, 2)
	net.WriteUInt(math.min(times, MAX_TIMES), 14)
	net.SendToServer()

	state.busyUntil = RealTime() + 3
	surface.PlaySound("ambient/energy/zap" .. math.random(1, 3) .. ".wav")
end

local function makeButton(parent, state, label, index, timesFn)
	local btn = vgui.Create("DButton", parent)
	btn:SetText("")

	btn.Paint = function(pnl, w, h)
		local enabled = timesFn() >= 1 and not isBusy(state)
		local hovered = enabled and pnl:IsHovered()
		ArtDeco.FillDecoPanel(0, 0, w, h, hovered and ArtDeco.Colors.cardHover or ArtDeco.Colors.cardIdle, 8)
		ArtDeco.DrawDecoFrame(0, 0, w, h, enabled and (hovered and ArtDeco.Colors.paleGold or ArtDeco.Colors.gold) or ColorAlpha(ArtDeco.Colors.brassInner, 90), 8)
		local col = enabled and (hovered and ArtDeco.Colors.textBright or ArtDeco.Colors.paleGold) or ColorAlpha(ArtDeco.Colors.textDim, 90)
		draw.SimpleText(label, "Arcana_Ancient", w * 0.5, h * 0.5, col, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
	end

	btn.DoClick = function()
		requestConvert(state, index, timesFn())
	end

	return btn
end

local function buildCard(parent, state, index)
	local recipe = X.Recipes[index]
	local card = vgui.Create("DPanel", parent)

	local function affordable()
		return math.floor(dustCount() / recipe.cost)
	end

	local buttons = {
		makeButton(card, state, "x1", index, function() return math.min(1, affordable()) end),
		makeButton(card, state, "x10", index, function() return affordable() >= 10 and 10 or 0 end),
		makeButton(card, state, "MAX", index, affordable),
	}

	local pad = 14
	local buttonsW = BUTTON_W * 3 + BUTTON_GAP * 2

	card.Paint = function(_, w, h)
		ArtDeco.FillDecoPanel(0, 0, w, h, ArtDeco.Colors.decoPanel, 10)
		ArtDeco.DrawDecoFrame(0, 0, w, h, ArtDeco.Colors.gold, 10)

		local isCoin = recipe.give == "coins"
		local outCol = isCoin and ArtDeco.Colors.coinGold or ArtDeco.Colors.shardBlue
		local outIcon = isCoin and ArtDeco.Icons.coin or ArtDeco.Icons.shard

		local _, th = ArtDeco.MeasureCostLine("Arcana_Ancient", {{text = "0"}})
		local lineY = math.floor((h - th) * 0.5)
		local rx = ArtDeco.DrawCostLine("Arcana_Ancient", pad + 4, lineY, {{text = recipe.cost .. " DUST", color = COLOR_DUST}}, TEXT_ALIGN_LEFT)
		drawChevron(rx + 14, lineY + th * 0.5, ArtDeco.Colors.paleGold)
		ArtDeco.DrawCostLine("Arcana_Ancient", rx + 28, lineY, {{text = "1", icon = outIcon, color = outCol}}, TEXT_ALIGN_LEFT)
	end

	card.PerformLayout = function(_, w, h)
		local bx = w - pad - buttonsW
		local by = math.floor((h - BUTTON_H) * 0.5)
		for i, btn in ipairs(buttons) do
			btn:SetPos(bx + (i - 1) * (BUTTON_W + BUTTON_GAP), by)
			btn:SetSize(BUTTON_W, BUTTON_H)
		end
	end

	return card
end

function X.OpenMenu()
	if IsValid(frameRef) then
		frameRef:MakePopup()
		return
	end

	local frame = vgui.Create("DFrame")
	frameRef = frame
	frame:SetSize(FRAME_W, FRAME_H)
	frame:Center()
	frame:SetTitle("")
	frame:MakePopup()
	frame._state = {motes = {}}
	local state = frame._state

	ArtDeco.MakeDraggableByBand(frame, 44)
	if IsValid(frame.btnMinim) then frame.btnMinim:Hide() end
	if IsValid(frame.btnMaxim) then frame.btnMaxim:Hide() end

	hook.Add("HUDPaint", frame, function()
		local fx, fy = frame:LocalToScreen(0, 0)
		ArtDeco.DrawBlurRect(fx + 6, fy + 6, frame:GetWide() - 12, frame:GetTall() - 12, 4, 8)
	end)

	frame.Paint = function(pnl, w, h)
		ArtDeco.FillDecoPanel(6, 6, w - 12, h - 12, ArtDeco.Colors.decoBg, 14)
		ArtDeco.DrawDecoFrame(6, 6, w - 12, h - 12, ArtDeco.Colors.gold, 14)
		local right = ArtDeco.DrawTitle("Arcana_AncientLarge", "CONDENSATOR", 7, STAGE_Y, ArtDeco.Colors.paleGold)
		right = ArtDeco.DrawChip("Arcana_AncientSmall", string.Comma(heldCount(X.Recipes[1])), right + 14, 7, STAGE_Y, ArtDeco.Colors.cardIdle, ArtDeco.Colors.shardBlue, ArtDeco.Icons.shard)
		ArtDeco.DrawChip("Arcana_AncientSmall", string.Comma(heldCount(X.Recipes[2])), right + 8, 7, STAGE_Y, ArtDeco.Colors.cardIdle, ArtDeco.Colors.coinGold, ArtDeco.Icons.coin)

		local sx, sy = pnl:LocalToScreen(STAGE_X, STAGE_Y)
		local sw = w - STAGE_X * 2
		render.SetScissorRect(sx, sy, sx + sw, sy + STAGE_H, true)
		drawStage(state, STAGE_X, STAGE_Y, sw, STAGE_H)
		render.SetScissorRect(0, 0, 0, 0, false)
	end

	frame.Think = function(pnl)
		local ply = LocalPlayer()
		local wep = IsValid(ply) and ply:GetActiveWeapon()
		if not IsValid(ply) or not ply:Alive() or not IsValid(wep) or wep:GetClass() ~= "arcana_condensator" then
			pnl:Close()
		end
	end

	frame.OnRemove = function()
		local g = state.game
		if g and not g.done then sendInput(g.id, true) end
	end

	local cards = {buildCard(frame, state, 1), buildCard(frame, state, 2)}

	ArtDeco.StyleCloseButton(frame, {
		layout = function(_, w)
			local top = STAGE_Y + STAGE_H + CARD_GAP
			for i, card in ipairs(cards) do
				card:SetPos(STAGE_X, top + (i - 1) * (ROW_H + CARD_GAP))
				card:SetSize(w - STAGE_X * 2, ROW_H)
			end
		end,
	})
end

net.Receive("Arcana_Condensator_OpenExchange", function()
	X.OpenMenu()
end)

net.Receive("Arcana_Condensator_Game", function()
	local id = net.ReadUInt(16)
	local gameIndex = net.ReadUInt(3)
	local recipe = net.ReadUInt(2)
	local times = net.ReadUInt(14)
	local public = net.ReadTable()

	if not IsValid(frameRef) or not X.Games[gameIndex] or not X.Recipes[recipe] then
		sendInput(id, true)
		return
	end

	net.Start("Arcana_Condensator_Ack", true)
	net.WriteUInt(id, 16)
	net.SendToServer()

	startGame(frameRef, id, gameIndex, recipe, times, public)
end)

net.Receive("Arcana_Condensator_Converted", function()
	local index = net.ReadUInt(2)
	local times = net.ReadUInt(14)
	local success = net.ReadBool()
	local pct = net.ReadInt(8)
	local gained = net.ReadUInt(16)

	if IsValid(frameRef) then
		local state = frameRef._state
		endGame(state)
		state.busyUntil = 0
		state.anim = {start = RealTime(), recipe = index, times = times, gained = gained, success = success, pct = pct}
	end

	if not success then
		surface.PlaySound("ambient/energy/spark6.wav")
	elseif X.Recipes[index] and X.Recipes[index].give == "coins" then
		surface.PlaySound("ambient/levels/labs/coinslot1.wav")
	else
		surface.PlaySound("arcana/arcane_" .. math.random(1, 3) .. ".ogg")
	end
end)
