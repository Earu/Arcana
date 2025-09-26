AddCSLuaFile()

-- Astral Vault
-- Store enchanted weapons in a personal astral inventory and summon them later
local Arcane = _G.Arcane or {}

-- Networking
if SERVER then
	util.AddNetworkString("Arcana_AstralVault_Open")
	util.AddNetworkString("Arcana_AstralVault_RequestOpen")
	util.AddNetworkString("Arcana_AstralVault_Imprint")
	util.AddNetworkString("Arcana_AstralVault_Summon")
	util.AddNetworkString("Arcana_AstralVault_Delete")
end

-- Server configuration (costs)
local VAULT_CFG = {
	MAX_SLOTS = 6,
	STORE_COINS = 250000,
	STORE_SHARDS = 60,
	SUMMON_COINS = 10000,
	SUMMON_SHARDS = 5,
}

-- Utility: fetch enchantment ids from a weapon entity, stable order
local function collectEnchantIds(wep)
	local set = Arcane and Arcane.GetEntityEnchantments and Arcane:GetEntityEnchantments(wep) or {}
	local out = {}
	for id, on in pairs(set) do if on then out[#out + 1] = id end end
	table.sort(out)
	return out
end

-- SERVER: persistence layer (separate, compact table)
if SERVER then
	Arcane.AstralVaultCache = Arcane.AstralVaultCache or {}

	local ensured = false
	local function ensureVaultTable()
		if ensured then return true end
		if _G.co and _G.db then
			_G.co(function()
				_G.db.Query([[CREATE TABLE IF NOT EXISTS arcane_astral_vault (
					steamid	VARCHAR(255) PRIMARY KEY,
					items	TEXT NOT NULL DEFAULT '[]'
				)]])
			end)

			ensured = true
			return true
		else
			local ok = sql.Query([[CREATE TABLE IF NOT EXISTS arcane_astral_vault (
				steamid	TEXT PRIMARY KEY,
				items	TEXT NOT NULL DEFAULT '[]'
			);]])
			if ok == false then
				MsgC(Color(255, 80, 80), "[Arcana][SQL] ", Color(255,255,255), "CREATE TABLE arcane_astral_vault failed: " .. tostring(sql.LastError() or "?") .. "\n")
				return false
			end

			ensured = true
			return true
		end
	end

	local function readVault(ply, callback)
		if not ensureVaultTable() then return end
		if not IsValid(ply) then return end

		local sid = ply:SteamID64()
		if Arcane.AstralVaultCache[sid] then
			callback(true, Arcane.AstralVaultCache[sid])
			return
		end

		local function decode(json)
			json = json or "[]"
			json = json:gsub("^%'", ""):gsub("%'$", "")
			local ok, arr = pcall(util.JSONToTable, json)
			if ok and istable(arr) then return arr end

			return {}
		end

		if _G.co and _G.db then
			_G.co(function()
				local rows = _G.db.Query("SELECT * FROM arcane_astral_vault WHERE steamid = $1 LIMIT 1", sql.SQLStr(sid, true))
				if rows == false or rows == nil then callback(false, {}) return end

				local items = {}
				if istable(rows) and rows[1] then items = decode(rows[1].items) end
				Arcane.AstralVaultCache[sid] = items
				callback(true, items)
			end)
		else
			local q = string.format("SELECT * FROM arcane_astral_vault WHERE steamid = '%s' LIMIT 1;", sql.SQLStr(sid, true))
			local rows = sql.Query(q)
			if rows == false then callback(false, {}) return end

			local items = {}
			if istable(rows) and rows[1] then items = decode(rows[1].items) end
			Arcane.AstralVaultCache[sid] = items
			callback(true, items)
		end
	end

	local function writeVault(ply, items)
		if not ensureVaultTable() then return end
		if not IsValid(ply) then return end

		local sid = ply:SteamID64()
		Arcane.AstralVaultCache[sid] = items or {}
		local json = sql.SQLStr(util.TableToJSON(items or {}) or "[]")
		local id = sql.SQLStr(sid, true)

		if _G.co and _G.db then
			_G.co(function()
				_G.db.Query([[INSERT INTO arcane_astral_vault(steamid, items)
				VALUES($1, $2) ON CONFLICT (steamid) DO UPDATE SET items = EXCLUDED.items]], id, json)
			end)
		else
			local q = string.format("INSERT OR REPLACE INTO arcane_astral_vault (steamid, items) VALUES ('%s', %s);", id, json)
			sql.Query(q)
		end
	end

	local function canAfford(ply, coins, shards)
		local haveCoins = (ply.GetCoins and ply:GetCoins()) or 0
		local haveShards = (ply.GetItemCount and ply:GetItemCount("mana_crystal_shard")) or 0
		if haveCoins < (coins or 0) then return false, "Insufficient coins" end
		if haveShards < (shards or 0) then return false, "Missing item: mana_crystal_shard" end
		return true
	end

	local function charge(ply, coins, shards, reason)
		if coins and coins > 0 and ply.TakeCoins then ply:TakeCoins(coins, reason or "Astral Vault") end
		if shards and shards > 0 and ply.TakeItem then ply:TakeItem("mana_crystal_shard", shards, reason or "Astral Vault") end
	end

	local function sendOpen(ply, items)
		net.Start("Arcana_AstralVault_Open")
		net.WriteTable(items or {})
		net.Send(ply)
	end

	-- Open request (from client)
	net.Receive("Arcana_AstralVault_RequestOpen", function(_, ply)
		readVault(ply, function(_, items)
			sendOpen(ply, items)
		end)
	end)

	-- Imprint current weapon into vault (consumes weapon)
	net.Receive("Arcana_AstralVault_Imprint", function(_, ply)
		local nickname = tostring(net.ReadString() or "")
		local wep = ply:GetActiveWeapon()
		if not IsValid(wep) then return end
		local cls = wep:GetClass()
		local ids = collectEnchantIds(wep)
		readVault(ply, function(_, items)
			items = items or {}
			if #items >= VAULT_CFG.MAX_SLOTS then
				if Arcane.SendErrorNotification then Arcane:SendErrorNotification(ply, "Astral vault is full") end
				return
			end

			local ok, reason = canAfford(ply, VAULT_CFG.STORE_COINS, VAULT_CFG.STORE_SHARDS)
			if not ok then if Arcane.SendErrorNotification then Arcane:SendErrorNotification(ply, reason) end return end

			charge(ply, VAULT_CFG.STORE_COINS, VAULT_CFG.STORE_SHARDS, "Astral Vault Imprint")

			-- Remove weapon to avoid duplication
			if cls and ply.HasWeapon and ply:HasWeapon(cls) then ply:StripWeapon(cls) end

			local swep = weapons.GetStored(cls)
			local pretty = (swep and (swep.PrintName or swep.Printname)) or cls
			local entry = {
				id = util.CRC(cls .. table.concat(ids) .. os.time()),
				class = cls,
				name = (nickname ~= "" and nickname) or pretty,
				print = pretty,
				enchant_ids = ids,
				time = os.time(),
			}

			table.insert(items, 1, entry)
			writeVault(ply, items)
			sendOpen(ply, items)
		end)
	end)

	-- Summon an entry (give fresh weapon and apply enchants)
	net.Receive("Arcana_AstralVault_Summon", function(_, ply)
		local entryId = tostring(net.ReadString() or "")
		readVault(ply, function(_, items)
			local idx, entry
			for i, it in ipairs(items or {}) do if tostring(it.id) == entryId then idx, entry = i, it break end end
			if not entry then return end

			local ok, reason = canAfford(ply, VAULT_CFG.SUMMON_COINS, VAULT_CFG.SUMMON_SHARDS)
			if not ok then if Arcane.SendErrorNotification then Arcane:SendErrorNotification(ply, reason) end return end

			charge(ply, VAULT_CFG.SUMMON_COINS, VAULT_CFG.SUMMON_SHARDS, "Astral Vault Summon")
			local cls = entry.class

			-- Replace existing weapon of same class
			if cls and ply.HasWeapon and ply:HasWeapon(cls) then ply:StripWeapon(cls) end
			ply:Give(cls)

			timer.Simple(0, function()
				if not IsValid(ply) then return end

				local newWep = ply.GetWeapon and ply:GetWeapon(cls) or nil
				if not IsValid(newWep) then return end

				for _, id in ipairs(entry.enchant_ids or {}) do
					Arcane:ApplyEnchantmentToWeaponEntity(ply, newWep, id, true)
				end

				Arcane:SyncWeaponEnchantNW(newWep)
				ply:SelectWeapon(cls)
			end)
		end)
	end)

	-- Delete an entry from the vault
	net.Receive("Arcana_AstralVault_Delete", function(_, ply)
		local entryId = tostring(net.ReadString() or "")
		readVault(ply, function(_, items)
			local out = {}
			for _, it in ipairs(items or {}) do if tostring(it.id) ~= entryId then out[#out + 1] = it end end
			writeVault(ply, out)
			sendOpen(ply, out)
		end)
	end)
end

-- CLIENT: UI
if CLIENT then
	-- Command to open the vault
	concommand.Add("arcana_vault", function()
		net.Start("Arcana_AstralVault_RequestOpen")
		net.SendToServer()
	end, nil, "Open the Arcana Astral Vault")

	-- Summon by slot: arcana_vault_summon <1-6>
	concommand.Add("arcana_vault_summon", function(_, _, args)
		local idx = tonumber(args and args[1] or 0) or 0
		idx = math.floor(idx)
		if idx < 1 or idx > (tonumber(6) or 6) then
			Arcane:Print("Usage: arcana_vault_summon <1-6>")
			return
		end

		net.Start("Arcana_AstralVault_Summon")
		net.WriteString(tostring(idx))
		net.SendToServer()
		surface.PlaySound("buttons/button15.wav")
	end, nil, "Summon the weapon from astral vault slot 1-6")

	-- Art deco helpers (mirrors enchanter styles)
	surface.CreateFont("Arcana_AncientSmall", {font = "Georgia", size = 16, weight = 600, antialias = true, extended = true})
	surface.CreateFont("Arcana_Ancient", {font = "Georgia", size = 20, weight = 700, antialias = true, extended = true})
	surface.CreateFont("Arcana_AncientLarge", {font = "Georgia", size = 24, weight = 800, antialias = true, extended = true})

	local decoBg = Color(12, 12, 20, 235)
	local decoPanel = Color(18, 18, 28, 235)
	local gold = Color(198, 160, 74, 255)
	local textBright = Color(236, 230, 220, 255)
	local paleGold = Color(222, 198, 120, 255)
	local blurMat = Material("pp/blurscreen")

	local function DrawBlurRect(x, y, w, h, layers, density)
		surface.SetMaterial(blurMat)
		surface.SetDrawColor(255,255,255)
		render.SetScissorRect(x, y, x + w, y + h, true)
		for i = 1, (layers or 4) do
			blurMat:SetFloat("$blur", (i / (layers or 4)) * (density or 8))
			blurMat:Recompute()
			render.UpdateScreenEffectTexture()
			surface.DrawTexturedRect(0, 0, ScrW(), ScrH())
		end
		render.SetScissorRect(0, 0, 0, 0, false)
	end

	local function FillDeco(x, y, w, h, col, corner)
		local c = math.max(8, corner or 12)
		draw.NoTexture()
		surface.SetDrawColor(col.r, col.g, col.b, col.a or 255)
		local pts = {
			{x = x + c, y = y}, {x = x + w - c, y = y}, {x = x + w, y = y + c}, {x = x + w, y = y + h - c},
			{x = x + w - c, y = y + h}, {x = x + c, y = y + h}, {x = x, y = y + h - c}, {x = x, y = y + c},
		}
		surface.DrawPoly(pts)
	end

	local function DrawDecoFrame(x, y, w, h, col, corner)
		local c = math.max(8, corner or 12)
		surface.SetDrawColor(col.r, col.g, col.b, col.a or 255)
		surface.DisableClipping(true)
		surface.DrawLine(x + c, y, x + w - c, y)
		surface.DrawLine(x + w, y + c, x + w, y + h - c)
		surface.DrawLine(x + w - c, y + h, x + c, y + h)
		surface.DrawLine(x, y + h - c, x, y + c)
		surface.DrawLine(x, y + c, x + c, y)
		surface.DrawLine(x + w - c, y, x + w, y + c)
		surface.DrawLine(x + w, y + h - c, x + w - c, y + h)
		surface.DrawLine(x + c, y + h, x, y + h - c)
		surface.DisableClipping(false)
	end

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

	local function drawTruncatedText(font, text, x, y, col, maxW)
		surface.SetFont(font)
		local tw, _ = surface.GetTextSize(text)
		if tw <= maxW then
			draw.SimpleText(text, font, x, y, col)
			return
		end
		local ell = "…"
		local base = text
		while #base > 0 do
			base = string.sub(base, 1, #base - 1)
			local test = base .. ell
			local w2, _ = surface.GetTextSize(test)
			if w2 <= maxW then
				draw.SimpleText(test, font, x, y, col)
				return
			end
		end
	end

	local function getEnchantDisplayList(ids)
		local out = {}
		for _, id in ipairs(ids or {}) do
			local e = Arcane and Arcane.RegisteredEnchantments and Arcane.RegisteredEnchantments[id]
			out[#out + 1] = (e and e.name) or tostring(id)
		end
		table.sort(out)
		return out
	end

	local function drawChip(x, y, txt, font, bgCol, frameCol)
		surface.SetFont(font or "Arcana_AncientSmall")
		local tw, th = surface.GetTextSize(txt)
		local padX, padY = 6, 2
		local w, h = tw + padX * 2, th + padY * 2
		FillDeco(x, y, w, h, bgCol or Color(20, 20, 28, 180), 6)
		DrawDecoFrame(x, y, w, h, frameCol or Color(160, 140, 110, 220), 6)
		draw.SimpleText(txt, font or "Arcana_AncientSmall", x + padX, y + padY - 1, textBright)
		return w, h
	end

	-- Fit a model into a DModelPanel based on its bounding box
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
		local dir = Vector(1, 1, 0.5)

		dir:Normalize()

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
			DrawBlurRect(x, y, frame:GetWide(), frame:GetTall(), 4, 8)
		end)

		frame.Paint = function(pnl, w, h)
			drawGalaxyBackground(pnl, w, h, VAULT.seed)
			DrawDecoFrame(6, 6, w - 12, h - 12, gold, 14)
			draw.SimpleText(string.upper("Astral Vault"), "Arcana_AncientLarge", 18, 10, paleGold)
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
				surface.SetDrawColor(gold)
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

		local function buildSlot(parent, it, slotIndex)
			local card = vgui.Create("DPanel", parent)
			card.Paint = function(pnl, w, h)
				FillDeco(2, 2, w - 4, h - 4, Color(24, 24, 36, 120), 8)
				DrawDecoFrame(2, 2, w - 4, h - 4, gold, 8)
				if it then
					local title = (it.name or it.print or it.class or "Weapon")
					drawTruncatedText("Arcana_AncientLarge", title, 10, 8, textBright, w - 20)
				else
					draw.SimpleText("EMPTY", "Arcana_AncientLarge", w * 0.5, h * 0.5, Color(200, 190, 170), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
				end
			end

			local model = vgui.Create("DModelPanel", card)
			model:SetMouseInputEnabled(false)
			function model:LayoutEntity(ent)
				ent:SetAngles(Angle(0, CurTime() * 15 % 360, 0))
				FitModelPanel(self)
			end

			-- Render enchant rings using the shared helper in a valid 3D context for DModelPanel
			function model:PostDrawModel(ent)
				if Arcane and Arcane.RenderEnchantBandsForEntity then
					local count = self._EnchantCount or 3
					local ply = LocalPlayer()
					local col = ply.GetWeaponColor and ply:GetWeaponColor():ToColor() or Color(198, 160, 74, 255)
					local style = "axis"

					Arcane:RenderEnchantBandsForEntity(ent, count, col, style)
				end
			end

			local sub = vgui.Create("DLabel", card)
			sub:SetFont("Arcana_AncientSmall")
			sub:SetTextColor(Color(170, 160, 140))
			sub:SetText("")

			local enchList = vgui.Create("DPanel", card)
			enchList:SetPaintBackground(false)
			enchList.names = {}
			enchList.Paint = function(pnl, w, h)
				if not it then return end

				surface.SetFont("Arcana_AncientSmall")
				local y = 0
				for _, name in ipairs(pnl.names or {}) do
					draw.SimpleText("- " .. name, "Arcana_AncientSmall", 0, y, Color(210, 200, 185))
					y = y + 16
					if y > h - 16 then break end
				end
			end

			local summon = vgui.Create("DButton", card)
			summon:SetText("")
			summon.Paint = function(pnl, w, h)
				FillDeco(0, 0, w, h, Color(46, 36, 26, 235), 8)
				DrawDecoFrame(0, 0, w, h, gold, 8)
				draw.SimpleText(it and "Summon" or "Imprint", "Arcana_Ancient", w * 0.5, h * 0.5, textBright, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
			end

			-- Cost panel (secondary) above the summon button for filled slots
			local costPanel = vgui.Create("DPanel", card)
			costPanel:SetPaintBackground(false)
			costPanel.Paint = function(pnl, w, h)
				if not it then return end

				draw.SimpleText("Costs", "Arcana_AncientSmall", 0, 0, Color(170, 160, 140))
				draw.SimpleText("- " .. string.Comma(tonumber(VAULT_CFG.SUMMON_COINS) or 0) .. " coins", "Arcana_AncientSmall", 0, 16, Color(210, 200, 185))
				draw.SimpleText("- " .. string.Comma(tonumber(VAULT_CFG.SUMMON_SHARDS) or 0) .. " shards", "Arcana_AncientSmall", 0, 32, Color(210, 200, 185))
			end

			-- Small delete cross at top-right for filled slots
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

			if it then
				local cls = it.class or ""
				local swep = weapons.GetStored(cls)
				local mdl = (swep and (swep.WorldModel or swep.ViewModel)) or "models/weapons/w_pistol.mdl"
				model:SetModel(mdl)
				FitModelPanel(model)
				model._EnchantCount = math.max(1, #(it.enchant_ids or {}))
				sub:SetText(cls)
				enchList.names = getEnchantDisplayList(it.enchant_ids)
				-- costPanel draws its own content
				summon.DoClick = function()
					net.Start("Arcana_AstralVault_Summon")
					net.WriteString(tostring(it.id))
					net.SendToServer()
					surface.PlaySound("buttons/button15.wav")
				end
				delBtn.DoClick = function()
					net.Start("Arcana_AstralVault_Delete")
					net.WriteString(tostring(it.id))
					net.SendToServer()
					surface.PlaySound("buttons/button8.wav")
				end
			else
				model:SetVisible(false)
				sub:SetText("")
				enchList:SetVisible(false)
				summon:SetVisible(false)
				delBtn:SetVisible(false)
				costPanel:SetVisible(false)
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
			FillDeco(0, 0, w, h, Color(46, 36, 26, 235), 8)
			DrawDecoFrame(0, 0, w, h, gold, 8)
			draw.SimpleText("Imprint Current Weapon", "Arcana_AncientLarge", w * 0.5, h * 0.5 - 8, textBright, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
			local sub = "Cost: " .. string.Comma(tonumber(VAULT_CFG.STORE_COINS) or 0) .. " coins, " .. string.Comma(tonumber(VAULT_CFG.STORE_SHARDS) or 0) .. " shards"
			surface.SetFont("Arcana_AncientSmall")
			local tw, th = surface.GetTextSize(sub)

			-- Draw a smaller, tighter subtext closer to center line
			draw.SimpleText(sub, "Arcana_AncientSmall", w * 0.5, h * 0.5 + 6, Color(170, 160, 140), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		end
		imprintBtn.DoClick = function()
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
end

