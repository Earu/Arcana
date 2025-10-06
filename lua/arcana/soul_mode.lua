local Tag = "Arcana_SoulMode"
local SOUL_GRACE_SECS = 8

if SERVER then
	hook.Add("PlayerDeath", Tag, function(ply)
		ply:SetNW2Float("Arcana_SoulGraceUntil", CurTime() + SOUL_GRACE_SECS)
		ply.ArcanaSoulSpawnPos = ply:GetPos()
		ply:SetDSP(0)
		SafeRemoveEntity(ply:GetNW2Entity("Arcana_SoulEnt"))
	end)

	hook.Add("PlayerSpawn", Tag, function(ply)
		SafeRemoveEntity(ply:GetNW2Entity("Arcana_SoulEnt"))
	end)

	hook.Add("Move", Tag, function(ply, mv)
		if ply:GetNW2Float("Arcana_SoulGraceUntil", 0) > CurTime() then return end
		local ent = ply:GetNW2Entity("Arcana_SoulEnt")
		if not ent:IsValid() then return end

		mv:SetOrigin(ent:GetPos())
		mv:SetVelocity(Vector(0, 0, 0))

		if not ent.GravityOn then
			local ang = ply:EyeAngles()
			local aim = ang:Forward()
			local vel = Vector(0, 0, 0)

			if ply:KeyDown(IN_FORWARD) then
				vel = aim * 1
			elseif ply:KeyDown(IN_BACK) then
				vel = aim * -1
			end

			if ply:KeyDown(IN_MOVELEFT) then
				vel = ang:Right() * -1
			elseif ply:KeyDown(IN_MOVERIGHT) then
				vel = ang:Right() * 1
			end

			if ply:KeyDown(IN_JUMP) then
				vel = vel + ply:GetUp() * 1
			end

			if ply:KeyDown(IN_SPEED) then
				vel = vel * 5
			end

			if ply:KeyDown(IN_DUCK) then
				vel = vel * 0.25
			end

			if ply:KeyDown(IN_WALK) then
				vel = vel * 0.5
			end

			vel = vel * 5
			local phys = ent:GetPhysicsObject()

			phys:ComputeShadowControl({
				secondstoarrive = 0.9,
				pos = phys:GetPos() + vel,
				angle = ply:EyeAngles(),
				maxangular = 5000,
				maxangulardamp = 10000,
				maxspeed = 1000000,
				maxspeeddamp = 10000,
				dampfactor = 0.05,
				teleportdistance = 200,
				deltatime = FrameTime(),
			})

			local rag = ply:GetRagdollEntity()
			rag = rag and rag:IsValid() and rag or nil

			if rag then
				for i = 0, rag:GetPhysicsObjectCount() - 1 do
					local phys = rag:GetPhysicsObjectNum(i)
					phys:AddVelocity((ply:GetPos() - phys:GetPos()):GetNormalized() * 0.1)
				end
			end
		end

		return true
	end)

	hook.Add("PlayerDeathThink", Tag, function(ply)
		if ply:GetNW2Float("Arcana_SoulGraceUntil", 0) > CurTime() then return end

		if ply.ArcanaSoulSpawnPos then
			local rag = ply:GetRagdollEntity()
			rag = rag and rag:IsValid() and rag or nil
			local pos = rag and rag:GetPos() or ply.ArcanaSoulSpawnPos

			if rag then
				for i = 0, rag:GetPhysicsObjectCount() - 1 do
					local phys = rag:GetPhysicsObjectNum(i)
					phys:EnableGravity(false)
				end
			end

			local soul = ents.Create("arcana_soul")
			soul:SetPos(pos)
			soul:Spawn()

			if soul.CPPISetOwner then
				soul:CPPISetOwner(ply)
			end

			ply:CallOnRemove("Arcana_SoulEnt", function()
				SafeRemoveEntity(soul)
			end)

			ply:SetOwner(soul)
			ply:SetNW2Entity("Arcana_SoulEnt", soul)
			ply.ArcanaSoulSpawnPos = nil
		end

		ply:SetDSP(130)

		if not ply:KeyDown(IN_ATTACK) or ply:KeyDown(IN_JUMP) then
			ply:SetMoveType(MOVETYPE_WALK)

			return false
		end
	end)
end

if CLIENT then
	hook.Add("EntityEmitSound", Tag, function(data)
		local ply = LocalPlayer()

		if not ply:Alive() then
			if ply:GetNW2Float("Arcana_SoulGraceUntil", 0) > CurTime() then return end
			local ent = ply:GetNW2Entity("Arcana_SoulEnt")

			if ent:IsValid() then
				data.Pitch = data.Pitch * 0.5

				return true
			end
		end
	end)

	hook.Add("CalcView", Tag, function(ply)
		if not ply:Alive() then
			if ply:GetNW2Float("Arcana_SoulGraceUntil", 0) > CurTime() then return end
			local ent = ply:GetNW2Entity("Arcana_SoulEnt")

			if ent:IsValid() then
				local ang = ply:EyeAngles()
				local aim = ang:Forward()
				local pos = ent:GetPos() + aim * -100

				local data = util.TraceLine({
					start = ent:GetPos(),
					endpos = pos,
					filter = ents.FindInSphere(ent:GetPos(), ent:BoundingRadius()),
					mask = MASK_VISIBLE,
				})

				if data.Hit and data.Entity ~= ply and not data.Entity:IsPlayer() and not data.Entity:IsVehicle() then
					pos = data.HitPos + aim * 5
				end

				return {
					origin = pos,
					fov = 50,
					angles = ang,
				}
			end
		end
	end)

	local emitter = ParticleEmitter(EyePos())
	emitter:SetNoDraw(true)
	local ambientSound
	local windupSound

	-- simple vignette using gradient material
	local grad_mat = Material("vgui/gradient-u")
	local function DrawVignette(intensity, col)
		if intensity <= 0 then return end
		local w, h = ScrW(), ScrH()
		surface.SetMaterial(grad_mat)
		surface.SetDrawColor(col.r, col.g, col.b, 180 * intensity)

		-- top
		surface.DrawTexturedRect(0, 0, w, h * 0.1)

		-- bottom (rotate by drawing flipped)
		surface.DrawTexturedRectRotated(w * 0.5, h - (h * 0.05), w, h * 0.1, 180)

		-- left/right using rotation
		surface.DrawTexturedRectRotated(w * 0.025, h * 0.5, h, w * 0.1, 90)
		surface.DrawTexturedRectRotated(w * 0.975, h * 0.5, h, w * 0.1, 270)
	end

	hook.Add("PrePlayerDraw", Tag, function(ply)
		if not ply:Alive() then return true end
	end)

	local COLOR_BLACK = Color(0, 0, 0, 255)
	hook.Add("RenderScreenspaceEffects", Tag, function()
		for _, ply in ipairs(player.GetAll()) do
			if ply:GetNW2Float("Arcana_SoulGraceUntil", 0) > CurTime() then continue end

			local ent = ply:GetNW2Entity("Arcana_SoulEnt")
			if not ent:IsValid() then continue end

			ply:SetPos(ent:GetPos() - Vector(0, 0, ply:BoundingRadius() + 15))
			ply:SetupBones()

			ent.Color = ply:GetWeaponColor():ToColor()
		end

		if not LocalPlayer():Alive() then
			ambientSound = ambientSound or CreateSound(LocalPlayer(), "ambient/levels/citadel/citadel_hub_ambience1.mp3")
			ambientSound:Play()
			ambientSound:SetDSP(1)
			ambientSound:ChangePitch(100 + math.sin(RealTime() / 5) * 5)
			local time = LocalPlayer():GetNW2Float("Arcana_SoulGraceUntil", 0) - CurTime()
			local f = time
			f = -math.Clamp(f / SOUL_GRACE_SECS, 0, 1) + 1
			f = f ^ 5
			ambientSound:ChangeVolume(f ^ 5)

			if f == 1 then
				cam.Start3D()
				emitter:Draw()
				cam.End3D()
			end

			DrawToyTown(2 * f, 500)
			windupSound = windupSound or CreateSound(LocalPlayer(), "ambient/levels/labs/teleport_mechanism_windup5.wav")
			windupSound:PlayEx(1, 255)
			windupSound:ChangeVolume(f)
			windupSound:ChangePitch(math.min(100 + f * 255, 255))

			if f == 1 then
				windupSound:Stop()
			end

			if f < 0.99 then
				DrawColorModify({
					["$pp_colour_brightness"] = f * 0.5,
					["$pp_colour_contrast"] = 1 + f * 1,
				})
			end

			local tbl = {}
			tbl["$pp_colour_addr"] = 0.1
			tbl["$pp_colour_addg"] = 0.1
			tbl["$pp_colour_addb"] = 0.1
			tbl["$pp_colour_brightness"] = -0.2 * f
			tbl["$pp_colour_contrast"] = Lerp(f, 1, 0.9)
			tbl["$pp_colour_colour"] = 1
			tbl["$pp_colour_mulr"] = 0
			tbl["$pp_colour_mulg"] = 0
			tbl["$pp_colour_mulb"] = 0
			DrawColorModify(tbl)
			DrawSharpen(math.sin(RealTime() * 5 + math.random() * 0.1) * 10 * f, 0.1 * f)

			for i = 1, 5 do
				local particle = emitter:Add("particle/fire", EyePos() + VectorRand() * 500)

				if particle then
					local col = HSVToColor(math.random() * 30, 0.1, 1)
					particle:SetColor(col.r, col.g, col.b, 266)
					particle:SetVelocity(VectorRand())
					particle:SetDieTime((math.random() + 4) * 3)
					particle:SetLifeTime(0)
					particle:SetAngles(AngleRand())
					particle:SetStartSize(1)
					particle:SetEndSize(0)
					particle:SetStartAlpha(0)
					particle:SetEndAlpha(255)
					particle:SetStartLength(particle:GetStartSize())
					particle:SetEndLength(math.random(50, 250))
					particle:SetAirResistance(500)
					particle:SetGravity(VectorRand() * 10 + Vector(0, 0, 200))
				end
			end

			-- draw vignette last for framing
			DrawVignette(100 * f, COLOR_BLACK)

			DrawBloom(0.6, 1.2 * f, 11.21, 9, 2, 1.96, 1, 1, 1)
			DrawMotionBlur(math.sin(RealTime() * 10) * 0.2 + 0.4, 0.5 * f, 0)
		else
			if ambientSound then
				ambientSound:Stop()
			end

			if windupSound then
				windupSound:Stop()
			end
		end
	end)
end