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
require("shader_to_gma")

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
		self:SetModelScale(1 + self._amount * 0.05)
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

	local MAX_RENDER_DIST = 700 * 700
	local function core(self)
		return self:WorldSpaceCenter()
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
			local origin = core(self)
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

		local dl = DynamicLight(self:EntIndex())
		if dl then
			local c = self:GetColor()
			dl.pos = self:WorldSpaceCenter()
			dl.r = c.r
			dl.g = c.g
			dl.b = c.b
			dl.brightness = 2
			dl.Decay = 200
			dl.Size = 60
			dl.DieTime = CurTime() + 0.1
		end
	end
end