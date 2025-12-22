AddCSLuaFile()

ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "Magical Mushroom"
ENT.Author = "Arcana"
ENT.Spawnable = false
ENT.Category = "Arcana"
ENT.RenderGroup = RENDERGROUP_BOTH

-- Tunables
ENT.IdleGlowColor = Color(110, 200, 130)
ENT.IdleLightBrightness = 2.2
ENT.TripCooldown = 45 -- seconds per player

function ENT:SetupDataTables()
	self:NetworkVar("Float", 0, "TripRadius")
	self:NetworkVar("Float", 1, "GlowStrength")
	self:NetworkVar("Float", 2, "MushroomScale")
	if SERVER then
		self:SetTripRadius(120)
		self:SetGlowStrength(1)
		self:SetMushroomScale(4)
	end
end

if SERVER then
	resource.AddFile("models/props_swamp/shroom_ref_01.mdl")
	resource.AddFile("materials/models/props_swamp/shroom_diffuse.vmt")
	resource.AddFile("materials/models/props_swamp/shroom_diffuse.vtf")

	function ENT:Initialize()
		-- Use a solid physics model and render the mushroom clientside
		local s = math.random(20, 50)
		self:SetMushroomScale(s)

		local physModel = "models/hunter/blocks/cube1x1x1.mdl"
		self:SetModel(physModel)
		self:SetMoveType(MOVETYPE_VPHYSICS)
		self:PhysicsInit(SOLID_VPHYSICS)
		self:SetSolid(SOLID_VPHYSICS)
		self:SetUseType(SIMPLE_USE)

		local phys = self:GetPhysicsObject()
		if IsValid(phys) then
			phys:Wake()
			phys:EnableMotion(false)
		end

		-- Lift so the cube sits on the ground (bottom at Z=0)
		local mins = self:OBBMins()
		self:SetPos(self:GetPos() + Vector(0, 0, -mins.z))

		self._nextUse = 0
		self._nextSporeDrop = CurTime() + math.Rand(60, 180)
	end

	function ENT:SpawnFunction(ply, tr, classname)
		if not tr or not tr.Hit then return end
		local pos = tr.HitPos + tr.HitNormal * 4
		local ent = ents.Create(classname or "magical_mushroom")
		if not IsValid(ent) then return end
		ent:SetPos(pos)
		ent:SetAngles(Angle(0, ply:EyeAngles().y, 0))
		ent:Spawn()
		ent:Activate()
		return ent
	end

	local function canTrip(ply)
		if not IsValid(ply) or not ply:IsPlayer() then return false end
		if not ply:Alive() then return false end

		local now = CurTime()
		if now < (ply._arcanaNextMushroomTrip or 0) then return false end

		return true
	end

	function ENT:Use(ply)
		if not IsValid(ply) or not ply:IsPlayer() then return end
		if not canTrip(ply) then
			self:EmitSound("buttons/button10.wav", 60, 95)
			return
		end

		-- Start trip on this player
		ply._arcanaNextMushroomTrip = CurTime() + self.TripCooldown

		local dur = self.TripCooldown
		if Arcane and Arcane.Status and Arcane.Status.SporeHigh and Arcane.Status.SporeHigh.Apply then
			Arcane.Status.SporeHigh.Apply(ply, { duration = dur, intensity = 0.25 })
		end

		self:EmitSound("ambient/levels/canals/windchime2.wav", 70, 120)
		self:SetGlowStrength(1.6)

		timer.Simple(0.6, function()
			if IsValid(self) then self:SetGlowStrength(1) end
		end)

		-- Soft cooldown sparkle burst for others to see
		local ed = EffectData()
		ed:SetOrigin(self:WorldSpaceCenter())
		util.Effect("cball_bounce", ed, true, true)

		-- Do not remove; keep mushroom in world
	end

	-- Periodic random spore drops
	local SPORE_OFFSET = Vector(0, 0, 100)
	function ENT:Think()
		local now = CurTime()
		if now >= (self._nextSporeDrop or 0) then
			self._nextSporeDrop = now + math.Rand(90, 180)
			if math.Rand(0, 1) <= 0.45 then
				local ent = ents.Create("arcana_solidified_spores")
				if IsValid(ent) then
					local pos = self:GetPos() + VectorRand():GetNormalized() * math.Rand(80, 140) + SPORE_OFFSET
					ent:SetPos(pos)
					ent:Spawn()
					if ent.CPPISetOwner then ent:CPPISetOwner(self:CPPIGetOwner() or self) end

					constraint.NoCollide(ent, self, 0, 0)

					local ed = EffectData()
					ed:SetOrigin(ent:WorldSpaceCenter())
					util.Effect("cball_bounce", ed, true, true)
				end
			end
		end

		self:NextThink(CurTime() + 1)
		return true
	end
end

if CLIENT then
	local CLIENT_MUSHROOM_MODEL = "models/props_swamp/shroom_ref_01.mdl"

	function ENT:Initialize()
		self._emitter = ParticleEmitter(self:GetPos(), false)
		self._nextSpores = 0
		self._sfxLoop = nil

		-- Client-only mushroom visual model
		self._mdl = ClientsideModel(CLIENT_MUSHROOM_MODEL, RENDERGROUP_OPAQUE)
	end

	function ENT:OnRemove()
		if self._emitter then
			self._emitter:Finish()
			self._emitter = nil
		end

		if self._sfxLoop then
			self._sfxLoop:Stop()
			self._sfxLoop = nil
		end

		if IsValid(self._mdl) then
			self._mdl:Remove()
			self._mdl = nil
		end
	end

	local OFFSET_MUSHROOM_L = Vector(0, 0, 20)
	local OFFSET_MUSHROOM_M = Vector(0, 0, 10)
	local OFFSET_MUSHROOM_S = Vector(0, 0, 4)
	local function worldTop(self)
		return self:GetPos() + (OFFSET_MUSHROOM_M * (self:GetModelScale() / 2.2))
	end

	function ENT:Think()
		if self._emitter then self._emitter:SetPos(self:GetPos()) end

		-- Soft ambient loop near mushroom
		if not self._sfxLoop then
			self._sfxLoop = CreateSound(self, "ambient/atmosphere/tone_quiet.wav")
			if self._sfxLoop then
				self._sfxLoop:PlayEx(0.0, 140)
			end
		end

		if self._sfxLoop then
			local dist = EyePos():DistToSqr(self:GetPos())
			local vol = 0
			if dist < (1200 * 1200) then
				vol = Lerp(math.Clamp((math.sqrt(dist) - 200) / 900, 0, 1), 0.2, 0.0)
				vol = math.Clamp(0.2 - vol, 0, 0.2)
			end
			self._sfxLoop:ChangeVolume(vol, 0.2)
		end

		local now = CurTime()
		if now >= (self._nextSpores or 0) then
			self:_SpawnSpores()
			self._nextSpores = now + 0.06
		end

		self:SetNextClientThink(CurTime())
		return true
	end

	local MAX_RENDER_DIST = 1500 * 1500
	function ENT:_SpawnSpores()
		if not self._emitter then return end
		if EyePos():DistToSqr(self:GetPos()) > MAX_RENDER_DIST then return end

		local top = worldTop(self) + (OFFSET_MUSHROOM_M * (self:GetMushroomScale() / 2.2))
		local col = self.IdleGlowColor or Color(110, 200, 130)
		-- bright spore motes (greenish)
		for i = 1, 4 do
			local p = self._emitter:Add("sprites/light_glow02_add", top + VectorRand() * (self:GetMushroomScale() * 6))
			if p then
				p:SetStartAlpha(140)
				p:SetEndAlpha(0)
				p:SetStartSize(math.Rand(3, 6))
				p:SetEndSize(0)
				p:SetDieTime(math.Rand(0.7, 1.5))
				p:SetVelocity(Vector(math.Rand(-8, 8), math.Rand(-8, 8), math.Rand(14, 30)))
				p:SetAirResistance(14)
				p:SetRoll(math.Rand(-180, 180))
				p:SetRollDelta(math.Rand(-1, 1))
				-- add slight variance towards yellow-green
				local g = math.Clamp(col.g + math.random(-10, 15), 0, 255)
				local r = math.Clamp(col.r + math.random(-10, 10), 0, 255)
				local b = math.Clamp(col.b + math.random(-20, 0), 0, 255)
				p:SetColor(r, g, b)
			end
		end

		-- drifting larger spores (misty green puffs)
		for i = 1, 2 do
			local p = self._emitter:Add("particle/particle_smokegrenade", top + VectorRand() * self:GetMushroomScale() * 4)
			if p then
				p:SetStartAlpha(40)
				p:SetEndAlpha(0)
				p:SetStartSize(math.Rand(8, 12))
				p:SetEndSize(math.Rand(16, 26))
				p:SetDieTime(math.Rand(1.8, 2.6))
				p:SetVelocity(Vector(math.Rand(-8, 8), math.Rand(-8, 8), math.Rand(8, 16)))
				p:SetAirResistance(10)
				p:SetGravity(OFFSET_MUSHROOM_S)
				p:SetColor(120, 200, 120)
			end
		end
	end

	function ENT:Draw()
		-- Draw the client mushroom aligned to physics cube
		local s = math.max(1, self:GetMushroomScale() or 4)
		if IsValid(self._mdl) then
			self._mdl:SetModelScale(s, 0)
			self._mdl:SetPos(self:GetPos() - OFFSET_MUSHROOM_L)
			self._mdl:SetAngles(self:GetAngles())
			self._mdl:DrawModel()
		end
	end
end