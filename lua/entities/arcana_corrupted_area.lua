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
		local ang = math.Rand(0, math.pi * 2)
		local r = math.Rand(math.max(12, radius * 0.15), math.max(24, radius * 0.55))
		local pos = center + Vector(math.cos(ang) * r, math.sin(ang) * r, math.Rand(24, 80))
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

		-- Despawn wisps if area idle for too long
		if (now - (self._lastPlayerPresence or now)) > (self._despawnGrace or 15) then
			for i = #self._wisps, 1, -1 do
				local w = self._wisps[i]

				if IsValid(w) then
					w:Remove()
				end

				table.remove(self._wisps, i)
			end

			-- back off spawn timer to avoid immediate respawn on next presence
			self._nextWispSpawn = now + (self._spawnInterval or 8)
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