ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "Lightning Orb"
ENT.Author = "Arcana"
ENT.Spawnable = false
ENT.AdminSpawnable = false
-- Tunables
ENT.OrbSpeed = 300
ENT.OrbRadius = 300
ENT.OrbTickDamage = 12
ENT.OrbTickInterval = 0.25
ENT.OrbMaxTargetsPerTick = 6
ENT.OrbExplodeDamage = 55
ENT.OrbExplodeRadius = 400
ENT.MaxLifetime = 6

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
		self:DrawShadow(false)
		local phys = self:GetPhysicsObject()

		if IsValid(phys) then
			phys:EnableGravity(false)
			phys:Wake()
		end

		self:SetColor(Color(170, 210, 255, 255))
		self:SetMaterial("models/debug/debugwhite")
		util.SpriteTrail(self, 0, Color(170, 210, 255, 200), true, 22, 6, 0.6, 1 / 64, "trails/electric.vmt")

		-- Add a couple of sprites for a bright electric core
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

			parent:CallOnRemove(name or ("ArcanaLightningOrb_" .. model), function(_, s)
				if IsValid(s) then
					s:Remove()
				end
			end, spr)
		end

		addSprite(self, "sprites/physbeam.vmt", Color(180, 220, 255), 0.5, "ArcanaLO_S1")
		addSprite(self, "sprites/light_glow02_add.vmt", Color(150, 200, 255), 0.8, "ArcanaLO_S2")
		self.Created = CurTime()
		self._nextTick = CurTime() + (self.OrbTickInterval or 0.25)

		timer.Simple(self.MaxLifetime or 6, function()
			if IsValid(self) and not self._detonated then
				self:Detonate()
			end
		end)
	end

	function ENT:LaunchTowards(dir)
		local phys = self:GetPhysicsObject()

		if IsValid(phys) then
			phys:SetVelocity(dir:GetNormalized() * (self.OrbSpeed or 520))
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
		if (CurTime() - (self.Created or 0)) < 0.03 then return end
		local hit = data.HitEntity

		if (IsValid(hit) and hit ~= self:GetSpellOwner() and isSolidNonTrigger(hit)) or data.HitWorld then
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

	local function spawnTeslaBurst(pos, radius)
		local tesla = ents.Create("point_tesla")
		if not IsValid(tesla) then return end
		tesla:SetPos(pos)
		tesla:SetKeyValue("targetname", "arcana_lightning_orb")
		tesla:SetKeyValue("m_SoundName", "DoSpark")
		tesla:SetKeyValue("texture", "sprites/physbeam.vmt")
		tesla:SetKeyValue("m_Color", "170 210 255")
		tesla:SetKeyValue("m_flRadius", radius)
		tesla:SetKeyValue("beamcount_min", "4")
		tesla:SetKeyValue("beamcount_max", "7")
		tesla:SetKeyValue("thick_min", "4")
		tesla:SetKeyValue("thick_max", "7")
		tesla:SetKeyValue("lifetime_min", "0.08")
		tesla:SetKeyValue("lifetime_max", "0.12")
		tesla:SetKeyValue("interval_min", "0.03")
		tesla:SetKeyValue("interval_max", "0.06")
		tesla:Spawn()
		tesla:Fire("DoSpark", "", 0)
		tesla:Fire("Kill", "", 0.4)

		return tesla
	end

	function ENT:ZapTick()
		local owner = self:GetSpellOwner()
		local center = self:WorldSpaceCenter()
		local radius = self.OrbRadius or 180
		local targets = {}

		for _, ent in ipairs(ents.FindInSphere(center, radius)) do
			if #targets >= (self.OrbMaxTargetsPerTick or 6) then break end
			local isValidTarget = IsValid(ent) and ent ~= self and ent ~= owner
			isValidTarget = isValidTarget and (ent:IsPlayer() or ent:IsNPC() or (ent.IsNextBot and ent:IsNextBot()))
			isValidTarget = isValidTarget and (not ent:IsPlayer() or ent:Alive())
			isValidTarget = isValidTarget and (not ent:IsNPC() or ent:Health() > 0)

			if isValidTarget then
				local tpos = ent:WorldSpaceCenter()

				local tr = util.TraceHull({
					start = center,
					endpos = tpos,
					mins = Vector(-2, -2, -2),
					maxs = Vector(2, 2, 2),
					mask = MASK_SHOT,
					filter = function(hit)
						if hit == self or hit == owner then return false end
						if IsValid(hit) and hit:GetParent() == self then return false end

						return true
					end
				})

				local clearLOS = (not tr.Hit) or (tr.Entity == ent) or (tr.Fraction >= 0.98)
				local veryClose = ent:NearestPoint(center):DistToSqr(center) <= (radius * 0.25) ^ 2

				if clearLOS or veryClose then
					table.insert(targets, ent)
				end
			end
		end

		if #targets > 0 then
			spawnTeslaBurst(center, radius)
		end

		for _, tgt in ipairs(targets) do
			local tpos = tgt:WorldSpaceCenter()
			local dmg = DamageInfo()
			dmg:SetDamage(self.OrbTickDamage or 12)
			dmg:SetDamageType(bit.bor(DMG_SHOCK, DMG_ENERGYBEAM))
			dmg:SetAttacker(IsValid(owner) and owner or self)
			dmg:SetInflictor(self)
			dmg:SetDamagePosition(tpos)

			if tgt.ForceTakeDamageInfo then
				tgt:ForceTakeDamageInfo(dmg)
			else
				tgt:TakeDamageInfo(dmg)
			end
		end
	end

	function ENT:Think()
		local now = CurTime()

		if now >= (self._nextTick or 0) then
			self._nextTick = now + (self.OrbTickInterval or 0.25)
			self:ZapTick()
		end

		self:NextThink(now)

		return true
	end

	function ENT:Detonate()
		if self._detonated then return end
		self._detonated = true
		local owner = self:GetSpellOwner() or self
		local pos = self:GetPos()
		util.BlastDamage(self, IsValid(owner) and owner or self, pos, self.OrbExplodeRadius or 220, self.OrbExplodeDamage or 55)
		local ed = EffectData()
		ed:SetOrigin(pos)
		util.Effect("cball_explode", ed, true, true)
		util.ScreenShake(pos, 6, 90, 0.35, 600)
		sound.Play("ambient/energy/zap" .. math.random(1, 9) .. ".wav", pos, 95, 100)
		sound.Play("ambient/levels/citadel/weapon_disintegrate3.wav", pos, 90, 110)
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

			-- Electric sparks trailing
			for i = 1, 3 do
				local p = self.Emitter:Add("effects/spark", pos + VectorRand() * 2)

				if p then
					p:SetVelocity(back * (60 + math.random(0, 40)) + VectorRand() * 30)
					p:SetDieTime(0.25 + math.Rand(0.05, 0.15))
					p:SetStartAlpha(255)
					p:SetEndAlpha(0)
					p:SetStartSize(6 + math.random(0, 2))
					p:SetEndSize(0)
					p:SetRoll(math.Rand(0, 360))
					p:SetRollDelta(math.Rand(-6, 6))
					p:SetColor(180, 220, 255)
					p:SetAirResistance(80)
					p:SetCollide(false)
				end
			end

			-- Soft electric cloud
			local mat = "effects/blueflare1"
			local p2 = self.Emitter:Add(mat, pos)

			if p2 then
				p2:SetVelocity(back * (40 + math.random(0, 30)) + VectorRand() * 10)
				p2:SetDieTime(0.4 + math.Rand(0.1, 0.2))
				p2:SetStartAlpha(160)
				p2:SetEndAlpha(0)
				p2:SetStartSize(16 + math.random(0, 8))
				p2:SetEndSize(32 + math.random(0, 12))
				p2:SetRoll(math.Rand(0, 360))
				p2:SetRollDelta(math.Rand(-1, 1))
				p2:SetColor(170, 210, 255)
				p2:SetAirResistance(70)
				p2:SetCollide(false)
			end
		end

		self:NextThink(now)

		return true
	end

	function ENT:Draw()
		-- Dynamic light for the orb
		local dlight = DynamicLight(self:EntIndex())

		if dlight then
			local c = self:GetColor()
			dlight.pos = self:GetPos()
			dlight.r = c.r or 170
			dlight.g = c.g or 210
			dlight.b = c.b or 255
			dlight.brightness = 2.4
			dlight.Decay = 900
			dlight.Size = 190
			dlight.DieTime = CurTime() + 0.1
		end
	end
end