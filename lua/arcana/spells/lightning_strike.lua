local function resolveStrikeGround(ply)
	local tr = ply:GetEyeTrace()

	return tr.HitPos, tr.HitNormal
end

local function spawnTeslaBurst(pos)
	local tesla = ents.Create("point_tesla")
	if not IsValid(tesla) then return end
	tesla:SetPos(pos)
	tesla:SetKeyValue("targetname", "arcana_lightning")
	tesla:SetKeyValue("m_SoundName", "DoSpark")
	tesla:SetKeyValue("texture", "sprites/physbeam.vmt")
	tesla:SetKeyValue("m_Color", "170 200 255")
	tesla:SetKeyValue("m_flRadius", "220")
	tesla:SetKeyValue("beamcount_min", "6")
	tesla:SetKeyValue("beamcount_max", "10")
	tesla:SetKeyValue("thick_min", "6")
	tesla:SetKeyValue("thick_max", "10")
	tesla:SetKeyValue("lifetime_min", "0.12")
	tesla:SetKeyValue("lifetime_max", "0.18")
	tesla:SetKeyValue("interval_min", "0.05")
	tesla:SetKeyValue("interval_max", "0.10")
	tesla:Spawn()
	tesla:Fire("DoSpark", "", 0)
	tesla:Fire("Kill", "", 0.6)

	return tesla
end

-- Draw a few quick effects at the impact point
local function impactVFX(pos, normal)
	local ed = EffectData()
	ed:SetOrigin(pos)
	util.Effect("cball_explode", ed, true, true)
	util.Effect("ManhackSparks", ed, true, true)
	util.Decal("Scorch", pos + normal * 8, pos - normal * 8)
	util.ScreenShake(pos, 6, 90, 0.35, 600)
	sound.Play("ambient/energy/zap" .. math.random(1, 9) .. ".wav", pos, 95, 100)
end

-- Apply shock damage in a radius and optionally chain to a few nearby targets
local function applyLightningDamage(attacker, hitPos, normal)
	local radius = 180
	local baseDamage = 60
	Arcane:BlastDamage(attacker, attacker, hitPos, radius, baseDamage, DMG_SHOCK, false, true)

	-- Chain to up to 3 nearby living targets
	local candidates = {}

	for _, ent in ipairs(ents.FindInSphere(hitPos, 380)) do
		if IsValid(ent) and (ent:IsPlayer() or ent:IsNPC()) and ent:Health() > 0 and ent:VisibleVec(hitPos) then
			table.insert(candidates, ent)
		end
	end

	table.sort(candidates, function(a, b) return a:GetPos():DistToSqr(hitPos) < b:GetPos():DistToSqr(hitPos) end)
	local maxChains = 3

	for i = 1, math.min(maxChains, #candidates) do
		local tgt = candidates[i]
		local tpos = tgt:WorldSpaceCenter()

		timer.Simple(0.03 * i, function()
			if not IsValid(tgt) then return end
			local tesla = spawnTeslaBurst(tpos)

			if IsValid(tesla) and tesla.CPPISetOwner then
				tesla:CPPISetOwner(attacker)
			end

			local dmg = DamageInfo()
			dmg:SetDamage(24)
			dmg:SetDamageType(bit.bor(DMG_SHOCK, DMG_ENERGYBEAM))
			dmg:SetAttacker(IsValid(attacker) and attacker or game.GetWorld())
			dmg:SetInflictor(IsValid(attacker) and attacker or game.GetWorld())
			dmg:SetDamagePosition(tpos)
			tgt:TakeDamageInfo(dmg)
		end)
	end
end

Arcane:RegisterSpell({
	id = "lightning_strike",
	name = "Lightning Strike",
	description = "Call a focused lightning bolt at your aim point, chaining to nearby foes.",
	category = Arcane.CATEGORIES.COMBAT,
	level_required = 2,
	knowledge_cost = 2,
	cooldown = 6.0,
	cost_type = Arcane.COST_TYPES.COINS,
	cost_amount = 25,
	cast_time = 1.0,
	range = 1500,
	icon = "icon16/weather_lightning.png",
	has_target = true,
	cast = function(caster, _, _, ctx)
		if not SERVER then return true end
		local targetPos = resolveStrikeGround(caster)

		-- Perform 1 strong strike and 2 lighter offset strikes for style
		local strikes = {
			{
				delay = 0.00,
				offset = Vector(0, 0, 0),
				power = 1.0
			},
			{
				delay = 0.10,
				offset = Vector(math.Rand(-60, 60), math.Rand(-60, 60), 0),
				power = 0.5
			},
			{
				delay = 0.18,
				offset = Vector(math.Rand(-60, 60), math.Rand(-60, 60), 0),
				power = 0.5
			},
		}

		for _, s in ipairs(strikes) do
			timer.Simple(s.delay, function()
				if not IsValid(caster) then return end
				-- Tesla burst at impact, plus supporting effects
				local normal = Vector(0, 0, 1)
				local tesla = spawnTeslaBurst(targetPos + s.offset)

				if IsValid(tesla) and tesla.CPPISetOwner then
					tesla:CPPISetOwner(caster)
				end

				impactVFX(targetPos + s.offset, normal)

				-- Damage and short chains for the main strike only
				if s.power >= 1.0 then
					applyLightningDamage(caster, targetPos + s.offset, normal)
				else
					Arcane:BlastDamage(caster, caster, targetPos + s.offset, 120, 30, DMG_SHOCK, false, true)
				end
			end)
		end

		return true
	end,
	trigger_phrase_aliases = {
		"lightning",
	}
})

if CLIENT then
	-- Custom moving magic circle for lightning_strike that follows the player's aim on the ground
	hook.Add("Arcane_BeginCastingVisuals", "Arcana_LightningStrike_Circle", function(caster, spellId, castTime, _forwardLike)
		if spellId ~= "lightning_strike" then return end
		if not MagicCircle then return end
		local color = Color(170, 200, 255, 255)
		local pos = resolveStrikeGround(caster, 1500) or (caster:GetPos() + Vector(0, 0, 2))
		local ang = Angle(0, 0, 0)
		local size = 26
		local intensity = 4
		local circle = MagicCircle.CreateMagicCircle(pos, ang, color, intensity, size, castTime, 2)
		if not circle then return end

		if circle.StartEvolving then
			circle:StartEvolving(castTime, true)
		end

		-- Follow the ground position under the caster's aim until cast ends
		local hookName = "Arcana_LS_CircleFollow_" .. tostring(circle)
		local endTime = CurTime() + castTime + 0.05

		hook.Add("Think", hookName, function()
			if not IsValid(caster) or not circle or (circle.IsActive and not circle:IsActive()) or CurTime() > endTime then
				hook.Remove("Think", hookName)

				return
			end

			local gpos = resolveStrikeGround(caster, 1500)

			if gpos then
				circle.position = gpos + Vector(0, 0, 0.5)
				circle.angles = Angle(0, 0, 0)
			end
		end)
	end)
end