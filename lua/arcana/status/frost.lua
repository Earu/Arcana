-- Shared Frost status: applies slowing and chill FX to players, NPCs, and NextBots
Arcane = Arcane or {}
Arcane.Status = Arcane.Status or {}

local Frost = {}

if SERVER then
	util.AddNetworkString("Arcana_FrostChill")
end

-- options: slowMult (0.5), duration (3.5), vfxTag ("frost_slow"), sendClientFX (true for players)
function Frost.Apply(target, options)
	if not IsValid(target) then return end
	options = options or {}
	local slowMult = tonumber(options.slowMult) or 0.5
	local duration = tonumber(options.duration) or 3.5
	local vfxTag = options.vfxTag or "frost_slow"
	local sendClientFX = options.sendClientFX ~= false -- default true

	local isActor = target:IsPlayer() or target:IsNPC() or (target.IsNextBot and target:IsNextBot())
	if not isActor then return end

	local untilTime = CurTime() + duration
	target.ArcanaFrostSlowUntil = math.max(target.ArcanaFrostSlowUntil or 0, untilTime)

	-- Visual band
	Arcane:SendAttachBandVFX(target, Color(170, 220, 255, 255), 24, 0.8, {
		{
			radius = 18,
			height = 6,
			spin = { p = 0, y = 40, r = 0 },
			lineWidth = 2,
		},
	}, vfxTag)

	if target:IsPlayer() then
		-- Initial heavy chill, then steady slow
		target:SetLaggedMovementValue(0.2)
		timer.Simple(0.5, function()
			if not IsValid(target) then return end
			if CurTime() < (target.ArcanaFrostSlowUntil or 0) then
				target:SetLaggedMovementValue(slowMult)
			end
		end)

		if sendClientFX then
			net.Start("Arcana_FrostChill", true)
			net.WriteFloat(duration)
			net.Send(target)
		end
	else
		-- NPC / NextBot logic
		-- NextBot: snapshot and apply loco desired speed
		if target.IsNextBot and target:IsNextBot() and target.loco then
			if target._ArcanaOrigLocoSpeed == nil and target.loco.GetDesiredSpeed then
				target._ArcanaOrigLocoSpeed = target.loco:GetDesiredSpeed()
			end

			if target.loco.SetDesiredSpeed then
				local baseLS = target._ArcanaOrigLocoSpeed or (target.loco.GetDesiredSpeed and target.loco:GetDesiredSpeed()) or 200
				target.loco:SetDesiredSpeed(math.max(10, baseLS * slowMult))
			end
		end

		-- Animation playback slow for actors (visual)
		if target._ArcanaOrigPlaybackRate == nil then
			target._ArcanaOrigPlaybackRate = target:GetPlaybackRate()
		end

		target:SetPlaybackRate(math.max(0.2, (target._ArcanaOrigPlaybackRate or 1) * slowMult))
	end

	-- Single per-entity maintenance timer: clamps speeds until slow expires, then restores
	local timerId = "Arcana_FrostSlowRestore_" .. target:EntIndex()
	timer.Create(timerId, 0.25, math.ceil(duration / 0.25) + 2, function()
		if not IsValid(target) then return end

		if CurTime() >= (target.ArcanaFrostSlowUntil or 0) then
			-- Restore
			if target:IsPlayer() then
				target:SetLaggedMovementValue(1)
			else
				if target.IsNextBot and target:IsNextBot() and target.loco and target._ArcanaOrigLocoSpeed then
					if target.loco.SetDesiredSpeed then target.loco:SetDesiredSpeed(target._ArcanaOrigLocoSpeed) end
				end
				if target._ArcanaOrigPlaybackRate then
					target:SetPlaybackRate(target._ArcanaOrigPlaybackRate)
				end
			end

			-- cleanup
			target._ArcanaNPCGroundClamp = nil
			target._ArcanaLocoClamp = nil
			Arcane:ClearBandVFX(target, vfxTag)
			timer.Remove(timerId)

			return
		end

		-- While slowed, keep clamping speeds so schedules/pathing can't override
		if not target:IsPlayer() then
			if target:IsNPC() then
				local curr = target.GetInternalVariable and target:GetInternalVariable("m_flGroundSpeed") or nil
				if isnumber(curr) and curr > 0 then
					local clamp = target._ArcanaNPCGroundClamp
					if not clamp or curr > clamp + 0.1 then
						clamp = math.max(10, curr * slowMult)
						target._ArcanaNPCGroundClamp = clamp
						target:SetSaveValue("m_flGroundSpeed", clamp)
					end
				end
			end

			if target.IsNextBot and target:IsNextBot() and target.loco then
				if target.loco.SetDesiredSpeed then
					local curLS = target.loco.GetDesiredSpeed and target.loco:GetDesiredSpeed() or nil
					if isnumber(curLS) and curLS > 0 then
						local clampLS = target._ArcanaLocoClamp
						if not clampLS or curLS > clampLS + 0.1 then
							clampLS = math.max(10, curLS * slowMult)
							target._ArcanaLocoClamp = clampLS
							target.loco:SetDesiredSpeed(clampLS)
						end
					end
				end
			end
		end
	end)
end

Arcane.Status.Frost = Frost

if CLIENT then
	-- Generic chill FX (breath + vignette) reused by all frost sources
	local chillEnd = 0
	local nextBreath = 0
	local breathEmitter
	local frostOverlayMat = Material("particle/particle_smokegrenade")

	net.Receive("Arcana_FrostChill", function()
		local dur = net.ReadFloat() or 2
		chillEnd = math.max(chillEnd, CurTime() + dur)
		if not breathEmitter then
			breathEmitter = ParticleEmitter(LocalPlayer():GetPos())
		end
	end)

	hook.Add("Think", "Arcana_Frost_Status_Breath", function()
		if CurTime() > chillEnd then return end

		local lp = LocalPlayer()
		if not IsValid(lp) then return end
		if CurTime() < nextBreath then return end

		nextBreath = CurTime() + 0.08
		if not breathEmitter then
			breathEmitter = ParticleEmitter(lp:GetPos())
		end

		local eye = lp:EyePos()
		local fwd = lp:EyeAngles():Forward()
		local p = breathEmitter:Add("particle/particle_smokegrenade", eye + fwd * 4)
		if p then
			p:SetVelocity(fwd * 20 + VectorRand() * 6)
			p:SetDieTime(0.5)
			p:SetStartAlpha(60)
			p:SetEndAlpha(0)
			p:SetStartSize(2)
			p:SetEndSize(8)
			p:SetColor(220, 235, 255)
			p:SetAirResistance(60)
		end
	end)

	hook.Add("RenderScreenspaceEffects", "Arcana_Frost_Status_Vignette", function()
		if CurTime() > chillEnd then return end

		local t = math.Clamp((chillEnd - CurTime()) / 3, 0, 1)
		local cm = {
			["$pp_colour_addr"] = 0,
			["$pp_colour_addg"] = 0,
			["$pp_colour_addb"] = 0.01 * t,
			["$pp_colour_brightness"] = -0.02 * t,
			["$pp_colour_contrast"] = 1 + 0.04 * t,
			["$pp_colour_colour"] = 1 - 0.1 * t,
			["$pp_colour_mulr"] = 0,
			["$pp_colour_mulg"] = 0,
			["$pp_colour_mulb"] = 0.02 * t,
		}
		DrawColorModify(cm)

		local w, h = ScrW(), ScrH()
		local edge = math.floor(math.min(w, h) * 0.08 * t)
		if edge > 0 then
			surface.SetMaterial(frostOverlayMat)
			surface.SetDrawColor(210, 230, 255, math.floor(110 * t))
			surface.DrawTexturedRect(0, 0, w, edge)
			surface.DrawTexturedRect(0, h - edge, w, edge)
			surface.DrawTexturedRect(0, 0, edge, h)
			surface.DrawTexturedRect(w - edge, 0, edge, h)
		end

		DrawSharpen(0.4 * t, 1 + 1.5 * t)
	end)
end


