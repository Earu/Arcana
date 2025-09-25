-- Healing Sanctuary: Create a healing field at the aimed ground that restores health over time
Arcane:RegisterSpell({
	id = "sanctuary",
	name = "Sanctuary",
	description = "Conjure a restorative field that heals allies over time.",
	category = Arcane.CATEGORIES.PROTECTION,
	level_required = 11,
	knowledge_cost = 3,
	cooldown = 20.0,
	cost_type = Arcane.COST_TYPES.COINS,
	cost_amount = 150,
	cast_time = 1.5,
	range = 0,
	icon = "icon16/heart_add.png",
	has_target = true,
	cast_anim = "becon",
	cast = function(caster, _, _, ctx)
		if not SERVER then return true end
		if not IsValid(caster) then return false end
		local tr = caster:GetEyeTrace()
		if not tr or not tr.Hit then return false end
		local center = tr.HitPos + Vector(0, 0, 2)
		local duration = 18
		local tick = 1.0
		local healPerTick = 6
		local radius = 360

		-- Anchor entity for VFX (must network to clients)
		local anchor = ents.Create("prop_dynamic")
		if not IsValid(anchor) then return false end
		anchor:SetModel("models/props_junk/PopCan01a.mdl")
		anchor:SetPos(center)
		anchor:SetAngles(Angle(0, 0, 0))
		anchor:Spawn()
		-- Make visually invisible without hiding for client effects
		anchor:DrawShadow(false)
		anchor:SetRenderMode(RENDERMODE_TRANSCOLOR)
		anchor:SetColor(Color(255, 255, 255, 1))
		anchor:SetModelScale(0.01, 0)
		anchor:SetSolid(SOLID_NONE)
		anchor:SetMoveType(MOVETYPE_NONE)

		-- Healing loop
		local endTime = CurTime() + duration
		local tname = "Arcana_Sanctuary_" .. tostring(anchor)
		timer.Create(tname, tick, math.ceil(duration / tick), function()
			if not IsValid(anchor) then return end

			for _, ent in ipairs(ents.FindInSphere(center, radius)) do
				if not IsValid(ent) then continue end

				-- Players and NPCs (and NextBots if SetHealth exists)
				local isActor = ent:IsPlayer() or ent:IsNPC() or (ent.IsNextBot and ent:IsNextBot())
				if not isActor then continue end

				local max = ent.GetMaxHealth and ent:GetMaxHealth() or 100
				local cur = ent.Health and ent:Health() or max
				if cur <= 0 or cur >= max then continue end

				local new = math.min(max, cur + healPerTick)
				if ent.SetHealth then ent:SetHealth(new) end

				-- Gentle band on healed target
				Arcane:SendAttachBandVFX(ent, Color(120, 255, 140, 255), 22, 0.6, {
					{ radius = 14, height = 3, spin = { p = 0, y = 35, r = 0 }, lineWidth = 2 }
				})
			end

			-- Small restorative pulse effect
			local ed = EffectData()
			ed:SetOrigin(center)
			util.Effect("cball_explode", ed, true, true)
			if CurTime() >= endTime then
				timer.Remove(tname)
				if IsValid(anchor) then anchor:Remove() end
			end
		end)

		-- Area VFX band(s)
		timer.Simple(0.1, function()
			Arcane:SendAttachBandVFX(anchor, Color(120, 255, 140, 255), radius * 0.9, duration, {
				{ radius = radius * 0.75, height = 6, spin = { p = 0, y = 28, r = 0 }, lineWidth = 3 },
				{ radius = radius * 0.45, height = 4, spin = { p = 0, y = -24, r = 0 }, lineWidth = 2 }
			})
		end)

		-- Soothing, divine hum
		local hum = CreateSound(anchor, "ambient/levels/citadel/field_loop1.wav")
		if hum then hum:Play() hum:ChangeVolume(0.6, 0) hum:ChangePitch(120, 0) end
		timer.Simple(duration, function()
			if IsValid(anchor) then
				if hum then hum:Stop() end
				anchor:Remove()
			end
		end)

		return true
	end,
	trigger_phrase_aliases = {
		"sanctuary",
		"healing field",
	}
})


