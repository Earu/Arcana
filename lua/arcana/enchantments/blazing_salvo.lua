local function attachHook(ply, wep, state)
	if not IsValid(ply) or not IsValid(wep) then return end

	state._hookId = string.format("Arcana_Ench_BlazingSalvo_%d_%d", wep:EntIndex(), ply:EntIndex())
	hook.Add("EntityFireBullets", hookId, function(ent, data)
		if not IsValid(ent) or not ent:IsPlayer() then return end

		local active = ent:GetActiveWeapon()
		if not IsValid(active) or active ~= wep then return end

		-- rate limit using state
		local now = CurTime()
		state._next = state._next or 0
		if now < state._next then return end
		state._next = now + 1.0

		local fb = ents.Create("arcana_fireball")
		if not IsValid(fb) then return end

		local pos = ply:WorldSpaceCenter() + ply:GetForward() * 25
		fb:SetPos(pos)
		fb:Spawn()
		fb:SetOwner(ply)

		if fb.SetSpellOwner then fb:SetSpellOwner(ply) end
		if fb.CPPISetOwner then fb:CPPISetOwner(ply) end
		if fb.LaunchTowards then fb:LaunchTowards(ply:GetAimVector()) end

		if Arcane and Arcane.SendAttachBandVFX then
			Arcane:SendAttachBandVFX(fb, Color(255, 150, 80, 255), 14, 6, {
				{ radius = 15, height = 4, spin = { p = 0, y = 80 * 50, r = 60 * 50 }, lineWidth = 2 },
				{ radius = 13, height = 3, spin = { p = 60 * 50, y = -45 * 50, r = 0 }, lineWidth = 2 },
			})
		end
	end)
end

local function detachHook(ply, wep, state)
	if not state or not state._hookId then return end
	hook.Remove("EntityFireBullets", state._hookId)
	state._hookId = nil
end

Arcane:RegisterEnchantment({
	id = "fireball_on_shoot",
	name = "Blazing Salvo",
	description = "Fires a fireball every second while shooting this weapon.",
	icon = "icon16/fire.png",
	cost_coins = 250,
	cost_items = {
		{ name = "mana_crystal_shard", amount = 10 },
	},
	can_apply = function(ply, wep)
		-- only firearms that can shoot bullets
		return IsValid(wep) and (wep.Primary ~= nil or wep.FireBullets ~= nil)
	end,
	apply = attachHook,
	remove = detachHook,
})


