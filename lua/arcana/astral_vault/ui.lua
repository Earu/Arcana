-- Astral Vault UI — client-side panel, slot cards, galaxy background renderer.
-- Server-side persistence, SQL schema, and net.Receive handlers live in astral_vault.lua.
if not CLIENT then return end

local Arcana = Arcana

-- Cost constants come from astral_vault_config.lua (loaded before this file via init.lua).
local VAULT_CFG = Arcana.VaultConfig

local HL2_MODELS = {
	weapon_357 = "models/weapons/w_357.mdl",
	weapon_ar2 = "models/weapons/w_irifle.mdl",
	weapon_bugbait = "models/weapons/w_bugbait.mdl",
	weapon_crossbow = "models/weapons/w_crossbow.mdl",
	weapon_crowbar = "models/weapons/w_crowbar.mdl",
	weapon_frag = "models/weapons/w_grenade.mdl",
	weapon_physcannon = "models/weapons/w_physics.mdl",
	weapon_pistol = "models/weapons/w_pistol.mdl",
	weapon_rpg = "models/weapons/w_rocket_launcher.mdl",
	weapon_shotgun = "models/weapons/w_shotgun.mdl",
	weapon_slam = "models/weapons/w_slam.mdl",
	weapon_smg = "models/weapons/w_smg1.mdl",
	weapon_stunstick = "models/weapons/w_stunbaton.mdl",
}

-- Command to open the vault
concommand.Add("arcana_vault", function()
	net.Start("Arcana_AstralVault_RequestOpen")
	net.SendToServer()
end, nil, "Open the Arcana Astral Vault")

list.Set("DesktopWindows", "ArcanaAstralVault", {
	title = "Astral Vault",
	icon = "arcana/astral_vault.png",
	init = function(icon, window)
		RunConsoleCommand("arcana_vault")
	end
})

-- Custom colors for astral vault (darker theme)
local decoBg = Color(12, 12, 20, 235)
local decoPanel = Color(18, 18, 28, 235)

local function drawGalaxyBackground(pnl, w, h, starSeed)
	-- Galaxy clipped to an art-deco octagon using the stencil buffer
	local x, y = 6, 6
	local ww, hh = w - 12, h - 12
	local c = 14
	local pts = {
		{x = x + c, y = y},
		{x = x + ww - c, y = y},
		{x = x + ww, y = y + c},
		{x = x + ww, y = y + hh - c},
		{x = x + ww - c, y = y + hh},
		{x = x + c, y = y + hh},
		{x = x, y = y + hh - c},
		{x = x, y = y + c},
	}

	render.ClearStencil()
	render.SetStencilEnable(true)
	render.SetStencilWriteMask(0xFF)
	render.SetStencilTestMask(0xFF)
	render.SetStencilReferenceValue(1)
	render.SetStencilCompareFunction(STENCIL_NEVER)
	render.SetStencilFailOperation(STENCIL_REPLACE)
	render.SetStencilPassOperation(STENCIL_KEEP)
	render.SetStencilZFailOperation(STENCIL_KEEP)

	draw.NoTexture()
	surface.SetDrawColor(255, 255, 255, 255)
	surface.DrawPoly(pts)

	render.SetStencilCompareFunction(STENCIL_EQUAL)
	render.SetStencilFailOperation(STENCIL_KEEP)
	render.SetStencilPassOperation(STENCIL_REPLACE)

	-- Background base
	surface.SetDrawColor(8, 10, 22, 240)
	surface.DrawRect(x, y, ww, hh)

	-- Nebulas
	local function nebula(cx, cy, r, cr, cg, cb, a)
		for k = r, 0, -6 do
			local alpha = (a or 90) * (k / r)
			surface.SetDrawColor(cr, cg, cb, alpha)
			surface.DrawCircle(x + cx, y + cy, k, cr, cg, cb, alpha)
		end
	end

	nebula(ww * 0.25, hh * 0.35, math.min(ww, hh) * 0.35, 58, 84, 150, 90)
	nebula(ww * 0.68, hh * 0.62, math.min(ww, hh) * 0.42, 40, 60, 120, 70)
	nebula(ww * 0.55, hh * 0.25, math.min(ww, hh) * 0.25, 80, 80, 140, 60)

	-- Stars (stable per-seed)
	surface.SetDrawColor(240, 220, 170, 255)
	math.randomseed(starSeed or 12345)
	for i = 1, 220 do
		local sx = x + math.random(6, ww - 6)
		local sy = y + math.random(6, hh - 6)
		surface.DrawRect(sx, sy, 1, 1)
		if i % 9 == 0 then surface.DrawRect(sx, sy, 2, 1) end
	end

	render.SetStencilEnable(false)
end

-- Global-ish state for live refresh
local VAULT = {frame = nil, items = {}, rebuild = nil}

local function getEnchantDisplayList(ids)
	local out = {}
	for _, id in ipairs(ids or {}) do
		local e = Arcana and Arcana.RegisteredEnchantments and Arcana.RegisteredEnchantments[id]
		out[#out + 1] = (e and e.name) or tostring(id)
	end
	table.sort(out)
	return out
end

local COLOR_CHIP_BG = Color(20, 20, 28, 180)
local COLOR_CHIP_FRAME = Color(160, 140, 110, 220)
local function drawChip(x, y, txt, font, bgCol, frameCol)
	surface.SetFont(font or "Arcana_AncientSmall")
	local tw, th = surface.GetTextSize(txt)
	local padX, padY = 6, 2
	local w, h = tw + padX * 2, th + padY * 2
	ArtDeco.FillDecoPanel(x, y, w, h, bgCol or COLOR_CHIP_BG, 6)
	ArtDeco.DrawDecoFrame(x, y, w, h, frameCol or COLOR_CHIP_FRAME, 6)
	draw.SimpleText(txt, font or "Arcana_AncientSmall", x + padX, y + padY - 1, ArtDeco.Colors.textBright)
	return w, h
end

-- Fit a model into a DModelPanel based on its bounding box
local DIRECTION_DEFAULT = Vector(1, 1, 0.5)
local function FitModelPanel(mp)
	if not IsValid(mp) then return end

	local ent = mp:GetEntity()
	if not IsValid(ent) then return end

	local mn, mx = ent:GetRenderBounds()
	local size = mx - mn
	local maxDim = math.max(math.abs(size.x), math.max(math.abs(size.y), math.abs(size.z)))
	if maxDim < 1 then maxDim = 1 end

	local radius = maxDim * 0.5
	local center = (mn + mx) * 0.5
	local fov = 30
	local tanHalf = math.tan(math.rad(fov * 0.5))
	if tanHalf <= 0 then tanHalf = 0.5 end

	local dist = (radius / tanHalf) * 1.25
	local dir = DIRECTION_DEFAULT:GetNormalized()
	local camPos = center + dir * dist
	mp:SetFOV(fov)
	mp:SetCamPos(camPos)
	mp:SetLookAt(center)
end

local function openVault(items)
	-- If already open, just refresh contents
	if VAULT.frame and IsValid(VAULT.frame) then
		VAULT.items = items or {}
		if VAULT.rebuild then VAULT.rebuild() end
		return
	end

	local ply = LocalPlayer()
	if not IsValid(ply) then return end
	local frame = vgui.Create("DFrame")
	frame:SetSize(1280, 720)
	frame:Center()
	frame:SetTitle("")
	frame:MakePopup()
	VAULT.frame = frame
	VAULT.items = items or {}
	VAULT.seed = math.random(1, 10^9)

	hook.Add("HUDPaint", frame, function()
		local x, y = frame:LocalToScreen(0, 0)
		ArtDeco.DrawBlurRect(x + 6, y + 6, frame:GetWide() - 12, frame:GetTall() - 12, 4, 8)
	end)

	frame.Paint = function(pnl, w, h)
		drawGalaxyBackground(pnl, w, h, VAULT.seed)
		ArtDeco.DrawDecoFrame(6, 6, w - 12, h - 12, ArtDeco.Colors.gold, 14)
		draw.SimpleText(string.upper("Astral Vault"), "Arcana_AncientLarge", 18, 10, ArtDeco.Colors.paleGold)
	end

	-- Style close button like enchanter
	if IsValid(frame.btnClose) then
		local close = frame.btnClose
		close:SetText("")
		close:SetSize(26, 26)
		function frame:PerformLayout(w, h)
			if IsValid(close) then close:SetPos(w - 26 - 10, 8) end
		end
		close.Paint = function(pnl, w, h)
			surface.SetDrawColor(ArtDeco.Colors.gold)
			local pad = 8
			surface.DrawLine(pad, pad, w - pad, h - pad)
			surface.DrawLine(w - pad, pad, pad, h - pad)
		end
	end

	-- Hide minimize/maximize buttons
	if IsValid(frame.btnMinim) then frame.btnMinim:Hide() end
	if IsValid(frame.btnMaxim) then frame.btnMaxim:Hide() end

	-- Single row of slot cards (max 6)
	local container = vgui.Create("DPanel", frame)
	container:Dock(FILL)
	container:DockMargin(8, 8, 8, 0)
	container.Paint = function(pnl, w, h) end

	local cards = {}

	local COLOR_DECO_BG = Color(24, 24, 36, 120)
	local COLOR_EMPTY_TEXT = Color(200, 190, 170)
	local COLOR_COST_TEXT = Color(210, 200, 185)
	local COLOR_GOLD = Color(198, 160, 74, 255)
	local COLOR_SUBTEXT = Color(170, 160, 140)
	local COLOR_BUTTON_BG = Color(46, 36, 26, 235)
	local COLOR_BUTTON_BG_HOVER = Color(58, 44, 32, 235)
	local COLOR_BUTTON_FRAME_DISABLED = Color(140, 120, 90, 255)
	local COLOR_BUTTON_TEXT_DISABLED = Color(200, 190, 170, 255)
	local function buildModelPanel(card, it)
		local model = vgui.Create("DModelPanel", card)
		model:SetMouseInputEnabled(false)
		function model:LayoutEntity(ent)
			ent:SetAngles(Angle(0, CurTime() * 15 % 360, 0))
			FitModelPanel(self)
		end
		function model:PostDrawModel(ent)
			if Arcana and Arcana.RenderEnchantBandsForEntity then
				Arcana:RenderEnchantBandsForEntity(ent, self._EnchantCount or 3,
					(LocalPlayer().GetWeaponColor and LocalPlayer():GetWeaponColor():ToColor()) or COLOR_GOLD, "axis")
			end
		end
		if it then
			local cls = it.class or ""
			local swep = weapons.GetStored(cls) or list.Get("Weapon")[cls]
			model:SetModel((swep and (swep.WorldModel or swep.ViewModel)) or HL2_MODELS[cls] or "models/weapons/w_pistol.mdl")
			FitModelPanel(model)
			model._EnchantCount = math.max(1, #(it.enchant_ids or {}))
		else
			model:SetVisible(false)
		end
		return model
	end

	local function buildEnchantList(card, it)
		local enchList = vgui.Create("DPanel", card)
		enchList:SetPaintBackground(false)
		enchList.names = it and getEnchantDisplayList(it.enchant_ids) or {}
		enchList.Paint = function(pnl, w, h)
			if not it then return end
			local y = 0
			for _, name in ipairs(pnl.names or {}) do
				draw.SimpleText("- " .. name, "Arcana_AncientSmall", 0, y, COLOR_COST_TEXT)
				y = y + 16
				if y > h - 16 then break end
			end
		end
		if not it then enchList:SetVisible(false) end
		return enchList
	end

	local function buildSummonButton(card, it)
		local summon = vgui.Create("DButton", card)
		summon:SetText("")
		summon.Paint = function(pnl, w, h)
			local enabled = pnl:IsEnabled()
			local hovered = enabled and pnl:IsHovered()
			ArtDeco.FillDecoPanel(0, 0, w, h, hovered and COLOR_BUTTON_BG_HOVER or COLOR_BUTTON_BG, 8)
			ArtDeco.DrawDecoFrame(0, 0, w, h, enabled and ArtDeco.Colors.gold or COLOR_BUTTON_FRAME_DISABLED, 8)
			draw.SimpleText(it and "Summon" or "Imprint", "Arcana_Ancient", w * 0.5, h * 0.5,
				enabled and ArtDeco.Colors.textBright or COLOR_BUTTON_TEXT_DISABLED, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		end
		summon.Think = function(pnl)
			if not it then pnl:SetEnabled(false) return end
			local lp = LocalPlayer()
			pnl:SetEnabled(Arcana:GetCoins(lp) >= (tonumber(VAULT_CFG.SUMMON_COINS) or 0)
				and Arcana:GetItemCount(lp, "mana_crystal_shard") >= (tonumber(VAULT_CFG.SUMMON_SHARDS) or 0))
		end
		if it then
			summon.DoClick = function()
				net.Start("Arcana_AstralVault_Summon")
				net.WriteString(tostring(it.id))
				net.SendToServer()
				surface.PlaySound("buttons/button15.wav")
				local ctrlDown = input.IsKeyDown(KEY_LCONTROL) or input.IsKeyDown(KEY_RCONTROL)
				if not ctrlDown and VAULT and IsValid(VAULT.frame) then VAULT.frame:Close() end
			end
		else
			summon:SetVisible(false)
		end
		return summon
	end

	local function buildCostPanel(card, it)
		local costPanel = vgui.Create("DPanel", card)
		costPanel:SetPaintBackground(false)
		costPanel.Paint = function(pnl, w, h)
			if not it then return end
			draw.SimpleText("Costs", "Arcana_AncientSmall", 0, 0, COLOR_SUBTEXT)
			draw.SimpleText("- " .. string.Comma(tonumber(VAULT_CFG.SUMMON_COINS) or 0) .. " coins", "Arcana_AncientSmall", 0, 16, COLOR_COST_TEXT)
			draw.SimpleText("- " .. string.Comma(tonumber(VAULT_CFG.SUMMON_SHARDS) or 0) .. " shards", "Arcana_AncientSmall", 0, 32, COLOR_COST_TEXT)
		end
		if not it then costPanel:SetVisible(false) end
		return costPanel
	end

	local function buildDeleteButton(card, it)
		local delBtn = vgui.Create("DButton", card)
		delBtn:SetText("")
		delBtn:SetSize(22, 22)
		delBtn.Paint = function(pnl, w, h)
			if not it then return end
			surface.SetDrawColor(160, 100, 90, 255)
			local pad = 6
			surface.DrawLine(pad, pad, w - pad, h - pad)
			surface.DrawLine(w - pad, pad, pad, h - pad)
		end
		if it then
			delBtn.DoClick = function()
				net.Start("Arcana_AstralVault_Delete")
				net.WriteString(tostring(it.id))
				net.SendToServer()
				surface.PlaySound("buttons/button8.wav")
			end
		else
			delBtn:SetVisible(false)
		end
		return delBtn
	end

	local function buildSlot(parent, it, slotIndex)
		local card = vgui.Create("DPanel", parent)
		card.Paint = function(pnl, w, h)
			ArtDeco.FillDecoPanel(2, 2, w - 4, h - 4, COLOR_DECO_BG, 8)
			ArtDeco.DrawDecoFrame(2, 2, w - 4, h - 4, ArtDeco.Colors.gold, 8)
			if it then
				ArtDeco.DrawTruncatedText("Arcana_AncientLarge", (it.name or it.print or it.class or "Weapon"), 10, 8, ArtDeco.Colors.textBright, w - 20)
			else
				draw.SimpleText("EMPTY", "Arcana_AncientLarge", w * 0.5, h * 0.5, COLOR_EMPTY_TEXT, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
			end
		end

		local model    = buildModelPanel(card, it)
		local enchList = buildEnchantList(card, it)
		local summon   = buildSummonButton(card, it)
		local costPanel = buildCostPanel(card, it)
		local delBtn   = buildDeleteButton(card, it)

		local sub = vgui.Create("DLabel", card)
		sub:SetFont("Arcana_AncientSmall")
		sub:SetTextColor(COLOR_SUBTEXT)
		sub:SetText(it and (it.class or "") or "")

		card.PerformLayout = function(pnl, w, h)
			local pad = 10
			local titleH = 24
			local modelTop = titleH + 4
			local mH = math.floor(h * 0.62)
			model:SetPos(pad, modelTop)
			model:SetSize(w - pad * 2, mH)
			sub:SetPos(pad, modelTop + mH + 2)
			sub:SetSize(w - pad * 2, 16)
			enchList:SetPos(pad, modelTop + mH + 20)
			enchList:SetSize(w - pad * 2, h - (modelTop + mH + 20) - 70)
			costPanel:SetSize(w - pad * 2, 48)
			costPanel:SetPos(pad, h - 55 - 52)
			summon:SetSize(w - pad * 2, 42)
			summon:SetPos(pad, h - 55)
			delBtn:SetPos(w - delBtn:GetWide() - 6, 6)
		end

		return card
	end

	local function layoutCards()
		local w = container:GetWide()
		local h = container:GetTall()
		local gap = 8
		local cols = VAULT_CFG.MAX_SLOTS
		local cw = math.max(160, math.floor((w - gap * (cols - 1) - 16) / cols))
		local ch = math.max(180, h - 16)
		for i, card in ipairs(cards) do
			local col = (i - 1)
			card:SetSize(cw, ch)
			card:SetPos(8 + col * (cw + gap), 8)
		end
	end

	local function rebuild()
		for _, c in ipairs(cards) do if IsValid(c) then c:Remove() end end
		cards = {}
		local items = VAULT.items or {}
		for i = 1, VAULT_CFG.MAX_SLOTS do
			local it = items[i]
			cards[#cards + 1] = buildSlot(container, it, i)
		end
		layoutCards()
	end

	container.PerformLayout = function() layoutCards() end

	-- Bottom imprint button spanning full width
	local imprintBtn = vgui.Create("DButton", frame)
	imprintBtn:Dock(BOTTOM)
	imprintBtn:SetTall(40)
	imprintBtn:DockMargin(12, 12, 12, 12)
	imprintBtn:SetText("")
	imprintBtn.Paint = function(pnl, w, h)
		local enabled = pnl:IsEnabled()
		local hovered = enabled and pnl:IsHovered()
		local bgCol = hovered and COLOR_BUTTON_BG_HOVER or COLOR_BUTTON_BG
		ArtDeco.FillDecoPanel(0, 0, w, h, bgCol, 8)
		local frameCol = enabled and ArtDeco.Colors.gold or COLOR_BUTTON_FRAME_DISABLED
		ArtDeco.DrawDecoFrame(0, 0, w, h, frameCol, 8)
		local txtCol = enabled and ArtDeco.Colors.textBright or COLOR_BUTTON_TEXT_DISABLED
		draw.SimpleText("Imprint Current Weapon", "Arcana_AncientLarge", w * 0.5, h * 0.5 - 8, txtCol, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		local sub = "Cost: " .. string.Comma(tonumber(VAULT_CFG.STORE_COINS) or 0) .. " coins, " .. string.Comma(tonumber(VAULT_CFG.STORE_SHARDS) or 0) .. " shards"
		surface.SetFont("Arcana_AncientSmall")
		local tw, th = surface.GetTextSize(sub)

		-- Draw a smaller, tighter subtext closer to center line
		draw.SimpleText(sub, "Arcana_AncientSmall", w * 0.5, h * 0.5 + 6, COLOR_SUBTEXT, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
	end
	-- Enable/disable imprint based on weapon presence, vault space and affordability
	imprintBtn.Think = function(pnl)
		local lp = LocalPlayer()
		local hasWeapon = IsValid(lp) and IsValid(lp:GetActiveWeapon())
		local items = VAULT.items or {}
		local hasRoom = (#items) < (tonumber(VAULT_CFG.MAX_SLOTS) or 0)
		local haveCoins = Arcana:GetCoins(lp)
		local haveShards = Arcana:GetItemCount(lp, "mana_crystal_shard")
		local needCoins = tonumber(VAULT_CFG.STORE_COINS) or 0
		local needShards = tonumber(VAULT_CFG.STORE_SHARDS) or 0
		local ok = hasWeapon and hasRoom and (haveCoins >= needCoins) and (haveShards >= needShards)
		pnl:SetEnabled(ok)
	end

	imprintBtn.DoClick = function()
		if not imprintBtn:IsEnabled() then
			surface.PlaySound("buttons/button8.wav")
			return
		end
		net.Start("Arcana_AstralVault_Imprint")
		net.WriteString("")
		net.SendToServer()
		surface.PlaySound("buttons/button14.wav")
	end

	rebuild()
	VAULT.rebuild = rebuild
end

-- Receive open payload
net.Receive("Arcana_AstralVault_Open", function()
	local items = net.ReadTable() or {}
	openVault(items)
end)
