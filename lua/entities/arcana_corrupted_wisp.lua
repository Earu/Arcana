AddCSLuaFile()
ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "Corrupted Wisp"
ENT.Category = "Arcana"
ENT.Spawnable = false
ENT.AdminOnly = false
ENT.RenderGroup = RENDERGROUP_BOTH
ENT.PhysgunDisabled = true
ENT.ms_notouch = true

local GLYPHS = {"Γ", "Δ", "Θ", "Λ", "Ξ", "Π", "Σ", "Φ", "Ψ", "Ω", "α", "β", "γ", "δ", "ε", "ζ", "η", "θ", "ι", "κ", "λ", "μ", "ξ", "π", "φ", "ψ", "ω"}

function ENT:SetupDataTables()
	self:NetworkVar("Float", 0, "LaserTime")
	self:NetworkVar("Vector", 0, "LaserStart")
	self:NetworkVar("Vector", 1, "LaserEnd")
	self:NetworkVar("Float", 1, "Radius")
end

if SERVER then
	local CHASE_SPEED = 120
	local LASER_INTERVAL = 1.2
	local LASER_RANGE = 200
	local LASER_DAMAGE = 10
	local WISP_XP = 10

	function ENT:Initialize()
		self:SetModel("models/hunter/misc/sphere025x025.mdl")
		self:SetMaterial("models/shiny")
		self:SetColor(Color(150, 150, 150, 10))
		self:SetRenderMode(RENDERMODE_TRANSCOLOR)
		self:SetModelScale(1.1, 0)
		self:SetMoveType(MOVETYPE_FLY)
		-- Make it hittable but not obstructive
		self:SetSolid(SOLID_BBOX)
		self:PhysicsInit(SOLID_BBOX)
		self:SetCollisionBounds(Vector(-8, -8, -8), Vector(8, 8, 8))
		self:SetCollisionGroup(COLLISION_GROUP_DEBRIS)
		self:DrawShadow(false)
		self:SetRadius(200)
		-- Health
		self:SetMaxHealth(10)
		self:SetHealth(10)
		self._lastThink = CurTime()
		self._nextLaser = CurTime() + 1.0
		self._lastTargetCheck = 0
		-- ambient sound schedule
		self._nextAmbient = CurTime() + math.Rand(2.0, 6.0)
		-- area binding (center/radius) provided by spawner
		self._areaCenter = self._areaCenter or self:GetPos()
		self._areaRadius = self._areaRadius or 300

		local phys = self:GetPhysicsObject()
		if IsValid(phys) then
			phys:SetMass(0.1)
			phys:EnableGravity(false)
			phys:Wake()
		end
	end

	function ENT:OnTakeDamage(dmginfo)
		local cur = self:Health()
		local new = math.max(0, cur - (dmginfo:GetDamage() or 0))
		self:SetHealth(new)

		-- Track last player who hurt the wisp for XP attribution
		local atk = dmginfo:GetAttacker()
		if IsValid(atk) and atk:IsPlayer() then
			self._lastHurtBy = atk
		else
			local inf = dmginfo:GetInflictor()
			local owner = IsValid(inf) and inf.GetOwner and inf:GetOwner() or nil
			if IsValid(owner) and owner:IsPlayer() then
				self._lastHurtBy = owner
			end
		end

		-- brief hit feedback: small tesla burst
		local tes = ents.Create("point_tesla")
		if IsValid(tes) then
			tes:SetPos(self:GetPos())
			tes:SetKeyValue("m_SoundName", "DoSpark")
			tes:SetKeyValue("texture", "sprites/physbeam.vmt")
			tes:SetKeyValue("m_Color", "180 180 180")
			tes:SetKeyValue("m_flRadius", "80")
			tes:SetKeyValue("beamcount_min", "2")
			tes:SetKeyValue("beamcount_max", "4")
			tes:SetKeyValue("thick_min", "1")
			tes:SetKeyValue("thick_max", "3")
			tes:SetKeyValue("lifetime_min", "0.03")
			tes:SetKeyValue("lifetime_max", "0.07")
			tes:SetKeyValue("interval_min", "0.02")
			tes:SetKeyValue("interval_max", "0.04")
			tes:Spawn()
			tes:Activate()
			tes:Fire("DoSpark", "", 0)
			tes:Fire("Kill", "", 0.15)
		end

		if new <= 0 and not self._arcanaDead then
			self._arcanaDead = true

			-- death flash
			local ed = EffectData()
			ed:SetOrigin(self:GetPos())
			util.Effect("cball_explode", ed, true, true)

			-- Award XP to the killer (very small amount)
			local killer = atk
			if not (IsValid(killer) and killer:IsPlayer()) then
				killer = self._lastHurtBy
			end

			if IsValid(killer) and killer:IsPlayer() then
				Arcane:GiveXP(killer, WISP_XP, "Wisp destroyed")
			end

			self:Remove()
		end
	end

	local function isValidEnemy(ply)
		return IsValid(ply) and ply:IsPlayer() and ply:Alive()
	end

	function ENT:_PickTarget()
		local now = CurTime()
		if now < (self._lastTargetCheck or 0) then return end
		self._lastTargetCheck = now + 0.3
		local myPos = self:GetPos()
		local nearest, nd2 = nil, math.huge

		for _, ply in ipairs(player.GetAll()) do
			if isValidEnemy(ply) then
				local d2 = myPos:DistToSqr(ply:GetPos())

				if d2 < nd2 then
					nearest, nd2 = ply, d2
				end
			end
		end

		-- Only accept target inside area bounds
		if IsValid(nearest) then
			local center = self._areaCenter or self:GetPos()
			local r = self._areaRadius or 300

			if nearest:GetPos():DistToSqr(center) <= r * r then
				self._target = nearest
			else
				self._target = nil
			end
		else
			self._target = nil
		end
	end

	function ENT:_Chase(dt)
		local center = self._areaCenter or self:GetPos()
		local r = self._areaRadius or 300
		local myPos = self:GetPos()

		-- If outside bounds, steer back in
		if myPos:DistToSqr(center) > r * r then
			local dir = (center - myPos)
			local dist = dir:Length()

			if dist > 1 then
				dir:Mul(1 / dist)
			end

			self:SetPos(myPos + dir * (CHASE_SPEED * 1.2) * dt)
			self:SetAngles(dir:Angle())

			return
		end

		if not IsValid(self._target) then
			local tr = util.TraceLine({
				start = myPos,
				endpos = myPos + Vector(0, 0, -10000),
				filter = self,
			})

			local desired = tr.HitPos + Vector(0, 0, 50)
			local dir = (desired - self:GetPos())
			local dist = dir:Length()
			if dist > 1 then
				dir:Mul(1 / dist)
				self:SetPos(self:GetPos() + dir * CHASE_SPEED * dt)
				self:SetAngles(dir:Angle())
			end

			return
		end

		local targetPos = self._target:EyePos()
		local desired = targetPos + Vector(0, 0, 20 + math.sin(CurTime() * 100) * 20)
		local dir = (desired - self:GetPos())
		local dist = dir:Length()
		if dist < self:GetRadius() then
			local speed = CHASE_SPEED

			if dist > 100 then
				dir:Mul(1 / dist)
				self:SetPos(self:GetPos() + dir * speed * dt)
				self:SetAngles(dir:Angle())
			else
				local right = dir:Cross(Vector(0, 0, 1)):GetNormalized()
				self:SetPos(self:GetPos() + right * speed * dt)
				self:SetAngles((-right):Angle())
			end
		end
	end

	function ENT:_FireLaser()
		if not IsValid(self._target) then return end
		-- Do not fire if target is outside the area
		local center = self._areaCenter or self:GetPos()
		local r = self._areaRadius or 300
		if self._target:GetPos():DistToSqr(center) > r * r then return end
		local myPos = self:GetPos()
		local shootPos = myPos + self:GetForward() * 6
		local aimPos = self._target:EyePos()

		local tr = util.TraceLine({
			start = shootPos,
			endpos = aimPos,
			filter = {self},
			mask = MASK_SHOT
		})

		local hitPos = tr.HitPos or aimPos
		if shootPos:DistToSqr(hitPos) > LASER_RANGE * LASER_RANGE then return end
		self:SetLaserStart(shootPos)
		self:SetLaserEnd(hitPos)
		self:SetLaserTime(CurTime())

		if tr.Entity and tr.Entity:IsPlayer() then
			local dmg = DamageInfo()
			dmg:SetDamage(LASER_DAMAGE)
			dmg:SetDamageType(DMG_ENERGYBEAM)
			dmg:SetAttacker(self)
			dmg:SetInflictor(self)
			--dmg:SetDamagePosition(hitPos)
			local takeDamageInfo = tr.Entity.ForceTakeDamageInfo or tr.Entity.TakeDamageInfo
			takeDamageInfo(tr.Entity, dmg)
		end

		-- Tesla sparks along the path (short-lived)
		local function spawnTesla(pos, radius)
			local tes = ents.Create("point_tesla")
			if not IsValid(tes) then return end
			tes:SetPos(pos)
			tes:SetKeyValue("m_SoundName", "DoSpark")
			tes:SetKeyValue("texture", "sprites/physbeam.vmt")
			tes:SetKeyValue("m_Color", "180 180 180")
			tes:SetKeyValue("m_flRadius", tostring(radius or 120))
			tes:SetKeyValue("beamcount_min", "3")
			tes:SetKeyValue("beamcount_max", "5")
			tes:SetKeyValue("thick_min", "2")
			tes:SetKeyValue("thick_max", "4")
			tes:SetKeyValue("lifetime_min", "0.05")
			tes:SetKeyValue("lifetime_max", "0.12")
			tes:SetKeyValue("interval_min", "0.03")
			tes:SetKeyValue("interval_max", "0.05")
			tes:Spawn()
			tes:Activate()
			tes:Fire("DoSpark", "", 0)
			tes:Fire("Kill", "", 0.2)
		end

		local dir = (hitPos - shootPos)
		local dist = dir:Length()
		if dist <= 0 then return end
		dir:Mul(1 / dist)
		-- three bursts: near start, mid, near end
		spawnTesla(shootPos + dir * math.min(30, dist * 0.15) + VectorRand() * 6, math.min(120, dist * 0.3))
		spawnTesla(shootPos + dir * (dist * 0.5) + VectorRand() * 8, math.min(140, dist * 0.35))
		spawnTesla(shootPos + dir * math.max(dist - 30, dist * 0.85) + VectorRand() * 6, math.min(120, dist * 0.3))
	end

	function ENT:Think()
		local now = CurTime()
		local dt = math.Clamp(now - (self._lastThink or now), 0, 0.2)
		self._lastThink = now
		self:_PickTarget()
		self:_Chase(dt)

		if now >= (self._nextLaser or 0) then
			self:_FireLaser()
			self._nextLaser = now + LASER_INTERVAL
		end

		-- Periodic ambient whispers/hollow sounds when players are nearby
		if now >= (self._nextAmbient or 0) then
			local snd = "ambient/hallow0" .. math.random(4, 8) .. ".wav"
			self:EmitSound(snd, 60, math.random(95, 105), math.random(0.6, 1.4))
			self._nextAmbient = now + math.Rand(2.0, 4.0)
		end

		self:NextThink(now + 0.02)

		return true
	end
end

if CLIENT then
	local SPRITE_MAT = Material("sprites/light_glow02_add")

	local COL_PURPLE = Color(180, 180, 180)
	local COL_DEEPBLUE = Color(97, 97, 97)

	surface.CreateFont("Arcana_WispGlyph", {
		font = "Arial",
		size = 120,
		weight = 900,
		antialias = true
	})

	surface.CreateFont("Arcana_WispGlyphSmall", {
		font = "Arial",
		size = 60,
		weight = 500,
		antialias = true
	})

	local function pickGlyph()
		return GLYPHS[math.random(1, #GLYPHS)] or "*"
	end

	function ENT:Initialize()
		self._glyphChar = pickGlyph()
		self._jxAmp = math.random(2, 5)
		self._jyAmp = math.random(2, 4)
		self._jxW = math.Rand(8, 16)
		self._jyW = math.Rand(9, 18)
		self._jxP = math.Rand(0, math.pi * 2)
		self._jyP = math.Rand(0, math.pi * 2)
		-- mini glyphs cloud
		self._miniGlyphs = {}
		self._miniSpawnRate = 6 -- per second
		self._miniMax = 18
		self._miniAccum = 0
		-- laser noise seed tracking
		self._laserLastTime = 0
		self._laserSeed = math.Rand(0, 10000)
	end

	function ENT:DrawTranslucent()
		render.SuppressEngineLighting(true)
		render.SetLightingMode(2)
		self:DrawModel()
		render.SetLightingMode(0)
		render.SuppressEngineLighting(false)
		-- Core glow sprites layered over the sphere
		render.SetMaterial(SPRITE_MAT)
		local t = CurTime()
		local pulse = 0.5 + 0.5 * math.sin(t * 3.1)
		local baseSize = 64 + 40 * pulse
		render.DrawSprite(self:GetPos(), baseSize * 1.4, baseSize * 1.4, Color(COL_DEEPBLUE.r, COL_DEEPBLUE.g, COL_DEEPBLUE.b, 235))
		render.DrawSprite(self:GetPos(), baseSize * 0.9, baseSize * 0.9, Color(COL_DEEPBLUE.r, COL_DEEPBLUE.g, COL_DEEPBLUE.b, 190))
		local ply = LocalPlayer()
		local ang = Angle(0, 0, 0)

		if IsValid(ply) then
			ang = (ply:GetPos() - self:GetPos()):Angle()
		end

		ang:RotateAroundAxis(ang:Right(), -90)
		ang:RotateAroundAxis(ang:Up(), 90)
		local jx = (self._jxAmp or 3) * math.sin(t * (self._jxW or 12) + (self._jxP or 0))
		local jy = (self._jyAmp or 3) * math.cos(t * (self._jyW or 14) + (self._jyP or 0))
		cam.IgnoreZ(true)
		cam.Start3D2D(self:GetPos(), ang, 0.12)
		surface.SetFont("Arcana_WispGlyph")
		local txt = self._glyphChar or "*"
		local tw, th = surface.GetTextSize(txt)
		local cx = -tw * 0.5
		local cy = -th * 0.5
		-- Stroke around center
		surface.SetTextColor(0, 0, 0, 230)
		surface.SetTextPos(cx - 1 + jx, cy - 1 + jy)
		surface.DrawText(txt)
		surface.SetTextPos(cx + 1 + jx, cy - 1 + jy)
		surface.DrawText(txt)
		surface.SetTextPos(cx - 1 + jx, cy + 1 + jy)
		surface.DrawText(txt)
		surface.SetTextPos(cx + 1 + jx, cy + 1 + jy)
		surface.DrawText(txt)
		-- Bright core
		surface.SetTextColor(255, 255, 255)
		surface.SetTextPos(cx + jx, cy + jy)
		surface.DrawText(txt)
		-- Chromatic offsets
		surface.SetTextColor(COL_PURPLE.r, COL_PURPLE.g, COL_PURPLE.b, 170)
		surface.SetTextPos(cx + 2 + jx * 0.8, cy + 2 + jy * 0.8)
		surface.DrawText(txt)
		surface.SetTextColor(255, 255, 255, 160)
		surface.SetTextPos(cx - 2 + jx * 0.6, cy - 2 + jy * 0.6)
		surface.DrawText(txt)
		cam.End3D2D()
		cam.IgnoreZ(false)
		-- Dynamic light
		local d = DynamicLight(self:EntIndex())

		if d then
			d.pos = self:GetPos()
			d.r = 150
			d.g = 150
			d.b = 150
			d.brightness = 3
			d.Decay = 800
			d.Size = 220
			d.DieTime = CurTime() + 0.1
		end

		-- Mini glyph particles around the wisp (low density)
		local dt = FrameTime() > 0 and FrameTime() or 0.05
		self._miniAccum = (self._miniAccum or 0) + (self._miniSpawnRate or 6) * dt
		local toSpawn = math.floor(self._miniAccum)
		self._miniAccum = self._miniAccum - toSpawn
		self._miniGlyphs = self._miniGlyphs or {}

		for i = 1, math.min(toSpawn, math.max(0, (self._miniMax or 18) - #self._miniGlyphs)) do
			ang = math.Rand(0, math.pi * 2)
			local r = math.Rand(10, 24)

			local entry = {
				char = pickGlyph(),
				born = t,
				life = math.Rand(0.8, 1.4),
				x = math.cos(ang) * r,
				y = math.sin(ang) * r,
				z = math.Rand(2, 8),
				speed = math.Rand(16, 28),
				rot = math.Rand(0, 360),
				rotW = math.Rand(-60, 60)
			}

			self._miniGlyphs[#self._miniGlyphs + 1] = entry
		end

		if #self._miniGlyphs > 0 then
			for idx = #self._miniGlyphs, 1, -1 do
				local g = self._miniGlyphs[idx]
				local age = t - (g.born or t)

				if age >= (g.life or 1) then
					table.remove(self._miniGlyphs, idx)
				else
					local fade = 1 - (age / math.max(0.001, g.life or 1))
					local pos = self:GetPos() + Vector(g.x or 0, g.y or 0, (g.z or 0) + (g.speed or 20) * age)
					local tang = Angle(0, 0, 0)

					if IsValid(ply) then
						tang = (ply:GetPos() - pos):Angle()
					end

					tang:RotateAroundAxis(tang:Right(), -90)
					tang:RotateAroundAxis(tang:Up(), 90)
					cam.Start3D2D(pos, tang, 0.045)
					surface.SetFont("Arcana_WispGlyphSmall")
					txt = g.char or "*"
					tw, th = surface.GetTextSize(txt)
					cx = -tw * 0.5
					cy = -th * 0.5
					surface.SetTextColor(139, 139, 139, math.floor(200 * fade))
					surface.SetTextPos(cx, cy)
					surface.DrawText(txt)
					cam.End3D2D()
				end
			end
		end
	end

	function ENT:Draw()
	end
end