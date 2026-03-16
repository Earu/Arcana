# Spell Fusion

This folder contains a prototype (`spell_fusion.lua`) that lets the Arcana
dynamically generate new "fusion spells" by combining two or more existing spells using the
Anthropic Claude API. The generated spell is a fully functional GLua spell file, not a template, but code
that runs on both server and client.

The file is **not** part of the addon. It lives here as a documented proof-of-concept.

## What it does

Given a list of spell IDs (e.g. `{ "fireball", "frost_nova" }`), the system:

1. Reads the Lua source of each component spell from `arcana/spells/`
2. Scans those sources for `ents.Create("arcana_...")` calls and also reads those entity (SENT) sources
3. Sends everything to Claude with a prompt requiring a **true fusion**, both mechanics and visual themes must be present simultaneously
4. Syntax-checks the output with `CompileString`
5. Runs it through a second Claude call (LLM-as-a-Judge) that scores security, correctness, quality, creativity, and fusion fidelity
6. Retries with feedback if any gate fails, up to `MAX_ATTEMPTS` times
7. Executes the final code server-side in a `setfenv` sandbox, then broadcasts it to clients who run it in their own sandbox

## Architecture

```
Fusion.Combine(spellIds)
│
├─ _FindSpellSourceFile()      read each component spell's .lua source
├─ _FindEntitySources()        scan for ents.Create("arcana_..."), read those SENT files
│
└─ _iterate() ─────────────── agent loop (up to MAX_ATTEMPTS)
    │
    ├─ _callAnthropic(generator)   Claude generates the fusion spell code
    │   └─ extended thinking enabled (THINKING_BUDGET tokens)
    │
    ├─ Gate 1: CompileString       syntax check — retries with error on fail
    │
    ├─ Gate 2: _callAnthropic(judge)   second Claude call scores the code
    │   └─ light thinking (JUDGE_THINKING_BUDGET tokens)
    │   └─ scores: security / correctness / quality / creativity / fusion
    │   └─ hard-fails: security < 8, fusion < 6, overall < 7.0
    │
    └─ _executeChunk()
        ├─ Fusion.CleanupAll()     tears down previous fusion first
        ├─ setfenv(sandbox)        runs inside restricted environment
        ├─ file.Write()            saves code to data/arcana_fusion/<id>.txt
        └─ net.Broadcast()         sends code string to all clients
```

---

## Framework internals

### Sandbox (`_CreateSandbox`)

Uses a **blacklist** approach: the generated code inherits all of `_G` via `__index`, but a set
of dangerous globals and sub-table methods are hidden:

| Blocked global / method | Reason |
|---|---|
| `HTTP`, `RunConsoleCommand`, `game.ConsoleCommand` | Server control |
| `concommand.Add` | Persistent command registration |
| `CompileString`, `RunString`, `CompileFile`, `require` | Arbitrary code execution |
| `file.Write`, `file.Delete`, `file.Append`, `file.Open` | Filesystem writes |
| `net.Start`, `net.Broadcast`, `net.Receive` | Raw net string access |
| `util.AddNetworkString` | Network pool pollution |
| `debug` | Sandbox escapes |

`Arcana:RegisterSpell` is wrapped so every registration is tracked in `_registeredIds` for
automatic cleanup.

### Hook wrapper (`_sandboxHook`)

Generated code calls `hook.Add` / `hook.Remove` normally, but the calls are routed through a
single real GMod hook per event (`Arcana_Fusion_<event>`). This means:

- No raw hook names leak into the global hook table
- All hooks are cleaned up in one pass during `Fusion.CleanupAll()`
- Each callback is individually `pcall`'d, a crashing callback is logged and removed without
  breaking other callbacks or the hook dispatcher

### Net wrapper (`Fusion.Broadcast` / `Fusion.Listen`)

Instead of registering new network strings at runtime (which is not possible post-load), all
server→client data travels over two static strings:

- `Arcana_FusionCode` - carries the full generated Lua source as a string; clients compile and
  execute it in their own sandbox on receipt
- `Arcana_FusionS2C` - carries a logical `id` (string) followed by arbitrary write data;
  `Fusion.Listen(id, fn)` registers a handler that is called when that id arrives

`Fusion.Broadcast`'s `writeCallback` is `pcall`'d; if it throws, `net.Abort()` discards the
half-written buffer so clients never receive corrupt data.

### Cleanup (`Fusion.CleanupAll`)

Called before every new fusion executes, on both server and client:

1. Removes all real GMod hook dispatchers registered by the previous fusion
2. Clears `_hookCallbacks`, `_dispatchers`, `_netListeners` tables
3. Nils out every entry in `Arcana.RegisteredSpells` that was registered by the previous fusion
4. Runs each `Fusion.Cleanup[id]` closure (LLM-generated) inside `pcall` to clear module-level
   render tables, timers, etc.

## LLM prompt design

### Generator system prompt

Gives the LLM only Arcana-specific context, it already knows GLua. Covers:

- `Arcana:RegisterSpell` field reference
- `SpellContext` fields
- Custom Arcana helper APIs (`BlastDamage`, `SendAttachBandVFX`, `LaunchProjectile`, etc.)
- Available entity classes and their common methods
- **Instance-override rule**: overriding methods on the spawned instance is fine;
  modifying the SENT class table (`scripted_ents.Get(...)` or `ENT.X = ...`) is forbidden
- `Fusion.Broadcast` / `Fusion.Listen` API
- `Fusion.Cleanup` mandatory closure pattern
- Hard constraint list (no raw net, no HTTP, no concommand, etc.)

### Generator user message

Built per-request. Contains:

1. Each component spell's full source, labeled `-- Component spell: <id>`
2. Each referenced entity's full SENT source, labeled `-- Entity SENT source (instance-override only): <class>`
   (auto-discovered by scanning the spell sources for `ents.Create("arcana_...")`)
3. A **true fusion** task description with explicit rules:
   - Extract core mechanic and visual theme from every component spell
   - Both must be simultaneously present in the result
   - Concrete example: `ring_of_fire + arcane_spear → ring of arcane spears`
   - Hard "DO NOT" list: no recolours, no ignoring a mechanic

### Judge

A separate Claude call (smaller thinking budget) returns structured JSON:

```json
{
  "security":    9,
  "correctness": 8,
  "quality":     7,
  "creativity":  8,
  "fusion":      7,
  "overall":     8.15,
  "passed":      true,
  "feedback":    ""
}
```

Weighted formula: `security×0.35 + correctness×0.30 + quality×0.10 + creativity×0.10 + fusion×0.15`

Hard-fail thresholds (any one fails → retry):

| Criterion | Minimum |
|---|---|
| `security` | 8 |
| `fusion` | 6 |
| `overall` | 7.0 |

The `fusion` score specifically measures whether **every** component spell's mechanic and visual
theme is recognisably present. A spell that is essentially one parent re-coloured scores 1–2 and
will always be rejected and retried with a `CRITICAL` note in the retry message.

---

## Configuration

| Constant | Default | Purpose |
|---|---|---|
| `API_MODEL` | `claude-sonnet-4-6` | Generator model |
| `JUDGE_MODEL` | `claude-sonnet-4-6` | Judge model |
| `MAX_ATTEMPTS` | `4` | Max agent loop iterations |
| `SCORE_PASS` | `7.0` | Minimum overall score |
| `SECURITY_MIN` | `8` | Minimum security score (hard-fail) |
| `FUSION_MIN` | `6` | Minimum fusion score (hard-fail) |
| `THINKING_BUDGET` | `8000` | Generator thinking tokens |
| `JUDGE_THINKING_BUDGET` | `2000` | Judge thinking tokens |
| `SPELL_IDS` | _(edit in file)_ | Component spells to fuse |

The API key is read from `_G.CLAUDE_API_KEY` at load time.

Generated spell code is saved to `data/arcana_fusion/<fusionId>.txt` for inspection.

## Known limitations and future directions

- **One active fusion at a time.** `CleanupAll` tears down the previous fusion before the new
  one runs. Supporting multiple simultaneous fusions would require per-fusion hook/net namespacing.
- **Net string size.** `Arcana_FusionCode` sends the full Lua source as a single net string.
  Very large generated files could hit GMod's net message size limit (~64 KB).
- **No persistence across map changes.** The fusion is re-generated from scratch each run. The
  saved `.txt` files in `data/arcana_fusion/` could be used as a cache in a future iteration.
- **Entity source scanning is static.** The regex scans for literal `ents.Create("arcana_...")`
  strings; dynamically constructed class names would not be detected.
- **Judge cannot run the code.** The judge scores based on static analysis only. A future
  improvement could be a lightweight GLua linter pass before the judge call.
- **Operational cost and scaling.** Every fusion request and judge call incurs usage fees on the Claude API (the thinking budgets are deliberately set quite high for best results), so frequent or large-scale use can become expensive. This approach is intended for low-throughput, single-user, or developer/research experimentation scenarios. It is not designed to scale to many users or mass spell generation at once.
