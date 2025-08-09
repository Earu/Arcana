AddCSLuaFile()

-- Arcane Magic System Core
-- A comprehensive magic system for Garry's Mod featuring spells, rituals, and progression

local Arcane = {}
Arcane.VERSION = "1.0.0"

function Arcane:Print(...)
    MsgC(Color(147, 112, 219), "[Arcana] ", Color(255, 255, 255), ...)
    MsgN()
end

-- Client-side stub for autocomplete and help so players see the command
if CLIENT then
    local function arcanaAutoComplete(cmd, stringargs)
        local input = string.lower(string.Trim(stringargs or ""))
        local out = {}
        for id, sp in pairs(Arcane and Arcane.RegisteredSpells or {}) do
            local idLower = string.lower(id)
            local nameLower = string.lower(sp.name or id)
            if input == "" or string.find(idLower, input, 1, true) or string.find(nameLower, input, 1, true) then
                out[#out + 1] = cmd .. " " .. id
            end
        end

        table.sort(out)
        return out
    end

    -- Forward to server so typing in client console still works
    concommand.Add("arcana", function(_, _, args)
        local raw = tostring(args and args[1] or "")
        local spellId = string.lower(string.Trim(raw))
        if spellId == "" then
            Arcane:Print("Usage: arcana <spellId>")
            return
        end

        net.Start("Arcane_ConsoleCastSpell")
        net.WriteString(spellId)
        net.SendToServer()
    end, arcanaAutoComplete, "Cast an Arcana spell: arcana <spellId>")
end

-- Configuration
Arcane.Config = {
    -- XP and Leveling
    BASE_XP_REQUIRED = 100,
    XP_MULTIPLIER = 1.5,
    KNOWLEDGE_POINTS_PER_LEVEL = 2,
    MAX_LEVEL = 100,

    -- Spell Configuration
    DEFAULT_SPELL_COOLDOWN = 1.0,
    SPELL_FAILURE_CHANCE = 0.05, -- 5% base failure chance

    -- Ritual Configuration
    RITUAL_PREPARATION_TIME = 5.0,
    RITUAL_CASTING_TIME = 10.0,

    -- Database
    DATABASE_FILE = "arcane_data.txt"
}

-- Storage for registered spells and rituals
Arcane.RegisteredSpells = {}
Arcane.RegisteredRituals = {}
Arcane.PlayerData = {}

-- Spell cost types
Arcane.COST_TYPES = {
    COINS = "coins",
    HEALTH = "health",
    ITEMS = "items"
}

-- Spell/Ritual categories
Arcane.CATEGORIES = {
    COMBAT = "combat",
    UTILITY = "utility",
    PROTECTION = "protection",
    SUMMONING = "summoning",
    DIVINATION = "divination",
    ENCHANTMENT = "enchantment"
}

-- Player data structure
local function CreateDefaultPlayerData()
    return {
        xp = 0,
        level = 1,
        knowledge_points = Arcane.Config.KNOWLEDGE_POINTS_PER_LEVEL,
        -- Note: coins are managed by your existing system
        unlocked_spells = {},
        unlocked_rituals = {},
        spell_cooldowns = {},
        active_effects = {},
        -- Quickspell system
        quickspell_slots = { nil, nil, nil, nil, nil, nil, nil, nil },
        selected_quickslot = 1,
        last_save = os.time()
    }
end

-- Utility Functions
function Arcane:GetXPRequiredForLevel(level)
    return math.floor(Arcane.Config.BASE_XP_REQUIRED * (Arcane.Config.XP_MULTIPLIER ^ (level - 1)))
end

function Arcane:GetTotalXPForLevel(level)
    local total = 0
    for i = 1, level - 1 do
        total = total + self:GetXPRequiredForLevel(i)
    end
    return total
end

-- Player Data Management
function Arcane:GetPlayerData(ply)
    local steamid = ply:SteamID64()
    if not self.PlayerData[steamid] then
        self.PlayerData[steamid] = CreateDefaultPlayerData()
    end
    return self.PlayerData[steamid]
end

function Arcane:SavePlayerData(ply)
    if not IsValid(ply) then return end

    local data = self:GetPlayerData(ply)
    data.last_save = os.time()

    -- TODO: Implement file-based persistence
    -- For now, data persists only during server session
end

function Arcane:LoadPlayerData(ply)
    if not IsValid(ply) then return end

    -- TODO: Implement file-based loading
    -- For now, use default data
    local steamid = ply:SteamID64()
    if not self.PlayerData[steamid] then
        self.PlayerData[steamid] = CreateDefaultPlayerData()
    end
end

-- Networking helpers
if SERVER then
    util.AddNetworkString("Arcane_FullSync")
    util.AddNetworkString("Arcane_SetQuickslot")
    util.AddNetworkString("Arcane_SetSelectedQuickslot")
    util.AddNetworkString("Arcane_BeginCasting")
    util.AddNetworkString("Arcane_PlayCastGesture")
    util.AddNetworkString("Arcana_AttachBandVFX")
    util.AddNetworkString("Arcana_AttachParticles")
    util.AddNetworkString("Arcane_ConsoleCastSpell")

    function Arcane:SyncPlayerData(ply)
        if not IsValid(ply) then return end
        local data = self:GetPlayerData(ply)

        local payload = {
            xp = data.xp,
            level = data.level,
            knowledge_points = data.knowledge_points,
            unlocked_spells = table.Copy(data.unlocked_spells),
            unlocked_rituals = table.Copy(data.unlocked_rituals),
            spell_cooldowns = table.Copy(data.spell_cooldowns),
            quickspell_slots = table.Copy(data.quickspell_slots),
            selected_quickslot = data.selected_quickslot,
        }

        net.Start("Arcane_FullSync")
        net.WriteTable(payload)
        net.Send(ply)
    end
end
-- Begin casting with a minimum cast time and broadcast evolving circle
function Arcane:StartCasting(ply, spellId)
    if not IsValid(ply) then return false end
    local canCast, reason = self:CanCastSpell(ply, spellId)
    if not canCast then
        if CLIENT then
            Arcane:Print("Cannot cast spell \"" .. spellId .. "\": " .. reason)
        else
            ply:EmitSound("buttons/button8.wav", 100, 120)
        end

        return false
    end

    local spell = self.RegisteredSpells[spellId]
    local castTime = math.max(0.1, spell.cast_time or 0)

    -- Decide gesture and broadcast to clients to play locally
    if SERVER then
        local forwardLike = spell.cast_anim == "forward" or spell.is_projectile or spell.has_target or ((spell.range or 0) > 0)
        local gesture = forwardLike and ACT_SIGNAL_FORWARD or ACT_GMOD_GESTURE_BECON
        if gesture then
            net.Start("Arcane_PlayCastGesture")
            net.WriteEntity(ply)
            net.WriteInt(gesture, 16)
            net.Broadcast()
        end

        -- Compute a server-side circle context (position/angle/size)
        local circlePos = ply:GetPos() + Vector(0, 0, 2)
        local circleAng = Angle(0, 180, 180)
        local circleSize = 60
        if forwardLike then
            local maxs = ply:OBBMaxs()
            circlePos = ply:GetPos() + ply:GetForward() * maxs.x * 1.5 + ply:GetUp() * maxs.z / 2
            circleAng = ply:EyeAngles()
            circleAng:RotateAroundAxis(circleAng:Right(), 90)
            circleSize = 30
        end

        -- Tell clients to show evolving circle for this cast
        net.Start("Arcane_BeginCasting")
        net.WriteEntity(ply)
        net.WriteString(spellId)
        net.WriteFloat(castTime)
        net.WriteBool(forwardLike)
        net.Broadcast()

        -- Schedule execution after cast time
        timer.Simple(castTime, function()
            if not IsValid(ply) then return end
            -- Re-check basic conditions before executing
            local ok = select(1, self:CanCastSpell(ply, spellId))
            if not ok then return end
            self:CastSpell(ply, spellId, nil, {
                circlePos = circlePos,
                circleAng = circleAng,
                circleSize = circleSize,
                forwardLike = forwardLike,
                castTime = castTime,
            })
        end)
    end

    return true
end

-- XP and Leveling System
function Arcane:GiveXP(ply, amount, reason)
    if not IsValid(ply) or amount <= 0 then return false end

    local data = self:GetPlayerData(ply)
    local oldLevel = data.level

    data.xp = data.xp + amount

    -- Check for level up
    local newLevel = self:CalculateLevel(data.xp)
    if newLevel > oldLevel then
        self:LevelUp(ply, oldLevel, newLevel)
    end

    -- Network update
    if SERVER then
        net.Start("Arcane_XPUpdate")
        net.WriteUInt(data.xp, 32)
        net.WriteUInt(data.level, 16)
        net.WriteString(reason or "Unknown")
        net.Send(ply)
    end

    self:SavePlayerData(ply)
    return true
end

function Arcane:CalculateLevel(totalXP)
    local level = 1
    local xpUsed = 0

    while level < self.Config.MAX_LEVEL do
        local xpNeeded = self:GetXPRequiredForLevel(level)
        if xpUsed + xpNeeded > totalXP then
            break
        end
        xpUsed = xpUsed + xpNeeded
        level = level + 1
    end

    return level
end

function Arcane:LevelUp(ply, oldLevel, newLevel)
    local data = self:GetPlayerData(ply)
    local levelsGained = newLevel - oldLevel

    data.level = newLevel
    data.knowledge_points = data.knowledge_points + (levelsGained * Arcane.Config.KNOWLEDGE_POINTS_PER_LEVEL)

    -- Notify player
    if SERVER then
        ply:ChatPrint("🌟 Level Up! You are now level " .. newLevel .. "!")
        ply:ChatPrint("💎 You gained " .. (levelsGained * Arcane.Config.KNOWLEDGE_POINTS_PER_LEVEL) .. " knowledge points!")

        -- Visual/audio feedback
        ply:EmitSound("buttons/bell1.wav", 75, 100)

        -- Network level up notification
        net.Start("Arcane_LevelUp")
        net.WriteUInt(newLevel, 16)
        net.WriteUInt(data.knowledge_points, 16)
        net.Send(ply)

        -- Ensure client has up-to-date totals
        self:SyncPlayerData(ply)
    end

    -- Hook for other addons
    hook.Run("Arcane_PlayerLevelUp", ply, oldLevel, newLevel, data.knowledge_points)
end

-- Spell Registration API
function Arcane:RegisterSpell(spellData)
    if not spellData.id or not spellData.name or not spellData.cast then
        ErrorNoHalt("Spell registration requires id, name, and cast function")
        return false
    end

    -- Default values
    local spell = {
        id = spellData.id,
        name = spellData.name,
        description = spellData.description or "A mysterious spell",
        category = spellData.category or Arcane.CATEGORIES.UTILITY,
        level_required = spellData.level_required or 1,
        knowledge_cost = spellData.knowledge_cost or 1,
        cooldown = spellData.cooldown or Arcane.Config.DEFAULT_SPELL_COOLDOWN,
        cost_type = spellData.cost_type or Arcane.COST_TYPES.COINS,
        cost_amount = spellData.cost_amount or 10,
        cast_time = spellData.cast_time or 0, -- Instant by default
        range = spellData.range or 500,
        icon = spellData.icon or "icon16/wand.png",

        -- Functions
        cast = spellData.cast, -- function(caster, target, data)
        can_cast = spellData.can_cast, -- function(caster, target, data) - optional validation
        on_success = spellData.on_success, -- function(caster, target, data) - optional callback
        on_failure = spellData.on_failure, -- function(caster, target, data) - optional callback

        -- Animation hints
        -- If provided, these help decide which player gesture to play during casting
        is_projectile = spellData.is_projectile,   -- boolean
        has_target = spellData.has_target,         -- boolean (clear aimed target/point)
        cast_anim = spellData.cast_anim            -- optional explicit act name, e.g., "forward" or "becon"
    }

    self.RegisteredSpells[spell.id] = spell

    self:Print("Registered spell '" .. spell.name .. "' (ID: " .. spell.id .. "')\n")
    return true
end

-- Ritual Registration API
function Arcane:RegisterRitual(ritualData)
    if not ritualData.id or not ritualData.name or not ritualData.perform then
        ErrorNoHalt("Ritual registration requires id, name, and perform function")
        return false
    end

    local ritual = {
        id = ritualData.id,
        name = ritualData.name,
        description = ritualData.description or "A mysterious ritual",
        category = ritualData.category or Arcane.CATEGORIES.UTILITY,
        level_required = ritualData.level_required or 1,
        knowledge_cost = ritualData.knowledge_cost or 2,
        preparation_time = ritualData.preparation_time or Arcane.Config.RITUAL_PREPARATION_TIME,
        casting_time = ritualData.casting_time or Arcane.Config.RITUAL_CASTING_TIME,
        coin_cost = ritualData.coin_cost or 50,
        item_requirements = ritualData.item_requirements or {}, -- {item_name = amount}
        participants_required = ritualData.participants_required or 1,
        icon = ritualData.icon or "icon16/book.png",

        -- Functions
        perform = ritualData.perform, -- function(caster, participants, data)
        can_perform = ritualData.can_perform, -- function(caster, participants, data)
        on_success = ritualData.on_success,
        on_failure = ritualData.on_failure,
        on_interrupted = ritualData.on_interrupted
    }

    self.RegisteredRituals[ritual.id] = ritual

    self:Print("Registered ritual '" .. ritual.name .. "' (ID: " .. ritual.id .. "')\n")
    return true
end

-- Spell Casting System
function Arcane:CanCastSpell(ply, spellId)
    local spell = self.RegisteredSpells[spellId]
    if not spell then return false, "Spell not found" end

    local data = self:GetPlayerData(ply)

    -- Check if spell is unlocked
    if not data.unlocked_spells[spellId] then
        return false, "Spell not unlocked"
    end

    -- Check level requirement
    if data.level < spell.level_required then
        return false, "Insufficient level"
    end

    -- Check cooldown
    local cooldownKey = spellId
    if data.spell_cooldowns[cooldownKey] and data.spell_cooldowns[cooldownKey] > CurTime() then
        return false, "Spell on cooldown"
    end

    -- Cost checks no longer block casting:
    -- - If coins are insufficient or unavailable, the equivalent amount is taken as health damage on cast
    -- - If health is insufficient, the player will take lethal damage on cast

    -- Custom validation
    if spell.can_cast then
        local canCast, reason = spell.can_cast(ply, nil, data)
        if not canCast then
            return false, reason or "Cannot cast spell"
        end
    end

    return true
end

-- Public helper: Attach BandCircle VFX to an entity (server-side entry)
if SERVER then
    function Arcane:SendAttachBandVFX(ent, color, size, duration, bandConfigs)
        if not IsValid(ent) then return end
        net.Start("Arcana_AttachBandVFX", true)
            net.WriteEntity(ent)
            net.WriteColor(color or Color(120, 200, 255, 255), true)
            net.WriteFloat(size or 80)
            net.WriteFloat(duration or 5)
            local count = istable(bandConfigs) and #bandConfigs or 0
            net.WriteUInt(count, 8)
            for i = 1, count do
                local c = bandConfigs[i]
                net.WriteFloat(c.radius or (size or 80) * 0.6)
                net.WriteFloat(c.height or 16)
                net.WriteFloat((c.spin and c.spin.p) or 0)
                net.WriteFloat((c.spin and c.spin.y) or 0)
                net.WriteFloat((c.spin and c.spin.r) or 0)
                net.WriteFloat(c.lineWidth or 2)
            end
        net.Broadcast()
    end
end

-- Server-side helper: ask clients to attach a particle system to an entity
if SERVER then
    function Arcane:SendAttachParticles(ent, effectName, duration)
        if not IsValid(ent) or not isstring(effectName) or #effectName == 0 then return end
        net.Start("Arcana_AttachParticles")
            net.WriteEntity(ent)
            net.WriteString(effectName)
            net.WriteFloat(duration or 5)
        net.Broadcast()
    end
end

function Arcane:CastSpell(ply, spellId, target, context)
    if not IsValid(ply) then return false end

    local canCast, reason = self:CanCastSpell(ply, spellId)
    if not canCast then
        if CLIENT then
            Arcane:Print("Cannot cast spell \"" .. spellId .. "\": " .. reason)
        else
            ply:EmitSound("buttons/button8.wav", 100, 120)
        end

        return false
    end

    local spell = self.RegisteredSpells[spellId]
    local data = self:GetPlayerData(ply)
    local takeDamageInfo = ply.ForceTakeDamageInfo or ply.TakeDamageInfo

    -- Apply costs
    if spell.cost_type == Arcane.COST_TYPES.COINS then
        local canPayWithCoins = ply.GetCoins and ply.TakeCoins and (ply:GetCoins() >= spell.cost_amount)
        if canPayWithCoins then
            ply:TakeCoins(spell.cost_amount, "Spell: " .. spell.name)
        else
            -- Fallback: pay with health as real damage
            local dmg = DamageInfo()
            dmg:SetDamage(spell.cost_amount)
            dmg:SetAttacker(IsValid(ply) and ply or game.GetWorld())
            dmg:SetInflictor(IsValid(ply:GetActiveWeapon()) and ply:GetActiveWeapon() or ply)
            -- Use DMG_DIRECT so armor is ignored by Source damage rules
            dmg:SetDamageType(bit.bor(DMG_GENERIC, DMG_DIRECT))
            takeDamageInfo(ply, dmg)

            if spell.cost_amount > 100 then
                return false, "Insufficient coins"
            end
        end
    elseif spell.cost_type == Arcane.COST_TYPES.HEALTH then
        -- Health costs are applied as real damage, which can be lethal
        local dmg = DamageInfo()
        dmg:SetDamage(spell.cost_amount)
        dmg:SetAttacker(IsValid(ply) and ply or game.GetWorld())
        dmg:SetInflictor(IsValid(ply:GetActiveWeapon()) and ply:GetActiveWeapon() or ply)
        -- Use DMG_DIRECT so armor is ignored by Source damage rules
        dmg:SetDamageType(bit.bor(DMG_GENERIC, DMG_DIRECT))
        takeDamageInfo(ply, dmg)
    end

    -- Set cooldown
    data.spell_cooldowns[spellId] = CurTime() + spell.cooldown

    -- Cast the spell
    local success = true
    local failureChance = Arcane.Config.SPELL_FAILURE_CHANCE

    if math.random() < failureChance then
        success = false
    else
        -- Gesture is handled at StartCasting

        -- Execute the spell
        local result = spell.cast(ply, target, data, context)
        if result == false then
            success = false
        end
    end

    -- Handle success/failure
    if success then
        -- Give XP
        local xpGain = math.max(1, spell.knowledge_cost * 5)
        self:GiveXP(ply, xpGain, "Cast " .. spell.name)

        if spell.on_success then
            spell.on_success(ply, target, data)
        end
    else
        if spell.on_failure then
            spell.on_failure(ply, target, data)
        end
    end

    self:SavePlayerData(ply)
    if SERVER then
        -- Sync cooldowns and any derived changes
        self:SyncPlayerData(ply)
    end
    return success
end

-- Knowledge System
function Arcane:CanUnlockSpell(ply, spellId)
    local spell = self.RegisteredSpells[spellId]
    if not spell then return false, "Spell not found" end

    local data = self:GetPlayerData(ply)

    if data.unlocked_spells[spellId] then
        return false, "Already unlocked"
    end

    if data.level < spell.level_required then
        return false, "Insufficient level"
    end

    if data.knowledge_points < spell.knowledge_cost then
        return false, "Insufficient knowledge points"
    end

    return true
end

function Arcane:UnlockSpell(ply, spellId)
    local canUnlock, reason = self:CanUnlockSpell(ply, spellId)
    if not canUnlock then
        if CLIENT then
            Arcane:Print("Cannot unlock spell \"" .. spellId .. "\": " .. reason)
        else
            ply:EmitSound("buttons/button8.wav", 100, 120)
        end
        return false
    end

    local spell = self.RegisteredSpells[spellId]
    local data = self:GetPlayerData(ply)

    data.knowledge_points = data.knowledge_points - spell.knowledge_cost
    data.unlocked_spells[spellId] = true

    -- Auto-assign to first empty quickslot
    for i = 1, 8 do
        if not data.quickspell_slots[i] then
            data.quickspell_slots[i] = spellId
            break
        end
    end

    if SERVER then
        ply:ChatPrint("🎓 Unlocked spell: " .. spell.name .. "!")
        self:SyncPlayerData(ply)
    end

    self:SavePlayerData(ply)
    return true
end

function Arcane:CanUnlockRitual(ply, ritualId)
    local ritual = self.RegisteredRituals[ritualId]
    if not ritual then return false, "Ritual not found" end

    local data = self:GetPlayerData(ply)

    if data.unlocked_rituals[ritualId] then
        return false, "Already unlocked"
    end

    if data.level < ritual.level_required then
        return false, "Insufficient level"
    end

    if data.knowledge_points < ritual.knowledge_cost then
        return false, "Insufficient knowledge points"
    end

    return true
end

function Arcane:UnlockRitual(ply, ritualId)
    local canUnlock, reason = self:CanUnlockRitual(ply, ritualId)
    if not canUnlock then
        if CLIENT then
            Arcane:Print("Cannot unlock ritual \"" .. ritualId .. "\": " .. reason)
        else
            ply:EmitSound("buttons/button8.wav", 100, 120)
        end
        return false
    end

    local ritual = self.RegisteredRituals[ritualId]
    local data = self:GetPlayerData(ply)

    data.knowledge_points = data.knowledge_points - ritual.knowledge_cost
    data.unlocked_rituals[ritualId] = true

    if SERVER then
        ply:ChatPrint("🎓 Unlocked ritual: " .. ritual.name .. "!")
        self:SyncPlayerData(ply)
    end

    self:SavePlayerData(ply)
    return true
end

-- Player Meta Extensions for Arcane-specific data only
local PLAYER = FindMetaTable("Player")

-- Note: This system assumes you already have:
-- PLAYER:GetCoins(), PLAYER:TakeCoins(amount, reason), PLAYER:GiveCoins(amount, reason)
-- PLAYER:GetItemCount(itemName)
-- If your methods have different names, you'll need to update the calls in the spell/ritual casting functions

function PLAYER:GetArcaneLevel()
    return Arcane:GetPlayerData(self).level
end

function PLAYER:GetArcaneXP()
    return Arcane:GetPlayerData(self).xp
end

function PLAYER:GetKnowledgePoints()
    return Arcane:GetPlayerData(self).knowledge_points
end

function PLAYER:HasSpellUnlocked(spellId)
    return Arcane:GetPlayerData(self).unlocked_spells[spellId] == true
end

function PLAYER:HasRitualUnlocked(ritualId)
    return Arcane:GetPlayerData(self).unlocked_rituals[ritualId] == true
end

-- Networking
if SERVER then
    util.AddNetworkString("Arcane_XPUpdate")
    util.AddNetworkString("Arcane_LevelUp")
    util.AddNetworkString("Arcane_CastSpell")
    util.AddNetworkString("Arcane_UnlockSpell")
    util.AddNetworkString("Arcane_UnlockRitual")

    -- Handle spell casting from client
    net.Receive("Arcane_CastSpell", function(len, ply)
        local spellId = net.ReadString()
        local hasTarget = net.ReadBool()
        local target = hasTarget and net.ReadEntity() or nil

        Arcane:CastSpell(ply, spellId, target)
    end)

    -- Handle spell unlocking
    net.Receive("Arcane_UnlockSpell", function(len, ply)
        local spellId = net.ReadString()
        Arcane:UnlockSpell(ply, spellId)
    end)

    -- Handle ritual unlocking
    net.Receive("Arcane_UnlockRitual", function(len, ply)
        local ritualId = net.ReadString()
        Arcane:UnlockRitual(ply, ritualId)
    end)

    -- Handle client-forwarded console cast: "arcana <spellId>"
    net.Receive("Arcane_ConsoleCastSpell", function(_, ply)
        if not IsValid(ply) then return end
        local raw = net.ReadString() or ""
        local spellId = string.lower(string.Trim(raw))
        if spellId == "" then return end

        local canCast, _ = Arcane:CanCastSpell(ply, spellId)
        if not canCast then
            ply:EmitSound("buttons/button8.wav", 100, 120)
            return
        end

        Arcane:StartCasting(ply, spellId)
    end)

    -- Assign a spell to a quickslot
    net.Receive("Arcane_SetQuickslot", function(_, ply)
        local slotIndex = math.Clamp(net.ReadUInt(4), 1, 8)
        local spellId = net.ReadString()

        local data = Arcane:GetPlayerData(ply)
        if not Arcane.RegisteredSpells[spellId] then return end
        if not data.unlocked_spells[spellId] then return end

        data.quickspell_slots[slotIndex] = spellId
        Arcane:SavePlayerData(ply)
        Arcane:SyncPlayerData(ply)
    end)

    -- Select the active quickslot
    net.Receive("Arcane_SetSelectedQuickslot", function(_, ply)
        local slotIndex = math.Clamp(net.ReadUInt(4), 1, 8)
        local data = Arcane:GetPlayerData(ply)
        data.selected_quickslot = slotIndex
        Arcane:SavePlayerData(ply)
        Arcane:SyncPlayerData(ply)
    end)
end

-- Client-side receivers to keep local state in sync
if CLIENT then
    net.Receive("Arcane_XPUpdate", function()
        local xp = net.ReadUInt(32)
        local level = net.ReadUInt(16)
        local _reason = net.ReadString()

        local ply = LocalPlayer()
        if not IsValid(ply) then return end
        local data = Arcane:GetPlayerData(ply)
        data.xp = xp
        data.level = level
    end)

    net.Receive("Arcane_LevelUp", function()
        local level = net.ReadUInt(16)
        local knowledge = net.ReadUInt(16)

        local ply = LocalPlayer()
        if not IsValid(ply) then return end
        local data = Arcane:GetPlayerData(ply)
        data.level = level
        data.knowledge_points = knowledge
    end)

    net.Receive("Arcane_FullSync", function()
        local payload = net.ReadTable()
        if not payload then return end

        local ply = LocalPlayer()
        if not IsValid(ply) then return end
        local data = Arcane:GetPlayerData(ply)

        data.xp = payload.xp or data.xp
        data.level = payload.level or data.level
        data.knowledge_points = payload.knowledge_points or data.knowledge_points

        if istable(payload.unlocked_spells) then
            data.unlocked_spells = payload.unlocked_spells
        end
        if istable(payload.unlocked_rituals) then
            data.unlocked_rituals = payload.unlocked_rituals
        end
        if istable(payload.spell_cooldowns) then
            data.spell_cooldowns = payload.spell_cooldowns
        end
        if istable(payload.quickspell_slots) then
            data.quickspell_slots = payload.quickspell_slots
        end
        if payload.selected_quickslot then
            data.selected_quickslot = payload.selected_quickslot
        end
    end)

    -- Show evolving circle while a spell is being cast
    net.Receive("Arcane_BeginCasting", function()
        local caster = net.ReadEntity()
        local spellId = net.ReadString()
        local castTime = net.ReadFloat()
        local forwardLike = net.ReadBool()
        if not IsValid(caster) then return end
        if not MagicCircle then return end

        -- Allow spells to override the default casting circle. If a hook returns true, stop.
        local handled = hook.Run("Arcane_BeginCastingVisuals", caster, spellId, castTime, forwardLike)
        if handled == true then return end

        local pos = caster:GetPos() + Vector(0, 0, 2)
        local ang = Angle(0, 180, 180)
        local size = 60

        if forwardLike then
            local maxs = caster:OBBMaxs()
            pos = caster:GetPos() + caster:GetForward() * maxs.x * 1.5 + caster:GetUp() * maxs.z / 2
            ang = caster:EyeAngles()
            ang:RotateAroundAxis(ang:Right(), 90)
            size = 30
        end

        local color = caster.GetWeaponColor and caster:GetWeaponColor():ToColor() or Color(150, 100, 255, 255)
        local intensity = 3
        if isstring(spellId) and #spellId > 0 then
            intensity = 2 + (#spellId % 3)
        end
        local circle = MagicCircle.CreateMagicCircle(pos, ang, color, intensity, size, castTime, 2)
        if circle and circle.StartEvolving then
            circle:StartEvolving(castTime, true)
        end
    end)

    -- Play cast gesture locally for a given player
    net.Receive("Arcane_PlayCastGesture", function()
        local ply = net.ReadEntity()
        local gesture = net.ReadInt(16)
        if not IsValid(ply) or not gesture then return end

        local slot = GESTURE_SLOT_CUSTOM

        -- Prefer playing by sequence for better compatibility with player models
        if gesture == ACT_SIGNAL_FORWARD then
            local seq = ply:LookupSequence("gesture_signal_forward")
            if seq and seq >= 0 then
                ply:AddVCDSequenceToGestureSlot(slot, seq, 0, true)
                return
            end
        elseif gesture == ACT_GMOD_GESTURE_BECON then
            local seq = ply:LookupSequence("gesture_becon")
            if seq and seq >= 0 then
                ply:AddVCDSequenceToGestureSlot(slot, seq, 0, true)
                return
            end
        end

        -- Fallback to ACT-based gesture
        ply:AnimRestartGesture(slot, gesture, true)
    end)

    -- Client-only: receive BandCircle VFX attachments
    net.Receive("Arcana_AttachBandVFX", function()
        local ent = net.ReadEntity()
        local color = net.ReadColor(true)
        local size = net.ReadFloat()
        local duration = net.ReadFloat()
        local count = net.ReadUInt(8)
        if not IsValid(ent) or not BandCircle then return end
        local bc = BandCircle.Create(ent:WorldSpaceCenter(), ent:GetAngles(), color, size, duration)
        if not bc then return end

        for i = 1, count do
            local radius = net.ReadFloat()
            local height = net.ReadFloat()
            local sp = net.ReadFloat()
            local sy = net.ReadFloat()
            local sr = net.ReadFloat()
            local lw = net.ReadFloat()
            bc:AddBand(radius, height, { p = sp, y = sy, r = sr }, lw)
        end

        -- Follow entity for duration
        local hookName = "BandCircleFollow_" .. tostring(bc)
        hook.Add("Think", hookName, function()
            if not IsValid(ent) or not bc or not bc.isActive then
                bc:Remove()
                hook.Remove("Think", hookName)
                return
            end
            bc.position = ent:WorldSpaceCenter()
            bc.angles = ent:GetAngles()
        end)
    end)
end

-- Hooks
hook.Add("PlayerInitialSpawn", "Arcane_PlayerJoin", function(ply)
    timer.Simple(1, function()
        if IsValid(ply) then
            Arcane:LoadPlayerData(ply)
            if SERVER then
                Arcane:SyncPlayerData(ply)
            end
        end
    end)
end)

hook.Add("PlayerDisconnected", "Arcane_PlayerLeave", function(ply)
    Arcane:SavePlayerData(ply)
end)

-- Console Commands for Testing
if SERVER then
    concommand.Add("arcane_give_xp", function(ply, cmd, args)
        if not IsValid(ply) then return end
        local amount = tonumber(args[1]) or 100
        Arcane:GiveXP(ply, amount, "Admin Command")
    end)

    concommand.Add("arcane_reset", function(ply, cmd, args)
        if not IsValid(ply) then return end
        Arcane.PlayerData[ply:SteamID64()] = CreateDefaultPlayerData()
        Arcane:SyncPlayerData(ply)
    end)
end

-- Export the main module
_G.Arcane = Arcane

return Arcane
