ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "Arcane Missile"
ENT.Author = "Earu"
ENT.Spawnable = false
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
				local tr = util.TraceLine({
					start = self:GetPos(),
					endpos = self:GetPos() + self:GetForward() * 100,
					filter = self,
					mask = MASK_SHOT,
				})

				if tr.Hit then
					local ed = EffectData()
					ed:SetOrigin(self:GetPos())
					util.Effect("cball_explode", ed, true, true)

					self:Remove()
				end
			end
		end

		self:NextThink(CurTime())
		return true
	end

	function ENT:StartTouch(ent)
		if not IsValid(ent) then return end

		local owner = self:GetSpellOwner()
		if ent == owner then return end
		if not ent:IsPlayer() or ent:IsNPC() then return end

		local dmg = DamageInfo()
		dmg:SetDamage(self.MissileDamage or 45)
		dmg:SetDamageType(bit.bor(DMG_ENERGYBEAM, DMG_DISSOLVE))
		dmg:SetAttacker(IsValid(owner) and owner or game.GetWorld())
		dmg:SetInflictor(self)
		ent:TakeDamageInfo(dmg)

		local ed = EffectData()
		ed:SetOrigin(self:GetPos())
		util.Effect("cball_explode", ed, true, true)

		self:Remove()
	end
end

if CLIENT then
	function ENT:Initialize()
	end

	function ENT:OnRemove()
	end

	function ENT:Think()
	end

	function ENT:Draw()
		render.SetLightingMode(2)
		render.SetColorModulation(ARCANE_COLOR.r / 255, ARCANE_COLOR.g / 255, ARCANE_COLOR.b / 255)
		self:DrawModel()
		render.SetColorModulation(1, 1, 1)
		render.SetLightingMode(0)

		local dlight = DynamicLight(self:EntIndex())
		if dlight then
			dlight.pos = self:GetPos()
			dlight.r = ARCANE_COLOR.r
			dlight.g = ARCANE_COLOR.g
			dlight.b = ARCANE_COLOR.b
			dlight.brightness = 1.8
			dlight.Decay = 800
			dlight.Size = 120
			dlight.DieTime = CurTime() + 0.1
		end
	end
end