AddCSLuaFile()
ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "Altar"
ENT.Category = "Arcana"
ENT.Spawnable = true
ENT.AdminSpawnable = true
ENT.RenderGroup = RENDERGROUP_BOTH
ENT.UseCooldown = 0.75
ENT.HintDistance = 140

function ENT:SetupDataTables()
	self:NetworkVar("Float", 0, "AuraSize")

	if SERVER then
		self:SetAuraSize(200)
	end
end

if SERVER then
	util.AddNetworkString("Arcana_OpenAltarMenu")

	resource.AddFile("materials/entities/arcana_altar.png")
	resource.AddFile("sound/arcana/altar_ambient_stereo.ogg")
	resource.AddFile("models/arcana_obelisk/arcana_obelisk_bottom.mdl")
	resource.AddFile("models/arcana_obelisk/arcana_obelisk_top.mdl")

	function ENT:Initialize()
		-- Use a base HL2 model that exists on all servers/clients
		self:SetModel("models/props_c17/gravestone_cross001b.mdl")
		self:SetMaterial("models/props_foliage/coastrock02")
		self:PhysicsInit(SOLID_VPHYSICS)
		self:SetMoveType(MOVETYPE_VPHYSICS)
		self:SetSolid(SOLID_VPHYSICS)
		self:SetUseType(SIMPLE_USE)

		local phys = self:GetPhysicsObject()
		if IsValid(phys) then
			phys:Wake()
			phys:EnableMotion(false)
		end

		-- Start motion controller for shadow control
		self:StartMotionController()
		self.ShadowParams = {}
		self._floatHeight = 100
		self._nextUse = 0
	end

	local TRACE_OFFSET = Vector(0, 0, 1000)
	local VECTOR_UP = Vector(0, 0, 1)
	function ENT:PhysicsSimulate(phys, deltatime)
		if not IsValid(phys) then return end

		phys:Wake()

		-- Trace down to find ground
		local currentPos = self.PositionOverride or self:GetPos()
		local tr = util.TraceLine({
			start = currentPos,
			endpos = currentPos - TRACE_OFFSET,
			mask = MASK_SOLID,
			filter = self,
		})

		-- Calculate target position from ground
		local floatPos = tr.HitPos + self._floatHeight * VECTOR_UP
		local targetAng = self:GetAngles()
		targetAng.p = 0
		targetAng.r = 0

		-- Set shadow parameters
		self.ShadowParams.secondstoarrive = 0.1
		self.ShadowParams.pos = floatPos
		self.ShadowParams.angle = targetAng
		self.ShadowParams.maxangular = 5000
		self.ShadowParams.maxangulardamp = 10000
		self.ShadowParams.maxspeed = 100000
		self.ShadowParams.maxspeeddamp = 10000
		self.ShadowParams.dampfactor = 0.8
		self.ShadowParams.teleportdistance = 0
		self.ShadowParams.delta = deltatime

		phys:ComputeShadowControl(self.ShadowParams)
	end

	function ENT:SpawnFunction(ply, tr, classname)
		if not tr or not tr.Hit then return end

		local pos = tr.HitPos + tr.HitNormal * 4
		local ent = ents.Create(classname or "arcana_altar")
		if not IsValid(ent) then return end

		ent:SetPos(pos + Vector(0, 0, 100))
		ent:SetAngles(Angle(0, ply:EyeAngles().y, 0))
		ent:Spawn()
		ent:Activate()

		return ent
	end

	function ENT:Use(ply)
		if not IsValid(ply) or not ply:IsPlayer() then return end
		local now = CurTime()
		if now < (self._nextUse or 0) then return end
		self._nextUse = now + self.UseCooldown
		net.Start("Arcana_OpenAltarMenu")
		net.WriteEntity(self)
		net.Send(ply)
		self:EmitSound("buttons/button9.wav", 60, 110)
	end
end

if CLIENT then
	-- 3D visuals
	function ENT:Initialize()
		self._circle = nil
		self._band = nil
		self._glowMat = Material("sprites/light_glow02_add")
		self._topGlyphPhrase = "αβραξασ  θεοσ  γνωσις  φως  ζωη  αληθεια  κοσμος  ψυχη  πνευμα  "
		self._lastThink = CurTime()
		-- Ambient loop state (only for the altar spawned by core.lua)
		self._ambient = nil
		self._ambientTargetVol = 0
		self:PrepareGlyphParticles()

		-- Create clientside obelisk props
		self:CreateObeliskProps()

		-- Animation state
		self._spinDuration = 24
		self._mergeDuration = 2
		self._mergedDuration = 5

		self._animStartTime = CurTime()
		self._animCycleTime = self._spinDuration + self._mergeDuration + self._mergedDuration -- Total cycle: 16s spin + 16s merge + 5s stay merged
	end

	function ENT:CreateObeliskProps()
		-- Clean up existing props if any
		if IsValid(self._obeliskTop) then
			self._obeliskTop:Remove()
		end

		if IsValid(self._obeliskBottom) then
			self._obeliskBottom:Remove()
		end

		-- Create bottom part
		self._obeliskBottom = ClientsideModel("models/arcana_obelisk/arcana_obelisk_bottom.mdl")
		if IsValid(self._obeliskBottom) then
			self._obeliskBottom:SetPos(self:GetPos())
			self._obeliskBottom:SetAngles(self:GetAngles())
			self._obeliskBottom:SetMaterial("models/props_foliage/coastrock02")
		end

		-- Create top part
		self._obeliskTop = ClientsideModel("models/arcana_obelisk/arcana_obelisk_top.mdl")
		if IsValid(self._obeliskTop) then
			self._obeliskTop:SetPos(self:GetPos())
			self._obeliskTop:SetAngles(self:GetAngles())
			self._obeliskTop:SetMaterial("models/props_foliage/coastrock02")

		end
	end

	-- Particle-style glyphs rising around the pillar (random XY spawn per glyph)
	function ENT:_SpawnGlyphParticle()
		local now = CurTime()
		local aura = math.max(60, self:GetAuraSize())
		local rMin = math.max(24, aura * 0.30)
		local rMax = math.max(rMin + 8, aura * 0.85)
		local ang = math.Rand(0, math.pi * 2)
		local r = math.Rand(rMin, rMax)
		local baseX = math.cos(ang) * r
		local baseY = math.sin(ang) * r

		-- Diverse speeds and travel distances
		local speed = math.random(30, 200)
		local travel = math.random(220, 900)
		local life = travel / speed

		-- Minor horizontal drift and a gentle orbit to keep it lively
		local driftX = math.Rand(-14, 14)
		local driftY = math.Rand(-14, 14)
		local orbitRadius = math.Rand(0, 10)
		local orbitSpeed = math.Rand(-4, 4)
		local orbitPhase = math.Rand(0, math.pi * 2)
		local phrase = self._topGlyphPhrase or "ARCANA "
		local phraseLen = (utf8 and utf8.len and utf8.len(phrase)) or #phrase
		local charIndex = math.random(1, math.max(1, phraseLen))
		local ch = (utf8 and utf8.sub and utf8.sub(phrase, charIndex, charIndex)) or string.sub(phrase, charIndex, charIndex)

		local particle = {
			born = now,
			dieAt = now + life,
			h = 0, -- vertical distance traveled
			speed = speed,
			travel = travel,
			char = ch,
			alpha = math.random(90, 160),
			baseX = baseX,
			baseY = baseY,
			driftX = driftX,
			driftY = driftY,
			orbitR = orbitRadius,
			orbitW = orbitSpeed,
			orbitP = orbitPhase,
		}

		self._glyphParticles[#self._glyphParticles + 1] = particle
	end

	function ENT:UpdateObeliskAnimation()
		-- Ensure props exist
		if not IsValid(self._obeliskTop) or not IsValid(self._obeliskBottom) then
			self:CreateObeliskProps()
			return
		end

		local now = CurTime()
		local cycleTime = self._animCycleTime
		local spinDur = self._spinDuration
		local mergeDur = self._mergeDuration
		local mergedDur = self._mergedDuration
		local startTime = self._animStartTime or now

		-- Calculate time in current cycle
		local elapsed = (now - startTime) % cycleTime

		local basePos = self:GetPos()
		local baseAng = self:GetAngles()
		local upVec = self:GetUp()

		local verticalSeparation = 30 -- Units to separate vertically

		if elapsed < spinDur then
			-- Spinning phase with vertical separation
			local spinFrac = elapsed / spinDur
			local spinAngle = spinFrac * 360 * 2 -- 2 full rotations during spin phase (faster)

			-- Ease in/out for vertical separation (smooth movement)
			local separationEase
			if spinFrac < 0.1 then
				-- Ease out when separating (10% of spin time)
				local t = spinFrac / 0.1
				separationEase = 1 - math.pow(1 - t, 3)
			else
				-- Stay fully separated for the rest of spin
				separationEase = 1
			end

			local separation = verticalSeparation * separationEase

			-- Bottom spins clockwise and moves down (rotate around entity's up axis)
			local bottomAng = Angle(baseAng.p, baseAng.y, baseAng.r)
			bottomAng:RotateAroundAxis(upVec, spinAngle)
			local bottomPos = basePos - upVec * separation
			self._obeliskBottom:SetPos(bottomPos)
			self._obeliskBottom:SetAngles(bottomAng)

			-- Top spins counter-clockwise and moves up (rotate around entity's up axis)
			local topAng = Angle(baseAng.p, baseAng.y, baseAng.r)
			topAng:RotateAroundAxis(upVec, -spinAngle)
			local topPos = basePos + upVec * separation
			self._obeliskTop:SetPos(topPos)
			self._obeliskTop:SetAngles(topAng)
		elseif elapsed < spinDur + mergeDur then
			-- Merging phase
			local mergeElapsed = elapsed - spinDur
			local mergeFrac = mergeElapsed / mergeDur

			-- Split merge into two phases: angle alignment (first 50%), then position merge (last 50%)
			local finalSpinAngle = 360 * 2

			if mergeFrac < 0.5 then
				-- Phase 1: Align angles while staying separated
				local alignFrac = mergeFrac / 0.5
				-- Ease in-out for smooth angle alignment
				local eased = alignFrac < 0.5
					and 2 * alignFrac * alignFrac
					or 1 - math.pow(-2 * alignFrac + 2, 2) / 2

				-- Bottom rotates from its final spin position to aligned (rotate around entity's up axis)
				local bottomAngle = finalSpinAngle * (1 - eased)
				local bottomAng = Angle(baseAng.p, baseAng.y, baseAng.r)
				bottomAng:RotateAroundAxis(upVec, bottomAngle)
				local bottomPos = basePos - upVec * verticalSeparation
				self._obeliskBottom:SetPos(bottomPos)
				self._obeliskBottom:SetAngles(bottomAng)

				-- Top rotates from its final spin position to aligned (rotate around entity's up axis)
				local topAngle = finalSpinAngle * (1 - eased)
				local topAng = Angle(baseAng.p, baseAng.y, baseAng.r)
				topAng:RotateAroundAxis(upVec, -topAngle)
				local topPos = basePos + upVec * verticalSeparation
				self._obeliskTop:SetPos(topPos)
				self._obeliskTop:SetAngles(topAng)
			else
				-- Phase 2: Move together while keeping angles aligned
				local moveFrac = (mergeFrac - 0.5) / 0.5
				-- Ease in-out for smooth position merge
				local eased = moveFrac < 0.5
					and 2 * moveFrac * moveFrac
					or 1 - math.pow(-2 * moveFrac + 2, 2) / 2

				-- Both parts are angle-aligned, now merge positions
				local currentSeparation = verticalSeparation * (1 - eased)

				local bottomPos = basePos - upVec * currentSeparation
				self._obeliskBottom:SetPos(bottomPos)
				self._obeliskBottom:SetAngles(baseAng)

				local topPos = basePos + upVec * currentSeparation
				self._obeliskTop:SetPos(topPos)
				self._obeliskTop:SetAngles(baseAng)
			end
		else
			-- Merged phase - both parts aligned and stay together for 5s
			self._obeliskBottom:SetPos(basePos)
			self._obeliskBottom:SetAngles(baseAng)

			self._obeliskTop:SetPos(basePos)
			self._obeliskTop:SetAngles(baseAng)
		end
	end

	function ENT:PrepareGlyphParticles()
		self._glyphParticles = {}
		self._glyphSpawnRate = 20 -- particles per second target
		self._glyphMaxParticles = 60
		self._glyphSpawnAccumulator = 0
	end

	function ENT:OnRemove()
		if self._circle and self._circle.Destroy then
			self._circle:Destroy()
		end

		self._circle = nil

		if self._band and self._band.Remove then
			self._band:Remove()
		end

		self._band = nil

		-- Stop ambient sound cleanly
		if self._ambient then
			self._ambient:Stop()
			self._ambient = nil
		end

		-- Clean up clientside obelisk props
		if IsValid(self._obeliskTop) then
			self._obeliskTop:Remove()
			self._obeliskTop = nil
		end

		if IsValid(self._obeliskBottom) then
			self._obeliskBottom:Remove()
			self._obeliskBottom = nil
		end
	end

	function ENT:Draw()
		-- Don't draw the base model, we use clientside obelisk props instead
		-- self:DrawModel()
	end

	local function getOrbPos(self)
		-- Calculate orb position at the merge point between the two separated parts
		return self:GetPos()
	end

	-- Removed ground magic circle to reduce visual noise
	local BAND_CIRCLE_COLOR = Color(222, 198, 120, 255)
	local function ensureBands(self)
		if not BandCircle or not BandCircle.Create then return end
		if self._band and self._band.IsActive and self._band:IsActive() then return end -- keep following in Think; nothing to do here

		-- Position at the merge point (center between separated parts)
		local top = getOrbPos(self)
		local ang = self:GetAngles()
		self._band = BandCircle.Create(top, ang, BAND_CIRCLE_COLOR, math.max(40, self:GetAuraSize() * 0.35))
		if not self._band then return end

		-- Three fast rotating bands on different axes
		local baseR = math.max(24, self:GetAuraSize() * 0.18)

		self._band:AddBand(baseR * 0.90 / 2, 6, {
			p = 0,
			y = 120,
			r = 0
		}, 2)

		self._band:AddBand(baseR * 1.10 / 2, 6, {
			p = 80,
			y = 0,
			r = 0
		}, 2)

		self._band:AddBand(baseR * 1.35 / 2, 6, {
			p = 0,
			y = 0,
			r = 140
		}, 2)
	end

	local function shouldShowOrb(self)
		-- Only show orb when parts are separated
		local now = CurTime()
		local cycleTime = self._animCycleTime or 37
		local spinDur = self._spinDuration or 16
		local mergeDur = self._mergeDuration or 16
		local startTime = self._animStartTime or now

		local elapsed = (now - startTime) % cycleTime

		-- Show orb during spinning phase and first half of merge (while still separated)
		if elapsed < spinDur then
			-- During spin - check if separated
			local spinFrac = elapsed / spinDur
			return spinFrac >= 0.01 -- Show almost immediately when separation starts
		elseif elapsed < spinDur + mergeDur then
			-- During merge - show during most of it, hide near the very end
			local mergeElapsed = elapsed - spinDur
			local mergeFrac = mergeElapsed / mergeDur
			return mergeFrac < 0.75 -- Hide later in the merge (was 0.5)
		else
			-- During merged phase - don't show
			return false
		end
	end

	function ENT:Think()
		local now = CurTime()
		self._lastThink = now

		-- Ensure/drive ambient loop only for the core-spawned altar
		local isCore = self:GetNWBool("ArcanaCoreSpawned", false)
		if isCore then
			if not self._ambient then
				self._ambient = CreateSound(self, "arcana/altar_ambient_stereo.ogg")

				if self._ambient then
					self._ambient:Play()
					self._ambient:SetSoundLevel(65)
					self._ambient:SetDSP(111)
					local timerName = "Arcana_AmbientLoop" .. self:EntIndex()

					timer.Create(timerName, 200, 0, function()
						if not self._ambient then return end
						if not IsValid(self) then return end
						self._ambient:Stop()
						self._ambient:Play()
						self._ambient:SetSoundLevel(65)
						self._ambient:SetDSP(111)
					end)
				end
			end

			if self._ambient then
				local listenerPos = EyePos()
				local dist = listenerPos:Distance(self:GetPos())
				-- Fade from 100% at <= 600u to 0% at >= 2000u
				local v = 1 - math.Clamp((dist - 1000) / (3000 - 1000), 0, 1)
				local target = math.Clamp(v, 0, 1)

				if math.abs((self._ambientTargetVol or 0) - target) > 0.01 then
					self._ambientTargetVol = target
					self._ambient:ChangeVolume(target, 0.2)
				end
			end
		else
			-- Not the core altar; ensure any stray ambient is silenced
			if self._ambient then
				self._ambient:Stop()
				self._ambient = nil
			end
		end

		-- Update obelisk animation
		self:UpdateObeliskAnimation()

		-- Only show bands and light when orb is visible (parts are separated)
		local showOrb = shouldShowOrb(self)
		if showOrb then
			ensureBands(self)

			if self._band and self._band.IsActive and self._band:IsActive() then
				local top = getOrbPos(self)
				self._band.position = top
				self._band.angles = self:GetAngles()
			end

			-- Dynamic light at exact orb sprite position
			local dl = DynamicLight(self:EntIndex())

			if dl then
				local orbPos = getOrbPos(self)
				dl.pos = orbPos
				dl.r = 255
				dl.g = 220
				dl.b = 140
				dl.brightness = 5
				dl.Decay = 800
				dl.Size = self:GetAuraSize() * 2
				dl.DieTime = now + 0.1
			end
		else
			-- Remove bands when orb should be hidden
			if self._band and self._band.Remove then
				self._band:Remove()
				self._band = nil
			end
		end

		-- Update glyph particles (spawn/update/expire)
		-- Only spawn particles when obelisk is separated (not merged)
		local showOrb = shouldShowOrb(self)
		local dt = FrameTime() > 0 and FrameTime() or 0.05

		if showOrb then
			self._glyphSpawnAccumulator = (self._glyphSpawnAccumulator or 0) + (self._glyphSpawnRate or 120) * dt
			local toSpawn = math.floor(self._glyphSpawnAccumulator)
			self._glyphSpawnAccumulator = self._glyphSpawnAccumulator - toSpawn

			if self._glyphParticles and #self._glyphParticles < (self._glyphMaxParticles or 160) then
				for i = 1, math.min(toSpawn, (self._glyphMaxParticles or 160) - #self._glyphParticles) do
					self:_SpawnGlyphParticle()
				end
			end
		else
			-- Reset accumulator when merged so it doesn't build up
			self._glyphSpawnAccumulator = 0
		end

		-- advance and cull
		if self._glyphParticles and #self._glyphParticles > 0 then
			local write = 1

			for read = 1, #self._glyphParticles do
				local p = self._glyphParticles[read]

				if p and now < (p.dieAt or 0) then
					p.h = (p.h or 0) + (p.speed or 60) * dt
					self._glyphParticles[write] = p
					write = write + 1
				end
			end

			for i = write, #self._glyphParticles do
				self._glyphParticles[i] = nil
			end
		end

		self:NextThink(now + 0.05)

		return true
	end

	-- Client menu
	local function BuildEligibleSpellList(ply)
		if not Arcane or not IsValid(ply) then return {} end
		local data = Arcane:GetPlayerData(ply)
		if not data then return {} end
		local out = {}

		for sid, sp in pairs(Arcane.RegisteredSpells or {}) do
			local already = data.unlocked_spells and data.unlocked_spells[sid]
			local levelOk = (data.level or 1) >= (sp.level_required or 1)
			local kpOk = (data.knowledge_points or 0) >= (sp.knowledge_cost or 1)

			if not already and levelOk and kpOk then
				table.insert(out, {
					id = sid,
					spell = sp
				})
			end
		end

		table.sort(out, function(a, b)
			if a.spell.level_required == b.spell.level_required then return a.spell.name < b.spell.name end

			return a.spell.level_required < b.spell.level_required
		end)

		return out
	end

	local function OpenAltarMenu(altar)
		if not Arcane then return end
		local ply = LocalPlayer()
		if not IsValid(ply) then return end
		local frame = vgui.Create("DFrame")
		frame:SetSize(760, 520)
		frame:Center()
		frame:SetTitle("")
		frame:MakePopup()
		-- Track tooltip panels for cleanup on close/remove
		frame._arcanaTooltips = {}

		hook.Add("HUDPaint", frame, function()
			local x, y = frame:LocalToScreen(0, 0)
			ArtDeco.DrawBlurRect(x, y, frame:GetWide(), frame:GetTall(), 4, 8)
		end)

		frame.Paint = function(pnl, w, h)
			ArtDeco.FillDecoPanel(6, 6, w - 12, h - 12, ArtDeco.Colors.decoBg, 14)
			ArtDeco.DrawDecoFrame(6, 6, w - 12, h - 12, ArtDeco.Colors.gold, 14)
			draw.SimpleText("ALTAR", "Arcana_DecoTitle", 18, 10, ArtDeco.Colors.paleGold)
			-- Level and Knowledge Points chips (XP progression hidden by request)
			local data = Arcane:GetPlayerData(ply)

			if data then
				-- Level chip
				local lvlText = "LVL " .. tostring(data.level or 1)
				surface.SetFont("Arcana_Ancient")
				local lvlW, lvlH = surface.GetTextSize(lvlText)
				local chipY = 11
				local chipX = 110
				local lvlChipW, chipH = lvlW + 18, lvlH + 6
				ArtDeco.FillDecoPanel(chipX, chipY, lvlChipW, chipH, ArtDeco.Colors.paleGold, 8)
				draw.SimpleText(lvlText, "Arcana_Ancient", chipX + (lvlChipW - lvlW) * 0.5, chipY + (chipH - lvlH) * 0.5, ArtDeco.Colors.chipTextCol)
				-- KP chip to the right
				local kpText = "KP " .. tostring(data.knowledge_points or 0)
				local kpW, kpH = surface.GetTextSize(kpText)
				local gap = 10
				local kpChipX = chipX + lvlChipW + gap
				local kpChipW = kpW + 18
				ArtDeco.FillDecoPanel(kpChipX, chipY, kpChipW, chipH, ArtDeco.Colors.paleGold, 8)
				draw.SimpleText(kpText, "Arcana_Ancient", kpChipX + (kpChipW - kpW) * 0.5, chipY + (chipH - kpH) * 0.5, ArtDeco.Colors.chipTextCol)
			end
		end

		if IsValid(frame.btnMinim) then
			frame.btnMinim:Hide()
		end

		if IsValid(frame.btnMaxim) then
			frame.btnMaxim:Hide()
		end

		if IsValid(frame.btnClose) then
			local close = frame.btnClose
			close:SetText("")
			close:SetSize(26, 26)

			function frame:PerformLayout(w, h)
				if IsValid(close) then
					close:SetPos(w - 26 - 10, 8)
				end
			end

			close.Paint = function(pnl, w, h)
				surface.SetDrawColor(ArtDeco.Colors.paleGold)
				local pad = 8
				surface.DrawLine(pad, pad, w - pad, h - pad)
				surface.DrawLine(w - pad, pad, pad, h - pad)
			end
		end

		-- Ensure tooltips are cleaned on close/remove
		frame.OnClose = function()
			if frame._arcanaTooltips then
				for pnl, _ in pairs(frame._arcanaTooltips) do
					if IsValid(pnl) then pnl:Remove() end
					hook.Remove("Think", "ArcanaTooltipPos_" .. tostring(pnl))
				end
				frame._arcanaTooltips = {}
			end
		end

		frame.OnRemove = frame.OnClose

		local content = vgui.Create("DPanel", frame)
		content:Dock(FILL)
		content:DockMargin(12, 34, 12, 12)
		content.Paint = nil
		local listPanel = vgui.Create("DPanel", content)
		listPanel:Dock(FILL)

		listPanel.Paint = function(pnl, w, h)
			ArtDeco.FillDecoPanel(4, 4, w - 8, h - 8, ArtDeco.Colors.decoPanel, 12)
			ArtDeco.DrawDecoFrame(4, 4, w - 8, h - 8, ArtDeco.Colors.gold, 12)
			draw.SimpleText(string.upper("Available Spells"), "Arcana_Ancient", 14, 10, ArtDeco.Colors.paleGold)
		end

		local scroll = vgui.Create("DScrollPanel", listPanel)
		scroll:Dock(FILL)
		scroll:DockMargin(12, 36, 12, 12)
		local vbar = scroll:GetVBar()
		vbar:SetWide(8)

		vbar.Paint = function(pnl, w, h)
			surface.DisableClipping(true)
			ArtDeco.FillDecoPanel(0, 0, w, h, ArtDeco.Colors.decoPanel, 8)
			ArtDeco.DrawDecoFrame(0, 0, w, h, ArtDeco.Colors.gold, 8)
			surface.DisableClipping(false)
		end

		vbar.btnGrip.Paint = function(pnl, w, h)
			surface.DisableClipping(true)
			surface.SetDrawColor(ArtDeco.Colors.gold)
			surface.DrawRect(0, 0, w, h)
			surface.DisableClipping(false)
		end

		local function rebuild()
			scroll:Clear()
			local eligible = BuildEligibleSpellList(ply)

			if #eligible == 0 then
				local lbl = vgui.Create("DLabel", scroll)
				lbl:SetText("No spells available to unlock right now.")
				lbl:SetFont("Arcana_AncientLarge")
				lbl:Dock(TOP)
				lbl:DockMargin(0, 6, 0, 0)
				lbl:SetTextColor(ArtDeco.Colors.textDim)

				return
			end

			for _, item in ipairs(eligible) do
				local sp = item.spell
				local row = vgui.Create("DPanel", scroll)
				row:Dock(TOP)
				row:SetTall(60)
				row:DockMargin(0, 0, 0, 8)
				-- Create info icon for spell description tooltip
				local infoIcon = vgui.Create("DPanel", row)
				infoIcon:SetSize(20, 20)
				infoIcon:SetPos(0, 0) -- Will be positioned in PerformLayout
				infoIcon:SetCursor("hand")
				infoIcon.SpellDescription = sp.description or "No description available"

				infoIcon.Paint = function(pnl, w, h)
					-- Draw a simple "i" icon in a circle using lines to create outline
					local cx, cy = w / 2, h / 2
					local radius = 8
					surface.SetDrawColor(ArtDeco.Colors.paleGold)
					-- Draw circle outline by drawing lines in a circle pattern
					local segments = 16

					for i = 0, segments - 1 do
						local angle1 = (i / segments) * math.pi * 2
						local angle2 = ((i + 1) / segments) * math.pi * 2
						local x1 = cx + math.cos(angle1) * radius
						local y1 = cy + math.sin(angle1) * radius
						local x2 = cx + math.cos(angle2) * radius
						local y2 = cy + math.sin(angle2) * radius
						surface.DrawLine(x1, y1, x2, y2)
					end

					draw.SimpleText("i", "Arcana_Ancient", w / 2, h / 2, ArtDeco.Colors.paleGold, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
				end

				-- Tooltip functionality
				local function updateTooltipPos(tooltip)
					if not IsValid(tooltip) then return end
					local x, y = gui.MousePos()
					tooltip:SetPos(x + 15, y - 30)
				end

				local function createTooltip()
					if IsValid(infoIcon.tooltip) then return end
					local tooltip = vgui.Create("DLabel")
					tooltip:SetSize(300, 60)
					tooltip:SetWrap(true)
					tooltip:SetText(infoIcon.SpellDescription)
					tooltip:SetFont("Arcana_AncientSmall")
					tooltip:SetTextColor(ArtDeco.Colors.textBright)
					tooltip:SetDrawOnTop(true)
					tooltip:SetMouseInputEnabled(false)
					tooltip:SetKeyboardInputEnabled(false)

					local TOOLTIP_BG_COLOR = Color(26, 20, 14, 245)
					tooltip.Paint = function(pnl, w, h)
						surface.DisableClipping(true)
						ArtDeco.FillDecoPanel(-10, 0, w, h, TOOLTIP_BG_COLOR, 8)
						ArtDeco.DrawDecoFrame(-10, 0, w, h, ArtDeco.Colors.gold, 8)
						surface.DisableClipping(false)
					end

					infoIcon.tooltip = tooltip

					-- Register for cleanup
					frame._arcanaTooltips[tooltip] = true
					updateTooltipPos(tooltip)

					-- Update position if mouse moves
					local hookName = "ArcanaTooltipPos_" .. tostring(tooltip)
					hook.Add("Think", hookName, function()
						if not IsValid(tooltip) then
							hook.Remove("Think", hookName)

							return
						end

						if not IsValid(infoIcon) then
							if IsValid(tooltip) then
								tooltip:Remove()
							end

							hook.Remove("Think", hookName)
							return
						end

						updateTooltipPos(tooltip)
					end)
				end

				local function destroyTooltip()
					if IsValid(infoIcon.tooltip) then
						local t = infoIcon.tooltip
						hook.Remove("Think", "ArcanaTooltipPos_" .. tostring(t))
						t:Remove()
						frame._arcanaTooltips[t] = nil
						infoIcon.tooltip = nil
					end
				end

				infoIcon.OnCursorEntered = createTooltip
				infoIcon.OnCursorExited = destroyTooltip

				local ROW_BG_COLOR = ArtDeco.Colors.cardIdle
				row.Paint = function(pnl, w, h)
					ArtDeco.FillDecoPanel(2, 2, w - 4, h - 4, ROW_BG_COLOR, 8)
					ArtDeco.DrawDecoFrame(2, 2, w - 4, h - 4, ArtDeco.Colors.gold, 8)
					draw.SimpleText(sp.name, "Arcana_AncientLarge", 12, 8, ArtDeco.Colors.textBright)
					local sub = string.format("Lvl %d  Cost %d KP", sp.level_required or 1, sp.knowledge_cost or 1)
					draw.SimpleText(sub, "Arcana_AncientSmall", 12, 34, ArtDeco.Colors.paleGold)
				end

				-- Position the info icon next to the spell name
				row.PerformLayout = function(pnl, w, h)
					if IsValid(infoIcon) then
						-- Get the width of the spell name to position icon after it
						surface.SetFont("Arcana_AncientLarge")
						local nameW, nameH = surface.GetTextSize(sp.name)
						infoIcon:SetPos(16 + nameW, 8 + (nameH - 20) / 2)
					end
				end

				local btn = vgui.Create("DButton", row)
				btn:Dock(RIGHT)
				btn:DockMargin(6, 10, 10, 10)
				btn:SetWide(120)
				btn:SetText("")

				-- Determine affordability live from current data
				local function updateEnabled()
					local d = Arcane:GetPlayerData(ply)
					local curKP = (d and d.knowledge_points) or 0
					local cost = sp.knowledge_cost or 1
					btn:SetEnabled(curKP >= cost)
				end

				updateEnabled()

				btn.Paint = function(pnl, w, h)
					local enabled = pnl:IsEnabled()
					local hovered = enabled and pnl:IsHovered()
					local bgCol = hovered and ArtDeco.Colors.cardHover or ArtDeco.Colors.cardIdle
					surface.DisableClipping(true)
					ArtDeco.FillDecoPanel(0, 0, w, h, bgCol, 8)
					ArtDeco.DrawDecoFrame(0, 0, w, h, ArtDeco.Colors.gold, 8)
					surface.DisableClipping(false)
					local col = enabled and ArtDeco.Colors.textBright or ArtDeco.Colors.textDim
					draw.SimpleText("Unlock", "Arcana_AncientLarge", w * 0.5, h * 0.5, col, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
				end

				function btn:DoClick()
					local d = Arcane:GetPlayerData(ply)
					local curKP = (d and d.knowledge_points) or 0
					local cost = sp.knowledge_cost or 1

					if curKP < cost then
						surface.PlaySound("buttons/button8.wav")
						notification.AddLegacy("Not enough Knowledge Points", NOTIFY_ERROR, 3)
						rebuild()

						return
					end

					net.Start("Arcane_UnlockSpell")
					net.WriteString(item.id)
					net.SendToServer()
					surface.PlaySound("buttons/button14.wav")
					self:SetEnabled(false)
					timer.Simple(0.25, rebuild)
				end
			end
		end

		rebuild()
		-- Live-rebuild when KP changes while the menu is open
		local lastKP = (Arcane:GetPlayerData(ply) and Arcane:GetPlayerData(ply).knowledge_points) or 0

		function frame:Think()
			local d = Arcane:GetPlayerData(ply)
			local kp = (d and d.knowledge_points) or 0

			if kp ~= lastKP then
				lastKP = kp
				rebuild()
			end
		end
	end

	net.Receive("Arcana_OpenAltarMenu", function()
		local ent = net.ReadEntity()

		if IsValid(ent) then
			OpenAltarMenu(ent)
		end
	end)

	local COLOR_GLOW = Color(255, 230, 160, 230)
	local TOP_OFFSET = Vector(0, 0, 10)
	function ENT:DrawTranslucent()
		-- glowy core at the merge point (only when parts are separated)
		if not self._glowMat then return end

		local t = CurTime()

		-- Only draw orb when parts are separated
		if shouldShowOrb(self) then
			local pos = getOrbPos(self)
			local pulse = 0.5 + 0.5 * math.sin(t * 3.2)
			local size = 128 + 64 * pulse
			render.SetMaterial(self._glowMat)
			render.DrawSprite(pos, size, size, COLOR_GLOW)
		end

		-- Lightweight glyph particles rising like sparks around the pillar top
		surface.SetFont("MagicCircle_Medium")

		-- local _, charH = surface.GetTextSize("A")
		local ply = LocalPlayer()
		local topAng = self:GetAngles()

		if IsValid(ply) then
			local toPlayer = (ply:GetPos() - self:GetPos()):GetNormalized()
			topAng = toPlayer:Angle()
		end

		topAng:RotateAroundAxis(topAng:Right(), -90)
		topAng:RotateAroundAxis(topAng:Up(), 90)

		-- ensure the font and color will show up clearly
		surface.SetFont("MagicCircle_Medium")
		local baseTop = self:GetPos() + TOP_OFFSET
		if not self._glyphParticles then return end

		draw.NoTexture()

		for _, p in ipairs(self._glyphParticles) do
			local lifeFrac = 1

			if p.dieAt then
				local remain = p.dieAt - t
				local total = (p.dieAt - (p.born or t))
				lifeFrac = math.Clamp(remain / math.max(0.001, total), 0, 1)
			end

			local travelFrac = math.Clamp((p.h or 0) / math.max(1, p.travel or 200), 0, 1)
			local tailFadeStart = 0.9
			local tailFade = travelFrac >= tailFadeStart and (1 - (travelFrac - tailFadeStart) / (1 - tailFadeStart)) or 1
			local alpha = math.floor((p.alpha or 36) * lifeFrac * tailFade)

			if alpha > 0 then
				local ox = (p.baseX or 0) + (p.driftX or 0) + (p.orbitR or 0) * math.cos((p.orbitW or 0) * t + (p.orbitP or 0))
				local oy = (p.baseY or 0) + (p.driftY or 0) + (p.orbitR or 0) * math.sin((p.orbitW or 0) * t + (p.orbitP or 0))
				local worldPos = baseTop + Vector(ox, oy, 0)
				cam.Start3D2D(worldPos, topAng, 0.06)
				surface.SetTextColor(255, 240, 180, alpha)
				surface.SetTextPos(0, -math.floor(p.h or 0))
				surface.DrawText(p.char or "")
				cam.End3D2D()
			end
		end
	end
end