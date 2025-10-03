AddCSLuaFile()
ENT.Type = "anim"
ENT.Base = "base_gmodentity"
ENT.PrintName = "Mana Crystal Shard"
ENT.Author = "Earu"
ENT.Spawnable = false
ENT.AdminOnly = false
ENT.Category = "Arcana"
ENT.PhysgunDisabled = true
ENT.ms_notouch = true

if SERVER then
	function ENT:Initialize()
		-- Pick a small model from base GMod props that reads well with shiny material
		self:SetModel("models/props_debris/concrete_chunk05g.mdl")
		self:SetMaterial("models/shiny")
		self:PhysicsInit(SOLID_VPHYSICS)
		self:SetMoveType(MOVETYPE_VPHYSICS)
		self:SetSolid(SOLID_VPHYSICS)
		self:SetUseType(SIMPLE_USE)
		self:SetTrigger(true)
		local phys = self:GetPhysicsObject()

		if IsValid(phys) then
			phys:Wake()
			phys:SetMaterial("gmod_ice")
			phys:SetBuoyancyRatio(0.2)
		end

		self._amount = self._amount or 1
		SafeRemoveEntityDelayed(self, 40)
		-- Subtle looping hum (softer)
		self._hum = CreateSound(self, "ambient/levels/citadel/field_loop3.wav")

		if self._hum then
			self._hum:PlayEx(0.18, 115)
		end
	end

	function ENT:OnRemove()
		if self._hum then
			self._hum:Stop()
			self._hum = nil
		end
	end

	function ENT:SetShardAmount(n)
		self._amount = math.max(1, math.floor(tonumber(n) or 1))
		self:SetModelScale(1 + self._amount)
		self:Activate()
	end

	function ENT:GetShardAmount()
		return math.max(1, math.floor(tonumber(self._amount) or 1))
	end

	local function tryPickup(self, ply)
		if not IsValid(self) or not IsValid(ply) or not ply:IsPlayer() then return false end
		if not ply.GiveItem then return false end
		local amount = self:GetShardAmount()
		ply:GiveItem("mana_crystal_shard", amount)
		self:EmitSound("physics/glass/glass_cup_break1.wav", 70, math.random(190, 210), 0.75)
		local ed = EffectData()
		ed:SetOrigin(self:WorldSpaceCenter())
		util.Effect("GlassImpact", ed, true, true)
		self:Remove()

		return true
	end

	function ENT:Use(activator)
		if not IsValid(activator) or not activator:IsPlayer() then return end
		tryPickup(self, activator)
	end

	function ENT:PhysicsCollide(data, phys)
		if data.Speed > 60 then
			self:EmitSound("physics/glass/glass_cup_break2.wav", 70, math.random(190, 210), 0.75)
		end

		if IsValid(phys) and data.Speed > 150 then
			phys:SetVelocity(phys:GetVelocity() * 0.6)
		end

		if IsValid(data.Entity) and data.Entity:IsPlayer() then
			tryPickup(self, data.Entity)

			return
		end
	end

	function ENT:StartTouch(ent)
		if ent:IsPlayer() then
			tryPickup(self, ent)
		end
	end
end

if CLIENT then
	local MAX_RENDER_DIST = 1500 * 1500
	local GLARE_MAT = Material("sprites/light_ignorez")
	local WARP_MAT = Material("particle/warp2_warp")

	local GLARE2_MAT = CreateMaterial(tostring{}, "UnlitGeneric", {
		["$BaseTexture"] = "particle/fire",
		["$Additive"] = 1,
		["$VertexColor"] = 1,
		["$VertexAlpha"] = 1,
	})

	local FIRE_MAT = CreateMaterial(tostring{}, "UnlitGeneric", {
		["$BaseTexture"] = "particle/water/watersplash_001a",
		["$Additive"] = 1,
		["$Translucent"] = 1,
		["$VertexColor"] = 1,
		["$VertexAlpha"] = 1,
	})

	local tempColorCache = Color(255, 255, 255, 255)
	local function tempColor(r, g, b, a)
		tempColorCache.r = math.min(r, 255)
		tempColorCache.g = math.min(g, 255)
		tempColorCache.b = math.min(b, 255)
		tempColorCache.a = a

		return tempColorCache
	end

	local render_UpdateScreenEffectTexture = _G.render.UpdateScreenEffectTexture
	local render_SetMaterial = _G.render.SetMaterial
	local render_DrawSprite = _G.render.DrawSprite
	local render_StartBeam = _G.render.StartBeam
	local render_EndBeam = _G.render.EndBeam
	local render_AddBeam = _G.render.AddBeam
	local cam_IgnoreZ = _G.cam.IgnoreZ
	local cam_Start3D = _G.cam.Start3D
	local cam_End3D = _G.cam.End3D
	local util_PixelVisible = _G.util.PixelVisible
	local util_GetPixelVisibleHandle = _G.util.GetPixelVisibleHandle
	function ENT:DrawGlow()
		local now = RealTime()

		self.crystalItemsRandom = self.crystalItemsRandom or {}
		self.crystalItemsRandom.rotation = self.crystalItemsRandom.rotation or math.random() * 360
		now = now + self.crystalItemsRandom.rotation

		local radius = self:BoundingRadius() * 4
		local posCenter = self:WorldSpaceCenter()
		local color = self:GetColor()
		local distance = EyePos():DistToSqr(posCenter)

		self.crystalItemsPixVis = self.crystalItemsPixVis or util_GetPixelVisibleHandle()
		self.crystalItemsPixVis2 = self.crystalItemsPixVis2 or util_GetPixelVisibleHandle()

		local vis = util_PixelVisible(posCenter, radius * 0.5, self.crystalItemsPixVis)
		if vis == 0 and util_PixelVisible(posCenter, radius * 5, self.crystalItemsPixVis2) == 0 then return end

		-- Depth-ignored core warp + layered glare
		cam_IgnoreZ(true)

		local r = radius / 8
		local pos = self:GetBonePosition(1) or self:GetBonePosition(0) or posCenter
		render_SetMaterial(WARP_MAT)
		render_DrawSprite(pos, 50, 50, tempColor(color.r * 2, color.g * 2, color.b * 2, vis * 20), self.crystalItemsRandom.rotation)
		local glow = math.sin(now * 5) * 0.5 + 0.5
		render_SetMaterial(GLARE2_MAT)
		local c = tempColor(color.r, color.g, color.b)
		c.a = vis * 170 * glow
		render_DrawSprite(pos, r * 10, r * 10, c)
		c.a = vis * 170 * (glow + 0.25)
		render_DrawSprite(pos, r * 20, r * 20, c)
		c.a = vis * 120 * (glow + 0.5)
		render_DrawSprite(pos, r * 30, r * 30, c)

		cam_IgnoreZ(false)

		render_SetMaterial(GLARE_MAT)
		c.a = vis * 20
		render_DrawSprite(pos, r * 180, r * 50, c)

		-- Trailing beams based on velocity
		render_SetMaterial(FIRE_MAT)

		self.crystalItemFade = self.crystalItemFade or 0
		self.crystalItemRandom = self.crystalItemRandom or math.Rand(0.5, 1)

		local vel = self:GetVelocity()
		local fade = 1
		if vel:Length() < 100 then
			vel:Zero()
			fade = math.min(now - self.crystalItemFade, 1) ^ 0.5
		else
			self.crystalItemFade = now
		end

		local ang = vel:Angle()
		local up = ang:Up()
		local right = ang:Right()
		local forward = ang:Forward()
		local max_inner = 5
		local max_outter = 3

		if distance > 1000 * 1000 then
			max_outter = 1
			max_inner = 2
		end

		local velLen = vel:Length()
		fade = fade * self.crystalItemRandom
		local items = self.crystalItemsRandom

		for i2 = 1, max_outter do
			items[i2] = items[i2] or math.random() * 2 - 1
			local f2 = i2 / 4
			f2 = f2 * 5 + items[i2]
			local offset = pos * 1
			local trailOffset = -(radius / 13) * math.abs(math.sin(f2 + now / 5) * 100)
			render_StartBeam(max_inner)

			for i = 1, max_inner do
				local f = i / max_inner
				local s = math.sin(f * math.pi * 2)

				if i ~= 1 then
					local upMult = -math.sin(f2 + now + s * 30 / max_inner * items[i2])
					local rightMult = -math.sin(f2 + now + s * 30 / max_inner * items[i2])
					local forwardMult = trailOffset * f * 0.5 / (1 + velLen / 100)
					offset.x = pos.x + (up.x * upMult + right.x * rightMult + forward.x * forwardMult) * fade
					offset.y = pos.y + (up.y * upMult + right.y * rightMult + forward.y * forwardMult) * fade
					offset.z = pos.z + (up.z * upMult + right.z * rightMult + forward.z * forwardMult) * fade
				end

				c.a = 255 * f
				render_AddBeam(offset, (-f + 1) * radius, f * 0.3 - now * 0.1 + items[i2], c)
			end

			render_EndBeam()
		end
	end

	hook.Add("RenderScreenspaceEffects", "arcana_crystal_shard_glow", function()
		cam_Start3D()
		render_UpdateScreenEffectTexture()

		for _, ent in ipairs(ents.FindByClass("arcana_crystal_shard")) do
			if EyePos():DistToSqr(ent:GetPos()) > MAX_RENDER_DIST then continue end

			ent:DrawGlow()
		end

		cam_End3D()
	end)

	function ENT:Initialize()
		self._fxEmitter = ParticleEmitter(self:GetPos(), false)
		self._fxNext = 0
	end

	function ENT:OnRemove()
		if self._fxEmitter then
			self._fxEmitter:Finish()
			self._fxEmitter = nil
		end
	end

	function ENT:Think()
		if self._fxEmitter then
			self._fxEmitter:SetPos(self:GetPos())
		end

		if EyePos():DistToSqr(self:GetPos()) > MAX_RENDER_DIST then return end

		local now = CurTime()
		if now >= (self._fxNext or 0) and self._fxEmitter then
			self._fxNext = now + 0.12
			local c = self:GetColor()
			local origin = self:WorldSpaceCenter()

			for i = 1, 1 do
				local offset = VectorRand() * math.Rand(1, 6)
				offset.z = math.abs(offset.z) * 0.5

				local p = self._fxEmitter:Add("sprites/light_glow02_add", origin + offset)
				if p then
					p:SetStartAlpha(180)
					p:SetEndAlpha(0)
					p:SetStartSize(math.Rand(2, 4))
					p:SetEndSize(0)
					p:SetDieTime(math.Rand(0.4, 0.7))
					p:SetVelocity(Vector(0, 0, math.Rand(8, 18)))
					p:SetAirResistance(40)
					p:SetGravity(Vector(0, 0, 0))
					p:SetRoll(math.Rand(-180, 180))
					p:SetRollDelta(math.Rand(-1, 1))
					p:SetColor(c.r, c.g, c.b)
				end
			end
		end

		self:SetNextClientThink(CurTime())
		return true
	end

	function ENT:Draw()
		render.SetLightingMode(2)
		self:DrawModel()
		render.SetLightingMode(0)
	end
end