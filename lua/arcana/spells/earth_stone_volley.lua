Arcane:RegisterSpell({
	id = "stone_volley",
	name = "Stone Volley",
	description = "Summon pebbles above and launch them forward.",
	category = Arcane.CATEGORIES.COMBAT,
	level_required = 1,
	knowledge_cost = 1,
	cooldown = 3.5,
	cost_type = Arcane.COST_TYPES.COINS,
	cost_amount = 18,
	cast_time = 0.8,
	range = 1000,
	icon = "icon16/brick.png",
	is_projectile = true,
	cast_anim = "forward",
	cast = function(caster, _, _, ctx)
		if not SERVER then return true end

		local srcEnt = IsValid(ctx.casterEntity) and ctx.casterEntity or caster
		local count = 8
		local start = (ctx and ctx.circlePos) or (srcEnt.EyePos and srcEnt:EyePos() or srcEnt:WorldSpaceCenter()) + Vector(0, 0, 18)
		local dir = srcEnt.GetAimVector and srcEnt:GetAimVector() or srcEnt:GetForward()
		local pebbleDamage = 25

		for i = 1, count do
			local pebble = ents.Create("prop_physics")
			if not IsValid(pebble) then continue end
			pebble:SetModel("models/props_junk/rock001a.mdl")
			pebble:SetMaterial("models/props_wasteland/rockcliff02b")
			pebble:SetPos(start + VectorRand() * 10 + Vector(0, 0, 8))
			pebble:Spawn()

			if pebble.CPPISetOwner then
				pebble:CPPISetOwner(caster)
			end

			-- Store owner for damage dealing
			pebble._ArcanaStoneOwner = caster
			pebble._ArcanaStoneHit = false
			pebble._ArcanaStoneDamage = pebbleDamage

			-- Add collision callback for direct damage
			pebble:AddCallback("PhysicsCollide", function(ent, data)
				if ent._ArcanaStoneHit then return end
				local hitEnt = data.HitEntity
				if IsValid(hitEnt) and (hitEnt:IsPlayer() or hitEnt:IsNPC()) then
					ent._ArcanaStoneHit = true
					local dmg = DamageInfo()
					dmg:SetDamage(ent._ArcanaStoneDamage or pebbleDamage)
					dmg:SetDamageType(DMG_CLUB)
					dmg:SetAttacker(IsValid(ent._ArcanaStoneOwner) and ent._ArcanaStoneOwner or game.GetWorld())
					dmg:SetInflictor(ent)
					hitEnt:TakeDamageInfo(dmg)
				end
			end)

			local phys = pebble:GetPhysicsObject()
			if IsValid(phys) then
				phys:SetVelocity(dir * 2000 + VectorRand() * 40)
				phys:AddAngleVelocity(VectorRand() * 200)
			end

			timer.Simple(4, function()
				if IsValid(pebble) then
					pebble:Remove()
				end
			end)
		end

		caster:EmitSound("physics/concrete/concrete_impact_hard" .. math.random(1, 3) .. ".wav", 70, 100)

		return true
	end,
	trigger_phrase_aliases = {
		"stones",
	}
})