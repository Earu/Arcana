local Arcane = _G.Arcane or {}
_G.Arcane = Arcane

-- ============================================================================
-- DEFAULT INVENTORY SYSTEM
-- ============================================================================
-- This provides a basic coin and item inventory for Arcana.
-- Third-party addons can override these functions to integrate with their own
-- economy systems (e.g., DarkRP money, PS2 points, custom inventories).
--
-- Override the functions below in your Initialize hook AFTER Arcana has loaded.
-- ============================================================================

Arcane.Inventory = Arcane.Inventory or {}

-- Item definitions for display purposes
Arcane.Inventory.Items = {
	["mana_crystal_shard"] = {
		name = "Crystal Shard",
		description = "A crystallized fragment of pure magical energy.",
		model = "models/props_debris/concrete_chunk05g.mdl",
		material = "models/shiny",
		color = Color(120, 200, 255),
		-- Use the entity's actual draw functions
		entityClass = "arcana_crystal_shard"
	},
}

-- Server-side inventory implementation with SQLite persistence
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

	-- Cache for active player inventories (steamid -> data)
	Arcane.Inventory.Cache = Arcane.Inventory.Cache or {}

	function Arcane.Inventory:Get(ply)
		if not IsValid(ply) then return {coins = 0, items = {}} end
		local sid = ply:SteamID64()
		if not Arcane.Inventory.Cache[sid] then
			Arcane.Inventory.Cache[sid] = getInventoryData(sid)
		end
		return Arcane.Inventory.Cache[sid]
	end

	function Arcane.Inventory:Save(ply)
		if not IsValid(ply) then return end
		local sid = ply:SteamID64()
		local data = Arcane.Inventory.Cache[sid]
		if data then
			saveInventoryData(sid, data)
		end
	end

	function Arcane.Inventory:SyncToClient(ply)
		if not IsValid(ply) then return end
		local data = self:Get(ply)
		net.Start("Arcane_InventorySync")
		net.WriteUInt(data.coins, 32)
		local itemsJson = util.TableToJSON(data.items) or "{}"
		net.WriteString(itemsJson)
		net.Send(ply)
	end

	-- Override default functions with actual implementation
	function Arcane:GiveCoins(ply, amount, reason)
		if not IsValid(ply) or amount <= 0 then return false end
		local inv = Arcane.Inventory:Get(ply)
		inv.coins = inv.coins + amount
		Arcane.Inventory:SyncToClient(ply)
		Arcane.RunHook("CoinsGiven", ply, amount, reason)
		return true
	end

	function Arcane:TakeCoins(ply, amount, reason)
		if not IsValid(ply) or amount <= 0 then return false end
		local inv = Arcane.Inventory:Get(ply)
		if inv.coins < amount then return false end
		inv.coins = inv.coins - amount
		Arcane.Inventory:SyncToClient(ply)
		Arcane.RunHook("CoinsTaken", ply, amount, reason)
		return true
	end

	function Arcane:GiveItem(ply, itemClass, amount, reason)
		if not IsValid(ply) or amount <= 0 then return false end
		local inv = Arcane.Inventory:Get(ply)
		inv.items[itemClass] = (inv.items[itemClass] or 0) + amount
		Arcane.Inventory:SyncToClient(ply)
		Arcane.RunHook("ItemGiven", ply, itemClass, amount, reason)
		return true
	end

	function Arcane:TakeItem(ply, itemClass, amount, reason)
		if not IsValid(ply) or amount <= 0 then return false end
		local inv = Arcane.Inventory:Get(ply)
		if (inv.items[itemClass] or 0) < amount then return false end
		inv.items[itemClass] = inv.items[itemClass] - amount
		if inv.items[itemClass] <= 0 then
			inv.items[itemClass] = nil
		end
		Arcane.Inventory:SyncToClient(ply)
		Arcane.RunHook("ItemTaken", ply, itemClass, amount, reason)
		return true
	end

	-- Player lifecycle hooks
	-- Sync inventory when player data is fully loaded (client is ready for net messages)
	hook.Add("LoadedPlayerData", "Arcane_InventorySyncOnLoad", function(ply)
		Arcane.Inventory:SyncToClient(ply)
	end)

	hook.Add("PlayerDisconnected", "Arcane_InventorySave", function(ply)
		Arcane.Inventory:Save(ply)
		Arcane.Inventory.Cache[ply:SteamID64()] = nil
	end)

	timer.Create("Arcane_InventoryAutosave", 120, 0, function()
		for _, ply in ipairs(player.GetAll()) do
			Arcane.Inventory:Save(ply)
		end
	end)

	-- Network strings
	util.AddNetworkString("Arcane_InventorySync")
end

-- Client-side: cache and UI
if CLIENT then
	Arcane.Inventory = Arcane.Inventory or {}
	Arcane.Inventory.LocalCache = Arcane.Inventory.LocalCache or {coins = 0, items = {}}

	net.Receive("Arcane_InventorySync", function()
		local coins = net.ReadUInt(32)
		local itemsJson = net.ReadString()
		local ok, items = pcall(util.JSONToTable, itemsJson)
		Arcane.Inventory.LocalCache = {
			coins = coins,
			items = (ok and istable(items)) and items or {}
		}
	end)

	-- ============================================================================
	-- ART DECO INVENTORY UI
	-- ============================================================================
	Arcane.Inventory.Panel = nil

	local function createInventoryPanel()
		if IsValid(Arcane.Inventory.Panel) then
			Arcane.Inventory.Panel:Remove()
		end

		local panel = vgui.Create("DPanel")
		local itemsPerRow = 6
		local visibleRows = 3
		local itemCardW = 110
		local itemCardH = 115
		local itemSpacing = 5
		local panelMargin = 10
		local headerHeight = 30
		local headerGap = 5
		
		-- Panel width: left margin + items + spacing between + right margin
		local panelW = (panelMargin * 2) + (itemCardW * itemsPerRow) + ((itemsPerRow - 1) * itemSpacing) + (itemSpacing * 2)
		-- Panel height: top margin + header + gap + items panel frame + items + bottom margin
		local itemsContentH = (itemCardH * visibleRows) + ((visibleRows - 1) * itemSpacing)
		local panelH = panelMargin + headerHeight + headerGap + (itemSpacing * 2) + itemsContentH + panelMargin
		
		panel:SetSize(panelW, panelH)
		panel:SetPos(ScrW() / 2 - panelW / 2, ScrH() - panelH - 20)
		panel:SetVisible(false)
		panel:SetMouseInputEnabled(true)
		panel:SetKeyboardInputEnabled(false)
		panel:MakePopup()
		panel:SetDrawOnTop(true)

		-- Screen-space blur behind panel (like grimoire and other UIs)
		hook.Add("HUDPaint", panel, function()
			if not IsValid(panel) or not panel:IsVisible() then return end
			local x, y = panel:LocalToScreen(0, 0)
			ArtDeco.DrawBlurRect(x, y, panel:GetWide(), panel:GetTall(), 4, 8)
		end)

		-- Panel background
		panel.Paint = function(pnl, w, h)
			ArtDeco.FillDecoPanel(0, 0, w, h, ArtDeco.Colors.decoBg, 12)
			ArtDeco.DrawDecoFrame(0, 0, w, h, ArtDeco.Colors.gold, 12)
		end

		-- Header with coins (horizontal layout)
		local header = vgui.Create("DPanel", panel)
		header:SetSize(panelW - (panelMargin * 2), headerHeight)
		header:SetPos(panelMargin, panelMargin)
		local coinIcon = Material("icon16/coins.png")
		header.Paint = function(pnl, w, h)
			-- Title styled like grimoire (uppercase)
			local titleText = string.upper("Inventory")
			surface.SetFont("Arcana_DecoTitle")
			local titleW = surface.GetTextSize(titleText)
			draw.SimpleText(titleText, "Arcana_DecoTitle", 0, 0, ArtDeco.Colors.paleGold, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
			
			-- Coins badge on the right (like level badge in grimoire)
			local coins = Arcane.Inventory.LocalCache.coins or 0
			local chipText = string.Comma(coins)
			surface.SetFont("Arcana_Ancient")
			local cw, ch = surface.GetTextSize(chipText)
			
			-- Badge dimensions
			local chipW = cw + 36 -- Extra space for icon
			local chipH = ch + 6
			local chipX = w - chipW
			local chipY = 0
			
			-- Draw badge background
			ArtDeco.FillDecoPanel(chipX, chipY, chipW, chipH, ArtDeco.Colors.paleGold, 6)
			
			-- Draw coin icon (matching badge text color)
			surface.SetDrawColor(ArtDeco.Colors.chipTextCol)
			surface.SetMaterial(coinIcon)
			surface.DrawTexturedRect(chipX + 6, chipY + (chipH - 16) / 2, 16, 16)
			
			-- Draw coin count
			draw.SimpleText(chipText, "Arcana_Ancient", chipX + 26, chipY + (chipH - ch) * 0.5, ArtDeco.Colors.chipTextCol, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
		end

		-- Items section (grid with vertical scrolling)
		local itemsPanel = vgui.Create("DPanel", panel)
		local itemsPanelY = panelMargin + headerHeight + headerGap
		local itemsPanelH = panelH - itemsPanelY - panelMargin
		itemsPanel:SetSize(panelW - (panelMargin * 2), itemsPanelH)
		itemsPanel:SetPos(panelMargin, itemsPanelY)
		
		-- Screen-space blur for items panel
		hook.Add("HUDPaint", itemsPanel, function()
			if not IsValid(itemsPanel) or not IsValid(panel) or not panel:IsVisible() then return end
			local x, y = itemsPanel:LocalToScreen(0, 0)
			ArtDeco.DrawBlurRect(x, y, itemsPanel:GetWide(), itemsPanel:GetTall(), 3, 6)
		end)
		
		itemsPanel.Paint = function(pnl, w, h)
			ArtDeco.FillDecoPanel(0, 0, w, h, ArtDeco.Colors.cardIdle, 8)
			ArtDeco.DrawDecoFrame(0, 0, w, h, ArtDeco.Colors.paleGold, 8)
		end

		-- Vertical scroll panel for grid
		local scroll = vgui.Create("DScrollPanel", itemsPanel)
		scroll:Dock(FILL)
		scroll:DockMargin(itemSpacing, itemSpacing, itemSpacing, itemSpacing)

		-- Style the scrollbar
		local vbar = scroll:GetVBar()
		vbar:SetWide(8)
		vbar.Paint = function() end
		vbar.btnUp.Paint = function() end
		vbar.btnDown.Paint = function() end
		vbar.btnGrip.Paint = function(pnl, w, h)
			surface.SetDrawColor(ArtDeco.Colors.gold)
			surface.DrawRect(0, 0, w, h)
		end

		-- Greek glyphs for empty slot backgrounds (same as spell wheel)
		local greekGlyphs = {"Α", "Β", "Γ", "Δ", "Ε", "Ζ", "Η", "Θ", "Ι", "Κ", "Λ", "Μ", "Ν", "Ξ", "Ο", "Π", "Ρ", "Σ", "Τ", "Υ", "Φ", "Χ", "Ψ", "Ω"}

		local function refreshItems()
			scroll:Clear()
			local items = Arcane.Inventory.LocalCache.items or {}
			
			-- Create grid container
			local gridContainer = vgui.Create("DPanel", scroll)
			gridContainer:Dock(TOP)
			gridContainer.Paint = function() end
			
			-- Collect all items into a table for grid layout
			local itemList = {}
			for itemClass, count in pairs(items) do
				table.insert(itemList, {class = itemClass, count = count})
			end
			
			-- Calculate grid dimensions (minimum of visible rows, expand if more items)
			local numRows = math.max(visibleRows, math.ceil(#itemList / itemsPerRow))
			local totalSlots = numRows * itemsPerRow
			-- Height: all cards + spacing between them (n-1 spacings)
			gridContainer:SetTall(numRows * itemCardH + (numRows - 1) * itemSpacing)
			
			-- Hide scrollbar if we have 3 rows or less
			local vbar = scroll:GetVBar()
			if numRows <= visibleRows then
				vbar:SetWide(0)
				vbar:SetEnabled(false)
			else
				vbar:SetWide(8)
				vbar:SetEnabled(true)
			end
			
			-- Create all grid slots
			for i = 1, totalSlots do
				-- Calculate grid position (0-indexed for math)
				local col = (i - 1) % itemsPerRow
				local row = math.floor((i - 1) / itemsPerRow)
				local x = col * (itemCardW + itemSpacing)
				local y = row * (itemCardH + itemSpacing)
				
				-- Check if this slot has an item
				local itemData = itemList[i]
				local itemClass = itemData and itemData.class
				local count = itemData and itemData.count
				local itemDef = itemClass and (Arcane.Inventory.Items[itemClass] or {
					name = itemClass,
					description = "",
					model = "models/props_junk/cardboard_box004a.mdl"
				})

				local itemCard = vgui.Create("DPanel", gridContainer)
				itemCard:SetSize(itemCardW, itemCardH)
				itemCard:SetPos(x, y)
				itemCard.Paint = function(pnl, w, h)
					if not itemData then
						-- Empty slot with Greek glyph
						ArtDeco.FillDecoPanel(0, 0, w, h, ColorAlpha(ArtDeco.Colors.decoPanel, 100), 6)
						ArtDeco.DrawDecoFrame(0, 0, w, h, ColorAlpha(ArtDeco.Colors.brassInner, 80), 6)
						
						-- Draw Greek glyph in center with subtle gold color
						local glyph = greekGlyphs[((i - 1) % #greekGlyphs) + 1]
						draw.SimpleText(glyph, "Arcana_AncientGlyph", w / 2, h / 2, ColorAlpha(ArtDeco.Colors.brassInner, 60), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
					else
						local isHovered = pnl:IsHovered()
						ArtDeco.FillDecoPanel(0, 0, w, h, isHovered and ArtDeco.Colors.cardHover or ArtDeco.Colors.decoPanel, 6)
						ArtDeco.DrawDecoFrame(0, 0, w, h, ArtDeco.Colors.brassInner, 6)
					end
				end
				
				-- Only add content if slot has an item
				if not itemData then continue end

				-- 3D Model preview
				if itemDef.model then
					local modelPanel = vgui.Create("DModelPanel", itemCard)
					modelPanel:SetSize(100, 70)
					modelPanel:SetPos(5, 5)
					modelPanel:SetModel(itemDef.model)
					modelPanel:SetFOV(50)
					modelPanel:SetCamPos(Vector(25, 25, 25))
					modelPanel:SetLookAt(Vector(0, 0, 0))
					
					local ent = modelPanel:GetEntity()
					if IsValid(ent) then
						if itemDef.material then
							ent:SetMaterial(itemDef.material)
						end
						if itemDef.color then
							ent:SetColor(itemDef.color)
						end
					end

					-- Use entity's actual draw functions if entityClass is specified
					if itemDef.entityClass then
						local entTable = scripted_ents.Get(itemDef.entityClass)
						if entTable and entTable.Draw and entTable.DrawGlow then
							function modelPanel:Paint(w, h)
								if not IsValid(self.Entity) then return end
								
								local x, y = self:LocalToScreen(0, 0)
								local ang = (self.vLookatPos - self.vCamPos):Angle()
								
								cam.Start3D(self.vCamPos, ang, self.fFOV, x, y, w, h, 5, 4096)
								
								-- Call entity's Draw function
								entTable.Draw(self.Entity)
								
								-- Call entity's DrawGlow function
								entTable.DrawGlow(self.Entity)
								
								cam.End3D()
							end
						end
					end
					
					modelPanel.LayoutEntity = function(pnl, entity)
						if entity.SetAngles then
							entity:SetAngles(Angle(0, RealTime() * 40, 0))
						end
					end
				end

				-- Name
				local label = vgui.Create("DLabel", itemCard)
				label:SetPos(5, 78)
				label:SetSize(100, 16)
				label:SetFont("Arcana_AncientSmall")
				label:SetTextColor(ArtDeco.Colors.textBright)
				label:SetText(itemDef.name)
				label:SetContentAlignment(5)

				-- Count
				local countLabel = vgui.Create("DLabel", itemCard)
				countLabel:SetPos(5, 94)
				countLabel:SetSize(100, 16)
				countLabel:SetFont("Arcana_AncientSmall")
				countLabel:SetTextColor(ArtDeco.Colors.textDim)
				countLabel:SetText("x" .. count)
				countLabel:SetContentAlignment(5)

				-- Tooltip
				itemCard:SetCursor("hand")
				itemCard.OnCursorEntered = function()
					if IsValid(itemCard.tooltip) then return end

					local tooltip = vgui.Create("DLabel")
					tooltip:SetSize(250, 50)
					tooltip:SetWrap(true)
					tooltip:SetText(itemDef.description)
					tooltip:SetFont("Arcana_AncientSmall")
					tooltip:SetTextColor(ArtDeco.Colors.textBright)
					tooltip:SetDrawOnTop(true)
					tooltip:SetMouseInputEnabled(false)
					tooltip:NoClipping(true)

					tooltip.Paint = function(pnl, w, h)
						ArtDeco.FillDecoPanel(0, 0, w, h, ArtDeco.Colors.decoBg, 8)
						ArtDeco.DrawDecoFrame(0, 0, w, h, ArtDeco.Colors.gold, 8)
					end

					itemCard.tooltip = tooltip

					local function updatePos()
						if not IsValid(tooltip) then return end
						local x, y = gui.MousePos()
						tooltip:SetPos(x + 15, y - 60)
					end

					updatePos()
					hook.Add("Think", "Arcane_ItemTooltip_" .. tostring(tooltip), function()
						if not IsValid(tooltip) or not IsValid(itemCard) then
							hook.Remove("Think", "Arcane_ItemTooltip_" .. tostring(tooltip))
							if IsValid(tooltip) then tooltip:Remove() end
							return
						end
						updatePos()
					end)
				end

				itemCard.OnCursorExited = function()
					if IsValid(itemCard.tooltip) then
						hook.Remove("Think", "Arcane_ItemTooltip_" .. tostring(itemCard.tooltip))
						itemCard.tooltip:Remove()
						itemCard.tooltip = nil
					end
				end
			end
		end

		-- Store reference and refresh function
		Arcane.Inventory.Panel = panel
		Arcane.Inventory.RefreshItems = refreshItems

		-- Initial refresh
		refreshItems()

		return panel
	end

	-- Show inventory when context menu opens
	hook.Add("OnContextMenuOpen", "Arcane_InventoryShow", function()
		local panel = IsValid(Arcane.Inventory.Panel) and Arcane.Inventory.Panel or createInventoryPanel()
		if IsValid(panel) then
			panel:SetVisible(true)
			panel:MoveToFront()
			if Arcane.Inventory.RefreshItems then
				Arcane.Inventory.RefreshItems()
			end
		end
	end)

	hook.Add("OnContextMenuClose", "Arcane_InventoryHide", function()
		if IsValid(Arcane.Inventory.Panel) then
			Arcane.Inventory.Panel:SetVisible(false)
		end
	end)
end

-- Shared getters (these provide the default implementation)
-- Third parties: override these functions to use your own system
function Arcane:GetCoins(ply)
	if SERVER then
		local inv = Arcane.Inventory:Get(ply)
		return inv.coins
	else
		return Arcane.Inventory.LocalCache.coins
	end
end

function Arcane:GetItemCount(ply, itemClass)
	if SERVER then
		local inv = Arcane.Inventory:Get(ply)
		return inv.items[itemClass] or 0
	else
		return (Arcane.Inventory.LocalCache.items or {})[itemClass] or 0
	end
end

-- OVERRIDE DATA PERSISTENCE
-- To use custom storage (e.g., MySQL, MongoDB, etc.), override these hooks

--[[
	Example: Override saving player data

	hook.Add("SavePlayerDataToSQL", "YourAddonName", function(ply, data)
		-- Your custom save logic here
		-- data contains: xp, level, knowledge_points, unlocked_spells, quickspell_slots, selected_quickslot, last_save

		-- Return true to prevent Arcana's default SQL save
		return true
	end)
]]

--[[
	Example: Override loading player data

	hook.Add("LoadPlayerDataFromSQL", "YourAddonName", function(ply, callback)
		-- Your custom load logic here
		-- When done, call: callback(success, data)
		-- where data should contain: xp, level, knowledge_points, unlocked_spells, quickspell_slots, selected_quickslot, last_save

		-- Example:
		-- YourDatabase:LoadPlayerData(ply:SteamID64(), function(loadedData)
		-- 	callback(true, loadedData)
		-- end)

		-- Return true to prevent Arcana's default SQL load
		return true
	end)
]]

--[[
	Example: Override reading Astral Vault data

	hook.Add("ReadAstralVault", "YourAddonName", function(ply, callback)
		-- Your custom vault read logic here
		-- When done, call: callback(success, items)
		-- where items is an array of vault items (each item contains weapon info and enchantments)

		-- Example:
		-- YourDatabase:LoadVaultData(ply:SteamID64(), function(vaultItems)
		-- 	Arcane.AstralVaultCache[ply:SteamID64()] = vaultItems
		-- 	callback(true, vaultItems)
		-- end)

		-- Return true to prevent Arcana's default SQL read
		return true
	end)
]]

--[[
	Example: Override writing Astral Vault data

	hook.Add("WriteAstralVault", "YourAddonName", function(ply, items)
		-- Your custom vault write logic here
		-- items is an array of vault items to save

		-- Example:
		-- YourDatabase:SaveVaultData(ply:SteamID64(), items)

		-- Return true to prevent Arcana's default SQL write
		return true
	end)
]]