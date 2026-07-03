-- Golden Sun scene — an encounter with the Golden Sun, an eldritch entity that
-- speaks through a golden statue (its Avatar). Its mischief does not map to
-- human mischief; its workings and goals are unknown. It offers coins in
-- exchange for the midas touch (the actual midas status is not implemented
-- yet; this is the encounter sequence and its rendering only).
--
-- Scene composition is derived from the "golden sun" advdupe2 reference: the golden
-- destroyed parliament dome encapsulates the whole walkable area with the Avatar
-- standing at its center, a sun aura blazing above it, and coins endlessly raining
-- from above, rolling across the floor and burning where they come to rest.
--
-- Start it with: Arcana:StartGoldenSunSequence()

if SERVER then return end

local SCENE_ID = "golden_sun"
local GOLD_MATERIAL = "models/player/shared/gold_player"
local FLOOR_Z = 0 -- Scene base height; coins land here
local GROUND_Z = 0 -- Height the player walks at

-- Uniform scale applied to the statue/pile and their offsets
local SCENE_SCALE = 2

-- Layout relative to the scene center (the statue stands in the middle of the
-- walkable area; offsets are scaled by SCENE_SCALE)
local STATUE_MODEL = "models/props_c17/gravestone_statue001a.mdl"
local STATUE_OFFSET = Vector(0, 0, 50)
local STATUE_YAW_OFFSET = 0 -- Tweak if the model's visual front isn't along +X

-- The dome is auto-scaled so it encapsulates the whole walkable area, and sunk
-- into the water proportionally to its final scale
local DOME_MODEL = "models/props_rooftop/parliament_dome_destroyed_interior.mdl"
local DOME_ANGLE = Angle(0, -220, 0)
local DOME_COVERAGE = 1.4 -- Dome radius relative to the walkable radius
local DOME_SINK = -100 -- Z offset per unit of dome scale

-- Base plate the whole scene stands on (this scene has no water);
-- auto-scaled to cover the walkable area
local PLATE_MODEL = "models/hunter/plates/plate32x32.mdl"
-- Stone model material: brush (concrete/...) materials don't apply reliably to
-- models, so use a VertexLitGeneric one from the HL2 rockcliff props
local PLATE_MATERIAL = "models/props_wasteland/rockcliff02c"
local PLATE_UV_SCALE = 0.25 -- <1 stretches the texture (larger features, less tiling)
local PLATE_Z = 0 -- Top of the floor; tweak if the plate surface isn't flush with the feet
local PLATE_COVERAGE = 1.4 -- Plate radius relative to the walkable radius

-- The plate model's UV map tiles the texture heavily at this scale, so build a
-- copy of the stone material with scaled-down texture coordinates
local plateMaterial = nil
local function getPlateMaterial()
	if plateMaterial then return plateMaterial end

	local src = Material(PLATE_MATERIAL)
	local tex = src:GetTexture("$basetexture")
	plateMaterial = CreateMaterial("Arcana_GoldenSunPlate", "VertexLitGeneric", {
		["$basetexture"] = tex and tex:GetName() or PLATE_MATERIAL,
		["$basetexturetransform"] = string.format("center .5 .5 scale %.3f %.3f rotate 0 translate 0 0", PLATE_UV_SCALE, PLATE_UV_SCALE),
	})

	return plateMaterial
end

-- Landed coins catch fire (visual only, no sound); fire style follows
-- arcana_brazier.lua. Raise the tick if performance suffers.
local COIN_FIRE_SCALE = 0.6
local FIRE_TICK = 0.05
local FIRE_CLOUDS_PER_TICK = 1

-- Sun aura: sits right behind the dome and statue (relative to the player
-- spawn), facing the player
local AURA_HEIGHT = 190 -- Scaled by SCENE_SCALE
local AURA_BACK_MARGIN = -225 -- Distance past the dome's edge
local AURA_EFFECT = "AR2Explosion"
local AURA_EFFECT_SCALE = 200

-- Falling coins
local COIN_MODEL = "models/props_pipes/pipe01_connector01.mdl"
local COIN_COUNT = 100
local COIN_SCALE = 1
local COIN_SPAWN_MIN_Z = 600
local COIN_SPAWN_MAX_Z = 1100
local COIN_RING_MIN = 150

-- Landing: a coin clings, rolls on its edge while slowing down, topples flat,
-- then burns on the ground for a few seconds before vanishing
local COIN_ROLL_MIN, COIN_ROLL_MAX = 0.6, 1.2 -- Roll duration
local COIN_ROLL_SPEED_MIN, COIN_ROLL_SPEED_MAX = 80, 160 -- Initial roll speed
local COIN_TOPPLE_FRAC = 0.35 -- Last fraction of the roll spent falling flat
-- The coin model's hole axis runs along its local X; this yaw offset points
-- that axle across the travel direction so the ring rolls like a wheel
local COIN_AXLE_YAW = -90
-- Extra lift while rolling upright (the model origin sits below the ring
-- center, so the bounds-derived radius alone leaves it half-buried)
local COIN_ROLL_HEIGHT_OFFSET = 8
local COIN_REST_MIN, COIN_REST_MAX = 2, 4 -- Seconds before a landed coin vanishes
local COIN_REST_HEIGHT = 3 -- Resting height above the floor
local COIN_FADE_TIME = 0.6 -- Fade-out at the end of the rest
local COIN_CLING_SOUND = "physics/metal/metal_solid_impact_soft" -- ..1-3.wav
local COIN_CLING_VOLUME = 1

-- Very light sunbeams catching the falling coins
local BEAM_LENGTH = 400
local BEAM_WIDTH = 12
local BEAM_COLOR = Color(255, 210, 120, 20)

-- Warm grade merged into the base tutorial color modify (additive deltas) to
-- counter the nebula skybox's purple/blue cast
local HEAT_COLOR_MOD = {
	["$pp_colour_addr"] = 0.05,
	["$pp_colour_addg"] = 0.02,
	["$pp_colour_addb"] = -0.04,
	["$pp_colour_mulr"] = 0.15,
	["$pp_colour_mulg"] = 0.05,
}

-- Screenspace godrays radiating from the sun (kept very light)
local SUNBEAMS_DARKEN = 0.98 -- 1 = no darkening of the rest of the screen
local SUNBEAMS_MULTIPLIER = 0.5 -- Beam brightness
local SUNBEAMS_SIZE = 0.12

local function isSceneActive(tutorial)
	return tutorial.currentSequence and tutorial.currentSequence.id == SCENE_ID
end

-- Scene state
local props = nil
local statue = nil
local goldPlate = nil
local auraPos = nil
local auraAng = nil
local nextAuraEffect = 0
local coins = nil
local coinCenter = nil
local coinRingMax = 1200
local coinRadius = 8 -- Half-width of the coin model, measured at scene creation
local sceneEmitter = nil -- ParticleEmitter for the burning coins

local function removeSceneEntities()
	if props then
		for _, ent in ipairs(props) do
			if IsValid(ent) then
				ent:Remove()
			end
		end
	end

	if IsValid(statue) then
		statue:Remove()
	end

	if IsValid(goldPlate) then
		goldPlate:Remove()
	end

	if coins then
		for _, coin in ipairs(coins) do
			if IsValid(coin.ent) then
				coin.ent:Remove()
			end
		end
	end

	if sceneEmitter then
		sceneEmitter:Finish()
	end

	props = nil
	statue = nil
	goldPlate = nil
	coins = nil
	auraPos = nil
	auraAng = nil
	coinCenter = nil
	sceneEmitter = nil
end

local function createProp(model, pos, ang, scale)
	local ent = ClientsideModel(model, RENDERGROUP_OPAQUE)
	if not IsValid(ent) then return nil end

	ent:SetNoDraw(true)
	ent:SetPos(pos)
	ent:SetAngles(ang)
	ent:SetModelScale(scale or SCENE_SCALE)

	return ent
end

-- Re-randomize a coin's fall (position in a ring around the scene, speed and tumble)
local function respawnCoin(coin, now)
	local ringAng = math.random() * math.pi * 2
	local ringDist = math.Rand(COIN_RING_MIN, coinRingMax)
	coin.x = coinCenter.x + math.cos(ringAng) * ringDist
	coin.y = coinCenter.y + math.sin(ringAng) * ringDist
	coin.startZ = math.Rand(COIN_SPAWN_MIN_Z, COIN_SPAWN_MAX_Z)
	coin.speed = math.Rand(120, 240)
	coin.spawnTime = now
	coin.spinOffset = math.random() * 360
	coin.spinSpeed = math.Rand(90, 260)
	coin.spinAxis = math.random(1, 3)
	coin.restingUntil = nil
	coin.rollStart = nil
	coin.nextFire = nil
end

hook.Add("Arcana_Tutorial_CreateScene", "Arcana_GoldenSunScene", function(tutorial, sequence)
	if sequence.id ~= SCENE_ID then return end

	removeSceneEntities()

	-- The statue is the focus entity, so the walkable area ends up centered on
	-- it; everything else is laid out around the scene center
	local walkRadius = tutorial.movementRadius or 666
	local sceneCenter = tutorial.simulatedPos * 1
	sceneCenter.z = FLOOR_Z

	props = {}

	-- The player spawns along spawnAwayDir from the statue; face it towards them
	local spawnDir = tutorial.spawnAwayDir or Vector(-1, 1, 0):GetNormalized()
	local statueAng = Angle(0, spawnDir:Angle().y + STATUE_YAW_OFFSET, 0)

	statue = createProp(STATUE_MODEL, sceneCenter + STATUE_OFFSET * SCENE_SCALE, statueAng)
	statue:SetMaterial(GOLD_MATERIAL)

	tutorial.focusEnt = statue
	tutorial.groundZ = GROUND_Z

	-- Dome scaled so it encapsulates the whole walkable area, centered on the scene
	local dome = createProp(DOME_MODEL, sceneCenter, DOME_ANGLE)
	if dome then
		local mins, maxs = dome:GetModelBounds()
		local boundsCenter = (mins + maxs) * 0.5
		local horizRadius = math.max(maxs.x - mins.x, maxs.y - mins.y) * 0.5
		local domeScale = (walkRadius * DOME_COVERAGE) / math.max(horizRadius, 1)
		dome:SetModelScale(domeScale)

		-- Center the dome's horizontal bounds on the scene center and sink it
		local centerOffset = Vector(boundsCenter.x, boundsCenter.y, 0) * domeScale
		centerOffset:Rotate(DOME_ANGLE)
		dome:SetPos(sceneCenter - centerOffset + Vector(0, 0, DOME_SINK * domeScale))
		table.insert(props, dome)
	end

	-- Golden base plate the scene stands on, scaled to cover the walkable area
	goldPlate = createProp(PLATE_MODEL, sceneCenter + Vector(0, 0, PLATE_Z), Angle(0, 0, 0))
	if IsValid(goldPlate) then
		local mins, maxs = goldPlate:GetModelBounds()
		local horizRadius = math.max(maxs.x - mins.x, maxs.y - mins.y) * 0.5
		goldPlate:SetModelScale((walkRadius * PLATE_COVERAGE) / math.max(horizRadius, 1))
		goldPlate:SetMaterial("!" .. getPlateMaterial():GetName())
	end

	-- The engine won't reliably simulate/draw an emitter out in the tutorial's
	-- fake coordinates, so it is drawn manually in the scene render hook
	-- (same trick as soul_mode.lua)
	sceneEmitter = ParticleEmitter(sceneCenter, false)
	if sceneEmitter then
		sceneEmitter:SetNoDraw(true)
	end

	-- Sun aura right behind the dome and statue relative to the player spawn,
	-- facing back towards the player; static in the scene
	if IsValid(statue) then
		local domeRadius = walkRadius * DOME_COVERAGE
		auraPos = statue:GetPos() - spawnDir * (domeRadius + AURA_BACK_MARGIN) + Vector(0, 0, AURA_HEIGHT * SCENE_SCALE)
		auraAng = spawnDir:Angle() -- Forward points from the aura towards the player
	end

	nextAuraEffect = 0

	-- Twisted, otherworldly audio while in the scene (same DSP as soul mode)
	local ply = LocalPlayer()
	if IsValid(ply) then
		ply:SetDSP(130, false)
	end

	-- Coin rain pool raining over the walkable area, staggered so coins are
	-- mid-fall when the scene fades in
	coinCenter = IsValid(statue) and statue:GetPos() or sceneCenter
	coinRingMax = walkRadius
	coins = {}
	local now = RealTime()

	for i = 1, COIN_COUNT do
		local ent = ClientsideModel(COIN_MODEL, RENDERGROUP_OPAQUE)

		if IsValid(ent) then
			ent:SetNoDraw(true)
			ent:SetModelScale(COIN_SCALE)
			ent:SetMaterial(GOLD_MATERIAL)

			-- Rolling radius from the model's bounds (shared by all coins);
			-- use the largest extent since the ring's diameter spans Y/Z
			if i == 1 then
				local mins, maxs = ent:GetModelBounds()
				local size = maxs - mins
				coinRadius = math.max(2, math.max(size.x, size.y, size.z) * 0.5 * COIN_SCALE)
			end

			local coin = {ent = ent, phase = math.random() * 10}
			respawnCoin(coin, now - math.random() * 6)
			table.insert(coins, coin)
		end
	end
end)

hook.Add("Arcana_Tutorial_DestroyScene", "Arcana_GoldenSunScene", function(tutorial, sequence)
	if sequence and sequence.id ~= SCENE_ID then return end

	removeSceneEntities()

	-- Restore normal audio
	local ply = LocalPlayer()
	if IsValid(ply) then
		ply:SetDSP(0, false)
	end
end)

-- Warp every sound played while inside the scene, soul-mode style (see
-- soul_mode.lua's EntityEmitSound pitch treatment)
hook.Add("EntityEmitSound", "Arcana_GoldenSunScene", function(data)
	local tutorial = Arcana and Arcana.Tutorial
	if not tutorial or not tutorial.active then return end
	if not isSceneActive(tutorial) then return end

	data.Pitch = math.Clamp(data.Pitch * 0.8, 1, 255)

	return true
end)

-- Falling golden coins raining onto the golden floor
local beamMat = Material("sprites/light_glow02_add")
hook.Add("Arcana_Tutorial_DrawAmbientParticles", "Arcana_GoldenSunScene", function(tutorial, eyePos)
	if not isSceneActive(tutorial) then return end
	if not coins then return end

	local now = RealTime()

	for _, coin in ipairs(coins) do
		if IsValid(coin.ent) then
			local alpha = 1

			-- Resting flat on the floor (burning): hold position, fade out near the end
			if coin.restingUntil then
				if now >= coin.restingUntil then
					respawnCoin(coin, now)
				else
					alpha = math.min(1, (coin.restingUntil - now) / COIN_FADE_TIME)
				end
			end

			if coin.rollStart then
				-- Rolling on its edge, decelerating to a stop, toppling flat at the end
				local t = math.min(1, (now - coin.rollStart) / coin.rollDur)
				-- Distance covered with linear deceleration to zero
				local dist = coin.rollSpeed * coin.rollDur * (t - 0.5 * t * t)
				local heading = Angle(0, coin.rollDir, 0)
				local fwd = heading:Forward()
				local right = heading:Right()
				local px = coin.rollX + fwd.x * dist
				local py = coin.rollY + fwd.y * dist

				-- Wheel rotation follows the distance travelled
				local spinDeg = (dist / coinRadius) * (180 / math.pi)

				-- Upright for most of the roll, tipping sideways flat at the end;
				-- the extra lift fades away as the coin topples down
				local topple = math.max(0, (t - (1 - COIN_TOPPLE_FRAC)) / COIN_TOPPLE_FRAC)
				local z = FLOOR_Z + COIN_REST_HEIGHT + (coinRadius + COIN_ROLL_HEIGHT_OFFSET - COIN_REST_HEIGHT) * (1 - topple)

				-- Axle across the travel direction, spin around the axle,
				-- topple around the travel line until the ring lies flat
				local ang = Angle(0, coin.rollDir + COIN_AXLE_YAW, 0)
				ang:RotateAroundAxis(right, spinDeg % 360)
				ang:RotateAroundAxis(fwd, topple * 90)

				coin.ent:SetPos(Vector(px, py, z))
				coin.ent:SetAngles(ang)
				coin._z = z

				if t >= 1 then
					-- Came to rest: keep the toppled-flat orientation and burn for a while
					coin.x, coin.y = px, py
					coin.rollStart = nil
					coin.restingUntil = now + math.Rand(COIN_REST_MIN, COIN_REST_MAX)
					coin.nextFire = 0
					coin.ent:SetPos(Vector(px, py, FLOOR_Z + COIN_REST_HEIGHT))
				end
			elseif not coin.restingUntil then
				local z = coin.startZ - (now - coin.spawnTime) * coin.speed

				if z <= FLOOR_Z + coinRadius then
					-- Touchdown: subtle cling, then roll away on its edge
					coin.rollStart = now
					coin.rollDur = math.Rand(COIN_ROLL_MIN, COIN_ROLL_MAX)
					coin.rollDir = math.Rand(0, 360)
					coin.rollSpeed = math.Rand(COIN_ROLL_SPEED_MIN, COIN_ROLL_SPEED_MAX)
					coin.rollX, coin.rollY = coin.x, coin.y
					sound.Play(COIN_CLING_SOUND .. math.random(1, 3) .. ".wav", Vector(coin.x, coin.y, FLOOR_Z), 60, math.random(160, 220), COIN_CLING_VOLUME)
				else
					-- Tumbling fall
					local spin = coin.spinOffset + now * coin.spinSpeed
					local ang

					if coin.spinAxis == 1 then
						ang = Angle(spin % 360, coin.spinOffset, 0)
					elseif coin.spinAxis == 2 then
						ang = Angle(coin.spinOffset, spin % 360, 90)
					else
						ang = Angle(90, coin.spinOffset, spin % 360)
					end

					coin.ent:SetPos(Vector(coin.x, coin.y, z))
					coin.ent:SetAngles(ang)
					coin._z = z
				end
			end

			render.SetBlend(alpha)
			coin.ent:DrawModel()
			render.SetBlend(1)
		end
	end
end)

hook.Add("Arcana_Tutorial_DrawScene", "Arcana_GoldenSunScene", function(tutorial, eyePos)
	if not isSceneActive(tutorial) then return end

	-- Golden base plate (this scene's floor)
	if IsValid(goldPlate) then
		goldPlate:DrawModel()
	end

	-- Golden props
	if props then
		for _, ent in ipairs(props) do
			if IsValid(ent) then
				ent:DrawModel()
			end
		end
	end

	if IsValid(statue) then
		statue:DrawModel()
	end

	-- Layered pulsing fire glow at each burning (resting) coin, brazier style;
	-- the flames themselves are emitter particles spawned from the Think hook
	if coins then
		local now = RealTime()
		render.SetMaterial(beamMat)

		for _, coin in ipairs(coins) do
			if IsValid(coin.ent) and coin.restingUntil then
				local fade = math.min(1, (coin.restingUntil - now) / COIN_FADE_TIME)
				local pulse = 0.7 + 0.3 * math.sin(now * 2.5 + coin.phase)
				local base = coin.ent:GetPos()
				local glowSize = (28 + 12 * pulse) * COIN_FIRE_SCALE

				-- Outer orange glow, mid yellow-orange, inner bright core
				render.DrawSprite(base, glowSize, glowSize, Color(255, 160, 60, 110 * pulse * fade))
				render.DrawSprite(base, glowSize * 0.7, glowSize * 0.7, Color(255, 200, 80, 100 * pulse * fade))
				render.DrawSprite(base, glowSize * 0.4, glowSize * 0.4, Color(255, 240, 140, 130 * pulse * fade))
			end
		end
	end

	-- Fire particles: the emitter is NoDraw'd and rendered by hand here so it
	-- simulates and draws inside the tutorial space (see soul_mode.lua)
	if sceneEmitter then
		sceneEmitter:Draw()
	end

	-- Coin sunbeams last, so they depth-test against the dome and props
	-- (beams write no depth; drawn earlier the dome would not occlude them).
	-- Only falling coins get a beam; grounded ones burn instead.
	if coins then
		render.SetMaterial(beamMat)

		for _, coin in ipairs(coins) do
			if IsValid(coin.ent) and coin._z and not coin.restingUntil and not coin.rollStart then
				local pos = Vector(coin.x, coin.y, coin._z)
				render.DrawBeam(pos + Vector(0, 0, BEAM_LENGTH), pos, BEAM_WIDTH, 0, 1, BEAM_COLOR)
			end
		end
	end
end)

-- Normal footsteps on the golden floor
hook.Add("Arcana_Tutorial_Footstep", "Arcana_GoldenSunScene", function(tutorial, ply)
	if not isSceneActive(tutorial) then return end

	ply:EmitSound("player/footsteps/concrete" .. math.random(1, 4) .. ".wav", 75, math.random(95, 105), 0.7)
end)

-- Warm "hot" grade over the nebula's purple/blue cast, merged into the base
-- color modify so a single DrawColorModify applies everything
hook.Add("Arcana_Tutorial_ColorModify", "Arcana_GoldenSunScene", function(tutorial, colorMod)
	if not isSceneActive(tutorial) then return end

	for k, v in pairs(HEAT_COLOR_MOD) do
		colorMod[k] = (colorMod[k] or 0) + v
	end
end)

-- Godrays radiating from the sun position
hook.Add("Arcana_Tutorial_ScreenspaceEffects", "Arcana_GoldenSunScene", function(tutorial)
	if not isSceneActive(tutorial) then return end
	if not auraPos then return end

	local scr = auraPos:ToScreen()
	if not scr.visible then return end

	DrawSunbeams(SUNBEAMS_DARKEN, SUNBEAMS_MULTIPLIER, SUNBEAMS_SIZE, scr.x / ScrW(), scr.y / ScrH())
end)

-- Brazier-style fire on a burning coin: fire cloud puffs + occasional embers,
-- following arcana_brazier.lua's SpawnFireParticle parameters
local function spawnCoinFire(coin)
	if not sceneEmitter then return end

	local s = COIN_FIRE_SCALE
	local center = coin.ent:GetPos()

	for _ = 1, FIRE_CLOUDS_PER_TICK do
		-- Cluster around the fire's heart, like inside the brazier bowl
		local offset = VectorRand() * 10 * s
		offset.z = math.Rand(-5, 3) * s

		local p = sceneEmitter:Add("effects/fire_cloud" .. math.random(1, 2), center + offset)

		if p then
			p:SetStartAlpha(200)
			p:SetEndAlpha(0)
			p:SetStartSize(math.Rand(10, 20) * s)
			p:SetEndSize(math.Rand(3, 7) * s)
			p:SetDieTime(math.Rand(0.9, 1.6))

			-- Gentle rise
			local vel = VectorRand() * 18
			vel.z = math.Rand(50, 95)
			p:SetVelocity(vel)

			p:SetAirResistance(40)
			p:SetGravity(Vector(0, 0, 15))
			p:SetRoll(math.Rand(-180, 180))
			p:SetRollDelta(math.Rand(-8, 8))

			-- Intense fire colors
			local colorChoice = math.random(1, 4)
			if colorChoice == 1 then
				p:SetColor(255, 180, 50) -- Orange
			elseif colorChoice == 2 then
				p:SetColor(255, 240, 100) -- Bright yellow
			elseif colorChoice == 3 then
				p:SetColor(255, 100, 20) -- Deep red-orange
			else
				p:SetColor(255, 200, 80) -- Golden fire
			end
		end
	end

	-- Occasional rising ember
	if math.random() < 0.25 then
		local e = sceneEmitter:Add("sprites/light_glow02_add", center + VectorRand() * 8 * s)

		if e then
			e:SetStartAlpha(220)
			e:SetEndAlpha(0)
			e:SetStartSize(math.Rand(3, 6))
			e:SetEndSize(0)
			e:SetDieTime(math.Rand(1, 2))
			e:SetVelocity(Vector(math.Rand(-20, 20), math.Rand(-20, 20), math.Rand(60, 120)))
			e:SetAirResistance(25)
			e:SetGravity(Vector(0, 0, 0))
			e:SetColor(255, 180, 80)
		end
	end
end

-- Sun aura behind the statue (the dupe's gmod_emitter looping the ar2explosion
-- effect) and burning-coin fire particles. Dispatched from Think (not from within a
-- render pass).
local nextAura = 0
hook.Add("Think", "Arcana_GoldenSunScene_Aura", function()
	local tutorial = Arcana.Tutorial
	if not tutorial or not tutorial.active then return end
	if not isSceneActive(tutorial) then return end
	if not auraPos or not auraAng then return end

	-- Only while the tutorial space is actually shown
	local phase = tutorial.phase
	if phase ~= "tutorial" and phase ~= "fade_from_black" and
	   phase ~= "show_panel" and phase ~= "fade_to_white" then return end

	local now = SysTime()
	if now > nextAura then
		nextAura = now + 0.025
		local ed = EffectData()
		ed:SetOrigin(auraPos)
		ed:SetNormal(auraAng:Forward())
		ed:SetRadius(AURA_EFFECT_SCALE * 4)
		util.Effect(AURA_EFFECT, ed, true, true)
	end

	-- Grounded coins burn, each on its own staggered spawn timer; stop feeding
	-- the fire once the coin starts fading out
	if coins and sceneEmitter then
		local rt = RealTime()

		for _, coin in ipairs(coins) do
			if IsValid(coin.ent) and coin.restingUntil
				and (coin.restingUntil - rt) > COIN_FADE_TIME
				and rt >= (coin.nextFire or 0) then
				coin.nextFire = rt + FIRE_TICK
				spawnCoinFire(coin)
			end
		end
	end
end)

-- The statue is only the Avatar of the Golden Sun - a borrowed mouth. What
-- speaks through it is an eldritch thing: mischievous in ways that do not map
-- to human mischief, with workings and goals it never explains.
local NODES = {
	START = {
		text = "A soul. It walks, it wants. Come closer, little flame. The light has never once bitten.",
		choices = {
			{ text = "What are you?", ["next"] = "WHO_ARE_YOU" },
			{ text = "Where am I?", ["next"] = "WHAT_IS_THIS" },
		}
	},
	WHO_ARE_YOU = {
		text = "The statue is a mouth. Call what speaks the Golden Sun. It is the shape you can hold.",
		choices = {
			{ text = "What is all this gold?", ["next"] = "THE_GOLD" },
			{ text = "What do you want from me?", ["next"] = "THE_OFFER" },
		}
	},
	WHAT_IS_THIS = {
		text = "A fold of Elysion. The coins fall because falling pleases. Do not look for reasons here.",
		choices = {
			{ text = "What are you?", ["next"] = "WHO_ARE_YOU" },
			{ text = "What do you want from me?", ["next"] = "THE_OFFER" },
		}
	},
	THE_GOLD = {
		text = "What remains where we have rested. Keep some, if you like.",
		choices = {
			{ text = "What do you want from me?", ["next"] = "THE_OFFER" },
		}
	},
	THE_OFFER = {
		text = "Coins. More than you can spend, and then more. In return: a touch. Yours.",
		choices = {
			{ text = "A touch?", ["next"] = "THE_PRICE" },
			{ text = "Why offer this to me?", ["next"] = "WHY_ME" },
		}
	},
	WHY_ME = {
		text = "Why does the sun fall on one field and not another?",
		choices = {
			{ text = "...What do you ask in exchange?", ["next"] = "THE_PRICE" },
		}
	},
	THE_PRICE = {
		text = "A small thing. You will hardly miss it. Everything you want, for everything you hold. Shall we conclude?",
		choices = {
			{
				text = "Give me the gold.",
				subtext = "Receive 25,000 coins and the Midas Touch affliction for 1 hour.",
				["next"] = "ACCEPTED",
				onSelect = function()
					cookie.Set("arcana_golden_sun_choice", "accepted")
					net.Start("Arcana_Midas_Choice")
					net.WriteBool(true)
					net.SendToServer()
				end
			},
			{
				text = "No. Keep it.",
				subtext = "Decline the bargain. Nothing happens.",
				["next"] = "REFUSED",
				onSelect = function()
					cookie.Set("arcana_golden_sun_choice", "refused")
					net.Start("Arcana_Midas_Choice")
					net.WriteBool(false)
					net.SendToServer()
				end
			},
		}
	},
	ACCEPTED = {
		text = "How it hurries. Go home, little flame. What was agreed will arrive.",
	},
	REFUSED = {
		text = "It believes refusing is a thing it can do. The offer does not expire.",
	}
}

-- The Golden Sun draws the newly-revived soul into its vision
net.Receive("Arcana_Midas_StartEncounter", function()
	Arcana:StartTutorialSequence({
		id = SCENE_ID,
		nodes = NODES,
		startNode = "START",
		interactionDistance = 150,
		onEnter = function() end,
		onComplete = function() end,
	})
end)

print('awdaw')