-- Arcana Core — bootstrap, config, spell registration, casting flow, and networking.
--
-- Naming convention:
--   PascalCase  → public Arcana.* namespace members (methods, tables, API constants)
--                 e.g. Arcana:RegisterSpell, Arcana.PlayerData, Arcana.RunHook
--   camelCase   → module-private helpers and local functions
--                 e.g. broadcastCastStart, validateCostForSpell, buildDamageInfo
--
-- Peer modules (included by init.lua after this file):
--   arcana/persistence.lua       — Player data storage, SQL, SyncPlayerData, lifecycle hooks
--   arcana/xp.lua                — GiveXP, LevelUp, UnlockSpell, knowledge point accessors
--   arcana/enchantments_api.lua  — RegisterEnchantment, Apply/Remove, SyncWeaponEnchantNW
--   arcana/damage.lua            — BlastDamage, TakeDamageInfo, IsPotentialCheater
--   arcana/map_setup.lua         — Altar/portal spawning (server-topology-specific)
--   arcana/vfx_network.lua       — Band VFX broadcast + all cast-circle/gesture client receivers
--   arcana/quickslots.lua        — Quickslot server handlers with debounced saves
--   arcana/lifecycle.lua         — PlayerInitialSpawn/Death/Disconnect hooks
--
-- NOTE: Arcana.Circle (circles.lua) is loaded AFTER core.lua by init.lua, so file-scope local
-- aliases like `local MagicCircle = Arcana.Circle.MagicCircle` would be nil at load time.
-- Any code in core.lua that needs circle types must access them inline via Arcana.Circle.*
-- inside function bodies, where they are guaranteed to be available at call time.

local Arcana = _G.Arcana or {}
_G.Arcana = Arcana

function Arcana:Print(...)
	MsgC(Color(147, 112, 219), "[Arcana] ", Color(255, 255, 255), table.concat({...}, " "), "\n")
end

local function runHook(name, ...)
	local success, a, b, c, d, e, f = xpcall(hook.Run, function(err)
		ErrorNoHalt(debug.traceback(err))
	end, "Arcana_" .. name, ...)

	if not success then return nil end
	return a, b, c, d, e, f
end

Arcana.RunHook = runHook

-- Client-side stub for autocomplete and help so players see the command
if CLIENT then
	local function arcanaAutoComplete(cmd, stringargs)
		local input = string.lower(string.Trim(stringargs or ""))
		local out = {}

		for id, sp in pairs(Arcana and Arcana.RegisteredSpells or {}) do
			local idLower = string.lower(id)
			local nameLower = string.lower(sp.name or id)

			if input == "" or string.find(idLower, input, 1, true) or string.find(nameLower, input, 1, true) then
				out[#out + 1] = cmd .. " " .. id
			end
		end

		table.sort(out)

		return out
	end

	-- Forward to server so typing in client console still works
	concommand.Add("arcana", function(_, _, args)
		local raw = tostring(args and args[1] or "")
		local spellId = string.lower(string.Trim(raw))

		if spellId == "" then
			Arcana:Print("Usage: arcana <spellId>")

			return
		end

		net.Start("Arcana_ConsoleCastSpell")
		net.WriteString(spellId)
		net.SendToServer()
	end, arcanaAutoComplete, "Cast an Arcana spell: arcana <spellId>")
end

-- Configuration
Arcana.Config = {
	KNOWLEDGE_POINTS_PER_LEVEL = 1,
	MAX_LEVEL = 100,
	-- Full XP is awarded at this cast time; shorter casts scale down, longer casts scale up (clamped)
	XP_BASE_CAST_TIME = 1.0,
	-- XP gained per successful enchantment application (applied per enchant)
	XP_PER_ENCHANT_SUCCESS = 20,
	-- Spell Configuration
	DEFAULT_SPELL_COOLDOWN = 1.0,
	RITUAL_CASTING_TIME = 10.0,
}

-- Visual Configuration
Arcana.RUNIC_FONT = "Pulsian" -- The base font to use for all runic/mystical text

-- Storage for registered spells
Arcana.RegisteredSpells = Arcana.RegisteredSpells or {}
Arcana.PlayerData = Arcana.PlayerData or {}
-- Storage for registered weapon enchantments
Arcana.RegisteredEnchantments = Arcana.RegisteredEnchantments or {}

-- Spell cost types
Arcana.COST_TYPES = {
	COINS = "coins",
	HEALTH = "health",
	ITEMS = "items"
}

-- Spell/Ritual categories
Arcana.CATEGORIES = {
	COMBAT = "combat",
	UTILITY = "utility",
	PROTECTION = "protection",
	SUMMONING = "summoning",
	DIVINATION = "divination",
	ENCHANTMENT = "enchantment"
}

-- Persistence (player data, SQL, SyncPlayerData, SendErrorNotification) → arcana/persistence.lua
-- XP/leveling (GetXPRequiredForLevel, GiveXP, LevelUp, UnlockSpell, etc.) → arcana/xp.lua
-- Enchantment API → arcana/enchantments_api.lua
-- Damage utils → arcana/damage.lua

-- Interrupt an ongoing spell cast
function Arcana:InterruptSpell(ply, spellId)
	if not IsValid(ply) then return false end

	local pdata = self:GetPlayerData(ply)
	if not pdata then return false end

	-- Check if player is actually casting this spell
	if pdata.casting_spell ~= spellId then return false end

	-- Clear casting state
	pdata.casting_until = nil
	pdata.casting_spell = nil

	-- Cancel the pending cast timer (server-side)
	if SERVER then
		local timerName = "Arcana_CastSpell_" .. ply:SteamID64() .. "_" .. spellId
		timer.Remove(timerName)

		-- Notify clients to fail the spell visuals
		net.Start("Arcana_SpellFailed", true)
		net.WriteEntity(ply)
		net.WriteString(spellId)
		net.WriteFloat(0)
		net.Broadcast()
	end

	-- Run the failure hook
	runHook("CastSpellFailure", ply, spellId)

	return true
end

-- Construct a fully-specified spell context.
-- All fields are documented here; callers and spell cast() functions should rely
-- on this constructor rather than building ad-hoc tables.
--   circlePos      (Vector)  : world position of the casting circle
--   circleAng      (Angle)   : orientation of the casting circle
--   circleSize     (number)  : radius in world units of the casting circle
--   forwardLike    (Vector)  : normalised aim direction at cast start
--   castTime       (number)  : total cast duration in seconds
--   casterEntity   (Entity)  : the entity representing the caster (default: ply)
function Arcana.NewSpellContext(opts)
	opts = opts or {}
	return {
		circlePos    = opts.circlePos    or Vector(0, 0, 0),
		circleAng    = opts.circleAng    or Angle(0, 0, 0),
		circleSize   = opts.circleSize   or 60,
		forwardLike  = opts.forwardLike  or Vector(1, 0, 0),
		castTime     = opts.castTime     or 1,
		casterEntity = opts.casterEntity or NULL,
	}
end

-- Begin casting with a minimum cast time and broadcast evolving circle
-- Broadcast gesture + circle start to all clients so they can display the cast animation.
local function broadcastCastStart(ply, spellId, castTime, forwardLike)
	local gesture = forwardLike and ACT_SIGNAL_FORWARD or ACT_GMOD_GESTURE_BECON
	net.Start("Arcana_PlayCastGesture", true)
	net.WriteEntity(ply)
	net.WriteInt(gesture, 16)
	net.Broadcast()

	net.Start("Arcana_BeginCasting", true)
	net.WriteEntity(ply)
	net.WriteString(spellId)
	net.WriteFloat(castTime)
	net.WriteBool(forwardLike)
	net.Broadcast()
end

-- Schedule the deferred spell execution after the cast wind-up timer elapses.
local function scheduleCastExecution(self, ply, spellId, spell, castTime, forwardLike)
	local timerName = "Arcana_CastSpell_" .. ply:SteamID64() .. "_" .. spellId
	timer.Create(timerName, castTime, 1, function()
		if not IsValid(ply) then return end

		-- Clear casting lock before final validation and execution
		local d = self:GetPlayerData(ply)
		if d then
			d.casting_until = nil
			d.casting_spell = nil
		end

		-- Re-check conditions at actual cast moment (player may have moved, died, etc.)
		local ok, _ = self:CanCastSpell(ply, spellId)
		if not ok then
			net.Start("Arcana_SpellFailed", true)
			net.WriteEntity(ply)
			net.WriteString(spellId)
			net.WriteFloat(castTime)
			net.Broadcast()
			runHook("CastSpellFailure", ply, spellId)
			return
		end

		-- Recompute circle context at actual cast moment so it follows the player
		local ctxPos = ply:GetPos() + Vector(0, 0, 2)
		local ctxAng = Angle(0, 180, 180)
		local ctxSize = 60

		if forwardLike then
			local maxsNow = ply:OBBMaxs()
			local eyePos = ply:EyePos()
			local eyeAng = ply:EyeAngles()
			local eyeFwd = eyeAng:Forward()
			local dist = maxsNow.x * 2.5
			local tr = util.TraceLine({ start = eyePos, endpos = eyePos + eyeFwd * dist, filter = ply, mask = MASK_SOLID_BRUSHONLY })
			ctxPos = tr.Hit and (tr.HitPos - eyeFwd * 2) or (eyePos + eyeFwd * dist)
			ctxAng = eyeAng
			ctxAng:RotateAroundAxis(ctxAng:Right(), 90)
			ctxSize = 30
		end

		self:CastSpell(ply, spellId, spell.has_target, Arcana.NewSpellContext({
			circlePos = ctxPos,
			circleAng = ctxAng,
			circleSize = ctxSize,
			forwardLike = forwardLike,
			castTime = castTime,
			casterEntity = ply,
		}))
	end)
end

function Arcana:StartCasting(ply, spellId)
	if not IsValid(ply) then return false end
	local canCast, reason = self:CanCastSpell(ply, spellId)
	if not canCast then
		if SERVER then
			Arcana:SendErrorNotification(ply, "Cannot cast spell \"" .. spellId .. "\": " .. reason)
		end

		return false
	end

	local spell = self.RegisteredSpells[spellId]
	local castTime = math.max(0.1, spell.cast_time or 0)
	local pdata = self:GetPlayerData(ply)
	if pdata then
		pdata.casting_until = CurTime() + castTime
		pdata.casting_spell = spellId
	end

	runHook("BeginCasting", ply, spellId)

	if SERVER then
		local forwardLike = spell.cast_anim == "forward" or spell.is_projectile or spell.has_target or ((spell.range or 0) > 0)
		broadcastCastStart(ply, spellId, castTime, forwardLike)
		scheduleCastExecution(self, ply, spellId, spell, castTime, forwardLike)
	end

	return true
end

-- XP and Leveling System
-- GiveXP, CalculateLevel, LevelUp → arcana/xp.lua

-- Spell Registration API
function Arcana:RegisterSpell(spellData)
	if not spellData.id or not spellData.name or not spellData.cast then
		ErrorNoHalt("Spell registration requires id, name, and cast function")

		return false
	end

	-- Default values
	local spell = {
		id = spellData.id,
		name = spellData.name,
		description = spellData.description or "A mysterious spell",
		category = spellData.category or Arcana.CATEGORIES.UTILITY,
		level_required = spellData.level_required or 1,
		knowledge_cost = spellData.knowledge_cost or 1,
		cooldown = spellData.cooldown or Arcana.Config.DEFAULT_SPELL_COOLDOWN,
		cost_type = spellData.cost_type or Arcana.COST_TYPES.COINS,
		cost_amount = spellData.cost_amount or 10,
		cast_time = spellData.cast_time or 0, -- Instant by default
		range = spellData.range or 500,
		icon = spellData.icon or "icon16/wand.png",
		-- Divine Pacts: special category of powerful spells unlocked at certain levels
		is_divine_pact = spellData.is_divine_pact or false,
		-- Rituals: special category of spells that create ritual entities
		is_ritual = spellData.is_ritual or false,
		-- Functions
		-- cast(caster, has_target, data, context) where has_target is bool (cast intent, not an entity)
		cast = spellData.cast,
		-- can_cast(caster, has_target, data) -> (bool, reason) - optional pre-cast validation
		can_cast = spellData.can_cast,
		on_success = spellData.on_success, -- function(caster, has_target, data, context) - optional callback
		on_failure = spellData.on_failure, -- function(caster, has_target, data, context) - optional callback
		-- Animation hints -- If provided, these help decide which player gesture to play during casting
		is_projectile = spellData.is_projectile, -- boolean
		has_target = spellData.has_target, -- boolean (clear aimed target/point)
		cast_anim = spellData.cast_anim -- optional explicit act name, e.g., "forward" or "becon"

	}

	self.RegisteredSpells[spell.id] = spell
	if CLIENT and Arcana.AddTriggerPhrase then
		Arcana:AddTriggerPhrase(spell.name, spell.id)

		if istable(spellData.trigger_phrase_aliases) then
			for _, phrase in ipairs(spellData.trigger_phrase_aliases) do
				Arcana:AddTriggerPhrase(phrase, spell.id)
			end
		end
	end

	if isfunction(spellData.on_register) then
		spellData.on_register(spell)
	end

	self:Print("Registered spell '" .. spell.name .. "' (ID: " .. spell.id .. "')\n")
	return true
end

function Arcana:RegisterRitualSpell(opts)
	if not istable(opts) then
		ErrorNoHalt("RegisterRitualSpell requires an options table\n")
		return false
	end

	local id = opts.id
	local name = opts.name

	if not id or not name then
		ErrorNoHalt("RegisterRitualSpell requires id and name\n")
		return false
	end

	local function defaultCanCast(caster)
		if not IsValid(caster) then return false, "Invalid caster" end

		return true
	end

	local function ritualCast(caster, _, _, ctx)
		if CLIENT then return true end
		if not IsValid(caster) then return false end

		local srcEnt = IsValid(ctx.casterEntity) and ctx.casterEntity or caster
		local eye = srcEnt.EyeAngles and srcEnt:EyeAngles() or srcEnt:GetAngles()
		local pos = srcEnt.GetEyeTrace and srcEnt:GetEyeTrace().HitPos or util.TraceLine({
			start = srcEnt:WorldSpaceCenter(),
			endpos = srcEnt:WorldSpaceCenter() + srcEnt:GetForward() * 1000,
			filter = {srcEnt, caster}
		}).HitPos

		local ent = ents.Create("arcana_ritual")
		if not IsValid(ent) then return false end

		ent:SetPos(pos)
		ent:SetAngles(Angle(0, eye.y, 0))

		if IsColor(opts.ritual_color) then
			ent:SetColor(opts.ritual_color)
		end

		ent:Spawn()
		ent:Activate()

		if ent.CPPISetOwner then
			ent:CPPISetOwner(caster)
		end

		local cfg = {
			id = id,
			owner = caster,
			lifetime = tonumber(opts.ritual_lifetime) or 300,
			coin_cost = tonumber(opts.ritual_coin_cost) or 1000,
			items = istable(opts.ritual_items) and opts.ritual_items or {},
			on_activate = nil,
		}

		-- Wrap on_activate to provide a stable signature and access to caster
		if isfunction(opts.on_activate) then
			local userFn = opts.on_activate

			cfg.on_activate = function(selfEnt, activatingPly)
				userFn(selfEnt, activatingPly, caster)
			end
		end

		-- Allow caller to mutate/replace the config before applying
		if isfunction(opts.build_config) then
			local ok, newCfg = pcall(opts.build_config, cfg, caster)

			if ok and istable(newCfg) then
				cfg = newCfg
			end
		end

		if ent.Configure then
			ent:Configure(cfg)
		end

		return true
	end
	-- Animation hints for casting visuals

	return self:RegisterSpell({
		id = id,
		name = name,
		description = opts.description or "A powerful ritual",
		category = opts.category or self.CATEGORIES.UTILITY,
		level_required = tonumber(opts.level_required) or 1,
		knowledge_cost = tonumber(opts.knowledge_cost) or 1,
		cooldown = tonumber(opts.cooldown) or self.Config.DEFAULT_SPELL_COOLDOWN,
		cost_type = opts.cost_type or self.COST_TYPES.COINS,
		cost_amount = tonumber(opts.cost_amount) or 100,
		cast_time = tonumber(opts.cast_time) or 10,
		has_target = opts.has_target == true and true or false,
		cast_anim = opts.cast_anim or "becon",
		can_cast = opts.can_cast or defaultCanCast,
		cast = ritualCast,
		is_projectile = false,
		is_ritual = true,
	})
end

-- Coin spells with cost above this threshold refuse to fall back to health payment.
-- Prevents high-cost coin spells from being lethal when the player is broke.
local COIN_COST_HEALTH_FALLBACK_LIMIT = 100

local function buildDamageInfo(ply, amount)
	local dmg = DamageInfo()
	dmg:SetDamage(amount)
	dmg:SetAttacker(IsValid(ply) and ply or game.GetWorld())
	dmg:SetInflictor(IsValid(ply:GetActiveWeapon()) and ply:GetActiveWeapon() or ply)
	dmg:SetDamageType(bit.bor(DMG_GENERIC, DMG_DIRECT))
	return dmg
end

-- Pure feasibility gate — reads state, never mutates. Returns false when the cast must be blocked.
local function validateCostForSpell(ply, spell)
	if spell.cost_type == Arcana.COST_TYPES.COINS then
		if Arcana:GetCoins(ply) < spell.cost_amount then
			-- High-cost coin spells cannot fall back to health; block early.
			if spell.cost_amount > COIN_COST_HEALTH_FALLBACK_LIMIT then
				return false, "Insufficient coins"
			end
		end
	end
	return true
end

-- Spell Casting System
function Arcana:CanCastSpell(ply, spellId)
	if not ply:Alive() then return false, "You are dead" end
	local spell = self.RegisteredSpells[spellId]
	if not spell then return false, "Spell not found" end

	local data = self:GetPlayerData(ply)
	if not data then return false, "Player data not loaded" end
	-- Block re-casting while a previous cast is still winding up
	if data.casting_until and data.casting_until > CurTime() then
		return false, "Already casting"
	end

	-- Check if spell is unlocked
	if not data.unlocked_spells[spellId] then return false, "Spell not unlocked" end

	-- Check level requirement
	if data.level < spell.level_required then return false, "Insufficient level" end

	-- Check cooldown
	local cooldownKey = spellId
	if data.spell_cooldowns[cooldownKey] and data.spell_cooldowns[cooldownKey] > CurTime() then return false, "Spell on cooldown" end

	-- Cost feasibility: high-cost coin spells block when the player can't afford them and the
	-- amount exceeds COIN_COST_HEALTH_FALLBACK_LIMIT (100). Lower amounts fall back to health.
	local costOk, costReason = validateCostForSpell(ply, spell)
	if not costOk then return false, costReason end

	-- Custom validation
	if spell.can_cast then
		local canCast, reason = spell.can_cast(ply, nil, data)
		if not canCast then return false, reason or "Cannot cast spell" end
	end

	local ok, reason = runHook("CanCastSpell", ply, spellId)
	if ok == false then return false, reason or "Cannot cast spell" end

	return true
end

-- Band VFX API (SendAttachBandVFX, ClearBandVFX) → arcana/vfx_network.lua

-- Side-effect mutator — deducts cost. Called only after validateCostForSpell has passed.
local function applyCostForSpell(ply, spell)
	local takeDamageInfo = ply.ForceTakeDamageInfo or ply.TakeDamageInfo
	if spell.cost_type == Arcana.COST_TYPES.COINS then
		if Arcana:GetCoins(ply) >= spell.cost_amount then
			Arcana:TakeCoins(ply, spell.cost_amount, "Spell: " .. spell.name)
		else
			-- Affordable-range coin shortfall: fall back to health damage
			takeDamageInfo(ply, buildDamageInfo(ply, spell.cost_amount))
		end
	elseif spell.cost_type == Arcana.COST_TYPES.HEALTH then
		takeDamageInfo(ply, buildDamageInfo(ply, spell.cost_amount))
	end
end

-- castInfo = { spellId, spell, has_target, context }
local function handleSpellResult(self, ply, data, castInfo, success)
	local spellId = castInfo.spellId
	local spell = castInfo.spell
	local has_target = castInfo.has_target
	local context = castInfo.context
	if success then
		local baseCast = math.max(0.1, Arcana.Config.XP_BASE_CAST_TIME or 1.0)
		local castTime = math.max(0.05, tonumber(spell.cast_time) or 0)
		local ratio = math.Clamp(castTime / baseCast, 0.001, 2.0)
		local xpGain = math.floor(math.max(20, (tonumber(spell.knowledge_cost) or 1) * 10) * ratio)
		self:GiveXP(ply, xpGain, "Cast " .. spell.name)

		if spell.on_success then
			spell.on_success(ply, has_target, data, context)
		end

		if SERVER then
			-- Fire hook so optional subsystems (e.g. ManaCrystals) can react without core.lua knowing their API.
			local ctxPos = (context and context.circlePos) or (IsValid(ply) and (ply:GetPos() + Vector(0, 0, 2))) or nil
			if ctxPos then
				local reportContext = table.Copy(context or {})
				reportContext.cooldown = spell.cooldown or Arcana.Config.DEFAULT_SPELL_COOLDOWN or 1.0
				runHook("SpellCastSucceeded", ply, spellId, ctxPos, reportContext)
			end
		end
	else
		if spell.on_failure then
			spell.on_failure(ply, has_target, data, context)
		end

		runHook("CastSpellFailure", ply, spellId, has_target, data, context)

		if SERVER then
			net.Start("Arcana_SpellFailed", true)
			net.WriteEntity(ply)
			net.WriteString(spellId)
			net.WriteFloat((context and context.castTime) or 0)
			net.Broadcast()
		end
	end
end

function Arcana:CastSpell(ply, spellId, has_target, context)
	if not IsValid(ply) then return false end
	local canCast, reason = self:CanCastSpell(ply, spellId)

	if not canCast then
		if SERVER then
			Arcana:SendErrorNotification(ply, "Cannot cast spell \"" .. spellId .. "\": " .. reason)
		end

		return false
	end

	local spell = self.RegisteredSpells[spellId]
	local data = self:GetPlayerData(ply)

	-- Cost validation was already performed by CanCastSpell; this only deducts.
	applyCostForSpell(ply, spell)

	data.spell_cooldowns[spellId] = CurTime() + spell.cooldown

	local castInfo = { spellId = spellId, spell = spell, has_target = has_target, context = context }

	local castOk, castResult = xpcall(function()
		return spell.cast(ply, has_target, data, context)
	end, function(err)
		ErrorNoHalt("[Arcana] Error in spell.cast for '" .. spellId .. "': " .. debug.traceback(err) .. "\n")
	end)
	local success = castOk and (castResult ~= false)

	runHook("CastSpell", ply, spellId, has_target, data, context, success)
	handleSpellResult(self, ply, data, castInfo, success)

	self:SavePlayerData(ply)

	if SERVER then
		self:SyncPlayerData(ply)
	end

	return success
end

-- Knowledge System
-- CanUnlockSpell, UnlockSpell, GetLevel, GetXP, GetKnowledgePoints, HasSpellUnlocked → arcana/xp.lua

-- Networking: XPUpdate/LevelUp/UnlockSpell → arcana/xp.lua
--             FullSync/ErrorNotification → arcana/persistence.lua
--             SetQuickslot/SetSelectedQuickslot → arcana/quickslots.lua

if SERVER then
	util.AddNetworkString("Arcana_BeginCasting")
	util.AddNetworkString("Arcana_PlayCastGesture")
	util.AddNetworkString("Arcana_SpellFailed")
	util.AddNetworkString("Arcana_AttachBandVFX")
	util.AddNetworkString("Arcana_ClearBandVFX")
	util.AddNetworkString("Arcana_ConsoleCastSpell")

	-- Handle client-forwarded console cast: "arcana <spellId>"
	net.Receive("Arcana_ConsoleCastSpell", function(_, ply)
		if not IsValid(ply) then return end
		local raw = net.ReadString() or ""
		local spellId = string.lower(string.Trim(raw))
		if spellId == "" then return end
		local canCast, reason = Arcana:CanCastSpell(ply, spellId)

		if not canCast then
			Arcana:SendErrorNotification(ply, "Cannot cast spell \"" .. spellId .. "\": " .. reason)

			return
		end

		Arcana:StartCasting(ply, spellId)
	end)
end

-- Client-side VFX receivers (BeginCasting, SpellFailed, PlayCastGesture, BandVFX) → arcana/vfx_network.lua
-- Player lifecycle hooks (PlayerInitialSpawn, SetupMove, PlayerDeath, PlayerDisconnected) → arcana/lifecycle.lua
-- Map-specific entity spawning (altar, portal) lives in arcana/map_setup.lua


-- Common position resolver for ground-targeted spells
-- Works with both players (GetEyeTrace) and entities (util.TraceLine fallback)
function Arcana:ResolveGroundTarget(caster, maxRange)
	if not IsValid(caster) then return nil end

	maxRange = maxRange or 1000

	if caster.GetEyeTrace then
		local tr = caster:GetEyeTrace()
		return tr.HitPos, tr.HitNormal
	else
		local tr = util.TraceLine({
			start = caster:WorldSpaceCenter(),
			endpos = caster:WorldSpaceCenter() + caster:GetForward() * maxRange,
			filter = {caster}
		})

		return tr.HitPos, tr.HitNormal
	end
end

-- CreateFollowingCastCircle (CLIENT helper for ground-following cast circles) → arcana/vfx_network.lua

-- Damage utilities (BlastDamage, TakeDamageInfo, IsPotentialCheater) moved to arcana/damage.lua
