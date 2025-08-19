AddCSLuaFile()

ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "Corrupted Area"
ENT.Category = "Arcana"
ENT.Spawnable = false
ENT.AdminOnly = false
ENT.RenderGroup = RENDERGROUP_BOTH

require("shader_to_gma")

function ENT:SetupDataTables()
	self:NetworkVar("Float", 0, "Radius")
end

if SERVER then
	resource.AddShader("arcana_corruption_ps30")

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
			self:SetRadius(500)
		end

		-- Wisp spawn control
		self._wisps = {}
		self._maxWisps = 3
		self._spawnInterval = 8
		self._nextWispSpawn = CurTime() + 3
		-- Idle timeout (despawn when no players for a while)
		self._lastPlayerPresence = CurTime()
		self._despawnGrace = 15
	end

	local function playerInRange(center, radius)
		radius = radius or 0
		local r2 = radius * radius
		for _, ply in ipairs(player.GetAll()) do
			if IsValid(ply) and ply:Alive() and ply:GetPos():DistToSqr(center) <= r2 then
				return true
			end
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
		-- Bind the wisp to this area
		ent._areaCenter = Vector(center)
		ent._areaRadius = radius

		self._wisps[#self._wisps + 1] = ent
		ent:CallOnRemove("Arcana_WispRemoved" .. ent:EntIndex(), function()
			for i = #self._wisps, 1, -1 do
				if not IsValid(self._wisps[i]) then table.remove(self._wisps, i) end
			end
		end)
	end

	function ENT:Think()
		local now = CurTime()
		local center = self:GetPos()
		local radius = self:GetRadius() or 500
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
			if (#self._wisps) < (self._maxWisps or 3) then
				self:_SpawnWisp()
			end
			self._nextWispSpawn = now + (self._spawnInterval or 8)
		end

		-- Despawn wisps if area idle for too long
		if (now - (self._lastPlayerPresence or now)) > (self._despawnGrace or 15) then
			for i = #self._wisps, 1, -1 do
				local w = self._wisps[i]
				if IsValid(w) then w:Remove() end
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
				if IsValid(w) then w:Remove() end
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

	-- Subtle darkening overlay for corrupted area
	local DARKEN_MAT = CreateMaterial("arcana_corruption_darken", "UnlitGeneric", {
		["$basetexture"] = "color/black",
		["$alpha"] = "0.18",
		["$additive"] = "0",
		["$translucent"] = "1"
	})

	-- Dedicated font for corrupted glyphs (avoid dependency on circles.lua fonts)
	surface.CreateFont("Arcana_CorruptGlyph", {
		font = "Arial",
		size = 80,
		weight = 700,
		antialias = true
	})

	-- 3D2D scale used for glyph drawing (world units per 1/scale of 2D units)
	local GLYPH_SCALE = 0.06

	-- Screenspace material template
	local shader_mat = [==[
		screenspace_general
		{
			$pixshader ""
			$vertexshader ""

			$basetexture ""
			$texture1    ""
			$texture2    ""
			$texture3    ""

			// Mandatory, don't touch
			$ignorez            1
			$vertexcolor        1
			$vertextransform    1
			"<dx90"
			{
				$no_draw 1
			}

			$copyalpha                 0
			$alpha_blend_color_overlay 0
			$alpha_blend               1
			$linearwrite               1
			$linearread_basetexture    1
		}
	]==]

	local function create_shader_mat(name, opts)
		local key_values = util.KeyValuesToTable(shader_mat, false, true)
		if opts then
			for k, v in pairs(opts) do
				key_values[k] = v
			end
		end

		return CreateMaterial(name, "screenspace_general", key_values)
	end

	local function drawCorruption(self)
		if not IsValid(self) then return end

		local world_pos = self:GetPos()
		local player_pos = LocalPlayer():GetPos()
		local distance = player_pos:Distance(world_pos)
		local radius = math.max(1, self:GetRadius() or 500)

		-- Update framebuffer for post-processing
		render.UpdateScreenEffectTexture()
		self.ShaderMat:SetFloat("$c0_x", CurTime())

		-- Tunables with subtle flicker/jitter
		local t = CurTime()
		local intensity = 1.6
		self.ShaderMat:SetFloat("$c0_y", intensity)
		self.ShaderMat:SetFloat("$c1_x", 0.5 + 0.02 * math.sin(t * 1.9))
		self.ShaderMat:SetFloat("$c1_y", 0.5 + 0.02 * math.cos(t * 2.3))
		self.ShaderMat:SetFloat("$c0_z", 1.7)
		self.ShaderMat:SetFloat("$c0_w", 0) -- World-space mode

		local function drawDarkOverlay()
			render.SetMaterial(DARKEN_MAT)
			render.DrawScreenQuad()
		end

		if distance < radius then
			-- Inside corruption volume: full-screen pass + darken overlay
			render.SetMaterial(self.ShaderMat)
			render.DrawScreenQuad()
			drawDarkOverlay()
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
			render.SetMaterial(self.ShaderMat)
			render.DrawScreenQuad()
			-- Darken within the mask as well
			drawDarkOverlay()
			render.SetStencilEnable(false)
		end
	end

	-- Corrupted glyph particle system (spread out and darker)
	local EVIL_GLYPHS = {
		"Α", "Β", "Γ", "Δ", "Ε", "Ζ", "Η", "Θ", "Ι", "Κ", "Λ", "Μ", "Ν", "Ξ", "Ο",
		"Π", "Ρ", "Σ", "Τ", "Υ", "Φ", "Χ", "Ψ", "Ω", "α", "β", "γ", "δ", "ε", "ζ",
		"η", "θ", "ι", "κ", "λ", "μ", "ν", "ξ", "ο", "π", "ρ", "σ", "τ", "υ", "φ",
		"χ", "ψ", "ω"
	}

	local function pickGlyph()
		return EVIL_GLYPHS[math.random(1, #EVIL_GLYPHS)] or "*"
	end

	function ENT:PrepareCorruptGlyphs()
		self._glyphParticles = {}
		self._glyphSpawnRate = 10
		self._glyphMaxParticles = 150
		self._glyphSpawnAccumulator = 0
		-- Seed some initial glyphs so the area looks active right away
		for i = 1, math.min(1, self._glyphMaxParticles or 1) do
			self:_SpawnCorruptGlyph()
		end
	end

	function ENT:_SpawnCorruptGlyph()
		local now = CurTime()
		local radius = math.max(1, self:GetRadius() or 200)
		local ang = math.Rand(0, math.pi * 2)
		local r = math.Rand(-radius, radius)
		local baseX = math.cos(ang) * r
		local baseY = math.sin(ang) * r
		-- Compute travel so glyph reaches top of the corruption sphere
		local targetWorldHeight = math.sqrt(math.max(0, radius * radius - (baseX * baseX + baseY * baseY))) * 0.5
		local travel = math.max(0, targetWorldHeight / GLYPH_SCALE)
		local lifeSeconds = math.Rand(3.0, 7.0)
		local speed = travel / lifeSeconds
		-- No horizontal drift/orbit, only vertical movement
		local driftX = 0
		local driftY = 0
		local orbitRadius = 0
		local orbitSpeed = 0
		local orbitPhase = 0

		local particle = {
			born = now,
			dieAt = now + lifeSeconds,
			h = 0,
			speed = speed,
			travel = travel,
			char = pickGlyph(),
			alpha = math.random(200, 255),
			baseX = baseX,
			baseY = baseY,
			driftX = driftX,
			driftY = driftY,
			orbitR = orbitRadius,
			orbitW = orbitSpeed,
			orbitP = orbitPhase,
			rot = math.Rand(0, 360),
			rotSpeed = math.Rand(-40, 40),
			-- jitter/glitch params (pixels in 3D2D space)
			jxAmp = math.random(1, 5),
			jyAmp = math.random(1, 4),
			jxW = math.Rand(8, 18),
			jyW = math.Rand(9, 20),
			jxP = math.Rand(0, math.pi * 2),
			jyP = math.Rand(0, math.pi * 2),
			glitchChance = 0.05,
			glitchPx = math.random(6, 14),
			-- teleport burst params (world units)
			nextTp = now + math.Rand(0.5, 2.5),
			tpDur = math.Rand(0.05, 0.15),
			tpMax = math.max(16, radius * 0.25),
			tpx = 0,
			tpy = 0
		}

		self._glyphParticles[#self._glyphParticles + 1] = particle
	end

	local function updateRenderBounds(self)
		local r = math.max(64, (self:GetRadius() or 100) + 64)
		self:SetRenderBounds(Vector(-r, -r, -32), Vector(r, r, r))
	end

	function ENT:Initialize()
		self.ShaderMat = create_shader_mat("arcana_corruption_" .. self:EntIndex(), {
			["$pixshader"] = "arcana_corruption_ps30",
			["$basetexture"] = "_rt_FullFrameFB",
			["$c0_x"] = 0,
			["$c0_y"] = 0.8,
			["$c0_z"] = 0.4,
			["$c0_w"] = 0.0,
			["$c1_x"] = 0.5,
			["$c1_y"] = 0.5,
			["$c1_z"] = 0.4,
			["$c1_w"] = 0.6,
		})

		-- Hook to draw corruption screenspace effect
		hook.Add("PostDrawOpaqueRenderables", self, function(_, _, _, sky3d)
			if sky3d then return end
			drawCorruption(self)
		end)

		self:PrepareCorruptGlyphs()
		updateRenderBounds(self)
		self._lastUpdate = CurTime()
	end

	function ENT:Think()
		-- Spawn/update evil glyph particles (use CurTime delta for stable speed)
		local now = CurTime()
		local dt = math.Clamp(now - (self._lastUpdate or now), 0, 0.2)
		self._lastUpdate = now
		self._glyphSpawnAccumulator = (self._glyphSpawnAccumulator or 0) + (self._glyphSpawnRate or 24) * dt
		local toSpawn = math.floor(self._glyphSpawnAccumulator)
		self._glyphSpawnAccumulator = self._glyphSpawnAccumulator - toSpawn

		if self._glyphParticles and (#self._glyphParticles < (self._glyphMaxParticles or 90)) then
			for i = 1, math.min(toSpawn, (self._glyphMaxParticles or 90) - #self._glyphParticles) do
				self:_SpawnCorruptGlyph()
			end
		end

		if self._glyphParticles and #self._glyphParticles > 0 then
			local write = 1

			for read = 1, #self._glyphParticles do
				local p = self._glyphParticles[read]
				if p and now < (p.dieAt or 0) then
					p.h = (p.h or 0) + (p.speed or 40) * dt
					p.rot = (p.rot or 0) + (p.rotSpeed or 0) * dt
					-- teleport scheduling (instant x/y bursts)
					if p.tpEnd and now >= p.tpEnd then
						p.tpx = 0
						p.tpy = 0
						p.tpEnd = nil
					end
					if (not p.tpEnd) and p.nextTp and now >= p.nextTp then
						local max = p.tpMax or math.max(16, (self:GetRadius() or 100) * 0.25)
						p.tpx = math.Rand(-max, max)
						p.tpy = math.Rand(-max, max)
						p.tpEnd = now + (p.tpDur or math.Rand(0.05, 0.12))
						p.nextTp = now + math.Rand(1.2, 3.5)
					end

					self._glyphParticles[write] = p
					write = write + 1
				end
			end

			for i = write, #self._glyphParticles do
				self._glyphParticles[i] = nil
			end
		end

		updateRenderBounds(self)
		self:SetNextClientThink(CurTime() + 0.05)
		return true
	end

	local OFFSET = Vector(0, 0, 40)
	local MAX_DIST = 3500 * 3500
	function ENT:DrawTranslucent()
		local ply = LocalPlayer()
		if ply:GetPos():DistToSqr(self:GetPos()) > MAX_DIST then return end

		-- Draw corrupted glyphs rising from the ground around the area
		if not self._glyphParticles or #self._glyphParticles == 0 then return end
		surface.SetFont("Arcana_CorruptGlyph")
		local baseTop = self:GetPos() - OFFSET

		--cam.IgnoreZ(true)
		for _, p in ipairs(self._glyphParticles) do
			local now = CurTime()
			local lifeFrac = 1
			if p.dieAt then
				local remain = p.dieAt - now
				local total = (p.dieAt - (p.born or now))
				lifeFrac = math.Clamp(remain / math.max(0.001, total), 0, 1)
			end
			local travelFrac = math.Clamp((p.h or 0) / math.max(1, p.travel or 200), 0, 1)
			local tailFadeStart = 0.85
			local tailFade = travelFrac >= tailFadeStart and (1 - (travelFrac - tailFadeStart) / (1 - tailFadeStart)) or 1
			local alpha = math.floor((p.alpha or 220) * lifeFrac * tailFade)
			if alpha > 0 then
				-- Only vertical rise: keep baseX/baseY fixed
				local worldPos = baseTop + Vector((p.baseX or 0) + (p.tpx or 0), (p.baseY or 0) + (p.tpy or 0), 0)
				local ang = Angle(0, 0, 0)
				if IsValid(ply) then
					ang = (ply:GetPos() - worldPos):Angle()
				end
				ang:RotateAroundAxis(ang:Right(), -90)
				ang:RotateAroundAxis(ang:Up(), 90)

				-- compute per-frame jitter in 3D2D pixels
				local jx = (p.jxAmp or 2) * math.sin(now * (p.jxW or 12) + (p.jxP or 0))
				local jy = (p.jyAmp or 2) * math.cos(now * (p.jyW or 14) + (p.jyP or 0))
				if (p.glitchChance and math.random() < p.glitchChance) then
					jx = jx + math.random(-(p.glitchPx or 8), p.glitchPx or 8)
					jy = jy + math.random(-(p.glitchPx or 8), p.glitchPx or 8)
					alpha = math.floor(alpha * math.Rand(0.6, 1.0))
				end

				cam.Start3D2D(worldPos, ang, GLYPH_SCALE)
					local txt = p.char or "*"
					-- Stroke for contrast
					surface.SetTextColor(0, 0, 0, math.floor(alpha * 0.9))
					surface.SetTextPos(-19 + jx, -math.floor(p.h or 0) - 1 + jy)
					surface.DrawText(txt)
					surface.SetTextPos(-17 + jx, -math.floor(p.h or 0) - 1 + jy)
					surface.DrawText(txt)
					surface.SetTextPos(-19 + jx, -math.floor(p.h or 0) + 1 + jy)
					surface.DrawText(txt)
					surface.SetTextPos(-17 + jx, -math.floor(p.h or 0) + 1 + jy)
					surface.DrawText(txt)
					-- Inner bright text (with jitter)
					surface.SetTextColor(240, 210, 255, alpha)
					surface.SetTextPos(-18 + jx, -math.floor(p.h or 0) + jy)
					surface.DrawText(txt)
					-- Chromatic glitch: magenta/green slight offsets (also jittered)
					surface.SetTextColor(220, 60, 240, math.floor(alpha * 0.75))
					surface.SetTextPos(-16 + jx * 0.8, -math.floor(p.h or 0) + 1 + jy * 0.8)
					surface.DrawText(txt)
					surface.SetTextColor(80, 255, 140, math.floor(alpha * 0.6))
					surface.SetTextPos(-20 + jx * 0.6, -math.floor(p.h or 0) - 1 + jy * 0.6)
					surface.DrawText(txt)
				cam.End3D2D()
			end
		end
	--cam.IgnoreZ(false)
	end

	function ENT:Draw()
		--self:DrawModel()
	end
end