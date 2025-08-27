AddCSLuaFile()
ENT.Type = "anim"
ENT.Base = "base_gmodentity"
ENT.PrintName = "Mana Crystal"
ENT.Author = "Earu"
ENT.Spawnable = false
ENT.AdminOnly = false
ENT.Category = "Arcana"
ENT.RenderGroup = RENDERGROUP_BOTH
require("shader_to_gma")

function ENT:SetupDataTables()
	self:NetworkVar("Float", 0, "AbsorbRadius")
	self:NetworkVar("Float", 1, "CrystalScale")
	self:NetworkVar("Float", 2, "StoredMana")

	if SERVER then
		self:SetAbsorbRadius(520)
		self:SetCrystalScale(0.35)
		self:SetStoredMana(0)
	end
end

if SERVER then
	resource.AddShader("arcana_crystal_surface_vs30")
	resource.AddShader("arcana_crystal_surface_ps30")

	function ENT:Initialize()
		self:SetModel("models/props_abandoned/crystals/crystal_damaged/crystal_cluster_huge_damaged_a.mdl")
		self:SetMaterial("models/mspropp/light_blue001")
		self:PhysicsInit(SOLID_VPHYSICS)
		self:SetMoveType(MOVETYPE_VPHYSICS)
		self:SetSolid(SOLID_VPHYSICS)
		self:SetUseType(SIMPLE_USE)
		self:SetColor(Color(80, 180, 255))

		local phys = self:GetPhysicsObject()
		if IsValid(phys) then
			phys:Wake()
			phys:EnableMotion(false)
		end

		self:SetCollisionGroup(COLLISION_GROUP_WEAPON)
		self:DrawShadow(true)
		self._growth = 0
		self._maxScale = 2.2
		self._minScale = 0.35
		self:_ApplyScale(self:GetCrystalScale())
	end

	function ENT:_ApplyScale(scale)
		local s = math.Clamp(tonumber(scale) or 1, self._minScale, self._maxScale)
		self:SetModelScale(s, 0)
		-- adjust absorb radius with size subtly
		self:SetAbsorbRadius(520 * (0.6 + (s - self._minScale) / (self._maxScale - self._minScale + 0.0001) * 0.8))
	end

	function ENT:SetCrystalScale(scale)
		self:SetDTFloat(1, scale)
		self:_ApplyScale(scale)
	end

	function ENT:AddCrystalGrowth(points)
		self._growth = math.max(0, (self._growth or 0) + (tonumber(points) or 0))
		local frac = math.Clamp(self._growth / 300, 0, 1)
		local target = self._minScale + (self._maxScale - self._minScale) * frac
		self:SetCrystalScale(target)
		self:EmitSound("buttons/blip1.wav", 55, 140)
	end

	-- Capacity and absorption helpers (computed from scale)
	function ENT:GetMaxMana()
		local s = math.Clamp(self:GetCrystalScale() or 1, self._minScale, self._maxScale)
		local t = (s - self._minScale) / math.max(0.0001, self._maxScale - self._minScale)
		local minCap = 200
		local maxCap = 2000

		return minCap + (maxCap - minCap) * t
	end

	function ENT:GetAbsorbRate()
		local s = math.Clamp(self:GetCrystalScale() or 1, self._minScale, self._maxScale)
		local t = (s - self._minScale) / math.max(0.0001, self._maxScale - self._minScale)
		local minRate = 6 -- mana/sec
		local maxRate = 30

		return minRate + (maxRate - minRate) * t
	end

	function ENT:AddStoredMana(amount)
		amount = tonumber(amount) or 0
		if amount <= 0 then return 0 end
		local cap = self:GetMaxMana()
		local cur = math.max(0, self:GetStoredMana() or 0)
		local add = math.min(amount, math.max(0, cap - cur))

		if add > 0 then
			self:SetStoredMana(cur + add)
		end

		return add
	end

	function ENT:IsFull()
		return (self:GetStoredMana() or 0) >= self:GetMaxMana() - 0.001
	end
end

if CLIENT then
	function ENT:Initialize()
		self.ShaderMat = CreateShaderMaterial("crystal_dispersion", {
			["$pixshader"] = "arcana_crystal_surface_ps30",
			["$vertexshader"] = "arcana_crystal_surface_vs30",
			["$basetexture"] = "models/mspropp/light_blue001",
			["$model"] = 1,
			["$vertexnormal"] = 1,
			["$softwareskin"] = 1,
			["$alpha_blend"] = 1,
			["$linearwrite"] = 1,
			["$linearread_basetexture"] = 1,
			["$c0_x"] = 3.0, -- dispersion strength
			["$c0_y"] = 4.0, -- fresnel power
			["$c0_z"] = 0.1, -- tint r
			["$c0_w"] = 0.5, -- tint g
			["$c1_x"] = 3, -- tint b
			["$c1_y"] = 1, -- opacity
		})

		-- Defaults for grain/sparkles and facet multi-bounce
		self.ShaderMat:SetFloat("$c2_y", 12) -- NOISE_SCALE
		self.ShaderMat:SetFloat("$c2_z", 0.6) -- GRAIN_STRENGTH
		self.ShaderMat:SetFloat("$c2_w", 0.2) -- SPARKLE_STRENGTH
		self.ShaderMat:SetFloat("$c3_x", 0.15) -- THICKNESS_SCALE
		self.ShaderMat:SetFloat("$c3_y", 12) -- FACET_QUANT
		self.ShaderMat:SetFloat("$c3_z", 8) -- BOUNCE_FADE
		self.ShaderMat:SetFloat("$c3_w", 1.4) -- BOUNCE_STEPS (1..4)
	end

	function ENT:OnRemove()
	end

	local function getCorePos(self)
		return self:LocalToWorld(self:OBBCenter())
	end

	function ENT:Think()
	end

	function ENT:Draw()
		self:DrawModel()

		-- draw only the refractive passes (skip solid base draw to avoid overbright)
		local PASSES = 4 -- try 3–6
		local baseDisp = 0.5 -- your $c0_x base
		local perPassOpacity = 1 / PASSES

		-- start from current screen
		render.UpdateScreenEffectTexture()
		local scr = render.GetScreenEffectTexture()
		self.ShaderMat:SetTexture("$basetexture", scr)

		local curColor = self:GetColor()
		self.ShaderMat:SetFloat("$c0_z", curColor.r / 255)
		self.ShaderMat:SetFloat("$c0_w", curColor.g / 255)
		self.ShaderMat:SetFloat("$c1_x", curColor.b / 255)

		render.OverrideDepthEnable(true, true) -- no Z write

		for i = 1, PASSES do
			-- ramp dispersion a bit each pass
			self.ShaderMat:SetFloat("$c0_x", baseDisp * (1 + 0.25 * (i - 1)))
			-- reduce opacity per pass
			self.ShaderMat:SetFloat("$c1_y", perPassOpacity)
			-- animate grain if you added it
			--	SHADER_MAT:SetFloat("$c2_x", CurTime())
			-- facet/bounce can be adjusted live too
			-- SHADER_MAT:SetFloat("$c3_x", 1.2)
			-- SHADER_MAT:SetFloat("$c3_y", 12)
			-- SHADER_MAT:SetFloat("$c3_z", 0.75)
			-- SHADER_MAT:SetFloat("$c3_w", 4)

			render.MaterialOverride(self.ShaderMat)
			self:DrawModel()
			render.MaterialOverride()
			-- capture the result to feed into next pass
			render.CopyRenderTargetToTexture(scr)
		end

		render.OverrideDepthEnable(false, false)

		local dl = DynamicLight(self:EntIndex())
		if dl then
			local center = getCorePos(self)
			dl.pos = center
			dl.r = curColor.r
			dl.g = curColor.g
			dl.b = curColor.b
			dl.brightness = 6
			dl.Decay = 100
			dl.Size = math.max(160, self:GetAbsorbRadius() * 0.3)
			dl.DieTime = CurTime() + 0.1
		end
	end

	function ENT:DrawTranslucent()
	end
end