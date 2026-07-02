-- Ritual: Magic Tower — summons a pilotable arcane battle tower for 10 minutes.
local TOWER_LIFETIME = 60 * 10 -- 10 minutes

Arcana:RegisterRitualSpell({
	id = "ritual_magic_tower",
	name = "Ritual: Magic Tower",
	description = "Summon an arcane battle tower you can climb into and pilot for 10 minutes: a devastating beam on primary fire and spooling magic flak on secondary.",
	category = Arcana.CATEGORIES.COMBAT,
	level_required = 32,
	knowledge_cost = 6,
	cooldown = 60 * 15,
	cost_type = Arcana.COST_TYPES.COINS,
	cost_amount = 8000,
	cast_time = 10.0,
	ritual_color = Color(150, 120, 255),
	ritual_lifetime = 300,
	ritual_coin_cost = 15000,
	ritual_items = {
		mana_crystal_shard = 50,
		battery = 8,
	},
	on_activate = function(selfEnt, activatingPly, caster)
		if not SERVER then return end

		local pos = selfEnt:GetPos()
		local ang = selfEnt:GetAngles()

		local tower = ents.Create("arcana_magic_tower")
		if not IsValid(tower) then return end

		tower:SetPos(pos + Vector(0, 0, 8))
		tower:SetAngles(Angle(0, ang.y, 0))
		tower:Spawn()
		tower:Activate()

		local owner = IsValid(caster) and caster or activatingPly
		if tower.CPPISetOwner and IsValid(owner) and owner:IsPlayer() then
			tower:CPPISetOwner(owner)
		end

		-- The summon lasts a fixed 10 minutes; removing it ejects any pilot (ENT:OnRemove).
		local towerRef = tower
		timer.Simple(TOWER_LIFETIME, function()
			if IsValid(towerRef) then
				towerRef:EmitSound("ambient/energy/newspark04.wav", 80, 90)
				towerRef:Remove()
			end
		end)

		selfEnt:EmitSound("ambient/energy/whiteflash.wav", 85, 100)
		selfEnt:EmitSound("ambient/levels/citadel/strange_talk5.wav", 75, 105)
		util.ScreenShake(pos, 8, 60, 1.0, 1200)
	end,
})
