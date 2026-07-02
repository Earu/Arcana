-- Golden transmutation burst — the flash, sparks and dust as matter turns to
-- gold under the Midas curse. Dispatched from arcana/status/midas.lua via
-- util.Effect("arcana_midas_gold", ed) with the origin and a size scale.

EFFECT.RingSounds = {
	"physics/metal/metal_solid_impact_soft1.wav",
	"physics/metal/metal_solid_impact_soft2.wav",
	"physics/metal/metal_solid_impact_soft3.wav",
}

function EFFECT:Init(data)
	local pos = data:GetOrigin()
	local scale = math.Clamp(data:GetScale(), 0.5, 6)

	-- An arcane shimmer plus a bright metallic ring
	sound.Play("arcana/arcane_" .. math.random(1, 3) .. ".ogg", pos, 70, math.random(120, 150), 0.7)
	sound.Play(self.RingSounds[math.random(#self.RingSounds)], pos, 68, math.random(150, 190), 0.5)

	local emitter = ParticleEmitter(pos)
	if not emitter then return end

	-- Bright central flash
	local flash = emitter:Add("sprites/light_glow02_add", pos)
	if flash then
		flash:SetVelocity(vector_origin)
		flash:SetDieTime(0.25)
		flash:SetStartAlpha(255)
		flash:SetEndAlpha(0)
		flash:SetStartSize(28 * scale)
		flash:SetEndSize(60 * scale)
		flash:SetColor(255, 225, 130)
	end

	-- Outward spray of golden sparks
	for _ = 1, math.floor(18 * scale) do
		local p = emitter:Add("effects/yellowflare", pos)
		if p then
			local dir = VectorRand()
			dir.z = math.abs(dir.z) * 0.6 + 0.2
			dir:Normalize()

			p:SetVelocity(dir * math.Rand(50, 160) * scale)
			p:SetDieTime(math.Rand(0.5, 1.1))
			p:SetStartAlpha(255)
			p:SetEndAlpha(0)
			p:SetStartSize(math.Rand(3, 7))
			p:SetEndSize(0)
			p:SetGravity(Vector(0, 0, -220))
			p:SetAirResistance(40)
			p:SetColor(255, math.random(180, 220), math.random(40, 90))
			p:SetRoll(math.Rand(0, 360))
			p:SetRollDelta(math.Rand(-4, 4))
		end
	end

	-- Lingering gold dust motes drifting up
	for _ = 1, math.floor(8 * scale) do
		local p = emitter:Add("particle/particle_glow_04", pos + VectorRand() * 6 * scale)
		if p then
			p:SetVelocity(VectorRand() * math.Rand(10, 30) + Vector(0, 0, 20))
			p:SetDieTime(math.Rand(0.8, 1.6))
			p:SetStartAlpha(180)
			p:SetEndAlpha(0)
			p:SetStartSize(math.Rand(4, 8))
			p:SetEndSize(0)
			p:SetGravity(Vector(0, 0, -20))
			p:SetAirResistance(60)
			p:SetColor(255, 210, 110)
		end
	end

	emitter:Finish()
end

function EFFECT:Think()
	return false
end

function EFFECT:Render()
end
