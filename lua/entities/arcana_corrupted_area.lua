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

function ENT:UpdateTransmitState()
	-- Correct only because UpdatePVSBounds resizes the surrounding box to the
	-- sphere: the engine derives an entity's PVS clusters from that box, and
	-- the barrel model's default box would network a 900+ unit area as if it
	-- were 28 units wide at the center. Players who can see no part of the
	-- sphere still get nothing (the screen-space effect corrupts stale
	-- framebuffer pixels)
	return TRANSMIT_PVS
end

if SERVER then
	resource.AddShader("arcana_corruption_ps30")
	resource.AddShader("arcana_blit_ps30")

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

		self:UpdatePVSBounds()

		-- Wisp spawn control
		self._wisps = {}
		self._maxWisps = 3
		self._spawnInterval = 8
		self._nextWispSpawn = CurTime() + 3

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

		-- Decay system: track when intensity last increased
		self._lastIntensityIncrease = CurTime()
		self._decayGracePeriod = 600 -- 10 minutes in seconds
		self._decayRate = 0.001 -- intensity decrease per second (~20 min for 1.2 intensity)
		self._isDecaying = false
	end

	-- The surrounding box is what the engine walks to list the clusters an
	-- entity occupies, which is what TRANSMIT_PVS is tested against. Sized to
	-- the sphere it makes the engine transmit whenever any part of the area
	-- is potentially visible, and always to players standing inside it (their
	-- own cluster is in the box and in their own PVS).
	function ENT:UpdatePVSBounds()
		local r = math.max(64, self:GetRadius() or 500)
		self._boundsRadius = r
		self:SetSurroundingBounds(Vector(-r, -r, -r), Vector(r, r, r))
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

		-- Heavy wisps appear only after 1.5 intensity
		self._maxHeavyWisps = k < 1.5 and 0 or 1
		self._heavySpawnInterval = 6
		if self._maxHeavyWisps < #self._heavyWisps then
			for i = #self._heavyWisps, self._maxHeavyWisps + 1, -1 do
				local h = self._heavyWisps[i]
				if IsValid(h) then
					h:Remove()
				end

				table.remove(self._heavyWisps, i)
			end
		end

		self:AddEFlags(EFL_FORCE_CHECK_TRANSMIT)
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
		local base = self:FindSpawnPos(false)
		local pos = base + Vector(0, 0, math.Rand(24, 80))

		local ent = ents.Create("arcana_corrupted_wisp")
		if not IsValid(ent) then return end

		ent:SetPos(pos)
		ent:Spawn()
		ent:SetRadius(radius * 2)

		-- Bind the wisp to this area
		ent._areaCenter = Vector(center)
		ent._areaRadius = radius
		table.insert(self._wisps, ent)

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
			filter = MASK_SOLID_BRUSHONLY
		})

		return tr.HitPos, tr.HitNormal
	end

	-- Shared spawn position selector: prioritizes players, then NPCs, then NextBots within the area.
	-- If grounded is true, returns a ground position via trace; otherwise returns a flat XY position.
	function ENT:FindSpawnPos(grounded, randomize)
		local center = self:GetPos()
		local radius = self:GetRadius() or 500

		local foundTarget = false
		local pos
		if not randomize then
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
			if targetList and #targetList > 0 then
				local t = targetList[math.random(1, #targetList)]
				local base = IsValid(t) and t:GetPos() or center
				local ang = math.Rand(0, math.pi * 2)
				local off = math.Rand(0, math.min(180, radius * 0.25))
				pos = base + Vector(math.cos(ang) * off, math.sin(ang) * off, 0)
				foundTarget = true
			end
		end

		if randomize or not foundTarget then
			local ang = math.Rand(0, math.pi * 2)
			local rr = math.Rand(math.max(24, radius * 0.2), math.max(64, radius * 0.9))
			pos = center + Vector(math.cos(ang) * rr, math.sin(ang) * rr, 0)
		end

		if grounded then
			local hp, _ = groundAt(pos)
			return hp
		else
			return pos
		end
	end

	function ENT:_SpawnHeavyWisp()
		local center = self:GetPos()
		local radius = self:GetRadius() or 500
		local pos = center + Vector(0, 0, 100)
		local ent = ents.Create("arcana_corrupted_wisp_heavy")
		if not IsValid(ent) then return end

		ent:SetPos(pos + Vector(0, 0, math.Rand(40, 90)))
		ent:Spawn()
		ent:Activate()
		ent._areaCenter = Vector(center)
		ent._areaRadius = radius
		table.insert(self._heavyWisps, ent)

		ent:CallOnRemove("Arcana_HeavyWispRemoved" .. ent:EntIndex(), function()
			for i = #self._heavyWisps, 1, -1 do
				if not IsValid(self._heavyWisps[i]) then
					table.remove(self._heavyWisps, i)
				end
			end
		end)
	end

	function ENT:ClearEntities()
		if self._wisps then
			for _, w in ipairs(self._wisps) do
				if IsValid(w) then
					w:Remove()
				end
			end

			self._wisps = {}
		end

		if self._heavyWisps then
			for _, h in ipairs(self._heavyWisps) do
				if IsValid(h) then
					h:Remove()
				end
			end

			self._heavyWisps = {}
		end
	end

	function ENT:ClearInvalidEntities()
		for i, w in ipairs(self._wisps) do
			if not IsValid(w) or w:GetPos():DistToSqr(self:GetPos()) > (self:GetRadius() or 500) ^ 2 then
				SafeRemoveEntity(w)
				table.remove(self._wisps, i)
			end
		end

		for i, h in ipairs(self._heavyWisps) do
			if not IsValid(h) or h:GetPos():DistToSqr(self:GetPos()) > (self:GetRadius() or 500) ^ 2 then
				SafeRemoveEntity(h)
				table.remove(self._heavyWisps, i)
			end
		end
	end

	function ENT:Think()
		local now = CurTime()
		local center = self:GetPos()
		local radius = self:GetRadius() or 500

		-- Apply intensity changes live
		local curI = self:GetIntensity() or 1
		if curI ~= (self._lastIntensity or -1) then
			-- Check if intensity increased
			if curI > (self._lastIntensity or -1) and self._lastIntensity >= 0 then
				-- Reset decay timer when intensity increases
				self._lastIntensityIncrease = now
				self._isDecaying = false
			end

			applyIntensityServer(self)
			self._lastIntensity = curI
		end

		-- Update wisps' bounds and cleanup
		for i = #self._wisps, 1, -1 do
			local w = self._wisps[i]

			if not IsValid(w) or w:GetPos():DistToSqr(center) > (radius or 500) ^ 2 then
				SafeRemoveEntity(w)
				table.remove(self._wisps, i)
			else
				w._areaCenter = Vector(center)
				w._areaRadius = radius
			end
		end

		if math.max(64, radius) ~= self._boundsRadius then
			self:UpdatePVSBounds()
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

		-- Heavy wisp spawn logic
		if hasPlayer and now >= (self._nextHeavySpawn or 0) then
			if (#self._heavyWisps) < (self._maxHeavyWisps or 0) and (self._maxHeavyWisps or 0) > 0 then
				self:_SpawnHeavyWisp()
			end

			self._nextHeavySpawn = now + (self._heavySpawnInterval or 12)
		end

		-- Progressive intensity decay for low-intensity areas
		local currentIntensity = self:GetIntensity() or 1
		if currentIntensity < 1.2 then
			local timeSinceIncrease = now - (self._lastIntensityIncrease or now)

			if timeSinceIncrease >= self._decayGracePeriod then
				-- Start decaying
				if not self._isDecaying then
					self._isDecaying = true
					self._lastDecayTick = now
				end

				-- Apply decay
				local deltaTime = now - (self._lastDecayTick or now)
				if deltaTime > 0 then
					local newIntensity = math.max(0, currentIntensity - self._decayRate * deltaTime)
					self:SetIntensity(newIntensity)
					self._lastDecayTick = now

					-- Remove the entity if intensity reaches 0
					if newIntensity <= 0 then
						self:Remove()
						return
					end
				end
			end
		else
			-- Reset decay state if intensity is >= 1.2
			self._isDecaying = false
		end

		-- Despawn wisps if area idle for too long
		if (now - (self._lastPlayerPresence or now)) > (self._despawnGrace or 15) then
			self:ClearEntities()

			-- back off spawn timer to avoid immediate respawn on next presence
			self._nextWispSpawn = now + (self._spawnInterval or 8)
			self._nextHeavySpawn = now + (self._heavySpawnInterval or 12)
		end

		self:ClearInvalidEntities()
		self:NextThink(now + 0.5)
		return true
	end

	function ENT:OnRemove()
		self:ClearEntities()

		for key, region in pairs(Arcana.ManaCrystals.regions) do
			if region and region.corruptEnt == self then
				Arcana.ManaCrystals.regions[key] = nil
				break
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

	local VECTOR_ZERO = Vector(0, 0, 0)
	function ENT:_DrawSphere(on_draw, radiusScale)
		if not IsValid(self) then return end

		local world_pos = self:GetPos()
		local player_pos = LocalPlayer():GetPos()
		local distance = player_pos:Distance(world_pos)
		local radius = math.max(1, self:GetRadius() or 500) * (radiusScale or 1)

		-- Remap intensity k in [0.5..2.0] -> s in [0..1], ensure visibility <0.9
		local k = math.Clamp(self:GetIntensity() or 1, 0, 2)
		if k < 0.5 then return end

		if distance < radius then
			-- Inside corruption volume: apply post-processing + darken overlay
			on_draw()
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
			render.DrawSphere(VECTOR_ZERO, 1, 24, 24)
			cam.PopModelMatrix()

			render.SetStencilCompareFunction(STENCIL_EQUAL)
			render.SetStencilPassOperation(STENCIL_KEEP)

			on_draw()

			render.SetStencilEnable(false)
		end
	end

	local SHADER_MAT = Material("effects/water_warp01")
	local CVAR_DRAW_CORRUPTION = CreateConVar("arcana_draw_corruption", "1", FCVAR_ARCHIVE, "Draw the corruption effect")

	-- Custom corruption shader: analytic sphere with noise-eaten flame edges
	-- and dark relief veins (see shaders/arcana_corruption_ps30.hlsl).  The
	-- stencil sphere is expanded so the flame licks have room outside the
	-- radius; the visual boundary itself is computed in the shader.
	local STENCIL_EXPAND = 1.4
	local corruptionMat, blitMat, maskBlurMat

	-- Screen-space mask of "world geometry inside the sphere": its blurred
	-- edge is exactly the sphere/world intersection curve, which the shader
	-- uses to draw flames along terrain, cliffs and buildings.
	--
	-- Built on the first corruption draw rather than at load. These four are
	-- 35 MB at 1440p (2.25x that at 4K), and Source never frees a render target,
	-- so allocating them up front charges every client for an effect most
	-- sessions never spawn. Same lazy pattern arcana_mana_crystal uses for its
	-- refraction RT. The materials bake the RT names in at creation time, so
	-- they have to be built here too rather than when the shaders mount.
	local CORR_SNAP_RT, CORR_MASK_RT, CORR_MBLUR_A, CORR_MBLUR_B
	local shadersMounted = false

	local function ensureCorruptionResources()
		if corruptionMat or not shadersMounted then return end

		local w, h = ScrW(), ScrH()
		local halfW, halfH = math.floor(w / 2), math.floor(h / 2)

		-- The snapshot restores the screen verbatim, so it keeps the full 8 bits
		-- per channel - at 16 bit the restore would band visibly.
		CORR_SNAP_RT = GetRenderTarget("arcana_corr_snap", w, h)

		-- The mask chain only ever carries two channels: the shader reads
		-- `tex2D(Tex1, i.uv).rg` and nothing else, red being "inside the true
		-- sphere" and green "expanded sphere visible here". RGB565 halves those
		-- three targets (2 bytes/px instead of 4) while keeping R and G
		-- independent, which no 1-byte format can - I8 replicates its single
		-- channel across rgb and would collapse the two flags into one.
		-- Verified in-game: the engine honours RT formats (unlike VTFs), and
		-- CopyRenderTargetToTexture writes into a 565 target correctly.
		-- Precision cost is 32 levels of red / 64 of green on the blurred edge,
		-- which the flame noise hides.
		local RT_FLAGS = bit.bor(4, 8, 256, 512) -- CLAMPS | CLAMPT | NOMIP | NOLOD (no TEXTUREFLAGS_* globals in GLua)
		CORR_MASK_RT = GetRenderTargetEx("arcana_corr_mask", w, h,
			RT_SIZE_OFFSCREEN, MATERIAL_RT_DEPTH_NONE, RT_FLAGS, 0, IMAGE_FORMAT_RGB565)
		CORR_MBLUR_A = GetRenderTargetEx("arcana_corr_mblur_a", halfW, halfH,
			RT_SIZE_OFFSCREEN, MATERIAL_RT_DEPTH_NONE, RT_FLAGS, 0, IMAGE_FORMAT_RGB565)
		CORR_MBLUR_B = GetRenderTargetEx("arcana_corr_mblur_b", halfW, halfH,
			RT_SIZE_OFFSCREEN, MATERIAL_RT_DEPTH_NONE, RT_FLAGS, 0, IMAGE_FORMAT_RGB565)

		corruptionMat = CreateShaderMaterial("arcana_corruption_fx", {
			["$pixshader"] = "arcana_corruption_ps30",
			["$vertexshader"] = "arcana_passthrough_vs30",
			["$basetexture"] = "_rt_FullFrameFB",
			["$texture1"] = CORR_MBLUR_B:GetName(), -- blurred intersection mask
			["$alpha_blend"] = 0,
			-- every constant component set at runtime MUST be declared here,
			-- otherwise SetFloat on it is silently ignored
			["$c0_x"] = 0.0, ["$c0_y"] = 0.0, ["$c0_z"] = 0.0, ["$c0_w"] = 1.0, -- sphere centre, radius
			["$c1_x"] = 0.0, ["$c1_y"] = 0.0, ["$c1_z"] = 0.0, ["$c1_w"] = 0.0, -- eye pos, time
			["$c2_x"] = 1.0, ["$c2_y"] = 0.0, ["$c2_z"] = 0.0, ["$c2_w"] = 0.0, -- camera forward, strength
			["$c3_x"] = 0.0, ["$c3_y"] = 1.0, ["$c3_z"] = 0.0, ["$c3_w"] = 1.0, -- camera right * tan(fov/2), vertical scale
		})

		-- Raw tinted blit: restores the screen snapshot without the tonemap
		-- scaling UnlitGeneric would apply; the tint rasterises mask channels
		blitMat = CreateShaderMaterial("arcana_corruption_blit", {
			["$pixshader"] = "arcana_blit_ps30",
			["$vertexshader"] = "arcana_passthrough_vs30",
			["$basetexture"] = CORR_SNAP_RT:GetName(),
			["$alpha_blend"] = 0,
			["$c0_x"] = 1.0, ["$c0_y"] = 1.0, ["$c0_z"] = 1.0, ["$c0_w"] = 1.0, -- tint
		})

		-- Separable gaussian for softening the mask (reuses the bloom shader)
		maskBlurMat = CreateShaderMaterial("arcana_corruption_maskblur", {
			["$pixshader"] = "arcana_bloom_ps30",
			["$vertexshader"] = "arcana_passthrough_vs30",
			["$basetexture"] = CORR_MASK_RT:GetName(),
			["$alpha_blend"] = 0,
			["$c0_x"] = 1.0, ["$c0_y"] = 0.0, ["$c0_z"] = 3.0, -- blur dir + radius
			["$c1_x"] = 1.0, ["$c1_y"] = 0.0, -- intensity, CA off
			["$c2_x"] = 0.0, ["$c2_y"] = 0.0, ["$c2_z"] = 1.0, -- diff mode off
		})
	end

	WaitForShaderMounted({"arcana_corruption_ps30", "arcana_blit_ps30", "arcana_bloom_ps30", "arcana_passthrough_vs30"}, function(available)
		shadersMounted = available
	end)

	local function maskBlurPass(srcRT, dstRT, dirX, dirY, radius)
		render.PushRenderTarget(dstRT)
		render.Clear(0, 0, 0, 0)
		maskBlurMat:SetTexture("$basetexture", srcRT)
		maskBlurMat:SetFloat("$c0_x", dirX)
		maskBlurMat:SetFloat("$c0_y", dirY)
		maskBlurMat:SetFloat("$c0_z", radius)
		render.SetMaterial(maskBlurMat)
		render.DrawScreenQuad()
		render.PopRenderTarget()
	end

	local function setBlitTint(r, g, bl, a)
		blitMat:SetFloat("$c0_x", r)
		blitMat:SetFloat("$c0_y", g)
		blitMat:SetFloat("$c0_z", bl)
		blitMat:SetFloat("$c0_w", a)
	end

	-- Rasterises the intersection mask on the real framebuffer (stencils need
	-- the scene depth buffer, which render targets do not have).  Two stencil
	-- bit-planes:
	--   bit 1: world surface inside the TRUE sphere (front surface in front
	--          of it, back surface behind it) -> mask RED channel
	--   bit 2: the EXPANDED sphere's front surface is visible at this pixel
	--          (not hidden behind foreground world) -> mask GREEN channel.
	--          Expanded, so the flame shell beyond the silhouette is counted
	--          as visible instead of being capped at the sphere's edge.
	-- The screen is snapshotted and restored around the rasterisation.
	local function buildIntersectionMask(self, radius, eyeInside)
		render.CopyRenderTargetToTexture(CORR_SNAP_RT)

		render.SetStencilEnable(true)
		render.SetStencilTestMask(255)
		render.ClearStencil()
		render.SetStencilFailOperation(STENCIL_KEEP)
		render.SetMaterial(INVISIBLE_MAT)

		local matrix = Matrix()
		matrix:SetTranslation(self:GetPos())

		-- Common op state: mark on z-pass, keep on z-fail
		render.SetStencilCompareFunction(STENCIL_ALWAYS)
		render.SetStencilPassOperation(STENCIL_REPLACE)
		render.SetStencilZFailOperation(STENCIL_KEEP)

		local trueScale = Vector(radius, radius, radius)
		local expandedScale = trueScale * STENCIL_EXPAND

		-- GREEN source (bit 2): "the effect at this pixel is not hidden
		-- behind foreground world".  Fully inside the volume there is no
		-- suppression at all (fullscreen quad below); everywhere else,
		-- visible = world beyond the expanded volume (expanded BACK faces
		-- z-pass) OR behind the true front surface (folded into the
		-- true-front draw further down).  One formulation for all outside
		-- distances.
		if not eyeInside then
			matrix:SetScale(expandedScale)
			render.SetStencilWriteMask(2)
			render.SetStencilReferenceValue(2)
			cam.PushModelMatrix(matrix)
			render.DrawSphere(VECTOR_ZERO, -1, 24, 24)
			cam.PopModelMatrix()
		end

		-- RED source (bit 1): world surface inside the TRUE sphere
		matrix:SetScale(trueScale)
		cam.PushModelMatrix(matrix)

		if eyeInside then
			-- Front surface is behind the eye: a pixel is inside the volume
			-- iff its geometry is closer than the back surface (z-fail)
			render.SetStencilWriteMask(1)
			render.SetStencilReferenceValue(1)
			render.SetStencilPassOperation(STENCIL_KEEP)
			render.SetStencilZFailOperation(STENCIL_REPLACE)
			render.DrawSphere(VECTOR_ZERO, -1, 24, 24)
			render.SetStencilPassOperation(STENCIL_REPLACE)
			render.SetStencilZFailOperation(STENCIL_KEEP)
		else
			-- Front faces z-pass -> inside-candidate (bit 1) + "world behind
			-- the true front surface counts as visible" (bit 2)
			render.SetStencilWriteMask(3)
			render.SetStencilReferenceValue(3)
			render.DrawSphere(VECTOR_ZERO, 1, 24, 24)
			-- Back faces z-pass -> geometry beyond the sphere, clear bit 1
			render.SetStencilWriteMask(1)
			render.SetStencilReferenceValue(0)
			render.DrawSphere(VECTOR_ZERO, -1, 24, 24)
		end

		cam.PopModelMatrix()

		-- Rasterise the bit-planes into colour channels (additive)
		render.Clear(0, 0, 0, 255, false, false)
		render.SetStencilPassOperation(STENCIL_KEEP)
		render.SetStencilCompareFunction(STENCIL_EQUAL)
		blitMat:SetTexture("$basetexture", "vgui/white")
		render.OverrideBlend(true, BLEND_ONE, BLEND_ONE, BLENDFUNC_ADD)

		-- RED: inside
		render.SetStencilTestMask(1)
		render.SetStencilReferenceValue(1)
		setBlitTint(1, 0, 0, 1)
		render.SetMaterial(blitMat)
		render.DrawScreenQuad()

		-- GREEN: effect not hidden by foreground world (fullscreen only when
		-- fully inside the volume)
		if eyeInside then
			render.SetStencilEnable(false)
		else
			render.SetStencilTestMask(2)
			render.SetStencilReferenceValue(2)
		end

		setBlitTint(0, 1, 0, 1)
		render.SetMaterial(blitMat)
		render.DrawScreenQuad()

		render.OverrideBlend(false)
		render.SetStencilEnable(false)
		render.CopyRenderTargetToTexture(CORR_MASK_RT)

		-- Restore the screen exactly
		setBlitTint(1, 1, 1, 1)
		blitMat:SetTexture("$basetexture", CORR_SNAP_RT)
		render.SetMaterial(blitMat)
		render.DrawScreenQuad()

		-- Soft edge for the visibility fade
		maskBlurPass(CORR_MASK_RT, CORR_MBLUR_A, 1, 0, 3)
		maskBlurPass(CORR_MBLUR_A, CORR_MBLUR_B, 0, 1, 3)
	end

	local render_UpdateScreenEffectTexture = _G.render.UpdateScreenEffectTexture
	local render_SetMaterial = _G.render.SetMaterial
	local render_DrawScreenQuad = _G.render.DrawScreenQuad
	local DrawColorModify = _G.DrawColorModify
	local mat_SetFloat = FindMetaTable("IMaterial").SetFloat
	local mat_SetInt = FindMetaTable("IMaterial").SetInt
	local math_Clamp = _G.math.Clamp
	local math_max = _G.math.max
	-- Intensity k in [0.5..2] -> effect strength s in [0..1]
	local function effectStrength(self)
		local k = math_Clamp(self:GetIntensity() or 1, 0, 2)
		local s0 = math_Clamp((k - 0.5) / 1.5, 0, 1)
		local sSmooth = (s0 * s0) * (3 - 2 * s0) -- smoothstep(0..1)

		return math_Clamp(0.5 * (s0 + sSmooth) + 0.08, 0, 1)
	end

	function ENT:_DrawCorruption()
		if not CVAR_DRAW_CORRUPTION:GetBool() then return end
		-- Out of the world (noclip void / out of map bounds) the engine never
		-- repaints the framebuffer, so the screen-space grading feeds back on
		-- its own output and the intersection-mask rasterisation persists
		if bit.band(util.PointContents(EyePos()), CONTENTS_SOLID) ~= 0 then return end

		-- First corrupted area actually drawn on this client pays for the RTs
		ensureCorruptionResources()

		if corruptionMat then
			-- Custom shader path: one pass does the grading, refraction and the
			-- noise-eaten flame boundary.  The expanded stencil only culls and
			-- provides world occlusion.
			local radius = math_max(1, self:GetRadius() or 500)
			local eyeInside = EyePos():Distance(self:GetPos()) < radius
			buildIntersectionMask(self, radius, eyeInside)

			self:_DrawSphere(function()
				-- Raw intensity: the shader computes the grading strength and
				-- the flame ramp (invisible < 1.25, fully black at 2) from it
				local k = math_Clamp(self:GetIntensity() or 1, 0, 2)
				local vs = render.GetViewSetup(true)
				local origin, ang = vs.origin, vs.angles
				local fwd = ang:Forward()
				local right = ang:Right()
				local up = ang:Up()

				-- Calibrate the shader's ray reconstruction against the real
				-- projection via ToScreen probes: for a point at fwd + right,
				-- the ray model gives ndcX = 1 / halfW (and likewise up/halfH),
				-- so measuring where the engine actually projects it yields
				-- exact half-tangents: immune to fov/aspect conventions.
				local probeR = (origin + (fwd + right) * 512):ToScreen()
				local probeU = (origin + (fwd + up) * 512):ToScreen()
				local ndcR = (probeR.x / ScrW()) * 2 - 1
				local ndcU = 1 - (probeU.y / ScrH()) * 2
				local halfW = 1 / math.max(0.05, ndcR)
				local halfH = 1 / math.max(0.05, ndcU)
				local pos = self:GetPos()

				render_UpdateScreenEffectTexture()
				corruptionMat:SetTexture("$basetexture", render.GetScreenEffectTexture())
				corruptionMat:SetFloat("$c0_x", pos.x)
				corruptionMat:SetFloat("$c0_y", pos.y)
				corruptionMat:SetFloat("$c0_z", pos.z)
				corruptionMat:SetFloat("$c0_w", radius)
				corruptionMat:SetFloat("$c1_x", origin.x)
				corruptionMat:SetFloat("$c1_y", origin.y)
				corruptionMat:SetFloat("$c1_z", origin.z)
				-- wrapped: unbounded CurTime degrades the noise hash precision
				corruptionMat:SetFloat("$c1_w", math.fmod(CurTime(), 1000))
				corruptionMat:SetFloat("$c2_x", fwd.x)
				corruptionMat:SetFloat("$c2_y", fwd.y)
				corruptionMat:SetFloat("$c2_z", fwd.z)
				corruptionMat:SetFloat("$c2_w", k)
				corruptionMat:SetFloat("$c3_x", right.x * halfW)
				corruptionMat:SetFloat("$c3_y", right.y * halfW)
				corruptionMat:SetFloat("$c3_z", right.z * halfW)
				corruptionMat:SetFloat("$c3_w", halfH)
				render_SetMaterial(corruptionMat)
				render_DrawScreenQuad(true)
			end, STENCIL_EXPAND)

			return
		end

		-- Legacy fallback (no custom shaders, e.g. non-Windows): hard sphere
		-- silhouette with color modify + water warp
		self:_DrawSphere(function()
			local s = effectStrength(self)

			-- Compute post-process values from s: moderate contrast, clear desaturation, slight darken
			local cm = {
				["$pp_colour_addr"] = 0,
				["$pp_colour_addg"] = 0,
				["$pp_colour_addb"] = 0,
				["$pp_colour_brightness"] = -0.04 * s,
				["$pp_colour_contrast"] = 1 + 1.0 * s,
				["$pp_colour_colour"] = math_max(0, 1 - 1.1 * s),
				["$pp_colour_mulr"] = 0,
				["$pp_colour_mulg"] = 0,
				["$pp_colour_mulb"] = 0,
			}

			DrawColorModify(cm)

			mat_SetFloat(SHADER_MAT, "$envmap", 0)
			mat_SetFloat(SHADER_MAT, "$envmaptint", 0 )
			mat_SetInt(SHADER_MAT, "$ignorez", 1)
			mat_SetFloat(SHADER_MAT, "$refractamount", 0.05 * s)

			render_UpdateScreenEffectTexture()
			render_SetMaterial(SHADER_MAT)
			render_DrawScreenQuad(true)
		end)
	end

	local function updateRenderBounds(self)
		-- Symmetric: the sphere reaches a full radius below the origin too, and
		-- a box that stops at -32 lets the engine cull Draw when only the lower
		-- part of the area is on screen
		local r = math.max(64, (self:GetRadius() or 100) + 64)
		self:SetRenderBounds(Vector(-r, -r, -r), Vector(r, r, r))
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

	-- The world-intersection flames make the boundary readable from inside,
	-- so no interior wall sphere is drawn anymore.
	function ENT:DrawTranslucent()
	end

	function ENT:Draw()
		self:_DrawCorruption()
	end

	function ENT:OnRemove()
	end

	-- HUD status message for players inside corruption
	local corruptionCache = {
		inCorruption = false,
		lastUpdate = 0,
	}

	function ENT:UpdateCorruptionStatus()
		local ply = LocalPlayer()
		if not IsValid(ply) then return end

		local intensity = self:GetIntensity() or 0
		if intensity < 0.5 then return end -- Not visible

		local plyPos = ply:GetPos()
		local center = self:GetPos()
		local radius = self:GetRadius() or 500
		local dist = plyPos:Distance(center)

		if dist <= radius then
			corruptionCache.inCorruption = true
		end
	end

	-- Custom color for corruption warning
	local TEXT_DANGER = Color(220, 100, 90, 255)

	-- Periodic update hook (runs less frequently than HUDPaint)
	hook.Add("Think", "Arcana_UpdateCorruptionStatus", function()
		local now = CurTime()
		if now - corruptionCache.lastUpdate < 1 then return end

		corruptionCache.lastUpdate = now
		corruptionCache.inCorruption = false

		-- Let each entity update the status
		for _, ent in ipairs(ents.FindByClass("arcana_corrupted_area")) do
			if IsValid(ent) and ent.UpdateCorruptionStatus then
				ent:UpdateCorruptionStatus()
			end
		end
	end)

	local TEXT_STATUS_COLOR = Color(0, 0, 0, 200)
	hook.Add("HUDPaint", "Arcana_CorruptionStatus", function()
		if not corruptionCache.inCorruption then return end

		local scrW, scrH = ScrW(), ScrH()
		local scale = math.min(1, scrH / 1080)
		local panelW = math.floor(math.min(scrW * 0.5, 600) * scale)
		local panelH = math.floor(56 * scale)
		local x = math.floor((scrW - panelW) * 0.5)
		local y = math.floor(24 * scale)

		local titleY = 8
		local subtitleY = 34

		-- Draw hex panel
		ArtDeco.DrawHexFill(x, y, panelW, panelH, 255)
		ArtDeco.DrawHexFrame(x, y, panelW, panelH, 255)

		-- Draw flourish centered between the two text lines
		local centerX = x + panelW * 0.5
		local centerY = y + math.floor((titleY + subtitleY) * 0.5) + 10
		ArtDeco.DrawStatusFlourish(centerX, centerY, panelW)

		-- Title
		local title = string.upper("Corrupted Area")

		-- Draw with subtle shadow
		draw.SimpleText(title, "Arcana_Ancient", centerX + 1, y + titleY + 1, TEXT_STATUS_COLOR, TEXT_ALIGN_CENTER)
		draw.SimpleText(title, "Arcana_Ancient", centerX, y + titleY, TEXT_DANGER, TEXT_ALIGN_CENTER)

		-- Subtext about ritual
		local ritualText = "Use the Purification ritual to cleanse"
		draw.SimpleText(ritualText, "Arcana_AncientSmall", centerX + 1, y + subtitleY + 1, TEXT_STATUS_COLOR, TEXT_ALIGN_CENTER)
		draw.SimpleText(ritualText, "Arcana_AncientSmall", centerX, y + subtitleY, ArtDeco.Colors.textBright, TEXT_ALIGN_CENTER)
	end)
end