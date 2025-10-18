-- Magical Forest environment definition
if not SERVER then return end

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
	timersOut[#timersOut + 1] = timerName

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
					if log.CPPISetOwner then log:CPPISetOwner(ctx.owner) end

					freeze(log)
					table.insert(entities, log)
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

		if tree.CPPISetOwner then tree:CPPISetOwner(ctx.owner) end

		if not isFallenTreeModel(mdl) then
			tree:DropToFloor()
			tree:SetPos(tree:GetPos() - Vector(0, 0, 20 * tree:GetModelScale()))
		end

		freeze(tree)
		table.insert(entities, tree)
		return true
	end

	timer.Create(timerName, 0.1, 0, function()
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
		if m.CPPISetOwner then m:CPPISetOwner(ctx.owner) end

		table.insert(entities, m)
	end

	return { entities = entities }
end

Envs:RegisterEnvironment({
	id = "magical_forest",
	name = "Magical Forest",
	lifetime = 60 * 60,
	lock_duration = 60 * 60,
	min_radius = 2500,
	spawn_base = function(ctx)
		return spawnForest(ctx)
	end,
	poi_min = 1,
	poi_max = 2,
	pois = {
		{ id = "mushroom_hotspot", weight = 100, spawn = spawnMushroomHotspot },
	},
})


