msitems.StartItem("mana_crystal_shard")

ITEM.State = "entity"
ITEM.WorldModel = "models/props_debris/concrete_chunk05g.mdl"
ITEM.EquipSound = "ui/item_helmet_pickup.wav"

ITEM.Inventory = {
	name = "Crystal Shard",
	info = "A crystal shard embued with mana."
}

if SERVER then
	function ITEM:Initialize()
		self:SetModel(self.WorldModel)
		self:PhysicsInit(SOLID_VPHYSICS)
		self:SetMoveType(MOVETYPE_VPHYSICS)
		self:SetSolid(SOLID_VPHYSICS)
		self:PhysWake()
	end

	function ITEM:PreDrop()
		self:Remove()
		return false
	end
end

msitems.EndItem()