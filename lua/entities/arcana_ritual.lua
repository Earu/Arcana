AddCSLuaFile()
ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "Ritual"
ENT.Category = "Arcana"
ENT.Spawnable = false
ENT.RenderGroup = RENDERGROUP_BOTH

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
		if self._hasActivated then return end
		if not IsValid(ply) or not ply:IsPlayer() then return end
		-- Check requirements against the player who pressed use
		local coinsOk = true

		if self._coinCost > 0 then
			coinsOk = (ply.GetCoins and ply:GetCoins() >= self._coinCost) == true
		end

		if not coinsOk then
			if Arcane and Arcane.SendErrorNotification then
				Arcane:SendErrorNotification(ply, "Insufficient coins")
			end

			self:EmitSound("buttons/button8.wav", 60, 110)

			return
		end

		for itemName, amt in pairs(self._requirements or {}) do
			local have = ply.GetItemCount and ply:GetItemCount(itemName) or 0

			if have < (amt or 1) then
				if Arcane and Arcane.SendErrorNotification then
					Arcane:SendErrorNotification(ply, "Missing item: " .. tostring(itemName))
				end

				self:EmitSound("buttons/button8.wav", 60, 110)

				return
			end
		end

		-- Consume from the player who activated
		if self._coinCost > 0 and ply.TakeCoins then
			ply:TakeCoins(self._coinCost, "Ritual: " .. (self:GetRitualId() or ""))
		end

		if ply.TakeItem and isfunction(ply.TakeItem) then
			for itemName, amt in pairs(self._requirements or {}) do
				ply:TakeItem(itemName, amt)
			end
		end

		-- Tell clients to evolve the circle then remove the entity after a short delay
		local evolveDur = 3.0
		net.Start("Arcana_Ritual_Activated")
		net.WriteEntity(self)
		net.WriteFloat(evolveDur)
		net.Broadcast()

		-- Report magic use at ritual activation
		if Arcane and Arcane.ManaCrystals and Arcane.ManaCrystals.ReportMagicUse then
			local pos = self:GetPos()
			local rid = self.GetRitualId and self:GetRitualId() or "ritual"
			Arcane.ManaCrystals:ReportMagicUse(ply, pos, rid, {isRitual = true})
		end

		timer.Simple(evolveDur + 0.1, function()
			if IsValid(self) then
				-- Callback
				if self._onActivate then
					self:_onActivate(ply)
				end

				self:Remove()
			end
		end)

		self._hasActivated = true
	end

	function ENT:Configure(config)
		-- config: { id, owner, coin_cost, items = {name=amt}, on_activate = function(self) end, lifetime }
		self._requirements = shallowCopy(config.items or {})
		self._coinCost = tonumber(config.coin_cost or 0) or 0
		self._owner = IsValid(config.owner) and config.owner or nil
		self._onActivate = isfunction(config.on_activate) and config.on_activate or nil
		self._lifetime = math.max(1, tonumber(config.lifetime or 300) or 300)
		self:SetRitualId(tostring(config.id or ""))
		self:SetExpireAt(CurTime() + self._lifetime)
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
		local start = self:GetPos() + Vector(0, 0, 100)

		local tr = util.TraceLine({
			start = start,
			endpos = start - Vector(0, 0, 256),
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

	function ENT:Initialize()
		self._glowMat = Material("sprites/light_glow02_add")
		self._circle = nil
		self._bands = nil
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
			ent._circle:StartEvolving(math.max(0.1, duration or 2.0), true)
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
		self:DrawModel()
		render.SetLightingMode(0)
	end

	function ENT:OnRemove()
		if self._circle then
			self._circle:Destroy()
		end

		if self._bands then
			self._bands:Remove()
		end
	end

	function ENT:DrawTranslucent()
		local color = self:GetColor()

		-- Create and maintain a static magic circle under the orb
		if not self._circle then
			local pos = self:GetPos() + Vector(0, 0, 2)
			local ang = Angle(0, 180, 180)
			self._circle = MagicCircle.new(pos, ang, color, 100, 100, 2)
			MagicCircleManager:Add(self._circle)
		end

		if self._circle then
			local tr = util.TraceLine({
				start = self:GetPos() + Vector(0, 0, 100),
				endpos = self:GetPos() - Vector(0, 0, 256),
				mask = MASK_SOLID,
				filter = self,
			})

			self._circle.position = tr.HitPos + Vector(0, 0, 2)
			self._circle.angles = Angle(0, 180, 180)
		end

		-- glowy orb similar to altar
		if self._glowMat then
			local pos = self:WorldSpaceCenter()
			local t = CurTime()
			local pulse = 0.5 + 0.5 * math.sin(t * 3.2)
			local size = 200 + 60 * pulse
			render.SetMaterial(self._glowMat)
			render.DrawSprite(pos, size, size, Color(color.r, color.g, color.b, 230))
			local dl = DynamicLight(self:EntIndex())

			if dl then
				dl.pos = pos
				dl.r = color.r
				dl.g = color.g
				dl.b = color.b
				dl.brightness = 2
				dl.Decay = 600
				dl.Size = 120
				dl.DieTime = t + 0.1
			end
		end

		-- Client-side BandCircle VFX around the ritual orb so we can scale it
		if not self._bands and BandCircle then
			local baseColor = self:GetColor()
			local pos = self:WorldSpaceCenter()
			local ang = self:GetAngles()
			self._bands = BandCircle.Create(pos, ang, baseColor, 80, 0)

			if self._bands then
				self._bands.position = pos
				self._bands.angles = ang

				-- Bands config mirrors previous server call
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
			-- keep the bands following the entity and adjust color to match ritual
			self._bands.position = self:WorldSpaceCenter()
			self._bands.angles = self:GetAngles()
			self._bands.color = self:GetColor()
		end

		-- Client-side BandCircle VFX around the ritual orb so we can scale it
		if not self._bands and BandCircle then
			local baseColor = self:GetColor()
			local pos = self:WorldSpaceCenter()
			local ang = self:GetAngles()
			self._bands = BandCircle.Create(pos, ang, baseColor, 80, 0)

			if self._bands then
				self._bands.position = pos
				self._bands.angles = ang

				-- Bands config mirrors previous server call
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
			-- keep the bands following the entity and adjust color to match ritual
			self._bands.position = self:WorldSpaceCenter()
			self._bands.angles = self:GetAngles()
			self._bands.color = self:GetColor()
		end

		local data = ritualState[self]
		if not data then return end
		local pos = self:WorldSpaceCenter() + Vector(0, 0, 24)
		local ang = LocalPlayer():EyeAngles()
		ang:RotateAroundAxis(ang:Right(), 90)
		ang:RotateAroundAxis(ang:Up(), -90)
		cam.Start3D2D(pos, ang, 0.06)
		surface.SetDrawColor(decoPanel)
		surface.DrawRect(-180, -90, 360, 180)
		surface.SetDrawColor(gold)
		surface.DrawOutlinedRect(-180, -90, 360, 180, 2)
		draw.SimpleText(string.upper((self:GetRitualId():gsub("%_", " ")) or "RITUAL"), "Arcana_Ritual_Title", 0, -70, paleGold, TEXT_ALIGN_CENTER)
		local y = -40
		draw.SimpleText("Coins: " .. tostring(data.coins or 0), "Arcana_Ritual_Row", -160, y, color_white)
		y = y + 20

		for name, amt in pairs(data.items or {}) do
			local cleanName = _G.msitems and _G.msitems.GetInventoryInfo and _G.msitems.GetInventoryInfo(name) and _G.msitems.GetInventoryInfo(name).name or name
			draw.SimpleText(tostring(cleanName) .. ": x" .. tostring(amt), "Arcana_Ritual_Row", -160, y, color_white)
			y = y + 18
		end

		local remain = math.max(0, (data.expireAt or 0) - CurTime())
		local key = input.LookupBinding("+use") or "UNBOUND"
		draw.SimpleText(string.format("Expires in %s", string.NiceTime(remain)), "Arcana_Ritual_Row", -160, 45, color_white)
		draw.SimpleText("Press [" .. string.upper(key) .. "] to activate", "Arcana_Ritual_Row", -160, 66, color_white)
		cam.End3D2D()
	end
end