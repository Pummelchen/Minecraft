# Purple House — Minecraft Java 26.1.2

A two-stage vanilla Java data pack that builds a cute purple mansion inspired by the reference image:
- tall raised base
- warm windows
- steep purple gable roofs
- dark stepped roof trim
- front balcony and grand stair
- amethyst/crystal garden
- fully decorated interior

## Install
1. Back up your world.
2. Put `Purple_House_26_1_2.zip` in:
   `.minecraft/saves/<your world>/datapacks/`
3. Open the world and run:
   `/reload`

## Build
Stand at ground level where you want the center of the front stair path to be.
The house builds mostly in front of you, extending about:
- 22 blocks left/right
- 12 blocks forward toward you
- 36 blocks behind the front stair path
- 35 blocks upward

Run in this order:
1. `/function purple_house:exterior`
2. `/function purple_house:interior`

Or build everything at once:
`/function purple_house:complete`

Erase the whole generated area:
`/function purple_house:erase`

## Notes
- The exterior function clears the build volume first. Do not run it over anything you want to keep.
- The reference image uses shader-like purple glow and nonstandard visual detail. This pack uses vanilla blocks only, so it recreates the silhouette, palette, windows, crystals, balcony, gables, and interior layout rather than non-vanilla lighting effects.
- For the closest look, view it at sunset/night with smooth lighting on.
