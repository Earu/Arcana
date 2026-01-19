-- Phoenix Form: Transforms the caster into a fiery bird with flight and fire attacks
if SERVER then
    util.AddNetworkString("Arcana_Phoenix_Start")
    util.AddNetworkString("Arcana_Phoenix_Stop")
end

local PHX_DURATION = 24.0
local PHX_SPEED = 1200
local PHX_TURN_RATE = 360 -- degrees per second target turn rate for the bird model
local PHX_WEAPON = "arcana_phoenix"

-- Hook lifecycle so we don't leave global command overrides when no one is transformed
local PHX_HOOKS_INSTALLED = false
local PHX_ACTIVE_COUNT = 0

local function installPhoenixHooks()
    if PHX_HOOKS_INSTALLED then return end
    PHX_HOOKS_INSTALLED = true
end

local function removePhoenixHooks()
    -- Leave hooks resident; they early-return when inactive.
    PHX_HOOKS_INSTALLED = false
end

local function isPhoenixActive(ply)
	if not IsValid(ply) then return false end

	local st = ply._ArcanaPhoenix
	return istable(st) and st.untilT and CurTime() < st.untilT
end

local function cleanupPhoenix(ply, reason)
	if not IsValid(ply) then return end

	local st = ply._ArcanaPhoenix
	if not istable(st) then return end

	-- Remove hooks if needed statefully handled globally; here just clear player state
    if IsValid(st.bird) then
        st.bird:Remove()
    end

	-- Restore defaults
    if st.oldMoveType then
        ply:SetMoveType(st.oldMoveType)
    end

    if st.oldGravity ~= nil then
        ply:SetGravity(st.oldGravity)
    end

	ply:SetNoDraw(false)
	ply:GodDisable()
	-- Keep a handle to state for counters before clearing
	local stActive = st and st.__active or false
	ply._ArcanaPhoenix = nil

    -- Strip phoenix weapon and restore previous weapon if possible
    if SERVER then
        if ply.StripWeapon then ply:StripWeapon(PHX_WEAPON) end
        local prev = (istable(st) and st.prevWeaponClass) or nil
        if prev and ply.HasWeapon and ply:HasWeapon(prev) then
            ply:SelectWeapon(prev)
        end
    end

    if SERVER then
		net.Start("Arcana_Phoenix_Stop", true)
		net.WriteEntity(ply)
		net.Broadcast()

        -- Stop hard expiry timer
        local key = "Arcana_Phoenix_Expire_" .. tostring(ply:EntIndex())
        timer.Remove(key)

        -- Decrement active count and remove hooks if none left
        if stActive then
            PHX_ACTIVE_COUNT = math.max(0, PHX_ACTIVE_COUNT - 1)
        end
        if PHX_ACTIVE_COUNT <= 0 then
            removePhoenixHooks()
        end
	end

    if CLIENT and ply == LocalPlayer() then
        hook.Remove("CalcView", "Arcana_Phoenix_Cam")
    end
end

if SERVER then
    -- Movement: fast flight with WASD; aim controls facing
    hook.Add("SetupMove", "Arcana_Phoenix_SetupMove", function(ply, mv, cmd)
        -- Handle expiry and only proceed if state exists
        local st = ply._ArcanaPhoenix
        if not st then return end

        if st.untilT and CurTime() >= st.untilT then
            cleanupPhoenix(ply, "expired")
            return
        end

        -- Smooth flight with collisions (use MOVETYPE_FLY) and WASD steering aligned to view
        if ply:GetMoveType() ~= MOVETYPE_FLY then
            ply:SetMoveType(MOVETYPE_FLY)
        end

        local speed = PHX_SPEED * ((cmd and cmd:KeyDown(IN_SPEED)) and 1.8 or 1.0)
        mv:SetMaxClientSpeed(speed)
        mv:SetMaxSpeed(speed)

        local aim = mv.GetMoveAngles and mv:GetMoveAngles() or mv:GetAngles()
		local fwd = aim:Forward()
		local right = aim:Right()
        local wish = fwd * (mv:GetForwardSpeed() / 10000) + right * (mv:GetSideSpeed() / 10000)
        local cur = mv:GetVelocity()
        local dt = engine.TickInterval()

        -- Vertical control via Space (up) and Ctrl (down)
        local climb = 0
        if cmd and cmd:KeyDown(IN_JUMP) then climb = climb + 1 end
        if cmd and cmd:KeyDown(IN_DUCK) then climb = climb - 1 end
        wish.z = climb * (speed * 0.8)
        if wish:LengthSqr() > 0 then
            wish:Normalize()
            wish = wish * speed
            local blend = math.Clamp(8 * dt, 0, 1)
            local new = (cur + (wish - cur) * blend)
            mv:SetVelocity(new)
        else
            -- Apply gentle friction when no input for smoother stop
            local friction = math.Clamp(6 * dt, 0, 1)
            mv:SetVelocity(cur * (1 - friction))
        end

        -- Prevent ground locking while flying
        if ply.SetGroundEntity then ply:SetGroundEntity(NULL) end

		-- Keep bird entity aligned to player position and view direction
		local bird = st.bird
        if IsValid(bird) then
            local pos = ply:EyePos() + aim:Forward() * 80 + aim:Up() * -12
			bird:SetPos(pos)
			-- Smoothly turn bird to aim yaw
            local target = Angle(0, aim.y, 0)
            local curAng = bird:GetAngles()
            local newYaw = math.ApproachAngle(curAng.y, target.y, PHX_TURN_RATE * dt)
			bird:SetAngles(Angle(0, newYaw, 0))
		end
		-- Extend duration keepalive if needed (no)
		-- Enforce phoenix weapon selection
		if ply.SelectWeapon and ply.HasWeapon and ply.Give then
			if not ply:HasWeapon(PHX_WEAPON) then
				ply:Give(PHX_WEAPON)
			end
			local aw = ply.GetActiveWeapon and ply:GetActiveWeapon()
			if (not IsValid(aw)) or aw:GetClass() ~= PHX_WEAPON then
				ply:SelectWeapon(PHX_WEAPON)
			end
		end
	end)

    hook.Add("PlayerSwitchWeapon", "Arcana_Phoenix_BlockSwitch", function(ply, oldWep, newWep)
        local st = ply and ply._ArcanaPhoenix
        if not st then return end
        if not IsValid(newWep) then return true end

        if newWep:GetClass() ~= PHX_WEAPON then
            -- Re-select phoenix weapon immediately
            timer.Simple(0, function()
                if IsValid(ply) and ply.SelectWeapon then ply:SelectWeapon(PHX_WEAPON) end
            end)
            return true
        end
    end)

    hook.Add("PlayerCanPickupWeapon", "Arcana_Phoenix_BlockPickup", function(ply, wep)
        local st = ply and ply._ArcanaPhoenix
        if not st then return end
        if not IsValid(wep) then return false end
        if wep:GetClass() ~= PHX_WEAPON then return false end
    end)

    -- Safety cleanup
    hook.Add("PlayerDeath", "Arcana_Phoenix_Cleanup", function(ply)
		if ply._ArcanaPhoenix then cleanupPhoenix(ply, "death") end
	end)

    hook.Add("PlayerDisconnected", "Arcana_Phoenix_Cleanup", function(ply)
		if ply and ply._ArcanaPhoenix then cleanupPhoenix(ply, "leave") end
	end)

    hook.Add("PlayerSpawn", "Arcana_Phoenix_Cleanup", function(ply)
        if ply and ply._ArcanaPhoenix then cleanupPhoenix(ply, "spawn_reset") end
    end)

    installPhoenixHooks()
end

-- Spell registration
Arcane:RegisterSpell({
	id = "phoenix",
	name = "Phoenix",
	description = "Transform into a blazing phoenix for 24s. Fly swiftly, unleash fireball salvos (LMB) and deadly firebreath (RMB).",
	category = Arcane.CATEGORIES.COMBAT,
	level_required = 40,
	knowledge_cost = 5,
	cooldown = 60.0,
	cost_type = Arcane.COST_TYPES.COINS,
	cost_amount = 550000,
	cast_time = 1.0,
	range = 0,
	icon = "icon16/fire.png",
	is_divine_pact = true,
	is_projectile = false,
	has_target = false,
	cast_anim = "forward",
	can_cast = function(caster)
		if isPhoenixActive(caster) then return false, "Already in Phoenix" end
		return true
	end,
	cast = function(caster)
		if CLIENT then return true end
		if not IsValid(caster) then return false end

        -- Create or replace existing state
		local st = caster._ArcanaPhoenix or {}
		caster._ArcanaPhoenix = st
		st.untilT = CurTime() + PHX_DURATION
		st.nextPrimary = 0
		st.nextFlame = 0
		st.oldMoveType = caster:GetMoveType()
        st.oldGravity = caster:GetGravity()
        if not st.__active then
            st.__active = true
            PHX_ACTIVE_COUNT = PHX_ACTIVE_COUNT + 1
        end

		-- Spawn our phoenix (HL2 pigeon repurposed)
		if IsValid(st.bird) then st.bird:Remove() end
		local bird = ents.Create("prop_dynamic")
		if not IsValid(bird) then return false end
		local origin = caster:GetPos() + Vector(0, 0, 40)
		bird:SetModel("models/pigeon.mdl")
		bird:SetPos(origin)
		bird:SetAngles(Angle(0, caster:EyeAngles().y, 0))
		bird:Spawn()
		bird:SetCollisionGroup(COLLISION_GROUP_WEAPON)
		bird:SetColor(Color(255, 140, 60, 255))
		bird:SetMaterial("models/debug/debugwhite")
		bird:ResetSequence("fly")
        bird:SetPlaybackRate(1.2)
        bird:SetModelScale(10, 0)
        bird:SetParent(caster)
		bird:SetNWBool("ArcanaPhoenixBird", true)
		bird:SetNWEntity("ArcanaPhoenixOwner", caster)
		st.bird = bird

		-- Player presentation
        caster:SetNoDraw(true)
        caster:SetMoveType(MOVETYPE_FLY)
        caster:SetGravity(0)
		caster:GodEnable()

        -- Equip phoenix weapon (non-spawnable)
        if caster.Give and caster.SelectWeapon then
            -- Store previous weapon to restore after
            local curwep = caster.GetActiveWeapon and caster:GetActiveWeapon()
            if IsValid(curwep) and curwep:GetClass() then
                st.prevWeaponClass = curwep:GetClass()
            end
            timer.Simple(0, function()
                if not IsValid(caster) then return end
                caster:Give(PHX_WEAPON)
                caster:SelectWeapon(PHX_WEAPON)
            end)
        end

        -- Opening VFX/SFX: reuse ring_of_fire visuals
		net.Start("Arcana_RingOfFire_VFX", true)
		net.WriteVector(origin)
		net.WriteFloat(500)
		net.WriteFloat(0.8)
		net.Broadcast()
		caster:EmitSound("ambient/fire/gascan_ignite1.wav", 75, 105)
		sound.Play("ambient/fire/mtov_flame2.wav", origin, 70, 100)

        -- Inform clients to attach local VFX
		net.Start("Arcana_Phoenix_Start", true)
		net.WriteEntity(caster)
		net.WriteEntity(bird)
		net.WriteFloat(PHX_DURATION)
		net.Broadcast()

        -- Hard expiry timer as a fallback in case no inputs occur
        local key = "Arcana_Phoenix_Expire_" .. tostring(caster:EntIndex())
        timer.Remove(key)
        timer.Create(key, PHX_DURATION + 0.05, 1, function()
            if not IsValid(caster) then return end
            if isPhoenixActive(caster) then cleanupPhoenix(caster, "expired_timer") end
        end)

        installPhoenixHooks()
		return true
	end,
	trigger_phrase_aliases = {
		"phoenix",
		"bird of fire",
	}
})

if CLIENT then
	-- Lightweight clientside embers/heat shimmer trailing the phoenix bird and hide viewmodel hands
	local active = {}
    local fullbrightMat = Material("models/debug/debugwhite")

	net.Receive("Arcana_Phoenix_Start", function()
		local ply = net.ReadEntity()
		local bird = net.ReadEntity()
		local life = net.ReadFloat() or 30
		if not IsValid(ply) then return end

		active[ply] = { untilT = CurTime() + life, bird = bird, emitter = ParticleEmitter(ply:EyePos()) }
		if ply == LocalPlayer() then
			local wep = ply:GetActiveWeapon()
			if IsValid(wep) and wep.DrawViewModel ~= nil then
				wep:DrawViewModel(false)
			end
		end
	end)

	net.Receive("Arcana_Phoenix_Stop", function()
		local ply = net.ReadEntity()
		if not IsValid(ply) then return end

		local st = active[ply]
			if st then
				if st.emitter then st.emitter:Finish() end
				if st.auraEmitter then st.auraEmitter:Finish() end
			end

		active[ply] = nil

		if ply == LocalPlayer() then
			local wep = ply:GetActiveWeapon()
			if IsValid(wep) and wep.DrawViewModel ~= nil then
				wep:DrawViewModel(true)
			end
		end
	end)

    -- Flamethrower visual moved to weapon file

		hook.Add("Think", "Arcana_Phoenix_ClientFX", function()
		for ply, st in pairs(active) do
			if not IsValid(ply) then active[ply] = nil continue end
			if st.untilT and CurTime() >= st.untilT then
					if st.emitter then st.emitter:Finish() end
					if st.auraEmitter then st.auraEmitter:Finish() end
				active[ply] = nil
				continue
			end

			-- Emit embers and heatwave around bird
			local bird = st.bird
			local pos
			local back
			if IsValid(bird) then
                pos = bird:GetPos() + bird:GetForward() * 16
                back = -bird:GetForward()
			else
				pos = ply:EyePos()
				back = -ply:EyeAngles():Forward()
			end

				-- Fullbright fiery render override & emissive sprites
            if IsValid(bird) and bird:GetNWBool("ArcanaPhoenixBird", false) then
                if not bird._ArcanaRenderHooked then
                    bird._ArcanaRenderHooked = true
                    local oldRO = bird.RenderOverride
                    bird.RenderOverride = function(self)
                        render.SuppressEngineLighting(true)
                        render.SetColorModulation(1, 0.6, 0.25)
                        render.SetBlend(1)
                        self:SetMaterial("models/debug/debugwhite")
                        self:DrawModel()
                        -- Add a couple of additive glow sprites near head/body
                        local head = self:LookupBone("ValveBiped.Bip01_Head1") or -1
                        local headPos = self:GetPos()
                        if head ~= -1 then
                            local m = self:GetBoneMatrix(head)
                            if m then headPos = m:GetTranslation() end
                        end
                        cam.Start3D(EyePos(), EyeAngles())
                        render.SetMaterial(Material("sprites/light_glow02_add"))
                        render.DrawSprite(headPos + self:GetForward() * 6, 48, 48, Color(255, 160, 60, 220))
                        render.DrawSprite(self:WorldSpaceCenter(), 72, 72, Color(255, 120, 40, 200))
                        cam.End3D()
                        self:SetMaterial("")
                        render.SetBlend(1)
                        render.SetColorModulation(1, 1, 1)
                        render.SuppressEngineLighting(false)
                        if oldRO then oldRO(self) end
                    end
                    self = bird
                    bird:CallOnRemove("ArcanaPhoenix_ClearRO", function(ent)
                        ent.RenderOverride = nil
                    end)
                end
            end

				-- Dynamic light aura
				if IsValid(bird) then
					local dl = DynamicLight(bird:EntIndex())
					if dl then
						dl.pos = bird:WorldSpaceCenter()
						dl.r = 255
						dl.g = 140
						dl.b = 60
						dl.brightness = 3.2
						dl.Decay = 1200
						dl.Size = 420
						dl.DieTime = CurTime() + 0.1
					end
				end

            -- Simple over-the-shoulder camera: offset the local player's view when transforming
            if ply == LocalPlayer() and IsValid(bird) then
            local view = {
                origin = pos - back * 200 + Vector(0, 0, 70),
                angles = bird:GetAngles(),
                fov = 90,
                drawviewer = true,
            }
                hook.Add("CalcView", "Arcana_Phoenix_Cam", function(_ply, origin, angles, fov)
                    if not IsValid(_ply) or _ply ~= ply then return end
                    if CurTime() > (st.untilT or 0) or not IsValid(bird) then
                        hook.Remove("CalcView", "Arcana_Phoenix_Cam")
                        return
                    end

                    -- Recompute dynamically to follow bird
                    local curPos = bird:GetPos() + bird:GetForward() * 16
                    local curBack = -bird:GetForward()
                    view.origin = curPos - curBack * 200 + Vector(0, 0, 70)
                    view.angles = bird:GetAngles()
                    view.fov = 90
                    view.drawviewer = true
                    return view
                end)
            end

			st.emitter = st.emitter or ParticleEmitter(pos)
			local em = st.emitter
			if not em then continue end

			-- Multiple trailing paths: attach to wing bones and center
			local offsets = {}
			if IsValid(bird) then
				local boneL = bird:LookupBone("Crow.Phalanges3_L") or bird:LookupBone("ValveBiped.Bip01_L_Forearm")
				local boneR = bird:LookupBone("Crow.Phalanges3_R") or bird:LookupBone("ValveBiped.Bip01_R_Forearm")
				local posL, posR = nil, nil
				if boneL and boneL ~= -1 then local m = bird:GetBoneMatrix(boneL) if m then posL = m:GetTranslation() end end
				if boneR and boneR ~= -1 then local m = bird:GetBoneMatrix(boneR) if m then posR = m:GetTranslation() end end
				offsets[#offsets + 1] = pos
				if posL then offsets[#offsets + 1] = posL end
				if posR then offsets[#offsets + 1] = posR end
			else
				offsets = { pos }
			end

			for _, tpos in ipairs(offsets) do
                -- Embers (match fireball style)
                for i = 1, 2 do
                    local p = em:Add("effects/yellowflare", tpos + VectorRand() * 3)
                    if p then
                        p:SetVelocity(back * (70 + math.random(0, 50)) + VectorRand() * 20)
                        p:SetDieTime(0.4 + math.Rand(0.1, 0.3))
                        p:SetStartAlpha(220)
                        p:SetEndAlpha(0)
                        p:SetStartSize(5 + math.random(0, 3))
                        p:SetEndSize(0)
                        p:SetRoll(math.Rand(0, 360))
                        p:SetRollDelta(math.Rand(-3, 3))
                        p:SetColor(255, 160 + math.random(0, 40), 60)
                        p:SetLighting(false)
                        p:SetAirResistance(60)
                        p:SetGravity(Vector(0, 0, -50))
                        p:SetCollide(false)
                    end
                end

                -- Fire cloud/smoke puffs
                local mat = (math.random() < 0.5) and "effects/fire_cloud1" or "effects/fire_cloud2"
                local p = em:Add(mat, tpos)
                if p then
                    p:SetVelocity(back * (50 + math.random(0, 30)) + VectorRand() * 10)
                    p:SetDieTime(0.5 + math.Rand(0.2, 0.5))
                    p:SetStartAlpha(180)
                    p:SetEndAlpha(0)
                    p:SetStartSize(12 + math.random(0, 10))
                    p:SetEndSize(30 + math.random(0, 12))
                    p:SetRoll(math.Rand(0, 360))
                    p:SetRollDelta(math.Rand(-1, 1))
                    p:SetColor(255, 120 + math.random(0, 60), 40)
                    p:SetLighting(false)
                    p:SetAirResistance(70)
                    p:SetGravity(Vector(0, 0, 20))
                    p:SetCollide(false)
                end
            end

            -- Surrounding fire aura particles (ring around body)
            if IsValid(bird) then
                st.auraEmitter = st.auraEmitter or ParticleEmitter(pos)
                local aem = st.auraEmitter
                if aem then
                    st._nextAura = st._nextAura or 0
                    local now = CurTime()
                    if now >= st._nextAura then
                        st._nextAura = now + (1 / 30)
                        local right = bird:GetRight()
                        local up = bird:GetUp()
                        local radius = 48
                        for i = 1, 6 do
                            local ang = (i / 6) * math.pi * 2 + now * 1.5
                            local rvec = right * math.cos(ang) + up * math.sin(ang)
                            local ppos = pos + rvec * radius + VectorRand() * 4
                            local mat = (math.random() < 0.5) and "effects/fire_cloud1" or "effects/fire_cloud2"
                            local p = aem:Add(mat, ppos)
                            if p then
                                p:SetVelocity(rvec * 40 + VectorRand() * 20)
                                p:SetDieTime(0.4 + math.Rand(0.2, 0.3))
                                p:SetStartAlpha(180)
                                p:SetEndAlpha(0)
                                p:SetStartSize(14 + math.random(0, 8))
                                p:SetEndSize(36 + math.random(0, 12))
                                p:SetRoll(math.Rand(0, 360))
                                p:SetRollDelta(math.Rand(-1, 1))
                                p:SetColor(255, 120 + math.random(0, 60), 40)
                                p:SetLighting(false)
                                p:SetAirResistance(70)
                                p:SetGravity(Vector(0, 0, 10))
                                p:SetCollide(false)
                            end
                        end
                    end
                end
            end

            -- Heat shimmer core
            local hw = em:Add("sprites/heatwave", pos)
            if hw then
                hw:SetVelocity(VectorRand() * 10)
                hw:SetDieTime(0.25)
                hw:SetStartAlpha(180)
                hw:SetEndAlpha(0)
                hw:SetStartSize(18)
                hw:SetEndSize(0)
                hw:SetRoll(math.Rand(0, 360))
                hw:SetRollDelta(math.Rand(-1, 1))
                hw:SetLighting(false)
            end

			-- Occasional ground scorch when near ground
			if math.random() < 0.05 then
				local tr = util.TraceLine({ start = pos + Vector(0, 0, 32), endpos = pos - Vector(0, 0, 96), mask = MASK_SOLID_BRUSHONLY })
				if tr.Hit then
					util.Decal("Scorch", tr.HitPos + tr.HitNormal * 4, tr.HitPos - tr.HitNormal * 8)
				end
			end
		end
	end)
end


