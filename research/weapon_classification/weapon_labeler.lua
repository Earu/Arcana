-- ============================================================
-- weapon_labeler.lua  —  Weapon Ground Truth Labeling Tool
--
-- SETUP (run both lines in the game console):
--   lua_openscript    wip/weapon_labeler.lua     <- server  (registers give handler)
--   lua_openscript_cl wip/weapon_labeler.lua     <- client  (shows the UI)
--
-- Flow per weapon:
--   1. Weapon is stripped and replaced with the next class.
--   2. Fire the weapon once.
--   3. 1 second later all label buttons unlock.
--   4. Click a label → saved to data/weapon_ground_truth_labeled.json → next weapon.
--   "Skip" is always available (label stays unchanged, weapon retried next session).
--   Progress is saved after every label; restarting resumes from the first unlabeled weapon.
-- ============================================================

-- ─── SERVER ──────────────────────────────────────────────────────────────────
if SERVER then
	util.AddNetworkString("wl_give")

	net.Receive("wl_give", function(_, ply)
		local cls = net.ReadString()
		ply:StripWeapons()
		timer.Simple(0.2, function()
			if not IsValid(ply) then return end
			ply:Give(cls)
			timer.Simple(0.1, function()
				if IsValid(ply) then ply:SelectWeapon(cls) end
			end)
		end)
	end)

	MsgN("[WL] Server side ready.")
	return
end

-- ─── CLIENT ──────────────────────────────────────────────────────────────────
local DATA_FILE = "weapon_ground_truth.json"
local SAVE_FILE = "weapon_ground_truth_labeled.json"

surface.CreateFont("WL_Title", { font = "Roboto", size = 26, weight = 700, antialias = true })
surface.CreateFont("WL_Body",  { font = "Roboto", size = 16, weight = 400, antialias = true })
surface.CreateFont("WL_BtnLg", { font = "Roboto", size = 20, weight = 700, antialias = true })
surface.CreateFont("WL_BtnSm", { font = "Roboto", size = 15, weight = 600, antialias = true })

-- ─── Colour palette ──────────────────────────────────────────────────────────
local C = {
	bg         = Color( 16,  16,  22, 238),
	stripe     = Color( 70, 130, 255),
	white      = Color(255, 255, 255),
	dim        = Color(130, 130, 150),
	unknown    = Color(255, 200,  50),
	green      = Color(140, 215, 140),
	yellow     = Color(255, 210,  80),
	barBg      = Color( 38,  38,  44),
	barFill    = Color( 55, 160,  75),
	disabled   = Color( 40,  40,  48),
	btnH_n     = Color( 28,  82, 195),
	btnH_h     = Color( 58, 128, 255),
	btnP_n     = Color(175,  55,  18),
	btnP_h     = Color(238,  92,  40),
	btnBr_n    = Color(140,  90,   0),
	btnBr_h    = Color(200, 135,  10),
	btnIr_n    = Color( 72,  52,  98),
	btnIr_h    = Color(108,  80, 145),
	btnSk_n    = Color( 52,  52,  58),
	btnSk_h    = Color( 88,  88,  94),
}

-- ─── State ───────────────────────────────────────────────────────────────────
local WL = {}
WL.__index = WL

function WL.new()
	return setmetatable({
		data         = nil,
		weapons      = nil,
		idx          = 1,
		savedSet     = nil,   -- {[cls]=true} for weapons already in SAVE_FILE
		savedCount   = 0,
		-- "waiting"   = player hasn't fired yet
		-- "countdown" = fired, 1 s delay running
		-- "labeling"  = all label buttons unlocked
		phase        = "idle",
		lastShotTime = 0,
		panel        = nil,
		ui           = {},
	}, WL)
end

-- ─── Data ────────────────────────────────────────────────────────────────────
function WL:load()
	-- Load original ground truth
	local raw = file.Read(DATA_FILE, "DATA")
	if not raw then
		MsgN("[WL] ERROR: cannot read data/" .. DATA_FILE)
		return false
	end
	self.data = util.JSONToTable(raw)
	if not self.data then
		MsgN("[WL] ERROR: JSON parse failed")
		return false
	end

	-- Merge existing save and build the "already labeled" set for resuming
	self.savedSet = {}
	local saveRaw = file.Read(SAVE_FILE, "DATA")
	if saveRaw then
		local saved = util.JSONToTable(saveRaw)
		if saved then
			for cls, lbl in pairs(saved) do
				self.data[cls]    = lbl
				self.savedSet[cls] = true
			end
		end
	end
	self.savedCount = table.Count(self.savedSet)

	-- Build sorted weapon list
	self.weapons = {}
	for cls in pairs(self.data) do
		table.insert(self.weapons, cls)
	end
	table.sort(self.weapons)

	-- Resume: jump to the first weapon not yet in the save file
	self.idx = #self.weapons + 1  -- default: everything done
	for i, cls in ipairs(self.weapons) do
		if not self.savedSet[cls] then
			self.idx = i
			break
		end
	end

	MsgN(string.format("[WL] Loaded %d weapons. %d already labeled. Resuming at #%d.",
		#self.weapons, self.savedCount, self.idx))
	return true
end

function WL:save()
	-- Only persist entries the user has explicitly labeled; never the original base labels.
	local out = {}
	for cls in pairs(self.savedSet) do
		out[cls] = self.data[cls]
	end
	file.Write(SAVE_FILE, util.TableToJSON(out, true))
end

function WL:current()
	return self.weapons[self.idx]
end

-- ─── Weapon management ───────────────────────────────────────────────────────
function WL:giveWeapon(cls)
	net.Start("wl_give")
		net.WriteString(cls)
	net.SendToServer()

	self.phase        = "waiting"
	self.lastShotTime = 0

	-- Fallback: weapon couldn't be given → unlock after 3 s so user can skip
	timer.Simple(3, function()
		if self.phase ~= "waiting" then return end
		self.phase = "labeling"
		if IsValid(self.panel) then self.panel:SetVisible(true) end
		gui.EnableScreenClicker(true)
		self:refresh()
	end)

	self:refresh()
end

-- ─── Actions ─────────────────────────────────────────────────────────────────
function WL:label(value)
	local cls = self:current()
	self.data[cls] = value
	if not self.savedSet[cls] then
		self.savedSet[cls] = true
		self.savedCount    = self.savedCount + 1
	end
	self:save()
	MsgN(string.format("[WL] %-50s  ->  %-18s  (%d / %d)",
		cls, value, self.savedCount, #self.weapons))
	self:advance()
end

function WL:skip()
	MsgN(string.format("[WL] SKIP  %-50s  (%d / %d)",
		self:current(), self.savedCount, #self.weapons))
	self:advance()
end

function WL:advance()
	gui.EnableScreenClicker(false)
	if IsValid(self.panel) then self.panel:SetVisible(false) end
	self.idx = self.idx + 1
	if self.idx > #self.weapons then
		self:finish()
		return
	end
	timer.Simple(0.3, function()
		self:giveWeapon(self:current())
	end)
	self:refresh()
end

function WL:finish()
	gui.EnableScreenClicker(false)
	if IsValid(self.panel) then self.panel:Remove() end
	notification.AddLegacy(
		string.format("[WL] Done! All %d weapons processed.", #self.weapons),
		NOTIFY_GENERIC, 6)
	MsgN("[WL] Labeling complete.")
end

-- ─── UI helpers ──────────────────────────────────────────────────────────────
local function makeBtn(parent, x, y, w, h, text, font, nc, hc, cb)
	local b = vgui.Create("DButton", parent)
	b:SetPos(x, y)
	b:SetSize(w, h)
	b:SetText(text)
	b:SetFont(font)
	b:SetTextColor(C.white)
	b.Paint = function(s, bw, bh)
		local col = (not s:IsEnabled()) and C.disabled
		         or (s:IsHovered()      and hc or nc)
		draw.RoundedBox(6, 0, 0, bw, bh, col)
	end
	b.DoClick = cb
	return b
end

-- ─── Build UI ────────────────────────────────────────────────────────────────
function WL:buildUI()
	if IsValid(self.panel) then self.panel:Remove() end

	local PW, PH = 510, 268

	local frame = vgui.Create("DFrame")
	frame:SetSize(PW, PH)
	frame:SetPos(ScrW() / 2 - PW / 2, math.Round(ScrH() * 0.07))
	frame:SetDraggable(true)
	frame:ShowCloseButton(false)
	frame:SetTitle("")
	frame:SetPaintBackgroundEnabled(false)
	frame:SetVisible(false)   -- hidden until the weapon is fired

	frame.Paint = function(_, w, h)
		draw.RoundedBox(10, 0, 0, w, h, C.bg)
		draw.RoundedBox(10, 0, 0, w,  4, C.stripe)
	end

	-- Weapon class name
	local lClass = vgui.Create("DLabel", frame)
	lClass:SetPos(20, 18)
	lClass:SetSize(PW - 40, 32)
	lClass:SetFont("WL_Title")
	lClass:SetTextColor(C.white)

	-- Existing label
	local lCurrent = vgui.Create("DLabel", frame)
	lCurrent:SetPos(20, 54)
	lCurrent:SetSize(PW - 40, 22)
	lCurrent:SetFont("WL_Body")

	-- Status / instruction line
	local lStatus = vgui.Create("DLabel", frame)
	lStatus:SetPos(20, 78)
	lStatus:SetSize(PW - 40, 22)
	lStatus:SetFont("WL_Body")

	-- ── Row 1: primary labels (require firing) ───────────────────────────────
	local bH = makeBtn(frame, 20, 108, 232, 48, "HITSCAN",    "WL_BtnLg",
		C.btnH_n, C.btnH_h,
		function() if self.phase == "labeling" then self:label("HITSCAN")    end end)

	local bP = makeBtn(frame, 258, 108, 232, 48, "PROJECTILE", "WL_BtnLg",
		C.btnP_n, C.btnP_h,
		function() if self.phase == "labeling" then self:label("PROJECTILE") end end)

	-- ── Row 2: meta labels + skip ────────────────────────────────────────────
	local bBr = makeBtn(frame, 20, 162, 148, 42, "Broken / Unsure",    "WL_BtnSm",
		C.btnBr_n, C.btnBr_h,
		function() if self.phase == "labeling" then self:label("BROKEN")     end end)

	local bIr = makeBtn(frame, 174, 162, 164, 42, "Irrelevant / Ignore", "WL_BtnSm",
		C.btnIr_n, C.btnIr_h,
		function() if self.phase == "labeling" then self:label("IRRELEVANT") end end)

	makeBtn(frame, 344, 162, 146, 42, "Skip  ->", "WL_Body",
		C.btnSk_n, C.btnSk_h,
		function() self:skip() end)

	-- Progress bar
	local prog = vgui.Create("DPanel", frame)
	prog:SetPos(20, 214)
	prog:SetSize(PW - 40, 46)
	prog.Paint = function(_, w, h)
		draw.RoundedBox(5, 0, 0, w, 26, C.barBg)
		local frac = self.savedCount / math.max(#self.weapons, 1)
		if frac > 0 then
			draw.RoundedBox(5, 0, 0, math.Round(w * frac), 26, C.barFill)
		end
		draw.SimpleText(
			string.format("%d / %d weapons labeled", self.savedCount, #self.weapons),
			"WL_Body", w / 2, 13,
			C.white, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
	end

	-- Fire-detection: runs every Think tick while phase == "waiting"
	frame.Think = function()
		if self.phase ~= "waiting" then return end
		local ply = LocalPlayer()
		if not IsValid(ply) then return end
		local wep = ply:GetActiveWeapon()
		if not IsValid(wep) then return end
		local t = wep:LastShootTime()
		if t > self.lastShotTime and t > 0 then
			self.lastShotTime = t
			self.phase        = "countdown"
			timer.Simple(1, function()
				if self.phase ~= "countdown" then return end
				self.phase = "labeling"
				if IsValid(self.panel) then self.panel:SetVisible(true) end
				gui.EnableScreenClicker(true)
				self:refresh()
			end)
		end
	end

	self.panel = frame
	self.ui    = { lClass = lClass, lCurrent = lCurrent, lStatus = lStatus,
	               bH = bH, bP = bP, bBr = bBr, bIr = bIr }
end

-- ─── Refresh visible state ───────────────────────────────────────────────────
function WL:refresh()
	if not IsValid(self.panel) then return end
	local ui  = self.ui
	local cls = self:current()
	if not cls then return end

	local existing  = self.data[cls] or "?"
	local isUnknown = type(existing) == "string" and existing:find("UNKNOWN") ~= nil
	local canLabel  = self.phase == "labeling"

	ui.lClass:SetText(cls)
	ui.lCurrent:SetText("Current label: " .. existing)
	ui.lCurrent:SetTextColor(isUnknown and C.unknown or C.dim)
	ui.bH:SetEnabled(canLabel)
	ui.bP:SetEnabled(canLabel)
	ui.bBr:SetEnabled(canLabel)
	ui.bIr:SetEnabled(canLabel)

	if self.phase == "waiting" then
		ui.lStatus:SetText("Fire the weapon, then wait 1 second...")
		ui.lStatus:SetTextColor(C.green)
	elseif self.phase == "countdown" then
		ui.lStatus:SetText("Locking in...")
		ui.lStatus:SetTextColor(C.yellow)
	else
		ui.lStatus:SetText("Choose a label:")
		ui.lStatus:SetTextColor(C.white)
	end
end

-- ─── Concommand ──────────────────────────────────────────────────────────────
-- Usage:
--   wl_start          → resume from first unlabeled weapon
--   wl_start 250      → jump to weapon #250 in the sorted list

local activeWL = nil

concommand.Add("wl_start", function(_, _, args)
	-- Clean up any existing session
	if activeWL and IsValid(activeWL.panel) then
		activeWL.panel:Remove()
		gui.EnableScreenClicker(false)
	end

	local wl = WL.new()
	if not wl:load() then return end

	-- Optional index override
	local override = tonumber(args[1])
	if override then
		override = math.Clamp(math.Round(override), 1, #wl.weapons)
		wl.idx = override
		MsgN(string.format("[WL] Index overridden to %d (%s).", override, wl.weapons[override]))
	end

	if wl.idx > #wl.weapons then
		MsgN("[WL] All weapons are already labeled. Nothing to do.")
		return
	end

	activeWL = wl
	wl:buildUI()
	wl:giveWeapon(wl:current())
	MsgN(string.format("[WL] Labeling started at #%d / %d. Good luck!", wl.idx, #wl.weapons))
end, nil, "Start (or resume) the weapon labeling UI. Optional arg: starting index.")
