Arcane:RegisterSpell({
	id = "blackhole",
	name = "Blackhole",
	description = "Summons a very dangerous blackhole.",
	category = Arcane.CATEGORIES.COMBAT,
	level_required = 25,
	knowledge_cost = 10,
	cooldown = 60,
	cost_type = Arcane.COST_TYPES.COINS,
	cost_amount = 1e6,
	cast_time = 6,
	range = 0,
	icon = "icon16/brick.png",
	cast_anim = "becon",
	has_target = false,
	is_projectile = false,
	cast = function(caster, _, _, ctx)
		if not SERVER then return true end
		local blackhole = ents.Create("arcana_blackhole")
		blackhole:SetPos(caster:GetEyeTrace().HitPos + Vector(0, 0, 200))
		blackhole:Spawn()
		caster:EmitSound("ambient/levels/citadel/portal_beam_shoot" .. math.random(1, 6) .. ".wav", 100, 80)

		if blackhole.CPPISetOwner then
			blackhole:CPPISetOwner(caster)
		end

		SafeRemoveEntityDelayed(blackhole, 20)

		return true
	end
})

local function resolveStrikeGround(ply)
	local tr = ply:GetEyeTrace()

	return tr.HitPos, tr.HitNormal
end

if CLIENT then
	hook.Add("Arcane_BeginCastingVisuals", "Arcana_Blackhole_Circle", function(caster, spellId, castTime, _forwardLike)
		if spellId ~= "blackhole" then return end
		if not MagicCircle then return end
		local color = Color(100, 50, 200, 255)
		local pos = resolveStrikeGround(caster) or (caster:GetPos() + Vector(0, 0, 2))
		local ang = Angle(0, 0, 0)
		local size = 300
		local intensity = 100
		local circle = MagicCircle.CreateMagicCircle(pos, ang, color, intensity, size, castTime, 2)
		if not circle then return end

		if circle.StartEvolving then
			circle:StartEvolving(castTime, true)
		end

		local hookName = "Arcana_BL_CircleFollow_" .. tostring(circle)
		local endTime = CurTime() + castTime + 0.05

		hook.Add("Think", hookName, function()
			if not IsValid(caster) or not circle or (circle.IsActive and not circle:IsActive()) or CurTime() > endTime then
				hook.Remove("Think", hookName)

				return
			end

			local gpos = resolveStrikeGround(caster)

			if gpos then
				circle.position = gpos + Vector(0, 0, 0.5)
				circle.angles = Angle(0, 0, 0)
			end
		end)
	end)
end