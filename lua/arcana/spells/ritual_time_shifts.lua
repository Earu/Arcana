local function registerRitual(id, name, description, time, custom_color)
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

	Arcane:RegisterRitualSpell({
		id = id,
		name = name,
		description = description,
		category = Arcane.CATEGORIES.UTILITY,
		level_required = 10,
		knowledge_cost = 4,
		cooldown = 60 * 20,
		cost_type = Arcane.COST_TYPES.COINS,
		cost_amount = 100,
		cast_time = 1.5,
		cast_anim = "becon",
		ritual_color = custom_color,
		ritual_lifetime = 300,
		ritual_coin_cost = 2000,
		ritual_items = {
			battery = 1,
			radioactive = 1,
			waterbottle = 1,
		},
		on_activate = function(selfEnt)
			setTime(time)
			sound.Play("ambient/levels/canals/windchime2.wav", selfEnt:GetPos(), 70, 105, 0.6)
		end,
	})
end

-- let tod load first
hook.Add("InitPostEntity", "arcana_time_shift_rituals", function()
	registerRitual("ritual_of_night", "Ritual: Night", "A ritual that calls to the goddess of the night to summon a night sky.", 0, Color(180, 160, 255))
	registerRitual("ritual_of_day", "Ritual: Day", "A ritual that calls to the god of the day to summon a bright sky.", 12, Color(222, 198, 120))
	registerRitual("ritual_of_daybreak", "Ritual: Daybreak", "A ritual that ushers in the first light of dawn.", 3, Color(255, 210, 130))
	registerRitual("ritual_of_sunset", "Ritual: Sunset", "A ritual that calls the last light before nightfall.", 23, Color(255, 120, 90))
end)