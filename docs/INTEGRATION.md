# Third-party integration

Arcana ships its own economy and inventory in
[`system/default_inventory.lua`](../lua/arcana/system/default_inventory.lua). Override the
functions below, or the persistence hooks, to back it with your own. Override after Arcana has
loaded, from an `Initialize` hook.

## Economy API

| Function | Realm | Returns |
| --- | --- | --- |
| `Arcana.GetCoins(ply)` | shared | number |
| `Arcana.GetItemCount(ply, itemClass)` | shared | number |
| `Arcana.GiveCoins(ply, amount, reason)` | server | `true` on success |
| `Arcana.TakeCoins(ply, amount, reason)` | server | `false` if the player cannot afford it |
| `Arcana.GiveItem(ply, itemClass, amount, reason)` | server | `true` on success |
| `Arcana.TakeItem(ply, itemClass, amount, reason)` | server | `false` if the player lacks the items |

`reason` is free-form, for your own logging.

`TakeCoins` and `TakeItem` must return `false` rather than going negative. ~25 call sites treat
`false` as "cannot afford" and abort the purchase.

The client branch of `GetCoins` / `GetItemCount` must work without a round trip: UI
affordability checks call it every frame.

### DarkRP

```lua
hook.Add("Initialize", "YourAddon_ArcanaCompat", function()
    function Arcana.GiveCoins(ply, amount, reason)
        if not IsValid(ply) or amount <= 0 then return false end
        ply:addMoney(amount)
        return true
    end

    function Arcana.TakeCoins(ply, amount, reason)
        if not IsValid(ply) or amount <= 0 then return false end
        if ply:getDarkRPVar("money") < amount then return false end
        ply:addMoney(-amount)
        return true
    end

    function Arcana.GetCoins(ply)
        if SERVER then
            return IsValid(ply) and ply:getDarkRPVar("money") or 0
        end
        return LocalPlayer():getDarkRPVar("money") or 0
    end
end)
```

### PointShop 2

```lua
hook.Add("Initialize", "YourAddon_ArcanaCompat", function()
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
        end
        return LocalPlayer():PS2_GetItemCount(itemClass) or 0
    end
end)
```

### Wrapping instead of replacing

`Arcana` is a namespace, not a class. Everything on it is a plain dot function, no `self`.

```lua
local oldRegisterItem = Arcana.RegisterItem
function Arcana.RegisterItem(itemClass, itemData)
    print("Registering item:", itemClass)
    oldRegisterItem(itemClass, itemData)
end
```

## Registering items

```lua
Arcana.RegisterItem("mystic_gem", {
    name = "Mystic Gem",
    description = "A rare gemstone with mysterious properties.",
    model = "models/props_junk/rock001a.mdl",
    material = nil,               -- optional material override
    color = Color(255, 100, 255), -- optional tint
    draw = nil,                   -- optional function(modelPanel, w, h) for custom rendering
})
```

## Persistence hooks

These are dispatched through `Arcana.RunHook`, which prefixes every name with `Arcana_`.
**Listen for the prefixed name**: `hook.Add("SavePlayerDataToSQL", ...)` never fires.

Return `true` to suppress Arcana's own SQL path.

### Player data

```lua
-- data: xp, level, knowledge_points, unlocked_spells,
--       quickspell_slots, selected_quickslot, last_save
hook.Add("Arcana_SavePlayerDataToSQL", "YourAddonName", function(ply, data, authoritative)
    YourDB:SavePlayerData(ply:SteamID64(), data)
    return true
end)

hook.Add("Arcana_LoadPlayerDataFromSQL", "YourAddonName", function(ply, callback)
    YourDB:LoadPlayerData(ply:SteamID64(), function(loadedData)
        callback(true, loadedData)
    end)
    return true
end)
```

`authoritative` marks a save that may overwrite a newer row. Non-authoritative saves merge, so
a slow load cannot roll progression back.

Call `callback` on **every** path including failure (`callback(false)`), or
`Arcana_LoadedPlayerData` and everything behind it stalls.

### Astral Vault

```lua
hook.Add("Arcana_ReadAstralVault", "YourAddonName", function(ply, callback)
    YourDB:LoadVaultData(ply:SteamID64(), function(vaultItems)
        Arcana.AstralVaultCache[ply:SteamID64()] = vaultItems
        callback(true, vaultItems)
    end)
    return true
end)

hook.Add("Arcana_WriteAstralVault", "YourAddonName", function(ply, items)
    YourDB:SaveVaultData(ply:SteamID64(), items)
    return true
end)
```

`items` is an array of vault entries, each carrying weapon info and enchantments.

### Spellcraft activations

Definitions live in the player's client file. The server only records what they unlocked and
consecrated *here*:

```lua
{
    essences      = { fire = true, frost = true },   -- essences bought on this server
    consecrations = { ["<defhash>"] = true },        -- crafted spells consecrated here
}
```

```lua
hook.Add("Arcana_ReadSpellcraftState", "YourAddonName", function(ply, callback)
    YourDB:LoadSpellcraft(ply:SteamID64(), function(state)
        callback(true, state)
    end)
    return true
end)

hook.Add("Arcana_WriteSpellcraftState", "YourAddonName", function(ply, state)
    YourDB:SaveSpellcraft(ply:SteamID64(), state)
    return true
end)
```

Consecration is keyed by defhash, not by slot, so re-importing the same build stays
consecrated. Both sets only grow, which is why the default write is append-only.

Call `callback` on every path including failure. A player whose state fails to load finds their
crafted spells locked, not deleted: both checks fail closed.
