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
	self:NetworkVar("Bool", 0, "AltarIsOpen")

	if SERVER then
		self:SetAuraSize(200)
		self:SetAltarIsOpen(false)
	end
end

if SERVER then
	util.AddNetworkString("Arcana_OpenAltarMenu")

	resource.AddFile("materials/entities/arcana_altar.png")
	resource.AddFile("sound/arcana/altar_ambient_stereo.ogg")
	resource.AddFile("models/arcana_obelisk/arcana_obelisk_bottom.mdl")
	resource.AddFile("models/arcana_obelisk/arcana_obelisk_top.mdl")
	resource.AddFile("materials/models/arcana_obelisk/arcana_bronze.vmt")
	resource.AddFile("materials/models/arcana_obelisk/arcana_bronze_nm.vtf")

	function ENT:Initialize()
		-- Use a base HL2 model that exists on all servers/clients
		self:SetModel("models/props_c17/gravestone_cross001b.mdl")
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
		self._activeUsers = {}
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

		self._activeUsers[ply] = true
		self:SetAltarIsOpen(true)

		net.Start("Arcana_OpenAltarMenu")
		net.WriteEntity(self)
		net.Send(ply)
		self:EmitSound("buttons/button9.wav", 60, 110)
	end

	function ENT:PlayerClosedMenu(ply)
		if self._activeUsers then
			self._activeUsers[ply] = nil
		end

		local hasUsers = false
		for p in pairs(self._activeUsers or {}) do
			if IsValid(p) then
				hasUsers = true
				break
			end
		end

		if not hasUsers then
			self:SetAltarIsOpen(false)
		end
	end

	util.AddNetworkString("Arcana_CloseAltarMenu")

	net.Receive("Arcana_CloseAltarMenu", function(len, ply)
		local ent = net.ReadEntity()
		if not IsValid(ent) or ent:GetClass() ~= "arcana_altar" then return end
		ent:PlayerClosedMenu(ply)
	end)

	hook.Add("PlayerDisconnected", "Arcana_AltarUserCleanup", function(ply)
		for _, ent in ipairs(ents.FindByClass("arcana_altar")) do
			if IsValid(ent) then
				ent:PlayerClosedMenu(ply)
			end
		end
	end)
end

if CLIENT then
	-- 3D visuals
	function ENT:Initialize()
		self._circle = nil
		self._band = nil
		self._glowMat = Material("sprites/light_glow02_add")
		self._topGlyphPhrase = "ABRAXAS  DIVINE  WISDOM  LIGHT  LIFE  TRUTH  COSMOS  SOUL  SPIRIT  "
		self._lastThink = CurTime()
		-- Ambient loop state (only for the altar spawned by core.lua)
		self._ambient = nil
		self._ambientTargetVol = 0
		self:PrepareGlyphParticles()

		-- Create clientside obelisk props
		self:CreateObeliskProps()

		-- Animation state (player-driven open/close)
		self._animState = "closed"  -- "closed", "opening", "open", "closing"
		self._animTransitionStart = 0
		self._closedAngle = 0            -- unified rotation applied to both parts when closed
		self._openStartAngle = 0         -- snapshot of _closedAngle when opening begins
		self._openSpinAngle = 0          -- counter-rotation divergence (bottom +, top -)
		self._spinAngleAtCloseStart = 0  -- snapshot of _openSpinAngle when closing begins
		self._animLastTime = 0
		self._spinRate = 30              -- deg/sec counter-spin while open
		self._closedSpinRate = 8         -- deg/sec slow unified rotation when closed
		self._openTransitionDur = 2      -- seconds to open
		self._closeTransitionDur = 2     -- seconds to close (0.5 align + 0.5 merge each)
		self._wasOpen = nil              -- nil = not yet initialized (snap on first Think)
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
		if not IsValid(self._obeliskTop) or not IsValid(self._obeliskBottom) then
			self:CreateObeliskProps()
			return
		end

		local now = CurTime()
		local dt = now - (self._animLastTime or now)
		self._animLastTime = now

		local basePos = self:GetPos()
		local baseAng = self:GetAngles()
		local upVec = self:GetUp()
		local verticalSeparation = 30
		local spinRate = self._spinRate or 30
		local closedSpinRate = self._closedSpinRate or 8
		local openTransDur = self._openTransitionDur or 2
		local closeTransDur = self._closeTransitionDur or 2
		local state = self._animState or "closed"

		-- Helper: build the two part angles from a base offset and a divergence
		local function applyAngles(baseOffset, divergence, separation)
			local bottomAng = Angle(baseAng.p, baseAng.y, baseAng.r)
			bottomAng:RotateAroundAxis(upVec, baseOffset + divergence)
			self._obeliskBottom:SetPos(basePos - upVec * separation)
			self._obeliskBottom:SetAngles(bottomAng)

			local topAng = Angle(baseAng.p, baseAng.y, baseAng.r)
			topAng:RotateAroundAxis(upVec, baseOffset - divergence)
			self._obeliskTop:SetPos(basePos + upVec * separation)
			self._obeliskTop:SetAngles(topAng)
		end

		if state == "closed" then
			-- Both parts together, rotating slowly as one piece
			self._closedAngle = (self._closedAngle or 0) + closedSpinRate * dt
			applyAngles(self._closedAngle, 0, 0)

		elseif state == "opening" then
			local elapsed = now - (self._animTransitionStart or now)
			local frac = math.Clamp(elapsed / openTransDur, 0, 1)
			-- Ease-out cubic: fast initial separation that slows near the end
			local eased = 1 - math.pow(1 - frac, 3)
			local separation = verticalSeparation * eased

			-- Counter-spin ramps up alongside the separation
			self._openSpinAngle = (self._openSpinAngle or 0) + spinRate * dt * eased
			applyAngles(self._openStartAngle or 0, self._openSpinAngle, separation)

			if frac >= 1 then
				self._animState = "open"
			end

		elseif state == "open" then
			-- Full separation, continuous counter-spin
			self._openSpinAngle = (self._openSpinAngle or 0) + spinRate * dt
			applyAngles(self._openStartAngle or 0, self._openSpinAngle, verticalSeparation)

		elseif state == "closing" then
			local elapsed = now - (self._animTransitionStart or now)
			local halfDur = closeTransDur * 0.5

			if elapsed < halfDur then
				-- Phase 1: parts stay fully separated while counter-spin lerps back to 0 (alignment)
				local pFrac = math.Clamp(elapsed / halfDur, 0, 1)
				local eased = pFrac < 0.5
					and 2 * pFrac * pFrac
					or 1 - math.pow(-2 * pFrac + 2, 2) / 2
				local divergence = (self._spinAngleAtCloseStart or 0) * (1 - eased)
				applyAngles(self._openStartAngle or 0, divergence, verticalSeparation)
			else
				-- Phase 2: angles are now aligned, parts slide back together
				local pFrac = math.Clamp((elapsed - halfDur) / halfDur, 0, 1)
				local eased = pFrac < 0.5
					and 2 * pFrac * pFrac
					or 1 - math.pow(-2 * pFrac + 2, 2) / 2
				local separation = verticalSeparation * (1 - eased)
				applyAngles(self._openStartAngle or 0, 0, separation)

				if pFrac >= 1 then
					-- Resume unified rotation from the angle the parts aligned to
					self._closedAngle = self._openStartAngle or 0
					self._openSpinAngle = 0
					self._animState = "closed"
				end
			end
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

	local BandCircle = Arcana.Circle.BandCircle
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
		self._band:SetReferenceEntity(self)

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
		local state = self._animState or "closed"
		if state == "open" then return true end
		if state == "closed" then return false end
		local elapsed = CurTime() - (self._animTransitionStart or CurTime())
		if state == "opening" then
			local frac = math.Clamp(elapsed / (self._openTransitionDur or 2), 0, 1)
			return frac >= 0.01
		end
		if state == "closing" then
			-- Show only while parts are still separated (phase 1 = first half of close duration)
			-- Hide once the merge phase (phase 2) begins
			local halfDur = (self._closeTransitionDur or 2) * 0.5
			return elapsed < halfDur * 1.1  -- small overlap so the orb fades out naturally
		end
		return false
	end

	function ENT:Think()
		local now = CurTime()
		self._lastThink = now

		local shouldPlayMusic = self:GetNWBool("ArcanaPlayMusic", false)
		if shouldPlayMusic then
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

	-- Drive open/close animation from networked state
	local isOpen = self:GetAltarIsOpen()
	if shouldPlayMusic then isOpen = true end
		if self._wasOpen == nil then
			-- First think: snap to correct state without animating (handles late-joining clients)
			self._wasOpen = isOpen
			if isOpen then
				self._animState = "open"
				self._openStartAngle = 0
				self._openSpinAngle = 0
			else
				self._animState = "closed"
				self._closedAngle = 0
			end
		elseif isOpen ~= self._wasOpen then
			self._wasOpen = isOpen
			if isOpen then
				if self._animState == "closed" or self._animState == "closing" then
					-- Snapshot the current unified angle so opening begins from the right rotation
					self._openStartAngle = self._closedAngle or 0
					self._openSpinAngle = 0
					self._animState = "opening"
					self._animTransitionStart = now
				end
			else
				if self._animState == "open" or self._animState == "opening" then
					-- Snapshot the current counter-spin divergence so phase 1 can unwind it
					self._spinAngleAtCloseStart = self._openSpinAngle or 0
					self._animState = "closing"
					self._animTransitionStart = now
				end
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
		if not Arcana or not IsValid(ply) then return {}, {} end
		local data = Arcana:GetPlayerData(ply)
		if not data then return {}, {} end
		local regularSpells = {}
		local rituals = {}

		for sid, sp in pairs(Arcana.RegisteredSpells or {}) do
			local already = data.unlocked_spells and data.unlocked_spells[sid]
			local levelOk = (data.level or 1) >= (sp.level_required or 1)
			local kpOk = (data.knowledge_points or 0) >= (sp.knowledge_cost or 1)
			local isDivinePact = sp.is_divine_pact == true
			local isRitual = sp.is_ritual == true
			local isCrafted = sp.is_crafted == true

			-- Exclude Divine Pacts and crafted spells (spellcraft has its own
			-- station) from the altar; separate rituals from regular spells
			if not already and levelOk and kpOk and not isDivinePact and not isCrafted then
				local item = {
					id = sid,
					spell = sp
				}

				if isRitual then
					table.insert(rituals, item)
				else
					table.insert(regularSpells, item)
				end
			end
		end

		table.sort(regularSpells, function(a, b)
			if a.spell.level_required == b.spell.level_required then return a.spell.name < b.spell.name end

			return a.spell.level_required < b.spell.level_required
		end)

		table.sort(rituals, function(a, b)
			if a.spell.level_required == b.spell.level_required then return a.spell.name < b.spell.name end

			return a.spell.level_required < b.spell.level_required
		end)

		return regularSpells, rituals
	end

	-- The inverse of BuildEligibleSpellList: what the player has learned and could
	-- give back. Divine pacts refund nothing and crafted spells belong to the
	-- Emissary, so neither appears here.
	local function BuildForgettableSpellList(ply)
		if not Arcana or not IsValid(ply) then return {}, {} end
		local data = Arcana:GetPlayerData(ply)
		if not data then return {}, {} end
		local regularSpells = {}
		local rituals = {}

		for sid in pairs(data.unlocked_spells or {}) do
			local sp = (Arcana.RegisteredSpells or {})[sid]

			if sp and not sp.is_divine_pact and not sp.is_crafted then
				local item = {
					id = sid,
					spell = sp
				}

				if sp.is_ritual then
					table.insert(rituals, item)
				else
					table.insert(regularSpells, item)
				end
			end
		end

		local function byLevel(a, b)
			if a.spell.level_required == b.spell.level_required then return a.spell.name < b.spell.name end

			return a.spell.level_required < b.spell.level_required
		end

		table.sort(regularSpells, byLevel)
		table.sort(rituals, byLevel)

		return regularSpells, rituals
	end

	-- Semi-transparent panel fill so the themed background shows through.
	local LIST_PANEL_BG = Color(18, 20, 16, 150)

	-- Empty-state text: a slow, simple fade-in.
	local REVEAL_COL = Color(255, 255, 255)
	local function drawFadeInLine(text, font, cx, cy, baseCol, t)
		REVEAL_COL.r = baseCol.r
		REVEAL_COL.g = baseCol.g
		REVEAL_COL.b = baseCol.b
		REVEAL_COL.a = 255 * math.Clamp(t / 1.5, 0, 1)
		draw.SimpleText(text, font, cx, cy, REVEAL_COL, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
	end

	-- Themed background: dark consecrated stone, the altar's orb glowing up
	-- from below the frame, a slow ceremonial circle behind the content, and
	-- ember sparks rising like the pillar's glyph particles.
	local function drawAltarBackground(w, h, seed)
		-- Clip everything to the art-deco octagon using the stencil buffer.
		local x, y = 6, 6
		local ww, hh = w - 12, h - 12
		local corner = 14
		local pts = {
			{x = x + corner, y = y},
			{x = x + ww - corner, y = y},
			{x = x + ww, y = y + corner},
			{x = x + ww, y = y + hh - corner},
			{x = x + ww - corner, y = y + hh},
			{x = x + corner, y = y + hh},
			{x = x, y = y + hh - corner},
			{x = x, y = y + corner},
		}

		render.ClearStencil()
		render.SetStencilEnable(true)
		render.SetStencilWriteMask(0xFF)
		render.SetStencilTestMask(0xFF)
		render.SetStencilReferenceValue(1)
		render.SetStencilCompareFunction(STENCIL_NEVER)
		render.SetStencilFailOperation(STENCIL_REPLACE)
		render.SetStencilPassOperation(STENCIL_KEEP)
		render.SetStencilZFailOperation(STENCIL_KEEP)

		draw.NoTexture()
		surface.SetDrawColor(255, 255, 255, 255)
		surface.DrawPoly(pts)

		render.SetStencilCompareFunction(STENCIL_EQUAL)
		render.SetStencilFailOperation(STENCIL_KEEP)
		render.SetStencilPassOperation(STENCIL_REPLACE)

		-- Cold mossy stone base, distinct from the vault's night sky and the
		-- Emissary's warm sanctum.
		surface.SetDrawColor(10, 14, 11, 245)
		surface.DrawRect(x, y, ww, hh)

		local t = CurTime()

		-- Three pattern rings spinning in the bottom-right corner at different
		-- speeds and directions — the altar's own motif, not a full magic circle.
		local base = math.min(ww, hh)
		local dim = Color(226, 200, 132)
		Arcana.Circle.Draw2DPatternRing(2, x + ww * 0.94, y + hh * 0.96, base * 0.36, t * 3, dim, 140)
		Arcana.Circle.Draw2DPatternRing(1, x + ww * 0.76, y + hh * 0.80, base * 0.21, -t * 5, dim, 115)
		Arcana.Circle.Draw2DPatternRing(2, x + ww * 0.62, y + hh * 0.94, base * 0.13, t * 8, dim, 95)

		-- Ember sparks rising from the orb (stable per-seed layout, animated by
		-- time), brightest near the bottom and fading as they climb.
		math.randomseed(seed or 1)
		for i = 1, 48 do
			local sx = x + math.random(14, ww - 14)
			local baseY = math.random(0, hh)
			local speed = math.Rand(8, 22)
			local sway = math.Rand(2, 8)
			local phase = math.Rand(0, math.pi * 2)
			local size = (i % 6 == 0) and 2 or 1
			local sy = y + ((baseY - t * speed) % (hh + 6)) - 3
			local px = sx + math.sin(t * 0.9 + phase) * sway
			local climb = math.Clamp((sy - y) / hh, 0, 1)
			surface.SetDrawColor(255, 226, 150, 45 + 180 * climb)
			surface.DrawRect(px, sy, size, size)
		end

		render.SetStencilEnable(false)
	end

	local function OpenAltarMenu(altar)
		if not Arcana then return end
		local ply = LocalPlayer()
		if not IsValid(ply) then return end

		-- Ritual uses art deco palette - same backgrounds as normal spells
		local ritualColors = {
			bg = ArtDeco.Colors.cardIdle,
			bgHover = ArtDeco.Colors.cardHover,
			frame1 = ArtDeco.Colors.brassInner,
			frame2 = ArtDeco.Colors.gold,
			accent = ArtDeco.Colors.paleGold,
			text = ArtDeco.Colors.textBright,
			textDim = ArtDeco.Colors.textDim,
		}

		-- Learn buttons: brass-tinted fill and a double frame so the action
		-- stands out from the plain gold rows. Two lines, vault-imprint style:
		-- label above, KP cost below.
		local BTN_BG = Color(58, 46, 24, 235)
		local BTN_BG_HOVER = Color(76, 60, 30, 235)
		local BTN_BG_DISABLED = Color(34, 29, 20, 235)
		local BTN_FRAME_DISABLED = Color(120, 105, 80, 255)
		local BTN_INNER_DISABLED = Color(90, 80, 60, 160)
		local function paintLearnButton(pnl, w, h, cost)
			local enabled = pnl:IsEnabled()
			local hovered = enabled and pnl:IsHovered()
			local bg = not enabled and BTN_BG_DISABLED or (hovered and BTN_BG_HOVER or BTN_BG)
			ArtDeco.FillDecoPanel(0, 0, w, h, bg, 8)
			ArtDeco.DrawDecoFrame(0, 0, w, h, enabled and (hovered and ArtDeco.Colors.paleGold or ArtDeco.Colors.gold) or BTN_FRAME_DISABLED, 8)
			ArtDeco.DrawDecoFrame(3, 3, w - 6, h - 6, enabled and ArtDeco.Colors.brassInner or BTN_INNER_DISABLED, 8)
			local col = enabled and ArtDeco.Colors.textBright or ArtDeco.Colors.textDim
			draw.SimpleText("Learn", "Arcana_Ancient", w * 0.5, h * 0.5 - 8, col, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
			draw.SimpleText(cost .. " KP", "Arcana_AncientSmall", w * 0.5, h * 0.5 + 9, enabled and ArtDeco.Colors.paleGold or ArtDeco.Colors.textDim, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		end

		-- Forget buttons echo the unlock button's shape — label above, price below — so
		-- the two tabs read as one station. A spell still inside its grace window is
		-- free, and says so in green rather than quoting a price.
		local BTN_FREE = Color(150, 214, 140, 255)
		local function paintForgetButton(pnl, w, h, coins, shards, isFree)
			local enabled = pnl:IsEnabled()
			local hovered = enabled and pnl:IsHovered()
			local bg = not enabled and BTN_BG_DISABLED or (hovered and BTN_BG_HOVER or BTN_BG)
			ArtDeco.FillDecoPanel(0, 0, w, h, bg, 8)
			ArtDeco.DrawDecoFrame(0, 0, w, h, enabled and (hovered and ArtDeco.Colors.paleGold or ArtDeco.Colors.gold) or BTN_FRAME_DISABLED, 8)
			ArtDeco.DrawDecoFrame(3, 3, w - 6, h - 6, enabled and ArtDeco.Colors.brassInner or BTN_INNER_DISABLED, 8)
			local col = enabled and ArtDeco.Colors.textBright or ArtDeco.Colors.textDim
			draw.SimpleText("Forget", "Arcana_Ancient", w * 0.5, h * 0.5 - 8, col, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
			if isFree then
				draw.SimpleText("Free", "Arcana_AncientSmall", w * 0.5, h * 0.5 + 9, BTN_FREE, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
			else
				ArtDeco.DrawCostLine("Arcana_AncientSmall", w * 0.5, h * 0.5 + 1, {
					{text = string.Comma(coins), icon = ArtDeco.Icons.coin, color = enabled and ArtDeco.Colors.coinGold or ArtDeco.Colors.textDim},
					{text = string.Comma(shards), icon = ArtDeco.Icons.shard, color = enabled and ArtDeco.Colors.shardBlue or ArtDeco.Colors.textDim},
				}, TEXT_ALIGN_CENTER)
			end
		end

		local frame = vgui.Create("DFrame")
		frame:SetSize(math.min(900, ScrW() - 60), math.min(620, ScrH() - 60))
		frame:Center()
		frame:SetTitle("")
		frame:MakePopup()
		-- Track tooltip panels for cleanup on close/remove
		frame._arcanaTooltips = {}
		local bgSeed = math.random(1, 10 ^ 9)

		-- Draggable by the whole header band (the stock strip is too thin).
		-- The cursor signals the band on hover and the drag while it lasts.
		frame:SetDraggable(false)
		frame.OnMousePressed = function(pnl, code)
			if code ~= MOUSE_LEFT then return end
			local mx, my = pnl:ScreenToLocal(gui.MouseX(), gui.MouseY())
			if my <= 44 then
				pnl._dragOffset = {mx, my}
				pnl:MouseCapture(true)
				pnl:SetCursor("sizeall")
			end
		end
		frame.OnMouseReleased = function(pnl)
			pnl._dragOffset = nil
			pnl:MouseCapture(false)
			local _, my = pnl:ScreenToLocal(gui.MouseX(), gui.MouseY())
			pnl:SetCursor(my <= 44 and "sizeall" or "arrow")
		end
		frame.OnCursorMoved = function(pnl)
			if pnl._dragOffset then
				local mx, my = gui.MousePos()
				pnl:SetPos(
					math.Clamp(mx - pnl._dragOffset[1], 0, ScrW() - pnl:GetWide()),
					math.Clamp(my - pnl._dragOffset[2], 0, ScrH() - pnl:GetTall()))

				return
			end

			local _, my = pnl:ScreenToLocal(gui.MouseX(), gui.MouseY())
			pnl:SetCursor(my <= 44 and "sizeall" or "arrow")
		end

		hook.Add("HUDPaint", frame, function()
			local x, y = frame:LocalToScreen(0, 0)
			ArtDeco.DrawBlurRect(x + 6, y + 6, frame:GetWide() - 12, frame:GetTall() - 12, 4, 8)
		end)

		-- Declared here so the title chips can measure the band down to its frame.
		local content

		frame.Paint = function(pnl, w, h)
			drawAltarBackground(w, h, bgSeed)
			ArtDeco.DrawDecoFrame(6, 6, w - 12, h - 12, ArtDeco.Colors.gold, 14)

			-- Title and chips share the band between the frame's top line and the spell
			-- list's frame below, so they center on one line with even gaps.
			local bandTop = 6 + 1
			local bandBottom = IsValid(content) and (content:GetY() + 4) or (bandTop + 38)
			local titleRight = ArtDeco.DrawTitle("Arcana_DecoTitle", "ALTAR", bandTop, bandBottom, ArtDeco.Colors.paleGold)

			-- Level and Knowledge Points chips (XP progression hidden by request)
			local data = Arcana:GetPlayerData(ply)

			if data then
				local gap = 14
				local nextX = ArtDeco.DrawChip("Arcana_Ancient", "LVL " .. tostring(data.level or 1), titleRight + gap, bandTop, bandBottom)
				ArtDeco.DrawChip("Arcana_Ancient", "KP " .. tostring(data.knowledge_points or 0), nextX + 10, bandTop, bandBottom)
			end
		end

		if IsValid(frame.btnMinim) then
			frame.btnMinim:Hide()
		end

		if IsValid(frame.btnMaxim) then
			frame.btnMaxim:Hide()
		end

		ArtDeco.StyleCloseButton(frame)

		-- Ensure tooltips are cleaned on close/remove
		frame.OnClose = function()
			if frame._arcanaTooltips then
				for pnl, _ in pairs(frame._arcanaTooltips) do
					if IsValid(pnl) then pnl:Remove() end
					hook.Remove("Think", "ArcanaTooltipPos_" .. tostring(pnl))
				end
				frame._arcanaTooltips = {}
			end

			if IsValid(altar) then
				net.Start("Arcana_CloseAltarMenu")
				net.WriteEntity(altar)
				net.SendToServer()
			end
		end

		frame.OnRemove = frame.OnClose

		content = vgui.Create("DPanel", frame)
		content:Dock(FILL)
		content:DockMargin(12, 12, 12, 12)
		content.Paint = nil

		-- Forgetting is the inverse of learning, so it lives at the same station rather
		-- than in a UI of its own. Declared ahead of the tab buttons that call it.
		local rebuild
		local activeTab = "learn"

		-- Tabs are lettering on a rail, not panels. A filled deco box would read as a third
		-- button alongside Unlock/Forget, and a filled octagon as a third chip alongside
		-- LVL/KP; the selected section is instead marked by the bar it stands on.
		local TAB_FONT = "Arcana_Ancient"
		local TAB_RAIL = Color(198, 160, 74, 55)
		local TAB_RAIL_HOVER = Color(222, 198, 120, 120)

		-- The title band overhangs 4px into content and the list frame is inset 4px, so the
		-- margins are offset by 8 to leave an equal band of air above and below the strip.
		local tabStrip = vgui.Create("DPanel", content)
		tabStrip:Dock(TOP)
		tabStrip:SetTall(30)
		tabStrip:DockMargin(4, 14, 4, 6)

		tabStrip.Paint = function(pnl, w, h)
			surface.SetDrawColor(TAB_RAIL)
			surface.DrawRect(0, h - 1, w, 1)
		end

		-- Caps the ends of the active tab's bar, echoing the deco flourishes elsewhere.
		local function drawTabDiamond(cx, cy, r, col)
			draw.NoTexture()
			surface.SetDrawColor(col)
			surface.DrawPoly({
				{x = cx, y = cy - r},
				{x = cx + r, y = cy},
				{x = cx, y = cy + r},
				{x = cx - r, y = cy},
			})
		end

		local function addTab(id, label)
			surface.SetFont(TAB_FONT)
			local labelW = surface.GetTextSize(label)

			local tab = vgui.Create("DButton", tabStrip)
			tab:Dock(LEFT)
			tab:SetWide(labelW + 34)
			tab:DockMargin(0, 0, 18, 0)
			tab:SetText("")
			tab:SetCursor("hand")

			tab.Paint = function(pnl, w, h)
				local active = activeTab == id
				local hovered = pnl:IsHovered()
				local col = active and ArtDeco.Colors.paleGold or (hovered and ArtDeco.Colors.textBright or ArtDeco.Colors.textDim)
				-- Centered in the space above the bar, not in the panel, so the two tabs
				-- sit on one line regardless of which is selected.
				draw.SimpleText(label, TAB_FONT, w * 0.5, (h - 4) * 0.5, col, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)

				if active then
					local barY = h - 3
					surface.SetDrawColor(ArtDeco.Colors.gold)
					surface.DrawRect(8, barY, w - 16, 3)
					drawTabDiamond(8, barY + 1, 4, ArtDeco.Colors.paleGold)
					drawTabDiamond(w - 8, barY + 1, 4, ArtDeco.Colors.paleGold)
				elseif hovered then
					surface.SetDrawColor(TAB_RAIL_HOVER)
					surface.DrawRect(8, h - 2, w - 16, 1)
				end
			end

			tab.DoClick = function()
				if activeTab == id then return end
				activeTab = id
				surface.PlaySound("buttons/button14.wav")
				rebuild()
			end
		end

		addTab("learn", "LEARN")
		addTab("forget", "FORGET")

		local listPanel = vgui.Create("DPanel", content)
		listPanel:Dock(FILL)

		-- Semi-transparent fill so the themed background shows through.
		listPanel.Paint = function(pnl, w, h)
			ArtDeco.FillDecoPanel(4, 4, w - 8, h - 8, LIST_PANEL_BG, 12)
			ArtDeco.DrawDecoFrame(4, 4, w - 8, h - 8, ArtDeco.Colors.gold, 12)
			local heading = activeTab == "forget" and "Learned Spells" or "Available Spells"
			draw.SimpleText(string.upper(heading), "Arcana_Ancient", 14, 10, ArtDeco.Colors.paleGold)

			if pnl._empty then
				local t = CurTime() - (pnl._emptyStart or CurTime())
				local line = activeTab == "forget" and "You have learned nothing." or "The altar is silent."
				drawFadeInLine(line, "Arcana_AncientLarge", w * 0.5, h * 0.5, ArtDeco.Colors.textBright, t)
			end
		end

		local scroll = vgui.Create("DScrollPanel", listPanel)
		scroll:Dock(FILL)
		scroll:DockMargin(12, 36, 12, 12)
		local vbar = scroll:GetVBar()
		vbar:SetWide(8)

		vbar.Paint = function(pnl, w, h)
			ArtDeco.FillDecoPanel(0, 0, w, h, ArtDeco.Colors.decoPanel, 8)
			ArtDeco.DrawDecoFrame(0, 0, w, h, ArtDeco.Colors.gold, 8)
		end

		vbar.btnGrip:NoClipping(true)
		vbar.btnGrip.Paint = function(pnl, w, h)
			surface.SetDrawColor(ArtDeco.Colors.gold)
			surface.DrawRect(0, 0, w, h)
		end

		local function rebuildLearn()
			local regularSpells, rituals = BuildEligibleSpellList(ply)
			-- Empty state is painted centered by listPanel.Paint; rebuild() owns the
			-- reveal timer for both tabs.
			listPanel._empty = #regularSpells == 0 and #rituals == 0
			if listPanel._empty then return end

			for _, item in ipairs(regularSpells) do
				local sp = item.spell
				local row = vgui.Create("DPanel", scroll)
				row:Dock(TOP)
				row:SetTall(60)
				row:DockMargin(0, 0, 0, 8)
				-- Create info icon for spell description tooltip
				local infoIcon = ArtDeco.CreateInfoIcon(row, sp.description or "No description available", 300)
				infoIcon:SetPos(0, 0) -- Will be positioned in PerformLayout

				local ROW_BG_COLOR = ArtDeco.Colors.cardIdle
				row.Paint = function(pnl, w, h)
					ArtDeco.FillDecoPanel(2, 2, w - 4, h - 4, ROW_BG_COLOR, 8)
					ArtDeco.DrawDecoFrame(2, 2, w - 4, h - 4, ArtDeco.Colors.gold, 8)
					draw.SimpleText(sp.name, "Arcana_AncientLarge", 12, 8, ArtDeco.Colors.textBright)
					draw.SimpleText("LVL. " .. (sp.level_required or 1), "Arcana_AncientSmall", 12, 34, ArtDeco.Colors.textDim)
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
				btn:DockMargin(12, 10, 12, 10)
				btn:SetSize(150, 40)
				btn:SetText("")

				-- Determine affordability live from current data
				local function updateEnabled()
					local d = Arcana:GetPlayerData(ply)
					local curKP = (d and d.knowledge_points) or 0
					local cost = sp.knowledge_cost or 1
					btn:SetEnabled(curKP >= cost)
				end

				updateEnabled()

				btn.Paint = function(pnl, w, h)
					paintLearnButton(pnl, w, h, sp.knowledge_cost or 1)
				end

				function btn:DoClick()
					local d = Arcana:GetPlayerData(ply)
					local curKP = (d and d.knowledge_points) or 0
					local cost = sp.knowledge_cost or 1

					if curKP < cost then
						surface.PlaySound("buttons/button8.wav")
						notification.AddLegacy("Not enough Knowledge Points", NOTIFY_ERROR, 3)
						rebuild()

						return
					end

					net.Start("Arcana_UnlockSpell")
					net.WriteString(item.id)
					net.SendToServer()
					surface.PlaySound("buttons/button14.wav")
					self:SetEnabled(false)
					timer.Simple(0.25, rebuild)
				end
			end

			-- Render rituals section
			if #rituals > 0 then
				-- Spacer before rituals
				local spacer = vgui.Create("DPanel", scroll)
				spacer:Dock(TOP)
				spacer:SetTall(10)
				spacer:DockMargin(0, 0, 0, 0)
				spacer.Paint = function() end

				-- Category header
				local ritualHeader = vgui.Create("DPanel", scroll)
				ritualHeader:Dock(TOP)
				ritualHeader:SetTall(19)
				ritualHeader:DockMargin(0, 0, 0, 4)

				ritualHeader.Paint = function(pnl, w, h)
					draw.SimpleText(string.upper("Rituals"), "Arcana_Ancient", 2, 0, ArtDeco.Colors.paleGold)
				end

				for _, item in ipairs(rituals) do
					local sp = item.spell
					local row = vgui.Create("DPanel", scroll)
					row:Dock(TOP)
					row:SetTall(68)
					row:DockMargin(0, 0, 0, 8)
					-- Create info icon for spell description tooltip
					local infoIcon = ArtDeco.CreateInfoIcon(row, sp.description or "No description available", 300)
					infoIcon:SetPos(0, 0) -- Will be positioned in PerformLayout

					row.Paint = function(pnl, w, h)
						-- Use consolidated ritual frame drawing
						local frameColors = {
							bg = ritualColors.bg,
							frame1 = ritualColors.frame1,
							frame2 = ritualColors.frame2
						}
						ArtDeco.DrawRitualFrame(2, 2, w - 4, h - 4, frameColors)

						-- Strip "Ritual: " prefix from name since it's already in the Rituals category
						local displayName = string.gsub(sp.name, "^Ritual:%s*", "")
						draw.SimpleText(displayName, "Arcana_AncientLarge", 14, 10, ritualColors.text)
						draw.SimpleText("LVL. " .. (sp.level_required or 1), "Arcana_AncientSmall", 14, 38, ritualColors.textDim)
					end

					-- Position the info icon next to the spell name
					row.PerformLayout = function(pnl, w, h)
						if IsValid(infoIcon) then
							-- Get the width of the spell name to position icon after it
							surface.SetFont("Arcana_AncientLarge")
							local displayName = string.gsub(sp.name, "^Ritual:%s*", "")
							local nameW, nameH = surface.GetTextSize(displayName)
							infoIcon:SetPos(18 + nameW, 10 + (nameH - 20) / 2)
						end
					end

					local btn = vgui.Create("DButton", row)
					btn:Dock(RIGHT)
					btn:DockMargin(12, 14, 12, 14)
					btn:SetSize(150, 40)
					btn:SetText("")

					-- Determine affordability live from current data
					local function updateEnabled()
						local d = Arcana:GetPlayerData(ply)
						local curKP = (d and d.knowledge_points) or 0
						local cost = sp.knowledge_cost or 1
						btn:SetEnabled(curKP >= cost)
					end

					updateEnabled()

					btn.Paint = function(pnl, w, h)
						paintLearnButton(pnl, w, h, sp.knowledge_cost or 1)
					end

					function btn:DoClick()
						local d = Arcana:GetPlayerData(ply)
						local curKP = (d and d.knowledge_points) or 0
						local cost = sp.knowledge_cost or 1

						if curKP < cost then
							surface.PlaySound("buttons/button8.wav")
							notification.AddLegacy("Not enough Knowledge Points", NOTIFY_ERROR, 3)
							rebuild()

							return
						end

						net.Start("Arcana_UnlockSpell")
						net.WriteString(item.id)
						net.SendToServer()
						surface.PlaySound("buttons/button14.wav")
						self:SetEnabled(false)
						timer.Simple(0.25, rebuild)
					end
				end
			end
		end

		local function rebuildForget()
			local regularSpells, rituals = BuildForgettableSpellList(ply)
			listPanel._empty = #regularSpells == 0 and #rituals == 0
			if listPanel._empty then return end

			local function addForgetRow(item, isRitual)
				local sp = item.spell
				local refund = sp.knowledge_cost or 1
				local displayName = isRitual and string.gsub(sp.name, "^Ritual:%s*", "") or sp.name
				local row = vgui.Create("DPanel", scroll)
				row:Dock(TOP)
				row:SetTall(isRitual and 68 or 60)
				row:DockMargin(0, 0, 0, 8)
				local infoIcon = ArtDeco.CreateInfoIcon(row, sp.description or "No description available", 300)
				infoIcon:SetPos(0, 0)

				local pad = isRitual and 14 or 12
				local nameY = isRitual and 10 or 8

				row.Paint = function(pnl, w, h)
					if isRitual then
						ArtDeco.DrawRitualFrame(2, 2, w - 4, h - 4, {
							bg = ritualColors.bg,
							frame1 = ritualColors.frame1,
							frame2 = ritualColors.frame2
						})
					else
						ArtDeco.FillDecoPanel(2, 2, w - 4, h - 4, ArtDeco.Colors.cardIdle, 8)
						ArtDeco.DrawDecoFrame(2, 2, w - 4, h - 4, ArtDeco.Colors.gold, 8)
					end

					draw.SimpleText(displayName, "Arcana_AncientLarge", pad, nameY, ArtDeco.Colors.textBright)
					draw.SimpleText(refund .. " KP", "Arcana_AncientSmall", pad, nameY + 26, ArtDeco.Colors.textDim)
				end

				row.PerformLayout = function()
					if IsValid(infoIcon) then
						surface.SetFont("Arcana_AncientLarge")
						local nameW, nameH = surface.GetTextSize(displayName)
						infoIcon:SetPos(pad + 4 + nameW, nameY + (nameH - 20) / 2)
					end
				end

				local btn = vgui.Create("DButton", row)
				btn:Dock(RIGHT)
				btn:DockMargin(12, isRitual and 14 or 10, 12, isRitual and 14 or 10)
				btn:SetSize(190, 40)
				btn:SetText("")

				-- The grace window expires on a clock and coins move underneath us, so the
				-- price and the enabled state are re-read rather than cached at build time.
				-- Polled a few times a second instead of every frame: CanForgetSpell runs a
				-- third-party hook, which has no business firing at framerate.
				local coins, shards, isFree = 0, 0, false
				local nextPoll = 0

				-- The price is read from the price functions, not from the gate: a disabled
				-- button still has to quote what the spell costs, and CanForgetSpell refuses
				-- (broke, casting, a third-party hook) before it can vouch for anything.
				local function refreshPrice()
					local ok = Arcana:CanForgetSpell(ply, item.id)
					isFree = Arcana:IsForgetFree(ply, item.id)
					coins, shards = Arcana:GetForgetCost(item.id)
					btn:SetEnabled(ok == true)
				end

				refreshPrice()

				btn.Think = function()
					if CurTime() < nextPoll then return end
					nextPoll = CurTime() + 0.25
					refreshPrice()
				end

				btn.Paint = function(pnl, w, h)
					paintForgetButton(pnl, w, h, coins, shards, isFree)
				end

				function btn:DoClick()
					local ok, reason = Arcana:CanForgetSpell(ply, item.id)

					if not ok then
						surface.PlaySound("buttons/button8.wav")
						notification.AddLegacy(tostring(reason), NOTIFY_ERROR, 3)

						return
					end

					net.Start("Arcana_ForgetSpell")
					net.WriteString(item.id)
					net.SendToServer()
					surface.PlaySound("buttons/button14.wav")
					self:SetEnabled(false)
					timer.Simple(0.25, rebuild)
				end
			end

			for _, item in ipairs(regularSpells) do
				addForgetRow(item, false)
			end

			if #rituals > 0 then
				local spacer = vgui.Create("DPanel", scroll)
				spacer:Dock(TOP)
				spacer:SetTall(10)
				spacer.Paint = function() end

				local ritualHeader = vgui.Create("DPanel", scroll)
				ritualHeader:Dock(TOP)
				ritualHeader:SetTall(19)
				ritualHeader:DockMargin(0, 0, 0, 4)

				ritualHeader.Paint = function(pnl, w, h)
					draw.SimpleText(string.upper("Rituals"), "Arcana_Ancient", 2, 0, ArtDeco.Colors.paleGold)
				end

				for _, item in ipairs(rituals) do
					addForgetRow(item, true)
				end
			end
		end

		rebuild = function()
			-- Both tabs re-enter here on a 0.25s timer after acting, by which point the
			-- player may have closed the altar.
			if not IsValid(scroll) or not IsValid(listPanel) then return end
			scroll:Clear()
			-- The empty-state rune reveal restarts whenever the list becomes empty.
			local wasEmpty = listPanel._empty

			if activeTab == "forget" then
				rebuildForget()
			else
				rebuildLearn()
			end

			if listPanel._empty and not wasEmpty then
				listPanel._emptyStart = CurTime()
			end
		end

		rebuild()
		-- Live-rebuild when KP changes while the menu is open
		local lastKP = (Arcana:GetPlayerData(ply) and Arcana:GetPlayerData(ply).knowledge_points) or 0

		function frame:Think()
			local d = Arcana:GetPlayerData(ply)
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

		self:DrawGlyphParticles()
	end

	-- Lightweight glyph particles rising like sparks around the pillar top
	function ENT:DrawGlyphParticles()
		if not self._glyphParticles then return end

		local t = CurTime()
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