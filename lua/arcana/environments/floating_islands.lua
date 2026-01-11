-- Floating Islands environment definition
-- Creates floating islands with flat tops and rocky bottoms

local Envs = Arcane.Environments
local MOSS_MAT = "models/props_wasteland/rocks02a"
local ROCKY_MAT = "models/Cliffs/Rocks02"

local CLUSTER_MODELS = {
	"models/props_wasteland/rockcliff_cluster01b.mdl",
	"models/props_wasteland/rockcliff_cluster02a.mdl",
	"models/props_wasteland/rockcliff_cluster02b.mdl",
	"models/props_wasteland/rockcliff_cluster02c.mdl",
	"models/props_wasteland/rockcliff_cluster03a.mdl",
	"models/props_wasteland/rockcliff_cluster03b.mdl",
	"models/props_wasteland/rockcliff_cluster03c.mdl",
}

local MUSOLEUM_MODEL = "models/props_rooftop/parliament_dome_destroyed_exterior.mdl"
local TREE_MODELS = {
	"models/props_foliage/tree_dead01.mdl",
	"models/props_foliage/tree_dead01.mdl",
	"models/props_foliage/tree_dead01.mdl",
	"models/props_foliage/tree_dead01.mdl",
}

local ISLAND_TYPES = {
	forest = { material = MOSS_MAT, type = "forest" },
	rocky = { material = ROCKY_MAT, type = "rocky" },
}

local function freezeEntity(ent)
	local phys = ent:GetPhysicsObject()
	if IsValid(phys) then
		phys:Wake()
		phys:EnableMotion(false)
	end

	ent.ms_notouch = true
	ent.PhysgunDisabled = true
end

function generateIslandForestTopsides(center_pos, radius, height, top_surface_z, created_props)
	local tree_count = math.floor(radius / 1000 * 15)
	for i = 1, tree_count do
		math.randomseed(i * 1000)
		local mdl = TREE_MODELS[math.random(1, #TREE_MODELS)]
		local tree_angle = math.random() * math.pi * 2
		local tree_dist = radius * (0.2 + math.random() * 0.6)
		local offset_x = math.cos(tree_angle) * tree_dist
		local offset_y = math.sin(tree_angle) * tree_dist
		local tree_pos = Vector(center_pos.x + offset_x, center_pos.y + offset_y, top_surface_z)

		local tree = ents.Create("prop_physics")
		if IsValid(tree) then
			tree:SetModel(mdl)
			tree:SetPos(tree_pos)
			tree:SetAngles(Angle(0, math.random(0, 360), 0))
			tree:Spawn()
			tree:Activate()

			freezeEntity(tree)
			table.insert(created_props, tree)
		end
	end

	-- Only spawn mausoleum on large islands (radius >= 1500)
	local mausoleumPos = nil
	if radius >= 1500 then
		local mausoleum = ents.Create("prop_physics")
		mausoleumPos = Vector(center_pos.x, center_pos.y, top_surface_z - 100)
		if IsValid(mausoleum) then
			mausoleum:SetModel(MUSOLEUM_MODEL)
			mausoleum:SetMaterial(ISLAND_TYPES.forest.material)
			mausoleum:SetPos(mausoleumPos)
			mausoleum:SetAngles(Angle(0, math.random(0, 360), 0))
			mausoleum:Spawn()
			mausoleum:Activate()
			mausoleum:SetCollisionGroup(COLLISION_GROUP_WORLD)

			freezeEntity(mausoleum)
			table.insert(created_props, mausoleum)
		end
	end

	return created_props, mausoleumPos
end

function generateIslandRockyTopsides(center_pos, radius, height, top_surface_z, created_props)
	return created_props
end

if SERVER then
	util.AddNetworkString("FloatingIslands_ActivateOnClient")
end

local function spawnRock(pos, ang, model, scale, material)
	local prop = ents.Create("prop_physics")
	if not IsValid(prop) then return nil end

	prop:SetModel(model)
	prop:SetMaterial(material or MOSS_MAT)
	prop:SetPos(pos)
	prop:SetAngles(ang)
	prop:SetModelScale(scale or 1, 0)
	prop:Spawn()
	prop:Activate()

	freezeEntity(prop)

	return prop
end

local ENTS_TO_ACTIVATE = {}
local function activateOnClient(ent)
	if not IsValid(ent) then return end

	BroadcastLua("local e = Entity(" .. ent:EntIndex() .. "); if IsValid(e) then e:Activate() end")
	ENTS_TO_ACTIVATE[ent:EntIndex()] = true
end

if SERVER then
	hook.Add("EntityRemoved", "FloatingIslands_ActivateOnClient", function(ent)
		ENTS_TO_ACTIVATE[ent:EntIndex()] = nil
	end)

	hook.Add("Arcana_LoadedPlayerData", "FloatingIslands_ActivateOnClient", function(ply)
		net.Start("FloatingIslands_ActivateOnClient")
		net.WriteTable(table.GetKeys(ENTS_TO_ACTIVATE))
		net.Send(ply)
	end)
end

local function generateFloatingIsland(center_pos, radius, height, opts)
	radius = radius or 400
	height = height or 400
	opts = opts or {}

	local created_props = {}
	local size_mult = math.max(1.0, 300 / radius)

	local spike_count = math.min(8, math.max(4, math.floor(radius / 150)))
	for i = 1, spike_count do
		local spike_angle = (i / spike_count) * math.pi * 2 + math.random() * 0.3
		local spike_dist = radius * (0.2 + math.random() * 0.4)
		local offset_x = math.cos(spike_angle) * spike_dist
		local offset_y = math.sin(spike_angle) * spike_dist
		local spike_bottom = center_pos.z - height * 0.7
		local spike_pos = Vector(center_pos.x + offset_x, center_pos.y + offset_y, spike_bottom)

		local model = CLUSTER_MODELS[math.random(1, #CLUSTER_MODELS)]
		local scale = math.min(3.0, (1.2 + math.random() * 1.0) * size_mult)
		local tilt_angle = Angle(180, math.random(0, 360), 0)

		local prop = spawnRock(spike_pos, tilt_angle, model, scale, opts.material)
		if IsValid(prop) then
			table.insert(created_props, prop)
		end
	end

	local outer_spike_count = math.min(12, math.max(6, math.floor(radius / 120)))
	for i = 1, outer_spike_count do
		local spike_angle = (i / outer_spike_count) * math.pi * 2
		local spike_dist = radius * (0.6 + math.random() * 0.3)
		local offset_x = math.cos(spike_angle) * spike_dist
		local offset_y = math.sin(spike_angle) * spike_dist
		local spike_height_offset = math.random(-height * 0.3, -height * 0.1)
		local spike_pos = Vector(center_pos.x + offset_x, center_pos.y + offset_y, center_pos.z + spike_height_offset)

		local model = CLUSTER_MODELS[math.random(1, #CLUSTER_MODELS)]
		local scale = math.min(2.5, (1.0 + math.random() * 0.8) * size_mult)
		local yaw = math.random(0, 360)

		local prop_down = spawnRock(spike_pos, Angle(180, yaw, 0), model, scale, opts.material)
		if IsValid(prop_down) then
			table.insert(created_props, prop_down)

			local _, maxs_down = prop_down:GetRotatedAABB(prop_down:OBBMins(), prop_down:OBBMaxs())
			local down_top_z = prop_down:GetPos().z + maxs_down.z
			local up_pos = Vector(spike_pos.x, spike_pos.y, down_top_z)

			local prop_up = spawnRock(up_pos, Angle(0, yaw, 0), model, scale, opts.material)
			if IsValid(prop_up) then
				local mins_up, _ = prop_up:GetRotatedAABB(prop_up:OBBMins(), prop_up:OBBMaxs())
				local up_bottom_z = prop_up:GetPos().z + mins_up.z
				local z_adjust = down_top_z - up_bottom_z
				prop_up:SetPos(prop_up:GetPos() + Vector(0, 0, z_adjust))

				table.insert(created_props, prop_up)
			end
		end
	end

	local mid_layer_count = math.min(12, math.max(6, math.floor(radius / 80)))
	for i = 1, mid_layer_count do
		local rand_angle = math.random() * math.pi * 2
		local rand_dist = radius * (0.3 + math.random() * 0.5)
		local offset_x = math.cos(rand_angle) * rand_dist
		local offset_y = math.sin(rand_angle) * rand_dist
		local mid_height = center_pos.z + math.random(-height * 0.2, height * 0.1)
		local mid_pos = Vector(center_pos.x + offset_x, center_pos.y + offset_y, mid_height)

		local model = CLUSTER_MODELS[math.random(1, #CLUSTER_MODELS)]
		local scale = math.min(2.2, (0.8 + math.random() * 0.7) * size_mult)
		local rock_angle = Angle(180, math.random(0, 360), 0)

		local prop = spawnRock(mid_pos, rock_angle, model, scale, opts.material)
		if IsValid(prop) then
			table.insert(created_props, prop)
		end
	end

	local average_z = 0
	for _, prop in pairs(created_props) do
		average_z = average_z + (prop:WorldSpaceCenter().z - center_pos.z)
	end
	average_z = average_z / #created_props

	local top_surface_z
	local octagon
	for i = 1, 5 do
		local top_pos = center_pos + Vector(0, 0, average_z * -2 + height * (0.4 + i * 0.15))
		octagon = ents.Create("prop_physics")
		if IsValid(octagon) then
			octagon:SetModel("models/hunter/geometric/hex1x1.mdl")
			octagon:SetMaterial(opts.material)
			octagon:SetPos(top_pos)
			octagon:SetAngles(Angle(0, math.random(0, 360), 0))
			local oct_scale = radius / 50 * size_mult
			octagon:SetModelScale(oct_scale, 0)
			octagon:Spawn()
			octagon:Activate()

			freezeEntity(octagon)
			table.insert(created_props, octagon)
		end
	end

	if IsValid(octagon) then
		top_surface_z = octagon:GetPos().z + octagon:OBBMaxs().z
		timer.Simple(0.1, function()
			if IsValid(octagon) then
				activateOnClient(octagon)
			end
		end)
	end

	if opts.type == "forest" then
		return generateIslandForestTopsides(center_pos, radius, height, top_surface_z, created_props)
	elseif opts.type == "rocky" then
		return generateIslandRockyTopsides(center_pos, radius, height, top_surface_z, created_props)
	end

	return created_props, nil
end

-- Check vertical space availability
local function checkVerticalSpace(origin, radius)
	local samples = {}
	local sampleCount = 8

	-- Sample at center and around the radius
	for i = 0, sampleCount do
		local angle = (i / sampleCount) * math.pi * 2
		local samplePos = origin + Vector(math.cos(angle) * radius, math.sin(angle) * radius, 0)
		if not util.IsInWorld(samplePos) then continue end

		local tr = util.TraceLine({
			start = samplePos,
			endpos = samplePos + Vector(0, 0, 10000),
			mask = MASK_SOLID_BRUSHONLY
		})

		if tr.Hit then
			table.insert(samples, tr.HitPos.z - origin.z)
		else
			table.insert(samples, 10000) -- Essentially infinite space
		end
	end

	-- Calculate average height
	local sum = 0
	for _, height in ipairs(samples) do
		sum = sum + height
	end

	return sum / #samples
end

-- Environment spawn function
local function spawnFloatingIslands(ctx)
	local entities = {}
	local effRadius = tonumber(ctx.effective_radius or 0) or 0
	local origin = ctx.origin

	-- Check average vertical space available
	local avgVerticalSpace = checkVerticalSpace(origin, effRadius)

	-- Need at least 3000 units of vertical space
	if avgVerticalSpace < 3000 then
		error(string.format("Insufficient vertical space: %.0f units available, 3000 units required", avgVerticalSpace))
	end

	-- Calculate usable vertical range
	-- Start at 2000 units minimum, use up to 80% of available space (leaving room at top)
	local minHeight = 2000
	local maxHeight = math.min(avgVerticalSpace * 0.8, 8000) -- Cap at 8000 for performance
	local usableVerticalRange = maxHeight - minHeight

	-- Scale number of islands based on effective radius, max 4 additional islands
	local radiusScale = math.Clamp(effRadius / 4000, 0.5, 1.5)
	local additionalIslandCount = math.Clamp(math.floor(3 * radiusScale), 2, 4)

	-- Increase spread radius to space islands further apart
	local spreadRadius = math.Clamp(effRadius * 0.8, 2500, 5000)

	-- Divide vertical space into zones to ensure good vertical separation
	-- Total islands = 1 main + additionalIslandCount
	local totalIslands = 1 + additionalIslandCount
	local verticalZoneSize = usableVerticalRange / totalIslands
	local minVerticalSpacing = math.max(1000, verticalZoneSize * 0.6) -- At least 800 units between islands

	-- Create shuffled zone assignments for variety
	local zoneAssignments = {}
	for i = 0, additionalIslandCount do
		table.insert(zoneAssignments, i)
	end
	-- Shuffle zones
	for i = #zoneAssignments, 2, -1 do
		local j = math.random(i)
		zoneAssignments[i], zoneAssignments[j] = zoneAssignments[j], zoneAssignments[i]
	end

	-- First, spawn the main island (radius 2000)
	-- Assign it to its shuffled zone
	local mainZone = table.remove(zoneAssignments, 1)
	local mainZoneMin = minHeight + (mainZone * verticalZoneSize)
	local mainZoneMax = mainZoneMin + verticalZoneSize
	local mainIslandHeight = math.random(mainZoneMin, mainZoneMax)
	local mainIslandPos = origin + Vector(0, 0, mainIslandHeight)
	local mainIslandRadius = 2000
	local mainIslandVerticalSize = 600

	local mainProps, mausoleumPos = generateFloatingIsland(mainIslandPos, mainIslandRadius, mainIslandVerticalSize, ISLAND_TYPES.forest)
	if istable(mainProps) then
		for _, prop in ipairs(mainProps) do
			if IsValid(prop) then
				table.insert(entities, prop)
				if ctx.spawned then table.insert(ctx.spawned, prop) end
			end
		end
	end

	-- Spawn portal at ritual location that leads to main island mausoleum
	if mausoleumPos then
		local portal = ents.Create("arcana_portal")
		if IsValid(portal) then
			portal:SetPos(origin - Vector(0, 0, 100))
			portal:SetAngles(Angle(0, 0, 0))
			portal:Spawn()
			portal:Activate()

			-- Set destination to inside the mausoleum
			portal:SetDestination(mausoleumPos + Vector(0, 0, 100))
			portal:SetDestinationAngles(Angle(0, 0, 0))
			portal:SetRadius(80)

			freezeEntity(portal)
			table.insert(entities, portal)

			if ctx.spawned then table.insert(ctx.spawned, portal) end
		end
	end

	-- Now spawn additional smaller islands around the main one
	-- Each gets its own vertical zone for guaranteed separation
	for i = 1, additionalIslandCount do
		-- Position islands in a scattered pattern around origin, further from center
		local angle = (i / additionalIslandCount) * math.pi * 2 + math.random() * 0.5
		-- Spawn much further from center to avoid touching (60-95% of spread radius)
		local dist = math.random(spreadRadius * 0.6, spreadRadius * 0.95)
		local offsetX = math.cos(angle) * dist
		local offsetY = math.sin(angle) * dist

		-- Assign this island to its shuffled zone
		local zone = table.remove(zoneAssignments, 1)
		local zoneMin = minHeight + (zone * verticalZoneSize)
		local zoneMax = zoneMin + verticalZoneSize
		local heightOffset = math.random(zoneMin, zoneMax)

		local islandPos = origin + Vector(offsetX, offsetY, heightOffset)

		-- Radius variation between 1000 and 1400
		local radius = math.random(1000, 1400)
		local height = math.random(400, 600)

		local props, _ = generateFloatingIsland(islandPos, radius, height, ISLAND_TYPES.rocky)
		if istable(props) then
			for _, prop in ipairs(props) do
				if IsValid(prop) then
					table.insert(entities, prop)
					if ctx.spawned then table.insert(ctx.spawned, prop) end
				end
			end
		end
	end

	return { entities = entities }
end

-- Register the Floating Islands environment
Envs:RegisterEnvironment({
	id = "floating_islands",
	name = "Floating Islands",
	lifetime = 60 * 60, -- 1 hour
	lock_duration = 60 * 60, -- 1 hour cooldown
	min_radius = 2000,
	max_radius = 8000,
	spawn_base = SERVER and spawnFloatingIslands or nil,
	poi_min = 0,
	poi_max = 0,
	pois = {},
})

if CLIENT then
	local ENTS_TO_ACTIVATE = {}
	net.Receive("FloatingIslands_ActivateOnClient", function()
		local ent_indices = net.ReadTable()
		for _, ent_index in pairs(ent_indices) do
			local ent = Entity(ent_index)
			if IsValid(ent) then
				ent:Activate()
			else
				-- if entity is not valid then its not networked to this client yet
				ENTS_TO_ACTIVATE[ent_index] = true
			end
		end
	end)

	hook.Add("NetworkEntityCreated", "FloatingIslands_ActivateOnClient", function(ent)
		if ENTS_TO_ACTIVATE[ent:EntIndex()] then
			ent:Activate()
			ENTS_TO_ACTIVATE[ent:EntIndex()] = nil
		end
	end)
end