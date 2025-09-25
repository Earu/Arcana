-- Freeze: Launch a fast ice bolt that applies Frost status on hit
Arcane:RegisterSpell({
	id = "freeze",
	name = "Freeze",
	description = "Launch a fast ice bolt that chills and slows the first target it hits.",
	category = Arcane.CATEGORIES.COMBAT,
	level_required = 3,
	knowledge_cost = 2,
	cooldown = 5.0,
	cost_type = Arcane.COST_TYPES.COINS,
	cost_amount = 35,
	cast_time = 0.5,
	range = 1400,
	icon = "icon16/weather_snow.png",
	is_projectile = true,
	has_target = true,
	cast_anim = "forward",
	cast = function(caster, _, _, ctx)
		if not SERVER then return true end
		if not IsValid(caster) then return false end
		local startPos

		if ctx and ctx.circlePos then
			startPos = ctx.circlePos + caster:GetForward() * 6
		else
			startPos = caster:WorldSpaceCenter() + caster:GetForward() * 20
		end

		local ent = ents.Create("arcana_ice_bolt")
		if not IsValid(ent) then return false end
		ent:SetPos(startPos)
		ent:SetAngles(caster:GetAimVector():Angle())
		ent:Spawn()
		ent:SetOwner(caster)

		if ent.SetSpellOwner then
			ent:SetSpellOwner(caster)
		end

		if ent.CPPISetOwner then
			ent:CPPISetOwner(caster)
		end

		if ent.LaunchTowards then
			ent:LaunchTowards(caster:GetAimVector())
		end

		-- Subtle cast SFX
		sound.Play("weapons/physcannon/energy_sing_flyby1.wav", startPos, 65, 220)

		return true
	end,
	trigger_phrase_aliases = {
		"ice bolt",
		"ice",
		"freeze",
	}
})


