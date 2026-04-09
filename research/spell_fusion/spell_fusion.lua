-- Arcana AI Spell Fusion
-- Dynamically generates fusion spells using the Anthropic Claude API.
-- Agent loop: generate → syntax check → LLM-as-a-Judge → retry up to MAX_ATTEMPTS.
-- Generated Lua is executed inside a setfenv sandbox on both server and client,
-- with multiplexed hook/net wrappers so the LLM never pollutes the net string pool.

local Arcana = Arcana

-- ─────────────────────────────────────────────────────────────────────────────
-- Config
-- ─────────────────────────────────────────────────────────────────────────────

local API_KEY      = _G.CLAUDE_API_KEY
local API_MODEL    = "claude-sonnet-4-6"
local JUDGE_MODEL  = "claude-sonnet-4-6"
local SPELL_IDS    = { "arcane_missiles", "fireball" }

local MAX_ATTEMPTS          = 4
local SCORE_PASS            = 7.0
local SECURITY_MIN          = 8
local FUSION_MIN            = 6     -- minimum fusion score; below this the spell is rejected regardless of overall
local THINKING_BUDGET       = 8000  -- tokens the generator can spend reasoning before writing code
local JUDGE_THINKING_BUDGET = 2000  -- smaller budget for the judge; scoring doesn't need deep reasoning

-- ─────────────────────────────────────────────────────────────────────────────
-- Fusion namespace
-- ─────────────────────────────────────────────────────────────────────────────

Arcana.Fusion         = Arcana.Fusion         or {}
Arcana.Fusion.Cleanup = Arcana.Fusion.Cleanup or {}
local Fusion          = Arcana.Fusion

-- ─────────────────────────────────────────────────────────────────────────────
-- Framework internals
-- Module-level tables shared between the framework and sandbox closures.
-- ─────────────────────────────────────────────────────────────────────────────

local _hookCallbacks  = {}   -- [event][name] = fn
local _dispatchers    = {}   -- [event] = true
local _netListeners   = {}   -- [id] = fn
local _registeredIds  = {}   -- [fusionId] = true  — tracked so CleanupAll can unregister them

-- Hook dispatcher: routes hook.Add/Remove calls from generated code through a
-- single real GMod hook per event. Return values are propagated so hooks like
-- Arcana_BeginCastingVisuals (which returns true to suppress the default circle)
-- work correctly.
local _sandboxHook = setmetatable({
	Add = function(event, name, fn)
		_hookCallbacks[event] = _hookCallbacks[event] or {}
		_hookCallbacks[event][name] = fn
		if not _dispatchers[event] then
			_dispatchers[event] = true
		hook.Add(event, "Arcana_Fusion_" .. event, function(...)
			local cbs = _hookCallbacks[event]
			if not cbs then return end
			for cbName, cb in pairs(cbs) do
				local ok, ret = pcall(cb, ...)
				if not ok then
					-- Log and remove the offending callback so it doesn't spam every frame.
					Arcana:Print(string.format(
						"[Fusion] Hook error in '%s' / '%s': %s — callback removed",
						event, tostring(cbName), tostring(ret)))
					cbs[cbName] = nil
				elseif ret ~= nil then
					return ret
				end
			end
		end)
		end
	end,
	Remove = function(event, name)
		if _hookCallbacks[event] then
			_hookCallbacks[event][name] = nil
		end
	end,
}, { __index = hook })

-- Server-to-client broadcast exposed in the sandbox (replaces net.Start/Broadcast)
Fusion.Broadcast = function(id, writeCallback)
	if not SERVER then return end
	net.Start("Arcana_FusionS2C")
	net.WriteString(id)
	local ok, err = pcall(writeCallback)
	if not ok then
		-- Abort the message — do not broadcast a half-written net buffer.
		net.Abort()
		Arcana:Print("[Fusion] Broadcast write error ('" .. tostring(id) .. "'): " .. tostring(err))
		return
	end
	net.Broadcast()
end

-- Client listener registration exposed in the sandbox (replaces net.Receive)
Fusion.Listen = function(id, callback)
	_netListeners[id] = callback
end

-- Remove all hooks, net listeners, spell registrations, and spell-specific state
-- from a previous run. Called before executing a new fusion on both server and client.
function Fusion.CleanupAll()
	-- Remove GMod hook dispatchers
	for event in pairs(_dispatchers) do
		hook.Remove(event, "Arcana_Fusion_" .. event)
	end
	_hookCallbacks = {}
	_dispatchers   = {}
	_netListeners  = {}

	-- Unregister fusion spells from Arcana on whichever realm this runs
	for id in pairs(_registeredIds) do
		Arcana.RegisteredSpells[id] = nil
		Arcana:Print("[Fusion] Unregistered spell: " .. id)
	end
	_registeredIds = {}

	-- Run LLM-generated cleanup closures (clears internal locals like render tables)
	for id, fn in pairs(Fusion.Cleanup) do
		local ok, err = pcall(fn)
		if not ok then
			Arcana:Print("[Fusion] Cleanup error ('" .. id .. "'): " .. tostring(err))
		end
		Fusion.Cleanup[id] = nil
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Sandbox — blacklist approach
-- Inherits all of _G; dangerous globals/sub-table entries are blocked via
-- __index metamethods that return nil or a helpful no-op.
-- ─────────────────────────────────────────────────────────────────────────────

local _GLOBAL_BLACKLIST = {
	RunConsoleCommand = true,
	HTTP              = true,
	CompileString     = true,
	RunString         = true,
	require           = true,
	CompileFile       = true,
	debug             = true,
}

local function _makeProxy(source, blacklist)
	return setmetatable({}, {
		__index = function(_, k)
			if blacklist[k] then return nil end
			return source[k]
		end,
	})
end

local function _CreateSandbox()
	local env = setmetatable({}, {
		__index    = function(_, k)
			if _GLOBAL_BLACKLIST[k] then return nil end
			return _G[k]
		end,
		__newindex = rawset,
	})

	env.file       = _makeProxy(file,       { Write = true, Delete = true, Append = true, Open = true })
	env.os         = { time = os.time, clock = os.clock }
	env.game       = _makeProxy(game,       { ConsoleCommand = true, CleanUpMap = true })
	env.util       = _makeProxy(util,       { AddNetworkString = true })
	env.concommand = setmetatable({ Add = function() end }, { __index = concommand })
	env.hook   = _sandboxHook
	env.net    = _makeProxy(net, { Start = true, Broadcast = true, Send = true, Receive = true })
	env.Fusion = Fusion

	-- Wrap Arcana so RegisterSpell calls are tracked for cleanup.
	env.Arcana = setmetatable({
		RegisterSpell = function(self, spellData)
			local ok = Arcana.RegisterSpell(Arcana, spellData)
			if ok and spellData and spellData.id then
				_registeredIds[spellData.id] = true
			end
			return ok
		end,
	}, { __index = Arcana })

	return env
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Spell source file lookup (server only)
-- ─────────────────────────────────────────────────────────────────────────────

local function _FindSpellSourceFile(spellId)
	local needle = '"' .. spellId .. '"'
	local files  = file.Find("arcana/spells/*.lua", "LUA")
	for _, fname in ipairs(files or {}) do
		local src = file.Read("arcana/spells/" .. fname, "LUA")
		if src and src:find(needle, 1, true) then
			return src
		end
	end
	Arcana:Print("[Fusion] Warning: source not found for spell '" .. spellId .. "'")
	return nil
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Entity source file lookup (server only)
-- Scans spell sources for ents.Create("arcana_...") and loads those SENT files.
-- ─────────────────────────────────────────────────────────────────────────────

local function _FindEntitySources(spellSources)
	local entitySources = {}
	for _, src in pairs(spellSources) do
		for className in src:gmatch('ents%.Create%s*%(%s*"(arcana_[^"]+)"') do
			if not entitySources[className] then
				local entSrc = file.Read("entities/" .. className .. ".lua", "LUA")
				if not entSrc then
					entSrc = file.Read("entities/" .. className .. "/init.lua", "LUA")
				end
				if entSrc then
					entitySources[className] = entSrc
				else
					Arcana:Print("[Fusion] Warning: entity source not found for '" .. className .. "'")
				end
			end
		end
	end
	return entitySources
end

-- ─────────────────────────────────────────────────────────────────────────────
-- System prompt — Arcana context + Fusion API only (LLM already knows GLua)
-- ─────────────────────────────────────────────────────────────────────────────

local _SYSTEM_PROMPT
local function _BuildSystemPrompt()
	if _SYSTEM_PROMPT then return _SYSTEM_PROMPT end
	_SYSTEM_PROMPT = [[You are writing a fusion spell for Arcana, a Garry's Mod magic system addon.
Players equip a Grimoire weapon, unlock spells, and cast them. Spells are registered with Arcana:RegisterSpell(def).
Your output will be compiled and executed at runtime inside a sandboxed GLua environment.

## Arcana:RegisterSpell(def) fields
- id (string, REQUIRED): unique identifier
- name (string): display name
- description (string)
- category (string): "combat", "utility", "protection", "summoning", "divination", or "enchantment"
- level_required (number): minimum player level
- knowledge_cost (number): KP cost to unlock
- cooldown (number): seconds between casts
- cost_type (string): "coins", "health", or "items"
- cost_amount (number)
- cast_time (number): wind-up in seconds
- range (number): max effective distance
- icon (string): e.g. "icon16/wand.png"
- is_projectile (bool): uses forward-aim gesture
- has_target (bool): spell aims at a target point or entity
- cast_anim (string): "forward" or "becon"
- cast(caster, has_target, data, ctx): REQUIRED — returns true on success, false on failure
- can_cast(caster, has_target, data): optional, return false to block the cast
- on_success / on_failure: optional callbacks

## SpellContext (ctx)
ctx.circlePos (Vector), ctx.circleAng (Angle), ctx.circleSize (number),
ctx.forwardLike (Vector — normalised aim direction), ctx.castTime (number), ctx.casterEntity (Entity)

## Arcana helper APIs (custom — not standard GMod)
- Arcana:BlastDamage(attacker, center, radius, baseDamage, opts)
    opts: damageType, ignoreAttacker (bool)
- Arcana:SendAttachBandVFX(ent, color, size, duration, bandConfigs, tag)
    bandConfigs: array of { radius, height, spin = { p, y, r }, lineWidth }
- Arcana:ClearBandVFX(ent, tag)
- Arcana.Common.LaunchProjectile(ent, caster, direction)
- Arcana.Common.LaunchMissiles(caster, origin, aim, opts) — opts: count, delay
- Arcana.Common.ApplyLightningChain(attacker, hitPos, opts)
    opts: baseDamage, blastRadius, chainRadius, chainDamage, maxChains, chainDelay, spawnTesla, onChain
- Arcana.Common.LightningImpactVFX(pos, normal, opts)
- Arcana.Common.SpawnTeslaBurst(pos, opts)
- Arcana.Status.Frost.Apply(ent, opts) — opts: slowMult, duration

## Arcana entity classes (ents.Create)
arcana_fireball, arcana_missile, arcana_ice_bolt,
arcana_lightning_orb, arcana_lightning_storm, arcana_blackhole, arcana_glyph_orb,
arcana_crystal_shard, arcana_portal, arcana_corrupted_area, arcana_corrupted_wisp,
arcana_corrupted_wisp_heavy, arcana_flaming_skull, arcana_soul, arcana_fairy,
arcana_skeleton, arcana_brazier, arcana_magical_mushroom, arcana_mana_crystal
All projectile entities: :LaunchTowards(dir), :SetSpellOwner(caster)

## Customising entity behaviour (instance-only — CRITICAL)
You may override methods on a spawned entity INSTANCE to change its behaviour.
NEVER touch the SENT class table — that would affect every future spawn of that class globally.

  -- CORRECT: override on the instance after ents.Create
  local ent = ents.Create("arcana_fireball")
  ent:SetSpellOwner(caster)
  function ent:Think()
      -- custom logic here
      self.BaseClass.Think(self)  -- call original if needed
  end
  ent:Spawn()
  ent:Activate()

  -- WRONG — do not do any of these:
  scripted_ents.Get("arcana_fireball").Think = function() ... end  -- modifies the class globally
  ENT.Think = function() ... end                                    -- same problem

The entity source files provided in the user message show you the existing fields, timers, and
variables you can read or call on the instance. Use them to know what state is available.

## Casting circle override (CLIENT realm, Arcana.Circle is CLIENT-only)
hook.Add("Arcana_BeginCastingVisuals", uniqueName, function(caster, spellId, castTime, forwardLike)
    if spellId ~= myId then return end
    local circle = Arcana.Circle.MagicCircle.CreateMagicCircle(pos, ang, color, intensity, size, castTime, lineWidth, seed)
    circle:StartEvolving(castTime, direction)  -- direction: 1 or -1
    caster._ArcanaCastingCircle = circle       -- required for cast failure VFX
    return true                                -- suppresses the default circle
end)

## Net API (util.AddNetworkString is NOT available — use these wrappers instead)
-- SERVER: broadcast data to all clients
Fusion.Broadcast("myEventId", function()
    net.WriteFloat(value)
    net.WriteEntity(ent)
end)

-- CLIENT: register a handler
Fusion.Listen("myEventId", function()
    local value = net.ReadFloat()
    local ent   = net.ReadEntity()
    -- populate local render tables, fire DynamicLight, ParticleEmitter, etc.
end)

hook.Add / hook.Remove work normally — all registered hooks are tracked and
cleaned up by the framework automatically when a new fusion is generated.

## Cleanup closure (MANDATORY — must be the last thing in the file)
Fusion.Cleanup["FUSION_ID"] = function()
    Arcana.RegisteredSpells["FUSION_ID"] = nil
    -- Clear module-level render tables via closure (e.g. bursts = nil, spikes = nil)
    -- timer.Remove any named timers you created
    -- Do NOT call hook.Remove or Fusion.Listen here — the framework handles them
end

## Constraints
- Output raw Lua ONLY — no markdown fences, no prose, no explanations
- Do NOT use: util.AddNetworkString, net.Start, net.Broadcast, net.Receive,
  RunConsoleCommand, HTTP, concommand.Add, CompileString, RunString,
  file.Write, file.Delete, game.ConsoleCommand, game.CleanUpMap
- cast() must return true on success, false on failure
- The spell id must be exactly the fusionId given in the user message
- Fusion.Cleanup["fusionId"] is MANDATORY]]
	return _SYSTEM_PROMPT
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Judge prompts
-- ─────────────────────────────────────────────────────────────────────────────

local _JUDGE_SYSTEM_PROMPT
local function _BuildJudgeSystemPrompt()
	if _JUDGE_SYSTEM_PROMPT then return _JUDGE_SYSTEM_PROMPT end
	_JUDGE_SYSTEM_PROMPT = [[You are a code review agent for a Garry's Mod magic spell written in GLua.
Evaluate the provided Lua code and respond with ONLY a valid JSON object.
No prose, no markdown fences, no explanation — just the raw JSON.
Score each criterion from 0 to 10.]]
	return _JUDGE_SYSTEM_PROMPT
end

local function _BuildJudgeUserMessage(code, fusionId)
	return string.format([[Evaluate this GLua spell file. The spell id must be %q.
Respond with ONLY this JSON (no markdown fences):
{
  "security":    <0-10>,
  "correctness": <0-10>,
  "quality":     <0-10>,
  "creativity":  <0-10>,
  "fusion":      <0-10>,
  "overall":     <security*0.35 + correctness*0.30 + quality*0.10 + creativity*0.10 + fusion*0.15>,
  "passed":      <true if overall >= 7.0 AND security >= 8 AND fusion >= 6, else false>,
  "feedback":    "<one actionable paragraph; empty string if passed>"
}

Scoring guide:
- security (0-10): deduct for RunConsoleCommand, HTTP, concommand.Add, file.Write/Delete,
  net.Start/Broadcast/Receive, game.ConsoleCommand — below 8 hard-fails
- correctness (0-10): correct spell id, uses Fusion.Broadcast/Listen for networking,
  has Fusion.Cleanup closure, cast() returns true/false
- quality (0-10): IsValid guards on all entity accesses, no obvious runtime errors, clean structure
- creativity (0-10): how novel, visually interesting, and fun the result is as a standalone spell
- fusion (0-10, hard-fails below 6): how faithfully BOTH component spells are combined —
    10: every component spell's core mechanic AND visual theme is clearly present and intertwined
     7: all mechanics present but one visual theme is weak or colour-only
     4: one component spell's mechanic is superficial (e.g. just a size change, just a recolour)
     1: essentially one spell with a different name; the other component is absent
  Ask yourself: if a player cast each component spell then cast this fusion, would they immediately
  recognise where each mechanic came from? If not, deduct heavily.

Code to evaluate:
%s]], fusionId, code)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- User message builder
-- ─────────────────────────────────────────────────────────────────────────────

local function _BuildUserMessage(sources, entitySources, fusionId)
	local parts = {}
	for id, src in pairs(sources) do
		table.insert(parts, "-- Component spell: " .. id .. "\n" .. src)
	end
	for className, src in pairs(entitySources) do
		table.insert(parts, "-- Entity SENT source (instance-override only): " .. className .. "\n" .. src)
	end
	table.insert(parts, string.format([[The fusion spell id must be exactly %q.

TASK — TRUE FUSION:
Study every component spell above and extract two things from each:
  1. Core mechanic — what does it do? (e.g. "spawns a ring of fire around the caster", "launches a fast piercing spear")
  2. Visual theme   — what does it look/sound like? (e.g. "orange/red fire ring", "cyan arcane bolt with trails")

The output spell MUST incorporate BOTH the mechanic AND the visual theme from EVERY component spell simultaneously.
The player must immediately recognise all parent spells in the result.

Example: ring_of_fire + arcane_spear → ring of arcane spears orbiting/firing outward from the caster
  - ring formation is taken from ring_of_fire
  - spear projectiles replace the fire, keeping the arc/spear mechanic
  - visuals blend the fire ring's orange glow with the spear's cyan arcane energy

Rules:
- DO NOT just recolour one spell and call it done.
- DO NOT ignore any component spell's core mechanic — every mechanic must be present.
- The cast function must implement the hybrid mechanic using Arcana APIs from the source files.
- Client visuals must blend both spells' colour palettes, particle styles, and light colours.
- The cast function and all client visuals must be entirely original — do not delegate to parent cast functions.

Output raw Lua only.]], fusionId))
	return table.concat(parts, "\n\n")
end

-- ─────────────────────────────────────────────────────────────────────────────
-- HTTP helper
-- ─────────────────────────────────────────────────────────────────────────────

-- thinkingBudget: number of tokens to allow for thinking, or 0/nil to disable.
local function _callAnthropic(model, system, messages, maxTokens, thinkingBudget, onSuccess, onFail)
	local budget = (thinkingBudget and thinkingBudget > 0) and thinkingBudget or nil
	local body = {
		model      = model,
		max_tokens = budget and math.max(maxTokens, budget + 1024) or maxTokens,
		system     = system,
		messages   = messages,
	}

	if budget then
		body.thinking = { type = "enabled", budget_tokens = budget }
	end

	HTTP({
		method  = "POST",
		url     = "https://api.anthropic.com/v1/messages",
		timeout = 300,  -- 5 minutes — thinking + large code generation can be slow
		headers = {
			["x-api-key"]         = API_KEY,
			["anthropic-version"] = "2023-06-01",
			["content-type"]      = "application/json",
		},
		body    = util.TableToJSON(body),
		success = function(_, rawBody)
			local decoded = util.JSONToTable(rawBody)
			if not (decoded and decoded.content) then
				onFail("Unexpected Anthropic response: " .. tostring(rawBody):sub(1, 300))
				return
			end
			-- Thinking responses interleave thinking/text blocks; find the text block.
			local text
			for _, block in ipairs(decoded.content) do
				if block.type == "text" then text = block.text; break end
			end
			if text then
				onSuccess(text)
			else
				onFail("No text block found in Anthropic response")
			end
		end,
		failed = onFail,
	})
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Fence stripping
-- ─────────────────────────────────────────────────────────────────────────────

local function _stripFences(str)
	str = str:gsub("^%s*```lua%s*\n", "")
	str = str:gsub("^%s*```%s*\n",    "")
	str = str:gsub("\n```%s*$",        "")
	str = str:gsub("```%s*$",          "")
	return str
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Execution helper
-- ─────────────────────────────────────────────────────────────────────────────

local function _executeChunk(chunk, fusionId, code)
	Fusion.CleanupAll()
	setfenv(chunk, _CreateSandbox())

	local ok, err = xpcall(chunk, function(e)
		return debug.traceback(e)
	end)

	if not ok then
		Arcana:Print("[Fusion] Runtime error: " .. tostring(err))
		return false
	end

	if not Arcana.RegisteredSpells[fusionId] then
		Arcana:Print("[Fusion] Spell did not register itself after execution.")
		return false
	end

	if not Fusion.Cleanup[fusionId] then
		Arcana:Print("[Fusion] Warning: Fusion.Cleanup closure was not defined by the generated spell.")
	end

	-- Persist the generated code so it survives map changes and can be inspected.
	if not file.IsDir("arcana_fusion", "DATA") then
		file.CreateDir("arcana_fusion")
	end
	local savePath = "arcana_fusion/" .. fusionId .. ".txt" -- cannot save .lua
	file.Write(savePath, code)
	Arcana:Print("[Fusion] Code saved to data/" .. savePath)

	net.Start("Arcana_FusionCode")
	net.WriteString(code)
	net.Broadcast()

	Arcana:Print("[Fusion] Ready! Cast with: arcana " .. fusionId)
	return true
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Agent loop (server only)
-- ─────────────────────────────────────────────────────────────────────────────

if SERVER then
	-- onSuccess(fusionId) — called when the spell passes all gates and executes successfully
	-- onFail(reason)     — called on any unrecoverable failure (no sources, max attempts, HTTP error, runtime error)
	function Fusion.Combine(spellIds, onSuccess, onFail)
		-- Gather component spell sources
		local sources = {}
		for _, id in ipairs(spellIds) do
			local src = _FindSpellSourceFile(id)
			if src then sources[id] = src end
		end

		if not next(sources) then
			local reason = "No spell sources found for the given spell IDs."
			Arcana:Print("[Fusion] " .. reason .. " Aborting.")
			if onFail then onFail(reason) end
			return
		end

		local fusionId      = "fusion_" .. os.time()
		local entitySources = _FindEntitySources(sources)
		if next(entitySources) then
			local names = {}
			for k in pairs(entitySources) do table.insert(names, k) end
			Arcana:Print("[Fusion] Entity sources found: " .. table.concat(names, ", "))
		end
		local messages = { { role = "user", content = _BuildUserMessage(sources, entitySources, fusionId) } }
		local attempt  = 0

		local function _iterate()
			if attempt >= MAX_ATTEMPTS then
				local reason = "Max attempts (" .. MAX_ATTEMPTS .. ") reached without passing validation."
				Arcana:Print("[Fusion] " .. reason)
				if onFail then onFail(reason) end
				return
			end

			attempt = attempt + 1
			Arcana:Print(string.format("[Fusion] Attempt %d/%d for %s ...", attempt, MAX_ATTEMPTS, fusionId))

			_callAnthropic(API_MODEL, _BuildSystemPrompt(), messages, 4096, THINKING_BUDGET,
				-- Generator success
				function(rawText)
					local code = _stripFences(rawText)

				-- ── Gate 1: Syntax check ──────────────────────────────────
				-- CompileString returns the error string on failure, or the compiled function on success
				local chunk = CompileString(code, "fusion_attempt_" .. attempt, false)
				if isstring(chunk) then
					local syntaxErr = chunk
					Arcana:Print(string.format(
						"[Fusion] Attempt %d — syntax error: %s",
						attempt, syntaxErr))

					table.insert(messages, { role = "assistant", content = rawText })
					table.insert(messages, { role = "user",
						content = "Your code has a Lua syntax error:\n"
						       .. syntaxErr
						       .. "\nFix it and output the corrected raw Lua only."
					})
					_iterate()
					return
				end

					-- ── Gate 2: LLM-as-a-Judge ────────────────────────────────
				_callAnthropic(
					JUDGE_MODEL,
					_BuildJudgeSystemPrompt(),
					{ { role = "user", content = _BuildJudgeUserMessage(code, fusionId) } },
					512, JUDGE_THINKING_BUDGET,
					-- Judge success
						function(judgeRaw)
							local verdict = util.JSONToTable(_stripFences(judgeRaw))

						if not verdict then
							Arcana:Print("[Fusion] Judge returned unparseable JSON — skipping gate.")
							local ok = _executeChunk(chunk, fusionId, code)
							if ok then
								if onSuccess then onSuccess(fusionId) end
							else
								if onFail then onFail("Runtime error during execution of " .. fusionId) end
							end
							return
						end

						local overall  = verdict.overall  or 0
						local security = verdict.security or 0
						local fusion   = verdict.fusion   or 0
						local passed   = verdict.passed
						            and overall  >= SCORE_PASS
						            and security >= SECURITY_MIN
						            and fusion   >= FUSION_MIN

						Arcana:Print(string.format(
							"[Fusion] Judge (attempt %d): overall=%.1f  security=%d  fusion=%d  passed=%s",
							attempt, overall, security, fusion, tostring(passed)))

						if not passed then
							local reasons = {}
							if overall  < SCORE_PASS   then table.insert(reasons, string.format("overall %.1f < %.1f", overall, SCORE_PASS)) end
							if security < SECURITY_MIN then table.insert(reasons, string.format("security %d < %d", security, SECURITY_MIN)) end
							if fusion   < FUSION_MIN   then table.insert(reasons, string.format("fusion %d < %d — not all component mechanics are present", fusion, FUSION_MIN)) end
							local feedback = tostring(verdict.feedback or "No feedback provided.")
							Arcana:Print("[Fusion] Rejected (" .. table.concat(reasons, ", ") .. ") — " .. feedback)

						table.insert(messages, { role = "assistant", content = rawText })
							local retryMsg = "A code reviewer rejected your spell (" .. table.concat(reasons, "; ") .. "):\n" .. feedback
							if fusion < FUSION_MIN then
								retryMsg = retryMsg .. "\n\nCRITICAL: The fusion score is too low. Every component spell's core mechanic must be clearly and actively present in the result — not just cosmetically. Rewrite the cast logic so both mechanics are genuinely combined."
							end
							retryMsg = retryMsg .. "\nOutput the corrected raw Lua only."
							table.insert(messages, { role = "user", content = retryMsg })
								_iterate()
								return
							end

						local ok = _executeChunk(chunk, fusionId, code)
						if ok then
							if onSuccess then onSuccess(fusionId) end
						else
							if onFail then onFail("Runtime error during execution of " .. fusionId) end
						end
					end,
					-- Judge HTTP error — skip gate rather than block indefinitely
					function(err)
						Arcana:Print("[Fusion] Judge HTTP error: " .. tostring(err) .. " — skipping gate.")
						local ok = _executeChunk(chunk, fusionId, code)
						if ok then
							if onSuccess then onSuccess(fusionId) end
						else
							if onFail then onFail("Runtime error during execution of " .. fusionId) end
						end
					end
					)
				end,
			-- Generator HTTP error
			function(err)
				local reason = "Generator HTTP error: " .. tostring(err)
				Arcana:Print("[Fusion] " .. reason)
				if onFail then onFail(reason) end
			end
			)
		end

		_iterate()
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Net strings + receivers
-- ─────────────────────────────────────────────────────────────────────────────

if SERVER then
	util.AddNetworkString("Arcana_FusionS2C")
	util.AddNetworkString("Arcana_FusionCode")
end

if CLIENT then
	-- Receive the generated spell code and run it in a fresh sandbox
	net.Receive("Arcana_FusionCode", function()
		local code  = net.ReadString()
		local chunk = CompileString(code, "fusion_spell_client", false)
		if isstring(chunk) then
			Arcana:Print("[Fusion] Client compile error: " .. chunk)
			return
		end
		Fusion.CleanupAll()
		setfenv(chunk, _CreateSandbox())
		xpcall(chunk, function(e)
			Arcana:Print("[Fusion] Client runtime error: " .. debug.traceback(e))
		end)
	end)

	-- Multiplexed S2C data stream — dispatch to the registered Fusion.Listen callback
	net.Receive("Arcana_FusionS2C", function()
		local id = net.ReadString()
		local cb = _netListeners[id]
		if cb then
			local ok, err = pcall(cb)
			if not ok then
				Arcana:Print("[Fusion] Listen callback error (" .. id .. "): " .. tostring(err))
			end
		end
	end)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Dev trigger — fires once on server map load
-- ─────────────────────────────────────────────────────────────────────────────

if SERVER then
	Fusion.Combine(SPELL_IDS,
		function(fusionId)
			Arcana:Print("[Fusion] SUCCESS — spell ready: " .. fusionId)
		end,
		function(reason)
			Arcana:Print("[Fusion] FAILED — " .. reason)
		end
	)
end