# SWEP Weapon Classifier

## Goal

Automatically classify any Garry's Mod scripted weapon (SWEP) as one of four outcomes **without
running it**:

| Label | Meaning |
|---|---|
| `HITSCAN` | Fires instant-hit bullets via `Entity:FireBullets` |
| `PROJECTILE` | Spawns a physical projectile entity via `ents.Create` |
| `IRRELEVANT` | Not a combat ranged weapon (melee, tool, gadget, utility item) |
| `BROKEN` | Weapon exists in the registry but is non-functional or crashes |

The target accuracy threshold was **≥ 90 %** against a human-labeled ground-truth dataset.

## Dataset

### Weapon selection

Weapons were collected by mounting a large number of **randomly selected Workshop addon packs**
covering a wide variety of weapon categories: military rifles, sci-fi blasters, CS:GO ports,
TF2 ports, throwable grenades, bows, crossbows, melee weapons, utility gadgets, and more.
No cherry-picking was performed, any pack that added SWEPs to the `weapons` list was fair game.

The full list of mounted Workshop addons used to produce the dataset is recorded in
`weapon_dataset_addons.json` (exported via the snippet at the bottom of
`weapon_classification.lua`). Each entry contains the Workshop ID (`wsid`) and title so the exact
dataset can be reproduced by subscribing to the same addons.

### Ground truth file

`weapon_dataset_labeled.json`, labels explicitly assigned by a human reviewer using
the interactive labeling tool (`weapon_labeler.lua`). Only weapons touched by the reviewer appear
here; the rest fall back to the original file.

### Labeling methodology

1. The **weapon labeler** (`weapon_labeler.lua`) was used to go through the dataset weapon by
   weapon in-game.
2. Each weapon was given to the player, fired at least once, and then labeled based on observed
   behavior.
3. Labels `BROKEN` and `IRRELEVANT` were available for weapons that crashed, malfunctioned, or
   were clearly non-ranged (melee, tools, utility items).

Total dataset size at time of writing: **~1 100 weapons**, of which **~963 were usable**
(spawnable and covered by the ground truth).

## Decision Tree - `weapon_classification.lua`

The classifier works entirely through **static source analysis** at runtime. No weapon is fired;
only the Lua source code of the weapon's functions is inspected.

### Classification pipeline

```
Given a SWEP table:

1. Check hold type
   ├── melee / melee2 / knife / fist / normal / passive  →  IRRELEVANT
   └── grenade holdtype, or class name contains "grenade"/"nade"  →  PROJECTILE

2. Scan WEAPON:PrimaryAttack recursively
   ├── Found  Entity:FireBullets   →  HITSCAN  (stop)
   └── Found  ents.Create(<scripted entity>)  →  PROJECTILE  (stop)

3. If PrimaryAttack is a thin stub (no custom method calls):
   └── Scan WEAPON:Think for ents.Create  →  PROJECTILE if found

4. Default  →  HITSCAN
```

### Key design decisions

- **FireBullets takes priority over ents.Create.** Shotguns that eject shell casings call
  `ents.Create` after `FireBullets`; without this priority the shell would cause a false
  `PROJECTILE` result.

- **`ents.Create` is filtered.** Only calls that create a *scripted* entity
  (`scripted_ents.GetStored` returns non-nil) are treated as projectiles. Engine entities like
  `"ai_sound"` or `"env_fire"` are ignored.

- **Recursive call-chain traversal.** `WEAPON:PrimaryAttack` often delegates to a helper method
  (`self:ShootProjectile()`, etc.). The algorithm follows `self:Method()` calls up to `MAX_DEPTH`
  levels deep, skipping native metatable methods (`Entity`, `Weapon`) and all standard
  `WEAPON_Hooks` overrides to avoid false positives.

- **All Lua call syntaxes are covered.** Pattern matching handles `func()`, `func "str"`,
  `func 'str'`, `func [[str]]`, and `func { }` call forms.

- **One-tick deferred evaluation.** The accuracy benchmark spawns a temporary weapon entity and
  defers holdtype / source analysis by one tick (`timer.Simple(0, ...)`) so that `Initialize`,
  `SetupDataTables`, and `SetWeaponHoldType` have all executed before the check runs.

- **Cycle detection.** A `visited` table keyed by `"file:line"` prevents infinite recursion in
  weapons whose helper methods call each other.

### Accuracy progression

| Milestone | Accuracy |
|---|---|
| Initial implementation (`ents.Create` only) | ~baseline |
| Add `FireBullets` hitscan detection | improvement |
| Filter engine entities from `ents.Create` | improvement |
| Add `WEAPON.Think` fallback for deferred projectiles | 73 % |
| Add `WEAPON_HOOKS` exclusion table | improvement |
| Expand Lua call-syntax patterns | improvement |
| Add hold-type irrelevancy filter + grenade class-name check | 88 % |
| One-tick deferred spawn evaluation | **93 %** ✓ |

The 90 % target was reached and exceeded under **testing conditions** (local server, full addon set
mounted). Accuracy in production is expected to be higher because `WEAPON:Deploy()` was not called during testing, but
in live condition that will be the case which causes holdtypes to be more reliable.

---

## Files

| File | Purpose |
|---|---|
| `weapon_classification.lua` | Main classifier + accuracy benchmark |
| `weapon_labeler.lua` | In-game interactive labeling UI |
| `weapon_dataset_labeled.json` | Human-reviewed labels (save file) |
| `weapon_dataset_addons.json` | Workshop addon IDs used to build the dataset |

## Usage

### Running the accuracy benchmark

```
lua_openscript weapon_classification.lua
```

Results are printed to console. Failures are listed as `className  TRUTH  PREDICTED`.

### Running the labeling tool

```
lua_openscript    weapon_labeler.lua   -- server side
lua_openscript_cl weapon_labeler.lua   -- client side (shows UI)
```

Then in console: `wl_start` to begin.

### Exporting the addon list

Uncomment the addon-export block at the bottom of `is_projectile_gun.lua` and run:

```
lua_openscript_cl weapon_classification.lua
```

Output goes to `data/weapon_dataset_addons.json`.
