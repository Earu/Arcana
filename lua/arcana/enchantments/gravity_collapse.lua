-- Gravity Collapse: on detonation the projectile tears a short-lived arcane vortex
-- that yanks nearby actors toward its center for 2.5 seconds, dealing light dissolve
-- damage per tick. When the vortex collapses it bursts outward, shoving and damaging
-- everything caught inside. One active vortex per player at a time.

local ARCANE_COLOR = Color(142, 120, 225)

if SERVER then
	util.AddNetworkString("Arcana_GravityCollapse")
end

local VORTEX_DURATION = 2.5
local VORTEX_RADIUS   = 250
local PULL_INTERVAL   = 0.15
local TICK_DAMAGE     = 8
local COLLAPSE_DAMAGE = 35
local PULL_FORCE      = 200

-- One active vortex per player; new detonation replaces the old one.
local activeTimers = {}

local function collapseVortex(owner, pos)
	for _, ent in ipairs(ents.FindInSphere(pos, VORTEX_RADIUS * 0.7)) do
		if not IsValid(ent) or ent == owner then continue end
		if ent:CreatedByMap() then continue end

		local pushDir = (ent:GetPos() - pos):GetNormalized()

		local phys = ent:GetPhysicsObject()
		if IsValid(phys) then
			phys:ApplyForceCenter(pushDir * 30000)
		end

		local isActor = ent:IsPlayer() or ent:IsNPC() or (ent.IsNextBot and ent:IsNextBot())
		if isActor then
			ent:SetVelocity(pushDir * 420)
			ent:SetGroundEntity(NULL)
		end
	end

	Arcana:BlastDamage(owner, pos, VORTEX_RADIUS * 0.7, COLLAPSE_DAMAGE, {
		damageType = bit.bor(DMG_DISSOLVE, DMG_ENERGYBEAM),
		ignoreAttacker = true,
	})

	local ed = EffectData()
	ed:SetOrigin(pos)
	util.Effect("cball_explode", ed, true, true)

	sound.Play("weapons/physcannon/energy_disintegrate4.wav", pos, 80, 80)
end

local function spawnVortex(owner, pos)
	local oldTimer = activeTimers[owner]
	if oldTimer then timer.Remove(oldTimer) end

	local timerName = string.format("Arcana_GravCollapse_%d", owner:EntIndex())
	activeTimers[owner] = timerName

	local endTime  = CurTime() + VORTEX_DURATION
	local tickNum  = 0

	sound.Play("weapons/physcannon/superphys_small_zap1.wav", pos, 80, 65)

	net.Start("Arcana_GravityCollapse", true)
	net.WriteVector(pos)
	net.WriteFloat(VORTEX_DURATION)
	net.Broadcast()

	timer.Create(timerName, PULL_INTERVAL, math.ceil(VORTEX_DURATION / PULL_INTERVAL) + 1, function()
		if not IsValid(owner) then timer.Remove(timerName); activeTimers[owner] = nil; return end

		if CurTime() >= endTime then
			collapseVortex(owner, pos)
			timer.Remove(timerName)
			activeTimers[owner] = nil
			return
		end

		tickNum = tickNum + 1

		for _, ent in ipairs(ents.FindInSphere(pos, VORTEX_RADIUS)) do
			if not IsValid(ent) or ent == owner then continue end
			if ent:CreatedByMap() then continue end

			local entPos = ent:GetPos()
			local delta  = pos - entPos
			local dist   = delta:Length()
			if dist < 1 then continue end

			local pullDir  = delta / dist
			local strength = math.Clamp(1 - dist / VORTEX_RADIUS, 0.15, 1) * PULL_FORCE

			local phys = ent:GetPhysicsObject()
			if IsValid(phys) then
				phys:ApplyForceCenter(pullDir * strength * phys:GetMass())
			end

			local isActor = ent:IsPlayer() or ent:IsNPC() or (ent.IsNextBot and ent:IsNextBot())
			if isActor then
				ent:SetVelocity(pullDir * strength * 0.5)
				ent:SetGroundEntity(NULL)
			end

			if isActor and tickNum % 3 == 0 then
				local dmg = DamageInfo()
				dmg:SetDamage(TICK_DAMAGE)
				dmg:SetDamageType(DMG_DISSOLVE)
				dmg:SetAttacker(owner)
				dmg:SetInflictor(owner)
				dmg:SetDamagePosition(ent:WorldSpaceCenter())
				ent:TakeDamageInfo(dmg)
			end
		end
	end)
end

Arcana:RegisterEnchantment({
	id = "gravity_collapse",
	name = "Gravity Collapse",
	description = "Your projectile tears open a short-lived arcane vortex on impact, pulling nearby enemies inward. When it collapses everything caught inside is blasted outward.",
	cost_coins = 2200,
	cost_items = {
		{ name = "mana_crystal_shard", amount = 90 },
	},
	can_apply = function(ply, wep)
		return Arcana.Common.GetWeaponClassification(wep) == "PROJECTILE"
	end,
	on_projectile_fired = function(ply, wep, proj, state)
		proj:CallOnRemove("Arcana_GravCollapse_Fire", function(e)
			if not IsValid(ply) then return end
			spawnVortex(ply, e:GetPos())
		end)
	end,
})

if CLIENT then
	local glowMat  = Material("sprites/light_glow02_add")
	local flareMat = Material("effects/blueflare1")

	local activeVortices = {}

	net.Receive("Arcana_GravityCollapse", function()
		local pos      = net.ReadVector()
		local duration = net.ReadFloat()

		table.insert(activeVortices, {
			pos      = pos,
			birth    = CurTime(),
			dieTime  = CurTime() + duration,
			duration = duration,
			emitter  = ParticleEmitter(pos),
			nextPfx  = 0,
		})
	end)

	hook.Add("Think", "Arcana_GravityCollapse_Particles", function()
		local now = CurTime()

		for i = #activeVortices, 1, -1 do
			local v = activeVortices[i]

			if now >= v.dieTime then
				-- Collapse burst: outward shower of arcane sparks
				if v.emitter then
					for j = 1, 30 do
						local p = v.emitter:Add("effects/blueflare1", v.pos + VectorRand() * 6)
						if p then
							p:SetDieTime(math.Rand(0.5, 1.0))
							p:SetStartAlpha(255)
							p:SetEndAlpha(0)
							p:SetStartSize(math.Rand(14, 26))
							p:SetEndSize(0)
							p:SetColor(ARCANE_COLOR.r, ARCANE_COLOR.g, ARCANE_COLOR.b)
							p:SetVelocity(VectorRand() * 280)
							p:SetAirResistance(60)
							p:SetGravity(Vector(0, 0, -50))
						end
					end
					v.emitter:Finish()
				end
				table.remove(activeVortices, i)
				continue
			end

			if not v.emitter then continue end
			if now < v.nextPfx then continue end
			v.nextPfx = now + 0.03

			local elapsed  = now - v.birth
			local lifeNorm = elapsed / v.duration

			-- Inward-spiraling particles from the perimeter
			local count = math.floor(3 + lifeNorm * 5)
			for j = 1, count do
				local angle    = math.random() * math.pi * 2
				local radius   = 130 + math.random(0, 120)
				local spawnPos = v.pos + Vector(math.cos(angle) * radius, math.sin(angle) * radius, math.Rand(-25, 55))

				local toCenter = (v.pos - spawnPos):GetNormalized()
				local tangent  = toCenter:Cross(Vector(0, 0, 1)):GetNormalized()

				local p = v.emitter:Add("effects/blueflare1", spawnPos)
				if p then
					local speed = 110 + math.random(0, 70) + lifeNorm * 50
					p:SetVelocity(toCenter * speed + tangent * (speed * 0.4) + Vector(0, 0, math.Rand(-8, 15)))
					p:SetDieTime(0.35 + math.Rand(0, 0.25))
					p:SetStartAlpha(150 + math.floor(lifeNorm * 70))
					p:SetEndAlpha(0)
					p:SetStartSize(5 + math.random(0, 4) + lifeNorm * 4)
					p:SetEndSize(2)
					p:SetColor(ARCANE_COLOR.r, ARCANE_COLOR.g, ARCANE_COLOR.b)
					p:SetAirResistance(25)
				end
			end

			-- Bright white-violet core flickers
			for j = 1, 2 do
				local cp = v.emitter:Add("effects/blueflare1", v.pos + VectorRand() * 6)
				if cp then
					cp:SetDieTime(0.15 + math.Rand(0, 0.12))
					cp:SetStartAlpha(210)
					cp:SetEndAlpha(0)
					cp:SetStartSize(10 + lifeNorm * 12)
					cp:SetEndSize(3)
					cp:SetColor(255, 230, 255)
					cp:SetVelocity(VectorRand() * 12)
					cp:SetAirResistance(120)
				end
			end

			-- Wisps of dark-purple smoke pulled inward (gives density to the vortex)
			if math.random() < 0.5 + lifeNorm * 0.3 then
				local sAngle = math.random() * math.pi * 2
				local sRadius = 80 + math.random(0, 60)
				local sPos = v.pos + Vector(math.cos(sAngle) * sRadius, math.sin(sAngle) * sRadius, math.Rand(-10, 30))
				local sp = v.emitter:Add("particle/particle_smokegrenade", sPos)
				if sp then
					local toC = (v.pos - sPos):GetNormalized()
					sp:SetVelocity(toC * (70 + lifeNorm * 40))
					sp:SetDieTime(0.4 + math.Rand(0, 0.3))
					sp:SetStartAlpha(30 + math.floor(lifeNorm * 25))
					sp:SetEndAlpha(0)
					sp:SetStartSize(16 + math.random(0, 10))
					sp:SetEndSize(6)
					sp:SetColor(100, 75, 180)
					sp:SetAirResistance(15)
				end
			end
		end
	end)

	-- Central glow sprites that pulse and grow toward collapse
	hook.Add("PostDrawTranslucentRenderables", "Arcana_GravityCollapse_Render", function()
		local now = CurTime()

		for _, v in ipairs(activeVortices) do
			if now >= v.dieTime then continue end

			local elapsed  = now - v.birth
			local lifeNorm = elapsed / v.duration
			local pulse    = 1 + math.sin(elapsed * 8) * 0.2

			render.SetMaterial(flareMat)
			local coreSize = (18 + lifeNorm * 28) * pulse
			render.DrawSprite(v.pos, coreSize, coreSize, Color(255, 240, 255, math.floor(190 * pulse)))

			render.SetMaterial(glowMat)
			local innerGlow = (45 + lifeNorm * 35) * pulse
			render.DrawSprite(v.pos, innerGlow, innerGlow, Color(ARCANE_COLOR.r, ARCANE_COLOR.g, ARCANE_COLOR.b, math.floor(150 * pulse)))

			local outerGlow = (75 + lifeNorm * 30) * pulse
			render.DrawSprite(v.pos, outerGlow, outerGlow, Color(ARCANE_COLOR.r - 40, ARCANE_COLOR.g - 40, ARCANE_COLOR.b, math.floor(55 * pulse)))
		end
	end)

	hook.Add("PostDrawOpaqueRenderables", "Arcana_GravityCollapse_DLight", function()
		local now = CurTime()

		for i, v in ipairs(activeVortices) do
			if now >= v.dieTime then continue end

			local elapsed  = now - v.birth
			local lifeNorm = elapsed / v.duration
			local pulse    = 1 + math.sin(elapsed * 8) * 0.15

			local dlight = DynamicLight(300 + ((i - 1) % 8))
			if dlight then
				dlight.pos        = v.pos
				dlight.r          = ARCANE_COLOR.r
				dlight.g          = ARCANE_COLOR.g
				dlight.b          = ARCANE_COLOR.b
				dlight.brightness = (2.0 + lifeNorm * 1.5) * pulse
				dlight.Decay      = 1000
				dlight.Size       = 260 + math.floor(lifeNorm * 80)
				dlight.DieTime    = now + 0.1
			end
		end
	end)
end
