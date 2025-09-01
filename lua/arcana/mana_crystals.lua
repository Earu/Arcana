local Arcane = _G.Arcane or {}

if SERVER then
	Arcane.ManaCrystals = Arcane.ManaCrystals or {}
	local M = Arcane.ManaCrystals

	-- Configuration
	M.Config = M.Config or {
		hotspotJoinRadius = 2000,    -- distance to merge reports into an existing hotspot
		hotspotDecayPerSecond = 6,  -- how fast hotspot intensity decays
		hotspotSpawnThreshold = 40, -- intensity required to attempt a spawn
		hotspotTrimBelow = 4,       -- remove hotspots below this intensity

		crystalSearchRadius = 2000,  -- try to find/grow an existing crystal within this distance
		crystalGrowthPerCast = 6,   -- growth points added per cast nearby
		crystalSpawnInitialGrowth = 6, -- initial growth given to freshly spawned crystals
		crystalMaxScale = 2.2,      -- maximum model scale
		crystalMinScale = 0.35,     -- starting model scale
		crystalMaxPerArea = 2,      -- limit new spawns if too many are near
		areaLimitRadius = 2000,      -- radius to count nearby crystals for the area limit
		hotspotSpawnCooldown = 10,   -- minimum seconds between spawns per hotspot
		-- Environment grouping and regen
		regionRadius = 2000,          -- radius to group crystals into an environment cell
		regionRegenPerSecond = 80,   -- how much mana the environment regenerates per region per sec
		corruptionRampPerSecond = 0.08, -- how fast corruption intensity increases while overdraw persists
	}

	M.hotspots = M.hotspots or {}
	M.regions = M.regions or {}
	M._saveDir = "arcana"

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
		ent:Activate()
		ent:AddEffects(EF_ITEM_BLINK)
		ent:DropToFloor()

		timer.Simple(0.5, function()
			ent:RemoveEffects(EF_ITEM_BLINK)
			ent:DropToFloor()
		end)

		-- Start small
		if ent.SetCrystalScale then
			ent:SetCrystalScale(M.Config.crystalMinScale)
		else
			ent:SetModelScale(M.Config.crystalMinScale, 0)
		end

		return ent
	end

	function M:ReportMagicUse(ply, pos, spellId, context)
		if not isvector(pos) then return end
		local cfg = self.Config
		local now = CurTime()
		-- Merge into an existing hotspot or create new
		local h = findNearestHotspot(pos, cfg.hotspotJoinRadius)
		if not h then
			h = {pos = pos, value = 0, touched = now}
			table.insert(self.hotspots, h)
		end

		-- Increase intensity and timestamp
		h.value = (h.value or 0) + cfg.crystalGrowthPerCast
		h.touched = now

		-- First, try to grow an existing crystal nearby
		local crystal = findCrystalNear(h.pos, cfg.crystalSearchRadius)
		if IsValid(crystal) and crystal.AddCrystalGrowth then
			crystal:AddCrystalGrowth(cfg.crystalGrowthPerCast)
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
		ent:Activate()
		ent:SetRadius(M.Config.regionRadius)
		ent:SetIntensity(0)
		M.regions[key] = M.regions[key] or {center = center}
		M.regions[key].corruptEnt = ent
		return ent
	end

	-- Main environment absorption and corruption loop
	timer.Create("Arcana_ManaEnvironment_Think", 1.0, 0, function()
		local cfg = M.Config
		local crystals = ents.FindByClass("arcana_mana_crystal")
		if #crystals < 1 then return end
		-- Group crystals by region key and compute draw
		local perRegion = {}
		for _, c in ipairs(crystals) do
			if IsValid(c) and not c:IsFull() then
				local k = regionKey(c:GetPos(), cfg.regionRadius)
				local bucket = perRegion[k]
				if not bucket then
					bucket = {center = c:GetPos(), crystals = {}, totalDesired = 0}
					perRegion[k] = bucket
				else
					-- keep center stable by averaging lightly
					bucket.center = (bucket.center * 0.9) + (c:GetPos() * 0.1)
				end
				table.insert(bucket.crystals, c)
				bucket.totalDesired = bucket.totalDesired + math.max(0, c:GetAbsorbRate())
			end
		end
		-- For each region, allocate environment regen proportionally, fill crystals, and handle corruption
		for key, bucket in pairs(perRegion) do
			local regen = cfg.regionRegenPerSecond
			local desired = bucket.totalDesired
			local overdrawing = desired > regen + 0.001
			local supply = math.min(desired, regen)
			-- Proportional share per crystal
			for _, c in ipairs(bucket.crystals) do
				local need = c:IsFull() and 0 or c:GetAbsorbRate()
				if need > 0 and supply > 0 and desired > 0 then
					local share = supply * (need / desired)
					c:AddStoredMana(share)
				end
			end
			-- Corruption logic: if overdrawing, ramp up intensity over time; otherwise stay as-is
			local corruptEnt = ensureCorruptedArea(key, bucket.center)
			if IsValid(corruptEnt) then
				local cur = corruptEnt:GetIntensity() or 0
				if overdrawing then
					corruptEnt:SetIntensity(math.Clamp(cur + cfg.corruptionRampPerSecond, 0, 2))
				end
			end
		end
	end)

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
			if IsValid(c) then
				state.crystals[#state.crystals + 1] = {
					pos = encodeVector(c:GetPos()),
					scale = tonumber(c.GetCrystalScale and c:GetCrystalScale() or 1) or 1,
					stored = tonumber(c.GetStoredMana and c:GetStoredMana() or 0) or 0,
				}
			end
		end
		-- Hotspots: pos, value
		for i = 1, #self.hotspots do
			local h = self.hotspots[i]
			state.hotspots[#state.hotspots + 1] = {pos = encodeVector(h.pos), value = tonumber(h.value) or 0}
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
			local stored = math.max(0, tonumber(entry.stored) or 0)
			if ent.SetCrystalScale then ent:SetCrystalScale(scale) end
			if ent.SetStoredMana then ent:SetStoredMana(stored) end
		end
	end

	local function spawnCorruptionRestored(entry)
		local center = decodeVector(entry.center or {})
		local e = ents.Create("arcana_corrupted_area")
		if not IsValid(e) then return end
		e:SetPos(center)
		e:Spawn()
		e:Activate()
		e:SetRadius(M.Config.regionRadius)
		e:SetIntensity(math.Clamp(tonumber(entry.intensity) or 0, 0, 2))
		local key = regionKey(center, M.Config.regionRadius)
		M.regions[key] = M.regions[key] or {center = center}
		M.regions[key].corruptEnt = e
	end

	function M:LoadState()
		local savePath = self:GetSaveFile()
		if not file.Exists(savePath, "DATA") then return false end
		local raw = file.Read(savePath, "DATA") or "{}"
		local ok, data = pcall(util.JSONToTable, raw)
		if not ok or not istable(data) then return false end
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
			self.hotspots[#self.hotspots + 1] = {pos = pos, value = value, touched = CurTime()}
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
		if not Arcane or not Arcane.ManaCrystals then return end
		Arcane.ManaCrystals:LoadState()
	end)

	timer.Create("Arcana_ManaEnvironment_Autosave", 60, 0, function()
		if not Arcane or not Arcane.ManaCrystals then return end
		Arcane.ManaCrystals:SaveState()
	end)
end

return Arcane


