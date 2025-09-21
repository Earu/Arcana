AddCSLuaFile()
ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "Corrupted Wisp (Heavy)"
ENT.Category = "Arcana"
ENT.Spawnable = false
ENT.AdminOnly = false
ENT.RenderGroup = RENDERGROUP_BOTH
ENT.PhysgunDisabled = true

function ENT:SetupDataTables()
	self:NetworkVar("Float", 0, "Radius")
end

if SERVER then
	local FIRE_INTERVAL = 2.2
	local PROJECTILE_SPEED = 520
	local SEARCH_RADIUS_FACTOR = 0.9 -- use 90% of area radius for targetable range
	local CHASE_SPEED = 60 -- slower than normal wisps
	local STANDOFF_MIN = 350 -- prefer to keep far from players
	local STANDOFF_MAX = 700
	local STANDOFF_AREA_FRACTION = 0.8 -- cap by area radius
	local HIGH_ALTITUDE = 260 -- fly high above ground when possible
	local HEAVY_WISP_XP = 50

	function ENT:Initialize()
		self:SetModel("models/hunter/misc/sphere025x025.mdl")
		self:SetMaterial("models/shiny")
		self:SetColor(Color(180, 180, 180, 30))
		self:SetRenderMode(RENDERMODE_TRANSCOLOR)
		self:SetModelScale(2.4, 0)
		self:SetMoveType(MOVETYPE_FLY)
		self:SetSolid(SOLID_BBOX)
		self:PhysicsInit(SOLID_BBOX)
		self:SetCollisionBounds(Vector(-20, -20, -20), Vector(20, 20, 20))
		self:SetCollisionGroup(COLLISION_GROUP_DEBRIS)
		self:DrawShadow(false)
		self:SetRadius(240)
		-- Health (higher than normal wisps)
		self:SetMaxHealth(60)
		self:SetHealth(60)
		self._lastThink = CurTime()
		self._nextFire = CurTime() + 1.2
		self._areaCenter = self._areaCenter or self:GetPos()
		self._areaRadius = self._areaRadius or 500

		local phys = self:GetPhysicsObject()
		if IsValid(phys) then
			phys:SetMass(0.2)
			phys:EnableGravity(false)
			phys:Wake()
		end
	end

	function ENT:OnTakeDamage(dmginfo)
		local cur = self:Health()
		local new = math.max(0, cur - (dmginfo:GetDamage() or 0))
		self:SetHealth(new)
		-- track last player who hurt the wisp
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

		-- brief hit feedback
		local tes = ents.Create("point_tesla")
		if IsValid(tes) then
			tes:SetPos(self:GetPos())
			tes:SetKeyValue("m_SoundName", "DoSpark")
			tes:SetKeyValue("texture", "sprites/physbeam.vmt")
			tes:SetKeyValue("m_Color", "200 200 200")
			tes:SetKeyValue("m_flRadius", "90")
			tes:SetKeyValue("beamcount_min", "3")
			tes:SetKeyValue("beamcount_max", "5")
			tes:SetKeyValue("thick_min", "2")
			tes:SetKeyValue("thick_max", "4")
			tes:SetKeyValue("lifetime_min", "0.04")
			tes:SetKeyValue("lifetime_max", "0.08")
			tes:SetKeyValue("interval_min", "0.02")
			tes:SetKeyValue("interval_max", "0.04")
			tes:Spawn()
			tes:Activate()
			tes:Fire("DoSpark", "", 0)
			tes:Fire("Kill", "", 0.2)
		end

		if new <= 0 and not self._arcanaDead then
			self._arcanaDead = true
			local ed = EffectData()
			ed:SetOrigin(self:GetPos())
			util.Effect("cball_explode", ed, true, true)
			-- award XP
			local killer = atk
			if not (IsValid(killer) and killer:IsPlayer()) then
				killer = self._lastHurtBy
			end
			if IsValid(killer) and killer:IsPlayer() and Arcane and Arcane.GiveXP then
				Arcane:GiveXP(killer, HEAVY_WISP_XP, "Heavy wisp destroyed")
			end
			self:Remove()
		end
	end

	local function pickTarget(self)
		local center = self._areaCenter or self:GetPos()
		local r = (self._areaRadius or 500) * SEARCH_RADIUS_FACTOR
		local best, bestD2 = nil, math.huge
		for _, ent in ipairs(ents.FindInSphere(center, r)) do
			if not IsValid(ent) then continue end
			if ent:IsPlayer() and not ent:Alive() then continue end
			local isTarget = ent:IsPlayer() or ent:IsNPC() or (ent.IsNextBot and ent:IsNextBot())
			if not isTarget then continue end
			local d2 = center:DistToSqr(ent:GetPos())
			if d2 < bestD2 then best, bestD2 = ent, d2 end
		end

		return best
	end

	function ENT:_FireAtTarget()
		local target = pickTarget(self)
		if not IsValid(target) then return end
		local dir = (target:WorldSpaceCenter() - self:WorldSpaceCenter()):GetNormalized()
		local orb = ents.Create("arcana_glyph_orb")
		if not IsValid(orb) then return end
		orb:SetPos(self:WorldSpaceCenter())
		orb:SetAngles(dir:Angle())
		orb:SetOwner(self)
		orb:SetSpellOwner(self)
		orb.OrbSpeed = PROJECTILE_SPEED
		orb:Spawn()
		orb:Activate()
		orb:LaunchTowards(dir)
		self:EmitSound("weapons/physcannon/energy_sing_flyby1.wav", 65, 90)
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

		if IsValid(nearest) then
			local center = self._areaCenter or self:GetPos()
			local r = self._areaRadius or 500
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
		local r = self._areaRadius or 500
		local myPos = self:GetPos()

		-- keep within area bounds
		if myPos:DistToSqr(center) > r * r then
			local dir = (center - myPos)
			local dist = dir:Length()
			if dist > 1 then
				dir:Mul(1 / dist)
			end
			self:SetPos(myPos + dir * (CHASE_SPEED * 1.1) * dt)
			self:SetAngles(dir:Angle())
			return
		end

		-- idle hover when no target (prefer high over ground)
		if not IsValid(self._target) then
			local tr = util.TraceLine({ start = myPos + Vector(0, 0, 200), endpos = myPos + Vector(0, 0, -10000), filter = self })
			local desired = Vector(myPos)
			desired.z = (tr.HitPos.z or myPos.z) + HIGH_ALTITUDE
			local dz = desired.z - myPos.z
			local vz = math.Clamp(dz, -1, 1) * (CHASE_SPEED * 0.8)
			self:SetPos(myPos + Vector(0, 0, vz * dt))
			-- face roughly towards area center while idling
			local face = (center - myPos):GetNormalized()
			self:SetAngles(face:Angle())
			return
		end

		-- keep large distance and fly high; no orbiting
		local targetPos = self._target:EyePos()
		local trGround = util.TraceLine({ start = targetPos + Vector(0, 0, 600), endpos = targetPos + Vector(0, 0, -10000), filter = self })
		local desiredZ = (trGround.HitPos.z or targetPos.z) + HIGH_ALTITUDE
		local standoff = math.Clamp((self._areaRadius or 500) * STANDOFF_AREA_FRACTION, STANDOFF_MIN, STANDOFF_MAX)

		local toTarget = targetPos - myPos
		local horiz = Vector(toTarget.x, toTarget.y, 0)
		local distH = horiz:Length()
		local move = Vector(0, 0, 0)
		local speed = CHASE_SPEED

		if distH > 1 then horiz:Mul(1 / distH) end
		-- horizontal control: move towards/away to maintain standoff, no strafing
		if distH < (standoff - 30) then
			move = move - horiz * speed -- move directly away
		elseif distH > (standoff + 60) then
			move = move + horiz * (speed * 0.75) -- close in slowly
		end

		-- vertical control: go to desiredZ
		local dz = desiredZ - myPos.z
		if math.abs(dz) > 6 then
			move = move + Vector(0, 0, math.Clamp(dz, -1, 1) * speed)
		end

		-- apply movement if any
		local mvLen = move:Length()
		if mvLen > 0 then
			move:Mul(1 / mvLen)
			self:SetPos(myPos + move * speed * dt)
		end
		-- face towards the player
		local face = (self._target:WorldSpaceCenter() - self:WorldSpaceCenter()):GetNormalized()
		self:SetAngles(face:Angle())
	end

	function ENT:Think()
		local now = CurTime()
		local dt = math.Clamp(now - (self._lastThink or now), 0, 0.2)
		self._lastThink = now

		self:_PickTarget()
		self:_Chase(dt)

		if now >= (self._nextFire or 0) then
			self:_FireAtTarget()
			self._nextFire = now + FIRE_INTERVAL
		end

		self:NextThink(now + 0.03)
		return true
	end

	function ENT:OnRemove()
	end
end

if CLIENT then
	local SPRITE_MAT = Material("sprites/light_glow02_add")
	local GLYPHS = {"Γ", "Δ", "Θ", "Λ", "Ξ", "Π", "Σ", "Φ", "Ψ", "Ω", "α", "β", "γ", "δ", "ε", "ζ", "η", "θ", "ι", "κ", "λ", "μ", "ξ", "π", "φ", "ψ", "ω"}

	surface.CreateFont("Arcana_HeavyGlyph", {
		font = "Arial",
		size = 300,
		weight = 900,
		antialias = true
	})

	surface.CreateFont("Arcana_HeavyGlyphSmall", {
		font = "Arial",
		size = 90,
		weight = 600,
		antialias = true
	})

	local function pickGlyph()
		return GLYPHS[math.random(1, #GLYPHS)] or "*"
	end

	function ENT:Initialize()
		self._glyphChar = pickGlyph()
		self._ringRot = math.Rand(0, 360)
		self._miniGlyphs = {}
		self._miniSpawnRate = 8
		self._miniMax = 22
		self._miniAccum = 0
	end

	function ENT:DrawTranslucent()
		self:DrawModel()
		local pos = self:GetPos()
		local t = CurTime()
		-- Core glow
		render.SetMaterial(SPRITE_MAT)
		local pulse = 0.5 + 0.5 * math.sin(t * 2.2)
		local size = 350 + 100 * pulse
		render.DrawSprite(pos, size, size, Color(230, 230, 230, 220))
		render.DrawSprite(pos, size * 0.6, size * 0.6, Color(255, 255, 255, 235))

		-- Dynamic light (grayscale)
		local d = DynamicLight(self:EntIndex())
		if d then
			d.pos = pos
			d.r = 220
			d.g = 220
			d.b = 220
			d.brightness = 2.2
			d.Decay = 900
			d.Size = 240
			d.DieTime = CurTime() + 0.1
		end

		-- Central large glyph
		local ply = LocalPlayer()
		local ang = Angle(0, 0, 0)
		if IsValid(ply) then
			ang = (ply:GetPos() - pos):Angle()
		end

		ang:RotateAroundAxis(ang:Right(), -90)
		ang:RotateAroundAxis(ang:Up(), 90)

		cam.Start3D2D(pos, ang, 0.14)
			surface.SetFont("Arcana_HeavyGlyph")
			local txt = self._glyphChar or "*"
			local tw, th = surface.GetTextSize(txt)
			surface.SetTextColor(0, 0, 0, 230)
			surface.SetTextPos(-tw * 0.5 + 2, -th * 0.5 + 2)
			surface.DrawText(txt)
			surface.SetTextPos(-tw * 0.5, -th * 0.5)
			surface.DrawText(txt)
		cam.End3D2D()

		-- Orbiting glyph ring
		self._ringRot = (self._ringRot or 0) + FrameTime() * 18
		local ringR = 150
		local count = 12
		for i = 1, count do
			local a = math.rad((i / count) * 360 + self._ringRot)
			local gpos = pos + Vector(math.cos(a) * ringR, math.sin(a) * ringR, math.sin(t * 1.5 + i) * 14)
			local gang = Angle(0, 0, 0)
			if IsValid(ply) then
				gang = (ply:GetPos() - gpos):Angle()
			end
			gang:RotateAroundAxis(gang:Right(), -90)
			gang:RotateAroundAxis(gang:Up(), 90)
			cam.Start3D2D(gpos, gang, 0.11)
				surface.SetFont("Arcana_HeavyGlyphSmall")
				local txt = GLYPHS[(i % #GLYPHS) + 1] or "*"
				local tw, th = surface.GetTextSize(txt)
				surface.SetTextColor(120, 120, 120, 220)
				surface.SetTextPos(-tw * 0.5, -th * 0.5)
				surface.DrawText(txt)
			cam.End3D2D()
		end

		-- Mini glyph cloud spawn/update
		local dt = FrameTime() > 0 and FrameTime() or 0.05
		self._miniAccum = (self._miniAccum or 0) + (self._miniSpawnRate or 8) * dt
		local toSpawn = math.floor(self._miniAccum)
		self._miniAccum = self._miniAccum - toSpawn
		for i = 1, math.min(toSpawn, math.max(0, (self._miniMax or 22) - #(self._miniGlyphs or {}))) do
			local ang2 = math.Rand(0, math.pi * 2)
			local r = math.Rand(24, 54)
			local entry = {
				char = pickGlyph(),
				born = t,
				life = math.Rand(0.9, 1.5),
				x = math.cos(ang2) * r,
				y = math.sin(ang2) * r,
				z = math.Rand(6, 14),
				speed = math.Rand(20, 36),
				rot = math.Rand(0, 360),
				rotW = math.Rand(-80, 80)
			}
			self._miniGlyphs[#self._miniGlyphs + 1] = entry
		end

		if self._miniGlyphs and #self._miniGlyphs > 0 then
			for idx = #self._miniGlyphs, 1, -1 do
				local g = self._miniGlyphs[idx]
				local age = t - (g.born or t)
				if age >= (g.life or 1) then
					table.remove(self._miniGlyphs, idx)
				else
					local fade = 1 - (age / math.max(0.001, g.life or 1))
					local p = pos + Vector(g.x or 0, g.y or 0, (g.z or 0) + (g.speed or 20) * age)
					local gang = Angle(0, 0, 0)
					if IsValid(ply) then
						gang = (ply:GetPos() - p):Angle()
					end
					gang:RotateAroundAxis(gang:Right(), -90)
					gang:RotateAroundAxis(gang:Up(), 90)
					cam.Start3D2D(p, gang, 0.09)
						surface.SetFont("Arcana_HeavyGlyphSmall")
						local txt = g.char or "*"
						local tw, th = surface.GetTextSize(txt)
						surface.SetTextColor(180, 180, 180, math.floor(200 * fade))
						surface.SetTextPos(-tw * 0.5, -th * 0.5)
						surface.DrawText(txt)
					cam.End3D2D()
				end
			end
		end
	end

	function ENT:Draw()
	end
end