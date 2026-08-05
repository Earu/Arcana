-- Generic crafted-spell projectile. One entity for every element, but each
-- element gets its own authentic look: a fire bolt IS a fireball (trail,
-- clouds, embers, heatwave), a lightning bolt crackles and sparks, frost
-- sheds ice, and so on. Damage/radius/speed live on the compiled spell stored
-- server-side (self._spellcraft); detonation visuals come from
-- Arcana.Spellcraft.ImpactFX via OnBoltDetonate.

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
	self:NetworkVar("String", 0, "Element")
end

if SERVER then
	AddCSLuaFile()

	-- Per-element serverside dressing: trail material + core sprites.
	local TRAILS = {
		fire = { trail = "trails/smoke.vmt", sprites = { { "sprites/orangecore1.vmt", 0.35 }, { "sprites/light_glow02_add.vmt", 0.6 } } },
		frost = { trail = "trails/tube.vmt", sprites = { { "sprites/light_glow02_add.vmt", 0.5 } } },
		lightning = { trail = "trails/electric.vmt", sprites = { { "sprites/light_glow02_add.vmt", 0.7 } } },
		earth = { trail = "trails/smoke.vmt", sprites = {} },
		wind = { trail = nil, sprites = { { "sprites/light_glow02_add.vmt", 0.3 } } },
		poison = { trail = "trails/plasma.vmt", sprites = { { "sprites/light_glow02_add.vmt", 0.4 } } },
		arcane = { trail = "trails/laser.vmt", sprites = { { "sprites/light_glow02_add.vmt", 0.6 } } },
		aurum = { trail = "trails/plasma.vmt", sprites = { { "sprites/orangecore1.vmt", 0.35 }, { "sprites/light_glow02_add.vmt", 0.6 } } },
	}

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

		local dress = TRAILS[self:GetElement()] or TRAILS.arcane
		if dress.trail then
			util.SpriteTrail(self, 0, Color(col.r, col.g, col.b, 220), true, 16, 2, 0.45, 1 / 128, dress.trail)
		end
		if Arcana and Arcana.Common and Arcana.Common.AddEntitySprite then
			for i, spr in ipairs(dress.sprites) do
				Arcana.Common.AddEntitySprite(self, spr[1], col, spr[2], "ArcanaSB_S" .. i)
			end
		end

		self.Created = CurTime()

		-- Modifier state (compiled spell is assigned before Spawn by CastBolt).
		self._bounces = self._spellcraft and self._spellcraft.ricochets or 0
		self._pierceCount = 0

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
				local steered = LerpVector(0.2, cur, desired):GetNormalized()
				phys:SetVelocity(steered * speed)
			end
		end
		self:NextThink(CurTime())
		return true
	end

	local function isSolidNonTrigger(ent)
		return Arcana and Arcana.Common and Arcana.Common.IsSolidNonTrigger(ent)
	end

	local function isActorEnt(ent)
		return IsValid(ent) and (ent:IsPlayer() or ent:IsNPC() or (ent.IsNextBot and ent:IsNextBot()))
	end

	-- The caster and the machine that fired the bolt are both off limits: a
	-- spell caster sits right behind its own muzzle, and a ricochet coming back
	-- must not blow up on the emitter.
	function ENT:IsOwnSource(ent)
		if not IsValid(ent) then return false end
		if ent == self:GetSpellOwner() then return true end

		return IsValid(self._spellcraftSource) and ent == self._spellcraftSource
	end

	function ENT:PhysicsCollide(data, phys)
		if self._detonated then return end
		if (CurTime() - (self.Created or 0)) < 0.03 then return end
		local hit = data.HitEntity
		local sc = self._spellcraft

		-- Piercing bolts fly through actors; the Touch handler strikes them.
		if isActorEnt(hit) and sc and sc.pierce then return end
		if self:IsOwnSource(hit) then return end

		if (IsValid(hit) and isSolidNonTrigger(hit)) or hit:IsWorld() then
			-- Ricochet: reflect off surfaces (never actors) while bounces remain.
			if not isActorEnt(hit) and (self._bounces or 0) > 0 then
				self._bounces = self._bounces - 1

				local vel = data.OurOldVelocity
				local n = data.HitNormal
				local reflected = vel - 2 * vel:Dot(n) * n
				timer.Simple(0, function()
					if not IsValid(self) then return end
					local p = self:GetPhysicsObject()
					if IsValid(p) then p:SetVelocity(reflected) end
				end)

				self:EmitSound("physics/concrete/rock_impact_hard" .. math.random(1, 3) .. ".wav", 65, 130)
				if Arcana.Spellcraft and Arcana.Spellcraft.ImpactFX then
					Arcana.Spellcraft.ImpactFX(self:GetElement(), data.HitPos or self:GetPos(), 50, 0.3)
				end
				return
			end

			self:Detonate()
		end
	end

	function ENT:Touch(ent)
		if self._detonated then return end
		if self:IsOwnSource(ent) then return end
		if (CurTime() - (self.Created or 0)) < 0.03 then return end

		local sc = self._spellcraft

		-- Piercing: strike the victim directly and keep flying.
		if isActorEnt(ent) and sc and sc.pierce then
			self._pierced = self._pierced or {}
			if self._pierced[ent] then return end
			self._pierced[ent] = true
			self._pierceCount = (self._pierceCount or 0) + 1

			local caster = self._spellcraftCaster
			if IsValid(caster) and not (ent:IsPlayer() and not ent:Alive()) then
				local mult = self._pierceCount == 1 and 1 or 0.85
				local dmg = DamageInfo()
				dmg:SetDamage(sc.damage * mult)
				dmg:SetDamageType(sc.damageType)
				dmg:SetAttacker(caster)
				dmg:SetInflictor(self)
				dmg:SetDamagePosition(ent:WorldSpaceCenter())
				Arcana:TakeDamageInfo(ent, dmg)
				Arcana.Spellcraft.ApplyEssenceHit(caster, ent, self:GetPos(), sc)
				Arcana.Spellcraft.ImpactFX(self:GetElement(), self:GetPos(), 60, 0.4)
			end

			-- Fly on: drop any homing lock so it doesn't orbit the victim.
			self._homingTarget = nil

			-- Spent after four victims: fizzle out (no full blast on top of
			-- the pierced hits; the damage cap already accounts for them).
			if self._pierceCount >= 4 then
				self._detonated = true
				self:Remove()
			end
			return
		end

		if isSolidNonTrigger(ent) then self:Detonate() end
	end

	function ENT:Detonate()
		if self._detonated then return end
		self._detonated = true

		-- All detonation visuals/sounds come from the element ImpactFX,
		-- fired by the runtime's AreaEssence.
		if Arcana and Arcana.Spellcraft and Arcana.Spellcraft.OnBoltDetonate then
			Arcana.Spellcraft.OnBoltDetonate(self, self:GetPos())
		end

		self:Remove()
	end
end

if CLIENT then
	-- Per-element in-flight particles. Each takes (emitter, pos, back, col).
	local function fxFire(emitter, pos, back, col)
		for _ = 1, 3 do
			local p = emitter:Add("effects/yellowflare", pos + VectorRand() * 2)
			if p then
				p:SetVelocity(back * (60 + math.random(0, 40)) + VectorRand() * 20)
				p:SetDieTime(0.4 + math.Rand(0.1, 0.3))
				p:SetStartAlpha(220)
				p:SetEndAlpha(0)
				p:SetStartSize(4 + math.random(0, 2))
				p:SetEndSize(0)
				p:SetRoll(math.Rand(0, 360))
				p:SetRollDelta(math.Rand(-3, 3))
				p:SetColor(col.r, col.g, col.b)
				p:SetLighting(false)
				p:SetAirResistance(60)
				p:SetGravity(Vector(0, 0, -50))
				p:SetCollide(false)
			end
		end

		for _ = 1, 2 do
			local mat = (math.random() < 0.5) and "effects/fire_cloud1" or "effects/fire_cloud2"
			local p = emitter:Add(mat, pos)
			if p then
				p:SetVelocity(back * (40 + math.random(0, 30)) + VectorRand() * 10)
				p:SetDieTime(0.6 + math.Rand(0.2, 0.5))
				p:SetStartAlpha(180)
				p:SetEndAlpha(0)
				p:SetStartSize(10 + math.random(0, 8))
				p:SetEndSize(30 + math.random(0, 12))
				p:SetRoll(math.Rand(0, 360))
				p:SetRollDelta(math.Rand(-1, 1))
				p:SetColor(col.r, col.g, col.b)
				p:SetLighting(false)
				p:SetAirResistance(70)
				p:SetGravity(Vector(0, 0, 20))
				p:SetCollide(false)
			end
		end

		local hw = emitter:Add("sprites/heatwave", pos)
		if hw then
			hw:SetVelocity(VectorRand() * 10)
			hw:SetDieTime(0.25)
			hw:SetStartAlpha(180)
			hw:SetEndAlpha(0)
			hw:SetStartSize(14)
			hw:SetEndSize(0)
			hw:SetLighting(false)
		end
	end

	local function fxLightning(emitter, pos, back, col)
		for _ = 1, 4 do
			local p = emitter:Add("effects/spark", pos + VectorRand() * 4)
			if p then
				p:SetVelocity(back * (60 + math.random(0, 60)) + VectorRand() * 50)
				p:SetDieTime(0.25 + math.Rand(0.05, 0.15))
				p:SetStartAlpha(255)
				p:SetEndAlpha(0)
				p:SetStartSize(6 + math.random(0, 4))
				p:SetEndSize(0)
				p:SetColor(col.r, col.g, col.b)
				p:SetAirResistance(80)
				p:SetCollide(false)
			end
		end

		local p2 = emitter:Add("effects/blueflare1", pos)
		if p2 then
			p2:SetVelocity(back * (50 + math.random(0, 40)) + VectorRand() * 15)
			p2:SetDieTime(0.4 + math.Rand(0.1, 0.2))
			p2:SetStartAlpha(180)
			p2:SetEndAlpha(0)
			p2:SetStartSize(16 + math.random(0, 8))
			p2:SetEndSize(30)
			p2:SetColor(col.r, col.g, col.b)
			p2:SetAirResistance(70)
			p2:SetCollide(false)
		end
	end

	local function fxFrost(emitter, pos, back, col)
		if math.random() < 0.7 then
			local mat = (math.random() < 0.5) and "effects/fleck_glass1" or "effects/fleck_glass2"
			local p = emitter:Add(mat, pos + VectorRand() * 3)
			if p then
				p:SetVelocity(back * 40 + VectorRand() * 30)
				p:SetDieTime(math.Rand(0.3, 0.6))
				p:SetStartAlpha(255)
				p:SetEndAlpha(0)
				p:SetStartSize(math.Rand(2, 4))
				p:SetEndSize(0)
				p:SetColor(200, 230, 255)
				p:SetGravity(Vector(0, 0, -180))
				p:SetCollide(false)
			end
		end

		local m = emitter:Add("particle/particle_smokegrenade", pos)
		if m then
			m:SetVelocity(back * 30 + VectorRand() * 10)
			m:SetDieTime(0.45)
			m:SetStartAlpha(45)
			m:SetEndAlpha(0)
			m:SetStartSize(7)
			m:SetEndSize(18)
			m:SetColor(215, 235, 255)
			m:SetAirResistance(60)
		end
	end

	local function fxEarth(emitter, pos, back, col)
		local p = emitter:Add("particle/particle_smokegrenade", pos)
		if p then
			p:SetVelocity(back * (30 + math.random(0, 20)) + VectorRand() * 12)
			p:SetDieTime(0.6 + math.Rand(0.1, 0.3))
			p:SetStartAlpha(90)
			p:SetEndAlpha(0)
			p:SetStartSize(9)
			p:SetEndSize(24)
			p:SetColor(120, 110, 100)
			p:SetAirResistance(60)
		end

		if math.random() < 0.5 then
			local mat = (math.random() < 0.5) and "effects/fleck_cement1" or "effects/fleck_cement2"
			local f = emitter:Add(mat, pos + VectorRand() * 3)
			if f then
				f:SetVelocity(VectorRand() * 60)
				f:SetDieTime(math.Rand(0.3, 0.6))
				f:SetStartAlpha(255)
				f:SetEndAlpha(0)
				f:SetStartSize(math.Rand(2, 4))
				f:SetEndSize(0)
				f:SetColor(140, 130, 120)
				f:SetGravity(Vector(0, 0, -400))
			end
		end
	end

	local function fxWind(emitter, pos, back, col)
		local p = emitter:Add("effects/splash2", pos)
		if p then
			p:SetVelocity(back * (60 + math.random(0, 30)) + VectorRand() * 20)
			p:SetDieTime(0.3)
			p:SetStartAlpha(70)
			p:SetEndAlpha(0)
			p:SetStartSize(6)
			p:SetEndSize(16)
			p:SetRoll(math.Rand(0, 360))
			p:SetRollDelta(math.Rand(-4, 4))
			p:SetColor(220, 240, 245)
			p:SetAirResistance(50)
		end
	end

	local function fxPoison(emitter, pos, back, col)
		local p = emitter:Add("particle/particle_smokegrenade", pos)
		if p then
			local cv = math.Rand(0.8, 1.1)
			p:SetVelocity(back * 30 + VectorRand() * 12 + Vector(0, 0, -20))
			p:SetDieTime(0.7 + math.Rand(0.1, 0.4))
			p:SetStartAlpha(80)
			p:SetEndAlpha(0)
			p:SetStartSize(8)
			p:SetEndSize(22)
			p:SetColor(100 * cv, 180 * cv, 50 * cv)
			p:SetAirResistance(70)
		end

		if math.random() < 0.4 then
			local d = emitter:Add("effects/blueflare1", pos)
			if d then
				d:SetVelocity(Vector(0, 0, -60) + VectorRand() * 15)
				d:SetDieTime(0.4)
				d:SetStartAlpha(160)
				d:SetEndAlpha(0)
				d:SetStartSize(5)
				d:SetEndSize(0)
				d:SetColor(120, 220, 70)
			end
		end
	end

	local function fxArcane(emitter, pos, back, col)
		for _ = 1, 2 do
			local p = emitter:Add("effects/blueflare1", pos + VectorRand() * 3)
			if p then
				p:SetVelocity(back * (50 + math.random(0, 30)) + VectorRand() * 16)
				p:SetDieTime(0.35 + math.Rand(0.1, 0.2))
				p:SetStartAlpha(210)
				p:SetEndAlpha(0)
				p:SetStartSize(6 + math.random(0, 4))
				p:SetEndSize(0)
				p:SetColor(col.r, col.g, col.b)
				p:SetAirResistance(70)
				p:SetCollide(false)
			end
		end
	end

	local function fxAurum(emitter, pos, back, col)
		fxFire(emitter, pos, back, Color(255, 200, 80))
		if math.random() < 0.4 then
			local p = emitter:Add("sprites/light_glow02_add", pos + VectorRand() * 4)
			if p then
				p:SetVelocity(VectorRand() * 30)
				p:SetDieTime(0.5)
				p:SetStartAlpha(220)
				p:SetEndAlpha(0)
				p:SetStartSize(math.Rand(2, 5))
				p:SetEndSize(0)
				p:SetColor(255, 230, 140)
			end
		end
	end

	local ELEMENT_FX = {
		fire = fxFire,
		frost = fxFrost,
		lightning = fxLightning,
		earth = fxEarth,
		wind = fxWind,
		poison = fxPoison,
		arcane = fxArcane,
		aurum = fxAurum,
	}

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

			local fx = ELEMENT_FX[self:GetElement()] or fxArcane
			fx(self.Emitter, pos, back, self:GetColor())
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
			dl.brightness = 2.4 + math.Rand(0, 0.5)
			dl.Decay = 900
			dl.Size = 170
			dl.DieTime = CurTime() + 0.1
		end
	end
end
