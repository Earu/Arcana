-- Arcana Weapon Utilities
-- Shared hold-type helpers used by enchantments and VFX

Arcana = Arcana or {}
Arcana.Common = Arcana.Common or {}

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

local function isNilOrEmptyString(str)
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
	if isNilOrEmptyString(ht) then
		-- for SetWeaponHoldType compatibility
		if istable(wep.ActivityTranslate) then
			local act = wep.ActivityTranslate[ACT_HL2MP_IDLE]
			if act then
				return ACT_INDEX[act]
			end
		end

		-- a lot of weapon set .HoldType or .Holdtype or some variant of that
		ht = tryFindHoldTypeByField(wep)
		if not isNilOrEmptyString(ht) then return ht end

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

local MELEE_HOLDTYPES = {
	["melee"] = true,
	["melee2"] = true,
	["knife"] = true,
	["fist"] = true,
}

-- Static classifications for default HL2/GMod weapons that are not SWEPs and
-- therefore cannot be inspected via source analysis.
local HL2_WEAPON_CLASSIFICATIONS = {
	-- Melee
	["weapon_crowbar"]    = "MELEE",
	["weapon_stunstick"]  = "MELEE",

	-- Hitscan
	["weapon_pistol"]     = "HITSCAN",
	["weapon_357"]        = "HITSCAN",
	["weapon_smg1"]       = "HITSCAN",
	["weapon_ar2"]        = "HITSCAN",
	["weapon_shotgun"]    = "HITSCAN",
	["weapon_annabelle"]  = "HITSCAN",
	["weapon_alyxgun"]    = "HITSCAN",

	-- Projectile
	["weapon_crossbow"]   = "PROJECTILE",
	["weapon_rpg"]        = "PROJECTILE",
	["weapon_frag"]       = "PROJECTILE",
	["weapon_slam"]       = "PROJECTILE",
	["weapon_bugbait"]    = "PROJECTILE",

	-- Unknown / special-purpose
	["weapon_physcannon"] = "UNKNOWN",
	["weapon_physgun"]    = "UNKNOWN",
	["weapon_medkit"]     = "UNKNOWN",
	["gmod_tool"]         = "UNKNOWN",
	["gmod_camera"]       = "UNKNOWN",
	["none"]              = "UNKNOWN",
}

-- Known projectile entity classes for native HL2 projectile weapons.
local HL2_WEAPON_PROJECTILE_CLASSES = {
	["weapon_crossbow"] = "crossbow_bolt",
	["weapon_rpg"]      = "rpg_missile",
	["weapon_frag"]     = "npc_grenade_frag",
	["weapon_slam"]     = "npc_satchel",
	["weapon_bugbait"]  = "grenade_bugbait",
}

local HL2_PROJECTILE_CLASSES = {
	["crossbow_bolt"]        = true,
	["rpg_missile"]          = true,
	["npc_grenade_frag"]     = true,
	["grenade_ar2"]          = true,
	["prop_combine_ball"]    = true,
	["grenade_bugbait"]      = true,
	["npc_satchel"]          = true,
	["apc_missile"]          = true,
	["grenade_spit"]         = true,
	["hunter_flechette"]     = true,
	["grenade_helicopter"]   = true,
	["weapon_striderbuster"] = true,
}

--- Returns true when the weapon uses a melee hold type.
function Arcana.Common.IsMeleeHoldType(wep)
	local ht = getHoldType(wep)
	return MELEE_HOLDTYPES[ht] or false
end

--- Returns true when the weapon uses a pistol hold type.
function Arcana.Common.IsPistolHoldType(wep)
	local ht = getHoldType(wep)
	return ht == "pistol" or ht == "revolver"
end

--- Returns true when the weapon uses a rifle / long-arm hold type.
function Arcana.Common.IsRifleHoldType(wep)
	local ht = getHoldType(wep)
	return ht == "ar2" or ht == "shotgun" or ht == "rpg" or ht == "crossbow" or ht == "smg" or ht == "physgun"
end

if SERVER then
	local ENTITY_META = FindMetaTable("Entity")
	local WEAPON_META = FindMetaTable("Weapon")
	local MAX_DEPTH = 10

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

	local function isProjectileClass(className)
		if scripted_ents.GetStored(className) then return true end
		return HL2_PROJECTILE_CLASSES[className] or false
	end

	-- Builds a name->value table of all upvalues for `func`.
	local function getUpvalues(func)
		local upvalues = {}
		local i = 1
		while true do
			local name, val = debug.getupvalue(func, i)
			if not name then break end
			upvalues[name] = val
			i = i + 1
		end
		return upvalues
	end

	-- Returns the scripted entity class string when `source` contains an ents.Create call
	-- that creates a scripted entity (truthy), true when the argument is a variable and
	-- the class cannot be resolved statically (conservatively assumes scripted), or false.
	-- `func`   – the function whose upvalues can be inspected to resolve bare variables
	-- `weapon` – the SWEP table used to resolve self.Field / SWEP.Field member access
	local function sourceHasScriptedCreate(source, func, weapon)
		-- Parenthesised call: ents.Create("foo") or ents.Create(var)
		for args in source:gmatch("ents%.Create%s*(%b())") do
			local literal = args:match("^%(%s*[\"']([^\"']+)[\"']%s*%)$")
			if literal then
				if isProjectileClass(literal) then return literal end
			else
				-- Try to resolve self.Field or SWEP.Field member access
				local field = args:match("^%(%s*[Ss][Ee][Ll][Ff]%.([%w_]+)%s*%)$") or args:match("^%(%s*SWEP%.([%w_]+)%s*%)$")
				if field and weapon then
					local v = weapon[field]
					if isstring(v) and isProjectileClass(v) then return v end
				end

				-- Try to resolve a bare local/upvalue variable
				local varName = args:match("^%(%s*([%w_]+)%s*%)$")
				if varName and func then
					local upvalues = getUpvalues(func)
					local v = upvalues[varName]
					if isstring(v) and isProjectileClass(v) then return v end
				end

				return true -- unresolvable variable; conservatively assume scripted
			end
		end

		-- Bare short-string call: ents.Create "foo" or ents.Create 'foo'
		for literal in source:gmatch("ents%.Create%s+[\"']([^\"']+)[\"']") do
			if isProjectileClass(literal) then return literal end
		end

		-- Bare long-string call: ents.Create [[foo]]
		for literal in source:gmatch("ents%.Create%s+%[%[([^%]]*)%]%]") do
			if isProjectileClass(literal) then return literal end
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

		local result = matchFn(source, func, weapon)
		if result then return result end

		-- Collect all self:Method() call sites within this function body
		-- Also covers bare-string and bare-table call syntax: self:Method "x", self:Method { }, self:Method [[x]]
		for methodName in source:gmatch("self%s*:%s*([%w_]+)%s*[%(\"'{%[]") do
			if not ENTITY_META[methodName] and not WEAPON_META[methodName] and not WEAPON_HOOKS[methodName] then
				local method = weapon[methodName]
				if isfunction(method) then
					result = checkForMatch(method, weapon, visited, depth + 1, matchFn)
					if result then return result end
				end
			end
		end

		return false
	end

	local function matchFireBullets(source) return source:find(":FireBullets%(") ~= nil end

	-- Entry point: classifies a weapon as "PROJECTILE" or "HITSCAN".
	-- FireBullets is checked first; finding it immediately means hitscan, which
	-- avoids misclassifying weapons that create a shell entity after shooting.
	-- Only if FireBullets is absent do we check for scripted ents.Create calls.
	-- Returns: type (string), projectileClass (string or nil)
	local function classifyRangedWeapon(weapon)
		local primaryAttack = weapon.PrimaryAttack
		if not isfunction(primaryAttack) then return "HITSCAN", nil end

		if checkForMatch(primaryAttack, weapon, {}, 1, matchFireBullets) then
			return "HITSCAN", nil
		end

		local projClass = checkForMatch(primaryAttack, weapon, {}, 1, sourceHasScriptedCreate)
		if projClass then
			return "PROJECTILE", isstring(projClass) and projClass or nil
		end

		local think = weapon.Think
		if isfunction(think) then
			projClass = checkForMatch(think, weapon, {}, 1, sourceHasScriptedCreate)
			if projClass then
				return "PROJECTILE", isstring(projClass) and projClass or nil
			end
		end

		return "HITSCAN", nil
	end

	local UNKNOWN_HOLDTYPES = {
		["normal"] = true,
		["passive"] = true,
	}

	util.AddNetworkString("Arcana_UpdateWeaponClassificationCache")

	local CACHE_FILE = "arcana/weapon_classification_cache.json"
	local weaponClassificationCache = {}
	if file.Exists(CACHE_FILE, "DATA") then
		local loaded = util.JSONToTable(file.Read(CACHE_FILE, "DATA")) or {}
		for className, v in pairs(loaded) do
			-- Discard entries from the old string-only format; they will be re-classified.
			if istable(v) then
				weaponClassificationCache[className] = v
			end
		end
	end

	function Arcana.Common.SendWeaponClassificationCache(ply)
		net.Start("Arcana_UpdateWeaponClassificationCache")
		net.WriteInt(table.Count(weaponClassificationCache), 32)
		for className, entry in pairs(weaponClassificationCache) do
			net.WriteString(className)
			net.WriteString(entry.type or "UNKNOWN")
			net.WriteString(entry.holdType or "")
			net.WriteString(entry.projectileClass or "")
		end

		if IsValid(ply) then
			net.Send(ply)
		else
			net.Broadcast()
		end
	end

	local function updateWeaponClassificationCache()
		if not file.Exists("arcana", "DATA") then
			file.CreateDir("arcana")
		end

		file.Write(CACHE_FILE, util.TableToJSON(weaponClassificationCache))

		Arcana.Common.SendWeaponClassificationCache()
	end

	local function classifyWeapon(wep)
		local className = wep:GetClass()
		local holdType = getHoldType(wep)

		local hl2Type = HL2_WEAPON_CLASSIFICATIONS[className]
		if hl2Type then
			local entry = { type = hl2Type, holdType = holdType }
			if hl2Type == "PROJECTILE" then
				entry.projectileClass = HL2_WEAPON_PROJECTILE_CLASSES[className]
			end
			return entry
		end

		if MELEE_HOLDTYPES[holdType] then
			return { type = "MELEE", holdType = holdType }
		elseif UNKNOWN_HOLDTYPES[holdType] then
			return { type = "UNKNOWN", holdType = holdType }
		else
			local wepType, projClass = classifyRangedWeapon(wep)
			if wepType == "HITSCAN" and (holdType == "grenade" or className:find("grenade") or className:find("nade")) then
				wepType = "PROJECTILE"
			end

			return { type = wepType, holdType = holdType, projectileClass = projClass }
		end
	end

	function Arcana.Common.GetWeaponClassification(wep)
		if not IsValid(wep) then return "UNKNOWN" end

		local className = wep:GetClass()
		local cached = weaponClassificationCache[className]
		if cached then return cached.type end

		local classification = classifyWeapon(wep)

		weaponClassificationCache[className] = classification
		updateWeaponClassificationCache()
		return classification.type
	end

	function Arcana.Common.GetWeaponClassificationData(className)
		if not isstring(className) then return nil end
		return weaponClassificationCache[className]
	end

	-- Classify weapons when theyre equipped
	hook.Add("WeaponEquip", "Arcana_UpdateWeaponClassificationCache", function(wep)
		if not IsValid(wep) then return end
		local className = wep:GetClass()
		if weaponClassificationCache[className] then return end

		timer.Simple(0.1, function()
			if not IsValid(wep) then return end

			weaponClassificationCache[className] = classifyWeapon(wep)
			updateWeaponClassificationCache()
		end)
	end)
end

if CLIENT then
	local weaponClassificationCache = {}
	net.Receive("Arcana_UpdateWeaponClassificationCache", function()
		local count = net.ReadInt(32)
		for i = 1, count do
			local className       = net.ReadString()
			local wepType         = net.ReadString()
			local holdType        = net.ReadString()
			local projectileClass = net.ReadString()
			weaponClassificationCache[className] = {
				type           = wepType,
				holdType       = holdType ~= "" and holdType or nil,
				projectileClass = projectileClass ~= "" and projectileClass or nil,
			}
		end
	end)

	function Arcana.Common.GetWeaponClassification(wep)
		local className = wep:GetClass()
		if not IsValid(wep) or not isstring(className) then return "UNKNOWN" end
		local cached = weaponClassificationCache[className]
		if cached then return cached.type end
		return "UNKNOWN"
	end

	function Arcana.Common.GetWeaponClassificationData(className)
		if not isstring(className) then return nil end
		return weaponClassificationCache[className]
	end
end