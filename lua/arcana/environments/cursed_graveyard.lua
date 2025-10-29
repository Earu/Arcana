-- Cursed Graveyard environment definition

local Envs = Arcane.Environments

local ACCEPTABLE_SURFACE_TYPES = {
	[MAT_GRASS] = true,
	[MAT_DIRT] = true,
	[MAT_SNOW] = true,
}

-- Helpers derived from existing environment utilities
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

local function setOwner(ent, owner)
	if not IsValid(owner) then return end
	if ent.CPPISetOwner then ent:CPPISetOwner(owner) end
end

local function freeze(ent)
	local phys = ent:GetPhysicsObject()
	if IsValid(phys) then phys:EnableMotion(false) end
end

local RANGE_MAX = 6000

local GRAVE_MODELS = {
	"models/props_c17/gravestone001a.mdl",
	"models/props_c17/gravestone002a.mdl",
	"models/props_c17/gravestone003a.mdl",
	"models/props_c17/gravestone004a.mdl",
}

local FEATURE_MODELS = {
	"models/props_c17/gravestone_cross001a.mdl",
	"models/props_c17/gravestone_statue001a.mdl",
}

local function traceToGround(pos)
	local tr = util.TraceLine({
		start = pos + Vector(0, 0, 1000),
		endpos = pos - Vector(0, 0, 4000),
		mask = bit.bor(MASK_WATER, MASK_SOLID_BRUSHONLY)
	})

	if tr.Hit and util.IsInWorld(tr.HitPos) and ACCEPTABLE_SURFACE_TYPES[tr.MatType] then
		return tr
	end

	return nil
end

local function placeProp(model, groundPos, groundUp, forward, owner, opts)
    opts = opts or {}
    local ent = ents.Create("prop_physics")
    if not IsValid(ent) then return nil end
    ent:SetModel(model)

    -- Initial orientation aligned to the surface normal with optional yaw/pitch/roll jitter
    local baseAng
    if forward then
        baseAng = angleFromForwardUp(forward, groundUp)
    else
        baseAng = slopeAlignedAngle(groundUp)
    end

    if opts.yawJitter then
        baseAng:RotateAroundAxis(groundUp, math.Rand(-opts.yawJitter, opts.yawJitter))
    end
    if opts.pitchJitter then
        baseAng:RotateAroundAxis(baseAng:Right(), math.Rand(-opts.pitchJitter, opts.pitchJitter))
    end
    if opts.rollJitter then
        baseAng:RotateAroundAxis(baseAng:Forward(), math.Rand(-opts.rollJitter, opts.rollJitter))
    end

    ent:SetAngles(baseAng)

    if opts.modelScale then
        ent:SetModelScale(opts.modelScale, 0)
    end

    -- Spawn before querying OBB
    ent:SetPos(groundPos)
    ent:Spawn()

    -- Vertical alignment: lift so the model's bottom just touches the ground plane along ent:Up()
    local mins = ent:OBBMins()
    local scale = ent:GetModelScale() or 1
    local bottomOffset = (-mins.z) * scale

    -- Place with a small epsilon to avoid z-fighting
    local epsilon = opts.groundEpsilon or 0.25
    local upVec = ent:GetUp()
    ent:SetPos(groundPos + upVec * (bottomOffset + epsilon))

    -- Correct for tiny penetration/floating with a short trace along -Up
    local checkStart = ent:GetPos() + upVec * 4
    local checkEnd = checkStart - upVec * 16
    local tr = util.TraceLine({ start = checkStart, endpos = checkEnd, filter = ent, mask = bit.bor(MASK_WATER, MASK_SOLID_BRUSHONLY) })
    if tr.Hit then
        ent:SetPos(tr.HitPos + upVec * (epsilon))
    end

    -- Optional: sink slightly into ground to anchor heavy models (e.g., trees)
    local sink = 0
    if opts.sinkMul then
        sink = (ent:GetModelScale() or 1) * tonumber(opts.sinkMul or 0)
    elseif opts.groundSink then
        sink = tonumber(opts.groundSink or 0)
    end
    if sink and sink > 0 then
        ent:SetPos(ent:GetPos() - upVec * sink)
    end

    ent:SetCollisionGroup(COLLISION_GROUP_DEBRIS)
    setOwner(ent, owner)
    freeze(ent)
    return ent
end

local function spawnGrid(ctx)
	local entities = {}
	local effRadius = tonumber(ctx.effective_radius or 0) or 0
	local range = math.Clamp(math.floor(effRadius * 0.85), 1200, RANGE_MAX)

	-- Grid parameters scale with area
	local density = (range / RANGE_MAX) ^ 2
	local rows = math.Clamp(math.floor(6 + 10 * density), 4, 16)
	local cols = math.Clamp(math.floor(8 + 14 * density), 6, 24)
	local spacingX = 96
	local spacingY = 72

	-- Align grid to world axes; find a workable ground origin near ctx.origin
	local originTrace = traceToGround(ctx.origin)
	local basePos = (originTrace and originTrace.HitPos) or (ctx.origin - Vector(0, 0, 32))
	local up = (originTrace and originTrace.HitNormal) or Vector(0, 0, 1)

	-- Offset grid so it centers around origin
	local originOffset = Vector(-(cols - 1) * 0.5 * spacingX, -(rows - 1) * 0.5 * spacingY, 0)

	local placed = 0
	local maxToPlace = math.min(rows * cols, 300)
	local missChance = math.Clamp(0.20 + (1 - density) * 0.10, 0.20, 0.35) -- more gaps for decay feel
    local posJitterX = 14
    local posJitterY = 12
    local yawJitter = 12
    local tiltJitter = 4
	for r = 0, rows - 1 do
		for c = 0, cols - 1 do
            if math.Rand(0, 1) < missChance then continue end

            local jitter = Vector(math.Rand(-posJitterX, posJitterX), math.Rand(-posJitterY, posJitterY), 0)
            local p = basePos + originOffset + Vector(c * spacingX, r * spacingY, 0) + jitter
			local tr = traceToGround(p)
			if not tr then continue end

			-- Face along row direction
			local forward = Vector(0, 1, 0)
            local ent = placeProp(
                GRAVE_MODELS[math.random(#GRAVE_MODELS)],
                tr.HitPos,
                tr.HitNormal,
                forward,
                ctx.owner,
                { yawJitter = yawJitter, pitchJitter = tiltJitter, rollJitter = 0 }
            )
			if IsValid(ent) then
				table.insert(entities, ent)
				if ctx.spawned then table.insert(ctx.spawned, ent) end
				placed = placed + 1
				if placed >= maxToPlace then break end
			end
		end
		if placed >= maxToPlace then break end
	end

	-- Sprinkle occasional features at row ends or random corners
	local featureCount = math.max(1, math.floor((rows + cols) * 0.15))
	for i = 1, featureCount do
		local fx = (math.random() < 0.5) and 0 or (cols - 1)
		local fy = math.random(0, rows - 1)
		local fp = basePos + originOffset + Vector(fx * spacingX, fy * spacingY, 0) + Vector(math.random(-32, 32), math.random(-32, 32), 0)
        local ftr = traceToGround(fp)
		if ftr then
			local model = FEATURE_MODELS[math.random(#FEATURE_MODELS)]
            local ent = placeProp(model, ftr.HitPos, ftr.HitNormal, Vector(0, 1, 0), ctx.owner, { yawJitter = 25, pitchJitter = 6 })
			if IsValid(ent) then
				table.insert(entities, ent)
				if ctx.spawned then table.insert(ctx.spawned, ent) end
			end
		end
	end

	return { entities = entities }
end

local function spawnRings(ctx)
	local entities = {}
	local effRadius = tonumber(ctx.effective_radius or 0) or 0
	local range = math.Clamp(math.floor(effRadius * 0.85), 1200, RANGE_MAX)

	-- Choose a center near origin that is valid ground
	local centerTrace
	for _ = 1, 24 do
		local p = ctx.origin + Vector(math.random(-range * 0.4, range * 0.4), math.random(-range * 0.4, range * 0.4), 0)
		centerTrace = traceToGround(p)
		if centerTrace then break end
	end
	centerTrace = centerTrace or traceToGround(ctx.origin) or { HitPos = ctx.origin, HitNormal = Vector(0, 0, 1) }

    local center = centerTrace.HitPos + Vector(0, 0, 2)
	local up = centerTrace.HitNormal

	-- Scale count and radii with available space
	local density = (range / RANGE_MAX) ^ 2
	local ringCount = math.Clamp(math.floor(1 + 2 * density + 0.5), 1, 3)
	local gravesPerRingBase = math.Clamp(math.floor(10 + 18 * density), 8, 28)
	local inner = math.floor(220 * math.sqrt(range / RANGE_MAX))
	local ringGap = 180

	local missChance = math.Clamp(0.18 + (1 - density) * 0.12, 0.18, 0.32)
    local yawJitter = 14
    local tiltJitter = 5
    for ring = 1, ringCount do
		local radius = inner + (ring - 1) * ringGap
		local count = gravesPerRingBase + math.random(-2, 2)
		for i = 1, count do
            if math.Rand(0, 1) < missChance then continue end
            local a = (i / count) * math.pi * 2 + math.Rand(-0.09, 0.09)
            local rj = radius + math.Rand(-26, 28)
            local pos2D = Vector(math.cos(a) * rj, math.sin(a) * rj, 0)
            local p = center + pos2D + Vector(0, 0, 64)
			local tr = util.TraceLine({
				start = p,
				endpos = p - Vector(0, 0, 2000),
				mask = bit.bor(MASK_WATER, MASK_SOLID_BRUSHONLY)
			})

			if tr.Hit and util.IsInWorld(tr.HitPos) and ACCEPTABLE_SURFACE_TYPES[tr.MatType] then
				local fwd = (center - tr.HitPos)
				if fwd:LengthSqr() < 1 then fwd = Vector(1, 0, 0) end
				fwd:Normalize()
                local ent = placeProp(
                    GRAVE_MODELS[math.random(#GRAVE_MODELS)],
                    tr.HitPos,
                    tr.HitNormal,
                    fwd,
                    ctx.owner,
                    { yawJitter = yawJitter, pitchJitter = tiltJitter }
                )
				if IsValid(ent) then
					table.insert(entities, ent)
					if ctx.spawned then table.insert(ctx.spawned, ent) end
				end
			end
		end
	end

	-- Add a feature at the center occasionally
    if math.random() < 0.85 then
		local model = FEATURE_MODELS[math.random(#FEATURE_MODELS)]
        local ent = placeProp(model, center + Vector(0, 0, 2), up, Vector(1, 0, 0), ctx.owner, { yawJitter = 25, pitchJitter = 8 })
		if IsValid(ent) then
			table.insert(entities, ent)
			if ctx.spawned then table.insert(ctx.spawned, ent) end
		end
	end

	return { entities = entities }
end

local function spawnCursedGraveyard(ctx)
	local out = { entities = {}, timers = {} }

	-- Combine a grid and ring pattern for visual variety
	local resGrid = spawnGrid(ctx)
	for _, e in ipairs(resGrid.entities or {}) do table.insert(out.entities, e) end

	local resRing = spawnRings(ctx)
	for _, e in ipairs(resRing.entities or {}) do table.insert(out.entities, e) end

	-- Helper to merge results
	local function merge(res)
		for _, e in ipairs(res.entities or {}) do table.insert(out.entities, e) end
	end

	-- Utility: sample a valid ground position within range
	local function sampleGroundNear(base, radius, tries)
		tries = tries or 24
		for _ = 1, tries do
			local a = math.Rand(0, math.pi * 2)
			local r = math.Rand(radius * 0.1, radius)
			local p = base + Vector(math.cos(a) * r, math.sin(a) * r, 64)
			local tr = util.TraceLine({ start = p, endpos = p - Vector(0, 0, 4000), mask = bit.bor(MASK_WATER, MASK_SOLID_BRUSHONLY) })
			if tr.Hit and util.IsInWorld(tr.HitPos) and ACCEPTABLE_SURFACE_TYPES[tr.MatType] then
				return tr
			end
		end
		return nil
	end

	-- Grid cluster at a given center (smaller than the main one)
	local function spawnGridAt(center)
		local entities = {}
		local effRadius = tonumber(ctx.effective_radius or 0) or 0
		local range = math.Clamp(math.floor(effRadius * 0.85), 1200, RANGE_MAX)
		local density = (range / RANGE_MAX) ^ 2
		local rows = math.Clamp(math.floor(3 + 8 * density), 3, 10)
		local cols = math.Clamp(math.floor(4 + 10 * density), 4, 14)
		local spacingX = 96
		local spacingY = 72
		local originTrace = traceToGround(center)
		local basePos = (originTrace and originTrace.HitPos) or (center - Vector(0, 0, 32))
		local originOffset = Vector(-(cols - 1) * 0.5 * spacingX, -(rows - 1) * 0.5 * spacingY, 0)
		local missChance = math.Clamp(0.22 + (1 - density) * 0.12, 0.20, 0.38)
		for r = 0, rows - 1 do
			for c = 0, cols - 1 do
				if math.Rand(0, 1) < missChance then continue end
				local jitter = Vector(math.Rand(-12, 12), math.Rand(-10, 10), 0)
				local p = basePos + originOffset + Vector(c * spacingX, r * spacingY, 0) + jitter
				local tr = traceToGround(p)
				if not tr then continue end
				local ent = placeProp(GRAVE_MODELS[math.random(#GRAVE_MODELS)], tr.HitPos, tr.HitNormal, Vector(0, 1, 0), ctx.owner, { yawJitter = 10, pitchJitter = 4 })
				if IsValid(ent) then table.insert(entities, ent) if ctx.spawned then table.insert(ctx.spawned, ent) end end
			end
		end
		return { entities = entities }
	end

	-- Ring cluster at a given center (slightly smaller)
	local function spawnRingsAt(center)
		local entities = {}
		local effRadius = tonumber(ctx.effective_radius or 0) or 0
		local range = math.Clamp(math.floor(effRadius * 0.85), 1200, RANGE_MAX)
		local density = (range / RANGE_MAX) ^ 2
		local baseTr = traceToGround(center)
		if not baseTr then return { entities = entities } end
		local c = baseTr.HitPos + Vector(0, 0, 2)
		local inner = math.floor(180 * math.sqrt(range / RANGE_MAX))
		local ringGap = 150
		local ringCount = math.Clamp(math.floor(1 + 2 * density + 0.5), 1, 2)
		local per = math.Clamp(math.floor(8 + 14 * density), 6, 22)
		local missChance = math.Clamp(0.2 + (1 - density) * 0.14, 0.2, 0.36)
		for ring = 1, ringCount do
			local radius = inner + (ring - 1) * ringGap
			for i = 1, per do
				if math.Rand(0, 1) < missChance then continue end
				local a = (i / per) * math.pi * 2 + math.Rand(-0.1, 0.1)
				local rr = radius + math.Rand(-22, 24)
				local p = c + Vector(math.cos(a) * rr, math.sin(a) * rr, 64)
				local tr = util.TraceLine({ start = p, endpos = p - Vector(0, 0, 2000), mask = bit.bor(MASK_WATER, MASK_SOLID_BRUSHONLY) })
				if tr.Hit and util.IsInWorld(tr.HitPos) and ACCEPTABLE_SURFACE_TYPES[tr.MatType] then
					local fwd = (c - tr.HitPos):GetNormalized()
					local ent = placeProp(GRAVE_MODELS[math.random(#GRAVE_MODELS)], tr.HitPos, tr.HitNormal, fwd, ctx.owner, { yawJitter = 14, pitchJitter = 5 })
					if IsValid(ent) then table.insert(entities, ent) if ctx.spawned then table.insert(ctx.spawned, ent) end end
				end
			end
		end
		return { entities = entities }
	end

	-- Long rows (lanes) of graves following a direction
	local function spawnRows(center, dir, laneCount)
		local entities = {}
		dir = (dir and dir:GetNormalized()) or Vector(1, 0, 0)
		laneCount = laneCount or math.random(2, 4)
		local effRadius = tonumber(ctx.effective_radius or 0) or 0
		local range = math.Clamp(math.floor(effRadius * 0.85), 1200, RANGE_MAX)
		local density = (range / RANGE_MAX) ^ 2
		local length = math.Clamp(math.floor(900 + 1600 * density), 600, 2200)
		local spacing = 96
		local lateral = dir:Cross(Vector(0, 0, 1))
		if lateral:LengthSqr() < 1e-3 then lateral = Vector(0, 1, 0) end
		lateral:Normalize()
		local missChance = math.Clamp(0.22 + (1 - density) * 0.16, 0.22, 0.4)
		for lane = 1, laneCount do
			local offset = (lane - (laneCount + 1) * 0.5) * 80
			local steps = math.floor(length / spacing)
			for s = 0, steps do
				if math.Rand(0, 1) < missChance then continue end
				local base = center + dir * (s * spacing - length * 0.5) + lateral * (offset + math.Rand(-14, 14))
				local tr = traceToGround(base)
				if not tr then continue end
				local ent = placeProp(GRAVE_MODELS[math.random(#GRAVE_MODELS)], tr.HitPos, tr.HitNormal, dir, ctx.owner, { yawJitter = 10, pitchJitter = 4 })
				if IsValid(ent) then table.insert(entities, ent) if ctx.spawned then table.insert(ctx.spawned, ent) end end
			end
		end
		return { entities = entities }
	end

	-- Small irregular packs with enforced spacing between graves
	local function spawnMicroClusters(center, packs)
		local entities = {}
		packs = packs or math.random(3, 6)
		for i = 1, packs do
			-- Slightly larger search radius for each micro pack
			local off = VectorRand() * math.Rand(180, 360)
			off.z = 0
			local p = center + off
			local tr = traceToGround(p)
			if not tr then continue end

			local targetCount = math.random(3, 7)
			local placed = {}
			local minDist = math.random(56, 84)
			local minDistSq = minDist * minDist
			local attempts = 0
			local maxAttempts = targetCount * 20

			while #placed < targetCount and attempts < maxAttempts do
				attempts = attempts + 1
				local jitter = VectorRand() * math.Rand(24, 72)
				jitter.z = 0
				local candidate = tr.HitPos + jitter

				local tooClose = false
				for _, pos in ipairs(placed) do
					if pos:DistToSqr(candidate) < minDistSq then
						tooClose = true
						break
					end
				end
				if tooClose then continue end

				local tr2 = traceToGround(candidate)
				if not tr2 then continue end

				local ent = placeProp(GRAVE_MODELS[math.random(#GRAVE_MODELS)], tr2.HitPos, tr2.HitNormal, VectorRand():GetNormalized(), ctx.owner, { yawJitter = 180, pitchJitter = 6 })
				if IsValid(ent) then
					table.insert(entities, ent)
					if ctx.spawned then table.insert(ctx.spawned, ent) end
					table.insert(placed, tr2.HitPos)
				end
			end
		end
		return { entities = entities }
	end

	-- Sparse scatter to fill gaps
	local function spawnScatter()
		local entities = {}
		local effRadius = tonumber(ctx.effective_radius or 0) or 0
		local range = math.Clamp(math.floor(effRadius * 0.85), 1200, RANGE_MAX)
		local density = (range / RANGE_MAX) ^ 2
		local attempts = math.Clamp(math.floor(220 + 400 * density), 120, 520)
		local missChance = 0.45
		for i = 1, attempts do
			if math.Rand(0, 1) < missChance then continue end
			local tr = sampleGroundNear(ctx.origin, range, 1)
			if not tr then continue end
			local ent = placeProp(GRAVE_MODELS[math.random(#GRAVE_MODELS)], tr.HitPos, tr.HitNormal, VectorRand():GetNormalized(), ctx.owner, { yawJitter = 180, pitchJitter = 5 })
			if IsValid(ent) then table.insert(entities, ent) if ctx.spawned then table.insert(ctx.spawned, ent) end end
		end
		return { entities = entities }
	end

	-- Place multiple clusters distributed over the radius
	local effRadius = tonumber(ctx.effective_radius or 0) or 0
	local range = math.Clamp(math.floor(effRadius * 0.85), 1200, RANGE_MAX)
	local density = (range / RANGE_MAX) ^ 2

	local extraGrids = math.Clamp(math.floor(1 + 3 * density), 1, 4)
	for i = 1, extraGrids do
		local tr = sampleGroundNear(ctx.origin, range * 0.9, 12)
		if tr then merge(spawnGridAt(tr.HitPos)) end
	end

	local extraRings = math.Clamp(math.floor(1 + 2 * density), 1, 3)
	for i = 1, extraRings do
		local tr = sampleGroundNear(ctx.origin, range * 0.9, 12)
		if tr then merge(spawnRingsAt(tr.HitPos)) end
	end

	-- Rows along 2-3 random axes
	local rowSets = math.Clamp(math.floor(2 + 3 * density), 2, 5)
	for i = 1, rowSets do
		local ctrTr = sampleGroundNear(ctx.origin, range * 0.8, 10)
		if ctrTr then
			local dir = Angle(0, math.Rand(0, 360), 0):Forward()
			merge(spawnRows(ctrTr.HitPos, dir, math.random(2, 4)))
		end
	end

	-- Micro-clusters sprinkled at multiple valid centers
	local microSets = math.Clamp(math.floor(6 + 10 * density), 5, 14)
	for i = 1, microSets do
		local ctrTr = sampleGroundNear(ctx.origin, range * 0.95, 8)
		if ctrTr then merge(spawnMicroClusters(ctrTr.HitPos, math.random(3, 6))) end
	end

	-- Scatter singles to fill remaining gaps
	merge(spawnScatter())

    -- Scatter some trees around to add vertical variety
    local effRadius = tonumber(ctx.effective_radius or 0) or 0
    local range = math.Clamp(math.floor(effRadius * 0.85), 1200, RANGE_MAX)
    local density = (range / RANGE_MAX) ^ 2
    local treeModels = {
        "models/props_foliage/old_tree01.mdl",
        "models/props_foliage/oak_tree01.mdl",
        "models/props_foliage/tree_deciduous_01a-lod.mdl",
        "models/props_foliage/tree_deciduous_01a.mdl",
        "models/props_foliage/tree_deciduous_02a.mdl",
    }
    local treeCount = math.Clamp(math.floor(6 + 14 * density), 4, 16)
    for i = 1, treeCount do
        local a = math.Rand(0, math.pi * 2)
        local r = math.Rand(range * 0.25, range)
        local p = ctx.origin + Vector(math.cos(a) * r, math.sin(a) * r, 64)
        local tr = util.TraceLine({ start = p, endpos = p - Vector(0, 0, 4000), mask = bit.bor(MASK_WATER, MASK_SOLID_BRUSHONLY) })
        if tr.Hit and util.IsInWorld(tr.HitPos) and ACCEPTABLE_SURFACE_TYPES[tr.MatType] then
            local scale = math.Rand(0.85, 1.6)
            local ent = placeProp(
                treeModels[math.random(#treeModels)],
                tr.HitPos,
                tr.HitNormal,
                Vector(1, 0, 0),
                ctx.owner,
                { yawJitter = 180, pitchJitter = 3, modelScale = scale, sinkMul = 20 }
            )
            if IsValid(ent) then
                table.insert(out.entities, ent)
                if ctx.spawned then table.insert(ctx.spawned, ent) end
            end
        end
    end

	return out
end

Envs:RegisterEnvironment({
	id = "cursed_graveyard",
	name = "Cursed Graveyard",
	lifetime = 60 * 60,
	lock_duration = 60 * 60,
	min_radius = 1500,
	max_radius = RANGE_MAX,
	spawn_base = function(ctx)
		return spawnCursedGraveyard(ctx)
	end,
	poi_min = 0,
	poi_max = 0,
	pois = {},
})

if CLIENT then
	hook.Add("SetupWorldFog", "Arcana_CursedGraveyard_Fog", function()
		local active = Envs and Envs.Active
		if not active or active.id ~= "cursed_graveyard" then return end

		local ply = LocalPlayer()
		if not IsValid(ply) then return end

		local origin = active.origin or Vector(0, 0, 0)
		local eff = tonumber(active.effective_radius or 0) or 0
		local range = math.floor(eff * 0.9)
		local fadeWidth = 250

		local p = ply:GetPos()
		local dx = p.x - origin.x
		local dy = p.y - origin.y
		local d2d = math.sqrt(dx * dx + dy * dy)

		-- If the player is within the graveyard range and above the origin, don't apply fog
		local dz = p.z - origin.z
		if d2d <= range and dz > 3000 then return end

		local t
		local toEdge = d2d - range
		t = 1 - math.Clamp(toEdge / fadeWidth, 0, 1)
		t = math.Clamp(t, 0, 1) ^ 0.7

		render.FogMode(MATERIAL_FOG_LINEAR)
		local fogStart = 0
		local fogEnd = math.floor(Lerp(t, 4500, 900))
		render.FogStart(fogStart)
		render.FogEnd(fogEnd)
		render.FogMaxDensity(Lerp(t, 0, 1))
		render.FogColor(255, 255, 255)

		return true
	end)
end