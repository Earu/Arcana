ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "Ice Bolt"
ENT.Author = "Earu"
ENT.Spawnable = false
ENT.AdminSpawnable = false

-- Tunables
ENT.BoltSpeed = 2400
ENT.EffectRadius = 100 -- primarily single-target; small grace radius
ENT.SlowMult = 0.5
ENT.SlowDuration = 3.5
ENT.MaxLifetime = 4

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
		local phys = self:GetPhysicsObject()

		if IsValid(phys) then
			phys:EnableGravity(false)
			phys:Wake()
		end

		self:SetColor(Color(170, 220, 255, 255))
		self:SetMaterial("models/debug/debugwhite")
		util.SpriteTrail(self, 0, Color(170, 220, 255, 220), true, 12, 1, 0.35, 1 / 128, "trails/smoke.vmt")

		local function addSprite(parent, model, color, scale, name)
			local spr = ents.Create("env_sprite")
			if not IsValid(spr) then return end

			spr:SetKeyValue("model", model)
			spr:SetKeyValue("rendercolor", string.format("%d %d %d", color.r, color.g, color.b))
			spr:SetKeyValue("rendermode", "9")
			spr:SetKeyValue("scale", tostring(scale))
			spr:SetParent(parent)
			spr:Spawn()
			spr:Activate()

			parent:CallOnRemove(name or ("ArcanaIceSprite_" .. model), function(_, s)
				if IsValid(s) then s:Remove() end
			end, spr)
		end

		addSprite(self, "sprites/blueflare1.vmt", Color(180, 230, 255), 0.35, "ArcanaIce_S1")
		addSprite(self, "sprites/light_glow02_add.vmt", Color(160, 210, 255), 0.55, "ArcanaIce_S2")
		self.Created = CurTime()

		timer.Simple(self.MaxLifetime or 4, function()
			if IsValid(self) and not self._detonated then
				self:Detonate()
			end
		end)
	end

	function ENT:LaunchTowards(dir)
		local phys = self:GetPhysicsObject()
		if IsValid(phys) then
			phys:SetVelocity(dir:GetNormalized() * (self.BoltSpeed or 2400))
		end
	end

	local function isSolidNonTrigger(ent)
		if not IsValid(ent) then return false end
		if ent:IsWorld() then return true end

		local solid = ent.GetSolid and ent:GetSolid() or SOLID_NONE
		if solid == SOLID_NONE then return false end

		local flags = ent.GetSolidFlags and ent:GetSolidFlags() or 0
		return bit.band(flags, FSOLID_TRIGGER) == 0
	end

	function ENT:PhysicsCollide(data, phys)
		if self._detonated then return end
		if (CurTime() - (self.Created or 0)) < 0.02 then return end

		local hit = data.HitEntity
		if (IsValid(hit) and hit ~= self:GetSpellOwner() and isSolidNonTrigger(hit)) or data.HitWorld then
			self._impactPos = data.HitPos
			self._impactNormal = data.HitNormal
			self._impactEnt = IsValid(hit) and hit or nil
			self:Detonate()
		end
	end

	function ENT:Touch(ent)
		if self._detonated then return end
		if ent == self:GetSpellOwner() then return end
		if (CurTime() - (self.Created or 0)) < 0.02 then return end

		if isSolidNonTrigger(ent) then
			self._impactEnt = ent
			self:Detonate()
		end
	end

	function ENT:Detonate()
		if self._detonated then return end

		self._detonated = true
		local owner = self:GetSpellOwner() or self
		local pos = self._impactPos or self:GetPos()
		local target = self._impactEnt

		local function applyFreeze(ent)
			if not IsValid(ent) then return end
			if not (ent:IsPlayer() or ent:IsNPC() or (ent.IsNextBot and ent:IsNextBot())) then return end
			if not Arcane or not Arcane.Status or not Arcane.Status.Frost or not Arcane.Status.Frost.Apply then return end

			Arcane.Status.Frost.Apply(ent, {
				slowMult = self.SlowMult or 0.25,
				duration = self.SlowDuration or 3.0,
				vfxTag = "ice_bolt_freeze",
				sendClientFX = ent:IsPlayer()
			})
		end

		if IsValid(target) then
			applyFreeze(target)
		else
			for _, v in ipairs(ents.FindInSphere(pos, self.EffectRadius or 48)) do
				applyFreeze(v)
			end
		end

		local ed = EffectData()
		ed:SetOrigin(pos)
		util.Effect("GlassImpact", ed, true, true)
		util.ScreenShake(pos, 3, 50, 0.2, 256)
		sound.Play("physics/glass/glass_impact_bullet1.wav", pos, 70, 150)
		sound.Play("ambient/levels/canals/windchime2.wav", pos, 65, 180)
		util.Decal("FadingScorch", pos + Vector(0, 0, 8), pos - Vector(0, 0, 16))

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

			-- cold sparkle
			for i = 1, 2 do
				local p = self.Emitter:Add("effects/fleck_glass1", pos + VectorRand() * 2)
				if p then
					p:SetVelocity(back * (60 + math.random(0, 40)) + VectorRand() * 15)
					p:SetDieTime(0.3 + math.Rand(0.1, 0.2))
					p:SetStartAlpha(255)
					p:SetEndAlpha(0)
					p:SetStartSize(2)
					p:SetEndSize(0)
					p:SetRoll(math.Rand(0, 360))
					p:SetRollDelta(math.Rand(-12, 12))
					p:SetColor(200, 230, 255)
					p:SetLighting(false)
					p:SetAirResistance(40)
					p:SetGravity(Vector(0, 0, -100))
					p:SetCollide(true)
					p:SetBounce(0.3)
				end
			end

			-- cold mist
			local m = self.Emitter:Add("particle/particle_smokegrenade", pos)
			if m then
				m:SetVelocity(back * (40 + math.random(0, 30)) + VectorRand() * 10)
				m:SetDieTime(0.4 + math.Rand(0.15, 0.25))
				m:SetStartAlpha(100)
				m:SetEndAlpha(0)
				m:SetStartSize(6)
				m:SetEndSize(18)
				m:SetColor(200, 230, 255)
				m:SetAirResistance(60)
				m:SetGravity(Vector(0, 0, 10))
			end
		end

		self:NextThink(now)
		return true
	end
end


