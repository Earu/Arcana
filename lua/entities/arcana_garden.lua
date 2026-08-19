-- The Crystal Garden: a planter that turns crystal dust into more of it.
-- Flowers draw upkeep from the garden's own reserve while they grow; starve
-- them and they wither, then die and free the slot.

AddCSLuaFile()

ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "Crystal Garden"
ENT.Author = "Earu"
ENT.Category = "Arcana"
ENT.Spawnable = true
ENT.AdminOnly = false
-- Opaque only.  Under RENDERGROUP_BOTH the base class's DrawTranslucent falls
-- back to Draw, so the crate, soil and flowers were all drawn a second time in
-- the translucent pass, where they sort against particles by distance and
-- paint over them depending on where you stand.
ENT.RenderGroup = RENDERGROUP_OPAQUE
ENT.UseCooldown = 0.75

local GARDEN_MODEL = "models/props/cs_italy/it_mkt_container3.mdl"
local GARDEN_SCALE = 3.5

-- The container's inner floor, read off the model's own upward-facing face:
-- x +-15, y +-10 at z 0 in model space.  Taken from the mesh rather than as a
-- fraction of the collision box, so the soil reaches the walls exactly.
local INTERIOR_X = 15 * GARDEN_SCALE
local INTERIOR_Y = 10 * GARDEN_SCALE
local SOIL_EDGE = 4 -- height of the soil where it meets the walls
local SOIL_PEAK = 14 -- height at the middle of the heap

-- Soil heaped into the box: full in the middle, tapering to a lip at the
-- walls, with a little deterministic roughness so it does not read as a
-- moulded dome.  u and v run -1..1 across the interior.
local function soilHeight(u, v)
	local dome = (1 - u * u) * (1 - v * v)
	-- Two octaves, the finer one carrying most of the amplitude: a smooth dome
	-- has near-vertical normals everywhere and shades as a flat sheet however
	-- high it actually rises, so the surface needs real relief to read.
	local rough = math.sin(u * 6.1) * math.cos(v * 5.3) * 1.6 + math.sin(u * 14.7 + v * 11.3) * 0.9 + math.cos(u * 19.1 - v * 16.7) * 0.55

	return SOIL_EDGE + (SOIL_PEAK - SOIL_EDGE) * dome + rough * (0.35 + 0.65 * dome)
end

function ENT:SetupDataTables()
	self:NetworkVar("Int", 0, "DustReserve")
	self:NetworkVar("Int", 1, "PendingDust")
	self:NetworkVar("String", 0, "GardenSlots")

	if SERVER then
		self:SetDustReserve(0)
		self:SetPendingDust(0)
		self:SetGardenSlots("")
	end
end

-- Local position of a planting slot, laid out two rows deep across the bed and
-- seated on the soil surface rather than a flat plane.
function ENT:SlotLocalPos(index)
	local cols = Arcana.Gardening.SLOT_COLUMNS
	local col = (index - 1) % cols
	local row = math.floor((index - 1) / cols)
	local u = -0.76 + col * (1.52 / (cols - 1))
	local v = row == 0 and -0.42 or 0.42

	return Vector(u * INTERIOR_X, v * INTERIOR_Y, soilHeight(u, v))
end

if SERVER then
	util.AddNetworkString("Arcana_Garden_Open")
	util.AddNetworkString("Arcana_Garden_State")
	util.AddNetworkString("Arcana_Garden_Plant")
	util.AddNetworkString("Arcana_Garden_Deposit")
	util.AddNetworkString("Arcana_Garden_Harvest")
	util.AddNetworkString("Arcana_Garden_Uproot")
	util.AddNetworkString("Arcana_Garden_Close")

	resource.AddFile("materials/entities/arcana_garden.png")

	function ENT:Initialize()
		self:SetModel(GARDEN_MODEL)
		self:SetModelScale(GARDEN_SCALE)
		self:SetUseType(SIMPLE_USE)

		-- SetModelScale leaves the vphysics mesh at its original size, so the
		-- hull is rebuilt from the scaled model bounds instead.
		local mins, maxs = self:GetModelBounds()
		self:PhysicsInitBox(mins * GARDEN_SCALE, maxs * GARDEN_SCALE)
		self:SetCollisionBounds(mins * GARDEN_SCALE, maxs * GARDEN_SCALE)

		-- After PhysicsInitBox, never before: it leaves the entity on
		-- SOLID_BBOX, which is a world-axis-aligned box that ignores the
		-- entity's angles.  A bed spawned at any yaw but a right angle would
		-- then collide well outside the crate it draws.
		self:SetMoveType(MOVETYPE_VPHYSICS)
		self:SetSolid(SOLID_VPHYSICS)

		local phys = self:GetPhysicsObject()

		if IsValid(phys) then
			phys:Wake()
			phys:EnableMotion(false)
		end

		self._nextUse = 0
		self._flowers = {}
		self._fallow = {}
		self._reserve = 0
		self._pending = 0
		self._pendingElem = {}
		self._openers = {}
		self._lastPacked = ""

		self:NextThink(CurTime() + Arcana.Gardening.TICK)
	end

	function ENT:SpawnFunction(ply, tr, classname)
		if not tr or not tr.Hit then return end

		local ent = ents.Create(classname or "arcana_garden")
		if not IsValid(ent) then return end

		ent:SetPos(tr.HitPos + tr.HitNormal * 4)
		ent:SetAngles(Angle(0, ply:EyeAngles().y + 90, 0))
		ent:Spawn()
		ent:Activate()

		return ent
	end

	function ENT:GetFlowers()
		return self._flowers or {}
	end

	function ENT:CountFlowers()
		local n = 0

		for _, f in pairs(self._flowers or {}) do
			if f then n = n + 1 end
		end

		return n
	end

	function ENT:SendState(ply)
		local targets = ply

		if not targets then
			targets = {}

			for p in pairs(self._openers or {}) do
				if IsValid(p) then targets[#targets + 1] = p end
			end

			-- Bail before net.Start: an abandoned message stays open and the
			-- next one to start is discarded in its favour.
			if #targets == 0 then return end
		end

		local elems = {}

		-- Only whole units: the fractional remainder is an internal accrual and
		-- a player can never be handed half an item, so it never goes on the
		-- wire and never reaches the UI.
		for item, amount in pairs(self._pendingElem or {}) do
			local whole = math.floor(amount)

			if whole >= 1 then
				elems[#elems + 1] = {item = item, amount = whole}
			end
		end

		net.Start("Arcana_Garden_State")
		net.WriteEntity(self)
		net.WriteUInt(#elems, 4)

		for _, e in ipairs(elems) do
			net.WriteString(e.item)
			net.WriteUInt(math.min(e.amount, 65535), 16)
		end

		net.Send(targets)
	end

	function ENT:_PushState()
		local G = Arcana.Gardening
		local packed = G.PackSlots(self._flowers, self._fallow)

		if packed ~= self._lastPacked then
			self._lastPacked = packed
			self:SetGardenSlots(packed)
		end

		local reserve = math.floor(self._reserve)
		if reserve ~= self:GetDustReserve() then self:SetDustReserve(reserve) end

		local pending = math.floor(self._pending)
		if pending ~= self:GetPendingDust() then self:SetPendingDust(pending) end

		self:SendState()
	end

	-- Adds one flower's produce to the unharvested piles.  Elemental dust only
	-- comes off a plant that has finished growing.
	function ENT:_Yield(item, amount, mature)
		local G = Arcana.Gardening

		if item == "crystal_dust" then
			self._pending = math.min(G.PENDING_CAP, self._pending + amount)
		elseif mature then
			self._pendingElem[item] = math.min(G.PENDING_ELEM_CAP, (self._pendingElem[item] or 0) + amount)
		end
	end

	-- A Storm flower letting go of its charge: the burst pays out at once, and
	-- the bolt has to land on something.  One planted neighbour catches it and
	-- is either scorched or jolted into growing.
	function ENT:_Discharge(index, dis, mult)
		for item, amount in pairs(dis.yield) do
			self:_Yield(item, amount * mult, true)
		end

		local targets = {}

		for _, j in ipairs(Arcana.Gardening.Neighbours(index)) do
			if self._flowers[j] then targets[#targets + 1] = j end
		end

		local hit = self._flowers[targets[math.random(#targets)] or 0]

		if hit then
			if math.random() < 0.5 then
				hit.wither = math.min(1, hit.wither + dis.scorch)
			else
				hit.growth = math.min(1, hit.growth + dis.jolt)
			end
		end

		self:EmitSound("ambient/energy/zap1.wav", 60, 130, 0.4)
	end

	function ENT:_Step(dt)
		local G = Arcana.Gardening
		local flowers = self._flowers
		-- Traits resolve against the whole bed before anything is charged for:
		-- what a flower costs and yields depends on what is planted beside it.
		local mods = G.ComputeMods(flowers)
		local owed = 0

		for i = 1, G.MAX_SLOTS do
			local f = flowers[i]
			local def = f and G.Flowers[f.id]

			if def and not def.selfFeeding then
				local m = mods[i]
				owed = owed + (def.upkeepPerMin + m.upkeepAdd) * m.upkeep * dt / 60
			end
		end

		local fed = owed <= 0 or self._reserve >= owed
		self._reserve = fed and math.max(0, self._reserve - owed) or 0

		for slot, left in pairs(self._fallow) do
			self._fallow[slot] = left > dt and (left - dt) or nil
		end

		for i = 1, G.MAX_SLOTS do
			local f = flowers[i]
			local def = f and G.Flowers[f.id]
			local m = mods[i]

			if not def then
				flowers[i] = nil
			else
				-- A self feeding flower is never starved, whatever the bed owes
				local supplied = fed or def.selfFeeding

				if def.rotPerSec and f.growth >= 1 then
					-- Rot is not starvation: no amount of dust reverses it
					f.wither = f.wither + dt * def.rotPerSec
				elseif supplied then
					f.wither = math.max(0, f.wither - dt / G.RECOVER_TIME)
				else
					f.wither = f.wither + (dt / G.WITHER_TIME) * m.wither
				end

				-- Whatever the neighbours are doing to it lands on top, and a
				-- full reserve is no protection from it
				f.wither = f.wither + dt * m.witherAdd

				if f.wither >= 1 then
					self:_Clear(i, def)
					self:EmitSound("physics/glass/glass_bottle_break1.wav", 60, 70, 0.45)
				elseif supplied then
					-- Starved plants only wither: without this the reserve buys
					-- nothing and a bed left empty still grows out and pays.
					f.growth = math.min(1, f.growth + (dt / G.MATURITY_TIME) * m.growth)

					local rate = f.growth * (1 - f.wither) * m.yield

					for item, perMin in pairs(def.yieldPerMin) do
						self:_Yield(item, perMin * (dt / 60) * rate, f.growth >= 1)
					end

					local dis = def.discharge

					if dis and f.growth >= 1 then
						f.charge = (f.charge or 0) + dt

						while f.charge >= dis.interval do
							f.charge = f.charge - dis.interval
							self:_Discharge(i, dis, rate)
						end
					end
				end
			end
		end
	end

	-- Frees a slot, poisoning the ground behind it where the flower calls for
	-- it.  Death and uprooting go through here alike, so waiting for a Blight to
	-- rot is no way to dodge the fallow ground it leaves.
	function ENT:_Clear(index, def)
		self._flowers[index] = nil

		if def and def.fallowOnUproot then
			self._fallow[index] = Arcana.Gardening.FALLOW_TIME
		end
	end

	-- Advances the garden by dt seconds.  Production scales with growth, so a
	-- single large step would pay the mature rate for the whole span: the work
	-- is split into tick-sized chunks and integrated instead.  That also keeps
	-- a stalled server from handing out a windfall on its next think.
	function ENT:_Advance(dt)
		local step = Arcana.Gardening.TICK
		local remaining = dt

		while remaining > 0 do
			local chunk = math.min(step, remaining)
			self:_Step(chunk)
			remaining = remaining - chunk
		end

		self:_PushState()
	end

	function ENT:Think()
		local G = Arcana.Gardening

		for p in pairs(self._openers) do
			if not IsValid(p) or p:GetPos():DistToSqr(self:GetPos()) > (G.USE_RANGE * 2) ^ 2 then
				self._openers[p] = nil
			end
		end

		self:_Advance(G.TICK)
		self:NextThink(CurTime() + G.TICK)

		return true
	end

	function ENT:Use(ply)
		if not IsValid(ply) or not ply:IsPlayer() then return end

		local now = CurTime()
		if now < (self._nextUse or 0) then return end
		self._nextUse = now + self.UseCooldown

		self._openers[ply] = true

		net.Start("Arcana_Garden_Open")
		net.WriteEntity(self)
		net.Send(ply)

		self:SendState(ply)
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

	hook.Add("PlayerDisconnected", "Arcana_Garden_Cleanup", function(ply)
		lastAction[ply:SteamID64()] = nil

		for _, ent in ipairs(ents.FindByClass("arcana_garden")) do
			if IsValid(ent) and ent._openers then
				ent._openers[ply] = nil
			end
		end
	end)

	-- Every request re-reads the entity, its class and the player's distance:
	-- the client is never trusted for any of it.
	local function readGarden(ply)
		if not IsValid(ply) or not rateOk(ply) then return end

		local ent = net.ReadEntity()
		if not IsValid(ent) or ent:GetClass() ~= "arcana_garden" then return end
		if ply:GetPos():DistToSqr(ent:GetPos()) > Arcana.Gardening.USE_RANGE ^ 2 then return end

		return ent
	end

	net.Receive("Arcana_Garden_Close", function(_, ply)
		local ent = readGarden(ply)
		if not ent then return end
		ent._openers[ply] = nil
	end)

	net.Receive("Arcana_Garden_Plant", function(_, ply)
		local G = Arcana.Gardening
		local ent = readGarden(ply)
		local slot = net.ReadUInt(8)
		local id = net.ReadString()
		if not ent then return end

		local def = G.Flowers[id]
		if not def then return end
		if slot < 1 or slot > G.MAX_SLOTS then return end
		if ent._flowers[slot] then return end

		if (ent._fallow[slot] or 0) > 0 then
			Arcana.SendErrorNotification(ply, "Nothing will take root in poisoned ground yet")

			return
		end

		-- A bed with nothing in the reserve cannot feed what it is given, so
		-- it refuses rather than taking the cost and letting it wither.  A
		-- flower that feeds itself has no such problem.
		if not def.selfFeeding and ent._reserve < def.upkeepPerMin then
			Arcana.SendErrorNotification(ply, "The garden needs Crystal Dust before anything will grow")

			return
		end

		-- Check the whole cost before taking any of it, so a partial payment
		-- can never happen.
		for item, amount in pairs(def.plantCost) do
			if Arcana.GetItemCount(ply, item) < amount then
				Arcana.SendErrorNotification(ply, "Not enough materials")

				return
			end
		end

		for item, amount in pairs(def.plantCost) do
			Arcana.TakeItem(ply, item, amount, "Planted a flower")
		end

		ent._flowers[slot] = {id = id, growth = 0, wither = 0}
		ent:_PushState()
		ent:EmitSound("physics/surfaces/sand_impact_bullet1.wav", 60, 110)
	end)

	net.Receive("Arcana_Garden_Uproot", function(_, ply)
		local G = Arcana.Gardening
		local ent = readGarden(ply)
		local slot = net.ReadUInt(8)
		if not ent then return end
		if slot < 1 or slot > G.MAX_SLOTS then return end

		local f = ent._flowers[slot]
		if not f then return end

		ent:_Clear(slot, G.Flowers[f.id])
		ent:_PushState()
		ent:EmitSound("physics/surfaces/sand_impact_bullet3.wav", 60, 95)
	end)

	net.Receive("Arcana_Garden_Deposit", function(_, ply)
		local G = Arcana.Gardening
		local ent = readGarden(ply)
		local want = net.ReadUInt(16)
		if not ent then return end

		local room = G.RESERVE_CAP - ent._reserve
		local amount = math.floor(math.min(want, room, Arcana.GetItemCount(ply, "crystal_dust")))

		if amount <= 0 then
			Arcana.SendErrorNotification(ply, "Nothing to deposit")

			return
		end

		if not Arcana.TakeItem(ply, "crystal_dust", amount, "Garden upkeep") then return end

		ent._reserve = ent._reserve + amount
		ent:_PushState()
		ent:EmitSound("ambient/levels/labs/electric_explosion5.wav", 55, 150, 0.35)
	end)

	net.Receive("Arcana_Garden_Harvest", function(_, ply)
		local ent = readGarden(ply)
		if not ent then return end

		local given = 0
		local dust = math.floor(ent._pending)

		if dust > 0 then
			Arcana.GiveItem(ply, "crystal_dust", dust, "Garden harvest")
			-- The fraction stays behind rather than being rounded away.
			ent._pending = ent._pending - dust
			given = given + dust
		end

		for item, amount in pairs(ent._pendingElem) do
			local n = math.floor(amount)

			if n > 0 then
				Arcana.GiveItem(ply, item, n, "Garden harvest")
				ent._pendingElem[item] = amount - n
				given = given + n
			end
		end

		if given <= 0 then
			Arcana.SendErrorNotification(ply, "Nothing ready to harvest")

			return
		end

		ent:_PushState()
		ent:EmitSound("physics/cardboard/cardboard_box_break1.wav", 60, 120, 0.5)
	end)
end

if CLIENT then
	local SOIL_MATERIAL = CreateMaterial("arcana_garden_soil", "UnlitGeneric", {
		["$basetexture"] = "nature/dirtfloor001a",
		["$vertexcolor"] = 1,
		["$nocull"] = 1,
		["$color2"] = "[1 1 1]",
	})

	local SOIL_TILING = 3
	local SOIL_COLS, SOIL_ROWS = 22, 15
	-- Baked facet shading: UnlitGeneric ignores normals, so without it the heap
	-- would read as a flat sheet however much it actually rises.
	local SOIL_LIGHT = Vector(0.3, 0.2, 0.93)
	SOIL_LIGHT:Normalize()

	local soilMesh

	local function getSoilMesh()
		if soilMesh then return soilMesh end

		local function vert(i, j)
			local u = -1 + 2 * (i / SOIL_COLS)
			local v = -1 + 2 * (j / SOIL_ROWS)

			return Vector(u * INTERIOR_X, v * INTERIOR_Y, soilHeight(u, v)), (i / SOIL_COLS) * SOIL_TILING, (j / SOIL_ROWS) * SOIL_TILING
		end

		soilMesh = Mesh()
		mesh.Begin(soilMesh, MATERIAL_TRIANGLES, SOIL_COLS * SOIL_ROWS * 2)

		for i = 0, SOIL_COLS - 1 do
			for j = 0, SOIL_ROWS - 1 do
				local a, au, av = vert(i, j)
				local b, bu, bv = vert(i + 1, j)
				local c, cu, cv = vert(i + 1, j + 1)
				local d, du, dv = vert(i, j + 1)

				for _, t in ipairs({{a, au, av, b, bu, bv, c, cu, cv}, {a, au, av, c, cu, cv, d, du, dv}}) do
					local n = (t[4] - t[1]):Cross(t[7] - t[1])

					if n:LengthSqr() > 1e-9 then
						n:Normalize()
						if n.z < 0 then n = -n end

						-- Soil sits darker than the crate around it
						local shade = math.floor(math.Clamp(0.52 + 0.48 * math.max(0, n:Dot(SOIL_LIGHT)), 0, 1) * 205)

						for k = 0, 2 do
							mesh.Position(t[k * 3 + 1])
							mesh.Normal(n)
							mesh.TexCoord(0, t[k * 3 + 2], t[k * 3 + 3])
							mesh.Color(shade, shade, shade, 255)
							mesh.AdvanceVertex()
						end
					end
				end
			end
		end

		mesh.End()

		return soilMesh
	end

	-- Additive glows read at a distance where a small opaque sprite vanishes.
	-- The smoke is alpha blended and so has to sort, which is fine now the
	-- entity draws opaque-only: what used to break it was the crate being
	-- redrawn in the translucent pass, not the sprite's blend mode.
	local FX_GLOW = "sprites/light_glow02_add"
	local FX_FLAME = "particles/flamelet5"
	local FX_SMOKE = "particle/particle_smokegrenade"
	local FX_DIST = 1100 * 1100

	-- One emitter for the whole bed rather than one per bloom
	function ENT:Initialize()
		self._slots = {}
		self._lastPacked = nil
		self._emitter = ParticleEmitter(self:GetPos(), false)
		self._nextFx = 0

		-- Flowers stand well above the crate and the default render bounds come
		-- from the model box, so they would be culled at grazing angles.  Grown
		-- from the collision box rather than the current bounds, so re-running
		-- this never stacks another flower's worth of headroom on top.
		local mins, maxs = self:OBBMins(), self:OBBMaxs()
		local F = Arcana.Gardening.FlowerRender
		self:SetRenderBounds(mins, Vector(maxs.x, maxs.y, maxs.z + (F and F.MaxHeight() or 44) + 8))
	end

	function ENT:OnRemove()
		if self._emitter then
			self._emitter:Finish()
			self._emitter = nil
		end
	end

	-- Each element gets its own behaviour off the bloom: what the flower is
	-- made of should be readable without opening the menu.
	local FX = {}

	function FX.fire(em, head, col)
		local p = em:Add(FX_FLAME, head + VectorRand() * 4)
		if not p then return end

		p:SetVelocity(Vector(math.Rand(-5, 5), math.Rand(-5, 5), math.Rand(16, 30)))
		p:SetDieTime(math.Rand(0.7, 1.2))
		p:SetStartAlpha(230) p:SetEndAlpha(0)
		p:SetStartSize(math.Rand(4, 7)) p:SetEndSize(0)
		p:SetColor(col.r, col.g, col.b)
		p:SetGravity(Vector(0, 0, 10))
		p:SetAirResistance(24)
		p:SetRoll(math.Rand(-180, 180))
		p:SetRollDelta(math.Rand(-2, 2))
	end

	function FX.frost(em, head, col)
		-- Frost falls rather than rises
		local p = em:Add(FX_GLOW, head + VectorRand() * 7)
		if not p then return end

		p:SetVelocity(Vector(math.Rand(-4, 4), math.Rand(-4, 4), math.Rand(-12, -4)))
		p:SetDieTime(math.Rand(1.2, 2.0))
		p:SetStartAlpha(210) p:SetEndAlpha(0)
		p:SetStartSize(math.Rand(3, 5.5)) p:SetEndSize(0)
		p:SetColor(col.r, col.g, col.b)
		p:SetGravity(Vector(0, 0, -6))
		p:SetAirResistance(40)
	end

	function FX.poison(em, head, col)
		-- Heavy spores that sag outward and settle
		local p = em:Add(FX_SMOKE, head + VectorRand() * 5)
		if not p then return end

		p:SetVelocity(Vector(math.Rand(-11, 11), math.Rand(-11, 11), math.Rand(-2, 7)))
		p:SetDieTime(math.Rand(1.6, 2.4))
		p:SetStartAlpha(120) p:SetEndAlpha(0)
		p:SetStartSize(math.Rand(4, 7)) p:SetEndSize(math.Rand(10, 16))
		p:SetColor(col.r, col.g, col.b)
		p:SetGravity(Vector(0, 0, -3))
		p:SetAirResistance(55)
		p:SetRoll(math.Rand(-180, 180))
		p:SetRollDelta(math.Rand(-0.8, 0.8))
	end

	function FX.arcane(em, head, col)
		-- Orbiting motes: launched on a tangent so they wheel around the bloom
		local a = math.Rand(0, math.pi * 2)
		local radius = math.Rand(2.5, 5)
		local at = head + Vector(math.cos(a) * radius, math.sin(a) * radius, math.Rand(-2, 4))
		local p = em:Add(FX_GLOW, at)
		if not p then return end

		p:SetVelocity(Vector(-math.sin(a), math.cos(a), 0) * math.Rand(16, 28) + Vector(0, 0, math.Rand(2, 9)))
		p:SetDieTime(math.Rand(0.9, 1.5))
		p:SetStartAlpha(230) p:SetEndAlpha(0)
		p:SetStartSize(math.Rand(5, 9)) p:SetEndSize(0)
		p:SetColor(col.r, col.g, col.b)
		p:SetGravity(Vector(0, 0, 2))
		p:SetAirResistance(30)
	end

	-- Clientside Think only repeats while it schedules itself and returns true,
	-- so the scheduling sits outside the work and every early bail still keeps
	-- the entity ticking.
	function ENT:Think()
		self:_ElementFx()
		self:SetNextClientThink(CurTime() + 0.05)

		return true
	end

	function ENT:_ElementFx()
		local em = self._emitter
		if not em then return end

		local now = CurTime()
		if now < (self._nextFx or 0) then return end
		self._nextFx = now + 0.06

		if EyePos():DistToSqr(self:GetPos()) > FX_DIST then return end

		self:_SyncSlots()

		local G = Arcana.Gardening
		local F = Arcana.Gardening.FlowerRender
		if not F or not F.HeadPos then return end

		-- The emitter's position is the sort origin.  Left at the entity origin
		-- it sits on the crate floor, so particles above the flowers sorted as
		-- though they were down inside the box.
		em:SetPos(self:GetPos() + self:GetUp() * 26)

		local ang = self:GetAngles()

		for i = 1, G.MAX_SLOTS do
			local slot = self._slots[i]
			local def = slot and G.Flowers[slot.id]
			local fx = def and FX[slot.id]

			-- Only what has grown into itself, and only while it is healthy
			-- enough to be doing anything
			if fx and slot.growth >= 0.6 and slot.wither < 0.7 then
				local strength = slot.growth * (1 - slot.wither)

				if math.random() < strength then
					-- Just clear of the petals: emitted at the head itself the
					-- bloom hides its own effect from most angles
					local head = F.HeadPos(self:LocalToWorld(self:SlotLocalPos(i)), ang, def, slot.growth, i, slot.wither) + self:GetUp() * 3

					fx(em, head, def.color)
				end
			end
		end
	end

	function ENT:_SyncSlots()
		local packed = self:GetGardenSlots()
		if packed == self._lastPacked then return end

		self._lastPacked = packed
		self._slots = Arcana.Gardening.UnpackSlots(packed)
	end

	-- The stock nature/* materials are LightmappedGeneric and will not render on
	-- loose geometry, so the soil uses its own material.  The heap is one
	-- shared mesh in local space, carried onto each garden by its matrix.
	local soilTint = Vector(1, 1, 1)
	local soilScale = Vector(1, 1, 1)

	function ENT:_DrawSoil()
		local light = render.ComputeLighting(self:GetPos() + Vector(0, 0, 8), self:GetUp())
		local shade = math.Clamp(math.pow(math.max(math.max(light.x, light.y, light.z), 0), 0.4545), 0.3, 1)
		soilTint:SetUnpacked(shade, shade, shade)
		SOIL_MATERIAL:SetVector("$color2", soilTint)

		local m = Matrix()
		m:SetTranslation(self:GetPos())
		m:SetAngles(self:GetAngles())
		m:SetScale(soilScale)

		render.SetMaterial(SOIL_MATERIAL)
		cam.PushModelMatrix(m)
		getSoilMesh():Draw()
		cam.PopModelMatrix()
	end

	function ENT:Draw()
		self:DrawModel()
		self:_SyncSlots()
		self:_DrawSoil()

		local F = Arcana.Gardening.FlowerRender
		if not F then return end

		local G = Arcana.Gardening
		local ang = self:GetAngles()
		local ambient = F.AmbientAt(self:GetPos() + Vector(0, 0, 16))

		-- Grabs the framebuffer once for the whole bed: the petals refract
		-- against it, and ten flowers must not mean ten copies.
		F.BeginBatch()

		for i = 1, G.MAX_SLOTS do
			local slot = self._slots[i]

			if slot then
				local def = G.Flowers[slot.id]

				if def then
					F.Draw(self:LocalToWorld(self:SlotLocalPos(i)), ang, def, slot.growth, slot.wither, i, ambient)
				end
			end
		end
	end
end
