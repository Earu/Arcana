# Arcana

***We like fireballs and stuff.***

Arcana is a magic mod for Garry's Mod, it comes with spells, enchantments and rituals that can be extended or integrated with various gamemodes.

## Integrating with Arcana

Arcana ships with a built-in coin and item inventory system. To integrate with an existing economy (DarkRP, PointShop2, a custom database, etc.), override any of the following functions:

```lua
-- Example: DarkRP coin integration
function Arcana.GiveCoins(ply, amount) ply:addMoney(amount) end
function Arcana.TakeCoins(ply, amount) ply:addMoney(-amount) end
function Arcana.GetCoins(ply) return ply:getDarkRPVar("money") end
```

```lua
-- Example: PointShop 2 item integration
function Arcana.GiveItem(ply, itemClass, amount, reason)
    if not IsValid(ply) or amount <= 0 then return false end
    ply:PS2_AddItem(itemClass, amount)
    return true
end

function Arcana.TakeItem(ply, itemClass, amount, reason)
    if not IsValid(ply) or amount <= 0 then return false end
    if ply:PS2_GetItemCount(itemClass) < amount then return false end
    ply:PS2_RemoveItem(itemClass, amount)
    return true
end

function Arcana.GetItemCount(ply, itemClass)
    if SERVER then
        return ply:PS2_GetItemCount(itemClass) or 0
    else
        return LocalPlayer():PS2_GetItemCount(itemClass) or 0
    end
end
```

Full examples for DarkRP, PointShop2, MySQL and custom backends are in [`docs/INTEGRATION.md`](docs/INTEGRATION.md).

Hooks are dispatched through `Arcana.RunHook`, which prefixes every name with `Arcana_`. Listen for the prefixed name.

### Persistence Hook Overrides

To replace the default SQLite persistence entirely, return `true` from any of these hooks to suppress Arcana's default behavior:

| Hook | Description |
|---|---|
| `Arcana_SavePlayerDataToSQL(ply, data)` | Override player data saving |
| `Arcana_LoadPlayerDataFromSQL(ply, callback)` | Override player data loading |
| `Arcana_ReadAstralVault(ply, callback)` | Override vault reading |
| `Arcana_WriteAstralVault(ply, items)` | Override vault writing |
| `Arcana_ReadSpellcraftState(ply, callback)` | Override spellcraft activation reading |
| `Arcana_WriteSpellcraftState(ply, state)` | Override spellcraft activation writing |

## Extending Arcana

### Registering a Spell

```lua
Arcana.RegisterSpell({
    id = "my_spell",
    name = "My Spell",
    description = "Does something magical.",
    category = "Arcane",
    level_required = 5,
    knowledge_cost = 1,
    cooldown = 3,
    cost_type = "mana",
    cost_amount = 20,
    cast_time = 1.0,
    range = 1500,

    cast = function(caster, has_target, data, context)
        if not SERVER then return true end
        -- spell logic here
    end,

    can_cast = function(caster, has_target, data)
        return true -- or return false, "reason"
    end,
})
```

### Registering a Ritual Spell

```lua
Arcana.RegisterRitualSpell({
    id = "ritual_my_ritual",
    name = "My Ritual",
    description = "Summons something.",
    category = "Ritual",
    level_required = 10,
    knowledge_cost = 2,
    cooldown = 60,
    cast_time = 10,
    ritual_color = Color(180, 80, 255),
    ritual_lifetime = 300,
    ritual_coin_cost = 5000,
    ritual_items = { { id = "crystal_shard", amount = 5 } },

    on_activate = function(selfEnt, activator, caster)
        -- triggered when a player pays the cost and activates the ritual
    end,
})
```

### Registering an Enchantment

```lua
Arcana.RegisterEnchantment({
    id = "my_enchantment",
    name = "My Enchantment",
    description = "Enchants a weapon with something.",
    cost_coins = 10000,
    cost_items = { { id = "crystal_shard", amount = 3 } },
    max_stacks = 1,
    grants_xp = true,

    can_apply = function(ply, wep)
        return true -- or return false, "reason"
    end,

    apply = function(ply, wep, state)
        -- attach hooks, modify weapon stats, etc.
    end,

    remove = function(ply, wep, state)
        -- clean up hooks and modifications
    end,
})
```

### Runtime API

Enchantments, on a specific weapon entity:

| Function | Notes |
| --- | --- |
| `Arcana.ApplyEnchantmentToWeaponEntity(ply, wep, enchId)` | Applies and awards XP. Returns `false, reason` on failure. |
| `Arcana.RestoreEnchantmentToWeaponEntity(ply, wep, enchId)` | Same, no XP. For system operations like a vault restore. |
| `Arcana.RemoveEnchantmentFromWeaponEntity(ply, wep, enchId)` | Runs `remove`, drops it, re-syncs. |
| `Arcana.GetEntityEnchantments(wep)` | Applied enchantments. |
| `Arcana.HasEntityEnchantment(wep, enchId)` | Whether one is applied. |
| `Arcana.SyncWeaponEnchantNW(wep)` | Force a re-sync after bulk changes. |

Progression and tutorial:

| Function | Realm | Notes |
| --- | --- | --- |
| `Arcana.GetLevel(ply)` / `GetXP(ply)` / `GetKnowledgePoints(ply)` | shared | |
| `Arcana.HasSpellUnlocked(ply, spellId)` | shared | |
| `Arcana.RecalculateAndRepairKnowledgePoints(ply)` | server | Recomputes KP from level and known spells, saves and syncs. Admin repair tool. |
| `Arcana.StartTutorialSequence(sequence)` | client | |
| `Arcana.IsTutorialActive()` | client | For suppressing your own UI. |

Voice activation: `Arcana.RegisterSpell` registers a trigger phrase for the spell name.
`Arcana.AddTriggerPhrase(phrase, spellId)` and `Arcana.RemoveTriggerPhrase(phrase)` manage extras.

### Registering an Environment

```lua
Arcana.Environments:RegisterEnvironment({
    id = "my_environment",
    name = "My Environment",
    lifetime = 600,
    lock_duration = 120,
    min_radius = 1000,
    max_radius = 3000,

    spawn_base = function(ctx)
        -- spawn base entities/timers, return { entities = {}, timers = {} }
    end,

    poi_min = 2,
    poi_max = 5,
    pois = {
        {
            id = "my_poi",
            min = 1,
            max = 3,
            can_spawn = function(ctx) return true end,
            spawn = function(ctx) end,
        },
    },
})
```

### Extending the Spellcraft Catalog

Crafted spells are stored as component ids only, never numbers. The server recompiles every
stat and cost from the catalog on load, so a modified client can inject ids at worst, and a
balance change applies retroactively.

Components live in three tables in `lua/arcana/spellcraft/catalog.lua`. Adding an entry is
enough to make it appear in the bench, be priced, and be castable.

```lua
local P = Arcana.Spellcraft

-- Form: the delivery shape. One per spell.
P.Forms.wave = {
    id = "wave", label = "Wave", order = 5, points = 25,
    desc = "A spreading front that washes outward from you.",
    isProjectile = false, hasTarget = false,
    baseDamage = 60, baseRadius = 400, baseRange = 700,
    baseCooldown = 7, baseCastTime = 1.0,
}

-- Essence: the element. One per spell, unlocked with a one-time offering.
P.Essences.acid = {
    id = "acid", label = "Acid", order = 7, points = 8,
    desc = "Corrodes victims over time.",
    rider = "corrode",                      -- needs a handler in effects.lua
    damageType = bit.bor(DMG_ACID, DMG_BLAST),
    color = Color(140, 220, 60),
    unlock = { coins = 20000, shards = 5 },
}

-- Clause: a modifier. Up to P.MAX_CLAUSE_SLOTS per spell, each with a rank.
P.Clauses.linger = {
    id = "linger", label = "Linger", order = 20, points = 12,
    desc = "The effect persists for +3s per rank.",
    maxRank = 2,
    levels = { 44, 49 },                    -- level required per rank
    onlyForm = { aoe = true },              -- optional whitelist
    denyForm = { self = true },             -- optional blacklist
    denyEssence = { fire = true },
    conflicts = { widen = true },
}
```

`points` is the power budget cost and the main balance lever. Budget is
`arcana_spellcraft_budget_base` plus `arcana_spellcraft_budget_per_level` per level above
`arcana_spellcraft_min_level`.

Operators also get `arcana_spellcraft_enabled`, `_max_damage`, `_max_radius`,
`_max_projectiles`, `_min_cooldown`, `_min_casttime`, `_max_range`, `_cost_mult`,
`_offering_mult` and `_max_slots`. Caps are enforced in `P.Compile`.

## Hooks

### Casting

| Hook | Realm | Parameters | Notes |
|---|---|---|---|
| `Arcana_CanCastSpell` | Server | `ply, spellId` | Return `false, reason` to block the cast |
| `Arcana_BeginCasting` | Server | `ply, spellId` | Fired when the cast wind-up begins |
| `Arcana_CastSpell` | Server | `ply, spellId, has_target, data, context, success` | Fired after every cast attempt regardless of outcome |
| `Arcana_SpellCastSucceeded` | Server | `ply, spellId, castPos, context` | Fired only on a successful cast; `castPos` is the world position of the magic circle |
| `Arcana_CastSpellFailure` | Server | `ply, spellId` | Fired when a cast fails or is interrupted |

### Casting Visuals (Client)

| Hook | Realm | Parameters | Notes |
|---|---|---|---|
| `Arcana_TrackCast` | Client | `caster, spellId, castTime` | Fired when the client receives a cast start network message |
| `Arcana_BeginCastingVisuals` | Client | `caster, spellId, castTime, forwardLike` | Return `true` to suppress the default magic circle VFX |
| `Arcana_TrackCastFailure` | Client | `caster, spellId, castTime` | Fired when the client receives a cast failure network message |
| `Arcana_CastSpellFailure` | Client | `caster, spellId` | Fired client-side after VFX teardown on failure |

### Progression

| Hook | Realm | Parameters | Notes |
|---|---|---|---|
| `Arcana_PlayerGainedXP` | Shared | `ply, amount, reason` | Fired on server when XP is awarded; fired on client when the XP update is received |
| `Arcana_PlayerLevelUp` | Server | `ply, oldLevel, newLevel, knowledgePoints` | Fired after level and knowledge point values are updated |
| `Arcana_ClientLevelUp` | Client | `prevLevel, newLevel, knowledgeDelta` | Fired after the client receives and applies a level-up packet |
| `Arcana_CanUnlockSpell` | Server | `ply, spellId` | Return `false, reason` to block unlocking |
| `Arcana_SpellUnlocked` | Shared | `ply, spellId, spellName` | Fired after a spell is successfully added to the player's known spells |

### Enchantments

| Hook | Realm | Parameters | Notes |
|---|---|---|---|
| `Arcana_CanApplyEnchantment` | Server | `ply, wep, enchId` | Return `false, reason` to block the enchantment |
| `Arcana_AppliedEnchantment` | Server | `ply, wep, enchId` | Fired after the enchantment is stored and synced |
| `Arcana_RemovedEnchantment` | Server | `ply, wep, enchId` | Fired after the enchantment is removed and synced |

### Persistence

| Hook | Realm | Parameters | Notes |
|---|---|---|---|
| `Arcana_SavePlayerDataToSQL` | Server | `ply, data, authoritative` | Return `true` to suppress the default SQLite save. `authoritative` may overwrite a newer stored row |
| `Arcana_LoadPlayerDataFromSQL` | Server | `ply, callback` | Return `true` to suppress the default SQLite load. Must call `callback(success, data)` on every path, failure included |
| `Arcana_SavedPlayerData` | Server | `ply, data` | Fired after player data is saved (any backend) |
| `Arcana_LoadedPlayerData` | Server | `ply, data` | Fired after player data is loaded and ready |
| `Arcana_SyncPlayerData` | Client | `ply, data` | Fired after the client receives a full data sync from the server |
| `Arcana_ReadAstralVault` | Server | `ply, callback` | Return `true` to suppress the default vault read. Must call `callback(success, items)` on every path |
| `Arcana_WriteAstralVault` | Server | `ply, items` | Return `true` to suppress the default vault write |
| `Arcana_ReadSpellcraftState` | Server | `ply, callback` | Return `true` to suppress the default spellcraft read. Must call `callback(success, state)` on every path |
| `Arcana_WriteSpellcraftState` | Server | `ply, state` | Return `true` to suppress the default spellcraft write |

### Economy & Inventory

| Hook | Realm | Parameters | Notes |
|---|---|---|---|
| `Arcana_ItemRegistered` | Shared | `itemClass, itemData` | Fired when a new item type is registered via `RegisterItem` |
| `Arcana_CoinsGiven` | Server | `ply, amount, reason` | Fired after coins are added to a player |
| `Arcana_CoinsTaken` | Server | `ply, amount, reason` | Fired after coins are deducted from a player |
| `Arcana_ItemGiven` | Server | `ply, itemClass, amount, reason` | Fired after items are added to a player's inventory |
| `Arcana_ItemTaken` | Server | `ply, itemClass, amount, reason` | Fired after items are removed from a player's inventory |
| `Arcana_ShouldDrawInventory` | Client | *(none)* | Return `false` to hide the Arcana inventory UI |

## Configuration

Core constants are defined in `lua/arcana/system/core.lua` under `Arcana.Config`:

| Key | Default | Description |
|---|---|---|
| `KNOWLEDGE_POINTS_PER_LEVEL` | `1` | Knowledge Points awarded per level |
| `MAX_LEVEL` | `100` | Maximum player level |
| `XP_BASE_CAST_TIME` | `1.0` | Reference cast time for XP scaling |
| `XP_PER_ENCHANT_SUCCESS` | `20` | Flat XP for a successful enchantment |
| `DEFAULT_SPELL_COOLDOWN` | `1.0` | Fallback cooldown if none is specified |
| `RITUAL_CASTING_TIME` | `10.0` | Default ritual casting time in seconds |
| `FORGET_COIN_BASE` | `2000` | Coin base for the forget price: `FORGET_COIN_BASE × knowledge_cost ^ FORGET_COIN_EXPONENT` |
| `FORGET_COIN_EXPONENT` | `1.3` | Superlinear, so undoing an expensive ritual costs far more than a cantrip |
| `FORGET_SHARDS_PER_KP` | `2` | Crystal shards charged per knowledge point refunded |
| `FORGET_GRACE_PERIOD` | `300` | Seconds after learning during which forgetting is free |

Astral Vault costs are configured in `lua/arcana/astral_vault/config.lua`. Mana crystal growth, hotspot decay, and corruption escalation parameters are in `lua/arcana/system/mana_crystals.lua`.