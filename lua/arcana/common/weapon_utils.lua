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

--- Returns true when the weapon uses a melee hold type.
function Arcana.Common.IsMeleeHoldType(wep)
	local ht = getHoldType(wep)
	return ht == "melee" or ht == "melee2" or ht == "knife" or ht == "fist"
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
