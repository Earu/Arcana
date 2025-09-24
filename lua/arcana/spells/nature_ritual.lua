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

local FOREST_LOCK_UNTIL = 0

local function freeze(ent)
	local phys = ent:GetPhysicsObject()
	if IsValid(phys) then
		phys:EnableMotion(false)
	end
end

-- Returns an Angle whose Up vector matches the provided surface normal,
-- with a randomized rotation around that normal to preserve variation.
local function slopeAlignedAngle(surfaceNormal)
	local ang = surfaceNormal:Angle()

	-- Make Up align with the normal (Vector:Angle sets Forward to the vector)
	ang:RotateAroundAxis(ang:Right(), -90)

	-- Randomize rotation around the normal so orientation along the slope varies
	ang:RotateAroundAxis(ang:Up(), math.random(0, 360))
	return ang
end

local function isFallenTreeModel(modelPath)
	return string.find(modelPath, "fallentree", 1, true) ~= nil
end

-- Build an Angle from desired forward and up vectors
local function angleFromForwardUp(forward, up)
	local f = forward:GetNormalized()
	local u = up:GetNormalized()

	-- Orthonormalize
	local r = f:Cross(u)
	if r:LengthSqr() < 1e-6 then
		-- Degenerate; fall back to simple up-aligned
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

-- Trace from two sides across a random tangent to compute slope direction and up
local function spanAlignedPose(centerPos, approxUp, halfSpan)
	local up = approxUp:GetNormalized()
	local tangent = VectorRand()

	-- Project random vector onto the plane perpendicular to up
	tangent = (tangent - up * tangent:Dot(up))
	if tangent:LengthSqr() < 1e-6 then tangent = up:Angle():Right() end
	tangent:Normalize()

	local startOffset = up * 64
	local p1 = centerPos + tangent * halfSpan
	local p2 = centerPos - tangent * halfSpan

	local tr1 = util.TraceLine({
		start = p1 + startOffset,
		endpos = p1 - up * 4096,
		mask = bit.bor(MASK_WATER, MASK_SOLID_BRUSHONLY),
	})

	local tr2 = util.TraceLine({
		start = p2 + startOffset,
		endpos = p2 - up * 4096,
		mask = bit.bor(MASK_WATER, MASK_SOLID_BRUSHONLY),
	})

	if not tr1.Hit or not tr2.Hit then
		return slopeAlignedAngle(approxUp), centerPos
	end

	local forward = (tr2.HitPos - tr1.HitPos)
	if forward:LengthSqr() < 1 then
		return slopeAlignedAngle(approxUp), (tr1.HitPos + tr2.HitPos) * 0.5
	end

	forward:Normalize()

	local upAvg = (tr1.HitNormal + tr2.HitNormal):GetNormalized()
	local ang = angleFromForwardUp(forward, upAvg)
	local groundCenter = (tr1.HitPos + tr2.HitPos) * 0.5
	return ang, groundCenter, upAvg
end

local FOREST_RANGE = 8000
local TREE_COUNT = 600
local TREE_LOG_COUNT = 3

local function generateForest(ply, base)
	local forest = {}
	local timerName = "Arcana_Nature_Ritual_Forest_Gen_" .. ply:SteamID64()
	timer.Create(timerName, 0.1, TREE_COUNT , function()
		local treePos = base + Vector(math.random(-FOREST_RANGE, FOREST_RANGE),math.random(-FOREST_RANGE, FOREST_RANGE), 300)
		local treeTrace = util.TraceLine({
			start = treePos,
			endpos = treePos - Vector(0, 0, 1000),
			mask = bit.bor(MASK_WATER, MASK_SOLID_BRUSHONLY),
		})

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
						local logTrace = util.TraceLine({
						start = logPos,
						endpos = logPos - Vector(0, 0, 1000),
						mask = bit.bor(MASK_WATER, MASK_SOLID_BRUSHONLY),
					})

					if not logTrace.Hit or logTrace.MatType ~= MAT_GRASS then continue end

					local log = ents.Create("prop_physics")
					if not IsValid(log) then continue end

					-- Compute span-aligned orientation and center for log slices
					local logAng, logCenter = spanAlignedPose(logTrace.HitPos, logTrace.HitNormal, 32)
					log:SetPos(logCenter + Vector(0, 0, 5))
					log:SetModel(treeLogs[math.random(#treeLogs)])
					log:SetModelScale(math.random(0.25, 4))
					log:SetAngles(logAng)
					log:Spawn()
					log:SetCollisionGroup(COLLISION_GROUP_DEBRIS)

					if log.CPPISetOwner then
						log:CPPISetOwner(ply)
					end

					freeze(log)
					table.insert(forest, log)
				end
			else
				mdl = deadTrees[math.random(#deadTrees)]
			end
		end

		tree:SetModel(mdl)
		local finalScale = math.random(1, 2.5)
		-- Scale over 0.5s instead of 1s
		tree:SetModelScale(finalScale, 0.5)

		if isFallenTreeModel(mdl) then
			-- Align fallen trees to terrain using span-based orientation
			local ang, groundPos = spanAlignedPose(treeTrace.HitPos, treeTrace.HitNormal, 128)
			tree:SetAngles(ang)
			tree:SetPos(groundPos + ang:Up() * 2)
		else
			-- Upright trees keep random yaw
			tree:SetAngles(Angle(0, math.random(360), 0))
		end
		tree:Spawn()
		tree:SetCollisionGroup(COLLISION_GROUP_DEBRIS)

		sound.Play("arcana/arcane_" .. math.random(1, 3) .. ".ogg", tree:GetPos() + Vector(0, 0, 100), 100, math.random(96, 104), 1)
		sound.Play("ambient/energy/ion_cannon_shot" .. math.random(1, 3) .. ".wav", tree:GetPos() + Vector(0, 0, 100), 100, math.random(96, 104), 1)

		if tree.CPPISetOwner then
			tree:CPPISetOwner(ply)
		end

		if not isFallenTreeModel(mdl) then
			tree:DropToFloor()
			tree:SetPos(tree:GetPos() - Vector(0, 0, 20 * tree:GetModelScale()))
		end

		freeze(tree)
		table.insert(forest, tree)
	end)

	timer.Simple(60 * 60, function()
		timer.Remove(timerName)
		for _, tree in pairs(forest) do
			SafeRemoveEntity(tree)
		end
	end)
end

Arcane:RegisterRitualSpell({
	id = "nature_ritual",
	name = "Ritual: Nature",
	description = "Perform a powerful ritual to create a dense forest (only works on grass).",
	category = Arcane.CATEGORIES.UTILITY,
	level_required = 23,
	knowledge_cost = 4,
	cooldown = 60 * 60,
	cost_type = Arcane.COST_TYPES.COINS,
	cost_amount = 10000,
	cast_time = 10.0,
	ritual_color = Color(0, 99, 0),
	ritual_items = {
		banana = 20,
		melon = 20,
		orange = 20
	},
	on_activate = function(selfEnt, activatingPly, caster)
		if not SERVER then return end

		-- Global lockout: only one forest may be created per hour (shared across all players)
		if CurTime() < (FOREST_LOCK_UNTIL or 0) then
			local remaining = math.max(0, math.floor((FOREST_LOCK_UNTIL - CurTime())))
			if IsValid(activatingPly) and activatingPly.ChatPrint then
				activatingPly:ChatPrint("The spirits are resting. Nature ritual available in " .. tostring(remaining) .. "s.")
			end
			return
		end

		FOREST_LOCK_UNTIL = CurTime() + 60 * 60
		generateForest(activatingPly, selfEnt:GetPos())
		selfEnt:EmitSound("ambient/levels/citadel/strange_talk5.wav", 70, 110)
	end,
})