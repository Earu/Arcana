# tools/

Developer scripts, none loaded by the addon. The Lua ones are console entry points, the Python
ones are shell utilities. Python scripts need Pillow.

## Rings and glyphs

```
lua_openscript_cl arcana/tools/export_ring_pngs.lua
  -> garrysmod/data/arcana/ring_exports/*.png       (2048px rings, 1024px glyphs)

python3 tools/png_to_vtf.py <gmod>/garrysmod/data/arcana/ring_exports \
    --out materials/arcana/rings
python3 tools/png_to_vtf.py <gmod>/garrysmod/data/arcana/ring_exports/glyphs \
    --out materials/arcana/glyphs
```

Only the VTFs ship. See [png_to_vtf.py](png_to_vtf.py) for why.

## Spawnicons

```
lua_openscript    arcana/tools/export_spawnicons.lua   -- server: staging
lua_openscript_cl arcana/tools/export_spawnicons.lua   -- client: rig + capture
arcana_spawnicon_setup
arcana_export_spawnicons [class]
  -> garrysmod/data/arcana/spawnicon_exports/*.png     (ScrH x ScrH)

python3 tools/build_spawnicons.py \
    <gmod>/garrysmod/data/arcana/spawnicon_exports --out materials/entities
```

`arcana_spawnicon_preview <class>` tunes one shot without writing files.
`arcana_spawnicon_reset` if a run leaves the screen black.

These stay PNG: the spawnmenu looks icons up at `materials/entities/<class>.png`.

## Standalone

| Script | Does |
| --- | --- |
| [export_glyphs.py](export_glyphs.py) | Pulsian glyphs to PNG, from `resource/fonts/pulsian.ttf`. |
| [export_currency_icons.py](export_currency_icons.py) | Coin and shard icons into `materials/arcana/icons/`. |
| [debug_attachments.lua](debug_attachments.lua) | Attachment markers on the held weapon. `lua_openscript_cl`, then `arcana_debug_attachments 1`. |

## shadercompile/

`ShaderCompile.exe`, run by [../shaders/compile.sh](../shaders/compile.sh) under wine to rebuild
`shaders/fxc/*.vcs`. Run after editing any `.hlsl`.
