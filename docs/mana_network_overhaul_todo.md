## Mana Network: Corruption and Success Logic Overhaul

### Goals
- Make excessive device density (purifiers, stabilizers, enchanters, etc.) increase draw from crystals and cause corruption when overdraw exceeds regional regen.
- Derive enchant success from local mana quality (purity/stability field), not specific entity counts.
- Allow any entity to contribute purity/stability/throughput (entity-agnostic providers).

### Purity/Stability Field (entity-agnostic)
- Replace hard-coded processor types with provider contributions.
- Providers register with payload: `{ purity_bonus, stability_bonus, throughput_bonus, radius, falloff }`.
- Compute consumer-local purity/stability from nearby providers (distance-weighted with falloff), clamped 0..1.
- Cache or compute per-tick (0.5–1.0s) for consumers; avoid per-frame work.

### Success Rate From Quality (not counts)
- Update `arcana_enchanter`:
  - `ComputeSuccessChance(purity, stability)` uses a mapping, e.g.: `chance = base + k1*purity + k2*stability`, clamped ≤ 1.0.
  - Stop using `min(#stab,#pur)`; use the field purity/stability already NW’d to clients for UI.
- Expose tunables in enchanter: `base_success`, `purity_coeff`, `stability_coeff`.

### Corruption Based on Net Overdraw (devices included)
- Current: corruption increases if crystals’ desired absorb > `regionRegenPerSecond`.
- New: include consumer extraction sourced from crystals in that region.
  - For each region per tick:
    - `supply = regionRegenPerSecond`.
    - `demand = crystals_absorb_need + consumer_intake_sourced_from_region` (proportional split when a consumer is linked to multiple regions/crystals).
    - If `demand > supply`, increase region corruption by `(demand - supply) * corruptionOverdrawFactor` per second.
- Add config: `corruptionOverdrawFactor` and optionally scale with overdraw magnitude.
- Only non-full crystals and active consumer draw are counted.

### Throughput Scaling
- Keep unbounded intake scaling at the consumer: `intake = baseIntake * (1 + perProcessorThroughputBonus * totalProvidersNearConsumer)`.
- Quality clamped at 1.0; no implicit caps.

### API and Data Model Changes
- Generalize node registration in `mana_network`:
  - `RegisterNode(ent, { range, intake, purity_bonus, stability_bonus, throughput_bonus, radius, falloff })`.
  - Maintain existing producer/consumer roles; treat any entity with bonuses as a provider.
- Remove/deprecate stage-specific terminology from config and code paths.
- Config keys:
  - `perProcessorThroughputBonus`, `perProcessorPurity`, `perProcessorStability`, new: `providerFalloff`, `corruptionOverdrawFactor`.

### Implementation Touchpoints
- `lua/arcana/mana_network.lua`
  - Add provider registry and distance-weighted field aggregation.
  - Compute region net overdraw inclusive of consumer intake and update corruption.
  - Replace count-based purity/stability with field value at consumer position.
- `lua/entities/arcana_enchanter.lua`
  - Use purity/stability field for `ComputeSuccessChance`.
  - Keep `GetManaCostPerEnchant` in enchanter.

### Visualization
- Mana flow glyph color already reflects purity/stability; consider modulating density/alpha by throughput.

### Testing Matrix
- Single/dual/many crystals per region; verify corruption rises only when `demand > supply`.
- Vary provider densities and ensure success rate follows quality, not specific entity classes.
- Multiple consumers linked to shared crystals; verify proportional sourcing and corruption scaling.

