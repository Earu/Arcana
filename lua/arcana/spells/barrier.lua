-- Arcane Barrier: A timed shield that absorbs incoming damage up to a cap

local BARRIER_COLOR = Color(150, 170, 255, 255)

-- Internal helpers
local function clearBarrier(ply)
	if not IsValid(ply) then return end
	ply._arcanaBarrierHP = nil
	ply._arcanaBarrierUntil = nil
	if SERVER then
		Arcane:ClearBandVFX(ply, "spell_barrier")
	end
	if CLIENT then return end
	if ply._arcanaBarrierVFXHook then
		hook.Remove("Think", ply._arcanaBarrierVFXHook)
		ply._arcanaBarrierVFXHook = nil
	end
end

local function hasBarrier(ply)
	if not IsValid(ply) then return false end
	local hp = tonumber(ply._arcanaBarrierHP or 0) or 0
	local untilT = tonumber(ply._arcanaBarrierUntil or 0) or 0
	return hp > 0 and CurTime() < untilT
end

if SERVER then
	-- Damage absorption
	hook.Add("EntityTakeDamage", "Arcana_BarrierAbsorb", function(ent, dmg)
		if not IsValid(ent) or not ent:IsPlayer() then return end
		if not hasBarrier(ent) then return end

		local hp = ent._arcanaBarrierHP or 0
		local amount = dmg:GetDamage()
		if amount <= 0 then return end

		local absorbed = math.min(hp, amount)
		if absorbed <= 0 then return end

		-- Reduce damage by absorbed amount
		dmg:SetDamage(amount - absorbed)
		ent._arcanaBarrierHP = hp - absorbed

		-- Visual ping when absorbing
		if ent._arcanaBarrierNextPing == nil or ent._arcanaBarrierNextPing < CurTime() then
			ent._arcanaBarrierNextPing = CurTime() + 0.15
			local r = math.max(ent:OBBMaxs():Unpack()) * 0.55
			Arcane:SendAttachBandVFX(ent, BARRIER_COLOR, 28, 0.25, {
				{ radius = r * 0.85, height = 4, spin = {p = 0, y = 120, r = 0}, lineWidth = 2 },
			})
		end

		-- If barrier broke on this hit
		if ent._arcanaBarrierHP <= 0 then
			ent._arcanaBarrierHP = 0
			ent._arcanaBarrierUntil = 0
			-- Shatter cue
			sound.Play("physics/glass/glass_impact_bullet4.wav", ent:WorldSpaceCenter(), 70, 140, 0.7)
			local ed = EffectData()
			ed:SetOrigin(ent:WorldSpaceCenter())
			util.Effect("GlassImpact", ed, true, true)
			-- Clear barrier VFX instantly on shatter
			Arcane:ClearBandVFX(ent, "spell_barrier")
		end
	end)

	-- Cleanup on death or disconnect
	hook.Add("PlayerDeath", "Arcana_BarrierCleanup", function(ply)
		clearBarrier(ply)
	end)
	hook.Add("PlayerDisconnected", "Arcana_BarrierCleanup", function(ply)
		clearBarrier(ply)
	end)
end

-- Spell registration
Arcane:RegisterSpell({
	id = "arcane_barrier",
	name = "Arcane Barrier",
	description = "Summon a protective shield that absorbs damage for a short time.",
	category = Arcane.CATEGORIES.PROTECTION,
	level_required = 5, -- push above level 3 as requested
	knowledge_cost = 3,
	cooldown = 18.0,
	cost_type = Arcane.COST_TYPES.COINS,
	cost_amount = 45,
	cast_time = 1.0,
	range = 0,
	icon = "icon16/shield.png",
	cast_anim = "becon",

	can_cast = function(caster)
		if hasBarrier(caster) then
			return false, "Barrier already active"
		end
		return true
	end,

	cast = function(caster, _, _, _)
		if CLIENT then return true end

		local duration = 120
		-- Capacity scales slightly with level: 60 base + 6 per level, capped
		local level = Arcane:GetPlayerData(caster).level or 1
		local capacity = math.Clamp(60 + (level * 6), 60, 1000)

		caster._arcanaBarrierHP = capacity
		caster._arcanaBarrierUntil = CurTime() + duration

		-- Activation SFX/VFX
		sound.Play("items/suitchargeok1.wav", caster:WorldSpaceCenter(), 70, 120, 0.7)
		local r = math.max(caster:OBBMaxs():Unpack()) * 0.6
		Arcane:SendAttachBandVFX(caster, BARRIER_COLOR, 34, duration, {
			{ radius = r * 0.95, height = 6, spin = {p = 0, y = 60 * 3, r = 20 * 3}, lineWidth = 2 },
			{ radius = r * 0.95, height = 6, spin = {p = -30 * 3, y = -40 * 3, r = 10 * 3}, lineWidth = 2 },
			{ radius = r * 0.95, height = 6, spin = {p = 30 * 3, y = -50 * 3, r = -15 * 3}, lineWidth = 2 },
			{ radius = r * 0.95, height = 6, spin = {p = -45 * 3, y = 35 * 3, r = -25 * 3}, lineWidth = 2 },
			{ radius = r * 0.95, height = 6, spin = {p = 15 * 3, y = -70 * 3, r = 30 * 3}, lineWidth = 2 },
			{ radius = r * 0.95, height = 6, spin = {p = -20 * 3, y = 45 * 3, r = -35 * 3}, lineWidth = 2 }
		}, "spell_barrier")

		-- Expiry watcher
		local key = "Arcana_BarrierExpire_" .. caster:EntIndex()
		timer.Create(key, 0.1, 0, function()
			if not IsValid(caster) then timer.Remove(key) return end
			if not hasBarrier(caster) then
				-- If it didn't shatter from damage, play a soft fade effect on natural expiry
				if not (caster._arcanaBarrierHP and caster._arcanaBarrierHP <= 0) then
					local ed = EffectData()
					ed:SetOrigin(caster:WorldSpaceCenter())
					util.Effect("cball_explode", ed, true, true)
					sound.Play("weapons/physcannon/energy_disintegrate4.wav", caster:WorldSpaceCenter(), 65, 160, 0.55)
				end
				clearBarrier(caster)
				timer.Remove(key)
			end
		end)

		return true
	end,
})


