if SERVER then return end

-- Arcana: Client-side weapon enchantment VFX (BandCircle rings)
-- Displays 1-3 rotating bands aligned to the weapon's longest axis.

local ActiveVFXByEnt = ActiveVFXByEnt or {}
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

local function isRifleHoldType(wep)
	if not IsValid(wep) then return false end
	local ht = string.lower(tostring((wep.GetHoldType and wep:GetHoldType()) or wep.HoldType or ""))
	if ht == "" then return false end
	local rifle = {
		ar2 = true,
		shotgun = true,
		rpg = true,
		crossbow = true,
		smg = true,
		physgun = true
	}
	return rifle[ht] == true
end

local function isPistolHoldType(wep)
	if not IsValid(wep) then return false end
	local ht = string.lower(tostring((wep.GetHoldType and wep:GetHoldType()) or wep.HoldType or ""))
	if ht == "" then return false end
	local pistol = {
		pistol = true,
		revolver = true,
	}
	return pistol[ht] == true
end

local function isMeleeHoldType(wep)
	if not IsValid(wep) then return false end
	local ht = string.lower(tostring((wep.GetHoldType and wep:GetHoldType()) or wep.HoldType or ""))
	if ht == "" then return false end
	local melee = {
		melee = true,
		melee2 = true,
		knife = true,
	}
	return melee[ht] == true
end

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

-- Map a viewmodel attachment position from viewmodel FOV space to world space
local function formatViewModelAttachment(vOrigin, bFrom)
    local view = render.GetViewSetup()
    local vEyePos = view.origin
    local aEyesRot = view.angles
    local vOffset = vOrigin - vEyePos
    local vForward = aEyesRot:Forward()

    local nViewX = math.tan(view.fovviewmodel_unscaled * math.pi / 360)
    if (nViewX == 0) then
        vForward:Mul(vForward:Dot(vOffset))
        vEyePos:Add(vForward)
        return vEyePos
    end

    local nWorldX = math.tan(view.fov_unscaled * math.pi / 360)
    if (nWorldX == 0) then
        vForward:Mul(vForward:Dot(vOffset))
        vEyePos:Add(vForward)
        return vEyePos
    end

    local vRight = aEyesRot:Right()
    local vUp = aEyesRot:Up()

    if (bFrom) then
        local nFactor = nWorldX / nViewX
        vRight:Mul(vRight:Dot(vOffset) * nFactor)
        vUp:Mul(vUp:Dot(vOffset) * nFactor)
    else
        local nFactor = nViewX / nWorldX
        vRight:Mul(vRight:Dot(vOffset) * nFactor)
        vUp:Mul(vUp:Dot(vOffset) * nFactor)
    end

    vForward:Mul(vForward:Dot(vOffset))
    vEyePos:Add(vRight)
    vEyePos:Add(vUp)
    vEyePos:Add(vForward)
    return vEyePos
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

-- Find a muzzle-like attachment on any entity (worldmodel or viewmodel)
local function getMuzzleAttachmentFull(ent)
    if not (IsValid(ent) and ent.LookupAttachment and ent.GetAttachment) then return nil end
    local candidates = {"muzzle", "muzzle_flash", "muzzle_flash1", "muzzle_end", "1", "0"}
    for _, name in ipairs(candidates) do
        local idx = ent:LookupAttachment(name)
        if idx and idx > 0 then
            local att = ent:GetAttachment(idx)
            if att then return att end
        end
    end
    return nil
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

local function createBandsForWeapon(wep, count, style)
	if not _G.BandCircle then return nil end
	if count <= 0 then return nil end
	local axis, dir, longest, lenX, lenY, lenZ = longestAxisInfo(wep)
	style = style or "axis"
	local ang
	if style == "orbital" then
		ang = Angle(0, 0, 0)
	else
		-- World orientation: Up follows weapon's longest axis, Forward follows second-longest axis
		local upAxis = (axis == "x" and wep:GetForward()) or (axis == "y" and wep:GetRight()) or wep:GetUp()
		local refFwd = getSecondLongestAxisVector(wep, axis, lenX, lenY, lenZ)
		ang = buildOrientedAnglesForAxis(upAxis, nil, refFwd)
	end
	local pos = wep:WorldSpaceCenter()
	local col = getPhysgunColorFor(wep)
	local bc = BandCircle.Create(pos, ang, col, 80, 0) -- not animated; we manage lifetime
	if not bc then return nil end

	-- Size heuristics (with minimums so very thin weapons still display clearly)
	local smallest = math.max(4, math.min(lenX, math.min(lenY, lenZ)))
	local minAxisSize = 6
	local effectiveSmallest = math.max(minAxisSize, smallest)
	local baseR = effectiveSmallest * 0.55
	local bandH = math.max(2.5, baseR * 0.18)

	-- Slightly different presentation for held vs world
	local held = isHeldActive(wep)
	if held then
		baseR = (baseR * 0.9) / 2
		bandH = bandH * 0.85
	end

	-- Re-apply minimums after held/world adjustments
	baseR = math.max(4, baseR)
	bandH = math.max(2.5, bandH)

    local ringCount = math.min(3, count)

    if style == "orbital" then
		-- Orbital style: barrier-like spinning rings around the weapon
		local base = math.max(10, effectiveSmallest * 0.9)
		local heightscale = math.max(3, base * 0.18)
		local configs = {
			{ radius = base * 0.95, height = heightscale, spin = {p = 0,   y = 120, r = 0} },
			{ radius = base * 0.95, height = heightscale, spin = {p = -30, y = -40, r = 10} },
			{ radius = base * 0.95, height = heightscale, spin = {p = 30,  y = -50, r = -15} },
		}
		for i = 1, ringCount do
			local cfg = configs[i] or configs[#configs]
			local ring = bc:AddBand(cfg.radius, cfg.height, cfg.spin, 2)
			if ring then
				ring.rotationSpeed = 0
				ring.zBias = (i - 1) * 0.5
			end
		end
    else
    	-- Axis style: gentle self-spin around longest axis and spaced along that axis
    	local totalSpan = (longest or 24) * (held and 0.35 or 0.45)
    	local step = (ringCount > 1) and (totalSpan / (ringCount - 1)) or 0
    	local startOffset = -0.5 * (ringCount - 1) * step

		for i = 1, ringCount do
			local stepR = math.max(2.5, effectiveSmallest * 0.16)
			local r = baseR + (i - 1) * stepR
			local height = bandH * (1 - (i - 1) * 0.10)
			local ring = bc:AddBand(r, height, nil, 2)
			if ring then
				ring.rotationSpeed = 35
				ring.rotationDirection = (i % 2 == 0) and 1 or -1
				ring.zBias = startOffset + (i - 1) * step
			end
		end
    end

	return {
		bc = bc,
		axis = axis,
		count = count,
		lastStr = wep:GetNWString("Arcana_EnchantIds", "[]"),
		held = held,
		color = col,
		style = style,
	}
end

local function destroyVFX(state)
	if not state then return end
	local bc = state.bc
	if bc and bc.Remove then bc:Remove() end
end

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
    local styleWanted = (isMeleeHoldType(wep) or isPistolHoldType(wep) or isRifleHoldType(wep)) and "axis" or "orbital"

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

	-- Update if enchant set or held state changed
	local nowHeld = isHeldActive(wep)
	if (s.lastStr ~= str) or (s.held ~= nowHeld) or (s.style ~= styleWanted) then
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


hook.Add("PostDrawOpaqueRenderables", "Arcana_EnchantVFX_Follow", function()
	for wep, st in pairs(ActiveVFXByEnt) do
		if not (st and st.bc) then continue end
		if not IsValid(wep) then continue end

		-- Update position, angles, and color each frame
		local pos = wep:WorldSpaceCenter()
		local axis, dir, longest = longestAxisInfo(wep)

		-- For rifle-like hold types when actively held, use hand bone direction
		local owner = wep:GetOwner()

		-- Skip rendering for local player's active viewmodel in first person
		if IsValid(owner) and owner == LocalPlayer() and wep == owner:GetActiveWeapon() and not owner:ShouldDrawLocalPlayer() then
			continue
		end

		-- If a player holds this weapon but it isn't active, skip rendering
		if IsValid(owner) and owner:GetActiveWeapon() ~= wep then
			continue
		end

		local handledType = false
		if IsValid(owner) and isHeldActive(wep) and isRifleHoldType(wep) then
			local rp, lp = getPlayerHandPositions(owner)
			local muzzle = getMuzzleAttachmentPos(wep)
			local leftPoint = muzzle or lp
			if rp and leftPoint then
				local v = (leftPoint - rp)
				if v:LengthSqr() > 1e-4 then
					dir = v:GetNormalized()
					pos = rp + v * 0.5 -- midpoint between hand and muzzle/left hand
				end
			end
			handledType = true
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
			handledType = true
		elseif IsValid(owner) and isHeldActive(wep) and isMeleeHoldType(wep) then
			local rpos, rang = getRightHandPose(owner)
			if rpos and rang then
				local up = rang:Up()
				if up:LengthSqr() < 1e-4 then up = rang:Forward() end
				dir = -up:GetNormalized()
				local size = tonumber(longest) or 20
				pos = rpos + dir * (size * 0.25)
			end
			handledType = true
		elseif IsValid(owner) and isHeldActive(wep) then
			-- For the rest, anchor the orbital circle at the right hand when held
			local rpos = select(1, getRightHandPose(owner))
			if rpos then
				pos = rpos
			end
			handledType = false
		end

		-- Decide style per-frame: default to axis when not held; use orbital only for held throwable types
		local held = IsValid(owner) and isHeldActive(wep)
		local desiredStyle
		if held and not (isRifleHoldType(wep) or isPistolHoldType(wep) or isMeleeHoldType(wep)) then
			desiredStyle = "orbital"
		else
			desiredStyle = "axis"
		end
		local upAxis = (desiredStyle == "orbital") and Vector(0, 0, 1) or dir
		local refFwd
		if desiredStyle == "axis" then
			local a, _, _, lx, ly, lz = longestAxisInfo(wep)
			refFwd = getSecondLongestAxisVector(wep, a, lx, ly, lz)
		else
			refFwd = wep:GetForward()
		end
		local ang = buildOrientedAnglesForAxis(upAxis, owner, refFwd)
		st.bc.position = pos
		st.bc.angles = ang

		-- Refresh color (physgun color may change)
		local col = getPhysgunColorFor(wep)
		st.bc.color = col
	end
end)

--
-- First-person viewmodel rendering for local player's active enchanted weapon
--
local ActiveVMVFX = ActiveVMVFX or {}

local function destroyVMVFX(state)
    if not state then return end
    local bc = state.bc
    if bc and bc.Remove then bc:Remove() end
end

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
    if not _G.BandCircle then return nil end
    count = math.max(1, math.floor(count))
    local owner = IsValid(wep) and wep:GetOwner() or LocalPlayer()
    local col = getPhysgunColorFor(wep)
    local bc = BandCircle.Create(owner:EyePos(), owner:EyeAngles(), col, 40, 0)
    if bc and bc.SetDrawnManually then bc:SetDrawnManually(true) end
    if not bc then return nil end

	style = style or "axis"
	local ringCount = math.min(3, count)
	-- Compact sizes for first person
	local baseR = 6
	local bandH = 2.2

	if style == "orbital" then
		-- Barrier-like spinning rings
		local configs = {
			{ radius = baseR * 1.2, height = bandH * 1.1, spin = {p = 0,   y = 120, r = 0} },
			{ radius = baseR * 1.2, height = bandH * 1.1, spin = {p = -30, y = -40, r = 10} },
			{ radius = baseR * 1.2, height = bandH * 1.1, spin = {p = 30,  y = -50, r = -15} },
		}
		for i = 1, ringCount do
			local cfg = configs[i] or configs[#configs]
			local ring = bc:AddBand(cfg.radius, cfg.height, cfg.spin, 2)
			if ring then
				ring.rotationSpeed = 0
				ring.zBias = (i - 1) * 0.4
			end
		end
	else
		-- Axis style
		local totalSpan = 8
		local step = (ringCount > 1) and (totalSpan / (ringCount - 1)) or 0
		local startOffset = -0.5 * (ringCount - 1) * step
		for i = 1, ringCount do
			local r = baseR + (i - 1) * 2
			local h = bandH * (1 - (i - 1) * 0.12)
			local ring = bc:AddBand(r, h, nil, 2)
			if ring then
				ring.rotationSpeed = 35
				ring.rotationDirection = (i % 2 == 0) and 1 or -1
				ring.zBias = startOffset + (i - 1) * step
			end
		end
	end

    return {
        bc = bc,
        lastStr = wep:GetNWString("Arcana_EnchantIds", "[]"),
		count = count,
		style = style,
    }
end

hook.Add("PostDrawViewModel", "Arcana_EnchantVFX_ViewModel", function(vm, ply, wep)
    if not IsValid(ply) or ply ~= LocalPlayer() then return end
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

    -- Require a muzzle-like attachment on the viewmodel
    local tAttachment = getMuzzleAttachmentFull(vm)
    if not tAttachment then
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
    local styleWanted = (isMeleeHoldType(wep) or isPistolHoldType(wep) or isRifleHoldType(wep)) and "axis" or "orbital"
    if (not s) or (s.lastStr ~= str) or (s.style ~= styleWanted) then
        if s then destroyVMVFX(s) end
        ActiveVMVFX[wep] = createBandsForViewModel(wep, count, styleWanted)
        s = ActiveVMVFX[wep]
        if not s then return end
    end

    -- Position and orient using the muzzle attachment
	local attPos = formatViewModelAttachment(tAttachment.Pos, false)
    local attAng = tAttachment.Ang
    -- Use attachment basis: Up aligned to muzzle forward; yaw from attachment Right vs player view Right
    local up = attAng:Forward()
    local right = attAng:Right()
	local ang = anglesFromUpRight(up, right)

	-- Bring the circle slightly closer to the player along +Up (towards camera)
	local pos = attPos + ang:Up() * 12

    s.bc.position = pos
    s.bc.angles = ang
    s.bc.color = getPhysgunColorFor(wep)

    -- Draw immediately in the viewmodel pass to avoid one-frame lag
    if s.bc.Draw then
        s.bc:Draw()
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

    -- Interval-based world rescan
    local now = CurTime()
    if now - lastRescan >= RESCAN_INTERVAL then
        lastRescan = now
        rescanWeapons()
    end
end)

-- =========================== HELPERS ===========================

local Arcane = _G.Arcane or {}
_G.Arcane = Arcane

-- Reusable: render rings for an entity in an active 3D context (e.g., PostDrawModel)
function Arcane:RenderEnchantBandsForEntity(ent, count, color, style)
    if not IsValid(ent) or not _G.BandCircle then return end
    count = math.max(1, math.floor(count or 1))
    style = style or "axis"

    local axis, dir, longest, lenX, lenY, lenZ = longestAxisInfo(ent)
    local upAxis = (style == "orbital") and Vector(0, 0, 1)
        or ((axis == "x" and ent:GetForward()) or (axis == "y" and ent:GetRight()) or ent:GetUp())
    local refFwd = (style == "axis") and getSecondLongestAxisVector(ent, axis, lenX, lenY, lenZ) or ent:GetForward()
    local ang = buildOrientedAnglesForAxis(upAxis, nil, refFwd)

    local pos = ent:WorldSpaceCenter()
    local col = color or Color(198, 160, 74, 255)
    local bc = BandCircle.Create(pos, ang, col, 80, 0)
    if not bc then return end

    local smallest = math.max(4, math.min(lenX or 8, math.min(lenY or 8, lenZ or 8)))
    local baseR = math.max(6, smallest * 0.55)
    local bandH = math.max(2.5, baseR * 0.18)
    local ringCount = math.min(3, count)

    if style == "orbital" then
        local base = math.max(10, smallest * 0.9)
        local heightscale = math.max(3, base * 0.18)
        local configs = {
            { radius = base * 0.95, height = heightscale, spin = {p = 0,   y = 120, r = 0} },
            { radius = base * 0.95, height = heightscale, spin = {p = -30, y = -40, r = 10} },
            { radius = base * 0.95, height = heightscale, spin = {p = 30,  y = -50, r = -15} },
        }
        for i = 1, ringCount do
            local cfg = configs[i] or configs[#configs]
            local ring = bc:AddBand(cfg.radius, cfg.height, cfg.spin, 2)
            if ring then
                ring.rotationSpeed = 0
                ring.zBias = (i - 1) * 0.5
            end
        end
    else
        local totalSpan = (longest or 24) * 0.40
        local step = (ringCount > 1) and (totalSpan / (ringCount - 1)) or 0
        local startOffset = -0.5 * (ringCount - 1) * step
        for i = 1, ringCount do
            local r = baseR + (i - 1) * math.max(2.5, smallest * 0.16)
            local h = bandH * (1 - (i - 1) * 0.10)
            local ring = bc:AddBand(r, h, nil, 2)
            if ring then
                ring.rotationSpeed = 35
                ring.rotationDirection = (i % 2 == 0) and 1 or -1
                ring.zBias = startOffset + (i - 1) * step
            end
        end
    end

    if bc.Draw then bc:Draw() end
    if bc.Remove then bc:Remove() end
end
