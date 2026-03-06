# Arcana

***We like fireballs and stuff.***

Arcana is a magic mod for Garry's Mod, it comes with spells, enchantments and rituals that can be extended or integrated with various gamemodes.

## Integrating with Arcana

Arcana ships with a built-in coin and item inventory system. To integrate with an existing economy (DarkRP, PointShop2, a custom database, etc.), override any of the following functions:

```lua
-- Example: DarkRP integration
function Arcana:GiveCoins(ply, amount) ply:addMoney(amount) end
function Arcana:TakeCoins(ply, amount) ply:addMoney(-amount) end
function Arcana:GetCoins(ply) return ply:getDarkRPVar("money") end
```

Full examples for DarkRP, PointShop2, MySQL, and custom database backends are documented in [`lua/arcana/third_party.lua`](lua/arcana/third_party.lua).

### Persistence Hook Overrides

To replace the default SQLite persistence entirely, return `true` from any of these hooks to suppress Arcana's default behavior:

| Hook | Description |
|---|---|
| `Arcana_SavePlayerDataToSQL(ply, data)` | Override player data saving |
| `Arcana_LoadPlayerDataFromSQL(ply, callback)` | Override player data loading |
| `Arcana_ReadAstralVault(ply, callback)` | Override vault reading |
| `Arcana_WriteAstralVault(ply, items)` | Override vault writing |

## Extending Arcana

### Registering a Spell

```lua
Arcana:RegisterSpell({
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
Arcana:RegisterRitualSpell({
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
Arcana:RegisterEnchantment({
    id = "my_enchantment",
    name = "My Enchantment",
    description = "Enchants a weapon with something.",
    icon = "materials/arcana/enchantments/my_enchant.png",
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

## Hooks

Arcana fires the following hooks that other addons can listen to:

| Hook | Realm | Description |
|---|---|---|
| `Arcana_PlayerGainedXP` | Server | Player gained XP |
| `Arcana_PlayerLevelUp` | Server | Player leveled up |
| `Arcana_ClientLevelUp` | Client | Client-side level up event |
| `Arcana_SpellUnlocked` | Server | Player unlocked a spell |
| `Arcana_CanUnlockSpell` | Server | Override whether a spell can be unlocked |
| `Arcana_BeginCasting` | Server | Player started casting a spell |
| `Arcana_CastSpell` | Server | A spell is being cast |
| `Arcana_CastSpellFailure` | Server | A spell cast failed |
| `Arcana_CanCastSpell` | Server | Override whether a spell can be cast |
| `Arcana_SpellCastSucceeded` | Server | A spell was cast successfully |
| `Arcana_CanApplyEnchantment` | Server | Override whether an enchantment can be applied |
| `Arcana_AppliedEnchantment` | Server | An enchantment was applied to a weapon |
| `Arcana_RemovedEnchantment` | Server | An enchantment was removed from a weapon |
| `Arcana_SavedPlayerData` | Server | Player data was saved |
| `Arcana_LoadedPlayerData` | Server | Player data was loaded |
| `Arcana_SyncPlayerData` | Client | Player data was synced to the client |
| `Arcana_ItemRegistered` | Shared | An item was registered in the inventory system |

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

Astral Vault costs are configured in `lua/arcana/astral_vault/config.lua`. Mana crystal growth, hotspot decay, and corruption escalation parameters are in `lua/arcana/system/mana_crystals.lua`.