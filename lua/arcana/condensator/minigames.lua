Arcana = Arcana or {}
Arcana.CondensatorExchange = Arcana.CondensatorExchange or {}

local X = Arcana.CondensatorExchange

local function angleDiff(a, b)
	return math.abs((a - b + 180) % 360 - 180)
end

local function shuffled(n)
	local out = {}
	for i = 1, n do out[i] = i end
	for i = n, 2, -1 do
		local j = math.random(1, i)
		out[i], out[j] = out[j], out[i]
	end

	return out
end

local function isInt(v, lo, hi)
	return isnumber(v) and v == math.floor(v) and v >= lo and v <= hi
end

function X.SpeedFrac(timing, t)
	return math.Clamp((timing.slow - t) / (timing.slow - timing.fast), 0, 1)
end

local TUNE_TOLERANCE = 12
local TUNE_HOLD = 0.7
local TUNE_GAP = 0.3
local SPARK_PERIOD = 2.4
local SPARK_WINDOW = 18
local SPARK_CLOCK_SLACK = 0.12
local ECHO_STEP = 0.6
local ECHO_LENGTH = 5
local RING_COUNT = 3
local RING_NOTCHES = 8

local function tuneSignal(diff)
	return math.Clamp(1 - diff / 70, 0, 1) ^ 2
end

local function sparkPar(p)
	local t = 0
	for i = 1, #p.order do
		local a = p.nodes[p.order[i]]
		local nextT = (math.floor(t / SPARK_PERIOD) + a / 360) * SPARK_PERIOD
		if nextT < t + 0.05 then nextT = nextT + SPARK_PERIOD end
		t = nextT
	end

	return t
end

local function ringOffset(init, moves, k)
	return (init[k] + (moves[k] or 0) + (moves[k - 1] or 0)) % RING_NOTCHES
end

local function ringsAligned(init, moves)
	for k = 1, RING_COUNT do
		if ringOffset(init, moves, k) ~= 0 then return false end
	end

	return true
end

X.Games = {
	{
		name = "Resonance",
		hint = "Sweep the ring, hold click where the signal peaks",
		timing = function()
			return {fast = 2.5, slow = 9, timeout = 20, lead = 0}
		end,
		generate = function()
			return {target = math.random(0, 359)}, {}
		end,
		input = function(st, v, now)
			if not isInt(v[1], 0, 3599) or not isInt(v[2], 0, 1) then return "ignore" end

			local diff = angleDiff(v[1] / 10, st.secret.target)
			local gap = now - (st.lastInput or now)
			st.lastInput = now

			if v[2] == 1 and diff <= TUNE_TOLERANCE then
				if not st.holdStart or gap > TUNE_GAP then st.holdStart = now end
				if now - st.holdStart >= TUNE_HOLD then return "success" end
			else
				st.holdStart = nil
			end

			return "continue", math.Round(tuneSignal(diff) * 255)
		end,
	},
	{
		name = "Cipher",
		hint = "Pick the glyphs in the order shown above",
		timing = function()
			return {fast = 3.5, slow = 10, timeout = 20, lead = 0}
		end,
		generate = function()
			local pool = shuffled(8)
			local target = {pool[1], pool[2], pool[3], pool[4]}
			local grid = {}
			local spots = shuffled(12)
			for i = 1, 4 do grid[spots[i]] = target[i] end
			for i = 1, 12 do grid[i] = grid[i] or math.random(1, 8) end
			local pub = {target = target, grid = grid}

			return pub, pub
		end,
		input = function(st, v)
			local cell = v[1]
			if not isInt(cell, 1, 12) then return "ignore" end

			st.step = st.step or 1
			st.used = st.used or {}
			if st.used[cell] then return "ignore" end
			if st.public.grid[cell] ~= st.public.target[st.step] then return "fail" end

			st.used[cell] = true
			st.step = st.step + 1

			return st.step > 4 and "success" or "continue"
		end,
	},
	{
		name = "Ring Lock",
		hint = "Click a ring to turn it, right click turns it back. Each ring drags the next",
		timing = function()
			return {fast = 5, slow = 15, timeout = 30, lead = 0}
		end,
		generate = function()
			local init = {}
			for k = 1, RING_COUNT do init[k] = math.random(0, RING_NOTCHES - 1) end
			if ringsAligned(init, {}) then init[1] = math.random(1, RING_NOTCHES - 1) end
			local pub = {init = init}

			return pub, pub
		end,
		input = function(st, v)
			if not isInt(v[1], 1, RING_COUNT) or (v[2] ~= 1 and v[2] ~= -1) then return "ignore" end

			st.moves = st.moves or {0, 0, 0}
			st.moves[v[1]] = st.moves[v[1]] + v[2]

			return ringsAligned(st.public.init, st.moves) and "success" or "continue"
		end,
	},
	{
		name = "Spark Strike",
		hint = "Click as the spark crosses each lit rune, in order",
		timing = function(p)
			local par = sparkPar(p)

			return {fast = par + 0.25, slow = par + SPARK_PERIOD * 2, timeout = par + SPARK_PERIOD * 4, lead = 0}
		end,
		generate = function()
			local nodes = {}
			while #nodes < 3 do
				local a = math.random(40, 320)
				local ok = true
				for _, b in ipairs(nodes) do
					if angleDiff(a, b) < 60 then ok = false break end
				end
				if ok then nodes[#nodes + 1] = a end
			end
			local pub = {nodes = nodes, order = shuffled(3)}

			return pub, pub
		end,
		input = function(st, v, now, ping)
			if not isInt(v[1], 0, 32000) then return "ignore" end

			local t = v[1] / 1000
			local expected = now - st.start - ping
			if math.abs(t - expected) > SPARK_CLOCK_SLACK + ping * 0.5 then return "fail" end
			if t <= (st.lastT or 0) then return "fail" end
			st.lastT = t

			st.step = st.step or 1
			local node = st.public.nodes[st.public.order[st.step]]
			if angleDiff((t / SPARK_PERIOD * 360) % 360, node) > SPARK_WINDOW + 3 then return "fail" end

			st.step = st.step + 1

			return st.step > 3 and "success" or "continue"
		end,
	},
	{
		name = "Echo",
		hint = "Watch the runes, then repeat the sequence",
		timing = function()
			local lead = ECHO_LENGTH * ECHO_STEP + 0.6

			return {fast = 3, slow = 8, timeout = lead + 15, lead = lead}
		end,
		generate = function()
			local pool = shuffled(8)
			local runes = {pool[1], pool[2], pool[3], pool[4], pool[5], pool[6]}
			local seq = {}
			for i = 1, ECHO_LENGTH do
				local pick
				repeat pick = math.random(1, 6) until pick ~= seq[i - 1]
				seq[i] = pick
			end
			local pub = {runes = runes, seq = seq}

			return pub, pub
		end,
		input = function(st, v, now, ping)
			if not isInt(v[1], 1, 6) then return "ignore" end
			if now - st.start - ping < st.timing.lead - 0.15 then return "ignore" end

			st.step = st.step or 1
			if v[1] ~= st.public.seq[st.step] then return "fail" end
			st.step = st.step + 1

			return st.step > ECHO_LENGTH and "success" or "continue"
		end,
	},
}

if SERVER then return end

local GLOW = Material("sprites/light_glow02_add")
local COLOR_DUST = Color(120, 200, 255)
local COLOR_FAIL = Color(232, 110, 90)
local gold = Color(198, 160, 74, 255)
local pale = Color(222, 198, 120, 255)
local brass = Color(160, 130, 60, 220)

local GLYPHS = {}
for i = 1, 8 do
	GLYPHS[i] = CreateMaterial("arcana_condensator_glyph_" .. i, "UnlitGeneric", {
		["$basetexture"] = "arcana/glyphs/glyph_" .. (64 + i),
		["$translucent"] = 1,
		["$vertexcolor"] = 1,
		["$vertexalpha"] = 1,
	})
end

local function glow(x, y, size, col, alpha)
	surface.SetMaterial(GLOW)
	surface.SetDrawColor(col.r, col.g, col.b, alpha)
	surface.DrawTexturedRect(x - size * 0.5, y - size * 0.5, size, size)
end

local function glyph(id, x, y, size, col, alpha, rot)
	surface.SetMaterial(GLYPHS[id])
	surface.SetDrawColor(col.r, col.g, col.b, alpha or 255)
	surface.DrawTexturedRectRotated(x, y, size, size, rot or 0)
end

local function polar(cx, cy, r, rel)
	local rad = math.rad(rel - 90)

	return cx + math.cos(rad) * r, cy + math.sin(rad) * r
end

local function relAngle(cx, cy, x, y)
	return (math.deg(math.atan2(y - cy, x - cx)) + 90) % 360
end

local function arc(cx, cy, r, from, to, col, thick)
	surface.SetDrawColor(col)
	local steps = math.max(2, math.ceil(math.abs(to - from) / 6))
	for t = 0, (thick or 1) - 1 do
		local px, py = polar(cx, cy, r + t, from)
		for i = 1, steps do
			local nx, ny = polar(cx, cy, r + t, from + (to - from) * i / steps)
			surface.DrawLine(px, py, nx, ny)
			px, py = nx, ny
		end
	end
end

local function ticks(cx, cy, r, count, col, len, emphasize)
	for i = 0, count - 1 do
		local rel = i * 360 / count
		local boost = emphasize and emphasize(rel) or 0
		local x1, y1 = polar(cx, cy, r, rel)
		local x2, y2 = polar(cx, cy, r + len + boost * 8, rel)
		surface.SetDrawColor(col.r, col.g, col.b, math.min(255, (col.a or 255) + boost * 200))
		surface.DrawLine(x1, y1, x2, y2)
	end
end

local function geometry(g)
	local cx, cy = g.w * 0.5, g.h * 0.5 + 8
	local r = math.min(g.w, g.h) * 0.33

	return cx, cy, r
end

X.Games[1].client = {
	init = function(g)
		g.angle, g.signal, g.serverSignal, g.hold, g.nextSend = 0, 0, 0, 0, 0
	end,
	signal = function(g, value)
		g.serverSignal = value / 255
	end,
	think = function(g, now, dt, mx, my, held)
		local cx, cy = geometry(g)
		g.angle = relAngle(cx, cy, mx, my)
		g.signal = Lerp(math.min(1, dt * 10), g.signal, g.serverSignal)

		if held and g.serverSignal >= tuneSignal(TUNE_TOLERANCE) then
			g.hold = math.min(TUNE_HOLD, g.hold + dt)
		else
			g.hold = math.max(0, g.hold - dt * 2)
		end

		if now >= g.nextSend then
			g.nextSend = now + 0.05
			g.send({math.Round(g.angle * 10) % 3600, held and 1 or 0})
		end
	end,
	draw = function(g, now)
		local cx, cy, r = geometry(g)
		local s = g.signal

		arc(cx, cy, r, 0, 360, ColorAlpha(brass, 160), 2)
		ticks(cx, cy, r + 4, 48, ColorAlpha(gold, 60), 6, function(rel)
			return math.Clamp(1 - angleDiff(rel, g.angle) / 25, 0, 1) * (0.3 + 0.7 * s)
		end)

		local amp = r * 0.22
		local x0, x1 = cx - r * 0.75, cx + r * 0.75
		local px, py
		surface.SetDrawColor(COLOR_DUST.r, COLOR_DUST.g, COLOR_DUST.b, 120 + 135 * s)
		for i = 0, 72 do
			local x = x0 + (x1 - x0) * i / 72
			local env = math.sin(math.pi * i / 72)
			local clean = math.sin(i * 0.42 + now * 9) * (0.25 + 0.75 * s)
			local noise = math.sin(i * 2.7 + now * 31) * math.sin(i * 1.3 + now * 17) * (1 - s)
			local y = cy + (clean + noise) * amp * env
			if px then surface.DrawLine(px, py, x, y) end
			px, py = x, y
		end

		glow(cx, cy, r * (0.8 + 1.4 * s), COLOR_DUST, 40 + 160 * s)

		local nx, ny = polar(cx, cy, r, g.angle)
		surface.SetDrawColor(pale.r, pale.g, pale.b, 120 + 135 * s)
		surface.DrawLine(cx, cy, nx, ny)
		glow(nx, ny, 26 + 40 * s, pale, 120 + 135 * s)

		if g.hold > 0 then
			arc(cx, cy, r + 14, g.angle - 20, g.angle - 20 + 40 * (g.hold / TUNE_HOLD), pale, 3)
		end
	end,
}

local CELL, CELL_GAP = 58, 10
local SLOT = 44

local function cipherTop(g)
	return math.floor((g.h - (SLOT + 18 + CELL * 3 + CELL_GAP * 2)) * 0.5) + 10
end

local function cipherCell(g, i)
	local cols = 4
	local gw = cols * CELL + (cols - 1) * CELL_GAP
	local x0 = (g.w - gw) * 0.5
	local y0 = cipherTop(g) + SLOT + 18
	local col, row = (i - 1) % cols, math.floor((i - 1) / cols)

	return x0 + col * (CELL + CELL_GAP), y0 + row * (CELL + CELL_GAP)
end

X.Games[2].client = {
	init = function(g)
		g.step, g.used = 1, {}
	end,
	press = function(g, code, mx, my)
		if code ~= MOUSE_LEFT then return end
		for i = 1, 12 do
			local x, y = cipherCell(g, i)
			if mx >= x and mx < x + CELL and my >= y and my < y + CELL then
				if g.used[i] then return end
				g.send({i})

				if g.params.grid[i] ~= g.params.target[g.step] then
					g.wrong = i
					g.settle()
					return
				end

				g.used[i] = g.step
				g.step = g.step + 1
				surface.PlaySound("buttons/blip1.wav")
				if g.step > 4 then g.settle() end
				return
			end
		end
	end,
	draw = function(g, now, mx, my)
		local gap = 12
		local sx0 = (g.w - (SLOT * 4 + gap * 3)) * 0.5
		local sy = cipherTop(g)
		for i = 1, 4 do
			local x = sx0 + (i - 1) * (SLOT + gap)
			local done = i < g.step
			local current = i == g.step
			ArtDeco.FillDecoPanel(x, sy, SLOT, SLOT, ArtDeco.Colors.cardIdle, 8)
			ArtDeco.DrawDecoFrame(x, sy, SLOT, SLOT, current and pale or (done and gold or ColorAlpha(brass, 120)), 8)
			local a = done and 255 or (current and (170 + 85 * math.sin(now * 6)) or 110)
			glyph(g.params.target[i], x + SLOT * 0.5, sy + SLOT * 0.5, SLOT - 12, done and COLOR_DUST or pale, a)
		end

		for i = 1, 12 do
			local x, y = cipherCell(g, i)
			local hovered = mx >= x and mx < x + CELL and my >= y and my < y + CELL
			local used = g.used[i]
			local flicker = 0.85 + 0.15 * math.sin(now * 13 + i * 2.3) * math.sin(now * 7 + i)
			local wrong = g.wrong == i

			ArtDeco.FillDecoPanel(x, y, CELL, CELL, hovered and not used and ArtDeco.Colors.cardHover or ArtDeco.Colors.cardIdle, 8)
			ArtDeco.DrawDecoFrame(x, y, CELL, CELL, wrong and COLOR_FAIL or (used and COLOR_DUST or (hovered and pale or ColorAlpha(gold, 140))), 8)
			if used then glow(x + CELL * 0.5, y + CELL * 0.5, CELL * 1.4, COLOR_DUST, 70) end
			glyph(g.params.grid[i], x + CELL * 0.5, y + CELL * 0.5, CELL - 16, wrong and COLOR_FAIL or (used and COLOR_DUST or pale), 255 * flicker * (used and 1 or 0.85))
		end
	end,
}

local function ringRadius(r, k)
	return r * (0.36 + 0.3 * (k - 1))
end

X.Games[3].client = {
	init = function(g)
		g.moves = {0, 0, 0}
		g.disp = {}
		for k = 1, RING_COUNT do g.disp[k] = g.params.init[k] end
	end,
	press = function(g, code, mx, my)
		if code ~= MOUSE_LEFT and code ~= MOUSE_RIGHT then return end
		local cx, cy, r = geometry(g)
		local dist = math.sqrt((mx - cx) ^ 2 + (my - cy) ^ 2)
		local pick, best
		for k = 1, RING_COUNT do
			local d = math.abs(dist - ringRadius(r, k))
			if d < 22 and (not best or d < best) then pick, best = k, d end
		end
		if not pick then return end

		local dir = code == MOUSE_LEFT and 1 or -1
		g.moves[pick] = g.moves[pick] + dir
		g.send({pick, dir})
		surface.PlaySound("buttons/lightswitch2.wav")

		if ringsAligned(g.params.init, g.moves) then g.settle() end
	end,
	think = function(g, now, dt)
		for k = 1, RING_COUNT do
			local target = g.params.init[k] + g.moves[k] + (g.moves[k - 1] or 0)
			g.disp[k] = Lerp(math.min(1, dt * 12), g.disp[k], target)
		end
	end,
	draw = function(g, now, mx, my)
		local cx, cy, r = geometry(g)
		local dist = math.sqrt((mx - cx) ^ 2 + (my - cy) ^ 2)

		surface.SetDrawColor(gold.r, gold.g, gold.b, 50)
		surface.DrawLine(cx, cy, cx, cy - ringRadius(r, RING_COUNT) - 18)
		local tx, ty = cx, cy - ringRadius(r, RING_COUNT) - 20
		surface.SetDrawColor(pale)
		surface.DrawLine(tx - 7, ty - 8, tx, ty)
		surface.DrawLine(tx, ty, tx + 7, ty - 8)
		surface.DrawLine(tx - 7, ty - 8, tx + 7, ty - 8)

		for k = 1, RING_COUNT do
			local rr = ringRadius(r, k)
			local aligned = ringOffset(g.params.init, g.moves, k) == 0
			local hovered = not g.done and math.abs(dist - rr) < 22
			arc(cx, cy, rr, 0, 360, aligned and pale or (hovered and gold or ColorAlpha(brass, 150)), hovered and 2 or 1)

			for j = 0, RING_NOTCHES - 1 do
				local rel = (g.disp[k] + j) * (360 / RING_NOTCHES)
				local x, y = polar(cx, cy, rr, rel)
				local id = (j + k * 3) % 8 + 1
				if j == 0 then
					glow(x, y, 46, aligned and pale or COLOR_DUST, aligned and 200 or 140)
					glyph(id, x, y, 24, aligned and pale or COLOR_DUST, 255, rel)
				else
					glyph(id, x, y, 16, gold, 90, rel)
				end
			end
		end

		glow(cx, cy, r * 0.5, gold, 60 + 30 * math.sin(now * 2))
	end,
}

X.Games[4].client = {
	init = function(g)
		g.step = 1
	end,
	press = function(g, code, mx, my, now)
		if code ~= MOUSE_LEFT then return end
		local t = now - g.start
		g.send({math.Round(t * 1000)})

		local rel = (t / SPARK_PERIOD * 360) % 360
		local node = g.params.nodes[g.params.order[g.step]]
		if angleDiff(rel, node) > SPARK_WINDOW then
			g.missAt = rel
			g.settle()
			return
		end

		g.step = g.step + 1
		surface.PlaySound("ambient/energy/spark" .. math.random(1, 3) .. ".wav")
		if g.step > 3 then g.settle() end
	end,
	draw = function(g, now)
		local cx, cy, r = geometry(g)
		local t = now - g.start
		local rel = g.done and g.frozen or ((t / SPARK_PERIOD * 360) % 360)
		if not g.done then g.frozen = rel end

		arc(cx, cy, r, 0, 360, ColorAlpha(brass, 150), 2)
		ticks(cx, cy, r + 4, 36, ColorAlpha(gold, 50), 5)

		local current = g.params.order[g.step]
		if current and not g.done then
			local node = g.params.nodes[current]
			arc(cx, cy, r - 3, node - SPARK_WINDOW, node + SPARK_WINDOW, ColorAlpha(pale, 140 + 80 * math.sin(now * 8)), 7)
		end

		for idx, node in ipairs(g.params.nodes) do
			local x, y = polar(cx, cy, r, node)
			local orderPos = 1
			for i, o in ipairs(g.params.order) do if o == idx then orderPos = i end end
			local hit = orderPos < g.step
			local isCurrent = idx == current and not g.done
			ArtDeco.FillDecoPanel(x - 20, y - 20, 40, 40, ArtDeco.Colors.cardIdle, 8)
			ArtDeco.DrawDecoFrame(x - 20, y - 20, 40, 40, hit and COLOR_DUST or (isCurrent and pale or ColorAlpha(gold, 120)), 8)
			if hit or isCurrent then glow(x, y, 70, hit and COLOR_DUST or pale, isCurrent and (120 + 80 * math.sin(now * 8)) or 140) end
			glyph(idx + 1, x, y, 26, hit and COLOR_DUST or pale, (hit or isCurrent) and 255 or 110)
			local lx, ly = polar(cx, cy, r + 34, node)
			draw.SimpleText(tostring(orderPos), "Arcana_AncientSmall", lx, ly, hit and COLOR_DUST or (isCurrent and pale or ArtDeco.Colors.textDim), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		end

		for i = 6, 0, -1 do
			local x, y = polar(cx, cy, r, rel - i * 5)
			glow(x, y, 30 - i * 3, g.missAt and COLOR_FAIL or pale, 255 - i * 34)
		end
		local sx, sy = polar(cx, cy, r, rel)
		glow(sx, sy, 22, color_white, 255)
	end,
}

local function echoPos(g, i)
	local cx, cy, r = geometry(g)

	return polar(cx, cy, r * 0.82, (i - 1) * 60)
end

X.Games[5].client = {
	init = function(g)
		g.input, g.flash = {}, {}
	end,
	press = function(g, code, mx, my, now)
		if code ~= MOUSE_LEFT then return end
		if now - g.start < g.timing.lead then return end

		for i = 1, 6 do
			local x, y = echoPos(g, i)
			if (mx - x) ^ 2 + (my - y) ^ 2 <= 34 * 34 then
				g.flash[i] = now
				g.send({i})

				if i ~= g.params.seq[#g.input + 1] then
					g.wrong = i
					g.settle()
					return
				end

				g.input[#g.input + 1] = i
				surface.PlaySound("buttons/blip1.wav")
				if #g.input == ECHO_LENGTH then g.settle() end
				return
			end
		end
	end,
	draw = function(g, now, mx, my)
		local cx, cy, r = geometry(g)
		local t = now - g.start
		local playing = t < g.timing.lead
		local lit

		if playing then
			local step = (t - 0.3) / ECHO_STEP
			local idx = math.floor(step) + 1
			if idx >= 1 and idx <= ECHO_LENGTH and step - math.floor(step) < 0.72 then
				lit = g.params.seq[idx]
				if g.lastBeep ~= idx then
					g.lastBeep = idx
					surface.PlaySound("buttons/blip2.wav")
				end
			end
		end

		arc(cx, cy, r * 0.82, 0, 360, ColorAlpha(brass, 90), 1)

		for i = 1, 6 do
			local x, y = echoPos(g, i)
			local flash = g.flash[i] and math.Clamp(1 - (now - g.flash[i]) / 0.35, 0, 1) or 0
			local on = lit == i or flash > 0
			local hovered = not playing and not g.done and (mx - x) ^ 2 + (my - y) ^ 2 <= 34 * 34
			local col = g.wrong == i and COLOR_FAIL or (on and COLOR_DUST or pale)

			ArtDeco.FillDecoPanel(x - 30, y - 30, 60, 60, hovered and ArtDeco.Colors.cardHover or ArtDeco.Colors.cardIdle, 10)
			ArtDeco.DrawDecoFrame(x - 30, y - 30, 60, 60, on and COLOR_DUST or (hovered and pale or ColorAlpha(gold, 140)), 10)
			if on then glow(x, y, 110, COLOR_DUST, 200) end
			glyph(g.params.runes[i], x, y, 38, col, on and 255 or 150)
		end

		if playing then
			draw.SimpleText("WATCH", "Arcana_Ancient", cx, cy, ColorAlpha(pale, 160 + 60 * math.sin(now * 5)), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		else
			draw.SimpleText("REPEAT", "Arcana_Ancient", cx, cy - 10, pale, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
			for i = 1, ECHO_LENGTH do
				local dx = cx + (i - (ECHO_LENGTH + 1) * 0.5) * 14
				surface.SetDrawColor(i <= #g.input and COLOR_DUST or ColorAlpha(gold, 90))
				surface.DrawRect(dx - 3, cy + 12, 6, 6)
			end
		end
	end,
}
