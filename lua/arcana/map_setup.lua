-- Arcana Map Setup — server-environment-specific entity spawning.
-- Depends on external globals provided by specific server/map addons:
--   _G.landmark  (landmark addon) — world position lookups by name
--   _G.aowl      (aowl admin addon) — GotoLocations alias registration
-- These are guarded at call time; missing globals cause silent no-ops.

if not SERVER then return end

local function SpawnAltar()
	if not _G.landmark then return end

	local pos = _G.landmark.get("slight")
	if not pos then return end

	local ent = ents.Create("arcana_altar")
	if not IsValid(ent) then return end

	ent:SetPos(pos + Vector(0, 0, 100))
	ent:Spawn()
	ent:Activate()
	ent.ms_notouch = true
	ent.PositionOverride = pos + Vector(0, 0, 100)

	ent:SetNWBool("ArcanaCoreSpawned", true)

	local phys = ent:GetPhysicsObject()
	if IsValid(phys) then
		phys:EnableMotion(false)
	end

	return ent
end

local LOBBY3_OFFSET = Vector(-522, 285, 14)
local function SpawnPortalToAltar(altar)
	if not IsValid(altar) then return end
	if not _G.landmark then return end

	local pos = _G.landmark.get("lobby_3")
	if not pos then return end

	local ent = ents.Create("arcana_portal")
	if not IsValid(ent) then return end

	ent:SetPos(pos + LOBBY3_OFFSET)
	ent:Spawn()
	ent:Activate()
	ent:SetDestination(altar:WorldSpaceCenter() + altar:GetForward() * 200)
	ent.ms_notouch = true

	local phys = ent:GetPhysicsObject()
	if IsValid(phys) then
		phys:EnableMotion(false)
	end
end

local function SpawnMapEntities()
	local altar = SpawnAltar()
	SpawnPortalToAltar(altar)

	if IsValid(altar) and _G.aowl and _G.aowl.GotoLocations then
		local aliases = {"altar", "magic", "arcane", "arcana"}
		for _, alias in ipairs(aliases) do
			_G.aowl.GotoLocations[alias] = altar:WorldSpaceCenter() + altar:GetForward() * 200
		end
	end
end

hook.Add("InitPostEntity", "Arcana_SpawnAltar", SpawnMapEntities)
hook.Add("PostCleanupMap", "Arcana_SpawnAltar", SpawnMapEntities)
