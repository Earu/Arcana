-- Magical Forest environment definition

local Envs = Arcane.Environments
local ACCEPTABLE_SURFACE_TYPES = {
	[MAT_GRASS] = true,
	[MAT_DIRT] = true,
}

-- Helpers borrowed from the ritual logic and kept local to this file
local function slopeAlignedAngle(surfaceNormal)
	local ang = surfaceNormal:Angle()
	ang:RotateAroundAxis(ang:Right(), -90)
	ang:RotateAroundAxis(ang:Up(), math.random(0, 360))

	return ang
end

local function angleFromForwardUp(forward, up)
	local f = forward:GetNormalized()
	local u = up:GetNormalized()
	local r = f:Cross(u)
	if r:LengthSqr() < 1e-6 then
		return slopeAlignedAngle(u)
	end

	r:Normalize()
	f = u:Cross(r)
	f:Normalize()

	local ang = f:Angle()
	local curUp = ang:Up()
	local rot = math.deg(math.atan2(curUp:Cross(u):Dot(f), curUp:Dot(u)))
	ang:RotateAroundAxis(f, rot)

	return ang
end

local function spanAlignedPose(centerPos, approxUp, halfSpan)
	halfSpan = halfSpan or 64
	local up = approxUp:GetNormalized()
	local tangent = VectorRand()
	tangent = (tangent - up * tangent:Dot(up))
	if tangent:LengthSqr() < 1e-6 then tangent = up:Angle():Right() end

	tangent:Normalize()

	local startOffset = up * 64
	local p1 = centerPos + tangent * halfSpan
	local p2 = centerPos - tangent * halfSpan
	local tr1 = util.TraceLine({start = p1 + startOffset, endpos = p1 - up * 4096, mask = bit.bor(MASK_WATER, MASK_SOLID_BRUSHONLY)})
	local tr2 = util.TraceLine({start = p2 + startOffset, endpos = p2 - up * 4096, mask = bit.bor(MASK_WATER, MASK_SOLID_BRUSHONLY)})

	if not tr1.Hit or not tr2.Hit then return slopeAlignedAngle(approxUp), centerPos end

	local forward = (tr2.HitPos - tr1.HitPos)
	if forward:LengthSqr() < 1 then return slopeAlignedAngle(approxUp), (tr1.HitPos + tr2.HitPos) * 0.5 end

	forward:Normalize()

	local upAvg = (tr1.HitNormal + tr2.HitNormal):GetNormalized()
	local ang = angleFromForwardUp(forward, upAvg)
	local groundCenter = (tr1.HitPos + tr2.HitPos) * 0.5

	return ang, groundCenter, upAvg
end

local function freeze(ent)
	local phys = ent:GetPhysicsObject()
	if IsValid(phys) then phys:EnableMotion(false) end
end

local function setOwner(ent, owner)
	if not IsValid(owner) then return end
	if ent.CPPISetOwner then ent:CPPISetOwner(owner) end
end

local FOREST_RANGE = 8000
local TREE_COUNT = 600
local TREE_LOG_COUNT = 3

local deadTrees = {
	"models/props_foliage/tree_dead01.mdl",
	"models/props_foliage/tree_dead02.mdl",
	"models/props_foliage/tree_dead03.mdl",
	"models/props_foliage/tree_dead04.mdl",
	"models/props_foliage/fallentree01.mdl",
	"models/props_foliage/fallentree02.mdl",
	"models/props_foliage/fallentree_dry01.mdl",
	"models/props_foliage/fallentree_dry02.mdl",
}

local trees = {
	"models/props_foliage/tree_pine04.mdl",
	"models/props_foliage/tree_pine05.mdl",
	"models/props_foliage/tree_pine06.mdl",
}

local treeStump = "models/props_foliage/tree_stump01.mdl"

local treeLogs = {
	"models/props_foliage/tree_slice01.mdl",
	"models/props_foliage/tree_slice02.mdl",
}

local function isFallenTreeModel(modelPath)
	return string.find(modelPath, "fallentree", 1, true) ~= nil
end

local function spawnForest(ctx)
	local entities = {}
	local timersOut = {}
	local timerName = "Arcana_Env_ForestGen_" .. tostring(IsValid(ctx.owner) and ctx.owner:SteamID64() or "world")
	table.insert(timersOut, timerName)

	-- Scale forest size and density using precomputed effective radius
	local effRadius = tonumber(ctx.effective_radius or 0) or 0
	local forestRange = math.Clamp(math.floor(effRadius * 0.9), 1500, FOREST_RANGE)
	local densityFactor = (forestRange / FOREST_RANGE) ^ 2
	local treeCount = math.Clamp(
		math.floor(TREE_COUNT * densityFactor),
		math.max(50, math.floor(TREE_COUNT * 0.25)),
		TREE_COUNT
	)

	local spawnedTrees = 0
	local attempts = 0
	local maxAttempts = treeCount * 40
	local attemptsPerTick = 8

	local function attemptPlaceTree()
		local base = ctx.origin
		local treePos = base + Vector(math.random(-forestRange, forestRange), math.random(-forestRange, forestRange), 1000)
		local treeTrace = util.TraceLine({
			start = treePos,
			endpos = treePos - Vector(0, 0, 2000),
			mask = bit.bor(MASK_WATER, MASK_SOLID_BRUSHONLY)
		})

		if not treeTrace.Hit or not ACCEPTABLE_SURFACE_TYPES[treeTrace.MatType] then return false end
		if not util.IsInWorld(treeTrace.HitPos) then return false end

		-- Decide model first so we can early-exit without creating a dangling entity
		local mdl = trees[math.random(#trees)]
		if math.random() <= 0.25 then
			if math.random() <= 0.25 then
				mdl = treeStump
				-- Occasionally skip stump placement entirely
				if math.random() > 0.5 then return false end

				-- Spawn a few logs nearby when we do place a stump
				for i = 1, math.random(1, TREE_LOG_COUNT) do
					local logPos = treePos + Vector(math.random(-300, 300), math.random(-300, 300), 1000)
					local logTrace = util.TraceLine({
						start = logPos,
						endpos = logPos - Vector(0, 0, 2000),
						mask = bit.bor(MASK_WATER, MASK_SOLID_BRUSHONLY)
					})

					if not logTrace.Hit or not ACCEPTABLE_SURFACE_TYPES[logTrace.MatType] then continue end

					local log = ents.Create("prop_physics")
					if not IsValid(log) then continue end

					local logAng, logCenter = spanAlignedPose(logTrace.HitPos, logTrace.HitNormal, 32)
					log:SetPos(logCenter + Vector(0, 0, 5))
					log:SetModel(treeLogs[math.random(#treeLogs)])
					log:SetModelScale(math.random(0.25, 4))
					log:SetAngles(logAng)
					log:Spawn()
					log:SetCollisionGroup(COLLISION_GROUP_DEBRIS)
					setOwner(log, ctx.owner)

					freeze(log)
					table.insert(entities, log)
					if ctx.spawned then table.insert(ctx.spawned, log) end
				end
			else
				mdl = deadTrees[math.random(#deadTrees)]
			end
		end

		local tree = ents.Create("prop_physics")
		if not IsValid(tree) then return false end

		tree:SetPos(treeTrace.HitPos)
		tree:SetModel(mdl)

		local finalScale = math.random(1, 2.5)
		tree:SetModelScale(finalScale, 0.5)

		if isFallenTreeModel(mdl) then
			local ang, groundPos = spanAlignedPose(treeTrace.HitPos, treeTrace.HitNormal, 128)
			tree:SetAngles(ang)
			tree:SetPos(groundPos + ang:Up() * 2)
		else
			tree:SetAngles(Angle(0, math.random(360), 0))
		end

		tree:Spawn()
		tree:SetCollisionGroup(COLLISION_GROUP_DEBRIS)

		setOwner(tree, ctx.owner)

		if not isFallenTreeModel(mdl) then
			tree:DropToFloor()
			tree:SetPos(tree:GetPos() - Vector(0, 0, 20 * tree:GetModelScale()))
		end

		freeze(tree)
		table.insert(entities, tree)
		if ctx.spawned then table.insert(ctx.spawned, tree) end

		return true
	end

	timer.Create(timerName, 0.01, 0, function()
		local placed = false
		local tries = 0
		while (not placed) and attempts < maxAttempts and tries < attemptsPerTick do
			attempts = attempts + 1
			tries = tries + 1
			placed = attemptPlaceTree()
		end

		if placed then
			spawnedTrees = spawnedTrees + 1
			if spawnedTrees >= treeCount then
				timer.Remove(timerName)
				return
			end
		end

		if attempts >= maxAttempts then
			timer.Remove(timerName)
		end
	end)

	return { entities = entities, timers = timersOut }
end

local function traceGrassNear(base, radius)
	for _ = 1, 24 do
		local p = base + Vector(math.random(-radius, radius), math.random(-radius, radius), 1000)
		local tr = util.TraceLine({
			start = p,
			endpos = p - Vector(0, 0, 2000),
			mask = bit.bor(MASK_WATER, MASK_SOLID_BRUSHONLY)
		})

		if tr.Hit and ACCEPTABLE_SURFACE_TYPES[tr.MatType] and util.IsInWorld(tr.HitPos) then
			return tr
		end
	end

	return nil
end

local function spawnMushroomHotspot(ctx)
	-- Scale hotspot spread and density using precomputed effective radius
	local effRadius = tonumber(ctx.effective_radius or 0) or 0
	local forestRange = math.Clamp(math.floor(effRadius * 0.9), 1500, FOREST_RANGE)
	local entities = {}
	local centerTrace = traceGrassNear(ctx.origin, forestRange) or util.TraceLine({
		start = ctx.origin + Vector(0, 0, 300),
		endpos = ctx.origin - Vector(0, 0, 1000),
		mask = bit.bor(MASK_WATER, MASK_SOLID_BRUSHONLY)
	})

	if not centerTrace.Hit or not ACCEPTABLE_SURFACE_TYPES[centerTrace.MatType] or not util.IsInWorld(centerTrace.HitPos) then
		return { entities = entities }
	end

	local center = centerTrace.HitPos + Vector(0, 0, 2)
	local densityFactor = (forestRange / FOREST_RANGE) ^ 2
	local baseCount = math.random(8, 16)
	local count = math.Clamp(math.floor(baseCount * math.max(0.5, densityFactor)), 6, 32)
	local placed = {}
	local rScale = math.sqrt(math.max(0.25, forestRange / FOREST_RANGE))
	local minDist = math.floor(220 * rScale)
	local minDistSq = minDist * minDist
	local rMin, rMax = math.floor(300 * rScale), math.floor(1000 * rScale)
	local maxAttempts = count * 20
	local attempts = 0
	while #placed < count and attempts < maxAttempts do
		attempts = attempts + 1
		local a = math.Rand(0, math.pi * 2)
		local r = math.Rand(rMin, rMax)
		local off = Vector(math.cos(a) * r, math.sin(a) * r, 0)
		local candidate = center + off
		local tooClose = false
		for _, pos in ipairs(placed) do
			if pos:DistToSqr(candidate) < minDistSq then
				tooClose = true
				break
			end
		end

		if tooClose then continue end

		local p = candidate + Vector(0, 0, 64)
		local tr = util.TraceLine({
			start = p,
			endpos = p - Vector(0, 0, 1000),
			mask = bit.bor(MASK_WATER, MASK_SOLID_BRUSHONLY)
		})

		if not tr.Hit or not ACCEPTABLE_SURFACE_TYPES[tr.MatType] then continue end
		if not util.IsInWorld(tr.HitPos) then continue end

		table.insert(placed, tr.HitPos)
	end

	for _, pos in ipairs(placed) do
		local m = ents.Create("arcana_magical_mushroom")
		if not IsValid(m) then continue end

		m:SetPos(pos + Vector(0, 0, 2))
		m:SetAngles(Angle(0, math.random(0, 360), 0))
		m:Spawn()
		setOwner(m, ctx.owner)

		table.insert(entities, m)
	end

	return { entities = entities }
end

local FAIRY_GROVE_TREE =  "models/props_foliage/oak_tree01.mdl"
local function spawnFairyGrove(ctx)
	-- Scale grove size using precomputed effective radius
	local effRadius = tonumber(ctx.effective_radius or 0) or 0
	local forestRange = math.Clamp(math.floor(effRadius * 0.9), 1500, FOREST_RANGE)

	local entities = {}
	local timersOut = {}

	local centerTrace = traceGrassNear(ctx.origin, forestRange) or util.TraceLine({
		start = ctx.origin + Vector(0, 0, 1000),
		endpos = ctx.origin - Vector(0, 0, 2000),
		mask = bit.bor(MASK_WATER, MASK_SOLID_BRUSHONLY)
	})

	if not centerTrace.Hit or not ACCEPTABLE_SURFACE_TYPES[centerTrace.MatType] or not util.IsInWorld(centerTrace.HitPos) then
		return { entities = entities, timers = timersOut }
	end

	local center = centerTrace.HitPos + Vector(0, 0, 2)

	-- Place a prominent tree as the grove's anchor
	local tree = ents.Create("prop_physics")
	if IsValid(tree) then
		tree:SetPos(center)
		tree:SetModel(FAIRY_GROVE_TREE)
		tree:SetModelScale(1, 0.5)
		tree:SetAngles(Angle(0, math.random(0, 360), 0))
		tree:Spawn()
		tree:SetCollisionGroup(COLLISION_GROUP_DEBRIS)
		setOwner(tree, ctx.owner)
		tree:DropToFloor()
		tree:SetPos(tree:GetPos() - Vector(0, 0, 20 * tree:GetModelScale()))

		freeze(tree)
		table.insert(entities, tree)
	end

	-- Spawn fairies that flutter around the tree
	local densityFactor = (forestRange / FOREST_RANGE) ^ 2
	local fairyCount = math.floor(3 + 4 * densityFactor)
	local rScale = math.sqrt(math.max(0.25, forestRange / FOREST_RANGE))
	local orbitRadius = math.floor(800 * rScale)

	local timerPrefix = "Arcana_Env_FairyGrove_Move_" .. tostring(IsValid(ctx.owner) and ctx.owner:SteamID64() or "world") .. "_"
	for i = 1, fairyCount do
		math.randomseed(os.clock() + (i * 1000))

		local a = math.Rand(0, math.pi * 2)
		local r = math.Rand(orbitRadius * 0.5, orbitRadius)
		local pos = center + Vector(math.cos(a) * r, math.sin(a) * r, 120 + math.random(-100, 400))

		local f = ents.Create("arcana_fairy")
		if not IsValid(f) then continue end

		f:SetPos(pos)
		f:Spawn()
		setOwner(f, ctx.owner)
		table.insert(entities, f)

		f:SetNWBool("Arcana_FairyVendor", true)
		f:SetNWInt("Arcana_FairyVendorPrice", 6000)

		local tname = timerPrefix .. tostring(f:EntIndex())
		table.insert(timersOut, tname)

		local function schedule(nextDelay)
			local delay = nextDelay or math.Rand(1.2, 3.6)
			timer.Create(tname, delay, 1, function()
				if Arcane.Environments.Active ~= ctx then timer.Remove(tname) return end
				if not IsValid(f) then timer.Remove(tname) return end

				local a = math.Rand(0, math.pi * 2)
				local r = math.Rand(orbitRadius * 0.4, orbitRadius)
				local dst = center + Vector(math.cos(a) * r, math.sin(a) * r, 120 + math.random(-80, 140))
				f:MoveTo(dst)

				schedule()
			end)
		end

		-- initial stagger per fairy
		schedule(math.Rand(0.25, 2.5))
	end

	return { entities = entities, timers = timersOut }
end

if SERVER then
	util.AddNetworkString("Arcana_GraveyardCircle")
end

local function spawnGraveyard(ctx)
	local entities = {}
	local timersOut = {}

	-- Scale graveyard size using precomputed effective radius
	local effRadius = tonumber(ctx.effective_radius or 0) or 0
	local forestRange = math.Clamp(math.floor(effRadius * 0.9), 1500, FOREST_RANGE)

	local centerTrace = traceGrassNear(ctx.origin, forestRange) or util.TraceLine({
		start = ctx.origin + Vector(0, 0, 1000),
		endpos = ctx.origin - Vector(0, 0, 2000),
		mask = bit.bor(MASK_WATER, MASK_SOLID_BRUSHONLY)
	})

	if not centerTrace.Hit or not ACCEPTABLE_SURFACE_TYPES[centerTrace.MatType] or not util.IsInWorld(centerTrace.HitPos) then
		return { entities = entities, timers = timersOut }
	end

	local center = centerTrace.HitPos + Vector(0, 0, 2)

	-- Centerpiece models
	local centerModels = {
		"models/props_c17/gravestone_statue001a.mdl",
		"models/props_c17/gravestone_cross001a.mdl",
	}

	-- Surrounding grave models
	local graveModels = {
		"models/props_c17/gravestone002a.mdl",
		"models/props_c17/gravestone003a.mdl",
		"models/props_c17/gravestone004a.mdl",
		"models/props_c17/gravestone001a.mdl",
	}

	-- Place center stone
	local cstone = ents.Create("prop_physics")
	if IsValid(cstone) then
		local ang = slopeAlignedAngle(centerTrace.HitNormal)
		cstone:SetPos(center + Vector(0, 0, 100))
		cstone:SetAngles(ang)
		cstone:SetModel(centerModels[math.random(#centerModels)])
		cstone:Spawn()
		cstone:SetCollisionGroup(COLLISION_GROUP_DEBRIS)
		setOwner(cstone, ctx.owner)
		cstone:DropToFloor()

		freeze(cstone)
		table.insert(entities, cstone)
		if ctx.spawned then table.insert(ctx.spawned, cstone) end
	end

	-- Place graves in rings around the center
	local densityFactor = (forestRange / FOREST_RANGE) ^ 2
	local rScale = math.sqrt(math.max(0.25, forestRange / FOREST_RANGE))
	local ringInner = math.floor(320 * rScale)
	local ringOuter = math.floor(640 * rScale)
	local baseCount = math.random(12, 22)
	local graveCount = math.Clamp(math.floor(baseCount * math.max(0.6, densityFactor)), 10, 28)
	local placed = {}
	local minDist = math.floor(120 * rScale)
	local minDistSq = minDist * minDist
	local function tooClose(pos)
		for _, p in ipairs(placed) do
			if p:DistToSqr(pos) < minDistSq then return true end
		end

		return false
	end

	local graves = {}
	local maxAttempts = graveCount * 24
	local attempts = 0
	while #graves < graveCount and attempts < maxAttempts do
		attempts = attempts + 1
		local a = math.Rand(0, math.pi * 2)
		local r = math.Rand(ringInner, ringOuter)
		local off = Vector(math.cos(a) * r, math.sin(a) * r, 64)
		local cand = cstone:GetPos() + off
		if tooClose(cand) then continue end

		local tr = util.TraceLine({
			start = cand + Vector(0, 0, 1000),
			endpos = cand - Vector(0, 0, 2000),
			mask = bit.bor(MASK_WATER, MASK_SOLID_BRUSHONLY)
		})

		if not tr.Hit or not ACCEPTABLE_SURFACE_TYPES[tr.MatType] or not util.IsInWorld(tr.HitPos) then continue end

		local up = tr.HitNormal
		local fwd = (center - tr.HitPos)

		if fwd:LengthSqr() < 1 then fwd = Vector(1, 0, 0) end
		fwd:Normalize()

		local ang = angleFromForwardUp(fwd, up)
		local g = ents.Create("prop_physics")
		if IsValid(g) then
			g:SetPos(tr.HitPos + up * 64)
			g:SetAngles(ang)
			g:SetModel(graveModels[math.random(#graveModels)])
			g:Spawn()
			g:SetCollisionGroup(COLLISION_GROUP_DEBRIS)

			setOwner(g, ctx.owner)
			g:DropToFloor()

			freeze(g)
			table.insert(entities, g)

			if ctx.spawned then table.insert(ctx.spawned, g) end
			table.insert(placed, tr.HitPos)
			table.insert(graves, { ent = g, pos = tr.HitPos, up = up, ang = ang })
		end
	end

	-- Proximity-based skeleton summoning
	if #graves > 0 then
		local timerName = "Arcana_Env_Graveyard_" .. tostring(IsValid(ctx.owner) and ctx.owner:SteamID64() or "world") .. "_" .. tostring(center.x) .. "_" .. tostring(center.y)
		table.insert(timersOut, timerName)
		local nextSummon = 0
		local activeSkeletons = {}
		local function broadcastCircle(pos, ang, size, duration)
			net.Start("Arcana_GraveyardCircle", true)
			net.WriteVector(pos)
			net.WriteAngle(ang)
			net.WriteFloat(size or 48)
			net.WriteFloat(duration or 1.2)
			net.Broadcast()
		end

		timer.Create(timerName, 0.35, 0, function()
			if Arcane.Environments.Active ~= ctx then timer.Remove(timerName) return end
			-- Cull invalid skeleton refs
			local alive = {}
			for _, s in ipairs(activeSkeletons) do if IsValid(s) then alive[#alive + 1] = s end end
			activeSkeletons = alive

			local now = CurTime()
			if now < nextSummon then return end

			-- Check for nearby players
			local triggerRadius = math.floor(900 * rScale)
			local anyNear = false
			for _, ply in ipairs(player.GetAll()) do
				if IsValid(ply) and ply:Alive() and ply:GetPos():DistToSqr(center) <= (triggerRadius * triggerRadius) then
					anyNear = true
					break
				end
			end

			if not anyNear then return end

			-- Cap active skeletons per graveyard
			if #activeSkeletons >= 3 then
				nextSummon = now + math.Rand(2.5, 4.0)
				return
			end

			-- Choose a grave to summon from
			local g = graves[math.random(#graves)]
			if not (g and IsValid(g.ent)) then return end
			local forward = g.ang:Forward()
			local summonPos = g.pos + forward * 42 + g.up * 2
			local summonAng = Angle(0, g.ang.y, 0)

			-- Show deep purple activation circle, then spawn
			broadcastCircle(summonPos, Angle(0, 0, 0), 52, 1.2)
			timer.Simple(1.0, function()
				if Arcane.Environments.Active ~= ctx then return end

				local sk = ents.Create("arcana_skeleton")
				if not IsValid(sk) then return end

				sk:SetPos(summonPos)
				sk:SetAngles(summonAng)
				sk:Spawn()
				setOwner(sk, ctx.owner)

				table.insert(activeSkeletons, sk)
			end)

			nextSummon = now + math.Rand(4.5, 7.0)
		end)
	end

	return { entities = entities, timers = timersOut }
end

Envs:RegisterEnvironment({
	id = "magical_forest",
	name = "Magical Forest",
	lifetime = 60 * 60,
	lock_duration = 60 * 60,
	min_radius = 2500,
	max_radius = FOREST_RANGE,
	spawn_base = function(ctx)
		return spawnForest(ctx)
	end,
	poi_min = 2,
	poi_max = 8,
	pois = {
		{ id = "mushroom_hotspot", spawn = spawnMushroomHotspot, max = 3, min = 1 },
		{ id = "fairy_grove", spawn = spawnFairyGrove, max = 1, min = 1 },
		{ id = "graveyard", spawn = spawnGraveyard, max = 4, min = 1 },
	},
})

if CLIENT then
	hook.Add("SetupWorldFog", "Arcana_MagicalForest_Fog", function()
		local active = Envs and Envs.Active
		if not active or active.id ~= "magical_forest" then return end

		local ply = LocalPlayer()
		if not IsValid(ply) then return end

		local origin = active.origin or Vector(0, 0, 0)
		local eff = tonumber(active.effective_radius or 0) or 0
		local forestRange = math.floor(eff * 0.9)
		local fadeWidth = 250

		local p = ply:GetPos()
		local dx = p.x - origin.x
		local dy = p.y - origin.y
		local d2d = math.sqrt(dx * dx + dy * dy)

		-- If the player is within the forest range and above the origin, don't apply fog
		local dz = p.z - origin.z
		if d2d <= forestRange and dz > 3000 then return end

		local t
		local toEdge = d2d - forestRange
		t = 1 - math.Clamp(toEdge / fadeWidth, 0, 1)
		t = math.Clamp(t, 0, 1) ^ 0.7

		render.FogMode(MATERIAL_FOG_LINEAR)
		local fogStart = 0
		local fogEnd = math.floor(Lerp(t, 4500, 900))
		render.FogStart(fogStart)
		render.FogEnd(fogEnd)
		render.FogMaxDensity(Lerp(t, 0, 1))
		render.FogColor(74, 102, 92)

		return true
	end)

	-- Client-side summoning circle for graveyard skeleton spawns
	net.Receive("Arcana_GraveyardCircle", function()
		local pos = net.ReadVector()
		local ang = net.ReadAngle()
		local size = net.ReadFloat() or 52
		local duration = net.ReadFloat() or 1.2
		if not _G.MagicCircle then return end
		local color = Color(110, 40, 200, 255) -- deep purple
		local circle = MagicCircle.CreateMagicCircle(pos + Vector(0, 0, 0.5), ang, color, 3, size, duration, 2)
		if circle and circle.StartEvolving then
			circle:StartEvolving(duration, true)
		end
	end)
end
