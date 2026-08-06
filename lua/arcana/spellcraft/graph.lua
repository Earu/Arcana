-- Spellcraft star map: the Emissary's node graph.
--
-- Every component of a spell is a star on one pannable, zoomable chart set
-- against the Elysion nebula:
--   center   the spell itself (click it to review what you have built)
--   ring 1   the eight elements, orbiting closest
--   ring 2   the four forms
--   outside  the modifiers, placed further out the higher their level
--
-- A line means "needs", and only that:
--   core -> element   the spell needs one element, and every element qualifies
--   core -> form      the spell needs one form
--   core -> modifier  this modifier works with any form
--   form -> modifier  this modifier only works with that form
-- Modifiers are never strung together, because none of them requires another,
-- and elements are never tied to a form, because every pairing is legal. A
-- star with no line to a form is a star that needs no form.
--
-- Left-click a star to take it (modifiers rank up one click at a time),
-- right-click to give a rank back.
--
-- The chart answers back. Picking a form or an element, or taking a modifier
-- that rules another one out, fades the stars you can no longer reach off the
-- map along with their lines, and giving the choice back brings them home.
-- Only the player's own choices can do that: a star you are simply too low a
-- level for stays put, dimmed and wearing the level it opens at, because that
-- is something to aim for rather than something ruled out.
--
-- Node positions are derived from the catalog, never hand-placed, so adding a
-- clause to catalog.lua puts it on the map at the right depth automatically.

if not CLIENT then return end

Arcana = Arcana or {}
Arcana.Spellcraft = Arcana.Spellcraft or {}
local P = Arcana.Spellcraft

local Graph = {}
P.Graph = Graph

----------------------------------------------------------------------
-- Layout constants (world units; the view scales them to the panel)
----------------------------------------------------------------------
-- Distance from the core means "how deep into the spell this sits": the
-- elements orbit closest, then the forms, then the modifiers, placed by the
-- level they open at.
local R_ESSENCE = 150
local R_FORM = 310
local R_COMMON_MIN, R_COMMON_MAX = 300, 440 -- modifiers that need no form
local R_GATED_MIN, R_GATED_MAX = 430, 580   -- modifiers locked to one form
local R_SHARED = 500                        -- modifiers that accept a few forms

-- How wide a fan of modifiers spreads. Form sectors stay clear of the diagonal
-- wedges (26 degrees either side of a form, 16 either side of a diagonal).
local FORM_SPREAD = 52
local COMMON_SPREAD = 32

local NODE_R = { core = 46, form = 26, essence = 21, clause = 15 }

-- The opening zoom is fitted to the panel, so these are only the limits the
-- wheel may reach.
local ZOOM_MIN, ZOOM_MAX = 0.30, 1.80
local PAN_LIMIT = 620
local DRAG_THRESHOLD = 6

----------------------------------------------------------------------
-- Small math and drawing helpers
----------------------------------------------------------------------

-- Reused vertex buffer: filled circles are drawn dozens of times per frame and
-- a fresh poly table each time would churn the collector.
local CIRCLE_SEGS = 18
local CIRCLE_POLY = {}
for i = 1, CIRCLE_SEGS do CIRCLE_POLY[i] = { x = 0, y = 0 } end

local function drawFilledCircle(cx, cy, radius, r, g, b, a)
	for i = 1, CIRCLE_SEGS do
		local ang = (i - 1) / CIRCLE_SEGS * math.pi * 2
		local v = CIRCLE_POLY[i]
		v.x = cx + math.cos(ang) * radius
		v.y = cy + math.sin(ang) * radius
	end
	draw.NoTexture()
	surface.SetDrawColor(r, g, b, a)
	surface.DrawPoly(CIRCLE_POLY)
end

-- An eight-point art deco star: long spikes on the cardinals, shorter ones on
-- the diagonals, pinched to a tight waist between them. Sixteen vertices, laid
-- into a reused buffer so the centrepiece costs nothing per frame.
local STAR_POLY = {}
for i = 1, 16 do STAR_POLY[i] = { x = 0, y = 0 } end

local STAR_TRI = { { x = 0, y = 0 }, { x = 0, y = 0 }, { x = 0, y = 0 } }
local starCX, starCY = 0, 0

local function layStar(cx, cy, radius, rot)
	starCX, starCY = cx, cy

	for i = 1, 16 do
		local idx = i - 1
		local rad
		if idx % 2 == 1 then
			rad = radius * 0.26 -- waist
		elseif idx % 4 == 0 then
			rad = radius        -- long point
		else
			rad = radius * 0.66 -- short point
		end

		local ang = math.rad(rot + idx * 22.5)
		local v = STAR_POLY[i]
		v.x = cx + math.cos(ang) * rad
		v.y = cy + math.sin(ang) * rad
	end
end

-- surface.DrawPoly only handles convex shapes, and a star is anything but, so
-- the fill goes down as a fan of triangles from the centre instead. Handing the
-- concave outline straight to DrawPoly collapses it into a wedge.
local function fillStar(r, g, b, a)
	draw.NoTexture()
	surface.SetDrawColor(r, g, b, a)

	STAR_TRI[1].x, STAR_TRI[1].y = starCX, starCY

	for i = 1, 16 do
		local p, q = STAR_POLY[i], STAR_POLY[i % 16 + 1]
		STAR_TRI[2].x, STAR_TRI[2].y = p.x, p.y
		STAR_TRI[3].x, STAR_TRI[3].y = q.x, q.y
		surface.DrawPoly(STAR_TRI)
	end
end

local function strokeStar(r, g, b, a)
	surface.SetDrawColor(r, g, b, a)
	for i = 1, 16 do
		local p, q = STAR_POLY[i], STAR_POLY[i % 16 + 1]
		surface.DrawLine(p.x, p.y, q.x, q.y)
	end
end

-- Applies a fade to a shared palette colour without allocating or, worse,
-- mutating the palette entry itself. The result is consumed immediately.
local DIM_LABEL = Color(140, 128, 108)
local GATE_LABEL = Color(170, 150, 110)

local FADE_COL = Color(255, 255, 255, 255)
local function fade(col, va)
	if va >= 0.999 then return col end
	FADE_COL.r, FADE_COL.g, FADE_COL.b = col.r, col.g, col.b
	FADE_COL.a = (col.a or 255) * va
	return FADE_COL
end

local function wrapText(font, text, maxW)
	surface.SetFont(font)
	local lines, cur = {}, ""
	for word in string.gmatch(text or "", "%S+") do
		local trial = cur == "" and word or (cur .. " " .. word)
		if surface.GetTextSize(trial) > maxW and cur ~= "" then
			lines[#lines + 1] = cur
			cur = word
		else
			cur = trial
		end
	end
	if cur ~= "" then lines[#lines + 1] = cur end
	return lines
end

----------------------------------------------------------------------
-- Hand-drawn ornaments (line art, so they stay crisp at any zoom)
----------------------------------------------------------------------
-- A small ornament per element, centred at (cx, cy). k scales the strokes.
function Graph.DrawElementOrnament(id, cx, cy, col, k)
	k = k or 1
	surface.SetDrawColor(col)

	local function line(x1, y1, x2, y2)
		surface.DrawLine(cx + x1 * k, cy + y1 * k, cx + x2 * k, cy + y2 * k)
	end

	if id == "fire" then
		-- Flame: nested upward strokes
		line(-5, 5, 0, -6)
		line(0, -6, 5, 5)
		line(5, 5, -5, 5)
		line(-2, 3, 0, -1)
		line(0, -1, 2, 3)
	elseif id == "frost" then
		-- Snowflake: six spokes
		line(0, -6, 0, 6)
		line(-5, -3, 5, 3)
		line(-5, 3, 5, -3)
	elseif id == "earth" then
		-- Stone: a core within an outline
		surface.DrawOutlinedRect(cx - 5 * k, cy - 5 * k, 10 * k, 10 * k)
		surface.DrawRect(cx - 2 * k, cy - 2 * k, 4 * k, 4 * k)
	elseif id == "wind" then
		-- Gusts: three staggered strokes
		line(-6, -4, 4, -4)
		line(-4, 0, 6, 0)
		line(-6, 4, 2, 4)
	elseif id == "poison" then
		-- Droplet
		line(0, -6, -4, 2)
		line(0, -6, 4, 2)
		line(-4, 2, 0, 6)
		line(4, 2, 0, 6)
	elseif id == "lightning" then
		-- Bolt zigzag
		line(3, -6, -3, 1)
		line(-3, 1, 1, 1)
		line(1, 1, -3, 6)
	elseif id == "arcane" then
		-- Sparkle: four-point star
		line(0, -6, 0, 6)
		line(-6, 0, 6, 0)
		line(-3, -3, 3, 3)
		line(-3, 3, 3, -3)
	elseif id == "aurum" then
		-- Sun: disc and rays
		surface.DrawCircle(cx, cy, 4 * k, col.r, col.g, col.b, col.a or 255)
		line(0, -7, 0, -5)
		line(0, 5, 0, 7)
		line(-7, 0, -5, 0)
		line(5, 0, 7, 0)
	else
		-- Fallback diamond
		line(0, -5, 5, 0)
		line(5, 0, 0, 5)
		line(0, 5, -5, 0)
		line(-5, 0, 0, -5)
	end
end

-- A small ornament per form, in the same line-art style.
local function drawFormGlyph(id, cx, cy, col, k)
	k = k or 1
	surface.SetDrawColor(col)

	local function line(x1, y1, x2, y2)
		surface.DrawLine(cx + x1 * k, cy + y1 * k, cx + x2 * k, cy + y2 * k)
	end

	if id == "bolt" then
		-- A hurled dart with a trail
		line(0, -8, 5, 4)
		line(0, -8, -5, 4)
		line(-5, 4, 0, 1)
		line(5, 4, 0, 1)
		line(0, 4, 0, 8)
	elseif id == "beam" then
		-- A lance struck along a line
		line(-8, 6, 8, -6)
		line(8, -6, 3, -5)
		line(8, -6, 7, -1)
		line(-6, 8, -2, 4)
	elseif id == "self" then
		-- A body inside its aura
		surface.DrawCircle(cx, cy, 8 * k, col.r, col.g, col.b, col.a or 255)
		line(0, -4, 0, 2)
		line(-3, 4, 0, 2)
		line(3, 4, 0, 2)
		line(-3, -1, 3, -1)
	else
		-- Area: a burst blooming outward
		surface.DrawCircle(cx, cy, 3 * k, col.r, col.g, col.b, col.a or 255)
		for i = 0, 5 do
			local a = math.rad(i * 60)
			local ca, sa = math.cos(a), math.sin(a)
			line(ca * 5, sa * 5, ca * 9, sa * 9)
		end
	end
end

----------------------------------------------------------------------
-- Layout: derived from the catalog, computed once
----------------------------------------------------------------------
local layoutCache

-- Whether a modifier is off the table entirely given what the player has
-- already chosen. Only their own choices can rule a star out, never their
-- level: a level gate is something to aim for, so those stars stay on the
-- chart, dimmed, rather than vanishing.
-- Pure so it can be exercised outside the game.
function Graph.ClauseRuledOut(state, clause)
	local ranks = state.clauseRanks or {}

	if state.form then
		if clause.onlyForm and not clause.onlyForm[state.form] then return true end
		if clause.denyForm and clause.denyForm[state.form] then return true end
	end
	if state.essence and clause.denyEssence and clause.denyEssence[state.essence] then return true end

	-- A modifier already taken never vanishes out from under the player.
	if (ranks[clause.id] or 0) > 0 then return false end

	if clause.id == "homing" and (ranks.widen or 0) >= 2 then return true end

	for other in pairs(clause.conflicts or {}) do
		if ranks[other] then return true end
	end
	for otherId, otherRank in pairs(ranks) do
		if otherRank > 0 then
			local other = P.Clauses[otherId]
			if other and other.conflicts and other.conflicts[clause.id] then return true end
		end
	end

	return false
end

local function angleOfForm(formId)
	local f = P.Forms[formId]
	if not f then return -90 end
	return -90 + (f.order - 1) * 90
end

local function hashOf(id)
	return tonumber(util.CRC("arcana_star_" .. id)) or 0
end

-- Every edge on this chart states a real requirement, and nothing else:
--   core -> element   the spell needs one element, and every element qualifies
--   core -> form      the spell needs one form
--   core -> modifier  this modifier works with any form
--   form -> modifier  this modifier only works with that form
-- Modifiers are never chained to one another, because none of them requires
-- another. A star with no line to a form is a star that needs no form.
function Graph.BuildLayout()
	if layoutCache then return layoutCache end

	local nodes, byId = {}, {}

	local function add(n)
		nodes[#nodes + 1] = n
		n.index = #nodes
		byId[n.id] = n
		return n
	end

	local core = add({ id = "@core", kind = "core", ang = 0, rad = 0, radius = NODE_R.core })

	-- Elements orbit the spell itself: any one of them fits any form, so they
	-- hang off the core and never off a form.
	local essenceNodes = {}
	for _, essence in ipairs(P.SortedEssences()) do
		essenceNodes[#essenceNodes + 1] = add({
			id = "essence:" .. essence.id,
			kind = "essence",
			def = essence,
			-- Offset half a step from the form spokes so those spokes pass cleanly between them.
			ang = -90 + 22.5 + (essence.order - 1) * 45,
			rad = R_ESSENCE,
			radius = NODE_R.essence,
			anchors = { core },
		})
	end

	local formNodes = {}
	for _, form in ipairs(P.SortedForms()) do
		formNodes[form.id] = add({
			id = "form:" .. form.id,
			kind = "form",
			def = form,
			ang = angleOfForm(form.id),
			rad = R_FORM,
			radius = NODE_R.form,
			anchors = { core },
		})
	end

	----------------------------------------------------------------
	-- Sort the modifiers by what they actually require
	----------------------------------------------------------------
	local gated, shared, common = {}, {}, {}

	for _, clause in ipairs(P.SortedClauses()) do
		local only, count = nil, 0
		for fid in pairs(clause.onlyForm or {}) do
			only, count = fid, count + 1
		end

		if count == 1 then
			gated[only] = gated[only] or {}
			table.insert(gated[only], clause)
		elseif count > 1 then
			shared[#shared + 1] = clause
		else
			common[#common + 1] = clause
		end
	end

	local loLevel, hiLevel = math.huge, -math.huge
	for _, clause in pairs(P.Clauses) do
		local lv = clause.levels[1] or 35
		loLevel = math.min(loLevel, lv)
		hiLevel = math.max(hiLevel, lv)
	end
	local levelSpan = math.max(1, hiLevel - loLevel)

	-- Depth always means level, so two stars the same distance out cost the
	-- same wait no matter which branch they sit on.
	local function levelRad(clause, rMin, rMax)
		return rMin + ((clause.levels[1] or loLevel) - loLevel) / levelSpan * (rMax - rMin)
	end

	local function byLevel(a, b)
		if a.levels[1] == b.levels[1] then return a.order < b.order end
		return a.levels[1] < b.levels[1]
	end

	local clauseNodes = {}
	local function addClause(clause, ang, rad, anchors)
		clauseNodes[#clauseNodes + 1] = add({
			id = "clause:" .. clause.id,
			kind = "clause",
			def = clause,
			ang = ang,
			rad = rad,
			radius = NODE_R.clause,
			anchors = anchors,
		})
	end

	-- Modifiers that need no particular form fill the four diagonal wedges
	-- between the form spokes, dealt out by level so each wedge climbs.
	table.sort(common, byLevel)
	local wedges = { {}, {}, {}, {} }
	for i, clause in ipairs(common) do
		table.insert(wedges[(i - 1) % 4 + 1], clause)
	end

	for wi, list in ipairs(wedges) do
		local base = -45 + (wi - 1) * 90
		local n = #list
		for i, clause in ipairs(list) do
			addClause(clause,
				base + (i - (n + 1) * 0.5) * (COMMON_SPREAD / math.max(1, n)),
				levelRad(clause, R_COMMON_MIN, R_COMMON_MAX),
				{ core })
		end
	end

	-- Modifiers locked to one form fan out beyond that form, in its own sector.
	for _, form in ipairs(P.SortedForms()) do
		local list = gated[form.id]
		if list then
			table.sort(list, byLevel)
			local fnode = formNodes[form.id]
			local n = #list
			for i, clause in ipairs(list) do
				addClause(clause,
					fnode.ang + (i - (n + 1) * 0.5) * (FORM_SPREAD / n),
					levelRad(clause, R_GATED_MIN, R_GATED_MAX),
					{ fnode })
			end
		end
	end

	-- Modifiers that accept a few forms sit between them, tied to each one.
	for _, clause in ipairs(shared) do
		local anchors, xs, ys = {}, 0, 0
		for fid in pairs(clause.onlyForm) do
			local fnode = formNodes[fid]
			if fnode then
				anchors[#anchors + 1] = fnode
				local a = math.rad(fnode.ang)
				xs, ys = xs + math.cos(a), ys + math.sin(a)
			end
		end
		table.sort(anchors, function(a, b) return a.id < b.id end)
		addClause(clause, math.deg(math.atan2(ys, xs)), R_SHARED, anchors)
	end

	for _, node in ipairs(nodes) do
		local a = math.rad(node.ang)
		node.x = math.cos(a) * node.rad
		node.y = math.sin(a) * node.rad
	end

	----------------------------------------------------------------
	-- Edges, stored requirement-first so the light pulse flows outward
	----------------------------------------------------------------
	local edges = {}
	for _, node in ipairs(nodes) do
		for _, anchor in ipairs(node.anchors or {}) do
			edges[#edges + 1] = { a = anchor, b = node, phase = (hashOf(anchor.id .. node.id) % 100) / 100 }
		end
	end

	-- Conflicts, deduplicated. Drawn only on hover or when actually violated.
	local conflicts, seen = {}, {}
	local function conflictPair(idA, idB, note)
		local key = idA < idB and (idA .. "|" .. idB) or (idB .. "|" .. idA)
		if seen[key] then return end
		seen[key] = true
		local a, b = byId["clause:" .. idA], byId["clause:" .. idB]
		if a and b then conflicts[#conflicts + 1] = { a = a, b = b, note = note } end
	end

	for _, clause in ipairs(P.SortedClauses()) do
		for other in pairs(clause.conflicts or {}) do
			conflictPair(clause.id, other)
		end
	end
	-- The one cross-rank rule Compile enforces by hand.
	conflictPair("homing", "widen", "rank II")

	local radius = 0
	for _, node in ipairs(nodes) do
		radius = math.max(radius, node.rad + node.radius)
	end

	layoutCache = {
		nodes = nodes,
		byId = byId,
		edges = edges,
		conflicts = conflicts,
		clauses = clauseNodes,
		essences = essenceNodes,
		radius = radius,
	}

	return layoutCache
end

----------------------------------------------------------------------
-- Materials
----------------------------------------------------------------------
local NEBULA_MATS, GLOW_MAT

local function getNebulaMats()
	if NEBULA_MATS then return NEBULA_MATS end

	-- The Elysion skybox has no VMTs, so bind the raw VTFs directly. Stable
	-- material names: a per-call suffix would leak a new material every reload.
	NEBULA_MATS = {}
	for i, face in ipairs({ "front", "up" }) do
		NEBULA_MATS[i] = CreateMaterial("arcana_emissary_nebula_" .. face, "UnlitGeneric", {
			["$basetexture"] = "arcana/skybox/nebula/" .. face,
			["$nolod"] = 1,
			["$translucent"] = 1,
			["$vertexalpha"] = 1,
			["$vertexcolor"] = 1,
		})
	end

	return NEBULA_MATS
end

local function getGlowMat()
	GLOW_MAT = GLOW_MAT or Material("sprites/light_glow02_add")
	return GLOW_MAT
end

----------------------------------------------------------------------
-- The canvas
----------------------------------------------------------------------
-- ctx = {
--   state, seed, bumpRev, playClick, playDeny, requestUnlock, rightInset
-- }
function Graph.CreateCanvas(parent, ctx)
	local C = ArtDeco.Colors
	local layout = Graph.BuildLayout()
	local state = ctx.state

	-- zoom is left unset until the panel has a size, then fitted to it once.
	-- After that it is the player's, and refreshes keep whatever they set.
	state.view = state.view or { x = 0, y = 0, zoom = nil }
	local view = state.view

	-- The sidebar floats over the right of the panel, so the chart centres in
	-- what is left rather than sliding half of itself underneath it.
	local function rightInset()
		return ctx.rightInset and ctx.rightInset() or 0
	end

	local function viewCenter(cw, ch)
		return (cw - rightInset()) * 0.5, ch * 0.5
	end

	local function fitZoom(w, h)
		return math.Clamp(math.min(w - rightInset(), h) * 0.94 / (layout.radius * 2), ZOOM_MIN, ZOOM_MAX)
	end

	----------------------------------------------------------------
	-- Star dust: laid out once, animated by time
	----------------------------------------------------------------
	local dust = {}
	math.randomseed(ctx.seed or 1337)
	for i = 1, 70 do
		dust[i] = {
			x = math.Rand(-820, 820),
			y = math.Rand(-660, 660),
			s = math.random(1, 2),
			sp = math.Rand(0.4, 1.8),
			ph = math.Rand(0, 6.283),
			a = math.random(50, 185),
		}
	end
	-- Restore the global RNG: leaving it seeded makes every math.random caller
	-- this frame (world VFX included) repeat the same sequence.
	math.randomseed(SysTime())

	----------------------------------------------------------------
	-- Derived state, recomputed only when the composition changes
	----------------------------------------------------------------
	local status = {}
	local statusRev = -1

	local function slotCount()
		local n = 0
		for _, r in pairs(state.clauseRanks) do n = n + r end
		return n
	end

	local function formListLabel(set)
		local names = {}
		for fid in pairs(set) do
			local f = P.Forms[fid]
			names[#names + 1] = f and f.label or fid
		end
		table.sort(names)
		return table.concat(names, " or ")
	end

	-- Why the next rank of this clause cannot be taken right now, or nil.
	-- Returns the reason and, when the block is a level gate, the level needed.
	local function clauseBlockReason(clause, level, used)
		if clause.onlyForm then
			if not state.form then return "Pick a form first" end
			if not clause.onlyForm[state.form] then return "Only for " .. formListLabel(clause.onlyForm) end
		end
		if clause.denyForm and state.form and clause.denyForm[state.form] then
			return "Not for " .. (P.Forms[state.form] and P.Forms[state.form].label or state.form)
		end
		if clause.denyEssence and state.essence and clause.denyEssence[state.essence] then
			return "Redundant with " .. (P.Essences[state.essence] and P.Essences[state.essence].label or state.essence)
		end

		local rank = state.clauseRanks[clause.id] or 0
		local nextRank = rank + 1
		if nextRank > clause.maxRank then return nil end -- maxed out, the click is simply inert

		if level < clause.levels[nextRank] then
			return "Unlocks at level " .. clause.levels[nextRank], clause.levels[nextRank]
		end
		if used >= P.MAX_CLAUSE_SLOTS then return "Modifier limit reached (" .. P.MAX_CLAUSE_SLOTS .. ")" end
		if clause.id == "homing" and (state.clauseRanks.widen or 0) >= 2 then return "Conflicts with Widen II" end
		if clause.id == "widen" and nextRank >= 2 and state.clauseRanks.homing then return "Rank II conflicts with Homing" end

		-- Generic pairwise conflicts (mirrors Compile), both directions.
		for other in pairs(clause.conflicts or {}) do
			if state.clauseRanks[other] then
				return "Conflicts with " .. (P.Clauses[other] and P.Clauses[other].label or other)
			end
		end
		for otherId, otherRank in pairs(state.clauseRanks) do
			if otherRank > 0 then
				local other = P.Clauses[otherId]
				if other and other.conflicts and other.conflicts[clause.id] then
					return "Conflicts with " .. other.label
				end
			end
		end

		return nil
	end

	local function recompute()
		statusRev = state.rev or 0
		local cs = P.GetClientState()
		local level = cs.level or 0
		local used = slotCount()

		for _, node in ipairs(layout.nodes) do
			local st = status[node.id]
			if not st then
				st = {}
				status[node.id] = st
			end
			st.reason, st.rank, st.canAdd, st.cost, st.gateLevel = nil, 0, false, nil, nil
			st.want = 1

			if node.kind == "core" then
				st.kind = "core"
			elseif node.kind == "form" then
				st.kind = state.form == node.def.id and "allocated" or "available"
			elseif node.kind == "essence" then
				local e = node.def
				if e.bargain and not cs.bargain then
					st.kind = "hidden"
				elseif (e.bargain and cs.bargain) or cs.essences[e.id] == true then
					st.kind = state.essence == e.id and "allocated" or "available"
				else
					st.kind = "locked"
					st.cost = e.unlock
				end
			else
				local rank = state.clauseRanks[node.def.id] or 0
				st.rank = rank
				st.reason, st.gateLevel = clauseBlockReason(node.def, level, used)
				st.canAdd = rank < node.def.maxRank and st.reason == nil
				st.want = Graph.ClauseRuledOut(state, node.def) and 0 or 1
				if rank > 0 then
					st.kind = "allocated"
				elseif st.reason then
					st.kind = "blocked"
				else
					st.kind = "available"
				end
			end

			st.vis = st.vis or st.want
		end
	end

	local function markDirty()
		if ctx.bumpRev then ctx.bumpRev() end
		recompute()
	end

	recompute()

	----------------------------------------------------------------
	-- The panel
	----------------------------------------------------------------
	local canvas = vgui.Create("DPanel", parent)
	canvas:SetMouseInputEnabled(true)
	canvas.Paint = nil

	local frameCol = Color(C.gold.r, C.gold.g, C.gold.b, 160)

	local hoverNode = nil
	local pressNode = nil
	local pressActive = false
	local pressX, pressY = 0, 0
	local panStartX, panStartY = 0, 0
	local dragging = false

	local function toScreen(wx, wy, cw, ch)
		local cx, cy = viewCenter(cw, ch)
		return cx + (wx - view.x) * view.zoom, cy + (wy - view.y) * view.zoom
	end

	local function toWorld(sx, sy, cw, ch)
		local cx, cy = viewCenter(cw, ch)
		return view.x + (sx - cx) / view.zoom, view.y + (sy - cy) / view.zoom
	end

	local function clampPan()
		view.x = math.Clamp(view.x, -PAN_LIMIT, PAN_LIMIT)
		view.y = math.Clamp(view.y, -PAN_LIMIT, PAN_LIMIT)
	end

	local function hitTest(mx, my)
		local cw, ch = canvas:GetSize()
		local best, bestD
		for _, node in ipairs(layout.nodes) do
			local st = status[node.id]
			if not st or (st.vis or 1) < 0.5 then continue end

			local sx, sy = toScreen(node.x, node.y, cw, ch)
			local d = math.sqrt((mx - sx) ^ 2 + (my - sy) ^ 2)
			local hit = math.max(14, node.radius * view.zoom)
			if d <= hit and (not bestD or d < bestD) then
				best, bestD = node, d
			end
		end
		return best
	end

	----------------------------------------------------------------
	-- Allocation
	----------------------------------------------------------------
	local function pickForm(form)
		if state.form == form.id then return end
		state.form = form.id
		-- Drop modifiers that no longer fit the new form.
		for id in pairs(state.clauseRanks) do
			local cl = P.Clauses[id]
			if cl and ((cl.onlyForm and not cl.onlyForm[form.id]) or (cl.denyForm and cl.denyForm[form.id])) then
				state.clauseRanks[id] = nil
			end
		end
		ctx.playClick()
		markDirty()
	end

	local function pickEssence(essence)
		if state.essence == essence.id then return end
		state.essence = essence.id
		-- Drop modifiers that clash with the new element.
		for id in pairs(state.clauseRanks) do
			local cl = P.Clauses[id]
			if cl and cl.denyEssence and cl.denyEssence[essence.id] then
				state.clauseRanks[id] = nil
			end
		end
		ctx.playClick()
		markDirty()
	end

	local function addRank(clause)
		local st = status["clause:" .. clause.id]
		if not st or not st.canAdd then
			ctx.playDeny()
			return
		end
		state.clauseRanks[clause.id] = (state.clauseRanks[clause.id] or 0) + 1
		ctx.playClick()
		markDirty()
	end

	local function removeRank(clause)
		local rank = state.clauseRanks[clause.id] or 0
		if rank <= 0 then
			ctx.playDeny()
			return
		end
		state.clauseRanks[clause.id] = rank > 1 and (rank - 1) or nil
		ctx.playClick()
		markDirty()
	end

	local function activate(node)
		if node.kind == "core" then
			-- The spell at the centre is the way home: clicking it brings the
			-- chart back under the cursor rather than opening anything.
			view.x, view.y = 0, 0
			view.zoom = fitZoom(canvas:GetWide(), canvas:GetTall())
			ctx.playClick()
		elseif node.kind == "form" then
			pickForm(node.def)
		elseif node.kind == "essence" then
			local st = status[node.id]
			if st.kind == "hidden" then
				ctx.playDeny()
			elseif st.kind == "locked" then
				ctx.playClick()
				if ctx.requestUnlock then ctx.requestUnlock(node.def) end
			else
				pickEssence(node.def)
			end
		else
			addRank(node.def)
		end
	end

	----------------------------------------------------------------
	-- Input
	----------------------------------------------------------------
	canvas.OnMousePressed = function(pnl, code)
		local mx, my = pnl:CursorPos()

		-- Right-click gives a rank back. On empty sky it does nothing at all:
		-- a deny sound every time the cursor misses would be maddening.
		if code == MOUSE_RIGHT then
			local node = hitTest(mx, my)
			if node and node.kind == "clause" then removeRank(node.def) end
			return
		end

		-- Middle-click snaps back to the spell at the centre, so wandering off
		-- into empty sky is never a dead end.
		if code == MOUSE_MIDDLE then
			view.x, view.y = 0, 0
			view.zoom = fitZoom(pnl:GetWide(), pnl:GetTall())
			ctx.playClick()
			return
		end

		if code ~= MOUSE_LEFT then return end

		pressX, pressY = mx, my
		panStartX, panStartY = view.x, view.y
		pressNode = hitTest(mx, my)
		pressActive = true
		dragging = false
		pnl:MouseCapture(true)
	end

	canvas.OnCursorMoved = function(pnl, mx, my)
		if not pressActive then return end

		-- The cursor itself is set from Paint, which is the one place that knows
		-- what is under it after a pan or a zoom has moved the chart.
		if not dragging and (math.abs(mx - pressX) > DRAG_THRESHOLD or math.abs(my - pressY) > DRAG_THRESHOLD) then
			dragging = true
		end

		if dragging then
			view.x = panStartX - (mx - pressX) / view.zoom
			view.y = panStartY - (my - pressY) / view.zoom
			clampPan()
		end
	end

	canvas.OnMouseReleased = function(pnl, code)
		pnl:MouseCapture(false)

		if code == MOUSE_LEFT and not dragging and pressNode then
			local mx, my = pnl:CursorPos()
			if hitTest(mx, my) == pressNode then
				activate(pressNode)
			end
		end

		pressNode = nil
		pressActive = false
		dragging = false
	end

	canvas.OnMouseWheeled = function(pnl, delta)
		local cw, ch = pnl:GetSize()
		local mx, my = pnl:CursorPos()
		local wx, wy = toWorld(mx, my, cw, ch)

		view.zoom = math.Clamp(view.zoom * (1 + delta * 0.12), ZOOM_MIN, ZOOM_MAX)

		-- Keep the world point under the cursor pinned while zooming.
		local ccx, ccy = viewCenter(cw, ch)
		view.x = wx - (mx - ccx) / view.zoom
		view.y = wy - (my - ccy) / view.zoom
		clampPan()

		return true
	end

	canvas.OnCursorExited = function()
		hoverNode = nil
	end

	----------------------------------------------------------------
	-- Painting
	----------------------------------------------------------------
	-- Elements always wear their own colour; everything you have taken borrows
	-- the colour of the chosen element, so a built spell reads as one hue.
	local function nodeColor(node, st)
		if node.kind == "essence" then
			local ec = node.def.color
			return ec.r, ec.g, ec.b
		end

		local e = state.essence and P.Essences[state.essence]
		if e and (node.kind == "core" or (st and st.kind == "allocated")) then
			return e.color.r, e.color.g, e.color.b
		end

		return C.paleGold.r, C.paleGold.g, C.paleGold.b
	end

	local function drawGlow(sx, sy, size, r, g, b, a)
		surface.SetMaterial(getGlowMat())
		surface.SetDrawColor(r, g, b, a)
		surface.DrawTexturedRect(sx - size * 0.5, sy - size * 0.5, size, size)
	end

	local function drawNebula(w, h)
		local mats = getNebulaMats()
		local size = math.max(w, h) * 1.6
		local cx, cy = w * 0.5, h * 0.5

		local t = CurTime()
		local layers = {
			{ mat = mats[1], par = 0.05, drift = 3, tint = { 92, 96, 128 }, alpha = 190 },
			{ mat = mats[2], par = 0.11, drift = -5, tint = { 130, 110, 150 }, alpha = 70 },
		}

		for _, L in ipairs(layers) do
			if L.mat and not L.mat:IsError() then
				-- The skybox faces do not tile, so the quad is oversized and only
				-- ever slides inside its own slack: no UV wrap, no visible seam.
				local ox = math.Clamp(-view.x * L.par + math.sin(t * 0.01) * L.drift, -size * 0.2, size * 0.2)
				local oy = math.Clamp(-view.y * L.par + math.cos(t * 0.013) * L.drift, -size * 0.2, size * 0.2)
				surface.SetMaterial(L.mat)
				surface.SetDrawColor(L.tint[1], L.tint[2], L.tint[3], L.alpha)
				surface.DrawTexturedRect(cx - size * 0.5 + ox, cy - size * 0.5 + oy, size, size)
			end
		end
	end

	local function drawDust(w, h)
		local t = CurTime()
		local par = 0.55
		local ccx, ccy = viewCenter(w, h)
		for i = 1, #dust do
			local d = dust[i]
			local sx = ccx + (d.x - view.x * par) * view.zoom
			local sy = ccy + (d.y - view.y * par) * view.zoom
			if sx > -4 and sx < w + 4 and sy > -4 and sy < h + 4 then
				local tw = 0.55 + 0.45 * math.sin(t * d.sp + d.ph)
				surface.SetDrawColor(226, 220, 208, math.floor(d.a * tw))
				surface.DrawRect(sx, sy, d.s, d.s)
			end
		end

		-- A shooting star crosses now and then, on a deterministic cycle.
		local cycle = 11
		local idx = math.floor(t / cycle)
		local phase = (t % cycle) / 0.9
		if phase < 1 then
			local hx = (idx * 9301 + 49297) % 233280 / 233280
			local hy = (idx * 4211 + 1327) % 65536 / 65536
			local x0, y0 = w * (hx * 0.6), h * (hy * 0.5)
			local x1, y1 = x0 + w * 0.45, y0 + h * 0.35
			local px = Lerp(phase, x0, x1)
			local py = Lerp(phase, y0, y1)
			local streakFade = math.sin(phase * math.pi)
			surface.SetDrawColor(235, 228, 215, math.floor(200 * streakFade))
			surface.DrawLine(px, py, px - w * 0.05, py - h * 0.04)
		end
	end

	local function drawGuideRing(w, h, radius)
		local segs = 56
		local px, py
		surface.SetDrawColor(C.gold.r, C.gold.g, C.gold.b, 16)
		for i = 0, segs do
			local a = i / segs * math.pi * 2
			local sx, sy = toScreen(math.cos(a) * radius, math.sin(a) * radius, w, h)
			if px then surface.DrawLine(px, py, sx, sy) end
			px, py = sx, sy
		end
	end

	local function drawEdges(w, h)
		local t = CurTime()

		for _, edge in ipairs(layout.edges) do
			local sa = status[edge.a.id]
			local sb = status[edge.b.id]
			-- An edge is only as visible as the star it leads to.
			local vis = math.min(sa and sa.vis or 1, sb and sb.vis or 1)
			if vis < 0.02 then continue end

			local lit = (sa and (sa.kind == "allocated" or sa.kind == "core")) and (sb and sb.kind == "allocated")

			local ax, ay = toScreen(edge.a.x, edge.a.y, w, h)
			local bx, by = toScreen(edge.b.x, edge.b.y, w, h)

			if lit then
				local er, eg, eb = nodeColor(edge.b, sb)
				surface.SetDrawColor(er, eg, eb, 150 * vis)
			else
				surface.SetDrawColor(C.gold.r, C.gold.g, C.gold.b, 38 * vis)
			end
			surface.DrawLine(ax, ay, bx, by)

			-- The chart's signature: light runs outward along everything you have
			-- taken, so a finished spell reads as a lit constellation.
			if lit then
				local p = ((t * 0.4 + edge.phase) % 1)
				local px, py = Lerp(p, ax, bx), Lerp(p, ay, by)
				local er, eg, eb = nodeColor(edge.b, sb)
				drawGlow(px, py, 18, er, eg, eb, 120)
				surface.SetDrawColor(255, 250, 240, 220)
				surface.DrawRect(px - 1, py - 1, 2, 2)
			end
		end

		-- Conflicts only surface when they matter: hovering one side, or holding both.
		for _, pair in ipairs(layout.conflicts) do
			local ra = state.clauseRanks[pair.a.def.id] or 0
			local rb = state.clauseRanks[pair.b.def.id] or 0
			local violated = ra > 0 and rb > 0
			if violated or hoverNode == pair.a or hoverNode == pair.b then
				local ax, ay = toScreen(pair.a.x, pair.a.y, w, h)
				local bx, by = toScreen(pair.b.x, pair.b.y, w, h)
				local dx, dy = bx - ax, by - ay
				local len = math.max(1, math.sqrt(dx * dx + dy * dy))
				local steps = math.floor(len / 12)
				surface.SetDrawColor(210, 90, 70, violated and 200 or 110)
				for i = 0, steps - 1 do
					local t0, t1 = i / steps, (i + 0.5) / steps
					surface.DrawLine(ax + dx * t0, ay + dy * t0, ax + dx * t1, ay + dy * t1)
				end
			end
		end
	end

	local function drawCoreNode(node, w, h)
		local sx, sy = toScreen(node.x, node.y, w, h)
		local radius = node.radius * view.zoom

		local e = state.essence and P.Essences[state.essence]
		local col = e and e.color or C.paleGold
		local hovered = hoverNode == node

		-- Kept tight: the element ring orbits close, and a wide glow would wash it out.
		drawGlow(sx, sy, radius * (hovered and 3.2 or 2.8), col.r, col.g, col.b, hovered and 95 or 65)

		-- The spell itself is a deco star rather than a working circle: a mark
		-- standing for the thing you are building, not another ring of runes.
		-- It holds still. Everything else on the chart already moves.
		layStar(sx, sy, radius, -90)
		fillStar(col.r * 0.28, col.g * 0.28, col.b * 0.28, 248)
		strokeStar(col.r, col.g, col.b, 255)

		-- A second star set between the first one's points.
		layStar(sx, sy, radius * 0.44, -90 + 22.5)
		fillStar(col.r, col.g, col.b, 210)

		-- No name under it. The column already reads "Fire Bolt" at the top, and
		-- the star does not need to say it a second time.
		if hovered then
			draw.SimpleText("click to recenter", "Arcana_AncientSmall", sx, sy + radius + 8, C.textDim, TEXT_ALIGN_CENTER)
		end
	end

	local function drawNode(node, w, h)
		local st = status[node.id]
		if not st then return end

		local sx, sy = toScreen(node.x, node.y, w, h)
		local pad = 60
		if sx < -pad or sx > w + pad or sy < -pad or sy > h + pad then return end

		if node.kind == "core" then
			drawCoreNode(node, w, h)
			return
		end

		-- Stars ruled out by what you have already taken shrink away and stop
		-- answering the cursor, rather than lingering as dead weight.
		local va = st.vis or 1
		if va < 0.02 then return end

		local hovered = hoverNode == node
		local radius = node.radius * view.zoom * (hovered and 1.12 or 1) * (0.55 + 0.45 * va)
		local t = CurTime()
		local r, g, b = nodeColor(node, st)

		-- Dim the stars you cannot take so the reachable chart stands out.
		local mul = 1
		if st.kind == "blocked" then
			mul = 0.32
		elseif st.kind == "locked" then
			mul = 0.5
		elseif st.kind == "hidden" then
			mul = 0.28
		elseif st.kind == "available" then
			mul = 0.72
		end

		local cr, cg, cb = r * mul, g * mul, b * mul

		if st.kind == "allocated" then
			local breathe = 0.85 + 0.15 * math.sin(t * 2 + node.rad * 0.02)
			drawGlow(sx, sy, radius * 6 * breathe, r, g, b, 95 * va)
			drawGlow(sx, sy, radius * 3 * breathe, r, g, b, 130 * va)
		elseif hovered then
			drawGlow(sx, sy, radius * 4.4, cr, cg, cb, 90 * va)
		elseif st.kind ~= "blocked" and st.kind ~= "hidden" then
			drawGlow(sx, sy, radius * 3.2, cr, cg, cb, 45 * va)
		end

		-- Body
		drawFilledCircle(sx, sy, radius, 18, 12, 9, 240 * va)
		drawFilledCircle(sx, sy, radius * 0.9, cr * 0.3, cg * 0.3, cb * 0.3, 235 * va)

		-- Chrome
		if node.kind == "form" then
			ArtDeco.DrawPolygonOutline(sx, sy, radius, 8, Color(cr, cg, cb, 255 * va))
			if st.kind == "allocated" then
				ArtDeco.DrawPolygonOutline(sx, sy, radius * 1.22, 8, Color(255, 255, 255, 90 * va))
			end
		else
			surface.DrawCircle(sx, sy, radius, cr, cg, cb, 255 * va)
			if st.kind == "allocated" then
				if node.kind == "essence" then
					Arcana.Circle.Draw2DRing(Arcana.Circle.RING_TYPES.SIMPLE_LINE, sx, sy, radius * 1.5, t * 20, Color(r, g, b), 190 * va)
				else
					surface.DrawCircle(sx, sy, radius * 1.25, 255, 255, 255, 90 * va)
				end
			end
		end

		if hovered then
			surface.DrawCircle(sx, sy, radius * 1.4, 255, 255, 255, 150 * va)
		end

		-- Glyph
		local k = math.Clamp(view.zoom, 0.55, 1.35) * (node.kind == "form" and 1.25 or 1) * (0.55 + 0.45 * va)
		local glyphCol = Color(cr, cg, cb, 255 * va)
		if node.kind == "form" then
			drawFormGlyph(node.def.id, sx, sy, glyphCol, k)
		elseif st.kind == "hidden" then
			draw.SimpleText("?", "Arcana_Ancient", sx, sy, glyphCol, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		elseif node.kind == "essence" then
			Graph.DrawElementOrnament(node.def.id, sx, sy, glyphCol, k)
		else
			-- Modifiers carry no art of their own: a diamond core, brighter once taken.
			drawFilledCircle(sx, sy, radius * 0.34, cr, cg, cb, (st.kind == "allocated" and 255 or 170) * va)
		end

		-- Rank pips under multi-rank modifiers
		if node.kind == "clause" and node.def.maxRank > 1 then
			local pip = math.max(3, 4 * view.zoom)
			local gap = pip + 3
			local total = node.def.maxRank * gap - 3
			local px = sx - total * 0.5
			local py = sy + radius + 3
			for i = 1, node.def.maxRank do
				if i <= st.rank then
					surface.SetDrawColor(r, g, b, 255 * va)
					surface.DrawRect(px, py, pip, pip)
				else
					surface.SetDrawColor(cr, cg, cb, 150 * va)
					surface.DrawOutlinedRect(px, py, pip, pip)
				end
				px = px + gap
			end
		end

		-- Labels: forms and elements are always named. Modifier names only appear
		-- once there is room for them, which the chart opens just short of: at
		-- the fitted zoom the closest pair of stars sits about 33px apart and the
		-- longest name is twice that, so showing them all would be a pile-up.
		-- One wheel click brings them in. Whatever you have taken keeps its name
		-- at any zoom, so the spell you are building always reads.
		local showLabel = node.kind ~= "clause" or hovered or st.kind == "allocated" or view.zoom >= 0.58
		if showLabel then
			local label = st.kind == "hidden" and "???" or node.def.label
			local labelY = sy + radius + (node.kind == "clause" and node.def.maxRank > 1 and 16 or 6)
			local lc = st.kind == "allocated" and C.textBright or (st.kind == "blocked" and DIM_LABEL or C.textDim)
			draw.SimpleText(label, "Arcana_AncientSmall", sx, labelY, fade(lc, va), TEXT_ALIGN_CENTER)

			-- Level-gated modifiers wear the level they open at.
			if st.gateLevel and st.rank == 0 then
				draw.SimpleText("lv " .. st.gateLevel, "Arcana_AncientSmall", sx, labelY + 15, fade(GATE_LABEL, va), TEXT_ALIGN_CENTER)
			end
		end
	end

	----------------------------------------------------------------
	-- Hover card
	----------------------------------------------------------------
	local function drawHoverCard(w, h, mx, my)
		local node = hoverNode
		if not node or node.kind == "core" then return end

		local st = status[node.id]
		if not st then return end

		local cardW = 300
		local pad = 12
		local hidden = st.kind == "hidden"
		local title = hidden and "???" or node.def.label
		local desc = hidden and "An element no one speaks of." or (node.def.desc or "")
		local descLines = wrapText("Arcana_AncientSmall", desc, cardW - pad * 2)

		local rows = {}
		if node.kind == "form" then
			rows[#rows + 1] = { text = node.def.points .. " power", col = C.paleGold }
			local dmg = node.def.id == "self" and (node.def.tickDamage .. " damage/s") or (node.def.baseDamage .. " damage")
			rows[#rows + 1] = { text = dmg .. ", " .. ("%.0fs"):format(node.def.baseCooldown) .. " cooldown", col = C.textDim }
			rows[#rows + 1] = { text = st.kind == "allocated" and "Taken" or "Left-click to take", col = C.textDim }
		elseif node.kind == "essence" then
			if not hidden then rows[#rows + 1] = { text = node.def.points .. " power", col = C.paleGold } end
			if st.kind == "locked" then
				rows[#rows + 1] = { text = "Locked. Left-click to buy it.", col = Color(220, 170, 110) }
			elseif st.kind == "allocated" then
				rows[#rows + 1] = { text = "Taken", col = C.textDim }
			elseif not hidden then
				rows[#rows + 1] = { text = "Left-click to take", col = C.textDim }
			end
		else
			local clause = node.def
			rows[#rows + 1] = {
				text = clause.points .. " power" .. (clause.maxRank > 1 and " per rank" or ""),
				col = C.paleGold,
			}
			if clause.maxRank > 1 then
				rows[#rows + 1] = { text = "Rank " .. st.rank .. " of " .. clause.maxRank, col = C.textDim }
			end
			if st.reason then
				rows[#rows + 1] = { text = st.reason, col = Color(220, 170, 110) }
			elseif st.canAdd then
				rows[#rows + 1] = { text = "Left-click to add a rank", col = C.textDim }
			else
				rows[#rows + 1] = { text = "Fully ranked", col = C.textDim }
			end
			if st.rank > 0 then
				rows[#rows + 1] = { text = "Right-click to give a rank back", col = C.textDim }
			end
		end

		local costH = st.cost and 22 or 0
		local cardH = pad + 24 + #descLines * 16 + 8 + #rows * 17 + costH + pad

		local cx = math.Clamp(mx + 18, 4, w - cardW - 4)
		local cy = math.Clamp(my + 18, 4, h - cardH - 4)

		ArtDeco.FillDecoPanel(cx, cy, cardW, cardH, Color(18, 14, 10, 246), 8)
		ArtDeco.DrawDecoFrame(cx, cy, cardW, cardH, C.gold, 8)

		local tc = C.paleGold
		if node.kind == "essence" and not hidden then
			local ec = node.def.color
			tc = Color(ec.r, ec.g, ec.b)
		end

		local y = cy + pad
		draw.SimpleText(title, "Arcana_Ancient", cx + pad, y, tc)
		y = y + 24

		for _, lineTxt in ipairs(descLines) do
			draw.SimpleText(lineTxt, "Arcana_AncientSmall", cx + pad, y, C.textDim)
			y = y + 16
		end
		y = y + 8

		for _, row in ipairs(rows) do
			draw.SimpleText(row.text, "Arcana_AncientSmall", cx + pad, y, row.col)
			y = y + 17
		end

		if st.cost then
			ArtDeco.DrawCostLine("Arcana_AncientSmall", cx + pad, y, {
				{ text = string.Comma(st.cost.coins), icon = ArtDeco.Icons.coin, color = C.coinGold },
				{ text = string.Comma(st.cost.shards), icon = ArtDeco.Icons.shard, color = C.shardBlue },
			})
		end
	end

	----------------------------------------------------------------
	canvas.Paint = function(pnl, w, h)
		if not view.zoom then view.zoom = fitZoom(w, h) end
		if statusRev ~= (state.rev or 0) then recompute() end

		-- Ease stars in and out rather than popping them off the chart.
		local ease = math.min(1, FrameTime() * 9)
		for _, node in ipairs(layout.nodes) do
			local st = status[node.id]
			if st and st.vis ~= st.want then
				st.vis = math.abs(st.want - st.vis) < 0.005 and st.want or Lerp(ease, st.vis, st.want)
			end
		end

		local mx, my = pnl:CursorPos()
		local inside = pnl:IsHovered() and mx >= 0 and my >= 0 and mx < w and my < h
		if inside and not dragging then
			hoverNode = hitTest(mx, my)
		elseif not inside then
			hoverNode = nil
		end

		-- A star you can act on takes the hand. The hidden element is hoverable
		-- but not actionable, so it keeps the arrow rather than promising a click.
		local hoverStatus = hoverNode and status[hoverNode.id]
		local actionable = hoverNode ~= nil and not (hoverStatus and hoverStatus.kind == "hidden")
		local cursor = dragging and "sizeall" or (actionable and "hand" or "arrow")
		if pnl._cursor ~= cursor then
			pnl._cursor = cursor
			pnl:SetCursor(cursor)
		end

		-- Clip everything to the art-deco octagon using the stencil buffer.
		ArtDeco.BeginOctagonClip(1, 1, w - 2, h - 2, 12)

		surface.SetDrawColor(6, 7, 14, 255)
		surface.DrawRect(1, 1, w - 2, h - 2)

		drawNebula(w, h)
		drawDust(w, h)
		drawGuideRing(w, h, R_ESSENCE)
		drawGuideRing(w, h, R_FORM)
		drawEdges(w, h)

		for _, node in ipairs(layout.nodes) do
			if node ~= hoverNode then drawNode(node, w, h) end
		end
		if hoverNode then drawNode(hoverNode, w, h) end

		ArtDeco.EndOctagonClip()

		ArtDeco.DrawDecoFrame(0, 0, w, h, frameCol, 12)

		if inside then drawHoverCard(w, h, mx, my) end
	end

	return canvas
end
