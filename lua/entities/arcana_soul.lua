AddCSLuaFile()

ENT.Type = "anim"
ENT.Base = "base_gmodentity"
ENT.PrintName = "Soul"
ENT.Author = "Earu"
ENT.Category = "Arcana"
ENT.Spawnable = false
ENT.AdminOnly = false
ENT.PhysgunDisabled = true

function ENT:GetSoulHue()
	-- Default to a deterministic hue based on entity index when not networked
	return self:GetNWInt("SoulHue", (tonumber(util.CRC(self:EntIndex())) or 0) % 360)
end

function ENT:SetSoulHue(h)
	self:SetNWInt("SoulHue", math.floor(tonumber(h) or 0) % 360)
end

if SERVER then
	function ENT:Initialize()
		self:SetModel("models/dav0r/hoverball.mdl")
		self:PhysicsInit(SOLID_VPHYSICS)
		self:PhysWake()

		local phys = self:GetPhysicsObject()
		if IsValid(phys) then
			phys:Wake()
			phys:EnableGravity(false)
			phys:SetMass(0.1)
		end

		-- Randomize its hue once on spawn (clients can still override via NW)
		self:SetSoulHue((tonumber(util.CRC(self:EntIndex())) or 0) % 360)
		self:StartMotionController()

		-- Soft ambient hum
		self._hum = CreateSound(self, "ambient/atmosphere/undercity_ambience.wav")
		if self._hum then
			self._hum:PlayEx(0.12, 120)
		end
	end

	function ENT:PhysicsCollide(data, phys)
		if not self.last_collide or self.last_collide < CurTime() then
			local ent = data.HitEntity

			if ent:IsValid() and not ent:IsPlayer() and ent:GetModel() then
				self.last_collide = CurTime() + 1
			end
		end

		if data.Speed > 50 and data.DeltaTime > 0.2 then
			local time = math.Rand(0.5, 1)
			self:EnableGravity(time)
			self.follow_ent = NULL
		end

		phys:SetVelocity(phys:GetVelocity():GetNormalized() * data.OurOldVelocity:Length() * 0.99)
	end

	function ENT:OnTakeDamage(dmg)
		local time = math.Rand(1, 2)
		self:EnableGravity(time)
		self.Hurting = true

		timer.Simple(time, function()
			if self:IsValid() then
				self.Hurting = false
			end
		end)

		local phys = self:GetPhysicsObject()
		phys:AddVelocity(dmg:GetDamageForce())
	end

	function ENT:OnRemove()
		if self._hum then
			self._hum:Stop()
			self._hum = nil
		end
	end

	function ENT:Think()
		self:PhysWake()
	end

	function ENT:EnableGravity(time)
		local phys = self:GetPhysicsObject()
		phys:EnableGravity(true)
		self.GravityOn = true

		timer.Simple(time, function()
			if self:IsValid() and phys:IsValid() then
				phys:EnableGravity(false)
				self.GravityOn = false
			end
		end)
	end
end

if CLIENT then
	ENT.RenderGroup = RENDERGROUP_TRANSLUCENT

	-- Materials inspired by both the fairy and crystal shard effects
	local WARP_MAT = Material("particle/warp2_warp")
	local GLARE_MAT = Material("sprites/light_ignorez")
	local CORE_MAT = Material("sprites/light_glow02_add")

	local GLOW_MAT = CreateMaterial(tostring({}), "UnlitGeneric", {
		["$BaseTexture"] = "particle/fire",
		["$Additive"] = 1,
		["$VertexColor"] = 1,
		["$VertexAlpha"] = 1,
	})

	local TRAIL_MAT = CreateMaterial(tostring({}), "UnlitGeneric", {
		["$BaseTexture"] = "particle/water/watersplash_001a",
		["$Additive"] = 1,
		["$Translucent"] = 1,
		["$VertexColor"] = 1,
		["$VertexAlpha"] = 1,
	})

	local MAX_RENDER_DIST_SQR = 1600 * 1600

	local tempColorCache = Color(255, 255, 255, 255)
	local function setTempColor(r, g, b, a)
		tempColorCache.r = math.min(r, 255)
		tempColorCache.g = math.min(g, 255)
		tempColorCache.b = math.min(b, 255)
		tempColorCache.a = a
		return tempColorCache
	end

	function ENT:Initialize()
		self._pixVisCore = util.GetPixelVisibleHandle()
		self._pixVisWide = util.GetPixelVisibleHandle()
		self._fxEmitter = ParticleEmitter(self:GetPos(), false)
		self._nextParticle = 0
		self._randomRotation = math.random() * 360
		self._size = 1

		if render.SupportsPixelShaders_2_0() then
			hook.Add("RenderScreenspaceEffects", self, function()
				cam.Start3D()
				render.UpdateScreenEffectTexture()
				self:DrawCoreAndTrails()
				cam.End3D()
			end)
		end
	end

	function ENT:OnRemove()
		if self._fxEmitter then
			self._fxEmitter:Finish()
			self._fxEmitter = nil
		end
	end

	function ENT:Think()
		-- Dynamic light pulses with color
		local hue = self:GetSoulHue()
		local col = self.Color or HSVToColor(hue, 0.65, 1)
		local dl = DynamicLight(self:EntIndex())
		if dl then
			dl.Pos = self:GetPos()
			dl.r = col.r
			dl.g = col.g
			dl.b = col.b
			dl.Brightness = 2
			dl.Size = 220
			dl.Decay = 800
			dl.DieTime = CurTime() + 0.2
		end

		if self._fxEmitter then
			self._fxEmitter:SetPos(self:GetPos())
		end

		if EyePos():DistToSqr(self:GetPos()) <= MAX_RENDER_DIST_SQR and CurTime() >= (self._nextParticle or 0) and self._fxEmitter then
			self._nextParticle = CurTime() + 0.08
			local origin = self:WorldSpaceCenter()
			local p = self._fxEmitter:Add("sprites/light_glow02_add", origin + VectorRand() * math.Rand(1, 6))
			if p then
				p:SetStartAlpha(180)
				p:SetEndAlpha(0)
				p:SetStartSize(math.Rand(3, 6))
				p:SetEndSize(0)
				p:SetDieTime(math.Rand(0.4, 0.7))
				p:SetVelocity(Vector(0, 0, math.Rand(10, 24)))
				p:SetAirResistance(40)
				p:SetGravity(vector_origin)
				p:SetRoll(math.Rand(-180, 180))
				p:SetRollDelta(math.Rand(-1, 1))
				p:SetColor(col.r, col.g, col.b)
			end
		end

		self:SetNextClientThink(CurTime())
		return true
	end

	function ENT:DrawCoreAndTrails()
		local now = RealTime() + self._randomRotation
		local hue = self:GetSoulHue()
		local col = self.Color or HSVToColor(hue, 0.65, 1)
		local pos = self:WorldSpaceCenter()
		local distance = EyePos():DistToSqr(pos)

		local radius = 8
		local vis = util.PixelVisible(pos, radius * 1.5, self._pixVisCore)
		if vis == 0 and util.PixelVisible(pos, radius * 6, self._pixVisWide) == 0 then return end

		-- Inner warp
		render.SetMaterial(WARP_MAT)
		render.DrawSprite(pos, 28, 28, setTempColor(col.r * 2, col.g * 2, col.b * 2, vis * 30))

		-- Additive glows that pulse
		render.SetMaterial(GLOW_MAT)
		local pulse = 1
		local c = setTempColor(col.r, col.g, col.b, vis * 180 * pulse)
		render.DrawSprite(pos, 18, 18, c)
		c.a = vis * 150 * (pulse + 0.25)
		render.DrawSprite(pos, 30, 30, c)
		c.a = vis * 120 * (pulse + 0.5)
		render.DrawSprite(pos, 44, 44, c)

		-- Strong core sprite to tie with brighter trails
		render.SetMaterial(CORE_MAT)
		local core = setTempColor(math.min(col.r * 2.2, 255), math.min(col.g * 2.2, 255), math.min(col.b * 2.2, 255), math.min(255, vis * 255))
		render.DrawSprite(pos, 48, 48, core)
		core = setTempColor(255, 255, 255, math.min(255, vis * 220))
		render.DrawSprite(pos, 30, 30, core)

		-- Long glare
		render.SetMaterial(GLARE_MAT)
		local far = setTempColor(col.r, col.g, col.b, vis * 24)
		render.DrawSprite(pos, 150, 50, far)

		local upDir = vector_up

		-- Motion trail beams that always point upward
		render.SetMaterial(TRAIL_MAT)
		local velLen = self:GetVelocity():Length()
		local segments = (distance > 900000) and 1 or 5
		local beams = (distance > 900000) and 1 or 3
		local height = 32 + velLen * 0.06
		for j = 1, beams do
			local jitter = (j - 1) * 0.35 + math.sin(now * 1.3 + j) * 0.25
			render.StartBeam(segments)
			for i = 1, segments do
				local t = (i - 1) / (segments - 1)
				local off = pos + upDir * t * height
				-- lateral jitter constrained to horizontal plane so the trail stays vertical
				local lateral = VectorRand()
				lateral.z = 0
				if lateral:LengthSqr() > 0 then lateral:Normalize() end
				off = off + lateral * jitter * (1 - t)
				local alpha = (1 - t) * 255 * vis
				render.AddBeam(off, (1 - t) * 10, t * 0.2 + now * 0.05, setTempColor(col.r, col.g, col.b, alpha))
			end
			render.EndBeam()
		end
	end

	function ENT:DrawTranslucent()
	end

	function ENT:Draw()
	end
end
