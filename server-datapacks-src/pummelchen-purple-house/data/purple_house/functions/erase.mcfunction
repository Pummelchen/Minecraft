# Purple House - erase build volume. Warning: destructive.
tellraw @a {"text":"Purple House: erasing build volume...","color":"red"}
fill ~-22 ~ ~-12 ~22 ~12 ~36 air
fill ~-22 ~13 ~-12 ~22 ~25 ~36 air
fill ~-22 ~26 ~-12 ~22 ~38 ~36 air
tellraw @a {"text": "Purple House: build volume erased.", "color": "red"}
