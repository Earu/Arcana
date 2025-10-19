AddCSLuaFile()
ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "Enchanter"
ENT.Category = "Arcana"
ENT.Spawnable = true
ENT.AdminSpawnable = true
ENT.AdminOnly = false
ENT.RenderGroup = RENDERGROUP_BOTH
ENT.UseCooldown = 0.75
ENT.HintDistance = 140

function ENT:SetupDataTables()
	self:NetworkVar("Entity", 0, "ContainedWeapon") -- weapon entity stored inside machine
	self:NetworkVar("String", 0, "ContainedClass") -- class name for persistence on client
end

if SERVER then
	util.AddNetworkString("Arcana_OpenEnchanterMenu")
	util.AddNetworkString("Arcana_Enchanter_Deposit")
	util.AddNetworkString("Arcana_Enchanter_Withdraw")
	util.AddNetworkString("Arcana_Enchanter_ApplyBatch")
	util.AddNetworkString("Arcana_Enchanter_ParticleBurst")

	resource.AddFile("materials/entities/arcana_enchanter.png")

	local function SendEnchantBurst(ent)
		if not IsValid(ent) then return end
		net.Start("Arcana_Enchanter_ParticleBurst", true)
		net.WriteEntity(ent)
		net.Broadcast()
	end

	function ENT:Initialize()
		self:SetModel("models/props/de_piranesi/pi_sundial.mdl")
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

		-- Mana receive state (boolean pulse, no buffering/costs)
		self._receivingMana = false
		self._receivingUntil = 0
		self:SetNWBool("Arcana_ReceivingMana", false)

		-- Register into ManaNetwork as a consumer
		local Arcane = _G.Arcane or {}
		if Arcane.ManaNetwork and Arcane.ManaNetwork.RegisterConsumer then
			Arcane.ManaNetwork:RegisterConsumer(self, {range = 700})
		end
	end

	function ENT:SpawnFunction(ply, tr, classname)
		if not tr or not tr.Hit then return end

		local pos = tr.HitPos + tr.HitNormal * 2
		local ent = ents.Create(classname or "arcana_enchanter")
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
		net.Start("Arcana_OpenEnchanterMenu")
		net.WriteEntity(self)
		net.Send(ply)
		self:EmitSound("buttons/button9.wav", 60, 110)
	end

	net.Receive("Arcana_Enchanter_Deposit", function(_, ply)
		local ent = net.ReadEntity()
		if not IsValid(ent) or ent:GetClass() ~= "arcana_enchanter" then return end

		local hasCls = tostring(ent:GetContainedClass() or "")
		if hasCls ~= "" or IsValid(ent:GetContainedWeapon()) then return end -- already holding a weapon

		local orig = ply:GetActiveWeapon()
		if not IsValid(orig) then return end

		local cls = orig:GetClass()
		if not isstring(cls) or cls == "" then return end

		-- Capture existing enchantments on player's weapon
		local transferIds = {}
		local map = Arcane:GetEntityEnchantments(orig)
		for id, _ in pairs(map or {}) do
			transferIds[#transferIds + 1] = id
		end

		-- Always strip the player's weapon (some remove themselves on drop)
		if ply:HasWeapon(cls) then
			ply:StripWeapon(cls)
		end

		-- Spawn a fresh weapon entity for display
		local wep = ents.Create(cls)
		if not IsValid(wep) then return end
		wep:Spawn()
		wep:Activate()
		wep:SetOwner(NULL)
		wep:SetPos(ent:WorldSpaceCenter() + ent:GetUp() * ent:OBBMaxs().z * 0.25)
		wep:SetAngles(Angle(0, ply:EyeAngles().y or 0, 0))
		wep:SetParent(ent)
		wep:SetMoveType(MOVETYPE_NONE)
		wep:SetCollisionGroup(COLLISION_GROUP_WORLD)
		wep.ArcanaStored = true
		wep.ms_notouch = true

		wep:AddEFlags(EFL_FORCE_CHECK_TRANSMIT)
		wep.UpdateTransmitState = function()
			return TRANSMIT_PVS
		end

		-- Store class and contained reference
		ent:SetContainedClass(cls)
		ent:SetContainedWeapon(wep)

		-- Re-apply enchantments to new entity and sync
		for _, id in ipairs(transferIds) do
			Arcane:ApplyEnchantmentToWeaponEntity(ply, wep, id, true)
		end

		Arcane:SyncWeaponEnchantNW(wep)

		-- Keep a snapshot for fallback re-give
		ent._containedEnchantIds = table.Copy(transferIds)

		-- Initialize slow multi-axis spin around its current local orientation
		ent._spinStart = CurTime()
		ent._spinBaseAng = wep:GetLocalAngles()
		-- Gentle speeds in deg/sec on all axes
		ent._spinSpeeds = Angle(8 + math.Rand(0, 4), 10 + math.Rand(0, 5), 6 + math.Rand(0, 4))
		ent._spinActive = true

		ent:EmitSound("items/suitchargeok1.wav", 70, 120)
	end)

	net.Receive("Arcana_Enchanter_Withdraw", function(_, ply)
		local ent = net.ReadEntity()
		if not IsValid(ent) or ent:GetClass() ~= "arcana_enchanter" then return end
		local wep = ent:GetContainedWeapon()
		local cls = ent:GetContainedClass()

		if IsValid(wep) then
			wep:SetParent(NULL)
			wep:SetMoveType(MOVETYPE_VPHYSICS)
			wep:SetCollisionGroup(COLLISION_GROUP_NONE)
			wep.ArcanaStored = nil
			wep.ms_notouch = nil
			wep:SetPos(ply:GetPos() + ply:GetForward() * 10 + ply:GetUp() * 40)
			wep:SetAngles(Angle(0, ply:EyeAngles().y, 0))
			wep:SetOwner(ply)

			-- Remove any pre-existing weapon of the same class from the player's inventory
			if cls and cls ~= "" and ply.HasWeapon and ply:HasWeapon(cls) then
				ply:StripWeapon(cls)
			end

			if ply.PickupWeapon then
				ply:PickupWeapon(wep)
			end

			-- Force switch to this weapon
			if cls and cls ~= "" then
				timer.Simple(0, function()
					if IsValid(ply) then ply:SelectWeapon(cls) end
				end)
			end

			ent:SetContainedWeapon(NULL)
			ent:SetContainedClass("")
			ent._containedEnchantIds = nil
			ent:EmitSound("items/smallmedkit1.wav", 70, 115)

			return
		end

		-- Fallback: if entity missing, give fresh
		if cls and cls ~= "" then
			ent:SetContainedClass("")

			-- Remove any pre-existing weapon of the same class first
			if ply:HasWeapon(cls) then
				ply:StripWeapon(cls)
			end

			ply:Give(cls)

			-- Force switch to this weapon after giving
			timer.Simple(0, function()
				if not IsValid(ply) then return end

				local newWep = ply.GetWeapon and ply:GetWeapon(cls) or nil
				if IsValid(newWep) then
					local ids = ent._containedEnchantIds or {}
					for _, id in ipairs(ids) do
						Arcane:ApplyEnchantmentToWeaponEntity(ply, newWep, id, true)
					end

					Arcane:SyncWeaponEnchantNW(newWep)
				end
				ply:SelectWeapon(cls)
			end)

			ent._containedEnchantIds = nil

			ent:EmitSound("items/smallmedkit1.wav", 70, 115)
		end
	end)

	-- Batch apply: aggregate costs, deduct once, then apply all to the held weapon entity
	net.Receive("Arcana_Enchanter_ApplyBatch", function(_, ply)
		local ent = net.ReadEntity()
		local list = net.ReadTable() or {}
		if not IsValid(ent) or ent:GetClass() ~= "arcana_enchanter" then return end

		local cls = ent:GetContainedClass()
		if not cls or cls == "" then return end
		if not istable(list) or #list == 0 then return end

		local wep = ent:GetContainedWeapon()
		if not IsValid(wep) then
			if Arcane and Arcane.SendErrorNotification then
				Arcane:SendErrorNotification(ply, "Deposit a weapon first")
			end

			return
		end

		-- Collect unique enchantments, drop duplicates or ones already present
		local targetCurrent = Arcane and Arcane.GetEntityEnchantments and Arcane:GetEntityEnchantments(wep) or {}
		local selected = {}
		for _, id in ipairs(list) do
			if not targetCurrent[id] then
				selected[id] = true
			end
		end

		-- Enforce cap of 3
		local count = 0
		for _ in pairs(targetCurrent) do
			count = count + 1
		end

		local room = math.max(0, 3 - count)
		local idsOrdered = {}
		for id, _ in pairs(selected) do
			idsOrdered[#idsOrdered + 1] = id
		end

		if #idsOrdered > room then
			-- Trim to available room
			while #idsOrdered > room do
				table.remove(idsOrdered)
			end
		end

		if #idsOrdered == 0 then return end

		-- Validate applicability and aggregate costs
		local enchs = {}
		for _, id in ipairs(idsOrdered) do
			local e = Arcane and Arcane.RegisteredEnchantments and Arcane.RegisteredEnchantments[id]

			if e then
				table.insert(enchs, {
					id = id,
					ench = e
				})
			end
		end

		for _, it in ipairs(enchs) do
			if it.ench.can_apply then
				local ok, reason = pcall(it.ench.can_apply, ply, wep)

				if not ok or reason == false then
					if Arcane and Arcane.SendErrorNotification then
						Arcane:SendErrorNotification(ply, "Cannot apply '" .. tostring(it.id) .. "': " .. tostring(reason or "invalid"))
					end

					return
				end
			end
		end

		local sumCoins = 0
		local itemTotals = {}
		for _, it in ipairs(enchs) do
			sumCoins = sumCoins + (tonumber(it.ench.cost_coins or 0) or 0)

			for _, it2 in ipairs(it.ench.cost_items or {}) do
				local name = tostring(it2.name or "")
				local amt = math.max(1, math.floor(tonumber(it2.amount or 1) or 1))

				if name ~= "" then
					itemTotals[name] = (itemTotals[name] or 0) + amt
				end
			end
		end

		local coins = (ply.GetCoins and ply:GetCoins()) or 0
		if coins < sumCoins then
			if Arcane and Arcane.SendErrorNotification then
				Arcane:SendErrorNotification(ply, "Insufficient coins")
			end

			return
		end

		for name, amt in pairs(itemTotals) do
			local have = (ply.GetItemCount and ply:GetItemCount(name)) or 0

			if have < amt then
				if Arcane and Arcane.SendErrorNotification then
					Arcane:SendErrorNotification(ply, "Missing item: " .. tostring(name))
				end

				return
			end
		end


		-- Deduct currency/items up front
		if sumCoins > 0 and ply.TakeCoins then
			ply:TakeCoins(sumCoins)
		end
		for name, amt in pairs(itemTotals) do
			if ply.TakeItem then ply:TakeItem(name, amt) end
		end

		local chance = ent:ComputeSuccessChance(ply)
		local successes = 0
		for _, it in ipairs(enchs) do
			local hasMana = (ent._receivingUntil or 0) > CurTime()
			if math.Rand(0, 1) <= chance then
				Arcane:ApplyEnchantmentToWeaponEntity(ply, wep, it.id)
				successes = successes + 1
			end
		end

		if successes > 0 then
			ent:EmitSound("ambient/machines/teleport1.wav", 70, 110)
		else
			ent:EmitSound("buttons/button10.wav", 65, 90)
		end

		-- Refresh stored enchantment IDs snapshot on the contained weapon
		if IsValid(wep) then
			local cur = Arcane:GetEntityEnchantments(wep)
			local arr = {}
			for id, _ in pairs(cur or {}) do arr[#arr + 1] = id end
			ent._containedEnchantIds = arr
		end

		-- Particle burst on attempt
		SendEnchantBurst(ent)
	end)

	-- Prevent players from picking up or physgunning weapons stored in the enchanter
	hook.Add("PlayerCanPickupWeapon", "Arcana_BlockPickupStoredWeapon", function(ply, wep)
		if IsValid(wep) and wep.ArcanaStored then return false end
	end)

	hook.Add("PhysgunPickup", "Arcana_BlockPhysgunStoredWeapon", function(ply, ent)
		if IsValid(ent) and ent:IsWeapon() and ent.ArcanaStored then return false end
	end)
end

-- Slow multi-axis spin for contained weapon (server authoritative)
if SERVER then
	function ENT:Think()
		local wep = self:GetContainedWeapon()
		if IsValid(wep) and wep:GetParent() == self and (self._spinActive or false) then
			if not (self._spinStart and self._spinSpeeds and self._spinBaseAng) then
				self._spinStart = CurTime()
				self._spinBaseAng = wep:GetLocalAngles()
				self._spinSpeeds = Angle(8, 10, 6)
			end

			local t = CurTime() - (self._spinStart or CurTime())
			local sp = self._spinSpeeds or Angle(8, 10, 6)
			local base = self._spinBaseAng or Angle(0, 0, 0)
			local ang = Angle(base.p + sp.p * t, base.y + sp.y * t, base.r + sp.r * t)
			wep:SetLocalAngles(ang)
		end

		-- Decay the receiving flag so success falls back to 5%
		if (self._receivingUntil or 0) > 0 and CurTime() > (self._receivingUntil or 0) then
			self._receivingUntil = 0
			if self._receivingMana then
				self._receivingMana = false
				self:SetNWBool("Arcana_ReceivingMana", false)
			end
		end

		self:NextThink(CurTime())
		return true
	end
end

if CLIENT then
	-- Single-model cache for the enchanter outline (model won't change)
	local ENCHANTER_MODEL_HULL2D
	local function Arcana_ComputeModelHull2D(modelName)
		local meshes = util.GetModelMeshes(modelName, 0)
		if not istable(meshes) or #meshes == 0 then return nil end

		local pts = {}
		local cap = 6000
		for _, part in ipairs(meshes) do
			for _, tri in ipairs(part.triangles or {}) do
				local v = tri.pos
				pts[#pts + 1] = Vector(math.Round(v.x, 1), math.Round(v.y, 1), 0)
				if #pts >= cap then break end
			end
			if #pts >= cap then break end
		end

		if #pts < 3 then return nil end

		table.sort(pts, function(a, b)
			if a.x == b.x then return a.y < b.y end
			return a.x < b.x
		end)

		local function cross(o, a, b)
			return (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
		end

		local lower = {}
		for _, p in ipairs(pts) do
			while #lower >= 2 and cross(lower[#lower - 1], lower[#lower], p) <= 0 do
				lower[#lower] = nil
			end
			lower[#lower + 1] = p
		end

		local upper = {}
		for i = #pts, 1, -1 do
			local p = pts[i]
			while #upper >= 2 and cross(upper[#upper - 1], upper[#upper], p) <= 0 do
				upper[#upper] = nil
			end
			upper[#upper + 1] = p
		end

		local hull = {}
		for i = 1, #lower - 1 do hull[#hull + 1] = lower[i] end
		for i = 1, #upper - 1 do hull[#hull + 1] = upper[i] end

		if #hull > 128 then
			local step = math.ceil(#hull / 128)
			local slim = {}
			for i = 1, #hull, step do slim[#slim + 1] = hull[i] end
			hull = slim
		end

		return hull
	end

	-- Particle burst: fast upward particles around enchanter outline on each attempt
	net.Receive("Arcana_Enchanter_ParticleBurst", function()
		local ent = net.ReadEntity()
		if not IsValid(ent) then return end

		local mdl = tostring(ent:GetModel() or "")
		if not ENCHANTER_MODEL_HULL2D then
			ENCHANTER_MODEL_HULL2D = Arcana_ComputeModelHull2D(mdl)
		end

		local emitter = ParticleEmitter(ent:WorldSpaceCenter(), false)
		if not emitter then return end

		local up = Vector(0,0,1)
		local life = 0.30
		local colR, colG, colB = 222, 198, 120

		if istable(ENCHANTER_MODEL_HULL2D) and #ENCHANTER_MODEL_HULL2D >= 3 then
			local countPerEdge = 22
			for i = 1, #ENCHANTER_MODEL_HULL2D do
				local aLocal = ENCHANTER_MODEL_HULL2D[i]
				local bLocal = ENCHANTER_MODEL_HULL2D[(i % #ENCHANTER_MODEL_HULL2D) + 1]
				local a = ent:LocalToWorld(aLocal)
				local b = ent:LocalToWorld(bLocal)
				local edge = (b - a)
				local len = edge:Length()
				if len > 1e-3 then
					local dir = edge * (1 / len)
					local perp = Vector(-dir.y, dir.x, 0)
					for k = 0, countPerEdge do
						local t = k / countPerEdge
						local p0 = a + dir * (len * t)
						local p = p0 + perp * math.Rand(-1.0, 1.0)
						local par = emitter:Add("effects/softglow", p)
						if par then
							par:SetVelocity(up * math.Rand(190, 280))
							par:SetDieTime(life * math.Rand(0.85, 1.05))
							par:SetStartAlpha(235)
							par:SetEndAlpha(0)
							par:SetStartSize(math.Rand(1.4, 2.6))
							par:SetEndSize(0)
							par:SetRoll(math.Rand(0, 360))
							par:SetRollDelta(math.Rand(-160, 160))
							par:SetColor(colR, colG, colB)
							par:SetAirResistance(95)
							par:SetGravity(vector_origin)
							par:SetCollide(false)
							par:SetLighting(false)
						end
					end
				end
			end
		else
			-- Fallback to OBB outline (bottom square)
			local mins, maxs = ent:OBBMins(), ent:OBBMaxs()
			local c = {
				Vector(mins.x, mins.y, 0), Vector(maxs.x, mins.y, 0),
				Vector(maxs.x, maxs.y, 0), Vector(mins.x, maxs.y, 0)
			}
			local countPerEdge = 28
			for i = 1, 4 do
				local a = ent:LocalToWorld(c[i])
				local b = ent:LocalToWorld(c[(i % 4) + 1])
				local edge = (b - a)
				local len = edge:Length()
				if len > 1e-3 then
					local dir = edge * (1 / len)
					local perp = Vector(-dir.y, dir.x, 0)
					for k = 0, countPerEdge do
						local t = k / countPerEdge
						local p0 = a + dir * (len * t)
						local p = p0 + perp * math.Rand(-1.0, 1.0)
						local par = emitter:Add("effects/softglow", p)
						if par then
							par:SetVelocity(up * math.Rand(190, 280))
							par:SetDieTime(life * math.Rand(0.85, 1.05))
							par:SetStartAlpha(235)
							par:SetEndAlpha(0)
							par:SetStartSize(math.Rand(1.4, 2.6))
							par:SetEndSize(0)
							par:SetRoll(math.Rand(0, 360))
							par:SetRollDelta(math.Rand(-160, 160))
							par:SetColor(colR, colG, colB)
							par:SetAirResistance(95)
							par:SetGravity(vector_origin)
							par:SetCollide(false)
							par:SetLighting(false)
						end
					end
				end
			end
		end

		emitter:Finish()
	end)

	-- Create band rings that spin around the deposited weapon
	function ENT:ClientInitBandVis()
		if self._bandCircle and self._bandCircle.IsActive and self._bandCircle:IsActive() then return end

		local wep = self:GetContainedWeapon()
		if not IsValid(wep) then return end
		if not _G.BandCircle then return end

		local pos = wep:WorldSpaceCenter()
		local ang = self:GetAngles()
		local color = Color(222, 198, 120, 255)
		local bc = BandCircle.Create(pos, ang, color, 80)
		if not bc then return end

		local mins, maxs = wep:OBBMins(), wep:OBBMaxs()
		local size = (maxs - mins):Length()
		local baseR = math.max(12, size * 0.25)
		local h = math.max(2, baseR * 0.18)

		-- A few elegant, slow bands with different spin axes
		bc:AddBand(baseR * 0.9, h, {p = 0, y = 28, r = 0}, 2)
		bc:AddBand(baseR * 0.72, h * 0.9, {p = 22, y = -18, r = 0}, 2)
		bc:AddBand(baseR * 1.08, h * 0.75, {p = 0, y = 0, r = 32}, 2)
		bc:AddBand(baseR * 1.32, h * 0.75, {p = -26, y = 0, r = 28}, 2)

		for i, r in ipairs(bc.rings or {}) do
			r.zBias = (i - 1) * 0.25
		end

		self._bandCircle = bc
	end

	function ENT:ClientCleanupBandVis()
		if self._bandCircle then
			local bc = self._bandCircle
			self._bandCircle = nil
			if bc.Remove then bc:Remove() end
		end
	end

	-- Keep the band circle following the weapon
	function ENT:Think()
		local wep = self:GetContainedWeapon()
		if IsValid(wep) then
			if not (self._bandCircle and self._bandCircle.IsActive and self._bandCircle:IsActive()) then
				self:ClientInitBandVis()
			end
			if self._bandCircle then
				self._bandCircle.position = wep:WorldSpaceCenter()
				self._bandCircle.angles = self:GetAngles()
			end
		else
			self:ClientCleanupBandVis()
		end
	end

	function ENT:OnRemove()
		self:ClientCleanupBandVis()
	end

	-- Minimal styling reuse from altar
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

	local decoBg = Color(26, 20, 14, 235)
	local decoPanel = Color(32, 24, 18, 235)
	local gold = Color(198, 160, 74, 255)
	local textBright = Color(236, 230, 220, 255)
	local paleGold = Color(222, 198, 120, 255)
	-- Blur helper (same as grimoire menu)
	local blurMat = Material("pp/blurscreen")

	local function Arcana_DrawBlurRect(x, y, w, h, layers, density)
		surface.SetMaterial(blurMat)
		surface.SetDrawColor(255, 255, 255)
		render.SetScissorRect(x, y, x + w, y + h, true)

		for i = 1, (layers or 4) do
			blurMat:SetFloat("$blur", (i / (layers or 4)) * (density or 8))
			blurMat:Recompute()
			render.UpdateScreenEffectTexture()
			surface.DrawTexturedRect(0, 0, ScrW(), ScrH())
		end

		render.SetScissorRect(0, 0, 0, 0, false)
	end

	-- UI-only glyph helpers to enrich the circle visuals (standalone from circles.lua)
	local GREEK_PHRASES = {"αβραξαςαβραξαςαβραξαςαβραξαςαβραξαςαβραξας", "θεοσγνωσιςφωςζωηαληθειακοσμοςψυχηπνευμα", "αρχηκαιτελοςαρχηκαιτελοςαρχηκαιτελος",}

	local ARABIC_PHRASES = {"بسماللهالرحمنالرحيمبسماللهالرحمنالرحيم", "اللهنورسماواتوالارضاللهنورسماواتوالارض", "سبحاناللهوبحمدهسبحاناللهالعظيمسبحانالله",}

	local GLYPH_PHRASES = {}

	for _, p in ipairs(GREEK_PHRASES) do
		table.insert(GLYPH_PHRASES, p)
	end

	for _, p in ipairs(ARABIC_PHRASES) do
		table.insert(GLYPH_PHRASES, p)
	end

	local UI_GLYPH_CACHE = {}
	local function UI_GetGlyphMaterial(fontName, char)
		local key = (fontName or "") .. ":" .. (char or "")
		local cached = UI_GLYPH_CACHE[key]
		if cached then return cached.mat, cached.w, cached.h end
		surface.SetFont(fontName or "DermaDefault")
		local w, h = surface.GetTextSize(char)
		w = math.max(1, math.floor(w + 2))
		h = math.max(1, math.floor(h + 2))
		local id = util.CRC and util.CRC(key) or tostring(key):gsub("%W", "")
		local rtName = "arcana_ui_glyph_rt_" .. id
		local tex = GetRenderTarget(rtName, w, h, true)
		local matName = "arcana_ui_glyph_mat_" .. id

		local mat = CreateMaterial(matName, "UnlitGeneric", {
			["$basetexture"] = tex:GetName(),
			["$translucent"] = 1,
			["$vertexalpha"] = 1,
			["$vertexcolor"] = 1,
			["$nolod"] = 1,
		})

		render.PushRenderTarget(tex)
		render.Clear(0, 0, 0, 0, true, true)
		cam.Start2D()
		surface.SetFont(fontName or "DermaDefault")
		surface.SetTextColor(255, 255, 255, 255)
		surface.SetTextPos(1, 1)
		surface.DrawText(char)
		cam.End2D()
		render.PopRenderTarget()

		UI_GLYPH_CACHE[key] = {
			mat = mat,
			w = w,
			h = h
		}

		return mat, w, h
	end

	local function UI_DrawGlyphRing(cx, cy, radius, fontName, phrase, scaleMul, count, col, rotOffset)
		phrase = tostring(phrase or "MAGIC")
		local chars = {}

		for _, code in utf8.codes(phrase) do
			chars[#chars + 1] = utf8.char(code)
		end

		if #chars == 0 then
			chars = {"*"}
		end

		local num = math.max(12, count or 36)
		local step = (math.pi * 2) / num
		local drawCol = col or Color(220, 200, 150, 235)
		surface.SetDrawColor(drawCol.r, drawCol.g, drawCol.b, drawCol.a)
		local ro = tonumber(rotOffset) or 0

		for i = 1, num do
			local ch = chars[((i - 1) % #chars) + 1]
			local mat, gw, gh = UI_GetGlyphMaterial(fontName or "DermaDefault", ch)
			local ang = -math.pi / 2 + i * step + ro
			local px = cx + math.cos(ang) * radius
			local py = cy + math.sin(ang) * radius
			local rot = math.deg(ang + math.pi * 0.5)
			local s = (scaleMul or 0.6)
			local w = math.max(1, gw * s)
			local h = math.max(1, gh * s)
			surface.SetMaterial(mat)
			surface.DrawTexturedRectRotated(px, py, w, h, rot)
		end
	end

	local function UI_DrawMinorTicks(cx, cy, radiusOuter, radiusInner, count, col)
		surface.SetDrawColor((col and col.r) or 200, (col and col.g) or 180, (col and col.b) or 140, (col and col.a) or 220)
		local n = math.max(1, count or 32)
		local step = (math.pi * 2) / n

		for i = 0, n - 1 do
			local a = -math.pi / 2 + i * step
			local x1 = cx + math.cos(a) * radiusOuter
			local y1 = cy + math.sin(a) * radiusOuter
			local x2 = cx + math.cos(a) * radiusInner
			local y2 = cy + math.sin(a) * radiusInner
			surface.DrawLine(x1, y1, x2, y2)
		end
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

	local function Arcana_DrawDecoFrame(x, y, w, h, col, corner)
		local c = math.max(8, corner or 12)
		surface.SetDrawColor(col.r, col.g, col.b, col.a or 255)
		surface.DisableClipping(true)
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

	local function getEnchantmentsList()
		return Arcane and Arcane.RegisteredEnchantments or {}
	end

	local function OpenEnchanterMenu(machine)
		local ply = LocalPlayer()
		if not IsValid(ply) then return end
		local frame = vgui.Create("DFrame")
		frame:SetSize(980, 600)
		frame:Center()
		frame:SetTitle("")
		frame:MakePopup()

		-- Screen-space blur behind frame (like grimoire)
		hook.Add("HUDPaint", frame, function()
			local x, y = frame:LocalToScreen(0, 0)
			Arcana_DrawBlurRect(x, y, frame:GetWide(), frame:GetTall(), 4, 8)
		end)

		-- Style close button like the rest of the UI
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
				surface.SetDrawColor(gold)
				local pad = 8
				surface.DrawLine(pad, pad, w - pad, h - pad)
				surface.DrawLine(w - pad, pad, pad, h - pad)
			end
		end

		frame.Paint = function(pnl, w, h)
			Arcana_FillDecoPanel(6, 6, w - 12, h - 12, decoBg, 14)
			Arcana_DrawDecoFrame(6, 6, w - 12, h - 12, gold, 14)
			draw.SimpleText(string.upper("Enchanter"), "Arcana_AncientLarge", 18, 10, paleGold)
		end

		if IsValid(frame.btnMinim) then
			frame.btnMinim:Hide()
		end

		if IsValid(frame.btnMaxim) then
			frame.btnMaxim:Hide()
		end

		local content = vgui.Create("DPanel", frame)
		content:Dock(FILL)
		content:DockMargin(12, 12, 12, 12)
		content.Paint = nil
		-- Selected enchantments (ids) available to all child builders
		local selected = {}
		-- Selection totals (for progress bars)
		local needCoins, needShards = 0, 0
		local function computeTotals()
			needCoins, needShards = 0, 0
			for id, on in pairs(selected) do
				if on then
					local e = Arcane and Arcane.RegisteredEnchantments and Arcane.RegisteredEnchantments[id]
					if e then
						needCoins = needCoins + (tonumber(e.cost_coins or 0) or 0)
						for _, it in ipairs(e.cost_items or {}) do
							local name = tostring(it.name or "")
							local amt = math.max(1, math.floor(tonumber(it.amount or 1) or 1))
							if name == "mana_crystal_shard" then
								needShards = needShards + amt
							end
						end
					end
				end
			end
		end

		-- Track applied enchantment set to refresh UI when it changes
		local lastAppliedStr = ""
		local function getAppliedStr()
			local wepEnt = (IsValid(machine) and machine.GetContainedWeapon and machine:GetContainedWeapon()) or NULL
			if not IsValid(wepEnt) then return "" end
			return wepEnt:GetNWString("Arcana_EnchantIds", "") or ""
		end

		-- Forward declaration so Think can trigger a rebuild
		local rebuild

		-- Top bars panel
		local topBars = vgui.Create("DPanel", content)
		topBars:Dock(TOP)
		topBars:SetTall(84)
		topBars:DockMargin(0, 0, 0, 8)

		topBars.Paint = function(pnl, w, h)
			Arcana_FillDecoPanel(4, 0, w - 8, h, decoPanel, 12)
			Arcana_DrawDecoFrame(4, 0, w - 8, h, gold, 12)
			-- Gather player amounts
			local haveCoins = (IsValid(ply) and ply.GetCoins and ply:GetCoins()) or 0
			local haveShards = (IsValid(ply) and ply.GetItemCount and ply:GetItemCount("mana_crystal_shard")) or 0

			-- Draw helper
			local function drawBar(x, y, bw, bh, label, have, need, fillCol)
				local innerPad = 8
				-- Label
				draw.SimpleText(label, "Arcana_Ancient", x + innerPad, y + 4, textBright)
				-- Bar geometry
				local labelH = draw.GetFontHeight("Arcana_Ancient") + 2
				local barY = y + labelH
				local barH = math.max(10, bh - labelH - 8)
				local barW = bw - innerPad * 2
				-- Bar frame + background
				surface.SetDrawColor(46, 36, 26, 235)
				surface.DrawRect(x + innerPad, barY, barW, barH)
				-- Fill
				local needSafe = math.max(1, math.floor(need))
				local haveClamped = math.min(have, needSafe)
				local frac = math.Clamp(haveClamped / needSafe, 0, 1)
				surface.SetDrawColor(fillCol)
				surface.DrawRect(x + innerPad + 2, barY + 2, math.floor((barW - 4) * frac), barH - 4)
				surface.SetDrawColor(gold)
				surface.DrawOutlinedRect(x + innerPad, barY, barW, barH)
				-- Text right-aligned
				local txt = string.format("%s / %s", string.Comma(haveClamped), string.Comma(needSafe))
				surface.SetFont("Arcana_AncientSmall")
				local tw, _ = surface.GetTextSize(txt)
				draw.SimpleText(txt, "Arcana_AncientSmall", x + bw - innerPad - tw, barY - 15, textBright)
			end

			local pad = 2
			local bw = w - pad * 2
			local eachH = math.floor((h - pad * 3) * 0.5)
			drawBar(pad, pad, bw, eachH, "Coins", haveCoins, needCoins, Color(210, 182, 100, 220))
			drawBar(pad, pad * 2 + eachH, bw, eachH, "Crystal Shards", haveShards, needShards, Color(105, 180, 255, 220))
		end

		-- Left: Engraved circle with weapon model/name + controls
		local left = vgui.Create("DPanel", content)
		left:Dock(LEFT)
		left:SetWide(520)

		left.Paint = function(pnl, w, h)
			Arcana_FillDecoPanel(4, 4, w - 8, h - 8, decoPanel, 12)
			Arcana_DrawDecoFrame(4, 4, w - 8, h - 8, gold, 12)

			-- Engraved circle background (non-pentagram)
			local cx, cy = w * 0.5, h * 0.44
			local radius = math.min(w, h) * 0.36

			-- Stone base
			draw.NoTexture()
			surface.DisableClipping(true)
			surface.SetDrawColor(36, 28, 22, 240)
			surface.DrawCircle(cx, cy, radius, 80, 70, 60, 245)

			-- Soft inner disc for contrast
			for r = radius, radius - 6, -1 do
				surface.DrawCircle(cx, cy, r, 90, 80, 70, 200)
			end

			-- Outer engraved rings
			local function thickCircle(r, t)
				for i = 0, t do
					surface.DrawCircle(cx, cy, r - i, 200, 180, 140, 255)
				end
			end

			thickCircle(radius - 8, 1)
			thickCircle(radius * 0.82, 1)
			thickCircle(radius * 0.64, 1)

			-- Helpers
			local function pnt(a, r)
				return cx + math.cos(a) * r, cy + math.sin(a) * r
			end

			-- Radial ticks
			surface.SetDrawColor(180, 160, 120, 200)

			for i = 0, 11 do
				local ang = i * (math.pi * 2 / 12)
				local x1, y1 = pnt(ang, radius * 0.90)
				local x2, y2 = pnt(ang, radius * 0.84)
				surface.DrawLine(x1, y1, x2, y2)
			end

			-- Fine ticks between main ticks (keep within outer band)
			UI_DrawMinorTicks(cx, cy, radius * 0.89, radius * 0.865, 48, Color(200, 180, 140, 160))

			-- Engraved glyph rings (slow counter-rotation)
			local t = CurTime()

			-- Outer glyph band (slightly larger for breathing room)
			local bandOuterMid = radius * 0.755
			local bandOuterIn = radius * 0.72
			local bandOuterOut = radius * 0.79
			thickCircle(bandOuterOut, 1)
			thickCircle(bandOuterIn, 1)
			local phraseOuter = GREEK_PHRASES[1 + (math.floor(t * 0.02) % #GREEK_PHRASES)]
			UI_DrawGlyphRing(cx, cy, bandOuterMid, "MagicCircle_Small", phraseOuter, 0.30, 64, Color(220, 200, 150, 235), t * 0.08)

			-- Inner glyph band (slightly larger)
			local bandInnerMid = radius * 0.585
			local bandInnerIn = radius * 0.56
			local bandInnerOut = radius * 0.61
			thickCircle(bandInnerOut, 1)
			thickCircle(bandInnerIn, 1)
			local phraseInner = ARABIC_PHRASES[1 + (math.floor(t * 0.015 + 1) % #ARABIC_PHRASES)]
			UI_DrawGlyphRing(cx, cy, bandInnerMid, "MagicCircle_Small", phraseInner, 0.26, 48, Color(220, 200, 150, 210), -t * 0.06)

			surface.DisableClipping(false)
		end

		-- Weapon model preview centered in the circle
		local modelPanel = vgui.Create("DModelPanel", left)
		modelPanel:SetSize(360, 360)
		modelPanel:SetMouseInputEnabled(false)

		function modelPanel:LayoutEntity(ent)
			ent:SetAngles(Angle(0, CurTime() * 15 % 360, 0))
		end

		local nameLabel = vgui.Create("DLabel", left)
		nameLabel:SetText("")
		nameLabel:SetFont("Arcana_Ancient")
		nameLabel:SetTextColor(textBright)
		nameLabel:SetContentAlignment(5)

		-- Compact success indicator at top-left above the circle
		local successBadge = vgui.Create("DPanel", left)
		successBadge:SetSize(110, 50)
		successBadge:SetPos(12, 12)
		successBadge.Paint = function(pnl, w, h)
			if not IsValid(machine) then return end

			-- Compute chance (client mirrors server logic; scales with player level when receiving)
			local lp = LocalPlayer()
			local chance = machine:ComputeSuccessChance(lp) or 0.05

			-- Badge background
			Arcana_FillDecoPanel(0, 0, w, h, Color(46, 36, 26, 235), 8)
			Arcana_DrawDecoFrame(0, 0, w, h, gold, 8)

			-- Left: small ring arc gauge
			local cx, cy = 20, h * 0.5
			local r = 12
			surface.SetDrawColor(gold)
			local steps = 22
			local frac = math.Clamp(chance, 0, 1)
			local sweep = frac * (math.pi * 1.8)
			local px, py
			for i = 0, steps do
				local a = -math.pi * 0.9 + (i / steps) * sweep
				local x = cx + math.cos(a) * r
				local y = cy + math.sin(a) * r
				if i > 0 then surface.DrawLine(px, py, x, y) end
				px, py = x, y
			end

			-- Right: percentage text
			local pct = math.floor(frac * 100 + 0.5)
			draw.SimpleText("SUCCESS", "Arcana_AncientSmall", 40, 6, paleGold)
			draw.SimpleText(pct .. "%", "Arcana_AncientLarge", 40, h - 8, textBright, TEXT_ALIGN_LEFT, TEXT_ALIGN_BOTTOM)
		end

		-- Controls area
		local controls = vgui.Create("DPanel", left)
		controls:Dock(BOTTOM)
		controls:SetTall(70)
		controls.Paint = function(pnl, w, h) end -- background intentionally empty (parent frame provides style)

		-- Forward declaration for preview setter used below
		local setPreviewForClass

		-- Selected enchantments (ids) available to all child builders
		-- (declared above)
		local function hasSelection()
			for _, v in pairs(selected) do
				if v then return true end
			end

			return false
		end

		-- Forward declare enchant button so earlier references are safe
		local enchantBtn
		-- One toggle button: Deposit / Withdraw
		local toggleBtn = vgui.Create("DButton", controls)
		toggleBtn:SetSize(220, 36)
		toggleBtn:SetPos(20, 16)
		toggleBtn:SetText("")

		local function updateToggle()
			local cls = IsValid(machine) and machine:GetContainedClass() or ""
			toggleBtn._mode = (cls == "" and "deposit") or "withdraw"
		end

		function toggleBtn:Paint(w, h)
			updateToggle()
			local hovered = self:IsHovered()
			local bgCol = hovered and Color(58, 44, 32, 235) or Color(46, 36, 26, 235)
			Arcana_FillDecoPanel(0, 0, w, h, bgCol, 8)
			Arcana_DrawDecoFrame(0, 0, w, h, gold, 8)
			local label = (self._mode == "deposit") and "Deposit" or "Withdraw"
			draw.SimpleText(label, "Arcana_AncientLarge", w * 0.5, h * 0.5, textBright, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		end

		function toggleBtn:DoClick()
			updateToggle()

			if self._mode == "deposit" then
				net.Start("Arcana_Enchanter_Deposit")
				net.WriteEntity(machine)
				net.SendToServer()
			else
				net.Start("Arcana_Enchanter_Withdraw")
				net.WriteEntity(machine)
				net.SendToServer()
			end

			surface.PlaySound("buttons/button6.wav")

			-- After deposit/withdraw, recalc totals and refresh buttons
			timer.Simple(0.05, function()
				if IsValid(machine) then
					computeTotals()
					topBars:InvalidateLayout(true)
				end

				if IsValid(enchantBtn) and IsValid(machine) then
					enchantBtn:SetEnabled((machine:GetContainedClass() or "") ~= "" and hasSelection())
				end
			end)
		end

		-- Enchant Selected button
		enchantBtn = vgui.Create("DButton", controls)
		enchantBtn:SetSize(220, 36)
		enchantBtn:SetPos(250, 16)
		enchantBtn:SetText("")

		local function refreshButtons()
			local cls = IsValid(machine) and machine:GetContainedClass() or ""
			enchantBtn:SetEnabled((cls ~= "") and hasSelection())
		end

		enchantBtn.Paint = function(pnl, w, h)
			local enabled = pnl:IsEnabled()
			local hovered = enabled and pnl:IsHovered()
			local bg = hovered and Color(58, 44, 32, 235) or Color(46, 36, 26, 235)
			Arcana_FillDecoPanel(0, 0, w, h, bg, 8)
			local frameCol = enabled and gold or Color(140, 120, 90, 255)
			Arcana_DrawDecoFrame(0, 0, w, h, frameCol, 8)
			draw.SimpleText("Enchant", "Arcana_AncientLarge", w * 0.5, h * 0.5, enabled and textBright or Color(200, 190, 170, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		end

		enchantBtn.DoClick = function()
			if not enchantBtn:IsEnabled() then
				surface.PlaySound("buttons/button8.wav")

				return
			end

			local ids = {}

			for id, on in pairs(selected) do
				if on then
					table.insert(ids, id)
				end
			end

			net.Start("Arcana_Enchanter_ApplyBatch")
			net.WriteEntity(machine)
			net.WriteTable(ids)
			net.SendToServer()
			surface.PlaySound("buttons/button14.wav")
		end

		-- Make buttons fill the parent width with consistent padding
		controls.PerformLayout = function(pnl, w, h)
			local pad = 20
			local gap = 10
			local top = 16
			local bw = math.max(80, math.floor(w - pad * 2 - gap))
			bw = math.floor(bw * 0.5)
			toggleBtn:SetSize(bw, 36)
			toggleBtn:SetPos(pad, top)
			enchantBtn:SetSize(bw, 36)
			enchantBtn:SetPos(pad + bw + gap, top)
		end

		-- Helper to derive model and name from weapon class
		setPreviewForClass = function(cls)
			if not cls or cls == "" then
				modelPanel:SetVisible(false)
				nameLabel:SetText("No weapon")

				return
			end

			modelPanel:SetVisible(true)
			local swep = weapons.GetStored(cls) or list.Get("Weapon")[cls]
			local model = (swep and (swep.WorldModel or swep.ViewModel)) or "models/weapons/w_pistol.mdl"
			local nice = (swep and (swep.PrintName or swep.Printname)) or cls
			modelPanel:SetModel(model)
			nameLabel:SetText(nice)
			-- Camera setup
			local ent = modelPanel:GetEntity()

			if IsValid(ent) then
				local mn, mx = ent:GetRenderBounds()
				local size = (mx - mn):Length()
				modelPanel:SetFOV(32)
				modelPanel:SetCamPos(Vector(size, size, size * 0.5))
				modelPanel:SetLookAt((mn + mx) * 0.5)
			end
		end

		-- Position the model and name inside left panel (centered in the circle)
		left.PerformLayout = function(pnl, w, h)
			local cx, cy = w * 0.5, h * 0.44
			local radius = math.min(w, h) * 0.36
			local s = math.floor(radius * 1.5)
			modelPanel:SetSize(s, s)
			modelPanel:SetPos(math.floor(cx - s * 0.5), math.floor(cy - s * 0.5))
			nameLabel:SetSize(math.floor(w * 0.6), 24)
			nameLabel:SetPos(math.floor(cx - nameLabel:GetWide() * 0.5), math.floor(cy + radius + 8))
		end

		-- Initialize preview and keep it updated
		setPreviewForClass(IsValid(machine) and machine:GetContainedClass() or "")
		computeTotals()
		topBars:InvalidateLayout(true)
		refreshButtons()

		frame.Think = function()
			if not IsValid(machine) then
				frame:Close()

				return
			end

			local cls = machine:GetContainedClass() or ""

			if (modelPanel._cls or "") ~= cls then
				modelPanel._cls = cls
				setPreviewForClass(cls)
				computeTotals()
				topBars:InvalidateLayout(true)
				refreshButtons()
			end

			-- Refresh right panel rows if the applied set changed on the contained weapon
			local curStr = getAppliedStr()
			if curStr ~= (lastAppliedStr or "") then
				lastAppliedStr = curStr
				if rebuild then rebuild() end
				computeTotals()
				topBars:InvalidateLayout(true)
				refreshButtons()
			end
		end

		-- Right: enchantment list
		local right = vgui.Create("DPanel", content)
		right:Dock(FILL)

		right.Paint = function(pnl, w, h)
			Arcana_FillDecoPanel(4, 4, w - 8, h - 8, decoPanel, 12)
			Arcana_DrawDecoFrame(4, 4, w - 8, h - 8, gold, 12)
			draw.SimpleText(string.upper("Enchantments"), "Arcana_Ancient", 14, 10, paleGold)
		end

		local scroll = vgui.Create("DScrollPanel", right)
		scroll:Dock(FILL)
		scroll:DockMargin(12, 36, 12, 12)
		local vbar = scroll:GetVBar()
		vbar:SetWide(8)

		vbar.Paint = function(pnl, w, h)
			Arcana_FillDecoPanel(0, 0, w, h, decoPanel, 8)
			Arcana_DrawDecoFrame(0, 0, w, h, gold, 8)
		end

		vbar.btnGrip.Paint = function(pnl, w, h)
			surface.SetDrawColor(gold)
			surface.DrawRect(0, 0, w, h)
		end

		rebuild = function()
			scroll:Clear()

			-- Determine currently applied enchantments on the contained weapon entity
			local appliedSet = {}
			local appliedCount = 0
			local wepEnt = (IsValid(machine) and machine.GetContainedWeapon and machine:GetContainedWeapon()) or NULL
			if IsValid(wepEnt) then
				local json = wepEnt:GetNWString("Arcana_EnchantIds", "[]")
				local ok, arr = pcall(util.JSONToTable, json)
				if ok and istable(arr) then
					for _, id in ipairs(arr) do
						appliedSet[id] = true
						appliedCount = appliedCount + 1
					end
				end
			end

			-- Clear selections that have just become applied so UI/state stays consistent
			for id, on in pairs(selected) do
				if on and appliedSet[id] then
					selected[id] = nil
				end
			end

			-- Build visible list filtered by can_apply for the deposited weapon (if any)
			local visible = {}
			for enchId, ench in pairs(getEnchantmentsList()) do
				local show = true
				if IsValid(wepEnt) and not appliedSet[enchId] then
					if ench and ench.can_apply then
						local ok, res = pcall(ench.can_apply, ply, wepEnt)
						show = ok and (res ~= false)
					end
				end

				if show then
					visible[enchId] = true
					local row = vgui.Create("DButton", scroll)
					row:Dock(TOP)
					row:SetTall(64)
					row:DockMargin(0, 0, 0, 8)
					row:SetText("")
					row._id = enchId
					row._applied = appliedSet[enchId] and true or false
					row._selected = (not row._applied) and (selected[enchId] and true or false) or false
					row.Paint = function(pnl, w, h)
						local isApplied = pnl._applied
						local bg
						if isApplied then
							bg = Color(36, 54, 64, 235) -- frosty blue for applied
						elseif pnl._selected then
							bg = Color(58, 44, 32, 235)
						else
							bg = Color(46, 36, 26, 235)
						end
						Arcana_FillDecoPanel(2, 2, w - 4, h - 4, bg, 8)
						local frameCol = (isApplied and Color(150, 200, 240, 255)) or (pnl._selected and textBright) or gold
						Arcana_DrawDecoFrame(2, 2, w - 4, h - 4, frameCol, 8)
						draw.SimpleText(ench.name or enchId, "Arcana_AncientLarge", 36, 8, textBright)
						if isApplied then
							draw.SimpleText("Already applied", "Arcana_AncientSmall", w - 12, 10, Color(180, 220, 255, 255), TEXT_ALIGN_RIGHT)
						end
					end

					row.DoClick = function(pnl)
						if pnl._applied then
							surface.PlaySound("buttons/button8.wav")
							return
						end

						local newState = not pnl._selected

						-- Enforce cap: appliedCount + (#selected on) + (newState and 1 or 0) <= 3
						local selCount = 0
						for _, on in pairs(selected) do
							if on then
								selCount = selCount + 1
							end
						end

						if newState and (appliedCount + selCount + 1) > 3 then
							surface.PlaySound("buttons/button8.wav")
							return
						end

						pnl._selected = newState
						selected[enchId] = pnl._selected or nil
						computeTotals()
						topBars:InvalidateLayout(true)
						topBars:InvalidateParent(true)
						refreshButtons()
						pnl:InvalidateLayout(true)
					end

					-- Info tooltip icon
					local infoIcon = vgui.Create("DPanel", row)
					infoIcon:SetSize(20, 20)
					infoIcon:SetCursor("hand")
					infoIcon.Paint = function(pnl, w, h)
						surface.SetDrawColor(gold)
						local cx, cy, r = w * 0.5, h * 0.5, 8
						local seg = 16
						for i = 0, seg - 1 do
							local a1 = (i / seg) * math.pi * 2
							local a2 = ((i + 1) / seg) * math.pi * 2
							surface.DrawLine(cx + math.cos(a1) * r, cy + math.sin(a1) * r, cx + math.cos(a2) * r, cy + math.sin(a2) * r)
						end
						draw.SimpleText("i", "Arcana_Ancient", cx, cy, gold, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
					end

					-- Tooltip behavior
					infoIcon.OnCursorEntered = function()
						if IsValid(infoIcon.tooltip) then return end

						local tooltip = vgui.Create("DLabel")
						tooltip:SetSize(320, 64)
						tooltip:SetWrap(true)
						tooltip:SetText(ench.description or "No description available")
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
						local function updateTooltipPos()
							if not IsValid(tooltip) then return end
							local x, y = gui.MousePos()
							tooltip:SetPos(x + 15, y - 30)
						end

						updateTooltipPos()
						hook.Add("Think", "ArcanaTooltipPos_" .. tostring(tooltip), function()
							if not IsValid(tooltip) then
								hook.Remove("Think", "ArcanaTooltipPos_" .. tostring(tooltip))
								return
							end

							if not IsValid(infoIcon) then
								if IsValid(tooltip) then
									tooltip:Remove()
								end

								hook.Remove("Think", "ArcanaTooltipPos_" .. tostring(tooltip))
								return
							end

							updateTooltipPos()
						end)
					end

					infoIcon.OnCursorExited = function()
						local t = infoIcon.tooltip
						if IsValid(t) then
							hook.Remove("Think", "ArcanaTooltipPos_" .. tostring(t))
							t:Remove()
							infoIcon.tooltip = nil
						end
					end

					-- Plain cost text under the name
					local costLbl = vgui.Create("DLabel", row)
					costLbl:SetFont("Arcana_AncientSmall")
					costLbl:SetTextColor(Color(180, 170, 150, 255))
					local parts = {}
					local coinAmt = tonumber(ench.cost_coins or 0) or 0
					if coinAmt > 0 then
						parts[#parts + 1] = ("x" .. string.Comma(coinAmt) .. " coins")
					end

					for _, it2 in ipairs(ench.cost_items or {}) do
						local name = tostring(it2.name or "item")
						local amt = math.max(1, math.floor(tonumber(it2.amount or 1) or 1))
						local pretty = name
						if _G.msitems and _G.msitems.GetInventoryInfo then
							local info = _G.msitems.GetInventoryInfo(name)
							if info and info.name then
								pretty = string.lower(info.name)
							end
						elseif name == "mana_crystal_shard" then
							pretty = "crystal shards"
						end
						parts[#parts + 1] = (string.Comma(amt) .. " " .. pretty)
					end

					costLbl:SetText(table.concat(parts, " | "))
					costLbl:SizeToContents()
					row.PerformLayout = function(pnl, w, h)
						-- Position info icon right after the enchant name
						surface.SetFont("Arcana_AncientLarge")
						local nameW, _ = surface.GetTextSize(ench.name or enchId)
						local nameX = 36
						infoIcon:SetPos(nameX + nameW + 8, 10)
						-- Costs under the name
						costLbl:SetPos(nameX, h - 24)
					end
				end
			end

			-- Prune any previously selected enchantments that are not visible for this weapon
			for id, on in pairs(selected) do
				if on and not visible[id] then
					selected[id] = nil
				end
			end
			computeTotals()
			topBars:InvalidateLayout(true)
		end

		rebuild()
	end

	net.Receive("Arcana_OpenEnchanterMenu", function()
		local ent = net.ReadEntity()

		if IsValid(ent) then
			OpenEnchanterMenu(ent)
		end
	end)
end


function ENT:ComputeSuccessChance(ply)
	-- Determine if currently receiving mana; client mirrors via NWBool
	local receiving = self:GetNWBool("Arcana_ReceivingMana", false) or ((self._receivingUntil or 0) > CurTime())
	local base = receiving and 0.25 or 0.05

	-- Only scale while receiving mana
	if not receiving then
		return base
	end

	-- Scale from base (25%) up to 80% at max Arcane level
	local playerLevel = ply:GetArcaneLevel() or 0
	local maxLevel = ((Arcane.Config and Arcane.Config.MAX_LEVEL) or 100) / 1.75
	local t = math.Clamp(playerLevel / math.max(1, maxLevel), 0, 1)
	local maxCap = 0.80
	local chance = base + (maxCap - base) * t
	return math.Clamp(chance, 0, maxCap)
end

if SERVER then
	-- Called by ManaNetwork to signal mana receive
	function ENT:AddMana(_amount)
		-- Treat any positive call as a pulse of receiving state
		self._receivingUntil = CurTime() + 0.6
		self._receivingMana = true
		self:SetNWBool("Arcana_ReceivingMana", true)
		return _amount or 0
	end
end