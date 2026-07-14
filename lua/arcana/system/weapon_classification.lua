-- Arcana Weapon Utilities
-- Shared hold-type helpers used by enchantments and VFX

Arcana = Arcana or {}
Arcana.WeaponClassification = Arcana.WeaponClassification or {}

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
			local act = wep.ActivityTranslate[ACT_MP_STAND_IDLE]
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

	-- Variants of hands
	["hands"]             = "UNKNOWN",
	["none"]              = "UNKNOWN",
	["passive"]           = "UNKNOWN",

	-- The grimoire shouldnt be enchanted or categorised as HITSCAN
	["grimoire"]          = "UNKNOWN", 
}

-- Known projectile entity classes for native HL2 projectile weapons.
local HL2_WEAPON_PROJECTILE_CLASSES = {
	["weapon_crossbow"] = "crossbow_bolt",
	["weapon_rpg"]      = "rpg_missile",
	["weapon_frag"]     = "npc_grenade_frag",
	["weapon_slam"]     = "npc_satchel",
	["weapon_bugbait"]  = "npc_grenade_bugbait",
}

local HL2_PROJECTILE_CLASSES = {
	["crossbow_bolt"]        = true,
	["rpg_missile"]          = true,
	["npc_grenade_frag"]     = true,
	["grenade_ar2"]          = true,
	["prop_combine_ball"]    = true,
	["npc_grenade_bugbait"]  = true,
	["npc_satchel"]          = true,
	["apc_missile"]          = true,
	["grenade_spit"]         = true,
	["hunter_flechette"]     = true,
	["grenade_helicopter"]   = true,
	["weapon_striderbuster"] = true,

	-- weird things that can be projectiles
	["prop_physics"] = true,
}

--- Returns true when the weapon uses a melee hold type.
function Arcana.WeaponClassification.IsMeleeHoldType(wep)
	local ht = getHoldType(wep)
	return MELEE_HOLDTYPES[ht] or false
end

--- Returns true when the weapon uses a pistol hold type.
function Arcana.WeaponClassification.IsPistolHoldType(wep)
	local ht = getHoldType(wep)
	return ht == "pistol" or ht == "revolver"
end

--- Returns true when the weapon uses a rifle / long-arm hold type.
function Arcana.WeaponClassification.IsRifleHoldType(wep)
	local ht = getHoldType(wep)
	return ht == "ar2" or ht == "shotgun" or ht == "rpg" or ht == "crossbow" or ht == "smg" or ht == "physgun"
end

--- Returns true when the weapon uses primary ammo or has a finite clip.
function Arcana.WeaponClassification.UsesAmmo(wep)
	if not IsValid(wep) then return false end

	local usesAmmo = (wep.GetPrimaryAmmoType and wep:GetPrimaryAmmoType() or -1) ~= -1
	local maxClip = wep.GetMaxClip1 and (wep:GetMaxClip1() or -1) or -1
	if (not maxClip or maxClip <= 0) and wep.Primary and tonumber(wep.Primary.ClipSize) then
		maxClip = tonumber(wep.Primary.ClipSize) or -1
	end

	return usesAmmo or (maxClip and maxClip > 0) or false
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
	-- Returns: type (string), projectileClass (string or nil), needsCapture (bool),
	--   usesBullets (bool or nil)
	--   needsCapture is true when the classification is incomplete and runtime
	--   capture is required: PROJECTILE whose class could not be statically resolved
	--   (unresolvable variable passed to ents.Create), or the catch-all HITSCAN
	--   result where usesBullets is still undetermined.
	--   usesBullets is true when the weapon was confirmed to fire actual bullets:
	--   either FireBullets was found in the source, or PrimaryAttack is not a Lua
	--   function (engine weapon, which cannot be analyzed nor wrapped). It is nil
	--   for the catch-all HITSCAN result, where runtime capture resolves it later.
	local function classifyRangedWeapon(weapon)
		local primaryAttack = weapon.PrimaryAttack
		if not isfunction(primaryAttack) then return "HITSCAN", nil, false, true end

		if checkForMatch(primaryAttack, weapon, {}, 1, matchFireBullets) then
			return "HITSCAN", nil, false, true
		end

		local projClass = checkForMatch(primaryAttack, weapon, {}, 1, sourceHasScriptedCreate)
		if projClass then
			local resolvedClass = isstring(projClass) and projClass or nil
			return "PROJECTILE", resolvedClass, resolvedClass == nil
		end

		local think = weapon.Think
		if isfunction(think) then
			projClass = checkForMatch(think, weapon, {}, 1, sourceHasScriptedCreate)
			if projClass then
				local resolvedClass = isstring(projClass) and projClass or nil
				return "PROJECTILE", resolvedClass, resolvedClass == nil
			end
		end

		return "HITSCAN", nil, true, nil
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

	function Arcana.WeaponClassification.SendCache(ply)
		net.Start("Arcana_UpdateWeaponClassificationCache")
		net.WriteInt(table.Count(weaponClassificationCache), 32)
		for className, entry in pairs(weaponClassificationCache) do
			net.WriteString(className)
			net.WriteString(entry.type or "UNKNOWN")
			net.WriteString(entry.holdType or "")
			net.WriteString(entry.projectileClass or "")
			-- usesBullets is a tri-state: nil = undetermined, false = confirmed no bullets
			net.WriteBool(entry.usesBullets ~= nil)
			net.WriteBool(entry.usesBullets == true)
			net.WriteBool(entry.usesAmmo == true)
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

		file.Write(CACHE_FILE, util.TableToJSON(weaponClassificationCache, true))
		Arcana.WeaponClassification.SendCache()
	end

	-- When static analysis finds an ents.Create call with an unresolvable argument,
	-- we try to resolve the projectile class using OnEntityCreated during the frame
	-- PrimaryAttack is called into.
	local PROJECTILE_CAPTURE_DISTANCE = 200 * 200 -- squared
	local function installRuntimeProjectileCapture(wep, weaponClass)
		if not IsValid(wep) then return end

		local originalPrimaryAttack = wep.PrimaryAttack
		wep.PrimaryAttack = function(self, ...)
			local hookId = "Arcana_RuntimeProjectileCapture_" .. weaponClass
			hook.Add("OnEntityCreated", hookId, function(ent)
				if isProjectileClass(ent:GetClass()) then
					timer.Simple(0, function()
						if ent:GetPos():DistToSqr(self:GetPos()) < PROJECTILE_CAPTURE_DISTANCE then
							local entry = weaponClassificationCache[weaponClass]
							if entry then
								entry.projectileClass = ent:GetClass()
								updateWeaponClassificationCache()
								hook.Remove("OnEntityCreated", hookId)
								self.PrimaryAttack = originalPrimaryAttack
							end
						end
					end)
				end
			end)

			timer.Simple(2, function()
				hook.Remove("OnEntityCreated", hookId)
			end)
			return originalPrimaryAttack(self, ...)
		end
	end

	-- A weapon can only produce a shot right now if its fire cooldown elapsed and,
	-- when it consumes ammo, it has some left. Used to gate out dry fires.
	local function canWeaponFireNow(wep, usesAmmo)
		return wep:GetNextPrimaryFire() <= CurTime() and (not usesAmmo or wep:HasAmmo())
	end

	-- Persistent PrimaryAttack wrapper for HITSCAN weapons confirmed to fire no
	-- actual bullets (usesBullets == false, e.g. weapon_hl1_gauss). Synthesizes an
	-- Arcana_ShotFired event per shot: builds a Bullet-like data table (see
	-- https://wiki.facepunch.com/gmod/Structures/Bullet), fires a trace from the
	-- owner's shoot position and invokes data.Callback with it, mirroring what the
	-- engine does for real FireBullets calls. Bullet-based weapons get the same
	-- event from the EntityFireBullets relay below instead.
	local SHOT_TRACE_DISTANCE = 56756 -- FireBullets default Distance
	local function installShotEventEmitter(wep)
		if not IsValid(wep) then return end
		if wep._ArcanaShotEmitter then return end
		if not isfunction(wep.PrimaryAttack) then return end -- engine weapons cannot be wrapped

		wep._ArcanaShotEmitter = true
		local usesAmmo = Arcana.WeaponClassification.UsesAmmo(wep)
		local originalPrimaryAttack = wep.PrimaryAttack
		wep.PrimaryAttack = function(self, ...)
			local owner = self:GetOwner()
			local canFire = canWeaponFireNow(self, usesAmmo) and IsValid(owner) and owner:IsPlayer()

			-- Capture the muzzle state before the attack runs; the original
			-- consumes ammo and sets the next fire time.
			local src, dir
			if canFire then
				src = owner:GetShootPos()
				dir = owner:GetAimVector()
			end

			local ret = originalPrimaryAttack(self, ...)
			if not canFire then return ret end

			local data = {
				Attacker = owner,
				Damage = 0,
				Force = 1,
				Distance = SHOT_TRACE_DISTANCE,
				HullSize = 0,
				Num = 1,
				Tracer = 1,
				AmmoType = game.GetAmmoName(self:GetPrimaryAmmoType() or -1) or "",
				Dir = dir,
				Spread = Vector(0, 0, 0),
				Src = src,
				IgnoreEntity = owner,
				ArcanaSynthesized = true, -- distinguishes this from real engine bullets
			}

			-- Handlers may set/wrap data.Callback or adjust Dir/Src, like they
			-- would in an EntityFireBullets hook
			Arcana.RunHook("ShotFired", owner, self, data)

			local tr = util.TraceLine({
				start = data.Src,
				endpos = data.Src + data.Dir * (data.Distance or SHOT_TRACE_DISTANCE),
				filter = {owner, self},
				mask = MASK_SHOT,
			})

			if isfunction(data.Callback) then
				local dmgInfo = DamageInfo()
				dmgInfo:SetAttacker(owner)
				dmgInfo:SetInflictor(self)
				dmgInfo:SetDamage(data.Damage or 0)
				dmgInfo:SetDamageType(DMG_BULLET)

				local ok, err = pcall(data.Callback, owner, tr, dmgInfo)
				if not ok then
					ErrorNoHalt("Arcana synthesized shot callback error: " .. tostring(err) .. "\n")
				end
			end

			return ret
		end
	end

	-- Relays engine bullet fire into the Arcana_ShotFired event so bullet-based
	-- and no-bullet weapons (see installShotEventEmitter) share a single event.
	hook.Add("EntityFireBullets", "Arcana_ShotFiredRelay", function(ent, data)
		local owner, wep
		if ent:IsPlayer() then
			owner, wep = ent, ent:GetActiveWeapon()
		elseif ent:IsWeapon() then
			owner, wep = ent:GetOwner(), ent
		else
			return
		end

		if not IsValid(wep) or not IsValid(owner) or not owner:IsPlayer() then return end
		Arcana.RunHook("ShotFired", owner, wep, data)
		-- do not return anything here, returning false would block the bullets
	end)

	-- Some HITSCAN-classified weapons never call FireBullets (e.g. weapon_hl1_gauss
	-- deals damage via traces). When static analysis could not tell (usesBullets is
	-- nil), we listen for an EntityFireBullets event attributable to the weapon
	-- within 2s of PrimaryAttack. Dry fires are gated out, so a shot that actually
	-- went out also proves the negative: seen -> true, timeout -> false, both final.
	local function installRuntimeBulletCapture(wep, weaponClass)
		if not IsValid(wep) then return end
		if not isfunction(wep.PrimaryAttack) then return end -- engine weapons cannot be wrapped

		local usesAmmo = Arcana.WeaponClassification.UsesAmmo(wep)
		local originalPrimaryAttack = wep.PrimaryAttack
		wep.PrimaryAttack = function(self, ...)
			-- Dry fires cannot prove anything: only arm detection when the weapon can shoot
			if canWeaponFireNow(self, usesAmmo) then
				local hookId = "Arcana_RuntimeBulletCapture_" .. weaponClass
				local detected = false
				hook.Add("EntityFireBullets", hookId, function(ent)
					if ent ~= self and ent ~= self:GetOwner() then return end

					-- The cache entry may not exist yet (capture can be installed before
					-- classifyWeapon returns); the timeout below concludes from this flag.
					detected = true

					local entry = weaponClassificationCache[weaponClass]
					if entry then
						entry.usesBullets = true
						updateWeaponClassificationCache()
						hook.Remove("EntityFireBullets", hookId)
						self.PrimaryAttack = originalPrimaryAttack
					end
					-- do not return anything here, returning false would block the bullets
				end)

				timer.Simple(2, function()
					hook.Remove("EntityFireBullets", hookId)

					local entry = weaponClassificationCache[weaponClass]
					if entry and entry.usesBullets == nil then
						entry.usesBullets = detected
						updateWeaponClassificationCache()
					end

					if IsValid(self) then
						-- Restore before wrapping so the emitter wraps the true original
						self.PrimaryAttack = originalPrimaryAttack
						if entry and entry.usesBullets == false then
							installShotEventEmitter(self)
						end
					end
				end)
			end

			return originalPrimaryAttack(self, ...)
		end
	end

	local function classifyWeapon(wep)
		local className = wep:GetClass()
		local holdType = getHoldType(wep)
		local usesAmmo = Arcana.WeaponClassification.UsesAmmo(wep)

		local hl2Type = HL2_WEAPON_CLASSIFICATIONS[className]
		if hl2Type and not weapons.Get(className) then -- we check for weapons.Get because addons can override class names for HL2
			local entry = { type = hl2Type, holdType = holdType, usesAmmo = usesAmmo }
			if hl2Type == "PROJECTILE" then
				entry.projectileClass = HL2_WEAPON_PROJECTILE_CLASSES[className]
				entry.usesBullets = false
			elseif hl2Type == "HITSCAN" then
				entry.usesBullets = true
			end
			return entry
		end

		if MELEE_HOLDTYPES[holdType] then
			return { type = "MELEE", holdType = holdType, usesAmmo = usesAmmo }
		elseif UNKNOWN_HOLDTYPES[holdType] then
			return { type = "UNKNOWN", holdType = holdType, usesAmmo = usesAmmo }
		else
			local wepType, projClass, needsCapture, usesBullets = classifyRangedWeapon(wep)
			if wepType == "HITSCAN" and (holdType == "grenade" or className:find("grenade") or className:find("nade")) then
				wepType = "PROJECTILE"
			end

			-- A PROJECTILE result means FireBullets was absent from the source
			-- (it is checked first), so usesBullets is a known negative there.
			-- This also overrides the value carried through a grenade-heuristic flip.
			if wepType == "PROJECTILE" then
				usesBullets = false
			end

			if needsCapture then
				if wepType == "PROJECTILE" then
					installRuntimeProjectileCapture(wep, className)
				else
					installRuntimeBulletCapture(wep, className)
				end
			end

			return {
				type = wepType,
				holdType = holdType,
				projectileClass = projClass,
				usesBullets = usesBullets,
				usesAmmo = usesAmmo
			}
		end
	end

	function Arcana.WeaponClassification.Get(wep)
		if not IsValid(wep) then return "UNKNOWN" end

		local className = wep:GetClass()
		local cached = weaponClassificationCache[className]
		if cached then return cached.type end

		local classification = classifyWeapon(wep)

		weaponClassificationCache[className] = classification
		updateWeaponClassificationCache()
		return classification.type
	end

	function Arcana.WeaponClassification.GetData(className)
		if not isstring(className) then return nil end
		return weaponClassificationCache[className]
	end

	-- Classify weapons when theyre equipped
	hook.Add("WeaponEquip", "Arcana_UpdateWeaponClassificationCache", function(wep)
		if not IsValid(wep) then return end
		local className = wep:GetClass()
		local cached = weaponClassificationCache[className]
		if cached then
			-- Already classified but projectileClass still unknown: try to resolve it at runtime.
			if cached.type == "PROJECTILE" and not cached.projectileClass then
				installRuntimeProjectileCapture(wep, className)
			end

			if cached.type == "HITSCAN" then
				if cached.usesBullets == nil then
					-- usesBullets still undetermined: try to determine it at runtime.
					installRuntimeBulletCapture(wep, className)
				elseif cached.usesBullets == false then
					-- Confirmed no-bullet weapon: synthesize Arcana_ShotFired events.
					installShotEventEmitter(wep)
				end
			end
			return
		end

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
			local className        = net.ReadString()
			local wepType          = net.ReadString()
			local holdType         = net.ReadString()
			local projectileClass  = net.ReadString()
			local hasUsesBullets   = net.ReadBool()
			local usesBulletsValue = net.ReadBool()
			local usesAmmo         = net.ReadBool()

			-- usesBullets is a tri-state:
			-- nil = undetermined, false = confirmed no bullets, true = fires bullets
			local usesBullets = nil
			if hasUsesBullets then
				usesBullets = usesBulletsValue
			end

			weaponClassificationCache[className] = {
				type            = wepType,
				holdType        = holdType ~= "" and holdType or nil,
				projectileClass = projectileClass ~= "" and projectileClass or nil,
				usesBullets     = usesBullets,
				usesAmmo        = usesAmmo,
			}
		end
	end)

	function Arcana.WeaponClassification.Get(wep)
		local className = wep:GetClass()
		if not IsValid(wep) or not isstring(className) then return "UNKNOWN" end
		local cached = weaponClassificationCache[className]
		if cached then return cached.type end
		return "UNKNOWN"
	end

	function Arcana.WeaponClassification.GetData(className)
		if not isstring(className) then return nil end
		return weaponClassificationCache[className]
	end
end

if SERVER then
	--- Cache a player's current PROJECTILE weapon data so the projectile dispatcher can
	-- recover enchantment state even if the weapon is removed before the deferred check.
	-- Called from PlayerSwitchWeapon, EntityRemoved, and on successful dispatch.
	-- @param ply Player
	-- @param wep Entity  The weapon to cache (must still be valid)
	function Arcana.WeaponClassification.CachePlayerProjectileWeapon(ply, wep)
		if not IsValid(ply) or not IsValid(wep) then return end
		if Arcana.WeaponClassification.Get(wep) ~= "PROJECTILE" then return end

		local wepData = Arcana.WeaponClassification.GetData(wep:GetClass())
		ply._ArcanaLastProjWeapon = {
			wep          = wep,
			wepClass     = wep:GetClass(),
			projClass    = wepData and wepData.projectileClass or nil,
			enchantments = wep.ArcanaEnchantments,
			cachedAt     = CurTime(),
		}
	end

	--- Retrieve the cached PROJECTILE weapon data for a player. Returns nil if the
	-- cache has expired (>0.1s) or was never set.
	-- @param ply Player
	-- @return table|nil  { wep, wepClass, projClass, enchantments, cachedAt }
	function Arcana.WeaponClassification.GetCachedProjectileWeapon(ply)
		if not IsValid(ply) then return nil end
		local cache = ply._ArcanaLastProjWeapon
		if not cache then return nil end
		if CurTime() - cache.cachedAt > 0.1 then
			ply._ArcanaLastProjWeapon = nil
			return nil
		end
		return cache
	end

	--- Resolve the player owner of a freshly-created projectile entity.
	-- Tries GetOwner, then CPPI (community standard, not vanilla — always guard), then
	-- spatial proximity to the closest player holding (or recently holding) a matching
	-- PROJECTILE-classified weapon. The proximity fallback also checks the player's cached
	-- previous weapon to handle weapons removed between fire and this deferred check.
	-- Must be called after a timer.Simple(0) defer so ownership has had time to settle.
	-- @param ent       Entity     The projectile entity
	-- @param projClass string|nil Expected entity class; used only to narrow the proximity fallback
	-- @return Player|nil
	function Arcana.WeaponClassification.ResolveProjectileOwner(ent, projClass)
		-- Tier 1: standard GMod owner
		local owner = ent:GetOwner()
		if IsValid(owner) and owner:IsPlayer() then return owner end

		-- Tier 2: CPPI community standard (not part of vanilla GLua API — always guard)
		if isfunction(ent.CPPIGetOwner) then
			owner = ent:CPPIGetOwner()
			if IsValid(owner) and owner:IsPlayer() then return owner end
		end

		-- Tier 3: closest player holding (or recently holding) a matching PROJECTILE weapon
		local pos = ent:GetPos()
		local bestPly, bestDist = nil, 300
		for _, ply in ipairs(player.GetAll()) do
			if not ply:Alive() then continue end

			local matched = false

			local wep = ply:GetActiveWeapon()
			if IsValid(wep) and Arcana.WeaponClassification.Get(wep) == "PROJECTILE" then
				if projClass then
					local data = Arcana.WeaponClassification.GetData(wep:GetClass())
					if data and data.projectileClass == projClass then matched = true end
				else
					matched = true
				end
			end

			if not matched then
				local cache = Arcana.WeaponClassification.GetCachedProjectileWeapon(ply)
				if cache then
					if not projClass or cache.projClass == projClass then
						matched = true
					end
				end
			end

			if matched then
				local dist = ply:GetPos():Distance(pos)
				if dist < bestDist then bestDist = dist; bestPly = ply end
			end
		end
		return bestPly
	end

	--- Tracks a projectile and calls each registered onDetonate(ent) callback when either:
	--   a) The entity is removed (standard detonation) — primary trigger via CallOnRemove.
	--   b) The entity's speed has been below SLOW_VEL_THRESHOLD for SLOW_VEL_DURATION seconds
	--      — catches sticky/long-lived projectiles that never naturally remove themselves.
	-- Multiple enchantments on the same projectile each call this independently; all callbacks
	-- are stored in a list and fired together from a single shared CallOnRemove/velocity trigger.
	-- Each callback fires exactly once per detonation event.
	-- @param proj       Entity    The projectile to track
	-- @param onDetonate function  Called as onDetonate(proj) on detonation
	local SLOW_VEL_THRESHOLD = 30   -- units/sec; below this counts as "stuck"
	local SLOW_VEL_DURATION  = 2.0  -- seconds of continuous low velocity before forcing detonation
	local SLOW_VEL_MIN_AGE   = 0.5  -- ignore velocity for the first N seconds so slow-launch weapons don't misfire

	local _projDetonTrack = {}

	local function fireDetonCallbacks(state, ent)
		state.fired = true
		for _, cb in ipairs(state.callbacks) do
			local ok, err = pcall(cb, ent)
			if not ok then ErrorNoHalt("TrackProjectileDetonation error: " .. tostring(err) .. "\n") end
		end
	end

	function Arcana.WeaponClassification.TrackProjectileDetonation(proj, onDetonate)
		if not IsValid(proj) or not isfunction(onDetonate) then return end

		local state = _projDetonTrack[proj]
		if state then
			-- Already tracking this projectile (another enchantment registered first);
			-- just append the new callback to the shared list.
			table.insert(state.callbacks, onDetonate)
			return
		end

		-- First registration for this projectile: create state and hook removal.
		state = {
			callbacks    = { onDetonate },
			fired        = false,
			lowVelSince  = nil,
			registeredAt = CurTime(),
		}
		_projDetonTrack[proj] = state

		-- Primary trigger: a single CallOnRemove fires all callbacks together.
		proj:CallOnRemove("Arcana_ProjDetonTrack", function(e)
			local s = _projDetonTrack[e]
			if not s or s.fired then
				_projDetonTrack[e] = nil
				return
			end
			_projDetonTrack[e] = nil
			fireDetonCallbacks(s, e)
		end)
	end

	-- Secondary trigger: velocity timeout, checked every 0.1s across all tracked projectiles.
	timer.Create("Arcana_ProjDetonVelCheck", 0.1, 0, function()
		local now = CurTime()
		for ent, state in pairs(_projDetonTrack) do
			if state.fired then
				_projDetonTrack[ent] = nil
				continue
			end

			if not IsValid(ent) then
				-- CallOnRemove should have cleaned this up, but guard anyway
				_projDetonTrack[ent] = nil
				continue
			end

			-- Don't penalise slow-launch projectiles during their initial flight window
			if now - state.registeredAt < SLOW_VEL_MIN_AGE then continue end

			local speed = ent:GetVelocity():Length()
			if speed < SLOW_VEL_THRESHOLD then
				if not state.lowVelSince then
					state.lowVelSince = now
				elseif now - state.lowVelSince >= SLOW_VEL_DURATION then
					_projDetonTrack[ent] = nil
					fireDetonCallbacks(state, ent)
				end
			else
				state.lowVelSince = nil  -- picked up speed again, reset the clock
			end
		end
	end)
end