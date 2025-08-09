ENT.Type = "anim"
ENT.Base = "base_anim"

ENT.PrintName = "Arcana Fireball"
ENT.Author = "Earu"
ENT.Spawnable = false
ENT.AdminSpawnable = false

-- Tunables
ENT.FireballSpeed = 900
ENT.FireballRadius = 300
ENT.FireballDamage = 120
ENT.FireballIgniteTime = 5
ENT.MaxLifetime = 6

function ENT:SetupDataTables()
	self:NetworkVar("Entity", 0, "SpellOwner")
end