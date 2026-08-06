-- Arcana Hostile Relations: makes stock Source NPCs see and hate Arcana's monsters.
--
-- Alyx, Barney, citizens and Combine only ever consider three kinds of thing when picking
-- an enemy: players, other CAI_BaseNPC entities, and entities registered with the engine's
-- sensed-objects manager. Arcana's monsters are nextbots and anim entities, so they land in
-- none of those buckets and a stock NPC walks straight past a skeleton.
--
-- Two things fix that, and neither works without the other (both verified in game):
--   * FL_OBJECT is what puts a non-NPC entity in the sensed-objects list. It has to be set
--     BEFORE the entity spawns: the engine reads the flag during the spawn pass, so adding
--     it afterwards leaves the NPC permanently blind to the entity.
--   * An explicit D_HT relationship per (npc, monster) pair. The default disposition toward
--     a non-NPC entity is D_NU, so a sensed monster is otherwise seen and ignored. Nextbots
--     have no Classify or SetNPCClass, so there is no class to hate by proxy either, and
--     NPC:AddRelationship's classname form only resolves against entities alive right then.
--
-- The relationship is one directional: this file makes NPCs hate monsters. Monsters hate
-- NPCs back through their own target acquisition (Arcana.Common.AcquireNearestEnemy), and
-- they hate everything equally, Combine and rebel alike, the way zombies do.

Arcana = Arcana or {}
Arcana.NPC = Arcana.NPC or {}

local NPCs = Arcana.NPC

-- Classes that fight the world. Friendly Arcana entities (fairy, emissary, enchanter) are
-- deliberately absent, and so are projectiles and hazards, which have no AI to speak of.
NPCs.MonsterClasses = {
	arcana_skeleton = true,
	arcana_skeleton_lich = true,
	arcana_crawling_skulls = true,
	arcana_corrupted_wisp = true,
	arcana_corrupted_wisp_heavy = true,
	arcana_flaming_skull = true,
}

--- True when the entity is one of Arcana's hostile creatures.
-- @param ent Entity to test
-- @return boolean
function NPCs.IsMonster(ent)
	return IsValid(ent) and NPCs.MonsterClasses[ent:GetClass()] == true
end

if not SERVER then return end

-- High enough to outrank whatever faction relationships the NPC was spawned with, so a
-- Combine soldier breaks off from a rebel to deal with the skeleton in its face.
local RELATION_PRIORITY = 99

local monsters = {}
local npcs = {}

--- Live set of the NPCs in the world, keyed by entity.
-- Arcana.Common.MonsterEnemies reads this so monster target scans stay a table walk rather
-- than a spatial query every third of a second.
-- @return table set of NPC entities
function NPCs.GetNPCs()
	return npcs
end

local function makeHate(npc, monster)
	if not IsValid(npc) or not IsValid(monster) then return end

	npc:AddEntityRelationship(monster, D_HT, RELATION_PRIORITY)
end

hook.Add("OnEntityCreated", "Arcana_NPCRelations", function(ent)
	if not IsValid(ent) then return end

	-- Synchronous on purpose: the spawn pass that reads this flag runs before the next tick.
	if NPCs.IsMonster(ent) then
		ent:AddFlags(FL_OBJECT)
	end

	-- Relationships need both sides spawned, and engine NPCs have not read their keyvalues
	-- yet at creation time, so pair them a tick later.
	timer.Simple(0, function()
		if not IsValid(ent) then return end

		if NPCs.IsMonster(ent) then
			monsters[ent] = true

			for npc in pairs(npcs) do
				makeHate(npc, ent)
			end
		elseif ent:IsNPC() then
			npcs[ent] = true

			for monster in pairs(monsters) do
				makeHate(ent, monster)
			end
		end
	end)
end)

hook.Add("EntityRemoved", "Arcana_NPCRelations", function(ent)
	monsters[ent] = nil
	npcs[ent] = nil
end)

-- The relationship alone only gets an NPC as far as being *able* to hate a monster. Actually
-- noticing one is left to the engine's sensed-objects pass, which is slow and unreliable for
-- entities that are not NPCs: a rebel citizen stared at a skeleton 450 units away for 18
-- seconds without reacting, and Alyx typically only woke up once the thing had already hit
-- her. A single UpdateEnemyMemory call had the same citizen firing within a second, so tell
-- NPCs about the monsters in front of them rather than waiting on the pass.
local NOTICE_RANGE_SQR = 1500 * 1500
local NOTICE_INTERVAL = 0.5

timer.Create("Arcana_NPCRelations_Notice", NOTICE_INTERVAL, 0, function()
	if not next(monsters) then return end

	for npc in pairs(npcs) do
		if not IsValid(npc) or npc:Health() <= 0 then continue end

		local npcPos = npc:GetPos()
		local enemy = npc:GetEnemy()

		for monster in pairs(monsters) do
			-- Already fighting it, and line of sight is required so nothing gets hunted
			-- through a wall it could not have seen through.
			if not IsValid(monster) or monster == enemy then continue end
			if npcPos:DistToSqr(monster:GetPos()) > NOTICE_RANGE_SQR then continue end
			if not npc:Visible(monster) then continue end

			npc:UpdateEnemyMemory(monster, monster:GetPos())
		end
	end
end)

-- Seed from the world so a Lua refresh does not leave everything already spawned unaware of
-- each other. Monsters that spawned before this file loaded keep their disposition but not
-- their FL_OBJECT registration, so those stay invisible until they are respawned.
for _, ent in ipairs(ents.GetAll()) do
	if NPCs.IsMonster(ent) then
		monsters[ent] = true
	elseif ent:IsNPC() then
		npcs[ent] = true
	end
end

for npc in pairs(npcs) do
	for monster in pairs(monsters) do
		makeHate(npc, monster)
	end
end
