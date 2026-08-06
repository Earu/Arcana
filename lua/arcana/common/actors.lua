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
