local Arcana = _G.Arcana or {}

if SERVER then
	Arcana.ManaCrystals = Arcana.ManaCrystals or {}
	local M = Arcana.ManaCrystals

	-- Configuration
	M.Config = M.Config or {
		hotspotJoinRadius = 2000,    -- distance to merge reports into an existing hotspot
		hotspotDecayPerSecond = 6,  -- how fast hotspot intensity decays
		hotspotSpawnThreshold = 70, -- intensity required to attempt a spawn (increased from 40)
		hotspotTrimBelow = 4,       -- remove hotspots below this intensity
		hotspotDecayGracePeriod = 600, -- seconds before decay starts after last magic use (10 minutes)

		crystalSearchRadius = 2000,  -- try to find/grow an existing crystal within this distance
		crystalGrowthPerCast = 6,   -- growth points added per cast nearby (base value)
		crystalSpawnInitialGrowth = 6, -- initial growth given to freshly spawned crystals
		crystalMaxScale = 2.2,      -- maximum model scale
		crystalMinScale = 0.35,     -- starting model scale
		crystalMaxPerArea = 2,      -- limit new spawns if too many are near
		areaLimitRadius = 2000,      -- radius to count nearby crystals for the area limit
		hotspotSpawnCooldown = 10,   -- minimum seconds between spawns per hotspot

		-- Cooldown scaling: spells with shorter cooldowns contribute less to crystal growth
		cooldownReference = 1.0,    -- reference cooldown (seconds) for full contribution
		cooldownScalingFactor = 0.7, -- how much cooldown affects growth (0-1, higher = more impact)

		-- Corruption area grouping
		regionRadius = 2000,          -- radius used to group positions into a corruption area cell

		-- Corruption from crystal destruction (replaces overdraw-based corruption)
		corruptionDestructionBase = 0.05,       -- very light base corruption per destroyed crystal
		corruptionDestructionSizeFactor = 0.35, -- additional corruption scaled by crystal size (0..1)
		corruptionDestructionEscalation = 0.06, -- per-region escalation per successive destruction (linear)

		-- Natural mana spots: places where mana concentrated before any player cast a
		-- spell, so mana dust gathering (and the economy built on it) works on a fresh map
		naturalSpotCount = 8,             -- natural spots seeded per map
		naturalSpotCapacity = 70,         -- max stored intensity of a natural spot
		naturalSpotRegenPerSecond = 0.15, -- refill rate (empty to full in ~8 minutes)
		naturalSpotMinSpacing = 3000,     -- minimum distance between natural spots
	}

	M.hotspots = M.hotspots or {}
	M.regions = M.regions or {}
	M._saveDir = "arcana"

	-- Track per-region destruction counts to escalate corruption on repeated crystal destruction
	M._regionDestructionCounts = M._regionDestructionCounts or {} -- { [regionKey] = count }

	-- Save file is map-specific; resolved at runtime via GetSaveFile()
	function M:GetSaveFile()
		local map = game.GetMap()
		map = tostring(map)

		-- sanitize map name for filesystem
		map = map:gsub("[^%w_%-%.]", "_")
		return string.format("%s/arcana_mana_state_%s.json", self._saveDir, map)
	end

	local function groundAt(pos)
		local tr = util.TraceLine({
			start = pos + Vector(0, 0, 64),
			endpos = pos - Vector(0, 0, 4096),
			mask = MASK_SOLID_BRUSHONLY
		})

		if tr.Hit then
			return tr.HitPos, tr.HitNormal
		end

		return pos, vector_up
	end

	local function findNearestHotspot(pos, maxDist)
		local nearest, distSqr, idx
		for i = 1, #M.hotspots do
			local h = M.hotspots[i]
			local d2 = h.pos:DistToSqr(pos)
			if d2 <= maxDist * maxDist and (not distSqr or d2 < distSqr) then
				nearest, distSqr, idx = h, d2, i
			end
		end

		return nearest, idx
	end

	local function countCrystalsNear(pos, radius)
		local n = 0
		for _, ent in ipairs(ents.FindInSphere(pos, radius)) do
			if IsValid(ent) and ent:GetClass() == "arcana_mana_crystal" then
				n = n + 1
			end
		end

		return n
	end

	local function findCrystalNear(pos, radius)
		local best, bestD2
		for _, ent in ipairs(ents.FindInSphere(pos, radius)) do
			if IsValid(ent) and ent:GetClass() == "arcana_mana_crystal" then
				local d2 = ent:GetPos():DistToSqr(pos)
				if not best or d2 < bestD2 then
					best, bestD2 = ent, d2
				end
			end
		end

		return best
	end

	local function spawnCrystalAt(pos, normal)
		if not util.IsInWorld(pos) then return nil end

		local ent = ents.Create("arcana_mana_crystal")
		if not IsValid(ent) then return nil end

		ent:SetPos(pos + (normal or vector_up) * 4)
		ent:SetAngles(Angle(0, math.random(0, 359), 0))
		ent:Spawn()
		ent:DropToFloor()
		ent.initialSpawn = true

		local snd = CreateSound(ent, "ambient/levels/labs/teleport_winddown1.wav")
		snd:SetDSP(16)
		snd:SetSoundLevel(80)
		snd:ChangePitch(math.random(150, 180))
		snd:Play()

		timer.Simple(0.5, function()
			if not IsValid(ent) then return end

			ent:DropToFloor()

			local tr = util.TraceLine({
				start = ent:GetPos(),
				endpos = ent:GetPos() - Vector(0, 0, 10),
				mask = MASK_SOLID,
				filter = ent,
			})

			if not tr.Hit then
				-- we dont want flying crystals
				SafeRemoveEntity(ent)
				return
			end

			ent.initialSpawn = nil
		end)

		-- Start small
		ent:SetCrystalScale(M.Config.crystalMinScale)

		return ent
	end

	function M:ReportMagicUse(ply, pos, spellId, context)
		if not isvector(pos) then return end
		local cfg = self.Config
		local now = CurTime()

		-- Calculate growth contribution based on spell cooldown
		-- Shorter cooldown spells contribute less to prevent spam farming
		local spellCooldown = tonumber(context and context.cooldown) or cfg.cooldownReference or 1.0
		local refCooldown = cfg.cooldownReference or 1.0
		local scaleFactor = cfg.cooldownScalingFactor or 0.7

		-- Growth formula: base * (scaled_ratio + (1-scale) to ensure minimum contribution)
		-- Example: 0.5s cooldown with 0.7 scaleFactor -> contributes ~53% of base growth
		-- Example: 2.0s cooldown with 0.7 scaleFactor -> contributes ~88% of base growth
		local cooldownRatio = math.Clamp(spellCooldown / refCooldown, 0.1, 3.0)
		local growthMultiplier = (cooldownRatio * scaleFactor) + (1 - scaleFactor)
		local growthAmount = cfg.crystalGrowthPerCast * growthMultiplier

		-- Merge into an existing hotspot or create new
		local h = findNearestHotspot(pos, cfg.hotspotJoinRadius)
		if not h then
			h = {pos = pos, value = 0, touched = now, _lastIncrease = now}
			table.insert(self.hotspots, h)
		end

		-- Increase intensity and timestamp
		h.value = (h.value or 0) + growthAmount
		h.touched = now
		h._lastIncrease = now

		-- First, try to grow an existing crystal nearby
		local crystal = findCrystalNear(h.pos, cfg.crystalSearchRadius)
		if IsValid(crystal) and crystal.AddCrystalGrowth then
			crystal:AddCrystalGrowth(growthAmount)
			return
		end

		-- Otherwise, consider spawning if hotspot is strong, area is not saturated, and cooldown passed
		if (h.value or 0) >= cfg.hotspotSpawnThreshold
			and countCrystalsNear(h.pos, cfg.areaLimitRadius) < cfg.crystalMaxPerArea
			and ((h.lastSpawn or 0) + (cfg.hotspotSpawnCooldown or 0) <= now) then
			local groundPos, nrm = groundAt(h.pos)
			local ent = spawnCrystalAt(groundPos, nrm)
			if IsValid(ent) and ent.AddCrystalGrowth then
				-- New crystals should start small; only seed with a minimal growth amount
				local seedGrowth = cfg.crystalSpawnInitialGrowth or cfg.crystalGrowthPerCast or 0
				ent:AddCrystalGrowth(seedGrowth)
			end

			-- Reduce hotspot to avoid immediately spawning again
			h.value = math.max(0, (h.value or 0) - cfg.hotspotSpawnThreshold * 0.75)
			h.lastSpawn = now
		end
	end

	-- Picks a random walkable ground position for a natural spot. The first downward
	-- trace from the top of the world bounds hits the OUTSIDE of the skybox ceiling
	-- (out of world), so the column is walked downward, restarting just below each
	-- out-of-world hit, until an in-world floor is found. Restarted traces may begin
	-- inside a brush: StartSolid is fine, only AllSolid means solid all the way down.
	local function tryFindNaturalSpotPos()
		local world = game.GetWorld()
		if not world or not world.GetModelBounds then return nil end

		local mins, maxs = world:GetModelBounds()
		local x = math.Rand(mins.x, maxs.x)
		local y = math.Rand(mins.y, maxs.y)

		local z = maxs.z
		for _ = 1, 8 do
			local tr = util.TraceLine({
				start = Vector(x, y, z),
				endpos = Vector(x, y, mins.z),
				mask = MASK_SOLID_BRUSHONLY,
			})

			if not tr.Hit or tr.AllSolid then return nil end

			local pos = tr.HitPos + vector_up * 8
			if tr.HitNormal.z >= 0.7 and util.IsInWorld(pos) then
				return pos
			end

			if tr.HitPos.z <= mins.z + 1 then return nil end
			z = tr.HitPos.z - 1
		end

		return nil
	end

	-- Fallback sampling anchored on player spawn points: always lands in reachable play
	-- space, unlike blind world-bounds sampling which can fail on odd geometry.
	local SPAWN_CLASSES = {"info_player_start", "info_player_deathmatch", "info_player_terrorist", "info_player_counterterrorist", "info_player_combine", "info_player_rebel", "gmod_player_start"}

	local function tryFindSpawnAreaPos()
		local spawns = {}
		for _, cls in ipairs(SPAWN_CLASSES) do
			for _, e in ipairs(ents.FindByClass(cls)) do
				if IsValid(e) then
					spawns[#spawns + 1] = e
				end
			end
		end

		if #spawns == 0 then return nil end

		local base = spawns[math.random(#spawns)]:GetPos()
		local offset = VectorRand() * math.Rand(150, 1200)
		offset.z = 0
		local probe = base + offset
		local tr = util.TraceLine({
			start = probe + Vector(0, 0, 128),
			endpos = probe - Vector(0, 0, 4096),
			mask = MASK_SOLID_BRUSHONLY,
		})

		if not tr.Hit or tr.AllSolid then return nil end
		if tr.HitNormal.z < 0.7 then return nil end

		local pos = tr.HitPos + vector_up * 8
		if not util.IsInWorld(pos) then return nil end

		return pos
	end

	-- Tops the map up to the configured number of natural spots. They are ordinary
	-- hotspots as far as the siphon is concerned, but never decay and refill over time.
	-- Placement must always end with at least one spot on the map: the dust economy has
	-- no other bootstrap. Spacing relaxes by half each pass so small maps still fit
	-- their spots, and the last resort anchors a spot near a player spawn.
	function M:EnsureNaturalSpots()
		local cfg = self.Config
		local want = cfg.naturalSpotCount or 8
		local have = 0
		for i = 1, #self.hotspots do
			if self.hotspots[i].natural then have = have + 1 end
		end
		if have >= want then return end

		local function addSpot(pos)
			local now = CurTime()
			table.insert(self.hotspots, {
				pos = pos,
				value = cfg.naturalSpotCapacity or 70,
				natural = true,
				touched = now,
				_lastIncrease = now,
			})
			have = have + 1
		end

		local function isTooClose(pos, spacing)
			for i = 1, #self.hotspots do
				local h = self.hotspots[i]
				if h.natural and h.pos:DistToSqr(pos) < spacing * spacing then
					return true
				end
			end

			return false
		end

		local baseSpacing = cfg.naturalSpotMinSpacing or 3000
		for _, spacingMul in ipairs({1, 0.5, 0.25}) do
			local spacing = baseSpacing * spacingMul
			local attempts = (want - have) * 50
			while have < want and attempts > 0 do
				attempts = attempts - 1
				local pos = tryFindNaturalSpotPos()
				if pos and not isTooClose(pos, spacing) then
					addSpot(pos)
				end
			end

			if have >= want then return end
		end

		-- World sampling failed outright: fall back to spawn-area placement with only a
		-- light spacing requirement, so the map is never left without a single source
		local attempts = (want - have) * 20
		while have < want and attempts > 0 do
			attempts = attempts - 1
			local pos = tryFindSpawnAreaPos()
			if pos and not isTooClose(pos, 500) then
				addSpot(pos)
			end
		end
	end

	-- Hash a world position into a region key (grid-based for stability)
	local function regionKey(pos, size)
		size = size or (M.Config and M.Config.regionRadius or 900)
		local cell = size * 2
		local x = math.floor(pos.x / cell)
		local y = math.floor(pos.y / cell)
		return tostring(x) .. ":" .. tostring(y)
	end

	-- Find or create a corrupted area entity attached to a region center
	local function ensureCorruptedArea(key, center)
		local region = M.regions[key]
		if region and IsValid(region.corruptEnt) then return region.corruptEnt end
		if not util.IsInWorld(center) then return nil end

		-- Spawn at low intensity at the region center
		local ent = ents.Create("arcana_corrupted_area")
		if not IsValid(ent) then return nil end
		ent:SetPos(center)
		ent:Spawn()
		ent:SetRadius(M.Config.regionRadius)
		ent:SetIntensity(0)

		M.regions[key] = M.regions[key] or {center = center}
		M.regions[key].corruptEnt = ent
		return ent
	end

	-- Report crystal destruction to increase corruption in the affected region
	function M:ReportCrystalDestroyed(crystalEnt)
		if not IsValid(crystalEnt) then return end
		local cfg = self.Config or {}
		local pos = crystalEnt:GetPos()
		local key = regionKey(pos, cfg.regionRadius)
		local center = pos
		local corruptEnt = ensureCorruptedArea(key, center)
		if not IsValid(corruptEnt) then return end

		-- If the existing corrupted area does not cover this position, move it here
		local r = (corruptEnt.GetRadius and corruptEnt:GetRadius()) or (cfg.regionRadius or 900)
		local curI = corruptEnt:GetIntensity() or 0
		if pos:DistToSqr(corruptEnt:GetPos()) > (r * r) and curI < 0.7 then
			corruptEnt:SetPos(pos)
			M.regions[key] = M.regions[key] or {}
			M.regions[key].center = pos
		end

		-- Determine size factor from crystal scale (normalized 0..1 between min/max)
		local s = (crystalEnt.GetCrystalScale and crystalEnt:GetCrystalScale()) or 1
		local minS = tonumber(cfg.crystalMinScale) or 0.35
		local maxS = tonumber(cfg.crystalMaxScale) or 2.2
		local sizeT = 0
		if maxS > minS then
			sizeT = math.Clamp((s - minS) / (maxS - minS), 0, 1)
		end

		-- Per-region escalation: each destruction increases subsequent corruption slightly
		local count = (self._regionDestructionCounts[key] or 0) + 1
		self._regionDestructionCounts[key] = count
		local escalateMul = 1 + (count - 1) * (cfg.corruptionDestructionEscalation or 0.06)

		local base = cfg.corruptionDestructionBase or 0.05
		local sizeAdd = (cfg.corruptionDestructionSizeFactor or 0.35) * sizeT
		local add = (base + sizeAdd) * escalateMul

		corruptEnt:SetIntensity(math.Clamp(curI + add, 0, 2))
	end

	--====================
	-- Persistence (Server)
	--====================
	local function encodeVector(v)
		return {x = v.x, y = v.y, z = v.z}
	end

	local function decodeVector(t)
		if not istable(t) then return Vector(0, 0, 0) end
		return Vector(tonumber(t.x) or 0, tonumber(t.y) or 0, tonumber(t.z) or 0)
	end

	function M:SerializeState()
		local map = game and game.GetMap and game.GetMap() or "unknown_map"
		local state = {version = 1, map = map, crystals = {}, hotspots = {}, corruption = {}}

		-- Crystals: position, scale, stored mana
		for _, c in ipairs(ents.FindByClass("arcana_mana_crystal")) do
			if IsValid(c) and not c.initialSpawn then
				local tr = util.TraceLine({
					start = c:GetPos(),
					endpos = c:GetPos() - Vector(0, 0, 10),
					mask = MASK_SOLID,
					filter = c,
				})

				if not tr.Hit then
					-- we dont want flying crystals
					SafeRemoveEntity(c)
					continue
				end

				state.crystals[#state.crystals + 1] = {
					pos = encodeVector(c:GetPos()),
					scale = tonumber(c.GetCrystalScale and c:GetCrystalScale() or 1) or 1,
				}
			end
		end

		-- Hotspots: pos, value, natural flag (natural spots keep their place across restarts)
		for i = 1, #self.hotspots do
			local h = self.hotspots[i]
			state.hotspots[#state.hotspots + 1] = {pos = encodeVector(h.pos), value = tonumber(h.value) or 0, natural = h.natural and true or nil}
		end

		-- Corruption areas: center, intensity
		for key, reg in pairs(self.regions) do
			local e = reg and reg.corruptEnt
			if IsValid(e) then
				state.corruption[#state.corruption + 1] = {
					center = encodeVector(e:GetPos()),
					intensity = math.Clamp(tonumber(e:GetIntensity() or 0) or 0, 0, 2),
				}
			end
		end

		return state
	end

	function M:SaveState()
		local data = self:SerializeState()
		local json = util.TableToJSON(data, false)
		if not file.Exists(self._saveDir, "DATA") then
			file.CreateDir(self._saveDir)
		end
		file.Write(self:GetSaveFile(), json or "{}")
	end

	local function spawnCrystalRestored(entry)
		local pos = decodeVector(entry.pos or {})
		local groundPos, nrm = groundAt(pos)
		local ent = spawnCrystalAt(groundPos, nrm)
		if IsValid(ent) then
			local scale = tonumber(entry.scale) or M.Config.crystalMinScale
			if ent.SetCrystalScale then ent:SetCrystalScale(scale) end
		end
	end

	local function spawnCorruptionRestored(entry)
		local center = decodeVector(entry.center or {})
		local e = ents.Create("arcana_corrupted_area")
		if not IsValid(e) then return end

		e:SetPos(center)
		e:Spawn()
		e:SetRadius(M.Config.regionRadius)
		e:SetIntensity(math.Clamp(tonumber(entry.intensity) or 0, 0, 2))

		if e._lastIntensityIncrease then
			e._lastIntensityIncrease = CurTime()
		end

		local key = regionKey(center, M.Config.regionRadius)
		M.regions[key] = M.regions[key] or {center = center}
		M.regions[key].corruptEnt = e
	end

	function M:LoadState()
		local savePath = self:GetSaveFile()
		if not file.Exists(savePath, "DATA") then return false end

		local data = Arcana.DecodeJSON(file.Read(savePath, "DATA"), "mana crystal state (" .. savePath .. ")", nil)
		if not data then return false end

		-- Guard: ensure the stored map matches current map (in case of manual copy)
		local curMap = (game and game.GetMap and game.GetMap()) or "unknown_map"
		if isstring(data.map) and data.map ~= curMap then
			return false
		end

		-- Clear current tracking tables
		self.hotspots = {}
		self.regions = {}

		-- Restore hotspots
		for _, h in ipairs(data.hotspots or {}) do
			local pos = decodeVector(h.pos or {})
			local value = tonumber(h.value) or 0
			local now = CurTime()
			self.hotspots[#self.hotspots + 1] = {pos = pos, value = value, natural = h.natural and true or nil, touched = now, _lastIncrease = now}
		end

		-- Restore crystals
		for _, c in ipairs(data.crystals or {}) do
			spawnCrystalRestored(c)
		end

		-- Restore corruption areas
		for _, ca in ipairs(data.corruption or {}) do
			spawnCorruptionRestored(ca)
		end

		return true
	end

	-- Load state after entities spawn; autosave periodically
	hook.Add("InitPostEntity", "Arcana_Mana_LoadState", function()
		if not Arcana or not Arcana.ManaCrystals then return end
		Arcana.ManaCrystals:LoadState()
		-- Runs whether or not a save existed: fresh maps get their natural spots, and
		-- maps saved before natural spots existed get topped up to the configured count.
		Arcana.ManaCrystals:EnsureNaturalSpots()
	end)

	timer.Create("Arcana_ManaEnvironment_Autosave", 60, 0, function()
		if not Arcana or not Arcana.ManaCrystals then return end
		Arcana.ManaCrystals:SaveState()
	end)

	-- Periodic top-up of natural spots. The InitPostEntity seeding alone is not enough:
	-- it never re-fires on a live server after a file reload, and a placement pass can
	-- come up short on difficult geometry. This timer makes the map converge to always
	-- having sources. Cheap no-op once the configured count exists.
	timer.Create("Arcana_ManaEnvironment_NaturalSpots", 60, 0, function()
		if not Arcana or not Arcana.ManaCrystals then return end
		Arcana.ManaCrystals:EnsureNaturalSpots()
	end)

	-- Hotspot decay timer (similar to corruption decay)
	timer.Create("Arcana_ManaEnvironment_HotspotDecay", 1, 0, function()
		if not Arcana or not Arcana.ManaCrystals then return end

		local cfg = Arcana.ManaCrystals.Config
		local now = CurTime()
		local decayGrace = cfg.hotspotDecayGracePeriod or 600

		for i = #Arcana.ManaCrystals.hotspots, 1, -1 do
			local h = Arcana.ManaCrystals.hotspots[i]

			if h.natural then
				-- Natural spots never decay or trim; they slowly refill after being siphoned
				local cap = cfg.naturalSpotCapacity or 70
				h.value = math.min(cap, (h.value or 0) + (cfg.naturalSpotRegenPerSecond or 0.15))
				continue
			end

			local timeSinceIncrease = now - (h._lastIncrease or h.touched or now)

			-- Only decay if grace period has passed since last magic use
			if timeSinceIncrease >= decayGrace then
				-- Apply decay
				h.value = math.max(0, (h.value or 0) - cfg.hotspotDecayPerSecond)
			end

			-- Remove hotspots below threshold
			if (h.value or 0) <= cfg.hotspotTrimBelow then
				table.remove(Arcana.ManaCrystals.hotspots, i)
			end
		end
	end)
end