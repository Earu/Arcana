local ACCEPTABLE_SURFACE_TYPES = {
	[MAT_GRASS] = true,
	[MAT_DIRT] = true,
	[MAT_SAND] = true,
	[MAT_SNOW] = true,
}

local FOREST_LIFETIME = 60 * 20

Arcana:RegisterRitualSpell({
	id = "ritual_magical_forest",
	name = "Ritual: Magical Forest",
	description = "Summons a dense magical forest.",
	category = Arcana.CATEGORIES.UTILITY,
	level_required = 23,
	knowledge_cost = 4,
    cooldown = 60 * 60,
	cost_type = Arcana.COST_TYPES.COINS,
	cost_amount = 10000,
	cast_time = 10.0,
	ritual_color = Color(0, 99, 0),
	ritual_lifetime = FOREST_LIFETIME,
	ritual_items = {
		banana = 20,
		melon = 20,
		orange = 20
	},
	can_cast = function(caster)
		if Arcana.Environments:IsActive() then
			return false, "Another environment is already active."
		end

		local tr = caster:GetEyeTrace()
		if not tr.Hit or not ACCEPTABLE_SURFACE_TYPES[tr.MatType] then return false, "This ritual may only be cast on grass, dirt, sand, or snow terrain." end

		return true
	end,
	ritual_replenishable = true,
	ritual_replenish_cost = 5000,
	on_activate = function(selfEnt, activatingPly, caster)
		if not SERVER then return end

        local Envs = Arcana.Environments
		if Envs:IsActive() then
			Arcana:SendErrorNotification(activatingPly, "Another environment is already active.")
			return
		end

        local ok, reason = Envs:Start("magical_forest", selfEnt:GetPos(), activatingPly)
        if not ok then
            Arcana:SendErrorNotification(activatingPly, "Ritual failed: " .. tostring(reason))
            return
        end

		selfEnt:CallOnRemove("StopForestEnv", function()
			local active = Envs:GetActive()
			if active and active.id == "magical_forest" then
				Envs:Stop("ritual ended")
			end
		end)

        selfEnt:EmitSound("ambient/levels/citadel/strange_talk5.wav", 70, 110)
	end,
	on_replenish = function(selfEnt, activatingPly, caster)
		if not SERVER then return end

		local Envs = Arcana.Environments
		if Envs and Envs.ExtendDuration then
			Envs:ExtendDuration("magical_forest", FOREST_LIFETIME)
		end
	end,
})