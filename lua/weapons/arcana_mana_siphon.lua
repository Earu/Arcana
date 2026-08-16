if SERVER then
	AddCSLuaFile()
	util.AddNetworkString("Arcana_ManaSight_Sources")
end

require("shader_to_gma")

if SERVER then
	resource.AddShader("arcana_manalens_ps30")
	resource.AddShader("arcana_manacloud_ps30")
	resource.AddShader("arcana_managhost_ps30")
	resource.AddShader("arcana_manabox_ps30")
	resource.AddShader("arcana_manabox_vs30")
end

SWEP.PrintName = "Mana Siphon"
SWEP.Author = "Earu"
SWEP.Category = "Arcana"
SWEP.Purpose = "Locate mana concentrations and collect them as mana dust"
SWEP.Instructions = "LMB: Collect mana dust | RMB: Toggle mana sight | R: Convert crystal shards into mana dust"
SWEP.Spawnable = true
SWEP.AdminOnly = true
SWEP.DrawAmmo = false
SWEP.DrawCrosshair = true
-- Bugbait viewmodel for the hands and grip; the bugbait itself is hidden and
-- a glass compass cube is drawn in the palm instead (see CUBE COMPASS)
SWEP.ViewModel = "models/weapons/c_bugbait.mdl"
SWEP.WorldModel = "models/hunter/blocks/cube025x025x025.mdl"
SWEP.UseHands = true
SWEP.HoldType = "slam"
SWEP.Weight = 3
SWEP.AutoSwitchTo = false
SWEP.AutoSwitchFrom = false
SWEP.Slot = 0
SWEP.SlotPos = 2
SWEP.Primary.ClipSize = -1
SWEP.Primary.DefaultClip = -1
SWEP.Primary.Automatic = true
SWEP.Primary.Ammo = "none"
SWEP.Secondary.ClipSize = -1
SWEP.Secondary.DefaultClip = -1
SWEP.Secondary.Automatic = false
SWEP.Secondary.Ammo = "none"

local KIND_NONE = 0
local KIND_HOTSPOT = 1
local KIND_CRYSTAL = 2

local SENSE_INTERVAL = 0.4
local SENSE_MIN_HOTSPOT_VALUE = 10
local EXTRACT_TICK = 0.25
local HOTSPOT_EXTRACT_RANGE = 600
local CRYSTAL_EXTRACT_RANGE = 350
-- Hotspots hold ~70 intensity at spawn threshold; crystals hold up to 300 growth.
-- Both drain to roughly 3 dust per second so neither source is strictly better.
local HOTSPOT_DRAIN_PER_TICK = 1.5
local DUST_PER_HOTSPOT_VALUE = 0.5
local CRYSTAL_DRAIN_PER_TICK = 7.5
local DUST_PER_GROWTH = 0.1
local CRYSTAL_DISSOLVE_BONUS_DUST = 2
-- Dust is granted in batches so the pickup announcements don't fire every tick.
local DUST_BATCH = 10
local SHARD_DUST_VALUE = 5
local CONVERT_COOLDOWN = 0.4

-- Mana sight: RMB toggles an overlay that reveals every nearby source through walls
local SIGHT_SYNC_INTERVAL = 0.75
local SIGHT_SOURCE_RANGE = 8000
local SIGHT_MAX_SOURCES = 16

function SWEP:SetupDataTables()
	self:NetworkVar("Vector", 0, "SourcePos")
	self:NetworkVar("Int", 0, "SourceKind")
	self:NetworkVar("Int", 1, "BufferedDust")
	self:NetworkVar("Float", 0, "SourceStrength")
	self:NetworkVar("Bool", 0, "Extracting")
	self:NetworkVar("Bool", 1, "SightActive")
end

function SWEP:Initialize()
	self:SetHoldType(self.HoldType)
	self._dustBuffer = 0
end

function SWEP:Deploy()
	self:SetHoldType(self.HoldType)
	if SERVER then
		self:SetSightActive(false)
	end

	return true
end

function SWEP:SecondaryAttack()
	self:SetNextSecondaryFire(CurTime() + 0.35)
	if CLIENT then return end

	local active = not self:GetSightActive()
	self:SetSightActive(active)

	-- Ethereal, not mechanical: a soft energy bloom, pitched up waking and
	-- down going dormant, with a chime shimmer as the panel materializes
	self:EmitSound("ambient/energy/whiteflash.wav", 60, active and 145 or 85, 0.55)
	if active then
		self:EmitSound("ambient/levels/canals/windchime2.wav", 60, 125, 0.45)
	end
end

if SERVER then
	local function findNearestCrystal(pos)
		local best, bestD2
		for _, ent in ipairs(ents.FindByClass("arcana_mana_crystal")) do
			if not IsValid(ent) then continue end

			local d2 = ent:WorldSpaceCenter():DistToSqr(pos)
			if not best or d2 < bestD2 then
				best, bestD2 = ent, d2
			end
		end

		return best, bestD2
	end

	local function findNearestHotspot(pos, minValue)
		local M = Arcana.ManaCrystals
		if not M then return nil end

		local best, bestD2
		for i = 1, #M.hotspots do
			local h = M.hotspots[i]
			if (h.value or 0) >= minValue then
				local d2 = h.pos:DistToSqr(pos)
				if not best or d2 < bestD2 then
					best, bestD2 = h, d2
				end
			end
		end

		return best, bestD2
	end

	-- Periodically points the needle at the nearest mana source on the map,
	-- whether a hotspot (invisible concentration) or a grown crystal.
	function SWEP:_UpdateSensedSource()
		-- The extract tick owns the source vars during a channel; re-sensing here could
		-- flip the needle to another source (or to none) while the beam is still running.
		if self:GetExtracting() then return end

		local owner = self:GetOwner()
		if not IsValid(owner) then
			self:SetSourceKind(KIND_NONE)
			return
		end

		local pos = owner:WorldSpaceCenter()
		local crystal, crystalD2 = findNearestCrystal(pos)
		local hotspot, hotspotD2 = findNearestHotspot(pos, SENSE_MIN_HOTSPOT_VALUE)

		if IsValid(crystal) and (not hotspot or crystalD2 <= hotspotD2) then
			local minS, maxS = 0.35, 2.2
			local cfg = Arcana.ManaCrystals and Arcana.ManaCrystals.Config
			if cfg then
				minS = tonumber(cfg.crystalMinScale) or minS
				maxS = tonumber(cfg.crystalMaxScale) or maxS
			end

			local s = crystal.GetCrystalScale and crystal:GetCrystalScale() or minS
			self:SetSourceKind(KIND_CRYSTAL)
			self:SetSourcePos(crystal:WorldSpaceCenter())
			self:SetSourceStrength(math.Clamp((s - minS) / math.max(0.0001, maxS - minS), 0, 1))
		elseif hotspot then
			local threshold = (Arcana.ManaCrystals and Arcana.ManaCrystals.Config.hotspotSpawnThreshold) or 70
			self:SetSourceKind(KIND_HOTSPOT)
			self:SetSourcePos(hotspot.pos)
			self:SetSourceStrength(math.Clamp((hotspot.value or 0) / threshold, 0, 1))
		else
			self:SetSourceKind(KIND_NONE)
		end
	end

	-- Streams every nearby source to the owner while mana sight is on. The overlay
	-- shows all of them at once, unlike the needle which only tracks the nearest.
	function SWEP:_SyncSightSources()
		local owner = self:GetOwner()
		if not IsValid(owner) or not owner:IsPlayer() then return end

		local pos = owner:WorldSpaceCenter()
		local sources = {}

		local M = Arcana.ManaCrystals
		if M then
			for i = 1, #M.hotspots do
				local h = M.hotspots[i]
				if (h.value or 0) >= 5 then
					local d2 = h.pos:DistToSqr(pos)
					if d2 <= SIGHT_SOURCE_RANGE * SIGHT_SOURCE_RANGE then
						local threshold = (M.Config and M.Config.hotspotSpawnThreshold) or 70
						sources[#sources + 1] = {
							kind = KIND_HOTSPOT,
							pos = h.pos,
							strength = math.Clamp((h.value or 0) / threshold, 0, 1),
							entIndex = 0,
							d2 = d2,
						}
					end
				end
			end
		end

		for _, ent in ipairs(ents.FindByClass("arcana_mana_crystal")) do
			if IsValid(ent) then
				local d2 = ent:WorldSpaceCenter():DistToSqr(pos)
				if d2 <= SIGHT_SOURCE_RANGE * SIGHT_SOURCE_RANGE then
					sources[#sources + 1] = {
						kind = KIND_CRYSTAL,
						pos = ent:WorldSpaceCenter(),
						strength = 1,
						entIndex = ent:EntIndex(),
						d2 = d2,
					}
				end
			end
		end

		table.sort(sources, function(a, b) return a.d2 < b.d2 end)
		local count = math.min(#sources, SIGHT_MAX_SOURCES)

		net.Start("Arcana_ManaSight_Sources", true)
		net.WriteUInt(count, 5)
		for i = 1, count do
			local s = sources[i]
			net.WriteUInt(s.kind, 2)
			net.WriteVector(s.pos)
			net.WriteFloat(s.strength)
			net.WriteUInt(s.entIndex, 16)
		end
		net.Send(owner)
	end

	-- Grants whole buffered dust to the owner. Partial units stay buffered so slow
	-- draining still adds up; a failed grant (inventory not loaded) keeps the buffer.
	function SWEP:_BankDust()
		local whole = math.floor(self._dustBuffer or 0)
		if whole < 1 then return end

		local owner = self:GetOwner()
		if not IsValid(owner) or not owner:IsPlayer() then return end

		if Arcana.GiveItem(owner, "mana_dust", whole, "Mana siphon") then
			self._dustBuffer = self._dustBuffer - whole
			self:SetBufferedDust(0)
		end
	end

	function SWEP:_FindExtractTarget()
		local owner = self:GetOwner()
		if not IsValid(owner) then return nil, nil end

		local pos = owner:WorldSpaceCenter()
		local crystal, crystalD2 = findNearestCrystal(pos)
		if IsValid(crystal) and crystalD2 <= CRYSTAL_EXTRACT_RANGE * CRYSTAL_EXTRACT_RANGE then
			return crystal, KIND_CRYSTAL
		end

		local hotspot, hotspotD2 = findNearestHotspot(pos, 0)
		if hotspot and hotspotD2 <= HOTSPOT_EXTRACT_RANGE * HOTSPOT_EXTRACT_RANGE then
			return hotspot, KIND_HOTSPOT
		end

		return nil, nil
	end

	function SWEP:_StartExtractSound()
		if self._extractSnd then return end
		self._extractSnd = CreateSound(self, "ambient/levels/citadel/field_loop3.wav")
		if self._extractSnd then
			self._extractSnd:PlayEx(0.35, 130)
		end
	end

	function SWEP:_StopExtractSound()
		if self._extractSnd then
			self._extractSnd:Stop()
			self._extractSnd = nil
		end
	end

	-- Gently dissolve a fully drained crystal. Unlike shattering it, this does not
	-- feed the corruption system: siphoning is the slow but clean harvest.
	local function dissolveCrystal(crystal)
		local ed = EffectData()
		ed:SetOrigin(crystal:WorldSpaceCenter())
		util.Effect("GlassImpact", ed, true, true)
		crystal:EmitSound("physics/glass/glass_sheet_break2.wav", 65, 160, 0.6)
		SafeRemoveEntity(crystal)
	end

	function SWEP:PrimaryAttack()
		self:SetNextPrimaryFire(CurTime() + EXTRACT_TICK)
		if CLIENT then return end

		local owner = self:GetOwner()
		if not IsValid(owner) or not owner:IsPlayer() then return end

		local target, kind = self:_FindExtractTarget()
		if not kind then
			self:SetExtracting(false)
			self:_StopExtractSound()
			return
		end

		local dust = 0
		if kind == KIND_CRYSTAL then
			local drained = target:DrainCrystalGrowth(CRYSTAL_DRAIN_PER_TICK)
			if drained > 0 then
				dust = drained * DUST_PER_GROWTH
			else
				dust = CRYSTAL_DISSOLVE_BONUS_DUST
				dissolveCrystal(target)
			end

			self:SetSourcePos(IsValid(target) and target:WorldSpaceCenter() or self:GetSourcePos())
			self:SetSourceKind(KIND_CRYSTAL)
		else
			local drained = math.min(target.value or 0, HOTSPOT_DRAIN_PER_TICK)
			target.value = (target.value or 0) - drained
			dust = drained * DUST_PER_HOTSPOT_VALUE
			self:SetSourcePos(target.pos)
			self:SetSourceKind(KIND_HOTSPOT)
		end

		self._dustBuffer = (self._dustBuffer or 0) + dust
		self._lastExtract = CurTime()
		self:SetExtracting(true)
		self:SetBufferedDust(math.floor(self._dustBuffer))
		self:_StartExtractSound()

		if self._dustBuffer >= DUST_BATCH then
			self:_BankDust()
		end
	end

	function SWEP:Think()
		local now = CurTime()

		if now >= (self._nextSense or 0) then
			self._nextSense = now + SENSE_INTERVAL
			self:_UpdateSensedSource()
		end

		if self:GetSightActive() and now >= (self._nextSightSync or 0) then
			self._nextSightSync = now + SIGHT_SYNC_INTERVAL
			self:_SyncSightSources()
		end

		-- The channel ended: cut the beam, then bank whatever was gathered.
		if now - (self._lastExtract or 0) > 0.5 then
			if self:GetExtracting() then
				self:SetExtracting(false)
				self:_StopExtractSound()
			end

			self:_BankDust()
		end
	end

	function SWEP:Holster()
		self:_StopExtractSound()
		self:SetExtracting(false)
		self:SetSightActive(false)
		self:_BankDust()
		return true
	end

	function SWEP:OnRemove()
		self:_StopExtractSound()
		self:_BankDust()
	end
end

-- R turns stored crystal shards into mana dust, one shard at a time.
function SWEP:Reload()
	if CLIENT then return end

	local now = CurTime()
	if now < (self._nextConvert or 0) then return end
	self._nextConvert = now + CONVERT_COOLDOWN

	local owner = self:GetOwner()
	if not IsValid(owner) or not owner:IsPlayer() then return end

	if Arcana.GetItemCount(owner, "mana_crystal_shard") < 1 then
		Arcana.SendErrorNotification(owner, "No crystal shards to convert")
		return
	end

	if not Arcana.TakeItem(owner, "mana_crystal_shard", 1, "Mana siphon") then return end

	Arcana.GiveItem(owner, "mana_dust", SHARD_DUST_VALUE, "Converted crystal shard")
	owner:EmitSound("physics/glass/glass_cup_break1.wav", 60, 200, 0.5)
end

if CLIENT then
	-- Art deco gold, like the altar's magic circle: the whole apparatus
	-- (cube, panel, halos, arrow) speaks the station palette
	local COLOR_MANA = Color(226, 192, 110)
	local OUTLINE_COL = Color(0, 0, 0, 220)
	local GRAIN_MAT = Material("sprites/light_glow02_add")
	local BEAM_MAT = Material("trails/laser")

	-- Where siphoned mana sinks in: just off the palm side of the view
	local function siphonHandPos(owner)
		local ea = owner:EyeAngles()
		return owner:EyePos() + ea:Forward() * 12 + ea:Right() * 5 - ea:Up() * 5
	end


	-- ========================================================================
	-- MANA SIGHT STATE
	-- ========================================================================
	-- Sources streamed by the server while sight is on: {kind, pos, strength, entIndex}
	local sightSources = {}
	local sightSourcesAt = 0

	net.Receive("Arcana_ManaSight_Sources", function()
		local count = net.ReadUInt(5)
		local sources = {}
		for _ = 1, count do
			sources[#sources + 1] = {
				kind = net.ReadUInt(2),
				pos = net.ReadVector(),
				strength = net.ReadFloat(),
				entIndex = net.ReadUInt(16),
			}
		end

		sightSources = sources
		sightSourcesAt = RealTime()
	end)

	-- Returns the deployed siphon, or nil
	local function getActiveSiphon()
		local ply = LocalPlayer()
		if not IsValid(ply) then return nil end

		local wep = ply:GetActiveWeapon()
		if not IsValid(wep) or wep:GetClass() ~= "arcana_mana_siphon" then return nil end

		return wep
	end

	local function getSightSources()
		-- Stale data after the server stops streaming (sight just turned off elsewhere)
		if RealTime() - sightSourcesAt > 3 then return {} end
		return sightSources
	end

	-- Volumetric gas for concentrations: one raymarched screen pass per source.
	local CLOUD_SHADER = "arcana_manacloud_ps30"

	-- Near-white warm gold for the elements that must pop inside the panel
	local COLOR_GHOST = Color(255, 238, 190)

	local cloudMat
	WaitForShaderMounted({CLOUD_SHADER, "arcana_passthrough_vs30"}, function(available)
		if not available then return end

		cloudMat = CreateShaderMaterial(CLOUD_SHADER, {
			["$pixshader"] = CLOUD_SHADER,
			["$vertexshader"] = "arcana_passthrough_vs30",
			["$ignorez"] = 1,
			-- every $c component set at draw time must be declared here,
			-- otherwise SetFloat on it is silently ignored
			["$c0_x"] = 0, ["$c0_y"] = 0, ["$c0_z"] = 0, ["$c0_w"] = 100,
			["$c1_x"] = 0, ["$c1_y"] = 0, ["$c1_z"] = 0, ["$c1_w"] = 0,
			["$c2_x"] = 1, ["$c2_y"] = 0, ["$c2_z"] = 0, ["$c2_w"] = 1,
			["$c3_x"] = 0, ["$c3_y"] = 1, ["$c3_z"] = 0, ["$c3_w"] = 1,
		})
	end)

	-- Ghost fill: warps and chromatically splits the frame beneath the crystal
	-- silhouette so it reads as shimmering glass, not a flat decal
	local GHOST_SHADER = "arcana_managhost_ps30"

	local ghostMat
	WaitForShaderMounted({GHOST_SHADER, "arcana_passthrough_vs30"}, function(available)
		if not available then return end

		ghostMat = CreateShaderMaterial(GHOST_SHADER, {
			["$pixshader"] = GHOST_SHADER,
			["$vertexshader"] = "arcana_passthrough_vs30",
			["$ignorez"] = 1,
			-- every $c component set at draw time must be declared here,
			-- otherwise SetFloat on it is silently ignored
			["$c0_x"] = 0, ["$c0_y"] = 1, ["$c0_z"] = 60, ["$c0_w"] = 1,
			["$c1_x"] = 0, ["$c1_y"] = 0, ["$c1_z"] = 0, ["$c1_w"] = 0,
			["$c2_x"] = 0, ["$c2_y"] = 1, ["$c2_z"] = 0, ["$c2_w"] = 0,
			["$c3_x"] = 1, ["$c3_y"] = 0, ["$c3_z"] = 0, ["$c3_w"] = 0,
		})
	end)

	-- The synced strength only updates every SIGHT_SYNC_INTERVAL; smooth it
	-- client-side so the cloud never pops in size between syncs
	local cloudStrengths = {}

	-- ToScreen probes calibrate the shader's ray reconstruction against the
	-- real projection, immune to fov/aspect conventions (see corruption fx)
	local function getCloudCalibration()
		if not cloudMat then return nil end

		local vs = render.GetViewSetup(true)
		local origin, ang = vs.origin, vs.angles
		local fwd, right, up = ang:Forward(), ang:Right(), ang:Up()
		local probeR = (origin + (fwd + right) * 512):ToScreen()
		local probeU = (origin + (fwd + up) * 512):ToScreen()
		local ndcR = (probeR.x / ScrW()) * 2 - 1
		local ndcU = 1 - (probeU.y / ScrH()) * 2
		local halfW = 1 / math.max(0.05, ndcR)
		local halfH = 1 / math.max(0.05, ndcU)

		return {
			origin = origin,
			fwd = fwd,
			rightW = right * halfW,
			halfH = halfH,
			time = math.fmod(RealTime(), 1000),
		}
	end

	-- One raymarched volume: basePos is the volume's ground anchor
	local function drawCloudVolume(calib, basePos, radius, strength)
		render.UpdateScreenEffectTexture()
		cloudMat:SetTexture("$basetexture", render.GetScreenEffectTexture())
		cloudMat:SetFloat("$c0_x", basePos.x)
		cloudMat:SetFloat("$c0_y", basePos.y)
		cloudMat:SetFloat("$c0_z", basePos.z)
		cloudMat:SetFloat("$c0_w", radius)
		cloudMat:SetFloat("$c1_x", calib.origin.x)
		cloudMat:SetFloat("$c1_y", calib.origin.y)
		cloudMat:SetFloat("$c1_z", calib.origin.z)
		cloudMat:SetFloat("$c1_w", calib.time)
		cloudMat:SetFloat("$c2_x", calib.fwd.x)
		cloudMat:SetFloat("$c2_y", calib.fwd.y)
		cloudMat:SetFloat("$c2_z", calib.fwd.z)
		cloudMat:SetFloat("$c2_w", strength)
		cloudMat:SetFloat("$c3_x", calib.rightW.x)
		cloudMat:SetFloat("$c3_y", calib.rightW.y)
		cloudMat:SetFloat("$c3_z", calib.rightW.z)
		cloudMat:SetFloat("$c3_w", calib.halfH)

		render.SetMaterial(cloudMat)
		render.DrawScreenQuad()
	end

	local function drawManaClouds(sources)
		local calib = getCloudCalibration()
		if not calib then return end

		for _, source in ipairs(sources) do
			if source.kind ~= KIND_HOTSPOT then continue end

			-- Skip sources fully behind the view
			local toSource = source.pos - calib.origin
			if toSource:Dot(calib.fwd) < 0 and toSource:LengthSqr() > 250 * 250 then continue end

			local key = string.format("%d:%d", math.floor(source.pos.x / 32), math.floor(source.pos.y / 32))
			local target = math.Clamp(source.strength or 0.5, 0.4, 1)
			local strength = Lerp(math.Clamp(FrameTime() * 2.5, 0, 1), cloudStrengths[key] or target, target)
			cloudStrengths[key] = strength

			drawCloudVolume(calib, source.pos, 100 + 80 * strength, strength)
		end
	end

	-- The siphoned gas itself: pieces of the cloud detach, billow along the
	-- path and shrink into the hand, staggered into a continuous stream
	local function drawSiphonGas(wep)
		if not wep:GetExtracting() then return end

		local owner = wep:GetOwner()
		if not IsValid(owner) then return end

		local calib = getCloudCalibration()
		if not calib then return end

		local now = RealTime()
		local src = wep:GetSourcePos()
		local hand = siphonHandPos(owner)

		for i = 1, 3 do
			local t = math.fmod(now * 0.4 + (i - 1) / 3, 1)
			local ease = t ^ 1.15
			local center = LerpVector(ease, src + Vector(0, 0, 26), hand)
			center.z = center.z + math.sin(t * math.pi) * 22

			local radius = Lerp(t, 40, 12)
			local strength = 1.15 * (1 - t * 0.25)
			drawCloudVolume(calib, center - Vector(0, 0, radius * 0.8), radius, strength)
		end
	end

	-- Crystal ghosts, silhouette-fill style: the model is drawn once more into
	-- the graded frame purely to MARK its pixels in a second stencil bit (it
	-- paints its own materials while doing so, which does not matter), then a
	-- near-opaque cyan-white quad floods exactly those pixels, covering that
	-- paint entirely.  ZFAIL also marks, so the silhouette shows through
	-- geometry.  MaterialOverride is deliberately not involved anywhere: it is
	-- not honoured for DrawModel in this render stage.
	-- Stencil layout: bit 1 = panel window, bit 2 = crystal silhouette.
	local function drawSightWorld()
		local sources = getSightSources()
		if #sources == 0 then return end

		local now = RealTime()

		drawManaClouds(sources)

		-- Mark silhouettes of crystals that have a client entity.  ZFAIL marks
		-- too, so the whole silhouette shows through world geometry: crystals
		-- reveal through walls exactly like the mana clouds do.  Each crystal
		-- is rasterized a few times with animated render-origin jitters, so
		-- the union silhouette in the stencil ripples: the SHAPE distorts, not
		-- just the fill.
		local marked = false
		cam.Start3D()
		render.SetStencilReferenceValue(3)
		render.SetStencilTestMask(9)
		render.SetStencilWriteMask(2)
		render.SetStencilPassOperation(STENCIL_REPLACE)
		render.SetStencilZFailOperation(STENCIL_REPLACE)

		for _, source in ipairs(sources) do
			if source.kind == KIND_CRYSTAL then
				local ent = source.entIndex > 0 and Entity(source.entIndex) or nil
				if IsValid(ent) then
					local origin = ent:GetPos()
					for j = 1, 4 do
						local phase = now * (1.1 + j * 0.5) + j * 2.1 + source.entIndex
						ent:SetRenderOrigin(origin + Vector(
							math.sin(phase) * 7,
							math.cos(phase * 1.3) * 7,
							math.sin(phase * 0.7) * 4
						))
						ent:DrawModel()
					end

					ent:SetRenderOrigin()
					marked = true
				end
			end
		end

		render.SetStencilPassOperation(STENCIL_KEEP)
		render.SetStencilZFailOperation(STENCIL_KEEP)
		cam.End3D()

		-- Flood the marked, rippling silhouettes, covering whatever the model
		-- painted while being rasterized
		if marked then
			render.SetStencilTestMask(10)
			render.SetStencilReferenceValue(2)
			local pulse = 0.85 + 0.15 * math.sin(now * 2)

			-- Anchor the world-space veins to the nearest crystal in view
			-- (sources are distance-sorted, so the first crystal wins)
			local anchor, anchorRadius
			for _, source in ipairs(sources) do
				if source.kind == KIND_CRYSTAL then
					local ent = source.entIndex > 0 and Entity(source.entIndex) or nil
					if IsValid(ent) then
						anchor = source.pos
						anchorRadius = math.max(40, ent:OBBMaxs().z * (ent:GetModelScale() or 1))
						break
					end
				end
			end

			local calib = ghostMat and getCloudCalibration() or nil
			if ghostMat and calib and anchor then
				-- Warping, chromatically-split glass fill with world-anchored veins
				render.UpdateScreenEffectTexture()
				ghostMat:SetTexture("$basetexture", render.GetScreenEffectTexture())
				ghostMat:SetFloat("$c0_x", math.fmod(RealTime(), 1000))
				ghostMat:SetFloat("$c0_y", pulse)
				ghostMat:SetFloat("$c0_z", anchorRadius)
				ghostMat:SetFloat("$c0_w", calib.halfH)
				ghostMat:SetFloat("$c1_x", calib.origin.x)
				ghostMat:SetFloat("$c1_y", calib.origin.y)
				ghostMat:SetFloat("$c1_z", calib.origin.z)
				ghostMat:SetFloat("$c1_w", anchor.x)
				ghostMat:SetFloat("$c2_x", calib.rightW.x)
				ghostMat:SetFloat("$c2_y", calib.rightW.y)
				ghostMat:SetFloat("$c2_z", calib.rightW.z)
				ghostMat:SetFloat("$c2_w", anchor.y)
				ghostMat:SetFloat("$c3_x", calib.fwd.x)
				ghostMat:SetFloat("$c3_y", calib.fwd.y)
				ghostMat:SetFloat("$c3_z", calib.fwd.z)
				ghostMat:SetFloat("$c3_w", anchor.z)
				render.SetMaterial(ghostMat)
				render.DrawScreenQuad()
			else
				draw.NoTexture()
				surface.SetDrawColor(COLOR_GHOST.r * pulse, COLOR_GHOST.g * pulse, COLOR_GHOST.b * pulse, 242)
				surface.DrawRect(0, 0, ScrW(), ScrH())
			end

		end

		-- Crystal aura: the same raymarched gas the concentrations use, tight
		-- around each crystal, so crystals share the clouds' aesthetic and
		-- their apparent shape billows instead of ending at a crisp edge.
		-- Tested against panel bit 1 only, so it also covers the marked pixels.
		if cloudMat then
			local calib = getCloudCalibration()
			if calib then
				render.SetStencilTestMask(9)
				render.SetStencilReferenceValue(1)

				for _, source in ipairs(sources) do
					if source.kind == KIND_CRYSTAL then
						local ent = source.entIndex > 0 and Entity(source.entIndex) or nil
						if IsValid(ent) then
							local height = math.max(50, ent:OBBMaxs().z * (ent:GetModelScale() or 1))
							drawCloudVolume(calib, ent:GetPos(), height * 0.85, 0.85)
						end
					end
				end
			end
		end

		-- Restore the plain panel-window mask
		render.SetStencilTestMask(255)
		render.SetStencilWriteMask(255)
		render.SetStencilReferenceValue(1)

		-- Crystals outside PVS have no client entity to rasterize: pulsing core
		cam.Start3D()
		render.SetMaterial(GRAIN_MAT)
		for _, source in ipairs(sources) do
			if source.kind == KIND_CRYSTAL and (source.entIndex <= 0 or not IsValid(Entity(source.entIndex))) then
				local pulse = 0.75 + 0.25 * math.sin(now * 2 + source.pos.x * 0.01)
				render.DrawSprite(source.pos, 16 * pulse, 16 * pulse, ColorAlpha(COLOR_GHOST, 200))
			end
		end
		cam.End3D()
	end

	-- ========================================================================
	-- HOLO PANEL VISOR
	-- ========================================================================
	-- The lens is a holographic panel projected from the siphon hand: it
	-- materializes out of the palm, then floats low-right of the view like a
	-- held tablet, with spring lag and a little roll sway as the view turns.
	-- The blueprint grading applies only to what is seen through its window.
	local PANEL_DIST = 9
	local PANEL_RIGHT = 1.5
	local PANEL_UP = -1
	local PANEL_W = 14.5
	local PANEL_H = 9
	local IRIS_TIME = 0.35

	local LENS_SHADER = "arcana_manalens_ps30"

	local sightMat
	WaitForShaderMounted({LENS_SHADER, "arcana_passthrough_vs30"}, function(available)
		if not available then return end

		sightMat = CreateShaderMaterial(LENS_SHADER, {
			["$pixshader"] = LENS_SHADER,
			["$vertexshader"] = "arcana_passthrough_vs30",
			["$ignorez"] = 1,
			-- every $c component set at draw time must be declared here,
			-- otherwise SetFloat on it is silently ignored
			["$c0_x"] = 0, ["$c0_y"] = 0, ["$c0_z"] = 1.777, ["$c0_w"] = 0,
			["$c1_x"] = 0, ["$c1_y"] = 0, ["$c1_z"] = 0, ["$c1_w"] = 0,
			["$c2_x"] = 0, ["$c2_y"] = 0, ["$c2_z"] = 0, ["$c2_w"] = 0,
		})
	end)

	-- The panel retracts into the palm on shutdown instead of vanishing;
	-- while RealTime() < panelClosingUntil the whole panel path keeps running
	-- with a reversed ramp
	local IRIS_OUT_TIME = 0.28
	local panelClosingUntil = 0

	local sightOnSince = 0
	local wasSightOn = false
	local panelAng, panelLastYaw, panelRoll


	-- rampOverride: raw 0..1 fraction driving the materialize/retract state
	-- (the shutdown path feeds the reversed iris through it)
	local function computePanelCorners(rampOverride)
		local ea = EyeAngles()
		local ep = EyePos()

		-- Rotation lags (smoothed angles), translation does not: the panel is
		-- always positioned relative to the CURRENT eye position, so walking
		-- never drags it, only turning the view does
		local ft = math.Clamp(FrameTime() * 22, 0, 1)
		panelAng = panelAng and LerpAngle(ft, panelAng, ea) or Angle(ea)
		local fwd, right, up = panelAng:Forward(), panelAng:Right(), panelAng:Up()

		local dyaw = panelLastYaw and math.AngleDifference(ea.y, panelLastYaw) or 0
		panelLastYaw = ea.y
		panelRoll = Lerp(math.Clamp(FrameTime() * 12, 0, 1), panelRoll or 0, math.Clamp(dyaw * 4, -9, 9))

		local ramp = rampOverride or math.Clamp((RealTime() - sightOnSince) / IRIS_TIME, 0, 1)
		ramp = ramp * ramp * (3 - 2 * ramp)

		-- Materializes out of the palm and grows into place
		local handPos = ep + ea:Forward() * 14 + ea:Right() * 7 - ea:Up() * 7
		local anchored = ep + fwd * PANEL_DIST + right * PANEL_RIGHT + up * PANEL_UP
		local center = LerpVector(ramp, handPos, anchored)
		local hw = PANEL_W * 0.5 * (0.25 + 0.75 * ramp)
		local hh = PANEL_H * 0.5 * (0.25 + 0.75 * ramp)

		local rot = Angle(panelAng)
		rot:RotateAroundAxis(fwd, panelRoll)
		rot:RotateAroundAxis(up, 5)
		local r2, u2 = rot:Right(), rot:Up()

		return {
			center + u2 * hh - r2 * hw, -- TL
			center + u2 * hh + r2 * hw, -- TR
			center - u2 * hh + r2 * hw, -- BR
			center - u2 * hh - r2 * hw, -- BL
		}, ramp
	end


	local function projectCorners(corners)
		local w, h = ScrW(), ScrH()
		local uv = {}
		for idx = 1, 4 do
			local s = corners[idx]:ToScreen()
			if not s.visible then return nil end
			uv[idx] = {x = s.x / w, y = s.y / h}
		end

		return uv
	end

	local function pointInQuad(pts, x, y)
		local sign
		for idx = 1, 4 do
			local a, b = pts[idx], pts[idx % 4 + 1]
			local cr = (b.x - a.x) * (y - a.y) - (b.y - a.y) * (x - a.x)
			if cr ~= 0 then
				local s = cr > 0
				if sign == nil then
					sign = s
				elseif sign ~= s then
					return false
				end
			end
		end

		return true
	end

	-- Nearest intersection of a ray from (cx, cy) along (dx, dy) with the
	-- panel's border segments
	local function rayQuadBorder(pts, cx, cy, dx, dy)
		local bestT
		for idx = 1, 4 do
			local a, b = pts[idx], pts[idx % 4 + 1]
			local ex, ey = b.x - a.x, b.y - a.y
			local denom = dx * ey - dy * ex
			if math.abs(denom) > 1e-6 then
				local px, py = a.x - cx, a.y - cy
				local t = (px * ey - py * ex) / denom
				local s = (px * dy - py * dx) / denom
				if t > 0 and s >= 0 and s <= 1 and (not bestT or t < bestT) then
					bestT = t
				end
			end
		end

		if not bestT then return nil end
		return cx + dx * bestT, cy + dy * bestT
	end

	-- Sources outside the panel window glow as halos on the panel edge in
	-- their direction; sources visible through the window need none, the
	-- grain cloud itself shows there
	local function drawEdgeHalos(pts, cx, cy, ramp)
		local sources = getSightSources()
		if #sources == 0 then return end

		local ea = EyeAngles()
		local ep = EyePos()
		local fwd, right, up = ea:Forward(), ea:Right(), ea:Up()
		local now = RealTime()

		for _, source in ipairs(sources) do
			local toSource = source.pos - ep
			local inFront = toSource:Dot(fwd) > 0
			local sx, sy

			if inFront then
				local scr = source.pos:ToScreen()
				if scr.visible then
					sx, sy = scr.x, scr.y
				end
			end

			if sx and pointInQuad(pts, sx, sy) then continue end

			local dx, dy
			if sx then
				dx, dy = sx - cx, sy - cy
			else
				-- Behind the view: aim the halo from the view-space direction
				dx, dy = toSource:Dot(right), -toSource:Dot(up)
			end

			local len = math.sqrt(dx * dx + dy * dy)
			if len < 1 then continue end
			dx, dy = dx / len, dy / len

			local ax, ay = rayQuadBorder(pts, cx, cy, dx, dy)
			if not ax then continue end

			local dist = toSource:Length()
			local prox = math.Clamp(1 - dist / SIGHT_SOURCE_RANGE, 0, 1)
			local pulse = 0.75 + 0.25 * math.sin(now * 3 + (source.entIndex or 0) + source.pos.x * 0.01)
			local size = (44 + 50 * prox) * ramp * pulse

			surface.SetMaterial(GRAIN_MAT)
			surface.SetDrawColor(ColorAlpha(COLOR_MANA, 255 * (0.4 + 0.6 * prox) * pulse * ramp))
			surface.DrawTexturedRect(ax - size / 2, ay - size / 2, size, size)
		end
	end

	-- Pale gold dressing (the altar band circle's colour), matching the lens's
	-- brass line work and edge glow
	local FRAME_COL = Color(222, 198, 120)

	-- The band-circle glyph strips: linear, horizontally tileable textures
	-- (they wrap around cylinders in 3D), perfect as flat scrolling tickers
	local BAND_MATS = {}
	for i, tex in ipairs({"arcana/rings/ring_band", "arcana/rings/ring_band_2", "arcana/rings/ring_band_3"}) do
		BAND_MATS[i] = CreateMaterial("arcana_siphon_band_" .. i, "UnlitGeneric", {
			["$basetexture"] = tex,
			["$translucent"] = 1,
			["$vertexcolor"] = 1,
			["$vertexalpha"] = 1,
		})
	end


	-- The apparatus dressing drawn along the panel's projected outline: a
	-- marquee of small pattern rings scrolling along each edge like a ticker,
	-- and spinning ring arrangements on the corners, clipped to the panel
	-- window (the stencil still holds this frame's window marks)
	-- One full pass of the panel dressing (tickers, extraction text, halos)
	-- at the given alpha scale.  Called twice: a faint copy inside the bloom
	-- capture becomes the halo, then the crisp copy draws on top (the same
	-- two-pass pattern the altar's glyphs use).
	local function drawFrameLayers(pts, cx, cy, ramp, wep, alphaScale)
		local t = RealTime()

		render.SetStencilEnable(true)
		render.SetStencilTestMask(9)
		render.SetStencilWriteMask(0)
		render.SetStencilReferenceValue(1)
		render.SetStencilCompareFunction(STENCIL_EQUAL)
		render.SetStencilPassOperation(STENCIL_KEEP)
		render.SetStencilFailOperation(STENCIL_KEEP)
		render.SetStencilZFailOperation(STENCIL_KEEP)

		local diag = math.sqrt((pts[1].x - pts[3].x) ^ 2 + (pts[1].y - pts[3].y) ^ 2)

		-- Edge tickers: the band-circle glyph strips scrolling flat along each
		-- edge, variant and direction alternating edge to edge.  The u-span is
		-- derived from the texture's aspect so the glyphs keep their shape,
		-- and each strip is shifted inward by its half-thickness so the whole
		-- band stays inside the window instead of clipping on the outer edge.
		for idx = 1, 4 do
			local a, b = pts[idx], pts[idx % 4 + 1]
			local dx, dy = b.x - a.x, b.y - a.y
			local len = math.sqrt(dx * dx + dy * dy)

			if len > 4 then
				local thickness = math.max(12, diag * 0.028)
				local mat = BAND_MATS[(idx % 3) + 1]
				local texW, texH = math.max(1, mat:Width()), math.max(1, mat:Height())
				local uSpan = len * texH / (texW * thickness)
				local dir = (idx % 2 == 0) and 1 or -1
				local scroll = t * 0.04 * dir

				-- Perpendicular pointing toward the panel centre
				local mx, my = (a.x + b.x) / 2, (a.y + b.y) / 2
				local px, py = cx - mx, cy - my
				local pLen = math.sqrt(px * px + py * py)
				local inset = thickness * 0.5 - 1
				if pLen > 1 then
					mx = mx + px / pLen * inset
					my = my + py / pLen * inset
				end

				local m = Matrix()
				m:Translate(Vector(mx, my, 0))
				m:Rotate(Angle(0, math.deg(math.atan2(dy, dx)), 0))

				surface.SetMaterial(mat)
				surface.SetDrawColor(FRAME_COL.r, FRAME_COL.g, FRAME_COL.b, 190 * ramp * alphaScale)
				cam.PushModelMatrix(m)
				surface.DrawTexturedRectUV(-len / 2, -thickness / 2, len, thickness, scroll, 0, scroll + uSpan, 1)
				cam.PopModelMatrix()
			end
		end

		render.SetStencilEnable(false)

		-- Extraction feedback sits INSIDE the panel, along the bottom edge
		if wep:GetExtracting() then
			local a, b = pts[4], pts[3]
			local ang = math.deg(math.atan2(b.y - a.y, b.x - a.x))
			local m = Matrix()
			m:Translate(Vector((a.x + b.x) / 2, (a.y + b.y) / 2, 0))
			m:Rotate(Angle(0, ang, 0))
			cam.PushModelMatrix(m)
			draw.SimpleTextOutlined(string.format("Collecting mana dust  +%d", wep:GetBufferedDust()), "Arcana_AncientSmall", 0, -16, ColorAlpha(ArtDeco.Colors.paleGold, 255 * ramp * alphaScale), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, 1, ColorAlpha(OUTLINE_COL, 220 * ramp * alphaScale))
			cam.PopModelMatrix()
		end

		drawEdgeHalos(pts, cx, cy, ramp * alphaScale)
	end

	-- Bloom halo copy strength, tuned like the altar glyphs: the bloom only
	-- ever sees a faint version so the blur becomes a hugging glow instead of
	-- swallowing the shapes
	local FRAME_BLOOM_ALPHA = 0.45

	local function drawPanelFrame(uv, ramp, wep)
		local w, h = ScrW(), ScrH()
		local pts = {}
		local cx, cy = 0, 0
		for idx = 1, 4 do
			pts[idx] = {x = uv[idx].x * w, y = uv[idx].y * h}
			cx = cx + pts[idx].x * 0.25
			cy = cy + pts[idx].y * 0.25
		end

		local bloom = Arcana.Bloom
		if bloom and bloom.ProcessBloom then
			bloom.ProcessBloom(function()
				drawFrameLayers(pts, cx, cy, ramp, wep, FRAME_BLOOM_ALPHA)
			end)
			bloom.RenderBloom(0.35, true)
		end

		drawFrameLayers(pts, cx, cy, ramp, wep, 1)
	end

	-- Constrains the through-wall reveal (clouds, crystal ghosts, grains) to
	-- the panel's window: outside it, only the edge halos hint at sources
	-- Stencil layout: bit 1 = panel window, bit 2 = crystal silhouettes,
	-- bit 8 = the viewmodel's silhouette (marked by the viewmodel pass, see
	-- the vmmask hook).  All panel layers require bit 1 set AND bit 8 clear,
	-- so the hand keeps its original rendering on top of the hologram.
	local function beginPanelStencil(pts)
		render.SetStencilEnable(true)
		render.SetStencilTestMask(255)
		render.SetStencilFailOperation(STENCIL_KEEP)
		render.SetStencilZFailOperation(STENCIL_KEEP)
		render.SetStencilCompareFunction(STENCIL_ALWAYS)
		render.SetStencilPassOperation(STENCIL_REPLACE)

		render.OverrideColorWriteEnable(true, false)
		draw.NoTexture()
		surface.SetDrawColor(255, 255, 255, 255)

		-- Clear everything EXCEPT the hand bit the viewmodel pass just wrote
		render.SetStencilWriteMask(247)
		render.SetStencilReferenceValue(0)
		surface.DrawRect(0, 0, ScrW(), ScrH())

		-- Mark the window (bit 1), again without touching the hand bit
		render.SetStencilReferenceValue(1)
		surface.DrawPoly(pts)
		render.OverrideColorWriteEnable(false)

		render.SetStencilWriteMask(255)
		render.SetStencilCompareFunction(STENCIL_EQUAL)
		render.SetStencilPassOperation(STENCIL_KEEP)
	end

	local function endPanelStencil()
		render.SetStencilEnable(false)
	end

	-- ========================================================================
	-- CUBE COMPASS
	-- ========================================================================
	-- The siphon is a magical box: a hollow frosted-glass cube on thin metal
	-- rails, lit from within, cradled in the palm.  Inside it a magical arrow
	-- points at the closest mana source.  The bugbait mesh is hidden via bone
	-- collapse and the box takes its place at the hand bone.
	local CUBE_GLASS = Material("models/props_c17/frostedglass_01a")
	local CUBE_TINT = Color(222, 198, 120)
	local CUBE_HALF = 1.6

	-- Stone gray, matching the shader path's rails
	local CUBE_FRAME_COL = Color(122, 118, 112)
	local CUBE_FRAME_T = 0.05

	local function quadBoth(a, b, c, d, col)
		render.DrawQuad(a, b, c, d, col)
		render.DrawQuad(d, c, b, a, col)
	end

	-- A square-section bar of real geometry from a to b.  NOT render.DrawBeam:
	-- beams are camera-facing quads, so an edge pointing at the viewer splays
	-- into a wide diagonal slab straight across the cube's face.
	local function drawBar(a, b, u, v, t)
		local du, dv = u * t, v * t
		local a1, a2, a3, a4 = a + du + dv, a + du - dv, a - du - dv, a - du + dv
		local b1, b2, b3, b4 = b + du + dv, b + du - dv, b - du - dv, b - du + dv

		quadBoth(a1, a2, b2, b1, CUBE_FRAME_COL)
		quadBoth(a2, a3, b3, b2, CUBE_FRAME_COL)
		quadBoth(a3, a4, b4, b3, CUBE_FRAME_COL)
		quadBoth(a4, a1, b1, b4, CUBE_FRAME_COL)
		quadBoth(a1, a2, a3, a4, CUBE_FRAME_COL)
		quadBoth(b1, b2, b3, b4, CUBE_FRAME_COL)
	end

	-- Dark metal frame on the 12 edges, teal glass panes inset inside it.  The
	-- panes are painted back to front (and on both windings) so the far glass
	-- shows through the near glass, and they thicken at grazing angles.
	local function drawCube(center, ang, half)
		local axes = {ang:Forward(), ang:Right(), ang:Up()}
		local t = half * CUBE_FRAME_T
		local inset = half - t * 1.2
		local eye = EyePos()

		render.SetColorMaterial()

		for i = 1, 3 do
			local d = axes[i]
			local u, v = axes[i % 3 + 1], axes[(i + 1) % 3 + 1]

			for _, su in ipairs({1, -1}) do
				for _, sv in ipairs({1, -1}) do
					local o = center + u * (half * su) + v * (half * sv)
					drawBar(o - d * half, o + d * half, u, v, t)
				end
			end
		end

		local panes = {}
		for i = 1, 3 do
			local n = axes[i]
			local u, v = axes[i % 3 + 1], axes[(i + 1) % 3 + 1]

			for _, s in ipairs({1, -1}) do
				local p = center + n * (half * s)
				panes[#panes + 1] = {p = p, n = n * s, u = u * inset, v = v * inset, d = p:DistToSqr(eye)}
			end
		end

		table.sort(panes, function(x, y) return x.d > y.d end)

		for _, pane in ipairs(panes) do
			local toEye = eye - pane.p
			toEye:Normalize()

			-- Fresnel: glass seen edge-on saturates to aqua, seen face-on it is
			-- the milky white of the lit cavity behind it
			local grazing = 1 - math.abs(pane.n:Dot(toEye))
			local milk = 1 - grazing
			local col = Color(
				CUBE_TINT.r + (245 - CUBE_TINT.r) * milk,
				CUBE_TINT.g + (252 - CUBE_TINT.g) * milk,
				CUBE_TINT.b + (250 - CUBE_TINT.b) * milk,
				70 + 130 * grazing
			)
			quadBoth(pane.p + pane.u + pane.v, pane.p + pane.u - pane.v, pane.p - pane.u - pane.v, pane.p - pane.u + pane.v, col)
		end
	end

	-- ------------------------------------------------------------------------
	-- The box proper: a local-space unit cube (spanning [-1,1] on each axis)
	-- shaded entirely by arcana_manabox_ps30, which raycasts the cavity in that
	-- same local space.  The model matrix carries it to the palm at the right
	-- size, so one mesh serves both the viewmodel and the world model.
	-- ------------------------------------------------------------------------
	local boxMesh

	-- Faces are wound clockwise as seen from outside (Source's front winding);
	-- the desired normal decides which way the pair of tangents goes.
	local function addQuad(c, u, v, n)
		if u:Cross(v):Dot(n) < 0 then
			u, v = v, u
		end

		local p = {c - u + v, c + u + v, c + u - v, c - u - v}
		local uvs = {{0, 1}, {1, 1}, {1, 0}, {0, 0}}

		for _, idx in ipairs({1, 2, 3, 1, 3, 4}) do
			mesh.Position(p[idx])
			mesh.Normal(n)
			mesh.TexCoord(0, uvs[idx][1], uvs[idx][2])
			mesh.Color(255, 255, 255, 255)
			mesh.AdvanceVertex()
		end
	end

	-- Six glass panes and nothing else: the shader's pane borders and inner
	-- cavity seams draw the edges themselves
	local function getBoxMesh()
		if boxMesh then return boxMesh end

		local axes = {Vector(1, 0, 0), Vector(0, 1, 0), Vector(0, 0, 1)}
		local quads = {}

		for i = 1, 3 do
			local n = axes[i]
			local u, v = axes[i % 3 + 1], axes[(i + 1) % 3 + 1]

			for _, s in ipairs({1, -1}) do
				quads[#quads + 1] = {c = n * s, u = u, v = v, n = n * s}
			end
		end

		boxMesh = Mesh()
		mesh.Begin(boxMesh, MATERIAL_TRIANGLES, #quads * 2)

		for _, q in ipairs(quads) do
			addQuad(q.c, q.u, q.v, q.n)
		end

		mesh.End()

		return boxMesh
	end

	local BOX_SHADER_PS = "arcana_manabox_ps30"
	local BOX_SHADER_VS = "arcana_manabox_vs30"

	local boxMat
	-- One material for viewmodel and world: real depth test (screenspace_general
	-- does none unless asked), no depth write (translucent glass).  The box is
	-- drawn in PostDrawPlayerHands, AFTER the hands render, so it z-tests
	-- against their depth: fingers in front occlude it, the palm behind shows
	-- through the glass.
	WaitForShaderMounted({BOX_SHADER_PS, BOX_SHADER_VS}, function(available)
		if not available then return end

		boxMat = CreateShaderMaterial("arcana_manabox", {
			["$pixshader"] = BOX_SHADER_PS,
			["$vertexshader"] = BOX_SHADER_VS,
			["$vertexnormal"] = 1,
			["$vertexcolor"] = 1,
			["$vertexalpha"] = 1,
			["$translucent"] = 1,
			["$ignorez"] = 0,
			["$depthtest"] = 1,
			-- No depth writes: pure painter's order, far cull pass then near
			["$writedepth"] = 0,
			-- every $c component set at draw time must be declared here,
			-- otherwise SetFloat on it is silently ignored
			["$c0_x"] = 0, ["$c0_y"] = 0, ["$c0_z"] = 0, ["$c0_w"] = 0,
			["$c1_x"] = 1, ["$c1_y"] = 1, ["$c1_z"] = 0, ["$c1_w"] = 0.16,
			["$c2_x"] = 0.5, ["$c2_y"] = 0.5, ["$c2_z"] = 0.5, ["$c2_w"] = 1,
			["$c3_x"] = 0.5, ["$c3_y"] = 0.49, ["$c3_z"] = 0.47, ["$c3_w"] = 0.55,
		})
	end)

	-- Dormant the box is a dark gray slab; live it takes the holo panel's own
	-- pale gold (FRAME_COL), so box and panel read as one apparatus
	local BOX_IDLE_TINT = Color(52, 54, 58)

	local BOX_SCALE = Vector(1, 1, 1)

	-- Two passes with opposite culling: the far half of the box, then whatever
	-- lives inside it (core glow, compass arrow), then the near half.  A convex
	-- shell has no self-overlap within either half, so that is the whole sort.
	local function drawManaBox(mat, center, ang, half, wep, drawInterior)
		local eyeLocal = WorldToLocal(EyePos(), angle_zero, center, ang) / half
		local now = RealTime()

		-- The box wakes when it is in use (sight panel up, or siphoning) and
		-- goes back to dormant gray stone otherwise; the fraction is smoothed
		-- so the transition sweeps instead of popping
		local awake = false
		local glow = 0.78 + 0.16 * math.sin(now * 2.2)
		local fill = 1
		if IsValid(wep) and wep.GetSourceKind then
			awake = (wep.GetSightActive and wep:GetSightActive() or false) or wep:GetExtracting()
			fill = wep:GetSourceKind() == KIND_NONE and 0.35 or (0.5 + 0.5 * wep:GetSourceStrength())
			if wep:GetExtracting() then
				glow = glow + 0.4 + 0.12 * math.sin(now * 14)
			end
		end

		-- Waking is paced to the wrist ceremony: full brightness lands exactly
		-- as the band ring appears (3 * GLYPH_STEP + BAND_DELAY = ~1s).
		-- Going dormant is quicker, matching the poof.
		local target = awake and 1 or 0
		local prev = wep._boxActive or 0
		local step = FrameTime() / (target > prev and 1.0 or 0.3)
		local active = prev < target and math.min(target, prev + step) or math.max(target, prev - step)
		wep._boxActive = active
		glow = glow * (0.2 + 0.8 * active)

		-- Live, the box throws the panel's light onto the hand and its
		-- surroundings
		if active > 0.05 then
			local dl = DynamicLight(wep:EntIndex())
			if dl then
				dl.pos = center
				dl.r = FRAME_COL.r
				dl.g = FRAME_COL.g
				dl.b = FRAME_COL.b
				dl.brightness = 2.5 * active
				dl.size = 60 * half * active
				dl.decay = 1000
				dl.dietime = CurTime() + 0.1
			end
		end

		BOX_SCALE.x, BOX_SCALE.y, BOX_SCALE.z = half, half, half

		local m = Matrix()
		m:SetTranslation(center)
		m:SetAngles(ang)
		m:SetScale(BOX_SCALE)

		mat:SetFloat("$c0_x", eyeLocal.x)
		mat:SetFloat("$c0_y", eyeLocal.y)
		mat:SetFloat("$c0_z", eyeLocal.z)
		mat:SetFloat("$c0_w", math.fmod(now, 1000))
		mat:SetFloat("$c1_x", glow)
		mat:SetFloat("$c1_y", fill)
		mat:SetFloat("$c1_z", active)

		-- Dormant the box is lit geometry, not a light source: sample the
		-- world light where it sits (linear -> gamma, the abyss-cap pattern)
		-- so the slab tracks the room's lighting
		local light = render.ComputeLighting(center, ang:Up())
		mat:SetFloat("$c3_x", math.Clamp(math.pow(math.max(light.x, 0), 0.4545), 0.03, 1))
		mat:SetFloat("$c3_y", math.Clamp(math.pow(math.max(light.y, 0), 0.4545), 0.03, 1))
		mat:SetFloat("$c3_z", math.Clamp(math.pow(math.max(light.z, 0), 0.4545), 0.03, 1))
		mat:SetFloat("$c2_x", Lerp(active, BOX_IDLE_TINT.r, FRAME_COL.r) / 255)
		mat:SetFloat("$c2_y", Lerp(active, BOX_IDLE_TINT.g, FRAME_COL.g) / 255)
		mat:SetFloat("$c2_z", Lerp(active, BOX_IDLE_TINT.b, FRAME_COL.b) / 255)

		local built = getBoxMesh()
		render.SetMaterial(mat)

		-- Far half FIRST: with our winding the CCW pass rasterizes the panes
		-- facing away (their insides), the CW pass the panes facing the eye.
		-- Painter's order does the sorting, so the near glass must go last or
		-- the interior walls paint over it.
		cam.PushModelMatrix(m)
		render.CullMode(MATERIAL_CULLMODE_CCW)
		built:Draw()
		cam.PopModelMatrix()

		if drawInterior then
			drawInterior()
		end

		cam.PushModelMatrix(m)
		render.CullMode(MATERIAL_CULLMODE_CW)
		render.SetMaterial(mat)
		built:Draw()
		cam.PopModelMatrix()
		render.CullMode(MATERIAL_CULLMODE_CCW)
	end

	-- The bugbait ball rides its own bones (the arms use the ValveBiped rig),
	-- so collapsing those bones removes the mesh.  SetSubMaterial does NOT
	-- stick on viewmodels: it reads back empty and the ball keeps rendering.
	local BALL_BONES = {"ValveBiped.cube", "ValveBiped.cube1", "ValveBiped.cube2", "ValveBiped.cube3"}
	local BALL_HIDDEN = Vector(0, 0, 0)

	-- The palm's own frame, derived from the hand bone and the finger bases:
	-- centre of the palm, the plane it lies in, and the normal coming out of
	-- it.  Anchoring to this beats hand-tuned offsets, which drift with the
	-- pose (the ball bones, for one, hover well clear of the fingertips).
	local function palmFrame(vm)
		local function bonePos(name)
			local b = vm:LookupBone(name)
			local m = b and vm:GetBoneMatrix(b)
			return m and m:GetTranslation()
		end

		local hand = bonePos("ValveBiped.Bip01_R_Hand")
		local index = bonePos("ValveBiped.Bip01_R_Finger1")
		local middle = bonePos("ValveBiped.Bip01_R_Finger2")
		local pinky = bonePos("ValveBiped.Bip01_R_Finger4")
		if not (hand and index and middle and pinky) then return end

		local center = (hand + index + middle + pinky) * 0.25
		local along = middle - hand
		local normal = (index - pinky):Cross(along)
		normal:Normalize()

		if normal:Dot(EyePos() - center) < 0 then
			normal = -normal
		end

		return center, along:AngleEx(normal), normal
	end

	local function hideBugbaitMesh(vm)
		for _, name in ipairs(BALL_BONES) do
			local b = vm:LookupBone(name)
			if b and vm:GetManipulateBoneScale(b) ~= BALL_HIDDEN then
				vm:ManipulateBoneScale(b, BALL_HIDDEN)
			end
		end
	end

	-- The magical pointer: a glowing shaft with four swept-back fins and a
	-- bright tip, pointing from the cube's centre toward the nearest source
	local function drawCompassArrow(wep, center)
		if wep:GetSourceKind() == KIND_NONE then return end

		local dir = wep:GetSourcePos() - EyePos()
		dir:Normalize()

		local now = RealTime()
		local pulse = 0.8 + 0.2 * math.sin(now * 3)
		local ang = dir:Angle()
		local up, right = ang:Up(), ang:Right()
		local tail = center - dir * 1.4
		local tip = center + dir * 1.4

		render.SetMaterial(BEAM_MAT)
		render.DrawBeam(tail, tip, 0.7, 0, 1, ColorAlpha(COLOR_MANA, 235 * pulse))
		render.DrawBeam(tip, tip - dir * 0.9 + right * 0.5, 0.45, 0, 1, ColorAlpha(COLOR_MANA, 210 * pulse))
		render.DrawBeam(tip, tip - dir * 0.9 - right * 0.5, 0.45, 0, 1, ColorAlpha(COLOR_MANA, 210 * pulse))
		render.DrawBeam(tip, tip - dir * 0.9 + up * 0.5, 0.45, 0, 1, ColorAlpha(COLOR_MANA, 210 * pulse))
		render.DrawBeam(tip, tip - dir * 0.9 - up * 0.5, 0.45, 0, 1, ColorAlpha(COLOR_MANA, 210 * pulse))

		render.SetMaterial(GRAIN_MAT)
		render.DrawSprite(tip, 1.6 * pulse, 1.6 * pulse, ColorAlpha(COLOR_GHOST, 255))
		render.DrawSprite(center, 3.2 * pulse, 3.2 * pulse, ColorAlpha(COLOR_MANA, 60))
	end

	-- ------------------------------------------------------------------------
	-- SIGHT TRANSITION
	-- Turning sight on kindles four glyphs around the wrist one after another,
	-- each with a chime (the emissary's shelf ceremony, worn small); once all
	-- four stand, a spinning band ring takes their place at the same radius
	-- and colour.  Turning sight off poofs a puff of brass dust off the cube.
	-- ------------------------------------------------------------------------
	local GLYPH_CODES = {65, 66, 67, 68, 69, 70, 71, 72}
	local GLYPH_STEP = 0.22 -- seconds between glyph appearances
	local GLYPH_IN = 0.15 -- each glyph's kindle time
	local GLYPH_FADE = 0.25 -- fade as the band replaces them
	local BAND_DELAY = 0.35 -- hold after the 4th glyph before the band
	local WRIST_BACK = 5.5 -- wrist centre, back from the palm along the forearm
	local WRIST_RING_R = 3.0 -- hugging the forearm

	local SIPHON_GLYPH_MATS = {}
	for _, code in ipairs(GLYPH_CODES) do
		SIPHON_GLYPH_MATS[code] = CreateMaterial("arcana_siphon_glyph_" .. code, "UnlitGeneric", {
			["$basetexture"] = "arcana/glyphs/glyph_" .. code,
			["$translucent"] = 1,
			["$vertexalpha"] = 1,
			["$vertexcolor"] = 1,
		})
	end

	local function wristFrame(palmPos, palmAng)
		local pos = palmPos - palmAng:Forward() * WRIST_BACK
		-- Band rings wrap their angles' Up axis: point it along the forearm
		local ang = palmAng:Forward():Angle()
		ang:RotateAroundAxis(ang:Right(), 90)

		return pos, ang
	end

	-- The four glyph anchors around the wrist, shared by the sequence and the
	-- band handoff so the ring truly replaces them in place
	local function glyphAnchor(wristPos, palmAng, i)
		local theta = math.rad((i - 1) * 90 + 45)
		local radial = palmAng:Right() * math.cos(theta) + palmAng:Up() * math.sin(theta)

		return wristPos + radial * WRIST_RING_R, radial
	end

	local function drawWristGlyphs(wep, wristPos, palmAng, now, alphaScale)
		local seq = wep._glyphSeq
		if not seq then return end

		local fadeMul = 1
		if seq.fadeAt then
			fadeMul = 1 - math.Clamp((now - seq.fadeAt) / GLYPH_FADE, 0, 1)
			if fadeMul <= 0 then return end
		end

		for i = 1, 4 do
			local t = now - (seq.startedAt + (i - 1) * GLYPH_STEP)
			if t < 0 then continue end

			local a = math.Clamp(t / GLYPH_IN, 0, 1)
			a = a * a * (3 - 2 * a)

			local pos, radial = glyphAnchor(wristPos, palmAng, i)
			local size = 2.1 * (0.6 + 0.4 * a)
			local mat = SIPHON_GLYPH_MATS[seq.codes[i]]
			if mat then
				render.SetMaterial(mat)
				render.DrawQuadEasy(pos, radial, size, size, ColorAlpha(FRAME_COL, 255 * a * fadeMul * alphaScale), 0)
			end
		end
	end

	-- Same faint-copy-into-bloom-then-crisp pattern as the panel dressing
	local function drawWristGlyphsBloomed(wep, wristPos, palmAng, now)
		if not wep._glyphSeq then return end

		local bloom = Arcana.Bloom
		if bloom and bloom.ProcessBloom then
			bloom.ProcessBloom(function()
				drawWristGlyphs(wep, wristPos, palmAng, now, FRAME_BLOOM_ALPHA)
			end)
			bloom.RenderBloom(0.35, true)
			-- RT pushes reset the vm depth-range hack (see the panel notes)
			render.DepthRange(0, 0.1)
		end

		drawWristGlyphs(wep, wristPos, palmAng, now, 1)
	end

	-- Advances the sequence clock: chimes each glyph in as it appears, then
	-- hands over to the band ring
	local function updateSightTransition(wep, wristPos, bandAng, now)
		local seq = wep._glyphSeq
		if not seq then return end

		if not seq.fadeAt then
			local visible = math.Clamp(math.floor((now - seq.startedAt) / GLYPH_STEP) + 1, 0, 4)
			while (seq.played or 0) < visible do
				seq.played = (seq.played or 0) + 1
				LocalPlayer():EmitSound("arcana/arcane_" .. math.random(1, 3) .. ".ogg", 60, 96 + seq.played * 6, 0.5)
			end

			-- All four stand: the band ring takes their place
			if now >= seq.startedAt + 3 * GLYPH_STEP + BAND_DELAY then
				local BandCircle = Arcana.Circle and Arcana.Circle.BandCircle
				if BandCircle and BandCircle.Create then
					local bc = BandCircle.Create(wristPos, bandAng, FRAME_COL, WRIST_RING_R, 0)
					if bc then
						bc:SetDrawnManually(true)
						bc:AddBand(WRIST_RING_R, 1.9, {p = 0, y = 120, r = 0}, 2)
						bc:StartEvolving(0.35)
						wep._wristBand = bc
					end
				end

				-- The lens panel waits for the ceremony: it only materializes
				-- once the band has taken over (see the PreDrawHUD gate)
				wep._panelReady = true
				seq.fadeAt = now
			end
		elseif now > seq.fadeAt + GLYPH_FADE then
			wep._glyphSeq = nil
		end
	end

	-- The off-poof: brass dust puffing off the cube, simulated right here in
	-- vm space so it stays glued to the hand
	-- Two size classes: quick bright dust and slower billowing puffs, under a
	-- brief core flash where the cube exhales
	local POOF_COUNT = 34

	local function spawnPoof(wep, center, palmAng, now)
		local parts = {born = now, center = center}

		for i = 1, POOF_COUNT do
			local dir = VectorRand()
			dir:Normalize()

			local puff = i % 3 == 0
			parts[#parts + 1] = {
				pos = center + dir * math.Rand(0.2, 1.4),
				vel = dir * (puff and math.Rand(4, 10) or math.Rand(9, 24)) + palmAng:Up() * math.Rand(0, 5),
				born = now + math.Rand(0, 0.06),
				life = puff and math.Rand(0.7, 1.1) or math.Rand(0.35, 0.7),
				size = puff and math.Rand(1.8, 3.0) or math.Rand(0.7, 1.4),
				grow = puff and 2.4 or 1.4,
				alpha = puff and 120 or 220,
			}
		end

		wep._poof = parts
	end

	-- The band ring is drawn from the panel pass (PreDrawHUD), AFTER the lens
	-- has graded the frame, so it reads as apparatus over the hologram rather
	-- than scenery under it.  It renders through a camera replicating the
	-- engine's vm projection (the enchant-ring pattern), anchored on the wrist
	-- frame the hands pass cached this frame.
	local function drawWristBand(wep)
		local bc = wep._wristBand
		if not bc then return end

		if not (bc.IsActive and bc:IsActive()) then
			wep._wristBand = nil
			return
		end

		-- No fresh wrist frame (thirdperson, vm hidden): nothing to anchor to
		if RealTime() - (wep._wristFrameAt or 0) > 0.1 then return end

		bc.position = wep._wristPos
		bc.angles = wep._bandAng

		local view = render.GetViewSetup()
		local vmFov = view.fovviewmodel or view.fovviewmodel_unscaled or 54
		local vmZNear = view.znearviewmodel or 1
		local vmZFar = view.zfarviewmodel or view.zfar or 28000

		-- vm depth range so the band z-tests against the arm already in the
		-- buffer instead of raw world depth
		local function bandCam()
			cam.Start3D(view.origin, view.angles, vmFov, 0, 0, ScrW(), ScrH(), vmZNear, vmZFar)
			render.DepthRange(0, 0.1)
		end

		-- Faint copy feeds the bloom, crisp bands on top (panel pattern)
		local bloom = Arcana.Bloom
		if bloom and bloom.ProcessBloom then
			local col = bc.color
			bc.color = ColorAlpha(col, (col.a or 255) * FRAME_BLOOM_ALPHA)
			bloom.ProcessBloom(function()
				bandCam()
				bc:Draw()
				cam.End3D()
			end)
			bc.color = col
			bloom.RenderBloom(0.35, true)
		end

		bandCam()
		bc:Draw()
		cam.End3D()
		render.DepthRange(0, 1)
	end

	local POOF_BRIGHT = Color(255, 228, 165)
	local POOF_FLASH_TIME = 0.18

	local function drawPoof(wep, now)
		local parts = wep._poof
		if not parts then return end

		local dt = FrameTime()
		local alive = false
		render.SetMaterial(GRAIN_MAT)

		-- Core flash where the cube exhaled
		local flashAge = now - (parts.born or now)
		if flashAge < POOF_FLASH_TIME then
			local f = 1 - flashAge / POOF_FLASH_TIME
			render.DrawSprite(parts.center, 5 * f, 5 * f, ColorAlpha(POOF_BRIGHT, 230 * f))
			alive = true
		end

		for _, p in ipairs(parts) do
			local age = now - p.born
			if age >= 0 and age < p.life then
				alive = true
				p.vel = p.vel * (1 - math.min(dt * 3.5, 0.5))
				p.pos = p.pos + p.vel * dt

				local frac = age / p.life
				local col = frac < 0.4 and POOF_BRIGHT or FRAME_COL
				local size = p.size * (1 + frac * (p.grow or 1.6))
				render.DrawSprite(p.pos, size, size, ColorAlpha(col, (p.alpha or 220) * (1 - frac)))
			elseif age < 0 then
				-- Not born yet (staggered burst): keep the system alive
				alive = true
			end
		end

		if not alive then
			wep._poof = nil
		end
	end

	-- PostDrawPlayerHands, NOT PostDrawViewModel: the hands entity renders
	-- after the viewmodel pass, so anything drawn from the vm hook gets painted
	-- over by the hand (it writes no depth for the hand to test against).
	-- Here both the vm's and the hands' depth is on screen and the box's
	-- depth-tested material sorts against it for free.
	local inVMMask = false
	hook.Add("PostDrawPlayerHands", "arcana_mana_siphon_cube", function(hands, vm, _, wep)
		if inVMMask then return end
		if not IsValid(wep) or wep:GetClass() ~= "arcana_mana_siphon" then return end

		hideBugbaitMesh(vm)

		-- Sat on the palm plane, oriented with it, so it reads as held: no
		-- spin, no bob, it only moves when the hand does
		local palmPos, palmAng = palmFrame(vm)
		if not palmPos then return end

		-- Forward runs up the fingers, Up comes out of the palm: rest the cube
		-- ON the palm plane (bottom face just clear of the skin), shifted back
		-- toward the wrist, out of the fingers
		-- The palm frame's plane runs through the bone centres, inside the
		-- flesh: the extra 1.8 is skin clearance.  The lift scales with the
		-- cube so resizing it keeps the same clearance.
		local center = palmPos - palmAng:Forward() * 0.3 - palmAng:Right() * 0.5 + palmAng:Up() * (CUBE_HALF + 2.4)

		local sightOn = wep.GetSightActive and wep:GetSightActive() or false
		-- The hand mask must persist through the shutdown iris, or the
		-- retracting panel grades the hand for its last fraction of a second
		local maskOn = sightOn or RealTime() < panelClosingUntil

		-- While sight is on, everything drawn here also stamps stencil bit 8
		-- (the hand layer), which the lens and panel layers exclude: the hand,
		-- cube and arrow render on top of the hologram untouched
		if maskOn then
			render.SetStencilEnable(true)
			render.SetStencilTestMask(255)
			render.SetStencilWriteMask(8)
			render.SetStencilCompareFunction(STENCIL_ALWAYS)
			render.SetStencilPassOperation(STENCIL_REPLACE)
			render.SetStencilFailOperation(STENCIL_KEEP)
			render.SetStencilZFailOperation(STENCIL_KEEP)

			-- Drop last frame's hand bit first, or the panel inherits holes
			-- where the hand used to be
			render.SetStencilReferenceValue(0)
			render.OverrideColorWriteEnable(true, false)
			cam.Start2D()
			draw.NoTexture()
			surface.SetDrawColor(255, 255, 255, 255)
			surface.DrawRect(0, 0, ScrW(), ScrH())
			cam.End2D()
			render.OverrideColorWriteEnable(false)
			render.SetStencilReferenceValue(8)

			-- The hands are a separate entity: re-rasterize them purely so
			-- their silhouette lands in the mask (identical pixels repaint)
			if IsValid(hands) then
				inVMMask = true
				hands:DrawModel()
				inVMMask = false
			end
		end

		-- The cavity's contents, drawn between the box's far and near halves.
		-- Plain depth-tested draws: the hand depth is already on screen, so
		-- fingers curling in front occlude the arrow like they occlude the box
		local function drawInterior()
			render.SetMaterial(GRAIN_MAT)
			render.DrawSprite(center, 2.6, 2.6, ColorAlpha(COLOR_GHOST, 90))
			drawCompassArrow(wep, center)
		end

		if boxMat then
			drawManaBox(boxMat, center, palmAng, CUBE_HALF, wep, drawInterior)
		else
			drawInterior()
			drawCube(center, palmAng, CUBE_HALF)
		end

		if maskOn then
			render.SetStencilEnable(false)
		end

		-- Sight toggle transitions.  Everything below runs with the stencil
		-- dropped: the glyph bloom would otherwise stamp the hand bit across
		-- the whole frame and kill the panel (see the panel notes above).
		local now = RealTime()

		if wep._sightWas == nil then
			wep._sightWas = sightOn
		elseif sightOn ~= wep._sightWas then
			wep._sightWas = sightOn

			if sightOn then
				-- Four distinct glyphs per activation
				local pool = {65, 66, 67, 68, 69, 70, 71, 72}
				local codes = {}
				for i = 1, 4 do
					codes[i] = table.remove(pool, math.random(#pool))
				end

				wep._glyphSeq = {startedAt = now, codes = codes, played = 0}
			else
				-- Shutdown ceremony, in stages: the band collapses onto the
				-- wrist with a low chime while the panel irises back into the
				-- palm; the poof punctuates the moment the panel lands
				wep._glyphSeq = nil
				wep._panelReady = nil
				wep._poofAt = now + IRIS_OUT_TIME
				LocalPlayer():EmitSound("arcana/arcane_" .. math.random(1, 3) .. ".ogg", 60, 72, 0.4)

				if wep._wristBand then
					wep._wristBand:SetScale(0, 0.3)
					wep._wristBand:Remove()
				end
			end

			if sightOn and wep._wristBand then
				-- Re-activation while the old band still lingers: drop it, the
				-- fresh ceremony brings its own
				wep._wristBand:Remove()
				wep._wristBand = nil
			end
		end

		-- The delayed poof: fires as the retracting panel reaches the palm
		if wep._poofAt and now >= wep._poofAt then
			wep._poofAt = nil
			spawnPoof(wep, center, palmAng, now)
			LocalPlayer():EmitSound("ambient/wind/wind_hit1.wav", 55, 135, 0.35)
		end

		local wristPos, bandAng = wristFrame(palmPos, palmAng)
		updateSightTransition(wep, wristPos, bandAng, now)
		drawWristGlyphsBloomed(wep, wristPos, palmAng, now)

		-- The band ring itself is drawn from the panel pass (drawWristBand),
		-- over the lens; this pass just publishes the wrist frame it anchors to
		wep._wristPos = wristPos
		wep._bandAng = bandAng
		wep._wristFrameAt = now

		drawPoof(wep, now)
	end)

	-- PreDrawHUD, not RenderScreenspaceEffects: the crystal's dispersion pass
	-- (and other screenspace participants) must all be on screen before the
	-- lens grades the frame, and hook order within one event is undefined
	hook.Add("PreDrawHUD", "arcana_mana_siphon_sight", function()
		local wep = getActiveSiphon()
		if not wep then
			wasSightOn = false
			return
		end

		-- The panel waits for the wrist ceremony: sight counts as "on" here
		-- only once the band ring has replaced the glyphs, so the lens
		-- materializes out of the finished ritual (edge detection below then
		-- starts the iris at that moment)
		local isOn = (wep.GetSightActive and wep:GetSightActive() or false) and wep._panelReady == true

		if isOn and not wasSightOn then
			sightOnSince = RealTime()
			panelAng = nil
			panelRoll = 0
		elseif not isOn and wasSightOn then
			-- Shutdown: the panel retracts into the palm before letting go
			panelClosingUntil = RealTime() + IRIS_OUT_TIME
		end
		wasSightOn = isOn

		-- While closing, the whole panel path below keeps running with the
		-- iris reversed, shrinking the window back into the hand
		local closingFrac
		if not isOn then
			local remain = panelClosingUntil - RealTime()
			if remain > 0 then
				closingFrac = remain / IRIS_OUT_TIME
			end
		end

		if not isOn and not closingFrac then
			-- Sight off (or the wrist ceremony still running): only the
			-- extraction visuals, in full colour, plus whatever the band ring
			-- is doing (fading out, or growing in before the panel opens)
			cam.Start3D()
			drawSiphonGas(wep)
			wep:_DrawSiphonMotes()
			cam.End3D()
			drawWristBand(wep)
			return
		end

		-- The visor is a first-person apparatus: in thirdperson (or any view
		-- that draws the local player) the panel makes no sense
		local ply = LocalPlayer()
		if IsValid(ply) and ply:ShouldDrawLocalPlayer() then return end

		local corners, ramp = computePanelCorners(closingFrac)
		local uv = projectCorners(corners)

		if uv then
			local w, h = ScrW(), ScrH()
			local pts = {}
			for idx = 1, 4 do
				pts[idx] = {x = uv[idx].x * w, y = uv[idx].y * h}
			end

			beginPanelStencil(pts)

			-- Lens pass, stencil-gated to the window
			if sightMat then
				local rt = GetRenderTarget("arcana_manasight_rt", w, h)
				render.CopyRenderTargetToTexture(rt)
				sightMat:SetTexture("$basetexture", rt)
				sightMat:SetFloat("$c0_x", math.fmod(RealTime(), 1000))
				sightMat:SetFloat("$c0_y", ramp)
				sightMat:SetFloat("$c0_z", w / h)
				sightMat:SetFloat("$c1_x", uv[1].x)
				sightMat:SetFloat("$c1_y", uv[1].y)
				sightMat:SetFloat("$c1_z", uv[2].x)
				sightMat:SetFloat("$c1_w", uv[2].y)
				sightMat:SetFloat("$c2_x", uv[3].x)
				sightMat:SetFloat("$c2_y", uv[3].y)
				sightMat:SetFloat("$c2_z", uv[4].x)
				sightMat:SetFloat("$c2_w", uv[4].y)

				render.SetMaterial(sightMat)
				render.DrawScreenQuad()
			end

			drawSightWorld()
			endPanelStencil()
		end

		-- The siphoned gas and motes stay vivid over the graded frame,
		-- unmasked: mana keeps its colour whether seen through the panel or
		-- beside it
		cam.Start3D()
		cam.IgnoreZ(true)
		drawSiphonGas(wep)
		wep:_DrawSiphonMotes()
		cam.IgnoreZ(false)
		cam.End3D()

		if uv then
			drawPanelFrame(uv, ramp, wep)
		end

		-- Last: the wrist band draws over everything the panel put up
		drawWristBand(wep)
	end)

	-- ========================================================================
	-- SIPHON MOTES
	-- ========================================================================
	-- The channel in Arcana's own language: the source sheds tiny dust motes
	-- that spiral outward, then get drawn through the air to the hand in soft
	-- converging arcs.  Each mote is simulated (attraction + damping), so every
	-- path curls differently.  No beams.
	local MOTE_SPAWN_INTERVAL = 0.04
	local MOTE_MAX_AGE = 6

	function SWEP:_UpdateSiphonMotes()
		local motes = self._siphonMotes
		if not motes then
			motes = {}
			self._siphonMotes = motes
		end

		local owner = self:GetOwner()
		if not IsValid(owner) then return end

		local now = RealTime()
		local dt = FrameTime()
		local hand = siphonHandPos(owner)

		if self:GetExtracting() and now >= (self._nextSiphonMote or 0) then
			self._nextSiphonMote = now + MOTE_SPAWN_INTERVAL

			local src = self:GetSourcePos()
			local spread = self:GetSourceKind() == KIND_CRYSTAL and 26 or 40
			local offset = VectorRand() * spread
			offset.z = math.abs(offset.z) * 0.8

			-- Tangential launch: the mote unwinds from the source before the
			-- pull toward the hand takes over
			local tangent = Vector(-offset.y, offset.x, 0)
			tangent:Normalize()

			motes[#motes + 1] = {
				pos = src + offset,
				vel = tangent * math.Rand(30, 70) + Vector(0, 0, math.Rand(20, 45)),
				size = math.Rand(1, 2.2),
				born = now,
			}
		end

		for i = #motes, 1, -1 do
			local m = motes[i]
			local toHand = hand - m.pos

			if toHand:Length() < 10 or now - m.born > MOTE_MAX_AGE then
				table.remove(motes, i)
			else
				-- The pull strengthens with age so fresh motes drift lazily
				-- and old ones commit to the hand
				local pull = 220 + (now - m.born) * 320
				m.vel = m.vel + toHand:GetNormalized() * pull * dt
				m.vel = m.vel * (1 - math.min(dt * 1.6, 0.5))
				m.pos = m.pos + m.vel * dt
			end
		end
	end

	function SWEP:_DrawSiphonMotes()
		local motes = self._siphonMotes
		if not motes or #motes == 0 then
			return
		end

		local now = RealTime()
		render.SetMaterial(GRAIN_MAT)

		for _, m in ipairs(motes) do
			local age = now - m.born
			local alpha = 255 * math.Clamp(age / 0.25, 0, 1)
			render.DrawSprite(m.pos, m.size, m.size, ColorAlpha(COLOR_GHOST, alpha))
		end

		-- Faint shimmer where the dust sinks into the palm
		if self:GetExtracting() then
			local owner = self:GetOwner()
			if IsValid(owner) then
				local hand = siphonHandPos(owner)
				for i = 1, 3 do
					local a = now * 3.5 + i * (math.pi * 2 / 3)
					local p = hand + Vector(math.cos(a) * 3.5, math.sin(a) * 3.5, math.sin(now * 2.5 + i) * 2)
					render.DrawSprite(p, 1.5, 1.5, ColorAlpha(COLOR_MANA, 190))
				end
			end
		end
	end

	-- ========================================================================
	-- SOUND, LIFECYCLE
	-- ========================================================================
	function SWEP:_StopSightSound()
		if self._sightSnd then
			self._sightSnd:Stop()
			self._sightSnd = nil
		end
	end

	-- Bone manipulations are shared entity state: restore the ball's bones so
	-- the real bugbait (and anything else on this viewmodel) is unaffected
	local BALL_SHOWN = Vector(1, 1, 1)
	local function restoreViewModelMaterials()
		local ply = LocalPlayer()
		local vm = IsValid(ply) and ply:GetViewModel() or nil
		if not IsValid(vm) then return end

		for _, name in ipairs(BALL_BONES) do
			local b = vm:LookupBone(name)
			if b then
				vm:ManipulateBoneScale(b, BALL_SHOWN)
			end
		end
	end

	function SWEP:_ClearSightTransition()
		if self._wristBand then
			self._wristBand:Remove()
			self._wristBand = nil
		end

		self._glyphSeq = nil
		self._poof = nil
		self._poofAt = nil
		self._sightWas = nil
		self._panelReady = nil
	end

	function SWEP:OnRemove()
		self:_StopSightSound()
		self:_ClearSightTransition()
		restoreViewModelMaterials()
	end

	function SWEP:Holster()
		self:_StopSightSound()
		self._siphonMotes = nil
		self:_ClearSightTransition()
		restoreViewModelMaterials()
		return true
	end

	function SWEP:Think()
		self:_UpdateSiphonMotes()

		-- Low hum while mana sight is on
		if self:GetSightActive() then
			if not self._sightSnd then
				self._sightSnd = CreateSound(self, "ambient/levels/citadel/field_loop2.wav")
				if self._sightSnd then
					self._sightSnd:PlayEx(0.22, 85)
				end
			end
		else
			self:_StopSightSound()
		end
	end

	-- No flat HUD in either mode: the cube compass is the sight-off locator,
	-- and everything else lives on the holo panel
	function SWEP:DrawHUD()
	end

	-- The world model is the same box, at held-item scale (the vm cube reads
	-- bigger than it is because of the vm fov).  A held weapon's own position
	-- is the owner's, so the box is anchored on the right hand bone the way
	-- the grimoire anchors its book; only a dropped siphon uses its own
	-- transform.
	local WORLD_HALF = 2.2
	local HAND_ATTACHMENT_POS = Vector(2.676, -1.712, 0)
	local HAND_ATTACHMENT_ROLL = 180

	local HAND_BONE_NAMES = {
		"ValveBiped.Bip01_R_Hand",
		"Bip01 R Hand",
		"bip_hand_R",
		"hand_R",
		"RightHand",
		"mixamorig:RightHand",
	}

	-- Bone ids are per model, so the cache is keyed by model path
	local handBoneCache = {}

	local function getHandBone(owner)
		local model = owner:GetModel()
		local cached = handBoneCache[model]
		if cached ~= nil then return cached or nil end

		for _, name in ipairs(HAND_BONE_NAMES) do
			local boneId = owner:LookupBone(name)
			if boneId then
				handBoneCache[model] = boneId
				return boneId
			end
		end

		handBoneCache[model] = false

		return nil
	end

	-- The palm frame from the finger bones, same construction as the vm path:
	-- it tracks the actual pose, so the cube sits on the palm and its edges
	-- align with the hand instead of hanging off a fixed attachment offset.
	-- For a right hand (index - pinky) x (middle - hand) IS the outward palm
	-- normal, no eye-flip needed.
	local function worldPalmFrame(owner)
		local function bonePos(name)
			local b = owner:LookupBone(name)
			local m = b and owner:GetBoneMatrix(b)
			return m and m:GetTranslation()
		end

		local hand = bonePos("ValveBiped.Bip01_R_Hand")
		local index = bonePos("ValveBiped.Bip01_R_Finger1")
		local middle = bonePos("ValveBiped.Bip01_R_Finger2")
		local pinky = bonePos("ValveBiped.Bip01_R_Finger4")
		if not (hand and index and middle and pinky) then return nil end

		local center = (hand + index + middle + pinky) * 0.25
		local along = middle - hand
		local normal = (index - pinky):Cross(along)
		normal:Normalize()

		return center, along:AngleEx(normal)
	end

	local function worldBoxFrame(wep)
		local owner = wep:GetOwner()
		if not IsValid(owner) then return wep:GetPos(), wep:GetAngles() end

		-- Bone matrices can be stale on a player the client has not animated
		-- this frame; the engine no-ops this when they are already fresh
		owner:SetupBones()

		local palmPos, palmAng = worldPalmFrame(owner)
		if palmPos then
			-- Resting on the palm, nudged back toward the wrist like the vm cube
			return palmPos - palmAng:Forward() * 0.3 + palmAng:Up() * (WORLD_HALF + 0.4), palmAng
		end

		-- Rigs without ValveBiped fingers: the rebuilt hand attachment frame
		local boneId = getHandBone(owner)
		local matrix = boneId and owner:GetBoneMatrix(boneId)
		if not matrix then return wep:GetPos(), wep:GetAngles() end

		local ang = matrix:GetAngles()
		local pos = matrix:GetTranslation()
		pos = pos + ang:Forward() * HAND_ATTACHMENT_POS.x + ang:Right() * HAND_ATTACHMENT_POS.y + ang:Up() * HAND_ATTACHMENT_POS.z
		ang:RotateAroundAxis(ang:Forward(), HAND_ATTACHMENT_ROLL)

		return pos + ang:Up() * (WORLD_HALF + 0.2) - ang:Forward() * 1, ang
	end

	-- The translucent box cannot draw from DrawWorldModel: that runs in entity
	-- render order, often BEFORE the owner's body is in the depth buffer, so
	-- the body (opaque, drawn later) paints over the glass and the box reads
	-- as behind the player.  Drawing after all translucent renderables means
	-- every body is already in the buffer and the depth test sorts it.
	hook.Add("PostDrawTranslucentRenderables", "arcana_mana_siphon_worldbox", function(depth, skybox)
		if depth or skybox then return end
		if not boxMat then return end

		local lp = LocalPlayer()
		for _, wep in ipairs(ents.FindByClass("arcana_mana_siphon")) do
			local owner = wep:GetOwner()

			-- First person renders the palm cube instead
			if IsValid(owner) and owner == lp and not lp:ShouldDrawLocalPlayer() then continue end
			-- Holstered weapons on players are not visible
			if IsValid(owner) and owner:IsPlayer() and owner:GetActiveWeapon() ~= wep then continue end
			if wep:WorldSpaceCenter():DistToSqr(EyePos()) > 3000 * 3000 then continue end

			local pos, ang = worldBoxFrame(wep)
			drawManaBox(boxMat, pos, ang, WORLD_HALF, wep, nil)
		end
	end)

	function SWEP:DrawWorldModel()
		-- Shader path: drawn in PostDrawTranslucentRenderables above
		if boxMat then return end

		render.MaterialOverride(CUBE_GLASS)
		render.SetColorModulation(CUBE_TINT.r / 255, CUBE_TINT.g / 255, CUBE_TINT.b / 255)
		self:DrawModel()
		render.SetColorModulation(1, 1, 1)
		render.MaterialOverride()
	end
end

hook.Add("Initialize", "arcana_mana_siphon_items", function()
	Arcana.RegisterItem("mana_dust", {
		name = "Mana Dust",
		description = "Condensed mana in powder form, gathered with a mana siphon.",
		model = "models/props_lab/jar01a.mdl",
		color = Color(170, 140, 255),
	})
end)
