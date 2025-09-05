msitems.StartItem("mana_crystal_shard")

local SHINY_MAT = Material("models/shiny")
local COLOR = Color(255, 0, 123)

ITEM.State = "entity"
ITEM.WorldModel = "models/props_debris/concrete_chunk05g.mdl"
ITEM.EquipSound = "ui/item_helmet_pickup.wav"
ITEM.DontReturnToInventory = true

ITEM.Inventory = {
	name = "Crystal Shard",
	info = "A crystal shard embued with mana."
}

if SERVER then
	function ITEM:Initialize()
		self:SetModel(self.WorldModel)
		self:SetMaterial("models/shiny")
		self:SetColor(COLOR)
		self:PhysicsInit(SOLID_VPHYSICS)
		self:SetMoveType(MOVETYPE_VPHYSICS)
		self:SetSolid(SOLID_VPHYSICS)
		self:PhysWake()
	end
end

if CLIENT then
	local MAX_RENDER_DIST = 700 * 700
	local function drawOverride(ent)
		if EyePos():DistToSqr(ent:GetPos()) <= MAX_RENDER_DIST then
			local now = CurTime()
			if now >= (ent._fxNext or 0) and ent._fxEmitter then
				ent._fxNext = now + 0.12
				local c = ent:GetColor()
				local origin = ent:WorldSpaceCenter()
				for i = 1, 1 do
					local offset = VectorRand() * math.Rand(1, 6)
					offset.z = math.abs(offset.z) * 0.5
					local p = ent._fxEmitter:Add("sprites/light_glow02_add", origin + offset)
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
		end

		render.SetLightingMode(2)
		render.MaterialOverride(SHINY_MAT)
		render.SetColorModulation(COLOR.r / 255, COLOR.g / 255, COLOR.b / 255)

		ent:DrawModel()

		render.SetColorModulation(1, 1, 1)
		render.MaterialOverride()
		render.SetLightingMode(0)

		local dl = DynamicLight(ent:EntIndex())
		if dl then
			local c = ent:GetColor()
			dl.pos = ent:WorldSpaceCenter()
			dl.r = c.r
			dl.g = c.g
			dl.b = c.b
			dl.brightness = 2
			dl.Decay = 200
			dl.Size = 60
			dl.DieTime = CurTime() + 0.1
		end
	end

	function ITEM:Initialize()
		self:SetModel(self.WorldModel)
		self:SetMaterial("models/shiny")
		self:SetColor(COLOR)
		self:AddBackpackOption()

		self._fxEmitter = ParticleEmitter(self:GetPos(), false)
		self._fxNext = 0

		function self:RenderOverride()
			drawOverride(self)
		end
	end

	function ITEM:OnRemove()
		if self._fxEmitter then
			self._fxEmitter:Finish()
			self._fxEmitter = nil
		end
	end

	-- This function is called when drawing the main model in the inventory panel (DModelPanel)
	function ITEM:DrawInInventory(panel, ent)
		drawOverride(ent)
	end

	-- This function is called when drawing the small icon in inventory lists (ModelImage)
	function ITEM:DrawInInventoryIcon(image, ent)
		drawOverride(ent)
	end
end

msitems.EndItem()