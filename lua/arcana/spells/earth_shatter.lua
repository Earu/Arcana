if SERVER then
	util.AddNetworkString("Arcana_EarthShatter_VFX")
end

-- Earth Shatter: Smash the ground to send a devastating seismic shockwave
Arcane:RegisterSpell({
	id = "earth_shatter",
	name = "Earth Shatter",
	description = "Smash the ground, fracturing earth in a wide radius and hurling foes away.",
	category = Arcane.CATEGORIES.COMBAT,
	level_required = 17,
	knowledge_cost = 4,
	cooldown = 13.0,
	cost_type = Arcane.COST_TYPES.COINS,
	cost_amount = 180,
	cast_time = 0.9,
	range = 0,
	icon = "icon16/brick.png",
	is_projectile = false,
	has_target = false,
	cast_anim = "becon",
	can_cast = function(caster)
		if caster:InVehicle() then return false, "Cannot cast while in a vehicle" end

		return true
	end,
	cast = function(caster, _, _, ctx)
		if not SERVER then return true end
		local pos = caster:WorldSpaceCenter()
		local radius = 520
		local baseDamage = 180
		local pushPlayer = 420
		local pushProp = 36000

		-- Visual dust ring + rumble
		local ed = EffectData()
		ed:SetOrigin(pos)
		util.Effect("ThumperDust", ed, true, true)
		util.Effect("cball_explode", ed, true, true)
		util.ScreenShake(pos, 8, 80, 0.5, 800)
		caster:EmitSound("physics/concrete/concrete_break2.wav", 80, 95)
		sound.Play("ambient/materials/rock_impact_hard2.wav", pos, 80, 100)
		-- Tell clients to render expanding earthy rings + dust/debris
		net.Start("Arcana_EarthShatter_VFX", true)
		net.WriteVector(pos)
		net.WriteFloat(radius)
		net.Broadcast()

		-- Fracture decals around the caster
		local count = 12
		for i = 1, count do
			local ang = (i / count) * 360 + math.Rand(-6, 6)
			local dir = Angle(0, ang, 0):Forward()
			local p = pos + dir * math.Rand(radius * 0.35, radius * 0.8)
			local tr = util.TraceLine({
				start = p + Vector(0, 0, 64),
				endpos = p - Vector(0, 0, 192),
				mask = MASK_SOLID_BRUSHONLY
			})

			if tr.Hit then
				util.Decal("Scorch", tr.HitPos + tr.HitNormal * 4, tr.HitPos - tr.HitNormal * 8)
			end
		end

		-- Stone eruption: spawn large boulders that burst upward and outward, then despawn
		local rocks = 8
		for i = 1, rocks do
			local ang = (i / rocks) * 360 + math.Rand(-10, 10)
			local dir = Angle(0, ang, 0):Forward()
			local rp = pos + dir * math.Rand(radius * 0.3, radius * 0.85)
			local tr = util.TraceLine({
				start = rp + Vector(0, 0, 64),
				endpos = rp - Vector(0, 0, 192),
				mask = MASK_SOLID_BRUSHONLY
			})

			if tr.Hit then
				local rock = ents.Create("prop_physics")
				if IsValid(rock) then
					-- Use the common rock model but upscale aggressively to sell the impact
					rock:SetModel("models/props_junk/rock001a.mdl")
					rock:SetMaterial("models/props_wasteland/rockcliff02b")
					rock:SetPos(tr.HitPos + tr.HitNormal * 4)
					rock:SetAngles(tr.HitNormal:Angle())
					rock:Spawn()
					-- Upscale to make it a boulder and rebuild physics
					local scale = math.Rand(2.2, 3.6)
					rock:SetModelScale(scale, 0)
					rock:PhysicsInit(SOLID_VPHYSICS)
					rock:SetMoveType(MOVETYPE_VPHYSICS)
					rock:SetSolid(SOLID_VPHYSICS)

					if rock.CPPISetOwner then
						rock:CPPISetOwner(caster)
					end

					local phys = rock:GetPhysicsObject()

					if IsValid(phys) then
						phys:Wake()
						-- Increase effective mass so launches feel weighty
						phys:SetMass(math.max(phys:GetMass() * 1.8, 150))
						phys:ApplyForceCenter(tr.HitNormal * math.Rand(36000, 54000) + dir * math.Rand(42000, 68000))
						phys:AddAngleVelocity(VectorRand() * 400)
					end

					-- Localized dust burst where the rock erupts
					local ed = EffectData()
					ed:SetOrigin(tr.HitPos)
					util.Effect("ThumperDust", ed, true, true)
					-- Leave the boulder for longer to emphasize scale, then clean up
					timer.Simple(18, function()
						if IsValid(rock) then rock:Remove() end
					end)
				end
			end
		end

		-- Damage and knockback
		for _, ent in ipairs(ents.FindInSphere(pos, radius)) do
			if not IsValid(ent) then continue end
			if ent == caster then continue end
			local isActor = ent:IsPlayer() or ent:IsNPC() or (ent.IsNextBot and ent:IsNextBot())
			local to = ent:WorldSpaceCenter() - pos
			local dist = to:Length()
			local dir = dist > 0 and (to / dist) or Vector(0, 0, 0)
			local fall = 0.6 + 0.4 * (1 - math.Clamp(dist / radius, 0, 1))

			if isActor then
				local dmg = DamageInfo()
				dmg:SetDamage(math.floor(baseDamage * fall))
				dmg:SetDamageType(DMG_CLUB)
				dmg:SetAttacker(IsValid(caster) and caster or game.GetWorld())
				dmg:SetInflictor(IsValid(caster) and caster or game.GetWorld())
				ent:TakeDamageInfo(dmg)
				-- Pop upward slightly then out
				if ent.SetVelocity then
					ent:SetVelocity(dir * (pushPlayer * fall) + Vector(0, 0, 180))
				end
			else
				local phys = ent:GetPhysicsObject()

				if IsValid(phys) then
					phys:Wake()
					phys:ApplyForceCenter(dir * (pushProp * fall) + Vector(0, 0, 14000))
				end
			end
		end

		return true
	end,
	trigger_phrase_aliases = {
		"shatter",
		"earthquake",
	}
})


if CLIENT then
	-- Expanding earthy rings + dust/debris
	local matGlow = Material("sprites/light_glow02_add")
	local matRing = Material("effects/select_ring")
	local matBeam = Material("sprites/physbeam")
	local bursts = {}

	local function addBurst(pos, radius, life)
		bursts[#bursts + 1] = {
			pos = pos,
			radius = radius,
			life = life,
			die = CurTime() + life,
		}
	end

	net.Receive("Arcana_EarthShatter_VFX", function()
		local pos = net.ReadVector()
		local radius = net.ReadFloat()
		-- Two earthy rings with different lifetimes
		local r1 = math.max(180, radius * 0.7)
		local r2 = math.max(240, radius)
		addBurst(pos, r1, 0.55)
		addBurst(pos, r2, 0.75)
		-- Dust cloud and rock flecks from the epicenter
		local emitter = ParticleEmitter(pos)

		if emitter then
			-- heavy dust plumes (increase density)
			for i = 1, 72 do
				local ang = (i / 30) * 360
				local dir = Angle(0, ang, 0):Forward()
				local p = emitter:Add("particle/particle_smokegrenade", pos + dir * math.Rand(8, 24) + Vector(0, 0, math.Rand(0, 12)))

				if p then
					p:SetVelocity(dir * math.Rand(180, 320) + Vector(0, 0, math.Rand(90, 160)))
					p:SetDieTime(math.Rand(1.1, 1.8))
					p:SetStartAlpha(170)
					p:SetEndAlpha(0)
					p:SetStartSize(math.Rand(16, 28))
					p:SetEndSize(math.Rand(48, 82))
					p:SetColor(120, 110, 100)
					p:SetAirResistance(80)
					p:SetGravity(Vector(0, 0, 60))
					p:SetCollide(false)
				end
			end

			-- rock/concrete flecks
			for i = 1, 48 do
				local mat = (math.random() < 0.5) and "effects/fleck_cement1" or "effects/fleck_cement2"
				local p = emitter.Add and emitter:Add(mat, pos + VectorRand() * 6)

				if p then
					local dir = Angle(0, (i / 36) * 360, 0):Forward()
					p:SetVelocity(dir * math.Rand(260, 440) + Vector(0, 0, math.Rand(160, 240)))
					p:SetDieTime(math.Rand(0.7, 1.2))
					p:SetStartAlpha(255)
					p:SetEndAlpha(0)
					p:SetStartSize(math.Rand(3, 6))
					p:SetEndSize(0)
					p:SetRoll(math.Rand(0, 360))
					p:SetRollDelta(math.Rand(-10, 10))
					p:SetColor(140, 130, 120)
					p:SetAirResistance(40)
					p:SetGravity(Vector(0, 0, -300))
					p:SetCollide(true)
					p:SetBounce(0.25)
				end
			end

			emitter:Finish()
		end

		-- Spawn local dust columns around the ring perimeter
		local columns = 12
		for i = 1, columns do
			local a = (i / columns) * math.pi * 2
			local p = pos + Vector(math.cos(a) * radius, math.sin(a) * radius, 0)
			local ed2 = EffectData()
			ed2:SetOrigin(p)
			util.Effect("ThumperDust", ed2, true, true)
		end
	end)

	-- Lingering area dust: several short waves of broad smoke across the radius
	timer.Simple(0, function() end) -- ensure timers can be scheduled safely within receive

	local function spawnAreaDust(pos, radius, waves)
		for w = 1, waves do
			timer.Simple(0.06 * w, function()
				local em = ParticleEmitter(pos)

				if not em then return end

				for i = 1, 36 do
					local r = math.Rand(radius * 0.2, radius)
					local a = math.Rand(0, math.pi * 2)
					local p = pos + Vector(math.cos(a) * r, math.sin(a) * r, math.Rand(0, 12))
					local d = em:Add("particle/particle_smokegrenade", p)

					if d then
						d:SetVelocity(VectorRand() * 70 + Vector(0, 0, math.Rand(60, 120)))
						d:SetDieTime(math.Rand(1.2, 2.0))
						d:SetStartAlpha(140)
						d:SetEndAlpha(0)
						d:SetStartSize(math.Rand(18, 30))
						d:SetEndSize(math.Rand(60, 100))
						d:SetColor(120, 110, 100)
						d:SetAirResistance(80)
						d:SetCollide(false)
					end
				end

				em:Finish()
			end)
		end
	end

	hook.Add("PostDrawTranslucentRenderables", "Arcana_EarthShatter_Render", function()
		-- Cull expired
		for i = #bursts, 1, -1 do
			local b = bursts[i]
			if CurTime() > b.die then table.remove(bursts, i) end
		end

		-- Draw rings
		for i = 1, #bursts do
			local b = bursts[i]
			local frac = 1 - (b.die - CurTime()) / b.life
			frac = math.Clamp(frac, 0, 1)
			local curr = Lerp(frac, 20, b.radius)
			local alpha = 210 * (1 - frac)
			-- outer dusty ring
			render.SetMaterial(matRing)
			render.DrawQuadEasy(b.pos + Vector(0, 0, 2), Vector(0, 0, 1), curr, curr, Color(140, 120, 90, math.floor(alpha)), 0)
			-- warm inner glow
			render.SetMaterial(matGlow)
			render.DrawSprite(b.pos + Vector(0, 0, 4), curr * 0.38, curr * 0.38, Color(200, 160, 90, math.floor(alpha * 0.5)))
		end
	end)
end


