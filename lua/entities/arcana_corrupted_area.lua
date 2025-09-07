AddCSLuaFile()
ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "Corrupted Area"
ENT.Category = "Arcana"
ENT.Spawnable = false
ENT.AdminOnly = false
ENT.RenderGroup = RENDERGROUP_BOTH
ENT.PhysgunDisabled = true
ENT.ms_notouch = true

function ENT:SetupDataTables()
	self:NetworkVar("Float", 0, "Radius")
	self:NetworkVar("Float", 1, "Intensity")
end

if SERVER then
	function ENT:UpdateTransmitState()
		return TRANSMIT_ALWAYS
	end

	function ENT:Initialize()
		self:SetModel("models/props_borealis/bluebarrel001.mdl")
		self:SetMoveType(MOVETYPE_NONE)
		self:SetSolid(SOLID_VPHYSICS)
		self:PhysicsInit(SOLID_VPHYSICS)
		self:SetCollisionGroup(COLLISION_GROUP_DEBRIS)
		local phys = self:GetPhysicsObject()

		if IsValid(phys) then
			phys:Wake()
			phys:EnableMotion(false)
			phys:EnableCollisions(false)
		end

		if not self:GetRadius() or self:GetRadius() <= 0 then
			self:SetRadius(900)
		end

		-- Wisp spawn control
		self._wisps = {}
		self._maxWisps = 3
		self._spawnInterval = 8
		self._nextWispSpawn = CurTime() + 3
		-- Geyser spawn control
		self._geysers = {}
		self._maxGeysers = 0
		self._geyserInterval = 8
		self._nextGeyserSpawn = CurTime() + math.Rand(2, 5)
		-- Heavy wisp spawn control
		self._heavyWisps = {}
		self._maxHeavyWisps = 0
		self._heavySpawnInterval = 12
		self._nextHeavySpawn = CurTime() + math.Rand(4, 10)
		-- Idle timeout (despawn when no players for a while)
		self._lastPlayerPresence = CurTime()
		self._despawnGrace = 15

		-- Intensity defaults
		if not self:GetIntensity() or self:GetIntensity() < 0 then
			self:SetIntensity(1)
		end

		self._lastIntensity = -1
	end

	local function applyIntensityServer(self)
		local k = math.Clamp(self:GetIntensity() or 1, 0, 2)
		-- Wisps only from 1.2→2: at 1.2 => 1 max, at 2 => 6 max (linear)
		local sw = math.Clamp((k - 1.2) / 0.8, 0, 1)

		if sw <= 0 then
			self._maxWisps = 0
			self._spawnInterval = 8
		else
			self._maxWisps = math.floor(1 + 5 * sw)
			self._spawnInterval = math.max(2, 10 - 8 * sw)
		end

		-- If intensity becomes extremely low, trim excess wisps gradually
		if self._maxWisps < #self._wisps then
			for i = #self._wisps, self._maxWisps + 1, -1 do
				local w = self._wisps[i]

				if IsValid(w) then
					w:Remove()
				end

				table.remove(self._wisps, i)
			end
		end

		-- Geysers from 1.0→2.0 scale with radius
		local sg = math.Clamp((k - 1.0) / 1.0, 0, 1)
		local radius = self:GetRadius() or 900
		local areaFactor = math.Clamp(radius / 900, 0.6, 2.5)
		self._maxGeysers = math.min(12, math.floor((1 + 7 * sg) * areaFactor))
		self._geyserInterval = math.max(2, (10 - 8 * sg) / areaFactor)

		-- Heavy wisps appear at higher intensity
		local sh = math.Clamp((k - 1.3) / 0.7, 0, 1)
		self._maxHeavyWisps = math.floor(1 * areaFactor + 2 * sh)
		self._heavySpawnInterval = math.max(6, 16 - 10 * sh)

		-- Trim excess geysers if limits reduced
		if self._maxGeysers < #self._geysers then
			for i = #self._geysers, self._maxGeysers + 1, -1 do
				local g = self._geysers[i]

				if IsValid(g) then
					g:Remove()
				end

				table.remove(self._geysers, i)
			end
		end
	end

	local function playerInRange(center, radius)
		radius = radius or 0
		local r2 = radius * radius

		for _, ply in ipairs(player.GetAll()) do
			if IsValid(ply) and ply:Alive() and ply:GetPos():DistToSqr(center) <= r2 then return true end
		end

		return false
	end

	function ENT:_SpawnWisp()
		local center = self:GetPos()
		local radius = self:GetRadius() or 500
		local ent = ents.Create("arcana_corrupted_wisp")
		if not IsValid(ent) then return end
		local base = self:FindSpawnPos(false) or center
		local pos = base + Vector(0, 0, math.Rand(24, 80))
		ent:SetPos(pos)
		ent:Spawn()
		ent:Activate()
		ent:SetRadius(radius * 2)

		-- Bind the wisp to this area
		ent._areaCenter = Vector(center)
		ent._areaRadius = radius
		self._wisps[#self._wisps + 1] = ent

		ent:CallOnRemove("Arcana_WispRemoved" .. ent:EntIndex(), function()
			for i = #self._wisps, 1, -1 do
				if not IsValid(self._wisps[i]) then
					table.remove(self._wisps, i)
				end
			end
		end)
	end

	local function groundAt(pos, up)
		up = up or Vector(0, 0, 1)
		local tr = util.TraceLine({
			start = pos + up * 512,
			endpos = pos - up * 4096,
			filter = {}
		})

		return tr.HitPos, tr.HitNormal
	end

	-- Shared spawn position selector: prioritizes players, then NPCs, then NextBots within the area.
	-- If grounded is true, returns a ground position via trace; otherwise returns a flat XY position.
	function ENT:FindSpawnPos(grounded)
		local center = self:GetPos()
		local radius = self:GetRadius() or 500
		local candPlayers, candNPCs, candNB = {}, {}, {}
		for _, ent in ipairs(ents.FindInSphere(center, radius)) do
			if not IsValid(ent) or ent == self then continue end
			if ent:IsPlayer() then
				if ent:Alive() then candPlayers[#candPlayers + 1] = ent end
			elseif ent:IsNPC() then
				candNPCs[#candNPCs + 1] = ent
			elseif ent.IsNextBot and ent:IsNextBot() then
				candNB[#candNB + 1] = ent
			end
		end

		local targetList = (#candPlayers > 0 and candPlayers) or (#candNPCs > 0 and candNPCs) or candNB
		local pos
		if targetList and #targetList > 0 then
			local t = targetList[math.random(1, #targetList)]
			local base = IsValid(t) and t:GetPos() or center
			local ang = math.Rand(0, math.pi * 2)
			local off = math.Rand(0, math.min(180, radius * 0.25))
			pos = base + Vector(math.cos(ang) * off, math.sin(ang) * off, 0)
		else
			local ang = math.Rand(0, math.pi * 2)
			local rr = math.Rand(math.max(24, radius * 0.2), math.max(64, radius * 0.9))
			pos = center + Vector(math.cos(ang) * rr, math.sin(ang) * rr, 0)
		end

		if grounded then
			local hp = select(1, groundAt(pos))
			return hp
		else
			return pos
		end
	end

	function ENT:_SpawnGeyser()
		local center = self:GetPos()
		local radius = self:GetRadius() or 500
		local hitPos = self:FindSpawnPos(true)
		if not hitPos then return end

		local ent = ents.Create("arcana_corrupted_geyser")
		if not IsValid(ent) then return end

		ent:SetPos(hitPos + Vector(0, 0, 2))
		ent:Spawn()
		ent:Activate()

		-- Scale radius and damage with area size and intensity
		local k = math.Clamp(self:GetIntensity() or 1, 0, 2)
		local sg = math.Clamp((k - 1.0) / 1.0, 0, 1)
		local gr = math.Clamp(radius * 0.2, 180, 380)
		if ent.SetRadius then ent:SetRadius(gr) end
		if ent.SetDamage then ent:SetDamage(50 + math.floor(40 * sg)) end

		self._geysers[#self._geysers + 1] = ent
		ent:CallOnRemove("Arcana_GeyserRemoved" .. ent:EntIndex(), function()
			for i = #self._geysers, 1, -1 do
				if not IsValid(self._geysers[i]) then
					table.remove(self._geysers, i)
				end
			end
		end)
	end

	function ENT:_SpawnHeavyWisp()
		local center = self:GetPos()
		local radius = self:GetRadius() or 500
		local pos = self:FindSpawnPos(false) or center
		local ent = ents.Create("arcana_corrupted_wisp_heavy")
		if not IsValid(ent) then return end
		ent:SetPos(pos + Vector(0, 0, math.Rand(40, 90)))
		ent:Spawn()
		ent:Activate()
		ent._areaCenter = Vector(center)
		ent._areaRadius = radius
		self._heavyWisps[#self._heavyWisps + 1] = ent
		ent:CallOnRemove("Arcana_HeavyWispRemoved" .. ent:EntIndex(), function()
			for i = #self._heavyWisps, 1, -1 do
				if not IsValid(self._heavyWisps[i]) then
					table.remove(self._heavyWisps, i)
				end
			end
		end)
	end

	function ENT:Think()
		local now = CurTime()
		local center = self:GetPos()
		local radius = self:GetRadius() or 500
		-- Apply intensity changes live
		local curI = self:GetIntensity() or 1

		if curI ~= (self._lastIntensity or -1) then
			applyIntensityServer(self)
			self._lastIntensity = curI
		end

		-- Update wisps' bounds and cleanup
		for i = #self._wisps, 1, -1 do
			local w = self._wisps[i]

			if not IsValid(w) then
				table.remove(self._wisps, i)
			else
				w._areaCenter = Vector(center)
				w._areaRadius = radius
			end
		end

		local hasPlayer = playerInRange(center, radius)

		if hasPlayer then
			self._lastPlayerPresence = now
		end

		-- Spawn logic: if player present and below cap, spawn on interval
		if hasPlayer and now >= (self._nextWispSpawn or 0) then
			if (#self._wisps) < (self._maxWisps or 3) and (self._maxWisps or 0) > 0 then
				self:_SpawnWisp()
			end

			self._nextWispSpawn = now + (self._spawnInterval or 8)
		end

		-- Geyser spawn logic
		if hasPlayer and now >= (self._nextGeyserSpawn or 0) then
			if (#self._geysers) < (self._maxGeysers or 0) and (self._maxGeysers or 0) > 0 then
				self:_SpawnGeyser()
			end

			self._nextGeyserSpawn = now + (self._geyserInterval or 8)
		end

		-- Heavy wisp spawn logic
		if hasPlayer and now >= (self._nextHeavySpawn or 0) then
			if (#self._heavyWisps) < (self._maxHeavyWisps or 0) and (self._maxHeavyWisps or 0) > 0 then
				self:_SpawnHeavyWisp()
			end

			self._nextHeavySpawn = now + (self._heavySpawnInterval or 12)
		end

		-- Despawn wisps if area idle for too long
		if (now - (self._lastPlayerPresence or now)) > (self._despawnGrace or 15) then
			for i = #self._wisps, 1, -1 do
				local w = self._wisps[i]

				if IsValid(w) then
					w:Remove()
				end

				table.remove(self._wisps, i)
			end

			-- remove lingering geysers as well
			for i = #self._geysers, 1, -1 do
				local g = self._geysers[i]

				if IsValid(g) then
					g:Remove()
				end

				table.remove(self._geysers, i)
			end

			-- remove heavy wisps
			for i = #self._heavyWisps, 1, -1 do
				local hw = self._heavyWisps[i]

				if IsValid(hw) then
					hw:Remove()
				end

				table.remove(self._heavyWisps, i)
			end

			-- back off spawn timer to avoid immediate respawn on next presence
			self._nextWispSpawn = now + (self._spawnInterval or 8)
			self._nextGeyserSpawn = now + (self._geyserInterval or 8)
			self._nextHeavySpawn = now + (self._heavySpawnInterval or 12)
		end

		self:NextThink(now + 0.5)
		return true
	end

	function ENT:OnRemove()
		if self._wisps then
			for _, w in ipairs(self._wisps) do
				if IsValid(w) then
					w:Remove()
				end
			end
		end
	end
end

if CLIENT then
	-- Invisible material used to write to the stencil buffer
	local INVISIBLE_MAT = CreateMaterial("arcana_corruption_stencil", "UnlitGeneric", {
		["$basetexture"] = "color/white",
		["$alpha"] = "0",
		["$translucent"] = "1"
	})

	-- server applier above; client has applyIntensityClient below
	local function applyIntensityClient(self)
		local k = math.Clamp(self:GetIntensity() or 1, 0, 2)
		-- Particles: very slow from 0.7→2, max at 2
		local sp = math.Clamp(k * 0.5, 0, 1)
		local sr = sp * sp * sp * sp -- quartic for very slow onset
		self._glyphSpawnRate = math.floor(20 * sr)
		self._glyphMaxParticles = math.floor(20 + 120 * sr)
		-- Overlay darken can follow a softer factor so it appears earlier
		self._intensityScale = sp
	end

	local function drawCorruption(self)
		if not IsValid(self) then return end

		local world_pos = self:GetPos()
		local player_pos = LocalPlayer():GetPos()
		local distance = player_pos:Distance(world_pos)
		local radius = math.max(1, self:GetRadius() or 500)

		-- Remap intensity k in [0.5..2.0] -> s in [0..1], ensure visibility <0.9
		local k = math.Clamp(self:GetIntensity() or 1, 0, 2)
		if k < 0.5 then return end

		local s0 = math.Clamp((k - 0.5) / 1.5, 0, 1)
		local sSmooth = (s0 * s0) * (3 - 2 * s0) -- smoothstep(0..1)
		local s = math.Clamp(0.5 * (s0 + sSmooth) + 0.08, 0, 1)
		-- Compute post-process values from s: moderate contrast, clear desaturation, slight darken
		local cm = {
			["$pp_colour_addr"] = 0,
			["$pp_colour_addg"] = 0,
			["$pp_colour_addb"] = 0,
			["$pp_colour_brightness"] = -0.04 * s,
			["$pp_colour_contrast"] = 1 + 1.0 * s,
			["$pp_colour_colour"] = math.max(0, 1 - 1.1 * s),
			["$pp_colour_mulr"] = 0,
			["$pp_colour_mulg"] = 0,
			["$pp_colour_mulb"] = 0,
		}

		if distance < radius then
			-- Inside corruption volume: apply post-processing + darken overlay
			DrawColorModify(cm)
			--drawDarkOverlay(s)
		else
			-- Outside: mask with a 3D sphere in the stencil buffer
			render.SetStencilEnable(true)
			render.SetStencilWriteMask(1)
			render.SetStencilTestMask(1)
			render.SetStencilReferenceValue(1)
			render.ClearStencil()
			render.SetStencilCompareFunction(STENCIL_ALWAYS)
			render.SetStencilPassOperation(STENCIL_REPLACE)
			render.SetStencilFailOperation(STENCIL_KEEP)
			render.SetStencilZFailOperation(STENCIL_KEEP)
			-- Draw invisible sphere to stencil
			render.SetMaterial(INVISIBLE_MAT)
			local matrix = Matrix()
			matrix:SetTranslation(world_pos)
			matrix:SetScale(Vector(radius, radius, radius))
			cam.PushModelMatrix(matrix)
			render.DrawSphere(Vector(0, 0, 0), 1, 24, 24)
			cam.PopModelMatrix()
			render.SetStencilCompareFunction(STENCIL_EQUAL)
			render.SetStencilPassOperation(STENCIL_KEEP)
			-- Apply post-processing within stencil
			DrawColorModify(cm)
			--drawDarkOverlay(s)
			render.SetStencilEnable(false)
		end
	end

	local function updateRenderBounds(self)
		local r = math.max(64, (self:GetRadius() or 100) + 64)
		self:SetRenderBounds(Vector(-r, -r, -32), Vector(r, r, r))
	end

	function ENT:Initialize()
		updateRenderBounds(self)
		self._lastUpdate = CurTime()
		self._lastIntensity = -1
		applyIntensityClient(self)
	end

	function ENT:Think()
		-- Spawn/update evil glyph particles (use CurTime delta for stable speed)
		local now = CurTime()
		self._lastUpdate = now

		-- Intensity changes live
		local curI = self:GetIntensity() or 1
		if curI ~= (self._lastIntensity or -1) then
			applyIntensityClient(self)
			self._lastIntensity = curI
		end

		updateRenderBounds(self)
		self:SetNextClientThink(CurTime() + 0.05)

		return true
	end

	function ENT:DrawTranslucent()
	end

	function ENT:Draw()
		drawCorruption(self)
	end
end