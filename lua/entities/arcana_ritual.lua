AddCSLuaFile()
ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "Ritual"
ENT.Category = "Arcana"
ENT.Spawnable = false
ENT.RenderGroup = RENDERGROUP_BOTH

local VECTOR_ABOVE_ORB = Vector(0, 0, 0)
local VECTOR_DOWN = Vector(0, 0, 256)

-- Server-only runtime
if SERVER then
	util.AddNetworkString("Arcana_Ritual_Update")
	util.AddNetworkString("Arcana_Ritual_Activated")
end

local function shallowCopy(tbl)
	local out = {}

	if istable(tbl) then
		for k, v in pairs(tbl) do
			out[k] = v
		end
	end

	return out
end

function ENT:SetupDataTables()
	self:NetworkVar("Float", 0, "ExpireAt")
	self:NetworkVar("String", 0, "RitualId")
	self:NetworkVar("Bool", 0, "IsReplenishable")
	self:NetworkVar("Bool", 1, "IsActivated")
	self:NetworkVar("Int", 0, "ReplenishCost")
	self:NetworkVar("Float", 1, "TotalLifetime")

	if CLIENT then
		self:NetworkVarNotify("IsActivated", function(ent, _, _, new)
			if not new then return end
			ent._lastBandFraction = nil
			ent._lastScaleUpdate = nil

			if ent._circle then
				ent._circle:Destroy()
				ent._circle = nil
			end
		end)

		self:NetworkVarNotify("ExpireAt", function(ent, _, old, new)
			if new > old + 1 then
				ent._lastBandFraction = nil
				surface.PlaySound("arcana/arcane_" .. math.random(1, 3) .. ".ogg")
			end
		end)
	end
end

if SERVER then
	function ENT:Initialize()
		-- Make the ritual entity itself the orb
		self:SetModel("models/hunter/misc/sphere025x025.mdl")
		self:SetMaterial("models/shiny")
		self:SetModelScale(1.1, 0)
		self:PhysicsInit(SOLID_VPHYSICS)
		self:SetMoveType(MOVETYPE_VPHYSICS)
		self:SetSolid(SOLID_VPHYSICS)
		self:SetUseType(SIMPLE_USE)
		local phys = self:GetPhysicsObject()

		if IsValid(phys) then
			phys:Wake()
			phys:EnableGravity(false)
		end

		self._requirements = self._requirements or {}
		self._coinCost = self._coinCost or 0
		self._owner = self._owner or nil
		self._startedAt = CurTime()
		self:SetExpireAt(self._startedAt + (self._lifetime or 300))
		self._hoverBaseZ = 28
		self._hoverAmp = 6
		self._hoverSpeed = 2
		self:StartMotionController()
		self:NextThink(CurTime() + 0.2)

		timer.Simple(0.1, function()
			if not IsValid(self) then return end
			self:StartMotionController()
			self:SetPos(self:GetPos() + Vector(0, 0, 50))
			phys = self:GetPhysicsObject()

			if IsValid(phys) then
				phys:Wake()
				phys:EnableGravity(false)
			end
		end)
	end

	function ENT:Use(ply)
		if not IsValid(ply) or not ply:IsPlayer() then return end

		-- Replenish branch: ritual is already activated and can be replenished
		if self:GetIsActivated() and self._replenishable then
			local replenishCost = self:GetReplenishCost()

			if replenishCost > 0 and Arcana:GetCoins(ply) < replenishCost then
				if Arcana and Arcana.SendErrorNotification then
					Arcana:SendErrorNotification(ply, "Insufficient coins to replenish ritual")
				end

				self:EmitSound("buttons/button8.wav", 60, 110)

				return
			end

			if replenishCost > 0 then
				Arcana:TakeCoins(ply, replenishCost, "Replenish ritual: " .. (self:GetRitualId() or ""):gsub("%_", " "))
			end

			-- Extend lifetime by one full period; SetExpireAt triggers NetworkVarNotify on clients
			self:SetExpireAt(self:GetExpireAt() + self._lifetime)

			if self._onReplenish then
				self:_onReplenish(ply)
			end

			self:EmitSound("arcana/arcane_" .. math.random(1, 3) .. ".ogg", 75, 100)

			return
		end

		-- Normal activation guard
		if self._hasActivated then return end

		-- Check requirements against the player who pressed use
		local coinsOk = true

		if self._coinCost > 0 then
			coinsOk = Arcana:GetCoins(ply) >= self._coinCost
		end

		if not coinsOk then
			if Arcana and Arcana.SendErrorNotification then
				Arcana:SendErrorNotification(ply, "Insufficient coins")
			end

			self:EmitSound("buttons/button8.wav", 60, 110)

			return
		end

		for itemName, amt in pairs(self._requirements or {}) do
			local have = Arcana:GetItemCount(ply, itemName)

			if have < (amt or 1) then
				if Arcana and Arcana.SendErrorNotification then
					Arcana:SendErrorNotification(ply, "Missing item: " .. tostring(itemName))
				end

				self:EmitSound("buttons/button8.wav", 60, 110)

				return
			end
		end

		-- Consume from the player who activated
		if self._coinCost > 0 then
			Arcana:TakeCoins(ply, self._coinCost, "Ritual: " .. (self:GetRitualId() or ""):gsub("%_", " "))
		end

		for itemName, amt in pairs(self._requirements or {}) do
			Arcana:TakeItem(ply, itemName, amt)
		end

		-- Tell clients to evolve the circle then finalise the entity
		local evolveDur = 3.0
		net.Start("Arcana_Ritual_Activated")
		net.WriteEntity(self)
		net.WriteFloat(evolveDur)
		net.Broadcast()

		-- Report magic use at ritual activation
		if Arcana and Arcana.ManaCrystals and Arcana.ManaCrystals.ReportMagicUse then
			local pos = self:GetPos()
			local rid = self.GetRitualId and self:GetRitualId() or "ritual"
			Arcana.ManaCrystals:ReportMagicUse(ply, pos, rid, {isRitual = true})
		end

		timer.Simple(evolveDur + 0.1, function()
			if not IsValid(self) then return end

			if self._onActivate then
				self:_onActivate(ply)
			end

			if self._replenishable then
				self._lockedPos = self:GetPos()
				-- Reset expiry to a full lifetime from now so the first period is fair
				self:SetExpireAt(CurTime() + self._lifetime)
				self:SetIsActivated(true)
			else
				self:Remove()
			end
		end)

		self._hasActivated = true
	end

	function ENT:Configure(config)
		-- config: { id, owner, coin_cost, items = {name=amt}, on_activate = function(self) end, lifetime,
		--           replenishable, replenish_cost, on_replenish }
		self._requirements = shallowCopy(config.items or {})
		self._coinCost = tonumber(config.coin_cost or 0) or 0
		self._owner = IsValid(config.owner) and config.owner or nil
		self._onActivate = isfunction(config.on_activate) and config.on_activate or nil
		self._onReplenish = isfunction(config.on_replenish) and config.on_replenish or nil
		self._lifetime = math.max(1, tonumber(config.lifetime or 300) or 300)
		self._replenishable = config.replenishable == true
		self:SetRitualId(tostring(config.id or ""))
		self:SetExpireAt(CurTime() + self._lifetime)
		self:SetIsReplenishable(self._replenishable)
		self:SetIsActivated(false)
		self:SetReplenishCost(math.Clamp(tonumber(config.replenish_cost or 0) or 0, 0, 2147483647))
		self:SetTotalLifetime(self._lifetime)
		self:_Sync()
	end

	function ENT:_Sync()
		net.Start("Arcana_Ritual_Update")
		net.WriteEntity(self)
		net.WriteUInt(math.Clamp(self._coinCost or 0, 0, 1073741824), 32)
		local cnt = 0

		for _ in pairs(self._requirements or {}) do
			cnt = cnt + 1
		end

		net.WriteUInt(cnt, 8)

		for itemName, amt in pairs(self._requirements or {}) do
			net.WriteString(tostring(itemName))
			net.WriteUInt(math.Clamp(tonumber(amt) or 1, 0, 100000), 32)
		end

		net.WriteFloat(self:GetExpireAt() or (CurTime() + 300))
		net.Broadcast()
	end

	function ENT:Think()
		if CurTime() >= (self:GetExpireAt() or 0) then
			self:Remove()

			return
		end

		-- Periodically resync for HUD/UI
		if (self._nextSync or 0) < CurTime() then
			self:_Sync()
			self._nextSync = CurTime() + 2
		end

		self:NextThink(CurTime() + 0.1)
		return true
	end

	function ENT:PhysicsSimulate(phys, dt)
		if not IsValid(phys) then return end
		phys:Wake()

		local start = self:GetIsActivated() and self._lockedPos or self:GetPos() + VECTOR_ABOVE_ORB
		local tr = util.TraceLine({
			start = start,
			endpos = start - VECTOR_DOWN,
			mask = MASK_SOLID,
			filter = self,
		})

		local floatPos = tr.HitPos + Vector(0, 0, 50 + 5 * math.sin(CurTime()))
		local shadowParams = {
			secondstoarrive = 0.2,
			pos = floatPos,
			angle = Angle(0, self:GetAngles().y, 0),
			maxangular = 5000,
			maxangulardamp = 10000,
			maxspeed = 1000,
			maxspeeddamp = 1000,
			dampfactor = 0.8,
			teleportdistance = 1000,
			deltatime = dt,
		}

		phys:ComputeShadowControl(shadowParams)
	end
end

if CLIENT then
	local decoPanel = Color(32, 24, 18, 240)
	local gold = Color(198, 160, 74, 255)
	local paleGold = Color(222, 198, 120, 255)

	surface.CreateFont("Arcana_Ritual_Title", {
		font = "Georgia",
		size = 20,
		weight = 700,
		antialias = true,
		extended = true
	})

	surface.CreateFont("Arcana_Ritual_Row", {
		font = "Georgia",
		size = 16,
		weight = 600,
		antialias = true,
		extended = true
	})

	local ritualState = {}

	local VECTOR_ZERO = Vector(0, 0, 0)
	function ENT:Initialize()
		self._glowMat = Material("sprites/light_glow02_add")
		self._circle = nil
		self._bands = nil
		self._fxEmitter = ParticleEmitter(self:GetPos(), false)
		self._fxNextParticle = 0
	end

	net.Receive("Arcana_Ritual_Update", function()
		local ent = net.ReadEntity()
		local coins = net.ReadUInt(32)
		local count = net.ReadUInt(8)
		local items = {}

		for i = 1, count do
			local name = net.ReadString()
			local amt = net.ReadUInt(32)
			items[name] = amt
		end

		local expireAt = net.ReadFloat()

		ritualState[ent] = {
			coins = coins,
			items = items,
			expireAt = expireAt
		}
	end)

	net.Receive("Arcana_Ritual_Activated", function()
		local ent = net.ReadEntity()
		local duration = net.ReadFloat()
		if not IsValid(ent) then return end

		if ent._circle then
			ent._circle:StartEvolving(math.max(0.1, duration or 2.0), -1) -- upward
		end

		-- Animate the client-side bands scale so they pulse on activation
		if ent._bands then
			local bandDuration = math.max(0.1, (duration or 2.0) - 1)

			timer.Simple(bandDuration, function()
				if IsValid(ent) and ent._bands then
					ent._bands:SetScale(10, bandDuration)
				end
			end)
		end

		surface.PlaySound("arcana/arcane_" .. math.random(1, 3) .. ".ogg")
	end)

	function ENT:Draw()
		render.SetLightingMode(2)
		local col = self:GetColor()
		render.SetColorModulation(math.max(0.75, col.r / 255 * 2), math.max(0.75, col.g / 255 * 2), math.max(0.75, col.b / 255 * 2))
		self:DrawModel()
		render.SetColorModulation(1, 1, 1)
		render.SetLightingMode(0)
	end

	function ENT:OnRemove()
		if self._circle then
			self._circle:Destroy()
		end

		if self._bands then
			self._bands:Remove()
		end

		if self._fxEmitter then
			self._fxEmitter:Finish()
			self._fxEmitter = nil
		end
	end

	function ENT:_SpawnRitualParticles()
		if not self._fxEmitter then return end

		local center = self:WorldSpaceCenter()
		local col = self:GetColor()

		-- One particle per call; spawned at 0.03s intervals so there are always
		-- ~70 particles drifting at any given moment (dieTime / interval).
		local dir = VectorRand()
		dir:Normalize()
		local pos = center + dir * 5 * math.Rand(3, 8)

		local p = self._fxEmitter:Add("sprites/light_glow02_add", pos)
		if p then
			p:SetStartAlpha(180)
			p:SetEndAlpha(0)
			p:SetStartSize(math.Rand(4, 7))
			p:SetEndSize(math.Rand(1, 2))
			p:SetDieTime(math.Rand(1.8, 2.5))
			p:SetVelocity(dir * math.Rand(15, 30))
			p:SetAirResistance(15)
			p:SetGravity(VECTOR_ZERO)
			p:SetRoll(math.Rand(-180, 180))
			p:SetRollDelta(math.Rand(-0.4, 0.4))
			p:SetColor(col.r, col.g, col.b)
		end
	end

	function ENT:Think()
		if self._fxEmitter then
			self._fxEmitter:SetPos(self:GetPos())
		end

		if self:GetIsActivated() and self._fxEmitter then
			local now = CurTime()
			if now >= (self._fxNextParticle or 0) then
				self:_SpawnRitualParticles()
				self._fxNextParticle = now + 0.1
			end
		end

		self:SetNextClientThink(CurTime())
		return true
	end

	local MagicCircle = Arcana.Circle.MagicCircle
	local BandCircle = Arcana.Circle.BandCircle
	local MagicCircleManager = Arcana.Circle.MagicCircleManager

	local VECTOR_SLIGHTLY_ABOVE = Vector(0, 0, 2)
	local TEXT_OFFSET = Vector(0, 0, 24)
	function ENT:DrawTranslucent()
		local color = self:GetColor()
		local isActivated = self:GetIsActivated()

		-- Create and maintain a static magic circle under the orb (pre-activation only)
		if not isActivated then
			if not self._circle then
				local pos = self:GetPos() + VECTOR_SLIGHTLY_ABOVE
				local ang = Angle(0, 180, 180)
				local ritualId = self:GetRitualId()
				local seed = (isstring(ritualId) and #ritualId > 0) and tonumber(util.CRC(ritualId)) or nil
				self._circle = MagicCircle.new(pos, ang, color, 100, 100, 2, seed)
				MagicCircleManager:Add(self._circle)
			end

			if self._circle then
				local tr = util.TraceLine({
					start = self:GetPos() + VECTOR_ABOVE_ORB,
					endpos = self:GetPos() - VECTOR_DOWN,
					mask = MASK_SOLID,
					filter = self,
				})

				self._circle.position = tr.HitPos + VECTOR_SLIGHTLY_ABOVE
				self._circle.angles = Angle(0, 180, 180)
			end
		end

		-- glowy orb
		if self._glowMat then
			local pos = self:WorldSpaceCenter()
			local t = CurTime()
			local pulse = isActivated and (0.6 + 0.4 * math.sin(t * 2.0)) or (0.5 + 0.5 * math.sin(t * 3.2))
			local size = 200 + 60 * pulse
			render.SetMaterial(self._glowMat)
			render.DrawSprite(pos, size, size, Color(color.r, color.g, color.b, 230))
			local dl = DynamicLight(self:EntIndex())

			if dl then
				dl.pos = pos
				dl.r = color.r
				dl.g = color.g
				dl.b = color.b
				dl.brightness = isActivated and 3 or 2
				dl.Decay = 600
				dl.Size = isActivated and 180 or 120
				dl.DieTime = t + 0.1
			end
		end

		-- Client-side BandCircle VFX around the ritual orb
		if not self._bands and BandCircle then
			local baseColor = self:GetColor()
			local pos = self:WorldSpaceCenter()
			local ang = self:GetAngles()
			self._bands = BandCircle.Create(pos, ang, baseColor, 80, 0)

			if self._bands then
				self._bands.position = pos
				self._bands.angles = ang

				self._bands:AddBand(20, 5, {
					p = 20,
					y = 60,
					r = 10
				}, 2)

				self._bands:AddBand(32, 4, {
					p = -30,
					y = -40,
					r = 0
				}, 2)

				self._bands:AddBand(26, 6, {
					p = -10,
					y = -20,
					r = 60
				}, 2)
			end
		end

		if self._bands then
			self._bands.position = self:WorldSpaceCenter()
			self._bands.angles = self:GetAngles()
			self._bands.color = self:GetColor()
		end

		-- Activated-state visuals for replenishable rituals
		if isActivated then
			-- Band weakening: scale bands progressively down as lifetime drains
			local totalLifetime = self:GetTotalLifetime()

			if totalLifetime > 0 and self._bands then
				local remaining = math.max(0, self:GetExpireAt() - CurTime())
				local fraction = math.Clamp(remaining / totalLifetime, 0, 1)

				if not self._lastBandFraction or math.abs(self._lastBandFraction - fraction) > 0.02
					or not self._lastScaleUpdate or CurTime() - self._lastScaleUpdate > 2 then
					self._lastBandFraction = fraction
					self._lastScaleUpdate = CurTime()
					self._bands:SetScale(10 * fraction, 2)
				end
			end
		end

		-- HUD panel
		local data = ritualState[self]
		if not data then return end

		local pos = self:WorldSpaceCenter() + TEXT_OFFSET
		local ang = LocalPlayer():EyeAngles()
		ang:RotateAroundAxis(ang:Right(), 90)
		ang:RotateAroundAxis(ang:Up(), -90)
		local key = input.LookupBinding("+use") or "UNBOUND"
		local remain = math.max(0, (data.expireAt or 0) - CurTime())

		cam.Start3D2D(pos, ang, 0.06)
		surface.SetDrawColor(decoPanel)
		surface.DrawRect(-180, -90, 360, 180)
		surface.SetDrawColor(gold)
		surface.DrawOutlinedRect(-180, -90, 360, 180, 2)
		draw.SimpleText(string.upper((self:GetRitualId():gsub("%_", " ")) or "RITUAL"), "Arcana_Ritual_Title", 0, -70, paleGold, TEXT_ALIGN_CENTER)

		if isActivated and self:GetIsReplenishable() then
			-- Post-activation HUD: show replenish info
			local replenishCost = self:GetReplenishCost()
			draw.SimpleText("ACTIVATED", "Arcana_Ritual_Title", 0, -40, Color(100, 220, 100, 255), TEXT_ALIGN_CENTER)
			draw.SimpleText("Remaining: " .. string.NiceTime(remain), "Arcana_Ritual_Row", -160, 0, color_white)
			draw.SimpleText("Replenish: " .. tostring(replenishCost) .. " coins", "Arcana_Ritual_Row", -160, 20, color_white)
			draw.SimpleText("Press [" .. string.upper(key) .. "] to replenish", "Arcana_Ritual_Row", -160, 56, color_white)
		else
			-- Pre-activation HUD: show activation requirements
			local y = -40
			draw.SimpleText("Coins: " .. tostring(data.coins or 0), "Arcana_Ritual_Row", -160, y, color_white)
			y = y + 20

			for name, amt in pairs(data.items or {}) do
				local cleanName = _G.msitems and _G.msitems.GetInventoryInfo and _G.msitems.GetInventoryInfo(name) and _G.msitems.GetInventoryInfo(name).name or name
				draw.SimpleText(tostring(cleanName) .. ": x" .. tostring(amt), "Arcana_Ritual_Row", -160, y, color_white)
				y = y + 18
			end

			draw.SimpleText(string.format("Expires in %s", string.NiceTime(remain)), "Arcana_Ritual_Row", -160, 45, color_white)
			draw.SimpleText("Press [" .. string.upper(key) .. "] to activate", "Arcana_Ritual_Row", -160, 66, color_white)
		end

		cam.End3D2D()
	end
end