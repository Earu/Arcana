local ENTITY_META = FindMetaTable("Entity")
local WEAPON_META  = FindMetaTable("Weapon")
local MAX_DEPTH    = 10

-- All overridable WEAPON hook names from https://wiki.facepunch.com/gmod/WEAPON_Hooks.
-- These live on the SWEP table itself rather than in the metatable, so we must
-- maintain a separate set to avoid recursing into them during source analysis.
local WEAPON_HOOKS = {
	AcceptInput          = true,
	AdjustMouseSensitivity = true,
	Ammo1                = true,
	Ammo2                = true,
	CalcView             = true,
	CalcViewModelView    = true,
	CanBePickedUpByNPCs  = true,
	CanPrimaryAttack     = true,
	CanSecondaryAttack   = true,
	CustomAmmoDisplay    = true,
	Deploy               = true,
	DoDrawCrosshair      = true,
	DoImpactEffect       = true,
	DrawHUD              = true,
	DrawHUDBackground    = true,
	DrawWeaponSelection  = true,
	DrawWorldModel       = true,
	DrawWorldModelTranslucent = true,
	Equip                = true,
	EquipAmmo            = true,
	FireAnimationEvent   = true,
	FreezeMovement       = true,
	GetCapabilities      = true,
	GetNPCBulletSpread   = true,
	GetNPCBurstSettings  = true,
	GetNPCRestTimes      = true,
	GetTracerOrigin      = true,
	GetViewModelPosition = true,
	Holster              = true,
	HUDShouldDraw        = true,
	Initialize           = true,
	KeyValue             = true,
	NPCShoot_Primary     = true,
	NPCShoot_Secondary   = true,
	OnDrop               = true,
	OnReloaded           = true,
	OnRemove             = true,
	OnRestore            = true,
	OwnerChanged         = true,
	PostDrawViewModel    = true,
	PreDrawViewModel     = true,
	PrimaryAttack        = true,
	PrintWeaponInfo      = true,
	Reload               = true,
	RenderScreen         = true,
	SecondaryAttack      = true,
	SetupDataTables      = true,
	SetWeaponHoldType    = true,
	ShootBullet          = true,
	ShootEffects         = true,
	ShouldDrawViewModel  = true,
	ShouldDropOnDie      = true,
	TakePrimaryAmmo      = true,
	TakeSecondaryAmmo    = true,
	Think                = true,
	Tick                 = true,
	TranslateActivity    = true,
	TranslateFOV         = true,
	ViewModelDrawn       = true,
}

local function getFunctionSource(func)
	local info = debug.getinfo(func, "Sl")
	if not info or not info.source or info.what == "C" then return nil end

	-- info.source starts with "@" for file-based functions
	if info.source:sub(1, 1) ~= "@" then return nil end

	local path = info.source:sub(2)  -- strip leading "@"
	local content = file.Read(path, "GAME")
	if not content then return nil end

	local lineStart = info.linedefined
	local lineEnd   = info.lastlinedefined
	if not lineStart or lineStart < 1 then return nil end

	local lines = {}
	local current = 0
	for line in (content .. "\n"):gmatch("([^\n]*)\n") do
		current = current + 1
		if current >= lineStart then
			lines[#lines + 1] = line
		end
		if lineEnd and lineEnd > 0 and current >= lineEnd then break end
	end

	return table.concat(lines, "\n"), info.source:sub(2) .. ":" .. lineStart
end

-- Returns true if `source` contains an ents.Create call that creates a scripted entity.
-- String literal arguments are verified with scripted_ents.GetStored.
-- Variable arguments cannot be resolved statically, so they are assumed scripted.
local function sourceHasScriptedCreate(source)
	-- Parenthesised call: ents.Create("foo") or ents.Create(var)
	for args in source:gmatch("ents%.Create%s*(%b())") do
		local literal = args:match("^%(%s*[\"']([^\"']+)[\"']%s*%)$")
		if literal then
			if scripted_ents.GetStored(literal) then return true end
		else
			return true -- variable argument; conservatively assume scripted
		end
	end
	-- Bare short-string call: ents.Create "foo" or ents.Create 'foo'
	for literal in source:gmatch("ents%.Create%s+[\"']([^\"']+)[\"']") do
		if scripted_ents.GetStored(literal) then return true end
	end
	-- Bare long-string call: ents.Create [[foo]]
	for literal in source:gmatch("ents%.Create%s+%[%[([^%]]*)%]%]") do
		if scripted_ents.GetStored(literal) then return true end
	end
	return false
end

-- Recursively inspects `func`'s source using a caller-supplied match function.
-- `weapon`  – the SWEP table being analysed (used to resolve self:Method calls)
-- `visited` – set of "file:line" keys already examined (cycle guard)
-- `depth`   – current recursion depth
-- `matchFn` – function(source: string): bool called on each function body
local function checkForMatch(func, weapon, visited, depth, matchFn)
	if depth > MAX_DEPTH then return false end

	local source, key = getFunctionSource(func)
	if not source then
		return false
	end

	-- Cycle guard: skip if we've already visited this exact function body
	if visited[key] then return false end
	visited[key] = true

	if matchFn(source) then
		return true
	end

	-- Collect all self:Method() call sites within this function body
	-- Also covers bare-string and bare-table call syntax: self:Method "x", self:Method { }, self:Method [[x]]
	for methodName in source:gmatch("self%s*:%s*([%w_]+)%s*[%(\"'{%[]") do
		if not ENTITY_META[methodName] and not WEAPON_META[methodName] and not WEAPON_HOOKS[methodName] then
			local method = weapon[methodName]
			if isfunction(method) and checkForMatch(method, weapon, visited, depth + 1, matchFn) then
				return true
			end
		end
	end

	return false
end

local function matchFireBullets(source) return source:find(":FireBullets%(") ~= nil end

-- Returns true if `source` contains at least one self:Method() call where Method
-- is NOT part of the Entity or Weapon metatables (i.e. a custom weapon method).
local function sourceHasCustomCalls(source)
	-- Also covers bare-string and bare-table call syntax: self:Method "x", self:Method { }, self:Method [[x]]
	for methodName in source:gmatch("self%s*:%s*([%w_]+)%s*[%(\"'{%[]") do
		if not ENTITY_META[methodName] and not WEAPON_META[methodName] and not WEAPON_HOOKS[methodName] then
			return true
		end
	end
	return false
end

local ACT_INDEX = {
	[ACT_HL2MP_IDLE_PISTOL] = "pistol",
	[ACT_HL2MP_IDLE_SMG1] = "smg",
	[ACT_HL2MP_IDLE_GRENADE] = "grenade",
	[ACT_HL2MP_IDLE_AR2] = "ar2",
	[ACT_HL2MP_IDLE_SHOTGUN] = "shotgun",
	[ACT_HL2MP_IDLE_RPG] = "rpg",
	[ACT_HL2MP_IDLE_PHYSGUN] = "physgun",
	[ACT_HL2MP_IDLE_CROSSBOW] = "crossbow",
	[ACT_HL2MP_IDLE_MELEE] = "melee",
	[ACT_HL2MP_IDLE_SLAM] = "slam",
	[ACT_HL2MP_IDLE] = "normal",
	[ACT_HL2MP_IDLE_FIST] = "fist",
	[ACT_HL2MP_IDLE_MELEE2] = "melee2",
	[ACT_HL2MP_IDLE_PASSIVE] = "passive",
	[ACT_HL2MP_IDLE_KNIFE] = "knife",
	[ACT_HL2MP_IDLE_DUEL] = "duel",
	[ACT_HL2MP_IDLE_CAMERA] = "camera",
	[ACT_HL2MP_IDLE_MAGIC] = "magic",
	[ACT_HL2MP_IDLE_REVOLVER] = "revolver"
}

local function isNullOrEmptyString(str)
	return str == "" or str == nil or not isstring(str)
end

local function tryFindHoldTypeByField(wep)
	local tbl = wep:GetTable()
	for k, v in pairs(tbl) do
		if isstring(k) and string.lower(k) == "holdtype" and isstring(v) then
			return string.lower(v)
		end
	end
end

local function getHoldType(wep)
	if not IsValid(wep) then return "" end

	local ht = (isfunction(wep.GetHoldType) and wep:GetHoldType())
	if isNullOrEmptyString(ht) then
		-- for SetWeaponHoldType compatibility
		if istable(wep.ActivityTranslate) then
			local act = wep.ActivityTranslate[ACT_HL2MP_IDLE]
			if act then
				return ACT_INDEX[act]
			end
		end

		-- a lot of weapon set .HoldType or .Holdtype or some variant of that
		ht = tryFindHoldTypeByField(wep)
		if not isNullOrEmptyString(ht) then return ht end

		-- if we have a weapon thats using a melee base its safe to assume the holdtype is going to be melee
		if isstring(wep.Base) and wep.Base:find("melee") then
			return "melee"
		end

		-- this makes me very sad
		return ""
	else
		return string.lower(ht)
	end
end
_G.GetHoldType = getHoldType

-- Entry point: classifies a weapon as "PROJECTILE" or "HITSCAN".
-- FireBullets is checked first; finding it immediately means hitscan, which
-- avoids misclassifying weapons that create a shell entity after shooting.
-- Only if FireBullets is absent do we check for scripted ents.Create calls.
local function classifyWeapon(weapon)
	local primaryAttack = weapon.PrimaryAttack
	if not isfunction(primaryAttack) then return "HITSCAN" end

	if checkForMatch(primaryAttack, weapon, {}, 1, matchFireBullets) then
		return "HITSCAN"
	end

	if checkForMatch(primaryAttack, weapon, {}, 1, sourceHasScriptedCreate) then
		return "PROJECTILE"
	end

	-- If PrimaryAttack makes no custom method calls it is a thin stub (e.g. just
	-- sets a timer or calls SetNextPrimaryFire). Some weapons defer projectile
	-- creation entirely to Think, so scan that function for scripted entity creation.
	local primarySource = getFunctionSource(primaryAttack)
	if primarySource and not sourceHasCustomCalls(primarySource) then
		local think = weapon.Think
		if isfunction(think) and checkForMatch(think, weapon, {}, 1, sourceHasScriptedCreate) then
			return "PROJECTILE"
		end
	end

	return "HITSCAN"
end

local GROUND_TRUTH = util.JSONToTable(file.Read("weapon_dataset_labeled.json", "DATA"))

local function cantBeSpawned(weaponClass, ply)
	local swep = list.Get("Weapon")[weaponClass]
	if not swep.Spawnable then return true end

	local isAdmin = ply:IsAdmin() or game.SinglePlayer()
	if (not swep.Spawnable and not isAdmin) or (swep.AdminOnly and not isAdmin) then return true end
	if not gamemode.Call("PlayerGiveSWEP", ply, weaponClass, swep) then return true end

	return false
end

local function spawnAndInit(className, ply)
	local inst = ents.Create(className)
	if not IsValid(inst) then return nil end
	inst:SetPos(Vector(0, 0, 0))
	inst:Spawn()
	inst:Activate()
	inst:SetCollisionGroup(COLLISION_GROUP_DEBRIS)
	local phys = inst:GetPhysicsObject()
	if IsValid(phys) then
		phys:EnableMotion(false)
		phys:EnableCollisions(false)
		phys:EnableGravity(false)
		phys:EnableDrag(false)
	end
	return inst
end

-- Build the candidate list up-front, then process one per tick so each
-- weapon instance has a full frame to initialize before holdtype / classify runs.
local ply = Entity(1)
local queue = {}
for _, weapon in ipairs(weapons.GetList()) do
	local truth = GROUND_TRUTH[weapon.ClassName]
	if not truth then continue end
	if cantBeSpawned(weapon.ClassName, ply) then continue end
	table.insert(queue, { className = weapon.ClassName, truth = truth })
end

local HT_IRRELEVANT_LOOKUP = {
	["melee"] = true,
	["melee2"] = true,
	["knife"] = true,
	["fist"] = true,
	["normal"] = true,
	["passive"] = true,
}

local accuracy = 0
local total    = 0
local qIdx     = 1

local function processNext()
	if qIdx > #queue then
		print("ACCURACY: " .. accuracy .. "/" .. total .. " (" .. (accuracy / total * 100) .. "%)")
		return
	end

	local entry     = queue[qIdx]
	local className = entry.className
	local truth     = entry.truth
	qIdx = qIdx + 1

	local inst = spawnAndInit(className, ply)
	if not IsValid(inst) then
		processNext()
		return
	end

	-- Wait one tick so the weapon's Initialize / SetupDataTables / etc. have run,
	-- making holdtype and other instance properties reliable.
	timer.Simple(0, function()
		if not IsValid(inst) then
			processNext()
			return
		end

		local ht = getHoldType(inst)
		local result

		if HT_IRRELEVANT_LOOKUP[ht] then
			result = "IRRELEVANT"
		elseif ht == "grenade" or className:find("grenade") or className:find("nade") then
			result = "PROJECTILE"
		else
			result = classifyWeapon(inst)
		end

		-- A BROKEN weapon that we classify as IRRELEVANT is an acceptable outcome.
		if (result ~= truth) and not (truth == "BROKEN" and result == "IRRELEVANT") then
			print(className, truth, result)
		else
			accuracy = accuracy + 1
		end

		total = total + 1
		SafeRemoveEntity(inst)
		processNext()
	end)
end

processNext()

function IsProjectileGun(weapon)
	local ht = getHoldType(weapon)
	if ht == "grenade" or weapon.ClassName:find("grenade") or weapon.ClassName:find("nade") then return true end

	return classifyWeapon(weapon) == "PROJECTILE"
end

--[[local output = {}
for _, weapon in ipairs(weapons.GetList()) do
	if Arcana.Common.IsMeleeHoldType(weapon) then continue end -- we dont care about melee weapons

	local ht = getHoldType(weapon)
	if ht == "normal" then continue end -- mostly irrelevant for this test

	local result
	if ht == "grenade" or weapon.ClassName:find("grenade") or weapon.ClassName:find("nade") then -- grenade holdtypes are almost always PROJECTILE
		result = "PROJECTILE"
	else
		result = classifyWeapon(weapon)
	end

	output[weapon.ClassName] = result
end

file.Write("weapon_ground_truth.json", util.TableToJSON(output))]]

--[[
local addons = {}
for _, addon in ipairs(engine.GetAddons()) do
	if addon.mounted and addon.wsid and addon.wsid ~= "0" then
		table.insert(addons, {
			wsid  = addon.wsid,
			title = addon.title,
		})
	end
end

table.sort(addons, function(a, b) return a.title < b.title end)

file.Write("weapon_dataset_addons.json", util.TableToJSON(addons, true))
MsgN("[Dataset] Exported " .. #addons .. " mounted addon IDs to data/weapon_dataset_addons.json")
]]