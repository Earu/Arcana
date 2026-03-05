-- Arcana Weapon Utilities
-- Shared hold-type helpers used by enchantments and VFX

Arcana = Arcana or {}
Arcana.Common = Arcana.Common or {}

local function getHoldType(wep)
	if not IsValid(wep) then return "" end
	local ht = (wep.GetHoldType and wep:GetHoldType()) or wep.HoldType
	if not isstring(ht) then return "" end
	return string.lower(ht)
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
