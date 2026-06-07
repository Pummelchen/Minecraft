# Purple House - runs exterior first, then interior.
function purple_house:exterior
function purple_house:interior
tellraw @a {"text":"Purple House complete: exterior + interior built.","color":"light_purple"}
