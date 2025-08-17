Arcane:RegisterSpell({
	id = "stone_volley",
	name = "Stone Volley",
	description = "Summon pebbles above and launch them forward.",
	category = Arcane.CATEGORIES.COMBAT,
	level_required = 1,
	knowledge_cost = 1,
	cooldown = 4.0,
	cost_type = Arcane.COST_TYPES.COINS,
	cost_amount = 15,
	cast_time = 0.8,
	range = 1000,
	icon = "icon16/brick.png",
	is_projectile = true,
	cast_anim = "forward",

	cast = function(caster, _, _, ctx)
		if not SERVER then return true end

		local count = 8
		local start = (ctx and ctx.circlePos or caster:GetShootPos()) + Vector(0, 0, 18)
		local dir = caster:GetAimVector()
		for i = 1, count do
			local pebble = ents.Create("prop_physics")
			if not IsValid(pebble) then continue end
			pebble:SetModel("models/props_junk/rock001a.mdl")
			pebble:SetMaterial("models/props_wasteland/rockcliff02b")
			pebble:SetPos(start + VectorRand() * 10 + Vector(0,0,8))
			pebble:Spawn()

			if pebble.CPPISetOwner then
				pebble:CPPISetOwner(caster)
			end

			local phys = pebble:GetPhysicsObject()
			if IsValid(phys) then
				phys:SetVelocity(dir * 2000 + VectorRand() * 40)
				phys:AddAngleVelocity(VectorRand() * 200)
			end
			timer.Simple(4, function() if IsValid(pebble) then pebble:Remove() end end)
		end

		caster:EmitSound("physics/concrete/concrete_impact_hard" .. math.random(1, 3) .. ".wav", 70, 100)
		return true
	end
})


