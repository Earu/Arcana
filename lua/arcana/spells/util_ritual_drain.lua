-- Ritual Drain
-- Siphon time off any ritual you aim at, cutting its remaining duration.
-- Repeated casts collapse the ritual entirely, so rituals must be defended.
local DRAIN_FRACTION = 0.20 -- fraction of the ritual's TOTAL lifetime removed per cast
local RANGE = 1500

if SERVER then
	hook.Add("Arcana_BeginCasting", "RitualDrain_TargetScan", function(caster, spellId)
		if spellId ~= "ritual_drain" then return end

		Arcana.Common.TargetScan(caster, function(ent)
			return IsValid(ent) and ent:GetClass() == "arcana_ritual"
		end, RANGE)
	end)
end

local function drain_bandvfx(target)
	local r = math.max(target:OBBMaxs():Unpack()) * 0.5

	Arcana:SendAttachBandVFX(target, Color(120, 40, 160, 255), 40, 0.6, {
		{
			radius = r * 1.1,
			height = 6,
			spin = {
				p = 0,
				y = -60,
				r = 0
			},
			lineWidth = 3
		},
	})
end

Arcana:RegisterSpell({
	id = "ritual_drain",
	name = "Ritual Drain",
	description = "Drains time from the ritual in your crosshair, cutting its remaining duration. Repeated casts collapse it.",
	category = Arcana.CATEGORIES.UTILITY,
	level_required = 4,
	knowledge_cost = 2,
	cooldown = 6.0,
	cost_type = Arcana.COST_TYPES.COINS,
	cost_amount = 250,
	cast_time = 2.0,
	range = RANGE,
	is_projectile = false,
	has_target = true,
	cast = function(caster, _, _, _)
		if not SERVER then return true end

		local target = Arcana.Common.GetLockedTarget(caster)
		if not IsValid(target) or target:GetClass() ~= "arcana_ritual" then return false end

		local total = target:GetTotalLifetime()
		if not total or total <= 0 then return false end

		local newExpire = target:GetExpireAt() - total * DRAIN_FRACTION
		target:SetExpireAt(newExpire)

		target:EmitSound("arcana/arcane_" .. math.random(1, 3) .. ".ogg", 75, 80)
		drain_bandvfx(target)

		-- Fully drained: collapse now rather than waiting for the next Think.
		if newExpire <= CurTime() then
			target:Remove()
		end

		return true
	end,
	trigger_phrase_aliases = {
		"siphon ritual",
		"drain ritual",
	}
})
