-- Spellcraft — runtime. One generic interpreter drives every crafted spell.
--
-- SHARED : BuildSpellData (turns a compiled crafted spell into an Arcana spell),
--          net-string strings used by both realms.
-- SERVER : Execute (form dispatch), ApplyEssenceHit / AreaEssence (essence
--          riders), lingering patches, aurum branding, the burst broadcast.
-- CLIENT : the player's local definition store (data/arcana/spellcraft.json),
--          the SyncUp responder, register/unregister/state receivers, and the
--          burst VFX.

Arcana = Arcana or {}
Arcana.Spellcraft = Arcana.Spellcraft or {}
local P = Arcana.Spellcraft

P.ID_PREFIX = "spellcraft_"

function P.SpellId(sid64, slot)
	return P.ID_PREFIX .. tostring(sid64) .. "_" .. tostring(slot)
end

function P.IsSpellcraftId(id)
	return isstring(id) and string.StartsWith(id, P.ID_PREFIX)
end

-- Aurum statue constants, shared: the server brands victims and cleans up the
-- networked ragdoll shell; each client gilds the visual ragdoll it created.
local GOLD_MATERIAL = "models/player/shared/gold_player"
local GOLD_TINT = Color(255, 226, 140)
local STATUE_LIFETIME = 20
local AURUM_BRAND_NW = "ArcanaAurumBrand"

----------------------------------------------------------------------
-- Shared: build an Arcana spell table from a stored definition.
-- On the server the spell gets the real cast + eligibility check; on the client
-- it is a display stub (return true) so menus/HUD/quickslots resolve it.
----------------------------------------------------------------------
function P.BuildSpellData(sid64, slot, def, name)
	local compiled, err = P.Compile(def)
	if not compiled then return nil, err end

	local id = P.SpellId(sid64, slot)
	local cfg = P.Config()

	local spell = {
		id = id,
		name = name or "Crafted Spell",
		description = P.Describe(compiled),
		category = Arcana.CATEGORIES.COMBAT,
		level_required = cfg.minLevel,
		knowledge_cost = 0,
		cooldown = compiled.cooldown,
		cost_type = Arcana.COST_TYPES.COINS,
		cost_amount = compiled.perCastCost,
		cast_time = compiled.castTime,
		range = compiled.range,
		is_projectile = compiled.isProjectile,
		has_target = compiled.hasTarget,
		is_crafted = true,
		crafted_owner = tostring(sid64),
	}

	if SERVER then
		spell.cast = function(caster, hasTarget, data, ctx)
			return P.Execute(caster, compiled, ctx)
		end
		spell.can_cast = function(caster)
			if not IsValid(caster) or caster:SteamID64() ~= tostring(sid64) then
				return false, "This spell is not yours"
			end
			local state = P.GetServerState(caster, def)
			local req = P.Requirements(def, state)
			if not req.castable then
				return false, req.firstMissing or "Cannot cast this spell"
			end
			return true
		end
	else
		spell.cast = function() return true end
		spell.can_cast = function() return true end
	end

	return spell, nil, compiled
end

-- A short human description of a compiled crafted spell (for tooltips / grimoire).
function P.Describe(compiled)
	local essence = P.Essences[compiled.essence]
	local form = P.Forms[compiled.form]
	local bits = { (essence and essence.label or "?") .. " " .. (form and form.label or "?") }
	local names = {}
	for id, rank in pairs(compiled.ranks or {}) do
		local c = P.Clauses[id]
		if c then names[#names + 1] = c.label .. (rank > 1 and (" " .. rank) or "") end
	end
	table.sort(names)
	if #names > 0 then bits[#bits + 1] = table.concat(names, ", ") end
	return table.concat(bits, ": ")
end

----------------------------------------------------------------------
-- SERVER: casting interpreter + essence riders
----------------------------------------------------------------------
if SERVER then
	local function isActor(ent)
		return IsValid(ent) and Arcana.Common.IsActor(ent)
	end

	-- Alive() is a player method; NPC mages answer on health. Prop casters (spell
	-- casters) carry no health at all, so for them existing is being alive.
	local function isAlive(ent)
		if not IsValid(ent) then return false end
		if ent:IsPlayer() then return ent:Alive() end
		if ent:IsNPC() or (ent.IsNextBot and ent:IsNextBot()) then return ent:Health() > 0 end

		return true
	end

	-- Key for per-caster records (self auras). Players keep their SteamID64 so a record
	-- survives their entity churn; anything else — NPC mages, spell casters — is keyed
	-- by entity index.
	local function casterKey(ent)
		if not IsValid(ent) then return nil end
		if ent:IsPlayer() then return ent:SteamID64() end

		return "ent_" .. ent:EntIndex()
	end

	-- Apply ONLY the essence rider to a single actor. Base damage is dealt
	-- separately by the area/direct damage pass so the cap stays honest.
	function P.ApplyEssenceHit(caster, target, hitPos, compiled)
		if not isActor(target) then return end
		local rider = compiled.rider

		if rider == "ignite" or rider == "aurum" then
			target:Ignite(3)
			if rider == "aurum" then
				-- The brand is networked: death ragdolls are CLIENTSIDE entities,
				-- so each client decides to gild in CreateClientsideRagdoll.
				target:SetNWFloat(AURUM_BRAND_NW, CurTime() + 4)
				target.ArcanaAurumBrander = IsValid(caster) and caster or nil

				-- The brand must read on the victim: golden rings while it lasts.
				Arcana.SendAttachBandVFX(target, Color(255, 210, 90, 255), 26, 4, {
					{ radius = 20, height = 6, spin = { p = 0, y = 40, r = 0 }, lineWidth = 2 },
				}, "spellcraft_aurum")

				-- Stacking aurum damage briefly seizes players solid gold.
				P.AddAurumHeat(target, compiled.damage)
			end
		elseif rider == "frost" then
			if Arcana.Status and Arcana.Status.Frost then
				Arcana.Status.Frost.Apply(target, { slowMult = 0.6, duration = 2.5, vfxTag = "spellcraft_frost", sendClientFX = target:IsPlayer() })
			end
		elseif rider == "earth" then
			local dir = (target:WorldSpaceCenter() - hitPos)
			dir.z = 0
			dir:Normalize()
			local push = dir * 400
			if target:IsPlayer() then
				target:SetVelocity(push)
			else
				local phys = target:GetPhysicsObject()
				if IsValid(phys) then phys:ApplyForceCenter(push * 60) end
			end
		elseif rider == "wind" then
			local up = Vector(0, 0, 380)
			if target:IsPlayer() then
				target:SetVelocity(up)
			else
				local phys = target:GetPhysicsObject()
				if IsValid(phys) then phys:ApplyForceCenter(up * 55) end
			end
		elseif rider == "poison" then
			-- DoT carrying the remaining 60% of the primary damage over 4 ticks.
			local perTick = (compiled.damage * 0.6) / 4
			local tag = "Arcana_SpellcraftPoison_" .. target:EntIndex()
			timer.Create(tag, 1.0, 4, function()
				if not IsValid(target) or not target:Alive() then timer.Remove(tag) return end
				local dmg = DamageInfo()
				dmg:SetDamage(perTick)
				dmg:SetDamageType(DMG_POISON)
				dmg:SetAttacker(IsValid(caster) and caster or game.GetWorld())
				dmg:SetInflictor(IsValid(caster) and caster or game.GetWorld())
				Arcana.TakeDamageInfo(target, dmg)
			end)
		end

		if compiled.concussive then
			local dir = (target:WorldSpaceCenter() - hitPos):GetNormalized()
			local force = dir * 650 + Vector(0, 0, 220)
			if target:IsPlayer() then
				target:SetVelocity(force)
			else
				local phys = target:GetPhysicsObject()
				if IsValid(phys) then phys:ApplyForceCenter(force * 50) end
			end
		end

		-- Pull: the inverse of concussive (they conflict at compile time).
		if compiled.pull then
			local dir = (hitPos - target:WorldSpaceCenter())
			dir.z = 0
			dir:Normalize()
			local force = dir * 650 + Vector(0, 0, 150)
			if target:IsPlayer() then
				target:SetVelocity(force)
			else
				local phys = target:GetPhysicsObject()
				if IsValid(phys) then phys:ApplyForceCenter(force * 50) end
			end
		end

		-- Hobble: light element-agnostic slow (frost element conflicts).
		if compiled.hobble and Arcana.Status and Arcana.Status.Frost then
			Arcana.Status.Frost.Apply(target, { slowMult = 0.5, duration = 4, vfxTag = "spellcraft_hobble", sendClientFX = target:IsPlayer() })
		end

		-- Curse: the victim takes extra damage from everything for a while
		-- (amplification happens in the EntityTakeDamage hook below).
		if compiled.curse then
			target.ArcanaCurseUntil = CurTime() + 8
			Arcana.SendAttachBandVFX(target, Color(120, 60, 160, 255), 24, 8, {
				{ radius = 18, height = 5, spin = { p = 0, y = -50, r = 0 }, lineWidth = 2 },
			}, "spellcraft_curse")
		end
	end

	-- Cursed victims take amplified damage from all sources.
	hook.Add("EntityTakeDamage", "Arcana_Spellcraft_Curse", function(target, dmginfo)
		if (target.ArcanaCurseUntil or 0) >= CurTime() then
			dmginfo:ScaleDamage(1.3)
		end
	end)

	-- Deal the primary damage in a sphere and apply riders to actors within it.
	-- opts: radius, inflictor, fxIntensity, damageMult (immediate damage only),
	-- isEcho (suppresses re-echoing).
	function P.AreaEssence(caster, pos, compiled, opts)
		opts = opts or {}
		local radius = opts.radius or compiled.radius
		local inflictor = IsValid(opts.inflictor) and opts.inflictor or caster
		if radius <= 0 then radius = 48 end

		local damageMult = opts.damageMult or 1
		local immediate = compiled.damage * damageMult
		if compiled.rider == "poison" then immediate = immediate * 0.4 end

		if immediate > 0 then
			Arcana.BlastDamage(caster, pos, radius, immediate, {
				damageType = compiled.damageType,
				ignoreAttacker = true,
				inflictor = inflictor,
			})
		end

		local hits = 0
		for _, ent in ipairs(ents.FindInSphere(pos, radius)) do
			if ent ~= caster and isActor(ent) then
				if not (ent:IsPlayer() and not ent:Alive()) then
					P.ApplyEssenceHit(caster, ent, pos, compiled)
					hits = hits + 1
				end
			end
		end

		-- Siphon: heal for part of the damage dealt, hard-capped per cast.
		if compiled.siphon and hits > 0 and isAlive(caster) then
			local heal = math.min(hits * compiled.damage * damageMult * 0.3, 100)
			caster:SetHealth(math.min(caster:GetMaxHealth(), caster:Health() + math.floor(heal)))
		end

		if compiled.rider == "lightning" and (compiled.chainDamage or 0) > 0 then
			Arcana.Common.ApplyLightningChain(caster, pos, {
				baseDamage = 0, blastRadius = 1,
				chainRadius = radius * 1.6,
				chainDamage = compiled.chainDamage * damageMult,
				maxChains = compiled.lightningMaxChains or 2,
			})
		end

		-- Element-authentic burst (effects.lua): a fire hit explodes, a frost
		-- hit shatters, lightning cracks, and so on. fxIntensity 0 skips the
		-- burst entirely (self auras have their own continuous visuals).
		local fxIntensity = opts.fxIntensity or 1
		if fxIntensity > 0 then
			P.ImpactFX(compiled.essence, pos, radius, fxIntensity)
		end

		-- Echo: the impact repeats once at the same spot, at half strength.
		if compiled.echo and not opts.isEcho then
			timer.Simple(1.5, function()
				if not IsValid(caster) then return end
				P.AreaEssence(caster, pos, compiled, {
					radius = radius,
					damageMult = damageMult * 0.75,
					fxIntensity = math.min(fxIntensity, 0.8),
					isEcho = true,
				})
			end)
		end
	end

	-- A short-lived ground patch that re-applies the essence.
	function P.SpawnLingering(caster, pos, compiled)
		if not compiled.lingering then return end
		local patchRadius = math.max(80, compiled.radius * 0.7)
		local duration = 6
		local ticks = 12 -- 6s at 0.5s
		local tag = "Arcana_SpellcraftLinger_" .. math.floor(pos.x) .. "_" .. math.floor(pos.y) .. "_" .. math.floor(CurTime() * 100)
		local perTick = compiled.damage * 0.4

		-- Continuous dense element volume for the whole patch lifetime
		-- (poison_cloud style), instead of sparse pulses.
		P.ZoneFX(compiled.essence, pos, patchRadius, duration)

		timer.Create(tag, 0.5, ticks, function()
			if not IsValid(caster) then timer.Remove(tag) return end
			for _, ent in ipairs(ents.FindInSphere(pos, patchRadius)) do
				if ent ~= caster and isActor(ent) and not (ent:IsPlayer() and not ent:Alive()) then
					local dmg = DamageInfo()
					dmg:SetDamage(perTick)
					dmg:SetDamageType(compiled.damageType)
					dmg:SetAttacker(caster)
					dmg:SetInflictor(caster)
					Arcana.TakeDamageInfo(ent, dmg)
				end
			end
		end)
	end

	-- Resolve the aim origin/direction for a cast.
	--
	-- Aim belongs to whatever is actually casting, never to the owner standing
	-- somewhere else: players and NPC mages sight down their eyes, while a spell
	-- caster entity fires along its own forward axis (the direction its physgun
	-- line advertises). Every entity answers EyePos/GetAimVector, so the split
	-- has to be on what the caster IS, not on which methods it has.
	local function resolveAim(caster, srcEnt, ctx)
		local aimer = IsValid(srcEnt) and srcEnt or caster
		local origin, aim

		if Arcana.Common.IsActor(aimer) then
			origin = aimer:EyePos()
			aim = aimer:GetAimVector()
		else
			origin = aimer:WorldSpaceCenter()
			aim = aimer:GetForward()
		end

		if isvector(ctx.circlePos) and not ctx.circlePos:IsZero() then
			origin = ctx.circlePos
		end

		return origin, aim:GetNormalized()
	end

	function P.CastBolt(caster, srcEnt, compiled, ctx)
		local origin, aim = resolveAim(caster, srcEnt, ctx)
		local count = math.max(1, compiled.projectiles or 1)
		local right = aim:Angle():Right()

		for i = 1, count do
			local spread = (i - (count + 1) * 0.5) * 10
			local spawnPos = origin + aim * 20 + right * spread
			local bolt = ents.Create("arcana_spellcraft_bolt")
			if IsValid(bolt) then
				bolt:SetPos(spawnPos)
				bolt:SetAngles(aim:Angle())
				bolt:SetColor(compiled.essenceColor)
				bolt._spellcraft = compiled
				bolt._spellcraftCaster = caster
				-- The machine that fired it is not a target: without this a bolt
				-- leaving a spell caster can detonate on its own emitter.
				bolt._spellcraftSource = srcEnt ~= caster and srcEnt or nil
				bolt:SetElement(compiled.essence)
				bolt:SetProjectileSpeed(compiled.speed > 0 and compiled.speed or 1200)
				bolt:Spawn()
				bolt:Activate()
				if compiled.homing then
					local tgt = P.SelectHomingTarget(origin, aim, caster)
					if IsValid(tgt) then bolt:SetHomingTarget(tgt) end
				end
				Arcana.Common.LaunchProjectile(bolt, caster, aim)
			end
		end
	end

	-- Called by the bolt entity on detonation.
	function P.OnBoltDetonate(bolt, pos)
		local compiled = bolt._spellcraft
		local caster = bolt._spellcraftCaster
		if not compiled or not IsValid(caster) then return end
		P.AreaEssence(caster, pos, compiled, { inflictor = bolt })
		P.SpawnLingering(caster, pos, compiled)

		-- Split: the detonation bursts into three smaller bolts. Children carry
		-- a reduced spell and never split, home, pierce, or echo again.
		if compiled.split and not bolt._isChild then
			local child = table.Copy(compiled)
			child.damage = compiled.damage * 0.55
			child.radius = compiled.radius * 0.75
			child.split = false
			child.homing = false
			child.pierce = false
			child.echo = false
			child.projectiles = 1

			for i = 1, 3 do
				local ang = (i - 1) * 120 + math.Rand(-25, 25)
				local dir = Angle(-math.Rand(35, 60), ang, 0):Forward()
				local mini = ents.Create("arcana_spellcraft_bolt")
				if IsValid(mini) then
					mini:SetPos(pos + Vector(0, 0, 8))
					mini:SetAngles(dir:Angle())
					mini:SetColor(compiled.essenceColor)
					mini._spellcraft = child
					mini._spellcraftCaster = caster
					mini._spellcraftSource = bolt._spellcraftSource
					mini._isChild = true
					mini:SetElement(compiled.essence)
					mini:SetProjectileSpeed(600)
					mini:Spawn()
					mini:Activate()
					Arcana.Common.LaunchProjectile(mini, caster, dir)
				end
			end
		end
	end

	function P.SelectHomingTarget(origin, aim, caster)
		local best, bestDot = nil, 0.2
		for _, ent in ipairs(ents.FindInSphere(origin + aim * 900, 1400)) do
			if IsValid(ent) and ent ~= caster and isActor(ent) and not (ent:IsPlayer() and not ent:Alive()) then
				local d = (ent:WorldSpaceCenter() - origin):GetNormalized():Dot(aim)
				if d > bestDot then bestDot, best = d, ent end
			end
		end
		return best
	end

	function P.CastBeam(caster, srcEnt, compiled, ctx)
		local origin, aim = resolveAim(caster, srcEnt, ctx)
		local maxDist = compiled.range > 0 and compiled.range or 2000

		local tr = util.TraceLine({
			start = origin,
			endpos = origin + aim * maxDist,
			filter = { caster, srcEnt },
			mask = MASK_SHOT,
		})

		-- Element-authentic beam visual (effects.lua): lightning arcs, flame
		-- streams, frost mist, and so on. Damage flows through AreaEssence so
		-- riders and the damage cap behave exactly like every other form.
		P.BeamFX(compiled.essence, origin + aim * 16, tr.HitPos)

		if tr.Hit then
			P.AreaEssence(caster, tr.HitPos, compiled, { inflictor = caster })
			P.SpawnLingering(caster, tr.HitPos, compiled)

			-- Refract: the beam forks from the impact to up to two more foes.
			if compiled.refract then
				local forks = 0
				for _, ent in ipairs(ents.FindInSphere(tr.HitPos, 400)) do
					if forks >= 2 then break end
					if ent ~= caster and isActor(ent) and not (ent:IsPlayer() and not ent:Alive()) then
						local tpos = ent:WorldSpaceCenter()
						P.BeamFX(compiled.essence, tr.HitPos, tpos)

						local dmg = DamageInfo()
						dmg:SetDamage(compiled.damage * 0.75)
						dmg:SetDamageType(compiled.damageType)
						dmg:SetAttacker(caster)
						dmg:SetInflictor(caster)
						dmg:SetDamagePosition(tpos)
						Arcana.TakeDamageInfo(ent, dmg)
						P.ApplyEssenceHit(caster, ent, tpos, compiled)

						forks = forks + 1
					end
				end
			end
		end
	end

	function P.CastAoe(caster, srcEnt, compiled, ctx)
		local origin, aim = resolveAim(caster, srcEnt, ctx)
		local maxRange = compiled.range > 0 and compiled.range or 900
		local tr = util.TraceLine({
			start = origin,
			endpos = origin + aim * maxRange,
			filter = { caster, srcEnt },
			mask = MASK_SHOT,
		})
		local pos = tr.HitPos
		P.AreaEssence(caster, pos, compiled, { inflictor = caster, fxIntensity = 1.2 })
		P.SpawnLingering(caster, pos, compiled)
	end

	-- Self aura: one maintenance timer per holder; re-casting refreshes it.
	-- The holder is whatever cast it (a player wears it, a spell caster emits it
	-- from its own body); the caster stays the owner so kills credit them.
	-- Records: [sid] = { endTime, compiled, caster, holder, thornsCD }
	P.SelfAuras = P.SelfAuras or {}

	local function removeHaste(caster)
		local rec = caster.ArcanaSpellcraftHaste
		if not rec then return end
		caster.ArcanaSpellcraftHaste = nil
		if IsValid(caster) then
			caster:SetWalkSpeed(rec.walk)
			caster:SetRunSpeed(rec.run)
		end
	end

	local function applyHaste(caster)
		if caster.ArcanaSpellcraftHaste then return end -- never stack on recast
		caster.ArcanaSpellcraftHaste = { walk = caster:GetWalkSpeed(), run = caster:GetRunSpeed() }
		caster:SetWalkSpeed(caster:GetWalkSpeed() * 1.4)
		caster:SetRunSpeed(caster:GetRunSpeed() * 1.4)
	end

	function P.CastSelf(caster, srcEnt, compiled, ctx)
		-- Bound to the body that cast it: a machine's aura burns around the
		-- machine, not around an owner standing on the other side of the map.
		local holder = IsValid(srcEnt) and srcEnt or caster
		local sid = casterKey(holder)
		if not sid then return end
		local duration = compiled.duration > 0 and compiled.duration or 8

		P.SelfAuras[sid] = {
			endTime = CurTime() + duration,
			compiled = compiled,
			caster = caster,
			holder = holder,
			thornsCD = {},
		}

		-- Continuous element aura around the holder (effects.lua): flames, arcs,
		-- mist... the element itself is the visual, no magic circles.
		P.AuraFX(holder, compiled.essence, compiled.radius, duration)

		-- Haste moves a body that walks; a machine has nothing to speed up.
		if compiled.haste and holder:IsPlayer() then
			applyHaste(holder)
		end

		local tag = "Arcana_SpellcraftSelf_" .. sid
		local interval = math.max(0.5, compiled.tickInterval or 1.0)
		timer.Create(tag, interval, 0, function()
			local aura = P.SelfAuras[sid]
			if not isAlive(holder) or not aura or CurTime() >= aura.endTime then
				timer.Remove(tag)
				if IsValid(holder) then
					P.AuraFX(holder, compiled.essence, 0, 0)
					removeHaste(holder)
				end
				P.SelfAuras[sid] = nil
				return
			end
			-- inflictor = holder so the emitter is never caught in its own pulse.
			P.AreaEssence(caster, holder:WorldSpaceCenter(), compiled, { inflictor = holder, fxIntensity = 0 })
		end)
	end

	-- Thorns: while an aura with thorns is up, attackers get struck by the
	-- aura's element (per-attacker cooldown so DoTs can't loop it).
	hook.Add("EntityTakeDamage", "Arcana_Spellcraft_Thorns", function(target, dmginfo)
		-- Cheap out before keying: this runs on every damage event on the map.
		if next(P.SelfAuras) == nil then return end

		-- Any aura holder retaliates, including a spell caster being shot at, so
		-- this cannot be gated on the target being an actor.
		local sid = casterKey(target)
		if not sid then return end

		local aura = P.SelfAuras[sid]
		if not aura or not aura.compiled.thorns or CurTime() >= aura.endTime then return end

		local attacker = dmginfo:GetAttacker()
		if not IsValid(attacker) or attacker == target then return end
		if not Arcana.Common.IsActor(attacker) then return end

		local now = CurTime()
		if (aura.thornsCD[attacker] or 0) > now then return end
		aura.thornsCD[attacker] = now + 1

		-- Reflect half the incoming damage, then strike with the element rider.
		-- Credit goes to the caster (the machine's owner, or the player wearing
		-- the aura), with the struck body as the inflictor.
		local credit = IsValid(aura.caster) and aura.caster or target
		local reflected = dmginfo:GetDamage() * 0.5
		if reflected > 0 then
			local dmg = DamageInfo()
			dmg:SetDamage(reflected)
			dmg:SetDamageType(aura.compiled.damageType)
			dmg:SetAttacker(credit)
			dmg:SetInflictor(target)
			dmg:SetDamagePosition(attacker:WorldSpaceCenter())
			Arcana.TakeDamageInfo(attacker, dmg)
		end
		P.ApplyEssenceHit(credit, attacker, target:WorldSpaceCenter(), aura.compiled)
	end)

	function P.Execute(caster, compiled, ctx)
		if not IsValid(caster) then return false end
		ctx = ctx or {}
		local srcEnt = IsValid(ctx.casterEntity) and ctx.casterEntity or caster
		local form = compiled.form
		if form == "bolt" then
			P.CastBolt(caster, srcEnt, compiled, ctx)
		elseif form == "beam" then
			P.CastBeam(caster, srcEnt, compiled, ctx)
		elseif form == "self" then
			P.CastSelf(caster, srcEnt, compiled, ctx)
		elseif form == "aoe" then
			P.CastAoe(caster, srcEnt, compiled, ctx)
		else
			return false
		end
		return true
	end

	-- Stacking aurum damage on a living player briefly seizes them in gold:
	-- frozen solid for a moment, then released. Heat resets if hits stop landing.
	local SEIZE_THRESHOLD = 120  -- accumulated aurum damage to trigger
	local SEIZE_DURATION = 1.2
	local SEIZE_COOLDOWN = 8     -- per-victim; prevents chain-freezing
	local HEAT_WINDOW = 4        -- seconds without an aurum hit before heat resets

	local function seizePlayer(ply)
		if not ply:Alive() then return end
		ply.ArcanaAurumSeizeCooldown = CurTime() + SEIZE_COOLDOWN
		ply.ArcanaAurumHeat = 0

		local prevMat = ply:GetMaterial()
		local prevCol = ply:GetColor()
		ply:Freeze(true)
		ply:Extinguish()
		ply:SetMaterial(GOLD_MATERIAL)
		ply:SetColor(GOLD_TINT)
		ply:EmitSound("physics/metal/metal_solid_impact_hard" .. math.random(1, 3) .. ".wav", 75, 90)
		P.ImpactFX("aurum", ply:WorldSpaceCenter(), 60, 0.6)

		timer.Simple(SEIZE_DURATION, function()
			if not IsValid(ply) then return end
			ply:Freeze(false)
			ply:SetMaterial(prevMat or "")
			ply:SetColor(prevCol or Color(255, 255, 255))
			ply:EmitSound("physics/metal/metal_box_impact_soft" .. math.random(1, 3) .. ".wav", 70, 130)
		end)
	end

	function P.AddAurumHeat(target, amount)
		if not IsValid(target) or not target:IsPlayer() then return end
		if CurTime() < (target.ArcanaAurumSeizeCooldown or 0) then return end

		-- Rolling accumulator: hits refresh the window, silence resets it.
		if CurTime() - (target.ArcanaAurumLastHit or 0) > HEAT_WINDOW then
			target.ArcanaAurumHeat = 0
		end
		target.ArcanaAurumLastHit = CurTime()
		target.ArcanaAurumHeat = (target.ArcanaAurumHeat or 0) + (tonumber(amount) or 0)

		if target.ArcanaAurumHeat >= SEIZE_THRESHOLD then
			seizePlayer(target)
		end
	end

	-- Statue visuals live entirely on the client (see CreateClientsideRagdoll
	-- below): player death ragdolls are hl2mp_ragdoll shells that spawn a
	-- clientside ragdoll per client, and NPC corpses are clientside too. The
	-- server only cleans up the networked shell so it cannot pile up.
	hook.Add("PlayerDeath", "Arcana_Spellcraft_AurumGold", function(victim)
		if victim:GetNWFloat(AURUM_BRAND_NW, 0) < CurTime() then return end
		timer.Simple(0, function()
			if not IsValid(victim) then return end
			local rag = victim:GetRagdollEntity()
			if not IsValid(rag) then return end
			timer.Simple(STATUE_LIFETIME + 2, function()
				SafeRemoveEntity(rag)
			end)
		end)
	end)
end

----------------------------------------------------------------------
-- CLIENT: local definition store + sync + register receivers + burst VFX
----------------------------------------------------------------------
if CLIENT then
	local STORE_PATH = "arcana/spellcraft.json"

	P.Local = P.Local or {}            -- array of { slot, name, form, essence, clauses, created_at }
	P.ClientActive = P.ClientActive or {}  -- [sid64][slot] = { name, form, essence, clauses }
	P.ClientState = P.ClientState or { essences = {}, consecrated = {}, bargain = false, maxSlots = 3 }

	function P.LoadLocal()
		P.Local = {}
		local raw = file.Read(STORE_PATH, "DATA")
		if not raw then return end

		local arr = Arcana.DecodeJSON(raw, "local crafted spell store (" .. STORE_PATH .. ")", nil)
		if arr then
			for _, d in ipairs(arr) do
				if istable(d) and isstring(d.form) and isstring(d.essence) then
					P.Local[#P.Local + 1] = {
						slot = math.floor(tonumber(d.slot) or (#P.Local + 1)),
						name = tostring(d.name or "Crafted Spell"),
						form = d.form,
						essence = d.essence,
						clauses = istable(d.clauses) and d.clauses or {},
						created_at = tonumber(d.created_at) or 0,
					}
				end
			end
		end
	end

	function P.SaveLocal()
		file.CreateDir("arcana")
		file.Write(STORE_PATH, util.TableToJSON(P.Local, true))
	end

	function P.GetLocal(slot)
		for _, d in ipairs(P.Local) do
			if d.slot == slot then return d end
		end
	end

	function P.UpsertLocal(def)
		for i, d in ipairs(P.Local) do
			if d.slot == def.slot then
				P.Local[i] = def
				P.SaveLocal()
				return
			end
		end
		P.Local[#P.Local + 1] = def
		P.SaveLocal()
	end

	function P.RemoveLocal(slot)
		for i = #P.Local, 1, -1 do
			if P.Local[i].slot == slot then table.remove(P.Local, i) end
		end
		P.SaveLocal()
	end

	-- Live eligibility state for the local player (used by the UI).
	function P.GetClientState()
		local ply = LocalPlayer()
		local level = 0
		if IsValid(ply) then
			local d = Arcana.GetPlayerData(ply)
			level = d and d.level or 0
		end
		return {
			level = level,
			essences = P.ClientState.essences or {},
			bargain = P.ClientState.bargain == true,
			consecrated = P.ClientState.consecrated or {},
			maxSlots = P.ClientState.maxSlots or 3,
		}
	end

	-- Registers (or replaces) a crafted spell spell locally for display.
	local function registerLocal(sid64, slot, name, form, essence, clauses)
		local def = { form = form, essence = essence, clauses = clauses }
		local spell = P.BuildSpellData(sid64, slot, def, name)
		if spell then
			Arcana.RegisteredSpells[spell.id] = spell
			-- Our own crafted spells must appear in the grimoire immediately; the initial
			-- FullSync predates registration, so mirror the unlock into local data.
			local ply = LocalPlayer()
			if IsValid(ply) and sid64 == ply:SteamID64() then
				local data = Arcana.GetPlayerData(ply)
				if data then data.unlocked_spells[spell.id] = true end
			end
		end
		P.ClientActive[sid64] = P.ClientActive[sid64] or {}
		P.ClientActive[sid64][slot] = { name = name, form = form, essence = essence, clauses = clauses }
	end

	local function readClauses()
		local n = net.ReadUInt(8)
		local out = {}
		for i = 1, n do out[i] = net.ReadString() end
		return out
	end

	net.Receive("Arcana_Spellcraft_RequestSync", function()
		P.LoadLocal()
		net.Start("Arcana_Spellcraft_SyncUp")
		net.WriteUInt(#P.Local, 8)
		for _, d in ipairs(P.Local) do
			net.WriteUInt(math.Clamp(d.slot, 1, 64), 8)
			net.WriteString(string.sub(d.name or "Crafted Spell", 1, 24))
			net.WriteString(d.form)
			net.WriteString(d.essence)
			local clauses = d.clauses or {}
			net.WriteUInt(math.min(#clauses, 8), 8)
			for i = 1, math.min(#clauses, 8) do net.WriteString(clauses[i]) end
		end
		net.SendToServer()
	end)

	net.Receive("Arcana_Spellcraft_Register", function()
		local sid64 = net.ReadString()
		local slot = net.ReadUInt(8)
		local name = net.ReadString()
		local form = net.ReadString()
		local essence = net.ReadString()
		local clauses = readClauses()
		registerLocal(sid64, slot, name, form, essence, clauses)

		-- If this is our own crafted spell, keep the local file authoritative/in sync.
		local ply = LocalPlayer()
		if IsValid(ply) and sid64 == ply:SteamID64() then
			P.UpsertLocal({ slot = slot, name = name, form = form, essence = essence, clauses = clauses, created_at = P.GetLocal(slot) and P.GetLocal(slot).created_at or 0 })
		end
		hook.Run("Arcana_Spellcraft_StateChanged")
	end)

	net.Receive("Arcana_Spellcraft_Unregister", function()
		local sid64 = net.ReadString()
		local slot = net.ReadUInt(8)
		local id = P.SpellId(sid64, slot)
		Arcana.RegisteredSpells[id] = nil
		if P.ClientActive[sid64] then P.ClientActive[sid64][slot] = nil end
		local ply = LocalPlayer()
		if IsValid(ply) and sid64 == ply:SteamID64() then
			P.RemoveLocal(slot)
			local data = Arcana.GetPlayerData(ply)
			if data then data.unlocked_spells[id] = nil end
		end
		hook.Run("Arcana_Spellcraft_StateChanged")
	end)

	net.Receive("Arcana_Spellcraft_State", function()
		local essences = {}
		local ne = net.ReadUInt(8)
		for i = 1, ne do essences[net.ReadString()] = true end
		local consecrated = {}
		local nc = net.ReadUInt(8)
		for i = 1, nc do consecrated[net.ReadString()] = true end
		P.ClientState = {
			essences = essences,
			consecrated = consecrated,
			bargain = net.ReadBool(),
			maxSlots = net.ReadUInt(8),
		}
		hook.Run("Arcana_Spellcraft_StateChanged")
	end)

	-- Aurum gold statues, done where the corpse actually exists: death ragdolls
	-- are CLIENTSIDE (player deaths spawn one per client via hl2mp_ragdoll, NPC
	-- corpses are client ragdolls outright). Gilding here also inherits
	-- client-only model swaps from addons like Outfitter, since the ragdoll is
	-- built from (or swapped to) the model this client sees.
	local function aurumBrandSource(owner, ragdoll)
		if IsValid(owner) and owner:GetNWFloat(AURUM_BRAND_NW, 0) >= CurTime() then
			return owner
		end

		-- Player death ragdolls arrive via an intermediate hl2mp_ragdoll entity,
		-- so the branded victim may need to be found by proximity instead.
		local pos = IsValid(ragdoll) and ragdoll:GetPos() or (IsValid(owner) and owner:GetPos() or nil)
		if not pos then return nil end

		for _, ply in ipairs(player.GetAll()) do
			if not ply:Alive() and ply:GetNWFloat(AURUM_BRAND_NW, 0) >= CurTime() and ply:GetPos():DistToSqr(pos) < (200 * 200) then
				return ply
			end
		end
	end

	hook.Add("CreateClientsideRagdoll", "Arcana_Spellcraft_AurumGold", function(owner, ragdoll)
		if not IsValid(ragdoll) then return end
		local source = aurumBrandSource(owner, ragdoll)
		if not source then return end

		-- Mirror the victim's clientside model (Outfitter-style addons swap
		-- player models client-only; this ragdoll is fully clientside).
		if source:IsPlayer() then
			local mdl = source:GetModel()
			if isstring(mdl) and mdl ~= "" and mdl ~= ragdoll:GetModel() and util.IsValidModel(mdl) then
				ragdoll:SetModel(mdl)
			end
		end

		ragdoll:SetMaterial(GOLD_MATERIAL)
		ragdoll:SetColor(GOLD_TINT)

		-- Let it settle for a beat, then seize it solid.
		timer.Simple(0.5, function()
			if not IsValid(ragdoll) then return end
			for i = 0, ragdoll:GetPhysicsObjectCount() - 1 do
				local phys = ragdoll:GetPhysicsObjectNum(i)
				if IsValid(phys) then phys:EnableMotion(false) end
			end
		end)

		-- The engine's own ragdoll fade cleans the statue up.
		timer.Simple(STATUE_LIFETIME, function()
			if not IsValid(ragdoll) then return end
			ragdoll:SetSaveValue("m_bFadingOut", true)
		end)
	end)

	-- Load the local store once at startup.
	hook.Add("InitPostEntity", "Arcana_Spellcraft_LoadLocal", function()
		P.LoadLocal()
	end)
end
