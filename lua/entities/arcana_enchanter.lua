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
	util.AddNetworkString("Arcana_Enchanter_ManaFlow")

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

		local swep = list.Get("Weapon")[cls]
		if not swep.Spawnable then return end

		local isAdmin = ply:IsAdmin() or game.SinglePlayer()
		if (not swep.Spawnable and not isAdmin) or (swep.AdminOnly and not isAdmin) then return end
		if not gamemode.Call("PlayerGiveSWEP", ply, cls, swep) then return end

		-- Capture existing enchantments on player's weapon
		local transferIds = {}
		local map = Arcana:GetEntityEnchantments(orig)
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
			Arcana:ApplyEnchantmentToWeaponEntity(ply, wep, id, true)
		end

		Arcana.SyncWeaponEnchantNW(wep)

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
					Arcana:ApplyEnchantmentToWeaponEntity(ply, newWep, id, true)
				end

			Arcana.SyncWeaponEnchantNW(newWep)
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
			if Arcana.SendErrorNotification then
				Arcana:SendErrorNotification(ply, "Deposit a weapon first")
			end

			return
		end

		-- Collect unique enchantments, drop duplicates or ones already present
		local targetCurrent = Arcana.GetEntityEnchantments and Arcana:GetEntityEnchantments(wep) or {}
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
			local e = Arcana.RegisteredEnchantments and Arcana.RegisteredEnchantments[id]

			if e then
				table.insert(enchs, {
					id = id,
					ench = e
				})
			end
		end

		for _, it in ipairs(enchs) do
			if it.ench.can_apply then
				local callOk, allowed, reason = pcall(it.ench.can_apply, ply, wep)

				if not callOk or allowed == false then
					if Arcana.SendErrorNotification then
						local msg = callOk and tostring(reason or "weapon not eligible") or tostring(allowed)
						Arcana:SendErrorNotification(ply, "Cannot apply '" .. tostring(it.id) .. "': " .. msg)
					end

					return
				end
			end
		end

		local sumCoins = 0
		local itemTotals = {}
		for _, it in ipairs(enchs) do
			sumCoins = sumCoins + (tonumber(it.ench.cost_coins) or 0)

			for _, it2 in ipairs(it.ench.cost_items or {}) do
				local name = tostring(it2.name or "")
				local amt = math.max(1, math.floor(tonumber(it2.amount) or 1))

				if name ~= "" then
					itemTotals[name] = (itemTotals[name] or 0) + amt
				end
			end
		end

		local coins = Arcana:GetCoins(ply)
		if coins < sumCoins then
			if Arcana.SendErrorNotification then
				Arcana:SendErrorNotification(ply, "Insufficient coins")
			end

			return
		end

		for name, amt in pairs(itemTotals) do
			local have = Arcana:GetItemCount(ply, name)

			if have < amt then
				if Arcana.SendErrorNotification then
					Arcana:SendErrorNotification(ply, "Missing item: " .. tostring(name))
				end

				return
			end
		end


		-- Deduct currency/items up front
		if sumCoins > 0 then
			Arcana:TakeCoins(ply, sumCoins)
		end
		for name, amt in pairs(itemTotals) do
			Arcana:TakeItem(ply, name, amt)
		end

		local chance = ent:ComputeSuccessChance(ply)
		local successes = 0
		for _, it in ipairs(enchs) do
			if math.Rand(0, 1) <= chance then
				Arcana:ApplyEnchantmentToWeaponEntity(ply, wep, it.id)
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
			local cur = Arcana:GetEntityEnchantments(wep)
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

		self:_PulseMana()

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
	local VECTOR_UP = Vector(0, 0, 1)
	net.Receive("Arcana_Enchanter_ParticleBurst", function()
		local ent = net.ReadEntity()
		if not IsValid(ent) then return end

		local mdl = tostring(ent:GetModel() or "")
		if not ENCHANTER_MODEL_HULL2D then
			ENCHANTER_MODEL_HULL2D = Arcana_ComputeModelHull2D(mdl)
		end

		local emitter = ParticleEmitter(ent:WorldSpaceCenter(), false)
		if not emitter then return end

		local up = VECTOR_UP
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

	-- Mana flow visual: glyphs streaming from each feeding crystal into the bench along a
	-- bezier arc. Driven by ENT:_PulseMana on the server.
	local glyphParticles = {}

	local GLYPH_PHRASES = {
		"ABRAXAS DIVINE WISDOM LIGHT LIFE TRUTH COSMOS SOUL SPIRIT",
		"BEGINNING AND END BEGINNING AND END BEGINNING AND END",
		"BY THE ORDAINED COMMAND OF THE LORD SPIRIT AND SCRIPTURE",
		"THE WRATH OF THE SON OF PELEUS SING O MUSE",
		"IN THE HALLS OF CHAOS THE POWER IS ETERNAL",
		"THE SONS OF ATREUS SENT FORTH BY THE GODS",
		"THE SHINING TROJANS STOOD FAST IN GLORY",
	}

	local FLOW_UP = Vector(0, 0, 1)
	local FLOW_RIGHT = Vector(1, 0, 0)
	local FLOW_ZERO = Vector(0, 0, 0)
	local FLOW_WHITE = Color(255, 255, 255)

	local function glyphCharAt(idx)
		local phrase = GLYPH_PHRASES[(idx % #GLYPH_PHRASES) + 1]
		local len = (utf8 and utf8.len and utf8.len(phrase)) or #phrase
		if len < 1 then return "*" end

		local i = (idx % len) + 1
		if utf8 and utf8.sub then return utf8.sub(phrase, i, i) end

		return string.sub(phrase, i, i)
	end

	local function billboardAnglesAt(pos)
		local ang = (EyePos() - pos):Angle()
		ang:RotateAroundAxis(ang:Right(), -90)
		ang:RotateAroundAxis(ang:Up(), 90)

		return ang
	end

	local function randomPointOnOBBSurface(ent)
		if not IsValid(ent) then return Vector(0, 0, 0) end

		local mins, maxs = ent:OBBMins(), ent:OBBMaxs()
		local axis = math.random(1, 3)
		local pos = FLOW_ZERO
		if axis == 1 then
			pos.x = (math.random(0, 1) == 1) and maxs.x or mins.x
			pos.y = math.Rand(mins.y, maxs.y)
			pos.z = math.Rand(mins.z, maxs.z)
		elseif axis == 2 then
			pos.y = (math.random(0, 1) == 1) and maxs.y or mins.y
			pos.x = math.Rand(mins.x, maxs.x)
			pos.z = math.Rand(mins.z, maxs.z)
		else
			pos.z = (math.random(0, 1) == 1) and maxs.z or mins.z
			pos.x = math.Rand(mins.x, maxs.x)
			pos.y = math.Rand(mins.y, maxs.y)
		end

		return ent:LocalToWorld(pos)
	end

	local function bezierPoint(a, b, c, t)
		local u = 1 - t

		return a * (u * u) + b * (2 * u * t) + c * (t * t)
	end

	net.Receive("Arcana_Enchanter_ManaFlow", function()
		local toEnt = net.ReadEntity()
		local count = net.ReadUInt(8)
		if not IsValid(toEnt) then return end

		local now = CurTime()
		for _ = 1, count do
			local fromEnt = net.ReadEntity()
			if IsValid(fromEnt) then
				local fromPos = randomPointOnOBBSurface(fromEnt)
				local toPos = toEnt:WorldSpaceCenter()
				local dir = (toPos - fromPos)
				local dist = dir:Length()

				if dist > 2 then
					dir:Normalize()

					local right = dir:Cross(FLOW_UP)
					if right:LengthSqr() < 0.01 then right = FLOW_RIGHT end
					right:Normalize()

					local mid = (fromPos + toPos) * 0.5
					local curveAmt = math.Clamp(dist * 0.25, 20, 160)
					local ctrl = mid + right * math.Rand(-curveAmt, curveAmt)
					local baseColor = fromEnt:GetColor() or FLOW_WHITE
					local countGlyphs = math.Clamp(math.floor(8 + dist * 0.02), 5, 50)

					for gi = 1, countGlyphs do
						local speed = math.Rand(120, 220)
						glyphParticles[#glyphParticles + 1] = {
							startPos = fromPos,
							ctrlPos = ctrl,
							endPos = toPos,
							startTime = now + math.Rand(0, 0.7),
							duration = dist / speed,
							char = glyphCharAt(gi + math.floor(now * 13)),
							baseColor = Color(baseColor.r, baseColor.g, baseColor.b, 255),
							size = math.Rand(10, 16),
						}
					end
				end
			end
		end
	end)

	local MAX_FLOW_RENDER_DIST = 2000 * 2000
	hook.Add("PostDrawOpaqueRenderables", "Arcana_Enchanter_ManaFlowDraw", function(bDrawingDepth)
		if bDrawingDepth then return end

		local eye = EyePos()
		local now = CurTime()
		local write = 1
		for i = 1, #glyphParticles do
			local p = glyphParticles[i]
			local startT = p.startTime or 0
			local endT = startT + (p.duration or 0)

			if now >= startT and now <= endT then
				local u = math.Clamp((now - startT) / math.max(0.001, p.duration), 0, 1)
				local pos = bezierPoint(p.startPos, p.ctrlPos, p.endPos, u)

				if eye:DistToSqr(pos) <= MAX_FLOW_RENDER_DIST then
					local br = Lerp(u, p.baseColor.r, 255)
					local bg = Lerp(u, p.baseColor.g, 255)
					local bb = Lerp(u, p.baseColor.b, 255)
					local alpha = math.floor(220 * (1 - 0.15 * u))
					local ang = billboardAnglesAt(pos)

					cam.Start3D2D(pos, ang, 0.08)
						surface.SetFont("MagicCircle_Medium")
						surface.SetTextColor(br, bg, bb, alpha)
						surface.SetTextPos(0, 0)
						surface.DrawText(p.char or "*")
					cam.End3D2D()
				end
			end

			if now <= endT + 0.05 then
				glyphParticles[write] = p
				write = write + 1
			end
		end

		for i = write, #glyphParticles do glyphParticles[i] = nil end
	end)

	local BandCircle    = Arcana.Circle.BandCircle
	local RING_TYPES    = Arcana.Circle.RING_TYPES
	local Draw2DRing    = Arcana.Circle.Draw2DRing
	local Draw2DPattern = Arcana.Circle.Draw2DPatternRing
	local Draw2DRune    = Arcana.Circle.Draw2DRuneStar

	-- Enchanter-specific circle appearance
	local _circleCol       = Color(210, 185, 145)
	local _runeGlyphs      = {65, 67, 69, 71}  -- inner star: A/C/E/G
	local _runeGlyphsOuter = {66, 68, 70, 72}  -- outer star: B/D/F/H

	-- Create band rings that spin around the deposited weapon
	function ENT:ClientInitBandVis()
		if self._bandCircle and self._bandCircle.IsActive and self._bandCircle:IsActive() then return end

		local wep = self:GetContainedWeapon()
		if not IsValid(wep) then return end
		if not BandCircle then return end

		local pos = wep:WorldSpaceCenter()
		local ang = self:GetAngles()
		local color = Color(222, 198, 120, 255)
		local bc = BandCircle.Create(pos, ang, color, 80)
		if not bc then return end
		bc:SetReferenceEntity(self)

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

	local function getEnchantmentsList()
		return Arcana.RegisteredEnchantments or {}
	end

	local HL2_MODELS = {
		weapon_357 = "models/weapons/w_357.mdl",
		weapon_ar2 = "models/weapons/w_irifle.mdl",
		weapon_bugbait = "models/weapons/w_bugbait.mdl",
		weapon_crossbow = "models/weapons/w_crossbow.mdl",
		weapon_crowbar = "models/weapons/w_crowbar.mdl",
		weapon_frag = "models/weapons/w_grenade.mdl",
		weapon_physcannon = "models/weapons/w_physics.mdl",
		weapon_pistol = "models/weapons/w_pistol.mdl",
		weapon_rpg = "models/weapons/w_rocket_launcher.mdl",
		weapon_shotgun = "models/weapons/w_shotgun.mdl",
		weapon_slam = "models/weapons/w_slam.mdl",
		weapon_smg = "models/weapons/w_smg1.mdl",
		weapon_stunstick = "models/weapons/w_stunbaton.mdl",
	}

	local WARN_TEXT = {
		"Not all enchantments work with every weapon.",
		"",
		"The enchanter does its best to figure out how your",
		"weapon works, but it can sometimes get it wrong.",
		"",
		"If an enchantment does not seem to do anything,",
		"it may simply not be compatible with this weapon.",
	}

	local function showClassificationWarning(parent, onConfirm)
		-- Full-frame dim overlay
		local overlay = vgui.Create("DPanel", parent)
		overlay:SetPos(0, 0)
		overlay:SetSize(parent:GetWide(), parent:GetTall())
		overlay:SetZPos(9999)
		overlay:MoveToFront()
		overlay.Paint = function(pnl, w, h)
			surface.SetDrawColor(0, 0, 0, 170)
			surface.DrawRect(0, 0, w, h)
		end

		-- Block input reaching the enchanter UI behind us
		overlay:SetMouseInputEnabled(true)

		local bw, bh = 580, 300
		local inner = vgui.Create("DPanel", overlay)
		inner:SetSize(bw, bh)
		inner:Center()
		inner.Paint = function(pnl, w, h)
			-- Background
			ArtDeco.FillDecoPanel(0, 0, w, h, Color(20, 10, 10, 245), 10)

			-- Pulsing red border (two passes for glow effect)
			local pulse = math.abs(math.sin(CurTime() * 3.5))
			local glowA = math.floor(60 + pulse * 80)
			local edgeR = math.floor(200 + pulse * 55)
			surface.SetDrawColor(edgeR, 20, 20, glowA)
			surface.DrawOutlinedRect(0, 0, w, h, 4)
			surface.DrawOutlinedRect(3, 3, w - 6, h - 6, 2)
			surface.SetDrawColor(edgeR, 30, 30, 200 + math.floor(pulse * 55))
			surface.DrawOutlinedRect(6, 6, w - 12, h - 12, 1)

			-- Corner diamonds (art deco)
			local function diamond(cx, cy, r, col)
				surface.SetDrawColor(col)
				surface.DrawLine(cx, cy - r, cx + r, cy)
				surface.DrawLine(cx + r, cy, cx, cy + r)
				surface.DrawLine(cx, cy + r, cx - r, cy)
				surface.DrawLine(cx - r, cy, cx, cy - r)
			end
			local dc = Color(edgeR, 40, 40, 220)
			local cr = 7
			diamond(cr + 6, cr + 6, cr, dc)
			diamond(w - cr - 6, cr + 6, cr, dc)
			diamond(cr + 6, h - cr - 6, cr, dc)
			diamond(w - cr - 6, h - cr - 6, cr, dc)

			-- Title
			draw.SimpleText("⚠  WARNING  ⚠", "Arcana_AncientLarge", w * 0.5, 22, Color(edgeR, 60, 60, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)

			-- Divider
			surface.SetDrawColor(edgeR, 40, 40, 160)
			surface.DrawRect(20, 42, w - 40, 1)

			-- Body text
			local lineH = draw.GetFontHeight("Arcana_Ancient") + 4
			local textY = 58
			for _, line in ipairs(WARN_TEXT) do
				if line ~= "" then
					draw.SimpleText(line, "Arcana_Ancient", w * 0.5, textY, Color(230, 200, 200, 245), TEXT_ALIGN_CENTER)
				end
				textY = textY + lineH
			end
		end

		local btn = vgui.Create("DButton", inner)
		btn:SetText("")
		btn:SetSize(200, 36)

		btn.Paint = function(pnl, w, h)
			local hovered = pnl:IsHovered()
			local bg = hovered and Color(80, 20, 20, 245) or Color(50, 15, 15, 245)
			ArtDeco.FillDecoPanel(0, 0, w, h, bg, 8)
			local pulse = math.abs(math.sin(CurTime() * 3.5))
			local edgeR = math.floor(180 + pulse * 75)
			ArtDeco.DrawDecoFrame(0, 0, w, h, Color(edgeR, 40, 40, 255), 8)
			draw.SimpleText("I UNDERSTAND", "Arcana_AncientLarge", w * 0.5, h * 0.5, Color(255, 200, 200, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		end

		btn.DoClick = function()
			surface.PlaySound("buttons/button6.wav")
			overlay:Remove()
			if onConfirm then onConfirm() end
		end

		inner.PerformLayout = function(pnl, w, h)
			btn:SetPos(math.floor(w * 0.5 - 100), h - 52)
		end

		-- Resize overlay if frame resizes
		parent.OnSizeChanged = function(pnl, w, h)
			overlay:SetSize(w, h)
			inner:Center()
		end
	end

	-- Semi-transparent panel fill so the themed background shows through.
	local PANEL_BG = Color(24, 19, 12, 180)

	local GLYPH_MATS
	local function getGlyphMats()
		if GLYPH_MATS then return GLYPH_MATS end
		GLYPH_MATS = {}

		-- DXT5 VTF rather than the PNG: a third of the VRAM, and it shares the
		-- upload with the ring glyph materials instead of adding a second
		-- BGRA8888 copy of all eight. Regenerate with tools/png_to_vtf.py.
		for i = 65, 72 do
			GLYPH_MATS[#GLYPH_MATS + 1] = CreateMaterial("arcana_enchanter_glyph_" .. i, "UnlitGeneric", {
				["$basetexture"] = "arcana/glyphs/glyph_" .. i,
				["$translucent"] = 1,
				["$vertexalpha"] = 1,
				["$vertexcolor"] = 1,
			})
		end

		return GLYPH_MATS
	end

	-- Themed background, in the family of the other stations: dark brass
	-- plate with concentric rings radiating out from the magic circle —
	-- the enchantment rippling through the bench — and faint runes sinking
	-- slowly down into the weapon.
	local function drawEnchanterBackground(w, h, seed)
		-- Clip everything to the art-deco octagon using the stencil buffer.
		local x, y = 6, 6
		local ww, hh = w - 12, h - 12
		local corner = 14
		ArtDeco.BeginOctagonClip(x, y, ww, hh, corner)

		-- Dark brass base, translucent enough for the blur to breathe through.
		surface.SetDrawColor(30, 23, 13, 205)
		surface.DrawRect(x, y, ww, hh)

		local t = CurTime()

		-- Concentric rings radiating from where the magic circle sits (the
		-- left panel), creeping outward slowly and fading with distance.
		local ccx, ccy = x + w * 0.28, y + h * 0.42
		local maxR = math.sqrt((w - ccx) ^ 2 + (h - ccy) ^ 2)
		local spacing = 40
		local drift = (t * 6) % spacing
		for r = 0, maxR, spacing do
			local rr = r + drift
			local a = 26 * (1 - rr / maxR)
			if a > 0.5 then
				surface.DrawCircle(ccx, ccy, rr, 198, 160, 74, a)
			end
		end

		-- Runes sinking slowly toward the bench (the Emissary's rise,
		-- inverted; stable per-seed layout, animated by time).
		local mats = getGlyphMats()
		math.randomseed(seed or 1)
		for i = 1, 10 do
			local mat = mats[math.random(1, #mats)]
			local rx = x + math.random(24, ww - 24)
			local baseY = math.random(0, hh)
			local speed = math.Rand(4, 9)
			local size = math.random(36, 80)
			local rot = math.Rand(-10, 10)
			local ry = y + ((baseY + t * speed) % (hh + size)) - size * 0.5
			surface.SetDrawColor(222, 185, 110, 9 + (i % 3) * 4)
			surface.SetMaterial(mat)
			surface.DrawTexturedRectRotated(rx, ry, size, size, rot)
		end

		-- Restore the global RNG: leaving it seeded makes every math.random
		-- caller this frame (world VFX included) repeat the same sequence
		math.randomseed(SysTime())

		ArtDeco.EndOctagonClip()
	end

	local function OpenEnchanterMenu(machine)
		local ply = LocalPlayer()
		if not IsValid(ply) then return end
		local frame = vgui.Create("DFrame")
		frame:SetSize(980, 600)
		frame:Center()
		frame:SetTitle("")
		frame:MakePopup()
		local bgSeed = math.random(1, 10 ^ 9)

		ArtDeco.MakeDraggableByBand(frame, 44)

		-- Screen-space blur behind frame (like grimoire)
		hook.Add("HUDPaint", frame, function()
			local x, y = frame:LocalToScreen(0, 0)
			ArtDeco.DrawBlurRect(x + 6, y + 6, frame:GetWide() - 12, frame:GetTall() - 12, 4, 8)
		end)

		ArtDeco.StyleCloseButton(frame)

		-- Declared here so the title can measure the band down to the panels' frames.
		local content

		frame.Paint = function(pnl, w, h)
			drawEnchanterBackground(w, h, bgSeed)
			ArtDeco.DrawDecoFrame(6, 6, w - 12, h - 12, ArtDeco.Colors.gold, 14)

			-- The title centers in the band between the frame's top line and the
			-- enchantment panels' frames below it.
			local bandTop = 6 + 1
			local bandBottom = IsValid(content) and (content:GetY() + 4) or (bandTop + 38)
			ArtDeco.DrawTitle("Arcana_AncientLarge", string.upper("Enchanter"), bandTop, bandBottom, ArtDeco.Colors.paleGold)
		end

		if IsValid(frame.btnMinim) then
			frame.btnMinim:Hide()
		end

		if IsValid(frame.btnMaxim) then
			frame.btnMaxim:Hide()
		end

		content = vgui.Create("DPanel", frame)
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
					local e = Arcana.RegisteredEnchantments and Arcana.RegisteredEnchantments[id]
					if e then
						needCoins = needCoins + (tonumber(e.cost_coins) or 0)
						for _, it in ipairs(e.cost_items or {}) do
							local name = tostring(it.name or "")
							local amt = math.max(1, math.floor(tonumber(it.amount) or 1))
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

		-- How many bands the preview shows. Only ever read when the applied set
		-- changed, which is also the only way the count can change.
		local function getAppliedCount()
			local ok, arr = pcall(util.JSONToTable, getAppliedStr())
			return (ok and istable(arr)) and #arr or 0
		end

		-- Forward declaration so Think can trigger a rebuild
		local rebuild

		-- Left: Engraved circle with weapon model/name + controls
		local left = vgui.Create("DPanel", content)
		left:Dock(LEFT)
		left:SetWide(520)
		left:NoClipping(true)

		local COST_CHANCE_LOW = Color(220, 110, 90)
		local COST_CHANCE_MID = Color(222, 198, 120)
		local COST_CHANCE_HIGH = Color(140, 210, 140)
		left.Paint = function(pnl, w, h)
			ArtDeco.FillDecoPanel(4, 4, w - 8, h - 8, PANEL_BG, 12)
			ArtDeco.DrawDecoFrame(4, 4, w - 8, h - 8, ArtDeco.Colors.gold, 12)

			local cx, cy = w * 0.5, h * 0.40
			local radius = math.min(w, h) * 0.34
			local t      = CurTime()

			Draw2DRune(cx, cy, radius,        t * 2,  _runeGlyphsOuter, _circleCol, 210)
			Draw2DPattern(2, cx, cy, radius * 0.88, -t * 4, _circleCol, 220)
			Draw2DRing(RING_TYPES.SIMPLE_LINE, cx, cy, radius * 0.74, t * 2, _circleCol, 190)
			Draw2DPattern(1, cx, cy, radius * 0.60, -t * 9, _circleCol, 210)
			Draw2DRune(cx, cy, radius * 0.44, -t * 3, _runeGlyphs, _circleCol, 210)

			-- Selection cost and success chance under the slotted weapon's
			-- name, have / need, each line in its own color.
			local infoY = cy + radius + 36
			if needCoins > 0 or needShards > 0 then
				local haveCoins = Arcana:GetCoins(ply)
				local haveShards = Arcana:GetItemCount(ply, "mana_crystal_shard")
				ArtDeco.DrawCostLine("Arcana_AncientSmall", cx, infoY, {
					{text = string.Comma(haveCoins) .. " / " .. string.Comma(needCoins), icon = ArtDeco.Icons.coin, color = ArtDeco.Colors.coinGold},
				}, TEXT_ALIGN_CENTER)
				infoY = infoY + 18
				ArtDeco.DrawCostLine("Arcana_AncientSmall", cx, infoY, {
					{text = string.Comma(haveShards) .. " / " .. string.Comma(needShards), icon = ArtDeco.Icons.shard, color = ArtDeco.Colors.shardBlue},
				}, TEXT_ALIGN_CENTER)
				infoY = infoY + 18
			end

			if IsValid(machine) and (machine:GetContainedClass() or "") ~= "" then
				local chance = math.Clamp(machine:ComputeSuccessChance(ply) or 0, 0, 1)
				local pct = math.floor(chance * 100 + 0.5)
				local chanceCol = COST_CHANCE_LOW
				if chance >= 0.55 then
					chanceCol = COST_CHANCE_HIGH
				elseif chance >= 0.25 then
					chanceCol = COST_CHANCE_MID
				end
				draw.SimpleText(pct .. "% success", "Arcana_AncientSmall", cx, infoY, chanceCol, TEXT_ALIGN_CENTER)
			end
		end

		-- Weapon model preview centered in the circle
		local PREVIEW_FOV = 32
		local modelPanel = vgui.Create("DModelPanel", left)
		modelPanel:SetSize(360, 360)
		modelPanel:SetMouseInputEnabled(false)

		function modelPanel:LayoutEntity(ent)
			-- Spin about the model's geometry, not its origin, or off-origin weapons
			-- (the RPG, the .357) orbit out of frame instead of turning in place.
			ArtDeco.SpinModelPanelEntity(ent, Angle(0, CurTime() * 15 % 360, 0))
			ArtDeco.FitModelPanel(self, PREVIEW_FOV, nil, self._fitPadding)
		end

		-- The weapon's applied enchantments, rendered as the very bands it carries
		-- once it is out in the world (same builder, same geometry-driven placement)
		function modelPanel:PostDrawModel(ent)
			-- Count 0 (a plain weapon, or one whose enchantments were just stripped)
			-- draws nothing and releases the bands, so this needs no guard
			local col = (LocalPlayer().GetWeaponColor and LocalPlayer():GetWeaponColor():ToColor()) or _circleCol
			Arcana:RenderEnchantBandsForEntity(ent, self._enchantCount or 0, col, self._bandStyle or "axis", {isMelee = self._bandIsMelee})
		end

		local nameLabel = vgui.Create("DLabel", left)
		nameLabel:SetText("")
		nameLabel:SetFont("Arcana_Ancient")
		nameLabel:SetTextColor(ArtDeco.Colors.textBright)
		nameLabel:SetContentAlignment(5)

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
			ArtDeco.FillDecoPanel(0, 0, w, h, bgCol, 8)
			ArtDeco.DrawDecoFrame(0, 0, w, h, ArtDeco.Colors.gold, 8)
			local label = (self._mode == "deposit") and "Deposit" or "Withdraw"
			draw.SimpleText(label, "Arcana_AncientLarge", w * 0.5, h * 0.5, ArtDeco.Colors.textBright, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		end

		local function doDeposit()
			net.Start("Arcana_Enchanter_Deposit")
			net.WriteEntity(machine)
			net.SendToServer()
		end

		function toggleBtn:DoClick()
			updateToggle()

			if self._mode == "deposit" then
				if cookie.GetNumber("Arcana_SeenClassificationWarning", 0) == 0 then
					showClassificationWarning(frame, function()
						cookie.Set("Arcana_SeenClassificationWarning", "1")
						doDeposit()
					end)
				else
					doDeposit()
				end
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
			ArtDeco.FillDecoPanel(0, 0, w, h, bg, 8)
			local frameCol = enabled and ArtDeco.Colors.gold or Color(140, 120, 90, 255)
			ArtDeco.DrawDecoFrame(0, 0, w, h, frameCol, 8)
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
			local model = (swep and (swep.WorldModel or swep.ViewModel)) or HL2_MODELS[cls] or "models/weapons/w_pistol.mdl"
			local nice = (swep and (swep.PrintName or swep.Printname)) or cls
			modelPanel:SetModel(model)
			nameLabel:SetText(nice)
			ArtDeco.FitModelPanel(modelPanel, PREVIEW_FOV, nil, modelPanel._fitPadding)
			modelPanel._bandStyle, modelPanel._bandIsMelee = Arcana:GetEnchantBandPreviewInfo(cls)
		end

		-- Position the model and name inside left panel (centered in the circle)
		left.PerformLayout = function(pnl, w, h)
			local cx, cy = w * 0.5, h * 0.40
			local radius = math.min(w, h) * 0.34
			-- The panel IS the 3D viewport, so enchant rings reaching past it get
			-- sliced off in mid-air. Grow it to the largest square the container
			-- holds around the circle's centre, and pull the camera back by the
			-- same factor: the weapon keeps the size it had at radius * 1.5 while
			-- the rings gain room, and the deco frame is what cuts.
			local base = math.floor(radius * 1.5)
			local s = math.max(base, math.floor(2 * math.min(cx, cy, w - cx, h - cy)) - 12)
			modelPanel._fitPadding = 1.15 * (s / base)
			modelPanel:SetSize(s, s)
			modelPanel:SetPos(math.floor(cx - s * 0.5), math.floor(cy - s * 0.5))
			nameLabel:SetSize(math.floor(w * 0.6), 24)
			nameLabel:SetPos(math.floor(cx - nameLabel:GetWide() * 0.5), math.floor(cy + radius + 8))
		end

		-- Initialize preview and keep it updated
		setPreviewForClass(IsValid(machine) and machine:GetContainedClass() or "")
		modelPanel._enchantCount = getAppliedCount()
		computeTotals()
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
				refreshButtons()
			end

			-- Refresh right panel rows if the applied set changed on the contained weapon
			local curStr = getAppliedStr()
			if curStr ~= (lastAppliedStr or "") then
				lastAppliedStr = curStr
				modelPanel._enchantCount = getAppliedCount()
				if rebuild then rebuild() end
				computeTotals()
				refreshButtons()
			end
		end

		-- Right: enchantment list
		local right = vgui.Create("DPanel", content)
		right:Dock(FILL)

		right.Paint = function(pnl, w, h)
			ArtDeco.FillDecoPanel(4, 4, w - 8, h - 8, PANEL_BG, 12)
			ArtDeco.DrawDecoFrame(4, 4, w - 8, h - 8, ArtDeco.Colors.gold, 12)
			draw.SimpleText(string.upper("Available Enchantments"), "Arcana_Ancient", 14, 10, ArtDeco.Colors.paleGold)
		end

		local scroll = vgui.Create("DScrollPanel", right)
		scroll:Dock(FILL)
		scroll:DockMargin(12, 36, 12, 12)
		ArtDeco.StyleScrollBar(scroll)

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
						local callOk, allowed = pcall(ench.can_apply, ply, wepEnt)
						show = callOk and (allowed ~= false)
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
						ArtDeco.FillDecoPanel(2, 2, w - 4, h - 4, bg, 8)
						local frameCol = (isApplied and Color(150, 200, 240, 255)) or (pnl._selected and Color(255, 255, 255, 255)) or ArtDeco.Colors.gold
						ArtDeco.DrawDecoFrame(2, 2, w - 4, h - 4, frameCol, 8)
						draw.SimpleText(ench.name or enchId, "Arcana_AncientLarge", 14, 8, ArtDeco.Colors.textBright)
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
						refreshButtons()
						pnl:InvalidateLayout(true)
					end

					-- Info tooltip icon
					local infoIcon = ArtDeco.CreateInfoIcon(row, ench.description or "No description available", 320)

					-- Cost amounts with currency icons under the name
					local costSegs = {}
					local coinAmt = tonumber(ench.cost_coins) or 0
					if coinAmt > 0 then
						costSegs[#costSegs + 1] = {text = string.Comma(coinAmt), icon = ArtDeco.Icons.coin, color = ArtDeco.Colors.textDim}
					end

					for _, it2 in ipairs(ench.cost_items or {}) do
						local name = tostring(it2.name or "item")
						local amt = math.max(1, math.floor(tonumber(it2.amount) or 1))
						if name == "mana_crystal_shard" then
							costSegs[#costSegs + 1] = {text = string.Comma(amt), icon = ArtDeco.Icons.shard, color = ArtDeco.Colors.textDim}
						else
							-- No icon for arbitrary items, keep the word form
							local pretty = name
							if _G.msitems and _G.msitems.GetInventoryInfo then
								local info = _G.msitems.GetInventoryInfo(name)
								if info and info.name then
									pretty = string.lower(info.name)
								end
							end
							costSegs[#costSegs + 1] = {text = string.Comma(amt) .. " " .. pretty, color = ArtDeco.Colors.textDim}
						end
					end

					local costLbl = vgui.Create("DPanel", row)
					costLbl:SetPaintBackground(false)
					costLbl:SetMouseInputEnabled(false)
					costLbl.Paint = function(pnl, w, h)
						ArtDeco.DrawCostLine("Arcana_AncientSmall", 0, 0, costSegs, TEXT_ALIGN_LEFT)
					end
					costLbl:SetSize(ArtDeco.MeasureCostLine("Arcana_AncientSmall", costSegs))
					row.PerformLayout = function(pnl, w, h)
						-- Position info icon right after the enchant name
						surface.SetFont("Arcana_AncientLarge")
						local nameW, _ = surface.GetTextSize(ench.name or enchId)
						local nameX = 14
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

	-- Scale from base (25%) up to 80% at max Arcana level
	local playerLevel = Arcana:GetLevel(ply) or 0
	local maxLevel = ((Arcana.Config and Arcana.Config.MAX_LEVEL) or 100) / 1.75
	local t = math.Clamp(playerLevel / math.max(1, maxLevel), 0, 1)
	local maxCap = 0.80
	local chance = base + (maxCap - base) * t
	return math.Clamp(chance, 0, maxCap)
end

if SERVER then
	local PULSE_INTERVAL = 0.5
	local FALLBACK_CRYSTAL_RANGE = 520

	-- A mana crystal within its own absorb radius feeds this bench, which is what lifts the
	-- enchant success chance off its 5% floor. This was a general-purpose producer/consumer
	-- network for a while; it only ever had one producer class and this one receiver, so it
	-- is a proximity check. Broadcasts the flow visual drawn in the client section.
	function ENT:_PulseMana()
		local now = CurTime()
		if now < (self._nextManaPulse or 0) then return end
		self._nextManaPulse = now + PULSE_INTERVAL

		local myPos = self:GetPos()
		local feeding = {}

		for _, crystal in ipairs(ents.FindByClass("arcana_mana_crystal")) do
			if IsValid(crystal) then
				local range = (crystal.GetAbsorbRadius and crystal:GetAbsorbRadius()) or FALLBACK_CRYSTAL_RANGE
				if myPos:DistToSqr(crystal:GetPos()) <= range * range then
					feeding[#feeding + 1] = crystal
				end
			end
		end

		if #feeding == 0 then return end

		self._receivingUntil = now + 0.6
		if not self._receivingMana then
			self._receivingMana = true
			self:SetNWBool("Arcana_ReceivingMana", true)
		end

		net.Start("Arcana_Enchanter_ManaFlow", true)
		net.WriteEntity(self)
		net.WriteUInt(math.min(#feeding, 255), 8)
		for i = 1, math.min(#feeding, 255) do
			net.WriteEntity(feeding[i])
		end
		net.Broadcast()
	end
end