-- The Emissary — a stone bench that carries prayers to the gods. Players
-- compose crafted spells here (Form + Essence + Clauses), buy essences, and
-- activate spells carried from other servers.

AddCSLuaFile()

ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "The Emissary"
ENT.Category = "Arcana"
ENT.Spawnable = true
ENT.AdminOnly = false
ENT.RenderGroup = RENDERGROUP_BOTH
ENT.UseCooldown = 0.75

local EMISSARY_MODEL = "models/arcana/bench/bench.mdl"
local GRIMOIRE_MODEL = "models/arcana/grimoire/grimoire.mdl"
local SHELF_MODEL = "models/arcana/shelf/shelf.mdl"

function ENT:SetupDataTables()
	self:NetworkVar("Bool", 0, "EmissaryIsOpen")

	if SERVER then
		self:SetEmissaryIsOpen(false)
	end
end

if SERVER then
	util.AddNetworkString("Arcana_CloseEmissaryMenu")

	resource.AddFile("models/arcana/bench/bench.mdl")
	resource.AddFile("materials/models/arcana/bench/altarstone.vmt")
	resource.AddFile("materials/models/arcana/bench/altarstone.vtf")
	resource.AddFile("materials/models/arcana/bench/altarstone_emissive.vtf")
	resource.AddFile("models/arcana/shelf/shelf.mdl")
	resource.AddFile("materials/models/arcana/shelf/shelf.vmt")
	resource.AddFile("materials/models/arcana/shelf/shelf.vtf")

	function ENT:Initialize()
		self:SetModel(EMISSARY_MODEL)
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
		self._activeUsers = {}
	end

	function ENT:SpawnFunction(ply, tr, classname)
		if not tr or not tr.Hit then return end
		local ent = ents.Create(classname or "arcana_emissary")
		if not IsValid(ent) then return end
		ent:SetPos(tr.HitPos + tr.HitNormal * 2)
		ent:SetAngles(Angle(0, ply:EyeAngles().y, 0))
		ent:Spawn()
		ent:Activate()
		return ent
	end

	function ENT:Use(ply)
		if not IsValid(ply) or not ply:IsPlayer() then return end
		local now = CurTime()
		if now < (self._nextUse or 0) then return end
		self._nextUse = now + self.UseCooldown

		self._activeUsers[ply] = true
		self:SetEmissaryIsOpen(true)

		-- Re-sync activation state (essences, activations, Golden Sun bargain)
		-- before the menu opens, so changes made mid-session are picked up
		-- without a reconnect.
		if Arcana.Spellcraft and Arcana.Spellcraft.SendState then
			Arcana.Spellcraft.SendState(ply)
		end

		net.Start("Arcana_OpenSpellcraftMenu")
		net.WriteEntity(self)
		net.Send(ply)
		self:EmitSound("buttons/button9.wav", 60, 100)
	end

	function ENT:PlayerClosedMenu(ply)
		if self._activeUsers then
			self._activeUsers[ply] = nil
		end

		local hasUsers = false
		for p in pairs(self._activeUsers or {}) do
			if IsValid(p) then
				hasUsers = true
				break
			end
		end

		if not hasUsers then
			self:SetEmissaryIsOpen(false)
		end
	end

	net.Receive("Arcana_CloseEmissaryMenu", function(len, ply)
		local ent = net.ReadEntity()
		if not IsValid(ent) or ent:GetClass() ~= "arcana_emissary" then return end
		ent:PlayerClosedMenu(ply)
	end)

	hook.Add("PlayerDisconnected", "Arcana_EmissaryUserCleanup", function(ply)
		for _, ent in ipairs(ents.FindByClass("arcana_emissary")) do
			if IsValid(ent) then
				ent:PlayerClosedMenu(ply)
			end
		end
	end)
end

if CLIENT then
	local GOLD = Color(222, 198, 120, 255)

	-- Shelves rising in a ring
	local SHELF_COUNT = 8
	local SHELF_RADIUS = 160
	local SHELF_SINK_DEPTH = 420 -- deep in the abyss when hidden, they fade out long before
	local SHELF_RISE_DUR = 1.2
	local SHELF_STAGGER = 0.12
	local SHELF_YAW_OFFSET = 180 -- model-forward correction so shelves face inward
	local SHELF_SCROLL_HEIGHT = 64 -- scroll/band anchor height, mid-board on the shelf mesh

	-- Grimoire resting on and floating above the bench
	-- Bench mesh: desk top z = 30, stele/platform on the -x half, open desk on +x
	local GRIM_REST_POS = Vector(18, 0, 35)
	local GRIM_REST_ANG = Angle(0, 90, 0)
	local GRIM_FLOAT_HEIGHT = 16
	local GRIM_LIFT_DUR = 1.0
	local GRIM_BOB_AMP = 4
	local GRIM_BOB_SPEED = 1.6
	local GRIM_SPIN_RATE = 25 -- deg/sec yaw while floating

	-- One big rune hovering in front of each shelf, facing the grimoire,
	-- drawn through bloom
	local RUNE_CHARS = string.gsub("SCRIPTURE PRAYER COVENANT OATH WORD OFFERING BLESSING", " ", "")
	local RUNE_INWARD_OFFSET = 26 -- hover depth in front of the shelf face
	local BIGRUNE_SCALE = 0.3
	local BIGRUNE_ALPHA = 230
	local BIGRUNE_BOB_AMP = 3
	local BIGRUNE_BOB_SPEED = 1.2

	-- Rune stream flowing from the shelves to the grimoire, through bloom
	local RUNE_RATE = 3 -- spawns/sec per emitting shelf
	local RUNE_MAX = 48
	local RUNE_SPEED = 110
	local RUNE_KILL_DIST = 10
	local RUNE_FADE_IN = 0.2
	local RUNE_FADE_OUT = 0.3
	local RUNE_SPREAD_SIDE = 18 -- lateral spawn spread along the shelf width
	local RUNE_SPREAD_UP = 30 -- vertical spawn spread across the boards
	local RUNE_WOBBLE_AMP = 40 -- sideways sway, damps out near the grimoire
	local RUNE_BURST_MIN, RUNE_BURST_MAX = 1.5, 4 -- seconds a shelf emits
	local RUNE_IDLE_MIN, RUNE_IDLE_MAX = 0.8, 2.5 -- seconds a shelf rests

	-- Additive aura shell around the grimoire while it floats
	local AURA_SCALE = 1.12
	local AURA_ALPHA = 0.5
	local AURA_PULSE = 0.15

	-- Engraved rune glow on the bench (emissive overlay through bloom),
	-- only while the ceremony is ongoing
	local RUNE_GLOW_MAX = 1
	local RUNE_GLOW_PULSE = 0.1

	-- Candle flames, wick tips measured from the bench mesh
	local CANDLE_FLAMES = {
		Vector(-3, 10, 46),
		Vector(-2.3, -12.5, 48),
	}
	local FLAME_CORE_COLOR = Color(255, 200, 120, 255)
	local FLAME_HALO_COLOR = Color(255, 150, 60, 70)

	local AMBIENT_SOUND = "ambient/atmosphere/tone_quiet.wav"
	local AMBIENT_VOLUME = 0.55

	-- Tear to Elysion under the ceremony. The jagged rim must stay outside
	-- the shelf ring (~177 units to a shelf's outer corner) at its narrowest
	local TEAR_RADIUS = 320
	local TEAR_POINTS = 18
	local TEAR_STRETCH = 1.15 -- widens one axis, an elongated rip rather than a disc
	local TEAR_OPEN_DUR = 0.7
	local ABYSS_ROCK_DEPTH = 430 -- how far the rock mass converges below the cap
	local ABYSS_VOID_COLOR = Color(6, 3, 14)
	local ABYSS_CAP_RADIUS = 130 -- flat stone top holding the bench above the void
	local ABYSS_CAP_TEXTURE = "models/props_foliage/coastrock02"
	local ABYSS_CAP_BRIGHTNESS = 1 -- extra gain on the sampled light, tune to match the bench
	local SHELF_FADE_RANGE = 300 -- shelves dissolve into the abyss past this depth

	local sparkMat = Material("sprites/light_glow02_add")

	local auraMat
	local function getAuraMat()
		if auraMat then return auraMat end

		auraMat = CreateMaterial("arcana_emissary_grim_aura", "UnlitGeneric", {
			["$basetexture"] = "models/debug/debugwhite",
			["$model"] = 1,
			["$additive"] = 1,
			["$nocull"] = 1,
		})

		return auraMat
	end

	local benchGlowMat
	local function getBenchGlowMat()
		if benchGlowMat then return benchGlowMat end

		benchGlowMat = CreateMaterial("arcana_emissary_bench_glow", "UnlitGeneric", {
			["$basetexture"] = "models/arcana/bench/altarstone_emissive",
			["$model"] = 1,
			["$additive"] = 1,
		})

		return benchGlowMat
	end

	-- Reuse the tutorial's Elysion skybox wholesale (materials, face layout,
	-- UV rotations) so the cube connects exactly like it does in the scenes
	local function getSkyFaces()
		local Tutorial = Arcana.Tutorial
		if not Tutorial then return end

		if not Tutorial.cubeFaces then
			Tutorial:InitializeSkybox()
			Tutorial:CreateCubeMesh()
		end

		return Tutorial.cubeFaces
	end

	local function drawAbyssSky(eyePos)
		local faces = getSkyFaces()
		if not faces then return end

		render.SetLightingMode(2)
		render.OverrideDepthEnable(true, false)
		render.PushFilterMin(TEXFILTER.LINEAR)
		render.PushFilterMag(TEXFILTER.LINEAR)

		for _, face in ipairs(faces) do
			if face.material and not face.material:IsError() then
				render.SetMaterial(face.material)
				mesh.Begin(MATERIAL_QUADS, 1)

				for i = 1, 4 do
					local vert = face.vertices[i]
					mesh.Position(eyePos + vert.pos)
					mesh.TexCoord(0, vert.u, vert.v)
					mesh.Color(255, 255, 255, 255)
					mesh.AdvanceVertex()
				end

				mesh.End()
			end
		end

		render.PopFilterMin()
		render.PopFilterMag()
		render.OverrideDepthEnable(false, false)
		render.SetLightingMode(0)
	end

	-- Stencil mask material: $ignorez so the tear punches through slopes and
	-- any world geometry above its plane
	local tearMaskMat
	local function getTearMaskMat()
		if tearMaskMat then return tearMaskMat end

		tearMaskMat = CreateMaterial("arcana_emissary_tear_mask", "UnlitGeneric", {
			["$basetexture"] = "vgui/white",
			["$ignorez"] = 1,
			["$nocull"] = 1,
			["$vertexcolor"] = 1,
		})

		return tearMaskMat
	end

	local capMat
	local function getCapMat()
		if capMat then return capMat end

		capMat = CreateMaterial("arcana_emissary_abyss_cap", "UnlitGeneric", {
			["$vertexcolor"] = 1,
		})

		-- $basetexture wants a texture, not a material: steal the actual
		-- texture from the stock rock material rather than guessing its path
		local src = Material(ABYSS_CAP_TEXTURE)

		if src and not src:IsError() then
			local tex = src:GetTexture("$basetexture")

			if tex then
				capMat:SetTexture("$basetexture", tex)
			end
		end

		return capMat
	end

	function ENT:Initialize()
		self._animState = "closed" -- "closed", "opening", "open", "closing"
		self._wasOpen = nil -- nil = snap on first Think (late joiners)
		self._openStartTime = 0
		self._lastThink = CurTime()
		self._shelfFrac = {}

		for i = 1, SHELF_COUNT do
			self._shelfFrac[i] = 0
		end

		self._grimFrac = 0
		self._grimSpin = 0
		self._grimWorldPos = self:LocalToWorld(GRIM_REST_POS)
		self._shelves = {}
		self._runes = {}
		self._shelfEmit = {}

		-- One stable random rune character per shelf
		self._shelfRuneChars = {}

		for i = 1, SHELF_COUNT do
			local idx = math.random(1, #RUNE_CHARS)
			self._shelfRuneChars[i] = string.sub(RUNE_CHARS, idx, idx)
		end

		self._ambient = nil

		self._grimoire = ClientsideModel(GRIMOIRE_MODEL)
		if IsValid(self._grimoire) then
			self._grimoire:SetPos(self._grimWorldPos)
			self._grimoire._arcanaCeremonyProp = true
		end

		self._grimAura = ClientsideModel(GRIMOIRE_MODEL)
		if IsValid(self._grimAura) then
			self._grimAura:SetNoDraw(true)
			self._grimAura:SetModelScale(AURA_SCALE)
			self._grimAura._arcanaCeremonyProp = true
		end

		-- Tear to Elysion: jagged rip shape, generated once per entity
		self._tearFrac = 0
		self._tearYaw = math.Rand(0, 360)
		self._tearShape = {}

		for i = 1, TEAR_POINTS do
			local a = (i / TEAR_POINTS) * math.pi * 2
			local jag = math.Rand(0.75, 1)

			-- pull alternating vertices inward for a ripped edge
			if i % 2 == 0 then
				jag = jag * math.Rand(0.85, 0.95)
			end

			self._tearShape[i] = {
				x = math.cos(a) * TEAR_RADIUS * TEAR_STRETCH * jag,
				y = math.sin(a) * TEAR_RADIUS * jag,
			}
		end

		-- Flat stone cap the bench stands on, jagged like the tear rim
		self._capShape = {}

		for i = 1, TEAR_POINTS do
			local a = (i / TEAR_POINTS) * math.pi * 2
			local jag = math.Rand(0.82, 1)

			self._capShape[i] = {
				x = math.cos(a) * ABYSS_CAP_RADIUS * jag,
				y = math.sin(a) * ABYSS_CAP_RADIUS * jag,
			}
		end

		self:_BuildAbyssRockMesh()

		self._groundPos = self:GetPos()

		-- The ceremony spans well past the bench's own bounds, abyss included.
		-- Vertical extent is refreshed in Think from the actual ground drop
		local r = math.max(SHELF_RADIUS, TEAR_RADIUS * TEAR_STRETCH) + 60
		self._boundsRadius = r
		self:SetRenderBounds(Vector(-r, -r, -700), Vector(r, r, 150))
	end

	function ENT:OnRemove()
		if IsValid(self._grimoire) then
			self._grimoire:Remove()
		end

		self._grimoire = nil

		if IsValid(self._grimAura) then
			self._grimAura:Remove()
		end

		self._grimAura = nil

		if self._rockMesh then
			self._rockMesh:Destroy()
			self._rockMesh = nil
		end

		if self._ambient then
			self._ambient:Stop()
			self._ambient = nil
		end

		for _, shelf in pairs(self._shelves or {}) do
			if IsValid(shelf) then
				shelf:Remove()
			end
		end

		self._shelves = {}
	end

	function ENT:Draw()
		self:DrawModel()
	end

	local function easeOutCubic(f)
		return 1 - math.pow(1 - f, 3)
	end

	-- Move a fraction toward its target at a fixed rate so reversal from any
	-- mid-point just retargets, preserving current progress
	local function moveFrac(current, target, dt, duration)
		local step = dt / math.max(0.01, duration)

		if current < target then
			return math.min(target, current + step)
		end

		return math.max(target, current - step)
	end

	-- The whole ceremony projects onto the ground below the entity, so a
	-- dragged-up bench still tears the floor open underneath it
	function ENT:_GroundPos()
		return self._groundPos or self:GetPos()
	end

	function ENT:_ShelfGroundPos(i)
		local yaw = self:GetAngles().y + (i - 1) * (360 / SHELF_COUNT)

		return self:_GroundPos() + Angle(0, yaw, 0):Forward() * SHELF_RADIUS, yaw
	end

	function ENT:_EnsureShelves()
		for i = 1, SHELF_COUNT do
			if not IsValid(self._shelves[i]) then
				local shelf = ClientsideModel(SHELF_MODEL)

				if IsValid(shelf) then
					shelf:SetNoDraw(true)
					shelf._arcanaCeremonyProp = true
					self._shelves[i] = shelf
				end
			end
		end
	end

	function ENT:_SpawnRune(i)
		if #self._runes >= RUNE_MAX then return end
		local now = CurTime()
		local groundPos, yaw = self:_ShelfGroundPos(i)
		local ang = Angle(0, yaw, 0)
		local pos = groundPos
			- ang:Forward() * (RUNE_INWARD_OFFSET * math.Rand(0.4, 1))
			+ ang:Right() * math.Rand(-RUNE_SPREAD_SIDE, RUNE_SPREAD_SIDE)
			+ Vector(0, 0, SHELF_SCROLL_HEIGHT + math.Rand(-RUNE_SPREAD_UP, RUNE_SPREAD_UP))
		local charIndex = math.random(1, #RUNE_CHARS)

		self._runes[#self._runes + 1] = {
			pos = pos,
			born = now,
			dieAt = now + 6, -- safety cap; runes die on arrival
			char = string.sub(RUNE_CHARS, charIndex, charIndex),
			alpha = math.random(150, 230),
			speed = RUNE_SPEED * math.Rand(0.7, 1.3),
			wobbleAmp = RUNE_WOBBLE_AMP * math.Rand(0.3, 1),
			wobbleFreq = math.Rand(2, 5),
			wobblePhase = math.Rand(0, math.pi * 2),
		}
	end

	function ENT:_UpdateRunes(dt)
		local now = CurTime()

		-- A random subset of shelves emits at any moment: each shelf flips
		-- between an emitting burst and a rest on its own randomized clock.
		-- Spawn only while fully open and the grimoire has lifted off.
		if self._animState == "open" and self._grimFrac > 0.3 then
			for i = 1, SHELF_COUNT do
				local em = self._shelfEmit[i]

				if not em then
					em = {active = false, switchAt = now + math.Rand(0, RUNE_IDLE_MAX), accum = 0}
					self._shelfEmit[i] = em
				end

				if now >= em.switchAt then
					em.active = not em.active
					em.switchAt = now + (em.active and math.Rand(RUNE_BURST_MIN, RUNE_BURST_MAX) or math.Rand(RUNE_IDLE_MIN, RUNE_IDLE_MAX))
				end

				if em.active then
					em.accum = em.accum + RUNE_RATE * dt
					local toSpawn = math.floor(em.accum)
					em.accum = em.accum - toSpawn

					for _ = 1, toSpawn do
						self:_SpawnRune(i)
					end
				end
			end
		else
			self._shelfEmit = {}
		end

		-- Home toward the grimoire with a damped sway, compact-in-place cull
		local target = self._grimWorldPos
		local write = 1

		for read = 1, #self._runes do
			local p = self._runes[read]
			local keep = false

			if p and now < (p.dieAt or 0) then
				local toTarget = target - p.pos
				local dist = toTarget:Length()

				if dist > RUNE_KILL_DIST then
					local dir = toTarget / dist
					local right = dir:Angle():Right()
					local sway = right * math.sin(now * (p.wobbleFreq or 3) + (p.wobblePhase or 0))
						+ vector_up * (0.5 * math.cos(now * (p.wobbleFreq or 3) * 0.8 + (p.wobblePhase or 0)))
					-- Sway fades out on approach so runes still land in the book
					local damp = math.Clamp(dist / 60, 0, 1)
					p.pos = p.pos + dir * math.min((p.speed or RUNE_SPEED) * dt, dist) + sway * ((p.wobbleAmp or 0) * damp * dt)
					keep = true
				end
			end

			if keep then
				self._runes[write] = p
				write = write + 1
			end
		end

		for i = write, #self._runes do
			self._runes[i] = nil
		end
	end

	function ENT:Think()
		local now = CurTime()
		local dt = math.Clamp(now - (self._lastThink or now), 0, 0.1)
		self._lastThink = now

		-- Anchor the ceremony to the ground below, wherever the bench is
		local tr = util.TraceLine({
			start = self:GetPos() + Vector(0, 0, 10),
			endpos = self:GetPos() - Vector(0, 0, 4000),
			mask = MASK_SOLID,
			filter = self,
			collisiongroup = COLLISION_GROUP_WEAPON,
		})

		self._groundPos = tr.Hit and tr.HitPos or self:GetPos()

		-- Keep render bounds covering the drop to the ground plus the abyss
		local drop = (self:GetPos().z - self._groundPos.z) + ABYSS_ROCK_DEPTH + 120
		local r = self._boundsRadius or 400
		self:SetRenderBounds(Vector(-r, -r, -math.max(700, drop)), Vector(r, r, 150))

		local isOpen = self:GetEmissaryIsOpen()

		if self._wasOpen == nil then
			-- First think: snap to the correct end state without animating
			-- (handles late-joining clients)
			self._wasOpen = isOpen

			if isOpen then
				self._animState = "open"

				for i = 1, SHELF_COUNT do
					self._shelfFrac[i] = 1
				end

				self._grimFrac = 1
				self._tearFrac = 1
				self._tearOpenedAt = now
				self:_EnsureShelves()
			else
				self._animState = "closed"
			end
		elseif isOpen ~= self._wasOpen then
			self._wasOpen = isOpen

			if isOpen then
				if self._animState == "closed" or self._animState == "closing" then
					self._animState = "opening"
					self._openStartTime = now
					self._tearOpenedAt = nil
					self:_EnsureShelves()
				end
			else
				if self._animState == "open" or self._animState == "opening" then
					self._animState = "closing"

					-- Live runes fade out quickly instead of vanishing
					for _, p in ipairs(self._runes) do
						p.dieAt = math.min(p.dieAt or now, now + RUNE_FADE_OUT)
					end
				end
			end
		end

		local state = self._animState

		-- Fraction updates
		if state == "opening" then
			local allUp = true

			for i = 1, SHELF_COUNT do
				-- Shelves only start rising once the tear is fully open
				local gate = self._tearOpenedAt and (self._tearOpenedAt + (i - 1) * SHELF_STAGGER) or math.huge

				if now >= gate then
					local prev = self._shelfFrac[i]
					self._shelfFrac[i] = moveFrac(prev, 1, dt, SHELF_RISE_DUR)

					-- Chime as each shelf locks into place
					if prev < 1 and self._shelfFrac[i] >= 1 then
						local shelfPos = self:_ShelfGroundPos(i)
						sound.Play("arcana/arcane_" .. math.random(1, 3) .. ".ogg", shelfPos, 70, math.random(96, 108), 0.5)
					end
				end

				if self._shelfFrac[i] < 1 then
					allUp = false
				end
			end

			if allUp then
				self._animState = "open"
			end
		elseif state == "open" then
			self._grimFrac = moveFrac(self._grimFrac, 1, dt, GRIM_LIFT_DUR)
		elseif state == "closing" then
			self._grimFrac = moveFrac(self._grimFrac, 0, dt, GRIM_LIFT_DUR)
			local allDown = self._grimFrac <= 0

			for i = 1, SHELF_COUNT do
				self._shelfFrac[i] = moveFrac(self._shelfFrac[i], 0, dt, SHELF_RISE_DUR)

				if self._shelfFrac[i] > 0 then
					allDown = false
				end
			end

			if allDown then
				self._animState = "closed"
			end
		end

		-- The tear opens ahead of the shelves and stays open while they sink
		-- back into it; once everything is down it closes last
		local tearOpen = self._animState ~= "closed"
		self._tearFrac = moveFrac(self._tearFrac or 0, tearOpen and 1 or 0, dt, TEAR_OPEN_DUR)

		if not self._tearOpenedAt and self._tearFrac >= 1 then
			self._tearOpenedAt = now
		end

		-- Apply shelf transforms; the models stay NoDraw and are drawn manually
		-- in DrawTranslucent so their buried halves show through the tear
		for i = 1, SHELF_COUNT do
			local shelf = self._shelves[i]

			if IsValid(shelf) then
				local f = self._shelfFrac[i]

				if f > 0 then
					local groundPos, yaw = self:_ShelfGroundPos(i)
					local e = easeOutCubic(f)
					shelf:SetPos(groundPos - Vector(0, 0, SHELF_SINK_DEPTH * (1 - e)))
					shelf:SetAngles(Angle(0, yaw + SHELF_YAW_OFFSET, 0))
				end
			end
		end

		-- Grimoire: rests on the bench at 0, floats and slowly spins at 1
		local g = easeOutCubic(self._grimFrac)
		local restPos = self:LocalToWorld(GRIM_REST_POS)
		local restAng = self:LocalToWorldAngles(GRIM_REST_ANG)
		local lift = GRIM_FLOAT_HEIGHT * g + math.sin(now * GRIM_BOB_SPEED) * GRIM_BOB_AMP * g
		self._grimSpin = (self._grimSpin + GRIM_SPIN_RATE * dt * g) % 360
		self._grimWorldPos = restPos + self:GetUp() * lift

		if IsValid(self._grimoire) then
			local ang = Angle(restAng.p, restAng.y, restAng.r)
			ang:RotateAroundAxis(self:GetUp(), self._grimSpin)
			self._grimoire:SetPos(self._grimWorldPos)
			self._grimoire:SetAngles(ang)
		end

		-- Aura shell shadows the grimoire
		if IsValid(self._grimAura) and IsValid(self._grimoire) then
			self._grimAura:SetPos(self._grimoire:GetPos())
			self._grimAura:SetAngles(self._grimoire:GetAngles())
		end

		self:_UpdateRunes(dt)

		-- Ambient loop while the emissary is engaged
		if isOpen then
			if not self._ambient then
				self._ambient = CreateSound(self, AMBIENT_SOUND)
				self._ambient:PlayEx(0, 100)
				self._ambient:SetSoundLevel(70)
			end

			if (self._ambVol or 0) ~= AMBIENT_VOLUME then
				self._ambVol = AMBIENT_VOLUME
				self._ambient:ChangeVolume(AMBIENT_VOLUME, 1.5)
			end
		elseif self._ambient then
			self._ambient:FadeOut(1.5)
			self._ambient = nil
			self._ambVol = 0
		end

		-- Warm candle light over the platform, flickering gently
		local dl = DynamicLight(self:EntIndex())

		if dl then
			dl.pos = self:LocalToWorld(Vector(-2, -2, 54))
			dl.r = 255
			dl.g = 170
			dl.b = 90
			dl.brightness = 0.55 + 0.12 * math.sin(now * 9) + 0.05 * math.sin(now * 21)
			dl.Decay = 1000
			dl.Size = 140
			dl.DieTime = now + 0.1
		end

	end

	function ENT:_DrawShelves()
		for i = 1, SHELF_COUNT do
			local shelf = self._shelves and self._shelves[i]
			local f = self._shelfFrac[i] or 0

			if IsValid(shelf) and f > 0 then
				-- Deep shelves dissolve into the abyss instead of popping in
				local below = SHELF_SINK_DEPTH * (1 - easeOutCubic(f))
				local alpha = 1 - math.Clamp(below / SHELF_FADE_RANGE, 0, 1)

				if alpha > 0 then
					render.SetBlend(alpha)
					shelf:DrawModel()
					render.SetBlend(1)
				end
			end
		end
	end

	-- The rock mass under the pedestal: top ring is exactly the cap polygon,
	-- shrinking jittered rings converge to an apex deep in the void. Built
	-- once, in entity-local space (translated to the entity at draw time).
	-- Purple gradient is baked into the vertex colors, brighter toward the
	-- bottom where the nebula glows
	function ENT:_BuildAbyssRockMesh()
		if self._rockMesh then
			self._rockMesh:Destroy()
			self._rockMesh = nil
		end

		local pts = self._capShape
		if not pts or #pts < 3 then return end

		local ang = Angle(0, self._tearYaw or 0, 0)
		local fwd = ang:Forward()
		local right = ang:Right()
		local n = #pts

		local ringDefs = {
			{scale = 1, z = -2, jitter = false, r = 88, g = 72, b = 116},
			{scale = 0.8, z = -ABYSS_ROCK_DEPTH * 0.3, jitter = true, r = 106, g = 84, b = 140},
			{scale = 0.52, z = -ABYSS_ROCK_DEPTH * 0.62, jitter = true, r = 126, g = 98, b = 166},
		}

		local rings = {}

		for ri, def in ipairs(ringDefs) do
			local ring = {}

			for i = 1, n do
				local p = pts[i]
				local jitter = def.jitter and math.Rand(0.85, 1.15) or 1
				local zJitter = def.jitter and math.Rand(-18, 18) or 0

				ring[i] = {
					pos = fwd * (p.x * def.scale * jitter) + right * (p.y * def.scale * jitter) + Vector(0, 0, def.z + zJitter),
					r = def.r,
					g = def.g,
					b = def.b,
				}
			end

			rings[ri] = ring
		end

		local apex = {
			pos = Vector(math.Rand(-20, 20), math.Rand(-20, 20), -ABYSS_ROCK_DEPTH),
			r = 148,
			g = 116,
			b = 188,
		}

		local function vert(v, u, vv)
			mesh.Position(v.pos)
			mesh.Color(v.r, v.g, v.b, 255)
			mesh.TexCoord(0, u, vv)
			mesh.AdvanceVertex()
		end

		self._rockMesh = Mesh()
		mesh.Begin(self._rockMesh, MATERIAL_TRIANGLES, n * 2 * (#rings - 1) + n)

		for ri = 1, #rings - 1 do
			local a, b = rings[ri], rings[ri + 1]

			for i = 1, n do
				local j = i % n + 1
				local u1 = (i - 1) / n * 4
				local u2 = i / n * 4

				vert(a[i], u1, ri)
				vert(b[i], u1, ri + 1)
				vert(b[j], u2, ri + 1)

				vert(a[i], u1, ri)
				vert(b[j], u2, ri + 1)
				vert(a[j], u2, ri)
			end
		end

		local last = rings[#rings]

		for i = 1, n do
			local j = i % n + 1
			vert(last[i], (i - 1) / n * 4, #rings)
			vert(apex, (i - 0.5) / n * 4, #rings + 1)
			vert(last[j], i / n * 4, #rings)
		end

		mesh.End()
	end

	-- The flat stone top of the abyss pedestal, lit by sampling the world
	-- light where the bench stands so it matches a real prop's top surface
	function ENT:_DrawAbyssCap()
		local pts = self._capShape
		if not pts or #pts < 3 then return end

		local center = self:_GroundPos() + Vector(0, 0, -2)

		-- ComputeLighting returns linear-space light, but lit props are
		-- displayed after gamma correction: convert (^1/2.2) so the cap
		-- reads as bright as the bench standing in the same light
		local light = render.ComputeLighting(self:_GroundPos() + Vector(0, 0, 8), vector_up)
		local r = math.Clamp(math.pow(math.max(light.x, 0), 0.4545) * ABYSS_CAP_BRIGHTNESS * 255, 16, 255)
		local g = math.Clamp(math.pow(math.max(light.y, 0), 0.4545) * ABYSS_CAP_BRIGHTNESS * 255, 16, 255)
		local b = math.Clamp(math.pow(math.max(light.z, 0), 0.4545) * ABYSS_CAP_BRIGHTNESS * 255, 16, 255)

		local ang = Angle(0, self._tearYaw or 0, 0)
		local fwd = ang:Forward()
		local right = ang:Right()
		local n = #pts
		render.SetMaterial(getCapMat())
		mesh.Begin(MATERIAL_TRIANGLES, n * 2)

		for i = 1, n do
			local p1 = pts[i]
			local p2 = pts[i % n + 1]
			local v1 = center + fwd * p1.x + right * p1.y
			local v2 = center + fwd * p2.x + right * p2.y

			mesh.Position(center)
			mesh.Color(r, g, b, 255)
			mesh.TexCoord(0, center.x / 128, center.y / 128)
			mesh.AdvanceVertex()
			mesh.Position(v1)
			mesh.Color(r, g, b, 255)
			mesh.TexCoord(0, v1.x / 128, v1.y / 128)
			mesh.AdvanceVertex()
			mesh.Position(v2)
			mesh.Color(r, g, b, 255)
			mesh.TexCoord(0, v2.x / 128, v2.y / 128)
			mesh.AdvanceVertex()

			mesh.Position(center)
			mesh.Color(r, g, b, 255)
			mesh.TexCoord(0, center.x / 128, center.y / 128)
			mesh.AdvanceVertex()
			mesh.Position(v2)
			mesh.Color(r, g, b, 255)
			mesh.TexCoord(0, v2.x / 128, v2.y / 128)
			mesh.AdvanceVertex()
			mesh.Position(v1)
			mesh.Color(r, g, b, 255)
			mesh.TexCoord(0, v1.x / 128, v1.y / 128)
			mesh.AdvanceVertex()
		end

		mesh.End()
	end

	-- Rasterize the tear polygon (triangle fan, both windings so backface
	-- culling cannot drop it whichever side the camera is on)
	function ENT:_DrawTearShape(center, scale)
		local pts = self._tearShape
		if not pts or #pts < 3 then return end

		local ang = Angle(0, self._tearYaw or 0, 0)
		local fwd = ang:Forward()
		local right = ang:Right()
		local n = #pts
		render.SetMaterial(getTearMaskMat())
		mesh.Begin(MATERIAL_TRIANGLES, n * 2)

		for i = 1, n do
			local p1 = pts[i]
			local p2 = pts[i % n + 1]
			local v1 = center + (fwd * p1.x + right * p1.y) * scale
			local v2 = center + (fwd * p2.x + right * p2.y) * scale

			mesh.Position(center)
			mesh.Color(255, 255, 255, 255)
			mesh.AdvanceVertex()
			mesh.Position(v1)
			mesh.Color(255, 255, 255, 255)
			mesh.AdvanceVertex()
			mesh.Position(v2)
			mesh.Color(255, 255, 255, 255)
			mesh.AdvanceVertex()

			mesh.Position(center)
			mesh.Color(255, 255, 255, 255)
			mesh.AdvanceVertex()
			mesh.Position(v2)
			mesh.Color(255, 255, 255, 255)
			mesh.AdvanceVertex()
			mesh.Position(v1)
			mesh.Color(255, 255, 255, 255)
			mesh.AdvanceVertex()
		end

		mesh.End()
	end

	function ENT:DrawTranslucent()
		local now = CurTime()

		-- Tear to Elysion: stencil out the rip, void the ground inside it,
		-- then show the nebula and the rock mass hanging in the abyss
		local tf = easeOutCubic(self._tearFrac or 0)

		if tf > 0.01 and self._tearShape then
			local center = self:_GroundPos() + Vector(0, 0, 1)

			render.SetStencilEnable(true)
			render.ClearStencil()
			render.SetStencilWriteMask(255)
			render.SetStencilTestMask(255)
			render.SetStencilReferenceValue(1)
			render.SetStencilCompareFunction(STENCIL_ALWAYS)
			render.SetStencilPassOperation(STENCIL_REPLACE)
			render.SetStencilFailOperation(STENCIL_KEEP)
			render.SetStencilZFailOperation(STENCIL_KEEP)

			-- Mask pass: no color writes and no depth test (the mask material
			-- is $ignorez), so the tear stencils its full projection even
			-- where sloped ground rises above its plane
			render.OverrideColorWriteEnable(true, false)
			render.OverrideAlphaWriteEnable(true, false)
			self:_DrawTearShape(center, tf)
			render.OverrideAlphaWriteEnable(false, false)
			render.OverrideColorWriteEnable(false, false)

			-- Inside the tear: void out the ground and its depth
			render.SetStencilCompareFunction(STENCIL_EQUAL)
			render.SetStencilPassOperation(STENCIL_KEEP)
			render.ClearBuffersObeyStencil(ABYSS_VOID_COLOR.r, ABYSS_VOID_COLOR.g, ABYSS_VOID_COLOR.b, 255, true)

			drawAbyssSky(EyePos())

			-- The rock mass under the cap: its rim continues the cap's edge
			-- and converges down into the void. Drawn with both cull modes so
			-- it reads solid from every angle
			if self._rockMesh then
				local m = Matrix()
				m:SetTranslation(self:_GroundPos())
				render.SetMaterial(getCapMat())
				cam.PushModelMatrix(m)
				self._rockMesh:Draw()
				render.CullMode(MATERIAL_CULLMODE_CW)
				self._rockMesh:Draw()
				render.CullMode(MATERIAL_CULLMODE_CCW)
				cam.PopModelMatrix()
			end

			-- The pedestal's flat stone top, drawn over the rock mass
			self:_DrawAbyssCap()

			-- The void clear erased everything standing inside the tear's
			-- projection, so the station itself is redrawn in the stencil
			self:DrawModel()

			if IsValid(self._grimoire) then
				self._grimoire:DrawModel()
			end

			-- Shelves inside the stencil: their buried halves exist only
			-- through the tear, never bleeding past its silhouette
			self:_DrawShelves()

			render.SetStencilEnable(false)
		end

		-- Shelves again without the stencil for their above-ground halves;
		-- ground depth hides whatever is still buried
		self:_DrawShelves()

		-- Engraved bench runes and the grimoire aura share one bloom capture:
		-- both are additive gold overlays whose glow carries their shape.
		-- They exist only while the ceremony runs (the tear or the grimoire
		-- lift is in some state of progress)
		local g = easeOutCubic(self._grimFrac or 0)
		local ceremony = math.max(g, tf)

		if ceremony > 0.01 then
			local auraVisible = g > 0 and IsValid(self._grimAura)

			Arcana.Bloom.ProcessBloom(function()
				local runePulse = 1 + RUNE_GLOW_PULSE * math.sin(now * 1.7)
				render.MaterialOverride(getBenchGlowMat())
				render.SetColorModulation(GOLD.r / 255, GOLD.g / 255, GOLD.b / 255)
				render.SetBlend(RUNE_GLOW_MAX * ceremony * runePulse)
				self:DrawModel()

				if auraVisible then
					local pulse = 1 + AURA_PULSE * math.sin(now * 2.4)
					render.MaterialOverride(getAuraMat())
					render.SetBlend(AURA_ALPHA * g * pulse)
					self._grimAura:DrawModel()
				end

				render.SetBlend(1)
				render.SetColorModulation(1, 1, 1)
				render.MaterialOverride()

				-- One big rune before each shelf, upright, facing the
				-- grimoire, fading with the shelf's depth in the abyss
				surface.SetFont("MagicCircle_Large")

				for i = 1, SHELF_COUNT do
					local f = self._shelfFrac and self._shelfFrac[i] or 0

					if f > 0 then
						local below = SHELF_SINK_DEPTH * (1 - easeOutCubic(f))
						local alpha = math.floor((1 - math.Clamp(below / SHELF_FADE_RANGE, 0, 1)) * BIGRUNE_ALPHA)

						if alpha > 0 then
							local groundPos, yaw = self:_ShelfGroundPos(i)
							local pos = groundPos - Vector(0, 0, below)
								- Angle(0, yaw, 0):Forward() * RUNE_INWARD_OFFSET
								+ Vector(0, 0, SHELF_SCROLL_HEIGHT + math.sin(now * BIGRUNE_BOB_SPEED + i * 1.3) * BIGRUNE_BOB_AMP)
							local ang = (self._grimWorldPos - pos):GetNormalized():Angle()
							ang:RotateAroundAxis(ang:Right(), -90)
							ang:RotateAroundAxis(ang:Up(), 90)
							local ch = self._shelfRuneChars and self._shelfRuneChars[i] or "A"
							local w, h = surface.GetTextSize(ch)
							cam.Start3D2D(pos, ang, BIGRUNE_SCALE)
							surface.SetTextColor(GOLD.r, GOLD.g, GOLD.b, alpha)
							surface.SetTextPos(-w * 0.5, -h * 0.5)
							surface.DrawText(ch)
							cam.End3D2D()
						end
					end
				end

				-- Rune stream flowing to the grimoire, one shared billboard
				-- angle, altar-style
				if self._runes and #self._runes > 0 then
					local streamAng = (EyePos() - self:GetPos()):GetNormalized():Angle()
					streamAng:RotateAroundAxis(streamAng:Right(), -90)
					streamAng:RotateAroundAxis(streamAng:Up(), 90)

					surface.SetFont("MagicCircle_Medium")

					for _, p in ipairs(self._runes) do
						local fadeIn = math.Clamp((now - (p.born or now)) / RUNE_FADE_IN, 0, 1)
						local fadeOut = math.Clamp(((p.dieAt or now) - now) / RUNE_FADE_OUT, 0, 1)
						local alpha = math.floor((p.alpha or 180) * fadeIn * fadeOut)

						if alpha > 0 then
							local w, h = surface.GetTextSize(p.char or "")
							cam.Start3D2D(p.pos, streamAng, 0.06)
							surface.SetTextColor(GOLD.r, GOLD.g, GOLD.b, alpha)
							surface.SetTextPos(-w * 0.5, -h * 0.5)
							surface.DrawText(p.char or "")
							cam.End3D2D()
						end
					end
				end
			end)

			Arcana.Bloom.RenderBloom()
		end

		-- Candle flames on the platform, flickering on two mixed frequencies
		render.SetMaterial(sparkMat)

		for i, off in ipairs(CANDLE_FLAMES) do
			local fpos = self:LocalToWorld(off)
			local flick = 0.85 + 0.15 * math.sin(now * 9 + i * 3.7) + 0.08 * math.sin(now * 23 + i * 7.1)
			render.DrawSprite(fpos, 6 * flick, 9 * flick, FLAME_CORE_COLOR)
			render.DrawSprite(fpos, 16 * flick, 16 * flick, FLAME_HALO_COLOR)
		end
	end
end
