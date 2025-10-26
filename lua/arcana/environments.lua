AddCSLuaFile()

local Arcane = _G.Arcane or {}
_G.Arcane = Arcane

Arcane.Environments = Arcane.Environments or {}
local Envs = Arcane.Environments

Envs.Registered = Envs.Registered or {}
Envs.Active = Envs.Active or nil -- { id=..., origin=Vector, owner=Player, started=CurTime(), expires=CurTime()+lifetime, spawned={entities...}, timers={...} }
Envs.LockUntilById = Envs.LockUntilById or {} -- cooldown per environment id

-- Networking for environment state
if SERVER then
	util.AddNetworkString("Arcana_EnvStart")
	util.AddNetworkString("Arcana_EnvStop")

	local function sendEnvStart(ctx, rcpt)
		net.Start("Arcana_EnvStart")
		net.WriteString(tostring(ctx.id or ""))
		net.WriteVector(ctx.origin or Vector(0, 0, 0))
		net.WriteFloat(tonumber(ctx.started or CurTime()) or CurTime())
		net.WriteFloat(tonumber(ctx.expires or (CurTime() + 1)) or (CurTime() + 1))
		net.WriteFloat(tonumber(ctx.effective_radius or 0) or 0)
		if rcpt then
			net.Send(rcpt)
		else
			net.Broadcast()
		end
	end

	hook.Remove("PlayerInitialSpawn", "Arcana_EnvSyncOnJoin")
	hook.Add("PlayerInitialSpawn", "Arcana_EnvSyncOnJoin", function(ply)
		local ctx = Envs.Active
		if not ctx then return end
		sendEnvStart(ctx, ply)
	end)
end

-- Utility: safe remove entity list
local function safeRemoveAll(list)
	if not istable(list) then return end
	for _, ent in ipairs(list) do
		if IsValid(ent) then SafeRemoveEntity(ent) end
	end
end

-- Utility: clear timers by name list
local function clearTimers(timerNames)
	if not istable(timerNames) then return end
	for _, t in ipairs(timerNames) do
		if isstring(t) then timer.Remove(t) end
	end
end

-- Public API: Register an environment
-- def = {
--   id = "magical_forest",
--   name = "Magical Forest",
--   lifetime = 3600, -- seconds
--   spawn_base = function(ctx) ... return {entities={}, timers={}} end,
--   poi_min = 1,
--   poi_max = 3,
--   pois = {
--     { id="mushroom_hotspot", min=0, max=2, can_spawn=function(ctx) return true end, spawn=function(ctx) ... end },
--     ...
--   }
-- }
function Envs:RegisterEnvironment(def)
	if not istable(def) then return false end
	local id = tostring(def.id or "")
	if id == "" then return false end
	def.name = def.name or id
	def.lifetime = tonumber(def.lifetime or 3600) or 3600
	def.lock_duration = tonumber(def.lock_duration or 0) or 0 -- seconds to prevent immediate re-cast/start
	def.min_radius = tonumber(def.min_radius or 0) or 0 -- minimum effective radius required to allow spawn
	def.max_radius = tonumber(def.max_radius or 0) or 32768 -- maximum effective radius allowed to spawn
	def.poi_min = math.max(0, tonumber(def.poi_min or 0) or 0)
	def.poi_max = math.max(def.poi_min, tonumber(def.poi_max or def.poi_min) or def.poi_min)
	def.pois = istable(def.pois) and def.pois or {}
	self.Registered[id] = def
	return true
end

function Envs:IsActive()
	return self.Active ~= nil
end

function Envs:GetActive()
	return self.Active
end

-- Stop and cleanup the active environment, if any
function Envs:Stop(reason)
	local env = self.Active
	if not env then return false end
	self.Active = nil

	-- Cleanup timers/entities
	clearTimers(env.timers)
	safeRemoveAll(env.spawned)

	-- Optional: notify owner
	if SERVER and IsValid(env.owner) and env.owner.ChatPrint then
		env.owner:ChatPrint("The environment fades" .. (reason and (": " .. tostring(reason)) or "."))
	end

	-- Broadcast stop to clients so they can clear client-side state/effects
	if SERVER then
		net.Start("Arcana_EnvStop")
		net.WriteString(tostring(env.id or ""))
		net.WriteString(reason or "unknown reason")
		net.Broadcast()
	end

	return true
end

-- Selection honoring per-item min/max counts; returns up to k picks (repeats allowed up to it.max).
-- Strategy: satisfy each item's min first (round-robin), then fill randomly up to remaining capacity.
local function choosePointsOfInterest(poiDefs, maxCount)
	local chosen = {}
	local allocation = {}
	for _, poiDef in ipairs(poiDefs) do
		allocation[poiDef.id] = 0
		if (poiDef.min or 0) > 0 then
			for i = 1, poiDef.min do
				table.insert(chosen, poiDef)
				allocation[poiDef.id] = allocation[poiDef.id] + 1
			end
		end
	end

	local remaining = maxCount - #chosen
	if remaining <= 0 then return chosen end

	while remaining > 0 do
		local poiDef = poiDefs[math.random(1, #poiDefs)]
		if allocation[poiDef.id] < (poiDef.max or 0) then
			table.insert(chosen, poiDef)
			allocation[poiDef.id] = allocation[poiDef.id] + 1
			remaining = remaining - 1
		end
	end

    return chosen
end

-- Compute effective horizontal radius available around origin by sampling along a vertical line
-- and tracing outwards in 4 cardinal directions every 50 units.
function Envs:ComputeEffectiveRadius(origin)
	if not origin or not origin.IsZero then return 0 end
	local upStart = origin + Vector(0, 0, 8)
	local upTrace = util.TraceLine({
		start = upStart,
		endpos = upStart + Vector(0, 0, 40000),
		mask = MASK_SOLID_BRUSHONLY
	})

	local topZ = upTrace.Hit and upTrace.HitPos.z or (origin.z + 600)
	local distances = {}
	local dirs = {Vector(1, 0, 0), Vector(-1, 0, 0), Vector(0, 1, 0), Vector(0, -1, 0)}
	local step = 50
	for z = origin.z, topZ, step do
		local sample = Vector(origin.x, origin.y, z)
		for _, d in ipairs(dirs) do
			local tr = util.TraceLine({
				start = sample,
				endpos = sample + d * 40000,
				mask = MASK_SOLID_BRUSHONLY
			})

			local hitPos = tr.Hit and tr.HitPos or (sample + d * 40000)
			distances[#distances + 1] = hitPos:Distance(sample)
		end
	end

	if #distances < 1 then return 0 end

	table.sort(distances)
	local mid = math.floor((#distances + 1) / 2)
	if (#distances % 2) == 1 then
		return distances[mid]
	else
		return (distances[mid] + distances[mid + 1]) * 0.5
	end
end

-- Public API: Start an environment by id at origin
-- Returns true on success, false and reason on failure
-- Start can be invoked on both realms. On the server it performs spawning and networking;
-- on the client it only mirrors state for client-side effects.
function Envs:Start(id, origin, owner, opts)
    if SERVER then
        if self:IsActive() then return false, "An environment is already active" end

		local def = self.Registered[id]
		if not def then return false, "Unknown environment" end

		local lockUntil = tonumber(self.LockUntilById[id] or 0) or 0
		if CurTime() < lockUntil then
			local remaining = math.max(0, math.floor(lockUntil - CurTime()))
			return false, (def.name or id) .. " is on cooldown for " .. tostring(remaining) .. "s"
		end

		origin = origin or Vector(0, 0, 0)

		-- Compute effective radius once and pass to environment context
		local eff_radius = self:ComputeEffectiveRadius(origin)
		if eff_radius > def.max_radius then
			eff_radius = def.max_radius
		end

		-- Space validation: ensure sufficient effective radius
		if (def.min_radius or 0) > 0 then
			if eff_radius < def.min_radius then
				return false, "Not enough space (radius " .. tostring(math.floor(eff_radius)) .. " < required " .. tostring(def.min_radius) .. ")"
			end
		end

		local ctx = {
			id = id,
			name = def.name,
			origin = origin,
			owner = IsValid(owner) and owner or game.GetWorld(),
			started = CurTime(),
			expires = CurTime() + def.lifetime,
			effective_radius = eff_radius,
			spawned = {},
			timers = {},
			-- convenience
			def = def,
		}

			self.Active = ctx

			-- Notify clients of environment start
			net.Start("Arcana_EnvStart")
			net.WriteString(tostring(ctx.id or ""))
			net.WriteVector(ctx.origin or Vector(0, 0, 0))
			net.WriteFloat(tonumber(ctx.started or CurTime()) or CurTime())
			net.WriteFloat(tonumber(ctx.expires or (CurTime() + 1)) or (CurTime() + 1))
			net.WriteFloat(tonumber(ctx.effective_radius or 0) or 0)
			net.Broadcast()

		-- Apply cooldown lock immediately upon successful start (mirrors prior ritual behavior)
		if (def.lock_duration or 0) > 0 then
			self.LockUntilById[id] = CurTime() + def.lock_duration
		end

		-- Base spawn
		if isfunction(def.spawn_base) then
			local ok, res = pcall(def.spawn_base, ctx)
			if not ok then
				self:Stop("base spawn failed")
				return false, "Base spawn failed"
			end
			if istable(res) then
				if istable(res.entities) then for _, e in ipairs(res.entities) do if IsValid(e) then table.insert(ctx.spawned, e) end end end
				if istable(res.timers) then for _, t in ipairs(res.timers) do table.insert(ctx.timers, t) end end
			end
		end

		-- POIs selection and spawn
		local candidates = {}
		for _, poi in ipairs(def.pois) do
			local can = true
			if isfunction(poi.can_spawn) then
				local ok, ret = pcall(poi.can_spawn, ctx)
				can = ok and ret ~= false
			end
			if can then table.insert(candidates, poi) end
		end

        local need = math.ceil(def.poi_max * (eff_radius / def.max_radius))
        local picks = choosePointsOfInterest(candidates, need)
		for _, poi in ipairs(picks) do
			if isfunction(poi.spawn) then
				local ok, res = pcall(poi.spawn, ctx)
				if ok and istable(res) then
					if istable(res.entities) then for _, e in ipairs(res.entities) do if IsValid(e) then table.insert(ctx.spawned, e) end end end
					if istable(res.timers) then for _, t in ipairs(res.timers) do table.insert(ctx.timers, t) end end
				end
			end
		end

		-- Auto-expire
		local tname = "Arcana_EnvExpire_" .. tostring(id)
		ctx.timers[#ctx.timers + 1] = tname
		timer.Create(tname, math.max(1, def.lifetime), 1, function()
			if Envs.Active == ctx then Envs:Stop("time elapsed") end
		end)

		-- Map cleanup safety
		hook.Remove("PostCleanupMap", "Arcana_EnvReset")
		hook.Add("PostCleanupMap", "Arcana_EnvReset", function()
			if Envs:IsActive() then Envs:Stop("map cleanup") end
		end)

        return true
    else
        -- CLIENT: mirror state from server (opts may carry computed values)
        local started = (istable(opts) and tonumber(opts.started)) or CurTime()
        local expires = (istable(opts) and tonumber(opts.expires)) or (CurTime() + 1)
        local effr = (istable(opts) and tonumber(opts.effective_radius)) or self:ComputeEffectiveRadius(origin or Vector(0, 0, 0))

        local ctx = {
            id = id,
            name = self.Registered[id] and (self.Registered[id].name or id) or id,
            origin = origin or Vector(0, 0, 0),
            owner = IsValid(owner) and owner or LocalPlayer(),
            started = started,
            expires = expires,
            effective_radius = effr,
            spawned = {},
            timers = {},
            def = self.Registered[id],
        }

        self.Active = ctx
        return true
    end
end

if CLIENT then
    -- Receive environment start/stop and invoke the same Start/Stop API on client
    net.Receive("Arcana_EnvStart", function()
        local id = net.ReadString() or ""
        local origin = net.ReadVector() or Vector(0, 0, 0)
        local started = net.ReadFloat() or CurTime()
        local expires = net.ReadFloat() or (CurTime() + 1)
        local effr = net.ReadFloat() or 0

        Envs:Start(id, origin, LocalPlayer(), {
            started = started,
            expires = expires,
            effective_radius = effr,
        })
    end)

    net.Receive("Arcana_EnvStop", function()
        local _ = net.ReadString() or ""
		local reason = net.ReadString() or "unknown reason"
        if Envs.Active then Envs:Stop(reason) end
    end)
end

return Envs