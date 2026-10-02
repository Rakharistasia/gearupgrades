# # EQ Might - EMU - GearUpgrades

Finds upgrades your characters already own. It compares every equippable item in each character's bags, bank and shared bank against what that character is wearing, and lists the best upgrade per character and slot, with an **Equip** button to swap it in. Inspired by MQ2Itemscore plugin, and Gearly.

Written for EQ Might (EQEmu), should work on other EQEmu servers.

## What it does

- **Scores with your MQ2ItemScore (`/iscore`) weights** from `config/MQ2ItemScore.ini`, so numbers line up with `/iscore`. You can switch to GearUpgrades' own per-class weights (which also count base stats, resists and endurance) and edit them in the window.
- **Augments count.** Item scores include socketed augs. In "Move my augs" mode, the new item is scored with your worn item's augs moved into its free slots of the right type.
- **Two-handers** are scored against primary + secondary together; if you wear a 2H it compares against the best 1H + offhand pair you own.
- **Haste** only counts above the best haste you already wear (worn haste doesn't stack).
- **Focus effects** - only the best focus of each type counts; focuses are reduced for spell-level limits, single resist type, or beneficial/detrimental-only limits.
- **Weapon procs** - damage at about 2 procs per minute (adjusted by the weapon's proc rate) plus a flat value for slows, stuns and debuffs.
- **Level filter** - "Max required level" hides items above a level and judges focus/proc level requirements at that level (for deleveling).
- **Other characters (tradeable)** - optionally includes tradeable items held by your other characters, checked against class and race.

Tabs: **Upgrades**, **By character** (count and total gain), **Focus coverage** (best focus per type, weapon procs, and effects lost at the level filter), **Stat weights**.

## Install

Put `init.lua` in `<MacroQuest>/lua/gearupgrades/`.

## Use

```
/lua run gearupgrades          scan this character and open the window
/lua run gearupgrades scan     scan this character, save, and exit (no window)
/gearupgrades scan             rescan this character
/gearupgrades scanall          ask every DanNet box to scan
/gearupgrades scanzone         ask DanNet boxes in your zone to scan
/gearupgrades export           write every focus/proc effect seen to config/GearUpgrades_effects_report.txt
/gearupgrades quit             close
```

### Equip button

Only for items in that character's **bags** (move bank items to bags first). It won't run in combat or with something on your cursor. With "Move my augs" on it moves the worn item to a bag, removes each aug that fits by clicking its socket in the item window, inserts it into the new item with `/insertaug`, then equips. A 2H empties your offhand first. For a boxed character the swap is sent over DanNet (`/dex <name> /lua run gearupgrades swap ...`). The character rescans afterwards.

Aug removal uses the free socket click EQ Might allows; servers that require a distiller will stop with a message.

## Files

Saved in your MQ `config` folder: `GearUpgrades_<server>_<name>.lua` per character, `GearUpgrades_index.lua`, `GearUpgrades_weights.lua` (your own weights) and the optional effects report.

## Requirements

- MacroQuest (MQNext) with Lua and ImGui
- MQ2DanNet for box rescans and remote swaps
- MQ2ItemScore is optional; without its ini the script uses its own weights

## Limits

- Clicky effects are listed but not scored.
- Proc rate is an estimate.
- Focus weights are a first pass; use the effects report to tune them for your server.
