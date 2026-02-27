-- ============================================================================
-- DEFAULT INVENTORY SYSTEM
-- ============================================================================
-- This provides a basic coin and item inventory for Arcana.
-- Implements the functions defined in third_party.lua
-- ============================================================================

local Arcana = _G.Arcana or {}

Arcana.Inventory = Arcana.Inventory or {}

-- Item definitions for display purposes
Arcana.Inventory.Items = Arcana.Inventory.Items or {}

-- Register an item for display in the inventory
-- @param itemClass string - Unique identifier for the item
-- @param itemData table - Item definition with name, description, model, etc.
function Arcana:RegisterItem(itemClass, itemData)
	if not itemClass or not itemData then
		ErrorNoHalt("[Arcana] RegisterItem: Invalid itemClass or itemData\n")
		return
	end

	Arcana.Inventory.Items[itemClass] = itemData
	Arcana.RunHook("ItemRegistered", itemClass, itemData)
end

-- ============================================================================
-- DEFAULT RITUAL ITEMS
-- ============================================================================
-- Register default items used in rituals

Arcana:RegisterItem("poison", {
	name = "Poison Vial",
	description = "A vial containing toxic liquid.",
	model = "models/props_junk/garbage_glassbottle001a.mdl",
	color = Color(100, 200, 100)
})

Arcana:RegisterItem("radioactive", {
	name = "Radioactive Material",
	description = "Highly radioactive material. Handle with extreme caution.",
	model = "models/props_c17/oildrum001.mdl",
	color = Color(255, 220, 0)
})

Arcana:RegisterItem("battery", {
	name = "Battery",
	description = "A charged battery crackling with electrical energy.",
	model = "models/Items/car_battery01.mdl"
})

Arcana:RegisterItem("waterbottle", {
	name = "Water Bottle",
	description = "A bottle of pure water.",
	model = "models/props_junk/garbage_plasticbottle003a.mdl",
})

Arcana:RegisterItem("banana", {
	name = "Banana",
	description = "A ripe banana. Full of potassium.",
	model = "models/props/cs_italy/bananna.mdl"
})

Arcana:RegisterItem("melon", {
	name = "Melon",
	description = "A fresh, juicy melon.",
	model = "models/props_junk/watermelon01.mdl"
})

Arcana:RegisterItem("orange", {
	name = "Orange",
	description = "A bright orange citrus fruit.",
	model = "models/props/cs_italy/orange.mdl"
})

-- ============================================================================
-- SERVER-SIDE: SQLite Persistence
-- ============================================================================
if SERVER then
	local dbEnsured = false

	local function ensureInventoryDB()
		if dbEnsured then return true end
		if not sql.TableExists("arcane_inventory") then
			local ok = sql.Query([[CREATE TABLE IF NOT EXISTS arcane_inventory (
				steamid TEXT PRIMARY KEY,
				coins INTEGER NOT NULL DEFAULT 0,
				items TEXT NOT NULL DEFAULT '{}'
			);]])
			if ok == false then
				ErrorNoHalt("[Arcana] Failed to create inventory table: " .. tostring(sql.LastError()) .. "\n")
				return false
			end
		end
		dbEnsured = true
		return true
	end

	local function getInventoryData(steamid)
		if not ensureInventoryDB() then return {coins = 0, items = {}} end
		local rows = sql.Query("SELECT * FROM arcane_inventory WHERE steamid = '" .. sql.SQLStr(steamid, true) .. "' LIMIT 1;")
		if rows and rows[1] then
			local ok, items = pcall(util.JSONToTable, rows[1].items or "{}")
			return {
				coins = tonumber(rows[1].coins) or 0,
				items = (ok and istable(items)) and items or {}
			}
		end
		return {coins = 0, items = {}}
	end

	local function saveInventoryData(steamid, data)
		if not ensureInventoryDB() then return end
		local coins = math.max(0, tonumber(data.coins) or 0)
		local itemsJson = util.TableToJSON(data.items or {}) or "{}"
		local sid = sql.SQLStr(steamid, true)
		local ok = sql.Query(string.format(
			"INSERT OR REPLACE INTO arcane_inventory (steamid, coins, items) VALUES ('%s', %d, %s);",
			sid, coins, sql.SQLStr(itemsJson)
		))
		if ok == false then
			ErrorNoHalt("[Arcana] Failed to save inventory: " .. tostring(sql.LastError()) .. "\n")
		end
	end

	Arcana.Inventory.Cache = Arcana.Inventory.Cache or {}

	function Arcana.Inventory:Get(ply)
		if not IsValid(ply) then return {coins = 0, items = {}} end
		local sid = ply:SteamID64()
		if not Arcana.Inventory.Cache[sid] then
			Arcana.Inventory.Cache[sid] = getInventoryData(sid)
		end
		return Arcana.Inventory.Cache[sid]
	end

	function Arcana.Inventory:Save(ply)
		if not IsValid(ply) then return end
		local sid = ply:SteamID64()
		local data = Arcana.Inventory.Cache[sid]
		if data then
			saveInventoryData(sid, data)
		end
	end

	function Arcana.Inventory:SyncToClient(ply)
		if not IsValid(ply) then return end
		local data = self:Get(ply)
		net.Start("Arcana_InventorySync")
		net.WriteUInt(data.coins, 32)
		local itemsJson = util.TableToJSON(data.items) or "{}"
		net.WriteString(itemsJson)
		net.Send(ply)
	end

	-- Override default functions with actual implementation
	function Arcana:GiveCoins(ply, amount, reason)
		if not IsValid(ply) or amount <= 0 then return false end
		local inv = Arcana.Inventory:Get(ply)
		inv.coins = inv.coins + amount
		Arcana.Inventory:SyncToClient(ply)
		Arcana.RunHook("CoinsGiven", ply, amount, reason)
		
		-- Send notification to client
		net.Start("Arcana_CoinsGained")
		net.WriteUInt(amount, 32)
		net.WriteString(reason or "")
		net.Send(ply)
		
		return true
	end

	function Arcana:TakeCoins(ply, amount, reason)
		if not IsValid(ply) or amount <= 0 then return false end
		local inv = Arcana.Inventory:Get(ply)
		if inv.coins < amount then return false end
		inv.coins = inv.coins - amount
		Arcana.Inventory:SyncToClient(ply)
		Arcana.RunHook("CoinsTaken", ply, amount, reason)
		
		-- Send notification to client
		net.Start("Arcana_CoinsTaken")
		net.WriteUInt(amount, 32)
		net.WriteString(reason or "")
		net.Send(ply)
		
		return true
	end

	function Arcana:GiveItem(ply, itemClass, amount, reason)
		if not IsValid(ply) or amount <= 0 then return false end
		local inv = Arcana.Inventory:Get(ply)
		inv.items[itemClass] = (inv.items[itemClass] or 0) + amount
		Arcana.Inventory:SyncToClient(ply)
		Arcana.RunHook("ItemGiven", ply, itemClass, amount, reason)
		
		-- Send notification to client
		net.Start("Arcana_ItemGained")
		net.WriteString(itemClass)
		net.WriteUInt(amount, 32)
		net.WriteString(reason or "")
		net.Send(ply)
		
		return true
	end

	function Arcana:TakeItem(ply, itemClass, amount, reason)
		if not IsValid(ply) or amount <= 0 then return false end
		local inv = Arcana.Inventory:Get(ply)
		if (inv.items[itemClass] or 0) < amount then return false end
		inv.items[itemClass] = inv.items[itemClass] - amount
		if inv.items[itemClass] <= 0 then
			inv.items[itemClass] = nil
		end
		Arcana.Inventory:SyncToClient(ply)
		Arcana.RunHook("ItemTaken", ply, itemClass, amount, reason)
		
		-- Send notification to client
		net.Start("Arcana_ItemTaken")
		net.WriteString(itemClass)
		net.WriteUInt(amount, 32)
		net.WriteString(reason or "")
		net.Send(ply)
		
		return true
	end

	-- Player lifecycle hooks
	hook.Add("Arcana_LoadedPlayerData", "Arcana_InventorySyncOnLoad", function(ply)
		Arcana.Inventory:SyncToClient(ply)
	end)

	hook.Add("PlayerDisconnected", "Arcana_InventorySave", function(ply)
		Arcana.Inventory:Save(ply)
		Arcana.Inventory.Cache[ply:SteamID64()] = nil
	end)

	timer.Create("Arcana_InventoryAutosave", 120, 0, function()
		for _, ply in ipairs(player.GetAll()) do
			Arcana.Inventory:Save(ply)
		end
	end)

	util.AddNetworkString("Arcana_InventorySync")
	util.AddNetworkString("Arcana_CoinsGained")
	util.AddNetworkString("Arcana_CoinsTaken")
	util.AddNetworkString("Arcana_ItemGained")
	util.AddNetworkString("Arcana_ItemTaken")
end

-- ============================================================================
-- CLIENT-SIDE: Cache and UI
-- ============================================================================
if CLIENT then
	Arcana.Inventory = Arcana.Inventory or {}
	Arcana.Inventory.LocalCache = Arcana.Inventory.LocalCache or {coins = 0, items = {}}

	net.Receive("Arcana_InventorySync", function()
		local coins = net.ReadUInt(32)
		local itemsJson = net.ReadString()
		local ok, items = pcall(util.JSONToTable, itemsJson)
		Arcana.Inventory.LocalCache = {
			coins = coins,
			items = (ok and istable(items)) and items or {}
		}
	end)

	net.Receive("Arcana_CoinsGained", function()
		local amount = net.ReadUInt(32)
		local reason = net.ReadString()
		if Arcana.HUD and Arcana.HUD.ShowCoinsGainedAnnouncement then
			Arcana.HUD.ShowCoinsGainedAnnouncement(LocalPlayer(), amount, reason)
		end
	end)

	net.Receive("Arcana_CoinsTaken", function()
		local amount = net.ReadUInt(32)
		local reason = net.ReadString()
		if Arcana.HUD and Arcana.HUD.ShowCoinsTakenAnnouncement then
			Arcana.HUD.ShowCoinsTakenAnnouncement(LocalPlayer(), amount, reason)
		end
	end)

	net.Receive("Arcana_ItemGained", function()
		local itemClass = net.ReadString()
		local amount = net.ReadUInt(32)
		local reason = net.ReadString()
		if Arcana.HUD and Arcana.HUD.ShowItemGainedAnnouncement then
			Arcana.HUD.ShowItemGainedAnnouncement(LocalPlayer(), itemClass, amount, reason)
		end
	end)

	net.Receive("Arcana_ItemTaken", function()
		local itemClass = net.ReadString()
		local amount = net.ReadUInt(32)
		local reason = net.ReadString()
		if Arcana.HUD and Arcana.HUD.ShowItemTakenAnnouncement then
			Arcana.HUD.ShowItemTakenAnnouncement(LocalPlayer(), itemClass, amount, reason)
		end
	end)

	-- ============================================================================
	-- ART DECO INVENTORY UI
	-- ============================================================================
	Arcana.Inventory.Panel = nil

	local function createInventoryPanel()
		if IsValid(Arcana.Inventory.Panel) then
			Arcana.Inventory.Panel:Remove()
		end

		local panel = vgui.Create("DPanel")
		local scale = math.max(1.2, ScrW() / 2560 )
		local itemsPerRow = 6
		local visibleRows = 3
		local itemCardW = math.floor(110 / scale)
		local itemCardH = math.floor(115 / scale)
		local itemSpacing = math.floor(5 / scale)
		local panelMargin = math.floor(10 / scale)
		local headerHeight = math.floor(30 / scale)
		local headerGap = math.floor(5 / scale)

		local panelW = (panelMargin * 2) + (itemCardW * itemsPerRow) + ((itemsPerRow - 1) * itemSpacing) + (itemSpacing * 2)
		local itemsContentH = (itemCardH * visibleRows) + ((visibleRows - 1) * itemSpacing)
		local panelH = panelMargin + headerHeight + headerGap + (itemSpacing * 2) + itemsContentH + panelMargin

		panel:SetSize(panelW, panelH)
		panel:SetPos(ScrW() / 2 - panelW / 2, ScrH() - panelH - 20)
		panel:SetVisible(false)
		panel:SetMouseInputEnabled(true)
		panel:SetKeyboardInputEnabled(false)
		panel:MakePopup()
		panel:SetDrawOnTop(true)

		panel.Think = function(pnl)
			if pnl:IsVisible() then
				pnl:SetPos(ScrW() / 2 - panelW / 2, ScrH() - panelH - 20)
			end
		end

		hook.Add("HUDPaint", panel, function()
			if not IsValid(panel) or not panel:IsVisible() then return end
			local x, y = panel:LocalToScreen(0, 0)
			ArtDeco.DrawBlurRect(x, y, panel:GetWide(), panel:GetTall(), 4, 8)
		end)

		panel.Paint = function(pnl, w, h)
			ArtDeco.FillDecoPanel(0, 0, w, h, ArtDeco.Colors.decoBg, math.floor(12 / scale))
			ArtDeco.DrawDecoFrame(0, 0, w, h, ArtDeco.Colors.gold, math.floor(12 / scale))
		end

		local header = vgui.Create("DPanel", panel)
		header:SetSize(panelW - (panelMargin * 2), headerHeight)
		header:SetPos(panelMargin, panelMargin)
		local coinIcon = Material("icon16/coins.png")
		header.Paint = function(pnl, w, h)
			local titleText = string.upper("Inventory")
			surface.SetFont("Arcana_DecoTitle")
			local titleW = surface.GetTextSize(titleText)
			draw.SimpleText(titleText, "Arcana_DecoTitle", 0, 0, ArtDeco.Colors.paleGold, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)

			local coins = Arcana.Inventory.LocalCache.coins or 0
			local chipText = string.Comma(coins)
			surface.SetFont("Arcana_Ancient")
			local cw, ch = surface.GetTextSize(chipText)

			local iconSize = math.floor(16 / scale)
			local iconPad = math.floor(6 / scale)
			local chipW = cw + math.floor(36 / scale)
			local chipH = ch + math.floor(6 / scale)
			local chipX = w - chipW
			local chipY = 0

			ArtDeco.FillDecoPanel(chipX, chipY, chipW, chipH, ArtDeco.Colors.paleGold, math.floor(6 / scale))

			surface.SetDrawColor(ArtDeco.Colors.chipTextCol)
			surface.SetMaterial(coinIcon)
			surface.DrawTexturedRect(chipX + iconPad, chipY + (chipH - iconSize) / 2, iconSize, iconSize)

			draw.SimpleText(chipText, "Arcana_Ancient", chipX + math.floor(26 / scale), chipY + (chipH - ch) * 0.5, ArtDeco.Colors.chipTextCol, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
		end

		local itemsPanel = vgui.Create("DPanel", panel)
		local itemsPanelY = panelMargin + headerHeight + headerGap
		local itemsPanelH = panelH - itemsPanelY - panelMargin
		itemsPanel:SetSize(panelW - (panelMargin * 2), itemsPanelH)
		itemsPanel:SetPos(panelMargin, itemsPanelY)

		hook.Add("HUDPaint", itemsPanel, function()
			if not IsValid(itemsPanel) or not IsValid(panel) or not panel:IsVisible() then return end
			local x, y = itemsPanel:LocalToScreen(0, 0)
			ArtDeco.DrawBlurRect(x, y, itemsPanel:GetWide(), itemsPanel:GetTall(), 3, 6)
		end)

		itemsPanel.Paint = function(pnl, w, h)
			ArtDeco.FillDecoPanel(0, 0, w, h, ArtDeco.Colors.cardIdle, math.floor(8 / scale))
			ArtDeco.DrawDecoFrame(0, 0, w, h, ArtDeco.Colors.paleGold, math.floor(8 / scale))
		end

		local scroll = vgui.Create("DScrollPanel", itemsPanel)
		scroll:Dock(FILL)
		scroll:DockMargin(itemSpacing, itemSpacing, itemSpacing, itemSpacing)

		local vbar = scroll:GetVBar()
		vbar:SetWide(math.floor(8 / scale))
		vbar.Paint = function() end
		vbar.btnUp.Paint = function() end
		vbar.btnDown.Paint = function() end
		vbar.btnGrip.Paint = function(pnl, w, h)
			surface.SetDrawColor(ArtDeco.Colors.gold)
			surface.DrawRect(0, 0, w, h)
		end

		local greekGlyphs = {"Α", "Β", "Γ", "Δ", "Ε", "Ζ", "Η", "Θ", "Ι", "Κ", "Λ", "Μ", "Ν", "Ξ", "Ο", "Π", "Ρ", "Σ", "Τ", "Υ", "Φ", "Χ", "Ψ", "Ω"}

		local function refreshItems()
			scroll:Clear()
			local items = Arcana.Inventory.LocalCache.items or {}

			local gridContainer = vgui.Create("DPanel", scroll)
			gridContainer:Dock(TOP)
			gridContainer.Paint = function() end

			local itemList = {}
			for itemClass, count in pairs(items) do
				table.insert(itemList, {class = itemClass, count = count})
			end

			local numRows = math.max(visibleRows, math.ceil(#itemList / itemsPerRow))
			local totalSlots = numRows * itemsPerRow
			gridContainer:SetTall(numRows * itemCardH + (numRows - 1) * itemSpacing)

			local vbar = scroll:GetVBar()
			if numRows <= visibleRows then
				vbar:SetWide(0)
				vbar:SetEnabled(false)
			else
				vbar:SetWide(math.floor(8 / scale))
				vbar:SetEnabled(true)
			end

			for i = 1, totalSlots do
				local col = (i - 1) % itemsPerRow
				local row = math.floor((i - 1) / itemsPerRow)
				local x = col * (itemCardW + itemSpacing)
				local y = row * (itemCardH + itemSpacing)

				local itemData = itemList[i]
				local itemClass = itemData and itemData.class
				local count = itemData and itemData.count
				local itemDef = itemClass and (Arcana.Inventory.Items[itemClass] or {
					name = itemClass,
					description = "",
					model = "models/props_junk/cardboard_box004a.mdl"
				})

				local itemCard = vgui.Create("DPanel", gridContainer)
				itemCard:SetSize(itemCardW, itemCardH)
				itemCard:SetPos(x, y)
				itemCard.Paint = function(pnl, w, h)
					if not itemData then
						ArtDeco.FillDecoPanel(0, 0, w, h, ColorAlpha(ArtDeco.Colors.decoPanel, 100), math.floor(6 / scale))
						ArtDeco.DrawDecoFrame(0, 0, w, h, ColorAlpha(ArtDeco.Colors.brassInner, 80), math.floor(6 / scale))

						local glyph = greekGlyphs[((i - 1) % #greekGlyphs) + 1]
						draw.SimpleText(glyph, "Arcana_AncientGlyph", w / 2, h / 2, ColorAlpha(ArtDeco.Colors.brassInner, 60), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
					else
						local isHovered = pnl:IsHovered()
						ArtDeco.FillDecoPanel(0, 0, w, h, isHovered and ArtDeco.Colors.cardHover or ArtDeco.Colors.decoPanel, math.floor(6 / scale))
						ArtDeco.DrawDecoFrame(0, 0, w, h, ArtDeco.Colors.brassInner, math.floor(6 / scale))
					end
				end

				if not itemData then continue end

				if itemDef.model then
					local modelPanel = vgui.Create("DModelPanel", itemCard)
					modelPanel:SetSize(itemCardW, itemCardH)
					modelPanel:SetPos(0, 0)
					modelPanel:SetMouseInputEnabled(false)
					modelPanel:SetModel(itemDef.model)

					local ent = modelPanel:GetEntity()
					if IsValid(ent) then
						if itemDef.material then
							ent:SetMaterial(itemDef.material)
						end
						if itemDef.color then
							ent:SetColor(itemDef.color)
						end

						local mins, maxs = ent:GetRenderBounds()
						local size = maxs - mins
						local radius = math.max(size.x, size.y, size.z)
						local center = (mins + maxs) / 2

						local fov = 50
						local distance = radius / math.tan(math.rad(fov / 2))
						distance = distance * 0.75

						modelPanel:SetFOV(fov)
						modelPanel:SetCamPos(center + Vector(distance, distance, distance * 0.5))
						modelPanel:SetLookAt(center)
					end

					if itemDef.draw then
						function modelPanel:Paint(w, h)
							itemDef.draw(self, w, h)
						end

						modelPanel.LayoutEntity = function(pnl, entity)
						end
					else
						modelPanel.LayoutEntity = function(pnl, entity)
							if entity.SetAngles then
								entity:SetAngles(Angle(0, RealTime() * 40, 0))
							end
						end
					end
				end

				local label = vgui.Create("DLabel", itemCard)
				label:SetPos(math.floor(5 / scale), math.floor(70 / scale))
				label:SetSize(math.floor(100 / scale), math.floor(16 / scale))
				label:SetFont("Arcana_AncientSmall")
				label:SetTextColor(ArtDeco.Colors.textBright)
				label:SetText(itemDef.name)
				label:SetContentAlignment(5)
				label:SetMouseInputEnabled(false)

				local countLabel = vgui.Create("DLabel", itemCard)
				countLabel:SetPos(math.floor(5 / scale), math.floor(86 / scale))
				countLabel:SetSize(math.floor(100 / scale), math.floor(20 / scale))
				countLabel:SetFont("Arcana_AncientSmall")
				countLabel:SetTextColor(ArtDeco.Colors.textDim)
				countLabel:SetText("x" .. count)
				countLabel:SetContentAlignment(5)
				countLabel:SetMouseInputEnabled(false)

				itemCard:SetCursor("hand")
				local tooltipText = ("%s (x%d)\n\n%s"):format(itemDef.name, count, itemDef.description)
				ArtDeco.AddTooltip(itemCard, tooltipText, math.floor(250 / scale), nil)
			end
		end

		Arcana.Inventory.Panel = panel
		Arcana.Inventory.RefreshItems = refreshItems

		refreshItems()

		return panel
	end

	hook.Add("OnContextMenuOpen", "Arcana_InventoryShow", function()
		local panel = IsValid(Arcana.Inventory.Panel) and Arcana.Inventory.Panel or createInventoryPanel()
		if IsValid(panel) then
			local shouldDraw = Arcana.RunHook("ShouldDrawInventory")
			if shouldDraw == false then return end

			panel:SetVisible(true)
			panel:MoveToFront()
			if Arcana.Inventory.RefreshItems then
				Arcana.Inventory.RefreshItems()
			end
		end
	end)

	hook.Add("OnContextMenuClose", "Arcana_InventoryHide", function()
		if IsValid(Arcana.Inventory.Panel) then
			Arcana.Inventory.Panel:SetVisible(false)
		end
	end)
end

-- ============================================================================
-- SHARED: Default Getter Functions
-- ============================================================================
function Arcana:GetCoins(ply)
	if SERVER then
		local inv = Arcana.Inventory:Get(ply)
		return inv.coins
	else
		return Arcana.Inventory.LocalCache.coins
	end
end

function Arcana:GetItemCount(ply, itemClass)
	if SERVER then
		local inv = Arcana.Inventory:Get(ply)
		return inv.items[itemClass] or 0
	else
		return (Arcana.Inventory.LocalCache.items or {})[itemClass] or 0
	end
end

return Arcana
