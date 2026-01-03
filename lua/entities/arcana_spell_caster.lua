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
end

if SERVER then
	util.AddNetworkString("Arcana_SpellCaster_OpenMenu")
	util.AddNetworkString("Arcana_SpellCaster_SetSpell")
	util.AddNetworkString("Arcana_SpellCaster_CastFromMenu")

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

	function ENT:GetEntityCooldown(spellId)
		local cooldownTime = self.SpellCooldowns[spellId] or 0
		return math.max(0, cooldownTime - CurTime())
	end

	function ENT:IsOnEntityCooldown(spellId)
		return self:GetEntityCooldown(spellId) > 0
	end

	function ENT:CanCastSpellForOwner(owner, spellId)
		if not IsValid(owner) then return false, "No owner set" end

		local spell = Arcane.RegisteredSpells[spellId]
		if not spell then return false, "Spell not found" end

		-- Check if currently casting
		if self.CastingUntil > CurTime() then
			return false, "Already casting"
		end

		-- Check entity-specific cooldown (not owner's cooldown)
		if self:IsOnEntityCooldown(spellId) then
			return false, "Spell on cooldown"
		end

		local data = Arcane:GetPlayerData(owner)

		-- Check if owner has spell unlocked
		if not data.unlocked_spells[spellId] then
			return false, "Owner hasn't unlocked this spell"
		end

		-- Check if owner can afford the spell (we'll consume resources later)
		if spell.cost_type == Arcane.COST_TYPES.COINS then
			local canPayWithCoins = owner.GetCoins and owner.TakeCoins and (owner:GetCoins() >= spell.cost_amount)
			if not canPayWithCoins and owner:Health() < spell.cost_amount then
				return false, "Owner cannot afford spell cost"
			end
		elseif spell.cost_type == Arcane.COST_TYPES.HEALTH then
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
		local ok, reason = hook.Run("Arcana_CanCastSpell", owner, spellId)
		if ok == false then return false, reason or "Cannot cast spell" end

		return true
	end

	function ENT:StartCastingSpell(spellId)
		local owner = self.CPPIGetOwner and self:CPPIGetOwner()
		if not IsValid(owner) then owner = self:GetNWEntity("FallbackOwner") end
		if not IsValid(owner) then return false end

		local canCast, reason = self:CanCastSpellForOwner(owner, spellId)
		if not canCast then
			if IsValid(owner) and owner:IsPlayer() then
				Arcane:SendErrorNotification(owner, "Spell Caster: " .. (reason or "Cannot cast"))
			end

			return false
		end

		local spell = Arcane.RegisteredSpells[spellId]
		local castTime = math.max(0.1, spell.cast_time or 0)

		self.CastingUntil = CurTime() + castTime
		self.QueuedSpell = spellId

		self:SetIsCasting(true)
		self:SetCurrentSpell(spellId)
		self:SetCastProgress(0)

		if WireLib then
			WireLib.TriggerOutput(self, "Casting", 1)
			WireLib.TriggerOutput(self, "Ready", 0)
		end

		-- Broadcast casting visuals
		local forwardLike = spell.cast_anim == "forward" or spell.is_projectile or spell.has_target or ((spell.range or 0) > 0)

		-- Use entity's position and orientation for casting circle
		local pos = self:GetPos() + self:GetForward() * 30
		local ang = self:GetAngles()
		ang:RotateAroundAxis(ang:Up(), 90)
		ang:RotateAroundAxis(ang:Right(), 90)
		local size = 30


		net.Start("Arcane_BeginCasting", true)
		net.WriteEntity(self)
		net.WriteString(spellId)
		net.WriteFloat(castTime)
		net.WriteBool(forwardLike)
		net.Broadcast()

		-- Schedule spell execution
		timer.Simple(castTime, function()
			if not IsValid(self) then return end

			self:SetIsCasting(false)
			self:SetCastProgress(1)

			if WireLib then
				WireLib.TriggerOutput(self, "Casting", 0)
			end

			-- Re-validate before casting
			local canExecute, reason = self:CanCastSpellForOwner(owner, spellId)
			if not canExecute then
				if IsValid(owner) and owner:IsPlayer() then
					Arcane:SendErrorNotification(owner, "Spell Caster: " .. (reason or "Cannot cast"))
				end

				net.Start("Arcane_SpellFailed", true)
				net.WriteEntity(self)
				net.WriteFloat(castTime)
				net.Broadcast()

				if WireLib then
					WireLib.TriggerOutput(self, "Ready", 1)
				end

				self.CastingUntil = 0
				self.QueuedSpell = nil
				return
			end

			self:ExecuteSpell(owner, spellId, spell, castTime, forwardLike, pos, ang, size)
		end)

		return true
	end

	function ENT:ExecuteSpell(owner, spellId, spell, castTime, forwardLike, pos, ang, size)
		if not IsValid(owner) then return end

		local data = Arcane:GetPlayerData(owner)
		local takeDamageInfo = owner.ForceTakeDamageInfo or owner.TakeDamageInfo

		-- Apply costs to owner
		if spell.cost_type == Arcane.COST_TYPES.COINS then
			local canPayWithCoins = owner.GetCoins and owner.TakeCoins and (owner:GetCoins() >= spell.cost_amount)

			if canPayWithCoins then
				owner:TakeCoins(spell.cost_amount, "Spell Caster: " .. spell.name)
			else
				-- Fallback: pay with health
				local dmg = DamageInfo()
				dmg:SetDamage(spell.cost_amount)
				dmg:SetAttacker(owner)
				dmg:SetInflictor(self)
				dmg:SetDamageType(bit.bor(DMG_GENERIC, DMG_DIRECT))
				takeDamageInfo(owner, dmg)
			end
		elseif spell.cost_type == Arcane.COST_TYPES.HEALTH then
			local dmg = DamageInfo()
			dmg:SetDamage(spell.cost_amount)
			dmg:SetAttacker(owner)
			dmg:SetInflictor(self)
			dmg:SetDamageType(bit.bor(DMG_GENERIC, DMG_DIRECT))
			takeDamageInfo(owner, dmg)
		end

		-- Set entity-specific cooldown (not owner's cooldown)
		self.SpellCooldowns[spellId] = CurTime() + spell.cooldown

		pos = self:GetPos() + self:GetForward() * 30
		ang = self:GetAngles()
		ang:RotateAroundAxis(ang:Up(), 90)
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

		hook.Run("Arcana_CastSpell", owner, spellId, nil, data, context, success)

		if success then
			if spell.on_success then
				spell.on_success(owner, nil, data)
			end

			-- Report magic usage location
			if Arcane.ManaCrystals and Arcane.ManaCrystals.ReportMagicUse then
				Arcane.ManaCrystals:ReportMagicUse(owner, pos, spellId, context)
			end
		else
			if spell.on_failure then
				spell.on_failure(owner, nil, data)
			end

			hook.Run("Arcana_CastSpellFailure", owner, spellId, nil, data, context)

			net.Start("Arcane_SpellFailed", true)
			net.WriteEntity(self)
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
				local owner = self.CPPIGetOwner and self:CPPIGetOwner()
				if not IsValid(owner) then owner = self:GetNWEntity("FallbackOwner") end
				if not IsValid(owner) then return end

				Arcane:SendErrorNotification(owner, "Spell Caster: No spell ID provided")
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

		-- Update wire outputs
		if WireLib then
			local spellId = activeSpell

			if spellId ~= "" then
				local cooldown = self:GetEntityCooldown(spellId)
				WireLib.TriggerOutput(self, "CooldownRemaining", cooldown)
			end

			-- Update cast progress
			if self:GetIsCasting() and self.CastingUntil > CurTime() then
				local spell = Arcane.RegisteredSpells[self.QueuedSpell]
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

		-- Check ownership
		local owner = ent.CPPIGetOwner and ent:CPPIGetOwner()
		if not IsValid(owner) then owner = ent:GetNWEntity("FallbackOwner") end
		if not IsValid(owner) then return end
		if owner ~= ply then return end

		spellId = string.lower(string.Trim(spellId))
		ent:SetSelectedSpell(spellId)
	end)

	net.Receive("Arcana_SpellCaster_CastFromMenu", function(_, ply)
		local ent = net.ReadEntity()

		if not IsValid(ent) or ent:GetClass() ~= "arcana_spell_caster" then return end

		-- Check ownership
		local owner = ent.CPPIGetOwner and ent:CPPIGetOwner()
		if not IsValid(owner) then owner = ent:GetNWEntity("FallbackOwner") end
		if not IsValid(owner) then return end
		if owner ~= ply then return end

		local spellId = ent:GetActiveSpellID()
		if spellId ~= "" then
			ent:StartCastingSpell(spellId)
		end
	end)
end

if CLIENT then
	-- Fonts (reusing Arcana style)
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

	-- Colors
	local decoBg = Color(26, 20, 14, 235)
	local decoPanel = Color(32, 24, 18, 235)
	local gold = Color(198, 160, 74, 255)
	local paleGold = Color(222, 198, 120, 255)
	local textBright = Color(236, 230, 220, 255)
	local textDim = Color(180, 170, 150, 255)
	local cardIdle = Color(46, 36, 26, 235)
	local cardHover = Color(58, 44, 32, 235)

	-- Blur helper
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
		surface.DisableClipping(true)
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
		surface.DisableClipping(false)
	end

	local function Arcana_FillDecoPanel(x, y, w, h, col, corner)
		local c = math.max(8, corner or 12)
		draw.NoTexture()
		surface.SetDrawColor(col.r, col.g, col.b, col.a or 255)

		local pts = {
			{x = x + c, y = y},
			{x = x + w - c, y = y},
			{x = x + w, y = y + c},
			{x = x + w, y = y + h - c},
			{x = x + w - c, y = y + h},
			{x = x + c, y = y + h},
			{x = x, y = y + h - c},
			{x = x, y = y + c},
		}

		surface.DrawPoly(pts)
	end

	-- Spell Caster Menu
	local function OpenSpellCasterMenu(caster)
		if not Arcane then return end
		local ply = LocalPlayer()
		if not IsValid(ply) or not IsValid(caster) then return end

		local owner = caster.CPPIGetOwner and caster:CPPIGetOwner()
		if not IsValid(owner) then owner = caster:GetNWEntity("FallbackOwner") end
		if not IsValid(owner) then return end
		if owner ~= ply then
			Arcane:Print("❌ You don't own this Spell Caster")
			return
		end

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
			draw.SimpleText("SPELL CASTER", "Arcana_DecoTitle", 18, 10, paleGold)
		end

		if IsValid(frame.btnMinim) then frame.btnMinim:Hide() end
		if IsValid(frame.btnMaxim) then frame.btnMaxim:Hide() end

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
		content:DockMargin(12, 8, 12, 12)
		content.Paint = nil

		-- Info panel about Wiremod
		local infoPanel = vgui.Create("DPanel", content)
		infoPanel:Dock(TOP)
		infoPanel:SetTall(50)
		infoPanel:DockMargin(0, 0, 0, 5)

		infoPanel.Paint = function(pnl, w, h)
			Arcana_FillDecoPanel(4, 4, w - 8, h - 8, Color(36, 44, 54, 235), 8)
			Arcana_DrawDecoFrame(4, 4, w - 8, h - 8, Color(120, 180, 220, 255), 8)

			-- Icon
			draw.SimpleText("⚡", "Arcana_DecoTitle", 18, h * 0.5 - 2, Color(120, 180, 220, 255), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)

			-- Info text
			draw.SimpleText("This entity works better with wiremod!", "Arcana_Ancient", 48, h * 0.5 - 8, textBright, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
			draw.SimpleText("Use Wiremod inputs/outputs for advanced control (overrides menu selection)", "Arcana_AncientSmall", 48, h * 0.5 + 8, textDim, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		end

		local listPanel = vgui.Create("DPanel", content)
		listPanel:Dock(FILL)

		listPanel.Paint = function(pnl, w, h)
			Arcana_FillDecoPanel(4, 4, w - 8, h - 8, decoPanel, 12)
			Arcana_DrawDecoFrame(4, 4, w - 8, h - 8, gold, 12)
			draw.SimpleText(string.upper("Select Spell"), "Arcana_Ancient", 14, 10, paleGold)

			-- Show current selected spell
			local currentSpell = caster:GetSelectedSpell() or ""
			if currentSpell ~= "" then
				local spell = Arcane.RegisteredSpells[currentSpell]
				if spell then
					draw.SimpleText("Current: " .. spell.name, "Arcana_AncientSmall", w - 14, 10, textDim, TEXT_ALIGN_RIGHT)
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
			local bg = hovered and cardHover or cardIdle
			local frameCol = enabled and gold or textDim
			Arcana_FillDecoPanel(0, 0, w, h, bg, 8)
			Arcana_DrawDecoFrame(0, 0, w, h, frameCol, 8)

			local label = "Cast Spell"
			local col = enabled and textBright or textDim

			-- Show cooldown if applicable
			local spellId = caster:GetSelectedSpell() or ""
			if spellId ~= "" and IsValid(ply) then
				local data = Arcane:GetPlayerData(ply)
				if data and data.spell_cooldowns then
					local cd = data.spell_cooldowns[spellId]
					if cd and cd > CurTime() then
						local remaining = math.max(0, math.ceil(cd - CurTime()))
						label = tostring(remaining) .. "s"
						col = textDim
					end
				end
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
			local spellId = caster:GetSelectedSpell() or ""
			pnl:SetEnabled(spellId ~= "" and IsValid(caster))
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
			local data = Arcane:GetPlayerData(ply)
			if not data then return end

			local unlocked = {}
			for sid, sp in pairs(Arcane.RegisteredSpells) do
				if data.unlocked_spells[sid] then
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
				lbl:SetTextColor(textDim)
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
					local bg = selected and Color(58, 64, 44, 235) or (hovered and cardHover or cardIdle)
					local frameCol = selected and Color(120, 200, 100) or gold

					Arcana_FillDecoPanel(2, 2, w - 4, h - 4, bg, 8)
					Arcana_DrawDecoFrame(2, 2, w - 4, h - 4, frameCol, 8)
					draw.SimpleText(sp.name, "Arcana_AncientLarge", 12, 8, textBright)

					-- Cost info
					local ca = tonumber(sp.cost_amount or 0) or 0
					local ct = tostring(sp.cost_type or "")
					local sub = string.format("Cost %s %s", string.Comma(ca), ct)
					draw.SimpleText(sub, "Arcana_AncientSmall", 12, 32, textDim)
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
	function ENT:Draw()
		self:DrawModel()

		-- Draw direction indicator and spell info for owner with physgun
		local ply = LocalPlayer()
		local owner = self.CPPIGetOwner and self:CPPIGetOwner()
		if not IsValid(owner) then owner = self:GetNWEntity("FallbackOwner") end
		if not IsValid(owner) then return end
		if owner ~= ply then return end

		if isOwner then
			local wep = ply:GetActiveWeapon()
			if IsValid(wep) and wep:GetClass() == "weapon_physgun" then
				-- Draw direction line
				local startPos = self:WorldSpaceCenter()
				local endPos = util.TraceLine({
					start = startPos,
					endpos = startPos + self:GetForward() * 1000,
					mask = MASK_SOLID_BRUSHONLY
				}).HitPos

				render.DrawLine(startPos, endPos, LINE_COLOR, true)

				local spellId = self:GetCurrentSpell()
				if spellId == "" then spellId = "None" end

				-- Position text alongside the line, oriented in the same direction
				local textPos = startPos + self:GetForward() * 40
				local ang = self:GetAngles()
				ang:RotateAroundAxis(ang:Forward(), 90)
				--ang:RotateAroundAxis(ang:Right(), 90)

				cam.Start3D2D(textPos, ang, 0.1)
					draw.SimpleTextOutlined(
						"Spell: " .. spellId,
						"DermaLarge",
						0, 0,
						LINE_COLOR,
						TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER,
						1,
						Color(0, 0, 0)
					)
				cam.End3D2D()

				ang = self:GetAngles()
				ang:RotateAroundAxis(ang:Forward(), -90)
				ang:RotateAroundAxis(ang:Up(), 180)
				cam.Start3D2D(textPos, ang, 0.1)
					draw.SimpleTextOutlined(
						"Spell: " .. spellId,
						"DermaLarge",
						0, 0,
						LINE_COLOR,
						TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER,
						1,
						Color(0, 0, 0)
					)
				cam.End3D2D()
			end
		end
	end

	function ENT:OnRemove()
		-- Cleanup handled by core.lua's hook system
		if self._ArcanaCastingCircle and self._ArcanaCastingCircle.Remove then
			self._ArcanaCastingCircle:Remove()
		end
	end
end

