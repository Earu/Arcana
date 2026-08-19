-- Alchemy Table menu.

if not CLIENT then return end

local C

-- Using the station again while its menu is up would otherwise stack a second
-- copy on top of the first.
local activeFrame

----------------------------------------------------------------------
-- Background motif: bubbles climbing inside a flask outline
----------------------------------------------------------------------
local function drawFlaskOutline(cx, cy, w, h, col, alpha)
	local neckW = w * 0.16
	local neckTop = cy - h * 0.5
	local shoulder = cy - h * 0.1
	local bottom = cy + h * 0.5
	local bodyW = w * 0.5

	surface.SetDrawColor(col.r, col.g, col.b, alpha)

	-- Neck
	surface.DrawLine(cx - neckW, neckTop, cx - neckW, shoulder)
	surface.DrawLine(cx + neckW, neckTop, cx + neckW, shoulder)
	surface.DrawLine(cx - neckW * 1.4, neckTop, cx + neckW * 1.4, neckTop)

	-- Shoulders flaring into the body, then the rounded base as segments
	surface.DrawLine(cx - neckW, shoulder, cx - bodyW, bottom - h * 0.16)
	surface.DrawLine(cx + neckW, shoulder, cx + bodyW, bottom - h * 0.16)

	local segs = 14

	for i = 0, segs - 1 do
		local a1 = math.pi + (i / segs) * math.pi
		local a2 = math.pi + ((i + 1) / segs) * math.pi
		local r = h * 0.16

		surface.DrawLine(cx - bodyW + (1 + math.cos(a1)) * bodyW, bottom - r + math.sin(a1) * -r, cx - bodyW + (1 + math.cos(a2)) * bodyW, bottom - r + math.sin(a2) * -r)
	end
end

local function drawAlchemyBackground(w, h, seed)
	local x, y = 6, 6
	local ww, hh = w - 12, h - 12
	ArtDeco.BeginOctagonClip(x, y, ww, hh, 14)

	surface.SetDrawColor(12, 12, 16, 245)
	surface.DrawRect(x, y, ww, hh)

	-- Cool glow pooled at the base, as if lit from under the glass
	local glowR = hh * 0.8

	for k = math.floor(glowR), 8, -12 do
		surface.DrawCircle(x + ww * 0.5, y + hh * 1.05, k, 120, 170, 210, 9 * (1 - k / glowR))
	end

	local cx, cy = x + ww * 0.5, y + hh * 0.52
	drawFlaskOutline(cx, cy, ww * 0.55, hh * 0.78, Color(150, 190, 220), 22)

	math.randomseed(seed or 1)

	-- Bubbles: 1 to 2 px, rising inside the flask and wrapping at the neck
	for i = 1, 40 do
		local spread = ww * 0.24
		local bx = cx + math.Rand(-spread, spread)
		local base = math.random(0, math.floor(hh * 0.7))
		local speed = math.Rand(8, 22)
		local size = math.random(1, 2)
		local by = y + hh * 0.9 - ((base + RealTime() * speed) % (hh * 0.72))
		local sway = math.sin((RealTime() + i * 1.7) * 1.1) * 3

		surface.SetDrawColor(170, 215, 235, 30 + (i % 4) * 12)
		surface.DrawRect(math.Round(bx + sway), math.Round(by), size, size)
	end

	math.randomseed(SysTime())

	ArtDeco.EndOctagonClip()
end

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------
local function itemLabel(item)
	local data = Arcana.Inventory and Arcana.Inventory.Items and Arcana.Inventory.Items[item]

	return data and data.name or item
end

local function canAfford(cost, mult)
	local ply = LocalPlayer()

	for item, amount in pairs(cost) do
		if Arcana.GetItemCount(ply, item) < amount * (mult or 1) then return false end
	end

	return true
end

local function makeButton(parent, label, w, h, fn)
	local btn = vgui.Create("DButton", parent)
	btn:SetText("")
	btn:SetSize(w, h)

	btn.Paint = function(pnl, bw, bh)
		ArtDeco.FillDecoPanel(0, 0, bw, bh, pnl:IsHovered() and C.cardHover or C.cardIdle, 6)
		ArtDeco.DrawDecoFrame(0, 0, bw, bh, pnl:IsHovered() and C.paleGold or C.brassInner, 6)
		draw.SimpleText(label, "Arcana_AncientSmall", bw * 0.5, bh * 0.5, pnl:IsHovered() and C.paleGold or C.textBright, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
	end

	btn.DoClick = fn

	return btn
end

----------------------------------------------------------------------
-- Menu
----------------------------------------------------------------------
local function OpenAlchemyMenu(station)
	local ply = LocalPlayer()
	if not IsValid(ply) or not IsValid(station) then return end

	C = ArtDeco.Colors

	if IsValid(activeFrame) then activeFrame:Remove() end

	local G = Arcana.Gardening
	local frame = vgui.Create("DFrame")
	activeFrame = frame
	frame:SetSize(math.min(720, ScrW()), math.min(600, ScrH()))
	frame:Center()
	frame:SetTitle("")
	frame:MakePopup()

	ArtDeco.MakeDraggableByBand(frame, 44)

	local bgSeed = math.random(1, 10 ^ 9)

	hook.Add("HUDPaint", frame, function()
		local x, y = frame:LocalToScreen(0, 0)
		ArtDeco.DrawBlurRect(x + 6, y + 6, frame:GetWide() - 12, frame:GetTall() - 12, 4, 8)
	end)

	ArtDeco.StyleCloseButton(frame)
	if IsValid(frame.btnMinim) then frame.btnMinim:Hide() end
	if IsValid(frame.btnMaxim) then frame.btnMaxim:Hide() end

	frame.Think = function()
		if not IsValid(station) or ply:GetPos():DistToSqr(station:GetPos()) > (G.USE_RANGE * 1.5) ^ 2 then
			frame:Close()
		end
	end

	frame.Paint = function(_, w, h)
		drawAlchemyBackground(w, h, bgSeed)
		ArtDeco.DrawDecoFrame(6, 6, w - 12, h - 12, C.gold, 14)
		ArtDeco.DrawTitle("Arcana_AncientLarge", "ALCHEMY TABLE", 7, 46, C.paleGold)

		draw.SimpleText("Refine", "Arcana_Ancient", 24, 58, C.paleGold, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
		draw.SimpleText("Exchange", "Arcana_Ancient", 24, 318, C.paleGold, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)

		surface.SetDrawColor(C.gold.r, C.gold.g, C.gold.b, 60)
		surface.DrawRect(24, 82, w - 48, 1)
		surface.DrawRect(24, 342, w - 48, 1)

		draw.SimpleText(Arcana.GetCoins(LocalPlayer()) .. " coins", "Arcana_AncientSmall", w - 24, 62, C.coinGold, TEXT_ALIGN_RIGHT, TEXT_ALIGN_TOP)
	end

	----------------------------------------------------------------------
	-- Recipes
	----------------------------------------------------------------------
	local recipes = vgui.Create("DScrollPanel", frame)
	recipes:SetPos(24, 92)
	recipes:SetSize(frame:GetWide() - 48, 216)
	ArtDeco.StyleScrollBar(recipes, 6)

	for _, recipe in ipairs(G.Recipes) do
		local row = vgui.Create("DPanel", recipes)
		row:Dock(TOP)
		row:DockMargin(0, 0, 0, 6)
		row:SetTall(46)

		row.Paint = function(_, w, h)
			ArtDeco.FillDecoPanel(0, 0, w, h, C.cardIdle, 8)

			surface.SetDrawColor(recipe.color.r, recipe.color.g, recipe.color.b, 230)
			surface.DrawRect(12, h * 0.5 - 8, 16, 16)

			local outAmount = recipe.output[recipe.id] or 0
			draw.SimpleText(outAmount .. "x " .. recipe.label, "Arcana_AncientSmall", 38, 10, C.textBright, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)

			local segs = {}

			for item, amount in pairs(recipe.ingredients) do
				segs[#segs + 1] = {
					text = amount .. " " .. itemLabel(item),
					color = G.DustColors[item] or C.textDim,
					order = item == "crystal_dust" and 1 or 2,
				}
			end

			table.sort(segs, function(a, b) return a.order < b.order end)

			if not canAfford(recipe.ingredients, 1) then
				for _, s in ipairs(segs) do
					s.color = C.textDim
				end
			end

			ArtDeco.DrawCostLine("Arcana_AncientSmall", 38, 26, segs, TEXT_ALIGN_LEFT)

			local held = Arcana.GetItemCount(LocalPlayer(), recipe.id)
			draw.SimpleText("You have " .. held, "Arcana_AncientSmall", w - 150, h * 0.5, C.textDim, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
		end

		local function craft(count)
			if not IsValid(station) then return end

			if not canAfford(recipe.ingredients, count) then
				surface.PlaySound("buttons/button10.wav")

				return
			end

			net.Start("Arcana_Alchemy_Craft")
			net.WriteEntity(station)
			net.WriteString(recipe.id)
			net.WriteUInt(count, 8)
			net.SendToServer()

			surface.PlaySound("buttons/button15.wav")
		end

		-- Positioned in PerformLayout because the row only learns its width
		-- once the scroll panel docks it.
		local one = makeButton(row, "Refine", 62, 26, function() craft(1) end)
		one.PerformLayout = function(pnl)
			pnl:SetPos(row:GetWide() - 136, 10)
		end

		local five = makeButton(row, "x5", 56, 26, function() craft(5) end)
		five.PerformLayout = function(pnl)
			pnl:SetPos(row:GetWide() - 68, 10)
		end
	end

	----------------------------------------------------------------------
	-- Exchange
	----------------------------------------------------------------------
	local exchange = vgui.Create("DScrollPanel", frame)
	exchange:SetPos(24, 352)
	exchange:SetSize(frame:GetWide() - 48, frame:GetTall() - 380)
	ArtDeco.StyleScrollBar(exchange, 6)

	for _, item in ipairs(G.SellOrder) do
		local rate = G.SellRates[item]
		if not rate then continue end

		local row = vgui.Create("DPanel", exchange)
		row:Dock(TOP)
		row:DockMargin(0, 0, 0, 6)
		row:SetTall(34)

		row.Paint = function(_, w, h)
			ArtDeco.FillDecoPanel(0, 0, w, h, C.cardIdle, 8)

			local col = G.DustColors[item] or C.textDim
			surface.SetDrawColor(col.r, col.g, col.b, 230)
			surface.DrawRect(12, h * 0.5 - 7, 14, 14)

			local held = Arcana.GetItemCount(LocalPlayer(), item)
			draw.SimpleText(itemLabel(item), "Arcana_AncientSmall", 34, h * 0.5, held > 0 and C.textBright or C.textDim, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
			draw.SimpleText("x" .. held, "Arcana_AncientSmall", 210, h * 0.5, C.textDim, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)

			ArtDeco.DrawCostLine("Arcana_AncientSmall", w - 150, h * 0.5 - 8, {{text = rate .. " each", icon = ArtDeco.Icons.coin, color = C.coinGold}}, TEXT_ALIGN_RIGHT)
		end

		local function sell(count)
			if not IsValid(station) then return end

			local held = Arcana.GetItemCount(LocalPlayer(), item)
			local amount = count == "all" and held or math.min(count, held)

			if amount <= 0 then
				surface.PlaySound("buttons/button10.wav")

				return
			end

			net.Start("Arcana_Alchemy_Sell")
			net.WriteEntity(station)
			net.WriteString(item)
			net.WriteUInt(math.min(amount, 65535), 16)
			net.SendToServer()

			surface.PlaySound("buttons/button15.wav")
		end

		local ten = makeButton(row, "Sell 10", 62, 24, function() sell(10) end)
		ten.PerformLayout = function(pnl)
			pnl:SetPos(row:GetWide() - 136, 5)
		end

		local all = makeButton(row, "All", 56, 24, function() sell("all") end)
		all.PerformLayout = function(pnl)
			pnl:SetPos(row:GetWide() - 68, 5)
		end
	end
end

net.Receive("Arcana_Alchemy_Open", function()
	local station = net.ReadEntity()
	if not IsValid(station) then return end

	OpenAlchemyMenu(station)
end)
