AddCSLuaFile()
require("shader_to_gma")

if SERVER then
	resource.AddFile("materials/arcana/skybox/nebula/right.vtf")
	resource.AddFile("materials/arcana/skybox/nebula/left.vtf")
	resource.AddFile("materials/arcana/skybox/nebula/up.vtf")
	resource.AddFile("materials/arcana/skybox/nebula/down.vtf")
	resource.AddFile("materials/arcana/skybox/nebula/front.vtf")
	resource.AddFile("materials/arcana/skybox/nebula/back.vtf")

	resource.AddFile("sound/arcana/altar_ambient_stereo.ogg")

	resource.AddShader("arcana_crystal_surface_ps30")
	resource.AddShader("arcana_crystal_surface_vs30")
	return
end -- This is a CLIENT-only module

local Tutorial = {}
Arcane.Tutorial = Tutorial

-- Initialize crystal shader material for tree
local TREE_SHADER_MAT
local function initTreeShaderMaterial()
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
end

if system.IsWindows() then
	if file.Exists("shaders/fxc/arcana_crystal_surface_ps30.vcs", "GAME") and file.Exists("shaders/fxc/arcana_crystal_surface_vs30.vcs", "GAME") then
		initTreeShaderMaterial()
	else
		hook.Add("ShaderMounted", "arcana_tree_crystal_dispersion", initTreeShaderMaterial)
	end
end

-- Tutorial state
Tutorial.active = false
Tutorial.phase = "none" -- none, fade_to_black, tutorial, fade_to_white
Tutorial.fadeProgress = 0
Tutorial.fadeStart = 0
Tutorial.fadeOutDuration = 2.5  -- Fade out (2.0s fade + 0.5s hold at peak)
Tutorial.fadeInDuration = 1.5   -- Fade in (0.5s hold at peak + 1.0s fade)
Tutorial.fadeOutTime = 2.0      -- Time spent actually fading out
Tutorial.fadeInTime = 1.0       -- Time spent actually fading in

-- Space environment
Tutorial.skyboxTextures = {
	RIGHT = "arcana/skybox/nebula/right",
	LEFT = "arcana/skybox/nebula/left",
	UP = "arcana/skybox/nebula/up",
	DOWN = "arcana/skybox/nebula/down",
	FRONT = "arcana/skybox/nebula/front",
	BACK = "arcana/skybox/nebula/back"
}

-- Skybox face rotations (in degrees: 0, 90, 180, 270, or any angle)
-- Adjust these values to rotate texture coordinates for each face
Tutorial.skyboxRotations = {
	RIGHT = 0,
	LEFT = 180,
	UP = 90,
	DOWN = 90,
	FRONT = 180,
	BACK = 0
}

-- Tutorial objects
Tutorial.tree = nil
Tutorial.waterPlate = nil
Tutorial.cubeModel = nil

-- Player state backup
Tutorial.backupPos = nil
Tutorial.backupAng = nil
Tutorial.backupVel = nil
Tutorial.simulatedPos = Vector(0, 0, 0)
Tutorial.simulatedAng = Angle(0, 0, 0)
Tutorial.simulatedVel = Vector(0, 0, 0)

-- Interaction
Tutorial.interactionDistance = 100
Tutorial.showingPanel = false
Tutorial.currentSequence = nil

-- Greek text morphing
Tutorial.morphProgress = 0
Tutorial.morphDuration = 1.0
Tutorial.greekText = ""
Tutorial.finalText = ""

--[[
	Sequence format:
	{
		teachingText = "This is what the player will learn",
		onEnter = function() end, -- Optional callback when sequence starts
		onComplete = function() end -- Optional callback when sequence completes
	}
]]

-- Rotate UV coordinates by specified angle (0, 90, 180, 270)
local function RotateUV(u, v, rotation)
	rotation = rotation % 360

	if rotation == 90 then
		return 1 - v, u
	elseif rotation == 180 then
		return 1 - u, 1 - v
	elseif rotation == 270 then
		return v, 1 - u
	else
		return u, v
	end
end

-- Initialize skybox textures
function Tutorial:InitializeSkybox()
	-- Create materials dynamically for each skybox face
	local faces = {"right", "left", "up", "down", "front", "back"}
	self.skyboxMaterials = {}

	for _, face in ipairs(faces) do
		local faceName = face:upper()
		self.skyboxMaterials[faceName] = CreateMaterial("ArcanaSkybox_" .. faceName .. "_" .. FrameNumber(), "UnlitGeneric", {
			["$basetexture"] = "arcana/skybox/nebula/" .. face,
			["$nolod"] = 1,
			["$vertexcolor"] = 1,
			["$vertexalpha"] = 1,
		})
	end
end

-- Create the cube mesh
function Tutorial:CreateCubeMesh()
	local cubeSize = 2000 -- Half-size for cube centered at origin
	self.cubeSize = cubeSize -- Store for movement constraint (1/3 = ~833 units)
	self.movementRadius = cubeSize / 3 -- Player can move 1/3 of cube size

	local inset = 0 -- Bring faces inward by 6 units to avoid seams

	-- Cube vertices (8 corners) - centered at (0, 0, 0), with inset
	local corners = {
		Vector(-cubeSize + inset, -cubeSize + inset, -cubeSize + inset), -- 0
		Vector( cubeSize - inset, -cubeSize + inset, -cubeSize + inset), -- 1
		Vector( cubeSize - inset,  cubeSize - inset, -cubeSize + inset), -- 2
		Vector(-cubeSize + inset,  cubeSize - inset, -cubeSize + inset), -- 3
		Vector(-cubeSize + inset, -cubeSize + inset,  cubeSize - inset), -- 4
		Vector( cubeSize - inset, -cubeSize + inset,  cubeSize - inset), -- 5
		Vector( cubeSize - inset,  cubeSize - inset,  cubeSize - inset), -- 6
		Vector(-cubeSize + inset,  cubeSize - inset,  cubeSize - inset)  -- 7
	}

	-- Helper function to create face with rotation
	local function CreateFace(name, material, positions, baseUVs)
		local rotation = self.skyboxRotations[name] or 0
		local vertices = {}

		for i = 1, 4 do
			local u, v = RotateUV(baseUVs[i].u, baseUVs[i].v, rotation)
			vertices[i] = {
				pos = positions[i],
				u = u,
				v = v
			}
		end

		return {
			name = name,
			material = material,
			vertices = vertices
		}
	end

	-- Face definitions with REVERSED winding order (so faces show inward to player)
	-- Base UVs before rotation with inset to avoid edge bleeding/seams
	local uvInset = 0.002 -- Small inset to prevent texture edge sampling issues
	local baseUVs = {
		{u = 0 + uvInset, v = 1 - uvInset},
		{u = 0 + uvInset, v = 0 + uvInset},
		{u = 1 - uvInset, v = 0 + uvInset},
		{u = 1 - uvInset, v = 1 - uvInset}
	}

	self.cubeFaces = {
		-- RIGHT (positive X)
		CreateFace("RIGHT", self.skyboxMaterials.RIGHT, {
			corners[3], corners[7], corners[6], corners[2]
		}, baseUVs),

		-- LEFT (negative X)
		CreateFace("LEFT", self.skyboxMaterials.LEFT, {
			corners[8], corners[4], corners[1], corners[5]
		}, baseUVs),

		-- UP (positive Z)
		CreateFace("UP", self.skyboxMaterials.UP, {
			corners[5], corners[6], corners[7], corners[8]
		}, baseUVs),

		-- DOWN (negative Z)
		CreateFace("DOWN", self.skyboxMaterials.DOWN, {
			corners[4], corners[3], corners[2], corners[1]
		}, baseUVs),

		-- FRONT (positive Y) - material swapped with BACK
		CreateFace("FRONT", self.skyboxMaterials.BACK, {
			corners[5], corners[1], corners[2], corners[6]
		}, baseUVs),

		-- BACK (negative Y) - material swapped with FRONT
		CreateFace("BACK", self.skyboxMaterials.FRONT, {
			corners[4], corners[8], corners[7], corners[3]
		}, baseUVs)
	}
end

-- Create the water plate mesh at player's feet
function Tutorial:CreateWaterPlate()
	self.plateSize = 2000 -- Match cube half-size (full size = 2000x2000)
	self.plateHeight = -50 -- Below player feet
	self.waterUVScale = 10 -- Tile the texture 10x to avoid stretched look

	-- Use predator shader (note: animation speed is baked into the shader)
	self.waterMaterial = Material("models/shadertest/predator")
end

-- Initialize ambient particles (sparkles only)
function Tutorial:InitializeAmbientParticles()
	self.ambientParticles = {}

	-- Spawn 150 sparkles
	for i = 1, 150 do
		-- Random position in a ring around the playable area (outside movement radius)
		local angle = math.random() * math.pi * 2
		local distance = math.Rand(900, 1500) -- Beyond walkable area
		local height = math.Rand(-1500, 1500) -- Cover entire skybox height

		-- Sparkle color (white, cyan, or purple)
		local sparkleColorType = math.random(1, 3)
		local sparkleIntensity = math.Rand(0.7, 1.3) -- Some sparkles brighter than others

		table.insert(self.ambientParticles, {
			startAngle = angle,
			distance = distance,
			startHeight = height,
			size = math.Rand(4, 10),
			sparkleColor = sparkleColorType, -- 1=white, 2=cyan, 3=purple
			sparkleIntensity = sparkleIntensity, -- Brightness multiplier
			twinkleOffset = math.random() * 10 -- Random phase for twinkle
		})
	end
end

-- Update and draw ambient particles
function Tutorial:DrawAmbientParticles()
	if not self.ambientParticles then return end

	local now = RealTime()
	local sparkleMat = Material("sprites/light_glow02_add")

	for i, particle in ipairs(self.ambientParticles) do
		-- Sparkle - static position, twinkles
		local pos = self.simulatedPos + Vector(
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
end

-- Create the golden tree
function Tutorial:CreateTree(sequence)
	if IsValid(self.tree) then
		self.tree:Remove()
	end

	self.tree = ClientsideModel("models/props/cs_militia/tree_large_militia.mdl", RENDERGROUP_OPAQUE)
	if not IsValid(self.tree) then return end

	self.tree:SetNoDraw(true)
	self.tree:SetModelScale(0.25)

	-- Position tree in front of player
	local treePos = self.simulatedPos + self.simulatedAng:Forward() * -200 + self.simulatedAng:Up() * -60
	self.tree:SetPos(treePos)
	self.tree:SetAngles(Angle(0, self.simulatedAng.y - 180, 0))
end

-- Start ambient music for tutorial
function Tutorial:StartAmbientMusic()
	-- Create looping sound patch
	self.ambientSound = CreateSound(LocalPlayer(), "arcana/altar_ambient_stereo.ogg")
	if self.ambientSound then
		self.ambientSound:SetSoundLevel(0) -- Play globally, not positional
		self.ambientSound:PlayEx(0, 100) -- Start at 0 volume, 100 pitch
		self.ambientTargetVolume = 1.0
		self.ambientCurrentVolume = 0
	end
end

-- Update ambient music volume based on tutorial phase
function Tutorial:UpdateAmbientMusic(dt)
	if not self.ambientSound then return end

	-- Ensure sound is playing (restart if stopped)
	if not self.ambientSound:IsPlaying() then
		self.ambientSound:Play()
	end

	-- Determine target volume based on phase
	local targetVolume = 0
	if self.phase == "fade_from_black" then
		targetVolume = self.fadeProgress -- Fade in with visual
	elseif self.phase == "tutorial" then
		targetVolume = 1.0
	elseif self.phase == "show_panel" then
		targetVolume = 1.0 -- Keep playing during panel
	elseif self.phase == "fade_to_white" then
		targetVolume = 1.0 - self.fadeProgress -- Fade out during white transition
	elseif self.phase == "fade_from_white" then
		targetVolume = 0 -- Keep silent when returning to reality
	end

	-- Smoothly interpolate volume
	self.ambientCurrentVolume = Lerp(dt * 2, self.ambientCurrentVolume, targetVolume)
	self.ambientSound:ChangeVolume(self.ambientCurrentVolume, 0)
end

-- Stop ambient music
function Tutorial:StopAmbientMusic()
	if self.ambientSound then
		self.ambientSound:Stop()
		self.ambientSound = nil
	end
end

-- Start a tutorial sequence
function Tutorial:StartSequence(sequence)
	if self.active then
		ErrorNoHalt("[Arcana Tutorial] Cannot start sequence - tutorial already active!\n")
		return false
	end

	local ply = LocalPlayer()
	if not IsValid(ply) then return false end

	self.currentSequence = sequence
	self.active = true
	self.phase = "fade_to_black"
	self.fadeProgress = 0
	self.fadeStart = CurTime()

	-- Backup player state
	self.backupPos = ply:GetPos()
	self.backupAng = ply:EyeAngles()
	self.backupVel = ply:GetVelocity()

	-- Initialize simulated position at origin (temporary)
	self.simulatedPos = Vector(0, 0, 0)
	self.simulatedAng = Angle(0, 0, 0)
	self.simulatedVel = Vector(0, 0, 0)
	self.triggeredPanel = false -- Track if player has triggered the teaching panel

	-- Initialize visuals
	self:InitializeSkybox()
	self:CreateCubeMesh()
	self:CreateWaterPlate()
	self:CreateTree(sequence)
	self:InitializeAmbientParticles()

	-- Start ambient music (will fade in)
	self:StartAmbientMusic()

	-- Position player at edge of movement radius from the tree
	if IsValid(self.tree) and self.movementRadius then
		local treePos = self.tree:GetPos()

		-- Calculate direction away from tree (opposite side - negative X)
		local awayDir = Vector(-1, 1, 0) -- Start on opposite side
		awayDir:Normalize()

		-- Place player at edge of movement radius
		self.simulatedPos = treePos + awayDir * self.movementRadius
	end

	-- Reset interaction state
	self.showingPanel = false
	self.fadeProgress = 0

	-- Store full text for line-by-line gradient reveal
	self.finalText = sequence.teachingText or "Welcome to Arcana"

	local function shouldHide()
		return self.phase == "tutorial" or self.phase == "fade_from_black" or self.phase == "fade_to_white" or self.phase == "show_panel"
	end

	-- Hook for rendering
	hook.Add("PreDrawOpaqueRenderables", "Arcana_TutorialRender", function()
		self:RenderTutorial()
		if shouldHide() then return true end
	end)

	hook.Add("PreDrawSkyBox", "Arcana_TutorialSkybox", function()
		if shouldHide() then return true end -- Don't render skybox during tutorial
	end)

	hook.Add("PreDrawTranslucentRenderables", "Arcana_TutorialTranslucent", function()
		if shouldHide() then return true end
	end)

	hook.Add("PreDrawViewModel", "Arcana_TutorialViewModels", function()
		if shouldHide() then return true end
	end)

	hook.Add("ShouldDrawLocalPlayer", "Arcana_TutorialShouldDrawLocalPlayer", function()
		if shouldHide() then return false end
	end)

	hook.Add("CalcView", "Arcana_TutorialView", function(ply, pos, angles, fov)
		return self:ModifyView(ply, pos, angles, fov)
	end)

	hook.Add("HUDPaint", "Arcana_TutorialHUD", function()
		self:DrawTutorialHUD()
	end)

	hook.Add("RenderScreenspaceEffects", "Arcana_TutorialScreenspace", function()
		self:RenderScreenspaceEffects()
	end)

	hook.Add("Think", "Arcana_TutorialThink", function()
		self:Think()
	end)

	-- Disable player movement simulation
	hook.Add("PlayerBindPress", "Arcana_TutorialInput", function(ply, bind, pressed)
		if self.active and self.phase == "tutorial" then
			return self:HandleInput(bind, pressed)
		end
	end)

	-- Suppress default footstep sounds during tutorial
	hook.Add("PlayerFootstep", "Arcana_TutorialFootstep", function(ply, pos, foot, sound, volume, filter)
		if self.active then
			return true -- Suppress default footsteps
		end
	end)

	-- Call onEnter callback
	if sequence.onEnter then
		sequence.onEnter()
	end

	return true
end

-- Handle input during tutorial
function Tutorial:HandleInput(bind, pressed)
	-- Allow camera movement
	if string.find(bind, "+left") or string.find(bind, "+right") or
	   string.find(bind, "+lookup") or string.find(bind, "+lookdown") then
		return false
	end

	-- Block all other inputs (movement handled separately)
	return true
end

-- Update movement based on key states (called in Think)
function Tutorial:UpdateMovement()
	if not self.active or self.phase ~= "tutorial" then return end

	local ply = LocalPlayer()
	if not IsValid(ply) then return end

	local moveSpeed = 200 -- Units per second
	local forward = self.simulatedAng:Forward()
	local right = self.simulatedAng:Right()

	-- Flatten forward/right to prevent up/down movement
	forward.z = 0
	forward:Normalize()
	right.z = 0
	right:Normalize()

	local moveDir = Vector(0, 0, 0)

	self.keyForward = self.keyForward or input.LookupBinding("+forward")
	self.keyBackward = self.keyBackward or input.LookupBinding("+backward")
	self.keyLeft = self.keyLeft or input.LookupBinding("+moveleft")
	self.keyRight = self.keyRight or input.LookupBinding("+moveright")

	-- Check continuous key states
	if self.keyForward and input.IsKeyDown(self.keyForward) then
		moveDir = moveDir + forward
	end
	if self.keyBackward and input.IsKeyDown(self.keyBackward) then
		moveDir = moveDir - forward
	end
	if self.keyLeft and input.IsKeyDown(self.keyLeft) then
		moveDir = moveDir - right
	end
	if self.keyRight and input.IsKeyDown(self.keyRight) then
		moveDir = moveDir + right
	end

	-- Track if we're moving for footsteps
	local wasMoving = self.isMoving or false
	self.isMoving = moveDir:Length() > 0

	-- Normalize and apply speed
	if self.isMoving then
		moveDir:Normalize()
		self.simulatedVel = moveDir * moveSpeed

		-- Play water footstep sounds
		if not wasMoving then
			self.nextFootstep = CurTime()
		end
	else
		self.simulatedVel = Vector(0, 0, 0)
	end
end

-- Play footstep sounds (very quiet)
function Tutorial:PlayFootsteps()
	if not self.isMoving then return end

	local now = CurTime()
	if now < (self.nextFootstep or 0) then return end

	local ply = LocalPlayer()
	if not IsValid(ply) then return end

	-- Play at very low volume (10%) for subtle effect
	ply:EmitSound("ambient/water/water_splash" .. math.random(1, 3) .. ".wav", 40, math.random(90, 110), 0.2)
	self.nextFootstep = now + 0.45 -- Slightly slower footstep interval
end

-- Try to interact with tree
-- Show the teaching panel
function Tutorial:ShowTeachingPanel()
	self.showingPanel = true
	self.fadeProgress = 0
	self.fadeStart = CurTime()

	-- Calculate duration: ~2 seconds per line for comfortable reading
	-- We'll estimate line count based on text length
	local estimatedCharsPerLine = 60
	local estimatedLines = math.max(1, math.ceil(#self.finalText / estimatedCharsPerLine))
	self.fadeDuration = estimatedLines * 2.0

	-- Enable mouse cursor
	gui.EnableScreenClicker(true)

	-- Create the "Understood" button
	self:CreateUnderstoodButton()
end

-- Create the "Understood" button
function Tutorial:CreateUnderstoodButton()
	if IsValid(self.understoodButton) then
		self.understoodButton:Remove()
	end

	local scrW, scrH = ScrW(), ScrH()
	local panelW, panelH = 1000, 600
	local panelY = (scrH - panelH) * 0.5
	local padding = 60
	local btnW, btnH = 180, 50
	local btnX = (scrW - btnW) * 0.5
	local btnY = panelY + panelH - btnH - padding

	self.understoodButton = vgui.Create("DButton")
	self.understoodButton:SetPos(btnX, btnY)
	self.understoodButton:SetSize(btnW, btnH)
	self.understoodButton:SetText("")
	self.understoodButton:SetCursor("hand")
	self.understoodButton:SetVisible(false) -- Will be shown when animation completes

	-- Custom paint function
	self.understoodButton.Paint = function(pnl, w, h)
		local hovered = pnl:IsHovered()

		-- Button background with golden theme using ArtDeco
		local bgCol = hovered and Color(220, 180, 70, 200) or Color(180, 140, 50, 150)
		local borderCol = Color(140, 100, 30, 255)

		if ArtDeco then
			ArtDeco.FillDecoPanel(0, 0, w, h, bgCol, 8)
			ArtDeco.DrawDecoFrame(0, 0, w, h, borderCol, 8)
		else
			draw.RoundedBox(8, 0, 0, w, h, bgCol)
			surface.SetDrawColor(borderCol)
			surface.DrawOutlinedRect(0, 0, w, h, 2)
		end

		-- Button text with shadow
		draw.SimpleText("Understood", "Arcana_Ancient", w * 0.5 + 1, h * 0.5 + 1,
			Color(0, 0, 0, 180), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		draw.SimpleText("Understood", "Arcana_Ancient", w * 0.5, h * 0.5,
			Color(255, 230, 150), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
	end

	self.understoodButton.DoClick = function()
		self:CloseTeachingPanel()
	end
end

-- Close teaching panel and transition back
function Tutorial:CloseTeachingPanel()
	self.showingPanel = false
	self.phase = "fade_to_white"
	self.fadeProgress = 0
	self.fadeStart = CurTime()

	-- Remove the button
	if IsValid(self.understoodButton) then
		self.understoodButton:Remove()
		self.understoodButton = nil
	end

	-- Disable mouse cursor
	gui.EnableScreenClicker(false)

	surface.PlaySound("arcana/arcane_1.ogg")

	-- Call onComplete callback
	if self.currentSequence and self.currentSequence.onComplete then
		self.currentSequence.onComplete()
	end
end

-- End tutorial and return to normal
function Tutorial:EndSequence()
	self.active = false
	self.phase = "none"

	-- Clean up
	if IsValid(self.tree) then
		self.tree:Remove()
		self.tree = nil
	end

	-- Remove the button if it exists
	if IsValid(self.understoodButton) then
		self.understoodButton:Remove()
		self.understoodButton = nil
	end

	-- Clean up particles and materials
	self.treeParticles = nil
	self.treeGlowMats = nil
	self.ambientParticles = nil

	-- Stop ambient music
	self:StopAmbientMusic()

	-- Remove hooks
	hook.Remove("PreDrawOpaqueRenderables", "Arcana_TutorialRender")
	hook.Remove("PreDrawSkyBox", "Arcana_TutorialSkybox")
	hook.Remove("PreDrawTranslucentRenderables", "Arcana_TutorialTranslucent")
	hook.Remove("PreDrawViewModels", "Arcana_TutorialViewModels")
	hook.Remove("ShouldDrawLocalPlayer", "Arcana_TutorialShouldDrawLocalPlayer")
	hook.Remove("CalcView", "Arcana_TutorialView")
	hook.Remove("HUDPaint", "Arcana_TutorialHUD")
	hook.Remove("RenderScreenspaceEffects", "Arcana_TutorialScreenspace")
	hook.Remove("Think", "Arcana_TutorialThink")
	hook.Remove("PlayerBindPress", "Arcana_TutorialInput")
	hook.Remove("PlayerFootstep", "Arcana_TutorialFootstep")

	self.currentSequence = nil
end

-- Think hook
function Tutorial:Think()
	if not self.active then return end

	local ply = LocalPlayer()
	if not IsValid(ply) then return end

	-- Check if player died during tutorial
	if not ply:Alive() and self.phase ~= "fade_to_white" and self.phase ~= "fade_from_white" then
		-- Close any open panels
		if self.showingPanel then
			self.showingPanel = false
			if IsValid(self.understoodButton) then
				self.understoodButton:Remove()
				self.understoodButton = nil
			end
			gui.EnableScreenClicker(false)
		end

		-- Start fade to white transition to return to reality
		self.phase = "fade_to_white"
		self.fadeProgress = 0
		self.fadeStart = CurTime()
	end

	local now = CurTime()
	local dt = FrameTime()

	-- Update fade transitions
	if self.phase == "fade_to_black" then
		self.fadeProgress = math.Clamp((now - self.fadeStart) / self.fadeOutDuration, 0, 1)
		if self.fadeProgress >= 1 then
			-- While screen is fully black, initialize tutorial view and start fade in
			self.phase = "fade_from_black"
			self.fadeProgress = 0
			self.fadeStart = now

			if IsValid(self.tree) then
				self.previousEyeAngles = ply:EyeAngles()

				local dirToTree = self.tree:GetPos() - self.simulatedPos
				local ang = dirToTree:Angle()
				ang.z = 0
				ang:Normalize() -- Ensure angle is normalized
				self.simulatedAng = ang
				ply:SetEyeAngles(self.simulatedAng)
			end
		end
	elseif self.phase == "fade_from_black" then
		self.fadeProgress = math.Clamp((now - self.fadeStart) / self.fadeInDuration, 0, 1)
		if self.fadeProgress >= 1 then
			self.phase = "tutorial"
		end
	elseif self.phase == "fade_to_white" then
		self.fadeProgress = math.Clamp((now - self.fadeStart) / self.fadeOutDuration, 0, 1)
		if self.fadeProgress >= 1 then
			-- Screen is fully white, start fading back from white
			self.phase = "fade_from_white"
			self.fadeProgress = 0
			self.fadeStart = now

			if self.previousEyeAngles then
				LocalPlayer():SetEyeAngles(self.previousEyeAngles)
				self.previousEyeAngles = nil
			end
		end
	elseif self.phase == "fade_from_white" then
		self.fadeProgress = math.Clamp((now - self.fadeStart) / self.fadeInDuration, 0, 1)
		if self.fadeProgress >= 1 then
			self:EndSequence()
		end
	end

	-- Update simulated position
	if self.phase == "tutorial" then
		-- Update simulated angles from actual view (allow free camera)
		self.simulatedAng = ply:EyeAngles()

		-- Update movement based on key states
		self:UpdateMovement()

		-- Apply velocity to position
		self.simulatedPos = self.simulatedPos + self.simulatedVel * dt

		-- Constrain player to movement area around the tree
		if self.movementRadius and IsValid(self.tree) then
			local treePos = self.tree:GetPos()
			local offset = self.simulatedPos - treePos
			local dist = offset:Length()

			if dist > self.movementRadius then
				offset:Normalize()
				self.simulatedPos = treePos + offset * self.movementRadius
			end

			-- Check if player is in range of tree to trigger teaching panel
			if not self.triggeredPanel and dist <= self.interactionDistance then
				self.triggeredPanel = true
				-- Show teaching panel immediately
				self.phase = "show_panel"
				self:ShowTeachingPanel()
			end
		end

		-- Play footstep sounds
		self:PlayFootsteps()
	end

	-- Update sentence fade-in progress
	if self.showingPanel and self.fadeProgress < 1 then
		self.fadeProgress = math.Clamp((now - self.fadeStart) / self.fadeDuration, 0, 1)

		-- Check for space or mouse button press to skip to next line
		if input.IsKeyDown(KEY_SPACE) or input.IsMouseDown(MOUSE_LEFT) or input.IsMouseDown(MOUSE_RIGHT) then
			if not self._skipHandled then
				self._skipHandled = true

				-- Calculate which line we're on and skip to the next one
				local wrappedLines = self:WrapText(self.finalText, "Arcana_AncientLarge", 1000 - 120)
				local totalLines = #wrappedLines
				local currentLineFloat = self.fadeProgress * totalLines
				local currentLineIndex = math.floor(currentLineFloat)

				-- Move to the next line (or complete if we're on the last line)
				if currentLineIndex < totalLines - 1 then
					self.fadeProgress = (currentLineIndex + 1) / totalLines
					self.fadeStart = now - (self.fadeProgress * self.fadeDuration)
				else
					self.fadeProgress = 1
				end
			end
		else
			self._skipHandled = false
		end
	end

	if self.showingPanel and not vgui.CursorVisible() then
		gui.EnableScreenClicker(true)
	end

	-- Update ambient music volume
	self:UpdateAmbientMusic(dt)
end

-- Modify camera view
function Tutorial:ModifyView(ply, pos, angles, fov)
	if not self.active then return end
	if self.phase == "none" then return end

	-- Keep the view override active during tutorial, panel, and fade in/from phases
	-- Don't override during fade_to_black (still in normal world) or fade_from_white (returning to normal)
	if self.phase == "tutorial" or self.phase == "fade_from_black" or
	   self.phase == "show_panel" or self.phase == "fade_to_white" then
		local view = {
			origin = self.simulatedPos + Vector(0, 0, 64), -- Eye height
			angles = angles,
			fov = fov,
			drawviewer = false,
			zfar = 4000,
			znear = 1,
		}

		return view
	end
end

-- Render the tutorial environment
function Tutorial:RenderTutorial()
	if not self.active then return end
	-- Only render tutorial space during fade_from_black, tutorial, show_panel, and fade_to_white
	-- Don't render during fade_to_black (still in normal world) or fade_from_white (back to normal)
	if self.phase ~= "tutorial" and self.phase ~= "fade_from_black" and
	   self.phase ~= "show_panel" and self.phase ~= "fade_to_white" then return end

	-- Set up rendering from simulated position
	local eyePos = self.simulatedPos + Vector(0, 0, 64)
	local eyeAng = self.simulatedAng

	-- Draw skybox cube
	self:DrawSkyboxCube(eyePos)

	-- Draw ambient particles (comets, sparkles, blue particles)
	self:DrawAmbientParticles()

	-- Draw water plate
	self:DrawWaterPlate(eyePos)

	-- Draw tree
	self:DrawTree(eyePos)
end

-- Draw the skybox cube
function Tutorial:DrawSkyboxCube(eyePos)
	if not self.cubeFaces then return end

	-- Forcefully clear any world rendering artifacts
	render.Clear(0, 0, 0, 255, true, true)

	render.OverrideDepthEnable(true, true)
	render.SetLightingMode(2)

	-- Clamp texture coordinates to avoid seams
	render.PushFilterMin(TEXFILTER.LINEAR)
	render.PushFilterMag(TEXFILTER.LINEAR)

	for _, face in ipairs(self.cubeFaces) do
		if not face.material or face.material:IsError() then continue end

		render.SetMaterial(face.material)

		-- Use mesh to support custom UV coordinates for rotation
		-- Offset cube by simulated position so it follows the player
		mesh.Begin(MATERIAL_QUADS, 1)
			for i = 1, 4 do
				local vert = face.vertices[i]
				mesh.Position(vert.pos + self.simulatedPos)
				mesh.TexCoord(0, vert.u, vert.v)
				mesh.Color(255, 255, 255, 255)
				mesh.AdvanceVertex()
			end
		mesh.End()
	end

	render.PopFilterMin()
	render.PopFilterMag()

	render.SetLightingMode(0)
	render.OverrideDepthEnable(false)
end

-- Draw the water plate
function Tutorial:DrawWaterPlate(eyePos)
	if not self.waterMaterial then return end

	local size = self.plateSize
	local height = self.plateHeight
	local uvScale = 60

	-- Setup render state for translucent water
	render.SetMaterial(self.waterMaterial)
	render.OverrideDepthEnable(true, false)

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

-- Draw the golden tree
local TREE_COLOR = Color(255, 180, 0)
function Tutorial:DrawTree(eyePos)
	if not IsValid(self.tree) then return end

	-- Initialize glow materials if needed
	if not self.treeGlowMats then
		self.treeGlowMats = {
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
	local mins, maxs = self.tree:GetRenderBounds()
	local treeRoot = self.tree:GetPos() + Vector(0, 0, mins.z) -- Actual root/base of tree
	local treeCenter = self.tree:GetPos() + Vector(0, 0, 80) -- Center for subtle glow

	-- Draw with crystal shader if available
	if TREE_SHADER_MAT then
		-- Crystal shader rendering (multi-pass refraction)
		--render.UpdateScreenEffectTexture()
		render.OverrideDepthEnable(true, false) -- no Z write

		-- Draw base model underneath at a low alpha to unify color
		render.SetBlend(0.9)
		self.tree:DrawModel()
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
			self.tree:DrawModel()
			render.MaterialOverride()

			-- Capture the result to feed into next pass
			--render.CopyRenderTargetToTexture(scr)
		end

		render.OverrideDepthEnable(false, false)
	else
		-- Fallback: Draw the tree normally (solid)
		render.SetColorModulation(col.r / 255, col.g / 255, col.b / 255)
		render.SetBlend(0.85)
		self.tree:DrawModel()

		-- Second transparent pass for glow effect (barely visible)
		render.SetBlend(0.08)
		self.tree:DrawModel()

		-- Reset render state
		render.SetColorModulation(1, 1, 1)
		render.SetBlend(1)
	end

	-- 3. Draw crystal shard-style layered glow effect (very minimal)
	local radius = self.tree:BoundingRadius() * 0.5

	-- Layered glare sprites (very reduced to see tree clearly)
	render.SetMaterial(self.treeGlowMats.glare)
	render.DrawSprite(treeCenter, radius * 6, radius * 6, Color(col.r, col.g, col.b, 15))

	-- Outer glow (respects depth, minimal)
	render.SetMaterial(self.treeGlowMats.glare2)
	render.DrawSprite(treeCenter, radius * 12, radius * 3, Color(col.r, col.g, col.b, 8))

	-- 4. Draw rising golden particles
	self:DrawTreeParticles(treeRoot, col, radius)
end

-- Draw rising golden particles around the tree
function Tutorial:DrawTreeParticles(treeRoot, col, radius)
	-- Initialize particle data if needed
	if not self.treeParticles then
		self.treeParticles = {}
		for i = 1, 30 do -- 30 particles
			self.treeParticles[i] = {
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

	for i, particle in ipairs(self.treeParticles) do
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

-- Render screenspace post-processing effects
function Tutorial:RenderScreenspaceEffects()
	if not self.active then return end
	-- Only apply effects during tutorial space phases
	if self.phase ~= "tutorial" and self.phase ~= "fade_from_black" and
	   self.phase ~= "show_panel" and self.phase ~= "fade_to_white" then return end

	-- Color modification for enhanced saturation and vibrancy
	local colorMod = {
		["$pp_colour_addr"] = 0,
		["$pp_colour_addg"] = 0,
		["$pp_colour_addb"] = 0,
		["$pp_colour_brightness"] = 0.05,  -- Slight brightness increase
		["$pp_colour_contrast"] = 1.15,    -- Increased contrast
		["$pp_colour_colour"] = 1.25,       -- 50% more saturation
		["$pp_colour_mulr"] = 0,
		["$pp_colour_mulg"] = 0,
		["$pp_colour_mulb"] = 0
	}

	DrawColorModify(colorMod)

	-- Subtle bloom for magical feel
	DrawBloom(0.65, 1.15, 2, 2, 1, 1, 1, 1, 1)
end

-- Draw HUD overlay
function Tutorial:DrawTutorialHUD()
	if not self.active then return end

	local scrW, scrH = ScrW(), ScrH()

	-- Draw fade overlays
	if self.phase == "fade_to_black" then
		-- Fade out to black: fade for 2.0s, hold at peak for 0.5s
		local elapsed = CurTime() - self.fadeStart
		local fadeProgress = math.Clamp(elapsed / Tutorial.fadeOutTime, 0, 1)
		local alpha = math.floor(255 * fadeProgress)
		surface.SetDrawColor(0, 0, 0, alpha)
		surface.DrawRect(0, 0, scrW, scrH)
	elseif self.phase == "fade_from_black" then
		-- Fade in from black: hold at peak for 0.5s, then fade for 1.0s
		local elapsed = CurTime() - self.fadeStart
		local holdTime = Tutorial.fadeInDuration - Tutorial.fadeInTime
		local alpha = 255
		if elapsed > holdTime then
			local fadeProgress = math.Clamp((elapsed - holdTime) / Tutorial.fadeInTime, 0, 1)
			alpha = math.floor(255 * (1 - fadeProgress))
		end
		surface.SetDrawColor(0, 0, 0, alpha)
		surface.DrawRect(0, 0, scrW, scrH)
	elseif self.phase == "show_panel" then
		-- Draw teaching panel directly on tutorial scene
		if self.showingPanel then
			self:DrawTeachingPanel(scrW, scrH)
		end
	elseif self.phase == "fade_to_white" then
		-- Keep drawing panel while fading to white
		if self.showingPanel then
			self:DrawTeachingPanel(scrW, scrH)
		end

		-- Fade out to white: fade for 2.0s, hold at peak for 0.5s
		local elapsed = CurTime() - self.fadeStart
		local fadeProgress = math.Clamp(elapsed / Tutorial.fadeOutTime, 0, 1)
		local alpha = math.floor(255 * fadeProgress)
		surface.SetDrawColor(255, 255, 255, alpha)
		surface.DrawRect(0, 0, scrW, scrH)
	elseif self.phase == "fade_from_white" then
		-- Fade in from white: hold at peak for 0.5s, then fade for 1.0s
		local elapsed = CurTime() - self.fadeStart
		local holdTime = Tutorial.fadeInDuration - Tutorial.fadeInTime
		local alpha = 255
		if elapsed > holdTime then
			local fadeProgress = math.Clamp((elapsed - holdTime) / Tutorial.fadeInTime, 0, 1)
			alpha = math.floor(255 * (1 - fadeProgress))
		end
		surface.SetDrawColor(255, 255, 255, alpha)
		surface.DrawRect(0, 0, scrW, scrH)
	end
end

-- Draw the teaching panel with morphing text
function Tutorial:DrawTeachingPanel(scrW, scrH)
	-- Darken the entire screen
	surface.SetDrawColor(0, 0, 0, 200)
	surface.DrawRect(0, 0, scrW, scrH)

	local panelW, panelH = 1000, 600
	local panelX = (scrW - panelW) * 0.5
	local panelY = (scrH - panelH) * 0.5
	local padding = 60

	-- Calculate which sentences should be visible
	local textX = panelX + padding
	local textY = panelY + padding
	local lineHeight = draw.GetFontHeight("Arcana_AncientLarge") + 8
	local maxWidth = panelW - padding * 2
	local maxTextHeight = panelH - padding * 2 - 70 -- Reserve space for close button

	if self.finalText then
		-- Wrap the entire text
		local wrappedLines = self:WrapText(self.finalText, "Arcana_AncientLarge", maxWidth)
		local totalLines = #wrappedLines

		-- Calculate which line is currently being revealed
		local currentLineFloat = self.fadeProgress * totalLines
		local currentLineIndex = math.floor(currentLineFloat)
		local currentLineProgress = currentLineFloat - currentLineIndex

		-- Calculate total height and scroll
		local totalTextHeight = totalLines * lineHeight
		local scrollOffset = 0
		if totalTextHeight > maxTextHeight then
			-- Scroll to keep current line visible
			local currentLineY = currentLineIndex * lineHeight
			if currentLineY > maxTextHeight then
				scrollOffset = currentLineY - maxTextHeight + lineHeight * 2
			end
		end

		-- Set up font for character width calculations
		surface.SetFont("Arcana_AncientLarge")

		-- Draw lines
		for lineIdx = 0, totalLines - 1 do
			local line = wrappedLines[lineIdx + 1]
			local lineY = textY + lineIdx * lineHeight - scrollOffset

			-- Only draw if line is within visible area
			if lineY >= textY and lineY < (textY + maxTextHeight) then
				if lineIdx < currentLineIndex then
					-- Fully visible line with shadow for engraved effect
					-- Draw shadow first (darker, slightly offset)
					draw.DrawText(line, "Arcana_AncientLarge", textX + 2, lineY + 2,
						Color(0, 0, 0, 180), TEXT_ALIGN_LEFT)
					-- Draw golden text
					draw.DrawText(line, "Arcana_AncientLarge", textX, lineY,
						Color(220, 180, 70, 255), TEXT_ALIGN_LEFT)
				elseif lineIdx == currentLineIndex then
					-- Currently revealing line with gradient effect
					-- Build character position array first for accurate positioning
					local chars = {}
					local currentX = 0
					for i = 1, #line do
						local char = string.sub(line, i, i)
						local charWidth = surface.GetTextSize(char)
						table.insert(chars, {
							char = char,
							x = currentX,
							width = charWidth,
							centerX = currentX + charWidth / 2
						})
						currentX = currentX + charWidth
					end

					local totalLineWidth = currentX
					local revealPosition = totalLineWidth * currentLineProgress
					local gradientWidth = 150 -- Wider gradient for smoother effect

					-- Draw each character with calculated alpha and shadow
					for _, charData in ipairs(chars) do
						local alpha = 0

						if charData.centerX <= revealPosition then
							alpha = 255
						elseif charData.centerX <= revealPosition + gradientWidth then
							-- Gradient zone
							local fadeProgress = 1 - ((charData.centerX - revealPosition) / gradientWidth)
							alpha = math.floor(255 * fadeProgress)
						end

						if alpha > 0 then
							-- Draw shadow (darker, slightly offset)
							local shadowAlpha = math.floor(alpha * 0.7)
							draw.DrawText(charData.char, "Arcana_AncientLarge", textX + charData.x + 2, lineY + 2,
								Color(0, 0, 0, shadowAlpha), TEXT_ALIGN_LEFT)
							-- Draw golden text
							draw.DrawText(charData.char, "Arcana_AncientLarge", textX + charData.x, lineY,
								Color(220, 180, 70, alpha), TEXT_ALIGN_LEFT)
						end
					end
				end
				-- Lines beyond currentLineIndex are not drawn yet
			end
		end
	end

	-- Show the "Understood" button when animation completes
	if IsValid(self.understoodButton) then
		self.understoodButton:SetVisible(self.fadeProgress >= 1)
	end
end

--- Wrap text to fit within a specified width
function Tutorial:WrapText(text, font, maxWidth)
	surface.SetFont(font)

	local words = string.Explode(" ", text)
	local lines = {}
	local currentLine = ""

	for _, word in ipairs(words) do
		local testLine = currentLine == "" and word or (currentLine .. " " .. word)
		local textWidth = surface.GetTextSize(testLine)

		if textWidth > maxWidth and currentLine ~= "" then
			-- Current line is full, start new line
			table.insert(lines, currentLine)
			currentLine = word
		else
			currentLine = testLine
		end
	end

	-- Add the last line
	if currentLine ~= "" then
		table.insert(lines, currentLine)
	end

	return lines
end

-- Public API to start a tutorial sequence
function Arcane:StartTutorialSequence(sequence)
	return Tutorial:StartSequence(sequence)
end

-- Public API to check if tutorial is active
function Arcane:IsTutorialActive()
	return Tutorial.active
end
