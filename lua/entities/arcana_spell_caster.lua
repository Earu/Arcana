AddCSLuaFile()

ENT.Type = "anim"
ENT.Base = "base_gmodentity"

ENT.PrintName = "Spell Caster"
ENT.Author = "Earu"
ENT.Category = "Arcana"
ENT.Spawnable = true
ENT.AdminOnly = false

ENT.RenderGroup = RENDERGROUP_OPAQUE

function ENT:SetupDataTables()
	self:NetworkVar("Bool", 0, "IsCasting")
	self:NetworkVar("String", 0, "CurrentSpell")
	self:NetworkVar("Float", 0, "CastProgress")
	self:NetworkVar("String", 1, "SelectedSpell") -- Menu-selected spell (Wiremod overrides this)
	-- Cooldowns here are the entity's own, not the owner's, so the menu has to
	-- read them from the entity rather than from player data.
	self:NetworkVar("Float", 1, "CooldownEnd")
end

if SERVER then
	util.AddNetworkString("Arcana_SpellCaster_OpenMenu")
	util.AddNetworkString("Arcana_SpellCaster_SetSpell")
	util.AddNetworkString("Arcana_SpellCaster_CastFromMenu")

	resource.AddFile("materials/entities/arcana_spell_caster.png")

	function ENT:Initialize()
		self:SetModel("models/hunter/blocks/cube025x025x025.mdl")
		self:SetMaterial("arcana/pattern")
		self:PhysicsInit(SOLID_VPHYSICS)
		self:SetMoveType(MOVETYPE_VPHYSICS)
		self:SetSolid(SOLID_VPHYSICS)
		self:SetUseType(SIMPLE_USE)

		local phys = self:GetPhysicsObject()
		if IsValid(phys) then
			phys:Wake()
		end

		-- Entity-specific spell cooldowns (independent from owner's cooldowns)
		self.SpellCooldowns = {}
		self.CastingUntil = 0
		self.QueuedSpell = nil
		self:SetSelectedSpell("") -- Default: no spell selected from menu
		self:SetCooldownEnd(0)

		-- Wiremod setup
		if WireLib then
			self.Inputs = WireLib.CreateInputs(self, {
				"Cast [NORMAL]",
				"SpellID [STRING]"
			})

			self.Outputs = WireLib.CreateOutputs(self, {
				"Casting [NORMAL]",
				"CooldownRemaining [NORMAL]",
				"Ready [NORMAL]"
			})

			WireLib.TriggerOutput(self, "Ready", 1)
		end
	end

	function ENT:SpawnFunction(ply, tr, className)
		if not tr.Hit then return end

		local spawnPos = tr.HitPos + tr.HitNormal * 16

		local ent = ents.Create(className)
		if not IsValid(ent) then return end

		ent:SetNWEntity("FallbackOwner", ply)
		ent:SetPos(spawnPos)
		ent:Spawn()
		ent:Activate()

		return ent
	end

	-- Resolve the player this machine answers to.
	function ENT:GetCasterOwner()
		local owner = self.CPPIGetOwner and self:CPPIGetOwner()
		if not IsValid(owner) then owner = self:GetNWEntity("FallbackOwner") end
		if not IsValid(owner) then return nil end

		return owner
	end

	-- A wire pulse can fire many times a second, so the same complaint is only
	-- said once every few seconds instead of flooding the owner's screen.
	local NOTICE_COOLDOWN = 5
	function ENT:NotifyOwner(owner, message)
		if not IsValid(owner) or not owner:IsPlayer() then return end

		local now = CurTime()
		if self._lastNotice == message and now < (self._lastNoticeAt or 0) + NOTICE_COOLDOWN then return end

		self._lastNotice = message
		self._lastNoticeAt = now
		Arcana:SendErrorNotification(owner, "Spell Caster: " .. message)
	end

	function ENT:GetEntityCooldown(spellId)
		local cooldownTime = self.SpellCooldowns[spellId] or 0
		return math.max(0, cooldownTime - CurTime())
	end

	function ENT:IsOnEntityCooldown(spellId)
		return self:GetEntityCooldown(spellId) > 0
	end

	function ENT:CanCastSpellForOwner(owner, spellId)
		if not IsValid(owner) then return false, "No owner set" end

		local spell = Arcana.RegisteredSpells[spellId]
		if not spell then return false, "Spell not found (" .. spellId .. ")" end

		-- Spell casters cannot cast divine pacts or ritual spells
		if spell.is_divine_pact then
			return false, "Cannot cast divine pact spells"
		end

		if spell.is_ritual then
			return false, "Cannot cast ritual spells"
		end

		-- Check if currently casting
		if self.CastingUntil > CurTime() then
			return false, "Already casting"
		end

		-- Check entity-specific cooldown (not owner's cooldown)
		if self:IsOnEntityCooldown(spellId) then
			return false, "Spell on cooldown (" .. spellId .. ")"
		end

		local data = Arcana:GetPlayerData(owner)

		-- Check if owner has spell unlocked
		if not data.unlocked_spells[spellId] then
			return false, "Owner hasn't unlocked this spell (" .. spellId .. ")"
		end

		-- Check if owner can afford the spell (we'll consume resources later)
		if spell.cost_type == Arcana.COST_TYPES.COINS then
			local canPayWithCoins = Arcana:GetCoins(owner) >= spell.cost_amount
			if not canPayWithCoins and owner:Health() < spell.cost_amount then
				return false, "Owner cannot afford " .. string.Comma(spell.cost_amount) .. " coins"
			end
		elseif spell.cost_type == Arcana.COST_TYPES.HEALTH then
			if owner:Health() < spell.cost_amount then
				return false, "Owner has insufficient health"
			end
		end

		-- Custom spell validation
		if spell.can_cast then
			local canCast, reason = spell.can_cast(owner, nil, data)
			if not canCast then return false, reason or "Cannot cast spell" end
		end

		-- Hook validation
		local ok, reason = Arcana.RunHook("CanCastSpell", owner, spellId)
		if ok == false then return false, reason or "Cannot cast spell" end

		return true
	end

	function ENT:StartCastingSpell(spellId)
		local owner = self:GetCasterOwner()
		if not IsValid(owner) then return false end

		local canCast, reason = self:CanCastSpellForOwner(owner, spellId)
		if not canCast then
			self:NotifyOwner(owner, reason or "Cannot cast")

			return false
		end

		local spell = Arcana.RegisteredSpells[spellId]
		local castTime = math.max(0.1, spell.cast_time or 0)

		self.CastingUntil = CurTime() + castTime
		self.QueuedSpell = spellId

		-- Run the BeginCasting hook so systems like target locking start their
		-- scans. The third argument carries the casting entity (same role as
		-- context.casterEntity later in the pipeline) so scans trace from the
		-- entity's facing instead of the owner's crosshair.
		Arcana.RunHook("BeginCasting", owner, spellId, self)

		self:SetIsCasting(true)
		self:SetCurrentSpell(spellId)
		self:SetCastProgress(0)

		if WireLib then
			WireLib.TriggerOutput(self, "Casting", 1)
			WireLib.TriggerOutput(self, "Ready", 0)
		end

		-- Broadcast casting visuals
		local forwardLike = spell.cast_anim == "forward" or spell.is_projectile or spell.has_target or ((spell.range or 0) > 0)

		-- Use entity's position and orientation for casting circle. This must
		-- match computeCastCircleTransform in vfx/casting.lua so the spell leaves
		-- the circle the player is actually looking at.
		local pos = self:WorldSpaceCenter() + self:GetForward() * 30
		local ang = self:GetForward():Angle()
		ang:RotateAroundAxis(ang:Right(), 90)
		local size = 30


		net.Start("Arcana_BeginCasting", true)
		net.WriteEntity(self)
		net.WriteString(spellId)
		net.WriteFloat(castTime)
		net.WriteBool(forwardLike)
		net.Broadcast()

		-- Schedule spell execution
		timer.Simple(castTime + 0.1, function()
			if not IsValid(self) then return end

			self:SetIsCasting(false)
			self:SetCastProgress(1)

			if WireLib then
				WireLib.TriggerOutput(self, "Casting", 0)
			end

			-- Re-validate before casting. This also catches a crafted spell that
			-- was dissolved or reworked during the wind-up, since it resolves the
			-- id against the live registry rather than trusting the captured table.
			local canExecute, failure = self:CanCastSpellForOwner(owner, spellId)
			if not canExecute then
				self:NotifyOwner(owner, failure or "Cannot cast")

				net.Start("Arcana_SpellFailed", true)
				net.WriteEntity(self)
				net.WriteString(spellId)
				net.WriteFloat(castTime)
				net.Broadcast()

				if WireLib then
					WireLib.TriggerOutput(self, "Ready", 1)
				end

				if Arcana.Common and Arcana.Common.ClearTargetLock then
					Arcana.Common.ClearTargetLock(self)
				end

				self.CastingUntil = 0
				self.QueuedSpell = nil
				return
			end

			-- Cast whatever that id means NOW: reworking a crafted spell keeps its
			-- id but replaces the definition, and the captured table would fire
			-- the old build with the old cost.
			self:ExecuteSpell(owner, spellId, Arcana.RegisteredSpells[spellId], castTime, forwardLike, pos, ang, size)
		end)

		return true
	end

	function ENT:ExecuteSpell(owner, spellId, spell, castTime, forwardLike, pos, ang, size)
		if not IsValid(owner) then return end

		-- Nothing left to cast (the spell vanished between validation and here):
		-- release the machine rather than leaving it stuck mid-cast.
		if not spell then
			self.CastingUntil = 0
			self.QueuedSpell = nil

			if WireLib then
				WireLib.TriggerOutput(self, "Ready", 1)
			end

			return
		end

		local data = Arcana:GetPlayerData(owner)
		local takeDamageInfo = owner.ForceTakeDamageInfo or owner.TakeDamageInfo

		-- Apply costs to owner
		if spell.cost_type == Arcana.COST_TYPES.COINS then
			local canPayWithCoins = Arcana:GetCoins(owner) >= spell.cost_amount

			if canPayWithCoins then
				Arcana:TakeCoins(owner, spell.cost_amount, "Spell Caster: " .. spell.name)
			else
				-- Fallback: pay with health
				local dmg = DamageInfo()
				dmg:SetDamage(spell.cost_amount)
				dmg:SetAttacker(owner)
				dmg:SetInflictor(self)
				dmg:SetDamageType(bit.bor(DMG_GENERIC, DMG_DIRECT))
				takeDamageInfo(owner, dmg)
			end
		elseif spell.cost_type == Arcana.COST_TYPES.HEALTH then
			local dmg = DamageInfo()
			dmg:SetDamage(spell.cost_amount)
			dmg:SetAttacker(owner)
			dmg:SetInflictor(self)
			dmg:SetDamageType(bit.bor(DMG_GENERIC, DMG_DIRECT))
			takeDamageInfo(owner, dmg)
		end

		-- Set entity-specific cooldown (not owner's cooldown)
		self.SpellCooldowns[spellId] = CurTime() + spell.cooldown
		self:SetCooldownEnd(self.SpellCooldowns[spellId])

		pos = self:WorldSpaceCenter() + self:GetForward() * 30
		ang = self:GetForward():Angle()
		ang:RotateAroundAxis(ang:Right(), 90)
		size = 30

		-- Cast spell with entity's context
		local context = {
			circlePos = pos,
			circleAng = ang,
			circleSize = size,
			forwardLike = forwardLike,
			castTime = castTime,
			casterEntity = self -- Pass entity reference for spells that need it
		}

		local success = true
		local result = spell.cast(owner, nil, data, context)
		if result == false then
			success = false
		end

		Arcana.RunHook("CastSpell", owner, spellId, nil, data, context, success)

		if success then
			if spell.on_success then
				spell.on_success(owner, nil, data, context)
			end

			-- Fire hook so optional subsystems (e.g. ManaCrystals) can react.
			local reportContext = table.Copy(context or {})
			reportContext.cooldown = spell.cooldown or Arcana.Config.DEFAULT_SPELL_COOLDOWN or 1.0
			Arcana.RunHook("SpellCastSucceeded", owner, spellId, pos, reportContext)
		else
			if spell.on_failure then
				spell.on_failure(owner, nil, data, context)
			end

		Arcana.RunHook("CastSpellFailure", owner, spellId, nil, data, context)

		net.Start("Arcana_SpellFailed", true)
		net.WriteEntity(self)
		net.WriteString(spellId)
		net.WriteFloat(castTime)
		net.Broadcast()
		end

		self.CastingUntil = 0
		self.QueuedSpell = nil

		if WireLib then
			WireLib.TriggerOutput(self, "Ready", 1)
		end
	end

	-- Get the active spell ID (Wiremod overrides menu selection)
	function ENT:GetActiveSpellID()
		-- Check if wiremod input is connected and has a value
		if WireLib and self.Inputs and self.Inputs.SpellID then
			local wireSpellId = self.Inputs.SpellID.Value or ""
			wireSpellId = string.lower(string.Trim(wireSpellId))
			if wireSpellId ~= "" then
				return wireSpellId
			end
		end

		-- Fall back to menu-selected spell
		local menuSpell = self:GetSelectedSpell() or ""
		menuSpell = string.lower(string.Trim(menuSpell))
		return menuSpell
	end

	function ENT:TriggerInput(iname, value)
		if iname == "Cast" and value ~= 0 then
			local spellId = self:GetActiveSpellID()

			if spellId == "" then
				self:NotifyOwner(self:GetCasterOwner(), "No spell ID provided")
				return
			end

			self:StartCastingSpell(spellId)
		end
	end

	function ENT:Think()
		-- Update the current spell display to reflect active spell (wiremod or menu)
		local activeSpell = self:GetActiveSpellID()
		if self:GetCurrentSpell() ~= activeSpell and not self:GetIsCasting() then
			self:SetCurrentSpell(activeSpell)
		end

		-- Publish the active spell's cooldown so the menu can show the entity's
		-- own timer instead of the owner's.
		self:SetCooldownEnd(activeSpell ~= "" and (self.SpellCooldowns[activeSpell] or 0) or 0)

		-- Update wire outputs
		if WireLib then
			local spellId = activeSpell

			if spellId ~= "" then
				local cooldown = self:GetEntityCooldown(spellId)
				WireLib.TriggerOutput(self, "CooldownRemaining", cooldown)
			end

			-- Update cast progress
			if self:GetIsCasting() and self.CastingUntil > CurTime() then
				local spell = Arcana.RegisteredSpells[self.QueuedSpell]
				if spell then
					local castTime = math.max(0.1, spell.cast_time or 0)
					local elapsed = castTime - (self.CastingUntil - CurTime())
					local progress = math.Clamp(elapsed / castTime, 0, 1)
					self:SetCastProgress(progress)
				end
			end
		end

		self:NextThink(CurTime() + 0.1)
		return true
	end

	function ENT:OnRemove()
		-- Cleanup
	end

	function ENT:Use(activator)
		if not IsValid(activator) or not activator:IsPlayer() then return end
		if self:GetCasterOwner() ~= activator then return end

		-- Open spell selection menu
		net.Start("Arcana_SpellCaster_OpenMenu")
		net.WriteEntity(self)
		net.Send(activator)
		self:EmitSound("buttons/button9.wav", 60, 110)
	end

	-- Network receivers
	net.Receive("Arcana_SpellCaster_SetSpell", function(_, ply)
		local ent = net.ReadEntity()
		local spellId = net.ReadString()

		if not IsValid(ent) or ent:GetClass() ~= "arcana_spell_caster" then return end
		if ent:GetCasterOwner() ~= ply then return end

		spellId = string.lower(string.Trim(spellId))
		ent:SetSelectedSpell(spellId)
	end)

	net.Receive("Arcana_SpellCaster_CastFromMenu", function(_, ply)
		local ent = net.ReadEntity()

		if not IsValid(ent) or ent:GetClass() ~= "arcana_spell_caster" then return end
		if ent:GetCasterOwner() ~= ply then return end

		local spellId = ent:GetActiveSpellID()
		if spellId ~= "" then
			ent:StartCastingSpell(spellId)
		end
	end)
end

if CLIENT then
	-- Spell Caster Menu
	local function OpenSpellCasterMenu(caster)
		if not Arcana then return end
		local ply = LocalPlayer()
		if not IsValid(ply) or not IsValid(caster) then return end

		local owner = caster.CPPIGetOwner and caster:CPPIGetOwner()
		if not IsValid(owner) then owner = caster:GetNWEntity("FallbackOwner") end
		if not IsValid(owner) then return end
		if owner ~= ply then
			Arcana:Print("❌ You don't own this Spell Caster")
			return
		end

		local frame = vgui.Create("DFrame")
		frame:SetSize(760, 520)
		frame:Center()
		frame:SetTitle("")
		frame:MakePopup()

		hook.Add("HUDPaint", frame, function()
			local x, y = frame:LocalToScreen(0, 0)
			ArtDeco.DrawBlurRect(x + 6, y + 6, frame:GetWide() - 12, frame:GetTall() - 12, 4, 8)
		end)

		-- Declared here so the title can measure the band down to the info panel's frame.
		local content

		frame.Paint = function(pnl, w, h)
			ArtDeco.FillDecoPanel(6, 6, w - 12, h - 12, ArtDeco.Colors.decoBg, 14)
			ArtDeco.DrawDecoFrame(6, 6, w - 12, h - 12, ArtDeco.Colors.gold, 14)

			-- The title centers in the band between the frame's top line and the
			-- wiremod info panel's frame below it.
			local bandTop = 6 + 1
			local bandBottom = IsValid(content) and (content:GetY() + 4) or (bandTop + 38)
			ArtDeco.DrawTitle("Arcana_DecoTitle", "SPELL CASTER", bandTop, bandBottom, ArtDeco.Colors.paleGold)
		end

		if IsValid(frame.btnMinim) then frame.btnMinim:Hide() end
		if IsValid(frame.btnMaxim) then frame.btnMaxim:Hide() end

		ArtDeco.StyleCloseButton(frame)

		content = vgui.Create("DPanel", frame)
		content:Dock(FILL)
		content:DockMargin(12, 8, 12, 12)
		content.Paint = nil

		-- Info panel about Wiremod
		local infoPanel = vgui.Create("DPanel", content)
		infoPanel:Dock(TOP)
		infoPanel:SetTall(50)
		infoPanel:DockMargin(0, 0, 0, 5)

		infoPanel.Paint = function(pnl, w, h)
			ArtDeco.FillDecoPanel(4, 4, w - 8, h - 8, Color(36, 44, 54, 235), 8)
			ArtDeco.DrawDecoFrame(4, 4, w - 8, h - 8, Color(120, 180, 220, 255), 8)

			-- Icon
			draw.SimpleText("⚡", "Arcana_DecoTitle", 18, h * 0.5 - 2, Color(120, 180, 220, 255), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)

			-- Info text
			draw.SimpleText("This entity works better with wiremod!", "Arcana_Ancient", 48, h * 0.5 - 8, ArtDeco.Colors.textBright, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
			draw.SimpleText("Use Wiremod inputs/outputs for advanced control (overrides menu selection)", "Arcana_AncientSmall", 48, h * 0.5 + 8, ArtDeco.Colors.textDim, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		end

		local listPanel = vgui.Create("DPanel", content)
		listPanel:Dock(FILL)

		listPanel.Paint = function(pnl, w, h)
			ArtDeco.FillDecoPanel(4, 4, w - 8, h - 8, ArtDeco.Colors.decoPanel, 12)
			ArtDeco.DrawDecoFrame(4, 4, w - 8, h - 8, ArtDeco.Colors.gold, 12)
			draw.SimpleText(string.upper("Select Spell"), "Arcana_Ancient", 14, 10, ArtDeco.Colors.paleGold)

			-- Show current selected spell
			local currentSpell = caster:GetSelectedSpell() or ""
			if currentSpell ~= "" then
				local spell = Arcana.RegisteredSpells[currentSpell]
				if spell then
					draw.SimpleText("Current: " .. spell.name, "Arcana_AncientSmall", w - 14, 10, ArtDeco.Colors.textDim, TEXT_ALIGN_RIGHT)
				end
			end
		end

		-- Cast button at bottom
		local castBtn = vgui.Create("DButton", listPanel)
		castBtn:Dock(BOTTOM)
		castBtn:SetTall(50)
		castBtn:DockMargin(12, 8, 12, 12)
		castBtn:SetText("")

		castBtn.Paint = function(pnl, w, h)
			local enabled = pnl:IsEnabled()
			local hovered = enabled and pnl:IsHovered()
			local bg = hovered and ArtDeco.Colors.cardHover or ArtDeco.Colors.cardIdle
			local frameCol = enabled and ArtDeco.Colors.gold or ArtDeco.Colors.textDim
			ArtDeco.FillDecoPanel(0, 0, w, h, bg, 8)
			ArtDeco.DrawDecoFrame(0, 0, w, h, frameCol, 8)

			local label = "Cast Spell"
			local col = enabled and ArtDeco.Colors.textBright or ArtDeco.Colors.textDim

			-- This machine keeps its own cooldowns, separate from the player's.
			local cooldownEnd = caster:GetCooldownEnd() or 0
			if caster:GetIsCasting() then
				label = "Casting"
				col = ArtDeco.Colors.textDim
			elseif cooldownEnd > CurTime() then
				label = tostring(math.max(0, math.ceil(cooldownEnd - CurTime()))) .. "s"
				col = ArtDeco.Colors.textDim
			end

			draw.SimpleText(label, "Arcana_AncientLarge", w * 0.5, h * 0.5, col, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		end

		castBtn.DoClick = function()
			if not castBtn:IsEnabled() then return end

			net.Start("Arcana_SpellCaster_CastFromMenu")
			net.WriteEntity(caster)
			net.SendToServer()
			surface.PlaySound("buttons/button14.wav")
		end

		-- Update cast button state
		castBtn.Think = function(pnl)
			if not IsValid(caster) then
				pnl:SetEnabled(false)
				return
			end

			local spellId = caster:GetSelectedSpell() or ""
			local ready = not caster:GetIsCasting() and (caster:GetCooldownEnd() or 0) <= CurTime()
			pnl:SetEnabled(spellId ~= "" and ready)
		end

		local scroll = vgui.Create("DScrollPanel", listPanel)
		scroll:Dock(FILL)
		scroll:DockMargin(12, 36, 12, 12)

		ArtDeco.StyleScrollBar(scroll)

		local function rebuild()
			scroll:Clear()
			local data = Arcana:GetPlayerData(ply)
			if not data then return end

			local unlocked = {}
			for sid, sp in pairs(Arcana.RegisteredSpells) do
				-- Filter out divine pacts and ritual spells
				if data.unlocked_spells[sid] and not sp.is_divine_pact and not sp.is_ritual then
					table.insert(unlocked, {id = sid, spell = sp})
				end
			end

			table.sort(unlocked, function(a, b) return a.spell.name < b.spell.name end)

			if #unlocked == 0 then
				local lbl = vgui.Create("DLabel", scroll)
				lbl:SetText("No spells unlocked")
				lbl:SetFont("Arcana_AncientLarge")
				lbl:Dock(TOP)
				lbl:DockMargin(0, 6, 0, 0)
				lbl:SetTextColor(ArtDeco.Colors.textDim)
				return
			end

			for _, item in ipairs(unlocked) do
				local sp = item.spell
				local row = vgui.Create("DButton", scroll)
				row:Dock(TOP)
				row:SetTall(56)
				row:DockMargin(0, 0, 0, 6)
				row:SetText("")
				row.SpellId = item.id

				row.Paint = function(pnl, w, h)
					local hovered = pnl:IsHovered()
					local selected = (caster:GetSelectedSpell() == item.id)
					local bg = selected and Color(58, 44, 32, 235) or (hovered and ArtDeco.Colors.cardHover or ArtDeco.Colors.cardIdle)
					local frameCol = selected and Color(255, 255, 255, 255) or ArtDeco.Colors.gold

					ArtDeco.FillDecoPanel(2, 2, w - 4, h - 4, bg, 8)
					ArtDeco.DrawDecoFrame(2, 2, w - 4, h - 4, frameCol, 8)
					draw.SimpleText(sp.name, "Arcana_AncientLarge", 12, 8, ArtDeco.Colors.textBright)

					-- Cost info
					local ca = tonumber(sp.cost_amount) or 0
					local ct = tostring(sp.cost_type or "")
					if ct == Arcana.COST_TYPES.COINS then
						ArtDeco.DrawCostLine("Arcana_AncientSmall", 12, 32, {
							{text = string.Comma(ca), icon = ArtDeco.Icons.coin, color = ArtDeco.Colors.textDim},
						})
					else
						draw.SimpleText(string.Comma(ca) .. " " .. ct, "Arcana_AncientSmall", 12, 32, ArtDeco.Colors.textDim)
					end
				end

				row.DoClick = function()
					-- Set this spell as selected
					net.Start("Arcana_SpellCaster_SetSpell")
					net.WriteEntity(caster)
					net.WriteString(item.id)
					net.SendToServer()

					-- Update local immediately for UI feedback
					caster:SetSelectedSpell(item.id)
					surface.PlaySound("buttons/button15.wav")
				end
			end
		end

		rebuild()

		frame.Think = function()
			if not IsValid(caster) then
				frame:Close()
			end
		end
	end

	net.Receive("Arcana_SpellCaster_OpenMenu", function()
		local ent = net.ReadEntity()
		if IsValid(ent) then
			OpenSpellCasterMenu(ent)
		end
	end)

	local LINE_COLOR = Color(0, 255, 0, 255)
	local TEXT_OUTLINE = Color(0, 0, 0)
	local TEXT_FACES = { 90, -90 } -- one roll per readable side

	function ENT:Draw()
		self:DrawModel()

		-- Direction indicator and spell name, shown to the owner while holding
		-- the physgun. The line is the direction the machine actually fires.
		local ply = LocalPlayer()
		local owner = self.CPPIGetOwner and self:CPPIGetOwner()
		if not IsValid(owner) then owner = self:GetNWEntity("FallbackOwner") end
		if owner ~= ply then return end

		local wep = ply:GetActiveWeapon()
		if not IsValid(wep) or wep:GetClass() ~= "weapon_physgun" then return end

		local startPos = self:WorldSpaceCenter()
		local endPos = util.TraceLine({
			start = startPos,
			endpos = startPos + self:GetForward() * 1000,
			mask = MASK_SOLID_BRUSHONLY
		}).HitPos

		render.DrawLine(startPos, endPos, LINE_COLOR, true)

		-- Crafted spell ids are unreadable (spellcraft_<steamid>_<slot>), so show
		-- the spell's name whenever it resolves.
		local spellId = self:GetCurrentSpell()
		local spell = spellId ~= "" and Arcana.RegisteredSpells[spellId] or nil
		local label = "Spell: " .. (spell and spell.name or (spellId ~= "" and spellId or "None"))

		-- Readable from either side: the same text drawn on both faces.
		local textPos = startPos + self:GetForward() * 40
		for _, roll in ipairs(TEXT_FACES) do
			local ang = self:GetAngles()
			ang:RotateAroundAxis(ang:Forward(), roll)
			if roll < 0 then ang:RotateAroundAxis(ang:Up(), 180) end

			cam.Start3D2D(textPos, ang, 0.1)
				draw.SimpleTextOutlined(label, "DermaLarge", 0, 0, LINE_COLOR, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER, 1, TEXT_OUTLINE)
			cam.End3D2D()
		end
	end

	function ENT:OnRemove()
		-- Cleanup handled by core.lua's hook system
		if self._ArcanaCastingCircle and self._ArcanaCastingCircle.Remove then
			self._ArcanaCastingCircle:Remove()
		end
	end
end

