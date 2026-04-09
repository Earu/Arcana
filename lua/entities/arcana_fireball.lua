ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "Fireball"
ENT.Author = "Earu"
ENT.Spawnable = false
ENT.RenderGroup = RENDERGROUP_BOTH
ENT.AdminSpawnable = false

-- Tunables
ENT.FireballSpeed = 900
ENT.FireballRadius = 150
ENT.FireballDamage = 120
ENT.FireballIgniteTime = 5
ENT.MaxLifetime = 6
ENT.FireballColor = Color(255, 120, 40, 255) -- override before Spawn() to tint all visuals

function ENT:SetupDataTables()
	self:NetworkVar("Entity", 0, "SpellOwner")
end

if SERVER then
	AddCSLuaFile()

	function ENT:Initialize()
		self:SetModel("models/hunter/misc/sphere025x025.mdl")
		self:SetMoveType(MOVETYPE_VPHYSICS)
		self:SetSolid(SOLID_VPHYSICS)
		self:PhysicsInit(SOLID_VPHYSICS)
		self:SetCollisionGroup(COLLISION_GROUP_PROJECTILE)
		self:SetTrigger(true)

		local phys = self:GetPhysicsObject()
		if IsValid(phys) then
			phys:EnableGravity(false)
			phys:Wake()
		end

		local fbColor = self.FireballColor or Color(255, 120, 40, 255)
		self:SetColor(fbColor)
		self:SetMaterial("models/debug/debugwhite")
		util.SpriteTrail(self, 0, Color(fbColor.r, fbColor.g, fbColor.b, 220), true, 18, 2, 0.45, 1 / 128, "trails/smoke.vmt")

		local addSprite = Arcana.Common.AddEntitySprite
		addSprite(self, "sprites/orangecore1.vmt", fbColor, 0.35, "ArcanaFB_S1")
		addSprite(self, "sprites/light_glow02_add.vmt", fbColor, 0.6, "ArcanaFB_S2")
		self.Created = CurTime()

		timer.Simple(self.MaxLifetime, function()
			if IsValid(self) and not self._detonated then
				self:Detonate()
			end
		end)
	end

	function ENT:LaunchTowards(dir)
		local phys = self:GetPhysicsObject()

		if IsValid(phys) then
			phys:SetVelocity(dir:GetNormalized() * self.FireballSpeed)
		end
	end

	local isSolidNonTrigger = Arcana.Common.IsSolidNonTrigger

	function ENT:PhysicsCollide(data, phys)
		if self._detonated then return end
		if (CurTime() - (self.Created or 0)) < 0.03 then return end

		local hit = data.HitEntity
		if (IsValid(hit) and hit ~= self:GetSpellOwner() and isSolidNonTrigger(hit)) or hit:IsWorld() then
			self:Detonate()
		end
	end

	function ENT:Touch(ent)
		if self._detonated then return end
		if ent == self:GetSpellOwner() then return end
		if (CurTime() - (self.Created or 0)) < 0.03 then return end

		if isSolidNonTrigger(ent) then
			self:Detonate()
		end
	end

	function ENT:Detonate()
		if self._detonated then return end
		self._detonated = true

		local owner = self:GetSpellOwner() or self
		local pos = self:GetPos()
		Arcana:BlastDamage(IsValid(owner) and owner or self, pos, self.FireballRadius, self.FireballDamage, { inflictor = self, damageType = DMG_BLAST, ignoreAttacker = true })

		for _, v in ipairs(ents.FindInSphere(pos, self.FireballRadius)) do
			if IsValid(v) and (v:IsPlayer() or v:IsNPC() or v:IsNextBot()) and v ~= owner then
				v:Ignite(self.FireballIgniteTime)
			end
		end

		local ed = EffectData()
		ed:SetOrigin(pos)
		util.Effect("Explosion", ed, true, true)
		util.ScreenShake(pos, 5, 5, 0.35, 512)
		util.Decal("Scorch", pos + Vector(0, 0, 8), pos - Vector(0, 0, 16))

		sound.Play("ambient/explosions/explode_4.wav", pos, 90, 100)
		self:Remove()
	end
end

if CLIENT then
	function ENT:Initialize()
		self._lastPos = self:GetPos()
		self._nextPFX = 0
		self.Emitter = ParticleEmitter(self:GetPos())
	end

	function ENT:OnRemove()
		if self.Emitter then
			self.Emitter:Finish()
			self.Emitter = nil
		end
	end

	function ENT:Think()
		if not self.Emitter then
			self.Emitter = ParticleEmitter(self:GetPos())
		end

		local now = CurTime()
		if now >= (self._nextPFX or 0) and self.Emitter then
			self._nextPFX = now + 1 / 90
			local pos = self:GetPos()
			local vel = (pos - (self._lastPos or pos)) / math.max(FrameTime(), 0.001)
			self._lastPos = pos
			local back = -vel:GetNormalized()

			local c = self:GetColor()

			for i = 1, 3 do
				local p = self.Emitter:Add("effects/yellowflare", pos + VectorRand() * 2)
				if p then
					p:SetVelocity(back * (60 + math.random(0, 40)) + VectorRand() * 20)
					p:SetDieTime(0.4 + math.Rand(0.1, 0.3))
					p:SetStartAlpha(220)
					p:SetEndAlpha(0)
					p:SetStartSize(4 + math.random(0, 2))
					p:SetEndSize(0)
					p:SetRoll(math.Rand(0, 360))
					p:SetRollDelta(math.Rand(-3, 3))
					p:SetColor(c.r, c.g, c.b)
					p:SetLighting(false)
					p:SetAirResistance(60)
					p:SetGravity(Vector(0, 0, -50))
					p:SetCollide(false)
				end
			end

			for i = 1, 2 do
				local mat = (math.random() < 0.5) and "effects/fire_cloud1" or "effects/fire_cloud2"
				local p = self.Emitter:Add(mat, pos)
				if p then
					p:SetVelocity(back * (40 + math.random(0, 30)) + VectorRand() * 10)
					p:SetDieTime(0.6 + math.Rand(0.2, 0.5))
					p:SetStartAlpha(180)
					p:SetEndAlpha(0)
					p:SetStartSize(10 + math.random(0, 8))
					p:SetEndSize(30 + math.random(0, 12))
					p:SetRoll(math.Rand(0, 360))
					p:SetRollDelta(math.Rand(-1, 1))
					p:SetColor(c.r, c.g, c.b)
					p:SetLighting(false)
					p:SetAirResistance(70)
					p:SetGravity(Vector(0, 0, 20))
					p:SetCollide(false)
				end
			end

			local hw = self.Emitter:Add("sprites/heatwave", pos)
			if hw then
				hw:SetVelocity(VectorRand() * 10)
				hw:SetDieTime(0.25)
				hw:SetStartAlpha(180)
				hw:SetEndAlpha(0)
				hw:SetStartSize(14)
				hw:SetEndSize(0)
				hw:SetRoll(math.Rand(0, 360))
				hw:SetRollDelta(math.Rand(-1, 1))
				hw:SetLighting(false)
			end
		end

		self:NextThink(now)
		return true
	end

	function ENT:Draw()
		local dlight = DynamicLight(self:EntIndex())
		if dlight then
			local c = self:GetColor()
			dlight.pos = self:GetPos()
			dlight.r = c.r
			dlight.g = c.g
			dlight.b = c.b
			dlight.brightness = 2.6 + math.Rand(0, 0.6)
			dlight.Decay = 900
			dlight.Size = 180
			dlight.DieTime = CurTime() + 0.1
		end
	end
end