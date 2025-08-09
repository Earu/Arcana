Arcane:RegisterSpell({
	id = "blackhole",
	name = "Blackhole",
	description = "Summons a very dangerous blackhole",
	category = Arcane.CATEGORIES.COMBAT,
	level_required = 60,
	knowledge_cost = 20,
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

		local blackhole = ents.Create("blackhole")
		blackhole:SetPos(caster:GetEyeTrace().HitPos + Vector(0,0,200))
		blackhole:Spawn()

		caster:EmitSound("ambient/levels/citadel/portal_beam_shoot" .. math.random(1, 6) .. ".wav", 100, 80)

		if blackhole.CPPISetOwner then
			blackhole:CPPISetOwner(caster)
		end

		SafeRemoveEntityDelayed(blackhole, 20)

		return true
	end
})

-- Find a reliable strike point based on the player's aim, clamped to range,
-- and projected to ground with a downward trace.
local function resolveStrikeGround(ply, maxRange)
	local eyePos = ply:EyePos()
	local eyeDir = ply:GetAimVector()

	-- Initial aim trace to anything the player points at
	local trAim = util.TraceLine({
		start = eyePos,
		endpos = eyePos + eyeDir * maxRange,
		mask = MASK_SHOT,
		filter = ply
	})

	local candidatePos = trAim.Hit and trAim.HitPos or (eyePos + eyeDir * math.min(maxRange, 1000))

	-- Ensure we end up on ground or on top of a surface
	local trDown = util.TraceLine({
		start = candidatePos + Vector(0, 0, 2048),
		endpos = candidatePos - Vector(0, 0, 4096),
		mask = MASK_SHOT,
		filter = ply
	})

	if trDown.Hit then
		return trDown.HitPos, trDown.HitNormal
	end

	return candidatePos, Vector(0, 0, 1)
end

if CLIENT then
	hook.Add("Arcane_BeginCastingVisuals", "Arcana_Blackhole_Circle", function(caster, spellId, castTime, _forwardLike)
		if spellId ~= "blackhole" then return end
		if not MagicCircle then return end

		local color = Color(100, 50, 200, 255)
		local pos = resolveStrikeGround(caster, 2e6) or (caster:GetPos() + Vector(0, 0, 2))
		local ang = Angle(0, 0, 0)
		local size = 300
		local intensity = 100

		local circle = MagicCircle.CreateMagicCircle(pos, ang, color, intensity, size, castTime, 2)
		if not circle then return end
		if circle.StartEvolving then circle:StartEvolving(castTime, true) end

		local hookName = "Arcana_BL_CircleFollow_" .. tostring(circle)
		local endTime = CurTime() + castTime + 0.05
		hook.Add("Think", hookName, function()
			if not IsValid(caster) or not circle or (circle.IsActive and not circle:IsActive()) or CurTime() > endTime then
				hook.Remove("Think", hookName)
				return
			end

			local gpos = resolveStrikeGround(caster, 2e6)
			if gpos then
				circle.position = gpos + Vector(0, 0, 0.5)
				circle.angles = Angle(0, 0, 0)
			end
		end)
	end)
end

