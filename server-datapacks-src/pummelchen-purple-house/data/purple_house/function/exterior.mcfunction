# Purple House - Exterior stage for Minecraft Java 26.1.2.
# Origin: stand at ground level in the center of the front stair path. The front door is built north of you.
tellraw @a {"text": "Purple House: exterior stage started.", "color": "light_purple"}
# Clear 45 x 49 x 39 volume in safe chunks
fill ~-22 ~ ~-12 ~22 ~12 ~36 air
fill ~-22 ~13 ~-12 ~22 ~25 ~36 air
fill ~-22 ~26 ~-12 ~22 ~38 ~36 air
# Ground, path, and raised terrace
fill ~-21 ~ ~-9 ~21 ~ ~35 grass_block
fill ~-20 ~1 ~-8 ~20 ~1 ~34 polished_deepslate
fill ~-18 ~2 ~-5 ~18 ~2 ~32 deepslate_tiles
fill ~-19 ~2 ~-6 ~19 ~2 ~-6 polished_blackstone_bricks
fill ~-19 ~2 ~33 ~19 ~2 ~33 polished_blackstone_bricks
fill ~-19 ~2 ~-6 ~-19 ~2 ~33 polished_blackstone_bricks
fill ~19 ~2 ~-6 ~19 ~2 ~33 polished_blackstone_bricks
fill ~-2 ~2 ~-11 ~2 ~2 ~-6 cobbled_deepslate
fill ~-1 ~2 ~-11 ~1 ~2 ~-6 polished_andesite
# Lower stone-and-wood level: visible raised basement
fill ~-17 ~3 ~ ~17 ~6 ~30 dark_oak_planks
fill ~-16 ~3 ~1 ~16 ~6 ~29 air
fill ~-17 ~2 ~ ~17 ~2 ~30 polished_deepslate
fill ~-17 ~7 ~ ~17 ~7 ~30 dark_oak_planks
fill ~-17 ~6 ~ ~17 ~6 ~ stripped_spruce_log[axis=x]
fill ~-17 ~3 ~ ~17 ~3 ~ polished_blackstone_bricks
fill ~-17 ~6 ~30 ~17 ~6 ~30 stripped_spruce_log[axis=x]
fill ~-17 ~3 ~30 ~17 ~3 ~30 polished_blackstone_bricks
fill ~-17 ~6 ~ ~-17 ~6 ~30 stripped_spruce_log[axis=z]
fill ~-17 ~3 ~ ~-17 ~3 ~30 polished_blackstone_bricks
fill ~17 ~6 ~ ~17 ~6 ~30 stripped_spruce_log[axis=z]
fill ~17 ~3 ~ ~17 ~3 ~30 polished_blackstone_bricks
# Main floor porch deck and walls
fill ~-18 ~7 ~-3 ~18 ~7 ~6 spruce_planks
fill ~-18 ~7 ~-3 ~18 ~7 ~-3 polished_blackstone_bricks
fill ~-18 ~7 ~6 ~18 ~7 ~6 polished_blackstone_bricks
fill ~-18 ~7 ~-3 ~-18 ~7 ~6 polished_blackstone_bricks
fill ~18 ~7 ~-3 ~18 ~7 ~6 polished_blackstone_bricks
fill ~-15 ~8 ~2 ~15 ~13 ~28 smooth_quartz
fill ~-14 ~8 ~3 ~14 ~13 ~27 air
fill ~-15 ~7 ~2 ~15 ~7 ~28 spruce_planks
fill ~-15 ~14 ~2 ~15 ~14 ~28 spruce_planks
# Upper wings and connector; asymmetrical photo-like massing
fill ~2 ~15 ~4 ~15 ~19 ~24 smooth_quartz
fill ~3 ~15 ~5 ~14 ~19 ~23 air
fill ~2 ~14 ~4 ~15 ~14 ~24 spruce_planks
fill ~2 ~20 ~4 ~15 ~20 ~24 spruce_planks
fill ~-15 ~15 ~6 ~-3 ~19 ~22 smooth_quartz
fill ~-14 ~15 ~7 ~-4 ~19 ~21 air
fill ~-15 ~14 ~6 ~-3 ~14 ~22 spruce_planks
fill ~-15 ~20 ~6 ~-3 ~20 ~22 spruce_planks
fill ~-4 ~15 ~9 ~5 ~17 ~24 smooth_quartz
fill ~-3 ~15 ~10 ~4 ~17 ~23 air
fill ~-4 ~14 ~9 ~5 ~14 ~24 spruce_planks
fill ~-4 ~18 ~9 ~5 ~18 ~24 spruce_planks
# Vertical white columns and dark timber trim
fill ~-17 ~3 ~ ~-17 ~13 ~ smooth_quartz
fill ~-17 ~3 ~30 ~-17 ~7 ~30 smooth_quartz
fill ~-9 ~3 ~ ~-9 ~13 ~ smooth_quartz
fill ~-9 ~3 ~30 ~-9 ~7 ~30 smooth_quartz
fill ~ ~3 ~ ~ ~13 ~ smooth_quartz
fill ~ ~3 ~30 ~ ~7 ~30 smooth_quartz
fill ~9 ~3 ~ ~9 ~13 ~ smooth_quartz
fill ~9 ~3 ~30 ~9 ~7 ~30 smooth_quartz
fill ~17 ~3 ~ ~17 ~13 ~ smooth_quartz
fill ~17 ~3 ~30 ~17 ~7 ~30 smooth_quartz
fill ~-17 ~3 ~ ~-17 ~13 ~ smooth_quartz
fill ~17 ~3 ~ ~17 ~13 ~ smooth_quartz
fill ~-17 ~3 ~8 ~-17 ~13 ~8 smooth_quartz
fill ~17 ~3 ~8 ~17 ~13 ~8 smooth_quartz
fill ~-17 ~3 ~16 ~-17 ~13 ~16 smooth_quartz
fill ~17 ~3 ~16 ~17 ~13 ~16 smooth_quartz
fill ~-17 ~3 ~24 ~-17 ~13 ~24 smooth_quartz
fill ~17 ~3 ~24 ~17 ~13 ~24 smooth_quartz
fill ~-17 ~3 ~30 ~-17 ~13 ~30 smooth_quartz
fill ~17 ~3 ~30 ~17 ~13 ~30 smooth_quartz
fill ~-15 ~8 ~2 ~-15 ~14 ~2 stripped_dark_oak_log[axis=y]
fill ~15 ~8 ~2 ~15 ~14 ~2 stripped_dark_oak_log[axis=y]
fill ~-15 ~8 ~28 ~-15 ~14 ~28 stripped_dark_oak_log[axis=y]
fill ~15 ~8 ~28 ~15 ~14 ~28 stripped_dark_oak_log[axis=y]
fill ~2 ~15 ~4 ~2 ~20 ~4 stripped_dark_oak_log[axis=y]
fill ~15 ~15 ~4 ~15 ~20 ~4 stripped_dark_oak_log[axis=y]
fill ~2 ~15 ~24 ~2 ~20 ~24 stripped_dark_oak_log[axis=y]
fill ~15 ~15 ~24 ~15 ~20 ~24 stripped_dark_oak_log[axis=y]
fill ~-15 ~15 ~6 ~-15 ~20 ~6 stripped_dark_oak_log[axis=y]
fill ~-3 ~15 ~6 ~-3 ~20 ~6 stripped_dark_oak_log[axis=y]
fill ~-15 ~15 ~22 ~-15 ~20 ~22 stripped_dark_oak_log[axis=y]
fill ~-3 ~15 ~22 ~-3 ~20 ~22 stripped_dark_oak_log[axis=y]
# Porch railings, lamps, and front columns
setblock ~-18 ~8 ~-3 spruce_fence
setblock ~-17 ~8 ~-3 spruce_fence
setblock ~-16 ~8 ~-3 spruce_fence
setblock ~-15 ~8 ~-3 spruce_fence
setblock ~-14 ~8 ~-3 spruce_fence
setblock ~-13 ~8 ~-3 spruce_fence
setblock ~-12 ~8 ~-3 spruce_fence
setblock ~-11 ~8 ~-3 spruce_fence
setblock ~-10 ~8 ~-3 spruce_fence
setblock ~-9 ~8 ~-3 spruce_fence
setblock ~-8 ~8 ~-3 spruce_fence
setblock ~-7 ~8 ~-3 spruce_fence
setblock ~-6 ~8 ~-3 spruce_fence
setblock ~-5 ~8 ~-3 spruce_fence
setblock ~8 ~8 ~-3 spruce_fence
setblock ~9 ~8 ~-3 spruce_fence
setblock ~10 ~8 ~-3 spruce_fence
setblock ~11 ~8 ~-3 spruce_fence
setblock ~12 ~8 ~-3 spruce_fence
setblock ~13 ~8 ~-3 spruce_fence
setblock ~14 ~8 ~-3 spruce_fence
setblock ~15 ~8 ~-3 spruce_fence
setblock ~16 ~8 ~-3 spruce_fence
setblock ~17 ~8 ~-3 spruce_fence
setblock ~18 ~8 ~-3 spruce_fence
setblock ~-18 ~8 ~-3 spruce_fence
setblock ~-18 ~8 ~-2 spruce_fence
setblock ~-18 ~8 ~-1 spruce_fence
setblock ~-18 ~8 ~ spruce_fence
setblock ~-18 ~8 ~1 spruce_fence
setblock ~-18 ~8 ~2 spruce_fence
setblock ~-18 ~8 ~3 spruce_fence
setblock ~-18 ~8 ~4 spruce_fence
setblock ~-18 ~8 ~5 spruce_fence
setblock ~-18 ~8 ~6 spruce_fence
setblock ~18 ~8 ~-3 spruce_fence
setblock ~18 ~8 ~-2 spruce_fence
setblock ~18 ~8 ~-1 spruce_fence
setblock ~18 ~8 ~ spruce_fence
setblock ~18 ~8 ~1 spruce_fence
setblock ~18 ~8 ~2 spruce_fence
setblock ~18 ~8 ~3 spruce_fence
setblock ~18 ~8 ~4 spruce_fence
setblock ~18 ~8 ~5 spruce_fence
setblock ~18 ~8 ~6 spruce_fence
fill ~-16 ~3 ~-2 ~-16 ~7 ~-2 smooth_quartz
setblock ~-16 ~8 ~-2 lantern[hanging=false]
fill ~-8 ~3 ~-2 ~-8 ~7 ~-2 smooth_quartz
setblock ~-8 ~8 ~-2 lantern[hanging=false]
fill ~ ~3 ~-2 ~ ~7 ~-2 smooth_quartz
setblock ~ ~8 ~-2 lantern[hanging=false]
fill ~8 ~3 ~-2 ~8 ~7 ~-2 smooth_quartz
setblock ~8 ~8 ~-2 lantern[hanging=false]
fill ~16 ~3 ~-2 ~16 ~7 ~-2 smooth_quartz
setblock ~16 ~8 ~-2 lantern[hanging=false]
# Grand front staircase rising to porch
fill ~4 ~2 ~-8 ~14 ~2 ~-8 polished_blackstone_brick_stairs[facing=south,half=bottom]
fill ~4 ~3 ~-7 ~14 ~3 ~-7 polished_blackstone_brick_stairs[facing=south,half=bottom]
fill ~4 ~2 ~-7 ~14 ~2 ~-7 polished_blackstone_bricks
fill ~4 ~4 ~-6 ~14 ~4 ~-6 polished_blackstone_brick_stairs[facing=south,half=bottom]
fill ~4 ~2 ~-6 ~14 ~3 ~-6 polished_blackstone_bricks
fill ~4 ~5 ~-5 ~14 ~5 ~-5 polished_blackstone_brick_stairs[facing=south,half=bottom]
fill ~4 ~2 ~-5 ~14 ~4 ~-5 polished_blackstone_bricks
fill ~4 ~6 ~-4 ~14 ~6 ~-4 polished_blackstone_brick_stairs[facing=south,half=bottom]
fill ~4 ~2 ~-4 ~14 ~5 ~-4 polished_blackstone_bricks
fill ~4 ~7 ~-3 ~14 ~7 ~-3 polished_blackstone_brick_stairs[facing=south,half=bottom]
fill ~4 ~2 ~-3 ~14 ~6 ~-3 polished_blackstone_bricks
fill ~3 ~2 ~-8 ~3 ~7 ~-3 polished_blackstone_bricks
fill ~15 ~2 ~-8 ~15 ~7 ~-3 polished_blackstone_bricks
fill ~4 ~7 ~-3 ~14 ~7 ~-3 deepslate_tiles
# Second-floor balcony
fill ~3 ~14 ~1 ~15 ~14 ~5 spruce_planks
fill ~3 ~14 ~1 ~15 ~14 ~1 polished_blackstone_bricks
setblock ~3 ~15 ~1 spruce_fence
setblock ~4 ~15 ~1 spruce_fence
setblock ~5 ~15 ~1 spruce_fence
setblock ~6 ~15 ~1 spruce_fence
setblock ~12 ~15 ~1 spruce_fence
setblock ~13 ~15 ~1 spruce_fence
setblock ~14 ~15 ~1 spruce_fence
setblock ~15 ~15 ~1 spruce_fence
setblock ~3 ~15 ~1 spruce_fence
setblock ~3 ~15 ~2 spruce_fence
setblock ~3 ~15 ~3 spruce_fence
setblock ~3 ~15 ~4 spruce_fence
setblock ~3 ~15 ~5 spruce_fence
setblock ~15 ~15 ~1 spruce_fence
setblock ~15 ~15 ~2 spruce_fence
setblock ~15 ~15 ~3 spruce_fence
setblock ~15 ~15 ~4 spruce_fence
setblock ~15 ~15 ~5 spruce_fence
fill ~3 ~8 ~1 ~3 ~14 ~1 smooth_quartz
fill ~9 ~8 ~1 ~9 ~14 ~1 smooth_quartz
fill ~15 ~8 ~1 ~15 ~14 ~1 smooth_quartz
# Steep purple roofs, gable faces, and roof ridges
fill ~1 ~20 ~3 ~16 ~20 ~3 smooth_quartz
fill ~2 ~21 ~3 ~15 ~21 ~3 smooth_quartz
fill ~3 ~22 ~3 ~14 ~22 ~3 smooth_quartz
fill ~4 ~23 ~3 ~13 ~23 ~3 smooth_quartz
fill ~5 ~24 ~3 ~12 ~24 ~3 smooth_quartz
fill ~6 ~25 ~3 ~11 ~25 ~3 smooth_quartz
fill ~7 ~26 ~3 ~10 ~26 ~3 smooth_quartz
fill ~8 ~27 ~3 ~9 ~27 ~3 smooth_quartz
fill ~ ~20 ~2 ~ ~20 ~26 purpur_stairs[facing=east,half=bottom]
fill ~17 ~20 ~2 ~17 ~20 ~26 purpur_stairs[facing=west,half=bottom]
fill ~ ~19 ~2 ~ ~19 ~26 purple_concrete
fill ~17 ~19 ~2 ~17 ~19 ~26 purple_concrete
fill ~1 ~21 ~2 ~1 ~21 ~26 purpur_stairs[facing=east,half=bottom]
fill ~16 ~21 ~2 ~16 ~21 ~26 purpur_stairs[facing=west,half=bottom]
fill ~1 ~20 ~2 ~1 ~20 ~26 purple_concrete
fill ~16 ~20 ~2 ~16 ~20 ~26 purple_concrete
fill ~2 ~22 ~2 ~2 ~22 ~26 purpur_stairs[facing=east,half=bottom]
fill ~15 ~22 ~2 ~15 ~22 ~26 purpur_stairs[facing=west,half=bottom]
fill ~2 ~21 ~2 ~2 ~21 ~26 purple_concrete
fill ~15 ~21 ~2 ~15 ~21 ~26 purple_concrete
fill ~3 ~23 ~2 ~3 ~23 ~26 purpur_stairs[facing=east,half=bottom]
fill ~14 ~23 ~2 ~14 ~23 ~26 purpur_stairs[facing=west,half=bottom]
fill ~3 ~22 ~2 ~3 ~22 ~26 purple_concrete
fill ~14 ~22 ~2 ~14 ~22 ~26 purple_concrete
fill ~4 ~24 ~2 ~4 ~24 ~26 purpur_stairs[facing=east,half=bottom]
fill ~13 ~24 ~2 ~13 ~24 ~26 purpur_stairs[facing=west,half=bottom]
fill ~4 ~23 ~2 ~4 ~23 ~26 purple_concrete
fill ~13 ~23 ~2 ~13 ~23 ~26 purple_concrete
fill ~5 ~25 ~2 ~5 ~25 ~26 purpur_stairs[facing=east,half=bottom]
fill ~12 ~25 ~2 ~12 ~25 ~26 purpur_stairs[facing=west,half=bottom]
fill ~5 ~24 ~2 ~5 ~24 ~26 purple_concrete
fill ~12 ~24 ~2 ~12 ~24 ~26 purple_concrete
fill ~6 ~26 ~2 ~6 ~26 ~26 purpur_stairs[facing=east,half=bottom]
fill ~11 ~26 ~2 ~11 ~26 ~26 purpur_stairs[facing=west,half=bottom]
fill ~6 ~25 ~2 ~6 ~25 ~26 purple_concrete
fill ~11 ~25 ~2 ~11 ~25 ~26 purple_concrete
fill ~7 ~27 ~2 ~7 ~27 ~26 purpur_stairs[facing=east,half=bottom]
fill ~10 ~27 ~2 ~10 ~27 ~26 purpur_stairs[facing=west,half=bottom]
fill ~7 ~26 ~2 ~7 ~26 ~26 purple_concrete
fill ~10 ~26 ~2 ~10 ~26 ~26 purple_concrete
fill ~8 ~28 ~2 ~8 ~28 ~26 purpur_stairs[facing=east,half=bottom]
fill ~9 ~28 ~2 ~9 ~28 ~26 purpur_stairs[facing=west,half=bottom]
fill ~8 ~27 ~2 ~8 ~27 ~26 purple_concrete
fill ~9 ~27 ~2 ~9 ~27 ~26 purple_concrete
fill ~8 ~29 ~2 ~9 ~29 ~26 amethyst_block
fill ~-1 ~19 ~1 ~18 ~19 ~1 polished_blackstone_brick_slab[type=top]
fill ~-1 ~19 ~27 ~18 ~19 ~27 polished_blackstone_brick_slab[type=top]
fill ~-16 ~20 ~6 ~-2 ~20 ~6 smooth_quartz
fill ~-15 ~21 ~6 ~-3 ~21 ~6 smooth_quartz
fill ~-14 ~22 ~6 ~-4 ~22 ~6 smooth_quartz
fill ~-13 ~23 ~6 ~-5 ~23 ~6 smooth_quartz
fill ~-12 ~24 ~6 ~-6 ~24 ~6 smooth_quartz
fill ~-11 ~25 ~6 ~-7 ~25 ~6 smooth_quartz
fill ~-10 ~26 ~6 ~-8 ~26 ~6 smooth_quartz
fill ~-9 ~27 ~6 ~-9 ~27 ~6 smooth_quartz
fill ~-17 ~20 ~5 ~-17 ~20 ~24 purpur_stairs[facing=east,half=bottom]
fill ~-1 ~20 ~5 ~-1 ~20 ~24 purpur_stairs[facing=west,half=bottom]
fill ~-17 ~19 ~5 ~-17 ~19 ~24 purple_concrete
fill ~-1 ~19 ~5 ~-1 ~19 ~24 purple_concrete
fill ~-16 ~21 ~5 ~-16 ~21 ~24 purpur_stairs[facing=east,half=bottom]
fill ~-2 ~21 ~5 ~-2 ~21 ~24 purpur_stairs[facing=west,half=bottom]
fill ~-16 ~20 ~5 ~-16 ~20 ~24 purple_concrete
fill ~-2 ~20 ~5 ~-2 ~20 ~24 purple_concrete
fill ~-15 ~22 ~5 ~-15 ~22 ~24 purpur_stairs[facing=east,half=bottom]
fill ~-3 ~22 ~5 ~-3 ~22 ~24 purpur_stairs[facing=west,half=bottom]
fill ~-15 ~21 ~5 ~-15 ~21 ~24 purple_concrete
fill ~-3 ~21 ~5 ~-3 ~21 ~24 purple_concrete
fill ~-14 ~23 ~5 ~-14 ~23 ~24 purpur_stairs[facing=east,half=bottom]
fill ~-4 ~23 ~5 ~-4 ~23 ~24 purpur_stairs[facing=west,half=bottom]
fill ~-14 ~22 ~5 ~-14 ~22 ~24 purple_concrete
fill ~-4 ~22 ~5 ~-4 ~22 ~24 purple_concrete
fill ~-13 ~24 ~5 ~-13 ~24 ~24 purpur_stairs[facing=east,half=bottom]
fill ~-5 ~24 ~5 ~-5 ~24 ~24 purpur_stairs[facing=west,half=bottom]
fill ~-13 ~23 ~5 ~-13 ~23 ~24 purple_concrete
fill ~-5 ~23 ~5 ~-5 ~23 ~24 purple_concrete
fill ~-12 ~25 ~5 ~-12 ~25 ~24 purpur_stairs[facing=east,half=bottom]
fill ~-6 ~25 ~5 ~-6 ~25 ~24 purpur_stairs[facing=west,half=bottom]
fill ~-12 ~24 ~5 ~-12 ~24 ~24 purple_concrete
fill ~-6 ~24 ~5 ~-6 ~24 ~24 purple_concrete
fill ~-11 ~26 ~5 ~-11 ~26 ~24 purpur_stairs[facing=east,half=bottom]
fill ~-7 ~26 ~5 ~-7 ~26 ~24 purpur_stairs[facing=west,half=bottom]
fill ~-11 ~25 ~5 ~-11 ~25 ~24 purple_concrete
fill ~-7 ~25 ~5 ~-7 ~25 ~24 purple_concrete
fill ~-10 ~27 ~5 ~-10 ~27 ~24 purpur_stairs[facing=east,half=bottom]
fill ~-8 ~27 ~5 ~-8 ~27 ~24 purpur_stairs[facing=west,half=bottom]
fill ~-10 ~26 ~5 ~-10 ~26 ~24 purple_concrete
fill ~-8 ~26 ~5 ~-8 ~26 ~24 purple_concrete
fill ~-9 ~28 ~5 ~-9 ~28 ~24 purpur_slab[type=top]
fill ~-9 ~29 ~5 ~-9 ~29 ~24 amethyst_block
fill ~-18 ~19 ~4 ~ ~19 ~4 polished_blackstone_brick_slab[type=top]
fill ~-18 ~19 ~25 ~ ~19 ~25 polished_blackstone_brick_slab[type=top]
fill ~-7 ~18 ~2 ~7 ~18 ~2 smooth_quartz
fill ~-6 ~19 ~2 ~6 ~19 ~2 smooth_quartz
fill ~-5 ~20 ~2 ~5 ~20 ~2 smooth_quartz
fill ~-4 ~21 ~2 ~4 ~21 ~2 smooth_quartz
fill ~-3 ~22 ~2 ~3 ~22 ~2 smooth_quartz
fill ~-2 ~23 ~2 ~2 ~23 ~2 smooth_quartz
fill ~-1 ~24 ~2 ~1 ~24 ~2 smooth_quartz
fill ~-8 ~18 ~1 ~-8 ~18 ~29 purpur_stairs[facing=east,half=bottom]
fill ~8 ~18 ~1 ~8 ~18 ~29 purpur_stairs[facing=west,half=bottom]
fill ~-8 ~17 ~1 ~-8 ~17 ~29 purple_concrete
fill ~8 ~17 ~1 ~8 ~17 ~29 purple_concrete
fill ~-7 ~19 ~1 ~-7 ~19 ~29 purpur_stairs[facing=east,half=bottom]
fill ~7 ~19 ~1 ~7 ~19 ~29 purpur_stairs[facing=west,half=bottom]
fill ~-7 ~18 ~1 ~-7 ~18 ~29 purple_concrete
fill ~7 ~18 ~1 ~7 ~18 ~29 purple_concrete
fill ~-6 ~20 ~1 ~-6 ~20 ~29 purpur_stairs[facing=east,half=bottom]
fill ~6 ~20 ~1 ~6 ~20 ~29 purpur_stairs[facing=west,half=bottom]
fill ~-6 ~19 ~1 ~-6 ~19 ~29 purple_concrete
fill ~6 ~19 ~1 ~6 ~19 ~29 purple_concrete
fill ~-5 ~21 ~1 ~-5 ~21 ~29 purpur_stairs[facing=east,half=bottom]
fill ~5 ~21 ~1 ~5 ~21 ~29 purpur_stairs[facing=west,half=bottom]
fill ~-5 ~20 ~1 ~-5 ~20 ~29 purple_concrete
fill ~5 ~20 ~1 ~5 ~20 ~29 purple_concrete
fill ~-4 ~22 ~1 ~-4 ~22 ~29 purpur_stairs[facing=east,half=bottom]
fill ~4 ~22 ~1 ~4 ~22 ~29 purpur_stairs[facing=west,half=bottom]
fill ~-4 ~21 ~1 ~-4 ~21 ~29 purple_concrete
fill ~4 ~21 ~1 ~4 ~21 ~29 purple_concrete
fill ~-3 ~23 ~1 ~-3 ~23 ~29 purpur_stairs[facing=east,half=bottom]
fill ~3 ~23 ~1 ~3 ~23 ~29 purpur_stairs[facing=west,half=bottom]
fill ~-3 ~22 ~1 ~-3 ~22 ~29 purple_concrete
fill ~3 ~22 ~1 ~3 ~22 ~29 purple_concrete
fill ~-2 ~24 ~1 ~-2 ~24 ~29 purpur_stairs[facing=east,half=bottom]
fill ~2 ~24 ~1 ~2 ~24 ~29 purpur_stairs[facing=west,half=bottom]
fill ~-2 ~23 ~1 ~-2 ~23 ~29 purple_concrete
fill ~2 ~23 ~1 ~2 ~23 ~29 purple_concrete
fill ~-1 ~25 ~1 ~-1 ~25 ~29 purpur_stairs[facing=east,half=bottom]
fill ~1 ~25 ~1 ~1 ~25 ~29 purpur_stairs[facing=west,half=bottom]
fill ~-1 ~24 ~1 ~-1 ~24 ~29 purple_concrete
fill ~1 ~24 ~1 ~1 ~24 ~29 purple_concrete
fill ~ ~26 ~1 ~ ~26 ~29 purpur_slab[type=top]
fill ~ ~27 ~1 ~ ~27 ~29 amethyst_block
fill ~-9 ~17 ~ ~9 ~17 ~ polished_blackstone_brick_slab[type=top]
fill ~-9 ~17 ~30 ~9 ~17 ~30 polished_blackstone_brick_slab[type=top]
fill ~-8 ~18 ~28 ~8 ~18 ~28 smooth_quartz
fill ~-7 ~19 ~28 ~7 ~19 ~28 smooth_quartz
fill ~-6 ~20 ~28 ~6 ~20 ~28 smooth_quartz
fill ~-5 ~21 ~28 ~5 ~21 ~28 smooth_quartz
fill ~-4 ~22 ~28 ~4 ~22 ~28 smooth_quartz
fill ~-3 ~23 ~28 ~3 ~23 ~28 smooth_quartz
fill ~-2 ~24 ~28 ~2 ~24 ~28 smooth_quartz
# Dark stepped gable trim
setblock ~ ~20 ~2 polished_blackstone_bricks
setblock ~17 ~20 ~2 polished_blackstone_bricks
setblock ~-17 ~20 ~5 polished_blackstone_bricks
setblock ~-1 ~20 ~5 polished_blackstone_bricks
setblock ~1 ~21 ~2 polished_blackstone_bricks
setblock ~16 ~21 ~2 polished_blackstone_bricks
setblock ~-16 ~21 ~5 polished_blackstone_bricks
setblock ~-2 ~21 ~5 polished_blackstone_bricks
setblock ~2 ~22 ~2 polished_blackstone_bricks
setblock ~15 ~22 ~2 polished_blackstone_bricks
setblock ~-15 ~22 ~5 polished_blackstone_bricks
setblock ~-3 ~22 ~5 polished_blackstone_bricks
setblock ~3 ~23 ~2 polished_blackstone_bricks
setblock ~14 ~23 ~2 polished_blackstone_bricks
setblock ~-14 ~23 ~5 polished_blackstone_bricks
setblock ~-4 ~23 ~5 polished_blackstone_bricks
setblock ~4 ~24 ~2 polished_blackstone_bricks
setblock ~13 ~24 ~2 polished_blackstone_bricks
setblock ~-13 ~24 ~5 polished_blackstone_bricks
setblock ~-5 ~24 ~5 polished_blackstone_bricks
setblock ~5 ~25 ~2 polished_blackstone_bricks
setblock ~12 ~25 ~2 polished_blackstone_bricks
setblock ~-12 ~25 ~5 polished_blackstone_bricks
setblock ~-6 ~25 ~5 polished_blackstone_bricks
setblock ~6 ~26 ~2 polished_blackstone_bricks
setblock ~11 ~26 ~2 polished_blackstone_bricks
setblock ~-11 ~26 ~5 polished_blackstone_bricks
setblock ~-7 ~26 ~5 polished_blackstone_bricks
setblock ~7 ~27 ~2 polished_blackstone_bricks
setblock ~10 ~27 ~2 polished_blackstone_bricks
setblock ~-10 ~27 ~5 polished_blackstone_bricks
setblock ~-8 ~27 ~5 polished_blackstone_bricks
setblock ~8 ~28 ~2 polished_blackstone_bricks
setblock ~9 ~28 ~2 polished_blackstone_bricks
setblock ~-9 ~28 ~5 polished_blackstone_bricks
setblock ~-9 ~28 ~5 polished_blackstone_bricks
fill ~8 ~30 ~2 ~9 ~30 ~26 amethyst_block
fill ~-9 ~28 ~5 ~-9 ~28 ~24 amethyst_block
fill ~ ~26 ~1 ~ ~26 ~29 amethyst_block
# Chimney / tower
fill ~-1 ~24 ~17 ~2 ~32 ~20 stone_bricks
fill ~ ~25 ~18 ~1 ~32 ~19 air
fill ~-2 ~32 ~16 ~3 ~32 ~21 polished_blackstone_bricks
fill ~-1 ~33 ~17 ~2 ~33 ~20 campfire[lit=true]
fill ~-2 ~34 ~16 ~3 ~34 ~21 iron_bars
# Warm windows and stained glass
fill ~-15 ~3 ~ ~-10 ~3 ~ stripped_dark_oak_log[axis=x]
fill ~-15 ~6 ~ ~-10 ~6 ~ stripped_dark_oak_log[axis=x]
fill ~-15 ~4 ~ ~-15 ~5 ~ stripped_dark_oak_log[axis=y]
fill ~-10 ~4 ~ ~-10 ~5 ~ stripped_dark_oak_log[axis=y]
fill ~-14 ~4 ~ ~-11 ~5 ~ yellow_stained_glass_pane
fill ~-14 ~4 ~1 ~-11 ~5 ~1 glowstone
fill ~-8 ~3 ~ ~-3 ~3 ~ stripped_dark_oak_log[axis=x]
fill ~-8 ~6 ~ ~-3 ~6 ~ stripped_dark_oak_log[axis=x]
fill ~-8 ~4 ~ ~-8 ~5 ~ stripped_dark_oak_log[axis=y]
fill ~-3 ~4 ~ ~-3 ~5 ~ stripped_dark_oak_log[axis=y]
fill ~-7 ~4 ~ ~-4 ~5 ~ yellow_stained_glass_pane
fill ~-7 ~4 ~1 ~-4 ~5 ~1 glowstone
fill ~9 ~3 ~ ~14 ~3 ~ stripped_dark_oak_log[axis=x]
fill ~9 ~6 ~ ~14 ~6 ~ stripped_dark_oak_log[axis=x]
fill ~9 ~4 ~ ~9 ~5 ~ stripped_dark_oak_log[axis=y]
fill ~14 ~4 ~ ~14 ~5 ~ stripped_dark_oak_log[axis=y]
fill ~10 ~4 ~ ~13 ~5 ~ yellow_stained_glass_pane
fill ~10 ~4 ~1 ~13 ~5 ~1 glowstone
fill ~ ~3 ~ ~1 ~5 ~ air
setblock ~ ~3 ~ spruce_door[facing=south,half=lower,hinge=left]
setblock ~ ~4 ~ spruce_door[facing=south,half=upper,hinge=left]
setblock ~1 ~3 ~ spruce_door[facing=south,half=lower,hinge=right]
setblock ~1 ~4 ~ spruce_door[facing=south,half=upper,hinge=right]
fill ~-14 ~8 ~2 ~-9 ~8 ~2 stripped_dark_oak_log[axis=x]
fill ~-14 ~13 ~2 ~-9 ~13 ~2 stripped_dark_oak_log[axis=x]
fill ~-14 ~9 ~2 ~-14 ~12 ~2 stripped_dark_oak_log[axis=y]
fill ~-9 ~9 ~2 ~-9 ~12 ~2 stripped_dark_oak_log[axis=y]
fill ~-13 ~9 ~2 ~-10 ~12 ~2 yellow_stained_glass_pane
fill ~-13 ~9 ~3 ~-10 ~12 ~3 glowstone
fill ~-6 ~8 ~2 ~-1 ~8 ~2 stripped_dark_oak_log[axis=x]
fill ~-6 ~13 ~2 ~-1 ~13 ~2 stripped_dark_oak_log[axis=x]
fill ~-6 ~9 ~2 ~-6 ~12 ~2 stripped_dark_oak_log[axis=y]
fill ~-1 ~9 ~2 ~-1 ~12 ~2 stripped_dark_oak_log[axis=y]
fill ~-5 ~9 ~2 ~-2 ~12 ~2 yellow_stained_glass_pane
fill ~-5 ~9 ~3 ~-2 ~12 ~3 glowstone
fill ~8 ~8 ~2 ~13 ~8 ~2 stripped_dark_oak_log[axis=x]
fill ~8 ~13 ~2 ~13 ~13 ~2 stripped_dark_oak_log[axis=x]
fill ~8 ~9 ~2 ~8 ~12 ~2 stripped_dark_oak_log[axis=y]
fill ~13 ~9 ~2 ~13 ~12 ~2 stripped_dark_oak_log[axis=y]
fill ~9 ~9 ~2 ~12 ~12 ~2 yellow_stained_glass_pane
fill ~9 ~9 ~3 ~12 ~12 ~3 glowstone
fill ~4 ~8 ~2 ~5 ~11 ~2 air
setblock ~4 ~8 ~2 dark_oak_door[facing=south,half=lower,hinge=left]
setblock ~4 ~9 ~2 dark_oak_door[facing=south,half=upper,hinge=left]
setblock ~5 ~8 ~2 dark_oak_door[facing=south,half=lower,hinge=right]
setblock ~5 ~9 ~2 dark_oak_door[facing=south,half=upper,hinge=right]
fill ~5 ~21 ~3 ~12 ~21 ~3 stripped_dark_oak_log[axis=x]
fill ~5 ~26 ~3 ~12 ~26 ~3 stripped_dark_oak_log[axis=x]
fill ~5 ~22 ~3 ~5 ~25 ~3 stripped_dark_oak_log[axis=y]
fill ~12 ~22 ~3 ~12 ~25 ~3 stripped_dark_oak_log[axis=y]
fill ~6 ~22 ~3 ~11 ~25 ~3 yellow_stained_glass_pane
fill ~6 ~22 ~4 ~11 ~25 ~4 glowstone
fill ~-14 ~15 ~6 ~-5 ~15 ~6 stripped_dark_oak_log[axis=x]
fill ~-14 ~19 ~6 ~-5 ~19 ~6 stripped_dark_oak_log[axis=x]
fill ~-14 ~16 ~6 ~-14 ~18 ~6 stripped_dark_oak_log[axis=y]
fill ~-5 ~16 ~6 ~-5 ~18 ~6 stripped_dark_oak_log[axis=y]
fill ~-13 ~16 ~6 ~-6 ~18 ~6 yellow_stained_glass_pane
fill ~-13 ~16 ~7 ~-6 ~18 ~7 glowstone
fill ~-4 ~19 ~2 ~4 ~19 ~2 stripped_dark_oak_log[axis=x]
fill ~-4 ~24 ~2 ~4 ~24 ~2 stripped_dark_oak_log[axis=x]
fill ~-4 ~20 ~2 ~-4 ~23 ~2 stripped_dark_oak_log[axis=y]
fill ~4 ~20 ~2 ~4 ~23 ~2 stripped_dark_oak_log[axis=y]
fill ~-3 ~20 ~2 ~3 ~23 ~2 yellow_stained_glass_pane
fill ~-3 ~20 ~3 ~3 ~23 ~3 glowstone
fill ~-17 ~3 ~6 ~-17 ~3 ~10 stripped_dark_oak_log[axis=z]
fill ~-17 ~6 ~6 ~-17 ~6 ~10 stripped_dark_oak_log[axis=z]
fill ~-17 ~4 ~6 ~-17 ~5 ~6 stripped_dark_oak_log[axis=y]
fill ~-17 ~4 ~10 ~-17 ~5 ~10 stripped_dark_oak_log[axis=y]
fill ~-17 ~4 ~7 ~-17 ~5 ~9 yellow_stained_glass_pane
fill ~-16 ~4 ~7 ~-16 ~5 ~9 glowstone
fill ~17 ~3 ~6 ~17 ~3 ~10 stripped_dark_oak_log[axis=z]
fill ~17 ~6 ~6 ~17 ~6 ~10 stripped_dark_oak_log[axis=z]
fill ~17 ~4 ~6 ~17 ~5 ~6 stripped_dark_oak_log[axis=y]
fill ~17 ~4 ~10 ~17 ~5 ~10 stripped_dark_oak_log[axis=y]
fill ~17 ~4 ~7 ~17 ~5 ~9 yellow_stained_glass_pane
fill ~16 ~4 ~7 ~16 ~5 ~9 glowstone
fill ~-17 ~3 ~15 ~-17 ~3 ~19 stripped_dark_oak_log[axis=z]
fill ~-17 ~6 ~15 ~-17 ~6 ~19 stripped_dark_oak_log[axis=z]
fill ~-17 ~4 ~15 ~-17 ~5 ~15 stripped_dark_oak_log[axis=y]
fill ~-17 ~4 ~19 ~-17 ~5 ~19 stripped_dark_oak_log[axis=y]
fill ~-17 ~4 ~16 ~-17 ~5 ~18 yellow_stained_glass_pane
fill ~-16 ~4 ~16 ~-16 ~5 ~18 glowstone
fill ~17 ~3 ~15 ~17 ~3 ~19 stripped_dark_oak_log[axis=z]
fill ~17 ~6 ~15 ~17 ~6 ~19 stripped_dark_oak_log[axis=z]
fill ~17 ~4 ~15 ~17 ~5 ~15 stripped_dark_oak_log[axis=y]
fill ~17 ~4 ~19 ~17 ~5 ~19 stripped_dark_oak_log[axis=y]
fill ~17 ~4 ~16 ~17 ~5 ~18 yellow_stained_glass_pane
fill ~16 ~4 ~16 ~16 ~5 ~18 glowstone
fill ~-17 ~3 ~23 ~-17 ~3 ~27 stripped_dark_oak_log[axis=z]
fill ~-17 ~6 ~23 ~-17 ~6 ~27 stripped_dark_oak_log[axis=z]
fill ~-17 ~4 ~23 ~-17 ~5 ~23 stripped_dark_oak_log[axis=y]
fill ~-17 ~4 ~27 ~-17 ~5 ~27 stripped_dark_oak_log[axis=y]
fill ~-17 ~4 ~24 ~-17 ~5 ~26 yellow_stained_glass_pane
fill ~-16 ~4 ~24 ~-16 ~5 ~26 glowstone
fill ~17 ~3 ~23 ~17 ~3 ~27 stripped_dark_oak_log[axis=z]
fill ~17 ~6 ~23 ~17 ~6 ~27 stripped_dark_oak_log[axis=z]
fill ~17 ~4 ~23 ~17 ~5 ~23 stripped_dark_oak_log[axis=y]
fill ~17 ~4 ~27 ~17 ~5 ~27 stripped_dark_oak_log[axis=y]
fill ~17 ~4 ~24 ~17 ~5 ~26 yellow_stained_glass_pane
fill ~16 ~4 ~24 ~16 ~5 ~26 glowstone
fill ~-15 ~9 ~7 ~-15 ~9 ~11 stripped_dark_oak_log[axis=z]
fill ~-15 ~13 ~7 ~-15 ~13 ~11 stripped_dark_oak_log[axis=z]
fill ~-15 ~10 ~7 ~-15 ~12 ~7 stripped_dark_oak_log[axis=y]
fill ~-15 ~10 ~11 ~-15 ~12 ~11 stripped_dark_oak_log[axis=y]
fill ~-15 ~10 ~8 ~-15 ~12 ~10 yellow_stained_glass_pane
fill ~-14 ~10 ~8 ~-14 ~12 ~10 glowstone
fill ~15 ~9 ~7 ~15 ~9 ~11 stripped_dark_oak_log[axis=z]
fill ~15 ~13 ~7 ~15 ~13 ~11 stripped_dark_oak_log[axis=z]
fill ~15 ~10 ~7 ~15 ~12 ~7 stripped_dark_oak_log[axis=y]
fill ~15 ~10 ~11 ~15 ~12 ~11 stripped_dark_oak_log[axis=y]
fill ~15 ~10 ~8 ~15 ~12 ~10 yellow_stained_glass_pane
fill ~14 ~10 ~8 ~14 ~12 ~10 glowstone
fill ~-15 ~15 ~7 ~-15 ~15 ~11 stripped_dark_oak_log[axis=z]
fill ~-15 ~19 ~7 ~-15 ~19 ~11 stripped_dark_oak_log[axis=z]
fill ~-15 ~16 ~7 ~-15 ~18 ~7 stripped_dark_oak_log[axis=y]
fill ~-15 ~16 ~11 ~-15 ~18 ~11 stripped_dark_oak_log[axis=y]
fill ~-15 ~16 ~8 ~-15 ~18 ~10 yellow_stained_glass_pane
fill ~-14 ~16 ~8 ~-14 ~18 ~10 glowstone
fill ~15 ~15 ~7 ~15 ~15 ~11 stripped_dark_oak_log[axis=z]
fill ~15 ~19 ~7 ~15 ~19 ~11 stripped_dark_oak_log[axis=z]
fill ~15 ~16 ~7 ~15 ~18 ~7 stripped_dark_oak_log[axis=y]
fill ~15 ~16 ~11 ~15 ~18 ~11 stripped_dark_oak_log[axis=y]
fill ~15 ~16 ~8 ~15 ~18 ~10 yellow_stained_glass_pane
fill ~14 ~16 ~8 ~14 ~18 ~10 glowstone
fill ~-15 ~9 ~16 ~-15 ~9 ~20 stripped_dark_oak_log[axis=z]
fill ~-15 ~13 ~16 ~-15 ~13 ~20 stripped_dark_oak_log[axis=z]
fill ~-15 ~10 ~16 ~-15 ~12 ~16 stripped_dark_oak_log[axis=y]
fill ~-15 ~10 ~20 ~-15 ~12 ~20 stripped_dark_oak_log[axis=y]
fill ~-15 ~10 ~17 ~-15 ~12 ~19 yellow_stained_glass_pane
fill ~-14 ~10 ~17 ~-14 ~12 ~19 glowstone
fill ~15 ~9 ~16 ~15 ~9 ~20 stripped_dark_oak_log[axis=z]
fill ~15 ~13 ~16 ~15 ~13 ~20 stripped_dark_oak_log[axis=z]
fill ~15 ~10 ~16 ~15 ~12 ~16 stripped_dark_oak_log[axis=y]
fill ~15 ~10 ~20 ~15 ~12 ~20 stripped_dark_oak_log[axis=y]
fill ~15 ~10 ~17 ~15 ~12 ~19 yellow_stained_glass_pane
fill ~14 ~10 ~17 ~14 ~12 ~19 glowstone
fill ~-15 ~15 ~16 ~-15 ~15 ~20 stripped_dark_oak_log[axis=z]
fill ~-15 ~19 ~16 ~-15 ~19 ~20 stripped_dark_oak_log[axis=z]
fill ~-15 ~16 ~16 ~-15 ~18 ~16 stripped_dark_oak_log[axis=y]
fill ~-15 ~16 ~20 ~-15 ~18 ~20 stripped_dark_oak_log[axis=y]
fill ~-15 ~16 ~17 ~-15 ~18 ~19 yellow_stained_glass_pane
fill ~-14 ~16 ~17 ~-14 ~18 ~19 glowstone
fill ~15 ~15 ~16 ~15 ~15 ~20 stripped_dark_oak_log[axis=z]
fill ~15 ~19 ~16 ~15 ~19 ~20 stripped_dark_oak_log[axis=z]
fill ~15 ~16 ~16 ~15 ~18 ~16 stripped_dark_oak_log[axis=y]
fill ~15 ~16 ~20 ~15 ~18 ~20 stripped_dark_oak_log[axis=y]
fill ~15 ~16 ~17 ~15 ~18 ~19 yellow_stained_glass_pane
fill ~14 ~16 ~17 ~14 ~18 ~19 glowstone
fill ~-14 ~8 ~28 ~-9 ~8 ~28 stripped_dark_oak_log[axis=x]
fill ~-14 ~13 ~28 ~-9 ~13 ~28 stripped_dark_oak_log[axis=x]
fill ~-14 ~9 ~28 ~-14 ~12 ~28 stripped_dark_oak_log[axis=y]
fill ~-9 ~9 ~28 ~-9 ~12 ~28 stripped_dark_oak_log[axis=y]
fill ~-13 ~9 ~28 ~-10 ~12 ~28 yellow_stained_glass_pane
fill ~-13 ~9 ~27 ~-10 ~12 ~27 glowstone
fill ~-4 ~8 ~28 ~1 ~8 ~28 stripped_dark_oak_log[axis=x]
fill ~-4 ~13 ~28 ~1 ~13 ~28 stripped_dark_oak_log[axis=x]
fill ~-4 ~9 ~28 ~-4 ~12 ~28 stripped_dark_oak_log[axis=y]
fill ~1 ~9 ~28 ~1 ~12 ~28 stripped_dark_oak_log[axis=y]
fill ~-3 ~9 ~28 ~ ~12 ~28 yellow_stained_glass_pane
fill ~-3 ~9 ~27 ~ ~12 ~27 glowstone
fill ~7 ~8 ~28 ~13 ~8 ~28 stripped_dark_oak_log[axis=x]
fill ~7 ~13 ~28 ~13 ~13 ~28 stripped_dark_oak_log[axis=x]
fill ~7 ~9 ~28 ~7 ~12 ~28 stripped_dark_oak_log[axis=y]
fill ~13 ~9 ~28 ~13 ~12 ~28 stripped_dark_oak_log[axis=y]
fill ~8 ~9 ~28 ~12 ~12 ~28 yellow_stained_glass_pane
fill ~8 ~9 ~27 ~12 ~12 ~27 glowstone
# Purple crystal garden, planters, and cute exterior details
fill ~-20 ~1 ~4 ~-20 ~3 ~4 amethyst_block
setblock ~-20 ~4 ~4 amethyst_cluster[facing=up]
setblock ~-19 ~2 ~4 large_amethyst_bud[facing=east]
setblock ~-21 ~2 ~4 large_amethyst_bud[facing=west]
fill ~-20 ~1 ~13 ~-20 ~4 ~13 amethyst_block
setblock ~-20 ~5 ~13 amethyst_cluster[facing=up]
setblock ~-19 ~2 ~13 large_amethyst_bud[facing=east]
setblock ~-21 ~2 ~13 large_amethyst_bud[facing=west]
fill ~-19 ~1 ~25 ~-19 ~3 ~25 amethyst_block
setblock ~-19 ~4 ~25 amethyst_cluster[facing=up]
setblock ~-18 ~2 ~25 large_amethyst_bud[facing=east]
setblock ~-20 ~2 ~25 large_amethyst_bud[facing=west]
fill ~19 ~1 ~6 ~19 ~4 ~6 amethyst_block
setblock ~19 ~5 ~6 amethyst_cluster[facing=up]
setblock ~20 ~2 ~6 large_amethyst_bud[facing=east]
setblock ~18 ~2 ~6 large_amethyst_bud[facing=west]
fill ~20 ~1 ~18 ~20 ~3 ~18 amethyst_block
setblock ~20 ~4 ~18 amethyst_cluster[facing=up]
setblock ~21 ~2 ~18 large_amethyst_bud[facing=east]
setblock ~19 ~2 ~18 large_amethyst_bud[facing=west]
fill ~18 ~1 ~31 ~18 ~4 ~31 amethyst_block
setblock ~18 ~5 ~31 amethyst_cluster[facing=up]
setblock ~19 ~2 ~31 large_amethyst_bud[facing=east]
setblock ~17 ~2 ~31 large_amethyst_bud[facing=west]
fill ~-12 ~1 ~-5 ~-12 ~2 ~-5 amethyst_block
setblock ~-12 ~3 ~-5 amethyst_cluster[facing=up]
setblock ~-11 ~2 ~-5 large_amethyst_bud[facing=east]
setblock ~-13 ~2 ~-5 large_amethyst_bud[facing=west]
fill ~-6 ~1 ~-7 ~-6 ~3 ~-7 amethyst_block
setblock ~-6 ~4 ~-7 amethyst_cluster[facing=up]
setblock ~-5 ~2 ~-7 large_amethyst_bud[facing=east]
setblock ~-7 ~2 ~-7 large_amethyst_bud[facing=west]
fill ~16 ~1 ~-4 ~16 ~2 ~-4 amethyst_block
setblock ~16 ~3 ~-4 amethyst_cluster[facing=up]
setblock ~17 ~2 ~-4 large_amethyst_bud[facing=east]
setblock ~15 ~2 ~-4 large_amethyst_bud[facing=west]
fill ~21 ~1 ~29 ~21 ~3 ~29 amethyst_block
setblock ~21 ~4 ~29 amethyst_cluster[facing=up]
setblock ~22 ~2 ~29 large_amethyst_bud[facing=east]
setblock ~20 ~2 ~29 large_amethyst_bud[facing=west]
fill ~-21 ~1 ~31 ~-21 ~3 ~31 amethyst_block
setblock ~-21 ~4 ~31 amethyst_cluster[facing=up]
setblock ~-20 ~2 ~31 large_amethyst_bud[facing=east]
setblock ~-22 ~2 ~31 large_amethyst_bud[facing=west]
fill ~-14 ~7 ~3 ~-10 ~7 ~3 spruce_slab[type=top]
setblock ~-14 ~8 ~3 potted_allium
setblock ~-12 ~8 ~3 potted_allium
setblock ~-10 ~8 ~3 potted_allium
fill ~-5 ~7 ~3 ~-1 ~7 ~3 spruce_slab[type=top]
setblock ~-5 ~8 ~3 potted_allium
setblock ~-3 ~8 ~3 potted_allium
setblock ~-1 ~8 ~3 potted_allium
fill ~9 ~7 ~3 ~13 ~7 ~3 spruce_slab[type=top]
setblock ~9 ~8 ~3 potted_allium
setblock ~11 ~8 ~3 potted_allium
setblock ~13 ~8 ~3 potted_allium
fill ~-13 ~14 ~7 ~-6 ~14 ~7 spruce_slab[type=top]
setblock ~-13 ~15 ~7 potted_allium
setblock ~-11 ~15 ~7 potted_allium
setblock ~-9 ~15 ~7 potted_allium
setblock ~-7 ~15 ~7 potted_allium
fill ~6 ~20 ~4 ~11 ~20 ~4 spruce_slab[type=top]
setblock ~6 ~21 ~4 potted_allium
setblock ~8 ~21 ~4 potted_allium
setblock ~10 ~21 ~4 potted_allium
setblock ~-18 ~1 ~4 allium
setblock ~-18 ~1 ~13 allium
setblock ~-17 ~1 ~25 allium
setblock ~17 ~1 ~6 allium
setblock ~18 ~1 ~18 allium
setblock ~16 ~1 ~31 allium
setblock ~-10 ~1 ~-5 allium
setblock ~-4 ~1 ~-7 allium
setblock ~14 ~1 ~-4 allium
setblock ~-14 ~18 ~1 chain[axis=y]
setblock ~-14 ~17 ~1 lantern[hanging=true]
setblock ~-8 ~18 ~1 chain[axis=y]
setblock ~-8 ~17 ~1 lantern[hanging=true]
setblock ~-2 ~18 ~1 chain[axis=y]
setblock ~-2 ~17 ~1 lantern[hanging=true]
setblock ~4 ~18 ~1 chain[axis=y]
setblock ~4 ~17 ~1 lantern[hanging=true]
setblock ~10 ~18 ~1 chain[axis=y]
setblock ~10 ~17 ~1 lantern[hanging=true]
setblock ~16 ~18 ~1 chain[axis=y]
setblock ~16 ~17 ~1 lantern[hanging=true]
setblock ~-14 ~20 ~6 chain[axis=y]
setblock ~-14 ~19 ~6 lantern[hanging=true]
setblock ~-6 ~20 ~6 chain[axis=y]
setblock ~-6 ~19 ~6 lantern[hanging=true]
setblock ~5 ~20 ~3 chain[axis=y]
setblock ~5 ~19 ~3 lantern[hanging=true]
setblock ~13 ~20 ~3 chain[axis=y]
setblock ~13 ~19 ~3 lantern[hanging=true]
setblock ~-16 ~19 ~5 purple_stained_glass
setblock ~-16 ~18 ~5 amethyst_cluster[facing=down]
setblock ~-13 ~19 ~5 purple_stained_glass
setblock ~-13 ~18 ~5 amethyst_cluster[facing=down]
setblock ~-4 ~19 ~5 purple_stained_glass
setblock ~-4 ~18 ~5 amethyst_cluster[facing=down]
setblock ~-1 ~19 ~5 purple_stained_glass
setblock ~-1 ~18 ~5 amethyst_cluster[facing=down]
setblock ~1 ~19 ~2 purple_stained_glass
setblock ~1 ~18 ~2 amethyst_cluster[facing=down]
setblock ~5 ~19 ~2 purple_stained_glass
setblock ~5 ~18 ~2 amethyst_cluster[facing=down]
setblock ~12 ~19 ~2 purple_stained_glass
setblock ~12 ~18 ~2 amethyst_cluster[facing=down]
setblock ~16 ~19 ~2 purple_stained_glass
setblock ~16 ~18 ~2 amethyst_cluster[facing=down]
tellraw @a {"text": "Purple House: exterior complete. Now run /function purple_house:interior.", "color": "light_purple"}
