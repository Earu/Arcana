if SERVER then return end

local SQUARE_SIZE = 4
local FONT_NAME = "Arcana_DebugAttach"

surface.CreateFont(FONT_NAME, {
	font = "Consolas",
	size = 14,
	weight = 600,
})

local function getWeaponModel(ply)
	local wep = ply:GetActiveWeapon()
	if not IsValid(wep) then return nil, false end

	if not ply:ShouldDrawLocalPlayer() then
		local vm = ply:GetViewModel()
		if IsValid(vm) then return vm, true end
	end

	return wep, false
end

local function projectViewModelToWorldPos(vOrigin)
	local view = render.GetViewSetup()
	if not view then return vOrigin end
	local vEyePos = view.origin
	local aEyesRot = view.angles
	local vOffset = vOrigin - vEyePos
	local vForward = aEyesRot:Forward()

	local nViewX = math.tan(view.fovviewmodel_unscaled * math.pi / 360)
	if nViewX == 0 then
		vForward:Mul(vForward:Dot(vOffset))
		vEyePos:Add(vForward)
		return vEyePos
	end

	local nWorldX = math.tan(view.fov_unscaled * math.pi / 360)
	if nWorldX == 0 then
		vForward:Mul(vForward:Dot(vOffset))
		vEyePos:Add(vForward)
		return vEyePos
	end

	local vRight = aEyesRot:Right()
	local vUp = aEyesRot:Up()
	local nFactor = nWorldX / nViewX
	vRight:Mul(vRight:Dot(vOffset) * nFactor)
	vUp:Mul(vUp:Dot(vOffset) * nFactor)
	vForward:Mul(vForward:Dot(vOffset))
	vEyePos:Add(vRight)
	vEyePos:Add(vUp)
	vEyePos:Add(vForward)
	return vEyePos
end

local function collectAttachments(ent)
	local result = {}
	if not (IsValid(ent) and ent.GetAttachments) then return result end

	local attachments = ent:GetAttachments()
	if not attachments then return result end

	for _, info in ipairs(attachments) do
		local idx = info.id
		local att = ent:GetAttachment(idx)
		if att and att.Pos then
			result[#result + 1] = { name = info.name, pos = att.Pos }
		end
	end
	return result
end

hook.Add("HUDPaint", "Arcana_DebugAttachments", function()
	local ply = LocalPlayer()
	if not IsValid(ply) or not ply:Alive() then return end

	local ent, isViewModel = getWeaponModel(ply)
	if not IsValid(ent) then return end

	local attachments = collectAttachments(ent)
	surface.SetFont(FONT_NAME)

	local half = SQUARE_SIZE / 2
	for _, att in ipairs(attachments) do
		local worldPos = att.pos
		if isViewModel then
			worldPos = projectViewModelToWorldPos(worldPos)
		end

		local screen = worldPos:ToScreen()
		if not screen.visible then continue end

		local sx, sy = screen.x, screen.y

		surface.SetDrawColor(255, 255, 255, 255)
		surface.DrawRect(sx - half, sy - half, SQUARE_SIZE, SQUARE_SIZE)

		surface.SetDrawColor(0, 0, 0, 200)
		surface.DrawOutlinedRect(sx - half, sy - half, SQUARE_SIZE, SQUARE_SIZE)

		local tw, th = surface.GetTextSize(att.name)
		local tx, ty = sx + half + 4, sy - th / 2

		surface.SetDrawColor(0, 0, 0, 180)
		surface.DrawRect(tx - 2, ty - 1, tw + 4, th + 2)

		surface.SetTextColor(255, 255, 255, 255)
		surface.SetTextPos(tx, ty)
		surface.DrawText(att.name)
	end
end)