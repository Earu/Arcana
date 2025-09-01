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
		consumerBaseIntake = 30,  -- base mana per second a consumer can intake from the network
		stageThroughputBonus = 0.25, -- each stabilizer/purifier stage increases throughput by 25%
		maxStages = 3,            -- three rounds of each to reach full purity/stability
		-- Quality
		rawPurity = 0.30,
		rawStability = 0.30,
		perStagePurity = 0.25,
		perStageStability = 0.25,
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
			if not cnode or not IsValid(cnode.ent) then table.remove(MN._consumers, i) goto continue end
			-- Refresh position once in a while (mostly static entities)
			MN:UpdateNodePosition(cnode.ent)
			-- Discover connected component
			local comp = collectComponent(cnode)
			local nProd = #comp.producers
			if nProd <= 0 then goto continue end
			local nStab = math.min(cfg.maxStages, #comp.stabilizers)
			local nPur = math.min(cfg.maxStages, #comp.purifiers)
			local purity = math.Clamp(cfg.rawPurity + nPur * cfg.perStagePurity, 0, 1)
			local stability = math.Clamp(cfg.rawStability + nStab * cfg.perStageStability, 0, 1)
			local throughputMul = 1 + (nPur + nStab) * cfg.stageThroughputBonus
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
				if not IsValid(pnode.ent) then goto nextprod end
				local got = crystalTake(pnode.ent, per)
				if got > 0 then
					delivered = delivered + got
					contributions[#contributions + 1] = {from = pnode.ent, amount = got}
				end
				::nextprod::
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
			::continue::
		end
	end)

	-- Helper exposed to other systems
	function MN:GetEnchantSuccessChance(purity, stability)
		purity = math.Clamp(tonumber(purity) or 0, 0, 1)
		stability = math.Clamp(tonumber(stability) or 0, 0, 1)
		-- Weight both equally; baseline 40%, max near 100%
		local chance = 0.40 + 0.30 * purity + 0.30 * stability
		return math.Clamp(chance, 0.05, 0.995)
	end

	function MN:GetManaCostPerEnchant()
		return self.Config.manaPerEnchant or 50
	end
end

return Arcane

if CLIENT then
	local flows = {}
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
				list[#list + 1] = {from = fromEnt, amount = amt, t = now, purity = purity, stability = stability}
			end
		end

		flows[toEnt] = list
	end)

	local MAX_RENDER_DIST = 2000 * 2000
	-- Glyph stream draw between producers and consumer; fades within 1 second
	hook.Add("PostDrawOpaqueRenderables", "Arcana_ManaNetwork_Draw", function()
		local eye = EyePos()
		for toEnt, list in pairs(flows) do
			if not IsValid(toEnt) then flows[toEnt] = nil goto continue_cons end
			if eye:DistToSqr(toEnt:GetPos()) > MAX_RENDER_DIST then goto continue_cons end

			for _, rec in ipairs(list) do
				local fromEnt = rec.from
				if not IsValid(fromEnt) then goto continue_beam end
				if eye:DistToSqr(fromEnt:GetPos()) > MAX_RENDER_DIST then goto continue_beam end

				local age = CurTime() - rec.t
				local life = 1.0
				if age > life then goto continue_beam end

				-- Color hint by purity/stability
				local baseA = 230 * (1 - age / life)
				local r = Lerp(rec.purity or 0, 120, 30)
				local g = Lerp(rec.stability or 0, 90, 230)
				local b = 255
				local from = fromEnt:WorldSpaceCenter()
				local to = toEnt:WorldSpaceCenter()
				local dir = (to - from)
				local segLen = dir:Length()
				if segLen < 2 then goto continue_beam end

				dir:Normalize()

				-- Per-amount density and size
				local spacing = 32
				local maxGlyphs = math.min(24, math.max(4, math.floor(segLen / spacing)))
				local speed = 120 + math.min(180, rec.amount * 2)
				local size = 10 + math.Clamp(rec.amount * 0.08, 2, 30)

				-- Perpendicular wobble for liveliness
				local up = Vector(0, 0, 1)
				local right = dir:Cross(up)
				if right:LengthSqr() < 0.01 then right = Vector(1, 0, 0) end

				right:Normalize()

				for gi = 0, maxGlyphs - 1 do
					local phase = (CurTime() * speed + gi * spacing) % segLen
					local pos = from + dir * phase + right * math.sin((CurTime() * 4 + gi) * 0.6) * 4
					local ang = billboardAnglesAt(pos)
					local alpha = math.Clamp(baseA * (0.35 + 0.65 * (phase / segLen)), 10, 255)
					cam.Start3D2D(pos, ang, 0.08)
						surface.SetFont("MagicCircle_Medium")
						local ok = pcall(function() end) -- noop to keep lua happy
						surface.SetTextColor(r, g, b, alpha)
						surface.SetTextPos(0, 0)
						surface.DrawText(pickGlyph(gi))
					cam.End3D2D()
				end

				-- Subtle glow at destination
				render.SetMaterial(Material("sprites/light_glow02_add"))
				render.DrawSprite(to, 6, 6, Color(r, g, b, baseA))

				::continue_beam::
			end

			::continue_cons::
		end
	end)
end


