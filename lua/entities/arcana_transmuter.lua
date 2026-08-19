-- The Transmuter: matter laid out on one side comes back as something else on
-- the other.  Crystal dust and a reagent become elemental dust; dust on its own
-- comes back as coin.  Nothing is sold here and nothing is free.

AddCSLuaFile()

ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "Transmuter"
ENT.Author = "Earu"
ENT.Category = "Arcana"
ENT.Spawnable = true
ENT.AdminOnly = true
ENT.RenderGroup = RENDERGROUP_BOTH
ENT.UseCooldown = 0.75

local TABLE_MODEL = "models/props/cs_italy/it_mkt_table3.mdl"
local JAR_MODEL = "models/props_lab/jar01a.mdl"

if SERVER then
	util.AddNetworkString("Arcana_Transmuter_Open")
	util.AddNetworkString("Arcana_Transmuter_Exchange")

	resource.AddFile("materials/entities/arcana_transmuter.png")

	function ENT:Initialize()
		self:SetModel(TABLE_MODEL)
		self:PhysicsInit(SOLID_VPHYSICS)
		self:SetMoveType(MOVETYPE_VPHYSICS)
		self:SetSolid(SOLID_VPHYSICS)
		self:SetUseType(SIMPLE_USE)

		local phys = self:GetPhysicsObject()

		if IsValid(phys) then
			phys:Wake()
			phys:EnableMotion(false)
		end

		self._nextUse = 0
	end

	function ENT:SpawnFunction(ply, tr, classname)
		if not tr or not tr.Hit then return end

		local ent = ents.Create(classname or "arcana_transmuter")
		if not IsValid(ent) then return end

		ent:SetPos(tr.HitPos + tr.HitNormal * 4)
		ent:SetAngles(Angle(0, ply:EyeAngles().y + 90, 0))
		ent:Spawn()
		ent:Activate()

		return ent
	end

	function ENT:Use(ply)
		if not IsValid(ply) or not ply:IsPlayer() then return end

		local now = CurTime()
		if now < (self._nextUse or 0) then return end
		self._nextUse = now + self.UseCooldown

		net.Start("Arcana_Transmuter_Open")
		net.WriteEntity(self)
		net.Send(ply)

		self:EmitSound("buttons/button9.wav", 60, 100)
	end

	----------------------------------------------------------------------
	-- Request handling
	----------------------------------------------------------------------
	local lastAction = {}
	local ACTION_COOLDOWN = 0.4

	local function rateOk(ply)
		local sid = ply:SteamID64()
		local now = CurTime()
		if (lastAction[sid] or 0) + ACTION_COOLDOWN > now then return false end
		lastAction[sid] = now

		return true
	end

	hook.Add("PlayerDisconnected", "Arcana_Transmuter_RateClear", function(ply)
		lastAction[ply:SteamID64()] = nil
	end)

	local function readStation(ply)
		if not IsValid(ply) or not rateOk(ply) then return end

		local ent = net.ReadEntity()
		if not IsValid(ent) or ent:GetClass() ~= "arcana_transmuter" then return end
		if ply:GetPos():DistToSqr(ent:GetPos()) > Arcana.Gardening.USE_RANGE ^ 2 then return end

		return ent
	end

	-- The client sends only what was laid out and how many times to repeat it.
	-- What that is worth is worked out here from the same shared resolver the
	-- menu draws from, so a forged payload buys nothing it should not.
	net.Receive("Arcana_Transmuter_Exchange", function(_, ply)
		local G = Arcana.Gardening
		local ent = readStation(ply)
		local n = net.ReadUInt(4)
		local inputs = {}

		for i = 1, math.min(n, G.MAX_INPUTS) do
			inputs[i] = net.ReadString()
		end

		-- 0 asks for as many as the offering will bear
		local want = net.ReadUInt(8)
		if not ent then return end

		local result = G.ResolveExchange(inputs)

		if not result then
			Arcana.SendErrorNotification(ply, "Nothing comes of that")

			return
		end

		local function held(item)
			return Arcana.GetItemCount(ply, item)
		end

		local most = G.MaxRepeats(result.cost, held)
		local reps = want == 0 and most or math.min(want, most)

		if reps < 1 then
			Arcana.SendErrorNotification(ply, "Not enough to give")

			return
		end

		-- The whole cost is checked through MaxRepeats before a single item is
		-- taken, so a partial exchange cannot happen.
		for item, amount in pairs(result.cost) do
			Arcana.TakeItem(ply, item, amount * reps, "Transmutation")
		end

		if result.kind == "coins" then
			Arcana.GiveCoins(ply, result.coins * reps, "Transmutation")
			ent:EmitSound("ambient/levels/labs/coinslot1.wav", 60, 110, 0.6)
		else
			for item, amount in pairs(result.give) do
				Arcana.GiveItem(ply, item, amount * reps, "Transmutation")
			end

			ent:EmitSound("ambient/levels/labs/electric_explosion5.wav", 60, 140, 0.5)
		end
	end)
end

if CLIENT then
	local JAR_SLOTS = 5
	local MOTE_MATERIAL = Material("sprites/light_glow02_add")
	local MAX_FX_DIST = 900 * 900

	-- The work surface, read off the model's own upward-facing quad.  The OBB
	-- top (34) is the raised rim posts, not the counter, so jars placed there
	-- float above it.
	local TABLE_TOP_Z = 28
	local JAR_SCALE = 0.85
	local JAR_ROW_X = -7
	local JAR_ROW_HALF_Y = 26

	function ENT:Initialize()
		self._jars = {}

		local probe = ClientsideModel(JAR_MODEL)
		-- Jar origins sit at their centre, so the model's own base offset is
		-- what puts the glass on the counter instead of halfway through it.
		local baseOffset = 8

		if IsValid(probe) then
			local jmins = probe:GetModelBounds()
			baseOffset = -jmins.z * JAR_SCALE
			probe:Remove()
		end

		for i = 1, JAR_SLOTS do
			local recipe = Arcana.Gardening.Recipes[i]
			if not recipe then break end

			local jar = ClientsideModel(JAR_MODEL, RENDERGROUP_OPAQUE)

			if IsValid(jar) then
				jar:SetNoDraw(true)
				jar:SetModelScale(JAR_SCALE)

				local fy = -1 + 2 * ((i - 1) / (JAR_SLOTS - 1))
				self._jars[i] = {
					ent = jar,
					pos = Vector(JAR_ROW_X, fy * JAR_ROW_HALF_Y, TABLE_TOP_Z + baseOffset),
					color = recipe.color,
					top = TABLE_TOP_Z + baseOffset * 2,
				}
			end
		end

		self._motePhase = math.Rand(0, 10)
	end

	function ENT:OnRemove()
		for _, jar in pairs(self._jars or {}) do
			if IsValid(jar.ent) then jar.ent:Remove() end
		end

		self._jars = nil
	end

	function ENT:Draw()
		self:DrawModel()

		for _, jar in pairs(self._jars or {}) do
			if IsValid(jar.ent) then
				jar.ent:SetPos(self:LocalToWorld(jar.pos))
				jar.ent:SetAngles(self:GetAngles())

				render.SetColorModulation(jar.color.r / 255, jar.color.g / 255, jar.color.b / 255)
				jar.ent:DrawModel()
				render.SetColorModulation(1, 1, 1)
			end
		end
	end

	-- Faint motes rising off the jars, 1 to 2 pixels so they read as vapour
	-- rather than sprites.
	function ENT:DrawTranslucent()
		if EyePos():DistToSqr(self:GetPos()) > MAX_FX_DIST then return end

		local now = CurTime()

		render.SetMaterial(MOTE_MATERIAL)

		for i, jar in pairs(self._jars or {}) do
			local base = self:LocalToWorld(Vector(jar.pos.x, jar.pos.y, jar.top))

			for k = 1, 3 do
				local t = (now * 0.22 + i * 0.31 + k * 0.37 + self._motePhase) % 1
				local rise = t * 14
				local sway = math.sin((now + i * 2 + k) * 1.4) * 1.6
				local alpha = math.sin(t * math.pi) * 90

				render.DrawSprite(base + Vector(sway, sway * 0.5, rise), 2, 2, Color(jar.color.r, jar.color.g, jar.color.b, alpha))
			end
		end
	end
end

hook.Add("Initialize", "arcana_transmuter_items", function()
	local variants = {
		{id = "fire_dust", name = "Ember Dust", desc = "Crystal dust fused with radioactive matter. Warm to the touch.", color = Color(255, 120, 40)},
		{id = "frost_dust", name = "Rime Dust", desc = "Crystal dust bound to still water. It never quite melts.", color = Color(170, 220, 255)},
		{id = "lightning_dust", name = "Storm Dust", desc = "Crystal dust holding a charge. It clings to the jar.", color = Color(150, 200, 255)},
		{id = "poison_dust", name = "Blight Dust", desc = "Crystal dust cut with spores. Best handled with gloves.", color = Color(120, 210, 70)},
		{id = "arcane_dust", name = "Arcane Dust", desc = "Crystal dust refined with a shard. The finest grade there is.", color = Color(180, 120, 255)},
	}

	for _, v in ipairs(variants) do
		Arcana.RegisterItem(v.id, {
			name = v.name,
			description = v.desc,
			model = JAR_MODEL,
			color = v.color,
		})
	end
end)
