-- Arcana Spawnmenu Icon Exporter — developer one-shot tool.
-- Renders every spawnable Arcana entity to a framed spawnicon PNG in the DATA folder.
--
-- WHY THIS IS NOT AN OFFSCREEN RENDER TARGET:
-- The obvious approach is PushRenderTarget + cam.Start3D + ent:Draw(). It does not work here.
-- ParticleEmitter and DynamicLight only ever render in the main scene pass, and Arcana's bloom
-- (arcana/system/vfx/bloom.lua) isolates its glow by diffing framebuffer snapshots — all three
-- vanish in an offscreen pass, which is most of what makes a brazier or a fae lantern readable.
-- So the icon IS a real engine frame: the world is erased out from under the subject and our own
-- backdrop is painted in its place, then the finished frame is captured.
--
-- Usage — load in BOTH realms, then set up before exporting:
--   lua_openscript    arcana/tools/export_spawnicons.lua   -- server half: staging
--   lua_openscript_cl arcana/tools/export_spawnicons.lua   -- client half: rig + capture
--   arcana_spawnicon_setup                                 -- (server) stage every subject
--   arcana_spawnicon_preview arcana_brazier                -- live tuning, no files written
--   arcana_spawnicon_preview off
--   arcana_export_spawnicons [class]                       -- batch, or one class
--   arcana_spawnicon_reset                                 -- panic button, see the bottom of file
--
-- The rig hides the rest of the world with SetNoDraw while it shoots. If a run is interrupted
-- badly enough that it cannot put things back, the screen goes black and stays there: run
-- arcana_spawnicon_reset. A watchdog also disarms the rig on its own after MAX_ARM_SECONDS.
--
-- The setup pass matters: several of these entities randomise themselves on spawn (the brazier
-- and the lantern each pick a colour preset at random) or only show their best state once a
-- player has interacted with them (the altar opens, the emissary's bench runes only glow while
-- its ceremony runs). Shooting whatever happens to be lying in the world gives a purple brazier
-- and a shut altar, and gives a different result every run.
--
-- Output:  garrysmod/data/arcana/spawnicon_exports/<class>.png   (ScrH x ScrH, square)
--
-- These are the authoring format only. Downsample them to the shipped 256x256 icons with:
--
--   python3 tools/build_spawnicons.py <gmod>/garrysmod/data/arcana/spawnicon_exports \
--       --out materials/entities
--
-- The capture is the centred square of the screen, so the source resolution is whatever the game
-- is running at. At 2560x1440 that is a 1440px square downsampled 5.6x, which is what keeps the
-- thin gold frame strokes clean without any antialiasing in the drawing code.

-- ── Configuration ─────────────────────────────────────────────────────────────

local OUTPUT = "arcana/spawnicon_exports"

-- Entities outside this radius of the subject are hidden for the shot. It is generous on purpose:
-- the altar's obelisks and the emissary's aura are separate clientside props that must survive.
local KEEP_RADIUS = 400

-- Round trip for the client to ask the server to stage a subject and see it arrive.
local STAGE_WAIT = 1.2

-- A shot lasts a fraction of a second. If the rig is still armed after this long, something went
-- wrong between arming and disarming — a map change mid-batch, an error, a queue left orphaned —
-- and an armed rig is not a harmless state: it paints over the world, holds the view, and leaves
-- every entity it hid invisible. The watchdog is what stops that becoming a game you have to
-- restart. Anything not recoverable this way is what arcana_spawnicon_reset is for.
local MAX_ARM_SECONDS = 20

-- Global draw hooks muted for the duration of a shot. These render Arcana effects for the whole
-- world rather than per entity, so SetNoDraw does not touch them: the mana network draws its glyph
-- flows for anything within 2000 units of the eye, and the rig camera counts as the eye.
local MUTED_HOOKS = {
	{"PostDrawOpaqueRenderables", "Arcana_ManaNetwork_Draw"},
}

-- A fixed light rig, so an icon shot in a dark corner of gm_streifen matches one shot on flatgrass.
-- Only lit models see this; particles, sprites and the bloom pass are unaffected.
local USE_STUDIO_LIGHT = true

local STUDIO_LIGHT = {
	[BOX_TOP]    = {1.15, 1.02, 0.84},   -- warm key from above
	[BOX_LEFT]   = {0.78, 0.63, 0.36},   -- gold rim
	[BOX_FRONT]  = {0.52, 0.47, 0.42},
	[BOX_RIGHT]  = {0.24, 0.23, 0.28},   -- cool fill
	[BOX_BACK]   = {0.18, 0.16, 0.14},
	[BOX_BOTTOM] = {0.10, 0.09, 0.08},
}

-- Per-entity config, shared by both realms.
--
-- `dir` is where the camera sits, in the SUBJECT'S OWN space: x forward, y right, z up. World-space
-- directions would shoot each entity from whatever way it happened to be facing — which is how the
-- emissary ended up photographed from behind.
--
-- `pad` is the slack around the subject, `radius` overrides the fit where the mesh does not cover
-- the visuals, and `settle` is how long the entity runs before the shot so emitters have particles
-- and fade-ins have finished. `stage` runs serverside to put the entity in the state worth
-- photographing, `suppress` names draw methods to stub out for the shot — set dressing that reads
-- as clutter once it is cropped to a 64px tile — and `preDraw` runs every frame just before the
-- translucent pass, for effects that are inline in DrawTranslucent and so cannot be stubbed by
-- name; the entity's Think refills their state each frame, hence per-frame rather than on arm.
local EMBER = Color(255, 160, 50)

local TARGETS = {
	{
		-- Open, the obelisk splits into two halves that carry the band circle between them: the
		-- pair spans z -91..+90 around the origin, well past the entity's own 118-unit mesh, so
		-- the fit needs telling and the look-at stays on the origin.
		class = "arcana_altar", fov = 40, dir = Vector(1, -0.35, 0.30), pad = 1.20, radius = 95, settle = 5,
		stage = function(ent) ent:SetAltarIsOpen(true) end,
	},
	{class = "arcana_enchanter",    fov = 40, dir = Vector(1, -0.35, 0.35), pad = 1.15, settle = 2},
	{
		class = "arcana_spell_caster", fov = 40, dir = Vector(1, -0.55, 0.45), pad = 1.30, settle = 1,
		-- Draws a green aim line and a spell readout to whoever owns it while they hold a physgun.
		-- Staging makes the exporting player the owner, so disown it and that branch returns early.
		stage = function(ent)
			if ent.CPPISetOwner then ent:CPPISetOwner(nil) end
			ent:SetNWEntity("FallbackOwner", NULL)
		end,
	},
	{
		-- lookZ aims the camera above the bowl, which drops the bowl down the frame and leaves the
		-- flame column room instead of cropping it at the top rail. liftZ holds it at its usual
		-- hover height so the ground circle projects well below the bowl instead of slicing it.
		class = "arcana_brazier", fov = 40, dir = Vector(1, -0.30, 0.22), pad = 1.40, lookZ = 55, liftZ = 120, settle = 3,
		-- SpawnFunction rolls a random colour preset; pin it to the default fire.
		stage = function(ent) ent:SetFlameColor(EMBER) end,
	},
	{
		class = "arcana_fae_lantern", fov = 40, dir = Vector(1, -0.30, 0.22), pad = 1.40, settle = 3,
		stage = function(ent) ent:SetLightColor(ent.DefaultLightColor) end,
	},
	{
		class = "arcana_emissary", fov = 40, dir = Vector(1, -0.34, 0.30), pad = 1.25, settle = 6,
		-- The engraved bench runes and the grimoire aura only bloom while the ceremony runs, which
		-- GetEmissaryIsOpen drives; the client eases _grimFrac / _tearFrac to 1 over a few seconds.
		stage = function(ent) ent:SetEmissaryIsOpen(true) end,
		-- The ceremony also rings the bench with eight bookshelves and tears the floor open under
		-- it. Both are set dressing that swallows the bench at icon size — and the shelf ring is
		-- what forced the camera outside it in the first place. Drop them and the subject is just
		-- the bench, framed on its own mesh.
		suppress = {"_DrawShelves", "_DrawAbyssCap", "_DrawTearShape"},
		-- Floating runes are the altar's signature, so the emissary keeps only the glow baked into
		-- its own model. Its two rune sets are drawn inline in DrawTranslucent and gated on this
		-- state, so emptying it each frame is what turns them off.
		--
		-- _grimFrac drives both the grimoire's lift off the bench and its aura, and zeroing it
		-- sets the book back down and hides the aura. The bench runes survive because their
		-- brightness is max(_grimFrac, _tearFrac) and the tear is still open — just not drawn.
		preDraw = function(ent)
			ent._runes = {}
			ent._grimFrac = 0

			-- Zeroing the fraction alone is not enough: Think re-advances it and recomputes the
			-- book's position before the frame draws, which leaves it a couple of units in the
			-- air. Snap the prop onto GRIM_REST_POS (arcana_emissary.lua:137) so it actually sits.
			if IsValid(ent._grimoire) then
				ent._grimoire:SetPos(ent:LocalToWorld(Vector(18, 0, 35)))
			end

			if ent._shelfFrac then
				for i = 1, #ent._shelfFrac do
					ent._shelfFrac[i] = 0
				end
			end
		end,
	},
	{
		-- Stood upright with the cover square to the lens — the emblem pose. Pitch +90, not -90:
		-- the model's +x axis is the BOTTOM of the cover art, so -90 stands it on its head. With
		-- the pitch flipped, +up is the side the sigil cover faces. camRoll does the 180 the
		-- entity pose cannot (see computeView).
		class = "grimoire", swep = true, fov = 40, dir = Vector(0, 0, 1), pad = 0.94, camRoll = 180, settle = 1,
		stage = function(ent) ent:SetAngles(Angle(90, 0, 0)) end,
	},
}

local TARGET_BY_CLASS = {}
for _, t in ipairs(TARGETS) do
	TARGET_BY_CLASS[t.class] = t
end

-- ── Server half: staging ──────────────────────────────────────────────────────

if SERVER then
	-- Exactly one subject exists in the world at a time. Staging the whole set at once and relying
	-- on distance to keep them apart does not work: SetNoDraw only stops an entity drawing ITSELF,
	-- and Arcana's biggest effects are drawn by global systems that never consult it — the mana
	-- network's glyph flows render anything within 2000 units of the eye, and magic circles are
	-- drawn by the circle system for every registered circle. Those leaked a neighbour's runes and
	-- band circles into the altar, enchanter and emissary shots.
	local SPACING = 700

	concommand.Add("arcana_spawnicon_setup", function(ply, _, args)
		if not IsValid(ply) then ply = player.GetAll()[1] end
		if not IsValid(ply) then return end

		local only = args and args[1]

		for _, t in ipairs(TARGETS) do
			for _, e in ipairs(ents.FindByClass(t.class)) do
				if not IsValid(e:GetOwner()) then e:Remove() end
			end
		end

		-- "none" is the cleanup verb: clear the stage and stop, used at the end of a batch so the
		-- last subject does not linger in the player's world.
		if only == "none" then
			MsgC(Color(180, 255, 180), "[ArcanaIcons] Stage cleared.\n")

			return
		end

		local wanted = {}

		for _, t in ipairs(TARGETS) do
			if not only or only == "" or t.class == only then
				wanted[#wanted + 1] = t
			end
		end

		local base = ply:GetPos()

		-- Lay the row out along whichever cardinal direction actually has floor for its whole
		-- length. Using the way the player happens to be looking silently drops half the set on
		-- any map where that direction is a pit or a wall.
		local axis, bestHits = Vector(1, 0, 0), -1

		for _, candidate in ipairs({Vector(1, 0, 0), Vector(-1, 0, 0), Vector(0, 1, 0), Vector(0, -1, 0)}) do
			local hits = 0

			for i = 1, #wanted do
				local p = base + candidate * (i * SPACING)
				local tr = util.TraceLine({
					start = p + Vector(0, 0, 200),
					endpos = p - Vector(0, 0, 600),
					filter = ply,
					mask = MASK_SOLID,
				})

				if tr.Hit then hits = hits + 1 end
			end

			if hits > bestHits then
				axis, bestHits = candidate, hits
			end
		end

		timer.Simple(0.3, function()
			for i, t in ipairs(wanted) do
				local p = base + axis * (i * SPACING)
				local tr = util.TraceLine({
					start = p + Vector(0, 0, 200),
					endpos = p - Vector(0, 0, 600),
					filter = ply,
					mask = MASK_SOLID,
				})

				if not tr.Hit then
					MsgC(Color(255, 160, 60), "[ArcanaIcons] No floor for " .. t.class .. ", skipped.\n")
					continue
				end

				local ent
				local stored = scripted_ents.GetStored(t.class)

				-- SpawnFunction is where each entity applies its own placement rules (the brazier
				-- is pitched 180 so the shell reads as a bowl, and so on). Going around it with a
				-- bare ents.Create is how you end up with an upside-down brazier.
				if stored and stored.t.SpawnFunction then
					ent = stored.t.SpawnFunction(stored.t, ply, tr, t.class)
				else
					ent = ents.Create(t.class)

					if IsValid(ent) then
						ent:SetPos(tr.HitPos + tr.HitNormal * 8)
						ent:Spawn()
						ent:Activate()
					end
				end

				if not IsValid(ent) then
					MsgC(Color(255, 80, 80), "[ArcanaIcons] Failed to spawn " .. t.class .. "\n")
					continue
				end

				-- Floaters are PLACED at their hover height rather than trusted to fly there.
				if t.liftZ then
					ent:SetPos(tr.HitPos + tr.HitNormal * t.liftZ)
				end

				-- Everything is frozen for the shot. Live physics has no upside for a still frame
				-- and two demonstrated downsides: the grimoire tumbled through the floor, and the
				-- brazier's float controller death-spiraled to z -15000 ("Crazy origin ...
				-- Removing!") — its PhysicsSimulate traces down 1000 units for ground, and one
				-- missed trace turns the float target into currentPos - 752, forever.
				local phys = ent:GetPhysicsObject()

				if IsValid(phys) then
					phys:EnableMotion(false)
				end

				if t.stage then
					local ok, err = pcall(t.stage, ent)
					if not ok then
						MsgC(Color(255, 80, 80), "[ArcanaIcons] stage(" .. t.class .. "): " .. tostring(err) .. "\n")
					end
				end

				MsgC(Color(120, 230, 120), "[ArcanaIcons] Staged " .. t.class .. "\n")
			end

			MsgC(Color(180, 255, 180), "[ArcanaIcons] Staging done — run arcana_export_spawnicons on the client.\n")
		end)
	end)

	return
end

-- ── Frame & backdrop art ──────────────────────────────────────────────────────
-- The frame every icon wears: a double-rule octagon with 45 degree cut corners, a runic glyph in
-- each open corner triangle, and a lozenge at each edge midpoint. Everything is a fraction of the
-- square size s. This lives HERE, not in the runtime addon: nothing player-facing draws it, and
-- the one thing that did (the animated grimoire icon) is gone.

local COL_BG_TOP    = Color(30, 23, 16)
local COL_BG_DARK   = Color(9, 7, 5)
local COL_GOLD      = Color(198, 160, 74)
local COL_PALE_GOLD = Color(222, 198, 120)
local COL_BRASS     = Color(160, 130, 60)

local MAT_GLOW = Material("particle/particle_glow_04_additive")

-- Four different glyphs so the frame reads as an inscription, not a stamp.
local CORNER_GLYPH_CODES = {65, 68, 70, 67}
local CORNERS = {{0, 0}, {1, 0}, {1, 1}, {0, 1}}

local glyphMats
local function getGlyphMats()
	if glyphMats then return glyphMats end
	glyphMats = {}

	-- DXT5 VTF rather than the PNG, matching spellcraft/ui.lua: the upload is shared with the
	-- ring glyphs instead of adding a BGRA8888 copy.
	for _, code in ipairs(CORNER_GLYPH_CODES) do
		glyphMats[code] = CreateMaterial("arcana_spawnicon_glyph_" .. code, "UnlitGeneric", {
			["$basetexture"] = "arcana/glyphs/glyph_" .. code,
			["$translucent"] = 1,
			["$vertexalpha"] = 1,
			["$vertexcolor"] = 1,
		})
	end

	return glyphMats
end

-- Axis-aligned stroke as a rect, ends extended by half the thickness so perpendicular runs meet
-- without notching.
local function bar(x1, y1, x2, y2, t)
	local h = t * 0.5

	if math.abs(y1 - y2) < 0.5 then
		local x0, x1b = math.min(x1, x2), math.max(x1, x2)
		surface.DrawRect(math.floor(x0 - h), math.floor(y1 - h), math.ceil(x1b - x0 + t), math.ceil(t))
	else
		local y0, y1b = math.min(y1, y2), math.max(y1, y2)
		surface.DrawRect(math.floor(x1 - h), math.floor(y0 - h), math.ceil(t), math.ceil(y1b - y0 + t))
	end
end

-- Diagonal stroke as a filled quad, same half-thickness end extension. Minus side first: with
-- screen-space y pointing down this walks the quad clockwise, which is the winding DrawPoly
-- renders — the mirror order gets culled.
local function slantBar(x1, y1, x2, y2, t)
	local dx, dy = x2 - x1, y2 - y1
	local len = math.sqrt(dx * dx + dy * dy)
	if len < 0.001 then return end

	local h = t * 0.5
	local ux, uy = dx / len, dy / len
	local nx, ny = -uy * h, ux * h

	x1, y1 = x1 - ux * h, y1 - uy * h
	x2, y2 = x2 + ux * h, y2 + uy * h

	draw.NoTexture()
	surface.DrawPoly({
		{x = x1 - nx, y = y1 - ny},
		{x = x2 - nx, y = y2 - ny},
		{x = x2 + nx, y = y2 + ny},
		{x = x1 + nx, y = y1 + ny},
	})
end

-- Closed outline of a square with 45 degree cut corners — the ArtDeco.DrawDecoFrame octagon, so
-- the icons speak the addon's dialect. Each corner is the two-point cut mirrored into its
-- quadrant; the two singly-mirrored ones are walked backwards so the path stays continuous.
local function octagonPath(x, y, s, c)
	local base = {{0, c}, {c, 0}}
	local pts = {}

	for _, m in ipairs(CORNERS) do
		local reversed = (m[1] + m[2]) == 1
		local from, to, dir = 1, #base, 1
		if reversed then from, to, dir = #base, 1, -1 end

		for i = from, to, dir do
			local p = base[i]
			pts[#pts + 1] = {
				x = x + (m[1] == 0 and p[1] or (s - p[1])),
				y = y + (m[2] == 0 and p[2] or (s - p[2])),
			}
		end
	end

	return pts
end

local function strokePath(pts, t, col)
	surface.SetDrawColor(col.r, col.g, col.b, col.a or 255)

	for i = 1, #pts do
		local p, n = pts[i], pts[(i % #pts) + 1]

		if math.abs(p.x - n.x) < 0.5 or math.abs(p.y - n.y) < 0.5 then
			bar(p.x, p.y, n.x, n.y, t)
		else
			slantBar(p.x, p.y, n.x, n.y, t)
		end
	end
end

-- Each glyph sits in the dead triangle OUTSIDE the frame, between the cut and the square's own
-- corner. The largest axis-aligned square under the cut line has side reach / 2 flush in the
-- corner; 0.46 with a 0.02 nudge leaves a hair of air on every side.
local function drawCornerGlyphs(x, y, s, a, c)
	local mats = getGlyphMats()
	local reach = a + c
	local size = reach * 0.46
	local d = size * 0.5 + reach * 0.02

	for i, m in ipairs(CORNERS) do
		local mat = mats[CORNER_GLYPH_CODES[i]]
		if not mat then continue end

		local sx = m[1] == 0 and 1 or -1
		local sy = m[2] == 0 and 1 or -1
		local cx = (m[1] == 0 and x or (x + s)) + sx * d
		local cy = (m[2] == 0 and y or (y + s)) + sy * d

		surface.SetMaterial(mat)
		surface.SetDrawColor(COL_PALE_GOLD.r, COL_PALE_GOLD.g, COL_PALE_GOLD.b, 255)
		surface.DrawTexturedRect(cx - size * 0.5, cy - size * 0.5, size, size)
	end
end

-- A gold lozenge seated on the band at the middle of each edge, echoing the diamond that
-- ArtDeco.DrawDecoFlourish puts at the centre of every station title rule.
local function drawEdgeDiamonds(x, y, s, a, b)
	local mid = (a + b) * 0.5
	local r = math.max(3, (b - a) * 0.80)

	local spots = {
		{x + s * 0.5, y + mid},
		{x + s * 0.5, y + s - mid},
		{x + mid, y + s * 0.5},
		{x + s - mid, y + s * 0.5},
	}

	draw.NoTexture()

	for _, p in ipairs(spots) do
		surface.SetDrawColor(COL_GOLD.r, COL_GOLD.g, COL_GOLD.b, 255)
		surface.DrawPoly({
			{x = p[1], y = p[2] - r},
			{x = p[1] + r, y = p[2]},
			{x = p[1], y = p[2] + r},
			{x = p[1] - r, y = p[2]},
		})

		local ri = r * 0.42
		surface.SetDrawColor(COL_BG_DARK.r, COL_BG_DARK.g, COL_BG_DARK.b, 255)
		surface.DrawPoly({
			{x = p[1], y = p[2] - ri},
			{x = p[1] + ri, y = p[2]},
			{x = p[1], y = p[2] + ri},
			{x = p[1] - ri, y = p[2]},
		})
	end
end

-- The full frame over a square region.
local function drawFrame(x, y, s)
	local tOuter = math.max(3, math.floor(s * 0.0105))
	local tInner = math.max(1, math.floor(s * 0.0035))
	local a = math.ceil(tOuter * 0.5)            -- outer rule, pulled in enough to sit inside
	local b = a + math.floor(s * 0.030)          -- inner rule
	local c = math.floor(s * 0.150)              -- corner cut reach

	-- Both rules use the SAME cut reach, which keeps the two slants exactly parallel so the band
	-- between them holds a constant width.
	strokePath(octagonPath(x + a, y + a, s - a * 2, c), tOuter, COL_GOLD)
	strokePath(octagonPath(x + b, y + b, s - b * 2, c), tInner, COL_BRASS)

	drawCornerGlyphs(x, y, s, a, c)
	drawEdgeDiamonds(x, y, s, a, b)
end

local GRADIENT_STEPS = 96

-- The shared backdrop: vertical gradient, warm core bloom, the addon's own pattern rings and
-- faint concentric hairlines. Fills w x h, composed around its centre at scale s.
local function paintBackdrop(x, y, w, h, s)
	local stepH = h / GRADIENT_STEPS

	for i = 0, GRADIENT_STEPS - 1 do
		local f = i / (GRADIENT_STEPS - 1)
		surface.SetDrawColor(
			Lerp(f, COL_BG_TOP.r, COL_BG_DARK.r),
			Lerp(f, COL_BG_TOP.g, COL_BG_DARK.g),
			Lerp(f, COL_BG_TOP.b, COL_BG_DARK.b),
			255
		)
		surface.DrawRect(x, math.floor(y + i * stepH), w, math.ceil(stepH) + 1)
	end

	local cx, cy = x + w * 0.5, y + h * 0.5

	-- Warm core bloom behind wherever the subject sits — the only thing lifting the middle off
	-- black; the subject is the hero, the backdrop just has to seat it.
	surface.SetMaterial(MAT_GLOW)
	surface.SetDrawColor(COL_GOLD.r, COL_GOLD.g, COL_GOLD.b, 46)
	surface.DrawTexturedRect(cx - s * 0.50, cy - s * 0.50, s, s)
	surface.SetDrawColor(COL_PALE_GOLD.r, COL_PALE_GOLD.g, COL_PALE_GOLD.b, 26)
	surface.DrawTexturedRect(cx - s * 0.24, cy - s * 0.24, s * 0.48, s * 0.48)

	-- Arcana's own ring art, faint, behind the subject
	if Arcana and Arcana.Circle and Arcana.Circle.Draw2DPatternRing then
		Arcana.Circle.Draw2DPatternRing(1, cx, cy, s * 0.355, 0, COL_GOLD, 26)
		Arcana.Circle.Draw2DPatternRing(2, cx, cy, s * 0.255, 0, COL_GOLD, 16)
	end

	-- Concentric hairlines, evenly spaced, to give the void some structure
	for i = 1, 4 do
		surface.DrawCircle(cx, cy, s * (0.10 + i * 0.075), COL_GOLD.r, COL_GOLD.g, COL_GOLD.b, 20)
	end
end

-- ── Backdrop ──────────────────────────────────────────────────────────────────
-- It is baked into a render target rather than drawn straight into the scene: the opaque pass runs
-- with alpha blending OFF, so a 2D draw there ignores its alpha entirely and every faint layer
-- comes out solid gold. Baking it where blending behaves and blitting the result opaquely is both
-- correct and cheaper — the backdrop never changes between icons.

local MAT_GRAD_UP   = Material("gui/gradient_up")
local MAT_GRAD_DOWN = Material("gui/gradient_down")
local MAT_GRAD      = Material("gui/gradient")

local backdropRT, backdropMat, backdropW, backdropH

local function buildBackdrop()
	local scrW, scrH = ScrW(), ScrH()
	if backdropMat and backdropW == scrW and backdropH == scrH then return end

	backdropW, backdropH = scrW, scrH
	backdropRT = GetRenderTarget("arcana_spawnicon_backdrop_" .. scrW .. "x" .. scrH, scrW, scrH, false)
	backdropMat = CreateMaterial("arcana_spawnicon_backdrop_mat", "UnlitGeneric", {
		["$basetexture"] = backdropRT:GetName(),
		["$ignorez"] = 1,
		["$nolod"] = 1,
	})

	render.PushRenderTarget(backdropRT, 0, 0, scrW, scrH)
	render.Clear(0, 0, 0, 255, true, true)
	cam.Start2D()
	paintBackdrop(0, 0, scrW, scrH, scrH)
	cam.End2D()
	render.PopRenderTarget()
end

local function blitBackdrop()
	if not backdropMat then return end

	surface.SetMaterial(backdropMat)
	surface.SetDrawColor(255, 255, 255, 255)
	surface.DrawTexturedRect(0, 0, backdropW, backdropH)
end

-- ── Vignette + frame ──────────────────────────────────────────────────────────
-- Drawn after the scene so the frame never feeds the bloom pass. Everything is expressed as a
-- fraction of the square size so the artwork is resolution independent.

local function drawVignette(x, y, s)
	local band = s * 0.30
	local a = 150

	surface.SetDrawColor(0, 0, 0, a)
	surface.SetMaterial(MAT_GRAD_DOWN)
	surface.DrawTexturedRect(x, y, s, band)
	surface.SetMaterial(MAT_GRAD_UP)
	surface.DrawTexturedRect(x, y + s - band, s, band)
	surface.SetMaterial(MAT_GRAD)
	surface.DrawTexturedRect(x, y, band, s)
	surface.DrawTexturedRectRotated(x + s - band * 0.5, y + s * 0.5, band, s, 180)
end


-- ── Capture rig ───────────────────────────────────────────────────────────────

local rig = {
	active = false,
	ent = nil,
	target = nil,
	view = nil,
	pendingName = nil,
	hidden = nil,
	armedAt = nil,
}

-- Declared up here so the watchdog in PostRender can cancel a batch it has had to abort.
local queue

local function captureRect()
	local scrW, scrH = ScrW(), ScrH()

	return math.floor((scrW - scrH) * 0.5), 0, scrH
end

-- Yaw-invariant framing, same radius rule as ArtDeco.FitModelPanel: the model's XY diagonal or its
-- height, whichever is larger, so nothing pops in or out as the subject turns.
-- Bounds come from GetModelRenderBounds — the mesh's own extent.
--   GetRenderBounds is inflated by the entity so its VFX survive culling (the brazier's are +-450
--     around a +-48 model), which frames the subject as a speck.
--   GetModelBounds is the physics hull, which is not the mesh: the grimoire's runs 11 units below
--     its origin against a mesh that starts at 0, so centring on it hangs the book off-frame.
local function computeView(ent, t)
	local mn, mx = ent:GetModelRenderBounds()
	local size = mx - mn
	local radius = t.radius or math.max(math.sqrt(size.x * size.x + size.y * size.y), math.abs(size.z)) * 0.5
	if radius < 1 then radius = 1 end

	local lookAt = ent:LocalToWorld((mn + mx) * 0.5)
	if t.lookZ then lookAt = lookAt + Vector(0, 0, t.lookZ) end

	local fov = t.fov or 40
	local aspect = ScrW() / ScrH()
	-- The crop is the centred square, so the subject has to fit the VERTICAL field of view.
	local tanV = math.tan(math.rad(fov) * 0.5) / math.max(0.01, aspect)
	if tanV <= 0 then tanV = 0.5 end

	local dist = (radius / tanV) * (t.pad or 1.2)

	-- dir is in the subject's own frame (x forward, y right, z up), so "the front" means the same
	-- thing for every entity no matter which way it was left facing.
	local d = t.dir or Vector(1, -0.35, 0.30)
	local ang = ent:GetAngles()
	local dir = (ang:Forward() * d.x + ang:Right() * d.y + ang:Up() * d.z):GetNormalized()
	local origin = lookAt + dir * dist

	-- camRoll rotates the photograph in the image plane. It exists because the entity route is a
	-- dead end for this: with the camera riding the subject's own axes, flipping the subject
	-- rotates the whole rig and produces the identical picture (measured, not guessed — pitch
	-- -90 and +90 exports of the grimoire diff to framing noise).
	local viewAng = (lookAt - origin):Angle()
	viewAng.roll = t.camRoll or 0

	return {
		origin = origin,
		angles = viewAng,
		fov = fov,
		znear = 1,
		zfar = math.max(4096, dist * 4),
		drawviewer = false,
	}
end

local function hideScene(subject)
	local hidden = {}
	local center = subject:GetPos()
	local rSqr = KEEP_RADIUS * KEEP_RADIUS

	for _, e in ipairs(ents.GetAll()) do
		if not IsValid(e) or e == subject then continue end
		if e:GetNoDraw() then continue end

		if e:IsPlayer() or e:GetPos():DistToSqr(center) > rSqr then
			hidden[#hidden + 1] = e
			e:SetNoDraw(true)
		end
	end

	return hidden
end

local function restoreScene()
	if not rig.hidden then return end

	for _, e in ipairs(rig.hidden) do
		if IsValid(e) then
			e:SetNoDraw(false)
		end
	end

	rig.hidden = nil
end

-- Pulled out of the hook table and put back afterwards, rather than gated by a flag: these belong
-- to systems the exporter does not own.
local mutedBackup

local function muteHooks()
	mutedBackup = {}

	for _, h in ipairs(MUTED_HOOKS) do
		local event, name = h[1], h[2]
		local tbl = hook.GetTable()[event]
		local fn = tbl and tbl[name]

		if fn then
			mutedBackup[#mutedBackup + 1] = {event, name, fn}
			hook.Remove(event, name)
		end
	end
end

local function unmuteHooks()
	if not mutedBackup then return end

	for _, h in ipairs(mutedBackup) do
		hook.Add(h[1], h[2], h[3])
	end

	mutedBackup = nil
end

local NOOP = function() end

-- Assigning to the instance shadows the class method for this one entity. Restoring puts the
-- original function back explicitly rather than clearing the key: clearing does NOT fall back to
-- the class method on a scripted entity, it just leaves the method nil, which killed the
-- emissary's _DrawTearShape for the rest of the session after its shot.
local suppressed

local function applySuppression(ent, t)
	suppressed = nil
	if not (t.suppress and IsValid(ent)) then return end

	suppressed = {}

	for _, name in ipairs(t.suppress) do
		suppressed[name] = ent[name]
		ent[name] = NOOP
	end
end

local function clearSuppression(ent)
	if not (suppressed and IsValid(ent)) then
		suppressed = nil

		return
	end

	for name, fn in pairs(suppressed) do
		ent[name] = fn
	end

	suppressed = nil
end

local function disarm()
	clearSuppression(rig.ent)
	unmuteHooks()
	restoreScene()
	rig.active = false
	rig.ent = nil
	rig.target = nil
	rig.view = nil
	rig.pendingName = nil
	rig.armedAt = nil
	rig.blankTries = nil
end

local function arm(ent, t)
	if not IsValid(ent) then return false end

	buildBackdrop()
	muteHooks()
	applySuppression(ent, t)
	rig.ent = ent
	rig.target = t
	rig.view = computeView(ent, t)
	rig.hidden = hideScene(ent)
	rig.armedAt = RealTime()
	rig.active = true

	return true
end

-- ── Hooks ─────────────────────────────────────────────────────────────────────
-- Registered unconditionally so a hot-reload replaces them instead of being skipped.

hook.Add("CalcView", "Arcana_SpawnIconRig", function()
	if not rig.active or not rig.view then return end
	if not IsValid(rig.ent) then
		disarm()

		return
	end

	return rig.view
end)

hook.Add("ShouldDrawLocalPlayer", "Arcana_SpawnIconRig", function()
	if rig.active then return false end
end)

hook.Add("PreDrawViewModel", "Arcana_SpawnIconRig", function()
	if rig.active then return true end
end)

hook.Add("PreDrawPlayerHands", "Arcana_SpawnIconRig", function()
	if rig.active then return true end
end)

hook.Add("HUDShouldDraw", "Arcana_SpawnIconRig", function()
	if rig.active then return false end
end)

-- This is the world replacement. The hook fires after the world has been drawn, so painting a
-- fullscreen 2D pass here erases it from the colour buffer, and ClearDepth drops its depth with
-- it so nothing left behind can occlude the subject. No cheat convars involved — r_drawworld is
-- FCVAR_CHEAT and would need sv_cheats.
hook.Add("PreDrawOpaqueRenderables", "Arcana_SpawnIconRig", function(bDrawingDepth, bDrawingSkybox)
	if not rig.active or bDrawingDepth or bDrawingSkybox then return end

	-- Ahead of the OPAQUE pass, not the translucent one. Some of what preDraw fixes up is opaque
	-- geometry — the emissary's grimoire is a plain ClientsideModel — and running after the opaque
	-- pass repositions it a full pass too late, so the frame still shows it where Think last put it.
	if rig.target and rig.target.preDraw and IsValid(rig.ent) then
		pcall(rig.target.preDraw, rig.ent)
	end

	cam.Start2D()
	blitBackdrop()
	cam.End2D()

	render.ClearDepth()

	if USE_STUDIO_LIGHT then
		render.SuppressEngineLighting(true)

		for box, c in pairs(STUDIO_LIGHT) do
			render.SetModelLighting(box, c[1], c[2], c[3])
		end
	end
end)

hook.Add("PostDrawOpaqueRenderables", "Arcana_SpawnIconRig", function(bDrawingDepth, bDrawingSkybox)
	if not rig.active or bDrawingDepth or bDrawingSkybox then return end

	if USE_STUDIO_LIGHT then
		render.SuppressEngineLighting(false)
	end
end)


hook.Add("PostRender", "Arcana_SpawnIconRig", function()
	if not rig.active then return end

	if rig.armedAt and RealTime() - rig.armedAt > MAX_ARM_SECONDS then
		queue = nil
		disarm()
		MsgC(Color(255, 160, 60), "[ArcanaIcons] Watchdog: rig was armed too long, disarmed.\n")

		return
	end

	local x, y, s = captureRect()

	cam.Start2D()
	drawVignette(x, y, s)
	drawFrame(x, y, s)
	cam.End2D()

	local name = rig.pendingName
	if not name then return end
	rig.pendingName = nil

	-- alpha = false: render.SetWriteDepthToDestAlpha is on for most scene draws, and capturing
	-- with alpha would bake the depth buffer into the icon's alpha channel.
	local png = render.Capture({format = "png", x = x, y = y, w = s, h = s, alpha = false})

	if not png then
		MsgC(Color(255, 80, 80), "[ArcanaIcons] Capture returned nil (escape menu open?) — " .. name .. "\n")

		return
	end

	-- A capture taken while the window is not rendering comes back a uniform black frame, which
	-- compresses to a fraction of a real icon (real ones run 500 KB+). One black frame is not a
	-- verdict — the window may regain focus a frame later — so re-queue the capture and only give
	-- up if the shot window runs out, rather than silently writing a blank tile.
	if #png < 60 * 1024 then
		rig.blankTries = (rig.blankTries or 0) + 1
		rig.pendingName = name

		if rig.blankTries == 1 then
			MsgC(Color(255, 160, 60), "[ArcanaIcons] " .. name .. " capturing blank — retrying while armed. Keep the game window focused.\n")
		end

		return
	end

	rig.blankTries = nil

	local path = OUTPUT .. "/" .. name .. ".png"
	file.Write(path, png)
	MsgC(Color(120, 230, 120), string.format("[ArcanaIcons]  %-40s  %d x %d  %d KB\n", path, s, s, math.floor(#png / 1024)))
end)

-- ── Subject sourcing ──────────────────────────────────────────────────────────

local function findSubject(t)
	local best, bestDist
	local eye = LocalPlayer():EyePos()

	for _, e in ipairs(ents.FindByClass(t.class)) do
		-- Skip carried weapons: a grimoire equipped by the exporting player reports the player's
		-- own position, so it always wins the nearest-check against the staged world copy — and a
		-- holstered weapon renders no world model, which photographs as an empty frame.
		if IsValid(e) and not IsValid(e:GetOwner()) then
			local d = e:GetPos():DistToSqr(eye)

			if not bestDist or d < bestDist then
				best, bestDist = e, d
			end
		end
	end

	return best
end

-- ── Batch export ──────────────────────────────────────────────────────────────

local function finish()
	disarm()
	queue = nil
	RunConsoleCommand("arcana_spawnicon_setup", "none")
	MsgC(Color(180, 255, 180), "[ArcanaIcons] Done — files in data/" .. OUTPUT .. "/\n")
end

local function step()
	if not queue then return end

	local t = table.remove(queue, 1)

	if not t then
		finish()

		return
	end

	-- Ask the server to clear the world and stage this subject alone, so nothing another entity
	-- draws through a global system can land in the shot.
	RunConsoleCommand("arcana_spawnicon_setup", t.class)

	timer.Simple(STAGE_WAIT + (t.settle or 2), function()
		local subject = findSubject(t)

		if not IsValid(subject) then
			MsgC(Color(255, 160, 60), "[ArcanaIcons] " .. t.class .. " did not stage, skipped.\n")
			step()

			return
		end

		if not arm(subject, t) then
			step()

			return
		end

		rig.pendingName = t.class

		-- Held armed for a beat: a frame for the rig to take effect, the rest as headroom for the
		-- blank-capture retry loop before PostRender gives up on the shot.
		timer.Simple(0.4, function()
			disarm()
			timer.Simple(0.35, step)
		end)
	end)
end

concommand.Add("arcana_export_spawnicons", function(_, _, args)
	-- Staging clears the world before each shot, so two batches running at once destroy each
	-- other's subject and both come out full of holes.
	if queue then
		MsgC(Color(255, 160, 60), "[ArcanaIcons] An export is already running.\n")

		return
	end

	file.CreateDir("arcana")
	file.CreateDir(OUTPUT)

	local only = args and args[1]
	queue = {}

	for _, t in ipairs(TARGETS) do
		if not only or only == "" or t.class == only then
			queue[#queue + 1] = t
		end
	end

	if #queue == 0 then
		MsgC(Color(255, 80, 80), "[ArcanaIcons] No target matching '" .. tostring(only) .. "'\n")

		return
	end

	MsgC(Color(180, 255, 180), "[ArcanaIcons] Exporting " .. #queue .. " icon(s)...\n")
	step()
end)

concommand.Add("arcana_spawnicon_preview", function(_, _, args)
	local class = args and args[1]

	if not class or class == "" or class == "off" then
		disarm()
		MsgC(Color(180, 255, 180), "[ArcanaIcons] Preview off.\n")

		return
	end

	local t = TARGET_BY_CLASS[class]

	if not t then
		MsgC(Color(255, 80, 80), "[ArcanaIcons] '" .. class .. "' is not a configured target.\n")

		return
	end

	local ent = findSubject(t)

	if not IsValid(ent) then
		MsgC(Color(255, 160, 60), "[ArcanaIcons] Spawn a " .. class .. " first.\n")

		return
	end

	disarm()
	arm(ent, t)
	MsgC(Color(180, 255, 180), "[ArcanaIcons] Previewing " .. class .. " — 'arcana_spawnicon_preview off' to stop.\n")
end)

-- Panic button. The rig hides entities with SetNoDraw and remembers what it hid, but that record
-- lives in this file's state: a map change wipes it while the entities stay hidden, and the result
-- is a client that renders almost nothing and cannot recover on its own. This sweeps every hidden
-- entity rather than the remembered set, which is blunt (props something else deliberately hid
-- come back too) but always works. Reconnect afterwards if you want a truly clean slate.
concommand.Add("arcana_spawnicon_reset", function()
	queue = nil
	disarm()

	local n = 0

	for _, e in ipairs(ents.GetAll()) do
		if IsValid(e) and e:GetNoDraw() then
			e:SetNoDraw(false)
			n = n + 1
		end
	end

	-- Only means anything inside a render pass, so release it from one.
	hook.Add("PostRender", "Arcana_SpawnIconResetLight", function()
		render.SuppressEngineLighting(false)
		hook.Remove("PostRender", "Arcana_SpawnIconResetLight")
	end)

	MsgC(Color(180, 255, 180), "[ArcanaIcons] Reset — un-hid " .. n .. " entities, rig disarmed.\n")
end)

MsgC(Color(180, 255, 180), "[ArcanaIcons] Loaded. arcana_spawnicon_preview <class> / arcana_export_spawnicons / arcana_spawnicon_reset\n")
