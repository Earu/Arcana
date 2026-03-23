# Enchantment VFX Placement Model

## Background

Arcana is a Garry's Mod addon that adds a magic system to the game. One of its visual features
is **enchantment VFX**: when a weapon carries one or more enchantments, rotating magical rings
(`BandCircle` instances) are rendered around it — either aligned to the weapon's barrel axis
(`axis` style) or spinning freely around the player's hand (`orbital` style).

These rings must be positioned and oriented correctly relative to each weapon model at runtime.
The problem is that Garry's Mod weapons can be any arbitrary mesh authored by third parties, with
no enforced convention for how a weapon is oriented in model space, how large it is visually, or
where it should be considered "centered" from a gameplay perspective.

---

## The Problem

To place a ring correctly, three things need to be known per weapon model:

| Property | Description |
|---|---|
| `type` | Whether to use axis-aligned rings (`axis`) or spherical orbital rings (`orbital`) |
| `direction` | A normalized vector in the model's local space pointing along the main axis of the weapon (e.g. barrel direction for a rifle, blade direction for a sword) |
| `anchor` | A 3D offset in the model's local space from the model origin (`GetPos()`) to where the ring cluster should be centered |
| `radius` | The minimum radius in game units for the innermost ring |

### Current Heuristic and Its Failure Modes

The live code uses a set of runtime heuristics to approximate these values:

1. **Direction**: finds the longest axis of the weapon's OBB (oriented bounding box) and uses the
   corresponding local basis vector (`GetForward`, `GetRight`, or `GetUp`)
2. **Anchor**: uses `WorldSpaceCenter()` (the center of the OBB) as-is, or shifts it toward a
   muzzle attachment or hand bone when those are available
3. **Radius**: derived from the *shortest* OBB dimension multiplied by a fixed scalar
4. **Type**: determined by hold type classification (melee/pistol/rifle → `axis`, throwables → `orbital`)

These heuristics fail in well-understood ways:

- The longest OBB axis is not always the barrel axis (e.g. a crossbow that is wider than it is
  long, or a weapon modeled at a non-cardinal angle)
- `WorldSpaceCenter()` can be far from the intended visual center (e.g. a melee weapon should
  anchor near the hilt, not the OBB center)
- The OBB shortest dimension can be misleading for objects with inflated physics meshes (e.g.
  bugbait, grenades) causing rings that are far too large
- Hand bone (`ValveBiped.Bip01_R_Hand`) and muzzle attachment fallbacks are absent on many
  non-standard addon weapons

### Why a Lookup Table Alone Is Insufficient

Garry's Mod addons introduce hundreds to thousands of new weapon models. A static per-model
override table must be maintained manually and cannot cover weapons added by arbitrary Workshop
content that Arcana has no prior knowledge of. The goal is a model that generalizes to unseen
weapons using only geometry and metadata available at runtime.

---

## Proposed Solution

Train a machine learning model that, given geometric features extractable from any weapon entity
at runtime, predicts the four placement properties above. Predictions are cached per model path
so the cost is paid at most once per unique model per session.

A **per-model override table** (JSON) takes precedence over model predictions at all times,
allowing manual correction of any edge case without retraining.

---

## Output Schema

```json
{
  "type": "axis",
  "direction": [0.707, 0.0, 0.707],
  "anchor": [2.5, 0.0, -1.0],
  "radius": 5.5
}
```

| Field | Type | Description |
|---|---|---|
| `type` | `"axis"` \| `"orbital"` | Ring layout style |
| `direction` | `[x, y, z]` normalized | Main weapon axis in **model-local space** |
| `anchor` | `[x, y, z]` offset | Offset from `GetPos()` in model-local space to ring center |
| `radius` | `float` (game units) | Radius of the innermost (or only) ring |

`direction` and `anchor` are stored in model-local space so they are valid regardless of the
weapon's position or rotation in the world. At runtime:

```lua
local worldDir    = wep:GetForward() * dir.x + wep:GetRight() * dir.y + wep:GetUp() * dir.z
local worldAnchor = wep:LocalToWorld(anchorOffset)
```

For `orbital` type, `direction` is unused and the anchor is the sole ring position.

---

## Feature Extraction

All features are extractable from the weapon entity at runtime using the GMod Lua API. No file
I/O or offline processing is required during inference.

### Geometric features (from OBB)

| Feature | Source |
|---|---|
| `len_x`, `len_y`, `len_z` | `OBBMaxs() - OBBMins()` per axis |
| `ratio_xy`, `ratio_xz`, `ratio_yz` | Pairwise ratios of the above |
| `volume` | `len_x * len_y * len_z` |
| `sphericity` | `min / max` of the three lengths — near 1.0 for grenades, bugbait, orbs |
| `longest_axis_index` | 0/1/2 integer — which local axis is longest |

### Muzzle attachment features

| Feature | Source |
|---|---|
| `has_muzzle` | Boolean — whether any of the candidate attachment names resolves |
| `muzzle_local_dir` | `[x, y, z]` — attachment forward transformed to model-local space |
| `muzzle_local_offset` | `[x, y, z]` — attachment position relative to `GetPos()` in local space |
| `muzzle_dist_from_center` | Scalar — distance from `WorldSpaceCenter()` to muzzle |

Candidate attachment names searched in order:
`"muzzle"`, `"muzzle_flash"`, `"muzzle_flash1"`, `"muzzle_end"`, `"barrel"`, `"tip"`, `"fire"`,
`"nozzle"`, `"1"`, `"0"`

### Skeleton features

| Feature | Source |
|---|---|
| `has_hand_bone` | Boolean — whether `ValveBiped.Bip01_R_Hand` resolves |
| `grip_to_center_offset` | `[x, y, z]` — vector from hand bone to `WorldSpaceCenter()` in local space, or zero if absent |

### Metadata features

| Feature | Source |
|---|---|
| `holdtype` | One-hot encoded: `melee`, `pistol`, `rifle`, `grenade`, `other` |
| `is_viewmodel` | Boolean — whether the entity is a `CBaseViewModel` |

The `is_viewmodel` flag allows a single model to cover both world models (`w_` prefix) and view
models (`v_` prefix). The underlying barrel direction is the same for both; only absolute scale
and anchor offset differ, and scale is normalized out by the ratio features.

---

## Label Schema

Labels are stored per model path in `enchant_vfx_labeled.json`:

```json
{
  "models/weapons/w_rifle_ak47.mdl": {
    "type": "axis",
    "direction": [1.0, 0.0, 0.0],
    "anchor": [3.0, 0.0, 0.0],
    "radius": 4.2,
    "source": "auto_muzzle"
  }
}
```

The `source` field tracks label provenance:

| Value | Meaning |
|---|---|
| `"auto_muzzle"` | Derived automatically from muzzle attachment (no human review needed) |
| `"auto_bone"` | Derived from hand bone + muzzle position |
| `"manual"` | Set explicitly using the labeling tool |
| `"override"` | Manually corrected after auto-label was found to be wrong |

---

## Labeling Methodology

### Tier 1 — Automatic labels (free)

For any weapon where a muzzle attachment resolves:

- **`direction`**: transform `attachment.Ang:Forward()` into model-local space
- **`anchor`**: project the attachment position into model-local space and store as offset from
  `GetPos()`
- **`radius`**: distance from `WorldSpaceCenter()` to the attachment position, projected onto the
  plane perpendicular to `direction`, clamped to a sane range

These labels are continuous (not snapped to cardinal axes) and provide dense training signal for
the majority of ranged weapons. They still require a one-time spot-check pass to flag outliers
where the attachment is positioned unusually.

### Tier 2 — Interactive labeling tool

An in-game Lua tool (`enchant_vfx_labeler.lua`) for manual annotation and correction.

The tool renders a live preview of the rings on the weapon using current label values, and
provides controls to adjust:

- **Direction**: a free 3D rotation gizmo (two-axis drag) — the ring plane visually tracks the
  arrow so the annotator sees the consequence directly
- **Anchor**: a draggable point along world axes, stored in local space internally — the ring
  cluster moves as it is dragged
- **Radius**: a scroll-wheel radius slider with a live ring preview
- **Type**: a toggle key switching between `axis` and `orbital` visual modes

A single keypress confirms and writes to `enchant_vfx_labeled.json`. The estimated annotation
rate for experienced reviewers is 40–80 weapons per hour.

### Tier 3 — Edge case categories requiring manual annotation

The following categories have no reliable automatic signal and must be manually labeled:

- Thrown items with inflated physics meshes (grenades, bugbait, magical orbs)
- Melee weapons with non-standard geometry (polearms, chainsaws, claws)
- Weapons mounted on non-humanoid NPCs with no ValveBiped skeleton
- Weapons with no standard muzzle attachment and ambiguous OBB geometry

---

## Model Architecture

### Why not PointNet or a heavy 3D network

The full mesh vertex data is not readily accessible at runtime in Lua without offline pre-processing
(`.mdl` parsing via external tools such as Crowbar). The feature set described above is extractable
entirely at runtime, making a lightweight model strongly preferable.

### Recommended: MLP or Gradient Boosted Trees on handcrafted features

Input dimensionality is approximately **25–30 features** after one-hot encoding. At this scale,
a small MLP (2–3 hidden layers, 64–128 units each) or a gradient boosted tree ensemble
(XGBoost / LightGBM) will train quickly and generalize well with a few hundred labeled examples.

### Output heads

| Head | Task | Loss |
|---|---|---|
| `type` | Binary classification | Cross-entropy |
| `direction` | 3D unit vector regression | Cosine similarity loss (normalize output at inference) |
| `anchor` | 3D offset regression | MSE in local-space units |
| `radius` | Scalar regression | MSE or Huber loss |

`direction` and `anchor` share the same backbone with separate prediction heads. `type` and
`radius` can be co-trained or trained separately.

### Expected generalization behaviour

| Output | Generalization difficulty | Reasoning |
|---|---|---|
| `type` | Low — easy | Hold type + sphericity is highly predictive |
| `direction` | Low — easy | OBB ratios + muzzle direction encode barrel orientation reliably |
| `radius` | Medium | Normalized OBB ratios should transfer; raw scale does not |
| `anchor` | Medium | Clusters well by weapon class (rifle: center-barrel, melee: hilt-end, grenade: center); outliers handled by override table |

---

## Runtime Integration

Predictions are resolved once per unique model path and cached for the session. The fallback
hierarchy, in priority order:

1. **Per-model override table** (`enchant_vfx_overrides.json`) — highest confidence, manually curated
2. **Model prediction** — inferred from extracted features at first encounter
3. **Muzzle attachment heuristic** — used as a sanity check; if prediction strongly disagrees
   with a present muzzle attachment, the attachment wins
4. **OBB longest-axis heuristic** — current live fallback, retained as last resort

The model output is baked as a Lua table at startup (or on first weapon encounter) and accessed
as a dictionary lookup for zero per-frame cost.

---

## Files

| File | Purpose |
|---|---|
| `enchant_vfx_labeler.lua` | In-game interactive annotation tool |
| `enchant_vfx_labeled.json` | Human-reviewed and auto-derived labels |
| `enchant_vfx_overrides.json` | Final per-model overrides (highest priority at runtime) |
| `enchant_vfx_features.lua` | Feature extraction module (shared by labeler and runtime) |
| `README.md` | This document |

---

## Dataset Targets

| Metric | Target |
|---|---|
| Total labeled weapons | ≥ 500 (≥ 300 auto, remainder manual) |
| Direction prediction cosine similarity | ≥ 0.97 on held-out set |
| Type classification accuracy | ≥ 95 % |
| Radius prediction median absolute error | ≤ 1.5 game units |
| Override table coverage (known outliers) | 100 % of manually identified edge cases |
