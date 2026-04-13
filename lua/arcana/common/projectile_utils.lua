-- Arcana Projectile Utilities
-- Shared helpers used by arcane projectile entities

Arcana = Arcana or {}
Arcana.Common = Arcana.Common or {}

if SERVER then
	--- Returns true when an entity is solid and not a trigger volume.
	-- Used by projectile collision handlers to decide whether to detonate.
	-- @param ent Entity to test
	-- @return boolean
	function Arcana.Common.IsSolidNonTrigger(ent)
		if not IsValid(ent) then return false end
		if ent:IsWorld() then return true end

		local solid = ent.GetSolid and ent:GetSolid() or SOLID_NONE
		if solid == SOLID_NONE then return false end

		local flags = ent.GetSolidFlags and ent:GetSolidFlags() or 0
		return bit.band(flags, FSOLID_TRIGGER) == 0
	end

	--- Attaches an env_sprite to a projectile entity and auto-removes it when the parent is removed.
	-- @param parent Entity to attach the sprite to
	-- @param model string VMT path for the sprite
	-- @param color Color tint for the sprite
	-- @param scale number Sprite scale
	-- @param name string Unique name used for the CallOnRemove callback
	function Arcana.Common.AddEntitySprite(parent, model, color, scale, name)
		local spr = ents.Create("env_sprite")
		if not IsValid(spr) then return end

		spr:SetKeyValue("model", model)
		spr:SetKeyValue("rendercolor", string.format("%d %d %d", color.r, color.g, color.b))
		spr:SetKeyValue("rendermode", "9")
		spr:SetKeyValue("scale", tostring(scale))
		spr:SetPos(parent:GetPos())
		spr:SetParent(parent)
		spr:Spawn()
		spr:Activate()

		parent:CallOnRemove(name, function(_, s)
			if IsValid(s) then s:Remove() end
		end, spr)
	end

	--- Assign ownership and launch a projectile entity towards a direction.
	-- Handles SetOwner, SetSpellOwner, CPPISetOwner, and LaunchTowards in one call.
	-- @param ent       Entity  The spawned projectile (must already be Spawn()ed or about to be)
	-- @param caster    Entity  The player or NPC launching the projectile
	-- @param direction Vector  Direction to launch towards (e.g. caster:GetAimVector())
	function Arcana.Common.LaunchProjectile(ent, caster, direction)
		if not IsValid(ent) or not IsValid(caster) then return end
		if ent.SetOwner then ent:SetOwner(caster) end
		if ent.SetSpellOwner then ent:SetSpellOwner(caster) end
		if ent.CPPISetOwner and caster:IsPlayer() then ent:CPPISetOwner(caster) end
		if ent.LaunchTowards and isvector(direction) then ent:LaunchTowards(direction) end
	end

	-- Canonical defaults for ApplyLightningChain opts — serves as documentation and
	-- allows callers to override only the keys that differ from the standard behaviour.
	Arcana.Common.LIGHTNING_CHAIN_DEFAULTS = {
		baseDamage  = 60,   -- AoE damage at hitPos
		blastRadius = 180,  -- radius of the initial AoE blast
		chainRadius = 380,  -- radius to search for chaining targets
		chainDamage = 24,   -- damage per chained target
		maxChains   = 3,    -- maximum number of secondary targets
		chainDelay  = 0.03, -- seconds between each chain strike
		-- spawnTesla: function(pos) -> Entity; defaults to Arcana.Common.SpawnTeslaBurst(pos)
		-- onChain: function(tgt, tpos, chainIdx) -> nil; called inside each chain timer (optional)
	}

	--- Apply an AoE lightning blast then chain to nearby living targets.
	-- @param attacker Entity  Attacker (player or NPC)
	-- @param hitPos   Vector  Center of the blast and chain search
	-- @param opts     table   Optional overrides (see Arcana.Common.LIGHTNING_CHAIN_DEFAULTS for all keys):
	--   spawnTesla: function(pos) -> Entity — called to spawn visual effect at chain position
	--   onChain:    function(tgt, tpos, chainIdx) -> nil — called after each chain strike
	function Arcana.Common.ApplyLightningChain(attacker, hitPos, opts)
		opts = opts or {}
		local D = Arcana.Common.LIGHTNING_CHAIN_DEFAULTS
		local blastRadius = opts.blastRadius or D.blastRadius
		local baseDamage  = opts.baseDamage  or D.baseDamage
		local chainRadius = opts.chainRadius or D.chainRadius
		local chainDamage = opts.chainDamage or D.chainDamage
		local maxChains   = opts.maxChains   or D.maxChains
		local chainDelay  = opts.chainDelay  or D.chainDelay
		local spawnFn     = opts.spawnTesla  or function(pos) return Arcana.Common.SpawnTeslaBurst(pos) end
		local onChain     = opts.onChain

		Arcana:BlastDamage(attacker, hitPos, blastRadius, baseDamage, { damageType = DMG_SHOCK, ignoreAttacker = true })

		local candidates = {}
		for _, ent in ipairs(ents.FindInSphere(hitPos, chainRadius)) do
			if ent == attacker then continue end
			if IsValid(ent) and (ent:IsPlayer() or ent:IsNPC() or ent:IsNextBot()) and ent:Health() > 0 and ent:VisibleVec(hitPos) then
				table.insert(candidates, ent)
			end
		end

		table.sort(candidates, function(a, b)
			return a:GetPos():DistToSqr(hitPos) < b:GetPos():DistToSqr(hitPos)
		end)

		for i = 1, math.min(maxChains, #candidates) do
			local tgt = candidates[i]
			local tpos = tgt:WorldSpaceCenter()
			timer.Simple(chainDelay * i, function()
				if not IsValid(tgt) or tgt == attacker then return end
				local tesla = spawnFn(tpos)
				if IsValid(tesla) and tesla.CPPISetOwner then
					tesla:CPPISetOwner(attacker)
				end
				local dmg = DamageInfo()
				dmg:SetDamage(chainDamage)
				dmg:SetDamageType(bit.bor(DMG_SHOCK, DMG_ENERGYBEAM))
				dmg:SetAttacker(IsValid(attacker) and attacker or game.GetWorld())
				dmg:SetInflictor(IsValid(attacker) and attacker or game.GetWorld())
				dmg:SetDamagePosition(tpos)
				tgt:TakeDamageInfo(dmg)
				if isfunction(onChain) then onChain(tgt, tpos, i) end
			end)
		end
	end

	--- Shared lightning impact VFX: scorch decal, sparks, screen shake, and zap sound.
	-- @param pos    Vector  World position of the impact
	-- @param normal Vector  Surface normal at the impact point
	-- @param opts   table   Optional overrides: power (number, default 1.0),
	--                       shakePower (number), shakeHz (number), shakeDur (number), shakeRadius (number)
	function Arcana.Common.LightningImpactVFX(pos, normal, opts)
		opts = opts or {}
		local power = opts.power or 1.0
		normal = normal or Vector(0, 0, 1)
		local ed = EffectData()
		ed:SetOrigin(pos)
		util.Effect("cball_explode", ed, true, true)
		util.Effect("ManhackSparks", ed, true, true)
		util.Decal("Scorch", pos + normal * 8, pos - normal * 8)
		util.ScreenShake(
			pos,
			(opts.shakePower or 6) * power,
			opts.shakeHz or 90,
			opts.shakeDur or 0.35,
			(opts.shakeRadius or 600) * power
		)
		sound.Play("ambient/energy/zap" .. math.random(1, 9) .. ".wav", pos, opts.soundLvl or 95, 100)
	end

	--- Creates a point_tesla entity for brief lightning visual feedback.
	-- @param pos Vector  World position for the burst
	-- @param opts table  Optional overrides:
	--   targetname (string), color (string "R G B"), radius (number),
	--   beamcount_min/max, thick_min/max, lifetime_min/max, interval_min/max,
	--   kill_delay (number, seconds before entity is removed)
	-- @return Entity  The spawned point_tesla (may be invalid if creation failed)
	function Arcana.Common.SpawnTeslaBurst(pos, opts)
		opts = opts or {}
		local tesla = ents.Create("point_tesla")
		if not IsValid(tesla) then return end

		tesla:SetPos(pos)
		tesla:SetKeyValue("targetname", opts.targetname or "arcana_tesla")
		tesla:SetKeyValue("m_SoundName", "DoSpark")
		tesla:SetKeyValue("texture", opts.texture or "sprites/physbeam.vmt")
		tesla:SetKeyValue("m_Color", opts.color or "170 200 255")
		tesla:SetKeyValue("m_flRadius", tostring(opts.radius or 200))
		tesla:SetKeyValue("beamcount_min", tostring(opts.beamcount_min or 5))
		tesla:SetKeyValue("beamcount_max", tostring(opts.beamcount_max or 8))
		tesla:SetKeyValue("thick_min", tostring(opts.thick_min or 5))
		tesla:SetKeyValue("thick_max", tostring(opts.thick_max or 8))
		tesla:SetKeyValue("lifetime_min", string.format("%.2f", opts.lifetime_min or 0.10))
		tesla:SetKeyValue("lifetime_max", string.format("%.2f", opts.lifetime_max or 0.16))
		tesla:SetKeyValue("interval_min", string.format("%.2f", opts.interval_min or 0.04))
		tesla:SetKeyValue("interval_max", string.format("%.2f", opts.interval_max or 0.08))
		tesla:Spawn()
		tesla:Fire("DoSpark", "", 0)
		tesla:Fire("Kill", "", opts.kill_delay or 0.5)

		return tesla
	end
end
