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

--- Nearest living player to `ent` within `range`, rate-limited per entity.
-- Between scans the previously acquired target is returned unchanged, so callers can run
-- this every Think without walking the player list every tick. The result is cached on
-- ent._target, which the AI entities already read directly.
-- @param ent Entity doing the looking
-- @param range Maximum distance in units
-- @param interval Seconds between rescans (default 0.4)
-- @return Player or nil
function Arcana.Common.AcquireNearestPlayer(ent, range, interval)
	if not IsValid(ent) then return nil end

	local now = CurTime()
	if now < (ent._arcanaNextTargetScan or 0) then return ent._target end
	ent._arcanaNextTargetScan = now + (interval or 0.4)

	local myPos = ent:GetPos()
	local nearest, bestD2 = nil, range * range

	for _, ply in ipairs(player.GetAll()) do
		if IsValid(ply) and ply:Alive() then
			local d2 = myPos:DistToSqr(ply:GetPos())
			if d2 < bestD2 then
				bestD2 = d2
				nearest = ply
			end
		end
	end

	ent._target = nearest

	return nearest
end
