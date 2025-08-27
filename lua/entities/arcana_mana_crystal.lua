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
		self:SetStoredMana(0)
	end

	-- Apply model scaling whenever CrystalScale changes (both realms)
	self:NetworkVarNotify("CrystalScale", function(ent, name, old, new)
		if ent._ApplyScale then
			ent:_ApplyScale(new)
		end
	end)
end

-- Shared scale application helper so clients render the correct size
function ENT:_ApplyScale(scale)
	-- Ensure sane defaults even if called before Initialize
	self._minScale = self._minScale or 0.35
	self._maxScale = self._maxScale or 2.2
	local s = math.Clamp(tonumber(scale) or 1, self._minScale, self._maxScale)
	self:SetModelScale(s, 0)
	-- adjust absorb radius with size subtly
	if self.SetAbsorbRadius then
		self:SetAbsorbRadius(520 * (0.6 + (s - self._minScale) / (self._maxScale - self._minScale + 0.0001) * 0.8))
	end
end

-- Shared capacity and absorption helpers (computed from scale)
function ENT:GetMaxMana()
	local minScale = self._minScale or 0.35
	local maxScale = self._maxScale or 2.2
	local s = math.Clamp(self:GetCrystalScale() or 1, minScale, maxScale)
	local t = (s - minScale) / math.max(0.0001, maxScale - minScale)
	local minCap = 200
	local maxCap = 2000
	return minCap + (maxCap - minCap) * t
end

function ENT:GetAbsorbRate()
	local minScale = self._minScale or 0.35
	local maxScale = self._maxScale or 2.2
	local s = math.Clamp(self:GetCrystalScale() or 1, minScale, maxScale)
	local t = (s - minScale) / math.max(0.0001, maxScale - minScale)
	local minRate = 6 -- mana/sec
	local maxRate = 30
	return minRate + (maxRate - minRate) * t
end

function ENT:IsFull()
	return (self:GetStoredMana() or 0) >= self:GetMaxMana() - 0.001
end

if SERVER then
	resource.AddShader("arcana_crystal_surface_vs30")
	resource.AddShader("arcana_crystal_surface_ps30")

	function ENT:Initialize()
		self:SetModel("models/props_abandoned/crystals/crystal_damaged/crystal_cluster_huge_damaged_a.mdl")
		self:SetMaterial("models/props_abandoned/crystals/crystal_damaged/crystal_damaged_huge_yellow.vmt")
		self:PhysicsInit(SOLID_VPHYSICS)
		self:SetMoveType(MOVETYPE_VPHYSICS)
		self:SetSolid(SOLID_VPHYSICS)
		self:SetUseType(SIMPLE_USE)
		self:SetColor(Color(255, 0, 255))

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

	function ENT:AddCrystalGrowth(points)
		self._growth = math.max(0, (self._growth or 0) + (tonumber(points) or 0))
		local frac = math.Clamp(self._growth / 300, 0, 1)
		local target = self._minScale + (self._maxScale - self._minScale) * frac
		self:SetCrystalScale(target)
		self:EmitSound("buttons/blip1.wav", 55, 140)
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
	local MAX_RENDER_DIST = 2000 * 2000
	function ENT:Initialize()
		-- Ensure client has consistent scale constants and apply current scale
		self._maxScale = 2.2
		self._minScale = 0.35
		self:_ApplyScale(self:GetCrystalScale())

		self.Material = Material(self:GetMaterial())
		self.ShaderMat = CreateShaderMaterial("crystal_dispersion", {
			["$pixshader"] = "arcana_crystal_surface_ps30",
			["$vertexshader"] = "arcana_crystal_surface_vs30",
			["$basetexture"] = self.Material:GetTexture("$basetexture"),
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

		-- Particle FX state
		self._fxEmitter = ParticleEmitter(self:GetPos(), false)
		self._fxNextAbsorb = 0
		self._fxNextZap = 0
	end

	function ENT:OnRemove()
		if self._fxEmitter then
			self._fxEmitter:Finish()
			self._fxEmitter = nil
		end
	end

	local function getCorePos(self)
		return self:LocalToWorld(self:OBBCenter())
	end

	local function randomPointAround(center, radius)
		local dir = VectorRand()
		dir:Normalize()
		return center + dir * radius
	end

	function ENT:_SpawnAbsorbParticles()
		if not self._fxEmitter then return end
		local center = getCorePos(self)
		local radius = math.max(48, (self:GetAbsorbRadius() or 300) * 0.6)
		local rate = self:GetAbsorbRate() or 10
		local num = math.Clamp(math.floor(2 + rate * 0.25), 3, 10)
		local col = self:GetColor() or Color(255, 255, 255)
		for i = 1, num do
			local pos = randomPointAround(center, radius)
			pos.z = pos.z + math.Rand(-radius * 0.25, radius * 0.25)
			local p = self._fxEmitter:Add("sprites/light_glow02_add", pos)
			if p then
				p:SetStartAlpha(220)
				p:SetEndAlpha(0)
				p:SetStartSize(math.Rand(3, 6))
				p:SetEndSize(0)
				p:SetDieTime(math.Rand(0.5, 0.9))
				local vel = (center - pos):GetNormalized() * math.Rand(80, 160)
				p:SetVelocity(vel)
				p:SetAirResistance(60)
				p:SetGravity(Vector(0, 0, 0))
				p:SetRoll(math.Rand(-180, 180))
				p:SetRollDelta(math.Rand(-1.2, 1.2))
				p:SetColor(col.r, col.g, col.b)
			end
		end
	end

	function ENT:_SpawnFullZap()
		local center = getCorePos(self)
		local bmin, bmax = self:OBBMins(), self:OBBMaxs()
		local localPos = Vector(math.Rand(bmin.x, bmax.x), math.Rand(bmin.y, bmax.y), math.Rand(bmin.z, bmax.z))
		local worldPos = self:LocalToWorld(localPos)
		local ed = EffectData()
		ed:SetOrigin(worldPos)
		ed:SetNormal((worldPos - center):GetNormalized())
		ed:SetMagnitude(2)
		ed:SetScale(1)
		ed:SetRadius(64)
		util.Effect("ElectricSpark", ed, true, true)
	end

	function ENT:Think()
		if self._fxEmitter then
			self._fxEmitter:SetPos(self:GetPos())
		end

		if EyePos():DistToSqr(self:GetPos()) > MAX_RENDER_DIST then return end

		local now = CurTime()
		if not self:IsFull() then
			if now >= (self._fxNextAbsorb or 0) then
				self:_SpawnAbsorbParticles()
				self._fxNextAbsorb = now + 0.06
			end
		else
			if now >= (self._fxNextZap or 0) then
				self:_SpawnFullZap()
				self._fxNextZap = now + math.Rand(0.2, 0.5)
			end
		end

		self:SetNextClientThink(CurTime())
		return true
	end

	function ENT:Draw()
		self:DrawModel()

		if EyePos():DistToSqr(self:GetPos()) > MAX_RENDER_DIST then return end

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
			-- SHADER_MAT:SetFloat("$c2_x", CurTime())
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