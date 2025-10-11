AddCSLuaFile()

ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "Magical Mushroom"
ENT.Author = "Arcana"
ENT.Spawnable = true
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
	util.AddNetworkString("Arcana_Mushroom_TripStart")
	util.AddNetworkString("Arcana_Mushroom_TripEnd")

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
		self._nextSpore = 0
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
		net.Start("Arcana_Mushroom_TripStart")
		net.WriteFloat(dur)
		net.Send(ply)

		self:EmitSound("ambient/levels/canals/windchime2.wav", 70, 120)
		self:SetGlowStrength(1.6)

		timer.Simple(0.6, function()
			if IsValid(self) then self:SetGlowStrength(1) end
		end)

		-- Soft cooldown sparkle burst for others to see
		local ed = EffectData()
		ed:SetOrigin(self:WorldSpaceCenter())
		util.Effect("cball_bounce", ed, true, true)

		SafeRemoveEntity(self)
	end
end

if CLIENT then
	local CLIENT_MUSHROOM_MODEL = "models/props_swamp/shroom_ref_01.mdl"

	function ENT:Initialize()
		self._emitter = ParticleEmitter(self:GetPos(), false)
		self._nextSpores = 0
		self._sfxLoop = nil

		-- Client-only mushroom visual model
		self._mdl = ClientsideModel(CLIENT_MUSHROOM_MODEL, RENDERGROUP_BOTH)
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

	function ENT:_SpawnSpores()
		if not self._emitter then return end
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

	function ENT:DrawTranslucent()
		local s = math.max(1, self:GetMushroomScale() or 4)
		local pos = self:GetPos() + (OFFSET_MUSHROOM_M * (s / 2.2)) + (OFFSET_MUSHROOM_S * (s / 2.2))
		local dl = DynamicLight(self:EntIndex())
		if dl then
			dl.pos = pos
			dl.r = 120
			dl.g = 255
			dl.b = 140
			dl.brightness = self.IdleLightBrightness or 2
			dl.Decay = 600
			dl.Size = 200
			dl.DieTime = CurTime() + 0.1
		end
	end

	-- LSD-like trip client effects
	local TRIP = {}

	net.Receive("Arcana_Mushroom_TripStart", function()
		local dur = net.ReadFloat() or 12
		TRIP.endTime = CurTime() + dur
		TRIP.active = true
		TRIP.start = CurTime()

		-- Subtle ambient tone & DSP
		local lp = LocalPlayer()
		if IsValid(lp) then
			lp:EmitSound("ambient/levels/citadel/weapon_disintegrate3.wav", 70, 160, 0.6)
			lp:SetDSP(33, true) -- stronger hall reverb
		end
	end)

	local function tripFrac()
		if not TRIP.active then return 0 end
		local now = CurTime()
		local ttotal = math.max(0.001, (TRIP.endTime or 0) - (TRIP.start or 0))
		local tcur = math.Clamp(now - (TRIP.start or 0), 0, ttotal)
		local rise = math.Clamp(tcur / math.min(4, ttotal * 0.25), 0, 1)
		local fall = math.Clamp((TRIP.endTime - now) / math.min(4, ttotal * 0.25), 0, 1)
		return math.min(rise, fall)
	end

	-- Screen-space color shift & wobble (intensified)
	hook.Add("RenderScreenspaceEffects", "Arcana_MushroomTrip", function()
		if not TRIP.active then return end
		local f = tripFrac()
		if f <= 0 then return end

		local ct = CurTime()
		local sinA = math.sin(ct * 1.2)
		local sinB = math.sin(ct * 2.4)
		local sinC = math.sin(ct * 4.8)
		local mult = f * 1.0

		DrawColorModify({
			["$pp_colour_addr"] = 0.08 * mult + 0.04 * sinA * mult,
			["$pp_colour_addg"] = 0.06 * mult + 0.04 * sinB * mult,
			["$pp_colour_addb"] = 0.14 * mult + 0.06 * sinC * mult,
			["$pp_colour_brightness"] = 0.06 * mult,
			["$pp_colour_contrast"] = 1.1 + 0.6 * mult,
			["$pp_colour_colour"] = 1.8 + 1.6 * mult,
			["$pp_colour_mulr"] = 0.3 * mult,
			["$pp_colour_mulg"] = 0.2 * mult,
			["$pp_colour_mulb"] = 0.4 * mult
		})

		-- vision wobble via sharpen, bloom, edge high-pass and motion blur
		DrawSharpen(1.2 + 2.0 * mult, 1.2 + 1.0 * mult)
		DrawBloom(0.35, 2.5 + 3.5 * mult, 8 + 8 * math.abs(sinA) * mult, 8 + 8 * math.abs(sinB) * mult, 2.0 + 2.0 * mult, 1, 0.9, 0.9, 1)
		DrawSobel(0.2 + 1.6 * mult)
		DrawMotionBlur(0.15 + 0.25 * mult, 0.9, 0.08 + 0.10 * mult)
		DrawToyTown(6 + math.floor(10 * mult), ScrH() * 0.5)
	end)

	-- View sway (intensified)
	hook.Add("CalcView", "Arcana_MushroomTripView", function(ply, origin, angles, fov)
		if not TRIP.active then return end
		local f = tripFrac()
		if f <= 0 then return end
		local t = CurTime()
		local ang = Angle(angles)
		ang:RotateAroundAxis(ang:Forward(), math.sin(t * 0.9) * 4.0 * f)
		ang:RotateAroundAxis(ang:Right(), math.sin(t * 1.8) * 3.0 * f)
		ang:RotateAroundAxis(ang:Up(), math.sin(t * 0.6) * 2.0 * f)
		local off = angles:Forward() * math.sin(t * 1.3) * 3.0 * f
		off = off + angles:Right() * math.sin(t * 0.7) * 2.0 * f
		off = off + angles:Up() * math.sin(t * 1.9) * 2.0 * f
		local newFov = fov + math.sin(t * 0.9) * 10.0 * f
		return {origin = origin + off, angles = ang, fov = newFov}
	end)

	-- End condition
	hook.Add("Think", "Arcana_MushroomTripTimer", function()
		if TRIP.active and CurTime() >= (TRIP.endTime or 0) then
			TRIP.active = false
			local lp = LocalPlayer()
			if IsValid(lp) then
				lp:SetDSP(0, false)
			end
		end
	end)
end