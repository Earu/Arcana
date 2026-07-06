local function attachInfiniteAmmo(ply, wep, state)
	if not SERVER then return end
	if not IsValid(ply) or not IsValid(wep) then return end

	-- Continuously top off the weapon clips while this weapon is active
	state._hookId = string.format("Arcana_Ench_InfiniteAmmo_%d_%d", wep:EntIndex(), ply:EntIndex())
	hook.Add("Think", state._hookId, function()
		if IsValid(wep:GetOwner()) then
			ply = wep:GetOwner()
		end

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

		-- SWEP:Ammo1 is not valid for engine weapons like ar2
		if isfunction(active.Ammo1) and active:Ammo1() < 2 then
			local primaryAmmoType = wep:GetPrimaryAmmoType()
			ply:SetAmmo(2, primaryAmmoType)
		end
	end)
end

local function detachInfiniteAmmo(ply, wep, state)
	if not SERVER then return end

	if not state or not state._hookId then return end
	hook.Remove("Think", state._hookId)
	state._hookId = nil
end

Arcana:RegisterEnchantment({
	id = "endless_munitions",
	name = "Endless Munitions",
	description = "This weapon never consumes ammo while equipped; clips auto-refill.",
	cost_coins = 2000,
	cost_items = {
		{ name = "mana_crystal_shard", amount = 100 },
	},
	can_apply = function(ply, wep)
		if not IsValid(wep) then return false end
		-- Eligible if weapon uses primary ammo or has a finite clip
		return Arcana.WeaponClassification.UsesAmmo(wep) and Arcana.WeaponClassification.Get(wep) ~= "MELEE"
	end,
	apply = attachInfiniteAmmo,
	remove = detachInfiniteAmmo,
})


