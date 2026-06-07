# Purple House - Interior stage for Minecraft Java 26.1.2.
# Run this after /function purple_house:exterior.
tellraw @a {"text": "Purple House: interior stage started.", "color": "light_purple"}
# Clean interior spaces without touching exterior shell
fill ~-16 ~3 ~1 ~16 ~6 ~29 air
fill ~-14 ~8 ~3 ~14 ~13 ~27 air
fill ~3 ~15 ~5 ~14 ~19 ~23 air
fill ~-14 ~15 ~7 ~-4 ~19 ~21 air
fill ~-3 ~15 ~10 ~4 ~17 ~23 air
# Floors and ceilings restored
fill ~-16 ~2 ~1 ~16 ~2 ~29 polished_deepslate
fill ~-14 ~7 ~3 ~14 ~7 ~27 spruce_planks
fill ~-14 ~14 ~3 ~14 ~14 ~27 spruce_planks
fill ~3 ~14 ~5 ~14 ~14 ~23 spruce_planks
fill ~-14 ~14 ~7 ~-4 ~14 ~21 spruce_planks
fill ~-3 ~14 ~10 ~4 ~14 ~23 spruce_planks
fill ~4 ~20 ~5 ~12 ~20 ~13 spruce_planks
fill ~-12 ~20 ~8 ~-6 ~20 ~16 spruce_planks
# Basement: storage, workshop, and crystal cellar
fill ~ ~3 ~2 ~ ~6 ~28 stripped_spruce_log[axis=y]
fill ~ ~3 ~13 ~ ~5 ~17 air
setblock ~-14 ~3 ~3 barrel[facing=south]
setblock ~-14 ~3 ~5 barrel[facing=south]
setblock ~-14 ~3 ~7 barrel[facing=south]
setblock ~-14 ~3 ~9 barrel[facing=south]
setblock ~14 ~3 ~3 barrel[facing=south]
setblock ~14 ~3 ~5 barrel[facing=south]
setblock ~14 ~3 ~7 barrel[facing=south]
setblock ~-13 ~3 ~25 chest[facing=north]
setblock ~-11 ~3 ~25 chest[facing=north]
setblock ~10 ~3 ~25 chest[facing=north]
setblock ~12 ~3 ~25 chest[facing=north]
setblock ~-7 ~3 ~25 crafting_table
setblock ~-6 ~3 ~25 smithing_table
setblock ~-5 ~3 ~25 stonecutter
setblock ~6 ~3 ~25 furnace[facing=north]
setblock ~7 ~3 ~25 blast_furnace[facing=north]
setblock ~8 ~3 ~25 smoker[facing=north]
fill ~-2 ~3 ~15 ~2 ~3 ~15 amethyst_block
setblock ~ ~4 ~15 amethyst_cluster[facing=up]
setblock ~-3 ~3 ~14 purple_candle[candles=3,lit=true]
setblock ~-3 ~3 ~16 purple_candle[candles=3,lit=true]
setblock ~3 ~3 ~14 purple_candle[candles=3,lit=true]
setblock ~3 ~3 ~16 purple_candle[candles=3,lit=true]
setblock ~-10 ~6 ~2 lantern[hanging=true]
setblock ~10 ~6 ~2 lantern[hanging=true]
setblock ~-10 ~6 ~28 lantern[hanging=true]
setblock ~10 ~6 ~28 lantern[hanging=true]
setblock ~ ~6 ~15 lantern[hanging=true]
# Main floor layout: foyer, living room, kitchen, dining
fill ~-1 ~8 ~4 ~-1 ~12 ~25 stripped_spruce_log[axis=y]
fill ~-1 ~8 ~10 ~-1 ~11 ~13 air
fill ~6 ~8 ~12 ~6 ~12 ~27 stripped_spruce_log[axis=y]
fill ~6 ~8 ~17 ~6 ~11 ~20 air
fill ~1 ~8 ~4 ~8 ~8 ~9 purple_carpet
fill ~3 ~8 ~5 ~6 ~8 ~8 magenta_carpet
fill ~-12 ~8 ~6 ~-8 ~8 ~6 purple_wool
setblock ~-12 ~9 ~6 purple_carpet
setblock ~-11 ~9 ~6 purple_carpet
setblock ~-10 ~9 ~6 purple_carpet
setblock ~-9 ~9 ~6 purple_carpet
setblock ~-8 ~9 ~6 purple_carpet
setblock ~-10 ~8 ~8 dark_oak_stairs[facing=south]
setblock ~-12 ~8 ~9 dark_oak_stairs[facing=east]
setblock ~-8 ~8 ~9 dark_oak_stairs[facing=west]
setblock ~-10 ~8 ~10 spruce_fence
setblock ~-10 ~9 ~10 oak_pressure_plate
fill ~-4 ~8 ~26 ~1 ~12 ~27 bricks
fill ~-3 ~8 ~26 ~ ~10 ~26 air
setblock ~-2 ~8 ~26 campfire[lit=true]
setblock ~-1 ~8 ~26 campfire[lit=true]
fill ~-4 ~13 ~26 ~1 ~18 ~27 stone_bricks
setblock ~-5 ~8 ~18 spruce_fence
setblock ~-5 ~9 ~18 spruce_pressure_plate
setblock ~-4 ~8 ~18 spruce_fence
setblock ~-4 ~9 ~18 spruce_pressure_plate
setblock ~-3 ~8 ~18 spruce_fence
setblock ~-3 ~9 ~18 spruce_pressure_plate
setblock ~-2 ~8 ~18 spruce_fence
setblock ~-2 ~9 ~18 spruce_pressure_plate
setblock ~-6 ~8 ~18 spruce_stairs[facing=east,half=bottom]
setblock ~-1 ~8 ~18 spruce_stairs[facing=west,half=bottom]
setblock ~-4 ~8 ~16 spruce_stairs[facing=south,half=bottom]
setblock ~-4 ~8 ~20 spruce_stairs[facing=north,half=bottom]
fill ~8 ~8 ~24 ~13 ~8 ~24 smooth_quartz
setblock ~8 ~9 ~24 smooth_quartz_slab[type=top]
setblock ~9 ~9 ~24 smooth_quartz_slab[type=top]
setblock ~10 ~9 ~24 smooth_quartz_slab[type=top]
setblock ~11 ~9 ~24 smooth_quartz_slab[type=top]
setblock ~12 ~9 ~24 smooth_quartz_slab[type=top]
setblock ~13 ~9 ~24 smooth_quartz_slab[type=top]
setblock ~9 ~8 ~25 furnace[facing=north]
setblock ~10 ~8 ~25 smoker[facing=north]
setblock ~11 ~8 ~25 barrel[facing=north]
setblock ~12 ~8 ~25 cauldron
setblock ~13 ~8 ~25 crafting_table
setblock ~13 ~8 ~6 barrel[facing=up]
setblock ~13 ~9 ~6 potted_allium
setblock ~ ~13 ~8 lantern[hanging=true]
setblock ~-10 ~13 ~13 lantern[hanging=true]
setblock ~10 ~13 ~20 lantern[hanging=true]
# Interior staircase from main floor to second floor
setblock ~1 ~8 ~18 dark_oak_stairs[facing=north,half=bottom]
setblock ~2 ~8 ~18 dark_oak_stairs[facing=north,half=bottom]
setblock ~1 ~9 ~19 dark_oak_stairs[facing=north,half=bottom]
setblock ~2 ~9 ~19 dark_oak_stairs[facing=north,half=bottom]
setblock ~1 ~10 ~20 dark_oak_stairs[facing=north,half=bottom]
setblock ~2 ~10 ~20 dark_oak_stairs[facing=north,half=bottom]
setblock ~1 ~11 ~21 dark_oak_stairs[facing=north,half=bottom]
setblock ~2 ~11 ~21 dark_oak_stairs[facing=north,half=bottom]
setblock ~1 ~12 ~22 dark_oak_stairs[facing=north,half=bottom]
setblock ~2 ~12 ~22 dark_oak_stairs[facing=north,half=bottom]
setblock ~1 ~13 ~23 dark_oak_stairs[facing=north,half=bottom]
setblock ~2 ~13 ~23 dark_oak_stairs[facing=north,half=bottom]
setblock ~1 ~14 ~24 dark_oak_stairs[facing=north,half=bottom]
setblock ~2 ~14 ~24 dark_oak_stairs[facing=north,half=bottom]
setblock ~ ~15 ~24 spruce_fence
setblock ~1 ~15 ~24 spruce_fence
setblock ~2 ~15 ~24 spruce_fence
setblock ~3 ~15 ~24 spruce_fence
setblock ~4 ~15 ~24 spruce_fence
setblock ~ ~15 ~18 spruce_fence
setblock ~ ~15 ~19 spruce_fence
setblock ~ ~15 ~20 spruce_fence
setblock ~ ~15 ~21 spruce_fence
setblock ~ ~15 ~22 spruce_fence
setblock ~ ~15 ~23 spruce_fence
setblock ~ ~15 ~24 spruce_fence
setblock ~2 ~15 ~24 air
setblock ~1 ~15 ~24 air
# Second floor: bedroom, library, balcony landing
fill ~-2 ~15 ~11 ~4 ~15 ~22 purple_carpet
fill ~4 ~15 ~7 ~9 ~15 ~10 purple_carpet
setblock ~11 ~15 ~8 purple_bed[facing=east,part=foot]
setblock ~12 ~15 ~8 purple_bed[facing=east,part=head]
setblock ~10 ~15 ~7 barrel[facing=up]
setblock ~13 ~15 ~7 barrel[facing=up]
setblock ~10 ~16 ~7 lantern[hanging=false]
setblock ~13 ~16 ~7 lantern[hanging=false]
fill ~12 ~15 ~12 ~14 ~16 ~12 bookshelf
setblock ~12 ~15 ~14 flower_pot
setblock ~12 ~16 ~14 potted_allium
fill ~8 ~15 ~4 ~10 ~17 ~4 air
setblock ~8 ~15 ~4 dark_oak_door[facing=south,half=lower,hinge=left]
setblock ~8 ~16 ~4 dark_oak_door[facing=south,half=upper,hinge=left]
setblock ~9 ~15 ~4 dark_oak_door[facing=south,half=lower,hinge=right]
setblock ~9 ~16 ~4 dark_oak_door[facing=south,half=upper,hinge=right]
fill ~-13 ~15 ~18 ~-5 ~17 ~18 bookshelf
fill ~-13 ~15 ~8 ~-13 ~17 ~18 bookshelf
fill ~-5 ~15 ~8 ~-5 ~17 ~18 bookshelf
setblock ~-9 ~15 ~13 enchanting_table
fill ~-11 ~15 ~11 ~-7 ~15 ~15 purple_carpet
setblock ~-9 ~16 ~9 lantern[hanging=false]
setblock ~-9 ~18 ~13 lantern[hanging=true]
setblock ~-7 ~15 ~20 lectern[facing=north]
setblock ~-12 ~15 ~9 purple_bed[facing=west,part=foot]
setblock ~-13 ~15 ~9 purple_bed[facing=west,part=head]
setblock ~-11 ~15 ~8 barrel[facing=up]
# Attic lofts under purple gables
fill ~5 ~20 ~6 ~11 ~20 ~11 purple_carpet
setblock ~8 ~21 ~8 amethyst_block
setblock ~8 ~22 ~8 amethyst_cluster[facing=up]
setblock ~7 ~21 ~10 lectern[facing=south]
setblock ~9 ~21 ~10 bookshelf
setblock ~6 ~21 ~7 soul_lantern[hanging=false]
setblock ~10 ~21 ~7 soul_lantern[hanging=false]
fill ~-11 ~20 ~9 ~-7 ~20 ~14 magenta_carpet
setblock ~-9 ~21 ~12 dark_oak_stairs[facing=south]
setblock ~-10 ~21 ~12 dark_oak_stairs[facing=south]
setblock ~-9 ~21 ~10 bookshelf
setblock ~-10 ~21 ~10 bookshelf
setblock ~-8 ~21 ~13 lantern[hanging=false]
# Final decorative glow and signs of life
setblock ~-14 ~12 ~5 lantern[hanging=true]
setblock ~14 ~12 ~5 lantern[hanging=true]
setblock ~-14 ~12 ~26 lantern[hanging=true]
setblock ~14 ~12 ~26 lantern[hanging=true]
setblock ~4 ~19 ~6 lantern[hanging=true]
setblock ~14 ~19 ~22 lantern[hanging=true]
setblock ~-14 ~19 ~20 lantern[hanging=true]
setblock ~-13 ~8 ~4 potted_allium
setblock ~-12 ~8 ~4 potted_allium
setblock ~12 ~8 ~4 potted_allium
setblock ~13 ~8 ~4 potted_allium
setblock ~-4 ~8 ~23 potted_allium
setblock ~4 ~8 ~23 potted_allium
tellraw @a {"text": "Purple House: interior complete.", "color": "light_purple"}
