# research/

Prototypes and abandoned experiments. **Nothing here is loaded by the addon**, no file in
`lua/` references this folder, and that is intentional. It is kept as a record of what was
tried and why it was or was not adopted, so the same ground is not re-explored from scratch.

| Folder | Status | Summary |
| --- | --- | --- |
| [gpu_particles/](gpu_particles/) | Abandoned | Replicating GMod's particle system on the GPU with custom Source shaders. No measurable win over the CPU path, and the visuals could not be matched 1:1. |
| [spell_fusion/](spell_fusion/) | Proof of concept | Generating runnable fusion spells from two or more existing spells via the Claude API. Works, but not shipped. |
| [weapon_classification/](weapon_classification/) | Proof of concept | Static classification of any SWEP as hitscan / projectile / irrelevant without running it, plus a labelled dataset. |

Each folder has its own README with the full write-up. Because this code is not held to the
addon's quality bar, `research` is excluded from `desloppify` scans.
