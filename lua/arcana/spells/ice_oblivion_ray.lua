-- Oblivion Ray: A divine pact spell granted at level 60 - channel the frozen void into a devastating directional beam
-- that obliterates everything in its path and deeply freezes anything daring enough to survive.
-- Cast time: 10s cannon-assembly charge. Beam duration: 15s, slowly following aim.

if SERVER then
	util.AddNetworkString("Arcana_IceOblivionRay_BeamStart")
	util.AddNetworkString("Arcana_IceOblivionRay_BeamTick")
	util.AddNetworkString("Arcana_IceOblivionRay_BeamEnd")
	util.AddNetworkString("Arcana_IceOblivionRay_ImpactNova")
	util.AddNetworkString("Arcana_IceOblivionRay_FinalExplosion")
end

local CAST_TIME      = 10.0
local BEAM_DURATION  = 15.0
local MAX_BEAM_RADIUS = 500
local MAX_BEAM_DIST  = 8000
local BEAM_DMG_TICK  = 800000
local COLOR          = Color(80, 200, 255)

local chargingPlayers = {}

if SERVER then
	hook.Add("SetupMove", "Arcana_IceOblivionRay_LockMovement", function(ply, mv, cmd)
		if not chargingPlayers[ply] then return end
		if not chargingPlayers[ply].charging then return end
		mv:SetForwardSpeed(0)
		mv:SetSideSpeed(0)
		mv:SetUpSpeed(0)
		mv:SetVelocity(Vector(0, 0, 0))
		if cmd:KeyDown(IN_JUMP) then cmd:RemoveKey(IN_JUMP) end
	end)

	hook.Add("PlayerDeath", "Arcana_IceOblivionRay_CleanupDeath", function(ply)
		chargingPlayers[ply] = nil
	end)

	hook.Add("PlayerDisconnected", "Arcana_IceOblivionRay_CleanupDisconnect", function(ply)
		chargingPlayers[ply] = nil
	end)

	hook.Add("Arcana_BeginCasting", "Arcana_IceOblivionRay_StartCharging", function(caster, spellId)
		if spellId ~= "ice_oblivion_ray" then return end
		if not IsValid(caster) then return end
		chargingPlayers[caster] = { charging = true, startTime = CurTime() }
	end)

	hook.Add("Arcana_CastSpellFailure", "Arcana_IceOblivionRay_CleanupOnFail", function(caster, spellId)
		if spellId ~= "ice_oblivion_ray" then return end
		chargingPlayers[caster] = nil
	end)
end

local function distToBeamLine(point, lineOrigin, lineDir)
	local v = point - lineOrigin
	local t = v:Dot(lineDir)
	if t < 0 then return math.huge, t end
	local closest = lineOrigin + lineDir * t
	return point:Distance(closest), t
end

local function startBeamPhase(caster)
	if not SERVER then return end
	if not IsValid(caster) then return end

	chargingPlayers[caster] = nil

	local currentDir = caster:GetAimVector()
	local startTime  = CurTime()
	local tickRate   = 0.1
	local ticks      = math.floor(BEAM_DURATION / tickRate)

	net.Start("Arcana_IceOblivionRay_BeamStart")
	net.WriteEntity(caster)
	net.WriteVector(currentDir)
	net.WriteFloat(BEAM_DURATION)
	net.Broadcast()

	util.ScreenShake(caster:GetPos(), 20, 120, 2.0, 3000)
	sound.Play("ambient/energy/whiteflash.wav", caster:GetPos(), 115, 75)
	sound.Play("ambient/atmosphere/thunder1.wav", caster:GetPos(), 105, 50)

	for tick = 0, ticks do
		timer.Simple(tick * tickRate, function()
			if not IsValid(caster) then return end

			local elapsed  = CurTime() - startTime
			local progress = math.Clamp(elapsed / BEAM_DURATION, 0, 1)

			-- Fast lerp: beam direction follows aim quickly, still slightly smoothed
			currentDir = (currentDir + caster:GetAimVector() * 0.15):GetNormalized()

		-- Radius grows over first 10 out of 15 seconds, then holds at MAX.
			-- Start at 200 so the beam is immediately impressive.
			local growProgress = math.Clamp(progress / (10 / BEAM_DURATION), 0, 1)
			local currentRadius = Lerp(growProgress, 200, MAX_BEAM_RADIUS)

			-- Beam fires from the muzzle (the concentration point 550u ahead)
			local beamOrigin = caster:EyePos() + currentDir * 550

			-- Sphere-sweep along beam to find and damage entities
			local checked  = {}
			local stepSize = math.max(currentRadius * 0.7, 120)
			local dist     = 50

			while dist <= MAX_BEAM_DIST do
				local checkPos = beamOrigin + currentDir * dist
				for _, ent in ipairs(ents.FindInSphere(checkPos, currentRadius * 1.15)) do
					if checked[ent] then continue end
					checked[ent] = true
					if not IsValid(ent) or ent == caster then continue end
					if not (ent:IsPlayer() or ent:IsNPC() or (ent.IsNextBot and ent:IsNextBot())) then continue end

					local actualDist = distToBeamLine(ent:WorldSpaceCenter(), beamOrigin, currentDir)
					if actualDist > currentRadius then continue end

					local dmg = DamageInfo()
					dmg:SetDamage(BEAM_DMG_TICK)
					dmg:SetDamageType(DMG_DISSOLVE)
					dmg:SetAttacker(caster)
					dmg:SetInflictor(caster)
					Arcana:TakeDamageInfo(ent, dmg)

					-- Deeply freeze anything that survives
					if IsValid(ent) then
						Arcana.Status.Frost.Apply(ent, { slowMult = 0.25, duration = 6, vfxTag = "oblivion_frost" })
					end
				end
				dist = dist + stepSize
			end

			-- Periodic screen shake scaled with progress
			if tick % 5 == 0 then
				util.ScreenShake(beamOrigin, 8 * (0.3 + progress * 0.7), 100, 0.5, 2000)
			end

			if tick % 10 == 0 then
				sound.Play("ambient/atmosphere/thunder" .. math.random(1, 4) .. ".wav", beamOrigin, 95, 55 + math.random(-10, 10))
			end

			if tick % 15 == 3 then
				sound.Play("ambient/energy/newspark0" .. math.random(4, 8) .. ".wav", beamOrigin, 88, 78)
			end

			-- Every 2 seconds: frost nova burst at beam impact point
			if tick % 20 == 5 then
				local impactTr = util.TraceLine({
					start  = beamOrigin,
					endpos = beamOrigin + currentDir * MAX_BEAM_DIST,
					mask   = MASK_SOLID_BRUSHONLY,
					filter = caster,
				})
				local impactPos  = impactTr.Hit and impactTr.HitPos or (beamOrigin + currentDir * MAX_BEAM_DIST)
				local novaRadius = 320

				for _, ent in ipairs(ents.FindInSphere(impactPos, novaRadius)) do
					if not IsValid(ent) or ent == caster then continue end
					if not (ent:IsPlayer() or ent:IsNPC() or (ent.IsNextBot and ent:IsNextBot())) then continue end

					local dmg2 = DamageInfo()
					dmg2:SetDamage(BEAM_DMG_TICK * 3)
					dmg2:SetDamageType(DMG_DISSOLVE)
					dmg2:SetAttacker(caster)
					dmg2:SetInflictor(caster)
					Arcana:TakeDamageInfo(ent, dmg2)

					if IsValid(ent) then
						Arcana.Status.Frost.Apply(ent, { slowMult = 0.5, duration = 4, vfxTag = "oblivion_nova" })
					end
				end

				util.ScreenShake(impactPos, 6, 70, 0.3, 800)
				net.Start("Arcana_IceOblivionRay_ImpactNova")
				net.WriteVector(impactPos)
				net.WriteFloat(novaRadius)
				net.Broadcast()
			end

			net.Start("Arcana_IceOblivionRay_BeamTick")
			net.WriteVector(beamOrigin)
			net.WriteVector(currentDir)
			net.WriteFloat(currentRadius)
			net.WriteFloat(progress)
			net.Broadcast()
		end)
	end

	timer.Simple(BEAM_DURATION, function()
		if not IsValid(caster) then return end

		-- ── Final icy explosion at the beam's last hitpoint ───────────────────
		local finalOrigin = caster:EyePos() + currentDir * 550
		local impactTr    = util.TraceLine({
			start  = finalOrigin,
			endpos = finalOrigin + currentDir * MAX_BEAM_DIST,
			mask   = MASK_SOLID_BRUSHONLY,
			filter = caster,
		})
		local impactPos   = impactTr.Hit and impactTr.HitPos or (finalOrigin + currentDir * MAX_BEAM_DIST)
		local blastRadius = 1200
		local freezeDur   = 30
		local dotDamage   = BEAM_DMG_TICK * 0.4
		local dotInterval = 2
		local dotTicks    = math.floor(freezeDur / dotInterval)

		-- Initial blast: massive damage + deep freeze on every entity in radius
		for _, ent in ipairs(ents.FindInSphere(impactPos, blastRadius)) do
			if not IsValid(ent) or ent == caster then continue end
			if not (ent:IsPlayer() or ent:IsNPC() or (ent.IsNextBot and ent:IsNextBot())) then continue end

			local dmg = DamageInfo()
			dmg:SetDamage(BEAM_DMG_TICK * 10)
			dmg:SetDamageType(DMG_DISSOLVE)
			dmg:SetAttacker(caster)
			dmg:SetInflictor(caster)
			Arcana:TakeDamageInfo(ent, dmg)

			if IsValid(ent) then
				Arcana.Status.Frost.Apply(ent, {
					slowMult = 0.05,
					duration = freezeDur,
					vfxTag   = "oblivion_final_freeze",
				})
			end
		end

		-- Frostbite DOT: 2-second ticks for the full 30-second freeze duration
		for i = 1, dotTicks do
			timer.Simple(i * dotInterval, function()
				if not IsValid(caster) then return end
				for _, ent in ipairs(ents.FindInSphere(impactPos, blastRadius)) do
					if not IsValid(ent) or ent == caster then continue end
					if not (ent:IsPlayer() or ent:IsNPC() or (ent.IsNextBot and ent:IsNextBot())) then continue end
					local dmg2 = DamageInfo()
					dmg2:SetDamage(dotDamage)
					dmg2:SetDamageType(DMG_DISSOLVE)
					dmg2:SetAttacker(caster)
					dmg2:SetInflictor(caster)
					Arcana:TakeDamageInfo(ent, dmg2)
				end
			end)
		end

		util.ScreenShake(impactPos,       35, 200, 5.0, 7000)
		util.ScreenShake(caster:GetPos(), 25, 150, 3.0, 4000)
		sound.Play("ambient/explosions/explode_9.wav",          impactPos, 135, 30)
		sound.Play("ambient/energy/whiteflash.wav",             impactPos, 125, 55)
		sound.Play("ambient/atmosphere/thunder1.wav",           impactPos, 118, 32)

		net.Start("Arcana_IceOblivionRay_FinalExplosion")
		net.WriteVector(impactPos)
		net.WriteFloat(blastRadius)
		net.WriteFloat(freezeDur)
		net.Broadcast()

		-- Standard beam-end cleanup (circles, beam fade)
		net.Start("Arcana_IceOblivionRay_BeamEnd")
		net.WriteEntity(caster)
		net.Broadcast()
	end)
end

Arcana:RegisterSpell({
	id = "ice_oblivion_ray",
	name = "Oblivion Ray",
	description = "Channel the frozen void into a devastating beam of oblivion. Obliterates all in its path and deeply freezes anything that dares survive.",
	category = Arcana.CATEGORIES.COMBAT,
	level_required = 60,
	knowledge_cost = 7,
	cooldown = 600.0,
	cost_type = Arcana.COST_TYPES.COINS,
	cost_amount = 750000,
	cast_time = CAST_TIME,
	range = 0,
	is_divine_pact = true,
	is_projectile = false,
	has_target = false,
	cast_anim = "forward",
	cast = function(caster, _, _, ctx)
		if not SERVER then return true end
		if not IsValid(caster) then return false end
		startBeamPhase(caster)
		return true
	end,
	trigger_phrase_aliases = { "oblivion ray", "ice ray" }
})

-- ─── CLIENT ──────────────────────────────────────────────────────────────────

if CLIENT then
	local MagicCircle = Arcana.Circle.MagicCircle

	local matBeam       = Material("effects/laser1")
	local matGlow       = Material("sprites/light_glow02_add")
	local matFlare      = Material("effects/blueflare1")
	local matSelectRing = Material("effects/select_ring")

	local activeBeam      = nil
	local castingData     = {}
	local lightningArcs   = {}
	local impactNovaRings = {}
	local iceSpikes       = {}
	local finalExplosions = {}

	-- Returns two unit vectors (right, up) orthogonal to dir and to each other.
	-- "up" points toward world-up as much as possible.
	local function getPerpendicularBasis(dir)
		local right = dir:Cross(Vector(0, 0, 1))
		if right:LengthSqr() < 0.0001 then
			right = dir:Cross(Vector(1, 0, 0))
		end
		right:Normalize()
		local up = right:Cross(dir)
		up:Normalize()
		return right, up
	end

	-- Builds a zigzag lightning arc as a sequence of world-space points.
	local function generateLightningArc(startPos, endPos, numSegments)
		numSegments = numSegments or 9
		local arcDir    = (endPos - startPos):GetNormalized()
		local right, up = getPerpendicularBasis(arcDir)
		local points    = { startPos }

		for i = 1, numSegments - 1 do
			local t       = i / numSegments
			local basePos = LerpVector(t, startPos, endPos)
			local jitter  = (right * math.Rand(-1, 1) + up * math.Rand(-1, 1)) * math.Rand(15, 40)
			points[#points + 1] = basePos + jitter
		end

		points[#points + 1] = endPos
		return points
	end

	-- Converts an aim direction vector into a MagicCircle angle whose canvas is
	-- perpendicular to the beam.  cam.Start3D2D uses the angle's Up vector as the
	-- canvas normal; Angle(0,yaw,0):Up() = world-up = flat/horizontal disc, so we
	-- add 90 to pitch to rotate the canvas to face along the aim direction.
	local function aimToCircleAngle(aimVec)
		local a = aimVec:Angle()
		return Angle(a.p + 90, a.y, 0)
	end

	-- Fades all circles/bands stored in castingData for a caster (cast phase + beam phase).
	local function fadeAllCastingCircles(caster, fadeDur)
		local d = castingData[caster]
		if not d then return end
		fadeDur = fadeDur or 0.5
		for _, cd in ipairs(d.barrelCircles or {}) do
			if cd.circle and cd.circle.StartFadeOut then cd.circle:StartFadeOut(fadeDur) end
		end
		for _, sd in ipairs(d.muzzleSatellites or {}) do
			if sd.circle and sd.circle.StartFadeOut then sd.circle:StartFadeOut(fadeDur) end
		end
		for _, bd in ipairs(d.bandCircles or {}) do
			if bd.bc and bd.bc.StartFadeOut then bd.bc:StartFadeOut(fadeDur) end
		end
		-- Beam-phase fast-rotating rings at the origin
		for _, bc in ipairs(d.beamBandCircles or {}) do
			if bc and bc.StartFadeOut then bc:StartFadeOut(fadeDur) end
		end
	end

	-- Returns a point near the caster: preferably on nearby ground, otherwise a
	-- floating point beside the player.
	local function getArcTarget(casterPos)
		local tr = util.TraceLine({
			start  = casterPos + Vector(0, 0, 10),
			endpos = casterPos - Vector(0, 0, 160),
			mask   = MASK_SOLID_BRUSHONLY,
		})
		if tr.Hit then return tr.HitPos end
		local ang  = math.Rand(0, math.pi * 2)
		local dist = math.Rand(60, 140)
		return casterPos + Vector(math.cos(ang) * dist, math.sin(ang) * dist, math.Rand(0, 70))
	end

	-- ── Casting VFX: directional cannon assembly ──────────────────────────────

	hook.Add("Arcana_BeginCastingVisuals", "Arcana_IceOblivionRay_CastCharge", function(caster, spellId, castTime)
		if spellId ~= "ice_oblivion_ray" then return end
		if not IsValid(caster) then return end

		local color          = COLOR
		local startTime      = CurTime()
		local barrelCircles  = {}
		local bandCircles    = {}
		local muzzleSatellites = {}
		local spinSpeed      = (math.pi * 2) / 5  -- full orbit every 5 seconds
		local MUZZLE_DIST    = 550

	-- Circles must survive both the 10s cast AND the 15s beam; give them the full span.
	local totalDuration = castTime + BEAM_DURATION

	castingData[caster] = {
		startTime        = startTime,
		castTime         = castTime,
		barrelCircles    = barrelCircles,
		bandCircles      = bandCircles,
		muzzleSatellites = muzzleSatellites,
		arcStarted       = false,
		nextArcTime      = 0,
		nextCrackleTime  = 0,
		currentMuzzlePos = nil,
	}

		-- t=0 ── First barrel ring (closest to caster)
		do
			local aimVec = caster:GetAimVector()
			local eyePos = caster:EyePos()
			local c = MagicCircle.CreateMagicCircle(eyePos + aimVec * 100, aimToCircleAngle(aimVec), color, 5, 160, totalDuration, 2)
			if c and c.StartEvolving then
				c:StartEvolving(castTime)
				barrelCircles[#barrelCircles + 1] = { circle = c, dist = 100 }
			end
			sound.Play("weapons/physcannon/energy_sing_explosion2.wav", eyePos, 88, 85)
			sound.Play("ambient/energy/weld1.wav", eyePos, 83, 90)
		end

		-- t=2 ── Second barrel ring
		timer.Simple(2, function()
			if not IsValid(caster) or not castingData[caster] then return end
			local aimVec   = caster:GetAimVector()
			local eyePos   = caster:EyePos()
			local remaining = castTime - 2
			local c = MagicCircle.CreateMagicCircle(eyePos + aimVec * 210, aimToCircleAngle(aimVec), color, 5, 140, totalDuration, 2)
			if c and c.StartEvolving then
				c:StartEvolving(remaining)
				barrelCircles[#barrelCircles + 1] = { circle = c, dist = 210 }
			end
			sound.Play("weapons/physcannon/energy_sing_explosion2.wav", eyePos, 90, 82)
			sound.Play("ambient/energy/weld" .. math.random(1, 2) .. ".wav", eyePos, 85, 85)
			util.ScreenShake(eyePos, 3, 80, 0.3, 400)
		end)

		-- t=3.5 ── Third barrel ring + first orbital BandCircle
		timer.Simple(3.5, function()
			if not IsValid(caster) or not castingData[caster] then return end
			local aimVec    = caster:GetAimVector()
			local eyePos    = caster:EyePos()
			local remaining = castTime - 3.5
			local c = MagicCircle.CreateMagicCircle(eyePos + aimVec * 325, aimToCircleAngle(aimVec), color, 6, 120, totalDuration, 2)
			if c and c.StartEvolving then
				c:StartEvolving(remaining)
				barrelCircles[#barrelCircles + 1] = { circle = c, dist = 325 }
			end
			if BandCircle then
				local bc = BandCircle.Create(eyePos + aimVec * 200, Angle(0, 0, 0), color, 340, totalDuration)
				if bc then
					bc:AddBand(170, 8, { p = 0, y = 60, r = 0 }, 3)
					bandCircles[#bandCircles + 1] = { bc = bc, dist = 200 }
				end
			end
			sound.Play("weapons/physcannon/energy_sing_explosion2.wav", eyePos, 92, 78)
			sound.Play("ambient/levels/labs/electric_explosion" .. math.random(1, 5) .. ".wav", eyePos, 88, 80)
			util.ScreenShake(eyePos, 4, 90, 0.4, 500)
		end)

		-- t=5 ── Fourth barrel ring
		timer.Simple(5, function()
			if not IsValid(caster) or not castingData[caster] then return end
			local aimVec    = caster:GetAimVector()
			local eyePos    = caster:EyePos()
			local remaining = castTime - 5
			local c = MagicCircle.CreateMagicCircle(eyePos + aimVec * 445, aimToCircleAngle(aimVec), color, 6, 100, totalDuration, 2)
			if c and c.StartEvolving then
				c:StartEvolving(remaining)
				barrelCircles[#barrelCircles + 1] = { circle = c, dist = 445 }
			end
			sound.Play("weapons/physcannon/energy_sing_explosion2.wav", eyePos, 93, 75)
			util.ScreenShake(eyePos, 5, 100, 0.5, 550)
		end)

		-- t=5.5 ── First two muzzle satellites (opposite sides)
		timer.Simple(5.5, function()
			if not IsValid(caster) or not castingData[caster] then return end
			local aimVec    = caster:GetAimVector()
			local eyePos    = caster:EyePos()
			local muzzlePos = eyePos + aimVec * MUZZLE_DIST
			local right, up = getPerpendicularBasis(aimVec)
			local orbitR    = 85
			local remaining = castTime - 5.5

		for i = 0, 1 do
			local baseAngle = (i / 2) * math.pi * 2
			local radialDir = right * math.cos(baseAngle) + up * math.sin(baseAngle)
			local satPos    = muzzlePos + radialDir * orbitR
			local c = MagicCircle.CreateMagicCircle(satPos, aimToCircleAngle(radialDir), color, 5, 55, totalDuration, 2)
			if c and c.StartEvolving then
				c:StartEvolving(remaining)
				muzzleSatellites[#muzzleSatellites + 1] = {
					circle     = c,
					baseAngle  = baseAngle,
						radius     = orbitR,
						startTime  = CurTime(),
					}
				end
			end

			sound.Play("weapons/physcannon/energy_sing_explosion2.wav", eyePos, 90, 80)
			sound.Play("ambient/energy/newspark0" .. math.random(4, 8) .. ".wav", eyePos, 85, 85)
			util.ScreenShake(eyePos, 5, 110, 0.6, 600)
		end)

		-- t=7 ── Two more muzzle satellites + second BandCircle + lightning arcs begin
		timer.Simple(7, function()
			if not IsValid(caster) or not castingData[caster] then return end
			local aimVec    = caster:GetAimVector()
			local eyePos    = caster:EyePos()
			local muzzlePos = eyePos + aimVec * MUZZLE_DIST
			local right, up = getPerpendicularBasis(aimVec)
			local orbitR    = 85
			local remaining = castTime - 7

		for i = 0, 1 do
			local baseAngle = (i / 2) * math.pi * 2 + math.pi * 0.5
			local radialDir = right * math.cos(baseAngle) + up * math.sin(baseAngle)
			local satPos    = muzzlePos + radialDir * orbitR
			local c = MagicCircle.CreateMagicCircle(satPos, aimToCircleAngle(radialDir), color, 5, 55, totalDuration, 2)
				if c and c.StartEvolving then
					c:StartEvolving(remaining)
					muzzleSatellites[#muzzleSatellites + 1] = {
						circle    = c,
						baseAngle = baseAngle,
						radius    = orbitR,
						startTime = CurTime(),
					}
				end
			end

			if BandCircle then
				local bc = BandCircle.Create(eyePos + aimVec * 390, Angle(0, 0, 0), color, 220, totalDuration)
				if bc then
					bc:AddBand(110, 8, { p = 0, y = -55, r = 0 }, 2.5)
					bandCircles[#bandCircles + 1] = { bc = bc, dist = 390 }
				end
			end

			castingData[caster].arcStarted = true

			sound.Play("weapons/physcannon/energy_sing_explosion2.wav", eyePos, 95, 70)
			sound.Play("ambient/levels/labs/electric_explosion" .. math.random(1, 5) .. ".wav", eyePos, 92, 72)
			sound.Play("ambient/energy/newspark0" .. math.random(4, 8) .. ".wav", eyePos, 88, 88)
			util.ScreenShake(eyePos, 7, 120, 0.8, 700)
		end)

		-- t=8.5 ── Intensity escalates
		timer.Simple(8.5, function()
			if not IsValid(caster) or not castingData[caster] then return end
			sound.Play("ambient/energy/whiteflash.wav", caster:EyePos(), 90, 90)
			sound.Play("ambient/atmosphere/thunder" .. math.random(1, 4) .. ".wav", caster:EyePos(), 92, 50)
			util.ScreenShake(caster:EyePos(), 9, 130, 1.2, 800)
		end)

		-- t=9.5 ── Final surge before firing
		timer.Simple(9.5, function()
			if not IsValid(caster) or not castingData[caster] then return end
			sound.Play("weapons/physcannon/energy_sing_explosion2.wav", caster:EyePos(), 98, 65)
			sound.Play("ambient/levels/labs/electric_explosion" .. math.random(1, 5) .. ".wav", caster:EyePos(), 95, 68)
			sound.Play("ambient/atmosphere/thunder1.wav", caster:EyePos(), 100, 42)
			util.ScreenShake(caster:EyePos(), 12, 150, 2.0, 1000)
		end)

		-- ── Per-frame Think: keep all circles aligned to live aim direction ──────
		local updateHook = "Arcana_IceOblivionRay_CastUpdate_" .. tostring(caster)
		hook.Add("Think", updateHook, function()
			if not IsValid(caster) or not castingData[caster] then
				hook.Remove("Think", updateHook)
				return
			end

			local d         = castingData[caster]
			local aimVec    = caster:GetAimVector()
			local eyePos    = caster:EyePos()
			local circleAng = aimToCircleAngle(aimVec)
			local muzzlePos = eyePos + aimVec * MUZZLE_DIST
			local right, up = getPerpendicularBasis(aimVec)

			-- Barrel circles: discs perpendicular to the beam
			for _, cd in ipairs(d.barrelCircles) do
				if cd.circle and cd.circle.IsActive and cd.circle:IsActive() then
					cd.circle.position = eyePos + aimVec * cd.dist
					cd.circle.angles   = circleAng
				end
			end

			-- Band circles: horizontal spinning hoops, follow position along barrel
			for _, bd in ipairs(d.bandCircles) do
				if bd.bc and bd.bc.isActive then
					bd.bc.position = eyePos + aimVec * bd.dist
				end
			end

		-- Track muzzle position for the render hook
		d.currentMuzzlePos = muzzlePos

		-- Muzzle satellites: orbit around the aim axis, each facing radially outward
		for _, sd in ipairs(d.muzzleSatellites) do
			if sd.circle and sd.circle.IsActive and sd.circle:IsActive() then
				local satElapsed   = CurTime() - sd.startTime
				local currentAngle = sd.baseAngle + satElapsed * spinSpeed
				local radialDir    = right * math.cos(currentAngle) + up * math.sin(currentAngle)
				local satPos       = muzzlePos + radialDir * sd.radius
				sd.circle.position = satPos
				sd.circle.angles   = aimToCircleAngle(radialDir)
			end
		end

		-- Beam phase: drive direction and origin from live aim (very fast lerp, visual only)
		if d.beamPhase and activeBeam and activeBeam.active then
			activeBeam.dir    = (activeBeam.dir + aimVec * (FrameTime() * 12)):GetNormalized()
			activeBeam.origin = eyePos + activeBeam.dir * MUZZLE_DIST
			-- Keep beam-phase band circles anchored at the moving origin
			for _, bc in ipairs(d.beamBandCircles or {}) do
				if bc and bc.isActive then
					bc.position = activeBeam.origin
				end
			end
		end

		-- Arc generation only during cast phase (beam origin arcs are in the render hook)
		if not d.beamPhase then
			-- Long arcs: muzzle to a point near the caster (wide, bright)
			if d.arcStarted and CurTime() >= d.nextArcTime then
				d.nextArcTime = CurTime() + 0.14
				local arcTarget = getArcTarget(caster:GetPos())
				lightningArcs[#lightningArcs + 1] = {
					points    = generateLightningArc(muzzlePos, arcTarget, 10),
					startTime = CurTime(),
					lifeTime  = 0.3,
					width     = 20,
				}
			end

			-- Short crackling arcs at the muzzle (energy concentration noise)
			if d.arcStarted and CurTime() >= (d.nextCrackleTime or 0) then
				d.nextCrackleTime = CurTime() + 0.07
				local castProgress = math.Clamp((CurTime() - d.startTime) / (d.castTime or 10), 0, 1)
				local arcCount     = math.random(2, 3 + math.floor(castProgress * 3))
				for _ = 1, arcCount do
					local ang    = math.Rand(0, math.pi * 2)
					local arcLen = math.Rand(30, 100 + castProgress * 90)
					local arcEnd = muzzlePos + (right * math.cos(ang) + up * math.sin(ang)) * arcLen
					              + aimVec * math.Rand(-30, 55)
					lightningArcs[#lightningArcs + 1] = {
						points    = generateLightningArc(muzzlePos, arcEnd, 5),
						startTime = CurTime(),
						lifeTime  = 0.1,
						width     = 10,
					}
				end
			end
		end
		end)

		-- ── Casting particles: ice mist + sparks streaming toward muzzle ─────────
		local particleSteps = math.floor(castTime / 0.4)
		for step = 0, particleSteps do
			timer.Simple(step * 0.4, function()
				if not IsValid(caster) or not castingData[caster] then return end
				local progress  = step / particleSteps
				local aimVec    = caster:GetAimVector()
				local muzzlePos = caster:EyePos() + aimVec * MUZZLE_DIST
				local right, up = getPerpendicularBasis(aimVec)
				local emitter   = ParticleEmitter(muzzlePos)
				if not emitter then return end

				local count = math.floor(2 + progress * 7)
				for _ = 1, count do
					local ang  = math.Rand(0, math.pi * 2)
					local dist = math.Rand(15, 70)
					local pos  = muzzlePos + (right * math.cos(ang) + up * math.sin(ang)) * dist
					local p    = emitter:Add("particle/particle_smokegrenade", pos)
					if p then
						p:SetVelocity(aimVec * math.Rand(-20, 50) + VectorRand() * 12)
						p:SetDieTime(math.Rand(0.4, 1.0))
						p:SetStartAlpha(90)
						p:SetEndAlpha(0)
						p:SetStartSize(math.Rand(6, 16))
						p:SetEndSize(math.Rand(18, 35))
						p:SetColor(180, 220, 255)
						p:SetAirResistance(70)
					end
				end

				-- Sparks streaking inward toward the muzzle (once past 35% charge)
				if progress > 0.35 then
					local sparkCount = math.floor(progress * 6)
					for _ = 1, sparkCount do
						local ang  = math.Rand(0, math.pi * 2)
						local dist = math.Rand(40, 130)
						local pos  = muzzlePos + (right * math.cos(ang) + up * math.sin(ang)) * dist
						local p    = emitter:Add("effects/blueflare1", pos)
						if p then
							local toMuzzle = (muzzlePos - pos):GetNormalized()
							p:SetVelocity(toMuzzle * math.Rand(80, 280))
							p:SetDieTime(math.Rand(0.15, 0.45))
							p:SetStartAlpha(255)
							p:SetEndAlpha(0)
							p:SetStartSize(math.Rand(3, 9))
							p:SetEndSize(0)
							p:SetColor(150, 215, 255)
						end
					end
				end

				emitter:Finish()
			end)
		end

		-- ── Sound buildup over the charge ────────────────────────────────────────
		timer.Simple(0, function()
			if not IsValid(caster) then return end
			sound.Play("ambient/wind/wind_rooftop1.wav", caster:EyePos(), 75, 70)
		end)

		timer.Simple(castTime * 0.5, function()
			if not IsValid(caster) then return end
			sound.Play("ambient/atmosphere/thunder" .. math.random(1, 4) .. ".wav", caster:EyePos(), 88, 55)
			util.ScreenShake(caster:EyePos(), 5, 100, 1.0, 600)
		end)

		timer.Simple(castTime * 0.75, function()
			if not IsValid(caster) then return end
			sound.Play("ambient/energy/whiteflash.wav", caster:EyePos(), 88, 88)
			util.ScreenShake(caster:EyePos(), 7, 115, 1.5, 750)
		end)

		-- Safety cleanup for cast failure / timeout (skip if beam phase is active —
		-- BeamEnd handles cleanup in that case)
		timer.Simple(castTime + 2, function()
			local d2 = castingData[caster]
			if d2 and not d2.beamPhase then
				fadeAllCastingCircles(caster, 0.5)
				castingData[caster] = nil
				hook.Remove("Think", updateHook)
			end
		end)

		return true
	end)

	hook.Add("Arcana_CastSpellFailure", "Arcana_IceOblivionRay_CastCleanup", function(caster, spellId)
		if spellId ~= "ice_oblivion_ray" then return end
		if not castingData[caster] then return end
		fadeAllCastingCircles(caster, 0.5)
		hook.Remove("Think", "Arcana_IceOblivionRay_CastUpdate_" .. tostring(caster))
		castingData[caster] = nil
	end)

	-- ── Net receivers ─────────────────────────────────────────────────────────

	net.Receive("Arcana_IceOblivionRay_BeamStart", function()
		local caster     = net.ReadEntity()
		local initialDir = net.ReadVector()
		local duration   = net.ReadFloat()

		-- Transition circles to beam phase: keep tracking aim, suppress casting-phase arcs.
		-- The Think hook remains running — it will now also drive the beam direction/origin.
		if IsValid(caster) and castingData[caster] then
			castingData[caster].beamPhase   = true
			castingData[caster].arcStarted  = false  -- beam-origin arcs come from the render hook
			castingData[caster].beamBandCircles = {}

			-- Fast-rotating BandCircles at the beam origin (follow it via Think hook)
			if BandCircle then
				local origin = caster:EyePos() + initialDir * 550
				local bbc    = castingData[caster].beamBandCircles

				local bc1 = BandCircle.Create(origin, Angle(0, 0, 0), COLOR, 290, duration + 2)
				if bc1 then
					bc1:AddBand(165, 12, { p = 40,  y =  450, r = 0 }, 0.35)
					bc1:StartEvolving(0.35)
					bbc[#bbc + 1] = bc1
				end
				local bc2 = BandCircle.Create(origin, Angle(0, 0, 0), COLOR, 210, duration + 2)
				if bc2 then
					bc2:AddBand(115, 8,  { p = -25, y = -520, r = 0 }, 0.35)
					bc2:StartEvolving(0.35)
					bbc[#bbc + 1] = bc2
				end
				local bc3 = BandCircle.Create(origin, Angle(0, 0, 0), COLOR, 360, duration + 2)
				if bc3 then
					bc3:AddBand(210, 6,  { p = -55, y =  330, r = 0 }, 0.35)
					bc3:StartEvolving(0.35)
					bbc[#bbc + 1] = bc3
				end
			end
		end

		local origin = IsValid(caster) and (caster:EyePos() + initialDir * 550) or Vector(0, 0, 0)
		activeBeam = {
			caster            = caster,
			dir               = initialDir,
			radius            = 200,
			progress          = 0,
			origin            = origin,
			startTime         = CurTime(),
			duration          = duration,
			active            = true,
			nextOriginArcTime = 0,
		}

		-- Climax burst on beam ignition
		if IsValid(caster) then
			local emitter = ParticleEmitter(caster:EyePos())
			if emitter then
				local aimVec    = caster:GetAimVector()
				local right, up = getPerpendicularBasis(aimVec)
				for i = 1, 60 do
					local angle  = (i / 60) * math.pi * 2
					local orbVec = right * math.cos(angle) + up * math.sin(angle)
					local p      = emitter:Add("effects/blueflare1", caster:EyePos())
					if p then
						p:SetVelocity(aimVec * math.Rand(300, 700) + orbVec * math.Rand(100, 400))
						p:SetDieTime(math.Rand(0.4, 0.9))
						p:SetStartAlpha(255)
						p:SetEndAlpha(0)
						p:SetStartSize(math.Rand(12, 30))
						p:SetEndSize(0)
						p:SetColor(180, 230, 255)
					end
				end
				emitter:Finish()
			end
			sound.Play("weapons/physcannon/energy_disintegrate5.wav", caster:EyePos(), 120, 65)
			sound.Play("ambient/energy/whiteflash.wav", caster:EyePos(), 115, 75)
		end
	end)

	net.Receive("Arcana_IceOblivionRay_BeamTick", function()
		local origin   = net.ReadVector()
		local dir      = net.ReadVector()
		local radius   = net.ReadFloat()
		local progress = net.ReadFloat()
		if not activeBeam then return end
		-- Direction and origin are driven client-side in the Think hook for instant visual response.
		-- Only sync the server-authoritative values that can't be derived locally.
		activeBeam.radius   = radius
		activeBeam.progress = progress
	end)

	net.Receive("Arcana_IceOblivionRay_BeamEnd", function()
		local caster = net.ReadEntity()
		if activeBeam then
			activeBeam.active    = false
			activeBeam.fadeStart = CurTime()
		end

		-- Fade all circles (barrel + satellites + cast-bands + beam-bands) and tear down hook
		if IsValid(caster) and castingData[caster] then
			fadeAllCastingCircles(caster, 1.0)
			hook.Remove("Think", "Arcana_IceOblivionRay_CastUpdate_" .. tostring(caster))
			castingData[caster] = nil
		end

		if IsValid(caster) then
			local emitter = ParticleEmitter(caster:EyePos())
			if emitter then
				for _ = 1, 70 do
					local p = emitter:Add("sprites/light_glow02_add", caster:EyePos() + VectorRand() * 80)
					if p then
						p:SetVelocity(VectorRand() * math.Rand(200, 600))
						p:SetDieTime(math.Rand(0.6, 1.4))
						p:SetStartAlpha(255)
						p:SetEndAlpha(0)
						p:SetStartSize(math.Rand(25, 60))
						p:SetEndSize(0)
						p:SetColor(200, 235, 255)
					end
				end
				emitter:Finish()
			end
		end

		timer.Simple(1.5, function() activeBeam = nil end)
	end)

	net.Receive("Arcana_IceOblivionRay_ImpactNova", function()
		local pos    = net.ReadVector()
		local radius = net.ReadFloat()

		-- Three staggered expanding frost rings
		for i = 1, 3 do
			impactNovaRings[#impactNovaRings + 1] = {
				pos       = pos + Vector(0, 0, 4),
				radius    = radius * (0.5 + i * 0.22),
				startTime = CurTime() + (i - 1) * 0.07,
				duration  = 0.55 + i * 0.05,
			}
		end

		-- Ice crystal burst particles
		local emitter = ParticleEmitter(pos)
		if emitter then
			for i = 1, 38 do
				local mat = (math.random() < 0.5) and "effects/fleck_glass1" or "effects/fleck_glass2"
				local p   = emitter:Add(mat, pos)
				if p then
					local aDir = Angle(0, (i / 38) * 360 + math.Rand(-5, 5), 0):Forward()
					p:SetVelocity(aDir * math.Rand(200, 370) + Vector(0, 0, math.Rand(60, 140)))
					p:SetDieTime(math.Rand(0.5, 1.0))
					p:SetStartAlpha(255)
					p:SetEndAlpha(0)
					p:SetStartSize(math.Rand(2, 5))
					p:SetEndSize(0)
					p:SetRoll(math.Rand(0, 360))
					p:SetRollDelta(math.Rand(-8, 8))
					p:SetColor(200, 230, 255)
					p:SetAirResistance(40)
					p:SetGravity(Vector(0, 0, -220))
					p:SetCollide(true)
					p:SetBounce(0.2)
				end
			end
			-- Frost mist puff
			for _ = 1, 20 do
				local p = emitter:Add("particle/particle_smokegrenade", pos + VectorRand() * 18)
				if p then
					p:SetVelocity(VectorRand() * 75 + Vector(0, 0, 45))
					p:SetDieTime(math.Rand(0.5, 1.2))
					p:SetStartAlpha(75)
					p:SetEndAlpha(0)
					p:SetStartSize(12)
					p:SetEndSize(34)
					p:SetColor(200, 225, 255)
					p:SetAirResistance(65)
				end
			end
			emitter:Finish()
		end

		-- Cold DynamicLight flash at impact
		local dl = DynamicLight(math.random(50000, 59999))
		if dl then
			dl.Pos        = pos
			dl.r          = 80
			dl.g          = 200
			dl.b          = 255
			dl.Brightness = 7
			dl.Size       = radius * 0.85
			dl.Decay      = 2000
			dl.DieTime    = CurTime() + 0.3
		end

		-- Outward lightning arcs from impact point
		for _ = 1, 7 do
			local ang    = math.Rand(0, math.pi * 2)
			local arcEnd = pos + Vector(math.cos(ang) * math.Rand(80, radius), math.sin(ang) * math.Rand(80, radius), math.Rand(-20, 30))
			lightningArcs[#lightningArcs + 1] = {
				points    = generateLightningArc(pos, arcEnd, 6),
				startTime = CurTime(),
				lifeTime  = 0.28,
				width     = 10,
			}
		end

		sound.Play("ambient/levels/canals/windchime2.wav",       pos, 78, 130)
		sound.Play("physics/glass/glass_impact_bullet1.wav",     pos, 72, 125)
	end)

	net.Receive("Arcana_IceOblivionRay_FinalExplosion", function()
		local pos       = net.ReadVector()
		local radius    = net.ReadFloat()
		local freezeDur = net.ReadFloat()

		-- Eight large staggered expanding frost rings
		for i = 1, 8 do
			impactNovaRings[#impactNovaRings + 1] = {
				pos       = pos + Vector(0, 0, 4),
				radius    = radius * (0.12 + i * 0.13),
				startTime = CurTime() + (i - 1) * 0.05,
				duration  = 1.8 + i * 0.12,
			}
		end

		-- Persistent 30-second ground frost zone
		finalExplosions[#finalExplosions + 1] = {
			pos       = pos + Vector(0, 0, 2),
			radius    = radius,
			startTime = CurTime(),
			duration  = freezeDur,
		}

		-- Massive particle burst
		local emitter = ParticleEmitter(pos)
		if emitter then
			-- Ice shards flying in all directions
			for i = 1, 130 do
				local mat = (math.random() < 0.5) and "effects/fleck_glass1" or "effects/fleck_glass2"
				local p   = emitter:Add(mat, pos + VectorRand() * 40)
				if p then
					local d = VectorRand():GetNormalized()
					p:SetVelocity(d * math.Rand(400, 1100))
					p:SetDieTime(math.Rand(1.2, 2.8))
					p:SetStartAlpha(255)
					p:SetEndAlpha(0)
					p:SetStartSize(math.Rand(3, 9))
					p:SetEndSize(0)
					p:SetRoll(math.Rand(0, 360))
					p:SetRollDelta(math.Rand(-7, 7))
					p:SetColor(200, 230, 255)
					p:SetAirResistance(25)
					p:SetGravity(Vector(0, 0, -320))
					p:SetCollide(true)
					p:SetBounce(0.3)
				end
			end
			-- Snow/frost mist cloud
			for _ = 1, 70 do
				local p = emitter:Add("particle/particle_smokegrenade", pos + VectorRand() * 80)
				if p then
					p:SetVelocity(VectorRand() * 140 + Vector(0, 0, 90))
					p:SetDieTime(math.Rand(3.0, 6.0))
					p:SetStartAlpha(90)
					p:SetEndAlpha(0)
					p:SetStartSize(math.Rand(25, 65))
					p:SetEndSize(math.Rand(80, 160))
					p:SetColor(200, 225, 255)
					p:SetAirResistance(50)
				end
			end
			-- Bright ice flares burst
			for _ = 1, 55 do
				local p = emitter:Add("effects/blueflare1", pos + VectorRand() * 30)
				if p then
					p:SetVelocity(VectorRand() * math.Rand(500, 1300))
					p:SetDieTime(math.Rand(0.5, 1.4))
					p:SetStartAlpha(255)
					p:SetEndAlpha(0)
					p:SetStartSize(math.Rand(20, 55))
					p:SetEndSize(0)
					p:SetColor(180, 225, 255)
				end
			end
			emitter:Finish()
		end

		-- Massive DynamicLight flash
		local dl = DynamicLight(math.random(60000, 69999))
		if dl then
			dl.Pos        = pos
			dl.r          = 100
			dl.g          = 200
			dl.b          = 255
			dl.Brightness = 14
			dl.Size       = radius * 1.8
			dl.Decay      = 600
			dl.DieTime    = CurTime() + 1.2
		end

		-- Dense ring of ice spikes erupting from the ground around impact
		local numSpikes = 36
		for i = 1, numSpikes do
			local ang  = (i / numSpikes) * 360 + math.Rand(-8, 8)
			local d    = Angle(0, ang, 0):Forward()
			local dist = math.Rand(radius * 0.08, radius * 0.88)
			local startPos = pos + d * dist + Vector(0, 0, 90)
			local tr   = util.TraceLine({
				start  = startPos,
				endpos = startPos + Vector(0, 0, -350),
				mask   = MASK_SOLID_BRUSHONLY,
			})
			if tr.Hit then
				iceSpikes[#iceSpikes + 1] = {
					pos    = tr.HitPos + tr.HitNormal * 2,
					normal = tr.HitNormal,
					height = math.Rand(100, 260),
					life   = 1.5,
					die    = CurTime() + 1.5,
				}
			end
		end

		-- Web of lightning arcs exploding outward from impact
		for _ = 1, 18 do
			local ang    = math.Rand(0, math.pi * 2)
			local arcLen = math.Rand(250, radius * 0.75)
			local arcEnd = pos + Vector(math.cos(ang) * arcLen, math.sin(ang) * arcLen, math.Rand(-60, 120))
			lightningArcs[#lightningArcs + 1] = {
				points    = generateLightningArc(pos, arcEnd, 8),
				startTime = CurTime(),
				lifeTime  = 0.45,
				width     = 16,
			}
		end

		sound.Play("ambient/explosions/explode_9.wav",        pos, 135, 28)
		sound.Play("ambient/energy/whiteflash.wav",           pos, 128, 58)
		sound.Play("ambient/atmosphere/thunder1.wav",         pos, 120, 30)
		sound.Play("ambient/levels/canals/windchime2.wav",    pos, 95,  90)
	end)

	-- ── Rendering ─────────────────────────────────────────────────────────────

	hook.Add("PostDrawTranslucentRenderables", "Arcana_IceOblivionRay_Render", function()
		local curTime = CurTime()

		-- Lightning arcs (both casting phase and beam side-discharge)
		if #lightningArcs > 0 then
			render.SetMaterial(matBeam)
			for i = #lightningArcs, 1, -1 do
				local arc = lightningArcs[i]
				if curTime > arc.startTime + arc.lifeTime then
					table.remove(lightningArcs, i)
					continue
				end

			local frac      = 1 - (curTime - arc.startTime) / arc.lifeTime
			local numPts    = #arc.points
			local arcWidth  = arc.width or 5
			render.StartBeam(numPts)
			for j, pt in ipairs(arc.points) do
				local t = (j - 1) / (numPts - 1)
				local w = (1 - math.abs(t - 0.5) * 1.3) * arcWidth * frac
				render.AddBeam(pt, math.max(w, 0.3), t, Color(200, 235, 255, math.floor(240 * frac)))
			end
			render.EndBeam()
			end
		end

	-- Casting muzzle concentration glow (cast phase only; beam phase has its own glow)
	for caster, d in pairs(castingData) do
		if not IsValid(caster) or not d.currentMuzzlePos or not d.arcStarted then continue end
		if d.beamPhase then continue end
		local mPos      = d.currentMuzzlePos
		local elapsed   = curTime - d.startTime
		local progress  = math.Clamp(elapsed / (d.castTime or 10), 0, 1)
		local pulse     = 1 + math.sin(curTime * 14) * 0.35
		local baseSize  = Lerp(progress, 40, 200) * pulse

		render.SetMaterial(matFlare)
		render.DrawSprite(mPos, baseSize,        baseSize,        Color(255, 255, 255, math.floor(210 * progress)))
		render.SetMaterial(matGlow)
		render.DrawSprite(mPos, baseSize * 2.4,  baseSize * 2.4,  Color(80, 200, 255,  math.floor(180 * progress)))
		render.DrawSprite(mPos, baseSize * 5,    baseSize * 5,    Color(50, 150, 255,  math.floor(70  * progress)))

		local dl = DynamicLight(caster:EntIndex() + 5000)
		if dl then
			dl.Pos        = mPos
			dl.r          = 100
			dl.g          = 200
			dl.b          = 255
			dl.Brightness = 6 * progress * pulse
			dl.Size       = baseSize * 4
			dl.DieTime    = curTime + 0.15
		end
	end

	-- Active beam
	if not activeBeam then return end

		local beam     = activeBeam
		local fadeFrac = 1
		if not beam.active and beam.fadeStart then
			fadeFrac = math.Clamp(1 - (curTime - beam.fadeStart) / 1.5, 0, 1)
		end
		if fadeFrac <= 0 then return end

		local origin = beam.origin
		local dir    = beam.dir
		local radius = beam.radius

		-- Client-side trace to find actual beam endpoint for clean rendering
		local tr = util.TraceLine({
			start  = origin,
			endpos = origin + dir * MAX_BEAM_DIST,
			mask   = MASK_SOLID_BRUSHONLY,
			filter = IsValid(beam.caster) and { beam.caster } or {},
		})
		local endPos  = tr.Hit and tr.HitPos or (origin + dir * MAX_BEAM_DIST)
		local beamLen = origin:Distance(endPos)
		if beamLen < 1 then return end

	local age    = curTime - beam.startTime
	local scroll = age * 0.4
	local pulse  = 1 + math.sin(age * 18) * 0.09
	local steps  = math.max(12, math.floor(beamLen / 150))

	render.SetMaterial(matBeam)

	-- Layer 1: Brilliant white-hot core
	render.StartBeam(steps + 1)
	for j = 0, steps do
		local t = j / steps
		render.AddBeam(origin + dir * (beamLen * t), radius * 0.5 * pulse * fadeFrac, t * beamLen / 400 + scroll, Color(255, 255, 255, math.floor(255 * fadeFrac)))
	end
	render.EndBeam()

	-- Layer 2: Main ice-blue beam
	render.StartBeam(steps + 1)
	for j = 0, steps do
		local t = j / steps
		render.AddBeam(origin + dir * (beamLen * t), radius * 1.2 * fadeFrac, t * beamLen / 512 + scroll * 0.7, Color(80, 200, 255, math.floor(220 * fadeFrac)))
	end
	render.EndBeam()

	-- Layer 3: Outer frost glow
	render.StartBeam(steps + 1)
	for j = 0, steps do
		local t = j / steps
		render.AddBeam(origin + dir * (beamLen * t), radius * 2.8 * fadeFrac, t * beamLen / 700, Color(120, 210, 255, math.floor(65 * fadeFrac)))
	end
	render.EndBeam()

	-- Layer 4: Wide wispy frozen haze
	render.StartBeam(steps + 1)
	for j = 0, steps do
		local t = j / steps
		render.AddBeam(origin + dir * (beamLen * t), radius * 5.0 * fadeFrac, t * beamLen / 900, Color(200, 235, 255, math.floor(22 * fadeFrac)))
	end
	render.EndBeam()

	-- ── Helix ──────────────────────────────────────────────────────────────────
	-- Adaptive resolution: fewer points for short beams, capped for long ones
	local hRight, hUp    = getPerpendicularBasis(dir)
	local helixSteps     = math.min(24, math.max(12, math.floor(beamLen / 350)))
	local innerR         = radius * 0.28
	local outerR         = radius * 0.55
	-- Negative multiplier on curTime = phase advances in +t direction = moves toward hitpoint
	local innerScroll    = -curTime * 1.5 * math.pi * 2
	local outerScroll    =  curTime * 0.7 * math.pi * 2  -- counter-rotates for depth
	local innerFreq      = 3.0
	local outerFreq      = 2.0

	render.SetMaterial(matBeam)

	-- 3 tight inner strands
	for h = 0, 2 do
		local phaseOff = (h / 3) * math.pi * 2
		render.StartBeam(helixSteps + 1)
		for j = 0, helixSteps do
			local t      = j / helixSteps
			local angle  = t * innerFreq * math.pi * 2 + phaseOff + innerScroll
			local orbR   = innerR * fadeFrac
			local orbPos = origin + dir * (beamLen * t)
			             + hRight * math.cos(angle) * orbR
			             + hUp    * math.sin(angle) * orbR
			local alpha  = math.floor(200 * fadeFrac * (0.65 + 0.35 * math.sin(t * math.pi)))
			render.AddBeam(orbPos, 18 * fadeFrac, t * beamLen / 300, Color(200, 240, 255, alpha))
		end
		render.EndBeam()
	end

	-- 2 loose outer strands (counter-rotating)
	for h = 0, 1 do
		local phaseOff = (h / 2) * math.pi * 2 + math.pi * 0.4
		render.StartBeam(helixSteps + 1)
		for j = 0, helixSteps do
			local t      = j / helixSteps
			local angle  = t * outerFreq * math.pi * 2 + phaseOff + outerScroll
			local orbR   = outerR * fadeFrac
			local orbPos = origin + dir * (beamLen * t)
			             + hRight * math.cos(angle) * orbR
			             + hUp    * math.sin(angle) * orbR
			local alpha  = math.floor(65 * fadeFrac * (0.5 + 0.5 * math.sin(t * math.pi)))
			render.AddBeam(orbPos, 22 * fadeFrac, t * beamLen / 500, Color(80, 200, 255, alpha))
		end
		render.EndBeam()
	end

	-- Glowing orbiting nodes: flow from origin toward hitpoint, fade in/out, then loop
	render.SetMaterial(matGlow)
	local beadSpeed      = 0.45  -- full beam length traversed per second
	local beadsPerStrand = 4
	for h = 0, 2 do
		local phaseOff = (h / 3) * math.pi * 2
		for n = 0, beadsPerStrand - 1 do
			-- t advances with time and loops 0→1
			local t     = (curTime * beadSpeed + n / beadsPerStrand) % 1
			local angle = t * innerFreq * math.pi * 2 + phaseOff + innerScroll
			local orbR  = innerR * fadeFrac
			local nPos  = origin + dir * (beamLen * t)
			            + hRight * math.cos(angle) * orbR
			            + hUp    * math.sin(angle) * orbR
			-- sin(t*π) = 0 at origin, peaks at midpoint, 0 at hitpoint → smooth fade in/out
			local tFade = math.sin(t * math.pi)
			local alpha = math.floor(230 * fadeFrac * tFade)
			local nSize = radius * 0.5 * fadeFrac * (0.4 + 0.6 * tFade)
			render.DrawSprite(nPos, nSize, nSize, Color(220, 248, 255, alpha))
		end
	end
	render.SetMaterial(matBeam)  -- restore for following side-arcs code

	-- Muzzle (beam origin) glow
	render.SetMaterial(matFlare)
	render.DrawSprite(origin, radius * 4   * fadeFrac, radius * 4   * fadeFrac, Color(255, 255, 255, math.floor(230 * fadeFrac)))
	render.SetMaterial(matGlow)
	render.DrawSprite(origin, radius * 7   * fadeFrac, radius * 7   * fadeFrac, Color(80, 200, 255,  math.floor(190 * fadeFrac)))
	render.DrawSprite(origin, radius * 12  * fadeFrac, radius * 12  * fadeFrac, Color(50, 150, 255,  math.floor(70  * fadeFrac)))

	-- Impact glow at hit point
	render.SetMaterial(matFlare)
	render.DrawSprite(endPos, radius * 5   * fadeFrac, radius * 5   * fadeFrac, Color(220, 245, 255, math.floor(200 * fadeFrac)))
	render.SetMaterial(matGlow)
	render.DrawSprite(endPos, radius * 8   * fadeFrac, radius * 8   * fadeFrac, Color(80, 200, 255,  math.floor(160 * fadeFrac)))
	render.DrawSprite(endPos, radius * 14  * fadeFrac, radius * 14  * fadeFrac, Color(50, 150, 255,  math.floor(60  * fadeFrac)))

	-- DynamicLight at beam origin (casts ice-blue light on the world)
	local baseEntIdx = IsValid(beam.caster) and beam.caster:EntIndex() or 0
	local dl = DynamicLight(baseEntIdx + 10000)
	if dl then
		dl.Pos        = origin
		dl.r          = 100
		dl.g          = 210
		dl.b          = 255
		dl.Brightness = 5 * fadeFrac * pulse
		dl.Size       = radius * 4
		dl.DieTime    = curTime + 0.15
	end

	-- DynamicLight at impact point
	local dlImpact = DynamicLight(baseEntIdx + 20000)
	if dlImpact then
		dlImpact.Pos        = endPos
		dlImpact.r          = 80
		dlImpact.g          = 200
		dlImpact.b          = 255
		dlImpact.Brightness = 4 * fadeFrac
		dlImpact.Size       = radius * 3.5
		dlImpact.DieTime    = curTime + 0.15
	end

	-- Intermediate DynamicLight along beam for even illumination
	if beamLen > 1500 then
		local dlMid = DynamicLight(baseEntIdx + 30000)
		if dlMid then
			local midPt      = origin + dir * (beamLen * 0.45)
			dlMid.Pos        = midPt
			dlMid.r          = 80
			dlMid.g          = 200
			dlMid.b          = 255
			dlMid.Brightness = 3 * fadeFrac
			dlMid.Size       = radius * 3
			dlMid.DieTime    = curTime + 0.15
		end
	end

	-- Frequent side-discharge arcs off the beam surface (cryo noise)
	local right, up = getPerpendicularBasis(dir)
	if math.random() < 0.28 then
		local t      = math.Rand(0.05, 0.95)
		local beamPt = origin + dir * (beamLen * t)
		local ang    = math.Rand(0, math.pi * 2)
		local arcEnd = beamPt + (right * math.cos(ang) + up * math.sin(ang)) * radius * math.Rand(1.2, 2.5)
		lightningArcs[#lightningArcs + 1] = {
			points    = generateLightningArc(beamPt, arcEnd, 6),
			startTime = curTime,
			lifeTime  = 0.14,
			width     = 7,
		}
	end

	-- Continuous lightning arcs erupting from the beam origin
	if beam.active and curTime >= (beam.nextOriginArcTime or 0) then
		beam.nextOriginArcTime = curTime + 0.08
		for _ = 1, math.random(2, 4) do
			local ang    = math.Rand(0, math.pi * 2)
			local arcLen = math.Rand(120, radius * 2.8)
			local arcEnd = origin + (right * math.cos(ang) + up * math.sin(ang)) * arcLen
			             + Vector(0, 0, math.Rand(-80, 80))
			local tr2 = util.TraceLine({ start = origin, endpos = arcEnd, mask = MASK_SOLID_BRUSHONLY })
			lightningArcs[#lightningArcs + 1] = {
				points    = generateLightningArc(origin, tr2.Hit and tr2.HitPos or arcEnd, 7),
				startTime = curTime,
				lifeTime  = 0.2,
				width     = 14,
			}
		end
	end

	-- Expanding frost nova rings from impact point (server-triggered, see ImpactNova receiver)
	if #impactNovaRings > 0 then
		render.SetMaterial(matSelectRing)
		for i = #impactNovaRings, 1, -1 do
			local r = impactNovaRings[i]
			if curTime > r.startTime + r.duration then
				table.remove(impactNovaRings, i)
				continue
			end
			local frac  = (curTime - r.startTime) / r.duration
			frac        = math.Clamp(frac, 0, 1)
			local curr  = Lerp(frac, 10, r.radius)
			local alpha = math.floor(210 * (1 - frac))
			render.DrawQuadEasy(r.pos, Vector(0, 0, 1), curr, curr, Color(170, 220, 255, alpha), 0)
		end
		render.SetMaterial(matGlow)
		for _, r in ipairs(impactNovaRings) do
			local frac  = math.Clamp((curTime - r.startTime) / r.duration, 0, 1)
			local curr  = Lerp(frac, 10, r.radius)
			render.DrawSprite(r.pos, curr * 0.4, curr * 0.4, Color(130, 210, 255, math.floor(100 * (1 - frac))))
		end
	end

	-- Ice spikes from final explosion (and impact nova)
	if #iceSpikes > 0 then
		render.SetMaterial(matBeam)
		for i = #iceSpikes, 1, -1 do
			local s = iceSpikes[i]
			if curTime > s.die then table.remove(iceSpikes, i) continue end
			local t    = math.Clamp(1 - (s.die - curTime) / s.life, 0, 1)
			local grow = math.EaseInOut(t, 0.2, 0.6)
			local tip  = s.pos + s.normal * (s.height * grow)
			render.StartBeam(2)
			render.AddBeam(s.pos, 10, 0, Color(210, 235, 255, math.floor(230 * (1 - t * 0.5))))
			render.AddBeam(tip,    2, 1, Color(210, 235, 255, math.floor(230 * (1 - t * 0.5))))
			render.EndBeam()
			render.StartBeam(2)
			render.AddBeam(s.pos, 18, 0, Color(170, 215, 255, math.floor(130 * (1 - t))))
			render.AddBeam(tip,    4, 1, Color(170, 215, 255, math.floor(130 * (1 - t))))
			render.EndBeam()
			render.SetMaterial(matGlow)
			render.DrawSprite(tip, 16, 16, Color(210, 245, 255, math.floor(200 * (1 - t))))
			render.SetMaterial(matBeam)
		end
	end

	-- Persistent ground frost zone from final explosion (fades over 30s)
	if #finalExplosions > 0 then
		render.SetMaterial(matSelectRing)
		for i = #finalExplosions, 1, -1 do
			local fx = finalExplosions[i]
			if curTime > fx.startTime + fx.duration then
				table.remove(finalExplosions, i)
				continue
			end
			local frac  = (curTime - fx.startTime) / fx.duration
			local alpha = math.floor(70 * (1 - frac))
			local pulse = 1 + math.sin(curTime * 0.8) * 0.06
			render.DrawQuadEasy(fx.pos + Vector(0, 0, 2), Vector(0, 0, 1), fx.radius * pulse, fx.radius * pulse, Color(160, 215, 255, alpha), 0)
		end
		render.SetMaterial(matGlow)
		for _, fx in ipairs(finalExplosions) do
			local frac = math.Clamp((curTime - fx.startTime) / fx.duration, 0, 1)
			local pulse = 1 + math.sin(curTime * 0.8) * 0.06
			render.DrawSprite(fx.pos, fx.radius * 0.25 * pulse, fx.radius * 0.25 * pulse, Color(80, 180, 255, math.floor(50 * (1 - frac))))
		end
	end
	end)
end
