local function minify_bandvfx(target)
	local r = math.max(target:OBBMaxs():Unpack()) * 0.5

	Arcane:SendAttachBandVFX(target, Color(150, 220, 255, 255), 30, .5, {
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

Arcane:RegisterSpell({
	id = "minify_player",
	name = "Minify Player",
	description = "Minifies the target player of the spell momentarily, or yourself if no player is in your crosshair!",
	category = Arcane.CATEGORIES.COMBAT,
	level_required = 4,
	knowledge_cost = 1,
	cooldown = 10.0,
	cost_type = Arcane.COST_TYPES.COINS,
	cost_amount = 500,
	cast_time = 3.0,
	range = 1200,
	icon = "icon16/zoom_out.png",
	is_projectile = false,
	has_target = true,
	cast = function(caster, _, _, ctx)
		if not SERVER then return true end
		local target = caster:GetEyeTrace().Entity

		if not target or not target:IsPlayer() then
			target = caster
		end

		if not target._arcanaminified then
			target:SetModelScale(target:GetModelScale() * .75, .5)
			target:EmitSound("player/suit_sprint.wav", 70, 90)
			minify_bandvfx(target)
			target._arcanaminified = true

			timer.Simple(20, function()
				target:SetModelScale(1, .5)
				target._arcanaminified = nil
				minify_bandvfx(target)
			end)

			return true
		else
			return false
		end
	end
})