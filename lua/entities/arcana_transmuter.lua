-- The Transmuter: matter laid out on one side comes back as something else on
-- the other.  Crystal dust and a reagent become elemental dust; dust on its own
-- comes back as coin.  Nothing is sold here and nothing is free.
--
-- The bench is built clientside: a marble slab with brass inlays carrying a
-- balance scale that hunts equilibrium, five crucible cups of element dust,
-- and a rune stream flowing between the two pans.

AddCSLuaFile()

ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "Transmuter"
ENT.Author = "Earu"
ENT.Category = "Arcana"
ENT.Spawnable = true
ENT.AdminOnly = false
ENT.RenderGroup = RENDERGROUP_BOTH
ENT.UseCooldown = 0.75

-- Only the collision volume; the visible bench is procedural
local TABLE_MODEL = "models/props/cs_italy/it_mkt_table3.mdl"

if SERVER then
	util.AddNetworkString("Arcana_Transmuter_Open")
	util.AddNetworkString("Arcana_Transmuter_Exchange")
	util.AddNetworkString("Arcana_Transmuter_Flourish")

	resource.AddFile("materials/entities/arcana_transmuter.png")
	resource.AddFile("materials/arcana/transmuter_inlay.vtf")
	resource.AddFile("materials/models/arcana/transmuter/brass.vmt")
	resource.AddFile("materials/models/arcana/transmuter/brass.vtf")
	resource.AddFile("materials/models/arcana/transmuter/brass_normal.vtf")

	for _, piece in ipairs({"scale_column", "scale_beam", "scale_pan"}) do
		resource.AddFile("models/arcana/transmuter/" .. piece .. ".mdl")
		resource.AddFile("models/arcana/transmuter/" .. piece .. ".vvd")
		resource.AddFile("models/arcana/transmuter/" .. piece .. ".dx80.vtx")
		resource.AddFile("models/arcana/transmuter/" .. piece .. ".dx90.vtx")
	end

	function ENT:Initialize()
		self:SetModel(TABLE_MODEL)
		self:PhysicsInit(SOLID_VPHYSICS)
		self:SetMoveType(MOVETYPE_VPHYSICS)
		self:SetSolid(SOLID_VPHYSICS)
		self:SetUseType(SIMPLE_USE)
		self:DrawShadow(false)

		local phys = self:GetPhysicsObject()

		if IsValid(phys) then
			phys:Wake()
			phys:EnableMotion(false)
		end

		self._nextUse = 0
	end

	function ENT:SpawnFunction(ply, tr, classname)
		if not tr or not tr.Hit then return end

		local ent = ents.Create(classname or "arcana_transmuter")
		if not IsValid(ent) then return end

		ent:SetPos(tr.HitPos + tr.HitNormal * 4)
		ent:SetAngles(Angle(0, ply:EyeAngles().y + 90, 0))
		ent:Spawn()
		ent:Activate()

		return ent
	end

	function ENT:Use(ply)
		if not IsValid(ply) or not ply:IsPlayer() then return end

		local now = CurTime()
		if now < (self._nextUse or 0) then return end
		self._nextUse = now + self.UseCooldown

		net.Start("Arcana_Transmuter_Open")
		net.WriteEntity(self)
		net.Send(ply)

		self:EmitSound("buttons/button9.wav", 60, 100)
	end

	----------------------------------------------------------------------
	-- Request handling
	----------------------------------------------------------------------
	local lastAction = {}
	local ACTION_COOLDOWN = 0.4

	local function rateOk(ply)
		local sid = ply:SteamID64()
		local now = CurTime()
		if (lastAction[sid] or 0) + ACTION_COOLDOWN > now then return false end
		lastAction[sid] = now

		return true
	end

	hook.Add("PlayerDisconnected", "Arcana_Transmuter_RateClear", function(ply)
		lastAction[ply:SteamID64()] = nil
	end)

	local function readStation(ply)
		if not IsValid(ply) or not rateOk(ply) then return end

		local ent = net.ReadEntity()
		if not IsValid(ent) or ent:GetClass() ~= "arcana_transmuter" then return end
		if ply:GetPos():DistToSqr(ent:GetPos()) > Arcana.Gardening.USE_RANGE ^ 2 then return end

		return ent
	end

	-- The client sends only what was laid out and how many times to repeat it.
	-- What that is worth is worked out here from the same shared resolver the
	-- menu draws from, so a forged payload buys nothing it should not.
	net.Receive("Arcana_Transmuter_Exchange", function(_, ply)
		local G = Arcana.Gardening
		local ent = readStation(ply)
		local n = net.ReadUInt(4)
		local inputs = {}

		for i = 1, math.min(n, G.MAX_INPUTS) do
			inputs[i] = net.ReadString()
		end

		-- 0 asks for as many as the offering will bear
		local want = net.ReadUInt(8)
		if not ent then return end

		local result = G.ResolveExchange(inputs)

		if not result then
			Arcana.SendErrorNotification(ply, "Nothing comes of that")

			return
		end

		local function held(item)
			return Arcana.GetItemCount(ply, item)
		end

		local most = G.MaxRepeats(result.cost, held)
		local reps = want == 0 and most or math.min(want, most)

		if reps < 1 then
			Arcana.SendErrorNotification(ply, "Not enough to give")

			return
		end

		-- The whole cost is checked through MaxRepeats before a single item is
		-- taken, so a partial exchange cannot happen.
		for item, amount in pairs(result.cost) do
			Arcana.TakeItem(ply, item, amount * reps, "Transmutation")
		end

		if result.kind == "coins" then
			Arcana.GiveCoins(ply, result.coins * reps, "Transmutation")
			ent:EmitSound("ambient/levels/labs/coinslot1.wav", 60, 110, 0.6)
		else
			for item, amount in pairs(result.give) do
				Arcana.GiveItem(ply, item, amount * reps, "Transmutation")
			end

			ent:EmitSound("arcana/arcane_" .. math.random(1, 3) .. ".ogg", 75, 105, 0.6)
		end

		net.Start("Arcana_Transmuter_Flourish", true)
		net.WriteEntity(ent)
		net.WriteColor(result.color or Color(222, 198, 120), false)
		net.WriteBool(result.kind == "recipe")
		net.Broadcast()
	end)
end

if CLIENT then
	local MOTE_MATERIAL = Material("sprites/light_glow02_add")
	local PALE_GOLD = Color(222, 198, 120)
	local MAX_FX_DIST = 900 * 900
	local THINK_GATE = 1500 * 1500

	local STONE_MATERIAL = CreateMaterial("arcana_transmuter_marble", "UnlitGeneric", {
		["$basetexture"] = "stone/marblefloor001b",
		["$vertexcolor"] = 1,
		["$color2"] = "[1 1 1]",
	})
	local BRASS_MATERIAL = CreateMaterial("arcana_transmuter_brass", "UnlitGeneric", {
		["$basetexture"] = "vgui/white",
		["$vertexcolor"] = 1,
		["$color2"] = "[1 1 1]",
	})
	-- White-on-transparent linework (tools/build_transmuter_inlay.py), tinted
	-- gold through $color2 like the brass
	local INLAY_MATERIAL = CreateMaterial("arcana_transmuter_inlay", "UnlitGeneric", {
		["$basetexture"] = "arcana/transmuter_inlay",
		["$translucent"] = 1,
		["$vertexcolor"] = 1,
		["$color2"] = "[1 1 1]",
	})

	local STONE_TINT = Vector(1, 1, 1)
	local BRASS_TINT = Vector(0.78, 0.58, 0.30)

	-- Bench geometry, all in entity space.  The collision model underneath is
	-- the old market table, so the slab keeps roughly its footprint.
	local SLAB_TOP = 28.5
	local PIVOT_Z = 53.4
	local BEAM_HALF = 26
	local PAN_HANG = 9
	local CUP_X = 13
	local CUP_SPREAD = 26

	----------------------------------------------------------------------
	-- Procedural meshes.  UnlitGeneric ignores normals, so every face bakes
	-- its own shade from a fixed key light and the whole thing is tinted by
	-- sampled world light at draw time (the garden soil approach).
	----------------------------------------------------------------------
	local LIGHT_DIR = Vector(0.35, 0.25, 0.9):GetNormalized()

	local function shadeFor(n)
		return 0.45 + 0.55 * math.max(0, n:Dot(LIGHT_DIR))
	end

	local function pushQuad(acc, a, b, c, d, uv, col)
		-- a..d wind counter-clockwise seen from outside; the outward normal
		-- for shading follows the right-hand rule from that order
		local n = (b - a):Cross(c - a)
		n:Normalize()

		local s = shadeFor(n)
		local r, g, bl = col.r * s, col.g * s, col.b * s

		local function v(p, u, vv)
			acc[#acc + 1] = {p = p, u = u or 0, v = vv or 0, r = r, g = g, b = bl}
		end

		-- Source treats clockwise winding as front-facing, so the triangles
		-- are emitted in reverse or every face renders inside-out
		uv = uv or {0, 0, 1, 0, 1, 1, 0, 1}
		v(a, uv[1], uv[2]) v(c, uv[5], uv[6]) v(b, uv[3], uv[4])
		v(a, uv[1], uv[2]) v(d, uv[7], uv[8]) v(c, uv[5], uv[6])
	end

	local function addBoxFrame(acc, c, ax, ay, az, col, uvScale)
		local function uvFor(e1, e2)
			if not uvScale then return nil end

			local l1, l2 = e1:Length() * 2 * uvScale, e2:Length() * 2 * uvScale

			return {0, 0, l1, 0, l1, l2, 0, l2}
		end

		pushQuad(acc, c - ax - ay + az, c + ax - ay + az, c + ax + ay + az, c - ax + ay + az, uvFor(ax, ay), col)
		pushQuad(acc, c - ax + ay - az, c + ax + ay - az, c + ax - ay - az, c - ax - ay - az, uvFor(ax, ay), col)
		pushQuad(acc, c - ax - ay - az, c + ax - ay - az, c + ax - ay + az, c - ax - ay + az, uvFor(ax, az), col)
		pushQuad(acc, c + ax + ay - az, c - ax + ay - az, c - ax + ay + az, c + ax + ay + az, uvFor(ax, az), col)
		pushQuad(acc, c + ax - ay - az, c + ax + ay - az, c + ax + ay + az, c + ax - ay + az, uvFor(ay, az), col)
		pushQuad(acc, c - ax + ay - az, c - ax - ay - az, c - ax - ay + az, c - ax + ay + az, uvFor(ay, az), col)
	end

	local function addBox(acc, center, hx, hy, hz, col, uvScale)
		addBoxFrame(acc, center, Vector(hx, 0, 0), Vector(0, hy, 0), Vector(0, 0, hz), col, uvScale)
	end

	-- inward = true turns the wall into an interior surface (recess lining)
	local function addCylinder(acc, base, r, h, segs, col, rTop, inward)
		rTop = rTop or r

		for i = 0, segs - 1 do
			local a0 = (i / segs) * math.pi * 2
			local a1 = ((i + 1) / segs) * math.pi * 2
			local c0, s0 = math.cos(a0), math.sin(a0)
			local c1, s1 = math.cos(a1), math.sin(a1)
			local p1 = base + Vector(c0 * r, s0 * r, 0)
			local p2 = base + Vector(c1 * r, s1 * r, 0)
			local p3 = base + Vector(c1 * rTop, s1 * rTop, h)
			local p4 = base + Vector(c0 * rTop, s0 * rTop, h)

			if inward then
				pushQuad(acc, p2, p1, p4, p3, nil, col)
			else
				pushQuad(acc, p1, p2, p3, p4, nil, col)
			end
		end
	end

	local function addDisc(acc, center, r, segs, col, down, rInner)
		rInner = rInner or 0

		for i = 0, segs - 1 do
			local a0 = (i / segs) * math.pi * 2
			local a1 = ((i + 1) / segs) * math.pi * 2
			local c0, s0 = math.cos(a0), math.sin(a0)
			local c1, s1 = math.cos(a1), math.sin(a1)
			local o1 = center + Vector(c0 * r, s0 * r, 0)
			local o2 = center + Vector(c1 * r, s1 * r, 0)
			local i1 = center + Vector(c0 * rInner, s0 * rInner, 0)
			local i2 = center + Vector(c1 * rInner, s1 * rInner, 0)

			if down then
				pushQuad(acc, o2, o1, i1, i2, nil, col)
			else
				pushQuad(acc, o1, o2, i2, i1, nil, col)
			end
		end
	end

	local function buildMesh(acc)
		local m = Mesh()
		mesh.Begin(m, MATERIAL_TRIANGLES, #acc / 3)

		for _, vt in ipairs(acc) do
			mesh.Position(vt.p)
			mesh.TexCoord(0, vt.u, vt.v)
			mesh.Color(vt.r, vt.g, vt.b, 255)
			mesh.AdvanceVertex()
		end

		mesh.End()

		return m
	end

	local WHITE = Color(255, 255, 255)
	local CUP_COL = Color(200, 200, 205)

	-- Shared across every transmuter; rebuilt when the recipe roster changes
	-- so a new dust registers as one more crucible cup.
	local meshes = nil
	local meshCupCount = -1

	local function cupPos(i, n)
		local fy = n == 1 and 0 or (-1 + 2 * (i - 1) / (n - 1))

		return Vector(CUP_X, fy * CUP_SPREAD, SLAB_TOP)
	end

	local function destroyMeshes()
		if not meshes then return end

		for _, m in pairs(meshes) do
			if m and m.Destroy then m:Destroy() end
		end

		meshes = nil
	end

	local function buildMeshes()
		destroyMeshes()

		local recipes = Arcana.Gardening.Recipes
		local n = #recipes
		meshCupCount = n
		meshes = {}

		-- stone: slab with an overhung lip on two trestle legs, plus the cups
		local stone = {}
		addBox(stone, Vector(0, 0, 24.5), 20, 34, 2.5, WHITE, 1 / 68)
		addBox(stone, Vector(0, 0, 27.75), 21, 35, 0.75, WHITE, 1 / 68)
		addBox(stone, Vector(0, -24, 11), 13, 2.6, 11, WHITE, 1 / 30)
		addBox(stone, Vector(0, 24, 11), 13, 2.6, 11, WHITE, 1 / 30)
		addBox(stone, Vector(0, -24, 1.2), 15, 3.4, 1.2, WHITE, 1 / 30)
		addBox(stone, Vector(0, 24, 1.2), 15, 3.4, 1.2, WHITE, 1 / 30)

		for i = 1, n do
			local cp = cupPos(i, n)
			addCylinder(stone, cp, 2.5, 2.3, 10, CUP_COL, 2.2)
			addDisc(stone, cp + Vector(0, 0, 2.3), 2.85, 10, CUP_COL, false, 1.85)
			-- interior lining between the rim and the dust heap
			addCylinder(stone, cp + Vector(0, 0, 1.55), 1.85, 0.75, 10, CUP_COL, nil, true)
		end

		meshes.stone = buildMesh(stone)

		-- dust heaps, vertex-colored per element
		local dust = {}

		for i = 1, n do
			local cp = cupPos(i, n)
			local col = recipes[i].color
			addCylinder(dust, cp + Vector(0, 0, 1.55), 1.85, 0.9, 10, col, 0.3)
			addDisc(dust, cp + Vector(0, 0, 2.45), 0.3, 10, col, false)
		end

		meshes.dust = buildMesh(dust)

		-- inlay artwork quad over the whole slab top; u runs along the long
		-- axis, matching tools/build_transmuter_inlay.py
		local inlay = {}
		local TOP = SLAB_TOP + 0.05
		pushQuad(inlay,
			Vector(-21, -35, TOP), Vector(21, -35, TOP), Vector(21, 35, TOP), Vector(-21, 35, TOP),
			{0, 0, 0, 1, 1, 1, 1, 0}, WHITE)
		meshes.inlay = buildMesh(inlay)

		-- graduated scale weights on the back edge
		local weights = {}

		for _, wd in ipairs({{r = 1.7, h = 3.0, y = -7}, {r = 1.35, h = 2.4, y = -1.5}, {r = 1.05, h = 1.9, y = 3.2}}) do
			local base = Vector(-13.5, wd.y, SLAB_TOP)
			addCylinder(weights, base, wd.r, wd.h, 10, WHITE, wd.r * 0.82)
			addDisc(weights, base + Vector(0, 0, wd.h), wd.r * 0.82, 10, WHITE, false)
			addCylinder(weights, base + Vector(0, 0, wd.h), 0.32, 0.55, 6, WHITE, 0.5)
			addDisc(weights, base + Vector(0, 0, wd.h + 0.55), 0.5, 6, WHITE, false)
		end

		-- a hoop banding each crucible; follows the cup count, which is why it
		-- lives in a mesh rather than the inlay texture
		for i = 1, n do
			local cp = cupPos(i, n)
			addCylinder(weights, cp + Vector(0, 0, 0.65), 2.62, 0.55, 10, WHITE)
			addDisc(weights, cp + Vector(0, 0, 1.2), 2.62, 10, WHITE, false, 2.38)
		end

		meshes.weights = buildMesh(weights)
	end

	local function ensureMeshes()
		if meshes and meshCupCount == #Arcana.Gardening.Recipes then return end
		buildMeshes()
	end

	----------------------------------------------------------------------
	-- Entity
	----------------------------------------------------------------------
	function ENT:Initialize()
		ensureMeshes()

		self._scale = {}

		for i, piece in ipairs({"scale_column", "scale_beam", "scale_pan", "scale_pan"}) do
			local mdl = ClientsideModel("models/arcana/transmuter/" .. piece .. ".mdl", RENDERGROUP_OPAQUE)

			if IsValid(mdl) then
				mdl:SetNoDraw(true)
				self._scale[i] = mdl
			end
		end

		self._flourishUntil = 0
		self._flourishColor = PALE_GOLD
		self._flourishRecipe = true
		self._beamAng = 0
		self._beamVel = 0
		self._beamBias = 0
		self._sparkPhase = math.Rand(0, 10)

		-- The scale rises well past the collision model
		self:SetRenderBounds(self:OBBMins() - Vector(10, 10, 4), self:OBBMaxs() + Vector(10, 10, 40))
	end

	function ENT:OnRemove()
		for _, mdl in pairs(self._scale or {}) do
			if IsValid(mdl) then mdl:Remove() end
		end

		self._scale = nil
	end

	function ENT:Think()
		-- Scheduled before the work so an early bail keeps the think ticking
		self:SetNextClientThink(CurTime() + 0.05)

		local now = CurTime()

		-- Damped spring: the beam forever hunts equilibrium, and an exchange
		-- loads one pan through _beamBias for a dip-and-recover
		local target = math.sin(now * 0.5) * 1.3 + (self._beamBias or 0)
		local ang = self._beamAng or 0
		local vel = self._beamVel or 0
		vel = vel + ((target - ang) * 6 - vel * 1.6) * 0.05
		ang = ang + vel * 0.05
		self._beamAng = ang
		self._beamVel = vel
		self._beamBias = (self._beamBias or 0) * 0.92

		if EyePos():DistToSqr(self:GetPos()) > THINK_GATE then return true end

		-- No idle light: the bench has nothing glowing to motivate one.  An
		-- exchange does, so its color throws light while it runs.
		if now < self._flourishUntil then
			local dl = DynamicLight(self:EntIndex())

			if dl then
				local col = self._flourishColor
				dl.pos = self:GetPos() + self:GetUp() * 46
				dl.r, dl.g, dl.b = col.r, col.g, col.b
				dl.brightness = 0.9
				dl.size = 140
				-- Recreated every think, so any decay strobes whatever the
				-- light touches (the lit scale models flash; unlit meshes hide it)
				dl.decay = 0
				dl.dietime = now + 0.15
			end
		end

		return true
	end

	local function lightTint(self)
		local l = render.ComputeLighting(self:GetPos() + Vector(0, 0, 40), Vector(0, 0, 1))

		return math.Clamp(math.max(l.x, l.y, l.z) ^ 0.4545, 0.45, 1)
	end

	local function beamMatrix(self)
		local bm = Matrix()
		bm:Translate(Vector(0, 0, PIVOT_Z))
		bm:Rotate(Angle(0, 0, self._beamAng or 0))

		return bm
	end

	local function panHook(bm, side)
		return bm * Vector(0, side == 1 and -BEAM_HALF or BEAM_HALF, -0.9)
	end

	function ENT:Draw()
		ensureMeshes()
		if not meshes then return end

		local b = lightTint(self)
		STONE_MATERIAL:SetVector("$color2", STONE_TINT * b)
		BRASS_MATERIAL:SetVector("$color2", BRASS_TINT * b)
		INLAY_MATERIAL:SetVector("$color2", BRASS_TINT * (b * 1.1))

		local em = self:GetWorldTransformMatrix()

		render.SetMaterial(STONE_MATERIAL)
		cam.PushModelMatrix(em)
		meshes.stone:Draw()
		cam.PopModelMatrix()

		render.SetMaterial(INLAY_MATERIAL)
		cam.PushModelMatrix(em)
		meshes.inlay:Draw()
		cam.PopModelMatrix()

		render.SetMaterial(BRASS_MATERIAL)
		cam.PushModelMatrix(em)
		meshes.weights:Draw()
		cam.PopModelMatrix()

		-- the scale itself is proper models, so the engine lights it
		local ang = self:GetAngles()
		local bm = beamMatrix(self)
		local scale = self._scale or {}
		local column, beam, panL, panR = scale[1], scale[2], scale[3], scale[4]

		if IsValid(column) then
			column:SetPos(self:LocalToWorld(Vector(0, 0, SLAB_TOP)))
			column:SetAngles(ang)
			column:DrawModel()
		end

		if IsValid(beam) then
			local bang = Angle(ang.p, ang.y, ang.r)
			bang:RotateAroundAxis(self:GetForward(), self._beamAng or 0)
			beam:SetPos(self:LocalToWorld(Vector(0, 0, PIVOT_Z)))
			beam:SetAngles(bang)
			beam:DrawModel()
		end

		for side, pan in ipairs({panL, panR}) do
			if IsValid(pan) then
				pan:SetPos(self:LocalToWorld(panHook(bm, side)))
				pan:SetAngles(ang)
				pan:DrawModel()
			end
		end

		BRASS_MATERIAL:SetVector("$color2", Vector(1, 1, 1) * math.max(0.6, b))
		render.SetMaterial(BRASS_MATERIAL)
		cam.PushModelMatrix(em)
		meshes.dust:Draw()
		cam.PopModelMatrix()
	end

	function ENT:_DrawGlowQuads(alphaScale)
		local now = CurTime()
		local recipes = Arcana.Gardening.Recipes
		local n = #recipes

		render.SetMaterial(MOTE_MATERIAL)

		-- dust glow and 1px sparkles above each cup
		for i = 1, n do
			local col = recipes[i].color
			local base = self:LocalToWorld(cupPos(i, n) + Vector(0, 0, 2.5))
			render.DrawSprite(base + Vector(0, 0, 0.4), 3.4, 3.4, Color(col.r, col.g, col.b, 46 * alphaScale))

			for k = 1, 2 do
				local t = (now * 0.16 + i * 0.37 + k * 0.5 + self._sparkPhase) % 1
				local sway = math.sin(now * 0.9 + i * 2 + k * 3) * 0.9
				local alpha = math.sin(t * math.pi) * 80 * alphaScale
				render.DrawSprite(base + Vector(sway * 0.4, sway, t * 9), 1.4, 1.4, Color(col.r, col.g, col.b, alpha))
			end
		end

		-- the receiving pan glows while an exchange settles
		if now < self._flourishUntil + 0.6 then
			local bm = beamMatrix(self)
			local em = self:GetWorldTransformMatrix()
			local panPos = em * panHook(bm, self._flourishRecipe and 2 or 1) + self:GetUp() * (-PAN_HANG + 1.6)
			local k = math.Clamp((self._flourishUntil + 0.6 - now) / 1.8, 0, 1)
			local col = self._flourishColor
			render.DrawSprite(panPos, 9, 9, Color(col.r, col.g, col.b, 120 * k * alphaScale))
		end
	end

	function ENT:DrawTranslucent()
		if EyePos():DistToSqr(self:GetPos()) > MAX_FX_DIST then return end

		local bloom = Arcana.Bloom

		if bloom and bloom.ProcessBloom then
			-- The bloom only ever sees a faint copy which becomes the halo;
			-- the readable pass sits crisp on top (altar idiom)
			bloom.ProcessBloom(function() self:_DrawGlowQuads(0.45) end)
			bloom.RenderBloom(0.35, true)
		end

		self:_DrawGlowQuads(1)
	end

	net.Receive("Arcana_Transmuter_Flourish", function()
		local ent = net.ReadEntity()
		local col = net.ReadColor(false)
		local isRecipe = net.ReadBool()
		if not IsValid(ent) or ent:GetClass() ~= "arcana_transmuter" then return end

		ent._flourishUntil = CurTime() + 1.4
		ent._flourishColor = Color(col.r, col.g, col.b)
		ent._flourishRecipe = isRecipe
		-- The offering pan takes the weight: tip toward it, then settle level
		ent._beamBias = isRecipe and -7 or 7
		ent._beamVel = (ent._beamVel or 0) + (isRecipe and -6 or 6)
		ent:EmitSound("physics/metal/metal_box_impact_soft2.wav", 55, 130, 0.35)
	end)
end
