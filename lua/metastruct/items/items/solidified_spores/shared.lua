msitems.StartItem("solidified_spores")

local COLOR = Color(120, 200, 120)

ITEM.State = "entity"
ITEM.WorldModel = "models/props_hive/larval_essence.mdl"
ITEM.EquipSound = "ui/item_helmet_pickup.wav"
ITEM.DontReturnToInventory = true

ITEM.Inventory = {
	name = "Solidified Spores",
	info = "A softly glowing cluster of condensed mushroom spores."
}

if SERVER then
	function ITEM:Initialize()
		self:AllowOption("Eat", "Eat")
		self:SetModel("models/Gibs/HGIBS.mdl")
		self:SetColor(COLOR)
		self:PhysicsInit(SOLID_VPHYSICS)
		self:SetMoveType(MOVETYPE_VPHYSICS)
		self:SetSolid(SOLID_VPHYSICS)
		self:PhysWake()
	end

	function ITEM:PlayEatSound(ply)
		timer.Create("msitems.Eat_"..ply:EntIndex(), 0.5, 3, function()
			if ply:IsValid() then
				ply:EmitSound("physics/flesh/flesh_squishy_impact_hard" .. math.random(1,2) .. ".wav", 72, math.random(75,85), 0.8)
			end
		end)
		timer.Simple(2.1, function()
			if ply:IsValid() then
				ply:EmitSound("npc/barnacle/barnacle_gulp" .. math.random(1,2) .. ".wav", 72, math.random(80,90), 0.8)
			end
		end)
	end

	-- Consume from inventory to get high
	function ITEM:Eat(ply)
		if not IsValid(ply) or not ply:IsPlayer() then return end

		-- Apply SporeHigh status for 45s
		if Arcane and Arcane.Status and Arcane.Status.SporeHigh and Arcane.Status.SporeHigh.Apply then
			Arcane.Status.SporeHigh.Apply(ply, { duration = 45, intensity = 0.25 })
		end

		self:PlayEatSound(ply)
		self:Remove()
	end
end

if CLIENT then
	local MAX_RENDER_DIST = 1500 * 1500
	local function drawOverride(ent)
		if EyePos():DistToSqr(ent:GetPos()) <= MAX_RENDER_DIST then
			local now = CurTime()
			ent._fxEmitter = ent._fxEmitter or ParticleEmitter(ent:GetPos(), false)
			if now >= (ent._fxNext or 0) and ent._fxEmitter then
				ent._fxNext = now + 0.12
				local origin = ent:WorldSpaceCenter()
				local p = ent._fxEmitter:Add("sprites/light_glow02_add", origin + VectorRand() * math.Rand(1, 6))
				if p then
					p:SetStartAlpha(150)
					p:SetEndAlpha(0)
					p:SetStartSize(math.Rand(2, 4))
					p:SetEndSize(0)
					p:SetDieTime(math.Rand(0.5, 0.8))
					p:SetVelocity(Vector(0, 0, math.Rand(8, 16)))
					p:SetAirResistance(40)
					p:SetGravity(Vector(0, 0, 0))
					p:SetRoll(math.Rand(-180, 180))
					p:SetRollDelta(math.Rand(-1, 1))
					p:SetColor(COLOR.r, COLOR.g, COLOR.b)
				end
			end
		end

        if not IsValid(ent._mdl) then
            ent._mdl = ClientsideModel("models/props_hive/larval_essence.mdl", RENDERGROUP_BOTH)
            ent._mdl:SetColor(COLOR)
            ent._mdl:SetModelScale(1, 0)
            ent._mdl:SetPos(ent:GetPos())
            ent._mdl:SetAngles(ent:GetAngles())
            ent._mdl:SetParent(ent)
        end

		ent._mdl:DrawModel()
	end

	function ITEM:Initialize()
		self:SetModel(self.WorldModel)
		self:SetColor(COLOR)
		self:AddBackpackOption()
		self:AddSimpleOption("Eat", "Eat", LocalPlayer())

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

		SafeRemoveEntity(self._mdl)
		self._mdl = nil
	end

	function ITEM:DrawInInventory(panel, ent)
		drawOverride(ent)
	end

	function ITEM:DrawInInventoryIcon(image, ent)
		drawOverride(ent)
	end
end

msitems.EndItem()