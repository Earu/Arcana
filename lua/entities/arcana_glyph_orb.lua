AddCSLuaFile()
ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "Glyph Orb"
ENT.Author = "Arcana"
ENT.Spawnable = false
ENT.AdminSpawnable = false

-- Tunables
ENT.OrbSpeed = 520
ENT.ExplodeRadius = 320
ENT.ExplodeDamage = 500
ENT.MaxLifetime = 6

function ENT:SetupDataTables()
	self:NetworkVar("Entity", 0, "SpellOwner")
end

if SERVER then
	function ENT:Initialize()
		self:SetModel("models/hunter/misc/sphere025x025.mdl")
		self:SetMoveType(MOVETYPE_VPHYSICS)
		self:SetSolid(SOLID_VPHYSICS)
		self:PhysicsInit(SOLID_VPHYSICS)
		self:SetCollisionGroup(COLLISION_GROUP_PROJECTILE)
		self:DrawShadow(false)
		self:SetTrigger(true)

		local phys = self:GetPhysicsObject()
		if IsValid(phys) then
			phys:EnableGravity(false)
			phys:Wake()
		end

		self:SetColor(Color(210, 210, 210, 255))
		self:SetMaterial("models/debug/debugwhite")
		util.SpriteTrail(self, 0, Color(200, 200, 200, 180), true, 22, 6, 0.6, 1 / 64, "trails/smoke.vmt")
		self.Created = CurTime()

		timer.Simple(self.MaxLifetime or 6, function()
			if IsValid(self) and not self._detonated then
				self:Detonate()
			end
		end)
	end

	function ENT:LaunchTowards(dir)
		local phys = self:GetPhysicsObject()
		if IsValid(phys) then
			phys:SetVelocity(dir:GetNormalized() * (self.OrbSpeed or 520))
		end
	end

	local function isSolidNonTrigger(ent)
		if not IsValid(ent) then return false end
		if ent:IsWorld() then return true end

		local solid = ent.GetSolid and ent:GetSolid() or SOLID_NONE
		if solid == SOLID_NONE then return false end

		local flags = ent.GetSolidFlags and ent:GetSolidFlags() or 0
		return bit.band(flags, FSOLID_TRIGGER) == 0
	end

	function ENT:PhysicsCollide(data, phys)
		if self._detonated then return end
		if (CurTime() - (self.Created or 0)) < 0.03 then return end

		local hit = data.HitEntity
		if (IsValid(hit) and hit ~= self:GetSpellOwner() and isSolidNonTrigger(hit)) or hit:IsWorld() then
			self:Detonate()
		end
	end

	function ENT:Touch(ent)
		if self._detonated then return end
		if ent == self:GetSpellOwner() then return end
		if (CurTime() - (self.Created or 0)) < 0.03 then return end

		if isSolidNonTrigger(ent) then
			self:Detonate()
		end
	end

	function ENT:Detonate()
		if self._detonated then return end
		self._detonated = true
		local owner = self:GetSpellOwner() or self
		local pos = self:GetPos()
		if Arcane and Arcane.BlastDamage then
			Arcane:BlastDamage(IsValid(owner) and owner or self, self, pos, self.ExplodeRadius or 260, self.ExplodeDamage or 400, DMG_DISSOLVE, true)
		else
			util.BlastDamage(self, IsValid(owner) and owner or self, pos, self.ExplodeRadius or 260, self.ExplodeDamage or 400)
		end

		local ed = EffectData()
		ed:SetOrigin(pos)
		ed:SetScale(1)
		util.Effect("arcana_glyph_burst", ed, true, true)

		-- Additional explosion visuals (grayscale-friendly)
		local ed2 = EffectData()
		ed2:SetOrigin(pos)
		ed2:SetScale(1.2)
		util.Effect("HelicopterMegaBomb", ed2, true, true)

		local ed3 = EffectData()
		ed3:SetOrigin(pos)
		ed3:SetScale(1)
		util.Effect("ThumperDust", ed3, true, true)

		local ed4 = EffectData()
		ed4:SetOrigin(pos)
		util.Effect("Explosion", ed4, true, true)
		util.ScreenShake(pos, 8, 150, 0.4, 700)

		self:Remove()
	end
end

if CLIENT then
	local SPRITE = Material("sprites/light_glow02_add")
	local GLYPHS = {"Γ", "Δ", "Θ", "Λ", "Ξ", "Π", "Σ", "Φ", "Ψ", "Ω", "α", "β", "γ", "δ", "ε", "ζ", "η", "θ", "ι", "κ", "λ", "μ", "ξ", "π", "φ", "ψ", "ω"}

	surface.CreateFont("Arcana_GlyphOrb", {
		font = "Arial",
		size = 90,
		weight = 700,
		antialias = true
	})

	local function pickGlyph()
		return GLYPHS[math.random(1, #GLYPHS)] or "*"
	end

	function ENT:Initialize()
		-- Define multiple orbit rings on different planes (axes)
		self._rings = {
			{ axis = Vector(0, 0, 1), speed = 60, count = 18, rot = math.Rand(0, 360) },
			{ axis = Vector(1, 0, 0), speed = 48, count = 16, rot = math.Rand(0, 360) },
			{ axis = Vector(0, 1, 0), speed = 52, count = 16, rot = math.Rand(0, 360) },
			{ axis = Vector(1, 1, 0):GetNormalized(), speed = 40, count = 14, rot = math.Rand(0, 360) },
			{ axis = Vector(1, 0, 1):GetNormalized(), speed = 44, count = 14, rot = math.Rand(0, 360) }
		}
		for _, r in ipairs(self._rings) do
			r.glyphs = {}
			for i = 1, r.count do
				r.glyphs[i] = pickGlyph()
			end
		end
	end

	function ENT:Draw()
		local pos = self:GetPos()
		render.SetMaterial(SPRITE)
		render.DrawSprite(pos, 150, 150, Color(255, 255, 255, 255))

		-- Dynamic light (grayscale)
		local d = DynamicLight(self:EntIndex())
		if d then
			d.pos = pos
			d.r = 245
			d.g = 245
			d.b = 245
			d.brightness = 3.0
			d.Decay = 900
			d.Size = 260
			d.DieTime = CurTime() + 0.1
		end

		-- Orbiting glyphs on multiple planes around the sphere
		local t = CurTime()
		local pulse = 0.5 + 0.5 * math.sin(t * 7.0)
		local sMid = 150 + 16 * pulse
		local ringR = (sMid * 0.25)
		local ply = LocalPlayer()
		for _, r in ipairs(self._rings or {}) do
			r.rot = (r.rot or 0) + FrameTime() * (r.speed or 50)
			-- Build orthonormal basis for the ring plane from its axis
			local n = (r.axis or Vector(0, 0, 1)):GetNormalized()
			local a = (math.abs(n.z or 0) < 0.99) and Vector(0, 0, 1) or Vector(0, 1, 0)
			local right = n:Cross(a)
			right:Normalize()
			local up = n:Cross(right)
			up:Normalize()
			for i = 1, (r.count or 12) do
				local angDeg = (i / (r.count or 12)) * 360 + (r.rot or 0)
				local ca = math.cos(math.rad(angDeg))
				local sa = math.sin(math.rad(angDeg))
				local offset = right * (ca * ringR) + up * (sa * ringR)
				local gpos = pos + offset
				local gang = Angle(0, 0, 0)
				if IsValid(ply) then gang = (ply:GetPos() - gpos):Angle() end
				gang:RotateAroundAxis(gang:Right(), -90)
				gang:RotateAroundAxis(gang:Up(), 90)
				cam.Start3D2D(gpos, gang, 0.1)
					surface.SetFont("Arcana_GlyphOrb")
					local txt = (r.glyphs and r.glyphs[i]) or "*"
					local tw, th = surface.GetTextSize(txt)
					surface.SetTextColor(220, 220, 220, 230)
					surface.SetTextPos(-tw * 0.5, -th * 0.5)
					surface.DrawText(txt)
				cam.End3D2D()
			end
		end
	end

	-- Glyph burst effect (projected 3D2D glyphs that fade fast)
	local EFFECT = {}

	function EFFECT:Init(data)
		self.Pos = data:GetOrigin()
		self.Die = CurTime() + 0.4
		self.Glyphs = {}
		local count = 128
		for i = 1, count do
			self.Glyphs[i] = {
				pos = Vector(self.Pos),
				vel = VectorRand():GetNormalized() * math.Rand(1200, 2400),
				char = pickGlyph(),
				born = CurTime(),
				life = math.Rand(0.25, 0.4),
				scale = math.Rand(0.08, 0.12)
			}
		end
	end

	function EFFECT:Think()
		local now = CurTime()
		if now > (self.Die or 0) then return false end

		local dt = FrameTime()
		for _, g in ipairs(self.Glyphs or {}) do
			g.pos = g.pos + g.vel * dt
			g.vel = g.vel * 0.96
		end

		return true
	end

	function EFFECT:Render()
		local ply = LocalPlayer()
		for _, g in ipairs(self.Glyphs or {}) do
			local age = CurTime() - (g.born or 0)
			local fade = 1 - age / math.max(0.001, g.life or 0.3)
			if fade <= 0 then continue end
			local ang = Angle(0, 0, 0)
			if IsValid(ply) then ang = (ply:GetPos() - g.pos):Angle() end
			ang:RotateAroundAxis(ang:Right(), -90)
			ang:RotateAroundAxis(ang:Up(), 90)
			cam.Start3D2D(g.pos, ang, g.scale or 0.1)
				surface.SetFont("Arcana_GlyphOrb")
				local txt = g.char or "*"
				local tw, th = surface.GetTextSize(txt)
				surface.SetTextColor(220, 220, 220, math.floor(255 * fade))
				surface.SetTextPos(-tw * 0.5, -th * 0.5)
				surface.DrawText(txt)
			cam.End3D2D()
		end
	end

	effects.Register(EFFECT, "arcana_glyph_burst")
end