local function registerRitual(id, name, description, is_night)
	if not _G.tod then return end -- dont register if tod is not loaded

	local function setTime(val)
		local time24 = val and tonumber(val) or 1

		if time24 then
			RunConsoleCommand("sv_tod", "0")
			tod.SetCycle((time24 / 24) % 1)
		elseif val == "demo" then
			RunConsoleCommand("sv_tod", "2")
		elseif val == "realtime" or time24 < 0 then
			RunConsoleCommand("sv_tod", "1")
		end

		timer.Simple(0.1, function()
			tod.SetMode(tod.cvar:GetInt())

			timer.Simple(0.5, function()
				BroadcastLua[[render.RedownloadAllLightmaps()]]
			end)
		end)
	end

	Arcane:RegisterSpell({
		id = id,
		name = name,
		description = description,
		category = Arcane.CATEGORIES.UTILITY,
		level_required = 10,
		knowledge_cost = 1,
		cooldown = 60 * 20, -- 20 minutes
		cost_type = Arcane.COST_TYPES.COINS,
		cost_amount = 100, -- cost is in the ritual requirements itself
		cast_time = 1.5,
		has_target = false,
		cast_anim = "becon",
		can_cast = function(caster)
			if not IsValid(caster) then return false, "Invalid caster" end

			return true
		end,
		cast = function(caster)
			if CLIENT then return true end
			local pos = caster:GetEyeTrace().HitPos
			local ent = ents.Create("arcana_ritual")
			if not IsValid(ent) then return false end

			ent:SetPos(pos)
			ent:SetAngles(Angle(0, caster:EyeAngles().y, 0))
			ent:SetColor(is_night and Color(180, 160, 255) or Color(222, 198, 120))
			ent:Spawn()
			ent:Activate()

			if ent.CPPISetOwner then
				ent:CPPISetOwner(caster)
			end

			ent:Configure({
				id = is_night and "ritual_of_night" or "ritual_of_day",
				owner = caster,
				lifetime = 300,
				coin_cost = 2000,
				items = {
					battery = 1,
					radioactive = 1,
					waterbottle = 1,
				},
				on_activate = function(selfEnt)
					setTime(is_night and 0 or 12)
					sound.Play("ambient/levels/canals/windchime2.wav", selfEnt:GetPos(), 70, 105, 0.6)
				end,
			})

			return true
		end,
	})
end

-- let tod load first
hook.Add("InitPostEntity", "arcana_time_shift_rituals", function()
	registerRitual("ritual_of_night", "Ritual: Night", "A ritual that calls to the goddess of the night to summon a night sky.", true)
	registerRitual("ritual_of_day", "Ritual: Day", "A ritual that calls to the god of the day to summon a bright sky.", false)
end)