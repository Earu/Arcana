local function bandvfx(target)
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

hook.Add("InitPostEntity", "arcana_plumpen_player", function()
	local PLY = FindMetaTable("Player")
	if not PLY.GetFatness or not PLY.SetFatness then return end

	Arcane:RegisterSpell({
		id = "plumpen_player",
		name = "Plumpen",
		description = "Makes the target player of the spell fatter, or yourself if no player is in your crosshair!",
		category = Arcane.CATEGORIES.COMBAT,
		level_required = 4,
		knowledge_cost = 1,
		cooldown = 10.0,
		cost_type = Arcane.COST_TYPES.COINS,
		cost_amount = 500,
		cast_time = 3.0,
		range = 1200,
		icon = "icon16/zoom_in.png",
		is_projectile = false,
		has_target = true,
		cast = function(caster, _, _, ctx)
			local target = caster:GetEyeTrace().Entity
			if not target or not target:IsPlayer() then
				target = caster
			end

			if not target.GetFatness then return false end
			if not SERVER then return true end

			target:SetFatness(target:GetFatness() + 100)
			target:EmitSound("player/suit_sprint.wav", 70, 90)
			bandvfx(target)

			return true
		end,
		trigger_phrase_aliases = {
			"fatten",
		}
	})
end)