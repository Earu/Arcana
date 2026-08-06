# tools/

Developer scripts. None of these are loaded by the addon at runtime: the Lua ones are entry
points you load by hand from the in-game console, the Python ones are shell utilities. Their
output is committed art, not the scripts themselves.

## Asset pipelines

Both pipelines are two-stage: render at high resolution in-game (or with Pillow), then convert
to the shipped format on the shell side.

### Rings and glyphs

```
lua_openscript_cl arcana/tools/export_ring_pngs.lua
  -> garrysmod/data/arcana/ring_exports/*.png          (2048px rings, 1024px glyphs)

python3 tools/png_to_vtf.py <gmod>/garrysmod/data/arcana/ring_exports \
    --out materials/arcana/rings
python3 tools/png_to_vtf.py <gmod>/garrysmod/data/arcana/ring_exports/glyphs \
    --out materials/arcana/glyphs
```

The PNGs are the authoring format and are not kept in the repo. Only the DXT5 VTFs ship:
`Material()` on a PNG uploads mipless BGRA8888 and costs ~3x the VRAM. See the header of
[png_to_vtf.py](png_to_vtf.py) for the measurements behind that choice.

### Spawnicons

```
lua_openscript    arcana/tools/export_spawnicons.lua   -- server half: staging
lua_openscript_cl arcana/tools/export_spawnicons.lua   -- client half: rig + capture
arcana_spawnicon_setup                                 -- stage every subject
arcana_export_spawnicons [class]                       -- batch, or one class
  -> garrysmod/data/arcana/spawnicon_exports/*.png     (ScrH x ScrH squares)

python3 tools/build_spawnicons.py \
    <gmod>/garrysmod/data/arcana/spawnicon_exports --out materials/entities
```

`arcana_spawnicon_preview <class>` tunes a single shot without writing files.
`arcana_spawnicon_reset` is the panic button if a run leaves the screen black.

These stay PNG rather than becoming VTFs: the spawnmenu looks icons up by the literal path
`materials/entities/<class>.png`.

## Standalone scripts

| Script | What it does |
| --- | --- |
| [export_glyphs.py](export_glyphs.py) | Renders the 8 Pulsian runic glyphs from `resource/fonts/pulsian.ttf` to PNGs. Only needed to regenerate glyphs outside the in-game exporter. |
| [export_currency_icons.py](export_currency_icons.py) | Draws the coin and crystal shard icons into `materials/arcana/icons/`. White silhouettes, tinted in-engine. |
| [debug_attachments.lua](debug_attachments.lua) | Labels attachment points on the held weapon. `lua_openscript_cl`, then `arcana_debug_attachments 1`. |

The Python scripts need Pillow (`pip install pillow`).

## shadercompile/

`ShaderCompile.exe`, invoked by [../shaders/compile.sh](../shaders/compile.sh) under wine to
rebuild `shaders/fxc/*.vcs` from the HLSL sources. Run it after editing any `.hlsl`.
