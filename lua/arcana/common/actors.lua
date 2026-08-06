-- Arcana Actor Predicates
-- "Actor" means a thing that can be damaged, targeted and knocked around: a player, an NPC
-- or a nextbot. Nearly every spell, enchantment and projectile in the addon needs this test
-- to sort a FindInSphere result into things worth hitting and scenery.
--
-- This lives here rather than inline because the inline copies drifted into two shapes:
-- `ent:IsNextBot()` and `(ent.IsNextBot and ent:IsNextBot())`. The guarded form is the
-- correct one, since anything that is not an Entity (or is an invalid one) has no such
-- method, and the bare call errors instead of returning false.

Arcana = Arcana or {}
Arcana.Common = Arcana.Common or {}

--- True when the entity is a player, an NPC or a nextbot.
-- @param ent Entity to test (nil and invalid entities return false)
-- @return boolean
function Arcana.Common.IsActor(ent)
	if not IsValid(ent) then return false end

	return ent:IsPlayer() or ent:IsNPC() or (ent.IsNextBot ~= nil and ent:IsNextBot())
end

--- True when the entity is an actor that is still alive.
-- Dead players linger as valid entities, so most damage and targeting paths want this
-- rather than IsActor on its own.
-- @param ent Entity to test
-- @return boolean
function Arcana.Common.IsLivingActor(ent)
	if not Arcana.Common.IsActor(ent) then return false end
	if ent:IsPlayer() and not ent:Alive() then return false end

	return ent:Health() > 0
end

--- True when `ent` is something an Arcana monster should fight.
-- Everything alive qualifies except Arcana's own creatures, which would otherwise tear each
-- other apart the moment two of them shared a corrupted area.
-- @param ent Entity to test
-- @return boolean
function Arcana.Common.IsMonsterEnemy(ent)
	if not Arcana.Common.IsLivingActor(ent) then return false end
	if Arcana.NPC and Arcana.NPC.IsMonster(ent) then return false end

	return true
end

local function livingPlayers()
	local out = {}

	for _, ply in ipairs(player.GetAll()) do
		if IsValid(ply) and ply:Alive() then
			out[#out + 1] = ply
		end
	end

	return out
end

--- Everything an Arcana monster hunts: living players plus every NPC in the world.
-- The NPC half comes from the registry arcana/system/npc_relations.lua keeps, which is the
-- same set of NPCs taught to hate the monsters back. Other addons' nextbots are not in it,
-- so they are never picked as a target, though they are still valid to damage on contact
-- (see IsMonsterEnemy). Allocates a fresh table per call.
-- @return table array of entities
function Arcana.Common.MonsterEnemies()
	local out = livingPlayers()

	local npcs = Arcana.NPC and Arcana.NPC.GetNPCs and Arcana.NPC.GetNPCs()
	for npc in pairs(npcs or {}) do
		if IsValid(npc) and npc:Health() > 0 then
			out[#out + 1] = npc
		end
	end

	return out
end

-- Between scans the previously acquired target is returned unchanged, so callers can run
-- acquisition every Think without walking the candidate list every tick. The result is
-- cached on ent._target, which the AI entities already read directly.
local function acquireNearest(ent, range, interval, listCandidates)
	if not IsValid(ent) then return nil end

	local now = CurTime()
	if now < (ent._arcanaNextTargetScan or 0) then return ent._target end
	ent._arcanaNextTargetScan = now + (interval or 0.4)

	local myPos = ent:GetPos()
	local nearest, bestD2 = nil, range * range

	for _, candidate in ipairs(listCandidates()) do
		if candidate ~= ent then
			local d2 = myPos:DistToSqr(candidate:GetPos())
			if d2 < bestD2 then
				bestD2 = d2
				nearest = candidate
			end
		end
	end

	ent._target = nearest

	return nearest
end

--- Nearest living player to `ent` within `range`, rate-limited per entity.
-- @param ent Entity doing the looking
-- @param range Maximum distance in units
-- @param interval Seconds between rescans (default 0.4)
-- @return Player or nil
function Arcana.Common.AcquireNearestPlayer(ent, range, interval)
	return acquireNearest(ent, range, interval, livingPlayers)
end

--- Nearest thing an Arcana monster should fight within `range`, rate-limited per entity.
-- Same contract as AcquireNearestPlayer, but NPCs count too, so a skeleton hunted by a
-- squad of Combine fights back instead of standing there being shot.
-- @param ent Entity doing the looking
-- @param range Maximum distance in units
-- @param interval Seconds between rescans (default 0.4)
-- @return Entity or nil
function Arcana.Common.AcquireNearestEnemy(ent, range, interval)
	return acquireNearest(ent, range, interval, Arcana.Common.MonsterEnemies)
end
