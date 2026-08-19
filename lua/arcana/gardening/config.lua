-- Shared tuning for the crystal garden and the alchemy table.
-- Both realms read this: the client uses it to grey out unaffordable actions
-- without a round trip, the server re-validates everything anyway.

Arcana = Arcana or {}
Arcana.Gardening = Arcana.Gardening or {}

local G = Arcana.Gardening

G.MAX_SLOTS = 10
G.SLOT_COLUMNS = 5 -- the bed is two rows of five, in the world and in the menu
G.MATURITY_TIME = 900 -- seconds from planting to full production
G.TICK = 5 -- server think interval
G.USE_RANGE = 200 -- how far a player may act on a station
G.FALLOW_TIME = 180 -- how long a poisoned slot stays unplantable

G.RESERVE_CAP = 500 -- dust the garden holds to pay upkeep
G.PENDING_CAP = 600 -- unharvested crystal dust ceiling
G.PENDING_ELEM_CAP = 60 -- unharvested ceiling per elemental dust

-- Starvation has to bite on the timescale someone is actually stood there:
-- at 1800 the first visible droop was ten minutes away, so an empty reserve
-- looked like nothing was happening at all.
G.WITHER_TIME = 300 -- healthy to dead with an empty reserve
G.RECOVER_TIME = 120 -- fully wilted back to healthy once fed again

-- Single letter codes keep the packed slot string short on the wire.
-- Petal counts differ per element so the flowers stay apart by shape: the
-- essence colours for frost, lightning and a plain crystal are all pale blue.
-- stems lists which stalk shapes the type can grow (see FlowerRender's
-- STEM_VARIANTS); the seed picks one, so a bed is not a row of identical rods.
--
-- Every element past the plain crystal carries a trait: something it does well
-- and something it costs, and a `neighbour` block it imposes on the slots
-- beside it.  A bed is a layout problem, not a shopping list.
--   growthMult / witherMult   multipliers on its own maturing and wilting
--   upkeepPerOther            extra upkeep per other flower in the bed
--   selfFeeding               draws no upkeep and cannot starve
--   rotPerSec                 wither gained once mature, which feeding cannot undo
--   discharge                 yields in bursts instead of continuously
--   fallowOnUproot            poisons the slot when removed
--   immuneTo                  ignores the neighbour block of these flower ids
--   neighbour.yield           above 1 it is a boost and does not stack, below
--                             1 it is a penalty and does
G.Flowers = {
	basic = {
		code = "b",
		petals = 6,
		stems = {1, 2},
		label = "Crystal Flower",
		short = "Crystal",
		order = 1,
		plantCost = {crystal_dust = 20},
		upkeepPerMin = 1,
		yieldPerMin = {crystal_dust = 3},
		-- Mana crystals are blue, not gold: this is the mana_crystal_shard
		-- item's own colour (lua/entities/arcana_crystal_shard.lua).
		color = Color(120, 200, 255),
		-- No trait, but it still answers for itself in the picker
		traitLines = {
			"Matures in 15 minutes, 3 dust a minute",
			"Costs 1 dust a minute",
			"Does nothing to its neighbours",
		},
	},
	fire = {
		code = "f",
		petals = 5,
		stems = {3, 5},
		label = "Ember Flower",
		short = "Ember",
		order = 2,
		plantCost = {crystal_dust = 20, fire_dust = 10},
		upkeepPerMin = 4,
		yieldPerMin = {crystal_dust = 7, fire_dust = 0.5},
		color = Color(255, 120, 40),
		growthMult = 1.7,
		witherMult = 2,
		neighbour = {growth = 1.25, upkeep = 1.5},
		traitShort = "Fast and hungry",
		traitLines = {
			"Matures 70% faster, 7 dust a minute",
			"Costs 4 dust a minute, wilts twice as fast",
			"Neighbours grow faster but cost 50% more",
		},
	},
	frost = {
		code = "r",
		petals = 8,
		stems = {1, 2},
		label = "Rime Flower",
		short = "Rime",
		order = 3,
		plantCost = {crystal_dust = 15, frost_dust = 8},
		upkeepPerMin = 1,
		yieldPerMin = {crystal_dust = 4, frost_dust = 0.4},
		color = Color(170, 220, 255),
		growthMult = 0.55,
		witherMult = 0.3,
		neighbour = {wither = 0.4, upkeep = 0.7},
		traitShort = "Slow, cheap, hardy",
		traitLines = {
			"Matures 45% slower, 4 dust a minute",
			"Costs 1 dust a minute and barely wilts",
			"Neighbours wilt slower and cost 30% less",
		},
	},
	lightning = {
		code = "l",
		petals = 4,
		arcs = true, -- draws electric arcs off the bloom, see FlowerRender
		stems = {4, 2},
		label = "Storm Flower",
		short = "Storm",
		order = 4,
		plantCost = {crystal_dust = 20, lightning_dust = 10},
		upkeepPerMin = 2,
		-- Everything it makes arrives through discharge, so it has no steady rate
		yieldPerMin = {},
		color = Color(150, 200, 255),
		discharge = {
			interval = 40,
			yield = {crystal_dust = 5, lightning_dust = 0.4},
			-- One neighbour catches the bolt: a scorch or a growth spurt
			scorch = 0.2,
			jolt = 0.06,
		},
		traitShort = "Yields in bursts",
		traitLines = {
			"Nothing steady: a burst every 40 seconds",
			"Averages 7.5 dust a minute once mature",
			"Every burst jolts or scorches a neighbour",
		},
	},
	poison = {
		code = "p",
		petals = 7,
		stems = {3, 4},
		label = "Blight Flower",
		short = "Blight",
		order = 5,
		plantCost = {crystal_dust = 30, poison_dust = 10},
		upkeepPerMin = 0,
		yieldPerMin = {crystal_dust = 9, poison_dust = 1.2},
		color = Color(120, 210, 70),
		selfFeeding = true,
		rotPerSec = 1 / 600,
		fallowOnUproot = true,
		immuneTo = {poison = true},
		-- Beats the RECOVER_TIME of 120 outright, so a neighbour loses ground
		-- even with a full reserve behind it
		neighbour = {witherAdd = 1 / 100, yield = 0.7},
		traitShort = "Free upkeep, short life",
		traitLines = {
			"Needs no dust at all, 9 dust a minute",
			"Rots away 10 minutes after maturing",
			"Neighbours wilt and yield 30% less",
			"Leaves the slot fallow for 3 minutes",
		},
	},
	arcane = {
		code = "a",
		petals = 6,
		stems = {5, 2},
		label = "Arcane Flower",
		short = "Arcane",
		order = 6,
		plantCost = {crystal_dust = 40, arcane_dust = 12},
		upkeepPerMin = 2,
		upkeepPerOther = 1,
		yieldPerMin = {crystal_dust = 2, arcane_dust = 0.5},
		color = Color(180, 120, 255),
		growthMult = 0.8,
		neighbour = {yield = 1.5, wither = 0.7},
		traitShort = "Boosts its neighbours",
		traitLines = {
			"Neighbours yield 50% more and wilt slower",
			"Poor on its own, matures 20% slower",
			"Costs 2 dust a minute, plus 1 per other flower",
		},
	},
}

-- Ordered view for the UI, plus a code lookup for unpacking slot strings.
G.FlowerOrder = {}
G.FlowerByCode = {}

for id, def in pairs(G.Flowers) do
	def.id = id
	G.FlowerOrder[#G.FlowerOrder + 1] = def
	G.FlowerByCode[def.code] = def
end

table.sort(G.FlowerOrder, function(a, b) return a.order < b.order end)

-- Slots touching the given one: left, right, and the one directly across in
-- the other row.  Two at the corners, three everywhere else.  The layout is
-- fixed, so the answer is worked out once per slot and kept.
local neighbourCache = {}

function G.Neighbours(index)
	local cached = neighbourCache[index]
	if cached then return cached end

	local cols = G.SLOT_COLUMNS
	local col = (index - 1) % cols
	local row = math.floor((index - 1) / cols)
	local out = {}

	if col > 0 then out[#out + 1] = index - 1 end
	if col < cols - 1 then out[#out + 1] = index + 1 end
	out[#out + 1] = row == 0 and index + cols or index - cols

	neighbourCache[index] = out

	return out
end

-- Resolves every flower's traits and its neighbours' into one modifier per
-- slot.  Pure and shared: the server runs it each tick to drive the maths, the
-- menu runs it on the unpacked slot string to show a plant's live figures, so
-- neither side has to network a modifier.
--
-- upkeep/growth/yield/wither are multipliers, upkeepAdd is dust per minute and
-- witherAdd is wither per second.
function G.ComputeMods(flowers)
	local mods = {}
	local planted = 0

	for i = 1, G.MAX_SLOTS do
		mods[i] = {upkeep = 1, growth = 1, yield = 1, wither = 1, upkeepAdd = 0, witherAdd = 0}

		local f = flowers and flowers[i]
		if f and G.Flowers[f.id] then planted = planted + 1 end
	end

	-- Boosts are taken at their best rather than multiplied out: a flower
	-- flanked by two Arcanes is helped once, not squared.
	local boost = {}

	for i = 1, G.MAX_SLOTS do
		local f = flowers and flowers[i]
		local def = f and G.Flowers[f.id]

		if def then
			local m = mods[i]
			m.growth = m.growth * (def.growthMult or 1)
			m.wither = m.wither * (def.witherMult or 1)
			m.upkeepAdd = m.upkeepAdd + (def.upkeepPerOther or 0) * math.max(0, planted - 1)

			local n = def.neighbour

			if n then
				for _, j in ipairs(G.Neighbours(i)) do
					local other = flowers[j]
					local odef = other and G.Flowers[other.id]

					if odef and not (odef.immuneTo and odef.immuneTo[def.id]) then
						local mo = mods[j]
						mo.upkeep = mo.upkeep * (n.upkeep or 1)
						mo.growth = mo.growth * (n.growth or 1)
						mo.wither = mo.wither * (n.wither or 1)
						mo.witherAdd = mo.witherAdd + (n.witherAdd or 0)

						if n.yield then
							if n.yield > 1 then
								boost[j] = math.max(boost[j] or 1, n.yield)
							else
								mo.yield = mo.yield * n.yield
							end
						end
					end
				end
			end
		end
	end

	for j, best in pairs(boost) do
		mods[j].yield = mods[j].yield * best
	end

	return mods
end

-- Dust variants produced at the alchemy table. Every ingredient is an item
-- that already exists in the addon, so no new sources are needed.
G.Recipes = {
	{
		id = "fire_dust",
		label = "Ember Dust",
		ingredients = {crystal_dust = 25, radioactive = 1},
		output = {fire_dust = 5},
		color = Color(255, 120, 40),
	},
	{
		id = "frost_dust",
		label = "Rime Dust",
		ingredients = {crystal_dust = 25, waterbottle = 1},
		output = {frost_dust = 5},
		color = Color(170, 220, 255),
	},
	{
		id = "lightning_dust",
		label = "Storm Dust",
		ingredients = {crystal_dust = 25, battery = 1},
		output = {lightning_dust = 5},
		color = Color(150, 200, 255),
	},
	{
		id = "poison_dust",
		label = "Blight Dust",
		ingredients = {crystal_dust = 25, solidified_spores = 1},
		output = {poison_dust = 5},
		color = Color(120, 210, 70),
	},
	{
		id = "arcane_dust",
		label = "Arcane Dust",
		ingredients = {crystal_dust = 25, mana_crystal_shard = 1},
		output = {arcane_dust = 5},
		color = Color(180, 120, 255),
	},
}

G.RecipeById = {}

for _, r in ipairs(G.Recipes) do
	G.RecipeById[r.id] = r
end

-- Coins paid per unit when exchanging dust at the alchemy table.  The rates
-- track how hard each one is to farm: Blight pours poison dust out, Rime and
-- Arcane barely trickle.
G.SellRates = {
	crystal_dust = 5,
	poison_dust = 30,
	fire_dust = 45,
	lightning_dust = 55,
	frost_dust = 65,
	arcane_dust = 90,
}

-- Ordered so the exchange list does not shuffle between openings.
G.SellOrder = {"crystal_dust", "fire_dust", "frost_dust", "lightning_dust", "poison_dust", "arcane_dust"}

G.DustColors = {
	crystal_dust = Color(120, 200, 255),
	fire_dust = Color(255, 120, 40),
	frost_dust = Color(170, 220, 255),
	lightning_dust = Color(150, 200, 255),
	poison_dust = Color(120, 210, 70),
	arcane_dust = Color(180, 120, 255),
}

-- Packs the server side flower table into the networked slot string.
-- Format: one entry per slot, "-" when empty, "x:<seconds>" while the ground is
-- fallow, otherwise "code:growth:wither" with both fractions as integer
-- percentages.  Carrying the fallow countdown here saves a second net path for
-- it, and the menu needs it to grey the card out.
function G.PackSlots(flowers, fallow)
	local parts = {}

	for i = 1, G.MAX_SLOTS do
		local f = flowers and flowers[i]
		local rest = fallow and fallow[i]

		if f then
			local def = G.Flowers[f.id]
			parts[i] = string.format("%s:%d:%d", def and def.code or "b", math.Round((f.growth or 0) * 100), math.Round((f.wither or 0) * 100))
		elseif rest and rest > 0 then
			parts[i] = string.format("x:%d", math.ceil(rest))
		else
			parts[i] = "-"
		end
	end

	return table.concat(parts, "|")
end

-- Inverse of PackSlots. Returns an array with holes for empty slots, each entry
-- either a planted {id, growth, wither} or a {fallow = seconds}.
function G.UnpackSlots(packed)
	local out = {}
	if not packed or packed == "" then return out end

	local i = 0

	for part in string.gmatch(packed, "[^|]+") do
		i = i + 1
		if i > G.MAX_SLOTS then break end

		if part ~= "-" then
			local rest = string.match(part, "^x:(%d+)$")

			if rest then
				out[i] = {fallow = tonumber(rest)}
			else
				local code, growth, wither = string.match(part, "^(%a):(%d+):(%d+)$")
				local def = code and G.FlowerByCode[code]

				if def then
					out[i] = {
						id = def.id,
						growth = math.Clamp(tonumber(growth) / 100, 0, 1),
						wither = math.Clamp(tonumber(wither) / 100, 0, 1),
					}
				end
			end
		end
	end

	return out
end

-- Plain wording for the condition column, shared by the UI and the slot cards.
function G.ConditionLabel(wither)
	if (wither or 0) >= 0.7 then return "Dying" end
	if (wither or 0) >= 0.2 then return "Withering" end

	return "Healthy"
end
