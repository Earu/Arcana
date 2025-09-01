local Arcane = _G.Arcane or {}

if SERVER then
	util.AddNetworkString("Arcana_ManaNetwork_Flow")
	Arcane.ManaNetwork = Arcane.ManaNetwork or {}
	local MN = Arcane.ManaNetwork

	-- Configuration
	MN.Config = MN.Config or {
		-- Graph/linking
		gridCell = 600,           -- spatial bucket size for neighbor discovery
		defaultLinkRange = 500,   -- default link range when a node doesn't specify

		-- Transfer
		consumerBaseIntake = 30,        -- base mana per second a consumer can intake from the network
		perProcessorThroughputBonus = 0.25, -- each stabilizer/purifier increases throughput by 25%

		-- Quality
		rawPurity = 0.30,
		rawStability = 0.30,
		perProcessorPurity = 0.25,     -- amount added to purity by each purifier
		perProcessorStability = 0.25,  -- amount added to stability by each stabilizer

		-- Enchant costs
		manaPerEnchant = 50,
	}

	MN._nodes = MN._nodes or {}        -- { [ent] = node }
	MN._buckets = MN._buckets or {}    -- { [key] = {node, ...} }
	MN._consumers = MN._consumers or {} -- array of nodes of type "consumer"

	local function regionKey(pos, size)
		size = size or MN.Config.gridCell
		local cell = size
		local x = math.floor(pos.x / cell)
		local y = math.floor(pos.y / cell)
		return tostring(x) .. ":" .. tostring(y)
	end

	local function addToBucket(node)
		local key = regionKey(node.pos)
		node._bucket = key
		MN._buckets[key] = MN._buckets[key] or {}
		table.insert(MN._buckets[key], node)
	end

	local function removeFromBucket(node)
		local key = node._bucket
		if not key then return end
		local arr = MN._buckets[key]
		if not arr then return end
		for i = #arr, 1, -1 do
			if arr[i] == node then table.remove(arr, i) end
		end
		if #arr == 0 then MN._buckets[key] = nil end
		node._bucket = nil
	end

	local function nearbyBuckets(pos)
		local cell = MN.Config.gridCell
		local baseX = math.floor(pos.x / cell)
		local baseY = math.floor(pos.y / cell)
		local out = {}
		for dy = -1, 1 do
			for dx = -1, 1 do
				local key = tostring(baseX + dx) .. ":" .. tostring(baseY + dy)
				local b = MN._buckets[key]
				if b then out[#out + 1] = b end
			end
		end
		return out
	end

	local function linkNeighbors(node)
		node.links = node.links or {}
		local range = node.range or MN.Config.defaultLinkRange
		local r2 = range * range
		for _, bucket in ipairs(nearbyBuckets(node.pos)) do
			for _, other in ipairs(bucket) do
				if other ~= node and IsValid(other.ent) then
					local maxR = math.min(range, other.range or MN.Config.defaultLinkRange)
					local d2 = other.pos:DistToSqr(node.pos)
					if d2 <= maxR * maxR then
						node.links[other] = true
						other.links = other.links or {}
						other.links[node] = true
					end
				end
			end
		end
	end

	local function unlinkAll(node)
		if not node.links then return end
		for other in pairs(node.links) do
			if other.links then other.links[node] = nil end
		end
		node.links = {}
	end

	function MN:RegisterNode(ent, def)
		if not IsValid(ent) then return nil end
		local node = {
			ent = ent,
			type = tostring(def.type or "misc"),
			pos = ent:GetPos(),
			range = tonumber(def.range or MN.Config.defaultLinkRange) or MN.Config.defaultLinkRange,
			intake = tonumber(def.intake or 0) or 0, -- only used for consumers; 0 means use defaults
			links = {},
		}
		MN._nodes[ent] = node
		addToBucket(node)
		linkNeighbors(node)
		if node.type == "consumer" then
			MN._consumers[#MN._consumers + 1] = node
		end
		-- Auto-clean on remove
		ent:CallOnRemove("Arcana_MN_Unregister", function(e)
			MN:UnregisterNode(e)
		end)
		return node
	end

	-- Convenience wrappers
	function MN:RegisterConsumer(ent, opts)
		opts = opts or {}
		opts.type = "consumer"
		return self:RegisterNode(ent, opts)
	end

	function MN:RegisterProducer(ent, opts)
		opts = opts or {}
		opts.type = "producer"
		return self:RegisterNode(ent, opts)
	end

	function MN:UnregisterNode(ent)
		local node = MN._nodes[ent]
		if not node then return end
		unlinkAll(node)
		removeFromBucket(node)
		MN._nodes[ent] = nil
		if node.type == "consumer" then
			for i = #MN._consumers, 1, -1 do
				if MN._consumers[i] == node then table.remove(MN._consumers, i) end
			end
		end
	end

	function MN:UpdateNodePosition(ent)
		local node = MN._nodes[ent]
		if not node then return end
		local newPos = ent:GetPos()
		if node.pos:DistToSqr(newPos) < 1 then return end
		-- Rebucket and relink
		unlinkAll(node)
		removeFromBucket(node)
		node.pos = newPos
		addToBucket(node)
		linkNeighbors(node)
	end

	-- Simple BFS over current graph to collect connected nodes for a consumer
	local function collectComponent(startNode)
		local out = {producers = {}, stabilizers = {}, purifiers = {}}
		local q = {startNode}
		local seen = {[startNode] = true}
		while #q > 0 do
			local cur = table.remove(q, 1)
			for other in pairs(cur.links or {}) do
				if not seen[other] and IsValid(other.ent) then
					seen[other] = true
					q[#q + 1] = other
					if other.type == "producer" then
						out.producers[#out.producers + 1] = other
					elseif other.type == "stabilizer" then
						out.stabilizers[#out.stabilizers + 1] = other
					elseif other.type == "purifier" then
						out.purifiers[#out.purifiers + 1] = other
					end
				end
			end
		end
		return out
	end

	-- Public: get counts of connected processors for a given consumer entity
	function MN:GetConnectedProcessorCounts(consumerEnt)
		if not IsValid(consumerEnt) then return 0, 0 end

		local node = MN._nodes[consumerEnt]
		if not node then return 0, 0 end

		local comp = collectComponent(node)
		return #comp.stabilizers, #comp.purifiers
	end

	-- Utilities expected on entities
	local function crystalTake(ent, amt)
		if ent and ent.TakeStoredMana then
			return ent:TakeStoredMana(amt)
		end
		return 0
	end

	local function consumerAdd(ent, amt, purity, stability)
		if ent and ent.AddMana then
			ent:AddMana(amt, purity, stability)
		end
	end

	-- Periodic transfer: pull from connected producers into consumers, applying stages
	timer.Create("Arcana_ManaNetwork_Tick", 1.0, 0, function()
		if not next(MN._nodes) then return end
		local cfg = MN.Config
		for i = #MN._consumers, 1, -1 do
			local cnode = MN._consumers[i]
			if not cnode or not IsValid(cnode.ent) then
				table.remove(MN._consumers, i)
				continue
			end

			-- Refresh position once in a while (mostly static entities)
			MN:UpdateNodePosition(cnode.ent)

			-- Discover connected component
			local comp = collectComponent(cnode)
			local nProd = #comp.producers
			if nProd <= 0 then continue end

			local nStab = #comp.stabilizers
			local nPur = #comp.purifiers

			-- Quality saturates at 1.0 naturally; no artificial cap
			local purity = math.Clamp(cfg.rawPurity + nPur * (cfg.perProcessorPurity or 0), 0, 1)
			local stability = math.Clamp(cfg.rawStability + nStab * (cfg.perProcessorStability or 0), 0, 1)

			-- Throughput scales with every processor present (no cap)
			local throughputMul = 1 + (nPur + nStab) * (cfg.perProcessorThroughputBonus or 0)

			-- Determine consumer's base intake
			local baseIntake = cnode.intake and cnode.intake > 0 and cnode.intake or cfg.consumerBaseIntake
			if cnode.ent.GetManaIntakePerSecond then
				local ok, v = pcall(cnode.ent.GetManaIntakePerSecond, cnode.ent)
				if ok and tonumber(v) and v > 0 then baseIntake = v end
			end

			local intake = baseIntake * throughputMul

			-- Pull evenly from producers
			local per = intake / nProd
			local delivered = 0
			local contributions = {}
			for _, pnode in ipairs(comp.producers) do
				if not IsValid(pnode.ent) then continue end

				local got = crystalTake(pnode.ent, per)
				if got > 0 then
					delivered = delivered + got
					contributions[#contributions + 1] = {from = pnode.ent, amount = got}
				end
			end

			if delivered > 0 then
				consumerAdd(cnode.ent, delivered, purity, stability)
				-- Broadcast a flow snapshot (throttled by tick at 1s)
				net.Start("Arcana_ManaNetwork_Flow", true)
				net.WriteEntity(cnode.ent)
				net.WriteFloat(purity)
				net.WriteFloat(stability)
				net.WriteUInt(#contributions, 8)
				for _, rec in ipairs(contributions) do
					net.WriteEntity(rec.from)
					net.WriteFloat(rec.amount)
				end
				net.Broadcast()
			end
		end
	end)

end

if CLIENT then
	local flows = {}
	local glyphParticles = {}

	-- Glyph stream config
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
		local len = utf8 and utf8.len and utf8.len(phrase) or #phrase
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

	-- Receive flow snapshots
	net.Receive("Arcana_ManaNetwork_Flow", function()
		local toEnt = net.ReadEntity()
		local purity = net.ReadFloat()
		local stability = net.ReadFloat()
		local count = net.ReadUInt(8)
		if not IsValid(toEnt) then
			for i = 1, count do
				net.ReadEntity()
				net.ReadFloat()
			end

			return
		end

		flows[toEnt] = flows[toEnt] or {}
		local now = CurTime()
		local list = {}
		for i = 1, count do
			local fromEnt = net.ReadEntity()
			local amt = net.ReadFloat()
			if IsValid(fromEnt) and amt > 0 then
				local rec = {from = fromEnt, amount = amt, t = now, purity = purity, stability = stability}
				list[#list + 1] = rec

				-- spawn glyph particles for this contribution
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
					local density = 2
					local countGlyphs = math.Clamp(math.floor(amt * 0.15 * density), 5, 80)
					for gi = 1, countGlyphs do
						local speed = math.Rand(120, 220) -- slower travel
						local dur = dist / speed
						local startDelay = math.Rand(0, 1.0) -- slightly more stagger

						glyphParticles[#glyphParticles + 1] = {
							startPos = fromPos,
							ctrlPos = ctrl,
							endPos = toPos,
							startTime = now + startDelay,
							duration = dur,
							char = pickGlyph(gi + math.floor(now * 13)),
							baseColor = Color(baseColor.r, baseColor.g, baseColor.b, 255),
							quality = math.Clamp((purity + stability) * 0.5, 0, 1),
							size = math.Rand(10, 16)
						}
					end
				end
			end
		end

		flows[toEnt] = list
	end)

	local MAX_RENDER_DIST = 2000 * 2000
	-- Glyph particles travel independently along curved bezier paths; color fades toward white by quality
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
					-- Color gradient: base producer color to white by quality and progress
					local mix = math.Clamp(p.quality * u, 0, 1)
					local br = Lerp(mix, p.baseColor.r, 255)
					local bg = Lerp(mix, p.baseColor.g, 255)
					local bb = Lerp(mix, p.baseColor.b, 255)
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


