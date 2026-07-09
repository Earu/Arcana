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
	util.AddNetworkString("Arcana_Spellcraft_Burst")

	local function isActor(ent)
		return IsValid(ent) and (ent:IsPlayer() or ent:IsNPC() or (ent.IsNextBot and ent:IsNextBot()))
	end

	-- Broadcast a colored burst (expanding ring + puff) at a point.
	function P.Burst(pos, radius, color)
		net.Start("Arcana_Spellcraft_Burst", true)
		net.WriteVector(pos)
		net.WriteFloat(radius)
		net.WriteColor(color or Color(200, 200, 255), false)
		net.Broadcast()
	end

	-- Apply ONLY the essence rider to a single actor. Base damage is dealt
	-- separately by the area/direct damage pass so the cap stays honest.
	function P.ApplyEssenceHit(caster, target, hitPos, compiled)
		if not isActor(target) then return end
		local rider = compiled.rider

		if rider == "ignite" or rider == "aurum" then
			target:Ignite(3)
			if rider == "aurum" then
				target.ArcanaAurumBrand = CurTime() + 4
				target.ArcanaAurumBrander = IsValid(caster) and caster or nil

				-- The brand must read on the victim: golden rings while it lasts.
				Arcana:SendAttachBandVFX(target, Color(255, 210, 90, 255), 26, 4, {
					{ radius = 20, height = 6, spin = { p = 0, y = 40, r = 0 }, lineWidth = 2 },
				}, "spellcraft_aurum")

				-- Sandbox NPC death ragdolls are clientside; force a serverside
				-- one so the gold statue is actually visible (CreateEntityRagdoll).
				if target.SetShouldServerRagdoll then
					target:SetShouldServerRagdoll(true)
				end

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
				Arcana:TakeDamageInfo(target, dmg)
			end)
		end

		if compiled.concussive then
			local dir = (target:WorldSpaceCenter() - hitPos):GetNormalized()
			local force = dir * 320 + Vector(0, 0, 120)
			if target:IsPlayer() then
				target:SetVelocity(force)
			else
				local phys = target:GetPhysicsObject()
				if IsValid(phys) then phys:ApplyForceCenter(force * 50) end
			end
		end
	end

	-- Deal the primary damage in a sphere and apply riders to actors within it.
	function P.AreaEssence(caster, pos, compiled, opts)
		opts = opts or {}
		local radius = opts.radius or compiled.radius
		local inflictor = IsValid(opts.inflictor) and opts.inflictor or caster
		if radius <= 0 then radius = 48 end

		local immediate = compiled.damage
		if compiled.rider == "poison" then immediate = compiled.damage * 0.4 end

		if immediate > 0 then
			Arcana:BlastDamage(caster, pos, radius, immediate, {
				damageType = compiled.damageType,
				ignoreAttacker = true,
				inflictor = inflictor,
			})
		end

		for _, ent in ipairs(ents.FindInSphere(pos, radius)) do
			if ent ~= caster and isActor(ent) then
				if not (ent:IsPlayer() and not ent:Alive()) then
					P.ApplyEssenceHit(caster, ent, pos, compiled)
				end
			end
		end

		if compiled.rider == "lightning" and (compiled.chainDamage or 0) > 0 then
			Arcana.Common.ApplyLightningChain(caster, pos, {
				baseDamage = 0, blastRadius = 1,
				chainRadius = radius * 1.6,
				chainDamage = compiled.chainDamage,
				maxChains = compiled.lightningMaxChains or 2,
			})
		end

		P.Burst(pos, radius, compiled.essenceColor)
	end

	-- A short-lived ground patch that re-applies the essence.
	function P.SpawnLingering(caster, pos, compiled)
		if not compiled.lingering then return end
		local patchRadius = math.max(80, compiled.radius * 0.7)
		local ticks = 8 -- 4s at 0.5s
		local tag = "Arcana_SpellcraftLinger_" .. math.floor(pos.x) .. "_" .. math.floor(pos.y) .. "_" .. math.floor(CurTime() * 100)
		local perTick = compiled.damage * 0.25
		local n = 0
		timer.Create(tag, 0.5, ticks, function()
			n = n + 1
			if not IsValid(caster) then timer.Remove(tag) return end
			for _, ent in ipairs(ents.FindInSphere(pos, patchRadius)) do
				if ent ~= caster and isActor(ent) and not (ent:IsPlayer() and not ent:Alive()) then
					local dmg = DamageInfo()
					dmg:SetDamage(perTick)
					dmg:SetDamageType(compiled.damageType)
					dmg:SetAttacker(caster)
					dmg:SetInflictor(caster)
					Arcana:TakeDamageInfo(ent, dmg)
				end
			end
			if n % 2 == 0 then P.Burst(pos, patchRadius, compiled.essenceColor) end
		end)
	end

	-- Resolve the aim origin/direction for a caster.
	local function resolveAim(caster, srcEnt, ctx)
		local origin, aim
		if caster.EyePos then
			origin = caster:EyePos()
			aim = caster:GetAimVector()
		else
			origin = srcEnt:WorldSpaceCenter()
			aim = srcEnt:GetForward()
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
		Arcana.Common.SpearBeam(caster, origin, aim, {
			maxDist = compiled.range > 0 and compiled.range or 2000,
			damage = 0,          -- damage handled through AreaEssence for rider parity
			splashDamage = 0,
			color = compiled.essenceColor,
			damageType = compiled.damageType,
			noImpactEffect = true,
			onHit = function(hitEnt, hitPos, hitNormal)
				P.AreaEssence(caster, hitPos, compiled, { inflictor = caster })
				P.SpawnLingering(caster, hitPos, compiled)
			end,
		})
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
		P.AreaEssence(caster, pos, compiled, { inflictor = caster })
		P.SpawnLingering(caster, pos, compiled)
		util.ScreenShake(pos, 5, 60, 0.3, compiled.radius * 1.5)
	end

	-- Self aura: one maintenance timer per caster; re-casting refreshes it.
	P.SelfAuras = P.SelfAuras or {}
	function P.CastSelf(caster, srcEnt, compiled, ctx)
		local sid = caster:SteamID64() or tostring(caster:EntIndex())
		local endTime = CurTime() + (compiled.duration > 0 and compiled.duration or 8)
		P.SelfAuras[sid] = endTime

		Arcana:SendAttachBandVFX(caster, compiled.essenceColor, compiled.radius * 0.8, compiled.duration, {
			{ radius = compiled.radius * 0.4, height = 16, spin = { p = 0, y = 26, r = 0 }, lineWidth = 3 },
			{ radius = compiled.radius * 0.28, height = 10, spin = { p = 0, y = -22, r = 0 }, lineWidth = 2 },
		}, "spellcraft_self")

		local tag = "Arcana_SpellcraftSelf_" .. sid
		local interval = math.max(0.5, compiled.tickInterval or 1.0)
		timer.Create(tag, interval, 0, function()
			if not IsValid(caster) or not caster:Alive() or CurTime() >= (P.SelfAuras[sid] or 0) then
				timer.Remove(tag)
				if IsValid(caster) then Arcana:ClearBandVFX(caster, "spellcraft_self") end
				P.SelfAuras[sid] = nil
				return
			end
			P.AreaEssence(caster, caster:WorldSpaceCenter(), compiled, { inflictor = caster })
		end)
	end

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

	-- Aurum: victims that die while branded are left as gold statues.
	local GOLD_MATERIAL = "models/player/shared/gold_player"
	local GOLD_TINT = Color(255, 226, 140)

	local function isBranded(ent)
		return IsValid(ent) and (ent.ArcanaAurumBrand or 0) >= CurTime()
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
		P.Burst(ply:WorldSpaceCenter(), 60, GOLD_TINT)

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

	-- Gild a ragdoll, let it settle for a beat, then seize it solid.
	local function gildRagdoll(rag)
		if not IsValid(rag) then return end
		rag:SetMaterial(GOLD_MATERIAL)
		rag:SetColor(GOLD_TINT)

		timer.Simple(0.5, function()
			if not IsValid(rag) then return end
			for i = 0, rag:GetPhysicsObjectCount() - 1 do
				local phys = rag:GetPhysicsObjectNum(i)
				if IsValid(phys) then
					phys:SetMaterial("metal")
					phys:EnableMotion(false)
				end
			end
		end)
	end

	-- Players get serverside death ragdolls (base gamemode CreateRagdoll).
	hook.Add("PlayerDeath", "Arcana_Spellcraft_AurumGold", function(victim)
		if not isBranded(victim) then return end
		timer.Simple(0, function()
			if IsValid(victim) and victim.GetRagdollEntity then
				gildRagdoll(victim:GetRagdollEntity())
			end
		end)
	end)

	-- NPC ragdolls are clientside by default; the brand forces a serverside one
	-- (SetShouldServerRagdoll in ApplyEssenceHit), which lands in this hook.
	hook.Add("CreateEntityRagdoll", "Arcana_Spellcraft_AurumGold", function(owner, ragdoll)
		if isBranded(owner) then
			gildRagdoll(ragdoll)
		end
	end)

	-- NextBots and other odd entities: best-effort gild before removal.
	hook.Add("EntityRemoved", "Arcana_Spellcraft_AurumGoldNextbot", function(ent)
		if isBranded(ent) and ent.IsNextBot and ent:IsNextBot() then
			ent:SetMaterial(GOLD_MATERIAL)
		end
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
		local ok, arr = pcall(util.JSONToTable, raw)
		if ok and istable(arr) then
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
			local d = Arcana:GetPlayerData(ply)
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
				local data = Arcana:GetPlayerData(ply)
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
			local data = Arcana:GetPlayerData(ply)
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

	-- Colored burst VFX (expanding ring + puff + light) reused by every form.
	local bursts = {}
	local matRing = Material("effects/select_ring")
	local matGlow = Material("sprites/light_glow02_add")
	net.Receive("Arcana_Spellcraft_Burst", function()
		local pos = net.ReadVector()
		local radius = net.ReadFloat()
		local col = net.ReadColor(false)
		bursts[#bursts + 1] = { pos = pos, radius = math.max(48, radius), col = col, life = 0.45, die = CurTime() + 0.45 }

		local dl = DynamicLight(math.random(1, 60000))
		if dl then
			dl.pos = pos
			dl.r, dl.g, dl.b = col.r, col.g, col.b
			dl.brightness = 2.4
			dl.Size = radius * 1.2
			dl.Decay = 1200
			dl.DieTime = CurTime() + 0.2
		end

		local emitter = ParticleEmitter(pos)
		if emitter then
			for i = 1, 14 do
				local p = emitter:Add("effects/softglow", pos + VectorRand() * radius * 0.2)
				if p then
					p:SetVelocity(VectorRand() * radius * 1.4 + Vector(0, 0, 40))
					p:SetDieTime(math.Rand(0.3, 0.6))
					p:SetStartAlpha(200)
					p:SetEndAlpha(0)
					p:SetStartSize(math.Rand(6, 12))
					p:SetEndSize(0)
					p:SetColor(col.r, col.g, col.b)
					p:SetAirResistance(80)
					p:SetGravity(Vector(0, 0, -30))
					p:SetLighting(false)
				end
			end
			emitter:Finish()
		end
	end)

	hook.Add("PostDrawTranslucentRenderables", "Arcana_Spellcraft_Bursts", function(depth, sky)
		if depth or sky then return end
		for i = #bursts, 1, -1 do
			local b = bursts[i]
			if CurTime() > b.die then
				table.remove(bursts, i)
			else
				local frac = math.Clamp(1 - (b.die - CurTime()) / b.life, 0, 1)
				local cur = Lerp(frac, b.radius * 0.2, b.radius)
				local a = 220 * (1 - frac)
				render.SetMaterial(matRing)
				render.DrawQuadEasy(b.pos + Vector(0, 0, 3), Vector(0, 0, 1), cur, cur, Color(b.col.r, b.col.g, b.col.b, a), 0)
				render.SetMaterial(matGlow)
				render.DrawSprite(b.pos + Vector(0, 0, 6), cur * 0.5, cur * 0.5, Color(b.col.r, b.col.g, b.col.b, a * 0.6))
			end
		end
	end)

	-- Load the local store once at startup.
	hook.Add("InitPostEntity", "Arcana_Spellcraft_LoadLocal", function()
		P.LoadLocal()
	end)
end
