ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "Lightning Orb"
ENT.Author = "Earu"
ENT.Spawnable = false
ENT.RenderGroup = RENDERGROUP_BOTH
ENT.AdminSpawnable = false
-- Tunables
ENT.OrbSpeed = 300
ENT.OrbRadius = 300
ENT.OrbTickDamage = 15
ENT.OrbTickInterval = 0.25
ENT.OrbMaxTargetsPerTick = 6
ENT.OrbExplodeDamage = 85
ENT.OrbExplodeRadius = 400
ENT.MaxLifetime = 6

function ENT:SetupDataTables()
	self:NetworkVar("Entity", 0, "SpellOwner")
end

if SERVER then
	AddCSLuaFile()
	util.AddNetworkString("Arcana_LightningOrbZap")
	util.AddNetworkString("Arcana_LightningOrbExplode")

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
		util.SpriteTrail(self, 0, Color(170, 210, 255, 200), true, 32, 8, 0.8, 1 / 64, "trails/electric.vmt")

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

		addSprite(self, "sprites/physbeam.vmt", Color(180, 220, 255), 0.8, "ArcanaLO_S1")
		addSprite(self, "sprites/light_glow02_add.vmt", Color(150, 200, 255), 1.2, "ArcanaLO_S2")
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
			local dmg = DamageInfo()
			dmg:SetDamage(self.OrbTickDamage or 15)
			dmg:SetDamageType(bit.bor(DMG_SHOCK, DMG_ENERGYBEAM))
			dmg:SetAttacker(IsValid(owner) and owner or self)
			dmg:SetInflictor(self)
			tgt:TakeDamageInfo(dmg)

			-- Send visual lightning arc to client
			net.Start("Arcana_LightningOrbZap", true)
			net.WriteVector(center)
			net.WriteVector(tgt:WorldSpaceCenter())
			net.Broadcast()
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
		Arcane:BlastDamage(self, IsValid(owner) and owner or self, pos, self.OrbExplodeRadius or 220, self.OrbExplodeDamage or 85, bit.bor(DMG_SHOCK, DMG_ENERGYBEAM), true)

		local ed = EffectData()
		ed:SetOrigin(pos)
		util.Effect("cball_explode", ed, true, true)
		util.Effect("ElectricSpark", ed, true, true)
		util.ScreenShake(pos, 10, 120, 0.5, 800)

		-- Impactful explosion sounds
		sound.Play("ambient/explosions/explode_" .. math.random(1, 3) .. ".wav", pos, 95, 110)
		--sound.Play("ambient/levels/labs/electric_explosion" .. math.random(1, 5) .. ".wav", pos, 95, 100)

		-- Send explosion visual to clients
		net.Start("Arcana_LightningOrbExplode", true)
		net.WriteVector(pos)
		net.Broadcast()

		self:Remove()
	end
end

if CLIENT then
	local LIGHTNING_COLOR = Color(170, 210, 255)
	local matBeam = Material("effects/laser1")
	local matFlare = Material("effects/blueflare1")
	local matGlow = Material("sprites/light_glow02_add")

	Arcane.LightningOrbZaps = Arcane.LightningOrbZaps or {}
	Arcane.LightningOrbExplosions = Arcane.LightningOrbExplosions or {}

	-- Receive zap arcs
	net.Receive("Arcana_LightningOrbZap", function()
		local startPos = net.ReadVector()
		local endPos = net.ReadVector()

		table.insert(Arcane.LightningOrbZaps, {
			startPos = startPos,
			endPos = endPos,
			dieTime = CurTime() + 0.2,
			startTime = CurTime()
		})
	end)

	-- Receive explosion
	net.Receive("Arcana_LightningOrbExplode", function()
		local pos = net.ReadVector()

		table.insert(Arcane.LightningOrbExplosions, {
			pos = pos,
			dieTime = CurTime() + 0.4,
			startTime = CurTime()
		})

		-- Massive particle explosion
		local emitter = ParticleEmitter(pos)
		if emitter then
			-- Electric burst
			for i = 1, 60 do
				local p = emitter:Add("effects/blueflare1", pos)
				if p then
					p:SetDieTime(math.Rand(0.4, 0.8))
					p:SetStartAlpha(255)
					p:SetEndAlpha(0)
					p:SetStartSize(math.Rand(15, 30))
					p:SetEndSize(0)
					p:SetColor(LIGHTNING_COLOR.r, LIGHTNING_COLOR.g, LIGHTNING_COLOR.b)
					p:SetVelocity(VectorRand() * 400)
					p:SetAirResistance(80)
					p:SetGravity(Vector(0, 0, -120))
				end
			end

			-- Sparks
			for i = 1, 40 do
				local p = emitter:Add("effects/spark", pos)
				if p then
					p:SetDieTime(math.Rand(0.5, 1.0))
					p:SetStartAlpha(255)
					p:SetEndAlpha(0)
					p:SetStartSize(math.Rand(3, 6))
					p:SetEndSize(0)
					p:SetColor(255, 255, 255)
					p:SetVelocity(VectorRand() * 350)
					p:SetGravity(Vector(0, 0, -600))
					p:SetCollide(true)
					p:SetBounce(0.3)
				end
			end

			emitter:Finish()
		end
	end)

	-- Render lightning arcs and explosions
	hook.Add("PostDrawTranslucentRenderables", "Arcana_RenderLightningOrbEffects", function()
		local curTime = CurTime()

		-- Render zap arcs
		for i = #Arcane.LightningOrbZaps, 1, -1 do
			local zap = Arcane.LightningOrbZaps[i]

			if curTime > zap.dieTime then
				table.remove(Arcane.LightningOrbZaps, i)
			else
				local frac = 1 - math.Clamp((zap.dieTime - curTime) / 0.2, 0, 1)
				local flicker = math.sin(curTime * 60 + zap.startTime * 80) * 0.3 + 0.7
				local alpha = (1 - frac) * 255 * flicker

				render.SetMaterial(matBeam)

				-- Generate jagged path
				local segments = 8
				local arcPath = {}
				for seg = 0, segments do
					local t = seg / segments
					local pos = LerpVector(t, zap.startPos, zap.endPos)
					local jaggedAmount = math.sin(t * math.pi) * 25
					pos = pos + VectorRand() * jaggedAmount
					arcPath[seg] = pos
				end

				-- White core
				render.StartBeam(segments + 1)
				for seg = 0, segments do
					local t = seg / segments
					local width = 10 * flicker
					render.AddBeam(arcPath[seg], width, t, Color(255, 255, 255, alpha))
				end
				render.EndBeam()

				-- Blue outer
				render.StartBeam(segments + 1)
				for seg = 0, segments do
					local t = seg / segments
					local width = 18 * flicker
					render.AddBeam(arcPath[seg], width, t, Color(LIGHTNING_COLOR.r, LIGHTNING_COLOR.g, LIGHTNING_COLOR.b, alpha * 0.7))
				end
				render.EndBeam()
			end
		end

		-- Render explosions
		for i = #Arcane.LightningOrbExplosions, 1, -1 do
			local exp = Arcane.LightningOrbExplosions[i]

			if curTime > exp.dieTime then
				table.remove(Arcane.LightningOrbExplosions, i)
			else
				local age = curTime - exp.startTime
				local frac = math.Clamp(age / 0.4, 0, 1)
				local alpha = (1 - frac) * 255

				-- Expanding electric sphere
				local size = Lerp(frac, 200, 600)

				render.SetMaterial(matGlow)
				render.DrawSprite(exp.pos, size, size, Color(255, 255, 255, alpha * 0.7))
				render.DrawSprite(exp.pos, size * 1.5, size * 1.5, Color(LIGHTNING_COLOR.r, LIGHTNING_COLOR.g, LIGHTNING_COLOR.b, alpha * 0.4))

				render.SetMaterial(matFlare)
				render.DrawSprite(exp.pos, size * 0.7, size * 0.7, Color(LIGHTNING_COLOR.r, LIGHTNING_COLOR.g, LIGHTNING_COLOR.b, alpha))

				-- Dynamic light
				local dlight = DynamicLight(math.random(20000, 29999))
				if dlight then
					dlight.pos = exp.pos
					dlight.r = 255
					dlight.g = 255
					dlight.b = 255
					dlight.brightness = Lerp(frac, 8, 2)
					dlight.Decay = 3000
					dlight.Size = size * 1.2
					dlight.DieTime = curTime + 0.1
				end
			end
		end
	end)

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

			-- Electric sparks trailing (more)
			for i = 1, 5 do
				local p = self.Emitter:Add("effects/spark", pos + VectorRand() * 4)

				if p then
					p:SetVelocity(back * (60 + math.random(0, 60)) + VectorRand() * 50)
					p:SetDieTime(0.3 + math.Rand(0.1, 0.2))
					p:SetStartAlpha(255)
					p:SetEndAlpha(0)
					p:SetStartSize(8 + math.random(0, 4))
					p:SetEndSize(0)
					p:SetRoll(math.Rand(0, 360))
					p:SetRollDelta(math.Rand(-8, 8))
					p:SetColor(180, 220, 255)
					p:SetAirResistance(80)
					p:SetCollide(false)
				end
			end

			-- Soft electric cloud (bigger)
			local mat = "effects/blueflare1"
			local p2 = self.Emitter:Add(mat, pos)

			if p2 then
				p2:SetVelocity(back * (50 + math.random(0, 40)) + VectorRand() * 15)
				p2:SetDieTime(0.5 + math.Rand(0.1, 0.3))
				p2:SetStartAlpha(180)
				p2:SetEndAlpha(0)
				p2:SetStartSize(22 + math.random(0, 10))
				p2:SetEndSize(40 + math.random(0, 15))
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
		-- Enhanced dynamic light for the orb
		local dlight = DynamicLight(self:EntIndex())

		if dlight then
			local c = self:GetColor()
			dlight.pos = self:GetPos()
			dlight.r = c.r or 170
			dlight.g = c.g or 210
			dlight.b = c.b or 255
			dlight.brightness = 3.2
			dlight.Decay = 1200
			dlight.Size = 250
			dlight.DieTime = CurTime() + 0.1
		end
	end
end