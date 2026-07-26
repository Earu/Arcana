AddCSLuaFile()
ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "Brazier"
ENT.Category = "Arcana"
ENT.Spawnable = true
ENT.RenderGroup = RENDERGROUP_BOTH
ENT.Author = "Earu"

-- Ground traces stop on world/props but pass through players and NPCs
local GROUND_COLLISION_GROUP = COLLISION_GROUP_WEAPON

-- Ranges for the player-adjustable properties (see the properties block at the bottom)
ENT.DefaultFlameColor = Color(255, 160, 50)
ENT.MinFloatHeight = 0
ENT.MaxFloatHeight = 600
ENT.MaxLightScale = 3

local function packColor(col)
	local r = math.Clamp(math.Round(col.r), 0, 255)
	local g = math.Clamp(math.Round(col.g), 0, 255)
	local b = math.Clamp(math.Round(col.b), 0, 255)

	return bit.bor(bit.lshift(r, 16), bit.lshift(g, 8), b)
end

local function unpackColor(packed)
	return Color(bit.band(bit.rshift(packed, 16), 255), bit.band(bit.rshift(packed, 8), 255), bit.band(packed, 255))
end

-- The flame color travels as a packed 24bit int: networked vectors lose too much
-- precision on 0-1 components to round-trip a color cleanly.
function ENT:SetFlameColor(col)
	self:SetFlameColorPacked(packColor(col))
end

function ENT:GetFlameColor()
	return unpackColor(self:GetFlameColorPacked())
end

function ENT:SetupDataTables()
	self:NetworkVar("Float", 0, "FloatHeight")
	self:NetworkVar("Float", 1, "CircleSize")
	self:NetworkVar("Float", 2, "LightScale")
	self:NetworkVar("Int", 0, "FlameColorPacked")

	if SERVER then
		-- Random float height between 100 and 250 units
		self:SetFloatHeight(math.Rand(100, 250))
		self:SetCircleSize(40)
		self:SetLightScale(1)
		self:SetFlameColor(self.DefaultFlameColor)
	end
end

if SERVER then
	function ENT:Initialize()
		-- Use the shell model inverted
		self:SetModel("models/hunter/misc/shell2x2a.mdl")
		self:SetMaterial("arcana/pattern_antique_stone")

		self:PhysicsInit(SOLID_VPHYSICS)
		self:SetMoveType(MOVETYPE_VPHYSICS)
		self:SetSolid(SOLID_VPHYSICS)

		local phys = self:GetPhysicsObject()
		if IsValid(phys) then
			phys:Wake()
			phys:EnableMotion(false)
		end

		-- Start motion controller for floating
		self:StartMotionController()
		self.ShadowParams = {}

		-- Initialize rotation angle
		self._rotationAngle = 0

		-- Initialize fire effect timer
		self._nextFireEffect = 0

		-- Start looping fire sound
		self._fireSound = CreateSound(self, "ambient/fire/fire_med_loop1.wav")
		if self._fireSound then
			self._fireSound:Play()
			self._fireSound:SetSoundLevel(65)
		end
	end

	local TRACE_OFFSET = Vector(0, 0, 1000)
	local VECTOR_UP = Vector(0, 0, 1)

	function ENT:PhysicsSimulate(phys, deltatime)
		if not IsValid(phys) then return end

		phys:Wake()

		-- Trace down to find ground
		local currentPos = self.PositionOverride or self:GetPos()
		local tr = util.TraceLine({
			start = currentPos,
			endpos = currentPos - TRACE_OFFSET,
			mask = MASK_SOLID,
			filter = self,
			collisiongroup = GROUND_COLLISION_GROUP,
		})

		-- Calculate target position from ground with gentle bobbing
		local bobOffset = math.sin(CurTime() * 0.8) * 8 + math.cos(CurTime() * 0.5) * 4
		local floatPos = tr.HitPos + (self:GetFloatHeight() + bobOffset) * VECTOR_UP

		-- Add extremely slow rotation
		self._rotationAngle = (self._rotationAngle + deltatime * 3) % 360
		local targetAng = Angle(180, self._rotationAngle, 0)

		-- Set shadow parameters for smooth floating
		self.ShadowParams.secondstoarrive = 0.15
		self.ShadowParams.pos = floatPos
		self.ShadowParams.angle = targetAng
		self.ShadowParams.maxangular = 3000
		self.ShadowParams.maxangulardamp = 8000
		self.ShadowParams.maxspeed = 100000
		self.ShadowParams.maxspeeddamp = 10000
		self.ShadowParams.dampfactor = 0.8
		self.ShadowParams.teleportdistance = 0
		self.ShadowParams.delta = deltatime

		phys:ComputeShadowControl(self.ShadowParams)
	end

	function ENT:SpawnFunction(ply, tr, classname)
		if not tr or not tr.Hit then return end

		local pos = tr.HitPos + tr.HitNormal * 4
		local ent = ents.Create(classname or "arcana_brazier")
		if not IsValid(ent) then return end

		-- Spawn at ground level, will float up
		ent:SetPos(pos)
		ent:SetAngles(Angle(180, ply:EyeAngles().y, 0))
		ent:Spawn()
		ent:Activate()

		return ent
	end

	function ENT:Think()
		local now = CurTime()

		-- Create fire effects periodically
		if not self._nextFireEffect or now >= self._nextFireEffect then
			self:CreateFireEffect()
			self._nextFireEffect = now + 0.1
		end

		self:NextThink(now + 0.05)
		return true
	end

	function ENT:CreateFireEffect()
		local center = self:GetPos()
		local offset = VectorRand() * 15
		offset.z = math.abs(offset.z) + 10

		local ed = EffectData()
		ed:SetOrigin(center + offset)
		ed:SetMagnitude(2)
		ed:SetScale(math.Rand(0.5, 1.2))
		ed:SetRadius(2)
		util.Effect("fire_embers", ed)
	end

	function ENT:OnRemove()
		-- Stop the looping fire sound cleanly
		if self._fireSound then
			self._fireSound:Stop()
			self._fireSound = nil
		end
	end
end

if CLIENT then
	-- Magical glow material
	local glowMat = Material("sprites/light_glow02_add")

	-- Create global material with scaled texture (4x larger) - shared by all braziers
	local BRAZIER_MATERIAL_NAME = "arcana_brazier_scaled_" .. FrameNumber()
	local BRAZIER_MATERIAL = CreateMaterial(BRAZIER_MATERIAL_NAME, "VertexLitGeneric", {
		["$basetexture"] = "arcana/pattern_antique_stone",
		["$basetexturetransform"] = "center 0 0 scale 0.25 0.25 rotate 0 translate 0 0",
		["$model"] = 1,
	})

	-- Every flame tone is derived from the networked base color so a recolored
	-- brazier keeps the same hot-core/deep-ember relationship the default had.
	local function shade(col, hueShift, satMul, valMul)
		local h, s, v = ColorToHSV(col)

		return HSVToColor((h + hueShift) % 360, math.Clamp(s * satMul, 0, 1), math.Clamp(v * valMul, 0, 1))
	end

	function ENT:GetPalette()
		local packed = self:GetFlameColorPacked()
		local pal = self._palette
		if pal and pal.packed == packed then return pal end

		local base = self:GetFlameColor()
		pal = {
			packed = packed,
			base = base,
			-- Shifts chosen so a default-orange brazier reproduces the original
			-- hardcoded fire tones (deep 255,100,20 / gold 255,200,80 / bright
			-- 255,240,100 / core 255,240,140) to within a few units.
			deep = shade(base, -6, 1.15, 1), -- ember tones at the edges
			gold = shade(base, 15, 0.85, 1),
			bright = shade(base, 22, 0.76, 1),
			core = shade(base, 18, 0.56, 1), -- near white-hot center
		}
		self._palette = pal

		if self._circle then
			self._circle.color = Color(base.r, base.g, base.b, 220)
		end

		return pal
	end

	function ENT:Initialize()
		self._circle = nil
		self._emitter = ParticleEmitter(self:GetPos(), false)
		self._nextMagicParticle = 0
		self._nextEmber = 0

		-- Set large render bounds to account for:
		-- - Dynamic lights (up to 400 unit radius)
		-- - Fire particles rising high above
		-- - Magic circle potentially far below
		self:SetRenderBounds(Vector(-450, -450, -300), Vector(450, 450, 500))
	end

	local MagicCircle = Arcana.Circle.MagicCircle
	local MagicCircleManager = Arcana.Circle.MagicCircleManager

	-- Create magic circle on ground underneath showing fire levitation
	function ENT:CreateLevitationCircle()
		if not MagicCircle or not MagicCircle.new then return end
		if self._circle and self._circle.IsActive and self._circle:IsActive() then return end

		-- Trace down to ground to get proper position and normal
		local center = self:GetPos()
		local tr = util.TraceLine({
			start = center,
			endpos = center - Vector(0, 0, 2000),
			mask = MASK_SOLID,
			filter = self,
			collisiongroup = GROUND_COLLISION_GROUP,
		})

		if not tr.Hit then return end

		-- Position circle on the ground surface
		local pos = tr.HitPos + tr.HitNormal * 2

		-- Align circle with ground surface
		local ang = tr.HitNormal:Angle()
		ang:RotateAroundAxis(ang:Right(), 90)

		-- Levitation circle takes the flame color
		local base = self:GetPalette().base
		local circleColor = Color(base.r, base.g, base.b, 220)
		local size = 70
		local intensity = 5

		self._circle = MagicCircle.new(pos, ang, circleColor, intensity, size, 2.5)
		if self._circle then
			self._circle:SetReferenceEntity(self)
			MagicCircleManager:Add(self._circle)
		end
	end

	function ENT:OnRemove()
		-- Clean up magic circle
		if self._circle and self._circle.Destroy then
			self._circle:Destroy()
		end
		self._circle = nil

		-- Clean up particle emitter
		if self._emitter then
			self._emitter:Finish()
			self._emitter = nil
		end
	end

	function ENT:Think()
		local now = CurTime()

		-- Ensure levitation circle exists below
		self:CreateLevitationCircle()

		-- Update circle position to stay on ground below brazier
		if self._circle and self._circle.IsActive and self._circle:IsActive() then
			local center = self:GetPos()
			local tr = util.TraceLine({
				start = center,
				endpos = center - Vector(0, 0, 2000),
				mask = MASK_SOLID,
				filter = self,
				collisiongroup = GROUND_COLLISION_GROUP,
			})

			if tr.Hit then
				self._circle.position = tr.HitPos + tr.HitNormal * 2
				local ang = tr.HitNormal:Angle()
				ang:RotateAroundAxis(ang:Right(), 90)
				self._circle.angles = ang
			end
		end

		-- Spawn fire levitation particles from below
		if now >= self._nextMagicParticle then
			self:SpawnLevitationParticle()
			self:SpawnLevitationParticle() -- Extra particles
			self._nextMagicParticle = now + 0.08
		end

		-- Spawn massive fire from inside the brazier
		if now >= self._nextEmber then
			self:SpawnFireParticle()
			self:SpawnFireParticle()
			self:SpawnFireParticle() -- Triple the fire
			self._nextEmber = now + 0.015
		end

		self:SetNextClientThink(now + 0.02)
		return true
	end

	-- Fire magic particles rising from below showing levitation force
	function ENT:SpawnLevitationParticle()
		if not self._emitter then return end

		local center = self:GetPos()
		local floatHeight = self:GetFloatHeight()

		-- Spawn from below, around the magic circle area
		local radius = 60
		local angle = math.Rand(0, math.pi * 2)
		local r = math.Rand(radius * 0.2, radius)

		local pos = center + Vector(
			math.cos(angle) * r,
			math.sin(angle) * r,
			-floatHeight * 0.8 -- Start from below
		)

		local p = self._emitter:Add("sprites/light_glow02_add", pos)
		if p then
			p:SetStartAlpha(220)
			p:SetEndAlpha(0)
			p:SetStartSize(math.Rand(4, 9))
			p:SetEndSize(0)
			p:SetDieTime(math.Rand(1.5, 2.5))

			-- Rise up toward the brazier with some spiral motion
			local vel = Vector(0, 0, math.Rand(60, 100))
			vel.x = math.Rand(-15, 15)
			vel.y = math.Rand(-15, 15)
			p:SetVelocity(vel)

			p:SetAirResistance(25)
			p:SetGravity(Vector(0, 0, 0))
			p:SetRoll(math.Rand(-180, 180))
			p:SetRollDelta(math.Rand(-2, 2))

			-- Flame tones: base, deep ember, bright tip
			local pal = self:GetPalette()
			local colorChoice = math.random(1, 3)
			local col = colorChoice == 1 and pal.base or colorChoice == 2 and pal.deep or pal.bright
			p:SetColor(col.r, col.g, col.b)
		end
	end

	-- Massive fire particles from inside the brazier
	function ENT:SpawnFireParticle()
		if not self._emitter then return end

		local center = self:GetPos()
		local offset = VectorRand() * 25
		offset.z = math.Rand(-12, 5) -- Inside and above the bowl

		local p = self._emitter:Add("effects/fire_cloud" .. math.random(1, 2), center + offset)
		if p then
			p:SetStartAlpha(255)
			p:SetEndAlpha(0)
			p:SetStartSize(math.Rand(20, 40)) -- Much larger
			p:SetEndSize(math.Rand(5, 12))
			p:SetDieTime(math.Rand(1.2, 2.5)) -- Longer life

			-- Vigorous rise from intense fire
			local vel = VectorRand() * 25
			vel.z = math.Rand(80, 160)
			p:SetVelocity(vel)

			p:SetAirResistance(40)
			p:SetGravity(Vector(0, 0, 15))
			p:SetRoll(math.Rand(-180, 180))
			p:SetRollDelta(math.Rand(-8, 8))

			-- Intense fire colors, all pulled from the flame palette
			local pal = self:GetPalette()
			local colorChoice = math.random(1, 4)
			local col = colorChoice == 1 and pal.base or colorChoice == 2 and pal.bright or colorChoice == 3 and pal.deep or pal.gold
			p:SetColor(col.r, col.g, col.b)
		end
	end

	function ENT:Draw()
		-- Draw the brazier model with scaled material
		render.MaterialOverride(BRAZIER_MATERIAL)
		self:DrawModel()
		render.MaterialOverride()
	end

	function ENT:DrawTranslucent()
		local center = self:GetPos()
		local t = CurTime()
		local pal = self:GetPalette()

		-- Massive fire glow from inside brazier
		local pulse = 0.7 + 0.3 * math.sin(t * 2.5)
		local glowSize = 140 + 60 * pulse -- Much larger

		render.SetMaterial(glowMat)
		-- Outer flame glow
		render.DrawSprite(center, glowSize, glowSize, Color(pal.base.r, pal.base.g, pal.base.b, 220 * pulse))
		-- Mid glow
		render.DrawSprite(center, glowSize * 0.7, glowSize * 0.7, Color(pal.gold.r, pal.gold.g, pal.gold.b, 200 * pulse))
		-- Inner hot core
		render.DrawSprite(center, glowSize * 0.4, glowSize * 0.4, Color(pal.core.r, pal.core.g, pal.core.b, 240 * pulse))

		-- Fire magic levitation glow from below (on ground)
		local tr = util.TraceLine({
			start = center,
			endpos = center - Vector(0, 0, 2000),
			mask = MASK_SOLID,
			filter = self,
			collisiongroup = GROUND_COLLISION_GROUP,
		})

		if tr.Hit then
			local magicPos = tr.HitPos + tr.HitNormal * 5
			local magicPulse = 0.6 + 0.4 * math.sin(t * 2.2)
			local magicSize = 140 + 50 * magicPulse

			render.DrawSprite(magicPos, magicSize, magicSize, Color(pal.base.r, pal.base.g, pal.base.b, 150 * magicPulse))
		end

		-- Light output is player-adjustable; 0 means the brazier lights nothing
		local lightScale = math.Clamp(self:GetLightScale(), 0, self.MaxLightScale)
		if lightScale <= 0 then return end

		local sizeScale = 0.6 + 0.4 * lightScale

		-- Dynamic light (intense fire from above)
		local dl = DynamicLight(self:EntIndex())
		if dl then
			dl.pos = center
			dl.r = pal.gold.r
			dl.g = pal.gold.g
			dl.b = pal.gold.b
			dl.brightness = (6 + pulse * 3) * lightScale
			dl.Decay = 400
			dl.Size = 400 * sizeScale -- Much larger light
			dl.DieTime = t + 0.1
		end

		-- Secondary light for fire levitation magic (below on ground)
		if tr.Hit then
			local dl2 = DynamicLight(self:EntIndex() + 1)
			if dl2 then
				local magicPulse = 0.6 + 0.4 * math.sin(t * 2.2)
				dl2.pos = tr.HitPos + tr.HitNormal * 5
				dl2.r = pal.base.r
				dl2.g = pal.base.g
				dl2.b = pal.base.b
				dl2.brightness = (3 + magicPulse * 2) * lightScale
				dl2.Decay = 300
				dl2.Size = 280 * sizeScale
				dl2.DieTime = t + 0.1
			end
		end
	end
end

-- Context-menu properties. Registered shared: the client builds the menus,
-- the server validates and applies. Guarded because non-sandbox gamemodes
-- have no properties module.
if properties and properties.Add then
	local FLAME_PRESETS = {
		{name = "Ember", color = Color(255, 160, 50)},
		{name = "Crimson", color = Color(255, 70, 45)},
		{name = "Gold", color = Color(255, 210, 95)},
		{name = "Witchfire", color = Color(140, 255, 90)},
		{name = "Emerald", color = Color(90, 255, 150)},
		{name = "Azure", color = Color(80, 170, 255)},
		{name = "Frost", color = Color(160, 230, 255)},
		{name = "Violet", color = Color(180, 110, 255)},
		{name = "Bone", color = Color(235, 230, 205)},
	}

	local HEIGHT_PRESETS = {
		{name = "Resting", height = 20},
		{name = "Low", height = 80},
		{name = "Standard", height = 150},
		{name = "High", height = 280},
		{name = "Soaring", height = 450},
	}

	local LIGHT_PRESETS = {
		{name = "Off", scale = 0},
		{name = "Dim", scale = 0.4},
		{name = "Normal", scale = 1},
		{name = "Bright", scale = 1.8},
		{name = "Blinding", scale = 3},
	}

	local sendThrottled, openFlameColorPicker

	if CLIENT then
		-- Sliders and the color mixer fire continuously while dragged: cap the rate
		-- but never drop the value the player actually settled on.
		local pending = {}

		sendThrottled = function(key, value, sendFn)
			local now = SysTime()
			local entry = pending[key]

			if not entry then
				entry = {last = 0}
				pending[key] = entry
			end

			entry.value = value
			entry.send = sendFn

			if now - entry.last >= 0.1 then
				entry.last = now
				sendFn(value)

				return
			end

			if entry.scheduled then return end
			entry.scheduled = true

			timer.Simple(0.1 - (now - entry.last), function()
				entry.scheduled = false
				entry.last = SysTime()
				entry.send(entry.value)
			end)
		end

		openFlameColorPicker = function(prop, ent)
			local frame = vgui.Create("DFrame")
			frame:SetSize(280, 330)
			frame:Center()
			frame:SetTitle("")
			frame:MakePopup()

			frame.Paint = function(_, w, h)
				ArtDeco.FillDecoPanel(0, 0, w, h, ArtDeco.Colors.decoBg, 12)
				ArtDeco.DrawDecoFrame(4, 4, w - 8, h - 8, ArtDeco.Colors.gold, 10)
				ArtDeco.DrawTitle("Arcana_Ancient", "FLAME COLOR", 8, 36, ArtDeco.Colors.paleGold)
			end

			ArtDeco.StyleCloseButton(frame)

			local mixer = vgui.Create("DColorMixer", frame)
			mixer:Dock(FILL)
			mixer:DockMargin(14, 40, 14, 14)
			mixer:SetPalette(true)
			mixer:SetAlphaBar(false)
			mixer:SetWangs(true)
			mixer:SetColor(ent:GetFlameColor())

			mixer.ValueChanged = function(_, col)
				if not IsValid(ent) then
					frame:Remove()

					return
				end

				sendThrottled("flame_" .. ent:EntIndex(), col, function(value) prop:Apply(ent, value) end)
			end

			return frame
		end
	end

	local function makeFilter(name)
		return function(_, ent, ply)
			if not IsValid(ent) or ent:GetClass() ~= "arcana_brazier" then return false end
			if not IsValid(ply) or not ply:IsPlayer() then return false end
			if not gamemode.Call("CanProperty", ply, name, ent) then return false end
			if ply:IsAdmin() then return true end

			-- Defer to prop protection when installed; plain sandbox lets anyone tweak
			local owner = ent.CPPIGetOwner and ent:CPPIGetOwner()
			if IsValid(owner) then return owner == ply end

			return true
		end
	end

	-- Reads the entity a property message targets, or nil if the sender may not touch it
	local function readTarget(prop, ply)
		local ent = net.ReadEntity()
		if not IsValid(ent) then return end
		if not properties.CanBeTargeted(ent, ply) then return end
		if not prop:Filter(ent, ply) then return end

		return ent
	end

	properties.Add("arcana_brazier_flame_color", {
		MenuLabel = "Flame Color",
		Order = 900,
		MenuIcon = "icon16/paintcan.png",
		Filter = makeFilter("arcana_brazier_flame_color"),

		Apply = function(self, ent, col)
			self:MsgStart()
			net.WriteEntity(ent)
			net.WriteUInt(packColor(col), 24)
			self:MsgEnd()
		end,

		MenuOpen = function(self, option, ent)
			local submenu = option:AddSubMenu()
			submenu:SetMinimumWidth(170)

			for _, preset in ipairs(FLAME_PRESETS) do
				local swatch = preset.color
				local opt = submenu:AddOption(preset.name, function() self:Apply(ent, swatch) end)

				opt.PaintOver = function(_, w, h)
					local y = h * 0.5 - 6
					surface.SetDrawColor(swatch)
					surface.DrawRect(w - 26, y, 16, 12)
					surface.SetDrawColor(0, 0, 0, 180)
					surface.DrawOutlinedRect(w - 26, y, 16, 12)
				end
			end

			submenu:AddSpacer()
			submenu:AddOption("Custom...", function() openFlameColorPicker(self, ent) end):SetIcon("icon16/color_wheel.png")
		end,

		Action = function() end,

		Receive = function(self, _, ply)
			local ent = readTarget(self, ply)
			local packed = net.ReadUInt(24)
			if not IsValid(ent) then return end

			ent:SetFlameColorPacked(packed)
		end,
	})

	properties.Add("arcana_brazier_float_height", {
		MenuLabel = "Float Height",
		Order = 901,
		MenuIcon = "icon16/arrow_up.png",
		Filter = makeFilter("arcana_brazier_float_height"),

		Apply = function(self, ent, height)
			self:MsgStart()
			net.WriteEntity(ent)
			net.WriteFloat(height)
			self:MsgEnd()
		end,

		MenuOpen = function(self, option, ent)
			local submenu = option:AddSubMenu()
			submenu:SetMinimumWidth(250)

			local slider = vgui.Create("DNumSlider", submenu)
			slider:SetSize(240, 44)
			slider:SetText("Units")
			slider:SetMin(ent.MinFloatHeight)
			slider:SetMax(ent.MaxFloatHeight)
			slider:SetDecimals(0)
			slider:SetValue(ent:GetFloatHeight())

			slider.OnValueChanged = function(_, value)
				if not IsValid(ent) then return end

				sendThrottled("height_" .. ent:EntIndex(), value, function(v) self:Apply(ent, v) end)
			end

			submenu:AddPanel(slider)
			submenu:AddSpacer()

			for _, preset in ipairs(HEIGHT_PRESETS) do
				submenu:AddOption(preset.name, function() self:Apply(ent, preset.height) end)
			end
		end,

		Action = function() end,

		Receive = function(self, _, ply)
			local ent = readTarget(self, ply)
			local height = net.ReadFloat()
			if not IsValid(ent) then return end

			ent:SetFloatHeight(math.Clamp(height, ent.MinFloatHeight, ent.MaxFloatHeight))
		end,
	})

	properties.Add("arcana_brazier_light", {
		MenuLabel = "Light Output",
		Order = 902,
		MenuIcon = "icon16/lightbulb.png",
		Filter = makeFilter("arcana_brazier_light"),

		Apply = function(self, ent, scale)
			self:MsgStart()
			net.WriteEntity(ent)
			net.WriteFloat(scale)
			self:MsgEnd()
		end,

		MenuOpen = function(self, option, ent)
			local submenu = option:AddSubMenu()
			submenu:SetMinimumWidth(250)

			local slider = vgui.Create("DNumSlider", submenu)
			slider:SetSize(240, 44)
			slider:SetText("Intensity")
			slider:SetMin(0)
			slider:SetMax(ent.MaxLightScale)
			slider:SetDecimals(1)
			slider:SetValue(ent:GetLightScale())

			slider.OnValueChanged = function(_, value)
				if not IsValid(ent) then return end

				sendThrottled("light_" .. ent:EntIndex(), value, function(v) self:Apply(ent, v) end)
			end

			submenu:AddPanel(slider)
			submenu:AddSpacer()

			for _, preset in ipairs(LIGHT_PRESETS) do
				submenu:AddOption(preset.name, function() self:Apply(ent, preset.scale) end)
			end
		end,

		Action = function() end,

		Receive = function(self, _, ply)
			local ent = readTarget(self, ply)
			local scale = net.ReadFloat()
			if not IsValid(ent) then return end

			ent:SetLightScale(math.Clamp(scale, 0, ent.MaxLightScale))
		end,
	})
end
