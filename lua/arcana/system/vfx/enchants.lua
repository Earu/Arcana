if SERVER then return end

-- Arcana: Client-side weapon enchantment VFX (BandCircle rings)
-- Displays 1-3 rotating bands aligned to the weapon's longest axis.
--
-- Load-order contract: init.lua must include circles.lua and arcana/common/ before this file.
-- These file-scope aliases become nil if the load order changes; they are guarded with asserts
-- that surface the problem immediately rather than silently at first render.
assert(Arcana.Circle and Arcana.Circle.BandCircle, "enchant_vfx.lua requires circles.lua to be loaded first")
assert(Arcana.WeaponClassification and Arcana.WeaponClassification.IsMeleeHoldType, "enchant_vfx.lua requires arcana/system/weapon_classification.lua to be loaded first")

local BandCircle = Arcana.Circle.BandCircle

local VFX_DEBUG = CreateConVar("arcana_enchant_vfx_debug", "0", FCVAR_ARCHIVE, "Enchant VFX anchor debug (1 = print chosen anchor, 2 = also draw anchor axes)")

local function vfxDebugPrint(fmt, ...)
	if VFX_DEBUG:GetInt() < 1 then return end
	MsgC(Color(120, 200, 255), "[Arcana EnchantVFX] ", color_white, string.format(fmt, ...), "\n")
end

local ActiveVFXByEnt = ActiveVFXByEnt or {}
-- Bands drawn on UI model panels, keyed by the panel's model entity (see the
-- preview section at the bottom of this file)
local PreviewVFXByEnt = PreviewVFXByEnt or {}
local RESCAN_INTERVAL = 0.50
local lastRescan = 0

local function safeJSONToTable(json)
	local ok, t = pcall(util.JSONToTable, json or "[]")
	return ok and istable(t) and t or {}
end

local function getEnchantCount(wep)
	if not IsValid(wep) then return 0 end
	local json = wep:GetNWString("Arcana_EnchantIds", "[]")
	local arr = safeJSONToTable(json)
	return istable(arr) and #arr or 0
end

local function computeOBBExtents(wep)
	local mins, maxs = wep:OBBMins(), wep:OBBMaxs()
	local size = maxs - mins
	return math.abs(size.x), math.abs(size.y), math.abs(size.z)
end

local function longestAxisInfo(wep)
	local lenX, lenY, lenZ = computeOBBExtents(wep)
	local axis = "x"
	local len = lenX
	if lenY >= len and lenY >= lenZ then
		axis = "y"; len = lenY
	elseif lenZ >= len and lenZ >= lenY then
		axis = "z"; len = lenZ
	end
	local dir = (axis == "x" and wep:GetForward()) or (axis == "y" and wep:GetRight()) or wep:GetUp()
	return axis, dir, len, lenX, lenY, lenZ
end

-- When aligning Up to a chosen axis, use an optional reference forward to stabilize yaw
local function getSecondLongestAxisVector(wep, axis, lenX, lenY, lenZ)
	if not IsValid(wep) then return Vector(1, 0, 0) end
	if axis == "x" then
		if lenY >= lenZ then return wep:GetRight() else return wep:GetUp() end
	elseif axis == "y" then
		if lenX >= lenZ then return wep:GetForward() else return wep:GetUp() end
	else -- axis == "z"
		if lenX >= lenY then return wep:GetForward() else return wep:GetRight() end
	end
end

local function buildOrientedAnglesForAxis(axisDir, owner, refForward)
	-- Build angles such that Up aligns to axisDir.
	-- If owner is valid, use their view/hand-derived right. Otherwise project refForward onto the plane orthogonal to Up.
	local up = axisDir:GetNormalized()
	local forward
	local right
	if IsValid(owner) then
		-- Derive a stable right vector from owner's eye forward projected onto plane orthogonal to Up
		local ref = owner:EyeAngles():Forward()
		right = (ref - up * ref:Dot(up))
		if right:LengthSqr() < 1e-4 then right = Vector(1, 0, 0) end
		right:Normalize()
		forward = right:Cross(up)
	else
		if isvector(refForward) then
			forward = (refForward - up * refForward:Dot(up))
		end
		if (not forward) or forward:LengthSqr() < 1e-4 then
			forward = up:Cross(Vector(0, 0, 1))
			if forward:LengthSqr() < 1e-4 then forward = up:Cross(Vector(1, 0, 0)) end
		end
		forward:Normalize()
		right = forward:Cross(up)
	end

	right:Normalize()
	local ang = forward:Angle()

	-- Roll so that Right matches our computed right
	local curRight = ang:Right()
	local axis = forward
	local cross = curRight:Cross(right)
	local dot = math.Clamp(curRight:Dot(right), -1, 1)
	local sign = (cross:Dot(axis) >= 0) and 1 or -1
	local roll = math.deg(math.atan2(sign * cross:Length(), dot))
	ang:RotateAroundAxis(axis, roll)

	return ang
end

local function isHeldActive(wep)
	local owner = IsValid(wep) and wep:GetOwner() or NULL
	return IsValid(owner) and owner:GetActiveWeapon() == wep
end

-- Some SWEPs (hl2m-style packs) draw their weapon mesh as a throwaway
-- ClientsideModel every frame — created, positioned, drawn and removed inside
-- SWEP:PostDrawViewModel, which runs AFTER all PostDrawViewModel hooks. The mesh
-- is never queryable when we run, so detour Entity.DrawModel (only ever invoked
-- by Lua-side manual draws) to record where such meshes get drawn; eval reads the
-- previous frame's records. Recording only happens on frames flagged by the vm
-- hook, so the detour is a boolean check otherwise. Globals keep the detour
-- single across hot-reloads.
Arcana._VMDrawnModels = Arcana._VMDrawnModels or {}
-- Recording logic lives in a global reassigned on every reload so the
-- once-installed metatable detour always runs the newest version. Two capture
-- gates: _VMDrawCaptureFrame (viewmodel pass, armed same-frame — that works
-- because the SWEP's own vm draws run later in the SAME pass) and
-- _WMCaptureUntil, a rolling RealTime window for the world pass. Frame-number
-- arming does NOT work there: FrameNumber() as read from render hooks never
-- equals FrameNumber() as read inside entity draw calls (measured: 100 draw
-- calls, 0 matches, while probes outside rendering saw flag == FrameNumber()).
function Arcana._DrawModelRecord(ent)
	local fn = FrameNumber()
	if fn ~= Arcana._VMDrawCaptureFrame and RealTime() >= (Arcana._WMCaptureUntil or 0) then return end
	local recs = Arcana._VMDrawnModels
	recs[#recs + 1] = {model = ent:GetModel(), pos = ent:GetPos(), ang = ent:GetAngles(), frame = fn, time = RealTime(), ent = ent}
	if #recs > 64 then table.remove(recs, 1) end
end
if CLIENT and not Arcana._DrawModelDetoured then
	Arcana._DrawModelDetoured = true
	local entMeta = FindMetaTable("Entity")
	local origDrawModel = entMeta.DrawModel
	function entMeta:DrawModel(...)
		Arcana._DrawModelRecord(self)
		return origDrawModel(self, ...)
	end
end

-- Most recent drawn-model record near a viewmodel position (raw vm space on both
-- sides — these packs position their ents from vm bone matrices). Records whose
-- model matches the weapon's WorldModel win: that's the prop such SWEPs paint.
-- excludeEnt filters out the weapon entity itself: a SWEP whose DrawWorldModel
-- just draws the entity produces a record at the entity origin, not at the mesh.
local function findDrawnModelNear(worldPos, preferModel, excludeEnt)
	local recs = Arcana._VMDrawnModels
	local minFrame = FrameNumber() - 1
	local now = RealTime()
	local best, bestDist, bestPreferred = nil, math.huge, false
	for i = #recs, 1, -1 do
		local r = recs[i]
		-- Frame recency for vm records; time recency for world records (frame
		-- counters don't compare across the render boundary, see _DrawModelRecord)
		if (r.frame >= minFrame or (r.time and now - r.time < 0.15)) and (excludeEnt == nil or r.ent ~= excludeEnt) then
			local d = r.pos:DistToSqr(worldPos)
			local preferred = (r.model == preferModel)
			if d < 900 and (preferred and not bestPreferred or preferred == bestPreferred and d < bestDist) then
				best, bestDist, bestPreferred = r, d, preferred
			end
		end
	end
	return best
end

local isMeleeHoldType = Arcana.WeaponClassification.IsMeleeHoldType
local isPistolHoldType = Arcana.WeaponClassification.IsPistolHoldType
local isRifleHoldType = Arcana.WeaponClassification.IsRifleHoldType

local function getPlayerHandPositions(ply)
	if not IsValid(ply) then return nil, nil end
	local rIdx = ply:LookupBone("ValveBiped.Bip01_R_Hand")
	local lIdx = ply:LookupBone("ValveBiped.Bip01_L_Hand")
	local function bonePos(idx)
		if not idx then return nil end
		local m = ply:GetBoneMatrix(idx)
		if m then return m:GetTranslation() end
		local pos, _ = ply:GetBonePosition(idx)
		return pos
	end
	local rp = bonePos(rIdx)
	local lp = bonePos(lIdx)
	if rp and lp then return rp, lp end
	return nil, nil
end

local function getRightHandPose(ply)
	if not IsValid(ply) then return nil, nil end
	local rIdx = ply:LookupBone("ValveBiped.Bip01_R_Hand")
	if not rIdx then return nil, nil end
	local m = ply:GetBoneMatrix(rIdx)
	if m then return m:GetTranslation(), m:GetAngles() end
	local pos, ang = ply:GetBonePosition(rIdx)
	return pos, ang
end

local function getMuzzleAttachmentPos(wep)
	if not (IsValid(wep) and wep.LookupAttachment and wep.GetAttachment) then return nil end
	local candidates = {"muzzle", "muzzle_flash", "muzzle_flash1", "muzzle_end", "1"}
	for _, name in ipairs(candidates) do
		local idx = wep:LookupAttachment(name)
		if idx and idx > 0 then
			local att = wep:GetAttachment(idx)
			if att and att.Pos then return att.Pos end
		end
	end
	return nil
end

-- Build angles given desired Up and Right vectors (orthonormalized)
local function anglesFromUpRight(up, right)
	up = (isvector(up) and up or Vector(0, 0, 1))
	right = (isvector(right) and right or Vector(1, 0, 0))
	if up:LengthSqr() < 1e-6 then up = Vector(0, 0, 1) end
	-- Gram-Schmidt: make right orthogonal to up
	right = right - up * right:Dot(up)
	if right:LengthSqr() < 1e-6 then right = Vector(1, 0, 0) - up * up.x end
	right:Normalize()
	local forward = right:Cross(up)
	if forward:LengthSqr() < 1e-6 then forward = Vector(0, 1, 0) end
	forward:Normalize()
	local ang = forward:Angle()
	-- Adjust roll so computed Right matches target Right
	local curRight = ang:Right()
	local axis = forward
	local cross = curRight:Cross(right)
	local dot = math.Clamp(curRight:Dot(right), -1, 1)
	local sign = (cross:Dot(axis) >= 0) and 1 or -1
	local roll = math.deg(math.atan2(sign * cross:Length(), dot))
	ang:RotateAroundAxis(axis, roll)
	return ang
end

--
-- Viewmodel anchor resolution
--
-- Finds a good point on the viewmodel to attach the rings to, trying tiers in order:
-- preferred named attachments -> any attachment scored by name -> bones scored by name
-- -> farthest-forward bone -> synthetic eye-space offset (always succeeds).
-- An anchor is { kind = "attachment"|"bone"|"synthetic", id = number|nil, name = string, model = string }.
--

local PREFERRED_ATTACHMENTS = {"muzzle", "muzzle_flash", "muzzle_flash1", "muzzle_end", "1", "0"}

local ATT_EXCLUDES = {"eye", "camera"}
local ATT_SCORES = {
	{"muzzle", 100}, {"barrel", 80}, {"silencer", 75}, {"tip", 70},
	{"front", 65}, {"blade", 60}, {"end", 60}, {"flash", 55},
	{"smoke", 45}, {"shell", 25}, {"eject", 25},
}

local BONE_EXCLUDES = {"camera"}
local BONE_SCORES_AXIS = {
	{"muzzle", 100}, {"barrel", 90}, {"tip", 85}, {"blade", 80},
	{"v_weapon", 70}, {"weapon", 65}, {"hand", 40},
}
local BONE_SCORES_ORBITAL = {
	{"hand", 70}, {"v_weapon", 50}, {"weapon", 45},
}

local LEFT_HAND_TOKENS = {"l_hand", "l hand", "lefthand", "left_hand", "hand_l", "hand l"}
local RIGHT_HAND_TOKENS = {"r_hand", "r hand", "righthand", "right_hand", "hand_r", "hand r"}

local function nameHasToken(lname, tokens)
	for _, tok in ipairs(tokens) do
		if lname:find(tok, 1, true) then return true end
	end
	return false
end

-- "hand" but not "handle": weapon-body bones like v_weapon.Knife_Handle are not hands
local function isHandBoneName(name)
	if not isstring(name) then return false end
	local lname = name:lower()
	if lname:find("handle", 1, true) then return false end
	return lname:find("hand", 1, true) ~= nil
end

local function scoreName(name, patterns, excludes, numericScore)
	if not isstring(name) or name == "" then return 0 end
	local lname = name:lower()
	for _, pat in ipairs(excludes) do
		if lname:find(pat, 1, true) then return -1 end
	end
	local best = 0
	for _, entry in ipairs(patterns) do
		if entry[2] > best and lname:find(entry[1], 1, true) then
			best = entry[2]
		end
	end
	if best == 0 and numericScore and lname:match("^%d+$") then
		best = numericScore
	end
	return best
end

-- Attachment/bone data on viewmodels lives in vm-FOV space near the eye; reject
-- broken data sitting at the world origin or absurdly far from the camera
local function isSaneVMSpacePos(pos, eyePos)
	if not isvector(pos) then return false end
	if pos:LengthSqr() < 1 then return false end
	if pos:DistToSqr(eyePos) > 200 * 200 then return false end
	return true
end

-- eyeFwd is only passed at resolve time: candidates must sit in front of the eye
-- (lowered/holstered off-hands park at the eye plane). Per-frame eval skips the gate
-- so animations can swing an anchor around without flagging it stale.
local function evalAttachment(vm, id, eyePos, eyeFwd)
	local att = vm:GetAttachment(id)
	if not (att and att.Pos and isSaneVMSpacePos(att.Pos, eyePos)) then return nil end
	if eyeFwd and (att.Pos - eyePos):Dot(eyeFwd) < 3 then return nil end
	return att.Pos, att.Ang
end

local function evalBone(vm, id, eyePos, eyeFwd)
	local m = vm:GetBoneMatrix(id)
	if not m then
		vm:SetupBones()
		m = vm:GetBoneMatrix(id)
		if not m then return nil end
	end
	local pos = m:GetTranslation()
	if not isSaneVMSpacePos(pos, eyePos) then return nil end
	if eyeFwd and (pos - eyePos):Dot(eyeFwd) < 3 then return nil end
	return pos, m:GetAngles()
end

local function resolvePreferredAttachment(vm, eyePos, eyeFwd)
	for _, name in ipairs(PREFERRED_ATTACHMENTS) do
		local idx = vm:LookupAttachment(name)
		if idx and idx > 0 and evalAttachment(vm, idx, eyePos, eyeFwd) then
			return {kind = "attachment", id = idx, name = name}
		end
	end
	return nil
end

local function resolveScoredAttachment(vm, eyePos, eyeFwd)
	local atts = vm:GetAttachments()
	if not istable(atts) then return nil end
	local bestScore, bestAnchor = 0, nil
	local bestFwd, fwdAnchor = 4, nil
	for _, att in ipairs(atts) do
		local score = scoreName(att.name, ATT_SCORES, ATT_EXCLUDES, 15)
		local pos = (score >= 0) and evalAttachment(vm, att.id, eyePos, eyeFwd) or nil
		if pos then
			if score > bestScore then
				bestScore = score
				bestAnchor = {kind = "attachment", id = att.id, name = att.name}
			end
			local d = eyeFwd:Dot(pos - eyePos)
			if d > bestFwd then
				bestFwd = d
				fwdAnchor = {kind = "attachment", id = att.id, name = att.name}
			end
		end
	end
	-- Weak name matches lose to geometry: the muzzle is almost always the
	-- farthest-forward attachment, while weakly-scored names can mark the wrong
	-- end of things ("bolt_end" on the crossbow is the bolt's REAR)
	if bestScore < 70 and fwdAnchor then return fwdAnchor end
	return bestAnchor
end

local function resolveScoredBone(vm, eyePos, eyeFwd, style, side, preferHands)
	local patterns = (style == "orbital") and BONE_SCORES_ORBITAL or BONE_SCORES_AXIS
	local offTokens = (side == "left") and RIGHT_HAND_TOKENS or LEFT_HAND_TOKENS
	local onTokens = (side == "left") and LEFT_HAND_TOKENS or RIGHT_HAND_TOKENS
	local offWord = (side == "left") and "right" or "left"
	local onWord = (side == "left") and "left" or "right"
	local bestScore, bestAnchor = 0, nil
	for i = 0, vm:GetBoneCount() - 1 do
		local name = vm:GetBoneName(i)
		local score = scoreName(name, patterns, BONE_EXCLUDES)
		if score > 0 then
			local lname = name:lower()
			if nameHasToken(lname, offTokens) or lname:find(offWord, 1, true) then
				-- Wrong-side bone: last-resort fallback only (some rigs hold the weapon there)
				score = 15
			elseif nameHasToken(lname, onTokens) or lname:find(onWord, 1, true) then
				local onsideBoost = (style == "orbital") and 90 or 60
				-- Melee: the fist's grip axis is anatomically fixed, making hand bones
				-- more reliable blade references than weapon bones with arbitrary axes
				if preferHands and isHandBoneName(name) then onsideBoost = 75 end
				score = math.max(score, onsideBoost)
			end
		end
		if score > bestScore and evalBone(vm, i, eyePos, eyeFwd) then
			bestScore = score
			bestAnchor = {kind = "bone", id = i, name = name or tostring(i)}
		end
	end
	return bestAnchor
end

-- Melee rigs that carry weapon bones tell us which fist actually grips the weapon:
-- anchor the hand bone nearest to the best-scored weapon bone. Some models hold
-- melee weapons in the left hand, so bone names alone pick the wrong fist.
local function resolveMeleeHandBone(vm, eyePos, eyeFwd)
	local bestScore, weaponPos = 0, nil
	for i = 0, vm:GetBoneCount() - 1 do
		local name = vm:GetBoneName(i)
		if name and not isHandBoneName(name) then
			local score = scoreName(name, BONE_SCORES_AXIS, BONE_EXCLUDES)
			if score > bestScore then
				local pos = evalBone(vm, i, eyePos, eyeFwd)
				if pos then
					bestScore = score
					weaponPos = pos
				end
			end
		end
	end
	if not weaponPos then return nil end
	local bestDist, bestAnchor = math.huge, nil
	for i = 0, vm:GetBoneCount() - 1 do
		local name = vm:GetBoneName(i)
		if name and isHandBoneName(name) then
			local pos = evalBone(vm, i, eyePos, eyeFwd)
			if pos then
				local d = pos:DistToSqr(weaponPos)
				if d < bestDist then
					bestDist = d
					bestAnchor = {kind = "bone", id = i, name = name}
				end
			end
		end
	end
	return bestAnchor
end

-- Geometric fallback: the valid bone that sits farthest ahead of the eye while staying
-- close to the view axis is usually the weapon's tip
local function resolveForwardBone(vm, eyePos, eyeFwd)
	local bestDist, bestAnchor = 4, nil
	for i = 0, vm:GetBoneCount() - 1 do
		local pos = evalBone(vm, i, eyePos)
		if pos then
			local name = vm:GetBoneName(i)
			if scoreName(name, {}, BONE_EXCLUDES) >= 0 then
				local rel = pos - eyePos
				local d = eyeFwd:Dot(rel)
				if d > bestDist and (rel - eyeFwd * d):Length() < 30 then
					bestDist = d
					bestAnchor = {kind = "bone", id = i, name = name or tostring(i)}
				end
			end
		end
	end
	return bestAnchor
end

-- A resolve that runs on the exact model-switch frame can bind against the previous
-- model's bone/attachment table (the engine refreshes them a frame late). Detect this
-- by checking that the cached ids still map to the same names on the current model.
local function isAnchorStale(vm, anchor)
	if anchor.kind == "bone" then
		return (vm:GetBoneName(anchor.id) or tostring(anchor.id)) ~= anchor.name
	elseif anchor.kind == "attachment" then
		return vm:LookupAttachment(anchor.name) ~= anchor.id
	end
	return false
end

local function resolveVMAnchor(vm, wep, style, eyePos, eyeAng, side)
	vm:SetupBones()
	side = side or "right"
	local eyeFwd = eyeAng:Forward()
	local anchor
	if style == "dual" then
		-- Attachment names can't tell the two guns apart; anchor each side to its hand
		anchor = resolveScoredBone(vm, eyePos, eyeFwd, "axis", side)
	elseif style == "orbital" then
		anchor = resolveScoredBone(vm, eyePos, eyeFwd, "orbital", side)
			or resolvePreferredAttachment(vm, eyePos, eyeFwd)
			or resolveScoredAttachment(vm, eyePos, eyeFwd)
	elseif isMeleeHoldType(wep) then
		-- Melee models' numeric attachments rarely mark the blade; trust bones first
		anchor = resolveMeleeHandBone(vm, eyePos, eyeFwd)
			or resolveScoredBone(vm, eyePos, eyeFwd, "axis", side, true)
			or resolvePreferredAttachment(vm, eyePos, eyeFwd)
			or resolveScoredAttachment(vm, eyePos, eyeFwd)
			or resolveForwardBone(vm, eyePos, eyeFwd)
	else
		anchor = resolvePreferredAttachment(vm, eyePos, eyeFwd)
			or resolveScoredAttachment(vm, eyePos, eyeFwd)
			or resolveScoredBone(vm, eyePos, eyeFwd, "axis", side)
			or resolveForwardBone(vm, eyePos, eyeFwd)
	end

	anchor = anchor or {kind = "synthetic", name = "eye-offset"}
	anchor.model = vm:GetModel() or ""
	anchor.side = side
	anchor.resolvedAt = CurTime()
	vfxDebugPrint("%s (%s/%s): anchor=%s '%s' id=%s model=%s", wep:GetClass(), style, side, anchor.kind, anchor.name, tostring(anchor.id), anchor.model)
	return anchor
end

-- Synthetic anchors are a last resort (often the product of a deploy animation holding
-- the weapon out of the view cone); keep retrying until something real resolves
local function needsReresolve(vm, anchor, vmModel)
	if not anchor then return true end
	if anchor.model ~= vmModel then return true end
	if anchor.kind == "synthetic" then
		return CurTime() - (anchor.resolvedAt or 0) > 0.5
	end
	return isAnchorStale(vm, anchor)
end

-- Eye-space offsets (forward, right, up) roughly matching where viewmodels hold the weapon
local function getSyntheticVMOffset(wep)
	local ht = (wep.GetHoldType and wep:GetHoldType() or ""):lower()
	if ht == "duel" then return Vector(18, 5, -4) end
	if isRifleHoldType(wep) then return Vector(28, 7, -5) end
	if isPistolHoldType(wep) then return Vector(20, 6, -5) end
	if isMeleeHoldType(wep) then return Vector(16, 8, -6) end
	return Vector(14, 6, -6)
end

local BONE_BASIS_AXES = {"Forward", "Right", "Up"}

-- Build ring angles from the anchor basis, but never trust a basis that is wildly
-- misaligned with the view direction (broken rigs would render skewed rings)
local function stableVMAngles(rawAng, eyeAng, kind, style, wep, anchorName)
	if style == "orbital" then
		return anglesFromUpRight(Vector(0, 0, 1), eyeAng:Right())
	end

	local eyeFwd = eyeAng:Forward()
	if rawAng then
		if kind == "attachment" then
			local f = rawAng:Forward()
			if f:Dot(eyeFwd) >= 0.5 then
				return anglesFromUpRight(f, rawAng:Right())
			end
		elseif kind == "bone" then
			-- Bone bases are arbitrary: pick whichever axis best aligns with the view direction
			local bestDot, bestAxis = 0.5, nil
			for _, getter in ipairs(BONE_BASIS_AXES) do
				local axisVec = rawAng[getter](rawAng)
				local d = axisVec:Dot(eyeFwd)
				if d > bestDot then
					bestDot = d
					bestAxis = axisVec
				elseif -d > bestDot then
					bestDot = -d
					bestAxis = -axisVec
				end
			end
			if bestAxis then
				return anglesFromUpRight(bestAxis, eyeAng:Right())
			end
		end
	end

	return anglesFromUpRight(eyeFwd, eyeAng:Right())
end

-- How far to slide melee rings from the grip towards the blade tip: measure the
-- model's extent along the blade axis so short weapons (bottles, knives) don't
-- get rings floating past their tip
local function getMeleeBladeSlide(vm, fromPos, bladeDir)
	local mins, maxs = vm:GetRenderBounds()
	if not (mins and maxs) then return 10 end
	local maxExt = 0
	for i = 0, 7 do
		local corner = Vector(
			bit.band(i, 1) == 0 and mins.x or maxs.x,
			bit.band(i, 2) == 0 and mins.y or maxs.y,
			bit.band(i, 4) == 0 and mins.z or maxs.z)
		local d = (vm:LocalToWorld(corner) - fromPos):Dot(bladeDir)
		if d > maxExt then maxExt = d end
	end
	if maxExt <= 2 then return 8 end
	-- Arms inflate the bounds, so the factor usually saturates the max — keep it
	-- short-blade sized: everything long resolves via hitboxes or drawn records
	return math.Clamp(maxExt * 0.6, 4, 10)
end

-- Dominant principal axis of a vertex cloud via covariance power iteration.
-- feed(cb) must call cb(pos) for every vertex. startAxis seeds the iteration
-- and provides a trust gate: returns nil when the cloud is degenerate or the
-- principal axis disagrees with startAxis by more than ~45 deg. Used to refine
-- AABB dominant axes: boxes wrap diagonal meshes (a gun whose barrel runs
-- slanted through its bone frame) with their long axis snapped to a cardinal
-- direction, while the principal axis follows the actual mesh elongation.
local function computePrincipalAxis(feed, startAxis)
	local sx, sy, sz, n = 0, 0, 0, 0
	local xx, yy, zz, xy, xz, yz = 0, 0, 0, 0, 0, 0
	feed(function(p)
		sx, sy, sz, n = sx + p.x, sy + p.y, sz + p.z, n + 1
		xx, yy, zz = xx + p.x * p.x, yy + p.y * p.y, zz + p.z * p.z
		xy, xz, yz = xy + p.x * p.y, xz + p.x * p.z, yz + p.y * p.z
	end)
	if n < 16 then return nil end
	local mx, my, mz = sx / n, sy / n, sz / n
	local cxx, cyy, czz = xx / n - mx * mx, yy / n - my * my, zz / n - mz * mz
	local cxy, cxz, cyz = xy / n - mx * my, xz / n - mx * mz, yz / n - my * mz
	local v = Vector(startAxis.x, startAxis.y, startAxis.z)
	if v:LengthSqr() < 0.5 then v = Vector(1, 0, 0) end
	for _ = 1, 32 do
		local nv = Vector(
			cxx * v.x + cxy * v.y + cxz * v.z,
			cxy * v.x + cyy * v.y + cyz * v.z,
			cxz * v.x + cyz * v.y + czz * v.z)
		if nv:LengthSqr() < 1e-9 then return nil end
		nv:Normalize()
		v = nv
	end
	if v:Dot(startAxis) < 0 then v = -v end
	if v:Dot(startAxis) < 0.7 then return nil end
	return v
end

-- Principal axis of the verts weighted to one bone, in that bone's local space
-- (same bind-pose transform convention as getBladeFromMesh)
local function computeBonePrincipalAxis(mdl, boneId, boxAxis)
	local meshes, bindPose = util.GetModelMeshes(mdl, 0, 0)
	local bind = meshes and bindPose and bindPose[boneId]
	if not (bind and bind.matrix) then return nil end
	local m = bind.matrix
	return computePrincipalAxis(function(cb)
		for _, mesh in ipairs(meshes) do
			for _, vert in ipairs(mesh.triangles or {}) do
				local bId, bestW = nil, 0.5
				for _, w in ipairs(vert.weights or {}) do
					if w.weight > bestW then bestW, bId = w.weight, w.bone end
				end
				if bId == boneId then cb(m * vert.pos) end
			end
		end
	end, boxAxis)
end

-- Long-axis info of a model's AABB ({center, axis, len} in model space), for
-- meshes we can't query through the viewmodel (custom-draw SWEPs paint props by
-- hand). Cached per model; false when the model can't be loaded.
local modelBladeCache = {}
local function getModelBladeInfo(mdl)
	local cached = modelBladeCache[mdl]
	if cached ~= nil then return cached or nil end
	cached = false
	local ent = ClientsideModel(mdl, RENDERGROUP_OTHER)
	if IsValid(ent) then
		local mins, maxs = ent:GetModelBounds()
		if mins and maxs then
			local size = maxs - mins
			local axis, len = Vector(1, 0, 0), size.x
			if size.y > len then axis, len = Vector(0, 1, 0), size.y end
			if size.z > len then axis, len = Vector(0, 0, 1), size.z end
			local center = (mins + maxs) * 0.5
			if center:Dot(axis) < 0 then axis = -axis end
			cached = {center = center, axis = axis, len = len}
			-- Model-space principal axis (see computePrincipalAxis); verts come
			-- back in bind-pose model space, which is what drawn-record props use
			local meshes = util.GetModelMeshes(mdl, 0, 0)
			if meshes then
				cached.pcaAxis = computePrincipalAxis(function(cb)
					for _, mesh in ipairs(meshes) do
						for _, vert in ipairs(mesh.triangles or {}) do
							cb(vert.pos)
						end
					end
				end, axis)
			end
		end
		ent:Remove()
	end
	modelBladeCache[mdl] = cached
	return cached or nil
end

local function boneDescendsFrom(vm, boneId, ancestorId)
	for _ = 1, 4 do
		if boneId == ancestorId then return true end
		boneId = vm:GetBoneParent(boneId)
		if not boneId or boneId < 0 then return false end
	end
	return false
end

local BODY_BONE_TOKENS = {"arm", "clavicle", "spine", "shoulder", "elbow", "neck", "pelvis", "finger", "wrist", "hand"}
local function isBodyBoneName(name)
	local lname = (name or ""):lower()
	for _, tok in ipairs(BODY_BONE_TOKENS) do
		if lname:find(tok, 1, true) then return true end
	end
	return false
end

-- Dominant axis of a local-space AABB: center, unit axis (signed towards the
-- centroid — the heavy side is the blade on melee), length, elongation, and the
-- two cross-section extents perpendicular to the dominant axis
local function dominantAxisOfBox(mins, maxs)
	local size = maxs - mins
	local axis, len = Vector(1, 0, 0), size.x
	local crossA, crossB = size.y, size.z
	if size.y > len then
		axis, len, crossA, crossB = Vector(0, 1, 0), size.y, size.x, size.z
	end
	if size.z > len then
		axis, len, crossA, crossB = Vector(0, 0, 1), size.z, size.x, size.y
	end
	local center = (mins + maxs) * 0.5
	if center:Dot(axis) < 0 then axis = -axis end
	return center, axis, len, len / math.max(1, math.max(crossA, crossB)), crossA, crossB
end

-- Weapon meshes rigidly skinned to bones get hitboxes that tightly wrap them.
-- A long hitbox on the anchor bone (or a child of it — gun barrels live on slide
-- bones) beats every heuristic: it yields the blade axis and the mesh centerline
-- (bones often sit off it). The most elongated qualifying box wins: a thin barrel
-- box describes the weapon line better than a chunky frame-plus-grip box.
-- minLen filters out boxes that are just fists/fingers.
local function getBladeHitbox(vm, anchorBoneId, minLen, excludeBody)
	local best
	for group = 0, (vm:GetHitboxSetCount() or 1) - 1 do
		for hb = 0, (vm:GetHitBoxCount(group) or 0) - 1 do
			local boneId = vm:GetHitBoxBone(hb, group)
			if boneId and (anchorBoneId == nil or boneDescendsFrom(vm, boneId, anchorBoneId))
				and not (excludeBody and isBodyBoneName(vm:GetBoneName(boneId))) then
				local mins, maxs = vm:GetHitBoxBounds(hb, group)
				if mins and maxs then
					local center, axis, len, aspect, crossA, crossB = dominantAxisOfBox(mins, maxs)
					if len >= minLen and (not best or aspect > best.aspect) then
						best = {
							center = center, axis = axis, len = len, bone = boneId, aspect = aspect,
							crossR = 0.5 * math.sqrt(crossA * crossA + crossB * crossB),
							mins = mins, maxs = maxs,
						}
					end
				end
			end
		end
	end
	if best then return best.center, best.axis, best.len, best.bone, best.crossR, best.mins, best.maxs end
end

-- Synthetic per-bone hitbox measured from the model's own vertices, for rigs
-- that ship no usable hitboxes (CS:S knives). Verts weighted to a bone, taken
-- in that bone's bind-pose space, bound exactly the geometry that bone drives —
-- including depth lean the hand-bone axes can't express. One-time per model,
-- then evaluated like a real hitbox on the live bone matrix.
local meshBladeCache = {}
local function getBladeFromMesh(vm, anchorBoneId, minLen, excludeBody)
	local key = (vm:GetModel() or "") .. "/" .. tostring(anchorBoneId) .. (excludeBody and "!b" or "")
	local cands = meshBladeCache[key]
	if cands == nil then
		cands = {}
		local meshes, bindPose = util.GetModelMeshes(vm:GetModel() or "", 0, 0)
		if meshes and bindPose then
			local boxes = {}
			for _, mesh in ipairs(meshes) do
				for _, vert in ipairs(mesh.triangles or {}) do
					local boneId, bestW = nil, 0.5
					for _, w in ipairs(vert.weights or {}) do
						if w.weight > bestW then bestW, boneId = w.weight, w.bone end
					end
					if boneId and (anchorBoneId == nil or boneDescendsFrom(vm, boneId, anchorBoneId))
						and not (excludeBody and isBodyBoneName(vm:GetBoneName(boneId))) then
						local bind = bindPose[boneId]
						if bind and bind.matrix then
							local box = boxes[boneId]
							if not box then
								box = {
									mins = Vector(math.huge, math.huge, math.huge),
									maxs = Vector(-math.huge, -math.huge, -math.huge),
								}
								boxes[boneId] = box
							end
							-- bindPose matrices are the INVERSE bind transforms: they map
							-- bind-pose model space straight into bone-local space
							local lp = bind.matrix * vert.pos
							box.mins.x = math.min(box.mins.x, lp.x)
							box.mins.y = math.min(box.mins.y, lp.y)
							box.mins.z = math.min(box.mins.z, lp.z)
							box.maxs.x = math.max(box.maxs.x, lp.x)
							box.maxs.y = math.max(box.maxs.y, lp.y)
							box.maxs.z = math.max(box.maxs.z, lp.z)
						end
					end
				end
			end
			for boneId, box in pairs(boxes) do
				local center, axis, len, aspect, crossA, crossB = dominantAxisOfBox(box.mins, box.maxs)
				local depth, walker = 0, boneId
				for _ = 1, 16 do
					walker = vm:GetBoneParent(walker)
					if not walker or walker < 0 then break end
					depth = depth + 1
				end
				cands[#cands + 1] = {
					center = center, axis = axis, len = len, bone = boneId, aspect = aspect, depth = depth,
					crossR = 0.5 * math.sqrt(crossA * crossA + crossB * crossB),
					mins = box.mins, maxs = box.maxs,
				}
			end
		end
		meshBladeCache[key] = cands
	end
	local bestAspect = 0
	for _, c in ipairs(cands) do
		if c.len >= minLen then bestAspect = math.max(bestAspect, c.aspect) end
	end
	if bestAspect <= 0 then return nil end
	local best, bestIsBlade
	for _, c in ipairs(cands) do
		-- Near-tied elongations (a balisong's blade vs its handles): a bone
		-- literally named after the blade wins outright; otherwise resolve by
		-- hierarchy — moving parts (handles, slides) hang off the main body
		-- bone, which carries the blade — preferring the shallowest cluster
		if c.len >= minLen and c.aspect >= bestAspect * 0.8 then
			local lname = (vm:GetBoneName(c.bone) or ""):lower()
			local isBlade = lname:find("blade", 1, true) ~= nil or lname:find("tip", 1, true) ~= nil
			local better
			if not best then
				better = true
			elseif isBlade ~= bestIsBlade then
				better = isBlade
			elseif c.depth ~= best.depth then
				better = c.depth < best.depth
			else
				better = c.aspect > best.aspect
			end
			if better then best, bestIsBlade = c, isBlade end
		end
	end
	return best.center, best.axis, best.len, best.bone, best.crossR, best.mins, best.maxs
end

--
-- Held (third-person) weapon geometry
--
-- Bonemerged world models expose live bone matrices, their own hitbox sets and
-- mesh data, but the entity's angles are just the owner's yaw — so placement
-- must come from per-bone geometry, never from OBB axes. Resolve a bone-local
-- box once per model (shipped hitboxes first, mesh vertices as fallback) and
-- evaluate it per frame on the live bone matrix.
local heldGeoCache = {}
local function resolveHeldWeaponGeometry(wep)
	local mdl = wep:GetModel() or ""
	if mdl == "" then return nil end
	local cached = heldGeoCache[mdl]
	if cached then
		if not cached.fail then return cached end
		if cached.tries >= 3 or CurTime() < cached.nextTry then return nil end
	end

	-- excludeBody first: c_models carry arm/hand bones in the world mesh. But most
	-- w_ models hang their entire mesh off a bone literally named
	-- ValveBiped.Bip01_R_Hand (that's how bonemerge attaches them), so when the
	-- body filter leaves nothing, retry without it — there are no real arms in
	-- that case, the "hand" bone IS the weapon.
	local center, axis, len, bone, crossR, mins, maxs = getBladeHitbox(wep, nil, 8, true)
	local source = "hitbox"
	if not axis then
		center, axis, len, bone, crossR, mins, maxs = getBladeFromMesh(wep, nil, 6, true)
		source = "mesh"
	end
	if not axis then
		center, axis, len, bone, crossR, mins, maxs = getBladeHitbox(wep, nil, 8, false)
		source = "hitbox!b"
	end
	if not axis then
		center, axis, len, bone, crossR, mins, maxs = getBladeFromMesh(wep, nil, 6, false)
		source = "mesh!b"
	end
	if not axis then
		-- Models may not be loaded yet; retry a couple of times before settling
		local tries = (cached and cached.tries or 0) + 1
		heldGeoCache[mdl] = {fail = true, tries = tries, nextTry = CurTime() + 2}
		vfxDebugPrint("%s: held geometry unresolved (try %d) model=%s", wep:GetClass(), tries, mdl)
		return nil
	end

	local geo = {
		bone = bone, boneName = wep:GetBoneName(bone) or tostring(bone),
		center = center, axis = axis, len = len, crossR = crossR,
		mins = mins, maxs = maxs, source = source,
		-- Refined mesh elongation direction (nil when unavailable/degenerate):
		-- guns use it over the AABB axis, whose cardinal snap tilts ~10 deg on
		-- meshes running diagonally through the bone frame (hl1 p_rpg)
		pcaAxis = computeBonePrincipalAxis(mdl, bone, axis),
	}
	heldGeoCache[mdl] = geo
	vfxDebugPrint("%s: held geometry via %s bone='%s' len=%.1f crossR=%.2f model=%s",
		wep:GetClass(), source, geo.boneName, len, crossR, mdl)
	return geo
end

-- Muzzle attachment id for axis refinement: only attachments literally named
-- after the muzzle — numeric ones ("1") can point sideways (shell ejects etc.)
local MUZZLE_AXIS_ATTACHMENTS = {"muzzle", "muzzle_flash", "muzzle_flash1", "muzzle_end"}
local function getMuzzleAxisAttachmentId(wep)
	if not (wep.LookupAttachment and wep.GetAttachment) then return nil end
	for _, name in ipairs(MUZZLE_AXIS_ATTACHMENTS) do
		local idx = wep:LookupAttachment(name)
		if idx and idx > 0 then return idx end
	end
	return nil
end

-- Per-frame evaluation of resolved held geometry on the live bone matrix.
-- Returns worldCenter, worldBladeDir (signed towards muzzle/tip), bonePos, boneAng;
-- nil when the bone matrix is unavailable or garbage this frame.
-- isMelee is passed in rather than derived: UI previews hand us a plain
-- ClientsideModel, which carries none of the SWEP fields the hold-type helpers read.
local function evalWeaponGeometry(wep, st, owner, isMelee)
	-- SWEPs with a custom DrawWorldModel may paint the visible mesh as a
	-- ClientsideModel at the hand while the entity's own bones sit stale near
	-- the player origin (TF2 c_models: their weapon_bone has no ValveBiped
	-- counterpart to bonemerge to). A drawn-model record of the WorldModel near
	-- the gripping hand IS the mesh on screen — trust it over the entity bones.
	-- Records of the weapon entity itself are excluded: those sit at the entity
	-- origin, and entity bones are the better source there.
	if isfunction(wep.DrawWorldModel) and IsValid(owner) then
		Arcana._WMCaptureUntil = RealTime() + 0.1
		local handPos, handAng = getRightHandPose(owner)
		if handPos and handAng then
			-- Fresh record: refresh the hand-relative cache. Packs place their
			-- throwaway models at FIXED offsets from the hand bone, so the cached
			-- transform keeps tracking through frames where the mesh isn't
			-- rendered (culling) and avoids the one-frame record lag.
			local drawn = findDrawnModelNear(handPos, wep.WorldModel, wep)
			if drawn and drawn.model == wep.WorldModel then
				st.dwmModel = drawn.model
				st.dwmLocalPos, st.dwmLocalAng = WorldToLocal(drawn.pos, drawn.ang, handPos, handAng)
			end
			if st.dwmLocalPos and st.dwmModel == wep.WorldModel then
				local drawnPos, drawnAng = LocalToWorld(st.dwmLocalPos, st.dwmLocalAng, handPos, handAng)
				local info = getModelBladeInfo(wep.WorldModel)
				if info then
					-- Guns follow the mesh's principal axis when the AABB axis is
					-- unreliable (diagonal meshes); melee stays on the AABB axis,
					-- whose centroid sign encodes the blade side
					local axisLocal = (not isMelee) and info.pcaAxis or info.axis
					local center = LocalToWorld(info.center, angle_zero, drawnPos, drawnAng)
					local tipEnd = LocalToWorld(info.center + axisLocal, angle_zero, drawnPos, drawnAng)
					local bladeDir = tipEnd - center
					bladeDir:Normalize()
					if not isMelee and bladeDir:Dot(owner:GetAimVector()) < 0 then
						bladeDir = -bladeDir
					end
					return center, bladeDir, drawnPos, drawnAng
				end
			end
		end
	end

	local geo = st.geo
	-- Always SetupBones: idle bonemerged weapons serve stale (even bind-pose)
	-- matrices until something forces a recompute — movement used to "fix" the
	-- rings for exactly that reason. The engine no-ops it when already set up.
	wep:SetupBones()
	local m = wep:GetBoneMatrix(geo.bone)
	if not m then return nil end
	local bonePos, boneAng = m:GetTranslation(), m:GetAngles()
	-- Bonemerged bones report origin/garbage when the owner isn't being rendered
	local refCenter = IsValid(owner) and owner:WorldSpaceCenter() or wep:WorldSpaceCenter()
	if bonePos:DistToSqr(refCenter) > 300 * 300 then return nil end
	local center = LocalToWorld(geo.center, angle_zero, bonePos, boneAng)
	local tipEnd = LocalToWorld(geo.center + geo.axis, angle_zero, bonePos, boneAng)
	local bladeDir = tipEnd - center
	bladeDir:Normalize()

	if isMelee then
		-- The centroid sign marks the heavy (blade) side, but verify against the
		-- grip once: the tip end must sit farther from the gripping hand than the
		-- butt end. Resolved here (not at build time) because bones are only live
		-- during rendering.
		if st.geoSign == nil then
			local rp = getPlayerHandPositions(owner)
			if rp then
				local half = geo.len * 0.5
				local tipD = (center + bladeDir * half):DistToSqr(rp)
				local buttD = (center - bladeDir * half):DistToSqr(rp)
				st.geoSign = (tipD >= buttD) and 1 or -1
			end
		end
		bladeDir = bladeDir * (st.geoSign or 1)
	else
		-- Guns follow the mesh's principal axis when available: the bone-space
		-- AABB axis snaps to a cardinal direction and tilts ~10 deg off meshes
		-- that run diagonally through the bone frame (measured 4-13 deg on HL2
		-- guns, hl1 p_rpg)
		if geo.pcaAxis then
			local pcaEnd = LocalToWorld(geo.center + geo.pcaAxis, angle_zero, bonePos, boneAng)
			bladeDir = pcaEnd - center
			bladeDir:Normalize()
		end
		-- Point the axis at the muzzle when the model marks one, else keep
		-- re-checking against the owner's aim (cheap dot, and aim is the only reference)
		if st.geoSign == nil then
			local muzzle = getMuzzleAttachmentPos(wep)
			if muzzle then
				st.geoSign = ((muzzle - center):Dot(bladeDir) >= 0) and 1 or -1
			end
		end
		if st.geoSign then
			bladeDir = bladeDir * st.geoSign
		elseif IsValid(owner) and bladeDir:Dot(owner:GetAimVector()) < 0 then
			bladeDir = -bladeDir
		end

		-- Refine axis and centerline via the muzzle attachment. Its direction is
		-- only trusted when it broadly agrees with the mesh principal axis:
		-- HL2 attachments track the barrel exactly (measured up to 7.2 deg from
		-- PCA on w_shotgun — stock/pump mass tilts PCA), while hl1 pack
		-- attachments can point ~11.5 deg off the tube (weapon_hl1_rpg), so the
		-- gate sits between at ~9 deg. Its POSITION is trusted either way — the
		-- box centerline averages in the stock/grip and sits off the barrel, so
		-- slide the ring center sideways onto the barrel line through the
		-- muzzle, keeping its station along the axis.
		if st.muzzleAxisAtt == nil then
			st.muzzleAxisAtt = getMuzzleAxisAttachmentId(wep) or false
		end
		if st.muzzleAxisAtt then
			local att = wep:GetAttachment(st.muzzleAxisAtt)
			if att and att.Pos then
				local mFwd = att.Ang and att.Ang:Forward() or bladeDir
				if mFwd:Dot(bladeDir) < 0 then mFwd = -mFwd end
				if mFwd:Dot(bladeDir) > 0.988 then
					bladeDir = mFwd
				end
				center = att.Pos + bladeDir * ((center - att.Pos):Dot(bladeDir))
			end
		end
	end

	return center, bladeDir, bonePos, boneAng
end

-- Viewmodel attachment positions come back FormatViewModelAttachment'd by the
-- engine: their lateral (right/up) eye-space components are scaled by
-- tan(worldFov/2)/tan(vmFov/2) so effects drawn in the world camera land on the
-- weapon. We render in the replicated vm camera instead (where depth values
-- compare against the weapon), so invert that scaling to recover raw vm space.
-- The ratio is identical for scaled and unscaled fov pairs (aspect scaling
-- multiplies both tangents by the same factor).
local function unformatVMAttachment(view, pos)
	local worldTan = math.tan(math.rad((view.fov or 90) * 0.5))
	local vmTan = math.tan(math.rad((view.fovviewmodel or 54) * 0.5))
	if worldTan <= 0 or vmTan <= 0 then return pos end
	local factor = vmTan / worldTan
	local eyeAng = view.angles
	local rel = pos - view.origin
	local r, u, f = rel:Dot(eyeAng:Right()), rel:Dot(eyeAng:Up()), rel:Dot(eyeAng:Forward())
	return view.origin + eyeAng:Right() * (r * factor) + eyeAng:Up() * (u * factor) + eyeAng:Forward() * f
end

-- Returns worldPos, ang; nil when the cached anchor went stale on the current model
local function evalVMAnchor(vm, wep, anchor, style, eyePos, eyeAng)
	if anchor.kind == "synthetic" then
		local off = getSyntheticVMOffset(wep)
		local rightOff = (anchor.side == "left") and -off.y or off.y
		local pos = eyePos + eyeAng:Forward() * off.x + eyeAng:Right() * rightOff + eyeAng:Up() * off.z
		return pos, stableVMAngles(nil, eyeAng, "synthetic", style, wep), "world"
	end

	local rawPos, rawAng
	if anchor.kind == "attachment" then
		rawPos, rawAng = evalAttachment(vm, anchor.id, eyePos)
		if rawPos then
			-- (verified with probe spheres: the raw attachment pos lands off-model
			-- in the vm camera and exactly on the muzzle in the world one)
			rawPos = unformatVMAttachment(render.GetViewSetup(), rawPos)
		end
	else
		rawPos, rawAng = evalBone(vm, anchor.id, eyePos)
	end
	if not rawPos then return nil end

	-- Positions stay in raw viewmodel space (attachments after unformatting): the
	-- hook draws the rings inside a cam.Start3D context replicating the engine's
	-- vm projection, so they line up pixel-perfect with the rendered weapon and
	-- z-test correctly against it
	local pos = Vector(rawPos)
	local ang
	local isMelee = isMeleeHoldType(wep)
	local wantsBladeAxis = style ~= "orbital" and anchor.kind == "bone" and rawAng ~= nil
	if wantsBladeAxis and isfunction(wep.PostDrawViewModel) then
		-- SWEPs with their own PostDrawViewModel may paint a replacement weapon
		-- mesh over a hidden vm one (hl2m-style packs). Arm the drawn-model capture
		-- and, when a record of the weapon's WorldModel shows up near the anchor,
		-- trust it over anything the vm itself can tell us — it's the exact mesh on
		-- screen. Packs whose PostDrawViewModel does something else (HL1's zoom
		-- overlays) never produce a matching record and fall through.
		Arcana._VMDrawCaptureFrame = FrameNumber()
		local drawn = findDrawnModelNear(pos, wep.WorldModel)
		if drawn and drawn.model == wep.WorldModel then
			local drawnInfo = getModelBladeInfo(drawn.model)
			if drawnInfo then
				local center = LocalToWorld(drawnInfo.center, angle_zero, drawn.pos, drawn.ang)
				local tipEnd = LocalToWorld(drawnInfo.center + drawnInfo.axis, angle_zero, drawn.pos, drawn.ang)
				local bladeDir = tipEnd - center
				bladeDir:Normalize()
				if not isMelee and bladeDir:Dot(eyeAng:Forward()) < 0 then
					bladeDir = -bladeDir
				end
				ang = anglesFromUpRight(bladeDir, eyeAng:Right())
				return center + bladeDir * (drawnInfo.len * (isMelee and 0.15 or 0.5)), ang, "vm"
			end
		end
	end
	if wantsBladeAxis and anchor.hbChecked == nil then
		anchor.evalFrame0 = anchor.evalFrame0 or FrameNumber()
		-- Give custom-draw SWEPs two frames to produce a drawn-model record before
		-- concluding the vm hitboxes describe what's actually on screen
		if not isfunction(wep.PostDrawViewModel) or FrameNumber() >= anchor.evalFrame0 + 2 then
			anchor.hbChecked = true
			-- Melee/dual weapons hang off the anchor bone, so search its subtree.
			-- Other bone-anchored guns (models without attachments) can carry the
			-- weapon on any bone — search them all, but with the stricter length
			-- gate so limb/fist boxes never qualify.
			local searchRoot = (isMelee or style == "dual") and anchor.id or nil
			local minLen = (searchRoot == nil or isHandBoneName(anchor.name)) and 12 or 8
			anchor.hbCenter, anchor.hbAxis, anchor.hbLen, anchor.hbBone = getBladeHitbox(vm, searchRoot, minLen)
			if not anchor.hbAxis then
				-- No shipped hitboxes: measure one from the mesh's own vertices
				anchor.hbCenter, anchor.hbAxis, anchor.hbLen, anchor.hbBone = getBladeFromMesh(vm, searchRoot, minLen)
			end
			-- Melee weapons can hang off a root-level weapon bone entirely outside
			-- the hand's subtree (TF2's weapon_bone) — widen to the whole rig,
			-- keeping body-part bones out by name so forearm boxes can't win
			-- (which also lets the length gate drop low enough for short blades).
			-- Dual stays subtree-only: each side must find its own gun.
			if not anchor.hbAxis and searchRoot ~= nil and style ~= "dual" then
				anchor.hbCenter, anchor.hbAxis, anchor.hbLen, anchor.hbBone = getBladeHitbox(vm, nil, 6, true)
				if not anchor.hbAxis then
					anchor.hbCenter, anchor.hbAxis, anchor.hbLen, anchor.hbBone = getBladeFromMesh(vm, nil, 6, true)
				end
			end
		end
	end
	if wantsBladeAxis and anchor.hbAxis then
		-- Ring on the hitbox centerline (plane perpendicular to its long axis).
		-- Melee: biased towards the tip so it sits mid-blade rather than at the
		-- grip. Dual guns: pushed to the far end so it circles the muzzle.
		local hbPos, hbAng = rawPos, rawAng
		if anchor.hbBone and anchor.hbBone ~= anchor.id then
			local hbM = vm:GetBoneMatrix(anchor.hbBone)
			if hbM then
				hbPos, hbAng = hbM:GetTranslation(), hbM:GetAngles()
			end
		end
		local center = LocalToWorld(anchor.hbCenter, angle_zero, hbPos, hbAng)
		local tipEnd = LocalToWorld(anchor.hbCenter + anchor.hbAxis, angle_zero, hbPos, hbAng)
		local bladeDir = tipEnd - center
		bladeDir:Normalize()
		if not isMelee and bladeDir:Dot(eyeAng:Forward()) < 0 then
			-- Gun barrels point away from the camera; the centroid sign can't know
			-- that (slide boxes sit nearly centered on their bone)
			bladeDir = -bladeDir
		end
		ang = anglesFromUpRight(bladeDir, eyeAng:Right())
		pos = center + bladeDir * (anchor.hbLen * (isMelee and 0.25 or 0.5))
	elseif isMelee and anchor.kind == "bone" and isHandBoneName(anchor.name) and rawAng and style ~= "orbital" then
		-- The weapon mesh hangs off the hand bone (c_ arm models carry no weapon
		-- bones), so derive the blade direction from the hand bone itself and follow
		-- it on the live matrix each frame — render-bounds directions are pose-
		-- dependent (sequence bboxes swing around) and point off-model on some idles.
		if not anchor.bladeAxis then
			if anchor.name:find("ValveBiped", 1, true) then
				-- A ValveBiped fist grips melee weapons along -Up of the hand bone
				-- (measured identical on crowbar/knife/bottle regardless of pose)
				anchor.bladeAxis, anchor.bladeSign = "Up", -1
			else
				-- Unknown rig: assume the weapon is held roughly upright right now
				-- and pick the hand axis best aligned with view up
				local eyeUp = eyeAng:Up()
				local bestDot = -1
				for _, getter in ipairs(BONE_BASIS_AXES) do
					local d = rawAng[getter](rawAng):Dot(eyeUp)
					if math.abs(d) > bestDot then
						bestDot = math.abs(d)
						anchor.bladeAxis = getter
						anchor.bladeSign = d >= 0 and 1 or -1
					end
				end
			end
		end
		local bladeDir = rawAng[anchor.bladeAxis](rawAng) * anchor.bladeSign
		ang = anglesFromUpRight(bladeDir, eyeAng:Right())
		local slide
		if isfunction(wep.PostDrawViewModel) and isstring(wep.WorldModel) and wep.WorldModel ~= "" then
			-- Custom-draw SWEP with no drawn-model record yet: size the slide from
			-- its WorldModel prop, not the vm's render bounds
			local info = getModelBladeInfo(wep.WorldModel)
			if info and info.len > 4 then slide = math.Clamp(info.len * 0.5, 3, 12) end
		end
		pos = pos + bladeDir * (slide or getMeleeBladeSlide(vm, pos, bladeDir))
	else
		ang = stableVMAngles(rawAng, eyeAng, anchor.kind, style, wep, anchor.name)
		if style == "orbital" then
			if anchor.kind == "bone" then
				-- Hand bones sit at the grip below the weapon; lift the halo onto its body
				pos = pos + Vector(0, 0, 4)
			end
		elseif anchor.kind == "bone" then
			-- NOTE: anglesFromUpRight yields angles whose Up points opposite the requested
			-- axis, so -ang:Up() nudges along the weapon towards its muzzle/tip; dual gun
			-- bones sit at the grips, so push further to reach the muzzles
			pos = pos - ang:Up() * (style == "dual" and 8 or 4)
		else
			-- Muzzle attachments: pull back towards the camera so rings sit on the barrel
			pos = pos + ang:Up() * 12
		end
	end

	return pos, ang, "vm"
end

local function getPhysgunColorFor(wep)
	-- Prefer color from current owner when held; cache to reuse when dropped
	local owner = IsValid(wep) and wep:GetOwner() or NULL
	if IsValid(owner) and owner.GetWeaponColor then
		local vc = owner:GetWeaponColor()
		if vc and vc.ToColor then
			local col = vc:ToColor()
			wep._ArcanaLastPhysColor = col
			return col
		end
	end
	if IsValid(wep) and wep._ArcanaLastPhysColor then
		return wep._ArcanaLastPhysColor
	end
	return Color(120, 200, 255, 255)
end

--- Populates `bc` with band rings for the given style.
-- @param bc BandCircle instance to add rings to
-- @param ringCount number of rings (1–3)
-- @param style "orbital" or "axis"
-- @param p table of style-specific scalars:
--   orbital: { base, heightscale, zBiasStep }
--   axis:    { baseR, bandH, stepR, totalSpan, zBiasStep }
local ORBITAL_SPIN_CONFIGS = {
	{p = 0,   y = 120, r = 0},
	{p = -30, y = -40, r = 10},
	{p = 30,  y = -50, r = -15},
}
local function buildBandRings(bc, ringCount, style, p)
	if style == "orbital" then
		local base, heightscale, zBiasStep = p.base, p.heightscale, p.zBiasStep
		for i = 1, ringCount do
			local spin = ORBITAL_SPIN_CONFIGS[i] or ORBITAL_SPIN_CONFIGS[#ORBITAL_SPIN_CONFIGS]
			local ring = bc:AddBand(base * 0.95, heightscale, spin, 2)
			if ring then
				ring.rotationSpeed = 0
				ring.zBias = (i - 1) * zBiasStep
			end
		end
	else
		local baseR, bandH, stepR, totalSpan, _ = p.baseR, p.bandH, p.stepR, p.totalSpan, p.zBiasStep
		local step = (ringCount > 1) and ((totalSpan or 0) / (ringCount - 1)) or 0
		local startOffset = -0.5 * (ringCount - 1) * step
		for i = 1, ringCount do
			local r = baseR + (i - 1) * stepR
			local height = bandH * (1 - (i - 1) * 0.10)
			local ring = bc:AddBand(r, height, nil, 2)
			if ring then
				ring.rotationSpeed = 35
				ring.rotationDirection = (i % 2 == 0) and 1 or -1
				-- p.zOffsets: explicit per-ring axial offsets (held-geometry melee
				-- stations) instead of the uniform symmetric spread
				ring.zBias = p.zOffsets and p.zOffsets[i] or (startOffset + (i - 1) * step)
			end
		end
	end
end

-- held/isMelee/color are explicit so UI previews can build the very same bands
-- around a plain model entity, which has no SWEP fields, no owner and therefore
-- no physgun color to read.
local function buildBandsForEntity(wep, count, style, held, isMelee, col)
	if not BandCircle then return nil end
	if count <= 0 then return nil end
	local axis, _, longest, lenX, lenY, lenZ = longestAxisInfo(wep)
	style = style or "axis"

	-- Axis-style weapons with resolvable model geometry get geometry-driven
	-- bands (held AND world/dropped — bones follow the entity transform either
	-- way): the follow hook positions/orients them on the live bone matrix each
	-- frame. Melee also takes radii and per-ring stations from the geometry (one
	-- ring on the handle, the rest along the blade); guns keep the OBB-extent
	-- sizing (orientation-independent scalars, and the look is already tuned)
	-- and only gain accurate position/orientation.
	if style == "axis" then
		local geo = resolveHeldWeaponGeometry(wep)
		if geo then
			local bc = BandCircle.Create(wep:WorldSpaceCenter(), Angle(0, 0, 0), col, 80, 0)
			if bc then
				local ringCount = math.min(3, count)
				local params
				if isMelee then
					local baseR = math.Clamp(geo.crossR * 1.2, 1.5, 8)
					-- Stations: fractions of the box length measured from the grip
					-- end (axis is signed towards the blade). Ring 1 sits on the
					-- handle, the rest spread over the blade.
					local stations = {0.18}
					local blades = ringCount - 1
					for i = 1, blades do
						stations[i + 1] = (blades > 1) and (0.5 + ((i - 1) / (blades - 1)) * 0.38) or 0.66
					end
					local zOffsets = {}
					for i, frac in ipairs(stations) do
						-- anglesFromUpRight yields Up OPPOSITE the requested blade
						-- axis and zBias translates along Up, so along-blade offsets
						-- must enter NEGATED (see the vm path's -ang:Up() slides)
						zOffsets[i] = -((frac - 0.5) * geo.len)
					end
					params = {
						baseR = baseR,
						bandH = math.Clamp(baseR * 0.35, 1.2, 3),
						stepR = 0,
						zOffsets = zOffsets,
					}
				else
					-- Legacy OBB sizing, including the held shrink, so gun ring
					-- sizes stay exactly as tuned in both states
					local smallest = math.max(4, math.min(lenX, math.min(lenY, lenZ)))
					local effectiveSmallest = math.max(6, smallest)
					local baseR = effectiveSmallest * 0.55
					local bandH = math.max(2.5, baseR * 0.18)
					if held then
						baseR = (baseR * 0.9) / 2
						bandH = bandH * 0.85
					end
					params = {
						baseR = math.max(4, baseR),
						bandH = math.max(2.5, bandH),
						stepR = math.max(2.5, effectiveSmallest * 0.16),
						totalSpan = math.min((longest or 24) * (held and 0.35 or 0.45), geo.len * 0.6),
					}
				end
				buildBandRings(bc, ringCount, "axis", params)
				return {
					bc = bc,
					axis = axis,
					count = count,
					lastStr = wep:GetNWString("Arcana_EnchantIds", "[]"),
					held = held,
					color = col,
					style = style,
					geo = geo,
					hasGeo = true,
				}
			end
		end
	end
	local ang
	if style == "orbital" then
		ang = Angle(0, 0, 0)
	else
		local upAxis = (axis == "x" and wep:GetForward()) or (axis == "y" and wep:GetRight()) or wep:GetUp()
		local refFwd = getSecondLongestAxisVector(wep, axis, lenX, lenY, lenZ)
		ang = buildOrientedAnglesForAxis(upAxis, nil, refFwd)
	end
	local pos = wep:WorldSpaceCenter()
	local bc = BandCircle.Create(pos, ang, col, 80, 0)
	if not bc then return nil end

	local smallest = math.max(4, math.min(lenX, math.min(lenY, lenZ)))
	local effectiveSmallest = math.max(6, smallest)
	local baseR = effectiveSmallest * 0.55
	local bandH = math.max(2.5, baseR * 0.18)

	if held then
		baseR = (baseR * 0.9) / 2
		bandH = bandH * 0.85
	end
	baseR = math.max(4, baseR)
	bandH = math.max(2.5, bandH)

	local ringCount = math.min(3, count)
	local orbBase = math.max(10, effectiveSmallest * 0.9)
	local ringParams = {
		base = orbBase, heightscale = math.max(3, orbBase * 0.18), zBiasStep = 0.5,
		baseR = baseR, bandH = bandH, stepR = math.max(2.5, effectiveSmallest * 0.16),
		totalSpan = (longest or 24) * (held and 0.35 or 0.45),
	}
	buildBandRings(bc, ringCount, style, ringParams)

	-- Akimbo: a second identical ring set for the off-hand gun
	local bcL
	if style == "dual" then
		bcL = BandCircle.Create(pos, ang, col, 80, 0)
		if bcL then
			buildBandRings(bcL, ringCount, style, ringParams)
		end
	end

	return {
		bc = bc,
		bcL = bcL,
		axis = axis,
		count = count,
		lastStr = wep:GetNWString("Arcana_EnchantIds", "[]"),
		held = held,
		color = col,
		style = style,
	}
end

local function createBandsForWeapon(wep, count, style)
	return buildBandsForEntity(wep, count, style, isHeldActive(wep), isMeleeHoldType(wep), getPhysgunColorFor(wep))
end

-- Shared cleanup for both ActiveVFXByEnt and ActiveVMVFX states
local function destroyBandState(state)
	if not state then return end
	local bc = state.bc
	if bc and bc.Remove then bc:Remove() end
	local bcL = state.bcL
	if bcL and bcL.Remove then bcL:Remove() end
end

local destroyVFX = destroyBandState

local function ensureVFXFor(wep)
	if not IsValid(wep) then return end
	if wep.ArcanaStored then return end -- enchanter UI manages its own bands
	-- Do not show VFX on weapons that are held but are not the owner's active weapon
	local owner = wep:GetOwner()
	if IsValid(owner) and owner:GetActiveWeapon() ~= wep then
		local s = ActiveVFXByEnt[wep]
		if s then
			destroyVFX(s)
			ActiveVFXByEnt[wep] = nil
		end
		return
	end

	-- Hide VFX for local player's active weapon when in first person
	if IsValid(owner) and owner == LocalPlayer() and owner:GetActiveWeapon() == wep and not owner:ShouldDrawLocalPlayer() then
		local s = ActiveVFXByEnt[wep]
		if s then
			destroyVFX(s)
			ActiveVFXByEnt[wep] = nil
		end
		return
	end

	local count = getEnchantCount(wep)
	local s = ActiveVFXByEnt[wep]
	local str = wep:GetNWString("Arcana_EnchantIds", "[]")
	local holdType = (wep.GetHoldType and wep:GetHoldType() or ""):lower()
	local styleWanted
	if holdType == "duel" and isHeldActive(wep) then
		styleWanted = "dual" -- akimbo: one axis ring set per hand
	elseif isMeleeHoldType(wep) or isPistolHoldType(wep) or isRifleHoldType(wep) then
		styleWanted = "axis"
	else
		styleWanted = "orbital"
	end

	if count <= 0 then
		if s then
			destroyVFX(s)
			ActiveVFXByEnt[wep] = nil
		end
		return
	end

	if not s then
		ActiveVFXByEnt[wep] = createBandsForWeapon(wep, count, styleWanted)
		return
	end

	-- Update if enchant set, held state, or geometry availability changed (a model
	-- that failed to resolve at creation may succeed on a later retry)
	local nowHeld = isHeldActive(wep)
	local geoAvail = (styleWanted == "axis") and (resolveHeldWeaponGeometry(wep) ~= nil) or false
	if (s.lastStr ~= str) or (s.held ~= nowHeld) or (s.style ~= styleWanted) or ((s.hasGeo or false) ~= geoAvail) then
		destroyVFX(s)
		ActiveVFXByEnt[wep] = createBandsForWeapon(wep, count, styleWanted)
	end
end

local function rescanWeapons()
	-- Scan for weapon entities that expose the enchant NWString
	for _, wep in ipairs(ents.GetAll()) do
		if IsValid(wep) and wep:IsWeapon() then
			ensureVFXFor(wep)
		end
	end

	-- Cleanup invalids
	for ent, st in pairs(ActiveVFXByEnt) do
		if not IsValid(ent) or getEnchantCount(ent) <= 0 then
			destroyVFX(st)
			ActiveVFXByEnt[ent] = nil
		end
	end
end

-- Positions and orients a state's rings for this frame. owner is the weapon's
-- carrier, or NULL for a weapon lying in the world — and for UI previews, which
-- take exactly the dropped-weapon path this way. isMelee/colorOverride are
-- explicit for the same reason buildBandsForEntity takes them.
local function updateBandPlacement(wep, st, owner, isMelee, colorOverride)
	local pos = wep:WorldSpaceCenter()
	local axis, dir, longest, lenX, lenY, lenZ = longestAxisInfo(wep)

	local angOverride
	local usedGeo = false
	local heldNow = IsValid(owner) and isHeldActive(wep)
	if st.geo and st.style ~= "dual" and (heldNow or not IsValid(owner)) then
		-- Geometry-driven placement (held and world/dropped): box center +
		-- blade axis evaluated on the weapon's live bone matrix. Falls
		-- through to the legacy heuristics below on frames where the bone
		-- matrix is unavailable.
		local gCenter, gDir, gBonePos, gBoneAng = evalWeaponGeometry(wep, st, owner, isMelee)
		if gCenter then
			usedGeo = true
			pos = gCenter
			-- Roll reference must not be parallel to the ring normal (gDir):
			-- held uses the eye RIGHT (same trick as dual); world weapons use
			-- the axis' own canonical right, stable for a resting prop.
			local refRight = heldNow and owner:EyeAngles():Right() or gDir:Angle():Right()
			angOverride = anglesFromUpRight(gDir, refRight)
			if VFX_DEBUG:GetInt() >= 2 then
				render.SetColorMaterial()
				render.DrawWireframeBox(gBonePos, gBoneAng, st.geo.mins, st.geo.maxs, Color(255, 220, 80), true)
				render.DrawLine(gCenter, gCenter + gDir * (st.geo.len * 0.5), Color(0, 255, 0), true)
			end
		end
	end

	if usedGeo then
		-- placement fully resolved above
	elseif IsValid(owner) and isHeldActive(wep) and st.style == "dual" and st.bcL then
		-- Akimbo: one ring per hand, both slid towards the muzzles along the
		-- aim direction (the guns track where the player looks)
		local rp, lp = getPlayerHandPositions(owner)
		local aim = owner:GetAimVector()
		dir = aim
		local fwdOff = math.max(4, (tonumber(longest) or 14) * 0.3)
		if rp then pos = rp + aim * fwdOff end
		if lp then st.bcL.position = lp + aim * fwdOff end
		-- The generic builder rolls against the eye FORWARD, which is parallel
		-- to this ring's normal (the aim) and therefore degenerate — the rings
		-- spin wildly on look. Roll against the eye right instead.
		angOverride = anglesFromUpRight(aim, owner:EyeAngles():Right())
	elseif IsValid(owner) and isHeldActive(wep) and isRifleHoldType(wep) then
		local rp, lp = getPlayerHandPositions(owner)
		local muzzle = getMuzzleAttachmentPos(wep)
		local leftPoint = muzzle or lp
		if rp and leftPoint then
			local v = (leftPoint - rp)
			if v:LengthSqr() > 1e-4 then
				dir = v:GetNormalized()
				pos = rp + v * 0.5
			end
		end
	elseif IsValid(owner) and isHeldActive(wep) and isPistolHoldType(wep) then
		local rpos, rang = getRightHandPose(owner)
		if rpos then
			local muzzle = getMuzzleAttachmentPos(wep)
			if muzzle then
				local v = muzzle - rpos
				if v:LengthSqr() > 1e-4 then
					dir = v:GetNormalized()
					pos = rpos + v * 0.5
				end
			else
				local fwd = (rang and rang:Forward()) or owner:EyeAngles():Forward()
				if fwd:LengthSqr() < 1e-4 then fwd = Vector(1, 0, 0) end
				dir = fwd:GetNormalized()
				pos = rpos + dir * ((tonumber(longest) or 20) * 0.35)
			end
		end
	elseif IsValid(owner) and isHeldActive(wep) and isMelee then
		local rpos, rang = getRightHandPose(owner)
		if rpos and rang then
			local up = rang:Up()
			if up:LengthSqr() < 1e-4 then up = rang:Forward() end
			dir = -up:GetNormalized()
			local size = tonumber(longest) or 20
			pos = rpos + dir * (size * 0.25)
		end
	elseif IsValid(owner) and isHeldActive(wep) then
		-- For the rest, anchor the orbital circle at the right hand when held
		local rpos = select(1, getRightHandPose(owner))
		if rpos then
			pos = rpos
		end
	end

	-- Decide style per-frame: default to axis when not held; use orbital only for held throwable types
	local held = IsValid(owner) and isHeldActive(wep)
	local desiredStyle
	if held and st.style ~= "dual" and not (isRifleHoldType(wep) or isPistolHoldType(wep) or isMelee) then
		desiredStyle = "orbital"
	else
		desiredStyle = "axis"
	end

	local upAxis = (desiredStyle == "orbital") and Vector(0, 0, 1) or dir
	local refFwd
	if desiredStyle == "axis" then
		refFwd = getSecondLongestAxisVector(wep, axis, lenX, lenY, lenZ)
	else
		refFwd = wep:GetForward()
	end

	local ang = angOverride or buildOrientedAnglesForAxis(upAxis, owner, refFwd)
	st.bc.position = pos
	st.bc.angles = ang

	-- Refresh color (physgun color may change)
	local col = colorOverride or getPhysgunColorFor(wep)
	st.bc.color = col
	if st.bcL then
		st.bcL.angles = ang
		st.bcL.color = col
	end
end

hook.Add("PostDrawOpaqueRenderables", "Arcana_EnchantVFX_Follow", function(bDrawingDepth)
	-- Skip the depth pass: translucent VFX must not write into the depth buffer
	if bDrawingDepth then return end

	for wep, st in pairs(ActiveVFXByEnt) do
		if not (st and st.bc) then continue end
		if not IsValid(wep) then continue end

		local owner = wep:GetOwner()

		if IsValid(owner) and owner == LocalPlayer() and wep == owner:GetActiveWeapon() and not owner:ShouldDrawLocalPlayer() then
			continue
		end

		if IsValid(owner) and owner:GetActiveWeapon() ~= wep then
			continue
		end

		updateBandPlacement(wep, st, owner, isMeleeHoldType(wep))
	end
end)

--
-- First-person viewmodel rendering for local player's active enchanted weapon
--
local ActiveVMVFX = ActiveVMVFX or {}

local destroyVMVFX = destroyBandState

local function pruneViewModelVFX()
	for wep, st in pairs(ActiveVMVFX) do
		local valid = IsValid(wep)
		if not valid then
			destroyVMVFX(st)
			ActiveVMVFX[wep] = nil
		else
			local owner = wep:GetOwner()
			if not IsValid(owner) or owner ~= LocalPlayer() then
				destroyVMVFX(st)
				ActiveVMVFX[wep] = nil
			else
				if owner:ShouldDrawLocalPlayer() or owner:GetActiveWeapon() ~= wep or getEnchantCount(wep) <= 0 then
					destroyVMVFX(st)
					ActiveVMVFX[wep] = nil
				end
			end
		end
	end
end

local function createBandsForViewModel(wep, count, style)
	if not BandCircle then return nil end
	count = math.max(1, math.floor(count))
	local owner = IsValid(wep) and wep:GetOwner() or LocalPlayer()
	local col = getPhysgunColorFor(wep)
	local bc = BandCircle.Create(owner:EyePos(), owner:EyeAngles(), col, 40, 0)
	if not bc then return nil end
	if bc.SetDrawnManually then bc:SetDrawnManually(true) end

	style = style or "axis"
	local ringCount = math.min(3, count)
	local baseR = 6
	local bandH = 2.2
	local stepR = 2
	local totalSpan = 8
	if isMeleeHoldType(wep) then
		-- Melee rings hug the blade/shaft rather than a gun body
		baseR, bandH, stepR, totalSpan = 3.5, 1.8, 1.2, 6
	elseif style == "dual" then
		-- One tighter ring set per gun
		baseR, bandH, stepR, totalSpan = 4, 1.8, 1.4, 5
	end

	local ringParams = {
		-- Orbital rings must clear the viewmodel geometry or they z-fail inside it
		base = baseR * 1.5, heightscale = bandH * 1.1, zBiasStep = 0.4,
		baseR = baseR, bandH = bandH, stepR = stepR, totalSpan = totalSpan,
	}
	buildBandRings(bc, ringCount, style, ringParams)

	local bcL
	if style == "dual" then
		bcL = BandCircle.Create(owner:EyePos(), owner:EyeAngles(), col, 40, 0)
		if bcL then
			if bcL.SetDrawnManually then bcL:SetDrawnManually(true) end
			buildBandRings(bcL, ringCount, style, ringParams)
		end
	end

	return {
		bc = bc,
		bcL = bcL,
		lastStr = wep:GetNWString("Arcana_EnchantIds", "[]"),
		count = count,
		style = style,
		createdAt = CurTime(),
	}
end

-- Renders a vm state's rings (and debug axes) in the current viewmodel pass.
-- Split out of the hook because custom-draw SWEPs need it to run AFTER their own
-- PostDrawViewModel has painted the weapon mesh (see the wrapper in the hook).
local function drawVMRings(s)
	if not (s and s.bc and s.bc.Draw and s.bc.position) then return end
	local view = render.GetViewSetup()
	local eyePos, eyeAng = view.origin, view.angles
	-- Raw viewmodel-space anchors render through a camera replicating the
	-- engine's vm projection exactly: aspect-scaled fovviewmodel (verified
	-- against bone positions in-game; the unscaled one lands off-model) AND the
	-- vm znear/zfar. The vm near plane differs from the world's (1 vs 3); with
	-- mismatched near planes depth values don't compare and rings would always
	-- z-fail behind the weapon instead of wrapping it.
	local vmFov = view.fovviewmodel or view.fovviewmodel_unscaled or 54
	local vmZNear = view.znearviewmodel or 1
	local vmZFar = view.zfarviewmodel or view.zfar or 28000

	-- Enters the camera matching an anchor's space: raw vm space needs the vm
	-- projection replicated; synthetic eye-offset positions use the plain world
	-- camera. Either way restore the engine's viewmodel depth-range hack, which
	-- cam.Start3D resets, so our depth values stay comparable with the weapon
	-- already in the buffer.
	local function startAnchorCam(anchorSpace)
		if anchorSpace == "world" then
			cam.Start3D(eyePos, eyeAng)
		else
			cam.Start3D(eyePos, eyeAng, vmFov, 0, 0, ScrW(), ScrH(), vmZNear, vmZFar)
		end
		render.DepthRange(0, 0.1)
	end

	if VFX_DEBUG:GetInt() >= 2 then
		local function drawAxes(bc)
			local p, a = bc.position, bc.angles
			render.SetColorMaterial()
			render.DrawLine(p, p + a:Forward() * 6, Color(0, 255, 0), true)
			render.DrawLine(p, p + a:Right() * 6, Color(255, 0, 0), true)
			render.DrawLine(p, p + a:Up() * 6, Color(0, 0, 255), true)
		end
		startAnchorCam(s.space)
		drawAxes(s.bc)
		cam.End3D()
		if s.bcL and s.bcL.position then
			startAnchorCam(s.spaceL)
			drawAxes(s.bcL)
			cam.End3D()
		end
	end

	-- ProcessBloom draws the bands to the screen (z-tested against the weapon,
	-- which is already in the depth buffer here) and captures the contribution
	Arcana.Bloom.ProcessBloom(function()
		startAnchorCam(s.space)
		s.bc:Draw()
		if s.bcL and s.bcL.Draw and s.spaceL == s.space then s.bcL:Draw() end
		cam.End3D()
		if s.bcL and s.bcL.Draw and s.spaceL ~= s.space then
			startAnchorCam(s.spaceL)
			s.bcL:Draw()
			cam.End3D()
		end
	end)
	Arcana.Bloom.RenderBloom()
	-- The bloom passes push/pop render targets, which resets the engine's
	-- viewmodel depth-range hack (DepthRange 0-0.1). Anything drawn after us in
	-- the viewmodel pass would then z-test against real world depth and clip
	-- into the map. Re-apply the hack for the remainder of the pass.
	render.DepthRange(0, 0.1)
end

-- Global indirection so per-weapon PostDrawViewModel wrappers keep working
-- across file reloads, always hitting the newest implementation and state table
function Arcana._DrawVMRings(wepEnt)
	drawVMRings(ActiveVMVFX[wepEnt])
end

hook.Add("PostDrawViewModel", "Arcana_EnchantVFX_ViewModel", function(vm, ply, wep)
	if not IsValid(ply) or ply ~= LocalPlayer() then return end
	if not IsValid(vm) then return end
	-- If third person or weapon mismatch, ensure any lingering state is cleared for this player
	if (not IsValid(wep)) or (wep ~= ply:GetActiveWeapon()) or ply:ShouldDrawLocalPlayer() then
		pruneViewModelVFX()
		return
	end

	local count = getEnchantCount(wep)
	if count <= 0 then
		local s = ActiveVMVFX[wep]
		if s then
			destroyVMVFX(s)
			ActiveVMVFX[wep] = nil
		end
		return
	end

	local s = ActiveVMVFX[wep]
	local str = wep:GetNWString("Arcana_EnchantIds", "[]")
	-- Decide desired style for viewmodel similar to world handling
	local holdType = (wep.GetHoldType and wep:GetHoldType() or ""):lower()
	local styleWanted
	if holdType == "duel" then
		styleWanted = "dual" -- akimbo: axis rings on each gun
	elseif isMeleeHoldType(wep) or isPistolHoldType(wep) or isRifleHoldType(wep) then
		styleWanted = "axis"
	else
		styleWanted = "orbital"
	end
	if (not s) or (s.lastStr ~= str) or (s.style ~= styleWanted) then
		if s then destroyVMVFX(s) end
		ActiveVMVFX[wep] = createBandsForViewModel(wep, count, styleWanted)
		s = ActiveVMVFX[wep]
		if not s then return end
	end

	local view = render.GetViewSetup()
	local eyePos, eyeAng = view.origin, view.angles

	-- Resolve anchors once per viewmodel model; re-resolve when they go stale.
	-- Deploy animations hold the weapon out of the view cone for the first frames,
	-- so don't cache anything until the pose settles.
	local vmModel = vm:GetModel() or ""
	if vmModel == "" or (CurTime() - (s.createdAt or 0)) < 0.25 then
		s.anchor = nil
		s.anchorL = nil
	else
		if needsReresolve(vm, s.anchor, vmModel) then
			s.anchor = resolveVMAnchor(vm, wep, styleWanted, eyePos, eyeAng, "right")
		end
		if s.bcL and needsReresolve(vm, s.anchorL, vmModel) then
			s.anchorL = resolveVMAnchor(vm, wep, styleWanted, eyePos, eyeAng, "left")
		end
	end

	local anchor = s.anchor or {kind = "synthetic", name = "no-model", model = "", side = "right"}
	local pos, ang, space = evalVMAnchor(vm, wep, anchor, styleWanted, eyePos, eyeAng)
	if not pos then
		s.anchor = resolveVMAnchor(vm, wep, styleWanted, eyePos, eyeAng, "right")
		pos, ang, space = evalVMAnchor(vm, wep, s.anchor, styleWanted, eyePos, eyeAng)
	end

	s.bc.position = pos
	s.bc.angles = ang
	s.bc.color = getPhysgunColorFor(wep)

	local posL, angL, spaceL
	if s.bcL then
		local anchorL = s.anchorL or {kind = "synthetic", name = "no-model", model = "", side = "left"}
		posL, angL, spaceL = evalVMAnchor(vm, wep, anchorL, styleWanted, eyePos, eyeAng)
		if not posL then
			s.anchorL = resolveVMAnchor(vm, wep, styleWanted, eyePos, eyeAng, "left")
			posL, angL, spaceL = evalVMAnchor(vm, wep, s.anchorL, styleWanted, eyePos, eyeAng)
		end
		s.bcL.position = posL
		s.bcL.angles = angL
		s.bcL.color = s.bc.color
	end

	-- Rings are sized for muzzle distance; shrink them when the anchor sits close to the camera.
	-- Orbital rings keep a higher floor so they stay wider than the weapon body.
	local minScale = (styleWanted == "orbital") and 0.75 or 0.5
	local scale = math.Clamp(pos:Distance(eyePos) / 28, minScale, 1.0)
	if (not s.scale) or math.abs(s.scale - scale) > 0.05 then
		s.scale = scale
		s.bc:SetScale(scale, 0)
		if s.bcL then s.bcL:SetScale(scale, 0) end
	end

	s.space = space
	s.spaceL = spaceL

	if isfunction(wep.PostDrawViewModel) then
		-- The gamemode calls SWEP:PostDrawViewModel AFTER every hook; packs that
		-- paint their weapon mesh there (TF2, hl2m-style) would cover rings drawn
		-- now. Wrap the SWEP fn once per weapon so the rings draw right after it —
		-- which also puts that mesh's depth in the buffer, so they wrap it too.
		if not wep._ArcanaVMRingWrap then
			wep._ArcanaVMRingWrap = true
			local orig = wep.PostDrawViewModel
			wep.PostDrawViewModel = function(wself, ...)
				local a, b, c = orig(wself, ...)
				if Arcana._DrawVMRings then Arcana._DrawVMRings(wself) end
				return a, b, c
			end
		end
	else
		drawVMRings(s)
	end
end)

-- Cleanup when a weapon entity is removed
hook.Add("EntityRemoved", "Arcana_EnchantVFX_Remove", function(ent)
	local st = ActiveVFXByEnt[ent]
	if st then
		destroyVFX(st)
		ActiveVFXByEnt[ent] = nil
	end

	local stvm = ActiveVMVFX[ent]
	if stvm then
		destroyVMVFX(stvm)
		ActiveVMVFX[ent] = nil
	end
end)

hook.Add("Think", "Arcana_EnchantVFX_Scan", function()
	-- Always prune VM VFX quickly to avoid lingering
	pruneViewModelVFX()

	-- A panel's model entity dies with the panel; drop the bands it owned
	for ent, st in pairs(PreviewVFXByEnt) do
		if not IsValid(ent) then
			destroyBandState(st)
			PreviewVFXByEnt[ent] = nil
		end
	end

	-- Interval-based world rescan
	local now = CurTime()
	if now - lastRescan >= RESCAN_INTERVAL then
		lastRescan = now
		rescanWeapons()
	end
end)

--
-- UI model-panel previews
--
-- Model panels show the weapon as it lies in the world, so previews run the very
-- same build and placement code the world path does, with no owner. State is kept
-- per entity: BandCircle.Create registers with MagicCircleManager and Remove()
-- only starts a fade, so a create-draw-destroy per frame would both rebuild the
-- band meshes every frame and leak fading circles into the world.
--
local PREVIEW_COLOR = Color(198, 160, 74, 255)

--- Ring style a weapon of this class shows in the world, plus whether it is melee.
-- For UIs that only have a class name and therefore no weapon entity for the
-- hold-type helpers to read. Mirrors ensureVFXFor's mapping for a weapon that is
-- not held (the state a model panel depicts).
-- @return style string ("axis" or "orbital"), isMelee boolean
function Arcana:GetEnchantBandPreviewInfo(class)
	local wc = Arcana.WeaponClassification
	local ht = wc.GetHoldTypeForClass(class)
	local isMelee = wc.IsMeleeHoldTypeName(ht)
	local style = (isMelee or wc.IsPistolHoldTypeName(ht) or wc.IsRifleHoldTypeName(ht)) and "axis" or "orbital"

	return style, isMelee
end

-- Reusable: render rings for an entity in an active 3D context (e.g., PostDrawModel).
-- opts.isMelee tells us what the hold-type helpers cannot read off a bare model.
-- A count of 0 draws nothing and releases the entity's bands, so callers can keep
-- calling unconditionally as a weapon's enchantments come and go.
function Arcana:RenderEnchantBandsForEntity(ent, count, color, style, opts)
	if not IsValid(ent) or not BandCircle then return end
	count = math.max(0, math.floor(count or 0))
	style = style or "axis"
	local isMelee = (opts and opts.isMelee) or false
	local col = color or PREVIEW_COLOR
	local model = ent:GetModel() or ""

	local st = PreviewVFXByEnt[ent]
	if st and (count <= 0 or st.count ~= count or st.style ~= style or st.isMelee ~= isMelee or st.model ~= model) then
		destroyBandState(st)
		PreviewVFXByEnt[ent] = nil
		st = nil
	end

	if count <= 0 then return end

	if not st then
		st = buildBandsForEntity(ent, count, style, false, isMelee, col)
		if not st then return end
		st.isMelee = isMelee
		st.model = model
		-- Ours to draw: the manager would otherwise paint these panel-space rings
		-- into the real world
		st.bc:SetDrawnManually(true)
		if st.bcL then st.bcL:SetDrawnManually(true) end
		PreviewVFXByEnt[ent] = st
	end

	updateBandPlacement(ent, st, NULL, isMelee, col)

	-- Same glow the world rings get. Bloom captures by diffing framebuffer
	-- snapshots, so it works from inside the panel's 3D pass, and no-ops on its
	-- own when the shaders are missing or arcana_bloom is off.
	Arcana.Bloom.ProcessBloom(function()
		st.bc:Draw()
		if st.bcL then st.bcL:Draw() end
	end)
	Arcana.Bloom.RenderBloom()
end