-- Generic crafted spell projectile. One entity for every essence/clause combination —
-- its damage, radius, colour, homing, and essence rider live on the compiled
-- crafted spell stored server-side (self._spellcraft), so no per-spell entity is needed.

ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "Spellcraft Bolt"
ENT.Author = "Earu"
ENT.Spawnable = false
ENT.AdminSpawnable = false
ENT.RenderGroup = RENDERGROUP_BOTH

ENT.MaxLifetime = 6

function ENT:SetupDataTables()
	self:NetworkVar("Entity", 0, "SpellOwner")
	self:NetworkVar("Float", 0, "ProjectileSpeed")
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

		local col = self:GetColor()
		self:SetMaterial("models/debug/debugwhite")
		util.SpriteTrail(self, 0, Color(col.r, col.g, col.b, 220), true, 16, 2, 0.45, 1 / 128, "trails/smoke.vmt")

		if Arcana and Arcana.Common and Arcana.Common.AddEntitySprite then
			Arcana.Common.AddEntitySprite(self, "sprites/light_glow02_add.vmt", col, 0.5, "ArcanaPB_S1")
		end

		self.Created = CurTime()

		timer.Simple(self.MaxLifetime, function()
			if IsValid(self) and not self._detonated then self:Detonate() end
		end)
	end

	function ENT:SetHomingTarget(ent)
		self._homingTarget = ent
	end

	function ENT:LaunchTowards(dir)
		self._dir = dir:GetNormalized()
		local phys = self:GetPhysicsObject()
		if IsValid(phys) then
			phys:SetVelocity(self._dir * (self:GetProjectileSpeed() > 0 and self:GetProjectileSpeed() or 1200))
		end
	end

	function ENT:Think()
		-- Homing steer: bend velocity toward the target while preserving speed.
		if IsValid(self._homingTarget) then
			local phys = self:GetPhysicsObject()
			if IsValid(phys) then
				local speed = self:GetProjectileSpeed() > 0 and self:GetProjectileSpeed() or 1200
				local desired = (self._homingTarget:WorldSpaceCenter() - self:WorldSpaceCenter()):GetNormalized()
				local cur = phys:GetVelocity():GetNormalized()
				local steered = LerpVector(0.1, cur, desired):GetNormalized()
				phys:SetVelocity(steered * speed)
			end
		end
		self:NextThink(CurTime())
		return true
	end

	local function isSolidNonTrigger(ent)
		return Arcana and Arcana.Common and Arcana.Common.IsSolidNonTrigger(ent)
	end

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
		if isSolidNonTrigger(ent) then self:Detonate() end
	end

	function ENT:Detonate()
		if self._detonated then return end
		self._detonated = true

		local pos = self:GetPos()
		if Arcana and Arcana.Spellcraft and Arcana.Spellcraft.OnBoltDetonate then
			Arcana.Spellcraft.OnBoltDetonate(self, pos)
		end

		local ed = EffectData()
		ed:SetOrigin(pos)
		util.Effect("cball_explode", ed, true, true)
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
			self._nextPFX = now + 1 / 60
			local pos = self:GetPos()
			local vel = (pos - (self._lastPos or pos)) / math.max(FrameTime(), 0.001)
			self._lastPos = pos
			local back = -vel:GetNormalized()
			local c = self:GetColor()

			for _ = 1, 2 do
				local p = self.Emitter:Add("effects/softglow", pos + VectorRand() * 2)
				if p then
					p:SetVelocity(back * (50 + math.random(0, 30)) + VectorRand() * 16)
					p:SetDieTime(0.35 + math.Rand(0.1, 0.25))
					p:SetStartAlpha(210)
					p:SetEndAlpha(0)
					p:SetStartSize(4 + math.random(0, 2))
					p:SetEndSize(0)
					p:SetColor(c.r, c.g, c.b)
					p:SetLighting(false)
					p:SetAirResistance(60)
					p:SetCollide(false)
				end
			end
		end

		self:NextThink(now)
		return true
	end

	function ENT:Draw()
		local dl = DynamicLight(self:EntIndex())
		if dl then
			local c = self:GetColor()
			dl.pos = self:GetPos()
			dl.r, dl.g, dl.b = c.r, c.g, c.b
			dl.brightness = 2.2 + math.Rand(0, 0.5)
			dl.Decay = 900
			dl.Size = 150
			dl.DieTime = CurTime() + 0.1
		end
	end
end
