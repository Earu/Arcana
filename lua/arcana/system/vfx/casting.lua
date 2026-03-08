-- VFX Network — Server-side broadcast helpers and client-side VFX receivers
-- for spell cast circles, band circles, gestures, and cast failure visuals.
-- Extracted from core.lua so core can stay focused on spell registration and casting flow.

local Arcana = Arcana

-- ── Server-side band VFX broadcast API ──────────────────────────────────────
if SERVER then
	function Arcana:SendAttachBandVFX(ent, color, size, duration, bandConfigs, tag)
		if not IsValid(ent) then return end
		net.Start("Arcana_AttachBandVFX", true)
		net.WriteEntity(ent)
		net.WriteColor(color or Color(120, 200, 255, 255), true)
		net.WriteFloat(size or 80)
		net.WriteFloat(duration or 5)
		local count = istable(bandConfigs) and #bandConfigs or 0
		net.WriteUInt(count, 8)

		for i = 1, count do
			local c = bandConfigs[i]
			net.WriteFloat(c.radius or (size or 80) * 0.6)
			net.WriteFloat(c.height or 16)
			net.WriteFloat((c.spin and c.spin.p) or 0)
			net.WriteFloat((c.spin and c.spin.y) or 0)
			net.WriteFloat((c.spin and c.spin.r) or 0)
			net.WriteFloat(c.lineWidth or 2)
		end

		net.WriteString(tostring(tag or ""))
		net.Broadcast()
	end

	function Arcana:ClearBandVFX(ent, tag)
		if not IsValid(ent) then return end
		net.Start("Arcana_ClearBandVFX", true)
		net.WriteEntity(ent)
		net.WriteString(tostring(tag or ""))
		net.Broadcast()
	end
end

-- ── Client-side VFX receivers ────────────────────────────────────────────────
if CLIENT then
	-- Direct-call registry for per-circle cast-failure VFX callbacks. Populated by
	-- CreateFollowingCastCircle; iterated and called before Arcana_CastSpellFailure fires
	-- so VFX teardown is guaranteed even when a third-party hook returns early.
	local castFailureCallbacks = {}
	-- Returns pos, ang, size for a casting circle given the caster's current transform.
	-- isSpellCaster: entity is an arcana_spell_caster NPC rather than a player.
	-- forwardLike: circle should track the eye-forward direction rather than sit on the ground.
	local function computeCastCircleTransform(caster, isSpellCaster, forwardLike)
		if isSpellCaster then
			local fwd = caster:GetForward()
			local ang = fwd:Angle()
			ang:RotateAroundAxis(ang:Right(), 90)
			return caster:WorldSpaceCenter() + fwd * 30, ang, 30
		end

		if forwardLike then
			-- When the local player is in first-person with a grimoire, anchor the circle
			-- to the book pages instead of projecting it into world space.
			if caster == LocalPlayer() and not caster:ShouldDrawLocalPlayer() then
				local wep = caster:GetActiveWeapon()
				if IsValid(wep) and wep:GetClass() == "grimoire" then
					local eyePos = caster:EyePos()
					local eyeAng = caster:EyeAngles()
					local pos = eyePos
						+ eyeAng:Forward() * 18
						+ eyeAng:Right()   * 7
						+ eyeAng:Up()      * (-5)
					local ang = Angle(eyeAng.p, eyeAng.y, eyeAng.r)
					ang:RotateAroundAxis(ang:Right(), 90)
					return pos, ang, 22
				end
			end

			local maxs = caster:OBBMaxs()
			local eyePos = caster:EyePos()
			local eyeAng = caster:EyeAngles()
			local eyeFwd = eyeAng:Forward()
			local dist = maxs.x * 2.5
			local tr = util.TraceLine({ start = eyePos, endpos = eyePos + eyeFwd * dist, filter = caster, mask = MASK_SOLID_BRUSHONLY })
			local pos = tr.Hit and (tr.HitPos - eyeFwd * 2) or (eyePos + eyeFwd * dist)
			local ang = eyeAng
			ang:RotateAroundAxis(ang:Right(), 90)
			return pos, ang, 30
		end

		-- Ground circle below player feet, facing upward
		return caster:GetPos() + Vector(0, 0, 2), Angle(0, 180, 180), 60
	end

	-- Show evolving circle while a spell is being cast
	net.Receive("Arcana_BeginCasting", function()
		local caster = net.ReadEntity()
		local spellId = net.ReadString()
		local castTime = net.ReadFloat()
		local forwardLike = net.ReadBool()
		if not IsValid(caster) then return end

		if Arcana.HUD and Arcana.HUD.TrackCast then
			Arcana.HUD.TrackCast(caster, spellId, castTime)
		end
		Arcana.RunHook("TrackCast", caster, spellId, castTime)

		if not (Arcana.Circle and Arcana.Circle.MagicCircle) then return end

		-- Allow spells to override the default casting circle. If a hook returns true, stop.
		local handled = Arcana.RunHook("BeginCastingVisuals", caster, spellId, castTime, forwardLike)
		if handled == true then return end

		local isSpellCaster = caster:GetClass() == "arcana_spell_caster"

		local pos, ang, size = computeCastCircleTransform(caster, isSpellCaster, forwardLike)
		-- Ground circles (player, not forward-like) face upward; forward/spellcaster circles are neutral
		local direction = (not isSpellCaster and not forwardLike) and -1 or nil

		local color
		if isSpellCaster then
			local owner = (caster.CPPIGetOwner and caster:CPPIGetOwner()) or (caster:GetNWEntity("FallbackOwner"))
			color = IsValid(owner) and owner.GetWeaponColor and owner:GetWeaponColor():ToColor() or Color(150, 100, 255, 255)
		else
			color = caster.GetWeaponColor and caster:GetWeaponColor():ToColor() or Color(150, 100, 255, 255)
		end

		local intensity = 3
		local seed

		if isstring(spellId) and #spellId > 0 then
			intensity = 2 + (#spellId % 3)
			seed = tonumber(util.CRC(spellId))
		end

		local circle = Arcana.Circle.MagicCircle.CreateMagicCircle(pos, ang, color, intensity, size, castTime, 2, seed)
		if circle and circle.StartEvolving then
			circle:StartEvolving(castTime, direction)
		end

		-- Track as the current casting circle for this caster
		caster._ArcanaCastingCircle = circle

		-- While casting, continuously follow the caster so visuals stay attached
		local followHook = "Arcana_FollowCasting_" .. tostring(caster)
		hook.Remove("PostDrawOpaqueRenderables", followHook)
		hook.Add("PostDrawOpaqueRenderables", followHook, function()
			if not IsValid(caster) then
				hook.Remove("PostDrawOpaqueRenderables", followHook)
				return
			end

			local c = caster._ArcanaCastingCircle
			if not c or not c.IsActive or not c:IsActive() then
				hook.Remove("PostDrawOpaqueRenderables", followHook)
				return
			end

			local newPos, newAng, newSize = computeCastCircleTransform(caster, isSpellCaster, forwardLike)
			c.position = newPos
			c.angles = newAng
			c.size = newSize
		end)
	end)

	-- On spell failure, break down the tracked circle for the caster
	net.Receive("Arcana_SpellFailed", function()
		local caster = net.ReadEntity()
		local spellId = net.ReadString()
		local castTime = net.ReadFloat() or 0
		if not IsValid(caster) then return end

		if Arcana.HUD and Arcana.HUD.TrackCastFailure then
			Arcana.HUD.TrackCastFailure(caster, spellId, castTime)
		end
		Arcana.RunHook("TrackCastFailure", caster, spellId, castTime)

		for _, cb in pairs(castFailureCallbacks) do
			cb(caster, spellId)
		end
		Arcana.RunHook("CastSpellFailure", caster, spellId)

		local circle = caster._ArcanaCastingCircle

		if circle and circle.StartBreakdown then
			local d = math.max(0.1, castTime)
			circle:StartBreakdown(d)
			caster._ArcanaCastingCircle = nil
		end
	end)

	-- Play cast gesture locally for a given player
	net.Receive("Arcana_PlayCastGesture", function()
		local ply = net.ReadEntity()
		local gesture = net.ReadInt(16)
		if not IsValid(ply) or not gesture then return end
		local slot = GESTURE_SLOT_CUSTOM

		-- Prefer playing by sequence for better compatibility with player models
		if gesture == ACT_SIGNAL_FORWARD then
			local seq = ply:LookupSequence("gesture_signal_forward")

			if seq and seq >= 0 then
				ply:AddVCDSequenceToGestureSlot(slot, seq, 0, true)

				return
			end
		elseif gesture == ACT_GMOD_GESTURE_BECON then
			local seq = ply:LookupSequence("gesture_becon")

			if seq and seq >= 0 then
				ply:AddVCDSequenceToGestureSlot(slot, seq, 0, true)

				return
			end
		end

		-- Fallback to ACT-based gesture
		ply:AnimRestartGesture(slot, gesture, true)
	end)

	-- Track active BandCircle VFX by entity and optional tag for early clearing
	local activeBandVFX = {}

	-- Client-only: receive BandCircle VFX attachments
	net.Receive("Arcana_AttachBandVFX", function()
		local ent = net.ReadEntity()
		local color = net.ReadColor(true)
		local size = net.ReadFloat()
		local duration = net.ReadFloat()
		local count = net.ReadUInt(8)
		if not IsValid(ent) or not (Arcana.Circle and Arcana.Circle.BandCircle) then return end

		local bc = Arcana.Circle.BandCircle.Create(ent:WorldSpaceCenter(), ent:GetAngles(), color, size, duration)
		if not bc then return end

		for i = 1, count do
			local radius = net.ReadFloat()
			local height = net.ReadFloat()
			local sp = net.ReadFloat()
			local sy = net.ReadFloat()
			local sr = net.ReadFloat()
			local lw = net.ReadFloat()

			bc:AddBand(radius, height, {
				p = sp,
				y = sy,
				r = sr
			}, lw)
		end

		-- Read optional tag after band list
		local tag = net.ReadString() or ""

		-- Follow entity for duration
		local hookName = "BandCircleFollow_" .. tostring(bc)
		hook.Add("PostDrawOpaqueRenderables", hookName, function()
			if not IsValid(ent) or not bc or not bc.isActive then
				bc:Remove()
				hook.Remove("PostDrawOpaqueRenderables", hookName)
				return
			end

			bc.position = ent:WorldSpaceCenter()
			bc.angles = ent:GetAngles()
		end)

		-- Store by entity and tag for later clearing
		activeBandVFX[ent] = activeBandVFX[ent] or {}
		local key = tag ~= "" and tag or "__untagged__"
		activeBandVFX[ent][key] = activeBandVFX[ent][key] or {}
		table.insert(activeBandVFX[ent][key], bc)
	end)

	-- Clear previously attached band VFX by tag
	net.Receive("Arcana_ClearBandVFX", function()
		local ent = net.ReadEntity()
		local tag = net.ReadString() or ""
		if not IsValid(ent) then return end
		local key = tag ~= "" and tag or "__untagged__"

		if activeBandVFX[ent] and activeBandVFX[ent][key] then
			for _, bc in ipairs(activeBandVFX[ent][key]) do
				if bc and bc.Remove then
					bc:Remove()
				end
			end

			activeBandVFX[ent][key] = nil

			if next(activeBandVFX[ent]) == nil then
				activeBandVFX[ent] = nil
			end
		end
	end)

	-- Create a ground-following magic circle during spell casting.
	-- Used by spells that want custom casting circle visuals tracking the caster's aim.
	-- options.positionResolver: function(caster) -> Vector|nil — defaults to Arcana:ResolveGroundTarget
	function Arcana:CreateFollowingCastCircle(caster, spellId, castTime, options)
		if not IsValid(caster) then return false end
		if not (Arcana.Circle and Arcana.Circle.MagicCircle) then return false end

		local opts = options or {}
		local color = opts.color or Color(150, 100, 255, 255)
		local size = opts.size or 100
		local intensity = opts.intensity or 4
		local positionResolver = opts.positionResolver or function(c)
			return Arcana:ResolveGroundTarget(c)
		end

		local pos = positionResolver(caster)
		if not pos then return false end

		local ang = Angle(0, 0, 0)
		local seed = (isstring(spellId) and #spellId > 0) and tonumber(util.CRC(spellId)) or nil
		local circle = Arcana.Circle.MagicCircle.CreateMagicCircle(pos, ang, color, intensity, size, castTime, 2, seed)
		if not circle then return false end

		if circle.StartEvolving then
			circle:StartEvolving(castTime, 1)
		end

		local hookName = "Arcana_FollowCastCircle_" .. spellId .. "_" .. tostring(circle)
		local endTime = CurTime() + castTime + 0.05

		hook.Add("PostDrawOpaqueRenderables", hookName, function()
			if not IsValid(caster) or not circle or (circle.IsActive and not circle:IsActive()) or CurTime() > endTime then
				hook.Remove("PostDrawOpaqueRenderables", hookName)
				castFailureCallbacks[hookName] = nil
				return
			end

			local newPos = positionResolver(caster)
			if newPos then
				circle.position = newPos + Vector(0, 0, 0.5)
				circle.angles = Angle(0, 0, 0)
			end
		end)

		local targetSpellId = spellId
		castFailureCallbacks[hookName] = function(failedCaster, failedSpellId)
			if failedSpellId ~= targetSpellId then return end
			if not IsValid(failedCaster) or not circle then
				castFailureCallbacks[hookName] = nil
				return
			end

			if circle.StartBreakdown then
				circle:StartBreakdown(0.1)
			end

			castFailureCallbacks[hookName] = nil
		end
	end
end
