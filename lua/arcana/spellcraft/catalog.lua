-- Spellcraft — shared component catalog, power budget, pricing, and the pure
-- Compile/Requirements functions.
--
-- A crafted spell is authored as component ids only (a Form, an Essence, and up to
-- four Clause ranks). Numbers never travel on the wire: the server recompiles
-- every stat, per-cast cost, and offering from this catalog, so a modified
-- client can inject ids at worst — never values — and a balance patch here
-- applies retroactively to every crafted spell on the next load.
--
-- Two pure entry points:
--   Compile(def)          -> (compiled, err)   structural validity + stats + prices
--   Requirements(def, st) -> checklist                per-server eligibility (level, essence, gates, budget, consecration)

Arcana = Arcana or {}
Arcana.Spellcraft = Arcana.Spellcraft or {}
local P = Arcana.Spellcraft

----------------------------------------------------------------------
-- Server-tunable knobs (replicated so the client quotes the same numbers)
----------------------------------------------------------------------
if SERVER then
	local F = bit.bor(FCVAR_REPLICATED, FCVAR_ARCHIVE, FCVAR_NOTIFY)
	CreateConVar("arcana_spellcraft_enabled", "1", F, "Enable spell crafting")
	CreateConVar("arcana_spellcraft_min_level", "35", F, "Minimum Arcana level to craft/cast spells")
	CreateConVar("arcana_spellcraft_max_slots", "10", F, "How many crafted spells each player may keep here")
	CreateConVar("arcana_spellcraft_budget_base", "60", F, "Power budget at the minimum level")
	CreateConVar("arcana_spellcraft_budget_per_level", "1", F, "Extra power budget per level above the minimum")
	CreateConVar("arcana_spellcraft_cost_mult", "1.0", F, "Multiplier on per-cast coin cost")
	CreateConVar("arcana_spellcraft_offering_mult", "1.0", F, "Multiplier on the one-time consecration offering")
	CreateConVar("arcana_spellcraft_max_damage", "220", F, "Hard cap on total damage per cast")
	CreateConVar("arcana_spellcraft_max_radius", "420", F, "Hard cap on effect radius")
	CreateConVar("arcana_spellcraft_max_projectiles", "3", F, "Hard cap on projectiles per cast")
	CreateConVar("arcana_spellcraft_min_cooldown", "2.0", F, "Floor on cooldown seconds")
	CreateConVar("arcana_spellcraft_min_casttime", "0.4", F, "Floor on cast time seconds")
	CreateConVar("arcana_spellcraft_max_range", "2500", F, "Hard cap on range / beam distance")
end

local function cvarNum(name, default)
	local cv = GetConVar(name)
	if cv then return cv:GetFloat() end
	return default
end

function P.Config()
	return {
		enabled        = cvarNum("arcana_spellcraft_enabled", 1) >= 1,
		minLevel       = math.floor(cvarNum("arcana_spellcraft_min_level", 35)),
		maxSlots       = math.floor(cvarNum("arcana_spellcraft_max_slots", 10)),
		budgetBase     = cvarNum("arcana_spellcraft_budget_base", 60),
		budgetPerLevel = cvarNum("arcana_spellcraft_budget_per_level", 1),
		costMult       = cvarNum("arcana_spellcraft_cost_mult", 1.0),
		offeringMult   = cvarNum("arcana_spellcraft_offering_mult", 1.0),
		maxDamage      = cvarNum("arcana_spellcraft_max_damage", 220),
		maxRadius      = cvarNum("arcana_spellcraft_max_radius", 420),
		maxProjectiles = math.floor(cvarNum("arcana_spellcraft_max_projectiles", 3)),
		minCooldown    = cvarNum("arcana_spellcraft_min_cooldown", 2.0),
		minCastTime    = cvarNum("arcana_spellcraft_min_casttime", 0.4),
		maxRange       = cvarNum("arcana_spellcraft_max_range", 2500),
	}
end

function P.Budget(level)
	local c = P.Config()
	level = math.max(c.minLevel, tonumber(level) or c.minLevel)
	return math.floor(c.budgetBase + (level - c.minLevel) * c.budgetPerLevel)
end

----------------------------------------------------------------------
-- Forms — the four orthogonal delivery mechanisms (pick exactly one)
----------------------------------------------------------------------
P.Forms = {
	bolt = {
		id = "bolt", label = "Bolt", order = 1, points = 20,
		desc = "A hurled projectile that detonates on impact.",
		isProjectile = true, hasTarget = true,
		baseDamage = 55, baseRadius = 120, baseRange = 1500, baseSpeed = 1200,
		baseCooldown = 4, baseCastTime = 0.8,
	},
	beam = {
		id = "beam", label = "Beam", order = 2, points = 25,
		desc = "An instant lance of force struck along your aim.",
		isProjectile = false, hasTarget = true,
		baseDamage = 70, baseRadius = 90, baseRange = 2000,
		baseCooldown = 5, baseCastTime = 0.8,
	},
	self = {
		id = "self", label = "Self", order = 3, points = 25,
		desc = "An aura bound to your body, harming those who draw near.",
		isProjectile = false, hasTarget = false, isSelf = true,
		tickDamage = 12, tickInterval = 1.0, baseRadius = 140, baseDuration = 8,
		baseCooldown = 20, baseCastTime = 0.7,
	},
	aoe = {
		id = "aoe", label = "Area", order = 4, points = 25,
		desc = "A burst that blooms at the point you aim.",
		isProjectile = false, hasTarget = true,
		baseDamage = 90, baseRadius = 300, baseRange = 900,
		baseCooldown = 8, baseCastTime = 0.9,
	},
}

----------------------------------------------------------------------
-- Essences — pick one; each is unlocked with a one-time offering.
-- Differentiation is behavioural (rider + damage type + colour), not points.
----------------------------------------------------------------------
P.Essences = {
	fire      = { id = "fire",      label = "Fire",      order = 1, points = 8,  rider = "ignite",    damageType = bit.bor(DMG_BURN, DMG_BLAST),        color = Color(255, 120, 40),  unlock = { coins = 20000, shards = 5 },
	              desc = "Sets victims ablaze." },
	frost     = { id = "frost",     label = "Frost",     order = 2, points = 8,  rider = "frost",     damageType = bit.bor(DMG_GENERIC, DMG_SONIC),     color = Color(170, 220, 255), unlock = { coins = 20000, shards = 5 },
	              desc = "Chills victims, slowing their movements." },
	earth     = { id = "earth",     label = "Earth",     order = 3, points = 8,  rider = "earth",     damageType = bit.bor(DMG_CLUB, DMG_BLAST),        color = Color(180, 140, 90),  unlock = { coins = 25000, shards = 6 },
	              desc = "Batters victims aside; excels against constructions." },
	wind      = { id = "wind",      label = "Wind",      order = 4, points = 8,  rider = "wind",      damageType = bit.bor(DMG_GENERIC, DMG_SLASH),     color = Color(200, 240, 220), unlock = { coins = 30000, shards = 8 },
	              desc = "Hurls victims skyward." },
	poison    = { id = "poison",    label = "Poison",    order = 5, points = 8,  rider = "poison",    damageType = DMG_POISON,                          color = Color(120, 210, 70),  unlock = { coins = 35000, shards = 8 },
	              desc = "Venom lingers in the blood, dealing damage over time." },
	lightning = { id = "lightning", label = "Lightning", order = 6, points = 8,  rider = "lightning", damageType = bit.bor(DMG_SHOCK, DMG_ENERGYBEAM),  color = Color(150, 200, 255), unlock = { coins = 40000, shards = 10 },
	              desc = "Arcs to nearby foes." },
	arcane    = { id = "arcane",    label = "Arcane",    order = 7, points = 8,  rider = "arcane",    damageType = bit.bor(DMG_DISSOLVE, DMG_ENERGYBEAM), color = Color(180, 120, 255), damageMult = 1.15, unlock = { coins = 50000, shards = 12 },
	              desc = "Pure force, struck harder than any element." },
	-- Not a gift of the gods: earned only by accepting the Golden Sun's bargain.
	-- No DMG_DISSOLVE here: dissolve kills disintegrate the corpse, and aurum
	-- needs a ragdoll left behind to turn into a statue.
	aurum     = { id = "aurum",     label = "Aurum",     order = 8, points = 10, rider = "aurum",     damageType = bit.bor(DMG_BURN, DMG_SLOWBURN),     color = Color(255, 210, 90),  bargain = true,
	              desc = "Golden fire. Those it consumes are left as gilded statues." },
}

----------------------------------------------------------------------
-- Clauses — 0..5 total ranks; each rank is level-gated. Repetition = rank.
----------------------------------------------------------------------
-- allowForm/allowEssence: nil = allowed everywhere; a set restricts.
-- deny: an explicit set that blocks specific forms.
-- conflicts: a set of clause ids this one cannot be combined with (checked
-- symmetrically in Compile).
P.Clauses = {
	reach      = { id = "reach",      label = "Reach",      order = 1,  points = 8,      maxRank = 1, levels = { 35 },       denyForm = { self = true },
	              desc = "+50% range, projectile speed, and beam distance." },
	concussive = { id = "concussive", label = "Concussive", order = 2,  points = 8,      maxRank = 1, levels = { 36 },       denyForm = { self = true }, denyEssence = { wind = true }, conflicts = { pull = true },
	              desc = "Knock foes back on hit (redundant with Wind)." },
	precision  = { id = "precision",  label = "Precision",  order = 3,  points = 6,      maxRank = 1, levels = { 37 },       onlyForm = { bolt = true, beam = true },
	              desc = "+25% damage, but the blast radius is halved." },
	swift      = { id = "swift",      label = "Swift",      order = 4,  points = 12,     maxRank = 1, levels = { 38 },
	              desc = "Cast 40% faster." },
	hobble     = { id = "hobble",     label = "Hobble",     order = 5,  points = 12,     maxRank = 1, levels = { 39 },       denyEssence = { frost = true },
	              desc = "Hits slow victims for 2s (redundant with Frost)." },
	widen      = { id = "widen",      label = "Widen",      order = 6,  points = 10,     maxRank = 2, levels = { 40, 44 },
	              desc = "+30% effect radius per rank." },
	ricochet   = { id = "ricochet",   label = "Ricochet",   order = 7,  points = 10,     maxRank = 2, levels = { 41, 47 },   onlyForm = { bolt = true },
	              desc = "Bolts bounce off surfaces once per rank." },
	haste      = { id = "haste",      label = "Haste",      order = 8,  points = 12,     maxRank = 1, levels = { 42 },       onlyForm = { self = true },
	              desc = "Move 20% faster while your aura lasts." },
	endure     = { id = "endure",     label = "Endure",     order = 9,  points = 15,     maxRank = 2, levels = { 42, 46 },   onlyForm = { self = true },
	              desc = "Self aura lasts +4s per rank." },
	pull       = { id = "pull",       label = "Pull",       order = 10, points = 10,     maxRank = 1, levels = { 43 },       conflicts = { concussive = true },
	              desc = "Victims are dragged toward the impact." },
	piercing   = { id = "piercing",   label = "Piercing",   order = 11, points = 14,     maxRank = 1, levels = { 44 },       onlyForm = { bolt = true }, conflicts = { split = true },
	              desc = "Bolts pass through up to 3 victims, only breaking on walls." },
	amplify    = { id = "amplify",    label = "Amplify",    order = 12, points = 10,     maxRank = 3, levels = { 45, 50, 55 },
	              desc = "+20% damage per rank." },
	thorns     = { id = "thorns",     label = "Thorns",     order = 13, points = 15,     maxRank = 1, levels = { 47 },       onlyForm = { self = true },
	              desc = "Whoever hurts you gets struck by your element." },
	lingering  = { id = "lingering",  label = "Lingering",  order = 14, points = 15,     maxRank = 1, levels = { 48 },       denyForm = { self = true },
	              desc = "Leaves a burning patch of essence for 4s." },
	curse      = { id = "curse",      label = "Curse",      order = 15, points = 14,     maxRank = 1, levels = { 49 },
	              desc = "Victims take +15% damage from everything for 5s." },
	alacrity   = { id = "alacrity",   label = "Alacrity",   order = 16, points = 12,     maxRank = 2, levels = { 50, 56 },
	              desc = "-25% cooldown per rank." },
	refract    = { id = "refract",    label = "Refract",    order = 17, points = 14,     maxRank = 1, levels = { 52 },       onlyForm = { beam = true },
	              desc = "The beam forks at impact to up to 2 nearby foes." },
	multishot  = { id = "multishot",  label = "Multishot",  order = 18, points = 15,     maxRank = 2, levels = { 55, 60 },   onlyForm = { bolt = true },
	              desc = "+1 projectile per rank, each dealing less." },
	echo       = { id = "echo",       label = "Echo",       order = 19, points = 16,     maxRank = 1, levels = { 57 },       denyForm = { self = true },
	              desc = "The impact repeats once after 1.5s at half damage." },
	split      = { id = "split",      label = "Split",      order = 20, points = 16,     maxRank = 1, levels = { 58 },       onlyForm = { bolt = true }, conflicts = { piercing = true },
	              desc = "Detonations burst into 3 smaller bolts." },
	siphon     = { id = "siphon",     label = "Siphon",     order = 21, points = 18,     maxRank = 1, levels = { 61 },
	              desc = "Heal for part of the damage dealt (up to 40 HP per cast)." },
	homing     = { id = "homing",     label = "Homing",     order = 22, points = 18,     maxRank = 1, levels = { 62 },       onlyForm = { bolt = true },
	              desc = "Projectiles seek the nearest foe." },
}

local MAX_CLAUSE_SLOTS = 5
P.MAX_CLAUSE_SLOTS = MAX_CLAUSE_SLOTS

----------------------------------------------------------------------
-- Normalisation + defhash (stable across renames; used per-server consecration)
----------------------------------------------------------------------
-- Returns a rank map { clauseId = rank } from a clause list where repetition = rank.
local function clauseRankMap(clauses)
	local ranks = {}
	for _, id in ipairs(clauses or {}) do
		ranks[id] = (ranks[id] or 0) + 1
	end
	return ranks
end

-- Canonical string: form|essence|clause:rank sorted alphabetically. Name excluded.
function P.Normalize(def)
	if not istable(def) then return "" end
	local ranks = clauseRankMap(def.clauses)
	local ids = {}
	for id in pairs(ranks) do ids[#ids + 1] = id end
	table.sort(ids)
	local parts = {}
	for _, id in ipairs(ids) do
		parts[#parts + 1] = id .. ":" .. ranks[id]
	end
	return string.format("%s|%s|%s", tostring(def.form or ""), tostring(def.essence or ""), table.concat(parts, ","))
end

function P.DefHash(def)
	return util.SHA256(P.Normalize(def))
end

----------------------------------------------------------------------
-- Compile — structural validity, clamped stats, and prices. Pure.
----------------------------------------------------------------------
-- Returns (compiled, nil) or (nil, errorString).
function P.Compile(def)
	if not istable(def) then return nil, "Malformed spell" end

	local form = P.Forms[def.form]
	if not form then return nil, "Unknown form" end

	local essence = P.Essences[def.essence]
	if not essence then return nil, "Unknown element" end

	local clauses = def.clauses
	if clauses ~= nil and not istable(clauses) then return nil, "Malformed modifiers" end
	clauses = clauses or {}
	if #clauses > MAX_CLAUSE_SLOTS then return nil, "Too many modifiers" end

	local ranks = clauseRankMap(clauses)
	for id, rank in pairs(ranks) do
		local clause = P.Clauses[id]
		if not clause then return nil, "Unknown clause: " .. tostring(id) end
		if rank > clause.maxRank then return nil, clause.label .. " cannot exceed rank " .. clause.maxRank end
		if clause.onlyForm and not clause.onlyForm[form.id] then
			return nil, clause.label .. " is not available for the " .. form.label .. " form"
		end
		if clause.denyForm and clause.denyForm[form.id] then
			return nil, clause.label .. " cannot be used with " .. form.label
		end
		if clause.denyEssence and clause.denyEssence[essence.id] then
			return nil, clause.label .. " is redundant with " .. essence.label
		end
		if clause.conflicts then
			for other in pairs(clause.conflicts) do
				if ranks[other] then
					return nil, clause.label .. " cannot be combined with " .. (P.Clauses[other] and P.Clauses[other].label or other)
				end
			end
		end
	end

	-- Cross-clause rule: Homing excludes Widen rank 2 (kills seeking wide AoE)
	if ranks.homing and (ranks.widen or 0) >= 2 then
		return nil, "Homing cannot be combined with Widen II"
	end

	local cfg = P.Config()

	-- Points + slot count (repetition counts as separate slots)
	local numClauseSlots = #clauses
	local points = form.points + essence.points
	for id, rank in pairs(ranks) do
		points = points + P.Clauses[id].points * rank
	end

	-- Multipliers
	local amplifyRank = ranks.amplify or 0
	local widenRank = ranks.widen or 0
	local alacrityRank = ranks.alacrity or 0
	local endureRank = ranks.endure or 0
	local multishotRank = ranks.multishot or 0

	local dmgMult = (1 + 0.20 * amplifyRank) * (essence.damageMult or 1)
	if ranks.precision then dmgMult = dmgMult * 1.25 end

	-- Projectiles (bolt only meaningfully; clamped)
	local projectiles = 1
	if form.id == "bolt" then
		projectiles = math.min(cfg.maxProjectiles, 1 + multishotRank)
	end

	-- Base damage number per form
	local baseDamage = form.baseDamage or form.tickDamage or 0
	local perHit = baseDamage * dmgMult
	if projectiles > 1 then perHit = perHit * 0.65 end

	-- Lightning chain draws from the same budget so it counts against the cap
	local chainDamage = 0
	if essence.rider == "lightning" then
		chainDamage = perHit * 0.4
	end
	local LIGHTNING_MAX_CHAINS = 2

	-- Clamp total output to the damage cap. Everything that multiplies output
	-- counts: projectiles, chains, pierce-through hits, split children,
	-- refract forks, and the echo repeat.
	local total = perHit * projectiles + chainDamage * LIGHTNING_MAX_CHAINS
	if ranks.piercing then total = total + perHit * 0.65 * 2 end
	if ranks.split then total = total + perHit * 0.35 * 3 end
	if ranks.refract then total = total + perHit * 0.5 * 2 end
	if ranks.echo then total = total * 1.5 end
	if total > cfg.maxDamage and total > 0 then
		local scale = cfg.maxDamage / total
		perHit = perHit * scale
		chainDamage = chainDamage * scale
	end

	-- Radius (splash for bolt/beam, blast for aoe, aura for self)
	local radius = (form.baseRadius or 0) * (1 + 0.30 * widenRank)
	if ranks.precision then radius = radius * 0.5 end
	radius = math.min(radius, cfg.maxRadius)

	-- Range / beam distance / aoe cast range
	local range = form.baseRange or 0
	local speed = form.baseSpeed or 0
	if ranks.reach then
		range = range * 1.5
		speed = speed * 1.5
	end
	range = math.min(range, cfg.maxRange)

	-- Cooldown (alacrity), floored
	local cooldown = form.baseCooldown or cfg.minCooldown
	if alacrityRank > 0 then cooldown = cooldown * (0.75 ^ alacrityRank) end
	cooldown = math.max(cfg.minCooldown, cooldown)

	-- Cast time (swift), floored
	local castTime = form.baseCastTime or 0.8
	if ranks.swift then castTime = castTime * 0.6 end
	castTime = math.max(cfg.minCastTime, castTime)

	-- Self aura duration (endure)
	local duration = (form.baseDuration or 0) + 4 * endureRank

	-- Prices (superlinear; clause tax past the second slot)
	local clauseTax = 1.25 ^ math.max(0, numClauseSlots - 2)
	local perCastCost = math.ceil(2.0 * (points ^ 1.35) * clauseTax * cfg.costMult)
	local consecrationCoins = math.ceil(500 * (points ^ 1.30) * cfg.offeringMult)
	local consecrationShards = math.ceil(points / 6)

	return {
		form = form.id,
		essence = essence.id,
		clauses = clauses,
		ranks = ranks,
		numClauseSlots = numClauseSlots,
		points = points,

		-- prices
		perCastCost = perCastCost,
		consecrationCoins = consecrationCoins,
		consecrationShards = consecrationShards,

		-- stats
		damage = perHit,
		projectiles = projectiles,
		radius = radius,
		range = range,
		speed = speed,
		cooldown = cooldown,
		castTime = castTime,
		duration = duration,
		tickInterval = form.tickInterval or 1.0,
		chainDamage = chainDamage,
		lightningMaxChains = LIGHTNING_MAX_CHAINS,

		-- descriptors carried for the runtime and animations
		isProjectile = form.isProjectile or false,
		hasTarget = form.hasTarget or false,
		isSelf = form.isSelf or false,
		damageType = essence.damageType,
		essenceColor = essence.color,
		rider = essence.rider,
		homing = ranks.homing ~= nil,
		lingering = ranks.lingering ~= nil,
		concussive = ranks.concussive ~= nil,
		pierce = ranks.piercing ~= nil,
		ricochets = ranks.ricochet or 0,
		split = ranks.split ~= nil,
		refract = ranks.refract ~= nil,
		pull = ranks.pull ~= nil,
		hobble = ranks.hobble ~= nil,
		curse = ranks.curse ~= nil,
		echo = ranks.echo ~= nil,
		thorns = ranks.thorns ~= nil,
		haste = ranks.haste ~= nil,
		siphon = ranks.siphon ~= nil,
	}, nil
end

----------------------------------------------------------------------
-- Requirements — per-server eligibility, evaluated live. Pure.
----------------------------------------------------------------------
-- state = { level = number, essences = { [id]=true }, bargain = bool, consecrated = bool }
-- Returns a checklist table with a `castable` flag and `firstMissing` reason.
function P.Requirements(def, state)
	state = state or {}
	local level = tonumber(state.level) or 0
	local essences = state.essences or {}
	local cfg = P.Config()

	local compiled, err = P.Compile(def)
	if not compiled then
		return { valid = false, err = err, castable = false, firstMissing = err }
	end

	local out = { valid = true, compiled = compiled, castable = true, checks = {}, firstMissing = nil }

	local function fail(reason)
		out.castable = false
		out.firstMissing = out.firstMissing or reason
	end

	-- 1) minimum level
	local levelOk = level >= cfg.minLevel
	out.checks.level = { ok = levelOk, need = cfg.minLevel, have = level }
	if not levelOk then fail("Requires level " .. cfg.minLevel) end

	-- 2) essence unlocked (aurum via bargain)
	local essence = P.Essences[compiled.essence]
	local essenceOk
	if essence.bargain then
		essenceOk = state.bargain == true
	else
		essenceOk = essences[compiled.essence] == true
	end
	out.checks.essence = { ok = essenceOk, id = compiled.essence, label = essence.label, unlock = essence.unlock, bargain = essence.bargain == true }
	if not essenceOk then fail(essence.label .. " element not unlocked on this server") end

	-- 3) clause level gates
	out.checks.clauses = {}
	for id, rank in pairs(compiled.ranks) do
		local clause = P.Clauses[id]
		local needLevel = clause.levels[rank] or clause.levels[#clause.levels]
		local ok = level >= needLevel
		out.checks.clauses[#out.checks.clauses + 1] = { id = id, label = clause.label, rank = rank, need = needLevel, ok = ok }
		if not ok then fail(clause.label .. (rank > 1 and (" " .. rank) or "") .. " requires level " .. needLevel) end
	end

	-- 4) points within the level budget
	local budget = P.Budget(level)
	local budgetOk = compiled.points <= budget
	out.checks.budget = { ok = budgetOk, have = budget, need = compiled.points }
	if not budgetOk then fail("Not enough power (" .. compiled.points .. "/" .. budget .. ")") end

	-- 5) consecrated on this server
	local consecratedOk = state.consecrated == true
	out.checks.consecrated = { ok = consecratedOk, coins = compiled.consecrationCoins, shards = compiled.consecrationShards }
	if not consecratedOk then fail("Spell not activated on this server") end

	return out
end

-- Convenience: sorted iteration helpers for the UI (stable order).
function P.SortedForms()
	local t = {}
	for _, f in pairs(P.Forms) do t[#t + 1] = f end
	table.sort(t, function(a, b) return a.order < b.order end)
	return t
end

function P.SortedEssences()
	local t = {}
	for _, e in pairs(P.Essences) do t[#t + 1] = e end
	table.sort(t, function(a, b) return a.order < b.order end)
	return t
end

function P.SortedClauses()
	local t = {}
	for _, c in pairs(P.Clauses) do t[#t + 1] = c end
	table.sort(t, function(a, b) return a.order < b.order end)
	return t
end
