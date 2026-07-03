local _shaderOk, _shaderErr = pcall(require, "shader_to_gma")
if not _shaderOk then
	MsgC(Color(255, 200, 0), "[Arcana] ", Color(200, 200, 200), "Optional dependency 'shader_to_gma' not found — tutorial crystal shaders will be disabled. " .. tostring(_shaderErr) .. "\n")
end

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
Arcana.Tutorial = Tutorial

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
-- focusEnt is set by the active scene (Arcana_Tutorial_CreateScene hook); it anchors
-- player spawn positioning, the initial look-at, voice playback and panel triggering.
Tutorial.focusEnt = nil
-- Direction from the focus entity towards the player spawn point; scenes can read
-- this (e.g. to make their focus entity face the player when the scene fades in)
Tutorial.spawnAwayDir = Vector(-1, 1, 0):GetNormalized()
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
Tutorial.currentNode = nil
Tutorial.currentVoiceSound = nil

-- Greek text morphing
Tutorial.morphProgress = 0
Tutorial.morphDuration = 1.0
Tutorial.greekText = ""
Tutorial.finalText = ""

--[[
	Sequence format (Conversation Tree):
	{
		id = "scene_id", -- Identifies which scene hooks should respond (see hooks below)
		nodes = {
			["node_id"] = {
				text = "Dialogue text here",
				voice = "path/to/voice.ogg", -- Optional voice file
				choices = {
					{ text = "Choice 1", next = "next_node_id", onSelect = function() end },
					{ text = "Choice 2", next = "another_node_id" },
					-- subtext: optional out-of-character mechanics line shown
					-- under the choice (e.g. what the choice grants/inflicts)
					{ text = "Choice 3", next = "id", subtext = "Get X and Y for 1h" },
				},
			}
		},
		startNode = "node_id",
		interactionDistance = 100, -- Optional: distance to focusEnt that triggers the panel
		allowTranslucents = false, -- Optional: keep the translucent pass so particle effects render
		onEnter = function() end,
		onComplete = function() end
	}

	Scene hooks (fired via Arcana.RunHook, receive the Tutorial table):
		Arcana_Tutorial_CreateScene(tutorial, sequence)
			Create scene ClientsideModels and set tutorial.focusEnt.
			Optionally set tutorial.groundZ to control the height the player
			walks at (defaults to the focus entity's z).
		Arcana_Tutorial_DrawScene(tutorial, eyePos)
			Draw the scene objects (models, floor/water, glows, effects).
		Arcana_Tutorial_DrawAmbientParticles(tutorial, eyePos)
			Draw the ambient particle field.
		Arcana_Tutorial_Footstep(tutorial, ply)
			Play a footstep sound (fired while the player is moving).
		Arcana_Tutorial_ColorModify(tutorial, colorMod)
			Mutate the base DrawColorModify table before it is applied.
		Arcana_Tutorial_ScreenspaceEffects(tutorial)
			Layer scene-specific post-processing on top of the base grade.
		Arcana_Tutorial_DestroyScene(tutorial, sequence)
			Remove scene entities and clear scene state.
	Hook implementations must guard on sequence/currentSequence id.
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

	-- Check if voice is still playing
	if self.voicePlaying and self.currentVoiceSound then
		if not IsValid(self.currentVoiceSound) then
			self.voicePlaying = false
			self.currentVoiceSound = nil
		end
	end

	-- Lower ambient music when voice is playing
	if self.voicePlaying then
		targetVolume = targetVolume * 0.3 -- Reduce to 30% when voice is playing
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
	if self.active then return false end

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
	self.interactionDistance = sequence.interactionDistance or 100

	-- Initialize visuals
	self:InitializeSkybox()
	self:CreateCubeMesh()

	-- Let the sequence's scene build its objects and set focusEnt
	-- (scenes may also set groundZ to control the height the player walks at)
	self.focusEnt = nil
	self.groundZ = nil
	Arcana.RunHook("Tutorial_CreateScene", self, sequence)

	-- Start ambient music (will fade in)
	self:StartAmbientMusic()

	-- Position player at edge of movement radius from the scene's focus entity
	if IsValid(self.focusEnt) and self.movementRadius then
		local focusPos = self.focusEnt:GetPos()

		-- Place player at edge of movement radius; walk height comes from the
		-- scene's groundZ when set (the focus entity may sit high above it)
		self.simulatedPos = focusPos + self.spawnAwayDir * self.movementRadius
		self.simulatedPos.z = self.groundZ or focusPos.z
	end

	-- Reset interaction state
	self.showingPanel = false
	self.fadeProgress = 0

	-- Initialize conversation tree
	self.currentNode = sequence.startNode or "start"

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
		-- Sequences with allowTranslucents keep this pass so particle effects
		-- (util.Effect) can render inside the tutorial space; the trade-off is
		-- that the real map's translucent surfaces may render too.
		if sequence.allowTranslucents then return end
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
	self.keyBackward = self.keyBackward or input.LookupBinding("+back")
	self.keyLeft = self.keyLeft or input.LookupBinding("+moveleft")
	self.keyRight = self.keyRight or input.LookupBinding("+moveright")

	-- Check continuous key states
	if self.keyForward and input.IsKeyDown(input.GetKeyCode(self.keyForward)) then
		moveDir = moveDir + forward
	end
	if self.keyBackward and input.IsKeyDown(input.GetKeyCode(self.keyBackward)) then
		moveDir = moveDir - forward
	end
	if self.keyLeft and input.IsKeyDown(input.GetKeyCode(self.keyLeft)) then
		moveDir = moveDir - right
	end
	if self.keyRight and input.IsKeyDown(input.GetKeyCode(self.keyRight)) then
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

-- Play footstep sounds; the actual sound is provided by the active scene
function Tutorial:PlayFootsteps()
	if not self.isMoving then return end

	local now = CurTime()
	if now < (self.nextFootstep or 0) then return end

	local ply = LocalPlayer()
	if not IsValid(ply) then return end

	Arcana.RunHook("Tutorial_Footstep", self, ply)
	self.nextFootstep = now + 0.45 -- Slightly slower footstep interval
end

-- Show the teaching panel
function Tutorial:ShowTeachingPanel()
	self.showingPanel = true
	self.fadeProgress = 0
	self.fadeStart = CurTime()

	-- Get current node data
	local nodeData = self:GetCurrentNodeData()
	if not nodeData then
		ErrorNoHalt("[Arcana Tutorial] Invalid node data!\n")
		return
	end

	-- Store text for display
	self.finalText = nodeData.text or "..."

	-- Calculate duration: ~4 seconds per line for comfortable reading
	local estimatedCharsPerLine = 60
	local estimatedLines = math.max(1, math.ceil(#self.finalText / estimatedCharsPerLine))
	self.fadeDuration = estimatedLines * 4.0

	-- Play voice if available
	self:PlayNodeVoice(nodeData)

	-- Enable mouse cursor
	gui.EnableScreenClicker(true)

	-- Get choices (or default "Understood" choice)
	local choices = nodeData.choices
	if not choices or #choices == 0 then
		choices = {{ text = "Understood", next = nil }}
	end

	-- Create choice buttons
	self:CreateChoiceButtons(choices)
end

-- Get current node data from conversation tree
function Tutorial:GetCurrentNodeData()
	if not self.currentSequence or not self.currentSequence.nodes then return nil end

	local nodeId = self.currentNode or self.currentSequence.startNode
	return self.currentSequence.nodes[nodeId]
end

-- Play voice for current node
function Tutorial:PlayNodeVoice(nodeData)
	-- Stop any currently playing voice
	self:StopNodeVoice()

	-- Play new voice if available
	if nodeData.voice and IsValid(self.focusEnt) then
		local voicePath = "sound/" .. nodeData.voice

		sound.PlayFile(voicePath, "mono noblock", function(channel, errorID, errorName)
			if IsValid(channel) then
				self.currentVoiceSound = channel

				-- Position at the scene's focus entity
				if IsValid(self.focusEnt) then
					channel:SetPos(self.focusEnt:GetPos())
				end

				-- Set high volume and enable 3D
				channel:SetVolume(3.0) -- Much louder than CSoundPatch
				channel:Play()

				-- Lower ambient music while voice is playing
				self.voicePlaying = true
			else
				ErrorNoHalt("[Arcana Tutorial] Failed to play voice: " .. tostring(errorName) .. "\n")
			end
		end)
	end
end

-- Stop any playing voice
function Tutorial:StopNodeVoice()
	if self.currentVoiceSound and IsValid(self.currentVoiceSound) then
		self.currentVoiceSound:Stop()
		self.currentVoiceSound = nil
	end
	self.voicePlaying = false
end

-- Create choice buttons (list style with art deco outline on hover)
function Tutorial:CreateChoiceButtons(choices)
	-- Remove any existing buttons
	if self.choiceButtons then
		for _, btn in ipairs(self.choiceButtons) do
			if IsValid(btn) then
				btn:Remove()
			end
		end
	end
	self.choiceButtons = {}

	local scrW, scrH = ScrW(), ScrH()
	local panelW, panelH = 1000, 600
	local panelY = (scrH - panelH) * 0.5
	local padding = 60
	local btnSpacing = 12
	local btnHeight = 45
	local btnHeightSub = 62 -- Taller when the choice carries a subtext line
	local btnWidth = panelW - padding * 2

	-- Heights vary per choice, so lay the stack out bottom-up from its total
	local totalHeight = 0

	for i, choice in ipairs(choices) do
		totalHeight = totalHeight + (choice.subtext and btnHeightSub or btnHeight)
		if i > 1 then
			totalHeight = totalHeight + btnSpacing
		end
	end

	local curY = panelY + panelH - padding - totalHeight

	for i, choice in ipairs(choices) do
		local btnX = (scrW - btnWidth) * 0.5
		local thisHeight = choice.subtext and btnHeightSub or btnHeight

		local btn = vgui.Create("DButton")
		btn:SetPos(btnX, curY)
		btn:SetSize(btnWidth, thisHeight)
		btn:SetText("")
		btn:SetCursor("hand")
		btn:SetVisible(false) -- Will be shown when animation completes
		curY = curY + thisHeight + btnSpacing

		-- Store choice data
		btn.choiceData = choice

		-- Custom paint function with list item style
		btn.Paint = function(pnl, w, h)
			local hovered = pnl:IsHovered()

			-- Background with subtle fill
			local bgCol = hovered and Color(220, 180, 70, 100) or Color(0, 0, 0, 80)
			local outlineCol = hovered and Color(220, 180, 70, 255) or Color(180, 140, 50, 150)

			if ArtDeco then
				-- Use art deco styling - always show background and outline
				ArtDeco.FillDecoPanel(0, 0, w, h, bgCol, 4)
				ArtDeco.DrawDecoFrame(0, 0, w, h, outlineCol, 4)
			else
				-- Fallback styling
				draw.RoundedBox(4, 0, 0, w, h, bgCol)
				surface.SetDrawColor(outlineCol)
				surface.DrawOutlinedRect(0, 0, w, h, 2)
			end

			-- With a subtext the main line sits higher to make room for it
			local mainY = choice.subtext and h * 0.32 or h * 0.5

			-- Bullet point (list style)
			local bulletX = 20
			local bulletSize = 4
			draw.RoundedBox(bulletSize, bulletX - bulletSize / 2, mainY - bulletSize / 2, bulletSize, bulletSize,
				hovered and Color(255, 230, 150) or Color(220, 180, 70))

			-- Choice text with shadow
			local textX = 40
			draw.SimpleText(choice.text, "Arcana_Ancient", textX + 1, mainY + 1,
				Color(0, 0, 0, 180), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
			draw.SimpleText(choice.text, "Arcana_Ancient", textX, mainY,
				hovered and Color(255, 230, 150) or Color(220, 180, 70), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)

			-- Mechanics subtext: dimmer, smaller line under the choice
			if choice.subtext then
				local subY = h * 0.72
				draw.SimpleText(choice.subtext, "Arcana_AncientSmall", textX + 1, subY + 1,
					Color(0, 0, 0, 160), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
				draw.SimpleText(choice.subtext, "Arcana_AncientSmall", textX, subY,
					hovered and Color(220, 195, 140) or Color(165, 140, 90), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
			end
		end

		btn.DoClick = function()
			self:OnChoiceSelected(choice)
		end

		table.insert(self.choiceButtons, btn)
	end
end

-- Handle choice selection
function Tutorial:OnChoiceSelected(choice)
	-- Let the sequence react to this specific choice (e.g. record a decision)
	if choice.onSelect then
		choice.onSelect(self, choice)
	end

	-- If no next node, close the panel (end of conversation)
	if not choice.next then
		self:CloseTeachingPanel()
		return
	end

	-- Stop current voice
	self:StopNodeVoice()

	-- Remove current buttons
	if self.choiceButtons then
		for _, btn in ipairs(self.choiceButtons) do
			if IsValid(btn) then
				btn:Remove()
			end
		end
		self.choiceButtons = nil
	end

	-- Navigate to next node
	self.currentNode = choice.next

	-- Reset fade progress for new text
	self.fadeProgress = 0
	self.fadeStart = CurTime()

	-- Get new node data
	local nodeData = self:GetCurrentNodeData()
	if not nodeData then
		ErrorNoHalt("[Arcana Tutorial] Invalid node: " .. tostring(choice.next) .. "\n")
		return
	end

	-- Update text
	self.finalText = nodeData.text or "..."

	-- Recalculate fade duration
	local estimatedCharsPerLine = 60
	local estimatedLines = math.max(1, math.ceil(#self.finalText / estimatedCharsPerLine))
	self.fadeDuration = estimatedLines * 4.0

	-- Play voice for new node
	self:PlayNodeVoice(nodeData)

	-- Get choices (or default "Understood" choice)
	local choices = nodeData.choices
	if not choices or #choices == 0 then
		choices = {{ text = "Understood", next = nil }}
	end

	-- Create new buttons
	self:CreateChoiceButtons(choices)
end

-- Close teaching panel and transition back
function Tutorial:CloseTeachingPanel()
	self.showingPanel = false
	self.phase = "fade_to_white"
	self.fadeProgress = 0
	self.fadeStart = CurTime()

	-- Stop voice
	self:StopNodeVoice()

	-- Remove choice buttons
	if self.choiceButtons then
		for _, btn in ipairs(self.choiceButtons) do
			if IsValid(btn) then
				btn:Remove()
			end
		end
		self.choiceButtons = nil
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

	-- Let the scene remove its entities and state
	Arcana.RunHook("Tutorial_DestroyScene", self, self.currentSequence)
	self.focusEnt = nil

	-- Stop voice
	self:StopNodeVoice()

	-- Remove choice buttons
	if self.choiceButtons then
		for _, btn in ipairs(self.choiceButtons) do
			if IsValid(btn) then
				btn:Remove()
			end
		end
		self.choiceButtons = nil
	end

	-- Stop ambient music
	self:StopAmbientMusic()

	-- Remove hooks
	hook.Remove("PreDrawOpaqueRenderables", "Arcana_TutorialRender")
	hook.Remove("PreDrawSkyBox", "Arcana_TutorialSkybox")
	hook.Remove("PreDrawTranslucentRenderables", "Arcana_TutorialTranslucent")
	hook.Remove("PreDrawViewModel", "Arcana_TutorialViewModels")
	hook.Remove("ShouldDrawLocalPlayer", "Arcana_TutorialShouldDrawLocalPlayer")
	hook.Remove("CalcView", "Arcana_TutorialView")
	hook.Remove("HUDPaint", "Arcana_TutorialHUD")
	hook.Remove("RenderScreenspaceEffects", "Arcana_TutorialScreenspace")
	hook.Remove("Think", "Arcana_TutorialThink")
	hook.Remove("PlayerBindPress", "Arcana_TutorialInput")
	hook.Remove("PlayerFootstep", "Arcana_TutorialFootstep")

	self.currentSequence = nil
	self.currentNode = nil
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

			-- Stop voice
			self:StopNodeVoice()

			-- Remove choice buttons
			if self.choiceButtons then
				for _, btn in ipairs(self.choiceButtons) do
					if IsValid(btn) then
						btn:Remove()
					end
				end
				self.choiceButtons = nil
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

			if IsValid(self.focusEnt) then
				self.previousEyeAngles = ply:EyeAngles()

				local dirToFocus = self.focusEnt:GetPos() - self.simulatedPos
				local ang = dirToFocus:Angle()
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

		-- Constrain player to movement area around the scene's focus entity
		-- (horizontal distance only - the focus entity may sit above the walk plane)
		if self.movementRadius and IsValid(self.focusEnt) then
			local focusPos = self.focusEnt:GetPos()
			local offset = self.simulatedPos - focusPos
			offset.z = 0
			local dist = offset:Length()

			if dist > self.movementRadius then
				offset:Normalize()
				self.simulatedPos = Vector(focusPos.x, focusPos.y, self.simulatedPos.z) + offset * self.movementRadius
			end

			-- Check if player is in range of the focus entity to trigger teaching panel
			if not self.triggeredPanel and dist <= self.interactionDistance then
				self.triggeredPanel = true

				-- Face the scene's focus entity as the dialogue begins
				local eyePos = self.simulatedPos + Vector(0, 0, 64)
				local lookAng = (self.focusEnt:WorldSpaceCenter() - eyePos):Angle()
				lookAng.z = 0
				lookAng:Normalize()
				self.simulatedAng = lookAng
				ply:SetEyeAngles(lookAng)

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

	-- Draw the active scene's ambient particle field
	Arcana.RunHook("Tutorial_DrawAmbientParticles", self, eyePos)

	-- Draw the active scene's objects (including its floor/water, if any)
	Arcana.RunHook("Tutorial_DrawScene", self, eyePos)
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

	-- Let the active scene adjust the grade (mutate the table in-place);
	-- a single DrawColorModify call applies the combined result
	Arcana.RunHook("Tutorial_ColorModify", self, colorMod)

	DrawColorModify(colorMod)

	-- Subtle bloom for magical feel
	DrawBloom(0.65, 1.15, 2, 2, 1, 1, 1, 1, 1)

	-- Let the active scene layer its own grading on top
	Arcana.RunHook("Tutorial_ScreenspaceEffects", self)
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
					draw.DrawText(line, "Arcana_AncientLarge", textX + 2, lineY + 2,
						Color(0, 0, 0, 180), TEXT_ALIGN_LEFT)
					draw.DrawText(line, "Arcana_AncientLarge", textX, lineY,
						Color(220, 180, 70, 255), TEXT_ALIGN_LEFT)
				elseif lineIdx == currentLineIndex then
					-- Currently revealing line with gradient effect
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
					local gradientWidth = 50 -- Tighter gradient for continuous feel

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
							local shadowAlpha = math.floor(alpha * 0.7)
							draw.DrawText(charData.char, "Arcana_AncientLarge", textX + charData.x + 2, lineY + 2,
								Color(0, 0, 0, shadowAlpha), TEXT_ALIGN_LEFT)
							draw.DrawText(charData.char, "Arcana_AncientLarge", textX + charData.x, lineY,
								Color(220, 180, 70, alpha), TEXT_ALIGN_LEFT)
						end
					end
				end
				-- Lines beyond currentLineIndex are not drawn yet
			end
		end
	end

	-- Show buttons when animation completes
	if self.choiceButtons then
		for _, btn in ipairs(self.choiceButtons) do
			if IsValid(btn) then
				btn:SetVisible(self.fadeProgress >= 1)
			end
		end
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
function Arcana:StartTutorialSequence(sequence)
	return Tutorial:StartSequence(sequence)
end

-- Public API to check if tutorial is active
function Arcana:IsTutorialActive()
	return Tutorial.active
end
