-- Arcana NPC Mages: an NPC handed a grimoire rolls an elemental speciality and
-- generates its own crafted spells through the spellcraft catalog, then fights with them.
--
-- SHARED : the speciality table (the client reads it to tint cast circles).
-- SERVER : spellbook generation, the combat think loop, and the cast pipeline.
--
-- NPCs have no player data: no unlocked spells, no knowledge level, no coins, no XP,
-- so none of Arcana.StartCasting/CastSpell applies here. What is reused instead is the
-- spellcraft interpreter: Arcana.Spellcraft.Compile turns a random {form, essence,
-- clauses} definition into a compiled spell, and Arcana.Spellcraft.Execute casts it for
-- any entity. Both are already caster-agnostic, so a mage needs no registered spell id.
--
-- NOTE: arcana/system/* is included before arcana/spellcraft/*, so Arcana.Spellcraft
-- must be read inside function bodies: a file-scope alias would be nil at load time.
-- Same gotcha core.lua documents for Arcana.Circle.

Arcana = Arcana or {}
Arcana.NPC = Arcana.NPC or {}

local NPCMage = Arcana.NPC

-- Networked so clients can colour a mage's cast circle by its element.
NPCMage.SCHOOL_NW = "ArcanaSchool"

-- Specialities an NPC may roll, weighted. Ids are Arcana.Spellcraft.Essences ids, so
-- label, colour, damage type and rider all come from the taxonomy players already learn.
-- Aurum is the Golden Sun's bargain rather than a gift, so it stays out of the roll.
NPCMage.Schools = {
	fire = 3,
	arcane = 3,
	frost = 2,
	lightning = 2,
	earth = 2,
	wind = 1,
	poison = 1,
}

if SERVER then
	-- npc Entity → { wep, school, book, cooldowns, castingUntil, queued, nextThink, timerName }
	local mages = {}

	local THINK_INTERVAL = 0.25

	-- Power budget a generated spell may spend. A form costs 20-25 points and an essence
	-- 8, so this leaves room for roughly two modifiers, and it is the only damage knob
	-- a mage has, since Compile derives everything else from the definition.
	local SPELL_BUDGET = 48
	local SPELLBOOK_SIZE = 3

	-- Generated spells cast at player speed; a mage winds up far slower so the cast is
	-- telegraphed and dodgeable, the same trade the Skeleton Lich makes.
	local CAST_TIME_MULT = 2.5
	local COOLDOWN_MULT = 1.5

	-- Bolt is weighted heaviest: a thrown projectile reads clearly at a distance and is
	-- the easiest cast for a player to see coming and dodge.
	local FORM_WEIGHTS = {
		bolt = 5,
		aoe = 2,
		beam = 2,
		self = 1,
	}

	local OFFENSIVE_FORM_WEIGHTS = {
		bolt = 5,
		aoe = 2,
		beam = 2,
	}

	-- Haste only ever applies to players (P.CastSelf guards it), so rolling it on an NPC
	-- would burn budget for nothing.
	local CLAUSE_BLACKLIST = {
		haste = true,
	}

	local function pickWeighted(weights)
		local total = 0
		for _, weight in pairs(weights) do
			total = total + weight
		end

		if total <= 0 then return nil end

		local roll = math.random() * total
		for id, weight in SortedPairs(weights) do
			roll = roll - weight
			if roll <= 0 then return id end
		end
	end

	-- Every clause repeated up to its maxRank, shuffled. Repetition in a definition's
	-- clause list *is* rank, so a shuffled bag lets a spell roll Amplify II naturally.
	local function shuffledClauseBag()
		local bag = {}

		for id, clause in pairs(Arcana.Spellcraft.Clauses) do
			if not CLAUSE_BLACKLIST[id] then
				for _ = 1, (clause.maxRank or 1) do
					bag[#bag + 1] = id
				end
			end
		end

		for i = #bag, 2, -1 do
			local j = math.random(i)
			bag[i], bag[j] = bag[j], bag[i]
		end

		return bag
	end

	--- Compile a random spell of the given essence that fits the power budget.
	-- Compile is the judge: propose a clause, keep it only if Compile still accepts the
	-- definition and the points stay under budget. Every catalog rule (onlyForm,
	-- denyForm, denyEssence, conflicts, maxRank, the Homing × Widen II exclusion) is
	-- therefore enforced by the exact code the player's crafting UI obeys.
	-- @return compiled table, or nil when even the bare form + essence busts the budget.
	function NPCMage.GenerateSpell(essenceId, budget, formWeights)
		local SC = Arcana.Spellcraft
		local def = {
			form = pickWeighted(formWeights or FORM_WEIGHTS),
			essence = essenceId,
			clauses = {},
		}

		local compiled = SC.Compile(def)
		if not compiled or compiled.points > budget then return nil end

		for _, clauseId in ipairs(shuffledClauseBag()) do
			if #def.clauses >= SC.MAX_CLAUSE_SLOTS then break end

			def.clauses[#def.clauses + 1] = clauseId
			local candidate = SC.Compile(def)

			if candidate and candidate.points <= budget then
				compiled = candidate
			else
				def.clauses[#def.clauses] = nil
			end
		end

		return compiled
	end

	-- Turn a compiled spell into what the combat loop needs: pacing, an engagement
	-- window, and a stable id for the cast-circle broadcast.
	local function buildEntry(compiled)
		local castTime = math.max(0.5, compiled.castTime * CAST_TIME_MULT)
		local cooldown = math.max(2, compiled.cooldown * COOLDOWN_MULT)

		local minRange, maxRange
		if compiled.isSelf then
			-- An aura only earns its cast when the enemy is already inside it.
			minRange, maxRange = 0, math.max(160, compiled.radius * 0.8)
		else
			minRange, maxRange = 120, math.max(300, compiled.range * 0.9)
		end

		return {
			-- Only ever used as the networked spell id: the client seeds the cast circle
			-- from it, so keeping it stable per element and form keeps a mage's look
			-- consistent. Cooldowns are keyed by the entry itself, not by this.
			key = "npc_" .. compiled.essence .. "_" .. compiled.form,
			compiled = compiled,
			castTime = castTime,
			cooldown = cooldown,
			minRange = minRange,
			maxRange = maxRange,
			label = Arcana.Spellcraft.Describe(compiled),
		}
	end

	--- Generate a mage's spellbook. The first entry is always offensive so no mage can
	-- roll a book of nothing but auras.
	function NPCMage.GenerateSpellbook(essenceId, budget, count)
		local book = {}
		local hasAura = false

		for i = 1, math.max(1, count) do
			local weights = (i == 1 or hasAura) and OFFENSIVE_FORM_WEIGHTS or FORM_WEIGHTS
			local compiled = NPCMage.GenerateSpell(essenceId, budget, weights)

			if compiled then
				hasAura = hasAura or compiled.isSelf
				book[#book + 1] = buildEntry(compiled)
			end
		end

		return book
	end

	local function currentEnemy(npc)
		local enemy = npc.GetEnemy and npc:GetEnemy()
		if IsValid(enemy) and enemy:Health() > 0 then return enemy end

		return nil
	end

	-- Spells and the spellcraft interpreter reach for the caster's aim through
	-- GetAimVector/GetEyeTrace. resolveAim (spellcraft/runtime.lua) picks its branch on
	-- EyePos existing, which NPCs have, so without these a mage either errors on a
	-- missing GetAimVector or fires flat along its body forward. These are defined on
	-- the entity instance: Lua callers see the aim, the engine AI is untouched.
	local function installAimShims(npc)
		function npc:GetAimVector()
			local enemy = currentEnemy(self)
			if not enemy then return self:GetForward() end

			return (enemy:WorldSpaceCenter() - self:EyePos()):GetNormalized()
		end

		function npc:GetEyeTrace()
			local origin = self:EyePos()

			return util.TraceLine({
				start = origin,
				endpos = origin + self:GetAimVector() * 4096,
				filter = self,
				mask = MASK_SHOT,
			})
		end
	end

	local function removeAimShims(npc)
		npc.GetAimVector = nil
		npc.GetEyeTrace = nil
	end

	-- Mirrors the forward-like circle placement core.lua computes for players, so a
	-- mage's circle hangs in front of its face and the spell issues from it.
	local function castCircleTransform(npc)
		local eyePos = npc:EyePos()
		local fwd = npc:GetAimVector()
		local dist = npc:OBBMaxs().x * 2.5

		local tr = util.TraceLine({
			start = eyePos,
			endpos = eyePos + fwd * dist,
			filter = npc,
			mask = MASK_SOLID_BRUSHONLY,
		})

		local ang = fwd:Angle()
		ang:RotateAroundAxis(ang:Right(), 90)

		return tr.Hit and (tr.HitPos - fwd * 2) or (eyePos + fwd * dist), ang
	end

	local function broadcastFailed(npc, spellId, castTime)
		if not IsValid(npc) then return end

		net.Start("Arcana_SpellFailed", true)
		net.WriteEntity(npc)
		net.WriteString(spellId)
		net.WriteFloat(castTime or 0)
		net.Broadcast()
	end

	function NPCMage.IsMage(npc)
		return mages[npc] ~= nil
	end

	function NPCMage.GetSchool(npc)
		local state = mages[npc]

		return state and state.school or nil
	end

	--- Roll a speciality, generate a spellbook, and start thinking about combat.
	-- Set npc.ArcanaSchool before the grimoire is equipped to pick the element yourself.
	function NPCMage.Register(npc, wep)
		if not IsValid(npc) or not IsValid(wep) then return end
		if mages[npc] then
			-- Re-equipping keeps the mage it already is; only the weapon reference moves.
			mages[npc].wep = wep

			return
		end

		local school = isstring(npc.ArcanaSchool) and NPCMage.Schools[npc.ArcanaSchool] and npc.ArcanaSchool
		school = school or pickWeighted(NPCMage.Schools)
		if not school then return end

		local book = NPCMage.GenerateSpellbook(school, SPELL_BUDGET, SPELLBOOK_SIZE)
		if #book == 0 then return end

		installAimShims(npc)
		npc:SetNWString(NPCMage.SCHOOL_NW, school)

		mages[npc] = {
			wep = wep,
			school = school,
			book = book,
			cooldowns = {},
			castingUntil = 0,
			queued = nil,
			nextThink = CurTime() + math.Rand(0.5, 1.5),
			timerName = "Arcana_NPCMageCast_" .. npc:EntIndex(),
		}
	end

	--- Abort a wind-up in progress: kills the pending cast and breaks down the circle.
	function NPCMage.Cancel(npc)
		local state = mages[npc]
		if not state then return end

		timer.Remove(state.timerName)

		local entry = state.queued
		state.queued = nil
		state.castingUntil = 0

		if entry then
			broadcastFailed(npc, entry.key, entry.castTime)
			Arcana.RunHook("CastSpellFailure", npc, entry.key)
		end
	end

	function NPCMage.Unregister(npc)
		if not mages[npc] then return end

		NPCMage.Cancel(npc)

		if IsValid(npc) then
			removeAimShims(npc)
			npc:SetNWString(NPCMage.SCHOOL_NW, "")
		end

		mages[npc] = nil
	end

	local function executeCast(npc, entry, castTime)
		local state = mages[npc]
		if not state then return end

		state.castingUntil = 0
		state.queued = nil

		if not IsValid(npc) or npc:Health() <= 0 or not IsValid(state.wep) then
			broadcastFailed(npc, entry.key, castTime)

			return
		end

		local pos, ang = castCircleTransform(npc)
		local ctx = Arcana.NewSpellContext({
			circlePos = pos,
			circleAng = ang,
			circleSize = 30,
			forwardLike = true,
			castTime = castTime,
			casterEntity = npc,
		})

		local ok, result = xpcall(function()
			return Arcana.Spellcraft.Execute(npc, entry.compiled, ctx)
		end, function(err)
			ErrorNoHalt("[Arcana] Error in NPC mage cast '" .. entry.key .. "': " .. debug.traceback(err) .. "\n")
		end)

		local success = ok and result ~= false

		Arcana.RunHook("CastSpell", npc, entry.key, entry.compiled.hasTarget, nil, ctx, success)

		if success then
			-- No mana crystal report on purpose: NPC casts must not seed farmable hotspots.
			Arcana.RunHook("SpellCastSucceeded", npc, entry.key, pos, ctx)
		else
			Arcana.RunHook("CastSpellFailure", npc, entry.key, entry.compiled.hasTarget, nil, ctx)
			broadcastFailed(npc, entry.key, castTime)
		end
	end

	function NPCMage.StartCasting(npc, entry)
		local state = mages[npc]
		if not state then return false end

		local castTime = entry.castTime
		state.castingUntil = CurTime() + castTime
		state.queued = entry
		-- Stamped at wind-up start, not on completion, so the loop cannot re-pick a
		-- spell that is still being cast.
		state.cooldowns[entry] = CurTime() + castTime + entry.cooldown

		-- Third argument is the casting entity, the contract arcana_spell_caster uses:
		-- target-scanning spells trace from the caster rather than an owner's crosshair.
		Arcana.RunHook("BeginCasting", npc, entry.key, npc)

		net.Start("Arcana_BeginCasting", true)
		net.WriteEntity(npc)
		net.WriteString(entry.key)
		net.WriteFloat(castTime)
		net.WriteBool(true)
		net.Broadcast()

		if npc.RestartGesture then
			npc:RestartGesture(ACT_GESTURE_RANGE_ATTACK1)
		end

		npc:EmitSound("arcana/arcane_" .. math.random(1, 3) .. ".ogg", 70, math.random(90, 110), 0.6)

		timer.Create(state.timerName, castTime, 1, function()
			executeCast(npc, entry, castTime)
		end)

		return true
	end

	local function selectSpell(state, distance)
		local now = CurTime()
		local eligible = {}

		for _, entry in ipairs(state.book) do
			if (state.cooldowns[entry] or 0) <= now and distance >= entry.minRange and distance <= entry.maxRange then
				eligible[#eligible + 1] = entry
			end
		end

		if #eligible == 0 then return nil end

		return eligible[math.random(#eligible)]
	end

	--- Cast at the NPC's current enemy if it has one, a line of sight, and something
	-- off cooldown that suits the range. Both the think loop and the weapon's engine
	-- fire callback come through here, so the two can never double-cast.
	function NPCMage.TryCast(npc)
		local state = mages[npc]
		if not state then return false end
		if state.castingUntil > CurTime() then return false end
		if not IsValid(npc) or npc:Health() <= 0 then return false end

		local enemy = currentEnemy(npc)
		if not enemy then return false end
		if npc.Visible and not npc:Visible(enemy) then return false end

		local entry = selectSpell(state, npc:WorldSpaceCenter():Distance(enemy:WorldSpaceCenter()))
		if not entry then return false end

		return NPCMage.StartCasting(npc, entry)
	end

	hook.Add("Think", "Arcana_NPCMages", function()
		local now = CurTime()

		for npc, state in pairs(mages) do
			if not IsValid(npc) or npc:Health() <= 0 or not IsValid(state.wep) then
				NPCMage.Unregister(npc)
			elseif now >= state.nextThink then
				state.nextThink = now + THINK_INTERVAL
				NPCMage.TryCast(npc)
			end
		end
	end)

	hook.Add("EntityRemoved", "Arcana_NPCMages", function(ent)
		NPCMage.Unregister(ent)
	end)

	hook.Add("OnNPCKilled", "Arcana_NPCMages", function(npc)
		NPCMage.Unregister(npc)
	end)

	--- The mage's spellbook: { compiled, castTime, cooldown, minRange, maxRange, label }.
	function NPCMage.GetSpellbook(npc)
		local state = mages[npc]

		return state and state.book or nil
	end
end
