Arcane:RegisterSpell({
	id = "blackhole",
	name = "Blackhole",
	description = "Summons a very dangerous blackhole.",
	category = Arcane.CATEGORIES.COMBAT,
	level_required = 50,
	knowledge_cost = 10,
	cooldown = 60,
	cost_type = Arcane.COST_TYPES.COINS,
	cost_amount = 600000,
	cast_time = 6,
	range = 0,
	icon = "icon16/brick.png",
	is_divine_pact = true,
	cast_anim = "becon",
	has_target = false,
	is_projectile = false,
	cast = function(caster, _, _, ctx)
		if not SERVER then return true end

		local srcEnt = IsValid(ctx.casterEntity) and ctx.casterEntity or caster
		local targetPos = Arcane:ResolveGroundTarget(srcEnt, 1000)

		local blackhole = ents.Create("arcana_blackhole")
		blackhole:SetPos(targetPos + Vector(0, 0, 200))
		blackhole:Spawn()

		-- Dramatic spawn sounds
		sound.Play("ambient/levels/citadel/portal_beam_shoot" .. math.random(1, 6) .. ".wav", targetPos, 100, 50)
		sound.Play("ambient/atmosphere/cave_hit" .. math.random(1, 6) .. ".wav", targetPos, 100, 70)
		sound.Play("ambient/explosions/explode_" .. math.random(1, 3) .. ".wav", targetPos, 95, 80)

		timer.Simple(0.2, function()
			sound.Play("ambient/levels/labs/teleport_preblast_suckin1.wav", targetPos, 100, 60)
		end)

		timer.Simple(0.5, function()
			sound.Play("ambient/atmosphere/thunder" .. math.random(1, 4) .. ".wav", targetPos, 95, 100)
		end)

		-- Visual effects at spawn
		local ed = EffectData()
		ed:SetOrigin(targetPos + Vector(0, 0, 200))
		util.Effect("cball_explode", ed, true, true)
		util.Effect("ManhackSparks", ed, true, true)

		if blackhole.CPPISetOwner then
			blackhole:CPPISetOwner(caster)
		end

		SafeRemoveEntityDelayed(blackhole, 20)

		return true
	end
})

if CLIENT then
	hook.Add("Arcana_BeginCastingVisuals", "Arcana_Blackhole_Circle", function(caster, spellId, castTime, _forwardLike)
		if spellId ~= "blackhole" then return end

		Arcane:CreateFollowingCastCircle(caster, spellId, castTime, {
			color = Color(100, 50, 200, 255),
			size = 300,
			intensity = 100,
			positionResolver = function(c)
				return Arcane:ResolveGroundTarget(c, 1000)
			end
		})
	end)
end