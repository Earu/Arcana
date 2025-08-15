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

		self._nextUse = 0
	end

	function ENT:SpawnFunction(ply, tr, classname)
		if not tr or not tr.Hit then return end
		local pos = tr.HitPos + tr.HitNormal * 4
		local ent = ents.Create(classname or "arcana_altar")
		if not IsValid(ent) then return end
		ent:SetPos(pos)
		local ang = Angle(0, ply:EyeAngles().y, 0)
		ent:SetAngles(ang)
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
	-- Fonts and styling (reused from grimoire/hud)
	surface.CreateFont("Arcana_AncientSmall", {
		font = "Georgia",
		size = 16,
		weight = 600,
		antialias = true,
		extended = true
	})

	surface.CreateFont("Arcana_Ancient", {
		font = "Georgia",
		size = 20,
		weight = 700,
		antialias = true,
		extended = true
	})

	surface.CreateFont("Arcana_AncientLarge", {
		font = "Georgia",
		size = 24,
		weight = 800,
		antialias = true,
		extended = true
	})

	surface.CreateFont("Arcana_DecoTitle", {
		font = "Georgia",
		size = 26,
		weight = 900,
		antialias = true,
		extended = true
	})

	local decoBg = Color(26, 20, 14, 235)
	local decoPanel = Color(32, 24, 18, 235)
	local gold = Color(198, 160, 74, 255)
	local paleGold = Color(222, 198, 120, 255)
	local textBright = Color(236, 230, 220, 255)
	local textDim = Color(180, 170, 150, 255)
	local chipTextCol = Color(24, 26, 36, 230)
	-- Removed XP fill color (XP bar hidden in altar UI)
	-- local backDim = Color(0, 0, 0, 140)
	local blurMat = Material("pp/blurscreen")

	local function Arcana_DrawBlurRect(x, y, w, h, layers, density)
		surface.SetMaterial(blurMat)
		surface.SetDrawColor(255, 255, 255)
		render.SetScissorRect(x, y, x + w, y + h, true)

		for i = 1, layers do
			blurMat:SetFloat("$blur", (i / layers) * density)
			blurMat:Recompute()
			render.UpdateScreenEffectTexture()
			surface.DrawTexturedRect(0, 0, ScrW(), ScrH())
		end

		render.SetScissorRect(0, 0, 0, 0, false)
	end

	local function Arcana_DrawDecoFrame(x, y, w, h, col, corner)
		local c = math.max(8, corner or 12)
		surface.SetDrawColor(col.r, col.g, col.b, col.a or 255)
		surface.DrawLine(x + c, y, x + w - c, y)
		surface.DrawLine(x + w, y + c, x + w, y + h - c)
		surface.DrawLine(x + w - c, y + h, x + c, y + h)
		surface.DrawLine(x, y + h - c, x, y + c)
		surface.DrawLine(x, y + c, x + c, y)
		surface.DrawLine(x + w - c, y, x + w, y + c)
		surface.DrawLine(x + w, y + h - c, x + w - c, y + h)
		surface.DrawLine(x + c, y + h, x, y + h - c)
	end

	local function Arcana_FillDecoPanel(x, y, w, h, col, corner)
		local c = math.max(8, corner or 12)
		draw.NoTexture()
		surface.SetDrawColor(col.r, col.g, col.b, col.a or 255)

		local pts = {
			{
				x = x + c,
				y = y
			},
			{
				x = x + w - c,
				y = y
			},
			{
				x = x + w,
				y = y + c
			},
			{
				x = x + w,
				y = y + h - c
			},
			{
				x = x + w - c,
				y = y + h
			},
			{
				x = x + c,
				y = y + h
			},
			{
				x = x,
				y = y + h - c
			},
			{
				x = x,
				y = y + c
			},
		}

		surface.DrawPoly(pts)
	end

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
	end

	function ENT:Draw()
		self:DrawModel()
	end

	-- Removed ground magic circle to reduce visual noise
	local function ensureBands(self)
		if not BandCircle or not BandCircle.Create then return end
		if self._band and self._band.IsActive and self._band:IsActive() then return end -- keep following in Think; nothing to do here
		-- Position a bit above the pillar top
		local top = self:GetPos() + self:GetUp() * (self:OBBMaxs().z + 30)
		local ang = self:GetAngles()
		self._band = BandCircle.Create(top, ang, Color(222, 198, 120, 255), math.max(40, self:GetAuraSize() * 0.35))
		if not self._band then return end
		-- Three fast rotating bands on different axes
		local baseR = math.max(24, self:GetAuraSize() * 0.18)

		self._band:AddBand(baseR * 0.90, 6, {
			p = 0,
			y = 120,
			r = 0
		}, 2)

		self._band:AddBand(baseR * 1.10, 6, {
			p = 80,
			y = 0,
			r = 0
		}, 2)

		self._band:AddBand(baseR * 1.35, 6, {
			p = 0,
			y = 0,
			r = 140
		}, 2)
	end

	local function getOrbPos(self)
		return self:GetPos() + self:GetUp() * (self:OBBMaxs().z + 30)
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

		-- Update glyph particles (spawn/update/expire)
		local dt = FrameTime() > 0 and FrameTime() or 0.05
		self._glyphSpawnAccumulator = (self._glyphSpawnAccumulator or 0) + (self._glyphSpawnRate or 120) * dt
		local toSpawn = math.floor(self._glyphSpawnAccumulator)
		self._glyphSpawnAccumulator = self._glyphSpawnAccumulator - toSpawn

		if self._glyphParticles and #self._glyphParticles < (self._glyphMaxParticles or 160) then
			for i = 1, math.min(toSpawn, (self._glyphMaxParticles or 160) - #self._glyphParticles) do
				self:_SpawnGlyphParticle()
			end
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

		hook.Add("HUDPaint", frame, function()
			local x, y = frame:LocalToScreen(0, 0)
			Arcana_DrawBlurRect(x, y, frame:GetWide(), frame:GetTall(), 4, 8)
		end)

		frame.Paint = function(pnl, w, h)
			Arcana_FillDecoPanel(6, 6, w - 12, h - 12, decoBg, 14)
			Arcana_DrawDecoFrame(6, 6, w - 12, h - 12, gold, 14)
			draw.SimpleText("ALTAR", "Arcana_DecoTitle", 18, 10, paleGold)
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
				Arcana_FillDecoPanel(chipX, chipY, lvlChipW, chipH, paleGold, 8)
				draw.SimpleText(lvlText, "Arcana_Ancient", chipX + (lvlChipW - lvlW) * 0.5, chipY + (chipH - lvlH) * 0.5, chipTextCol)
				-- KP chip to the right
				local kpText = "KP " .. tostring(data.knowledge_points or 0)
				local kpW, kpH = surface.GetTextSize(kpText)
				local gap = 10
				local kpChipX = chipX + lvlChipW + gap
				local kpChipW = kpW + 18
				Arcana_FillDecoPanel(kpChipX, chipY, kpChipW, chipH, paleGold, 8)
				draw.SimpleText(kpText, "Arcana_Ancient", kpChipX + (kpChipW - kpW) * 0.5, chipY + (chipH - kpH) * 0.5, chipTextCol)
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
				surface.SetDrawColor(paleGold)
				local pad = 8
				surface.DrawLine(pad, pad, w - pad, h - pad)
				surface.DrawLine(w - pad, pad, pad, h - pad)
			end
		end

		local content = vgui.Create("DPanel", frame)
		content:Dock(FILL)
		content:DockMargin(12, 34, 12, 12)
		content.Paint = nil
		local listPanel = vgui.Create("DPanel", content)
		listPanel:Dock(FILL)

		listPanel.Paint = function(pnl, w, h)
			Arcana_FillDecoPanel(4, 4, w - 8, h - 8, decoPanel, 12)
			Arcana_DrawDecoFrame(4, 4, w - 8, h - 8, gold, 12)
			draw.SimpleText(string.upper("Available Spells"), "Arcana_Ancient", 14, 10, paleGold)
		end

		local scroll = vgui.Create("DScrollPanel", listPanel)
		scroll:Dock(FILL)
		scroll:DockMargin(12, 36, 12, 12)

		local vbar = scroll:GetVBar()
		vbar:SetWide(8)

		vbar.Paint = function(pnl, w, h)
			surface.DisableClipping(true)
			Arcana_FillDecoPanel(0, 0, w, h, decoPanel, 8)
			Arcana_DrawDecoFrame(0, 0, w, h, gold, 8)
			surface.DisableClipping(false)
		end

		vbar.btnGrip.Paint = function(pnl, w, h)
			surface.DisableClipping(true)
			surface.SetDrawColor(gold)
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
				lbl:SetTextColor(textDim)

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
					surface.SetDrawColor(paleGold)
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
					draw.SimpleText("i", "Arcana_Ancient", w / 2, h / 2, paleGold, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
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
					tooltip:SetTextColor(textBright)
					tooltip:SetDrawOnTop(true)
					tooltip:SetMouseInputEnabled(false)
					tooltip:SetKeyboardInputEnabled(false)

					tooltip.Paint = function(pnl, w, h)
						surface.DisableClipping(true)
						Arcana_FillDecoPanel(-10, 0, w, h, Color(26, 20, 14, 245), 8)
						Arcana_DrawDecoFrame(-10, 0, w, h, gold, 8)
						surface.DisableClipping(false)
					end

					infoIcon.tooltip = tooltip
					updateTooltipPos(tooltip)

					-- Update position if mouse moves
					local hookName = "ArcanaTooltipPos_" .. tostring(tooltip)
					hook.Add("Think", hookName, function()
						if not IsValid(tooltip) then
							hook.Remove("Think", hookName)
							return
						end
						updateTooltipPos(tooltip)
					end)
				end

				local function destroyTooltip()
					if IsValid(infoIcon.tooltip) then
						hook.Remove("Think", "ArcanaTooltipPos_" .. tostring(infoIcon.tooltip))
						infoIcon.tooltip:Remove()
						infoIcon.tooltip = nil
					end
				end

				infoIcon.OnCursorEntered = createTooltip
				infoIcon.OnCursorExited = destroyTooltip

				row.Paint = function(pnl, w, h)
					Arcana_FillDecoPanel(2, 2, w - 4, h - 4, Color(46, 36, 26, 235), 8)
					Arcana_DrawDecoFrame(2, 2, w - 4, h - 4, gold, 8)
					draw.SimpleText(sp.name, "Arcana_AncientLarge", 12, 8, textBright)
					local sub = string.format("Lvl %d  Cost %d KP", sp.level_required or 1, sp.knowledge_cost or 1)
					draw.SimpleText(sub, "Arcana_AncientSmall", 12, 34, paleGold)
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
					local bgCol = hovered and Color(58, 44, 32, 235) or Color(46, 36, 26, 235)
					surface.DisableClipping(true)
					Arcana_FillDecoPanel(0, 0, w, h, bgCol, 8)
					Arcana_DrawDecoFrame(0, 0, w, h, gold, 8)
					surface.DisableClipping(false)
					local col = enabled and textBright or textDim
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

	function ENT:DrawTranslucent()
		-- glowy core above the pillar
		if not self._glowMat then return end
		local pos = getOrbPos(self)
		local t = CurTime()
		local pulse = 0.5 + 0.5 * math.sin(t * 3.2)
		local size = 48 + 24 * pulse
		render.SetMaterial(self._glowMat)
		render.DrawSprite(pos, size, size, Color(255, 230, 160, 230))
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
		local baseTop = self:GetPos() + Vector(0, 0, 10)
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