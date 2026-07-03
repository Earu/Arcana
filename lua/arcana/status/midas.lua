-- Shared Midas status: the Golden Sun's bargain made manifest.
-- While cursed:
--   - Props the player grabs with the physgun/gravgun turn to solid gold:
--     they become non-physgunnable and far heavier.
--   - Weapons the player tries to pick up (outside the standard loadout)
--     never reach their hands: a golden husk of the weapon drops to the
--     ground instead and crumbles away after a moment.
--   - Either event may be accompanied by a distant, distorted laugh.
--
-- Apply with: Arcana.Status.Midas.Apply(ply) / remove with .Remove(ply)
Arcana = Arcana or {}
Arcana.Status = Arcana.Status or {}

local Midas = {}

local GOLD_MATERIAL = "models/player/shared/gold_player"
local NW_ACTIVE = "Arcana_Midas"
local NW_GOLDED = "Arcana_Midased"

local GOLD_MASS_MULT = 50
local GOLD_MASS_MIN = 5000
local GOLD_MASS_MAX = 50000 -- Source's physics mass ceiling

local HUSK_LIFETIME = 2 -- Seconds before a golden weapon husk starts crumbling
local HUSK_FADE_TIME = 0.8

-- A picked-up weapon gilds in the player's hands for this long before it drops
local WEAPON_GILD_TIME = 1

local LAUGH_CHANCE = 0.35
local LAUGH_COOLDOWN = 4 -- Minimum seconds between laughs (per player)
-- The laugh rolls in from far off, drowned in reverb
local LAUGH_DISTANCE = 550
local LAUGH_SOUNDLEVEL = 72
local LAUGH_REVERB_DSP = 14 -- Cavernous reverb preset (tweak to taste)
local LAUGH_DSP_HOLD = 4 -- Seconds to hold the reverb before restoring

-- The curse lasts one hour of real time. The absolute expiry is persisted per
-- player (via PData) so it keeps counting down across disconnects and cannot be
-- reset or shed by reconnecting; the session timer is only a live convenience.
local MIDAS_DURATION = 3600
local PDATA_EXPIRY = "arcana_midas_expiry"
-- Persistent "has this player ever met the Golden Sun" marker ("1" once seen)
local PDATA_MET = "arcana_met_golden_sun"

-- Weapons the curse spares: standard loadout/tooling (extend as needed)
Midas.WeaponWhitelist = {
	["weapon_physgun"] = true,
	["weapon_physcannon"] = true,
	["gmod_tool"] = true,
	["gmod_camera"] = true,
	["weapon_fists"] = true,
	["grimoire"] = true,
}

function Midas.IsActive(ply)
	return IsValid(ply) and ply:GetNW2Bool(NW_ACTIVE, false)
end

-- Set the live curse state and a session timer for the given remaining seconds.
-- Does not touch the persisted expiry (callers own that).
local function startCurse(target, remaining)
	target:SetNW2Bool(NW_ACTIVE, true)

	local timerName = "Arcana_Midas_" .. target:SteamID64()
	timer.Create(timerName, math.max(1, remaining), 1, function()
		if IsValid(target) then
			Midas.Remove(target)
		end
	end)
end

-- options: duration (seconds; defaults to MIDAS_DURATION)
function Midas.Apply(target, options)
	if not IsValid(target) or not target:IsPlayer() then return end
	if CLIENT then return end

	options = options or {}
	local duration = tonumber(options.duration) or MIDAS_DURATION

	-- Persist an absolute expiry so the curse survives reconnects and expires on schedule
	target:SetPData(PDATA_EXPIRY, os.time() + duration)
	startCurse(target, duration)
end

function Midas.Remove(target)
	if not IsValid(target) or not target:IsPlayer() then return end
	if CLIENT then return end

	target:SetNW2Bool(NW_ACTIVE, false)
	timer.Remove("Arcana_Midas_" .. target:SteamID64())
	target:RemovePData(PDATA_EXPIRY)
end

Arcana.Status.Midas = Midas

if SERVER then
	util.AddNetworkString("Arcana_Midas_Laugh")
	util.AddNetworkString("Arcana_Midas_GildViewModel")

	local function maybeLaugh(ply)
		if math.random() > LAUGH_CHANCE then return end

		-- Throttle so a flurry of transmutations doesn't stack the reverb
		local now = CurTime()
		if (ply._arcanaNextLaugh or 0) > now then return end
		ply._arcanaNextLaugh = now + LAUGH_COOLDOWN

		net.Start("Arcana_Midas_Laugh", true)
		net.Send(ply)
	end

	local function isGolded(ent)
		return IsValid(ent) and ent:GetNW2Bool(NW_GOLDED, false)
	end

	local function isProp(ent)
		return IsValid(ent) and ent:GetClass():find("^prop_physics") ~= nil
	end

	-- Ownership check: trust CPPI when available, otherwise assume the prop
	-- belongs to the player
	local function ownsProp(ply, ent)
		if ent.CPPIGetOwner then
			local owner = ent:CPPIGetOwner()

			if IsValid(owner) then
				return owner == ply
			end
		end

		return true
	end

	-- The burst of light, dust and sound as matter turns to gold.
	-- The trailing `true` bypasses the prediction filter, otherwise the acting
	-- player (grabbing with the physgun/gravgun) would never see their own effect.
	local function dispatchGoldEffect(pos, scale)
		local ed = EffectData()
		ed:SetOrigin(pos)
		ed:SetScale(scale or 1)
		util.Effect("arcana_midas_gold", ed, true, true)
	end

	local function turnPropToGold(ply, ent)
		if isGolded(ent) then return end

		ent:SetNW2Bool(NW_GOLDED, true)
		ent:SetMaterial(GOLD_MATERIAL)
		ent.PhysgunDisabled = true -- Respected by FPP and friends

		local phys = ent:GetPhysicsObject()
		if IsValid(phys) then
			phys:SetMass(math.Clamp(phys:GetMass() * GOLD_MASS_MULT, GOLD_MASS_MIN, GOLD_MASS_MAX))
		end

		dispatchGoldEffect(ent:WorldSpaceCenter(), math.Clamp(ent:BoundingRadius() / 20, 0.6, 5))
		maybeLaugh(ply)
	end

	-- Attempting to grab an owned prop transmutes it; gold is never grabbable
	local function handleGrab(ply, ent)
		if isGolded(ent) then return false end
		if not Midas.IsActive(ply) then return end
		if not isProp(ent) then return end
		if not ownsProp(ply, ent) then return end

		turnPropToGold(ply, ent)

		return false
	end

	hook.Add("PhysgunPickup", "Arcana_Midas", function(ply, ent)
		return handleGrab(ply, ent)
	end)

	hook.Add("GravGunPickupAllowed", "Arcana_Midas", function(ply, ent)
		return handleGrab(ply, ent)
	end)

	hook.Add("GravGunPunt", "Arcana_Midas", function(ply, ent)
		return handleGrab(ply, ent)
	end)

	-- Golden husk of a weapon: a gold prop dropped at pos, that then crumbles
	local function dropGoldenHusk(mdl, pos, ang)
		if not mdl or mdl == "" or not util.IsValidModel(mdl) then return end

		local husk = ents.Create("prop_physics")
		if not IsValid(husk) then return end

		husk:SetModel(mdl)
		husk:SetPos(pos)
		husk:SetAngles(ang or angle_zero)
		husk:Spawn()
		husk:SetMaterial(GOLD_MATERIAL)
		husk:SetNW2Bool(NW_GOLDED, true)
		husk.PhysgunDisabled = true
		husk:SetCollisionGroup(COLLISION_GROUP_WEAPON) -- Falls to the ground, never blocks players

		-- Crumble away after a moment
		timer.Simple(HUSK_LIFETIME, function()
			if not IsValid(husk) then return end

			husk:SetRenderMode(RENDERMODE_TRANSALPHA)
			local steps = 8

			for i = 1, steps do
				timer.Simple(HUSK_FADE_TIME * (i / steps), function()
					if not IsValid(husk) then return end

					if i == steps then
						husk:Remove()
					else
						local col = husk:GetColor()
						col.a = math.floor(255 * (1 - i / steps))
						husk:SetColor(col)
					end
				end)
			end
		end)
	end

	-- A weapon that reaches a cursed player's hands gilds before their eyes,
	-- then slips away as a golden husk a moment later.
	hook.Add("WeaponEquip", "Arcana_Midas", function(wep, owner)
		if not IsValid(wep) then return end

		local ply = IsValid(owner) and owner or wep:GetOwner()
		if not IsValid(ply) or not ply:IsPlayer() then return end
		if not Midas.IsActive(ply) then return end
		if Midas.WeaponWhitelist[wep:GetClass()] then return end
		if wep._arcanaMidasProcessed then return end

		wep._arcanaMidasProcessed = true

		local mdl = wep.WorldModel or wep:GetModel()

		-- Force it into view and gild the viewmodel client-side
		ply:SelectWeapon(wep:GetClass())
		net.Start("Arcana_Midas_GildViewModel")
		net.WriteFloat(WEAPON_GILD_TIME)
		net.Send(ply)

		-- Burst at the hands as it turns
		dispatchGoldEffect(ply:EyePos() + ply:GetAimVector() * 30 - Vector(0, 0, 6), 1)

		timer.Simple(WEAPON_GILD_TIME, function()
			if IsValid(ply) then
				local dropPos = ply:EyePos() + ply:GetAimVector() * 40 - Vector(0, 0, 10)
				dropGoldenHusk(mdl, dropPos, ply:EyeAngles())
				maybeLaugh(ply)
			end

			if IsValid(wep) then
				SafeRemoveEntity(wep)
			end
		end)
	end)

	-- =====================================================================
	-- The Golden Sun's bargain: offered when a player dies to a spell they
	-- could not afford. The very first such death always summons the Sun;
	-- every one thereafter rolls a chance.
	-- =====================================================================
	local ENCOUNTER_CHANCE = 0.15 -- Chance on deaths after the first
	local ENCOUNTER_COIN_REWARD = 25000 -- Coins granted when the deal is accepted
	local UNPAID_DEATH_WINDOW = 0.25 -- Death must follow the failed payment within this
	local ENCOUNTER_DELAY = 1.5 -- Delay after respawn before the vision takes hold

	util.AddNetworkString("Arcana_Midas_StartEncounter")
	util.AddNetworkString("Arcana_Midas_Choice")

	-- Note the instant a spell's coin cost is paid with health instead
	hook.Add("Arcana_SpellCoinShortfall", "Arcana_Midas_TrackUnpaid", function(ply, spell)
		if IsValid(ply) then
			ply._arcanaUnpaidSpellCast = CurTime()
		end
	end)

	-- If that health payment killed them, mark the Sun as pending for respawn
	hook.Add("PlayerDeath", "Arcana_Midas_Trigger", function(ply)
		if not IsValid(ply) or not ply:IsPlayer() then return end

		local t = ply._arcanaUnpaidSpellCast
		ply._arcanaUnpaidSpellCast = nil
		if not t or (CurTime() - t) > UNPAID_DEATH_WINDOW then return end

		-- Guaranteed the first time, a chance thereafter
		local firstTime = ply:GetPData(PDATA_MET, "0") ~= "1"
		if not firstTime and math.random() > ENCOUNTER_CHANCE then return end

		ply._arcanaMidasEncounterPending = true
	end)

	-- The tutorial system needs a living player, so the vision waits for respawn.
	-- The "seen" flag is only set once the vision actually reaches the player, so
	-- disconnecting between death and respawn does not burn the guaranteed first.
	hook.Add("PlayerSpawn", "Arcana_Midas_Encounter", function(ply)
		if not ply._arcanaMidasEncounterPending then return end
		ply._arcanaMidasEncounterPending = nil

		timer.Simple(ENCOUNTER_DELAY, function()
			if not IsValid(ply) or not ply:Alive() then return end

			ply:SetPData(PDATA_MET, "1")
			ply._arcanaMidasAwaitingChoice = true
			net.Start("Arcana_Midas_StartEncounter")
			net.Send(ply)
		end)
	end)

	-- Restore the curse for its remaining time when a returning player's data loads
	hook.Add("Arcana_LoadedPlayerData", "Arcana_Midas_Restore", function(ply)
		if not IsValid(ply) then return end

		local expiry = tonumber(ply:GetPData(PDATA_EXPIRY, 0)) or 0
		if expiry <= 0 then return end

		local remaining = expiry - os.time()
		if remaining <= 0 then
			ply:RemovePData(PDATA_EXPIRY)
			return
		end

		startCurse(ply, remaining)
	end)

	-- The player's answer inside the encounter; accepting seals the bargain.
	-- Gated on an outstanding offer so the choice cannot be forged for coins.
	net.Receive("Arcana_Midas_Choice", function(_, ply)
		if not IsValid(ply) then return end
		if not ply._arcanaMidasAwaitingChoice then return end
		ply._arcanaMidasAwaitingChoice = nil

		local accepted = net.ReadBool()
		if not accepted then return end

		if Arcana.GiveCoins then
			Arcana:GiveCoins(ply, ENCOUNTER_COIN_REWARD, "The Golden Sun's Bargain")
		end

		Midas.Apply(ply)
	end)
end

if CLIENT then
	-- Gild the held weapon's viewmodel while it turns to gold in the hands
	local GILD_TAG = "Arcana_Midas_GildVM"
	local goldVMMaterial = Material(GOLD_MATERIAL)
	local gildUntil = 0

	net.Receive("Arcana_Midas_GildViewModel", function()
		gildUntil = CurTime() + (net.ReadFloat() or WEAPON_GILD_TIME)

		hook.Add("PreDrawViewModel", GILD_TAG, function()
			render.MaterialOverride(goldVMMaterial)
		end)

		hook.Add("PostDrawViewModel", GILD_TAG, function()
			render.MaterialOverride(nil)

			if CurTime() > gildUntil then
				hook.Remove("PreDrawViewModel", GILD_TAG)
				hook.Remove("PostDrawViewModel", GILD_TAG)
			end
		end)
	end)

	-- Father Grigori's mad laughter, pitched into something that is not him:
	-- deep, warped, rolling in from far off and drowned in reverb.
	local LAUGHS = {
		"vo/ravenholm/madlaugh01.wav",
		"vo/ravenholm/madlaugh02.wav",
		"vo/ravenholm/madlaugh03.wav",
		"vo/ravenholm/madlaugh04.wav",
	}

	-- Delay / volume / pitch-offset per echo tap (first two = detuned double)
	local LAUGH_TAPS = {
		{0.00, 0.9, 0},
		{0.05, 0.5, 4},
		{0.34, 0.55, -3},
		{0.72, 0.36, 3},
		{1.20, 0.22, -5},
		{1.75, 0.12, 5},
	}

	net.Receive("Arcana_Midas_Laugh", function()
		local lp = LocalPlayer()
		if not IsValid(lp) then return end

		local snd = LAUGHS[math.random(#LAUGHS)]
		local basePitch = math.random(12, 20) -- deep and slowed
		local origin = lp:GetPos() + Vector(0, 0, 40)

		-- A vast, cavernous space swallows the sound while it plays
		lp:SetDSP(LAUGH_REVERB_DSP, false)
		timer.Simple(LAUGH_DSP_HOLD, function()
			if IsValid(lp) then lp:SetDSP(0, false) end
		end)

		-- Each tap is positional (real distance falloff) and detuned, so the
		-- laughter echoes back from somewhere far off as a warped choir
		for _, tap in ipairs(LAUGH_TAPS) do
			timer.Simple(tap[1], function()
				if not IsValid(lp) then return end

				local dir = VectorRand()
				dir.z = dir.z * 0.25
				dir:Normalize()

				local pos = origin + dir * LAUGH_DISTANCE
				sound.Play(snd, pos, LAUGH_SOUNDLEVEL, math.Clamp(basePitch + tap[3], 1, 255), tap[2])
			end)
		end
	end)
end
