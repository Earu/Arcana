-- Shared context-menu properties for Arcana's placeable entities.
-- Registered shared: the client builds the submenu (presets plus a control that
-- can be dragged live), the server validates the sender and applies the value.
-- Colors travel as a packed 24bit int -- networked vectors lose too much
-- precision on 0-1 components to round-trip a color cleanly.

Arcana = Arcana or {}
Arcana.Common = Arcana.Common or {}

function Arcana.Common.PackColor(col)
	local r = math.Clamp(math.Round(col.r), 0, 255)
	local g = math.Clamp(math.Round(col.g), 0, 255)
	local b = math.Clamp(math.Round(col.b), 0, 255)

	return bit.bor(bit.lshift(r, 16), bit.lshift(g, 8), b)
end

function Arcana.Common.UnpackColor(packed)
	return Color(bit.band(bit.rshift(packed, 16), 255), bit.band(bit.rshift(packed, 8), 255), bit.band(packed, 255))
end

if not properties or not properties.Add then return end

local packColor = Arcana.Common.PackColor
local sendThrottled, openColorPicker

if CLIENT then
	-- Sliders and the color mixer fire continuously while dragged: cap the rate
	-- but never drop the value the player actually settled on.
	local pending = {}

	sendThrottled = function(key, value, sendFn)
		local now = SysTime()
		local entry = pending[key]

		if not entry then
			entry = {last = 0}
			pending[key] = entry
		end

		entry.value = value
		entry.send = sendFn

		if now - entry.last >= 0.1 then
			entry.last = now
			sendFn(value)

			return
		end

		if entry.scheduled then return end
		entry.scheduled = true

		timer.Simple(0.1 - (now - entry.last), function()
			entry.scheduled = false
			entry.last = SysTime()
			entry.send(entry.value)
		end)
	end

	openColorPicker = function(prop, ent, cfg)
		local frame = vgui.Create("DFrame")
		frame:SetSize(280, 330)
		frame:Center()
		frame:SetTitle(ArtDeco and "" or cfg.title)
		frame:MakePopup()

		if ArtDeco then
			frame.Paint = function(_, w, h)
				ArtDeco.FillDecoPanel(0, 0, w, h, ArtDeco.Colors.decoBg, 12)
				ArtDeco.DrawDecoFrame(4, 4, w - 8, h - 8, ArtDeco.Colors.gold, 10)
				ArtDeco.DrawTitle("Arcana_Ancient", string.upper(cfg.title), 8, 36, ArtDeco.Colors.paleGold)
			end

			ArtDeco.StyleCloseButton(frame)
		end

		local mixer = vgui.Create("DColorMixer", frame)
		mixer:Dock(FILL)
		mixer:DockMargin(14, ArtDeco and 40 or 6, 14, 14)
		mixer:SetPalette(true)
		mixer:SetAlphaBar(false)
		mixer:SetWangs(true)
		mixer:SetColor(cfg.get(ent))

		mixer.ValueChanged = function(_, col)
			if not IsValid(ent) then
				frame:Remove()

				return
			end

			sendThrottled(prop.InternalName .. ent:EntIndex(), col, function(value) prop:Apply(ent, value) end)
		end

		return frame
	end
end

-- Shared gate: right class, and the player is allowed to touch this entity.
local function makeFilter(name, cfg)
	return function(_, ent, ply)
		if not IsValid(ent) or ent:GetClass() ~= cfg.class then return false end
		if not IsValid(ply) or not ply:IsPlayer() then return false end
		if not gamemode.Call("CanProperty", ply, name, ent) then return false end
		if ply:IsAdmin() then return true end

		-- Defer to prop protection when installed; plain sandbox lets anyone tweak
		local owner = ent.CPPIGetOwner and ent:CPPIGetOwner()
		if IsValid(owner) then return owner == ply end

		return true
	end
end

-- Reads the entity a property message targets, or nil if the sender may not touch it
local function readTarget(prop, ply)
	local ent = net.ReadEntity()
	if not IsValid(ent) then return end
	if not properties.CanBeTargeted(ent, ply) then return end
	if not prop:Filter(ent, ply) then return end

	return ent
end

--- Context-menu color property backed by a packed-int network var.
-- cfg: class, label, order, icon, title, presets = {{name, color}}, get(ent), set(ent, color)
function Arcana.Common.AddColorProperty(name, cfg)
	properties.Add(name, {
		MenuLabel = cfg.label,
		Order = cfg.order or 900,
		MenuIcon = cfg.icon or "icon16/paintcan.png",
		InternalName = name,
		Filter = makeFilter(name, cfg),

		Apply = function(self, ent, col)
			self:MsgStart()
			net.WriteEntity(ent)
			net.WriteUInt(packColor(col), 24)
			self:MsgEnd()
		end,

		MenuOpen = function(self, option, ent)
			local submenu = option:AddSubMenu()
			submenu:SetMinimumWidth(170)

			for _, preset in ipairs(cfg.presets or {}) do
				local swatch = preset.color
				local opt = submenu:AddOption(preset.name, function() self:Apply(ent, swatch) end)

				opt.PaintOver = function(_, w, h)
					local y = h * 0.5 - 6
					surface.SetDrawColor(swatch)
					surface.DrawRect(w - 26, y, 16, 12)
					surface.SetDrawColor(0, 0, 0, 180)
					surface.DrawOutlinedRect(w - 26, y, 16, 12)
				end
			end

			submenu:AddSpacer()
			submenu:AddOption("Custom...", function() openColorPicker(self, ent, cfg) end):SetIcon("icon16/color_wheel.png")
		end,

		Action = function() end,

		Receive = function(self, _, ply)
			local ent = readTarget(self, ply)
			local packed = net.ReadUInt(24)
			if not IsValid(ent) then return end

			cfg.set(ent, Arcana.Common.UnpackColor(packed))
		end,
	})
end

--- Context-menu numeric property: a live slider plus named presets.
-- cfg: class, label, order, icon, sliderLabel, min, max, decimals,
--      presets = {{name, value}}, get(ent), set(ent, number)
function Arcana.Common.AddScalarProperty(name, cfg)
	properties.Add(name, {
		MenuLabel = cfg.label,
		Order = cfg.order or 900,
		MenuIcon = cfg.icon or "icon16/cog.png",
		InternalName = name,
		Filter = makeFilter(name, cfg),

		Apply = function(self, ent, value)
			self:MsgStart()
			net.WriteEntity(ent)
			net.WriteFloat(value)
			self:MsgEnd()
		end,

		MenuOpen = function(self, option, ent)
			local submenu = option:AddSubMenu()
			submenu:SetMinimumWidth(250)

			local slider = vgui.Create("DNumSlider", submenu)
			slider:SetSize(240, 44)
			slider:SetText(cfg.sliderLabel or cfg.label)
			slider:SetMin(cfg.min)
			slider:SetMax(cfg.max)
			slider:SetDecimals(cfg.decimals or 0)
			slider:SetValue(cfg.get(ent))

			slider.OnValueChanged = function(_, value)
				if not IsValid(ent) then return end

				sendThrottled(name .. ent:EntIndex(), value, function(v) self:Apply(ent, v) end)
			end

			submenu:AddPanel(slider)
			submenu:AddSpacer()

			for _, preset in ipairs(cfg.presets or {}) do
				submenu:AddOption(preset.name, function() self:Apply(ent, preset.value) end)
			end
		end,

		Action = function() end,

		Receive = function(self, _, ply)
			local ent = readTarget(self, ply)
			local value = net.ReadFloat()
			if not IsValid(ent) then return end

			cfg.set(ent, math.Clamp(value, cfg.min, cfg.max))
		end,
	})
end

-- Entity files declare their properties at file scope and the load order between
-- arcana/common and lua/entities is not guaranteed -- a reload can run either side
-- on its own. Entities that loaded first are listening for this.
Arcana.RunHook("EntityPropertiesReady")
