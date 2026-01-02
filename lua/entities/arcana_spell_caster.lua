AddCSLuaFile()

ENT.Type = "anim"
ENT.Base = "base_gmodentity"

ENT.PrintName = "Arcane Spell Caster"
ENT.Author = "Arcana"
ENT.Category = "Arcana"
ENT.Spawnable = true
ENT.AdminOnly = false

ENT.RenderGroup = RENDERGROUP_OPAQUE

function ENT:SetupDataTables()
	self:NetworkVar("Bool", 0, "IsCasting")
	self:NetworkVar("String", 0, "CurrentSpell")
	self:NetworkVar("Float", 0, "CastProgress")
end

if SERVER then
	function ENT:Initialize()
		self:SetModel("models/hunter/blocks/cube025x025x025.mdl")
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

	function ENT:GetEntityCooldown(spellId)
		local cooldownTime = self.SpellCooldowns[spellId] or 0
		return math.max(0, cooldownTime - CurTime())
	end

	function ENT:IsOnEntityCooldown(spellId)
		return self:GetEntityCooldown(spellId) > 0
	end

	function ENT:CanCastSpellForOwner(owner, spellId)
		if not IsValid(owner) then return false, "No owner set" end
		if not owner:Alive() then return false, "Owner is dead" end

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
		local owner = self:CPPIGetOwner() or self:GetOwner()

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
		local pos = self:GetPos() + self:GetUp() * 15
		local ang = self:GetAngles()
		local size = 40

		if forwardLike then
			pos = self:GetPos() + self:GetForward() * 30 + self:GetUp() * 15
			ang = self:GetAngles()
			ang:RotateAroundAxis(ang:Right(), 90)
			size = 30
		end

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
			local canExecute, _ = self:CanCastSpellForOwner(owner, spellId)
			if not canExecute then
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

		-- Recompute casting position at execution time
		pos = self:GetPos() + self:GetUp() * 15
		ang = self:GetAngles()
		size = 40

		if forwardLike then
			pos = self:GetPos() + self:GetForward() * 30 + self:GetUp() * 15
			ang = self:GetAngles()
			ang:RotateAroundAxis(ang:Right(), 90)
			size = 30
		end

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

	function ENT:TriggerInput(iname, value)
		if iname == "Cast" and value ~= 0 then
			local spellId = self.Inputs.SpellID.Value or ""
			spellId = string.lower(string.Trim(spellId))

			if spellId == "" then
				local owner = self:CPPIGetOwner() or self:GetOwner()
				if IsValid(owner) and owner:IsPlayer() then
					Arcane:SendErrorNotification(owner, "Spell Caster: No spell ID provided")
				end
				return
			end

			self:StartCastingSpell(spellId)
		end
	end

	function ENT:Think()
		-- Update wire outputs
		if WireLib then
			local spellId = self.Inputs.SpellID.Value or ""
			spellId = string.lower(string.Trim(spellId))

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
		-- Optional: manual interaction could open a spell selection menu
	end
end

if CLIENT then
	local LINE_COLOR = Color(0, 255, 0, 255)
	function ENT:Draw()
		self:DrawModel()

		-- Draw direction indicator and spell info for owner with physgun
		local ply = LocalPlayer()
		local owner = self:CPPIGetOwner() or self:GetOwner()
		local isOwner = IsValid(owner) and owner == ply

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

