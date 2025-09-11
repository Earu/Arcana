local Arcane = _G.Arcane or {}

if SERVER then
	util.AddNetworkString("Arcana_ManaNetwork_Flow")
	Arcane.ManaNetwork = Arcane.ManaNetwork or {}
	local MN = Arcane.ManaNetwork

	-- Minimal configuration
	MN.Config = MN.Config or {
		defaultRange = 500,
		pulseInterval = 0.5, -- seconds
	}

	MN._producers = MN._producers or {} -- array of { ent=Entity, range=number }
	MN._consumers = MN._consumers or {} -- optional; not used in pulse logic but kept for API compatibility
	MN._nodes = MN._nodes or {} -- map for quick unregister lookup

	local function addProducer(ent, range)
		local rec = {ent = ent, range = range}
		MN._nodes[ent] = rec
		MN._producers[#MN._producers + 1] = rec

		-- Auto-clean on remove
		ent:CallOnRemove("Arcana_MN_Unregister", function(e)
			MN:UnregisterNode(e)
		end)

		return rec
	end

	function MN:RegisterProducer(ent, opts)
		if not IsValid(ent) then return nil end

		opts = opts or {}
		local range = tonumber(opts.range or MN.Config.defaultRange) or MN.Config.defaultRange
		return addProducer(ent, range)
	end

	function MN:RegisterConsumer(ent, _opts)
		if not IsValid(ent) then return nil end

		local rec = {ent = ent}
		MN._nodes[ent] = rec
		MN._consumers[#MN._consumers + 1] = rec
		ent:CallOnRemove("Arcana_MN_Unregister", function(e)
			MN:UnregisterNode(e)
		end)

		return rec
	end

	function MN:UnregisterNode(ent)
		local rec = MN._nodes[ent]
		if not rec then return end

		MN._nodes[ent] = nil

		-- remove from producers
		table.RemoveByValue(MN._producers, rec)

		-- remove from consumers
		table.RemoveByValue(MN._consumers, rec)
	end

	-- Periodic pulse: each producer pings nearby entities that implement AddMana, and we broadcast simple flow visuals
	local function doPulse()
		if not MN._producers or #MN._producers == 0 then return end

		local flows = {}
		for i = #MN._producers, 1, -1 do
			local p = MN._producers[i]
			local ent = p and p.ent
			if not ent or not IsValid(ent) then
				table.remove(MN._producers, i)
				continue
			end

			local range = tonumber(p.range or MN.Config.defaultRange) or MN.Config.defaultRange
			local pos = ent:GetPos()
			local around = ents.FindInSphere(pos, range)
			for _, target in ipairs(around or {}) do
				if target ~= ent and target.AddMana then
					local succ, err = pcall(target.AddMana, target, 1)
					if not succ then
						ErrorNoHalt(err)
					end

					local list = flows[target]
					if not list then
						list = {}
						flows[target] = list
					end

					list[#list + 1] = ent
				end
			end
		end

		for target, producers in pairs(flows) do
			if IsValid(target) then
				net.Start("Arcana_ManaNetwork_Flow", true)
				net.WriteEntity(target)
				net.WriteUInt(#producers, 8)
				for _, fromEnt in ipairs(producers) do
					net.WriteEntity(fromEnt)
					net.WriteFloat(1)
				end
				net.Broadcast()
			end
		end
	end

	timer.Create("Arcana_ManaNetwork_Pulse", MN.Config.pulseInterval or 0.5, 0, doPulse)
end

if CLIENT then
	local glyphParticles = {}

	local GLYPH_PHRASES = {
		"αβραξασθεοσγνωσιςφωςζωηαληθειακοσμοςψυχηπνευμα",
		"αρχηκαιτελοςαρχηκαιτελοςαρχηκαιτελος",
		"τῶνπροστεταγμένωνκυρίουπνευμακαιγραφή",
		"ΜῆνινἄειδεΠηληϑύροςὀκνεῖτονἄστελλον",
		"ἐνΧαίδεριςὀκνοπαντίδυναμιςἐστίν",
		"Ἀτρεΐδαςἄρ'ἵηκεΠοτειδεύς",
		"ἨριφάειςΤρῶεςἵστετοκλυτόν",
	}

	local function pickGlyph(idx)
		local phrase = GLYPH_PHRASES[(idx % #GLYPH_PHRASES) + 1]
		local len = (utf8 and utf8.len and utf8.len(phrase)) or #phrase
		if len < 1 then return "*" end
		local i = (idx % len) + 1
		if utf8 and utf8.sub then return utf8.sub(phrase, i, i) end
		return string.sub(phrase, i, i)
	end

	local function billboardAnglesAt(pos)
		local ang = (EyePos() - pos):Angle()
		ang:RotateAroundAxis(ang:Right(), -90)
		ang:RotateAroundAxis(ang:Up(), 90)
		return ang
	end

	local function randomPointOnOBBSurface(ent)
		if not IsValid(ent) then return ent:WorldSpaceCenter() end
		local mins, maxs = ent:OBBMins(), ent:OBBMaxs()
		local axis = math.random(1, 3)
		local pos = Vector(0, 0, 0)
		if axis == 1 then
			pos.x = (math.random(0, 1) == 1) and maxs.x or mins.x
			pos.y = math.Rand(mins.y, maxs.y)
			pos.z = math.Rand(mins.z, maxs.z)
		elseif axis == 2 then
			pos.y = (math.random(0, 1) == 1) and maxs.y or mins.y
			pos.x = math.Rand(mins.x, maxs.x)
			pos.z = math.Rand(mins.z, maxs.z)
		else
			pos.z = (math.random(0, 1) == 1) and maxs.z or mins.z
			pos.x = math.Rand(mins.x, maxs.x)
			pos.y = math.Rand(mins.y, maxs.y)
		end
		return ent:LocalToWorld(pos)
	end

	local function bezierPoint(a, b, c, t)
		local u = 1 - t
		return a * (u * u) + b * (2 * u * t) + c * (t * t)
	end

	net.Receive("Arcana_ManaNetwork_Flow", function()
		local toEnt = net.ReadEntity()
		local count = net.ReadUInt(8)
		if not IsValid(toEnt) then return end

		local now = CurTime()
		for i = 1, count do
			local fromEnt = net.ReadEntity()
			local amt = net.ReadFloat()
			if IsValid(fromEnt) and amt > 0 then
				local fromPos = randomPointOnOBBSurface(fromEnt)
				local toPos = toEnt:WorldSpaceCenter()
				local dir = (toPos - fromPos)
				local dist = dir:Length()
				if dist > 2 then
					dir:Normalize()

					local up = Vector(0, 0, 1)
					local right = dir:Cross(up)
					if right:LengthSqr() < 0.01 then right = Vector(1, 0, 0) end

					right:Normalize()

					local mid = (fromPos + toPos) * 0.5
					local curveAmt = math.Clamp(dist * 0.25, 20, 160)
					local ctrl = mid + right * math.Rand(-curveAmt, curveAmt)
					local baseColor = fromEnt:GetColor() or Color(255, 255, 255)
					local countGlyphs = math.Clamp(math.floor(8 + dist * 0.02), 5, 50)
					for gi = 1, countGlyphs do
						local speed = math.Rand(120, 220)
						local dur = dist / speed
						local startDelay = math.Rand(0, 0.7)
						glyphParticles[#glyphParticles + 1] = {
							startPos = fromPos,
							ctrlPos = ctrl,
							endPos = toPos,
							startTime = now + startDelay,
							duration = dur,
							char = pickGlyph(gi + math.floor(now * 13)),
							baseColor = Color(baseColor.r, baseColor.g, baseColor.b, 255),
							size = math.Rand(10, 16)
						}
					end
				end
			end
		end
	end)

	local MAX_RENDER_DIST = 2000 * 2000
	hook.Add("PostDrawOpaqueRenderables", "Arcana_ManaNetwork_Draw", function()
		local eye = EyePos()
		local now = CurTime()
		local write = 1
		for i = 1, #glyphParticles do
			local p = glyphParticles[i]
			local startT = p.startTime or 0
			local endT = startT + (p.duration or 0)
			local active = (now >= startT and now <= endT)
			if active then
				local u = math.Clamp((now - startT) / math.max(0.001, p.duration), 0, 1)
				local pos = bezierPoint(p.startPos, p.ctrlPos, p.endPos, u)
				if eye:DistToSqr(pos) <= MAX_RENDER_DIST then
					local br = Lerp(u, p.baseColor.r, 255)
					local bg = Lerp(u, p.baseColor.g, 255)
					local bb = Lerp(u, p.baseColor.b, 255)
					local alpha = math.floor(220 * (1 - 0.15 * u))
					local ang = billboardAnglesAt(pos)
					cam.Start3D2D(pos, ang, 0.08)
						surface.SetFont("MagicCircle_Medium")
						surface.SetTextColor(br, bg, bb, alpha)
						surface.SetTextPos(0, 0)
						surface.DrawText(p.char or "*")
					cam.End3D2D()
				end
			end
			if now <= endT + 0.05 then
				glyphParticles[write] = p
				write = write + 1
			end
		end
		for i = write, #glyphParticles do glyphParticles[i] = nil end
	end)
end