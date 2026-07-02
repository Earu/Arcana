-- Grimoire tutorial scene — Iara and the golden tree in Elysion.
-- Provides the dialogue tree, the auto-trigger when a player first carries the
-- grimoire, and the scene visuals (crystal tree + white/cyan/purple sparkles)
-- rendered through the Arcana_Tutorial_* scene hooks (see arcana/system/tutorial.lua).

if SERVER then
	-- add the sound files for the tutorial
	for _, f in ipairs(file.Find("sound/arcana/tutorials/grimoire/*.ogg", "GAME")) do
		resource.AddFile("sound/arcana/tutorials/grimoire/" .. f)
	end

	return
end

local SCENE_ID = "grimoire"

local function isSceneActive(tutorial)
	return tutorial.currentSequence and tutorial.currentSequence.id == SCENE_ID
end

-- Crystal shader material for the tree (provided by the optional shader_to_gma module,
-- required by tutorial.lua; falls back to tinted model rendering when unavailable)
local TREE_SHADER_MAT

if WaitForShaderMounted then
	WaitForShaderMounted({"arcana_crystal_surface_ps30", "arcana_crystal_surface_vs30"}, function(available)
		if not available then return end

		TREE_SHADER_MAT = CreateShaderMaterial("tree_crystal_dispersion", {
			["$pixshader"] = "arcana_crystal_surface_ps30",
			["$vertexshader"] = "arcana_crystal_surface_vs30",
			["$model"] = 1,
			["$vertexnormal"] = 1,
			["$softwareskin"] = 1,
			["$alpha_blend"] = 1,
			["$linearwrite"] = 1,
			["$linearread_basetexture"] = 1,
			["$c0_x"] = 3.0, -- dispersion strength
			["$c0_y"] = 4.0, -- fresnel power
			["$c0_z"] = 1.0, -- tint r (golden)
			["$c0_w"] = 0.7, -- tint g (golden)
			["$c1_x"] = 0.0, -- tint b (golden)
			["$c1_y"] = 1, -- opacity
			["$c1_z"] = 0.75, -- albedo blend
			["$c1_w"] = 1.0, -- selfillum glow strength
			-- Defaults for grain/sparkles and facet multi-bounce
			["$c2_y"] = 12, -- NOISE_SCALE
			["$c2_z"] = 0.6, -- GRAIN_STRENGTH
			["$c2_w"] = 0.2, -- SPARKLE_STRENGTH
			["$c3_x"] = 0.15, -- THICKNESS_SCALE
			["$c3_y"] = 12, -- FACET_QUANT
			["$c3_z"] = 8, -- BOUNCE_FADE
			["$c3_w"] = 1.4, -- BOUNCE_STEPS (1..4)
		})
	end)
end

-- Scene state
local tree = nil
local treeParticles = nil
local treeGlowMats = nil
local ambientParticles = nil

-- Water plate covering the floor of the astral plane
local WATER_SIZE = 2000 -- Match skybox cube half-size
local WATER_HEIGHT = -50 -- Below player feet
local WATER_UV_SCALE = 60
local waterMaterial = nil

local function drawWaterPlate()
	-- Predator shader (note: animation speed is baked into the shader)
	waterMaterial = waterMaterial or Material("models/shadertest/predator")

	local size = WATER_SIZE
	local height = WATER_HEIGHT
	local uvScale = WATER_UV_SCALE

	-- Depth writes stay enabled so scene geometry sitting below the water
	-- plane is properly occluded by it
	render.SetMaterial(waterMaterial)
	render.OverrideDepthEnable(true, true)

	-- Draw water plate with static UVs (reversed winding to face upward)
	mesh.Begin(MATERIAL_QUADS, 1)
		-- Top-left
		mesh.Position(Vector(-size, size, height))
		mesh.TexCoord(0, 0, uvScale)
		mesh.Color(255, 255, 255, 255)
		mesh.AdvanceVertex()

		-- Top-right
		mesh.Position(Vector(size, size, height))
		mesh.TexCoord(0, uvScale, uvScale)
		mesh.Color(255, 255, 255, 255)
		mesh.AdvanceVertex()

		-- Bottom-right
		mesh.Position(Vector(size, -size, height))
		mesh.TexCoord(0, uvScale, 0)
		mesh.Color(255, 255, 255, 255)
		mesh.AdvanceVertex()

		-- Bottom-left
		mesh.Position(Vector(-size, -size, height))
		mesh.TexCoord(0, 0, 0)
		mesh.Color(255, 255, 255, 255)
		mesh.AdvanceVertex()
	mesh.End()

	render.OverrideDepthEnable(false)
end

hook.Add("Arcana_Tutorial_CreateScene", "Arcana_GrimoireScene", function(tutorial, sequence)
	if sequence.id ~= SCENE_ID then return end

	if IsValid(tree) then
		tree:Remove()
	end

	tree = ClientsideModel("models/props/cs_militia/tree_large_militia.mdl", RENDERGROUP_OPAQUE)
	if not IsValid(tree) then return end

	tree:SetNoDraw(true)
	tree:SetModelScale(0.25)

	-- Position tree in front of player
	local treePos = tutorial.simulatedPos + tutorial.simulatedAng:Forward() * -200 + tutorial.simulatedAng:Up() * -60
	tree:SetPos(treePos)
	tree:SetAngles(Angle(0, tutorial.simulatedAng.y - 180, 0))

	tutorial.focusEnt = tree
	treeParticles = nil

	-- Ambient sparkles: random positions in a ring around the playable area
	ambientParticles = {}

	for i = 1, 150 do
		local angle = math.random() * math.pi * 2
		local distance = math.Rand(900, 1500) -- Beyond walkable area
		local height = math.Rand(-1500, 1500) -- Cover entire skybox height

		-- Sparkle color (white, cyan, or purple)
		local sparkleColorType = math.random(1, 3)
		local sparkleIntensity = math.Rand(0.7, 1.3) -- Some sparkles brighter than others

		table.insert(ambientParticles, {
			startAngle = angle,
			distance = distance,
			startHeight = height,
			size = math.Rand(4, 10),
			sparkleColor = sparkleColorType, -- 1=white, 2=cyan, 3=purple
			sparkleIntensity = sparkleIntensity, -- Brightness multiplier
			twinkleOffset = math.random() * 10 -- Random phase for twinkle
		})
	end
end)

hook.Add("Arcana_Tutorial_DestroyScene", "Arcana_GrimoireScene", function(tutorial, sequence)
	if sequence and sequence.id ~= SCENE_ID then return end

	if IsValid(tree) then
		tree:Remove()
	end

	tree = nil
	treeParticles = nil
	treeGlowMats = nil
	ambientParticles = nil
end)

hook.Add("Arcana_Tutorial_DrawAmbientParticles", "Arcana_GrimoireScene", function(tutorial, eyePos)
	if not isSceneActive(tutorial) then return end
	if not ambientParticles then return end

	local now = RealTime()
	local sparkleMat = Material("sprites/light_glow02_add")

	for _, particle in ipairs(ambientParticles) do
		-- Sparkle - static position around the player, twinkles
		local pos = tutorial.simulatedPos + Vector(
			math.cos(particle.startAngle) * particle.distance,
			math.sin(particle.startAngle) * particle.distance,
			particle.startHeight
		)

		-- Enhanced twinkling effect - faster and more dramatic
		local twinkle = math.abs(math.sin(now * 4 + particle.twinkleOffset))
		local twinkle2 = math.abs(math.cos(now * 3 + particle.twinkleOffset * 1.5))
		local combinedTwinkle = (twinkle + twinkle2) / 2
		local alpha = 100 + combinedTwinkle * 155 -- Range from 100 to 255 for more dramatic range

		-- Color based on sparkle type (white, cyan, or purple)
		local intensity = particle.sparkleIntensity or 1
		local sparkleColor
		if particle.sparkleColor == 1 then
			sparkleColor = Color(math.min(255, 255 * intensity), math.min(255, 255 * intensity), math.min(255, 255 * intensity), alpha) -- White
		elseif particle.sparkleColor == 2 then
			sparkleColor = Color(math.min(255, 150 * intensity), math.min(255, 200 * intensity), math.min(255, 255 * intensity), alpha) -- Cyan
		else
			sparkleColor = Color(math.min(255, 200 * intensity), math.min(255, 150 * intensity), math.min(255, 255 * intensity), alpha) -- Purple
		end

		render.SetMaterial(sparkleMat)
		-- More dramatic size pulsing for mirror-like glitter effect
		local sizeMult = 0.5 + combinedTwinkle * 0.8 -- Range from 0.5x to 1.3x
		render.DrawSprite(pos, particle.size * sizeMult, particle.size * sizeMult, sparkleColor)
	end
end)

-- Draw rising golden particles around the tree
local function drawTreeParticles(treeRoot, col, radius)
	-- Initialize particle data if needed
	if not treeParticles then
		treeParticles = {}
		for i = 1, 30 do -- 30 particles
			treeParticles[i] = {
				angle = math.random() * math.pi * 2,
				distance = math.random() * radius * 1.5,
				height = math.random() * 300,
				speed = math.Rand(20, 40),
				size = math.Rand(2, 6),
				lifetime = math.Rand(5, 8),
				spawnTime = RealTime() - math.random() * 5
			}
		end
	end

	local now = RealTime()
	local particleMat = Material("particle/particle_glow_04")
	render.SetMaterial(particleMat)

	for _, particle in ipairs(treeParticles) do
		local age = now - particle.spawnTime

		-- Reset particle if it's too old
		if age > particle.lifetime then
			particle.angle = math.random() * math.pi * 2
			particle.distance = math.random() * radius * 1.5
			particle.height = 0
			particle.speed = math.Rand(20, 40)
			particle.size = math.Rand(2, 6)
			particle.lifetime = math.Rand(5, 8)
			particle.spawnTime = now
			age = 0
		end

		-- Calculate position
		local height = age * particle.speed
		local fade = 1 - (age / particle.lifetime) -- Fade out as it rises

		local pos = treeRoot + Vector(
			math.cos(particle.angle) * particle.distance,
			math.sin(particle.angle) * particle.distance,
			height
		)

		-- Slight drift/sway
		local drift = math.sin(now * 0.5 + particle.angle) * 5
		pos = pos + Vector(drift, drift * 0.5, 0)

		local alpha = fade * 200
		render.DrawSprite(pos, particle.size * fade, particle.size * fade, Color(col.r, col.g, col.b, alpha))
	end
end

-- Draw the golden tree
local TREE_COLOR = Color(255, 180, 0)
hook.Add("Arcana_Tutorial_DrawScene", "Arcana_GrimoireScene", function(tutorial, eyePos)
	if not isSceneActive(tutorial) then return end

	-- Water floor first so the tree renders over it
	drawWaterPlate()

	if not IsValid(tree) then return end

	-- Initialize glow materials if needed
	if not treeGlowMats then
		treeGlowMats = {
			warp = Material("particle/warp2_warp"),
			glare = CreateMaterial("ArcanaTreeGlow_" .. FrameNumber(), "UnlitGeneric", {
				["$BaseTexture"] = "particle/fire",
				["$Additive"] = 1,
				["$VertexColor"] = 1,
				["$VertexAlpha"] = 1,
			}),
			glare2 = Material("sprites/light_ignorez")
		}
	end

	local col = TREE_COLOR

	-- Calculate actual root position (bottom of tree bounding box)
	local mins, _ = tree:GetRenderBounds()
	local treeRoot = tree:GetPos() + Vector(0, 0, mins.z) -- Actual root/base of tree
	local treeCenter = tree:GetPos() + Vector(0, 0, 80) -- Center for subtle glow

	-- Draw with crystal shader if available
	if TREE_SHADER_MAT then
		-- Crystal shader rendering (multi-pass refraction)
		render.OverrideDepthEnable(true, false) -- no Z write

		-- Draw base model underneath at a low alpha to unify color
		render.SetBlend(0.9)
		tree:DrawModel()
		render.SetBlend(1)

		-- Draw refractive passes
		local PASSES = 4
		local baseDisp = 0.5
		local perPassOpacity = 1 / PASSES

		-- Start from current screen
		local scr = render.GetScreenEffectTexture()
		TREE_SHADER_MAT:SetTexture("$basetexture", scr)
		TREE_SHADER_MAT:SetFloat("$c2_x", RealTime())
		TREE_SHADER_MAT:SetFloat("$c1_w", 0.25)

		-- Set golden color (255, 180, 0)
		TREE_SHADER_MAT:SetFloat("$c0_z", col.r / 255 * 10)
		TREE_SHADER_MAT:SetFloat("$c0_w", col.g / 255 * 10)
		TREE_SHADER_MAT:SetFloat("$c1_x", col.b / 255 * 10)
		TREE_SHADER_MAT:SetFloat("$c1_z", 0)

		for i = 1, PASSES do
			-- Ramp dispersion a bit each pass
			TREE_SHADER_MAT:SetFloat("$c0_x", baseDisp * (1 + 0.25 * (i - 1)))
			-- Reduce opacity per pass
			TREE_SHADER_MAT:SetFloat("$c1_y", perPassOpacity)

			render.MaterialOverride(TREE_SHADER_MAT)
			tree:DrawModel()
			render.MaterialOverride()
		end

		render.OverrideDepthEnable(false, false)
	else
		-- Fallback: Draw the tree normally (solid)
		render.SetColorModulation(col.r / 255, col.g / 255, col.b / 255)
		render.SetBlend(0.85)
		tree:DrawModel()

		-- Second transparent pass for glow effect (barely visible)
		render.SetBlend(0.08)
		tree:DrawModel()

		-- Reset render state
		render.SetColorModulation(1, 1, 1)
		render.SetBlend(1)
	end

	-- Draw crystal shard-style layered glow effect (very minimal)
	local radius = tree:BoundingRadius() * 0.5

	-- Layered glare sprites (very reduced to see tree clearly)
	render.SetMaterial(treeGlowMats.glare)
	render.DrawSprite(treeCenter, radius * 6, radius * 6, Color(col.r, col.g, col.b, 15))

	-- Outer glow (respects depth, minimal)
	render.SetMaterial(treeGlowMats.glare2)
	render.DrawSprite(treeCenter, radius * 12, radius * 3, Color(col.r, col.g, col.b, 8))

	-- Draw rising golden particles
	drawTreeParticles(treeRoot, col, radius)
end)

-- Quiet water splashes as the player wades through the astral plane
hook.Add("Arcana_Tutorial_Footstep", "Arcana_GrimoireScene", function(tutorial, ply)
	if not isSceneActive(tutorial) then return end

	ply:EmitSound("ambient/water/water_splash" .. math.random(1, 3) .. ".wav", 40, math.random(90, 110), 0.2)
end)

local NODES = {
	START = {
		text = "Ah. Mortal. You have found something of consequence...",
		voice = "arcana/tutorials/grimoire/start.ogg",
		choices = {
			{ text = "Who are you?", ["next"] = "WHO_ARE_YOU" },
			{ text = "What is this place?", ["next"] = "WHAT_IS_THIS" },
			{ text = "I DEMAND TO KNOW WHY I'M HERE!", ["next"] = "WHY_AM_I_HERE" },
		}
	},
	WHO_ARE_YOU = {
		text = "I am Iara. I tend the balance of this world and preserve its truths.. I oversee its equilibrium along with its souls, like yours.",
		voice = "arcana/tutorials/grimoire/who_are_you.ogg", -- redo
		choices = {
			{ text = "What is this place?", ["next"] = "WHAT_IS_THIS" },
			{ text = "Why am I here?", ["next"] = "WHY_AM_I_HERE" },
		}
	},
	WHAT_IS_THIS = {
		text = "This is Elysion, the astral plane. A space removed from matter, where intent may be addressed without consequence to the physical world. Only your soul is present.",
		voice = "arcana/tutorials/grimoire/what_is_this.ogg",
		choices = {
			{ text = "Who are you?", ["next"] = "WHO_ARE_YOU" },
			{ text = "Why did you bring me here?", ["next"] = "WHY_AM_I_HERE" },
		}
	},
	WHY_AM_I_HERE = {
		text = "I summoned you because you now carry an artifact that interacts directly with the laws I uphold. The grimoire does not forgive ignorance. Without guidance, it will extract payment regardless of your intent.",
		voice = "arcana/tutorials/grimoire/why_am_i_here.ogg",
		choices = {
			{ text = "Is it really that powerful?", ["next"] = "GRIMOIRE_EXPLANATION" },
			{ text = "LET ME GO. NOW.", ["next"] = "END_RUDE" },
		}
	},
	GRIMOIRE_EXPLANATION = {
		text = "Yes. Through it, you may impose your will upon the world - briefly. Such imposition requires balance. An offering satisfies this exchange. Without one, the cost is reclaimed from you instead.",
		voice = "arcana/tutorials/grimoire/grimoire_explanation.ogg",
		choices = {
			{ text = "So how does it work?", ["next"] = "SPELL_EXPLANATION" },
			{ text = "From me... ?", ["next"] = "OFFERING_EXPLANATION" },
		}
	},
	OFFERING_EXPLANATION = {
		text = "You do not possess mana, and so you have the world do your biding, we make this possible, but to uphold balance an offering is required. Your body and your life will qualify as such if you do not offer something else.",
		voice = "arcana/tutorials/grimoire/offering_explanation.ogg",
		choices = {
			{ text = "So how does it work?", ["next"] = "SPELL_EXPLANATION" },
		}
	},
	SPELL_EXPLANATION = {
		text = "The grimoire grows as you do. Each spell cast, each ritual completed, each risk endured refines your understanding. Experience becomes knowledge. Knowledge allows new inscriptions, rituals, and pacts to be recorded at altars. I have also blessed you with a first spell...",
		voice = "arcana/tutorials/grimoire/spell_explanation.ogg",
		choices = {
			{ text = "You said it could be dangerous?", ["next"] = "CORRUPTION_WARNING" },
			{ text = "What spell?", ["next"] = "FIREBALL_EXPLANATION" },
		}
	},
	FIREBALL_EXPLANATION = {
		text = "I have entrusted you with the \"Fireball\" incantation. It condenses ambient mana into a volatile fiery orb that releases its energy on impact. I am sure you will find it useful.",
		voice = "arcana/tutorials/grimoire/fireball_explanation.ogg",
		choices = {
			{ text = "You said it could be dangerous?", ["next"] = "CORRUPTION_WARNING" },
		}
	},
	CORRUPTION_WARNING = {
		text = "Repeated casting draws ambient mana inward. Where it gathers too densely, it hardens. When disturbed, it may rupture - and corruption follows. Such areas are unstable and indifferent to life. Beware...",
		voice = "arcana/tutorials/grimoire/corruption_warning.ogg",
		choices = {
			{ text = "Corruption... ?", ["next"] = "END" },
		}
	},
	END = {
		text = "Ah, it seems I am required elsewhere. That is all for now, we will speak again... soon.",
		voice = "arcana/tutorials/grimoire/end.ogg", -- redo
	},
	END_RUDE = {
		text = "Very well. You shall be released and your choice will be remembered. No further assistance will be provided, your choices are now your own.",
		voice = "arcana/tutorials/grimoire/end_rude.ogg",
	}
}

hook.Add("Think", "Arcana_GrimoireTutorial", function()
	local ply = LocalPlayer()
	if not IsValid(ply) then return end
	if not ply:HasWeapon("grimoire") then return end

	if cookie.GetString("arcana_grimoire_tutorial_completed", "false") == "false" then
		Arcana:StartTutorialSequence({
			id = SCENE_ID,
			nodes = NODES,
			startNode = "START",
			onEnter = function() end,
			onComplete = function()
				cookie.Set("arcana_grimoire_tutorial_completed", "true")
			end
		})
	end
end)
