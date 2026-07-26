AddCSLuaFile()
ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "Fae Lantern"
ENT.Category = "Arcana"
ENT.Spawnable = true
-- Opaque only: the model is solid and the glow is drawn by the bloom pass, so a
-- translucent pass would just draw the model a second time.
ENT.RenderGroup = RENDERGROUP_OPAQUE
ENT.Author = "Earu"

ENT.LanternModel = "models/props/cs_italy/it_lantern2.mdl"

-- Submaterial 0 is models/cs_italy/light_orange, the glass panes. Its mesh is
-- centered on the entity origin (+-6.9 x +-6.4 x +-5), so the origin doubles as
-- the light position.
ENT.GlassMaterialIndex = 0
ENT.GlassSubMaterial = "models/cs_italy/light_orange"

ENT.DefaultLightColor = Color(255, 190, 110)
ENT.MaxBrightness = 3

function ENT:SetLightColor(col)
	self:SetLightColorPacked(Arcana.Common.PackColor(col))
end

function ENT:GetLightColor()
	return Arcana.Common.UnpackColor(self:GetLightColorPacked())
end

function ENT:SetupDataTables()
	self:NetworkVar("Float", 0, "Brightness")
	self:NetworkVar("Int", 0, "LightColorPacked")

	if SERVER then
		self:SetBrightness(1)
		self:SetLightColor(self.DefaultLightColor)
	end
end

if SERVER then
	function ENT:Initialize()
		self:SetModel(self.LanternModel)
		self:PhysicsInit(SOLID_VPHYSICS)
		self:SetMoveType(MOVETYPE_VPHYSICS)
		self:SetSolid(SOLID_VPHYSICS)

		local phys = self:GetPhysicsObject()
		if IsValid(phys) then
			phys:Wake()
			phys:EnableGravity(false)
		end
	end

	function ENT:SpawnFunction(ply, tr, classname)
		if not tr or not tr.Hit then return end

		local ent = ents.Create(classname or "arcana_fae_lantern")
		if not IsValid(ent) then return end

		-- Lift it clear of the surface so the physics box does not spawn stuck
		ent:SetPos(tr.HitPos + tr.HitNormal * 14)
		ent:SetAngles(Angle(0, ply:EyeAngles().y, 0))
		ent:Spawn()
		ent:Activate()

		return ent
	end
end

if CLIENT then
	-- Each lantern owns its two materials. A single shared pair re-tinted per draw
	-- lets lanterns of different colors swap tints depending on draw order, which
	-- reads as the color changing on its own.
	-- Tinting goes through $color2: $color is silently ignored by this shader
	-- (verified in game -- panes stay pure white no matter what it is set to).
	local function createMaterials(index)
		-- The lit panes: fullbright white, tinted to the lantern's color.
		local pane = CreateMaterial("arcana_fae_lantern_pane_" .. index, "UnlitGeneric", {
			["$basetexture"] = "models/debug/debugwhite",
			["$model"] = 1,
			["$nocull"] = 1,
			["$color2"] = "[1 1 1]",
		})

		-- Same panes drawn additively during the bloom pass. The bloom captures
		-- (screen after - screen before), so the added light IS the bloom source,
		-- and it carries the panes' shape rather than a generic sprite blob.
		-- No $model here: this one is bound for a raw IMesh draw, not a studio
		-- model, and with $model set its $color2 is ignored and the panes add
		-- plain white. Tinting must go through $color2 -- render.SetColorModulation
		-- does not apply on the mesh path (both verified in game).
		local bloom = CreateMaterial("arcana_fae_lantern_bloom_" .. index, "UnlitGeneric", {
			["$basetexture"] = "models/debug/debugwhite",
			["$nocull"] = 1,
			["$additive"] = 1,
			["$color2"] = "[1 1 1]",
		})

		return pane, bloom
	end

	local glassTint = Vector(1, 1, 1)
	local VECTOR_ZERO = Vector(0, 0, 0)

	-- Motes leave the lamp within this many degrees of horizontal
	local MOTE_PITCH = 25

	-- Gearing on the cast light only (panes and halo are unaffected). The glow
	-- reads far brighter than the light it threw, so even Dim has to actually
	-- light its surroundings.
	local LIGHT_GAIN = 3.2

	-- The pane geometry, lifted out of the model once and drawn directly by the
	-- bloom pass. It cannot ask the entity to redraw itself: Entity:DrawModel
	-- called outside ENTITY:Draw re-enters ENTITY:Draw, which reinstates the
	-- normal pane material, so the additive pass would redraw the panes exactly as
	-- they already look and the bloom's before/after diff would come out empty.
	local glassMesh

	local function getGlassMesh(model, subMaterial)
		if glassMesh ~= nil then return glassMesh end

		glassMesh = false -- built at most once, even on failure

		local groups = util.GetModelMeshes(model)
		if not groups then return glassMesh end

		local tris
		for _, group in ipairs(groups) do
			if group.material == subMaterial and group.triangles and #group.triangles >= 3 then
				tris = group.triangles
				break
			end
		end

		if not tris then return glassMesh end

		local built = Mesh()
		mesh.Begin(built, MATERIAL_TRIANGLES, #tris / 3)

		for _, v in ipairs(tris) do
			mesh.Position(v.pos)
			mesh.Normal(v.normal)
			mesh.TexCoord(0, v.u, v.v)
			mesh.AdvanceVertex()
		end

		mesh.End()
		glassMesh = built

		return glassMesh
	end

	-- Every lantern that currently exists clientside; the bloom pass walks this
	-- instead of ents.FindByClass every frame.
	local ACTIVE = {}

	function ENT:GetPalette()
		local packed = self:GetLightColorPacked()
		local pal = self._palette
		if pal and pal.packed == packed then return pal end

		local base = self:GetLightColor()
		local h, s, v = ColorToHSV(base)
		pal = {
			packed = packed,
			base = base,
			-- Pale, near-white version for the hot center of the glow
			core = HSVToColor(h, math.Clamp(s * 0.45, 0, 1), v),
			normalized = Vector(base.r / 255, base.g / 255, base.b / 255),
		}
		self._palette = pal

		return pal
	end

	function ENT:Initialize()
		self._emitter = ParticleEmitter(self:GetPos(), false)
		self._nextMote = 0
		self._paneMaterial, self._bloomMaterial = createMaterials(self:EntIndex())

		-- Room for the glow and the motes drifting out of the lamp
		self:SetRenderBounds(Vector(-120, -120, -120), Vector(120, 120, 160))

		ACTIVE[self] = true
	end

	function ENT:OnRemove()
		ACTIVE[self] = nil

		if self._emitter then
			self._emitter:Finish()
			self._emitter = nil
		end
	end

	-- Unlit glass. The lit appearance is NOT applied here: the bloom captures
	-- (screen after - screen before), so anything already at full brightness in the
	-- before-snapshot cannot contribute. Drawing the panes saturated here and
	-- boosting them in the bloom pass captures only the channels that still had
	-- headroom -- a red lantern bloomed cyan. The panes are therefore dark in this
	-- pass and get their light entirely from DrawGlow, inside the capture window,
	-- the same way magic circles are drawn only inside ProcessBloom.
	local UNLIT_GLASS = 0.12

	function ENT:Draw()
		local pal = self:GetPalette()
		glassTint:SetUnpacked(pal.normalized.x * UNLIT_GLASS, pal.normalized.y * UNLIT_GLASS, pal.normalized.z * UNLIT_GLASS)
		self._paneMaterial:SetVector("$color2", glassTint)

		render.MaterialOverrideByIndex(self.GlassMaterialIndex, self._paneMaterial)
		self:DrawModel()
		render.MaterialOverrideByIndex(self.GlassMaterialIndex, nil)
	end

	-- Called inside the bloom pass (see the hook at the bottom), never directly.
	-- This is what actually lights the panes: it draws them additively over the
	-- unlit glass from ENT:Draw, inside the capture window, so the whole of the
	-- lamp's light is new contribution the bloom can pick up. Occlusion still
	-- works -- it depth-tests against the scene like any other draw.
	function ENT:DrawGlow()
		local brightness = math.Clamp(self:GetBrightness(), 0, self.MaxBrightness)
		if brightness <= 0 then return end

		local glass = getGlassMesh(self.LanternModel, self.GlassSubMaterial)
		if not glass then return end

		local pal = self:GetPalette()

		-- Scale by the color's peak channel rather than multiplying it flat. A flat
		-- multiply drives the dominant channel into the 1.0 ceiling first, after
		-- which extra brightness only lifts the remaining channels -- which reads as
		-- the color desaturating to white. Normalising to the peak keeps the hue
		-- ratios intact right up to the clip point. Past 1.0 it does blow out, which
		-- is what the top of the brightness range is for.
		local level = math.min(0.25 + 0.55 * brightness, 1.25)
		local peak = math.max(pal.normalized.x, pal.normalized.y, pal.normalized.z, 0.001)
		local boost = level / peak

		glassTint:SetUnpacked(pal.normalized.x * boost, pal.normalized.y * boost, pal.normalized.z * boost)
		self._bloomMaterial:SetVector("$color2", glassTint)

		local matrix = Matrix()
		matrix:SetTranslation(self:GetPos())
		matrix:SetAngles(self:GetAngles())

		local scale = self:GetModelScale()
		if scale ~= 1 then
			matrix:Scale(Vector(scale, scale, scale))
		end

		cam.PushModelMatrix(matrix)
		render.SetMaterial(self._bloomMaterial)
		glass:Draw()
		cam.PopModelMatrix()
	end

	function ENT:Think()
		local now = CurTime()
		local brightness = math.Clamp(self:GetBrightness(), 0, self.MaxBrightness)

		if brightness > 0 then
			local pal = self:GetPalette()

			-- Light motes leaking out of the lamp. The emitter's position is what
			-- the engine sorts and culls against, so it has to follow a lantern
			-- that gets picked up and carried off.
			if self._emitter then
				self._emitter:SetPos(self:GetPos())
			end

			if now >= self._nextMote then
				self:SpawnMote(pal, brightness)
				self._nextMote = now + 0.05 / math.max(brightness, 0.35)
			end

			-- The light the lantern casts read far weaker than the panes suggested,
			-- so the whole curve is geared up: Normal now throws roughly what the
			-- Bright preset used to, and the presets scale from there.
			local lit = brightness * LIGHT_GAIN

			local dl = DynamicLight(self:EntIndex())
			if dl then
				dl.pos = self:GetPos()
				dl.r = pal.base.r
				dl.g = pal.base.g
				dl.b = pal.base.b
				dl.brightness = 2 * lit
				dl.Decay = 500
				dl.Size = math.min(200 * (0.6 + 0.4 * lit), 560)
				dl.DieTime = now + 0.15
			end
		end

		self:SetNextClientThink(now + 0.03)

		return true
	end

	function ENT:SpawnMote(pal, brightness)
		if not self._emitter then return end

		-- Same shape as the ritual orb (_SpawnRitualParticles): one direction picks
		-- both where the mote appears and where it travels, so they radiate out of
		-- the lamp rather than each drifting off on its own heading. Yaw is free,
		-- pitch is capped at +-25 degrees so they stay near the lamp's own plane.
		local dir = Angle(math.Rand(-MOTE_PITCH, MOTE_PITCH), math.Rand(0, 360), 0):Forward()

		-- GetPos, not OBBCenter: the glass mesh is centered on the entity origin,
		-- so that is where the light actually leaves the lantern.
		local pos = self:GetPos() + dir * math.Rand(3, 7)

		local p = self._emitter:Add("sprites/light_glow02_add", pos)
		if not p then return end

		p:SetStartAlpha(math.min(255, 180 * brightness))
		p:SetEndAlpha(0)
		p:SetStartSize(math.Rand(1.5, 3.5) * (0.7 + 0.3 * brightness))
		p:SetEndSize(0)
		p:SetDieTime(math.Rand(1, 1.8))
		p:SetVelocity(dir * math.Rand(10, 22))
		p:SetAirResistance(20)
		p:SetGravity(VECTOR_ZERO)
		p:SetRoll(math.Rand(-180, 180))
		p:SetRollDelta(math.Rand(-0.4, 0.4))

		local col = math.random(1, 3) == 1 and pal.core or pal.base
		p:SetColor(col.r, col.g, col.b)
	end

	-- One bloom pass per frame for every visible lantern. ProcessBloom snapshots
	-- the whole framebuffer, so this must never run per-entity; the glow sprites
	-- it draws are z-tested against the real scene, so occluded lanterns cost
	-- nothing but a rejected sprite.
	local BLOOM_DISTANCE_SQR = 3000 * 3000
	local drawList = {}

	hook.Add("PostDrawTranslucentRenderables", "Arcana_LanternBloom", function(bDrawingDepth, isSkybox)
		if bDrawingDepth or isSkybox then return end

		local eyePos = EyePos()
		local count = 0

		for ent in pairs(ACTIVE) do
			if not IsValid(ent) then
				ACTIVE[ent] = nil
			elseif not ent:IsDormant() and ent:GetBrightness() > 0 and ent:GetPos():DistToSqr(eyePos) < BLOOM_DISTANCE_SQR then
				count = count + 1
				drawList[count] = ent
			end
		end

		if count == 0 then return end

		local function drawGlows()
			for i = 1, count do
				drawList[i]:DrawGlow()
				drawList[i] = nil
			end
		end

		local bloom = Arcana.Bloom

		-- ProcessBloom draws the glows to the screen itself and captures their
		-- contribution for the blur passes; without it they still need drawing.
		-- CA scale 0: the fringe suits arcane circles, not a lamp.
		if bloom and bloom.ProcessBloom then
			bloom.ProcessBloom(drawGlows)
			bloom.RenderBloom(0)
		else
			drawGlows()
		end
	end)
end

-- Context-menu properties (see arcana/common/entity_properties.lua). That file and
-- this one can load in either order, so register now if it is already there and
-- otherwise wait for it to announce itself.
local function registerProperties()
	Arcana.Common.AddColorProperty("arcana_fae_lantern_color", {
		class = "arcana_fae_lantern",
		label = "Light Color",
		title = "Lantern Color",
		order = 900,
		icon = "icon16/paintcan.png",
		presets = {
			{name = "Candle", color = Color(255, 190, 110)},
			{name = "Ember", color = Color(255, 150, 60)},
			{name = "Crimson", color = Color(255, 70, 45)},
			{name = "Gold", color = Color(255, 215, 105)},
			{name = "Witchfire", color = Color(140, 255, 90)},
			{name = "Emerald", color = Color(90, 255, 150)},
			{name = "Azure", color = Color(80, 170, 255)},
			{name = "Frost", color = Color(160, 230, 255)},
			{name = "Violet", color = Color(180, 110, 255)},
		},
		get = function(ent) return ent:GetLightColor() end,
		set = function(ent, col) ent:SetLightColor(col) end,
	})

	Arcana.Common.AddScalarProperty("arcana_fae_lantern_brightness", {
		class = "arcana_fae_lantern",
		label = "Brightness",
		sliderLabel = "Intensity",
		order = 901,
		icon = "icon16/lightbulb.png",
		min = 0,
		max = ENT.MaxBrightness,
		decimals = 1,
		presets = {
			{name = "Out", value = 0},
			{name = "Dim", value = 0.4},
			{name = "Normal", value = 1},
			{name = "Bright", value = 1.8},
		},
		get = function(ent) return ent:GetBrightness() end,
		set = function(ent, value) ent:SetBrightness(value) end,
	})
end

if Arcana.Common.AddColorProperty then
	registerProperties()
else
	hook.Add("Arcana_EntityPropertiesReady", "arcana_fae_lantern_properties", registerProperties)
end
