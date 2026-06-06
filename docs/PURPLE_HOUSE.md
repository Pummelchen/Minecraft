# Purple House

## Reference Frame Analysis

Source: `https://www.youtube.com/watch?v=gL_4xJ6TO7g`

The requested reference reads as a large survival compound rather than a small
cabin:

- Wide, symmetrical front composition with two broad side staircases.
- Raised lower deck wrapping the building front and side wings.
- Central multi-floor house volume with a steep gable roof.
- Stone-and-wood support rhythm under the decks.
- Courtyard focal point in front of the entrance, shown as a square pool.
- Side utility zones that look like farms, storage, or work bays.
- Dense rails, lanterns, potted plants, hanging greenery, and flower accents.

The Pummelchen version keeps that massing and survival-house role, then shifts
the color story toward purple where it does not weaken the silhouette: purpur
roofing, purple terracotta walls, purple glass, amethyst floor inlays, purple
carpet, purple bed, and allium-heavy flower beds.

## 3D Plan

Coordinate plan uses the structure's local origin at the northwest lower corner.
The finished NBT footprint is `57 x 32 x 57` blocks.

```text
Y 25-31  Purple gable roof, polished deepslate ridge/trim
Y 18-24  Upper roof shell over central house
Y 13-18  Upper living floor: bedroom, balcony, bookshelves, work desk
Y 12-14  Left/right roof terraces: flower planters and wheat patches
Y  7-12  Main floor: kitchen, dining/living room, purple glass, front doors
Y  6-7   Raised deck wrapping house and side wings
Y  1-5   Basement: storage, enchanting, smelting, quartz stair access
Y  0-1   Courtyard, paths, flower beds, pool, foundation
```

```text
Top view, X/Z:

  0        16        28        40        56
0 +------------------------------------------------+
  | flowers / grass / approach paths               |
8 |                upper house volume              |
12|      left wing     central hall      right wing |
34|      deck and front double entrance             |
40|  left stairs     courtyard pool     right stairs|
56+------------------------------------------------+
```

## Generation Density

The datapack adds one random-spread placement cell every `108` chunks.

- `108 chunks * 16 blocks = 1,728 blocks`
- `1,728 * 1,728 = 2,985,984 square blocks`
- Minecraft blocks are treated as square meters, so the cell is about
  `2.986 km2`, effectively one Purple House per 3 square kilometers.

Biome targeting is `#minecraft:is_overworld`, so compatible overworld mod biomes
can receive the structure when they advertise that tag.

## Interior Direction

The generated structure uses vanilla block IDs for boot and worldgen safety.
That avoids hard failures if a decorative mod changes registry names. The design
is still based on what the Pummelchen server already carries:

- ModernArch makes the vanilla shell and purple/glass/quartz palette read more
  polished on clients.
- Macaw's Furniture and MrCrayfish's Furniture Mod: Refurbished are the intended
  optional upgrade path for sofas, kitchen counters, wardrobes, desks, and
  balcony seating.
- Cooking for Blockheads maps naturally to the generated kitchen zone.
- Display Case, PTS-Deco, and Luxury Building Pack can replace the vanilla
  bookshelves, barrels, slabs, and utility displays after generation.

## Project Files

- `server-datapacks/pummelchen-purple-house.zip` is the deployable datapack.
- `server-datapacks-src/pummelchen-purple-house/` is generated source content.
- `server-datapacks-src/custom_datapacks.json` registers the pack as
  `Purple House` in the SQLite-backed mod collection.
- `scripts/build_purple_house_datapack.py` rebuilds and checks the zip.
- `scripts/sync_custom_datapacks.py` installs the zip into
  `server-datapacks`, mirrors it into the active world datapacks folder when
  present, and upserts the tracker row.

Quality gate:

```bash
python3 scripts/build_purple_house_datapack.py --check
python3 scripts/sync_custom_datapacks.py --project-dir . --check
bash scripts/validate_project.sh
```
