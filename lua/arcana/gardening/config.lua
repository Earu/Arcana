-- Shared tuning for the crystal garden and the alchemy table.
-- Both realms read this: the client uses it to grey out unaffordable actions
-- without a round trip, the server re-validates everything anyway.

Arcana = Arcana or {}
Arcana.Gardening = Arcana.Gardening or {}

local G = Arcana.Gardening

G.MAX_SLOTS = 10
G.MATURITY_TIME = 900 -- seconds from planting to full production
G.TICK = 5 -- server think interval
G.USE_RANGE = 200 -- how far a player may act on a station

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
	},
	fire = {
		code = "f",
		petals = 5,
		stems = {3, 5},
		label = "Ember Flower",
		short = "Ember",
		order = 2,
		plantCost = {crystal_dust = 20, fire_dust = 10},
		upkeepPerMin = 2,
		yieldPerMin = {crystal_dust = 6, fire_dust = 0.5},
		color = Color(255, 120, 40),
	},
	frost = {
		code = "r",
		petals = 8,
		stems = {1, 2},
		label = "Rime Flower",
		short = "Rime",
		order = 3,
		plantCost = {crystal_dust = 20, frost_dust = 10},
		upkeepPerMin = 2,
		yieldPerMin = {crystal_dust = 6, frost_dust = 0.5},
		color = Color(170, 220, 255),
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
		yieldPerMin = {crystal_dust = 6, lightning_dust = 0.5},
		color = Color(150, 200, 255),
	},
	poison = {
		code = "p",
		petals = 7,
		stems = {3, 4},
		label = "Blight Flower",
		short = "Blight",
		order = 5,
		plantCost = {crystal_dust = 20, poison_dust = 10},
		upkeepPerMin = 2,
		yieldPerMin = {crystal_dust = 6, poison_dust = 0.5},
		color = Color(120, 210, 70),
	},
	arcane = {
		code = "a",
		petals = 6,
		stems = {5, 2},
		label = "Arcane Flower",
		short = "Arcane",
		order = 6,
		plantCost = {crystal_dust = 20, arcane_dust = 10},
		upkeepPerMin = 2,
		yieldPerMin = {crystal_dust = 6, arcane_dust = 0.5},
		color = Color(180, 120, 255),
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

-- Coins paid per unit when exchanging dust at the alchemy table.
G.SellRates = {
	crystal_dust = 5,
	fire_dust = 50,
	frost_dust = 50,
	lightning_dust = 50,
	poison_dust = 50,
	arcane_dust = 60,
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
-- Format: one entry per slot, "-" when empty, otherwise "code:growth:wither"
-- with both fractions as integer percentages.
function G.PackSlots(flowers)
	local parts = {}

	for i = 1, G.MAX_SLOTS do
		local f = flowers and flowers[i]

		if f then
			local def = G.Flowers[f.id]
			parts[i] = string.format("%s:%d:%d", def and def.code or "b", math.Round((f.growth or 0) * 100), math.Round((f.wither or 0) * 100))
		else
			parts[i] = "-"
		end
	end

	return table.concat(parts, "|")
end

-- Inverse of PackSlots. Returns an array of {id, growth, wither} with holes
-- for empty slots.
function G.UnpackSlots(packed)
	local out = {}
	if not packed or packed == "" then return out end

	local i = 0

	for part in string.gmatch(packed, "[^|]+") do
		i = i + 1
		if i > G.MAX_SLOTS then break end

		if part ~= "-" then
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

	return out
end

-- Plain wording for the condition column, shared by the UI and the slot cards.
function G.ConditionLabel(wither)
	if (wither or 0) >= 0.7 then return "Dying" end
	if (wither or 0) >= 0.2 then return "Withering" end

	return "Healthy"
end
