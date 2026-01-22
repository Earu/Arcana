-- Fallen Down: A devastating super-tier spell inspired by Overlord
-- Charges for 60 seconds with spectacular magic circle array, then unleashes a godly beam from the heavens
if SERVER then
	util.AddNetworkString("Arcana_FallenDown_BeamStart")
	util.AddNetworkString("Arcana_FallenDown_BeamTick")
	util.AddNetworkString("Arcana_FallenDown_ImpactWave")
	util.AddNetworkString("Arcana_FallenDown_VacuumImplosion")
	util.AddNetworkString("Arcana_FallenDown_VacuumCollapse")
	util.AddNetworkString("Arcana_FallenDown_BGM")

	resource.AddFile("sound/arcana/fallen_down/bgm.wav")
	resource.AddFile("sound/arcana/fallen_down/blast.wav")
	resource.AddFile("sound/arcana/fallen_down/after_blast.wav")
end

local CHARGE_TIME = 60.0
local BEAM_DURATION = 15.0 -- Grows for first 10s, stays at max for last 5s
local MAX_BEAM_RADIUS = 2000 -- Doubled for massive devastation
local BEAM_DAMAGE_PER_TICK = 1000000 -- 1 million damage per tick - instant obliteration
-- Track players currently charging this spell
local chargingPlayers = {}

-- Prevent movement during charge (server-side)
if SERVER then
	hook.Add("SetupMove", "Arcana_FallenDown_LockMovement", function(ply, mv, cmd)
		local state = chargingPlayers[ply]
		if not state then return end
		if not state.charging then return end
		-- Allow looking around but prevent all movement
		mv:SetForwardSpeed(0)
		mv:SetSideSpeed(0)
		mv:SetUpSpeed(0)
		-- Keep player in place
		mv:SetVelocity(Vector(0, 0, 0))

		-- Prevent jumping
		if cmd:KeyDown(IN_JUMP) then
			cmd:RemoveKey(IN_JUMP)
		end
	end)
end

local function cleanupChargingState(ply, stopBGM)
	if not IsValid(ply) then return end
	chargingPlayers[ply] = nil

	-- Stop BGM if interrupted
	if SERVER and stopBGM then
		net.Start("Arcana_FallenDown_BGM", true)
		net.WriteEntity(ply)
		net.WriteBool(false) -- Stop
		net.Broadcast()
	end
end

-- Cleanup on death/disconnect
if SERVER then
	hook.Add("PlayerDeath", "Arcana_FallenDown_Cleanup", function(ply)
		cleanupChargingState(ply, true) -- Stop BGM on death
	end)

	hook.Add("PlayerDisconnected", "Arcana_FallenDown_Cleanup", function(ply)
		cleanupChargingState(ply, true) -- Stop BGM on disconnect
	end)

	-- Set up charging state when spell casting begins
	hook.Add("Arcana_BeginCasting", "Arcana_FallenDown_StartCharging", function(caster, spellId)
		if spellId ~= "fallen_down" then return end
		if not IsValid(caster) then return end

		-- Mark player as charging (movement lock starts immediately)
		chargingPlayers[caster] = {
			charging = true,
			startTime = CurTime()
		}

		-- Start BGM
		net.Start("Arcana_FallenDown_BGM", true)
		net.WriteEntity(caster)
		net.WriteBool(true) -- Start
		net.Broadcast()
	end)

	-- Clean up charging state if spell cast fails
	hook.Add("Arcana_CastSpellFailure", "Arcana_FallenDown_CleanupOnFail", function(caster, spellId)
		if spellId ~= "fallen_down" then return end
		cleanupChargingState(caster, true) -- Stop BGM on failure
	end)
end

local function startBeamPhase(caster, targetPos)
	if not SERVER then return end
	if not IsValid(caster) then return end
	-- Clean up charging state
	cleanupChargingState(caster)
	-- Announce beam start to clients (they handle all sounds)
	net.Start("Arcana_FallenDown_BeamStart", true)
	net.WriteEntity(caster)
	net.WriteVector(targetPos)
	net.WriteFloat(BEAM_DURATION)
	net.Broadcast()
	-- Initial MASSIVE screen shake
	util.ScreenShake(targetPos, 30, 150, 3.0, MAX_BEAM_RADIUS * 2)
	local startTime = CurTime()
	local endTime = startTime + BEAM_DURATION
	-- Damage tick rate
	local damageTickRate = 0.1
	local damageTicks = math.floor(BEAM_DURATION / damageTickRate)

	for tick = 0, damageTicks do
		timer.Simple(tick * damageTickRate, function()
			if not IsValid(caster) then return end
			local elapsed = CurTime() - startTime
			local progress = math.Clamp(elapsed / BEAM_DURATION, 0, 1)
			-- Beam grows for first 10s, stays at max for last 5s (10/15 = 0.666...)
			local growthProgress = math.Clamp(progress * 1.5, 0, 1) -- Reaches 1.0 at 66.6% (10s out of 15s)
			local currentRadius = Lerp(growthProgress, 50, MAX_BEAM_RADIUS)
			-- Broadcast current beam state for visuals
			net.Start("Arcana_FallenDown_BeamTick", true)
			net.WriteVector(targetPos)
			net.WriteFloat(currentRadius)
			net.WriteFloat(progress)
			net.Broadcast()

			-- Apply damage to everything in the growing beam
			for _, ent in ipairs(ents.FindInSphere(targetPos, currentRadius)) do
				if not IsValid(ent) then continue end
				if ent == caster then continue end
				local isLiving = ent:IsPlayer() or ent:IsNPC() or (ent.IsNextBot and ent:IsNextBot())

				if isLiving then
					-- Obliterate living things with GODLY damage - 1 million per tick
					local dmg = DamageInfo()
					dmg:SetDamage(BEAM_DAMAGE_PER_TICK)
					dmg:SetDamageType(DMG_DISSOLVE)
					dmg:SetAttacker(caster)
					dmg:SetInflictor(caster)
					Arcane:TakeDamageInfo(ent, dmg)
				else
					-- Ignite everything else
					if ent:IsOnFire() == false then
						ent:Ignite(10, 0)
					end

					-- Apply force to physics objects
					local phys = ent:GetPhysicsObject()

					if IsValid(phys) then
						local dir = (ent:WorldSpaceCenter() - targetPos):GetNormalized()
						dir.z = math.abs(dir.z) + 0.5
						phys:Wake()
						phys:ApplyForceCenter(dir * 50000 * progress)
					end
				end
			end

			-- Periodic screen shake - more intense as beam grows
			if tick % 3 == 0 then
				util.ScreenShake(targetPos, 15 * progress, 120, 0.6, currentRadius * 1.5)
			end

			-- Periodic powerful rumble sounds
			if tick % 8 == 0 then
				sound.Play("ambient/atmosphere/thunder" .. math.random(1, 4) .. ".wav", targetPos, 105, 60 + math.random(-10, 10))
			end

			-- Additional crackling energy sounds
			if tick % 12 == 5 then
				sound.Play("ambient/levels/labs/electric_explosion" .. math.random(1, 5) .. ".wav", targetPos, 100, 75)
			end

			-- Periodic explosions as things vaporize
			if tick % 20 == 0 then
				sound.Play("ambient/explosions/explode_" .. math.random(1, 9) .. ".wav", targetPos, 95, 70 + math.random(-15, 15))
			end
		end)
	end

	-- Final explosion at the end
	timer.Simple(BEAM_DURATION, function()
		if not IsValid(caster) then return end
		-- Stop ALL continuous beam sounds
		caster:StopSound("ambient/energy/force_field_loop1.wav")
		caster:StopSound("ambient/atmosphere/city_rumble_loop1.wav")
		caster:StopSound("weapons/physcannon/superphys_launch3.wav")
		caster:StopSound("ambient/wind/wind_rooftop1.wav")
		caster:StopSound("ambient/atmosphere/ambience01.wav")
		-- Absolutely MASSIVE final blast with layered sounds
		sound.Play("ambient/explosions/explode_9.wav", targetPos, 130, 40) -- Deepest explosion
		sound.Play("ambient/explosions/explode_8.wav", targetPos, 128, 50)

		timer.Simple(0.1, function()
			sound.Play("ambient/explosions/explode_7.wav", targetPos, 125, 60)
			sound.Play("weapons/physcannon/energy_disintegrate4.wav", targetPos, 120, 65)
		end)

		timer.Simple(0.2, function()
			sound.Play("ambient/energy/whiteflash.wav", targetPos, 125, 70)
			sound.Play("ambient/atmosphere/thunder" .. math.random(1, 4) .. ".wav", targetPos, 120, 50)
		end)

		util.ScreenShake(targetPos, 40, 200, 4.0, MAX_BEAM_RADIUS * 2.5)
		-- Final damage wave
		Arcane:BlastDamage(caster, caster, targetPos, MAX_BEAM_RADIUS, 200, bit.bor(DMG_BLAST, DMG_DISSOLVE), true)
		-- Broadcast final impact wave
		net.Start("Arcana_FallenDown_ImpactWave", true)
		net.WriteVector(targetPos)
		net.Broadcast()

		-- VACUUM IMPLOSION PHASE - Air rushes in violently after 0.5 seconds
		timer.Simple(0.5, function()
			if not IsValid(caster) then return end
			-- Broadcast vacuum implosion start
			net.Start("Arcana_FallenDown_VacuumImplosion", true)
			net.WriteVector(targetPos)
			net.WriteFloat(MAX_BEAM_RADIUS)
			net.Broadcast()
			-- Eerie vacuum sounds
			sound.Play("ambient/wind/wind_snippet5.wav", targetPos, 120, 30) -- Rushing air (low pitch)
			sound.Play("ambient/atmosphere/hole_hit" .. math.random(1, 5) .. ".wav", targetPos, 115, 40) -- Void sound
			local implosionDuration = 3.0 -- 3 seconds of violent suction
			local implosionTicks = 30
			local tickRate = implosionDuration / implosionTicks

			for tick = 0, implosionTicks do
				timer.Simple(tick * tickRate, function()
					if not IsValid(caster) then return end
					local suctionProgress = tick / implosionTicks
					local suctionStrength = math.sin(suctionProgress * math.pi) -- Peak in middle
					-- Pull everything towards center
					local ents = ents.FindInSphere(targetPos, MAX_BEAM_RADIUS * 1.5)

					for _, ent in ipairs(ents) do
						if IsValid(ent) and ent ~= caster then
							local dir = (targetPos - ent:WorldSpaceCenter()):GetNormalized()
							local distance = ent:WorldSpaceCenter():Distance(targetPos)
							local pullForce = (1 - (distance / (MAX_BEAM_RADIUS * 1.5))) * suctionStrength
							-- Apply physics force
							local phys = ent:GetPhysicsObject()

							if IsValid(phys) then
								phys:Wake()
								phys:ApplyForceCenter(dir * 150000 * pullForce)
							end

							-- Pull players/NPCs
							if ent:IsPlayer() or ent:IsNPC() then
								local vel = ent:GetVelocity()
								ent:SetVelocity(vel + dir * 40 * pullForce)
							end

							-- Damage entities caught in implosion
							if tick % 10 == 0 and (ent:IsPlayer() or ent:IsNPC()) then
								local dmg = DamageInfo()
								dmg:SetDamage(15000 * suctionStrength)
								dmg:SetDamageType(DMG_CRUSH)
								dmg:SetAttacker(caster)
								dmg:SetInflictor(caster)
								Arcane:TakeDamageInfo(ent, dmg)
							end
						end
					end

					-- Periodic vacuum sounds
					if tick % 8 == 0 then
						sound.Play("ambient/wind/wind_hit" .. math.random(1, 3) .. ".wav", targetPos, 110, 40 + (suctionProgress * 30))
					end

					-- Screen shake
					if tick % 5 == 0 then
						util.ScreenShake(targetPos, 15 + (suctionProgress * 10), 150, 0.4, MAX_BEAM_RADIUS * 2)
					end
				end)
			end

			-- Final implosion collapse
			timer.Simple(implosionDuration, function()
				if not IsValid(caster) then return end
				-- Massive collapse sounds - MUCH MORE INTENSE
				sound.Play("ambient/explosions/explode_9.wav", targetPos, 135, 40) -- Deep explosion
				sound.Play("ambient/explosions/explode_8.wav", targetPos, 133, 50)
				sound.Play("physics/body/body_medium_break" .. math.random(2, 4) .. ".wav", targetPos, 130, 30)

				timer.Simple(0.1, function()
					sound.Play("ambient/atmosphere/thunder" .. math.random(1, 4) .. ".wav", targetPos, 128, 35)
					sound.Play("weapons/physcannon/energy_disintegrate5.wav", targetPos, 125, 55)
				end)

				timer.Simple(0.2, function()
					sound.Play("ambient/energy/whiteflash.wav", targetPos, 125, 60)
					sound.Play("ambient/explosions/explode_7.wav", targetPos, 123, 60)
				end)

				-- Final pull damage
				Arcane:BlastDamage(caster, caster, targetPos, MAX_BEAM_RADIUS * 1.2, 100000, bit.bor(DMG_CRUSH, DMG_BLAST), true)
				util.ScreenShake(targetPos, 50, 255, 2.0, MAX_BEAM_RADIUS * 2.5)
				-- Broadcast collapse visuals
				net.Start("Arcana_FallenDown_VacuumCollapse", true)
				net.WriteVector(targetPos)
				net.WriteFloat(MAX_BEAM_RADIUS)
				net.Broadcast()
			end)
		end)
	end)
end

Arcane:RegisterSpell({
	id = "fallen_down",
	name = "Fallen Down",
	description = "A spell of absolute devastation. Charge for 60 seconds, immobilized by the spell's complexity, then unleash a godly beam from the heavens that obliterates everything in its wake.",
	category = Arcane.CATEGORIES.COMBAT,
	level_required = Arcane.Config.MAX_LEVEL,
	knowledge_cost = 15, -- It doesnt cost KPs, but XP scales off this value
	cooldown = 60 * 20, -- 20 minutes
	cost_type = Arcane.COST_TYPES.COINS,
	cost_amount = 5000000,
	cast_time = CHARGE_TIME,
	range = 2000,
	icon = "icon16/star.png",
	is_divine_pact = true,
	is_projectile = false,
	has_target = true,
	cast_anim = "becon",
	can_cast = function(caster) return true end,
	cast = function(caster, _, _, ctx)
		if not IsValid(caster) then return false end

		-- Server-side: unleash the beam immediately when cast completes
		-- (cast function is called AFTER the 60-second charge time)
		if SERVER then
			-- Re-check target position at moment of cast completion
			local finalTarget = Arcane:ResolveGroundTarget(caster, 2000)

			if not finalTarget then
				cleanupChargingState(caster, true) -- Stop BGM on targeting failure

				return false
			end

			-- Unleash beam immediately (charging is already done)
			startBeamPhase(caster, finalTarget)
		end

		return true
	end,
	trigger_phrase_aliases = {"fallen down", "super tier",}
})

if CLIENT then
	local matBeam = Material("effects/laser1")
	local matGlow = Material("sprites/light_glow02_add")
	local matFlare = Material("effects/blueflare1")
	local matRing = Material("effects/select_ring")
	-- Active beams being rendered
	local activeBeams = {}
	-- Lightning arc system for phase 2
	local fallenDownLightningArcs = {}
	local fallenDownCircleData = {} -- Store circle data per caster

	-- ============================================================================
	-- FIRST-PERSON HUD FOR CASTER
	-- ============================================================================
	-- Ancient Greek character sets (GMod compatible)
	local RUNES = {"Α", "Β", "Γ", "Δ", "Ε", "Ζ", "Η", "Θ", "Ι", "Κ", "Λ", "Μ", "Ν", "Ξ", "Ο", "Π", "Ρ", "Σ", "Τ", "Υ", "Φ", "Χ", "Ψ", "Ω", "α", "β", "γ", "δ", "ε", "ζ", "η", "θ", "ι", "κ", "λ", "μ", "ν", "ξ", "ο", "π", "ρ", "σ", "ς", "τ", "υ", "φ", "χ", "ψ", "ω"}

	-- Uppercase Greek
	-- Lowercase Greek
	local SYSTEM_MESSAGES = {">>> PROTOCOL GAMMA-5 INITIATED", ">>> OVERRIDE SEQUENCE ACTIVE", ">>> MANA FLUX STABILIZING", ">>> DIMENSIONAL ANCHOR LOCKED", ">>> REALITY BREACH IMMINENT", ">>> ARCANE MATRIX SYNCHRONIZING", ">>> SUPER-TIER AUTHORIZATION GRANTED", ">>> WARNING: POWER LEVELS CRITICAL", ">>> VOID SIGNATURE DETECTED", ">>> FAILSAFE PROTOCOLS DISABLED"}

	-- Terminal state for Phase 1
	local terminalLines = {}
	local terminalNextCharTime = 0
	local terminalCharDelay = 0.015 -- 15ms per character (faster)
	local terminalLineDelay = 0.2 -- 200ms between lines (faster)
	local currentlyTypingLine = nil -- Track which line is currently being typed
	local phase1Complete = false -- Track when Phase 1 terminal is done
	local phase1CompleteTime = 0 -- When Phase 1 completed
	local transitionDuration = 1.5 -- 1.5 second transition with noise
	-- Big runes for Phase 2
	local bigRunesList = {}
	local matrixStreams = {}
	-- FOV state
	local currentFOVModifier = 0
	local fovActive = false

	local function resetHUDState()
		terminalLines = {}
		terminalNextCharTime = 0
		currentlyTypingLine = nil
		phase1Complete = false
		phase1CompleteTime = 0
		bigRunesList = {}
		matrixStreams = {}
		-- Reset FOV
		currentFOVModifier = 0
		fovActive = false
	end

	local function getRandomRune()
		return RUNES[math.random(1, #RUNES)]
	end

	local function generateRuneLine()
		local len = math.random(15, 45) -- Varied length for better pacing
		local line = ""

		for i = 1, len do
			line = line .. getRandomRune()

			-- 30% chance to add space between runes
			if math.random() < 0.3 then
				line = line .. " "
			end
		end

		return line
	end

	-- BGM Control
	net.Receive("Arcana_FallenDown_BGM", function()
		local caster = net.ReadEntity()
		local shouldStart = net.ReadBool()
		if not IsValid(caster) then return end

		if shouldStart then
			-- Caster hears it clearly (higher volume, no DSP), others hear it in 3D with DSP
			if caster == LocalPlayer() then
				LocalPlayer():EmitSound("arcana/fallen_down/bgm.wav", 120, 100, 10) -- No DSP, louder
			else
				caster:EmitSound("arcana/fallen_down/bgm.wav", 85, 100, 10, CHAN_AUTO, SND_NOFLAGS, 22) -- 3D with DSP
			end
		else
			-- Stop for both cases
			if caster == LocalPlayer() then
				LocalPlayer():StopSound("arcana/fallen_down/bgm.wav")
			else
				caster:StopSound("arcana/fallen_down/bgm.wav")
			end
		end
	end)

	local function spawnLightningArc(caster)
		if not IsValid(caster) then return end
		local data = fallenDownCircleData[caster]
		if not data then return end
		local satelliteCircles = data.satelliteCircles or {}
		local midSatelliteCircles = data.midSatelliteCircles or {}
		local bandOrbs = data.bandOrbs or {}
		-- Collect all possible sources (satellites and orbs)
		local sources = {}

		-- Add main satellites
		for _, satData in ipairs(satelliteCircles) do
			if satData.circle and satData.circle.IsActive and satData.circle:IsActive() then
				local elapsed = CurTime() - satData.startTime
				local spinSpeed = (math.pi * 2) / 8
				local currentAngle = satData.baseAngle + (elapsed * spinSpeed)
				local offsetX = math.cos(currentAngle) * satData.radius
				local offsetY = math.sin(currentAngle) * satData.radius
				local pos = caster:GetPos() + Vector(offsetX, offsetY, satData.height)
				table.insert(sources, pos)
			end
		end

		-- Add mid satellites and their orbs
		for idx, satData in ipairs(midSatelliteCircles) do
			if satData.circle and satData.circle.IsActive and satData.circle:IsActive() then
				local elapsed = CurTime() - satData.startTime
				local spinSpeed = (math.pi * 2) / 10
				local currentAngle = satData.baseAngle + (elapsed * spinSpeed)
				local offsetX = math.cos(currentAngle) * satData.radius
				local offsetY = math.sin(currentAngle) * satData.radius
				local pos = caster:GetPos() + Vector(offsetX, offsetY, satData.height)
				table.insert(sources, pos)

				-- Add orbs
				for _, orbData in ipairs(bandOrbs) do
					if orbData.parentSatIndex == (idx - 1) and orbData.bc and orbData.bc.isActive then
						local orbOffsetX = math.cos(currentAngle) * (satData.radius + orbData.orbDistance)
						local orbOffsetY = math.sin(currentAngle) * (satData.radius + orbData.orbDistance)
						local orbPos = caster:GetPos() + Vector(orbOffsetX, orbOffsetY, orbData.height)
						table.insert(sources, orbPos)
					end
				end
			end
		end

		if #sources == 0 then return end
		-- Pick random source
		local startPos = sources[math.random(1, #sources)]
		-- Find ground position within 1000 units
		local angle = math.random() * math.pi * 2
		local dist = math.Rand(300, 1000) -- Increased min distance for visibility
		local targetPos = caster:GetPos() + Vector(math.cos(angle) * dist, math.sin(angle) * dist, 0)

		-- Trace to ground
		local tr = util.TraceLine({
			start = targetPos + Vector(0, 0, 5000),
			endpos = targetPos - Vector(0, 0, 5000),
			mask = MASK_SOLID_BRUSHONLY
		})

		local endPos = tr.HitPos + Vector(0, 0, 5)

		-- Create lightning arc
		table.insert(fallenDownLightningArcs, {
			startPos = startPos,
			endPos = endPos,
			dieTime = CurTime() + 0.3, -- Slightly longer duration (was 0.25)
			startTime = CurTime()
		})

		-- Impact effect at ground with sound
		local ed = EffectData()
		ed:SetOrigin(endPos)
		ed:SetScale(2)
		util.Effect("ElectricSpark", ed, true, true)
		-- Impact sounds (layered for better effect)
		sound.Play("ambient/energy/spark" .. math.random(1, 6) .. ".wav", endPos, 70, math.random(90, 110))
		sound.Play("ambient/energy/zap" .. math.random(1, 3) .. ".wav", endPos, 68, math.random(100, 120))

		-- Small explosion impact
		-- 70% chance for extra impact
		if math.random() < 0.7 then
			timer.Simple(0.05, function()
				sound.Play("weapons/physcannon/energy_bounce" .. math.random(1, 2) .. ".wav", endPos, 65, math.random(130, 150))
			end)
		end
	end

	-- Override the default casting visuals for Fallen Down
	-- Client-side cleanup function for interruption
	local function cleanupClientVisuals(caster)
		if not IsValid(caster) then return end
		-- Remove all hooks for this caster
		local chargeSoundHook = "Arcana_FallenDown_ChargeSounds_" .. tostring(caster)
		local particleHook = "Arcana_FallenDown_ChargeParticles_" .. tostring(caster)
		local renderHook = "Arcana_FallenDown_RenderCircles_" .. tostring(caster)
		local lightHook = "Arcana_FallenDown_ChargeLight_" .. tostring(caster)
		local shakeHook = "Arcana_FallenDown_ChargeShake_" .. tostring(caster)
		local screenHook = "Arcana_FallenDown_ChargeScreen_" .. tostring(caster)
		hook.Remove("Think", chargeSoundHook)
		hook.Remove("Think", particleHook)
		hook.Remove("PostDrawTranslucentRenderables", renderHook)
		hook.Remove("Think", lightHook)
		hook.Remove("Think", shakeHook)
		hook.Remove("RenderScreenspaceEffects", screenHook)
		timer.Remove("Arcana_FallenDown_MenacingSounds_" .. tostring(caster))
		-- Clear lightning arcs and circle data
		table.Empty(fallenDownLightningArcs)

		-- Remove all magic circles
		if fallenDownCircleData[caster] then
			local data = fallenDownCircleData[caster]

			-- Remove main vertical stacked circles
			if data.circles then
				for _, circleData in ipairs(data.circles) do
					if circleData.circle and circleData.circle.Remove then
						circleData.circle:Remove()
					end
				end
			end

			-- Remove satellite circles
			if data.satelliteCircles then
				for _, circle in ipairs(data.satelliteCircles) do
					if circle and circle.Remove then
						circle:Remove()
					end
				end
			end

			-- Remove mid satellite circles
			if data.midSatelliteCircles then
				for _, circle in ipairs(data.midSatelliteCircles) do
					if circle and circle.Remove then
						circle:Remove()
					end
				end
			end

			-- Remove band circles
			if data.bandCircles then
				for _, bc in ipairs(data.bandCircles) do
					if bc and bc.Remove then
						bc:Remove()
					end
				end
			end

			-- Remove band orbs (which may have circles attached)
			if data.bandOrbs then
				for _, orb in ipairs(data.bandOrbs) do
					if orb.circles then
						for _, circle in ipairs(orb.circles) do
							if circle and circle.Remove then
								circle:Remove()
							end
						end
					end
				end
			end

			fallenDownCircleData[caster] = nil
		end

		-- Reset HUD state if this is the local player
		if caster == LocalPlayer() then
			resetHUDState()
		end

		-- Stop all looping sounds
		if IsValid(caster) then
			caster:StopSound("ambient/wind/wind_rooftop1.wav")
			caster:StopSound("ambient/wind/wind_snippet1.wav")
			caster:StopSound("ambient/atmosphere/cave_hit1.wav")
			caster:StopSound("ambient/energy/weld1.wav")
			caster:StopSound("ambient/energy/weld2.wav")
			caster:StopSound("ambient/energy/whiteflash.wav")
			caster:StopSound("ambient/atmosphere/tone_quiet.wav")
			caster:StopSound("ambient/atmosphere/tone_alley.wav")
			caster:StopSound("ambient/energy/force_field_loop1.wav")
			caster:StopSound("ambient/atmosphere/ambience5.wav")
			caster:StopSound("ambient/levels/citadel/citadel_ambient_scream_loop1.wav")
			caster:StopSound("ambient/atmosphere/city_rumble_loop1.wav")
			caster:StopSound("ambient/atmosphere/cave_hit2.wav")
			caster:StopSound("ambient/atmosphere/cave_hit3.wav")
			caster:StopSound("weapons/physcannon/physcannon_charge.wav")

			-- Stop thunder sounds (may have electrical crackling)
			for i = 1, 4 do
				caster:StopSound("ambient/atmosphere/thunder" .. i .. ".wav")
			end
		end
	end

	hook.Add("Arcana_BeginCastingVisuals", "Arcana_FallenDown_ChargingCircles", function(caster, spellId, castTime, _)
		if spellId ~= "fallen_down" then return end
		if not IsValid(caster) then return end
		if not MagicCircle then return end

		-- Reset HUD state IMMEDIATELY if this is the local player casting
		if caster == LocalPlayer() then
			resetHUDState()
		end

		-- Create a structured array of magic circles
		local circles = {}
		local satelliteCircles = {}
		local midSatelliteCircles = {}
		local bandCircles = {}
		local bandOrbs = {}
		local color = Color(170, 220, 255, 255) -- Bright blue-white/cyan like in the anime

		-- Store circle data for lightning arcs, HUD, and cleanup
		fallenDownCircleData[caster] = {
			circles = circles, -- Main vertical stacked circles
			satelliteCircles = satelliteCircles,
			midSatelliteCircles = midSatelliteCircles,
			bandCircles = bandCircles,
			bandOrbs = bandOrbs,
			startTime = CurTime()
		}

		-- Define all circle parameters
		local stackHeights = {80, 200, 350, 550, 780}

		local stackSizes = {120, 180, 240, 320, 240}

		local stackIntensities = {5, 6, 7, 9, 7}

		-- Ramp-up timing: all circles should be visible by 1/3 of cast time (20 seconds)
		local rampUpTime = castTime / 3
		local startTime = CurTime()

		-- Ground circle appears first (immediately)
		timer.Simple(0, function()
			if not IsValid(caster) then return end
			if not fallenDownCircleData[caster] then return end -- Spell was interrupted
			local groundCircle = MagicCircle.CreateMagicCircle(caster:GetPos() + Vector(0, 0, 2), Angle(0, 0, 0), color, 6, 150, castTime, 2)

			if groundCircle and groundCircle.StartEvolving then
				groundCircle:StartEvolving(castTime, true)

				circles[#circles + 1] = {
					circle = groundCircle,
					height = 2
				}
			end

			-- Quick, loud "lock in" sound for ground circle - layered
			local lockPitch = 85
			caster:EmitSound("ambient/energy/weld1.wav", 95, lockPitch, 1.0) -- Sharp energy hit (base)
			caster:EmitSound("weapons/physcannon/energy_sing_explosion2.wav", 80, lockPitch - 10, 0.6) -- Deep impact
		end)

		-- First 3 stacked circles appear progressively
		for i = 1, 3 do
			local delay = (i / 6) * rampUpTime -- Spread evenly: ~3.33s, ~6.67s, ~10s

			timer.Simple(delay, function()
				if not IsValid(caster) then return end
				if not fallenDownCircleData[caster] then return end -- Spell was interrupted
				local circle = MagicCircle.CreateMagicCircle(caster:GetPos() + Vector(0, 0, stackHeights[i]), Angle(0, 0, 0), color, stackIntensities[i], stackSizes[i], castTime - delay, 3)

				if circle and circle.StartEvolving then
					circle:StartEvolving(castTime - delay, true)

					circles[#circles + 1] = {
						circle = circle,
						height = stackHeights[i]
					}
				end

				-- Quick, loud "lock in" sound
				local lockPitch = 85
				local volume = 88 + (i * 2) -- 90, 92, 94
				caster:EmitSound("weapons/physcannon/energy_sing_explosion2.wav", volume - 12, lockPitch - 10, 0.6)
			end)
		end

		-- Satellite configuration
		local satelliteHeight = stackHeights[4]
		local satelliteRadius = stackSizes[4] * 0.95
		local satelliteSize = 60
		-- Band and satellite timing
		local bandHeightOffset = 80
		local lowerBandHeight = satelliteHeight - bandHeightOffset
		local upperBandHeight = satelliteHeight + bandHeightOffset
		local lowerBandRadius = satelliteRadius + bandHeightOffset
		local upperBandRadius = satelliteRadius - bandHeightOffset
		local bandsDelay = (3 / 6) * rampUpTime + 0.5 -- 0.5s after circle 3 (~10.5s)
		local satelliteStartDelay = bandsDelay + 0.5 -- Start 0.5s after bands (~11s)
		local satelliteSpacing = 0.5 -- 0.5 seconds between each satellite
		local satelliteStartTime = startTime + satelliteStartDelay
		-- Circle 4 (biggest) appears AFTER all satellites with a louder, deeper thump
		local circle4Delay = satelliteStartDelay + (8 * satelliteSpacing) -- After last satellite (~15s)

		timer.Simple(circle4Delay, function()
			if not IsValid(caster) then return end
			if not fallenDownCircleData[caster] then return end -- Spell was interrupted
			local circle = MagicCircle.CreateMagicCircle(caster:GetPos() + Vector(0, 0, stackHeights[4]), Angle(0, 0, 0), color, stackIntensities[4], stackSizes[4], castTime - circle4Delay, 3)

			if circle and circle.StartEvolving then
				circle:StartEvolving(castTime - circle4Delay, true)

				circles[#circles + 1] = {
					circle = circle,
					height = stackHeights[4]
				}
			end

			-- LOUDER, DEEPER thump for the 4th circle
			local lockPitch = 70 -- Deeper than normal (was 85)
			local volume = 100 -- Much louder
			caster:EmitSound("weapons/physcannon/energy_sing_explosion2.wav", volume - 10, lockPitch - 15, 0.8) -- Extra deep
			caster:EmitSound("ambient/levels/labs/electric_explosion" .. math.random(1, 5) .. ".wav", volume - 8, lockPitch - 20, 0.7) -- Massive impact
		end)

		-- Circle 5 appears quickly after circle 4 (accelerated)
		local circle5Delay = circle4Delay + 1.0 -- Just 1 second later (~16s)

		timer.Simple(circle5Delay, function()
			if not IsValid(caster) then return end
			if not fallenDownCircleData[caster] then return end -- Spell was interrupted
			local circle = MagicCircle.CreateMagicCircle(caster:GetPos() + Vector(0, 0, stackHeights[5]), Angle(0, 0, 0), color, stackIntensities[5], stackSizes[5], castTime - circle5Delay, 3)

			if circle and circle.StartEvolving then
				circle:StartEvolving(castTime - circle5Delay, true)

				circles[#circles + 1] = {
					circle = circle,
					height = stackHeights[5]
				}
			end

			-- LOUDER, DEEPER thump for the 5th circle
			local lockPitch = 70 -- Deeper than normal (was 85)
			local volume = 100 -- Much louder
			caster:EmitSound("weapons/physcannon/energy_sing_explosion2.wav", volume - 12, lockPitch - 10, 0.6)
			caster:EmitSound("ambient/levels/labs/electric_explosion" .. math.random(1, 5) .. ".wav", volume - 10, lockPitch - 15, 0.5)
		end)

		-- Mid-level system: band circle, 2 satellites, and orbs - all appear together
		local midSatelliteHeight = (stackHeights[2] + stackHeights[3]) / 2 -- Between 200 and 350 = 275
		local midSatelliteRadius = 150
		local midSatelliteSize = 50
		local midSystemDelay = (2.5 / 6) * rampUpTime -- ~8.33 seconds - between circle 2 (6.67s) and circle 3 (10s)
		local midSatelliteStartTime = startTime + midSystemDelay

		timer.Simple(midSystemDelay, function()
			if not IsValid(caster) then return end
			if not fallenDownCircleData[caster] then return end -- Spell was interrupted
			local remainingTime = castTime - midSystemDelay
			-- Single thump sound for entire mid-level system
			local lockPitch = 85
			local volume = 93
			caster:EmitSound("ambient/energy/newspark0" .. math.random(4, 8) .. ".wav", volume - 8, lockPitch - 5, 0.8)
			caster:EmitSound("weapons/physcannon/energy_sing_explosion2.wav", volume - 12, lockPitch - 10, 0.6)

			-- Create band circle at mid-satellite height
			if BandCircle then
				local midBandRadius = midSatelliteRadius * 0.8 -- Smaller than satellite orbit (120 vs 150)
				local bcMid = BandCircle.Create(caster:GetPos() + Vector(0, 0, midSatelliteHeight), Angle(0, 0, 0), color, midBandRadius * 2, remainingTime)

				if bcMid then
					bcMid:AddBand(midBandRadius, 10, {
						p = 0,
						y = 35,
						r = 0
					}, 2.5)

					bandCircles[#bandCircles + 1] = {
						bc = bcMid,
						height = midSatelliteHeight
					}
				end
			end

			-- Create 2 satellites and their orbs
			-- 2 satellites (0-1)
			for i = 0, 1 do
				local baseAngle = (i / 2) * math.pi * 2 -- Opposite sides (0 and 180 degrees)
				-- Facing outwards (90 degrees perpendicular to center)
				local satCircle = MagicCircle.CreateMagicCircle(caster:GetPos() + Vector(0, 0, midSatelliteHeight), Angle(90, math.deg(baseAngle), 0), color, 4, midSatelliteSize, remainingTime, 2)

				if satCircle and satCircle.StartEvolving then
					satCircle:StartEvolving(remainingTime, true)

					midSatelliteCircles[#midSatelliteCircles + 1] = {
						circle = satCircle,
						height = midSatelliteHeight,
						baseAngle = baseAngle,
						radius = midSatelliteRadius,
						startTime = midSatelliteStartTime,
						createdAt = CurTime()
					}

					-- Create 1 band circle orb in front of this satellite
					if BandCircle then
						-- Position orb in front of the satellite circle
						local orbDistance = 80 -- 80 units in front
						local angle = baseAngle
						local offsetX = math.cos(angle) * (midSatelliteRadius + orbDistance)
						local offsetY = math.sin(angle) * (midSatelliteRadius + orbDistance)
						local orb = BandCircle.Create(caster:GetPos() + Vector(offsetX, offsetY, midSatelliteHeight), Angle(0, 0, 0), color, 40, remainingTime) -- Size

						if orb then
							-- Add bands like the ritual entity
							orb:AddBand(20, 5, {
								p = 20,
								y = 60,
								r = 10
							}, 2)

							orb:AddBand(32, 4, {
								p = -30,
								y = -40,
								r = 0
							}, 2)

							orb:AddBand(26, 6, {
								p = -10,
								y = -20,
								r = 60
							}, 2)

							bandOrbs[#bandOrbs + 1] = {
								bc = orb,
								parentSatIndex = i,
								orbDistance = orbDistance,
								height = midSatelliteHeight
							}
						end
					end
				end
			end
		end)

		-- Band circle between 3rd and 4th vertical circles
		if BandCircle then
			local between3and4Height = (stackHeights[3] + stackHeights[4]) / 2 -- Between 350 and 550 = 450
			local between3and4Radius = stackSizes[3] * 1.1 -- Slightly bigger than 3rd circle (240 * 1.1 = 264)
			local between3and4Delay = rampUpTime * 0.6

			timer.Simple(between3and4Delay, function()
				if not IsValid(caster) then return end
				if not fallenDownCircleData[caster] then return end -- Spell was interrupted
				local remainingTime = castTime - between3and4Delay
				local bc3to4 = BandCircle.Create(caster:GetPos() + Vector(0, 0, between3and4Height), Angle(0, 0, 0), color, between3and4Radius * 2, remainingTime)

				if bc3to4 then
					bc3to4:AddBand(between3and4Radius, 11, {
						p = 0,
						y = -40,
						r = 0
					}, 2.8)

					bandCircles[#bandCircles + 1] = {
						bc = bc3to4,
						height = between3and4Height
					}
				end
			end)
		end

		-- 2 Band circles spawn first: one below satellites, one above, spinning opposite directions
		-- These define the satellite ring area before satellites appear
		if BandCircle then
			timer.Simple(bandsDelay, function()
				if not IsValid(caster) then return end
				if not fallenDownCircleData[caster] then return end -- Spell was interrupted
				local remainingTime = castTime - bandsDelay
				-- Single thump for both bands
				local lockPitch = 85
				local volume = 95
				caster:EmitSound("weapons/physcannon/energy_sing_explosion2.wav", volume - 12, lockPitch - 10, 0.6)
				-- Lower band circle (below satellites, spinning clockwise)
				local bcLower = BandCircle.Create(caster:GetPos() + Vector(0, 0, lowerBandHeight), Angle(0, 0, 0), color, lowerBandRadius * 2, remainingTime)

				if bcLower then
					bcLower:AddBand(lowerBandRadius, 12, {
						p = 0,
						y = 50,
						r = 0
					}, 3)

					bandCircles[#bandCircles + 1] = {
						bc = bcLower,
						height = lowerBandHeight
					}
				end

				-- Upper band circle (above satellites, spinning counter-clockwise)
				local bcUpper = BandCircle.Create(caster:GetPos() + Vector(0, 0, upperBandHeight), Angle(0, 0, 0), color, upperBandRadius * 2, remainingTime)

				if bcUpper then
					bcUpper:AddBand(upperBandRadius, 12, {
						p = 0,
						y = -50,
						r = 0
					}, 3)

					bandCircles[#bandCircles + 1] = {
						bc = bcUpper,
						height = upperBandHeight
					}
				end
			end)
		end

		-- 8 satellite circles spawn rapidly AFTER the bands with lighter thumps for each
		-- 8 satellites (0-7)
		for i = 0, 7 do
			local delay = satelliteStartDelay + (i * satelliteSpacing) -- Rapid succession

			timer.Simple(delay, function()
				if not IsValid(caster) then return end
				if not fallenDownCircleData[caster] then return end -- Spell was interrupted
				local baseAngle = (i / 8) * math.pi * 2
				-- Angled 45 degrees upward (pitch 45, facing outward)
				local satCircle = MagicCircle.CreateMagicCircle(caster:GetPos() + Vector(0, 0, satelliteHeight), Angle(45, math.deg(baseAngle), 0), color, 5, satelliteSize, castTime - delay, 2) -- 45 deg upward

				if satCircle and satCircle.StartEvolving then
					satCircle:StartEvolving(castTime - delay, true)

					satelliteCircles[#satelliteCircles + 1] = {
						circle = satCircle,
						height = satelliteHeight,
						baseAngle = baseAngle,
						radius = satelliteRadius,
						startTime = satelliteStartTime,
						createdAt = CurTime()
					}
				end

				-- Light thump for each satellite
				local lockPitch = 90 -- Higher pitch (lighter)
				local volume = 80 -- Quieter
				caster:EmitSound("ambient/energy/weld" .. math.random(1, 2) .. ".wav", volume, lockPitch, 0.7)
			end)
		end

		-- Make all circles follow the caster during charge
		local hookName = "Arcana_FallenDown_FollowCaster_" .. tostring(caster)

		hook.Add("Think", hookName, function()
			if not IsValid(caster) then
				hook.Remove("Think", hookName)

				return
			end

			-- Stop if spell was interrupted
			if not fallenDownCircleData[caster] then
				hook.Remove("Think", hookName)

				return
			end

			local casterPos = caster:GetPos()

			-- Update all main circles
			for _, circleData in ipairs(circles) do
				if circleData.circle and circleData.circle.IsActive and circleData.circle:IsActive() then
					circleData.circle.position = casterPos + Vector(0, 0, circleData.height)
				end
			end

			-- Update satellite circles (orbit around 4th circle position, spinning)
			for _, satData in ipairs(satelliteCircles) do
				if satData.circle and satData.circle.IsActive and satData.circle:IsActive() then
					-- Calculate spinning angle (one full rotation every 8 seconds)
					local elapsed = CurTime() - satData.startTime
					local spinSpeed = (math.pi * 2) / 8 -- radians per second
					local currentAngle = satData.baseAngle + (elapsed * spinSpeed)
					-- Update position in orbit
					local offsetX = math.cos(currentAngle) * satData.radius
					local offsetY = math.sin(currentAngle) * satData.radius
					satData.circle.position = casterPos + Vector(offsetX, offsetY, satData.height)
					-- Update angle to face outward and upward at 45 degrees
					satData.circle.angles = Angle(45, math.deg(currentAngle), 0)
				end
			end

			-- Update mid-level satellite circles (between 2nd and 3rd vertical circles)
			for idx, satData in ipairs(midSatelliteCircles) do
				if satData.circle and satData.circle.IsActive and satData.circle:IsActive() then
					-- Calculate spinning angle (one full rotation every 10 seconds, slower)
					local elapsed = CurTime() - satData.startTime
					local spinSpeed = (math.pi * 2) / 10 -- radians per second
					local currentAngle = satData.baseAngle + (elapsed * spinSpeed)
					-- Update position in orbit
					local offsetX = math.cos(currentAngle) * satData.radius
					local offsetY = math.sin(currentAngle) * satData.radius
					satData.circle.position = casterPos + Vector(offsetX, offsetY, satData.height)
					-- Update angle to face outward (perpendicular)
					satData.circle.angles = Angle(90, math.deg(currentAngle), 0)

					-- Update band orbs that belong to this satellite (parentSatIndex is 0 or 1, idx-1 to match)
					for _, orbData in ipairs(bandOrbs) do
						if orbData.parentSatIndex == (idx - 1) and orbData.bc and orbData.bc.isActive then
							-- Position orb in front of the satellite
							local orbOffsetX = math.cos(currentAngle) * (satData.radius + orbData.orbDistance)
							local orbOffsetY = math.sin(currentAngle) * (satData.radius + orbData.orbDistance)
							orbData.bc.position = casterPos + Vector(orbOffsetX, orbOffsetY, orbData.height)
						end
					end
				end
			end

			-- Update band circles
			for _, bcData in ipairs(bandCircles) do
				if bcData.bc and bcData.bc.isActive then
					bcData.bc.position = casterPos + Vector(0, 0, bcData.height)
				end
			end
		end)

		-- Charging aura - elegant beam rising to the sky
		-- Store aura particles for manual rendering to ensure they appear on top of circles
		local auraParticles = {}
		-- Track when charging started for phase transitions
		local chargeStartTime = CurTime()
		-- Ambient sound design for charging phases
		local chargeSoundHook = "Arcana_FallenDown_ChargeSounds_" .. tostring(caster)
		local nextAmbientSound = 0
		local phase1SoundStarted = false
		local phase2SoundStarted = false
		local phase3SoundStarted = false
		local finalPhaseStarted = false
		local nextFinalPhaseSound = 0

		hook.Add("Think", chargeSoundHook, function()
			if not IsValid(caster) then
				hook.Remove("Think", chargeSoundHook)
				timer.Remove("Arcana_FallenDown_MenacingSounds_" .. tostring(caster))

				return
			end

			-- Stop if spell was interrupted
			if not fallenDownCircleData[caster] then
				hook.Remove("Think", chargeSoundHook)
				timer.Remove("Arcana_FallenDown_MenacingSounds_" .. tostring(caster))

				return
			end

			local now = CurTime()
			local elapsed = now - chargeStartTime
			local midPhaseStart = CHARGE_TIME / 2 -- 30 seconds

			-- Phase 1: Charging phase (0-20s) - Powerful energy gathering
			if elapsed < rampUpTime and not phase1SoundStarted then
				phase1SoundStarted = true
				-- Powerful ambient base layers
				caster:EmitSound("ambient/atmosphere/cave_hit1.wav", 75, 55, 0.8) -- Deeper, louder rumble
				caster:EmitSound("ambient/energy/weld1.wav", 70, 60, 0.6) -- Energy hum base

				timer.Simple(0.3, function()
					if IsValid(caster) then
						caster:EmitSound("ambient/wind/wind_rooftop1.wav", 72, 45, 0.7) -- Deeper wind
					end
				end)

				timer.Simple(0.8, function()
					if IsValid(caster) then
						caster:EmitSound("ambient/atmosphere/tone_quiet.wav", 70, 70, 0.6) -- Ominous tone layer
					end
				end)

				nextAmbientSound = now + 2.5
			end

			-- Periodic powerful energy surges during phase 1
			if elapsed < rampUpTime and now >= nextAmbientSound then
				local progress = elapsed / rampUpTime -- 0 to 1
				local volume = 65 + (progress * 15) -- 65 to 80 - gets louder over time
				local soundChoice = math.random(1, 4)

				if soundChoice == 2 then
					-- Thunder only (no lightning in phase 1 - circles not ready yet)
					caster:EmitSound("ambient/atmosphere/thunder" .. math.random(1, 4) .. ".wav", volume - 5, 80, 0.4)
				elseif soundChoice == 3 then
					caster:EmitSound("ambient/energy/whiteflash.wav", volume - 8, 75, 0.5) -- Energy flash
				else
					caster:EmitSound("ambient/wind/wind_snippet1.wav", volume - 10, 55, 0.4) -- Wind gust
				end

				nextAmbientSound = now + math.Rand(1.5, 2.5) -- More frequent (was 2-3.5)
			end

			-- Phase 2: Power phase (20-30s) - Ominous intensification
			if elapsed >= rampUpTime and elapsed < midPhaseStart and not phase2SoundStarted then
				phase2SoundStarted = true
				-- Ominous, threatening sounds as godly power builds
				caster:EmitSound("ambient/atmosphere/tone_alley.wav", 78, 60, 0.8) -- Ominous drone
				nextAmbientSound = now + 2
			end

			-- Periodic menacing energy sounds during phase 2 WITH LIGHTNING ARCS
			if elapsed >= rampUpTime and elapsed < midPhaseStart and now >= nextAmbientSound then
				local soundChoice = math.random(1, 4)

				if soundChoice == 1 then
					-- Thunder with multiple lightning arcs
					caster:EmitSound("ambient/levels/labs/electric_explosion" .. math.random(1, 5) .. ".wav", 72, 70, 1)
					local numArcs = math.random(3, 5)

					for i = 1, numArcs do
						spawnLightningArc(caster)
					end
				elseif soundChoice == 2 then
					-- Electric explosion with arcs
					caster:EmitSound("ambient/levels/labs/electric_explosion" .. math.random(1, 5) .. ".wav", 70, 80, 1)
					local numArcs = math.random(2, 3)

					for i = 1, numArcs do
						spawnLightningArc(caster)
					end
				elseif soundChoice == 3 then
					-- Electric crackle with single arc
					caster:EmitSound("ambient/levels/labs/electric_explosion" .. math.random(1, 5) .. ".wav", 68, 60, 1)
					spawnLightningArc(caster)
				else
					-- Eerie whispers without lightning
					caster:EmitSound("ambient/levels/citadel/strange_talk" .. math.random(3, 11) .. ".wav", 60, 40, 1)
				end

				nextAmbientSound = now + math.Rand(1, 2) -- More frequent (was 2-3)
			end

			-- Phase 3: Maximum power (30-60s) - MENACING godly power
			if elapsed >= midPhaseStart and not phase3SoundStarted then
				phase3SoundStarted = true
				-- Deep, menacing, apocalyptic sounds
				caster:EmitSound("ambient/levels/citadel/citadel_ambient_scream_loop1.wav", 85, 40, 0.9) -- Distant screams/doom
				caster:EmitSound("ambient/atmosphere/city_rumble_loop1.wav", 82, 45, 0.8) -- Deep ominous rumble
				caster:EmitSound("ambient/atmosphere/cave_hit2.wav", 78, 35, 0.7) -- Very deep impact
				-- Periodic menacing impacts during final phase WITH MASSIVE LIGHTNING
				local menacingTimer = "Arcana_FallenDown_MenacingSounds_" .. tostring(caster)

				-- Every 3 seconds (was 4), more instances
				timer.Create(menacingTimer, 3, 10, function()
					if IsValid(caster) then
						local timeRemaining = CHARGE_TIME - (CurTime() - chargeStartTime)
						local isFinalFive = timeRemaining <= 5
						-- Thunder with massive lightning display
						caster:EmitSound("ambient/levels/labs/electric_explosion" .. math.random(1, 5) .. ".wav", isFinalFive and 82 or 78, 65, isFinalFive and 0.8 or 0.7)
						local numArcs = isFinalFive and math.random(6, 9) or math.random(4, 7) -- EVEN MORE in final 5s

						for i = 1, numArcs do
							spawnLightningArc(caster)
						end

						-- Follow-up electric explosion with more arcs
						timer.Simple(0.4, function()
							if IsValid(caster) then
								caster:EmitSound("ambient/levels/labs/electric_explosion" .. math.random(1, 5) .. ".wav", isFinalFive and 76 or 72, 50, isFinalFive and 0.7 or 0.6)
								local numArcs2 = isFinalFive and math.random(3, 6) or math.random(2, 4)

								for i = 1, numArcs2 do
									spawnLightningArc(caster)
								end
							end
						end)

						-- Extra intense layer in final 5 seconds
						if isFinalFive then
							timer.Simple(0.2, function()
								if IsValid(caster) then
									caster:EmitSound("ambient/energy/whiteflash.wav", 75, 70, 0.7)
									caster:EmitSound("weapons/physcannon/physcannon_charge.wav", 70, 80, 0.6)
								end
							end)
						end
					end
				end)
			end

			-- Final Phase: Last 5 seconds (55-60s) - APOCALYPTIC CLIMAX
			local finalPhaseTime = CHARGE_TIME - 5 -- 55 seconds

			if elapsed >= finalPhaseTime and not finalPhaseStarted then
				finalPhaseStarted = true
				-- Massive intensity layered sounds
				caster:EmitSound("ambient/atmosphere/city_rumble_loop1.wav", 88, 40, 1.0) -- VERY LOUD deep rumble
				caster:EmitSound("ambient/energy/force_field_loop1.wav", 85, 55, 0.9) -- Intense energy
				nextFinalPhaseSound = now + 1
			end

			-- Periodic intense bursts during final 5 seconds
			if elapsed >= finalPhaseTime and now >= nextFinalPhaseSound then
				caster:EmitSound("ambient/energy/whiteflash.wav", 78, 75, 0.7)
				caster:EmitSound("ambient/atmosphere/cave_hit3.wav", 75, 30, 0.6) -- Very deep impact
				nextFinalPhaseSound = now + math.Rand(0.8, 1.5) -- Very frequent bursts
			end
		end)

		local particleHook = "Arcana_FallenDown_ChargeParticles_" .. tostring(caster)

		hook.Add("Think", particleHook, function()
			if not IsValid(caster) then
				hook.Remove("Think", particleHook)

				return
			end

			-- Stop if spell was interrupted
			if not fallenDownCircleData[caster] then
				hook.Remove("Think", particleHook)

				return
			end

			local casterPos = caster:GetPos()
			local now = CurTime()
			local elapsed = now - chargeStartTime

			-- Phase 1: Charging phase (first 20 seconds) - particles move inward like mana crystal
			if elapsed < rampUpTime then
				-- Spawn particles around the caster that move inward
				local spawnRadius = 200
				local casterCenter = casterPos + Vector(0, 0, 50)
				-- Spawn 5-8 charging particles
				local numParticles = math.random(5, 8)

				for i = 1, numParticles do
					-- Random point around the caster
					local dir = VectorRand()
					dir:Normalize()
					local spawnPos = casterCenter + dir * spawnRadius
					spawnPos.z = spawnPos.z + math.Rand(-spawnRadius * 0.3, spawnRadius * 0.3)
					-- Velocity toward the center
					local vel = (casterCenter - spawnPos):GetNormalized() * math.Rand(120, 200)

					table.insert(auraParticles, {
						pos = spawnPos,
						velocity = vel,
						dieTime = now + math.Rand(0.6, 1.0),
						startTime = now,
						size = math.Rand(4, 8),
						alpha = 220,
						color = Color(170, 220, 255),
						isCharging = true
					})
				end
			else
				-- Phase 2: Power phase (after all circles visible) - upward beam
				local finalPhaseTime = CHARGE_TIME - 5 -- Last 5 seconds (55s)
				local isFinalPhase = elapsed >= finalPhaseTime
				-- Scale up particles in final 5 seconds
				local sizeMultiplier = isFinalPhase and 1.8 or 1.0
				local numOuterParticles = isFinalPhase and 5 or 3 -- More particles in final phase
				local velocityBoost = isFinalPhase and 100 or 0

				-- Outer aura - large glowing particles (MORE and BIGGER in final phase)
				for i = 1, numOuterParticles do
					table.insert(auraParticles, {
						pos = casterPos + Vector(0, 0, 5),
						velocity = Vector(0, 0, math.Rand(200 + velocityBoost, 300 + velocityBoost)),
						dieTime = now + math.Rand(3.5, 4.5),
						startTime = now,
						size = math.Rand(100, 140) * sizeMultiplier,
						alpha = isFinalPhase and 150 or 120, -- Brighter in final phase
						color = Color(170, 220, 255),
						isCharging = false
					})
				end

				-- Inner core - bright streak (MUCH BIGGER in final phase)
				table.insert(auraParticles, {
					pos = casterPos + Vector(0, 0, 5),
					velocity = Vector(0, 0, math.Rand(280 + velocityBoost, 380 + velocityBoost)),
					dieTime = now + math.Rand(4.0, 5.0),
					startTime = now,
					size = math.Rand(40, 60) * sizeMultiplier,
					alpha = isFinalPhase and 240 or 200, -- Much brighter in final phase
					color = Color(200, 235, 255),
					isCharging = false
				})
			end
		end)

		-- Render aura particles and orb sprites on top of everything
		local renderHook = "Arcana_FallenDown_RenderAura_" .. tostring(caster)
		local matGlow = Material("sprites/light_glow02_add")

		hook.Add("PostDrawTranslucentRenderables", renderHook, function()
			if not IsValid(caster) then
				hook.Remove("PostDrawTranslucentRenderables", renderHook)

				return
			end

			-- Stop if spell was interrupted
			if not fallenDownCircleData[caster] then
				hook.Remove("PostDrawTranslucentRenderables", renderHook)

				return
			end

			-- Don't draw particles for the caster if they're in first person
			local localPly = LocalPlayer()
			local isCasterLocalPlayer = (caster == localPly)
			local isThirdPerson = localPly:ShouldDrawLocalPlayer()

			if isCasterLocalPlayer and not isThirdPerson then
				-- Still need to update particle positions even if not rendering
				local now = CurTime()

				for i = #auraParticles, 1, -1 do
					local p = auraParticles[i]

					if now > p.dieTime then
						table.remove(auraParticles, i)
					else
						p.pos = p.pos + p.velocity * FrameTime()
					end
				end

				return
			end

			local now = CurTime()

			-- Update and render aura particles
			for i = #auraParticles, 1, -1 do
				local p = auraParticles[i]

				-- Remove dead particles
				if now > p.dieTime then
					table.remove(auraParticles, i)
				else
					-- Update position
					local dt = now - p.startTime
					p.pos = p.pos + p.velocity * FrameTime()
					-- Calculate fade
					local lifetime = p.dieTime - p.startTime
					local age = now - p.startTime
					local frac = age / lifetime
					local currentAlpha = p.alpha * (1 - frac)
					local currentSize = p.size * (1 - frac * 0.3) -- Shrink slightly as they rise
					-- Render particle
					render.SetMaterial(matGlow)
					local renderColor = Color(p.color.r, p.color.g, p.color.b, currentAlpha)
					render.DrawSprite(p.pos, currentSize, currentSize, renderColor)
				end
			end

			-- Render glowing sprites in the center of each band orb (like ritual entity)
			for idx, satData in ipairs(midSatelliteCircles) do
				if satData.circle and satData.circle.IsActive and satData.circle:IsActive() then
					local elapsed = now - satData.startTime
					local spinSpeed = (math.pi * 2) / 10
					local currentAngle = satData.baseAngle + (elapsed * spinSpeed)

					-- Find orbs for this satellite
					for _, orbData in ipairs(bandOrbs) do
						if orbData.parentSatIndex == (idx - 1) and orbData.bc and orbData.bc.isActive then
							-- Calculate orb position
							local orbOffsetX = math.cos(currentAngle) * (satData.radius + orbData.orbDistance)
							local orbOffsetY = math.sin(currentAngle) * (satData.radius + orbData.orbDistance)
							local orbPos = caster:GetPos() + Vector(orbOffsetX, orbOffsetY, orbData.height)
							-- Render pulsing sprite like ritual entity
							local t = now
							local pulse = 0.5 + 0.5 * math.sin(t * 3.2)
							local size = 50 + 15 * pulse
							render.SetMaterial(matGlow)
							render.DrawSprite(orbPos, size, size, Color(170, 220, 255, 230))
						end
					end
				end
			end
		end)

		-- Intense dynamic light during charge with blue color
		local lightHook = "Arcana_FallenDown_ChargeLight_" .. tostring(caster)

		hook.Add("Think", lightHook, function()
			if not IsValid(caster) then
				hook.Remove("Think", lightHook)

				return
			end

			-- Stop if spell was interrupted
			if not fallenDownCircleData[caster] then
				hook.Remove("Think", lightHook)

				return
			end

			local now = CurTime()
			-- Main aura light
			local dlight = DynamicLight(caster:EntIndex() + 30000)

			if dlight then
				dlight.pos = caster:GetPos() + Vector(0, 0, 100)
				dlight.r = 170
				dlight.g = 220
				dlight.b = 255
				dlight.brightness = 8
				dlight.Decay = 1000
				dlight.Size = 600
				dlight.DieTime = now + 0.2
			end

			-- Dynamic lights for each band orb (like ritual entity)
			for idx, satData in ipairs(midSatelliteCircles) do
				if satData.circle and satData.circle.IsActive and satData.circle:IsActive() then
					local elapsed = now - satData.startTime
					local spinSpeed = (math.pi * 2) / 10
					local currentAngle = satData.baseAngle + (elapsed * spinSpeed)

					for orbIdx, orbData in ipairs(bandOrbs) do
						if orbData.parentSatIndex == (idx - 1) and orbData.bc and orbData.bc.isActive then
							-- Calculate orb position
							local orbOffsetX = math.cos(currentAngle) * (satData.radius + orbData.orbDistance)
							local orbOffsetY = math.sin(currentAngle) * (satData.radius + orbData.orbDistance)
							local orbPos = caster:GetPos() + Vector(orbOffsetX, orbOffsetY, orbData.height)
							-- Create dynamic light for this orb
							local orbLight = DynamicLight(caster:EntIndex() + 31000 + orbIdx)

							if orbLight then
								orbLight.pos = orbPos
								orbLight.r = 170
								orbLight.g = 220
								orbLight.b = 255
								orbLight.brightness = 2
								orbLight.Decay = 600
								orbLight.Size = 120
								orbLight.DieTime = now + 0.1
							end
						end
					end
				end
			end
		end)

		-- Progressive screen shake (starts at 30s, intensifies until unleash)
		local shakeHook = "Arcana_FallenDown_ScreenShake_" .. tostring(caster)
		local lastShakeTime = 0

		hook.Add("Think", shakeHook, function()
			if not IsValid(caster) then
				hook.Remove("Think", shakeHook)

				return
			end

			-- Stop if spell was interrupted
			if not fallenDownCircleData[caster] then
				hook.Remove("Think", shakeHook)

				return
			end

			local now = CurTime()
			local elapsed = now - chargeStartTime
			local midPhaseStart = CHARGE_TIME / 2 -- 30 seconds

			-- Start shaking at 30 seconds
			if elapsed >= midPhaseStart then
				local shakeProgress = (elapsed - midPhaseStart) / (CHARGE_TIME / 2) -- 0 to 1 over 30 seconds
				-- Shake frequency increases over time
				local shakeInterval = Lerp(shakeProgress, 0.5, 0.05) -- From every 0.5s to every 0.05s

				if now >= lastShakeTime + shakeInterval then
					-- Shake intensity increases over time
					local amplitude = Lerp(shakeProgress, 1, 15) -- From 1 to 15
					local frequency = Lerp(shakeProgress, 1, 8) -- From 1 to 8
					local duration = Lerp(shakeProgress, 0.3, 1.0) -- From 0.3s to 1.0s
					util.ScreenShake(caster:GetPos(), amplitude, frequency, duration, 3000)
					lastShakeTime = now
				end
			end
		end)

		-- Screen effects and post-processing (starts at 30s, intensifies until unleash)
		local screenHook = "Arcana_FallenDown_ScreenEffect_" .. tostring(caster)

		hook.Add("RenderScreenspaceEffects", screenHook, function()
			if not IsValid(caster) then
				hook.Remove("RenderScreenspaceEffects", screenHook)

				return
			end

			-- Stop if spell was interrupted
			if not fallenDownCircleData[caster] then
				hook.Remove("RenderScreenspaceEffects", screenHook)

				return
			end

			local now = CurTime()
			local elapsed = now - chargeStartTime
			local midPhaseStart = CHARGE_TIME / 2 -- 30 seconds
			local finalPhaseStart = CHARGE_TIME - 2 -- 58 seconds

			-- Phase 1: Progressive effects from 30s to 58s
			--[[if elapsed >= midPhaseStart then
				local midProgress = math.Clamp((elapsed - midPhaseStart) / (CHARGE_TIME / 2), 0, 1) -- 0 to 1 over 30 seconds

				-- Color modification (brightness and contrast increase)
				local colorMod = {
					["$pp_colour_addr"] = midProgress * 0.1,
					["$pp_colour_addg"] = midProgress * 0.15,
					["$pp_colour_addb"] = midProgress * 0.2,
					["$pp_colour_brightness"] = midProgress * 0.15,
					["$pp_colour_contrast"] = 1 + (midProgress * 0.3),
					["$pp_colour_colour"] = 1 + (midProgress * 0.5),
				}
				DrawColorModify(colorMod)

				-- Bloom effect (glow intensifies)
				local bloomDarken = Lerp(midProgress, 1, 0.7)
				local bloomMultiply = Lerp(midProgress, 1, 2.5)
				local bloomSizeX = Lerp(midProgress, 1, 4)
				local bloomSizeY = Lerp(midProgress, 1, 4)
				local bloomPasses = math.floor(Lerp(midProgress, 1, 3))
				local bloomColor = Lerp(midProgress, 1, 1.5)

				DrawBloom(bloomDarken, bloomMultiply, bloomSizeX, bloomSizeY, bloomPasses, bloomColor, 1, 1, 1)

				-- Motion blur (slight distortion effect)
				local blurAmount = midProgress * 0.15
				if blurAmount > 0.01 then
					DrawMotionBlur(1 - blurAmount, blurAmount, 0.02)
				end

				-- Sharpen effect (makes everything more intense)
				local sharpenContrast = Lerp(midProgress, 0, 1.5)
				local sharpenDistance = Lerp(midProgress, 0, 2)
				if sharpenContrast > 0.1 then
					DrawSharpen(sharpenContrast, sharpenDistance)
				end
			end]]
			--
			-- Phase 2: Final intense sunbeams + white fade (58s to 60s)
			if elapsed >= finalPhaseStart then
				local finalProgress = (elapsed - finalPhaseStart) / 2 -- 0 to 1 over 2 seconds
				-- Get screen position of caster for sunbeams origin
				local casterScreenPos = caster:GetPos():ToScreen()
				-- Sunbeams effect (intensifies rapidly)
				local sunbeamDarkness = Lerp(finalProgress, 0.95, 0.1) -- Gets much brighter
				local sunbeamMultiplier = Lerp(finalProgress, 0.5, 3.5) -- Intensifies dramatically
				DrawSunbeams(sunbeamDarkness, sunbeamMultiplier, 0.15, casterScreenPos.x / ScrW(), casterScreenPos.y / ScrH())
				-- White fade overlay (grows to complete white)
				local whiteAlpha = Lerp(finalProgress, 0, 255)

				if whiteAlpha > 0 then
					-- Draw white overlay that fills the screen
					surface.SetDrawColor(255, 255, 255, whiteAlpha)
					surface.DrawRect(0, 0, ScrW(), ScrH())
				end
			end
		end)

		-- Cleanup after charge
		timer.Simple(castTime, function()
			cleanupClientVisuals(caster)
			auraParticles = {}
		end)

		return true -- We've handled the visuals
	end)

	-- Beam start: Initialize the growing beam
	net.Receive("Arcana_FallenDown_BeamStart", function()
		local caster = net.ReadEntity()
		local targetPos = net.ReadVector()
		local duration = net.ReadFloat()
		if not IsValid(caster) then return end

		-- Reset HUD state for caster when beam starts (charging complete)
		if caster == LocalPlayer() then
			resetHUDState()
		end

		-- Stop all charging phase looping sounds
		caster:StopSound("ambient/wind/wind_rooftop1.wav")
		caster:StopSound("ambient/wind/wind_snippet1.wav")
		caster:StopSound("ambient/atmosphere/cave_hit1.wav")
		caster:StopSound("ambient/energy/weld1.wav")
		caster:StopSound("ambient/energy/weld2.wav")
		caster:StopSound("ambient/energy/whiteflash.wav")
		caster:StopSound("ambient/atmosphere/tone_quiet.wav")
		caster:StopSound("ambient/atmosphere/tone_alley.wav")
		caster:StopSound("ambient/energy/force_field_loop1.wav")
		caster:StopSound("ambient/atmosphere/ambience5.wav")
		caster:StopSound("ambient/levels/citadel/citadel_ambient_scream_loop1.wav")
		caster:StopSound("ambient/atmosphere/city_rumble_loop1.wav")
		caster:StopSound("ambient/atmosphere/cave_hit2.wav")
		caster:StopSound("ambient/atmosphere/cave_hit3.wav")
		caster:StopSound("weapons/physcannon/physcannon_charge.wav")

		-- Stop thunder sounds (may have electrical crackling)
		for i = 1, 4 do
			caster:StopSound("ambient/atmosphere/thunder" .. i .. ".wav")
		end

		-- Store active beam state
		activeBeams[#activeBeams + 1] = {
			caster = caster,
			targetPos = targetPos,
			startTime = CurTime(),
			endTime = CurTime() + duration,
			duration = duration
		}

		-- APOCALYPTIC BEAM BLARE - DEAFENING initial impact (CLIENT-SIDE)
		surface.PlaySound("arcana/fallen_down/blast.wav") -- PRIMARY BLAST SOUND
		sound.Play("ambient/explosions/explode_9.wav", targetPos, 140, 45) -- MASSIVE deep explosion
		sound.Play("ambient/atmosphere/thunder1.wav", targetPos, 138, 35) -- Devastating thunder
		sound.Play("ambient/explosions/explode_8.wav", targetPos, 137, 50)

		timer.Simple(0.05, function()
			sound.Play("weapons/physcannon/energy_disintegrate5.wav", targetPos, 135, 60)
			sound.Play("ambient/energy/whiteflash.wav", targetPos, 135, 70)
		end)

		timer.Simple(0.1, function()
			sound.Play("ambient/explosions/explode_7.wav", targetPos, 133, 55)
			sound.Play("ambient/atmosphere/thunder2.wav", targetPos, 132, 40)
		end)

		timer.Simple(0.15, function()
			sound.Play("ambient/explosions/explode_4.wav", targetPos, 130, 65)
		end)

		-- SUSTAINED ROARING BEAM SOUND - Loops for entire duration at MAXIMUM volume
		caster:EmitSound("ambient/energy/force_field_loop1.wav", 135, 50, 1.0) -- Intense energy roar
		caster:EmitSound("ambient/atmosphere/city_rumble_loop1.wav", 133, 30, 1.0) -- Deep rumbling
		caster:EmitSound("weapons/physcannon/superphys_launch3.wav", 130, 45, 1.0) -- Physics cannon roar

		-- Additional sustained intensity layers
		timer.Simple(1, function()
			if IsValid(caster) then
				caster:EmitSound("ambient/energy/weld2.wav", 128, 40, 1.0)
			end
		end)

		timer.Simple(2, function()
			if IsValid(caster) then
				caster:EmitSound("ambient/explosions/explode_5.wav", 125, 60)
			end
		end)

		-- Periodic impact sounds throughout beam duration
		for i = 1, math.floor(duration / 2) do
			timer.Simple(i * 2, function()
				if not IsValid(caster) then return end
				sound.Play("ambient/atmosphere/thunder" .. math.random(1, 4) .. ".wav", targetPos, 128, math.random(35, 50))
				sound.Play("ambient/explosions/explode_" .. math.random(4, 8) .. ".wav", targetPos, 125, math.random(50, 70))
			end)
		end

		-- MASSIVE initial flash - blinding
		local dlight = DynamicLight(math.random(50000, 99999))

		if dlight then
			dlight.pos = targetPos
			dlight.r = 255
			dlight.g = 255
			dlight.b = 255
			dlight.brightness = 20 -- Even brighter
			dlight.Decay = 10000
			dlight.Size = 4000 -- Doubled size
			dlight.DieTime = CurTime() + 0.8
		end

		-- Create overwhelming particle effects for the beam impact
		local emitter = ParticleEmitter(targetPos, false)

		if emitter then
			-- Initial explosion burst
			for i = 1, 150 do
				local particle = emitter:Add("effects/softglow", targetPos + Vector(0, 0, 50))

				if particle then
					local dir = VectorRand():GetNormalized()
					particle:SetVelocity(dir * math.Rand(500, 2000))
					particle:SetLifeTime(0)
					particle:SetDieTime(math.Rand(2, 4))
					particle:SetStartAlpha(255)
					particle:SetEndAlpha(0)
					particle:SetStartSize(math.Rand(30, 80))
					particle:SetEndSize(math.Rand(5, 15))
					particle:SetColor(math.Rand(170, 255), math.Rand(220, 255), 255)
					particle:SetRoll(math.Rand(0, 360))
					particle:SetRollDelta(math.Rand(-2, 2))
					particle:SetGravity(Vector(0, 0, math.Rand(-50, 50)))
				end
			end

			-- Upward energy streaks
			for i = 1, 80 do
				local particle = emitter:Add("effects/softglow", targetPos + VectorRand() * 200)

				if particle then
					particle:SetVelocity(Vector(0, 0, math.Rand(800, 1500)))
					particle:SetLifeTime(0)
					particle:SetDieTime(math.Rand(1.5, 3))
					particle:SetStartAlpha(220)
					particle:SetEndAlpha(0)
					particle:SetStartSize(math.Rand(40, 100))
					particle:SetEndSize(math.Rand(10, 30))
					particle:SetColor(math.Rand(200, 255), math.Rand(230, 255), 255)
					particle:SetRoll(math.Rand(0, 360))
				end
			end

			emitter:Finish()
		end
	end)

	-- Beam tick: Update current radius
	net.Receive("Arcana_FallenDown_BeamTick", function()
		local targetPos = net.ReadVector()
		local currentRadius = net.ReadFloat()
		local progress = net.ReadFloat()
		-- HEAVY DUST and energy particles
		local emitter = ParticleEmitter(targetPos)

		if emitter then
			-- MASSIVE HEAVY DUST CLOUDS around cylinder edge
			for i = 1, 40 do
				local angle = math.random() * math.pi * 2
				local dist = currentRadius * math.Rand(0.95, 1.15) -- At and beyond edge
				local height = math.Rand(0, 1000)
				local pos = targetPos + Vector(math.cos(angle) * dist, math.sin(angle) * dist, height)
				-- Heavy brown/gray dust
				local p = emitter:Add("particle/smokesprites_000" .. math.random(1, 9), pos)

				if p then
					local outward = Vector(math.cos(angle), math.sin(angle), 0)
					p:SetVelocity(outward * math.Rand(100, 250) + Vector(0, 0, math.Rand(50, 150)))
					p:SetDieTime(math.Rand(2, 4))
					p:SetStartAlpha(math.Rand(180, 220))
					p:SetEndAlpha(0)
					p:SetStartSize(math.Rand(currentRadius * 0.15, currentRadius * 0.3))
					p:SetEndSize(math.Rand(currentRadius * 0.4, currentRadius * 0.6))
					p:SetColor(math.Rand(120, 160), math.Rand(110, 150), math.Rand(90, 130))
					p:SetLighting(true)
					p:SetCollide(false)
					p:SetRoll(math.Rand(0, 360))
					p:SetRollDelta(math.Rand(-1, 1))
					p:SetAirResistance(50)
				end
			end

			-- Inner energy glow particles
			for i = 1, 15 do
				local angle = math.random() * math.pi * 2
				local dist = math.Rand(0, currentRadius * 0.7)
				local pos = targetPos + Vector(math.cos(angle) * dist, math.sin(angle) * dist, math.Rand(0, 800))
				local p = emitter:Add("effects/softglow", pos)

				if p then
					p:SetVelocity(Vector(0, 0, math.Rand(1000, 2000)))
					p:SetDieTime(math.Rand(0.8, 1.5))
					p:SetStartAlpha(220)
					p:SetEndAlpha(0)
					p:SetStartSize(math.Rand(60, 120))
					p:SetEndSize(math.Rand(20, 40))
					p:SetColor(math.Rand(200, 255), math.Rand(230, 255), 255)
					p:SetLighting(false)
					p:SetCollide(false)
					p:SetRoll(math.Rand(0, 360))
				end
			end

			-- Debris and vaporization at the edge
			for i = 1, 25 do
				local angle = math.random() * math.pi * 2
				local dist = currentRadius * math.Rand(0.9, 1.0)
				local pos = targetPos + Vector(math.cos(angle) * dist, math.sin(angle) * dist, math.Rand(0, 300))
				local p = emitter:Add("effects/yellowflare", pos)

				if p then
					local dir = Vector(math.cos(angle), math.sin(angle), math.Rand(-0.2, 0.5)):GetNormalized()
					p:SetVelocity(dir * math.Rand(400, 900))
					p:SetDieTime(math.Rand(0.4, 1.0))
					p:SetStartAlpha(255)
					p:SetEndAlpha(0)
					p:SetStartSize(math.Rand(20, 45))
					p:SetEndSize(0)
					p:SetColor(255, math.Rand(180, 240), math.Rand(120, 180))
					p:SetLighting(false)
					p:SetCollide(true)
					p:SetBounce(0.3)
					p:SetGravity(Vector(0, 0, -200))
				end
			end

			emitter:Finish()
		end

		-- Multiple powerful dynamic lights throughout the beam area
		for lightIdx = 1, 3 do
			if math.random() < 0.7 then
				local dlight = DynamicLight(math.random(40000, 49999))

				if dlight then
					dlight.pos = targetPos + VectorRand() * currentRadius * 0.6
					dlight.r = math.Rand(200, 255)
					dlight.g = math.Rand(230, 255)
					dlight.b = 255
					dlight.brightness = math.Rand(12, 18)
					dlight.Decay = 5000
					dlight.Size = currentRadius * 0.8
					dlight.DieTime = CurTime() + 0.15
				end
			end
		end
	end)

	-- Final impact wave
	net.Receive("Arcana_FallenDown_ImpactWave", function()
		local pos = net.ReadVector()
		-- Massive explosion particles with blue-white color
		local emitter = ParticleEmitter(pos)

		if emitter then
			for i = 1, 200 do
				local p = emitter:Add("effects/blueflare1", pos)

				if p then
					p:SetVelocity(VectorRand() * math.Rand(500, 1000))
					p:SetDieTime(math.Rand(2.0, 4.0))
					p:SetStartAlpha(255)
					p:SetEndAlpha(0)
					p:SetStartSize(math.Rand(30, 60))
					p:SetEndSize(0)
					p:SetColor(170, 220, 255)
					p:SetLighting(false)
					p:SetAirResistance(50)
					p:SetGravity(Vector(0, 0, -200))
					p:SetCollide(true)
					p:SetBounce(0.3)
				end
			end

			emitter:Finish()
		end

		-- Massive final light with blue tint
		local dlight = DynamicLight(math.random(20000, 29999))

		if dlight then
			dlight.pos = pos
			dlight.r = 170
			dlight.g = 220
			dlight.b = 255
			dlight.brightness = 20
			dlight.Decay = 3000
			dlight.Size = 3000
			dlight.DieTime = CurTime() + 2.0
		end
	end)

	-- VACUUM IMPLOSION - Everything gets violently sucked inward
	net.Receive("Arcana_FallenDown_VacuumImplosion", function()
		local pos = net.ReadVector()
		local radius = net.ReadFloat()
		-- Play after blast sound when implosion starts
		surface.PlaySound("arcana/fallen_down/after_blast.wav")
		local implosionDuration = 3.0
		local startTime = CurTime()
		-- Create MASSIVE particle implosion effect - reusing dust particles
		local emitter = ParticleEmitter(pos)

		if emitter then
			-- Spawn dust particles at the edges being violently sucked inward
			for i = 1, 500 do
				timer.Simple(math.Rand(0, 0.5), function()
					if not emitter then return end
					-- Start at random position in expanded area
					local angle = math.rad(math.random(0, 360))
					local dist = math.Rand(radius * 0.8, radius * 1.8)
					local height = math.Rand(-100, 600)
					local startPos = pos + Vector(math.cos(angle) * dist, math.sin(angle) * dist, height)
					-- Dust particle (like beam dust)
					local p = emitter:Add("particle/particle_smokegrenade", startPos)

					if p then
						local dir = (pos - startPos):GetNormalized()
						local speed = math.Rand(1000, 2000)
						p:SetVelocity(dir * speed)
						p:SetDieTime(math.Rand(2.0, 2.8))
						p:SetStartAlpha(math.Rand(150, 220))
						p:SetEndAlpha(0)
						p:SetStartSize(math.Rand(60, 120))
						p:SetEndSize(10)
						p:SetColor(150, 140, 120) -- Dust color
						p:SetRoll(math.Rand(0, 360))
						p:SetRollDelta(math.Rand(-3, 3))
						p:SetAirResistance(0) -- No air resistance for violent suction
						p:SetGravity(Vector(0, 0, 0))

						-- Accelerate towards center over time
						p:SetThinkFunction(function(particle)
							if not IsValid(particle) then return end
							local toCenter = (pos - particle:GetPos()):GetNormalized()
							local currentVel = particle:GetVelocity()
							particle:SetVelocity(currentVel + toCenter * 1500 * FrameTime())
						end)

						p:SetNextThink(CurTime())
					end
				end)
			end

			-- Blue energy streaks being sucked in
			for i = 1, 250 do
				timer.Simple(math.Rand(0, 0.8), function()
					if not emitter then return end
					local angle = math.rad(math.random(0, 360))
					local dist = math.Rand(radius * 0.6, radius * 1.5)
					local height = math.Rand(0, 500)
					local startPos = pos + Vector(math.cos(angle) * dist, math.sin(angle) * dist, height)
					local p = emitter:Add("effects/blueflare1", startPos)

					if p then
						local dir = (pos - startPos):GetNormalized()
						p:SetVelocity(dir * math.Rand(1200, 2500))
						p:SetDieTime(math.Rand(1.5, 2.5))
						p:SetStartAlpha(255)
						p:SetEndAlpha(0)
						p:SetStartSize(math.Rand(20, 50))
						p:SetEndSize(2)
						p:SetColor(170, 220, 255)
						p:SetLighting(false)
						p:SetGravity(Vector(0, 0, 0))
						p:SetAirResistance(0)

						-- Accelerate inward
						p:SetThinkFunction(function(particle)
							if not IsValid(particle) then return end
							local toCenter = (pos - particle:GetPos()):GetNormalized()
							particle:SetVelocity(particle:GetVelocity() + toCenter * 2000 * FrameTime())
						end)

						p:SetNextThink(CurTime())
					end
				end)
			end

			-- Debris/vaporized matter trails
			for i = 1, 150 do
				timer.Simple(math.Rand(0, 1.0), function()
					if not emitter then return end
					local angle = math.rad(math.random(0, 360))
					local dist = math.Rand(radius * 1.0, radius * 2.0)
					local height = math.Rand(50, 400)
					local startPos = pos + Vector(math.cos(angle) * dist, math.sin(angle) * dist, height)
					local p = emitter:Add("effects/fire_cloud1", startPos)

					if p then
						local dir = (pos - startPos):GetNormalized()
						p:SetVelocity(dir * math.Rand(800, 1500))
						p:SetDieTime(math.Rand(1.0, 2.0))
						p:SetStartAlpha(200)
						p:SetEndAlpha(0)
						p:SetStartSize(math.Rand(80, 150))
						p:SetEndSize(5)
						p:SetColor(100, 120, 140) -- Dark vaporized color
						p:SetLighting(false)
						p:SetGravity(Vector(0, 0, 0))
					end
				end)
			end

			timer.Simple(implosionDuration + 0.5, function()
				if emitter then
					emitter:Finish()
				end
			end)
		end

		-- Dark pulsing light effect (void)
		local hookName = "Arcana_FallenDown_VacuumLight_" .. math.random(100000, 999999)

		hook.Add("Think", hookName, function()
			local elapsed = CurTime() - startTime

			if elapsed > implosionDuration then
				hook.Remove("Think", hookName)

				return
			end

			local progress = elapsed / implosionDuration
			local intensity = math.sin(progress * math.pi) * 12
			local dlight = DynamicLight(math.random(10000, 19999))

			if dlight then
				dlight.pos = pos + Vector(0, 0, 200)
				dlight.r = 80
				dlight.g = 100
				dlight.b = 120
				dlight.brightness = intensity
				dlight.Decay = 2000
				dlight.Size = radius * (1 - progress * 0.4) -- Shrinking void
				dlight.DieTime = CurTime() + 0.1
			end
		end)
	end)

	-- VACUUM COLLAPSE - Final explosion when implosion completes
	net.Receive("Arcana_FallenDown_VacuumCollapse", function()
		local pos = net.ReadVector()
		local radius = net.ReadFloat()
		-- MASSIVE explosion burst at center
		local emitter = ParticleEmitter(pos)

		if emitter then
			-- Shockwave ring - MUCH BIGGER
			-- More rings
			for i = 1, 12 do
				timer.Simple(i * 0.05, function()
					if not emitter then return end
					local ringRadius = i * 400 -- Larger radius

					-- More particles per ring
					for ang = 0, 360, 20 do
						local angle = math.rad(ang)
						local ringPos = pos + Vector(math.cos(angle) * ringRadius, math.sin(angle) * ringRadius, 20) -- Ground level
						local p = emitter:Add("effects/blueflare1", ringPos)

						if p then
							p:SetVelocity(Vector(0, 0, math.Rand(100, 300))) -- Higher velocity
							p:SetDieTime(math.Rand(2.0, 3.5)) -- Lives longer
							p:SetStartAlpha(255)
							p:SetEndAlpha(0)
							p:SetStartSize(math.Rand(120, 200)) -- Much larger
							p:SetEndSize(10)
							p:SetColor(170, 220, 255)
							p:SetLighting(false)
							p:SetGravity(Vector(0, 0, -150))
						end
					end
				end)
			end

			-- Central explosion burst (violent outward) - MUCH BIGGER
			-- Doubled particle count
			for i = 1, 600 do
				local p = emitter:Add("effects/blueflare1", pos + Vector(0, 0, 20)) -- Ground level

				if p then
					local dir = VectorRand():GetNormalized()
					p:SetVelocity(dir * math.Rand(1200, 2500)) -- Faster
					p:SetDieTime(math.Rand(3.0, 6.0)) -- Lives longer
					p:SetStartAlpha(255)
					p:SetEndAlpha(0)
					p:SetStartSize(math.Rand(80, 150)) -- Much larger
					p:SetEndSize(5)
					p:SetColor(math.Rand(150, 255), math.Rand(200, 255), 255)
					p:SetLighting(false)
					p:SetGravity(Vector(0, 0, -150))
					p:SetAirResistance(50)
					p:SetRoll(math.Rand(0, 360))
					p:SetRollDelta(math.Rand(-5, 5))
				end
			end

			-- Dust explosion cloud - MUCH BIGGER
			-- Doubled particle count
			for i = 1, 300 do
				local p = emitter:Add("particle/particle_smokegrenade", pos + Vector(0, 0, 10)) -- Ground level

				if p then
					p:SetVelocity(VectorRand() * math.Rand(400, 900)) -- Faster spread
					p:SetDieTime(math.Rand(4.0, 7.0)) -- Lives longer
					p:SetStartAlpha(220)
					p:SetEndAlpha(0)
					p:SetStartSize(math.Rand(150, 300)) -- Much larger
					p:SetEndSize(math.Rand(500, 800)) -- Grows even bigger
					p:SetColor(120, 120, 120)
					p:SetRoll(math.Rand(0, 360))
					p:SetRollDelta(math.Rand(-2, 2))
					p:SetGravity(Vector(0, 0, -30)) -- Less gravity for longer float
					p:SetAirResistance(100)
				end
			end

			-- Debris/sparks - MUCH BIGGER
			-- Doubled particle count
			for i = 1, 200 do
				local p = emitter:Add("effects/fire_cloud1", pos + Vector(0, 0, 15)) -- Ground level

				if p then
					p:SetVelocity(VectorRand() * math.Rand(700, 1500)) -- Faster
					p:SetDieTime(math.Rand(2.0, 4.0))
					p:SetStartAlpha(255)
					p:SetEndAlpha(0)
					p:SetStartSize(math.Rand(60, 120)) -- Much larger
					p:SetEndSize(10)
					p:SetColor(200, 150, 100)
					p:SetLighting(false)
					p:SetGravity(Vector(0, 0, -300))
					p:SetAirResistance(80)
				end
			end

			-- Delay emitter finish until all delayed spawns are complete
			-- Longest timer is 12 * 0.05 = 0.6s, so wait 1.0s to be safe
			timer.Simple(1.0, function()
				if emitter then
					emitter:Finish()
				end
			end)
		end

		-- MASSIVE blinding light - EVEN BIGGER
		-- More lights
		for i = 1, 5 do
			timer.Simple(i * 0.08, function()
				local dlight = DynamicLight(math.random(30000, 39999))

				if dlight then
					dlight.pos = pos + Vector(0, 0, 50) -- Ground level
					dlight.r = 200
					dlight.g = 230
					dlight.b = 255
					dlight.brightness = 25 - (i * 3) -- Brighter
					dlight.Decay = 4000 -- Slower decay
					dlight.Size = radius * 3 -- MUCH larger
					dlight.DieTime = CurTime() + 0.8 -- Lasts longer
				end
			end)
		end

		-- Ground decal
		util.Decal("Scorch", pos + Vector(0, 0, 10), pos - Vector(0, 0, 10))
	end)

	-- Render the beam from sky
	hook.Add("PostDrawTranslucentRenderables", "Arcana_FallenDown_RenderBeam", function()
		local curTime = CurTime()
		-- Render and clean up lightning arcs
		local matBeamLightning = Material("effects/laser1")

		for i = #fallenDownLightningArcs, 1, -1 do
			local arc = fallenDownLightningArcs[i]

			if curTime > arc.dieTime then
				table.remove(fallenDownLightningArcs, i)
			else
				local age = curTime - arc.startTime
				local lifetime = arc.dieTime - arc.startTime
				local frac = age / lifetime
				local flicker = math.sin(curTime * 60 + arc.startTime * 80) * 0.3 + 0.7
				local alpha = (1 - frac) * 255 * flicker
				render.SetMaterial(matBeamLightning)
				-- Generate jagged lightning path
				local segments = 10 -- More segments for better detail
				local arcPath = {}

				for seg = 0, segments do
					local t = seg / segments
					local pos = LerpVector(t, arc.startPos, arc.endPos)
					local jaggedAmount = math.sin(t * math.pi) * 30 -- More jagged
					pos = pos + VectorRand() * jaggedAmount
					arcPath[seg] = pos
				end

				-- White core (brightest)
				render.StartBeam(segments + 1)

				for seg = 0, segments do
					local t = seg / segments
					local width = 12 * flicker -- Thicker (was 8)
					render.AddBeam(arcPath[seg], width, t, Color(255, 255, 255, alpha))
				end

				render.EndBeam()
				-- Bright cyan layer
				render.StartBeam(segments + 1)

				for seg = 0, segments do
					local t = seg / segments
					local width = 20 * flicker -- Thicker (was 15)
					render.AddBeam(arcPath[seg], width, t, Color(200, 235, 255, alpha * 0.8))
				end

				render.EndBeam()
				-- Blue outer glow (widest)
				render.StartBeam(segments + 1)

				for seg = 0, segments do
					local t = seg / segments
					local width = 32 * flicker -- Much thicker
					render.AddBeam(arcPath[seg], width, t, Color(170, 220, 255, alpha * 0.5))
				end

				render.EndBeam()
				-- Add dynamic light at impact point
				local dlight = DynamicLight(math.random(40000, 49999))

				if dlight then
					dlight.pos = arc.endPos
					dlight.r = 170
					dlight.g = 220
					dlight.b = 255
					dlight.brightness = 3 * (1 - frac)
					dlight.Decay = 2000
					dlight.Size = 300
					dlight.DieTime = curTime + 0.1
				end
			end
		end

		-- Clean up expired beams
		for i = #activeBeams, 1, -1 do
			if curTime > activeBeams[i].endTime then
				local beam = activeBeams[i]

				-- Stop all sustained beam sounds
				if IsValid(beam.caster) then
					beam.caster:StopSound("ambient/energy/force_field_loop1.wav")
					beam.caster:StopSound("ambient/atmosphere/city_rumble_loop1.wav")
					beam.caster:StopSound("weapons/physcannon/superphys_launch3.wav")
					beam.caster:StopSound("ambient/energy/weld2.wav")
				end

				table.remove(activeBeams, i)
			end
		end

		-- Render active beams as PERFECT EXPANDING CYLINDERS
		for _, beam in ipairs(activeBeams) do
			local elapsed = curTime - beam.startTime
			local progress = math.Clamp(elapsed / beam.duration, 0, 1)
			-- Beam grows for first 10s, stays at max for last 5s
			local growthProgress = math.Clamp(progress * 1.5, 0, 1)
			local currentRadius = Lerp(growthProgress, 50, MAX_BEAM_RADIUS)
			-- Sky position (very high above)
			local skyPos = beam.targetPos + Vector(0, 0, 10000) -- Maximum height
			local groundPos = beam.targetPos
			local beamRadius = currentRadius * 40 -- 10x radius for massive beam
			-- Draw PERFECT UNIFORM CYLINDER (same radius at top and bottom)
			-- MASSIVE width multipliers to fill the entire attack radius
			render.SetMaterial(matBeam)
			-- Core white vaporizing beam (UNIFORM CYLINDER) - MUCH THICKER
			render.StartBeam(2)
			render.AddBeam(skyPos, beamRadius * 0.7, 0, Color(255, 255, 255, 255))
			render.AddBeam(groundPos, beamRadius * 0.7, 1, Color(255, 255, 255, 255))
			render.EndBeam()
			-- Bright cyan-white layer (UNIFORM CYLINDER) - MUCH THICKER
			render.StartBeam(2)
			render.AddBeam(skyPos, beamRadius * 0.9, 0, Color(220, 240, 255, 240))
			render.AddBeam(groundPos, beamRadius * 0.9, 1, Color(220, 240, 255, 240))
			render.EndBeam()
			-- Blue-white layer (UNIFORM CYLINDER) - FILLS CYLINDER
			render.StartBeam(2)
			render.AddBeam(skyPos, beamRadius * 1.05, 0, Color(190, 225, 255, 220))
			render.AddBeam(groundPos, beamRadius * 1.05, 1, Color(190, 225, 255, 220))
			render.EndBeam()
			-- Outer blue glow (UNIFORM CYLINDER) - SLIGHTLY BEYOND RADIUS
			render.StartBeam(2)
			render.AddBeam(skyPos, beamRadius * 1.2, 0, Color(170, 215, 255, 180))
			render.AddBeam(groundPos, beamRadius * 1.2, 1, Color(170, 215, 255, 180))
			render.EndBeam()
			-- Soft outer edge (UNIFORM CYLINDER) - MAXIMUM SPREAD
			render.StartBeam(2)
			render.AddBeam(skyPos, beamRadius * 1.35, 0, Color(150, 200, 255, 120))
			render.AddBeam(groundPos, beamRadius * 1.35, 1, Color(150, 200, 255, 120))
			render.EndBeam()
			-- Draw massive expanding ground ring
			render.SetMaterial(matRing)
			local ringAlpha = 240 * (1 - progress * 0.3)
			render.DrawQuadEasy(groundPos + Vector(0, 0, 5), Vector(0, 0, 1), currentRadius * 2.5, currentRadius * 2.5, Color(170, 220, 255, ringAlpha), curTime * 20)
			-- Draw bright impact sprite at ground
			render.SetMaterial(matGlow)
			render.DrawSprite(groundPos + Vector(0, 0, 10), currentRadius * 3, currentRadius * 3, Color(220, 240, 255, 220))
			render.DrawSprite(groundPos + Vector(0, 0, 15), currentRadius * 2, currentRadius * 2, Color(255, 255, 255, 200))
			-- Draw sky source sprite
			render.DrawSprite(skyPos, currentRadius * 2.5, currentRadius * 2.5, Color(200, 230, 255, 240))
			render.DrawSprite(skyPos, currentRadius * 1.5, currentRadius * 1.5, Color(255, 255, 255, 220))
			-- HEAVY DUST CLOUD around the cylinder edge
			local matSmoke = Material("particle/smokesprites_0001")
			render.SetMaterial(matSmoke)
			-- Create dust ring segments around the cylinder
			local dustSegments = 32

			for seg = 0, dustSegments - 1 do
				local angle = (seg / dustSegments) * math.pi * 2
				local nextAngle = ((seg + 1) / dustSegments) * math.pi * 2

				-- Multiple dust layers at different heights
				for heightIdx = 0, 8 do
					local height = (heightIdx / 8) * 8000
					local heightFrac = heightIdx / 8
					-- Position dust slightly outside the beam radius
					local dustOffset = currentRadius * 1.08
					local pos = beam.targetPos + Vector(math.cos(angle) * dustOffset, math.sin(angle) * dustOffset, height)
					-- Dust rotation and drift
					local driftAngle = curTime * 10 + seg * 15 + heightIdx * 20
					local drift = Vector(math.cos(math.rad(driftAngle)) * 50, math.sin(math.rad(driftAngle)) * 50, 0)
					pos = pos + drift
					-- Dust size varies with height and time
					local dustSize = currentRadius * 0.4 * (1 + heightFrac * 0.3) * (math.sin(curTime * 2 + seg + heightIdx) * 0.2 + 1)
					local dustAlpha = 140 * (1 - heightFrac * 0.5) * (1 - progress * 0.2)
					-- Heavy brown/gray dust
					local dustColor = Color(180, 170, 150, dustAlpha)
					render.DrawQuadEasy(pos, (pos - beam.targetPos):GetNormalized(), dustSize, dustSize, dustColor, math.deg(angle))
				end
			end

			-- Additional swirling dust particles
			local dustParticles = 80

			for i = 1, dustParticles do
				local angle = (i / dustParticles) * math.pi * 2 + curTime * 20
				local radiusOffset = currentRadius * (0.95 + math.sin(curTime * 3 + i) * 0.15)
				local height = ((i + curTime * 500) % 8000)
				local pos = beam.targetPos + Vector(math.cos(angle) * radiusOffset, math.sin(angle) * radiusOffset, height)
				local size = currentRadius * 0.15 * (math.sin(curTime * 2 + i * 0.1) * 0.3 + 1.2)
				local alpha = 100 * (1 - (height / 8000) * 0.6)
				render.DrawQuadEasy(pos, Vector(0, 0, 1), size, size, Color(150, 140, 120, alpha), curTime * 50 + i * 5)
			end

			-- Add multiple dynamic lights along the beam height
			for lightIdx = 1, 6 do
				local heightFrac = lightIdx / 6
				local lightPos = LerpVector(heightFrac, groundPos, skyPos)
				local dlight = DynamicLight(50000 + (beam.startTime * 1000) % 1000 + lightIdx)

				if dlight then
					dlight.pos = lightPos
					dlight.r = 200
					dlight.g = 235
					dlight.b = 255
					dlight.brightness = 10 * (1 - heightFrac * 0.4)
					dlight.Decay = 6000
					dlight.Size = currentRadius * 2.5
					dlight.DieTime = curTime + 0.1
				end
			end
		end
	end)

	-- Start HUD when casting begins
	hook.Add("Arcana_BeginCastingVisuals", "Arcana_FallenDown_StartHUD", function(caster, spellId, castTime, targetPos)
		if spellId ~= "fallen_down" then return end
		if caster ~= LocalPlayer() then return end
		resetHUDState()
	end)

	-- Main HUD rendering
	hook.Add("HUDPaint", "Arcana_FallenDown_CasterHUD", function()
		local ply = LocalPlayer()
		if not IsValid(ply) then return end
		-- Find if we're casting
		local casting = false
		local startTime = 0

		for caster, data in pairs(fallenDownCircleData) do
			if caster == ply and data.startTime then
				casting = true
				startTime = data.startTime
				break
			end
		end

		if not casting then
			-- Ensure HUD state is reset when not casting
			if phase1Complete or fovActive or #terminalLines > 0 then
				resetHUDState()
			end

			return
		end

		local elapsed = CurTime() - startTime

		if elapsed >= CHARGE_TIME then
			-- Charging is done, reset HUD state
			resetHUDState()

			return
		end

		local scrW, scrH = ScrW(), ScrH()
		local rampUpTime = CHARGE_TIME / 3

		-- ==========================================
		-- PHASE 1: Terminal-style rune loading (0-20s or until complete)
		-- ==========================================
		if not phase1Complete then
			surface.SetFont("DermaLarge")
			local currentTime = CurTime()
			local terminalY = scrH * 0.15
			local lineHeight = 30
			-- Add new line only if no line is currently being typed
			local isTyping = false

			if #terminalLines > 0 then
				local lastLine = terminalLines[#terminalLines]

				if not lastLine.completed then
					isTyping = true
				end
			end

			-- Create new line if not currently typing and enough time has passed
			if not isTyping and currentTime >= terminalNextCharTime then
				-- Decide if we add a system message or runes
				local isSystemMsg = math.random() < 0.35 -- 35% chance for system messages (more dramatic)

				if isSystemMsg then
					local msg = SYSTEM_MESSAGES[math.random(1, #SYSTEM_MESSAGES)]

					table.insert(terminalLines, {
						text = msg,
						currentLength = 0,
						targetLength = #msg,
						isSystem = true,
						nextCharTime = currentTime,
						completed = false,
						startedTyping = false
					})
				else
					local runeText = generateRuneLine()

					table.insert(terminalLines, {
						text = runeText,
						currentLength = 0,
						targetLength = #runeText,
						isSystem = false,
						nextCharTime = currentTime,
						completed = false,
						startedTyping = false
					})
				end

				-- Play tick sound when new line starts
				surface.PlaySound("arcana/arcane_" .. math.random(1, 3) .. ".ogg")
				terminalNextCharTime = currentTime + terminalLineDelay
			end

			-- Remove old lines that have scrolled off screen to keep performance good
			while #terminalLines > 30 do
				table.remove(terminalLines, 1)
			end

			-- Update and render lines
			local yOffset = terminalY

			for i, line in ipairs(terminalLines) do
				-- Only type the last line (sequential typing)
				if i == #terminalLines and not line.completed then
					if currentTime >= line.nextCharTime then
						line.currentLength = math.min(line.currentLength + 1, line.targetLength)
						line.nextCharTime = currentTime + terminalCharDelay

						if line.currentLength >= line.targetLength then
							line.completed = true
						end
					end
				end

				local displayText = string.sub(line.text, 1, line.currentLength)

				-- Draw with shadow for better visibility
				if line.isSystem then
					draw.SimpleText(displayText, "DermaLarge", scrW * 0.1 + 2, yOffset + 2, Color(0, 0, 0, 200), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP) -- Shadow
					draw.SimpleText(displayText, "DermaLarge", scrW * 0.1, yOffset, Color(100, 126, 255), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
				else
					draw.SimpleText(displayText, "DermaLarge", scrW * 0.1 + 2, yOffset + 2, Color(0, 0, 0, 200), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP) -- Shadow
					draw.SimpleText(displayText, "DermaLarge", scrW * 0.1, yOffset, Color(170, 220, 255, 200), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
				end

				yOffset = yOffset + lineHeight
				-- Stop rendering if we go off screen
				if yOffset > scrH * 0.85 then break end
			end

			-- Draw cursor blink effect on last incomplete line
			if #terminalLines > 0 and not terminalLines[#terminalLines].completed then
				if math.floor(currentTime * 3) % 2 == 0 then
					local lastLine = terminalLines[#terminalLines]
					local cursorY = terminalY + (#terminalLines - 1) * lineHeight
					local textWidth = surface.GetTextSize(string.sub(lastLine.text, 1, lastLine.currentLength))
					surface.SetDrawColor(170, 220, 255, 255)
					surface.DrawRect(scrW * 0.1 + textWidth, cursorY + 5, 15, 20)
				end
			end

			-- Mark Phase 1 as complete when we've reached the ramp up time (20 seconds)
			if elapsed >= rampUpTime and not phase1Complete then
				phase1Complete = true
				phase1CompleteTime = CurTime()
			end
			-- ==========================================
			-- PHASE 2: Big fading runes + Matrix streams (after Phase 1 complete, until 5s before end)
			-- ==========================================
		elseif phase1Complete and elapsed < CHARGE_TIME - 5 then
			-- Render terminal lines with CRAZY noise transition fade-out
			local transitionElapsed = CurTime() - phase1CompleteTime

			if transitionElapsed < transitionDuration then
				local transitionProgress = transitionElapsed / transitionDuration
				local fadeAlpha = (1 - transitionProgress) * 255
				local terminalY = scrH * 0.15
				local lineHeight = 30
				local yOffset = terminalY

				for i, line in ipairs(terminalLines) do
					local displayText = string.sub(line.text, 1, line.currentLength)

					-- Skip random lines as glitch gets stronger
					if math.random() < transitionProgress * 0.4 then
						yOffset = yOffset + lineHeight
						continue
					end

					-- EXTREME glitch effects that get crazier over time
					local glitchIntensity = transitionProgress * 50 -- Up to 50 pixels
					local xGlitch = math.random(-glitchIntensity, glitchIntensity)
					local yGlitch = math.random(-glitchIntensity * 0.5, glitchIntensity * 0.5)
					-- RGB color separation effect
					local rgbSeparation = transitionProgress * 10
					local baseX = scrW * 0.1
					local baseY = yOffset + yGlitch

					-- Randomly distort the text itself
					if math.random() < transitionProgress * 0.3 then
						displayText = string.sub(displayText, 1, math.random(1, #displayText))
					end

					if line.isSystem then
						-- Draw multiple ghost copies for more chaos
						if transitionProgress > 0.3 then
							draw.SimpleText(displayText, "DermaLarge", baseX + xGlitch - rgbSeparation, baseY, Color(255, 0, 0, fadeAlpha * 0.5), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
							draw.SimpleText(displayText, "DermaLarge", baseX + xGlitch + rgbSeparation, baseY, Color(0, 255, 255, fadeAlpha * 0.5), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
						end

						-- Main text with shadow
						draw.SimpleText(displayText, "DermaLarge", baseX + 2 + xGlitch, baseY + 2, Color(0, 0, 0, fadeAlpha * 0.8), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
						draw.SimpleText(displayText, "DermaLarge", baseX + xGlitch, baseY, Color(100, 126, 255, fadeAlpha), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
					else
						-- Draw multiple ghost copies for more chaos
						if transitionProgress > 0.3 then
							draw.SimpleText(displayText, "DermaLarge", baseX + xGlitch - rgbSeparation, baseY, Color(255, 0, 0, fadeAlpha * 0.4), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
							draw.SimpleText(displayText, "DermaLarge", baseX + xGlitch + rgbSeparation, baseY, Color(0, 255, 255, fadeAlpha * 0.4), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
						end

						draw.SimpleText(displayText, "DermaLarge", baseX + 2 + xGlitch, baseY + 2, Color(0, 0, 0, fadeAlpha * 0.8), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
						draw.SimpleText(displayText, "DermaLarge", baseX + xGlitch, baseY, Color(170, 220, 255, fadeAlpha), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
					end

					yOffset = yOffset + lineHeight
					if yOffset > scrH * 0.85 then break end
				end
			end

			-- Matrix and big runes (start appearing during/after transition)
			local phaseProgress = (elapsed - rampUpTime) / (CHARGE_TIME - 5 - rampUpTime)
			-- Fade-out transition as we approach Phase 3 (last 2 seconds of Phase 2)
			local timeUntilPhase3 = (CHARGE_TIME - 5) - elapsed
			local transitionFade = 1.0
			local phase2TransitionDuration = 2.0

			if timeUntilPhase3 < phase2TransitionDuration then
				transitionFade = timeUntilPhase3 / phase2TransitionDuration
			end

			-- FOV manipulation during Phase 2 (only in first person)
			fovActive = true
			-- Gradually DECREASE FOV during Phase 2 (down to -50 FOV - VERY narrow tunnel vision)
			currentFOVModifier = math.Approach(currentFOVModifier, -50 * phaseProgress, FrameTime() * 25)

			-- Initialize matrix streams if needed (going UP)
			if #matrixStreams == 0 then
				for i = 1, 40 do
					table.insert(matrixStreams, {
						x = math.random(0, scrW),
						y = math.random(scrH, scrH + 200), -- Start at bottom
						speed = math.random(200, 600),
						runes = {}
					})

					-- Pre-generate runes for this stream
					for j = 1, 15 do
						table.insert(matrixStreams[i].runes, getRandomRune())
					end
				end
			end

			-- Update and draw matrix streams (background) - GOING UP
			surface.SetFont("DermaLarge")

			for _, stream in ipairs(matrixStreams) do
				stream.y = stream.y - stream.speed * FrameTime() * (1 + phaseProgress * 2) -- Negative = up

				-- Reset when goes off top
				if stream.y < -200 then
					stream.y = scrH + 200
					stream.x = math.random(0, scrW)
				end

				-- Draw rune trail with shadow and CHROMATIC ABERRATION (trail goes DOWN as stream moves UP)
				for i, rune in ipairs(stream.runes) do
					local yPos = stream.y + i * 30 -- Positive offset = trail below
					local alpha = math.max(0, 150 - i * 10) * (0.5 + phaseProgress * 0.5) * transitionFade
					-- Chromatic aberration - grows stronger with phase progress
					local aberrationOffset = phaseProgress * 8 -- Up to 8 pixels separation
					-- Red channel (left)
					draw.SimpleText(rune, "DermaLarge", stream.x - aberrationOffset, yPos, Color(255, 0, 0, alpha * 0.6), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
					-- Cyan channel (right)
					draw.SimpleText(rune, "DermaLarge", stream.x + aberrationOffset, yPos, Color(0, 255, 255, alpha * 0.6), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
					-- Main blue channel (center) with shadow
					draw.SimpleText(rune, "DermaLarge", stream.x + 2, yPos + 2, Color(0, 0, 0, alpha * 0.8), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
					draw.SimpleText(rune, "DermaLarge", stream.x, yPos, Color(170, 220, 255, alpha), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
				end
			end

			-- Add big runes periodically
			if math.random() < 0.02 * (1 + phaseProgress * 3) then
				table.insert(bigRunesList, {
					rune = getRandomRune(),
					x = math.random(scrW * 0.1, scrW * 0.9), -- Across entire screen width
					y = math.random(scrH * 0.1, scrH * 0.9), -- Across entire screen height
					size = math.random(scrH * 0.15, scrH * 0.35) * (1 + phaseProgress), -- MUCH bigger, scales with screen
					alpha = 0,
					lifetime = 0,
					maxLifetime = math.random(1.5, 3.0)
				})
			end

			-- Update and draw big runes (foreground)
			for i = #bigRunesList, 1, -1 do
				local rune = bigRunesList[i]
				rune.lifetime = rune.lifetime + FrameTime()
				-- Fade in, stay, fade out
				local fadeProgress = rune.lifetime / rune.maxLifetime

				if fadeProgress < 0.2 then
					rune.alpha = (fadeProgress / 0.2) * 255
				elseif fadeProgress > 0.8 then
					rune.alpha = ((1 - fadeProgress) / 0.2) * 255
				else
					rune.alpha = 255
				end

				if rune.lifetime >= rune.maxLifetime then
					table.remove(bigRunesList, i)
				else
					-- UNSTABLE EFFECTS - make runes look chaotic and powerful
					local time = CurTime()
					-- Position jitter (increases with phase progress)
					local jitterAmount = phaseProgress * 15
					local xJitter = math.sin(time * 15 + rune.lifetime * 10) * jitterAmount
					local yJitter = math.cos(time * 12 + rune.lifetime * 8) * jitterAmount
					-- Scale pulse (breathing effect)
					local scalePulse = 1 + math.sin(time * 8 + rune.lifetime * 5) * 0.15 * phaseProgress
					local unstableSize = rune.size * scalePulse
					-- Alpha flicker (subtle)
					local alphaFlicker = 1 - math.random() * 0.1 * phaseProgress
					local finalAlpha = rune.alpha * alphaFlicker
					-- Color shift (subtle blue/white variation)
					local colorShift = math.sin(time * 10 + rune.lifetime * 7) * 30 * phaseProgress
					local r = math.Clamp(200 + colorShift, 170, 255)
					local g = math.Clamp(230 + colorShift, 200, 255)
					-- Create/use dynamic font for this rune size
					local fontName = "FallenDown_BigRune_" .. math.floor(unstableSize / 50)

					if not _G["_fallendown_font_" .. fontName] then
						surface.CreateFont(fontName, {
							font = "Arial",
							size = unstableSize,
							weight = 700,
							antialias = true
						})

						_G["_fallendown_font_" .. fontName] = true
					end

					-- Draw with shadow for visibility (shadow also jitters slightly)
					local shadowOffset = math.max(3, unstableSize * 0.02)
					local finalX = rune.x + xJitter
					local finalY = rune.y + yJitter
					-- Apply transition fade
					local fadedAlpha = finalAlpha * transitionFade
					-- Chromatic aberration - scales with rune size and phase progress
					local aberrationOffset = (unstableSize * 0.015) * phaseProgress -- Grows with progress
					-- Red channel (offset left)
					draw.SimpleText(rune.rune, fontName, finalX - aberrationOffset, finalY, Color(255, 0, 100, fadedAlpha * 0.5), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
					-- Cyan channel (offset right)
					draw.SimpleText(rune.rune, fontName, finalX + aberrationOffset, finalY, Color(0, 255, 255, fadedAlpha * 0.5), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
					-- Shadow
					draw.SimpleText(rune.rune, fontName, finalX + shadowOffset, finalY + shadowOffset, Color(0, 0, 0, fadedAlpha * 0.8), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
					-- Main colored text (center)
					draw.SimpleText(rune.rune, fontName, finalX, finalY, Color(r, g, 255, fadedAlpha), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
				end
			end
		elseif phase1Complete and elapsed >= CHARGE_TIME - 5 then
			-- ==========================================
			-- PHASE 3: White screen + Alpha/Omega (last 5 seconds)
			-- ==========================================
			local climaxProgress = (elapsed - (CHARGE_TIME - 5)) / 5
			-- DRAMATIC FOV EXPLOSION for Phase 3
			fovActive = true
			-- MAXIMUM FOV boost: +70 FOV (from -30 to +70 is a HUGE 100 FOV swing!)
			currentFOVModifier = math.Approach(currentFOVModifier, 70, FrameTime() * 200)
			-- White screen fade
			local whiteAlpha = math.min(255, climaxProgress * 255 * 1.5)
			surface.SetDrawColor(255, 255, 255, whiteAlpha)
			surface.DrawRect(0, 0, scrW, scrH)

			-- Draw ABSOLUTELY MASSIVE ALPHA and OMEGA symbols in black (140% of screen - goes off-screen!)
			if whiteAlpha > 150 then
				local symbolAlpha = math.min(255, (climaxProgress - 0.5) * 400)
				-- Create ABSOLUTELY MASSIVE font (140% of screen height - dominates everything!)
				local massiveSize = scrH * 1.4
				local fontName = "FallenDown_AlphaOmega"

				if not _G["_fallendown_font_alphaomega"] then
					surface.CreateFont(fontName, {
						font = "Arial",
						size = massiveSize,
						weight = 900, -- Ultra bold
						antialias = true
					})

					_G["_fallendown_font_alphaomega"] = true
				end

				-- Alpha (Α) on left side - centered to show more of the character
				draw.SimpleText("Α", fontName, scrW * 0.3, scrH * 0.5, Color(0, 0, 0, symbolAlpha), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
				-- Omega (Ω) on right side - centered to show more of the character
				draw.SimpleText("Ω", fontName, scrW * 0.7, scrH * 0.5, Color(0, 0, 0, symbolAlpha), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
			end
		elseif phase1Complete and elapsed >= CHARGE_TIME - 0.3 then
			-- ==========================================
			-- IMPACT FRAME: Last 0.3 seconds before unleash
			-- ==========================================
			-- FULL BLACK SCREEN impact frame
			surface.SetDrawColor(0, 0, 0, 255)
			surface.DrawRect(0, 0, scrW, scrH)
			-- Flash of symbols at moment of impact
			local impactProgress = (elapsed - (CHARGE_TIME - 0.3)) / 0.3
			-- Create ultra-massive font
			local impactSize = scrH * 1.6
			local impactFont = "FallenDown_Impact"

			if not _G["_fallendown_font_impact"] then
				surface.CreateFont(impactFont, {
					font = "Arial",
					size = impactSize,
					weight = 900,
					antialias = true
				})

				_G["_fallendown_font_impact"] = true
			end

			-- Symbols flash with inverted colors (white on black)
			local flashAlpha = math.sin(impactProgress * math.pi * 3) * 255 -- Multiple flashes
			draw.SimpleText("Α", impactFont, scrW * 0.3, scrH * 0.5, Color(255, 255, 255, flashAlpha), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
			draw.SimpleText("Ω", impactFont, scrW * 0.7, scrH * 0.5, Color(255, 255, 255, flashAlpha), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		end
	end)

	-- Cleanup HUD when spell fails
	hook.Add("Arcana_CastSpellFailure", "Arcana_FallenDown_CleanupHUD", function(caster, spellId)
		if spellId ~= "fallen_down" then return end
		-- Clean up all client visuals, sounds, and HUD
		cleanupClientVisuals(caster)

		-- Stop sustained beam sounds if interrupted (beam was already started)
		if IsValid(caster) then
			caster:StopSound("ambient/energy/force_field_loop1.wav")
			caster:StopSound("ambient/atmosphere/city_rumble_loop1.wav")
			caster:StopSound("weapons/physcannon/superphys_launch3.wav")
			caster:StopSound("ambient/energy/weld2.wav")
		end
	end)

	-- CalcView hook to apply FOV changes (only in first person)
	hook.Add("CalcView", "Arcana_FallenDown_FOV", function(ply, pos, angles, fov)
		if not fovActive then return end
		if ply ~= LocalPlayer() then return end
		if ply:ShouldDrawLocalPlayer() then return end -- Only in first person

		local view = {
			origin = pos,
			angles = angles,
			fov = fov + currentFOVModifier
		}

		return view
	end)

	-- Casting circle to indicate where the spell will land and its size
	hook.Add("Arcana_BeginCastingVisuals", "Arcana_FallenDown_TargetCircle", function(caster, spellId, castTime, _forwardLike)
		if spellId ~= "fallen_down" then return end

		Arcane:CreateFollowingCastCircle(caster, spellId, castTime, {
			color = Color(170, 220, 255, 255), -- Bright blue-white/cyan matching the spell's theme
			size = MAX_BEAM_RADIUS, -- 2000 - shows the full impact radius
			intensity = 150,
			positionResolver = function(c)
				return Arcane:ResolveGroundTarget(c, 1000)
			end
		})
	end)
end