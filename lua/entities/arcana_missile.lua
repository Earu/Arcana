ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "Arcane Missile"
ENT.Author = "Earu"
ENT.Spawnable = false
ENT.RenderGroup = RENDERGROUP_BOTH
ENT.AdminSpawnable = false

-- Tunables
ENT.MissileSpeed = 600
ENT.MissileDamage = 45
ENT.MaxLifetime = 5
ENT.ProximityRadius = 28

function ENT:SetupDataTables()
	self:NetworkVar("Entity", 0, "SpellOwner")
	self:NetworkVar("Entity", 1, "HomingTarget")
end

local ARCANE_COLOR = Color(142, 120, 225)

if SERVER then
	AddCSLuaFile()

	function ENT:Initialize()
		self:SetModel("models/hunter/misc/sphere025x025.mdl")
		self:SetMaterial("models/shiny")
		self:SetColor(ARCANE_COLOR)
		self:SetMoveType(MOVETYPE_FLY)
		self:SetSolid(SOLID_BBOX)
		self:SetCollisionGroup(COLLISION_GROUP_PROJECTILE)
		self:PhysicsInitSphere(10)
		self.Created = CurTime()
		self:SetTrigger(true)
		self:EmitSound("weapons/physcannon/energy_sing_flyby1.wav", 65, 180)

		local phys = self:GetPhysicsObject()
		if IsValid(phys) then
			phys:SetMass(1)
			phys:Wake()
			phys:EnableGravity(false)
		end

		Arcane:SendAttachBandVFX(self, ARCANE_COLOR, 14, self.MaxLifetime, {
			{
				radius = 10,
				height = 3,
				spin = {
					p = 0,
					y = 80 * 3,
					r = 60 * 3
				},
				lineWidth = 2
			},
			{
				radius = 10,
				height = 3,
				spin = {
					p = 60 * 3,
					y = -45 * 3,
					r = 0
				},
				lineWidth = 2
			},
		})
	end

	function ENT:Think()
		if (CurTime() - (self.Created or 0)) > (self.MaxLifetime or 5) then
			self:Remove()
			return
		end

		local phys = self:GetPhysicsObject()
		if IsValid(phys) then
			local target = self:GetHomingTarget()
			if IsValid(target) then
				local desiredDir = (target:WorldSpaceCenter() - self:GetPos()):GetNormalized()
				local curDir = phys:GetVelocity():GetNormalized()
				local steer = (desiredDir - curDir):GetNormalized()
				local newVel = (curDir + steer * 0.25):GetNormalized() * (self.MissileSpeed or 1100)
				phys:SetVelocity(newVel)
			else
				phys:SetVelocity(self:GetForward() * (self.MissileSpeed or 1100))
			end
		end

		self:NextThink(CurTime())
		return true
	end

	function ENT:PhysicsCollide(data, phys)
		-- Impact effects
		local pos = self:GetPos()
		local ed = EffectData()
		ed:SetOrigin(pos)
		util.Effect("cball_explode", ed, true, true)

		sound.Play("weapons/physcannon/energy_disintegrate4.wav", pos, 75, 140)

		self:Remove()
	end

	function ENT:StartTouch(ent)
		if not IsValid(ent) then return end

		local owner = self:GetSpellOwner()
		if ent == owner then return end

		-- Only damage players, NPCs, or NextBots
		if not (ent:IsPlayer() or ent:IsNPC() or ent:IsNextBot()) then return end

		local dmg = DamageInfo()
		dmg:SetDamage(self.MissileDamage or 45)
		dmg:SetDamageType(bit.bor(DMG_ENERGYBEAM, DMG_DISSOLVE))
		dmg:SetAttacker(IsValid(owner) and owner or game.GetWorld())
		dmg:SetInflictor(self)
		ent:TakeDamageInfo(dmg)

		-- Enhanced impact effects
		local pos = self:GetPos()
		local ed = EffectData()
		ed:SetOrigin(pos)
		util.Effect("cball_explode", ed, true, true)

		-- Additional impact sound
		sound.Play("weapons/physcannon/energy_disintegrate4.wav", pos, 75, 140)

		self:Remove()
	end
end

if CLIENT then
	local matGlow = Material("sprites/light_glow02_add")
	local matFlare = Material("effects/blueflare1")
	local matBeam = Material("effects/laser1")

	function ENT:Initialize()
		self.TrailPositions = {}
		self.LastParticleTime = 0
	end

	function ENT:OnRemove()
		-- Explosion effect on removal
		local pos = self:GetPos()
		local emitter = ParticleEmitter(pos)
		if emitter then
			-- Explosion burst
			for i = 1, 25 do
				local p = emitter:Add("effects/blueflare1", pos)
				if p then
					p:SetDieTime(math.Rand(0.4, 0.8))
					p:SetStartAlpha(255)
					p:SetEndAlpha(0)
					p:SetStartSize(math.Rand(12, 24))
					p:SetEndSize(0)
					p:SetColor(ARCANE_COLOR.r, ARCANE_COLOR.g, ARCANE_COLOR.b)
					p:SetVelocity(VectorRand() * 220)
					p:SetAirResistance(80)
					p:SetGravity(Vector(0, 0, -50))
				end
			end
			emitter:Finish()
		end
	end

	function ENT:Think()
		-- Trail particles
		if CurTime() - self.LastParticleTime > 0.03 then
			self.LastParticleTime = CurTime()

			local pos = self:GetPos()
			local emitter = ParticleEmitter(pos)
			if emitter then
				-- Energy trail
				for i = 1, 2 do
					local p = emitter:Add("effects/blueflare1", pos + VectorRand() * 5)
					if p then
						p:SetDieTime(math.Rand(0.3, 0.5))
						p:SetStartAlpha(200)
						p:SetEndAlpha(0)
						p:SetStartSize(math.Rand(8, 14))
						p:SetEndSize(0)
						p:SetColor(ARCANE_COLOR.r, ARCANE_COLOR.g, ARCANE_COLOR.b)
						p:SetVelocity(VectorRand() * 20)
						p:SetAirResistance(150)
					end
				end
				emitter:Finish()
			end
		end

		-- Store trail positions for rendering
		table.insert(self.TrailPositions, 1, {pos = self:GetPos(), time = CurTime()})
		while #self.TrailPositions > 8 do
			table.remove(self.TrailPositions)
		end
	end

	function ENT:Draw()
		local pos = self:GetPos()

		-- Draw core sphere with enhanced brightness
		render.SetLightingMode(2)
		render.SetColorModulation(1, 1, 1)
		self:DrawModel()
		render.SetColorModulation(1, 1, 1)
		render.SetLightingMode(0)

		-- Draw energy trail
		if #self.TrailPositions > 1 then
			local curTime = CurTime()
			render.SetMaterial(matBeam)
			render.StartBeam(#self.TrailPositions)

			for i, data in ipairs(self.TrailPositions) do
				local age = curTime - data.time
				local frac = 1 - math.Clamp(age / 0.5, 0, 1)
				local width = 8 * frac
				render.AddBeam(data.pos, width, i / #self.TrailPositions, Color(ARCANE_COLOR.r, ARCANE_COLOR.g, ARCANE_COLOR.b, 200 * frac))
			end

			render.EndBeam()
		end

		-- Multiple glow sprites for impressive look
		render.SetMaterial(matFlare)
		render.DrawSprite(pos, 28, 28, Color(255, 255, 255, 255))
		render.DrawSprite(pos, 20, 20, Color(ARCANE_COLOR.r, ARCANE_COLOR.g, ARCANE_COLOR.b, 255))

		render.SetMaterial(matGlow)
		render.DrawSprite(pos, 40, 40, Color(ARCANE_COLOR.r, ARCANE_COLOR.g, ARCANE_COLOR.b, 180))
		render.DrawSprite(pos, 60, 60, Color(ARCANE_COLOR.r - 40, ARCANE_COLOR.g - 40, ARCANE_COLOR.b, 100))

		-- Enhanced dynamic light
		local dlight = DynamicLight(self:EntIndex())
		if dlight then
			dlight.pos = pos
			dlight.r = ARCANE_COLOR.r
			dlight.g = ARCANE_COLOR.g
			dlight.b = ARCANE_COLOR.b
			dlight.brightness = 2.5
			dlight.Decay = 1200
			dlight.Size = 180
			dlight.DieTime = CurTime() + 0.1
		end
	end
end