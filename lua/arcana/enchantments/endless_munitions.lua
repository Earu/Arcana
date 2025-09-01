local function attachInfiniteAmmo(ply, wep, state)
	if not SERVER then return end
	if not IsValid(ply) or not IsValid(wep) then return end

	-- Continuously top off the weapon clips while this weapon is active
	state._hookId = string.format("Arcana_Ench_InfiniteAmmo_%d_%d", wep:EntIndex(), ply:EntIndex())
	hook.Add("Think", state._hookId, function()
		if not IsValid(ply) then return end
		local active = ply:GetActiveWeapon()
		if not IsValid(active) or active ~= wep then return end

		-- Resolve max primary clip size
		local maxClip1 = -1
		if active.GetMaxClip1 then
			maxClip1 = tonumber(active:GetMaxClip1() or -1) or -1
		end
		if (not maxClip1 or maxClip1 <= 0) and active.Primary and tonumber(active.Primary.ClipSize) then
			maxClip1 = tonumber(active.Primary.ClipSize) or -1
		end

		if maxClip1 and maxClip1 > 0 then
			local cur = tonumber(active:Clip1() or 0) or 0
			if cur < maxClip1 then
				active:SetClip1(maxClip1)
			end
		end

		-- Resolve max secondary clip size
		local maxClip2 = -1
		if active.GetMaxClip2 then
			maxClip2 = tonumber(active:GetMaxClip2() or -1) or -1
		end
		if (not maxClip2 or maxClip2 <= 0) and active.Secondary and tonumber(active.Secondary.ClipSize) then
			maxClip2 = tonumber(active.Secondary.ClipSize) or -1
		end

		if maxClip2 and maxClip2 > 0 then
			local cur2 = tonumber(active:Clip2() or 0) or 0
			if cur2 < maxClip2 then
				active:SetClip2(maxClip2)
			end
		end
	end)
end

local function detachInfiniteAmmo(ply, wep, state)
	if not SERVER then return end

	if not state or not state._hookId then return end
	hook.Remove("Think", state._hookId)
	state._hookId = nil
end

local function isMeleeHoldType(wep)
	if not IsValid(wep) then return false end

	local ht = (wep.GetHoldType and wep:GetHoldType()) or wep.HoldType
	if not isstring(ht) then return false end

	ht = string.lower(ht)
	return ht == "melee" or ht == "melee2" or ht == "knife" or ht == "fist"
end

Arcane:RegisterEnchantment({
	id = "infinite_ammo",
	name = "Endless Munitions",
	description = "This weapon never consumes ammo while equipped; clips auto-refill.",
	icon = "icon16/bullet_black.png",
	cost_coins = 500,
	cost_items = {
		{ name = "mana_crystal_shard", amount = 20 },
	},
	can_apply = function(ply, wep)
		if not IsValid(wep) then return false end
		-- Eligible if weapon uses primary ammo or has a finite clip
		local usesAmmo = (wep.GetPrimaryAmmoType and wep:GetPrimaryAmmoType() or -1) ~= -1
		local maxClip = wep.GetMaxClip1 and (wep:GetMaxClip1() or -1) or -1
		if (not maxClip or maxClip <= 0) and wep.Primary and tonumber(wep.Primary.ClipSize) then
			maxClip = tonumber(wep.Primary.ClipSize) or -1
		end
		return usesAmmo or (maxClip and maxClip > 0) and not isMeleeHoldType(wep)
	end,
	apply = attachInfiniteAmmo,
	remove = detachInfiniteAmmo,
})


