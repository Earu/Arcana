AddCSLuaFile()

if SERVER then
	require("shader_to_gma")
	-- Register GPU particle shaders
	resource.AddShader("arcana_particles_vs30")
	resource.AddShader("arcana_particles_ps30")
	resource.AddShader("arcana_particles_simple_vs30")
	return
 end

--[[
	GPU Particle System for Arcana

	This system renders particles entirely on the GPU with minimal CPU interaction.
	Once initialized, particles simulate themselves using vertex shaders.

	Usage:
		local particles = Arcana.GPUParticles.Create({
			maxParticles = 1000,
			lifetime = 2.0,
			spawnPosition = Vector(0, 0, 0),
			spawnRadius = 25,
			velocity = Vector(0, 0, 100),
			velocityVariance = 25,
			gravity = Vector(0, 0, 15),
			airResistance = 40,
			particleSize = 20,
			sizeVariance = 0.5,
			color = Color(255, 180, 50),
			texture = "effects/fire_cloud1",
		})

		-- In your draw function:
		particles:Draw()

		-- Update spawn position if needed:
		particles:SetSpawnPosition(newPos)

		-- Clean up:
		particles:Destroy()
]]

Arcana = Arcana or {}
Arcana.GPUParticles = Arcana.GPUParticles or {}

local GPUParticleSystem = {}
GPUParticleSystem.__index = GPUParticleSystem

-- Material cache
local particleMaterials = {}
local materialCounter = 0

-- Create a new GPU particle system
function Arcana.GPUParticles.Create(config)
	local self = setmetatable({}, GPUParticleSystem)

	-- Configuration
	self.maxParticles = config.maxParticles or 500
	self.lifetime = config.lifetime or 2.0
	self.spawnPosition = config.spawnPosition or Vector(0, 0, 0)
	self.spawnRadius = config.spawnRadius or 25
	self.velocity = config.velocity or Vector(0, 0, 100)
	self.velocityVariance = config.velocityVariance or 25
	self.gravity = config.gravity or Vector(0, 0, 15)
	self.airResistance = config.airResistance or 40
	self.particleSize = config.particleSize or 20 -- Start size
	self.sizeVariance = config.sizeVariance or 0.5
	self.endSize = config.endSize -- End size (nil = same as start)
	self.startAlpha = config.startAlpha or 255 -- Start alpha
	self.endAlpha = config.endAlpha or 0 -- End alpha
	self.roll = config.roll or 0 -- Initial rotation variance (e.g., 180 for -180 to 180)
	self.rollDelta = config.rollDelta or 0 -- Rotation speed variance (e.g., 8 for -8 to 8 deg/sec)
	self.color = config.color or Color(255, 255, 255)
	self.texture = config.texture or "effects/fire_cloud1"

	-- State
	self.birthTime = RealTime()
	self.enabled = true
	self.seedOffset = math.random() * 1000

	-- Create material
	self:CreateMaterial()

	-- Build mesh
	self:BuildMesh()

	return self
end

-- Create shader material for this particle system
function GPUParticleSystem:CreateMaterial()
	materialCounter = materialCounter + 1
	local matName = "arcana_gpu_particles_" .. materialCounter

	-- Check if shaders are loaded
	if not file.Exists("shaders/fxc/arcana_particles_vs30.vcs", "GAME") then
		ErrorNoHalt("[Arcana GPU Particles] Shaders not compiled! Run shader compiler on arcana_particles_vs30.hlsl and arcana_particles_ps30.hlsl\n")
		return
	end

	-- Create material using shader_to_gma helper if available
	if CreateShaderMaterial then
		self.material = CreateShaderMaterial(matName, {
			["$pixshader"] = "arcana_particles_ps30",
			["$vertexshader"] = "arcana_particles_vs30",  -- Main shader
			["$basetexture"] = self.texture,
			["$vertexcolor"] = 1,
			["$cull"] = 0,
			["$ignorez"] = 1,           -- REQUIRED for screenspace_general
			["$vertextransform"] = 1,   -- Ensures worldspace transforms
			["$translucent"] = 1,       -- Enable transparency
		})
	else
		-- Fallback: create material manually
		self.material = CreateMaterial(matName, "screenspace_general", {
			["$pixshader"] = "arcana_particles_ps30",
			["$vertexshader"] = "arcana_particles_vs30",
			["$basetexture"] = self.texture,
			["$vertexcolor"] = 1,
			["$ignorez"] = 1,
			["$vertextransform"] = 1,
			["$cull"] = 0,
			["$translucent"] = 1,
		})
	end

	if not self.material or self.material:IsError() then
		ErrorNoHalt("[Arcana GPU Particles] Failed to create material!\n")
		return
	end

	-- Force texture to load (especially important for sprite textures)
	local sourceMat = Material(self.texture)
	if sourceMat and not sourceMat:IsError() then
		local sourceTexture = sourceMat:GetTexture("$basetexture")
		if sourceTexture then
			self.material:SetTexture("$basetexture", sourceTexture)
			self.material:Recompute()
		end
	end
end

-- Build the particle mesh (using quads instead of points for better compatibility)
function GPUParticleSystem:BuildMesh()
	-- Create mesh
	self.mesh = Mesh()

	-- Build particle data as quads (4 vertices per particle)
	mesh.Begin(self.mesh, MATERIAL_QUADS, self.maxParticles)

	-- Use relative time (time=0 at particle system creation)
	-- Particles are staggered in the past so they appear to loop continuously
	for i = 1, self.maxParticles do
		-- Each particle is a quad with custom data
		local particleID = i
		local lifetimeVariance = math.Rand(0.7, 1.3)

		-- Birth time relative to particle system creation (negative = born in the past)
		-- Stagger particles across the lifetime so they loop continuously
		local birthTime = -(i / self.maxParticles) * self.lifetime * lifetimeVariance

		-- Initial velocity with variance
		local vel = self.velocity + VectorRand() * self.velocityVariance

		-- Roll: random initial rotation and rotation speed
		local roll = math.Rand(-self.roll, self.roll) -- Degrees
		local rollDelta = math.Rand(-self.rollDelta, self.rollDelta) -- Degrees per second

		-- Color with slight variance
		local r = math.Clamp(self.color.r + math.Rand(-20, 20), 0, 255)
		local g = math.Clamp(self.color.g + math.Rand(-20, 20), 0, 255)
		local b = math.Clamp(self.color.b + math.Rand(-20, 20), 0, 255)
		local a = self.color.a or 255

		-- Create quad (4 vertices) - will be transformed in vertex shader
		-- The vertex shader will position these based on camera
		local quadVerts = {
			{u = 0, v = 0}, -- Bottom-left
			{u = 1, v = 0}, -- Bottom-right
			{u = 1, v = 1}, -- Top-right
			{u = 0, v = 1}, -- Top-left
		}

		for _, vert in ipairs(quadVerts) do
			-- Store particle ID in position.x, quad corner in position.yz
			mesh.Position(particleID, vert.u - 0.5, vert.v - 0.5)
			-- Birth time in UV.x, roll delta in UV.y
			mesh.TexCoord(0, birthTime, rollDelta, 0)
			-- Quad UVs in UserData (TANGENT semantic) xy=quad UV, z=lifetime, w=roll
			mesh.UserData(vert.u, vert.v, lifetimeVariance, roll)
			mesh.Color(self.color.r, self.color.g, self.color.b, self.color.a)
			-- Store velocity in normal
			mesh.Normal(Vector(vel.x, vel.y, vel.z))
			mesh.AdvanceVertex()
		end
	end

	mesh.End()
end

-- Update spawn position
function GPUParticleSystem:SetSpawnPosition(pos)
	self.spawnPosition = pos
end

-- Update velocity
function GPUParticleSystem:SetVelocity(vel)
	self.velocity = vel
end

-- Enable/disable particles
function GPUParticleSystem:SetEnabled(enabled)
	self.enabled = enabled
end

-- Draw the particle system
function GPUParticleSystem:Draw()
	if not self.enabled then return end
	if not self.mesh or not self.material or self.material:IsError() then return end

	-- Set shader constants using ambient cube hack for vertex shader (Example 6 method)
	local time = RealTime() - self.birthTime
	local endSize = self.endSize or self.particleSize

	-- Use render.SetModelLighting to pass data to vertex shader
	-- Direction 0: time, lifetime, particleSize
	-- Direction 1: endSize, startAlpha, endAlpha
	render.SuppressEngineLighting(true)
	render.SetModelLighting(0, time, self.lifetime, self.particleSize)  -- cAmbientCubeX[0]
	render.SetModelLighting(1, endSize, self.startAlpha / 255.0, self.endAlpha / 255.0)  -- cAmbientCubeX[1]

	-- Need to draw a dummy model to force engine to set up lighting
	if not self._dummyModel then
		self._dummyModel = ClientsideModel("models/hunter/plates/plate.mdl")
		self._dummyModel:SetNoDraw(true)
		self._dummyModel:SetModelScale(0)  -- Make invisible
	end
	if IsValid(self._dummyModel) then
		self._dummyModel:DrawModel()
	end

	render.SuppressEngineLighting(false)

	-- Pixel shader constants (these work normally)
	self.material:SetFloat("$c0_x", time)

	-- Position the particle system at spawn position
	local mat = Matrix()
	mat:SetTranslation(self.spawnPosition)
	cam.PushModelMatrix(mat)

	-- Render mesh
	render.SetMaterial(self.material)

	-- Override depth for proper rendering (required for IMesh with custom shaders)
	render.OverrideDepthEnable(true, false)  -- Enable depth test, disable depth write

	-- Set additive blending for fire effect
	render.OverrideBlend(true, BLEND_SRC_ALPHA, BLEND_ONE, BLENDFUNC_ADD)

	-- Draw the mesh
	self.mesh:Draw()

	-- Reset render states
	render.OverrideBlend(false)
	render.OverrideDepthEnable(false)

	-- Pop model matrix
	cam.PopModelMatrix()
end

-- Cleanup
function GPUParticleSystem:Destroy()
	if self.mesh then
		self.mesh:Destroy()
		self.mesh = nil
	end

	if IsValid(self._dummyModel) then
		self._dummyModel:Remove()
		self._dummyModel = nil
	end

	self.enabled = false
end

-- Convenient presets
Arcana.GPUParticles.Presets = {
	-- Fire particles (like brazier fire)
	Fire = {
		lifetime = 2.0,
		spawnRadius = 25,
		velocity = Vector(0, 0, 100),
		velocityVariance = 25,
		gravity = Vector(0, 0, 15),
		airResistance = 40,
		particleSize = 30,
		sizeVariance = 0.5,
		color = Color(255, 180, 50, 255),
		texture = "effects/fire_cloud1",
	},

	-- Magic levitation particles (like brazier magic)
	MagicLevitation = {
		lifetime = 2.0,
		spawnRadius = 60,
		velocity = Vector(0, 0, 80),
		velocityVariance = 15,
		gravity = Vector(0, 0, 0),
		airResistance = 25,
		particleSize = 6,
		sizeVariance = 0.3,
		color = Color(255, 160, 50, 220),
		texture = "sprites/light_glow02_add",
	},

	-- Embers
	Embers = {
		lifetime = 1.0,
		spawnRadius = 15,
		velocity = Vector(0, 0, 60),
		velocityVariance = 20,
		gravity = Vector(0, 0, -10),
		airResistance = 50,
		particleSize = 2,
		sizeVariance = 0.5,
		color = Color(255, 140, 30, 200),
		texture = "sprites/light_glow02_add",
	},

	-- Magic sparkles
	Sparkles = {
		lifetime = 1.5,
		spawnRadius = 30,
		velocity = Vector(0, 0, 40),
		velocityVariance = 30,
		gravity = Vector(0, 0, 0),
		airResistance = 60,
		particleSize = 4,
		sizeVariance = 0.8,
		color = Color(150, 200, 255, 200),
		texture = "sprites/light_glow02_add",
	},
}

print("[Arcana] GPU Particle System loaded")
