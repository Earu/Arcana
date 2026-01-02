-- Wind Dash
-- Propel the caster forward in their aim direction with wind magic, negating fall damage
local DASH_FORCE = 2000 -- Base propulsion force
local UPWARD_LIFT = 300 -- Upward component to help with mobility
local FALL_DAMAGE_IMMUNITY_TIME = 3.0 -- Seconds of fall damage immunity

Arcane:RegisterSpell({
	id = "wind_dash",
	name = "Wind Dash",
	description = "Propel yourself forward with a powerful gust of wind. Grants temporary immunity to fall damage.",
	category = Arcane.CATEGORIES.UTILITY,
	level_required = 8,
	knowledge_cost = 2,
	cooldown = 3.0,
	cost_type = Arcane.COST_TYPES.COINS,
	cost_amount = 25,
	cast_time = 0.3,
	range = 0,
	icon = "icon16/arrow_up.png",
	has_target = false,
	cast_anim = "forward",
	cast = function(caster, _, _, ctx)
		if not SERVER then return true end

		-- Get the direction the player is looking
		local aimDir = caster:GetAimVector()

		-- Calculate propulsion force with slight upward component for better mobility
		local forceVector = aimDir * DASH_FORCE + Vector(0, 0, UPWARD_LIFT)
		local curVel = caster:GetVelocity()
		caster:SetVelocity(curVel + forceVector)
		caster:SetGroundEntity(NULL)

		local r = math.max(caster:OBBMaxs():Unpack()) * 0.5
		Arcane:SendAttachBandVFX(caster, Color(150, 220, 255, 255), 30, .5, {
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

		-- Grant temporary fall damage immunity
		caster.ArcanaWindDashProtection = CurTime() + FALL_DAMAGE_IMMUNITY_TIME

		-- Wind sound effect
		caster:EmitSound("ambient/wind/wind_snippet" .. math.random(1, 5) .. ".wav", 75, math.random(110, 130))

		return true
	end
})

-- Hook to handle fall damage negation
if SERVER then
	hook.Add("EntityTakeDamage", "Arcana_WindDashFallProtection", function(target, dmg)
		if not target:IsPlayer() then return end
		if not target.ArcanaWindDashProtection then return end

		-- Check if this is fall damage
		local damageType = dmg:GetDamageType()
		if bit.band(damageType, DMG_FALL) == DMG_FALL then
			-- Still protected?
			if CurTime() < target.ArcanaWindDashProtection then
				-- Negate fall damage
				dmg:SetDamage(0)
				-- Play a soft landing sound
				target:EmitSound("physics/cardboard/cardboard_box_impact_soft" .. math.random(1, 7) .. ".wav", 60, 120)
				-- Remove protection after use
				target.ArcanaWindDashProtection = nil

				return true
			else
				-- Protection expired
				target.ArcanaWindDashProtection = nil
			end
		end
	end)
end