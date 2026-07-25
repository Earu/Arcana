Arcana = Arcana or {}
Arcana.Common = Arcana.Common or {}

-- util.ScreenShake networks to every player within radius regardless of visibility,
-- and its clientside version shakes the local screen unconditionally (pos/radius are
-- serverside-only args). This wrapper restricts the effect to players that are both
-- within radius and in the PVS of the origin, with distance falloff on the client.
function Arcana.Common.ScreenShake(pos, amplitude, frequency, duration, radius, airshake)
	if SERVER then
		local filter = RecipientFilter()
		filter:AddPVS(pos)

		local radiusSqr = radius * radius
		for _, ply in ipairs(filter:GetPlayers()) do
			if ply:EyePos():DistToSqr(pos) > radiusSqr then
				filter:RemovePlayer(ply)
			end
		end

		if filter:GetCount() < 1 then return end

		util.ScreenShake(pos, amplitude, frequency, duration, radius, airshake or false, filter)
	else
		local lp = LocalPlayer()
		if not IsValid(lp) then return end

		local dist = lp:EyePos():Distance(pos)
		if dist > radius then return end

		-- mimic the engine's serverside distance attenuation
		util.ScreenShake(pos, amplitude * (1 - dist / radius), frequency, duration, radius)
	end
end
