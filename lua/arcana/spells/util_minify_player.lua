if SERVER then
	hook.Add("Arcana_BeginCasting", "MinifyPlayer_TargetScan", function(caster, spellId)
		if spellId ~= "minify_player" then return end
		Arcana.Common.TargetScan(caster, function(ent)
			return IsValid(ent) and ent:IsPlayer()
		end, 1200)
	end)
end

local function minify_bandvfx(target)
	local r = math.max(target:OBBMaxs():Unpack()) * 0.5

	Arcana:SendAttachBandVFX(target, Color(150, 220, 255, 255), 30, .5, {
		{
			radius = r * 0.9,
			height = 5,
			spin = {
				p = 0,
				y = 35,
				r = 0
			},
			lineWidth = 2
		},
	})
end

Arcana:RegisterSpell({
	id = "minify_player",
	name = "Minify",
	description = "Minifies the target player of the spell momentarily, or yourself if no player is in your crosshair!",
	category = Arcana.CATEGORIES.COMBAT,
	level_required = 4,
	knowledge_cost = 1,
	cooldown = 10.0,
	cost_type = Arcana.COST_TYPES.COINS,
	cost_amount = 500,
	cast_time = 3.0,
	range = 1200,
	is_projectile = false,
	has_target = true,
	cast = function(caster, _, _, ctx)
		if not SERVER then return true end

		local target = Arcana.Common.GetLockedTarget(caster)
		if not target or not target:IsPlayer() then
			target = caster
		end

		if not target._arcanaminified then
			if target.SetKidMode then
				target:SetKidMode(true)
				minify_bandvfx(target)
				target._arcanaminified = true

				timer.Simple(20, function()
					target:SetKidMode(false)
					minify_bandvfx(target)
					target._arcanaminified = nil
				end)
			else
				target:SetModelScale(target:GetModelScale() * .75, .5)
				target:EmitSound("player/suit_sprint.wav", 70, 90)
				minify_bandvfx(target)
				target._arcanaminified = true

				timer.Simple(20, function()
					target:SetModelScale(1, .5)
					target._arcanaminified = nil
					minify_bandvfx(target)
				end)
			end

			return true
		else
			return false
		end
	end,
	trigger_phrase_aliases = {
		"shrink",
	}
})
