-- Magical Forest environment definition
if not SERVER then return end

local Arcane = _G.Arcane or {}
local Envs = (Arcane and Arcane.Environments) or nil
if not Envs then return end

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
	timer.Create(timerName, 0.1, TREE_COUNT, function()
		local base = ctx.origin
		local treePos = base + Vector(math.random(-FOREST_RANGE, FOREST_RANGE), math.random(-FOREST_RANGE, FOREST_RANGE), 300)
		local treeTrace = util.TraceLine({ start = treePos, endpos = treePos - Vector(0, 0, 1000), mask = bit.bor(MASK_WATER, MASK_SOLID_BRUSHONLY) })
		if not treeTrace.Hit or treeTrace.MatType ~= MAT_GRASS then return end
		if not util.IsInWorld(treeTrace.HitPos) then return end

		local tree = ents.Create("prop_physics")
		if not IsValid(tree) then return end

		tree:SetPos(treeTrace.HitPos)
		local mdl = trees[math.random(#trees)]

		if math.random() <= 0.25 then
			if math.random() <= 0.25 then
				mdl = treeStump
				if math.random() > 0.5 then return end

				for i = 1, math.random(1, TREE_LOG_COUNT) do
					local logPos = treePos + Vector(math.random(-300, 300), math.random(-300, 300), 300)
					local logTrace = util.TraceLine({ start = logPos, endpos = logPos - Vector(0, 0, 1000), mask = bit.bor(MASK_WATER, MASK_SOLID_BRUSHONLY) })
					if not logTrace.Hit or logTrace.MatType ~= MAT_GRASS then continue end

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

		sound.Play("arcana/arcane_" .. math.random(1, 3) .. ".ogg", tree:GetPos() + Vector(0, 0, 100), 100, math.random(96, 104), 1)
		sound.Play("ambient/energy/ion_cannon_shot" .. math.random(1, 3) .. ".wav", tree:GetPos() + Vector(0, 0, 100), 100, math.random(96, 104), 1)

		if tree.CPPISetOwner then tree:CPPISetOwner(ctx.owner) end

		if not isFallenTreeModel(mdl) then
			tree:DropToFloor()
			tree:SetPos(tree:GetPos() - Vector(0, 0, 20 * tree:GetModelScale()))
		end

		freeze(tree)
		table.insert(entities, tree)
	end)

	return { entities = entities, timers = timersOut }
end

local function traceGrassNear(base, radius)
	for _ = 1, 24 do
		local p = base + Vector(math.random(-radius, radius), math.random(-radius, radius), 256)
		local tr = util.TraceLine({ start = p, endpos = p - Vector(0, 0, 1024), mask = bit.bor(MASK_WATER, MASK_SOLID_BRUSHONLY) })
		if tr.Hit and tr.MatType == MAT_GRASS and util.IsInWorld(tr.HitPos) then
			return tr
		end
	end
	return nil
end

local function spawnMushroomHotspot(ctx)
	local entities = {}
	local centerTrace = traceGrassNear(ctx.origin, 1500) or util.TraceLine({
		start = ctx.origin + Vector(0,0,128),
		endpos = ctx.origin - Vector(0,0,1024),
		mask = bit.bor(MASK_WATER, MASK_SOLID_BRUSHONLY)
	})

	if not centerTrace or not centerTrace.Hit or centerTrace.MatType ~= MAT_GRASS then return {entities = entities} end

	local center = centerTrace.HitPos + Vector(0, 0, 2)
	local count = math.random(8, 16)
	local placed = {}
	local minDist = 220
	local minDistSq = minDist * minDist
	local rMin, rMax = 300, 1000
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
		local tr = util.TraceLine({ start = p, endpos = p - Vector(0, 0, 256), mask = bit.bor(MASK_WATER, MASK_SOLID_BRUSHONLY) })
		if not tr.Hit or tr.MatType ~= MAT_GRASS then continue end

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
	spawn_base = function(ctx)
		return spawnForest(ctx)
	end,
	poi_min = 1,
	poi_max = 2,
	pois = {
		{ id = "mushroom_hotspot", weight = 100, spawn = spawnMushroomHotspot },
	},
})


