

AddCSLuaFile()
ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "Corruption Test"
ENT.Category = "Arcana"
ENT.Spawnable = true
ENT.AdminOnly = true

if SERVER then
	resource.AddFile("materials/arcana/corruption.vmt")

	function ENT:Initialize()
		self:SetModel("models/props_borealis/bluebarrel001.mdl")
		self:SetMoveType(MOVETYPE_NONE)
		self:SetSolid(SOLID_VPHYSICS)
		self:PhysicsInit(SOLID_VPHYSICS)

		if _G.ShaderToGMA then
			_G.ShaderToGMA({ "arcana_corruption_ps30" })
		end
	end
end

if CLIENT then
	local corruption = Material("arcana/corruption.vmt")

	-- Configuration
	local WORLD_RADIUS = 500  -- Pollution sphere radius in world units

	local function corruption_test(self)
		if not IsValid(self) then return end

		local world_pos = self:GetPos()
		local player_pos = LocalPlayer():GetPos()
		local distance = player_pos:Distance(world_pos)

		-- Update framebuffer for post-processing
		render.UpdateScreenEffectTexture()
		corruption:SetFloat("$c0_x", CurTime())

		-- Set pollution intensity
		local intensity = 1.2
		corruption:SetFloat("$c0_y", intensity)

		corruption:SetFloat("$c1_x", 0.5)
		corruption:SetFloat("$c1_y", 0.5)
		corruption:SetFloat("$c0_z", 1.6)
		corruption:SetFloat("$c0_w", 0)  -- World-space mode

		-- Check if player is inside the sphere
		if distance < WORLD_RADIUS then
			-- INSIDE SPHERE: Render pollution on entire screen (no stencil needed)
			render.SetMaterial(corruption)
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
			local invisible_mat = CreateMaterial("arcana_corruption_stencil", "UnlitGeneric", {
				["$basetexture"] = "color/white",
				["$alpha"] = "0",
				["$translucent"] = "1"
			})

			render.SetMaterial(invisible_mat)

			-- Draw sphere at entity position
			local matrix = Matrix()
			matrix:SetTranslation(world_pos)
			matrix:SetScale(Vector(WORLD_RADIUS, WORLD_RADIUS, WORLD_RADIUS))

			cam.PushModelMatrix(matrix)
			render.DrawSphere(Vector(0, 0, 0), 1, 16, 16)  -- Unit sphere (scaled by matrix)
			cam.PopModelMatrix()

			-- Step 3: Set stencil to only draw where sphere was rendered
			render.SetStencilCompareFunction(STENCIL_EQUAL)
			render.SetStencilPassOperation(STENCIL_KEEP)

			render.SetMaterial(corruption)
			render.DrawScreenQuad()

			render.SetStencilEnable(false)
		end
	end

	function ENT:Initialize()
		hook.Add("PostDrawOpaqueRenderables", self, function(_, _, _, sky3d)
			if sky3d then return end
			corruption_test(self)
		end)
	end
end