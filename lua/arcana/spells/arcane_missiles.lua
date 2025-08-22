-- Arcane Missiles: Launch three homing projectiles that prefer the target closest to the caster's aim

Arcane:RegisterSpell({
	id = "arcane_missiles",
	name = "Arcane Missiles",
	description = "Launch three homing bolts that seek your aimed target.",
	category = Arcane.CATEGORIES.COMBAT,
	level_required = 13,
	knowledge_cost = 4,
	cooldown = 9.0,
	cost_type = Arcane.COST_TYPES.COINS,
	cost_amount = 65,
	cast_time = 0.7,
	range = 1200,
	icon = "icon16/wand.png",
	has_target = true,
	is_projectile = true,
	cast_anim = "forward",

	cast = function(caster, _, _, ctx)
		if not SERVER then return true end

		local origin = (ctx and ctx.circlePos) or caster:GetShootPos()
		local aim = caster:GetAimVector()

		-- Select target once: closest to center of screen (aim direction)
		local best, bestDot, maxRange = nil, -1, 1600
		for _, ent in ipairs(ents.FindInSphere(origin + aim * (maxRange * 0.6), maxRange)) do
			if not IsValid(ent) or ent == caster then continue end
			if not (ent:IsPlayer() or ent:IsNPC()) then continue end
			if ent:Health() <= 0 then continue end
			local dir = (ent:WorldSpaceCenter() - origin):GetNormalized()
			local d = dir:Dot(aim)
			if d > bestDot then
				bestDot, best = d, ent
			end
		end

		for i = 1, 3 do
			timer.Simple(0.06 * (i - 1), function()
				if not IsValid(caster) then return end
				local ent = ents.Create("arcana_missile")
				if not IsValid(ent) then return end
				ent:SetPos(origin + aim * 12 + caster:GetRight() * ((i - 2) * 6) + caster:GetUp() * (i == 2 and 0 or 2))
				ent:SetAngles(aim:Angle())
				ent:Spawn()
				ent:SetOwner(caster)
				if ent.SetSpellOwner then ent:SetSpellOwner(caster) end
				if ent.CPPISetOwner then ent:CPPISetOwner(caster) end
				if IsValid(best) and ent.SetHomingTarget then ent:SetHomingTarget(best) end
			end)
		end

		sound.Play("weapons/physcannon/energy_sing_flyby1.wav", origin, 70, 160)
		return true
	end
})



