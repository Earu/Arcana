-- Procedural crystal flowers for the garden.
--
-- One stem mesh and one petal mesh are built once in unit space, then drawn
-- per flower through a model matrix, the same approach as the condensator's
-- glass cube (arcana_condensator.lua getBoxMesh).  Growth opens the petals and
-- extends the stem, wither droops them, and the element only changes the tint,
-- so nothing is ever rebuilt at runtime.

if not CLIENT then return end

Arcana = Arcana or {}
Arcana.Gardening = Arcana.Gardening or {}
-- Named apart from Arcana.Gardening.Flowers, which is config.lua's table of
-- flower definitions: sharing that key merged the renderer into the defs and
-- only survived on load order.
Arcana.Gardening.FlowerRender = Arcana.Gardening.FlowerRender or {}

local F = Arcana.Gardening.FlowerRender

-- World units at full growth.  Sized against the player, who stands 72 units:
-- a garden flower reading at roughly a third of that clears the bed's 22 unit
-- rim without looming over whoever planted it.  The head stays a large
-- fraction of the whole, or the stalk reads as a lollipop stick.
local STEM_HEIGHT = 16
local STEM_RADIUS = 0.6
local PETAL_LENGTH = 8.5
local PETAL_COUNT = 6

-- Per-flower height spread, so a bed does not come out as one flat canopy
local HEIGHT_VARIANCE = 0.26

-- Petal pitch: nearly closed as a bud, opening into a cup when mature.  Fully
-- flat petals read as a paper daisy, so the open angle keeps a lift.  Negative
-- pitch points up in Source.
local PITCH_CLOSED = -78
local PITCH_OPEN = -34
local PITCH_DROOP = 92 -- added at full wither, so dying petals hang down

local WITHER_COLOR = Color(104, 96, 82)

-- How far the whole plant flops over once it is fully withered.  Petals alone
-- going grey reads as a lighting change; the stalk giving way reads as dying.
local STEM_SAG = 62
local PETAL_SHRINK = 0.4

-- Which way a given plant keels over, and how far it has got.  Colour drains
-- faster than it accrues so the first minute of starving is already visible.
local function plantFrame(ang, wither, seed)
	if wither <= 0.001 then return ang end

	local lean = math.rad(((seed or 0) * 97) % 360)
	local sag = wither * wither * STEM_SAG
	local out = Angle(ang.p, ang.y, ang.r)

	out:RotateAroundAxis(ang:Forward(), sag * math.cos(lean))
	out:RotateAroundAxis(ang:Right(), sag * math.sin(lean))

	return out
end

-- Storm arcs.  Stateless: the bolt shape is seeded from the flower and the
-- current phase, so it re-rolls a fixed number of times a second and holds
-- still in between rather than needing anything stored per flower.
local ARC_MAT = Material("trails/laser")
local ARC_FLASH = Material("sprites/light_glow02_add")
local ARC_RATE = 12
local ARC_SEGMENTS = 4

local function arcHash(a, b, c)
	local n = math.sin(a * 12.9898 + b * 78.233 + c * 37.719) * 43758.5453

	return n - math.floor(n)
end

local function drawArcs(head, up, col, strength, seed)
	local phase = math.floor(CurTime() * ARC_RATE)

	render.SetMaterial(ARC_MAT)

	for k = 1, 3 do
		-- Only some phases carry a bolt, so it cracks intermittently instead
		-- of streaming
		if arcHash(seed, phase, k) < 0.2 + 0.45 * strength then
			local a = arcHash(seed, phase, k + 10) * math.pi * 2
			local tilt = -0.5 + arcHash(seed, phase, k + 20) * 1.7
			local dir = (Vector(math.cos(a), math.sin(a), 0) * math.cos(tilt) + up * math.sin(tilt)):GetNormalized()
			local len = 7 + arcHash(seed, phase, k + 30) * 8
			local prev = head

			for i = 1, ARC_SEGMENTS do
				local t = i / ARC_SEGMENTS
				local j = k * 100 + i
				local jitter = Vector(arcHash(seed, phase, j) - 0.5, arcHash(seed, phase, j + 40) - 0.5, arcHash(seed, phase, j + 80) - 0.5) * 5

				local p = head + dir * (len * t) + jitter * (1 - t * 0.25)
				render.DrawBeam(prev, p, 1.8 * (1 - t * 0.55), 0, 1, Color(col.r, col.g, col.b, 255))
				prev = p
			end
		end
	end

	-- The bloom itself flashes with the discharge
	local flash = arcHash(seed, phase, 7)

	if flash > 0.45 then
		render.SetMaterial(ARC_FLASH)
		local size = (5 + flash * 9) * strength
		render.DrawSprite(head, size, size, Color(col.r, col.g, col.b, 190))
	end
end

local function witherFrac(wither)
	return math.pow(math.Clamp(wither or 0, 0, 1), 0.6)
end

local MAX_DRAW_DIST = 1500
local SIMPLE_DRAW_DIST = 700

-- Faceted shading is baked into vertex colors: UnlitGeneric ignores normals,
-- so without this every facet would read as one flat silhouette.
local FACET_LIGHT = Vector(0.35, 0.25, 0.90)
local FACET_AMBIENT = 0.52
local FACET_RANGE = 0.48
-- The stalk gets a wider range: at 0.52 ambient a cylinder barely varies and
-- reads as a flat green strip
local STEM_AMBIENT = 0.3
local STEM_RANGE = 0.7

local petalMesh
local matCache = {}

-- The same refractive shader the mana crystals use, so a crystal flower's
-- petals are made of the same stuff (arcana_mana_crystal.lua).  One shared
-- material re-tinted per flower, the way the condensator drives its glass.
local CRYSTAL_PS = "arcana_crystal_surface_ps30"
local CRYSTAL_VS = "arcana_crystal_surface_vs30"
local crystalMat

WaitForShaderMounted({CRYSTAL_PS, CRYSTAL_VS}, function(available)
	if not available then return end

	crystalMat = CreateShaderMaterial("arcana_flower_crystal", {
		["$pixshader"] = CRYSTAL_PS,
		["$vertexshader"] = CRYSTAL_VS,
		-- A real texture, not the baseline's empty string: SetTexture on a
		-- string-typed var warns instead of binding the framebuffer grab
		["$basetexture"] = "models/debug/debugwhite",
		["$vertexnormal"] = 1,
		["$vertexcolor"] = 1,
		["$alpha_blend"] = 1,
		["$nocull"] = 1,
		["$linearwrite"] = 1,
		["$linearread_basetexture"] = 1,
		["$ignorez"] = 0,
		["$depthtest"] = 1,
		["$writedepth"] = 0,
		-- every $c component written at draw time must be declared here or the
		-- SetFloat is silently dropped
		["$c0_x"] = 0.22, -- dispersion strength
		["$c0_y"] = 4.0, -- fresnel power
		["$c0_z"] = 0.1, -- tint r
		["$c0_w"] = 0.5, -- tint g
		["$c1_x"] = 3.0, -- tint b
		["$c1_y"] = 1.0, -- opacity
		["$c1_z"] = 0.0, -- albedo blend: the solid pass beneath supplies it
		["$c1_w"] = 0.35, -- selfillum glow
		["$c2_x"] = 0, -- time
		["$c2_y"] = 12, -- noise scale
		["$c2_z"] = 0.6, -- grain
		["$c2_w"] = 0.2, -- sparkle
		["$c3_x"] = 0.15, -- thickness
		["$c3_y"] = 12, -- facet quantisation
		["$c3_z"] = 8, -- bounce fade
		["$c3_w"] = 1.4, -- bounce steps
	})
end)

-- One framebuffer grab per garden rather than per flower: the crystal entity
-- can afford four passes each because there is one of it, a bed has ten.
function F.BeginBatch()
	if not crystalMat then return false end

	local scr = Arcana.GetScreenScratchRT and Arcana.GetScreenScratchRT()
	if not scr then return false end

	render.CopyRenderTargetToTexture(scr)
	crystalMat:SetTexture("$basetexture", scr)
	crystalMat:SetFloat("$c2_x", math.fmod(RealTime(), 1000))

	return true
end

----------------------------------------------------------------------
-- Mesh building
----------------------------------------------------------------------
FACET_LIGHT:Normalize()

local function facetShade(n)
	return FACET_AMBIENT + FACET_RANGE * math.max(0, n:Dot(FACET_LIGHT))
end

-- Emits a triangle with a flat facet normal and its baked shading.
local function addTri(a, b, c)
	local n = (b - a):Cross(c - a)
	if n:LengthSqr() < 1e-9 then return end

	n:Normalize()

	local shade = facetShade(n)
	local v = math.floor(math.Clamp(shade, 0, 1) * 255)

	for _, p in ipairs({a, b, c}) do
		mesh.Position(p)
		mesh.Normal(n)
		mesh.TexCoord(0, 0, 0)
		mesh.Color(v, v, v, 255)
		mesh.AdvanceVertex()
	end
end

-- Explicit normal and shade, for surfaces that should read as curved rather
-- than faceted.  addTri bakes one flat normal per triangle, which on a stalk
-- shows up as hard bands around the cylinder.
local function addSmoothVert(p, n, u, v, shade)
	local c = math.floor(math.Clamp(shade, 0, 1) * 255)

	mesh.Position(p)
	mesh.Normal(n)
	mesh.TexCoord(0, u, v)
	mesh.Color(c, c, c, 255)
	mesh.AdvanceVertex()
end

-- Quad as two triangles, wound so the face points along wantDir.
local function addQuad(a, b, c, d, wantDir)
	local n = (b - a):Cross(c - a)

	if n:Dot(wantDir) < 0 then
		a, b, c, d = d, c, b, a
	end

	addTri(a, b, c)
	addTri(a, c, d)
end

local STEM_SIDES = 10
local STEM_RINGS = 9

-- Stalks differ per plant rather than every flower standing on the same rod.
-- curve is the sideways reach of the tip in radius units, twist spirals the
-- ring, thorns are spikes set along the upper stem.
local STEM_VARIANTS = {
	{curve = 0.0, twist = 0, thorns = 0, taper = 0.55},
	{curve = 2.4, twist = 45, thorns = 0, taper = 0.50},
	{curve = 3.6, twist = -30, thorns = 3, taper = 0.45},
	{curve = 1.5, twist = 95, thorns = 5, taper = 0.60},
	{curve = 4.8, twist = 20, thorns = 2, taper = 0.40},
}

local stemMeshes = {}

-- Where the stalk's tip sits, in the same radius units, so the head can ride
-- a curved stem instead of hanging in the air above a bent one.
function F.StemTip(variant)
	local v = STEM_VARIANTS[variant] or STEM_VARIANTS[1]

	return v.curve
end

function F.StemVariant(def, seed)
	local pool = def and def.stems or {1}

	return pool[(math.floor(seed or 0) % #pool) + 1]
end

local function getStemMesh(variant)
	local built = stemMeshes[variant]
	if built then return built end

	local v = STEM_VARIANTS[variant] or STEM_VARIANTS[1]

	-- A ring of centres following the curve, each rotated by the twist
	local rings = {}

	for r = 0, STEM_RINGS do
		local t = r / STEM_RINGS
		-- Quadratic, so the stalk leaves the soil upright and leans as it rises
		local cx = v.curve * t * t
		local radius = Lerp(t, 1, v.taper)
		local spin = math.rad(v.twist * t)
		local pts, norms = {}, {}

		for i = 0, STEM_SIDES - 1 do
			local a = (i / STEM_SIDES) * math.pi * 2 + spin
			pts[i + 1] = Vector(cx + math.cos(a) * radius, math.sin(a) * radius, t)
			-- Radial, shared between the faces either side of it, so the shading
			-- runs smoothly around the stalk
			norms[i + 1] = Vector(math.cos(a), math.sin(a), 0)
		end

		rings[r + 1] = {pts = pts, norms = norms, cx = cx, radius = radius, t = t}
	end

	local tris = STEM_RINGS * STEM_SIDES * 2 + (STEM_SIDES - 2) + v.thorns * 3

	built = Mesh()
	mesh.Begin(built, MATERIAL_TRIANGLES, tris)

	-- Darker toward the soil, so the stalk has depth along its length as well
	-- as around it
	local function stemShade(n, t)
		return (STEM_AMBIENT + STEM_RANGE * math.max(0, n:Dot(FACET_LIGHT))) * (0.62 + 0.38 * t)
	end

	for r = 1, STEM_RINGS do
		local lower, upper = rings[r], rings[r + 1]

		for i = 1, STEM_SIDES do
			local j = i % STEM_SIDES + 1
			local ln, lnj = lower.norms[i], lower.norms[j]
			local un, unj = upper.norms[i], upper.norms[j]

			addSmoothVert(lower.pts[i], ln, 0, lower.t, stemShade(ln, lower.t))
			addSmoothVert(lower.pts[j], lnj, 1, lower.t, stemShade(lnj, lower.t))
			addSmoothVert(upper.pts[j], unj, 1, upper.t, stemShade(unj, upper.t))

			addSmoothVert(lower.pts[i], ln, 0, lower.t, stemShade(ln, lower.t))
			addSmoothVert(upper.pts[j], unj, 1, upper.t, stemShade(unj, upper.t))
			addSmoothVert(upper.pts[i], un, 0, upper.t, stemShade(un, upper.t))
		end
	end

	local cap = rings[STEM_RINGS + 1].pts

	for i = 2, STEM_SIDES - 1 do
		addTri(cap[1], cap[i], cap[i + 1])
	end

	-- Thorns: a flat spike off the stalk, angled back down the way a real one
	-- sits.  Spread up the upper two thirds and around the stem.
	for k = 1, v.thorns do
		local t = 0.3 + (k / (v.thorns + 1)) * 0.6
		local r = math.floor(t * STEM_RINGS) + 1
		local ring = rings[math.Clamp(r, 1, STEM_RINGS + 1)]
		local a = k * 2.399 -- golden angle, so they spiral rather than line up
		local dir = Vector(math.cos(a), math.sin(a), 0)
		local base = Vector(ring.cx, 0, ring.t)
		local root = base + dir * ring.radius * 0.9
		local tip = base + dir * (ring.radius + 1.5) - Vector(0, 0, 0.055)
		local side = Vector(-dir.y, dir.x, 0) * ring.radius * 0.5

		addTri(root - side, root + side, tip)
		addTri(root + side, root - side, tip)
		addTri(root - side, tip, root + side)
	end

	mesh.End()

	stemMeshes[variant] = built

	return built
end

-- Blade running along +X so a petal's angles point its length directly.
-- Half widths run along Y, the raised centre ridge along Z.
local PETAL_SPINE = {
	{x = 0.00, w = 0.12, zt = 0.05, zb = -0.03},
	{x = 0.35, w = 0.50, zt = 0.26, zb = -0.13},
	{x = 0.70, w = 0.36, zt = 0.15, zb = -0.08},
	{x = 1.00, w = 0.00, zt = 0.00, zb = 0.00},
}

local UP = Vector(0, 0, 1)
local DOWN = Vector(0, 0, -1)

local function getPetalMesh()
	if petalMesh then return petalMesh end

	local segs = #PETAL_SPINE - 1

	petalMesh = Mesh()
	-- Four quads per segment: top and bottom, left and right of the ridge
	mesh.Begin(petalMesh, MATERIAL_TRIANGLES, segs * 8)

	for i = 1, segs do
		local a, b = PETAL_SPINE[i], PETAL_SPINE[i + 1]
		local ridgeA, ridgeB = Vector(a.x, 0, a.zt), Vector(b.x, 0, b.zt)
		local baseA, baseB = Vector(a.x, 0, a.zb), Vector(b.x, 0, b.zb)
		local leftA, leftB = Vector(a.x, -a.w, 0), Vector(b.x, -b.w, 0)
		local rightA, rightB = Vector(a.x, a.w, 0), Vector(b.x, b.w, 0)

		addQuad(ridgeA, ridgeB, leftB, leftA, UP)
		addQuad(ridgeA, rightA, rightB, ridgeB, UP)
		addQuad(baseA, leftA, leftB, baseB, DOWN)
		addQuad(baseA, baseB, rightB, rightA, DOWN)
	end

	mesh.End()

	return petalMesh
end

----------------------------------------------------------------------
-- Materials
----------------------------------------------------------------------
-- One material per element rather than one shared material re-tinted per
-- draw: the fae lantern documents that sharing makes instances swap colors by
-- draw order.  $model is deliberately left off, since with it set $color2 is
-- ignored on a raw mesh draw.
local function getMaterial(id)
	local mat = matCache[id]

	if not mat then
		mat = CreateMaterial("arcana_flower_" .. id, "UnlitGeneric", {
			["$basetexture"] = "models/debug/debugwhite",
			["$vertexcolor"] = 1,
			["$nocull"] = 1,
			["$color2"] = "[1 1 1]",
		})

		matCache[id] = mat
	end

	return mat
end

local tintVec = Vector(1, 1, 1)

local function setTint(mat, col, mul)
	tintVec:SetUnpacked((col.r / 255) * mul, (col.g / 255) * mul, (col.b / 255) * mul)
	mat:SetVector("$color2", tintVec)
end

----------------------------------------------------------------------
-- Drawing
----------------------------------------------------------------------
-- Stable per-petal variation: math.random would flicker every frame.
local function hash01(a, b)
	local n = math.sin(a * 12.9898 + b * 78.233) * 43758.5453

	return n - math.floor(n)
end

local scaleVec = Vector(1, 1, 1)

local function drawMeshAt(built, pos, ang, sx, sy, sz)
	local m = Matrix()
	scaleVec:SetUnpacked(sx, sy, sz)
	m:SetTranslation(pos)
	m:SetAngles(ang)
	m:SetScale(scaleVec)

	cam.PushModelMatrix(m)
	built:Draw()
	cam.PopModelMatrix()
end

-- Where a flower's bloom sits, so effects can be hung off it without
-- duplicating the stem maths.
function F.HeadPos(pos, ang, def, growth, seed, wither)
	local variance = 1 + (hash01(seed or 0, 91) - 0.5) * HEIGHT_VARIANCE
	local stemH = STEM_HEIGHT * variance * (0.28 + 0.72 * math.Clamp(growth or 0, 0, 1))
	local stemR = STEM_RADIUS * (0.55 + 0.45 * math.Clamp(growth or 0, 0, 1))

	return LocalToWorld(Vector(F.StemTip(F.StemVariant(def, seed)) * stemR, 0, stemH), angle_zero, pos, plantFrame(ang, wither or 0, seed))
end

-- Ambient term so flowers sit in the map's lighting instead of glowing flat.
function F.AmbientAt(pos)
	local light = render.ComputeLighting(pos, UP)
	local lum = math.max(light.x, light.y, light.z)

	return math.Clamp(math.pow(math.max(lum, 0), 0.4545), 0.35, 1)
end

-- pos: base of the stem, ang: the bed's orientation (stem grows along its up)
-- growth and wither are 0..1, seed keeps each slot's jitter stable.
function F.Draw(pos, ang, def, growth, wither, seed, ambient)
	local dist = EyePos():Distance(pos)
	if dist > MAX_DRAW_DIST then return end

	growth = math.Clamp(growth or 0, 0, 1)
	wither = math.Clamp(wither or 0, 0, 1)
	ambient = ambient or 1

	local col = def.color or Color(222, 198, 120)
	local drain = witherFrac(wither)
	local tint = Color(Lerp(drain, col.r, WITHER_COLOR.r), Lerp(drain, col.g, WITHER_COLOR.g), Lerp(drain, col.b, WITHER_COLOR.b))

	-- Everything below works in the plant's own frame, which keels over as it
	-- dies rather than staying bolt upright with grey petals
	ang = plantFrame(ang, wither, seed)

	local mat = getMaterial(def.id or "basic")
	local variance = 1 + (hash01(seed or 0, 91) - 0.5) * HEIGHT_VARIANCE
	local stemH = STEM_HEIGHT * variance * (0.28 + 0.72 * growth)
	local stemR = STEM_RADIUS * (0.55 + 0.45 * growth)
	local variant = F.StemVariant(def, seed)
	local curve = F.StemTip(variant)
	-- The head rides the stalk's tip, which a curved stem carries off to one
	-- side rather than straight overhead
	local head = LocalToWorld(Vector(curve * stemR, 0, stemH), angle_zero, pos, ang)

	-- The bloom sits square to the stalk, not to the ground: the tip tangent of
	-- x = curve * t^2 is 2 * curve, against the stem's own height.  Its frame is
	-- that tangent plus the bed's forward made perpendicular to it.
	local headUp = (ang:Forward() * (2 * curve * stemR) + ang:Up() * stemH):GetNormalized()
	local headFwd = ang:Forward() - headUp * ang:Forward():Dot(headUp)

	if headFwd:LengthSqr() < 1e-6 then headFwd = ang:Right() end

	headFwd:Normalize()

	local headRight = headUp:Cross(headFwd)

	-- Stem stays green-leaning whatever the element, so the bloom reads as the
	-- flower head rather than the whole plant.
	local stemCol = Color(Lerp(drain, 120, 96), Lerp(drain, 170, 84), Lerp(drain, 110, 58))

	render.SetMaterial(mat)
	setTint(mat, stemCol, ambient)
	drawMeshAt(getStemMesh(variant), pos, ang, stemR, stemR, stemH)

	-- Curling in on itself as well as drooping
	local petalLen = PETAL_LENGTH * (0.35 + 0.65 * growth) * (1 - drain * PETAL_SHRINK)

	local built = getPetalMesh()
	local basePitch = Lerp(growth, PITCH_CLOSED, PITCH_OPEN) + wither * PITCH_DROOP
	local yawBase = ((seed or 0) * 37) % 360
	-- Past this range the petals cover a couple of pixels, so one upright
	-- blade reads the same as six and costs a single draw.
	local petals = dist <= SIMPLE_DRAW_DIST and (def.petals or PETAL_COUNT) or 1

	-- Worked out once and reused by both passes
	local xforms = {}

	for i = 1, petals do
		local jitterA = hash01(seed or 0, i)
		local jitterB = hash01(i, seed or 0)
		local yaw = yawBase + (i - 1) * (360 / petals) + (jitterA - 0.5) * 12
		local pitch = basePitch + (jitterB - 0.5) * 10
		local len = petalLen * (0.85 + jitterA * 0.3)

		-- Built in the head's own frame, so petals splay around the stalk's
		-- axis and a leaning plant tips its flower with it
		local local_ = Angle(pitch, yaw, 0):Forward()
		local dir = headFwd * local_.x + headRight * local_.y + headUp * local_.z

		xforms[i] = {ang = dir:Angle(), len = len}
	end

	-- Solid element colour first, refraction over the top.  The mana crystal
	-- does the same (base model, then shader passes): without an albedo pass
	-- underneath, the dispersion has nothing to tint and comes out as rainbow
	-- noise rather than a coloured crystal.
	setTint(mat, tint, ambient)
	render.SetMaterial(mat)

	for i = 1, petals do
		local t = xforms[i]
		drawMeshAt(built, head, t.ang, t.len, t.len, t.len)
	end

	if def.arcs and dist <= SIMPLE_DRAW_DIST and growth >= 0.55 and wither < 0.85 then
		drawArcs(head, headUp, col, growth * (1 - wither), seed or 0)
	end

	if crystalMat then
		crystalMat:SetFloat("$c0_z", tint.r / 255 * 1.5)
		crystalMat:SetFloat("$c0_w", tint.g / 255 * 1.5)
		crystalMat:SetFloat("$c1_x", tint.b / 255 * 1.5)
		crystalMat:SetFloat("$c1_y", 0.4 * (1 - wither * 0.7))

		render.SetMaterial(crystalMat)

		for i = 1, petals do
			local t = xforms[i]
			drawMeshAt(built, head, t.ang, t.len * 1.008, t.len * 1.008, t.len * 1.008)
		end
	end

end

-- Tallest a flower can reach, used to size the garden's render bounds.  Takes
-- the height spread into account so the luckiest slot is still covered.
function F.MaxHeight()
	return STEM_HEIGHT * (1 + HEIGHT_VARIANCE * 0.5) + PETAL_LENGTH
end
