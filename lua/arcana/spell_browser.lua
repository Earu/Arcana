if not CLIENT then return end

local Arcane = _G.Arcane or {}

-- Opens a developer spell browser listing all registered spells and their metadata
local function OpenSpellBrowser()
	if not Arcane or not Arcane.RegisteredSpells then return end

	if IsValid(Arcane._SpellBrowser) then
		Arcane._SpellBrowser:MakePopup()
		Arcane._SpellBrowser:Center()
		return
	end

	local frame = vgui.Create("DFrame")
	frame:SetSize(1200, 500)
	frame:Center()
	frame:MakePopup()
	frame:SetTitle("")
	frame:ShowCloseButton(false)
	frame:DockPadding(0, 0, 0, 0)
	frame:DockMargin(0, 0, 0, 0)
	Arcane._SpellBrowser = frame

	-- Frame styling
	local bgCol = Color(22, 18, 14, 245)
	local borderCol = Color(198, 160, 74)
	local borderAccent = Color(236, 230, 220, 80)
	frame.Paint = function(pnl, w, h)
		surface.SetDrawColor(bgCol)
		surface.DrawRect(0, 0, w, h)

		-- outer border
		surface.SetDrawColor(borderCol)
		surface.DrawOutlinedRect(0, 0, w, h, 1)

		-- subtle accent border inset
		surface.SetDrawColor(borderAccent)
		surface.DrawOutlinedRect(1, 1, w - 2, h - 2, 1)
	end

	-- Palette
	local gold = Color(198, 160, 74)
	local paleGold = Color(222, 198, 120)
	local textBright = Color(236, 230, 220)
	local headerDark = Color(32, 24, 18, 245)
	local rowDark1 = Color(30, 24, 20, 180)
	local rowDark2 = Color(36, 30, 26, 180)
	local rowHover = Color(56, 48, 38, 220)

	-- Header
	local header = vgui.Create("DPanel", frame)
	header:Dock(TOP)
	header:SetTall(44)
	function header:Paint(w, h)
		surface.SetDrawColor(headerDark)
		surface.DrawRect(0, 0, w, h)
		surface.SetDrawColor(gold)
		surface.DrawLine(0, h - 1, w, h - 1)
		draw.SimpleText("Spell Browser", "Arcana_DecoTitle", 12, 10, paleGold)
	end

	-- Inline close button inside the header
	local headerClose = vgui.Create("DButton", header)
	headerClose:Dock(RIGHT)
	headerClose:DockMargin(0, 8, 8, 8)
	headerClose:SetWide(36)
	headerClose:SetText("✕")
	headerClose:SetFont("Arcana_Ancient")
	headerClose:SetTextColor(gold)
	headerClose.Paint = function(pnl, w, h)
		if pnl:IsHovered() then
			surface.SetDrawColor(Color(56, 48, 38, 220))
			surface.DrawRect(0, 0, w, h)
		end
	end
	headerClose.DoClick = function() frame:Remove() end

	-- Toolbar (filters)
	local toolbar = vgui.Create("DPanel", frame)
	toolbar:Dock(TOP)
	toolbar:SetTall(32)
	toolbar:DockPadding(8, 4, 8, 4)
	function toolbar:Paint(w, h)
		surface.SetDrawColor(24, 20, 16, 245)
		surface.DrawRect(0, 0, w, h)
		surface.SetDrawColor(80, 64, 40, 180)
		surface.DrawLine(0, h - 1, w, h - 1)
	end

	local search = vgui.Create("DTextEntry", toolbar)
	search:Dock(LEFT)
	search:DockMargin(0, 4, 6, 4)
	search:SetWide(220)
	search:SetPlaceholderText("Search id or name...")

	local categoryBox = vgui.Create("DComboBox", toolbar)
	categoryBox:Dock(LEFT)
	categoryBox:DockMargin(0, 4, 6, 4)
	categoryBox:SetWide(150)
	categoryBox:SetSortItems(false)
	categoryBox:AddChoice("All Categories", "__all__", true)

	-- Build categories from Arcane.CATEGORIES and any found on spells
	local seenCats = {}
	if Arcane.CATEGORIES then
		for _, c in pairs(Arcane.CATEGORIES) do
			if not seenCats[c] then
				categoryBox:AddChoice(string.upper(string.Left(c, 1)) .. string.sub(c, 2), c)
				seenCats[c] = true
			end
		end
	end

	for _, sp in pairs(Arcane.RegisteredSpells or {}) do
		local c = sp.category
		if c and not seenCats[c] then
			categoryBox:AddChoice(string.upper(string.Left(c, 1)) .. string.sub(c, 2), c)
			seenCats[c] = true
		end
	end

	local minLevel = vgui.Create("DNumberWang", toolbar)
	minLevel:Dock(LEFT)
	minLevel:DockMargin(0, 4, 6, 4)
	minLevel:SetWide(80)
	minLevel:SetMinMax(0, 1000)
	minLevel:SetDecimals(0)
	minLevel:SetValue(0)
	minLevel:SetTooltip("Minimum required level")

	local clearBtn = vgui.Create("DButton", toolbar)
	clearBtn:Dock(LEFT)
	clearBtn:DockMargin(0, 4, 6, 4)
	clearBtn:SetText("Clear")
	clearBtn:SetWide(64)

	local statusLbl = vgui.Create("DLabel", toolbar)
	statusLbl:Dock(RIGHT)
	statusLbl:DockMargin(6, 0, 0, 0)
	statusLbl:SetFont("Arcana_AncientSmall")
	statusLbl:SetTextColor(paleGold)
	statusLbl:SetText("")
	statusLbl:SetContentAlignment(6)
	statusLbl:SetWide(260)
	statusLbl:SetMouseInputEnabled(false)
	statusLbl:SetKeyboardInputEnabled(false)

	local function setStatusText(txt)
		statusLbl:SetText(txt)
	end

	-- List
	local list = vgui.Create("DListView", frame)
	list:Dock(FILL)
	list:SetMultiSelect(false)
	list.Paint = function(pnl, w, h)
		surface.SetDrawColor(28, 22, 18, 245)
		surface.DrawRect(0, 0, w, h)
	end

	-- Scrollbar theme
	local vbar = list.VBar
	if IsValid(vbar) then
		vbar.Paint = function(_, w, h)
			surface.SetDrawColor(26, 20, 16, 255)
			surface.DrawRect(0, 0, w, h)
		end
		vbar.btnUp.Paint = function(_, w, h)
			surface.SetDrawColor(40, 32, 26, 255)
			surface.DrawRect(0, 0, w, h)
			surface.SetDrawColor(borderCol)
			surface.DrawOutlinedRect(0, 0, w, h)
		end
		vbar.btnDown.Paint = vbar.btnUp.Paint
		vbar.btnGrip.Paint = function(_, w, h)
			surface.SetDrawColor(64, 52, 40, 255)
			surface.DrawRect(0, 0, w, h)
			surface.SetDrawColor(borderCol)
			surface.DrawOutlinedRect(0, 0, w, h)
		end
	end

	-- Define columns, then compute equal widths dynamically
	local columnDefs = {
		"ID",
		"Name",
		"Category",
		"Level",
		"KP",
		"Cooldown",
		"CastTime",
		"CostType",
		"Cost",
		"Range",
		"IsProjectile",
		"HasTarget",
	}

	local colCount = #columnDefs
	local scrollbarReserve = 0
	local listSidePadding = 0
	local frameSidesReserve = 0

	-- target per-column width; will clamp to screen
	local targetCol = 110
	local desiredFrameW = math.min(ScrW() - 40, (targetCol * colCount) + scrollbarReserve + listSidePadding + frameSidesReserve)
	frame:SetWide(desiredFrameW)
	frame:Center()

	-- Now that frame width is set, compute actual equal column width
	local availableListW = frame:GetWide() - scrollbarReserve - listSidePadding - frameSidesReserve
	local equalColW = math.floor(math.max(90, availableListW / colCount))
	for i = 1, colCount do
		local col = list:AddColumn(columnDefs[i])
		col:SetFixedWidth(equalColW)
	end

	-- Column header theming (avoid GetHeader, style each header button)
	for _, c in ipairs(list.Columns or {}) do
		if IsValid(c.Header) then
			local btn = c.Header
			btn:SetTall(24)
			btn:SetFont("Arcana_AncientSmall")
			btn:SetTextColor(paleGold)
			btn.Paint = function(pnl, w, h)
				surface.SetDrawColor(34, 26, 20, 255)
				surface.DrawRect(0, 0, w, h)
				surface.SetDrawColor(borderCol)
				surface.DrawLine(0, h - 1, w, h - 1)
				surface.DrawOutlinedRect(0, 0, w, h)
			end
		end
	end

	-- Adjust (re-center) after column sizing
	frame:Center()

	local function toStr(v)
		if v == nil then return "no" end
		if isbool(v) then return v and "yes" or "no" end
		return tostring(v)
	end

	local function numberOr(defaultValue, value)
		local n = tonumber(value)
		return n ~= nil and n or defaultValue
	end

	local function passesFilters(sid, sp, name, cat)
		local q = string.lower(string.Trim(search:GetText() or ""))
		if q ~= "" then
			local idL = string.lower(sid)
			local nameL = string.lower(name)
			if not string.find(idL, q, 1, true) and not string.find(nameL, q, 1, true) then
				return false
			end
		end

		local _, selectedCat = categoryBox:GetSelected()
		if selectedCat and selectedCat ~= "__all__" then
			if (sp.category or "") ~= selectedCat then return false end
		end

		local minLvl = tonumber(minLevel:GetValue() or 0) or 0
		if tonumber(sp.level_required or 0) < minLvl then return false end

		return true
	end

	local categoryStripe = {
		["combat"] = Color(180, 70, 70),
		["protection"] = Color(90, 150, 210),
		["utility"] = Color(120, 160, 120),
		["summoning"] = Color(150, 110, 190),
		["divination"] = Color(200, 180, 100),
		["enchantment"] = Color(210, 130, 70),
	}

	local function populate()
		list:Clear()
		local total = 0
		local shown = 0
		local totalKP = 0
		for sid, sp in pairs(Arcane.RegisteredSpells or {}) do
			total = total + 1
			local name = sp.name or sid
			local cat = sp.category or ""
			local lvl = numberOr(1, sp.level_required)
			local kp = numberOr(1, sp.knowledge_cost)
			local cd = numberOr(Arcane.Config and Arcane.Config.DEFAULT_SPELL_COOLDOWN or 0, sp.cooldown)
			local ct = numberOr(0, sp.cast_time)
			local ctype = sp.cost_type or ""
			local camount = numberOr(0, sp.cost_amount)
			local range = numberOr(0, sp.range)
			local isProj = toStr(sp.is_projectile)
			local hasTarget = toStr(sp.has_target)

			if not passesFilters(sid, sp, name, cat) then
				continue
			end

			local line = list:AddLine(sid, name, cat, lvl, kp, cd, ct, ctype, camount, range, isProj, hasTarget)
			if line and lvl > 1 then
				line:SetSortValue(4, lvl)
			end

			if line then
				shown = shown + 1
				totalKP = totalKP + kp
				local idx = #list:GetLines()
				local alt = (idx % 2 == 0)
				local stripe = categoryStripe[string.lower(cat or "")] or Color(100, 100, 100)
				line.Paint = function(pnl, w, h)
					if pnl:IsHovered() or pnl:IsSelected() then
						surface.SetDrawColor(rowHover)
						surface.DrawRect(0, 0, w, h)
					else
						surface.SetDrawColor(alt and rowDark2 or rowDark1)
						surface.DrawRect(0, 0, w, h)
					end
					surface.SetDrawColor(stripe)
					surface.DrawRect(0, 0, 4, h)
				end

				-- align numeric columns to center for readability
				local centers = {4, 5, 6, 7, 9, 10, 11, 12}
				for _, colIdx in ipairs(centers) do
					if line.Columns and line.Columns[colIdx] then
						line.Columns[colIdx]:SetContentAlignment(5)
					end
				end
				-- add extra left padding to ID column so stripe has breathing room
				if line.Columns and line.Columns[1] and line.Columns[1].SetTextInset then
					line.Columns[1]:SetTextInset(18, 0)
				end

				-- force row text to white for readability
				if line.Columns then
					for _, lbl in ipairs(line.Columns) do
						if IsValid(lbl) and lbl.SetTextColor then
							lbl:SetTextColor(Color(255, 255, 255))
						end
					end
				end
			end
		end
		setStatusText(string.format("%d shown / %d total   |   Σ KP %d", shown, total, totalKP))
		list:SortByColumn(4, false)
	end

	local function triggerPopulate()
		-- slight debounce
		timer.Create("ArcanaDevSpellPopulate", 0.05, 1, populate)
	end

	clearBtn.DoClick = function()
		search:SetText("")
		categoryBox:ChooseOptionID(1)
		minLevel:SetValue(0)
		triggerPopulate()
	end

	search.OnChange = triggerPopulate
	categoryBox.OnSelect = triggerPopulate
	minLevel.OnValueChanged = triggerPopulate

	populate()
end

-- Console command to open the browser
concommand.Add("arcana_spell_browser", OpenSpellBrowser, nil, "Open the Arcana spell browser")
