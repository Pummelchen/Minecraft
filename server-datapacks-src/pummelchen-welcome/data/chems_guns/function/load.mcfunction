tellraw @a ["",{"text":"["},{"text":"CG V1.1.4","color":"#557d62"},{"text":"] Datapack successfully loaded!"}]
schedule function chems_guns:equipment/proxy_mine/schedule_loop 8t replace
#schedule function chems_guns:misc/spawn_more_mobs_loop 3s replace
schedule function chems_guns:misc/misc_loop 4s replace
# Creating & Modifying Teams
team add chems_guns.attackers {"text":"Attackers","color":"green"}
team add chems_guns.defenders {"text":"Defenders","color":"dark_purple"}
team add chems_guns.champion {"text":"Champion","color":"gold"}
team modify chems_guns.attackers color green
team modify chems_guns.attackers friendlyFire false
team modify chems_guns.defenders color dark_purple
team modify chems_guns.defenders friendlyFire false
team modify chems_guns.champion color gold
team modify chems_guns.champion friendlyFire false
# Creating and Modifying Bossbars
bossbar add chems_guns:giant {"text":"Giant","color":"dark_green"}
bossbar set chems_guns:giant color green
bossbar set chems_guns:giant max 1000
bossbar set chems_guns:giant players @a
bossbar set chems_guns:giant style notched_10
bossbar set chems_guns:giant visible true
bossbar add chems_guns:lichking {"bold":true,"color":"aqua","text":"Lich King"}
bossbar set chems_guns:lichking color white
bossbar set chems_guns:lichking max 1024
bossbar set chems_guns:lichking players @a
bossbar set chems_guns:lichking style notched_20
bossbar set chems_guns:lichking visible true
bossbar add chems_guns:spiderboss {"text":"Spider Queen","color":"dark_red"}
bossbar set chems_guns:spiderboss color red
bossbar set chems_guns:spiderboss max 400
bossbar set chems_guns:spiderboss players @a
bossbar set chems_guns:spiderboss style notched_6
bossbar set chems_guns:spiderboss visible true
bossbar add chems_guns:warden {"bold":true,"color":"blue","text":"Warden"}
bossbar set chems_guns:warden color blue
bossbar set chems_guns:warden max 500
bossbar set chems_guns:warden players @a
bossbar set chems_guns:warden style progress
bossbar set chems_guns:warden visible true
# Creating Scoreboards
#Misc/General
scoreboard objectives add chems.raid_mode dummy
scoreboard players add mode chems.raid_mode 0
scoreboard objectives add chems_guns.temp dummy
scoreboard objectives add chems_guns.carrot_detect minecraft.used:minecraft.carrot_on_a_stick
#Lich King Boss
scoreboard objectives add lichKingHealth dummy
scoreboard objectives add lichKingPhase dummy
scoreboard objectives add tickCount dummy
scoreboard objectives add musicPhase dummy
scoreboard objectives add lichKingActive dummy
#Mode Selection
scoreboard objectives add chems_guns.set_mode trigger
scoreboard objectives add chems_guns.operator_config trigger
scoreboard players set mode chems.raid_mode -1
