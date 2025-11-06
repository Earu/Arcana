AddCSLuaFile()
ENT.Type = "anim"
ENT.Base = "base_gmodentity"
ENT.PrintName = "Mana Crystal"
ENT.Author = "Earu"
ENT.Spawnable = false
ENT.AdminOnly = false
ENT.Category = "Arcana"
ENT.RenderGroup = RENDERGROUP_BOTH
ENT.PhysgunDisabled = true
ENT.ms_notouch = true
require("shader_to_gma")

function ENT:SetupDataTables()
	self:NetworkVar("Float", 0, "AbsorbRadius")
	self:NetworkVar("Float", 1, "CrystalScale")

	if SERVER then
		self:SetAbsorbRadius(520)
	end

	-- Apply model scaling whenever CrystalScale changes (both realms)
	self:NetworkVarNotify("CrystalScale", function(ent, name, old, new)
		if old == new then return end
		if ent._ApplyScale then
			ent:_ApplyScale(new)
		end
		if ent._OnScaleChanged then
			ent:_OnScaleChanged(new)
		end
	end)
end

-- Shared scale application helper so clients render the correct size
function ENT:_ApplyScale(scale)
	-- Ensure sane defaults even if called before Initialize
	self._minScale = self._minScale or 0.35
	self._maxScale = self._maxScale or 2.2
	local s = math.Clamp(tonumber(scale) or 1, self._minScale, self._maxScale)

	if SERVER then
		self:SetModelScale(s)
		self:Activate()
	end

	-- adjust absorb radius with size subtly
	if self.SetAbsorbRadius then
		self:SetAbsorbRadius(520 * (0.6 + (s - self._minScale) / (self._maxScale - self._minScale + 0.0001) * 0.8))
	end
end

-- Health scales with crystal size. Server-only state is fine; health is ephemeral.
function ENT:GetMaxHealthFromScale()
	local minScale = self._minScale or 0.35
	local maxScale = self._maxScale or 2.2
	local s = math.Clamp(self:GetCrystalScale() or 1, minScale, maxScale)
	local t = (s - minScale) / math.max(0.0001, maxScale - minScale)
	local minHP = 150
	local maxHP = 800
	return minHP + (maxHP - minHP) * t
end

function ENT:_OnScaleChanged()
	if SERVER then
		local newMax = math.floor(self:GetMaxHealthFromScale())
		self._maxHealth = newMax
		-- Do not heal on growth; just clamp if current exceeds new max
		if self._health then
			self._health = math.min(self._health, newMax)
		else
			self._health = newMax
		end
	end
end

-- Shared capacity and absorption helpers (computed from scale)
function ENT:GetAbsorbRate()
	local minScale = self._minScale or 0.35
	local maxScale = self._maxScale or 2.2
	local s = math.Clamp(self:GetCrystalScale() or 1, minScale, maxScale)
	local t = (s - minScale) / math.max(0.0001, maxScale - minScale)
	local minRate = 6 -- mana/sec
	local maxRate = 30
	return minRate + (maxRate - minRate) * t
end

if SERVER then
	resource.AddShader("arcana_crystal_surface_vs30")
	resource.AddShader("arcana_crystal_surface_ps30")

	resource.AddFile("models/props_abandoned/crystals_fixed/crystal_damaged/crystal_cluster_huge_damaged_a.mdl")
	resource.AddFile("models/props_abandoned/crystals_fixed/crystal_damaged/crystal_cluster_huge_damaged_b.mdl")
	resource.AddFile("materials/models/props_abandoned/crystals_fixed/crystal_damaged/crystal_damaged_huge_multi.vmt")
	resource.AddFile("materials/models/props_abandoned/crystals_fixed/crystal_damaged/crystal_damaged_huge.vmt")

	-- Cooldown to prevent excessive shard drops from multi-hit weapons (non-shatter only)
	local DAMAGE_SHARD_COOLDOWN = 1

	function ENT:Initialize()
		self:SetModel("models/props_abandoned/crystals_fixed/crystal_damaged/crystal_cluster_huge_damaged_" .. (math.random() > 0.5 and "a" or "b") .. ".mdl")
		self:SetMaterial("models/props_abandoned/crystals_fixed/crystal_damaged/crystal_damaged_huge.vmt")
		self:PhysicsInit(SOLID_VPHYSICS)
		self:SetMoveType(MOVETYPE_VPHYSICS)
		self:SetSolid(SOLID_VPHYSICS)
		self:SetUseType(SIMPLE_USE)
		self:SetColor(Color(55, 155, 255))

		local phys = self:GetPhysicsObject()
		if IsValid(phys) then
			phys:Wake()
			phys:EnableMotion(false)
		end

		self:DrawShadow(true)
		self._growth = 0
		self._maxScale = 2.2
		self._minScale = 0.35
		self:_ApplyScale(self:GetCrystalScale())

		-- Initialize health based on current scale
		self:_OnScaleChanged(self:GetCrystalScale())

		-- Register as producer in ManaNetwork
		local Arcane = _G.Arcane or {}
		if Arcane.ManaNetwork and Arcane.ManaNetwork.RegisterProducer then
			Arcane.ManaNetwork:RegisterProducer(self, {range = self:GetAbsorbRadius() or 520})
		end
	end

	-- Spawn a shard entity with optional amount and outward impulse
	local function SpawnShard(self, amount, dir, crystalPos)
		local ent = ents.Create("arcana_crystal_shard")
		if not IsValid(ent) then return end

		local center = crystalPos or self:WorldSpaceCenter()
		local normal = (dir and dir:GetNormalized()) or VectorRand():GetNormalized()
		local spawnPos = center + normal * math.Rand(8, 20)
		ent:SetPos(spawnPos)
		ent:SetAngles(AngleRand())
		ent:SetColor(self:GetColor())
		ent:Spawn()
		ent:Activate()
		ent:SetShardAmount(amount or 1)

		local phys = ent:GetPhysicsObject()
		if IsValid(phys) then
			phys:Wake()
			phys:SetVelocity((normal + VectorRand() * 0.2):GetNormalized() * math.Rand(300, 600))
			phys:AddAngleVelocity(VectorRand() * 120)
		end

		constraint.NoCollide(ent, self, 0, 0)
	end

	function ENT:DropShards(count, amountPerShard, dir, crystalPos)
		count = math.Clamp(math.floor(tonumber(count) or 1), 1, 12)
		amountPerShard = math.Clamp(math.floor(tonumber(amountPerShard) or 1), 1, 10)
		for i = 1, count do
			SpawnShard(self, amountPerShard, dir, crystalPos)
		end
	end

	function ENT:_Shatter()
		if self._shattered then return end

		-- burst of shards, glass effect, remove
		local count = math.random(8, 16) * math.max(self:GetCrystalScale(), 1)
		for i = 1, count do
			local dir = Vector(math.Rand(-1, 1), math.Rand(-1, 1), math.Rand(0.1, 1))
			SpawnShard(self, 1, dir)
		end

		local ed = EffectData()
		ed:SetOrigin(self:WorldSpaceCenter())
		util.Effect("GlassImpact", ed, true, true)
		self:EmitSound("physics/glass/glass_largesheet_break1.wav", 70, 100)

		-- Report destruction to corruption system before removal
		local Arcane = _G.Arcane or {}
		if Arcane.ManaCrystals and Arcane.ManaCrystals.ReportCrystalDestroyed then
			Arcane.ManaCrystals:ReportCrystalDestroyed(self)
		end

		self._shattered = true
		self:Remove()
	end

	function ENT:OnTakeDamage(dmginfo)
		local dmg = math.max(0, dmginfo:GetDamage())
		if dmg <= 0 then return end

		-- Compute ejection direction
		local dir
		local attacker = dmginfo:GetAttacker()
		local crystalPos = self:WorldSpaceCenter()
		if IsValid(attacker) and attacker:IsPlayer() then
			self:EmitSound("physics/glass/glass_impact_bullet4.wav", 60, 130)

			local tr = attacker:GetEyeTrace()
			crystalPos = tr.Entity == self and tr.HitPos or crystalPos
			dir = -(crystalPos - attacker:WorldSpaceCenter())
		end

		if not dir or dir:IsZero() then
			dir = dmginfo:GetDamageForce()
		end

		-- Chance to drop shards scales with damage, gated by per-crystal cooldown
		local now = CurTime()
		if now >= (self._nextShardDrop or 0) then
			local chance = math.Clamp(0.15 + (dmg * 0.01), 0.15, 0.9)
			if math.Rand(0, 1) <= chance then
				local num = math.Clamp(math.floor(1 + dmg / 35), 1, 6)
				self:DropShards(num, 1, dir, crystalPos)
				self._nextShardDrop = now + DAMAGE_SHARD_COOLDOWN
			end
		end

		-- Apply health damage and shatter at zero
		self._health = math.max(0, math.floor((self._health or self:GetMaxHealthFromScale()) - dmg))
		if self._health <= 0 then
			self:_Shatter()
		end
	end

	function ENT:AddCrystalGrowth(points)
		self._growth = math.max(0, (self._growth or 0) + (tonumber(points) or 0))
		local frac = math.Clamp(self._growth / 300, 0, 1)
		local target = self._minScale + (self._maxScale - self._minScale) * frac
		self:SetCrystalScale(target)
		self:EmitSound("buttons/blip1.wav", 55, 140)
	end

	-- Register into the ManaNetwork on spawn
	function ENT:OnRemove()
		local Arcane = _G.Arcane or {}
		if Arcane.ManaNetwork and Arcane.ManaNetwork.UnregisterNode then
			Arcane.ManaNetwork:UnregisterNode(self)
		end
	end

	function ENT:Think()
	end
end

if CLIENT then
	local SHADER_MAT
	local function initShaderMaterial()
		SHADER_MAT = CreateShaderMaterial("crystal_dispersion", {
			["$pixshader"] = "arcana_crystal_surface_ps30",
			["$vertexshader"] = "arcana_crystal_surface_vs30",
			--["$texture1"] = "models/props_abandoned/crystals_fixed/crystal_damaged/crystal_damaged_huge",
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
			["$c1_z"] = 0.75, -- albedo blend
			["$c1_w"] = 1.0, -- selfillum glow strength

			-- Defaults for grain/sparkles and facet multi-bounce
			["$c2_y"] = 12, -- NOISE_SCALE
			["$c2_z"] = 0.6, -- GRAIN_STRENGTH
			["$c2_w"] = 0.2, -- SPARKLE_STRENGTH
			["$c3_x"] = 0.15, -- THICKNESS_SCALE
			["$c3_y"] = 12, -- FACET_QUANT
			["$c3_z"] = 8, -- BOUNCE_FADE
			["$c3_w"] = 1.4, -- BOUNCE_STEPS (1..4)
		})
	end

	if system.IsWindows() then
		if file.Exists("shaders/fxc/arcana_crystal_surface_ps30.vcs", "GAME") and file.Exists("shaders/fxc/arcana_crystal_surface_vs30.vcs", "GAME") then
			initShaderMaterial()
		else
			hook.Add("ShaderMounted", "arcana_crystal_dispersion", initShaderMaterial)
		end
	end

	local MAX_RENDER_DIST = 2000 * 2000
	local RENDER_MAX_DIST = 2000
	local FADE_WINDOW = 600
	function ENT:Initialize()
		self._origColor = self:GetColor() or Color(255, 255, 255)

		-- Particle FX state
		self._fxEmitter = ParticleEmitter(self:GetPos(), false)
		self._fxNextAbsorb = 0
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

	local VECTOR_ZERO = Vector(0, 0, 0)
	local COLOR_WHITE = Color(255, 255, 255)
	function ENT:_SpawnAbsorbParticles()
		if not self._fxEmitter then return end

		local center = getCorePos(self)
		local radius = math.max(48, (self:GetAbsorbRadius() or 300) * 0.6)
		local rate = self:GetAbsorbRate() or 10
		local num = math.Clamp(math.floor(2 + rate * 0.25), 3, 10)
		local col = self:GetColor() or COLOR_WHITE
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
				p:SetGravity(VECTOR_ZERO)
				p:SetRoll(math.Rand(-180, 180))
				p:SetRollDelta(math.Rand(-1.2, 1.2))
				p:SetColor(col.r, col.g, col.b)
			end
		end
	end

	function ENT:Think()
		if self._fxEmitter then
			self._fxEmitter:SetPos(self:GetPos())
		end

		if EyePos():DistToSqr(self:GetPos()) > MAX_RENDER_DIST then return end

		local now = CurTime()
		if now >= (self._fxNextAbsorb or 0) then
			self:_SpawnAbsorbParticles()
			self._fxNextAbsorb = now + 0.06
		end

		self:SetNextClientThink(CurTime())
		return true
	end

	local render_UpdateScreenEffectTexture = _G.render.UpdateScreenEffectTexture
	local render_GetScreenEffectTexture = _G.render.GetScreenEffectTexture
	local render_OverrideDepthEnable = _G.render.OverrideDepthEnable
	local render_MaterialOverride = _G.render.MaterialOverride
	local render_CopyRenderTargetToTexture = _G.render.CopyRenderTargetToTexture
	local DYNAMIC_LIGHT_OFFSET = Vector(0, 0, 50)
	function ENT:Draw()
		local distSqr = EyePos():DistToSqr(self:GetPos())
		local dist = math.sqrt(distSqr)
		local isFar = dist > RENDER_MAX_DIST
		local fade = 1
		if dist > (RENDER_MAX_DIST - FADE_WINDOW) then
			fade = math.Clamp(1 - (dist - (RENDER_MAX_DIST - FADE_WINDOW)) / FADE_WINDOW, 0, 1)
		end

		if SHADER_MAT then
			if isFar then
				self:DrawModel()
			else
				render_OverrideDepthEnable(true, true) -- no Z write

				-- draw base model underneath at a low alpha to unify color
				local baseUnderAlpha = 0.9 * fade
				if baseUnderAlpha > 0 then
					render.SetBlend(baseUnderAlpha)
					self:DrawModel()
					render.SetBlend(1)
				end

				-- draw refractive passes with distance-based fade
				local PASSES = 4 -- try 3–6
				local baseDisp = 0.5 * (0.6 + 0.4 * fade)
				local perPassOpacity = (1 / PASSES) * fade

				-- start from current screen
				render_UpdateScreenEffectTexture()
				local scr = render_GetScreenEffectTexture()
				SHADER_MAT:SetTexture("$basetexture", scr)
				SHADER_MAT:SetFloat("$c2_x", RealTime())
				SHADER_MAT:SetFloat("$c1_w", 0.25)

				local curColor = self:GetColor()
				SHADER_MAT:SetFloat("$c0_z", curColor.r / 255 * 1.5)
				SHADER_MAT:SetFloat("$c0_w", curColor.g / 255 * 1.5)
				SHADER_MAT:SetFloat("$c1_x", curColor.b / 255 * 1.5)
				SHADER_MAT:SetFloat("$c1_z", 0)

				for i = 1, PASSES do
					-- ramp dispersion a bit each pass
					SHADER_MAT:SetFloat("$c0_x", baseDisp * (1 + 0.25 * (i - 1)))
					-- reduce opacity per pass
					SHADER_MAT:SetFloat("$c1_y", perPassOpacity)

					render_MaterialOverride(SHADER_MAT)
					self:DrawModel()
					render_MaterialOverride()

					-- capture the result to feed into next pass
					render_CopyRenderTargetToTexture(scr)
				end

				render_OverrideDepthEnable(false, false)

				-- crossfade in the base model as shader fades out
				if fade < 1 then
					render.SetBlend(1 - fade)
					self:DrawModel()
					render.SetBlend(1)
				end
			end
		else
			self:DrawModel()
		end

		if not isFar then
			local curColor = self:GetColor()
			local dl = DynamicLight(self:EntIndex())
			if dl then
				dl.pos = self:GetPos() + DYNAMIC_LIGHT_OFFSET
				dl.r = curColor.r
				dl.g = curColor.g
				dl.b = curColor.b
				dl.brightness = 6
				dl.Decay = 100
				dl.Size = math.max(160, self:GetAbsorbRadius() * 0.3)
				dl.DieTime = CurTime() + 0.1
			end
		end
	end

	function ENT:DrawTranslucent()
	end
end