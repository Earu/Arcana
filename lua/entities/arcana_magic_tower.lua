AddCSLuaFile()

ENT.Type = "anim"
ENT.Base = "base_gmodentity"

ENT.PrintName = "Magic Tower"
ENT.Author = "Earu"
ENT.Category = "Arcana"
ENT.Spawnable = false
ENT.AdminOnly = false

ENT.RenderGroup = RENDERGROUP_BOTH

-- Tunables
ENT.CannonCost   = 1800                       -- coins per shot (falls back to HP)
ENT.Windup       = 1.0                        -- seconds of charge before the beam fires
ENT.Winddown     = 1.0                        -- seconds of recovery before it can fire again
ENT.BeamDamage   = 250                        -- direct (line) beam damage
ENT.BeamWidth    = 240                         -- full width of the beam core (huge)
ENT.ImpactRadius = 500                         -- radius of the arcane explosion at the beam's impact
ENT.ImpactDamage = 200                         -- AoE damage of the arcane explosion
ENT.BeamMaxDist  = 100000

-- Secondary fire: magic flak bullets (anti-air artillery). Fire rate spools up while held.
ENT.FlakCost         = 25                       -- coins per bullet (falls back to a little HP)
ENT.FlakHealthCost   = 3                         -- HP per bullet when out of coins
ENT.FlakDamage       = 20                        -- direct hit damage per bullet
ENT.FlakBurstRadius  = 110                        -- small flak-burst AoE at each impact
ENT.FlakBurstDamage  = 35
ENT.FlakSpread       = 0                      -- aim cone (0 = perfect)
ENT.FlakMaxDist      = 100000
ENT.FlakSpoolTime    = 1.5                        -- seconds of holding to reach max fire rate
ENT.FlakIntervalSlow = 0.30                       -- seconds between shots when cold
ENT.FlakIntervalFast = 0.06                       -- seconds between shots at full spool
ENT.CannonRadius     = 50                         -- flak muzzle origins scatter across this disc
ENT.BubbleHeight = 64                          -- resting bubble-center height above the base (empty)
ENT.PilotHeight  = 200                         -- bubble-center height once a pilot climbs in
ENT.BubbleRadius = 52                          -- radius of the bubble the pilot floats in
ENT.MuzzleDist   = 58                         -- distance of the cannon circle from the bubble center
ENT.AimLerp      = 0.8                         -- how fast the cannon direction chases the pilot's aim
ENT.FlakAimLerp  = 0.8                        -- slower cannon traverse while firing flak (heavy)
ENT.TowerColor   = Color(150, 120, 255)

-- Pilot lookup key, shared so hooks in both realms can find a player's tower.
local PILOT_KEY = "Arcana_MagicTowerPilot"

function ENT:SetupDataTables()
	self:NetworkVar("Entity", 0, "Pilot")
	self:NetworkVar("Angle", 0, "CannonAngle")
	self:NetworkVar("Int", 0, "FireState") -- 0 idle, 1 windup, 2 winddown
	self:NetworkVar("Float", 0, "BubbleZ") -- current bubble-center height (lerps on enter/exit)
end

-- Shared helper: world-space center of the bubble that holds the pilot.
function ENT:BubbleCenter()
	return self:GetPos() + Vector(0, 0, self:GetBubbleZ())
end

-- Shared helper: world-space origin of the beam / cannon circle.
function ENT:MuzzlePos()
	return self:BubbleCenter() + self:GetCannonAngle():Forward() * self.MuzzleDist
end

-- Shared hooks: keep the held weapon from firing, feed the pilot a swimming animation,
-- and read exit keys. Server-only actions are guarded inside. Registered unconditionally
-- (hook.Add replaces by name) so edits take effect on file reload.
do
	-- Pose the seated pilot as if swimming in place.
	hook.Add("CalcMainActivity", "Arcana_MagicTower_Anim", function(ply, vel)
		local tower = ply:GetNW2Entity(PILOT_KEY)
		if not IsValid(tower) or tower:GetPilot() ~= ply then return end
		return ACT_MP_SWIM, -1
	end)

	-- Capture the fire intent and swallow the keys the pilot shouldn't act on while
	-- seated (attack -> weapon, jump/reload -> side effects, use -> we use it to exit).
	-- Exit is USE only, and only after the key has been released once post-entry, so the
	-- +use that got the pilot in can never immediately eject them.
	hook.Add("SetupMove", "Arcana_MagicTower_SetupMove", function(ply, mv, cmd)
		local tower = ply:GetNW2Entity(PILOT_KEY)
		if not IsValid(tower) or tower:GetPilot() ~= ply then return end

		ply._TowerFire  = cmd:KeyDown(IN_ATTACK)
		ply._TowerFire2 = cmd:KeyDown(IN_ATTACK2)

		local use = cmd:KeyDown(IN_USE)

		if SERVER then
			-- Arm exit only once USE has been released after entering.
			if not use then ply._towerExitArmed = true end
			if ply._towerExitArmed and use and not ply._towerUseDown then
				tower:EjectPilot()
			end
			ply._towerUseDown = use
		end

		cmd:RemoveKey(IN_ATTACK)
		cmd:RemoveKey(IN_ATTACK2)
		cmd:RemoveKey(IN_JUMP)
		cmd:RemoveKey(IN_USE)
		cmd:RemoveKey(IN_RELOAD)
	end)
end

if SERVER then
	util.AddNetworkString("Arcana_MagicTower_Enter")
	util.AddNetworkString("Arcana_MagicTower_Impact")
	util.AddNetworkString("Arcana_MagicTower_Beam")
	util.AddNetworkString("Arcana_MagicTower_Flak")

	function ENT:Initialize()
		self:SetModel("models/hunter/blocks/cube025x025x025.mdl")
		self:PhysicsInit(SOLID_VPHYSICS)
		self:SetMoveType(MOVETYPE_VPHYSICS)
		self:SetSolid(SOLID_VPHYSICS)
		self:SetUseType(SIMPLE_USE)

		local phys = self:GetPhysicsObject()
		if IsValid(phys) then
			phys:Wake()
			phys:EnableMotion(false) -- anchor it so the ritual area stays put
		end

		self:SetCannonAngle(self:GetForward():Angle())
		self:SetFireState(0)
		self:SetBubbleZ(self.BubbleHeight)
		self._fireState = "idle"
		self._stateUntil = 0
	end

	function ENT:SpawnFunction(ply, tr, className)
		if not tr.Hit then return end

		local ent = ents.Create(className)
		if not IsValid(ent) then return end

		ent:SetNWEntity("FallbackOwner", ply)
		ent:SetPos(tr.HitPos + tr.HitNormal * 8)
		ent:Spawn()
		ent:Activate()

		return ent
	end

	-- Deduct one shot's cost: coins first, health otherwise.
	-- Gate on GetCoins rather than TakeCoins' return value — third-party TakeCoins
	-- overrides may not return anything, which would wrongly trigger the health cost.
	function ENT:ChargePilot(ply)
		if not IsValid(ply) then return end

		if Arcana:GetCoins(ply) >= self.CannonCost then
			Arcana:TakeCoins(ply, self.CannonCost, "Magic Tower")
			return
		end

		local takeDamageInfo = ply.ForceTakeDamageInfo or ply.TakeDamageInfo
		local dmg = DamageInfo()
		dmg:SetDamage(self.CannonCost)
		dmg:SetAttacker(ply)
		dmg:SetInflictor(self)
		dmg:SetDamageType(bit.bor(DMG_GENERIC, DMG_DIRECT))
		takeDamageInfo(ply, dmg)
	end

	-- Arcane explosion at the beam's impact — damage + networked visual, all owned by
	-- the tower (the beam only draws itself and deals the direct line hit).
	function ENT:ArcaneExplosion(pos, normal)
		local pilot = self:GetPilot()
		local attacker = IsValid(pilot) and pilot or self

		-- AoE excludes the tower (inflictor) and the pilot (attacker + ignoreAttacker).
		Arcana:BlastDamage(attacker, pos, self.ImpactRadius, self.ImpactDamage, {
			inflictor      = self,
			damageType     = bit.bor(DMG_DISSOLVE, DMG_ENERGYBEAM, DMG_BLAST),
			ignoreAttacker = true,
		})

		util.ScreenShake(pos, 9, 80, 0.6, 1400)
		sound.Play("ambient/energy/whiteflash.wav", pos, 90, 90)
		sound.Play("ambient/explosions/explode_" .. math.random(1, 4) .. ".wav", pos, 95, 105)

		net.Start("Arcana_MagicTower_Impact")
		net.WriteVector(pos)
		net.WriteVector(isvector(normal) and normal or Vector(0, 0, 1))
		net.WriteColor(self.TowerColor, false)
		net.WriteFloat(self.ImpactRadius)
		net.Broadcast()
	end

	function ENT:FireBeam(ply)
		local dir    = self:GetCannonAngle():Forward()
		local muzzle = self:MuzzlePos()

		self:ChargePilot(ply)

		-- Trace from the pilot's eye along the aim so the impact lands on the crosshair,
		-- then draw the beam from the muzzle to that point (converges on where they aim).
		local eye = ply:EyePos()
		local tr = util.TraceLine({
			start  = eye,
			endpos = eye + dir * self.BeamMaxDist,
			filter = { self, ply },
			mask   = MASK_SHOT,
		})

		-- Direct line hit on whatever the beam strikes.
		local hit = tr.Entity
		if IsValid(hit) then
			local dmg = DamageInfo()
			dmg:SetDamage(self.BeamDamage)
			dmg:SetDamageType(bit.bor(DMG_DISSOLVE, DMG_ENERGYBEAM))
			dmg:SetAttacker(ply)
			dmg:SetInflictor(self)
			dmg:SetDamagePosition(tr.HitPos)
			Arcana:TakeDamageInfo(hit, dmg)
		end

		-- Beam visual (owned by the tower for full control over thickness).
		net.Start("Arcana_MagicTower_Beam")
		net.WriteVector(muzzle)
		net.WriteVector(tr.HitPos)
		net.WriteColor(self.TowerColor, false)
		net.WriteFloat(self.BeamWidth)
		net.Broadcast()

		self:ArcaneExplosion(tr.HitPos, tr.HitNormal)

		util.ScreenShake(muzzle, 5, 60, 0.5, 1600)
		self:EmitSound("weapons/physcannon/energy_disintegrate4.wav", 85, 90)
	end

	-- Can the pilot afford one flak bullet (coins, or a little HP to spare)?
	function ENT:CanAffordFlak(ply)
		if not IsValid(ply) then return false end
		return Arcana:GetCoins(ply) >= self.FlakCost or ply:Health() > self.FlakHealthCost
	end

	-- One flak bullet's cost: coins first, otherwise a small chunk of HP.
	function ENT:ChargeFlak(ply)
		if not IsValid(ply) then return end
		if Arcana:GetCoins(ply) >= self.FlakCost then
			Arcana:TakeCoins(ply, self.FlakCost, "Magic Tower Flak")
			return
		end

		local takeDamageInfo = ply.ForceTakeDamageInfo or ply.TakeDamageInfo
		local dmg = DamageInfo()
		dmg:SetDamage(self.FlakHealthCost)
		dmg:SetAttacker(ply)
		dmg:SetInflictor(self)
		dmg:SetDamageType(bit.bor(DMG_GENERIC, DMG_DIRECT))
		takeDamageInfo(ply, dmg)
	end

	-- Fire a single magic flak bullet: hitscan with spread, direct hit + small burst AoE,
	-- networked tracer from the muzzle to the impact.
	function ENT:FireFlak(ply)
		self:ChargeFlak(ply)

		local dir    = self:GetCannonAngle():Forward()
		local muzzle = self:MuzzlePos()

		-- Scatter the visual muzzle origin across the cannon circle face (uniform disc).
		local right = dir:Cross(Vector(0, 0, 1))
		if right:LengthSqr() < 0.0001 then right = dir:Cross(Vector(1, 0, 0)) end
		right:Normalize()
		local up = right:Cross(dir)
		up:Normalize()
		local a   = math.random() * math.pi * 2
		local rad = math.sqrt(math.random()) * self.CannonRadius
		local origin = muzzle + right * (math.cos(a) * rad) + up * (math.sin(a) * rad)

		-- Apply a small cone of spread around the aim.
		local aimDir = (dir + VectorRand() * self.FlakSpread):GetNormalized()

		local eye = ply:EyePos()
		local tr = util.TraceLine({
			start  = eye,
			endpos = eye + aimDir * self.FlakMaxDist,
			filter = { self, ply },
			mask   = MASK_SHOT,
		})

		local hit = tr.Entity
		if IsValid(hit) then
			local dmg = DamageInfo()
			dmg:SetDamage(self.FlakDamage)
			dmg:SetDamageType(bit.bor(DMG_DISSOLVE, DMG_ENERGYBEAM))
			dmg:SetAttacker(ply)
			dmg:SetInflictor(self)
			dmg:SetDamagePosition(tr.HitPos)
			Arcana:TakeDamageInfo(hit, dmg)
		end

		-- Small flak burst at the impact (excludes tower + pilot).
		Arcana:BlastDamage(ply, tr.HitPos, self.FlakBurstRadius, self.FlakBurstDamage, {
			inflictor      = self,
			damageType     = DMG_BLAST,
			ignoreAttacker = true,
		})

		net.Start("Arcana_MagicTower_Flak")
		net.WriteVector(origin)
		net.WriteVector(tr.HitPos)
		net.WriteColor(self.TowerColor, false)
		net.Broadcast()

		-- Reuse the arcane spear sound family (see arcane_spear / arcane_rounds).
		self:EmitSound("arcana/arcane_" .. math.random(1, 3) .. ".ogg", 72, math.random(110, 130), 0.6)
	end

	function ENT:SetPilotPlayer(ply)
		if not IsValid(ply) then return end
		if IsValid(self:GetPilot()) then return end
		if IsValid(ply:GetNW2Entity(PILOT_KEY)) then return end -- already piloting a tower

		self:SetPilot(ply)
		ply:SetNW2Entity(PILOT_KEY, self)

		ply._TowerFire = false
		ply._towerExitArmed = false
		ply._towerUseDown = false
		self._enterTime = CurTime()

		-- Seat the pilot: MOVETYPE_NONE holds them in place (no falling/walking) while
		-- still delivering button + aim input, and predicts as "no movement" so it stays
		-- smooth. The swim animation plays on top.
		ply:SetVelocity(-ply:GetVelocity())
		ply:SetMoveType(MOVETYPE_NONE)
		ply:SetPos(self:BubbleCenter() - Vector(0, 0, ply:OBBMaxs().z * 0.5))

		-- Holster the weapon: hide its worldmodel (Think keeps it hidden + un-fireable,
		-- the viewmodel is suppressed client-side).
		local wep = ply:GetActiveWeapon()
		if IsValid(wep) then
			wep:SetNoDraw(true)
			ply._TowerHiddenWep = wep
		end

		self:EmitSound("ambient/energy/whiteflash.wav", 80, 120)

		net.Start("Arcana_MagicTower_Enter")
		net.WriteEntity(self)
		net.WriteBool(true)
		net.Send(ply)
	end

	function ENT:EjectPilot()
		local ply = self:GetPilot()
		self:SetPilot(NULL)
		self:SetFireState(0)
		self._fireState = "idle"

		if IsValid(ply) then
			ply:SetNW2Entity(PILOT_KEY, NULL)
			ply:SetMoveType(MOVETYPE_WALK)

			-- Restore the holstered weapon.
			if IsValid(ply._TowerHiddenWep) then ply._TowerHiddenWep:SetNoDraw(false) end
			ply._TowerHiddenWep = nil

			if ply:Alive() then
				-- Set them down just outside the base so they don't fall through it.
				ply:SetPos(self:GetPos() + self:GetForward() * 48 + Vector(0, 0, 8))
			end

			net.Start("Arcana_MagicTower_Enter")
			net.WriteEntity(self)
			net.WriteBool(false)
			net.Send(ply)
		end

		self:EmitSound("ambient/energy/newspark04.wav", 75, 110)
	end

	function ENT:Use(activator)
		if not IsValid(activator) or not activator:IsPlayer() then return end
		if not activator:Alive() then return end
		if activator == self:GetPilot() then return end
		self:SetPilotPlayer(activator)
	end

	function ENT:Think()
		local ply = self:GetPilot()

		-- Lerp the bubble (and pilot) up to PilotHeight when occupied, back down when empty.
		local targetZ = IsValid(ply) and self.PilotHeight or self.BubbleHeight
		self:SetBubbleZ(Lerp(FrameTime() * 5, self:GetBubbleZ(), targetZ))

		if not IsValid(ply) or not ply:Alive() or ply:GetNW2Entity(PILOT_KEY) ~= self then
			if IsValid(self:GetPilot()) then self:EjectPilot() end
			self:NextThink(CurTime())
			return true
		end

		-- Keep the seated pilot centered in the bubble.
		ply:SetPos(self:BubbleCenter() - Vector(0, 0, ply:OBBMaxs().z * 0.5))

		-- Belt-and-suspenders weapon lockout: keep the active weapon un-fireable and hidden.
		local wep = ply:GetActiveWeapon()
		if IsValid(wep) then
			wep:SetNextPrimaryFire(CurTime() + 1)
			wep:SetNextSecondaryFire(CurTime() + 1)
			if wep ~= ply._TowerHiddenWep then
				if IsValid(ply._TowerHiddenWep) then ply._TowerHiddenWep:SetNoDraw(false) end
				wep:SetNoDraw(true)
				ply._TowerHiddenWep = wep
			end
		end

		-- Lerp the cannon direction toward the pilot's live aim (never instant). The cannon
		-- traverses slower while spitting flak, so the pilot walks fire around more heavily.
		local aim     = ply:GetAimVector()
		local curDir  = self:GetCannonAngle():Forward()
		local lerpAmt = (ply._TowerFire2 and self._fireState == "idle") and self.FlakAimLerp or self.AimLerp
		local newDir  = (curDir + aim * lerpAmt):GetNormalized()
		self:SetCannonAngle(newDir:Angle())

		-- Fire state machine: idle -> windup -> (fire) -> winddown -> idle
		local now = CurTime()
		local state = self._fireState

		if state == "idle" then
			if ply._TowerFire then
				self._fireState = "windup"
				self._stateUntil = now + self.Windup
				self:SetFireState(1)
				self:EmitSound("weapons/physcannon/energy_sing_explosion2.wav", 80, 95)
			end
		elseif state == "windup" then
			if now >= self._stateUntil then
				self:FireBeam(ply)
				self._fireState = "winddown"
				self._stateUntil = now + self.Winddown
				self:SetFireState(2)
			end
		elseif state == "winddown" then
			if now >= self._stateUntil then
				self._fireState = "idle"
				self:SetFireState(0)
			end
		end

		-- Secondary fire: magic flak. Fire rate spools up while +attack2 is held; only
		-- available when the beam isn't winding up / firing / recovering.
		if self._fireState == "idle" and ply._TowerFire2 and self:CanAffordFlak(ply) then
			self._flakSpool = math.min(1, (self._flakSpool or 0) + FrameTime() / self.FlakSpoolTime)
			if now >= (self._nextFlak or 0) then
				local interval = Lerp(self._flakSpool, self.FlakIntervalSlow, self.FlakIntervalFast)
				self._nextFlak = now + interval
				self:FireFlak(ply)
			end
		else
			-- Spin down when released, blocked, or broke.
			self._flakSpool = math.max(0, (self._flakSpool or 0) - FrameTime() / (self.FlakSpoolTime * 0.5))
		end

		self:NextThink(now)
		return true
	end

	function ENT:OnRemove()
		if IsValid(self:GetPilot()) then
			self:EjectPilot()
		end
	end

	hook.Add("PlayerDisconnected", "Arcana_MagicTower_Disconnect", function(ply)
		local tower = ply:GetNW2Entity(PILOT_KEY)
		if IsValid(tower) then tower:EjectPilot() end
	end)

	hook.Add("PlayerDeath", "Arcana_MagicTower_Death", function(ply)
		local tower = ply:GetNW2Entity(PILOT_KEY)
		if IsValid(tower) then tower:EjectPilot() end
	end)
end

if CLIENT then
	local MagicCircle = Arcana.Circle.MagicCircle
	local MagicCircleManager = Arcana.Circle.MagicCircleManager
	local BandCircle = Arcana.Circle.BandCircle

	local matGlow   = Material("sprites/light_glow02_add")
	local matFlare  = Material("effects/blueflare1")
	local matRing   = Material("effects/select_ring")
	local matBeam   = Material("effects/laser1")

	-- Transparent additive bubble shell (same recipe as the Ward's sphere).
	local BUBBLE_MAT = CreateMaterial("arcana_magic_tower_bubble_" .. tostring(SysTime()), "UnlitGeneric", {
		["$basetexture"] = "color/white",
		["$translucent"] = 1,
		["$vertexalpha"] = 1,
		["$vertexcolor"] = 1,
		["$nocull"]      = 1,
		["$additive"]    = 1,
	})

	local VECTOR_ABOVE = Vector(0, 0, 8)
	local VECTOR_DOWN  = Vector(0, 0, 256)
	local VECTOR_SLIGHTLY_ABOVE = Vector(0, 0, 2)

	-- Convert an aim direction into a MagicCircle angle whose disc faces along the aim.
	local function aimToCircleAngle(aimVec)
		local a = aimVec:Angle()
		return Angle(a.p + 90, a.y, 0)
	end

	local towerImpacts = {}
	local towerBeams   = {}
	local towerTracers = {}
	local TRACER_W     = 200

    -- Hide the pilot's own viewmodel while seated in the bubble.
    hook.Add("PreDrawViewModel", "Arcana_MagicTower_HideVM", function(vm, ply, wep)
        local p     = LocalPlayer()
        local tower = p:GetNW2Entity(PILOT_KEY)
        if IsValid(tower) and tower:GetPilot() == p then return true end
    end)

    -- Third-person chase camera while piloting.
    local VIEW_HULL_MIN = Vector(-8, -8, -8)
    local VIEW_HULL_MAX = Vector(8, 8, 8)
    hook.Add("CalcView", "Arcana_MagicTower_View", function(ply, pos, angles, fov)
        local tower = ply:GetNW2Entity(PILOT_KEY)
        if not IsValid(tower) or tower:GetPilot() ~= ply then return end

        local eyeAng = ply:EyeAngles()
        local focus  = tower:BubbleCenter()
        local desired = focus - eyeAng:Forward() * 220 + eyeAng:Up() * 60

        -- Pull the camera in if a wall is in the way.
        local tr = util.TraceHull({
            start  = focus,
            endpos = desired,
            mins   = VIEW_HULL_MIN,
            maxs   = VIEW_HULL_MAX,
            filter = { ply, tower },
            mask   = MASK_SOLID,
        })

        return {
            origin     = tr.Hit and tr.HitPos or desired,
            angles     = eyeAng,
            fov        = fov,
            drawviewer = true, -- show the pilot's (swimming) body
        }
    end)

    -- Pilot targeting HUD: a fixed screen-centre arcane reticle that always shows while
    -- piloting, changes state (idle / target locked / charging / cooldown), and reports
    -- what the cannon is currently aimed at.
    hook.Add("HUDPaint", "Arcana_MagicTower_HUD", function()
        local ply   = LocalPlayer()
        local tower = ply:GetNW2Entity(PILOT_KEY)
        if not IsValid(tower) or tower:GetPilot() ~= ply then return end

        local Draw2DRing     = Arcana.Circle.Draw2DRing
        local RT             = Arcana.Circle.RING_TYPES
        if not Draw2DRing or not RT then return end

        -- Scale the whole reticle with vertical resolution (reference 1080p).
        local s      = math.max(0.75, ScrH() / 1080)
        local cx, cy = ScrW() * 0.5, ScrH() * 0.5
        local t      = CurTime()
        local state  = tower:GetFireState()

        -- State colour: charging (warm) > cooldown (grey) > locked (red) > idle (tower).
        local col = tower.TowerColor

        -- Base reticle: layered counter-rotating arcane rings, always visible.
        Draw2DRing(RT.STAR_RING,     cx, cy, 150 * s, t * 14,  col, 255)
        Draw2DRing(RT.PATTERN_LINES, cx, cy, 98 * s,  -t * 28, col, 220)
        Draw2DRing(RT.SIMPLE_LINE,   cx, cy, 54 * s,  t * 55,  col, 230)

        -- Windup: a thick rune circle converging + pulsing onto centre (runes stay legible).
        if state == 1 then
            if not tower._windupStart then tower._windupStart = t end
            local prog = math.Clamp((t - tower._windupStart) / math.max(0.01, tower.Windup), 0, 1)
            local r    = Lerp(prog, 300 * s, 130 * s)
            local a    = 210 + 45 * math.sin(t * 30)
            Draw2DRing(RT.PATTERN_LINES, cx, cy, r, t * 120, col, a)
        else
            tower._windupStart = nil
        end

        -- Cooldown: a ring that grows back as the winddown recovers.
        if state == 2 then
            if not tower._winddownStart then tower._winddownStart = t end
            local prog = math.Clamp((t - tower._winddownStart) / math.max(0.01, tower.Winddown), 0, 1)
            Draw2DRing(RT.SIMPLE_LINE, cx, cy, Lerp(prog, 30 * s, 54 * s), 0, col, 110 + 110 * prog)
        else
            tower._winddownStart = nil
        end
    end)

    -- Big arcane beam, owned by the tower.
    net.Receive("Arcana_MagicTower_Beam", function()
        local s   = net.ReadVector()
        local e   = net.ReadVector()
        local col = net.ReadColor(false)
        local w   = net.ReadFloat()
        towerBeams[#towerBeams + 1] = { s = s, e = e, col = col, w = w, start = CurTime(), life = 0.35 }
    end)

    hook.Add("PostDrawTranslucentRenderables", "Arcana_MagicTower_Beams", function(_, isSkybox)
        if isSkybox then return end
        local now = CurTime()

        for i = #towerBeams, 1, -1 do
            local b    = towerBeams[i]
            local frac = (now - b.start) / b.life
            if frac >= 1 then
                table.remove(towerBeams, i)
            else
                local fade = 1 - frac
                local a, c = b.s, b.e
                local d    = c - a
                local len  = d:Length()
                if len >= 1 then
                    d:Normalize()
                    local steps = math.Clamp(math.floor(len / 48), 10, 96)
                    local w     = b.w * 10
                    local col   = b.col

                    render.SetMaterial(matBeam)
                    render.StartBeam(steps + 1)
                    for j = 0, steps do
                        local tt = j / steps
                        render.AddBeam(a + d * (len * tt), w * 1.8 * fade, tt * len / 256, Color(col.r, col.g, col.b, 90 * fade))
                    end
                    render.EndBeam()
                    render.StartBeam(steps + 1)
                    for j = 0, steps do
                        local tt = j / steps
                        render.AddBeam(a + d * (len * tt), w * fade, tt * len / 256, Color(col.r, col.g, col.b, 230 * fade))
                    end
                    render.EndBeam()
                    render.StartBeam(steps + 1)
                    for j = 0, steps do
                        local tt = j / steps
                        render.AddBeam(a + d * (len * tt), w * 0.45 * fade, tt * len / 256, Color(255, 255, 255, 255 * fade))
                    end
                    render.EndBeam()

                    render.SetMaterial(matGlow)
                    render.DrawSprite(a, w * 2.2 * fade, w * 2.2 * fade, Color(col.r, col.g, col.b, 200 * fade))
                    render.DrawSprite(c, w * 2.6 * fade, w * 2.6 * fade, Color(col.r, col.g, col.b, 220 * fade))
                end
            end
        end
    end)

    -- Magic flak tracers (secondary fire): quick bright streaks + a small impact burst.
    net.Receive("Arcana_MagicTower_Flak", function()
        local s   = net.ReadVector()
        local e   = net.ReadVector()
        local col = net.ReadColor(false)
        towerTracers[#towerTracers + 1] = { s = s, e = e, col = col, start = CurTime(), life = 0.14 }

        local emitter = ParticleEmitter(e)
        if emitter then
            for _ = 1, 8 do
                local p = emitter:Add("effects/blueflare1", e)
                if p then
                    p:SetVelocity(VectorRand():GetNormalized() * math.Rand(60, 240))
                    p:SetDieTime(math.Rand(0.15, 0.4))
                    p:SetStartAlpha(255)
                    p:SetEndAlpha(0)
                    p:SetStartSize(math.Rand(4, 11))
                    p:SetEndSize(0)
                    p:SetColor(col.r, col.g, col.b)
                    p:SetGravity(Vector(0, 0, -160))
                    p:SetAirResistance(80)
                end
            end
            local pp = emitter:Add("particle/particle_smokegrenade", e)
            if pp then
                pp:SetVelocity(VectorRand() * 30)
                pp:SetDieTime(math.Rand(0.3, 0.6))
                pp:SetStartAlpha(110)
                pp:SetEndAlpha(0)
                pp:SetStartSize(math.Rand(10, 20))
                pp:SetEndSize(math.Rand(30, 55))
                pp:SetColor(col.r, col.g, col.b)
                pp:SetAirResistance(70)
            end
            emitter:Finish()
        end
    end)

    hook.Add("PostDrawTranslucentRenderables", "Arcana_MagicTower_Tracers", function(_, isSkybox)
        if isSkybox then return end
        local now = CurTime()

        for i = #towerTracers, 1, -1 do
            local trc  = towerTracers[i]
            local frac = (now - trc.start) / trc.life
            if frac >= 1 then
                table.remove(towerTracers, i)
            else
                local fade = 1 - frac
                local a, c = trc.s, trc.e
                local d    = c - a
                local len  = d:Length()
                if len >= 1 then
                    local col = trc.col
                    local uv  = len / 64

                    render.SetMaterial(matBeam)
                    -- Colored streak
                    render.StartBeam(2)
                    render.AddBeam(a, TRACER_W * fade, 0, Color(col.r, col.g, col.b, 220 * fade))
                    render.AddBeam(c, TRACER_W * fade, uv, Color(col.r, col.g, col.b, 220 * fade))
                    render.EndBeam()
                    -- White-hot core
                    render.StartBeam(2)
                    render.AddBeam(a, TRACER_W * 0.4 * fade, 0, Color(255, 255, 255, 255 * fade))
                    render.AddBeam(c, TRACER_W * 0.4 * fade, uv, Color(255, 255, 255, 255 * fade))
                    render.EndBeam()

                    -- Muzzle flash + impact flash
                    render.SetMaterial(matFlare)
                    render.DrawSprite(a, 34 * fade, 34 * fade, Color(255, 255, 255, 230 * fade))
                    render.SetMaterial(matGlow)
                    render.DrawSprite(c, 56 * fade, 56 * fade, Color(col.r, col.g, col.b, 230 * fade))
                    render.SetMaterial(matFlare)
                    render.DrawSprite(c, 26 * fade, 26 * fade, Color(255, 255, 255, 255 * fade))
                end
            end
        end
    end)

    -- Arcane explosion visual at the beam's impact.
    net.Receive("Arcana_MagicTower_Impact", function()
        local pos    = net.ReadVector()
        local normal = net.ReadVector()
        local col    = net.ReadColor(false)
        local radius = net.ReadFloat()

        towerImpacts[#towerImpacts + 1] = {
            pos    = pos,
            normal = normal,
            col    = col,
            radius = radius,
            start  = CurTime(),
            life   = 0.7,
        }

        local emitter = ParticleEmitter(pos)
        if emitter then
            for _ = 1, 60 do
                local p = emitter:Add("effects/blueflare1", pos + VectorRand() * 12)
                if p then
                    p:SetVelocity(VectorRand():GetNormalized() * math.Rand(180, 720))
                    p:SetDieTime(math.Rand(0.35, 0.9))
                    p:SetStartAlpha(255)
                    p:SetEndAlpha(0)
                    p:SetStartSize(math.Rand(10, 28))
                    p:SetEndSize(0)
                    p:SetColor(col.r, col.g, col.b)
                    p:SetGravity(Vector(0, 0, -140))
                    p:SetAirResistance(60)
                end
            end
            for _ = 1, 24 do
                local p = emitter:Add("particle/particle_smokegrenade", pos + VectorRand() * 24)
                if p then
                    p:SetVelocity(VectorRand() * 100 + Vector(0, 0, 70))
                    p:SetDieTime(math.Rand(0.6, 1.5))
                    p:SetStartAlpha(120)
                    p:SetEndAlpha(0)
                    p:SetStartSize(math.Rand(22, 44))
                    p:SetEndSize(math.Rand(70, 130))
                    p:SetColor(col.r, col.g, col.b)
                    p:SetAirResistance(80)
                end
            end
            emitter:Finish()
        end

        local dl = DynamicLight(util.CRC(tostring(pos) .. tostring(CurTime())) % 60000)
        if dl then
            dl.pos        = pos
            dl.r          = col.r
            dl.g          = col.g
            dl.b          = col.b
            dl.brightness = 6
            dl.Decay      = 1200
            dl.Size       = radius * 3
            dl.DieTime    = CurTime() + 0.4
        end
    end)

    hook.Add("PostDrawTranslucentRenderables", "Arcana_MagicTower_Impacts", function(_, isSkybox)
        if isSkybox then return end
        local now = CurTime()

        for i = #towerImpacts, 1, -1 do
            local e    = towerImpacts[i]
            local frac = (now - e.start) / e.life
            if frac >= 1 then
                table.remove(towerImpacts, i)
            else
                local grow  = frac
                local alpha = 1 - frac
                local col   = e.col

                -- Core flash + colored glow.
                render.SetMaterial(matFlare)
                local coreSize = e.radius * (0.5 + grow * 1.1) * 3
                render.DrawSprite(e.pos, coreSize, coreSize, Color(255, 255, 255, 255 * alpha))
                render.SetMaterial(matGlow)
                local glowSize = e.radius * (1.0 + grow * 2.4) * 3
                render.DrawSprite(e.pos, glowSize, glowSize, Color(col.r, col.g, col.b, 220 * alpha))

                -- Expanding surface-aligned arcane ring.
                render.SetMaterial(matRing)
                local ringSize = e.radius * (0.4 + grow * 2.6) * 3
                render.DrawQuadEasy(e.pos + e.normal * 3, e.normal, ringSize, ringSize, Color(col.r, col.g, col.b, 255 * alpha), now * 60 % 360)
            end
        end
    end)
	
	function ENT:Initialize()
		self.NextWindupPFX = 0
		-- Model is hidden, so widen render bounds to cover the bubble, ground circle and cannon.
		self:SetRenderBounds(Vector(-150, -150, -24), Vector(150, 150, 190))
	end

	-- Model is hidden; all visuals live in DrawTranslucent.
	function ENT:Draw()
	end

	function ENT:DrawTranslucent()
		local color = self:GetColor()
		if color.r == 255 and color.g == 255 and color.b == 255 then
			color = self.TowerColor
		end

		-- Ground magic circle (ritual area), anchored to the ground beneath the base.
		if not self._groundCircle then
			self._groundCircle = MagicCircle.new(self:GetPos() + VECTOR_SLIGHTLY_ABOVE, Angle(0, 180, 180), color, 60, 110, 2)
			MagicCircleManager:Add(self._groundCircle)
		end

		if self._groundCircle then
			local tr = util.TraceLine({
				start  = self:GetPos() + VECTOR_ABOVE,
				endpos = self:GetPos() - VECTOR_DOWN,
				mask   = MASK_SOLID_BRUSHONLY,
				filter = self,
			})
			local groundPos = tr.Hit and tr.HitPos or self:GetPos()
			self._groundCircle.position = groundPos + VECTOR_SLIGHTLY_ABOVE
			self._groundCircle.angles = Angle(0, 180, 180)
		end

		local center = self:BubbleCenter()
		local dir    = self:GetCannonAngle():Forward()
		local muzzle = self:MuzzlePos()

		-- Cannon magic circle, perpendicular to the (lerp-following) aim direction.
		-- Hidden for the pilot (they get a HUD reticle instead); shown to everyone else.
		local isPilot = LocalPlayer() == self:GetPilot()
		if isPilot then
			if self._cannonCircle then
				self._cannonCircle:Remove()
				self._cannonCircle = nil
			end
		else
			if not self._cannonCircle then
				self._cannonCircle = MagicCircle.new(muzzle, aimToCircleAngle(dir), color, 40, 52, 2)
				MagicCircleManager:Add(self._cannonCircle)
			end
			self._cannonCircle.position = muzzle
			self._cannonCircle.angles = aimToCircleAngle(dir)
		end

        local t = CurTime()
		local pulse = 1 + math.sin(t * 2.5) * 0.03

		-- Horizontal band spinning around the bubble's vertical center.
		if not self._bands and BandCircle then
			self._bands = BandCircle.Create(center, Angle(0, 0, 0), color, self.BubbleRadius, 0)
			if self._bands then
				self._bands:AddBand(self.BubbleRadius * 1.05, 10, { p = 0, y = 70, r = 35 }, 4)
                self._bands:AddBand(self.BubbleRadius * 1.05, 10, { p = -70, y = -35, r = 0 }, 4)
                self._bands:AddBand(self.BubbleRadius * 1.05, 10, { p = 70, y = 0, r = 70 }, 4)
			end
		end
		if self._bands and self._bands.isActive then
			self._bands.position = center
		end

		-- Transparent energy bubble that holds the pilot.
		render.SetMaterial(BUBBLE_MAT)
		render.DrawSphere(center, self.BubbleRadius * pulse, 32, 32, Color(color.r, color.g, color.b, 26))
		render.DrawSphere(center, self.BubbleRadius * pulse * 1.04, 32, 32, Color(color.r, color.g, color.b, 12))

		-- Windup glow at the muzzle while charging.
		if self:GetFireState() == 1 then
			local flick = 5 + math.sin(t * 30) * 0.3
			render.SetMaterial(matFlare)
			render.DrawSprite(muzzle, 44 * flick, 44 * flick, Color(255, 255, 255, 230))
			render.SetMaterial(matGlow)
			render.DrawSprite(muzzle, 110 * flick, 110 * flick, Color(color.r, color.g, color.b, 200))

			if t >= (self.NextWindupPFX or 0) then
				self.NextWindupPFX = t + 1 / 30
				local emitter = ParticleEmitter(muzzle)
				if emitter then
					for _ = 1, 3 do
						local off = VectorRand() * math.Rand(50, 110)
						local p = emitter:Add("effects/blueflare1", muzzle + off)
						if p then
							p:SetVelocity((muzzle - (muzzle + off)):GetNormalized() * math.Rand(120, 260))
							p:SetDieTime(math.Rand(0.15, 0.35))
							p:SetStartAlpha(255)
							p:SetEndAlpha(0)
							p:SetStartSize(math.Rand(4, 9) * 10)
							p:SetEndSize(0)
							p:SetColor(color.r, color.g, color.b)
						end
					end
					emitter:Finish()
				end
			end

			local dl = DynamicLight(self:EntIndex())
			if dl then
				dl.pos = muzzle
				dl.r = color.r
				dl.g = color.g
				dl.b = color.b
				dl.brightness = 3
				dl.Decay = 800
				dl.Size = 220
				dl.DieTime = t + 0.1
			end
		end
	end

	function ENT:OnRemove()
		if self._groundCircle then self._groundCircle:Remove() end
		if self._cannonCircle then self._cannonCircle:Remove() end
		if self._bands and self._bands.Remove then self._bands:Remove() end
	end

	net.Receive("Arcana_MagicTower_Enter", function()
		-- Reserved for future client-side feedback (view tweaks, HUD hints).
		net.ReadEntity()
		net.ReadBool()
	end)
end
