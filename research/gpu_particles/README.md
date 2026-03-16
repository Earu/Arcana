# GPU Particle System

This folder contains a prototype (`gpu_particles.lua`) that attempts to replicate Garry's Mod's
CPU-side particle system entirely on the GPU using custom Source Engine vertex and pixel shaders,
with the goal of eliminating the CPU bottleneck present in GMod's native particle rendering.

The experiment was **abandoned**. No meaningful performance gains were observed over the standard
CPU particle path, and it was not possible to faithfully match the visual output of GMod's built-in
particles 1:1. The files are preserved here as a documented proof-of-concept.

## Goal

Replace GMod's `ParticleEmitter` CPU particle pipeline with a fully GPU-driven
system where all per-particle simulation (physics, lifetime, billboarding, rotation, fading) runs
inside a shader, leaving the CPU responsible only for uploading the initial particle mesh
once and setting a handful of shader constants per frame.

## Approach

### Data layout

All per-particle data is baked into a static `IMesh` at spawn time, one quad (4 vertices) per
particle. No per-frame CPU updates are performed after construction. Each vertex carries:

| Semantic | Contents |
|---|---|
| `POSITION` | `x` = particle ID, `yz` = quad corner offset (±0.5) |
| `TEXCOORD0` | `x` = birth time (relative, negative = born in the past), `y` = roll delta (deg/sec) |
| `TANGENT` | `xy` = quad UV, `z` = lifetime multiplier, `w` = initial roll angle |
| `NORMAL` | `xyz` = initial velocity |
| `COLOR` | base RGBA color |

Particles are staggered in birth time across the full lifetime range so the system loops
continuously without any CPU re-emission logic.

### Vertex shader (`arcana_particles_vs30.hlsl`)

For every vertex the shader:

1. Extracts particle ID, birth time, initial velocity, roll, and quad corner from the packed vertex attributes
2. Computes the looped particle age via `fmod(currentTime - birthTime, lifetime)`
3. Simulates physics: exponential velocity decay (air resistance `v(t) = v₀ · e^(−kt)`) plus
   simplified quadratic gravity
4. Interpolates size between `startSize` and `endSize` over the normalised lifetime, multiplied by
   a `sin(life · π)` fade curve so particles ease in and out
5. Calculates billboard orientation by extracting camera right/up vectors from the view-projection
   matrix, then rotates the quad corner by the current roll angle before applying the billboard offset
6. Interpolates alpha between `startAlpha` and `endAlpha`, also modulated by the same sine fade curve

Shader constants (time, lifetime, sizes, alphas) are passed to the vertex shader through the
**ambient cube registers** (`cAmbientCubeX`, slots 0–1) via `render.SetModelLighting`, a workaround
needed because Garry's Mod provides no direct mechanism to set custom vertex shader float constants
from Lua. A hidden zero-scale clientside model is drawn each frame solely to force the engine to
commit the lighting constants before the mesh draw call.

### Pixel shader (`arcana_particles_ps30.hlsl`)

Minimal: samples `TexBase` with the interpolated quad UVs, multiplies by the vertex color (which
carries the per-particle alpha computed by the vertex shader), and discards fully transparent
fragments.

### Material / render state

- Shader: `screenspace_general` base with custom `$vertexshader` / `$pixshader` overrides
- Blending: `BLEND_SRC_ALPHA` → `BLEND_ONE` (additive) via `render.OverrideBlend`
- Depth: test enabled, write disabled via `render.OverrideDepthEnable`
- No backface culling (`$cull 0`)

## Architecture

```
Arcana.GPUParticles.Create(config)
│
├─ GPUParticleSystem:CreateMaterial()   build screenspace_general material with custom shaders
│   └─ force texture load via Material():GetTexture → SetTexture
│
├─ GPUParticleSystem:BuildMesh()        bake all particles into a static IMesh (quads)
│   └─ stagger birth times across [-lifetime, 0] for continuous looping
│
└─ GPUParticleSystem:Draw()             called every frame
    ├─ render.SetModelLighting(0/1, …)  push time/lifetime/sizes/alphas into ambient cube regs
    ├─ dummyModel:DrawModel()           force engine to commit lighting constants
    ├─ cam.PushModelMatrix(spawnPos)    position the particle system in world space
    ├─ self.mesh:Draw()                 single GPU draw call for all particles
    └─ cam.PopModelMatrix()
```

## Why it was abandoned

- **No measurable performance gain.** The CPU was not the bottleneck in the scenarios tested.
  GMod's CPU particle path is fast enough for typical spell effect counts, and the overhead of the
  ambient-cube constant hack, the dummy model draw, and the render state overrides per system
  largely negated any theoretical GPU-side savings.

- **Visual fidelity gap.** GMod's `ParticleEmitter` provides per-particle texture animation,
  lighting, collision, and operator-based behaviours that are impractical to replicate fully in a
  static vertex shader without a much more complex data layout and additional render passes.

- **Shader constant limitations.** Source Engine's Lua API does not expose arbitrary vertex shader
  float constants. Routing data through the ambient cube registers is fragile, limited to 6 float3
  slots, and conflicts with engine lighting passes, requiring the dummy-model workaround that adds
  its own per-frame cost.

## Configuration

`Arcana.GPUParticles.Create` accepts a config table:

| Field | Default | Description |
|---|---|---|
| `maxParticles` | `500` | Number of particles in the pool |
| `lifetime` | `2.0` | Base lifetime in seconds |
| `spawnPosition` | `Vector(0,0,0)` | World-space origin |
| `spawnRadius` | `25` | Random spawn offset radius (units) |
| `velocity` | `Vector(0,0,100)` | Base initial velocity |
| `velocityVariance` | `25` | Per-axis velocity randomisation |
| `gravity` | `Vector(0,0,15)` | Constant acceleration |
| `airResistance` | `40` | Exponential drag coefficient |
| `particleSize` | `20` | Start size (units) |
| `sizeVariance` | `0.5` | Size randomisation factor |
| `endSize` | _(= startSize)_ | End size; interpolated over lifetime |
| `startAlpha` | `255` | Alpha at birth |
| `endAlpha` | `0` | Alpha at death |
| `roll` | `0` | Initial rotation variance (±degrees) |
| `rollDelta` | `0` | Rotation speed variance (±deg/sec) |
| `color` | `Color(255,255,255)` | Base color (±20 per channel variance) |
| `texture` | `"effects/fire_cloud1"` | Material base texture path |

Four built-in presets are provided in `Arcana.GPUParticles.Presets`: `Fire`, `MagicLevitation`,
`Embers`, and `Sparkles`.

## Files

| File | Purpose |
|---|---|
| `gpu_particles.lua` | Lua-side particle system: mesh construction, material setup, per-frame draw |
| `arcana_particles_vs30.hlsl` | Vertex shader: physics simulation, billboarding, size/alpha interpolation |
| `arcana_particles_ps30.hlsl` | Pixel shader: texture sampling and vertex color application |

## Usage

```lua
lua_openscript_cl gpu_particles.lua
```

```lua
local particles = Arcana.GPUParticles.Create(Arcana.GPUParticles.Presets.Fire)

hook.Add("PostDrawOpaqueRenderables", "TestGPUParticles", function()
    particles:Draw()
end)
```

Shaders must be compiled and distributed via `shader_to_gma` before the system will function.
The server-side block of `gpu_particles.lua` registers `arcana_particles_vs30` and
`arcana_particles_ps30` as shader resources for automatic client download.
