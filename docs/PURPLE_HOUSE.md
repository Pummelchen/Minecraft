# Purple House Datapack

Version: **Minecraft Java 26.1.2**

The pack is now a **staged manual build** flow with vanilla functions.

## Install

- Copy `server-datapacks/pummelchen-purple-house.zip` into:
  `.minecraft/saves/<your world>/datapacks/`
- Run:

```mcfunction
/reload
```

## Build

Build on your stand position (centered on the front stair path):

```mcfunction
/function purple_house:exterior
/function purple_house:interior
```

Or run both in one go:

```mcfunction
/function purple_house:complete
```

To fully clear the generated area:

```mcfunction
/function purple_house:erase
```

## Notes

- `exterior` builds the outside/terraces, decks, façade, roofs, stairs, lanterns,
  landscaping and shell details first.
- `interior` fills rooms and add-on structure details after the shell is complete.
- Namespace compatibility includes both `data/purple_house/function` and
  `data/purple_house/functions`.
- Backup your world first before running the build.
- This package is **not** a worldgen random-spread structure pack.

## Current project files

- `server-datapacks/pummelchen-purple-house.zip` — deployable datapack.
- `server-datapacks-src/pummelchen-purple-house/` — source contents for this build.
- `server-datapacks-src/custom_datapacks.json` — server registration metadata.
- `scripts/build_purple_house_datapack.py` — validates source and zip are in sync.

Quality check examples:

```bash
python3 scripts/build_purple_house_datapack.py --check
python3 scripts/sync_custom_datapacks.py --project-dir . --check
bash scripts/validate_project.sh
```
