AddCSLuaFile()
ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "Corruption Test"
ENT.Category = "Arcana"
ENT.Spawnable = true
ENT.AdminOnly = true
require("shader_to_gma")

if SERVER then
	resource.AddShader("arcana_corruption_ps30")

	function ENT:Initialize()
		self:SetModel("models/props_borealis/bluebarrel001.mdl")
		self:SetMoveType(MOVETYPE_NONE)
		self:SetSolid(SOLID_VPHYSICS)
		self:PhysicsInit(SOLID_VPHYSICS)
	end
end

if CLIENT then
	-- Configuration
	local WORLD_RADIUS = 500 -- Pollution sphere radius in world units

	local INVISIBLE_MAT = CreateMaterial("arcana_corruption_stencil", "UnlitGeneric", {
		["$basetexture"] = "color/white",
		["$alpha"] = "0",
		["$translucent"] = "1"
	})

	local function corruption_test(self)
		if not IsValid(self) then return end
		local world_pos = self:GetPos()
		local player_pos = LocalPlayer():GetPos()
		local distance = player_pos:Distance(world_pos)
		-- Update framebuffer for post-processing
		render.UpdateScreenEffectTexture()
		self.ShaderMat:SetFloat("$c0_x", CurTime())
		-- Set corruption intensity
		local intensity = 1.2
		self.ShaderMat:SetFloat("$c0_y", intensity)
		self.ShaderMat:SetFloat("$c1_x", 0.5)
		self.ShaderMat:SetFloat("$c1_y", 0.5)
		self.ShaderMat:SetFloat("$c0_z", 1.6)
		self.ShaderMat:SetFloat("$c0_w", 0) -- World-space mode

		-- Check if player is inside the sphere
		if distance < WORLD_RADIUS then
			-- INSIDE SPHERE: Render corruption on entire screen (no stencil needed)
			render.SetMaterial(self.ShaderMat)
			render.DrawScreenQuad()
		else
			-- OUTSIDE SPHERE: Use stencil to mask to sphere shape
			-- Step 1: Set up stencil buffer
			render.SetStencilEnable(true)
			render.SetStencilWriteMask(1)
			render.SetStencilTestMask(1)
			render.SetStencilReferenceValue(1)
			-- Step 2: Clear stencil and write sphere to stencil buffer
			render.ClearStencil()
			render.SetStencilCompareFunction(STENCIL_ALWAYS)
			render.SetStencilPassOperation(STENCIL_REPLACE)
			render.SetStencilFailOperation(STENCIL_KEEP)
			render.SetStencilZFailOperation(STENCIL_KEEP)
			-- Draw invisible sphere to stencil buffer
			render.SetMaterial(INVISIBLE_MAT)
			-- Draw sphere at entity position
			local matrix = Matrix()
			matrix:SetTranslation(world_pos)
			matrix:SetScale(Vector(WORLD_RADIUS, WORLD_RADIUS, WORLD_RADIUS))
			cam.PushModelMatrix(matrix)
			render.DrawSphere(Vector(0, 0, 0), 1, 16, 16) -- Unit sphere (scaled by matrix)
			cam.PopModelMatrix()
			-- Step 3: Set stencil to only draw where sphere was rendered
			render.SetStencilCompareFunction(STENCIL_EQUAL)
			render.SetStencilPassOperation(STENCIL_KEEP)
			render.SetMaterial(self.ShaderMat)
			render.DrawScreenQuad()
			render.SetStencilEnable(false)
		end
	end

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
			$alpha_blend               1 // whether or not to enable alpha blend
			$linearwrite               1 // to disable broken gamma correction for colors
			$linearread_basetexture    1 // to disable broken gamma correction for textures
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

	function ENT:Initialize()
		self.ShaderMat = create_shader_mat("arcana_corruption" .. self:EntIndex(), {
			-- pixshader/vertexshader must end with _ps30/_vs30/_ps20b
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

		hook.Add("PostDrawOpaqueRenderables", self, function(_, _, _, sky3d)
			if sky3d then return end
			corruption_test(self)
		end)
	end
end