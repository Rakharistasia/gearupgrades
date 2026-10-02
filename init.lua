--[[
  GearUpgrades - finds upgrades sitting in your bags and bank, per character and slot

  Compares every equippable item each character owns (bags, bank, shared bank)
  against what that character has equipped, including socketed augments.
  Two-handers are scored against your primary + secondary together, and a 2H
  you wear now is compared against the best 1H + offhand pair you own.

  Scoring uses your MQ2ItemScore (/iscore) weights from MQ2ItemScore.ini by
  default, so numbers line up with /iscore. You can switch to GearUpgrades'
  own weights (which also count base stats, resists and endurance).

  Install:  <MacroQuest>/lua/gearupgrades/init.lua

  Usage:
    /lua run gearupgrades          scan this character and open the window
    /lua run gearupgrades scan     scan this character, save, and exit (no UI)
    /gearupgrades scan | scanall | scanzone | export | quit   (while the window runs)
    (swap mode is used by the window: /lua run gearupgrades swap <id> <slot> <moveAugs> [<id2>])

  Focus effects and weapon procs are scored too (toggle in the window):
  only the best focus of each type counts, focuses are reduced for spell-level
  limits / single resist type / beneficial-or-detrimental-only, and procs are
  valued as damage x ~2 procs per minute plus flat value for slows, stuns and
  debuffs. The Focus coverage tab shows each character's best focus per type,
  weapon procs, unrecognised effects, and effects lost at the level filter.
  "Export effects report" writes every effect seen to
  config/GearUpgrades_effects_report.txt for tuning.

  The Equip button swaps an upgrade in from your bags, moving augments over
  first if "Move my augs" is selected (removes them by clicking the socket in
  the item display, then /insertaug), then rescans so the list updates. For a boxed
  character the button sends the swap to that character over DanNet.
]]

local mq    = require('mq')
local ImGui = require('ImGui')

local SCRIPT   = 'gearupgrades'
local CFG_DIR  = mq.configDir
local INDEX    = CFG_DIR .. '/GearUpgrades_index.lua'
local WEIGHTS  = CFG_DIR .. '/GearUpgrades_weights.lua'
local ISCORE_INI = CFG_DIR .. '/MQ2ItemScore.ini'
local args     = { ... }

-- ---------------------------------------------------------------- slots ---
local WORN = {
  [0]='Charm','Left Ear','Head','Face','Right Ear','Neck','Shoulders','Arms',
  'Back','Left Wrist','Right Wrist','Range','Hands','Primary','Secondary',
  'Left Finger','Right Finger','Chest','Legs','Feet','Waist','Power Source','Ammo',
}
-- names /itemnotify understands
local NOTIFY = {
  [0]='charm','leftear','head','face','rightear','neck','shoulder','arms',
  'back','leftwrist','rightwrist','range','hands','mainhand','offhand',
  'leftfinger','rightfinger','chest','legs','feet','waist','powersource','ammo',
}
local PAIRED = { [1]=4, [4]=1, [9]=10, [10]=9, [15]=16, [16]=15, [13]=14, [14]=13 }
local SKIP_SLOTS = { [22]=true }        -- ammo
local PRIMARY, SECONDARY, RANGE = 13, 14, 11
local DUAL_WIELD = { WAR=true, MNK=true, ROG=true, BER=true, RNG=true, BST=true, BRD=true }
local PACK_FIRST = 23
local function packLast() return PACK_FIRST - 1 + (tonumber(mq.TLO.Me.NumBagSlots()) or 10) end
local BANK_SLOTS, SHARED_SLOTS, MAX_AUGS = 24, 2, 6

-- ---------------------------------------------------------------- stats ---
local STAT_DEFS = {
  {'hp','HP','HP'}, {'mana','Mana','Mana'}, {'endurance','Endurance','End'},
  {'ac','AC','AC'}, {'attack','Attack','ATK'}, {'haste','Haste','Haste'},
  {'hpregen','HPRegen','HP Regen'}, {'manaregen','ManaRegen','Mana Regen'},
  {'endregen','EnduranceRegen','End Regen'},
  {'str','STR','STR'}, {'sta','STA','STA'}, {'agi','AGI','AGI'}, {'dex','DEX','DEX'},
  {'wis','WIS','WIS'}, {'int','INT','INT'}, {'cha','CHA','CHA'},
  {'hstr','HeroicSTR','H-STR'}, {'hsta','HeroicSTA','H-STA'}, {'hagi','HeroicAGI','H-AGI'},
  {'hdex','HeroicDEX','H-DEX'}, {'hwis','HeroicWIS','H-WIS'}, {'hint','HeroicINT','H-INT'},
  {'hcha','HeroicCHA','H-CHA'},
  {'svMagic','svMagic'}, {'svFire','svFire'}, {'svCold','svCold'},
  {'svDisease','svDisease'}, {'svPoison','svPoison'}, {'svCorruption','svCorruption'},
  {'avoidance','Avoidance','Avoidance'}, {'accuracy','Accuracy','Accuracy'},
  {'shielding','Shielding','Shielding'}, {'spellshield','SpellShield','Spell Shield'},
  {'strikethrough','StrikeThrough','Strikethrough'}, {'dotshielding','DoTShielding','DoT Shield'},
  {'stunresist','StunResist','Stun Resist'}, {'damageshield','DamShield','Dmg Shield'},
  {'dsmit','DamageShieldMitigation','DS Mitigation'}, {'combateffects','CombatEffects','Combat Eff.'},
  {'healamount','HealAmount','Heal Amt'}, {'spelldamage','SpellDamage','Spell Dmg'},
  {'clairvoyance','Clairvoyance','Clairvoyance'},
  {'damage','Damage'}, {'delay','ItemDelay'},
}

-- 'resists' = sum of all sv*, 'ratio' = 100 x damage / delay
local WEIGHT_KEYS = {
  'hp','mana','endurance','ac','attack','haste','hpregen','manaregen','endregen',
  'str','sta','agi','dex','wis','int','cha',
  'hstr','hsta','hagi','hdex','hwis','hint','hcha',
  'resists','avoidance','accuracy','shielding','spellshield','strikethrough',
  'dotshielding','stunresist','damageshield','dsmit','combateffects',
  'healamount','spelldamage','clairvoyance','ratio',
}
local LABEL = { resists = 'Resists (all)', ratio = 'Weapon ratio' }
for _, d in ipairs(STAT_DEFS) do if d[3] then LABEL[d[1]] = d[3] end end

-- MQ2ItemScore.ini key -> GearUpgrades stat key
local ISCORE_MAP = {
  AC='ac', HP='hp', HPReg='hpregen', Mana='mana', ManaReg='manaregen',
  hSTR='hstr', hSTA='hsta', hAGI='hagi', hDEX='hdex', hINT='hint', hWIS='hwis', hCHR='hcha',
  Heal='healamount', Nuke='spelldamage', Clrv='clairvoyance', Attack='attack',
  Accuracy='accuracy', CE='combateffects', StrikeThrough='strikethrough',
  Avoidance='avoidance', Shielding='shielding', DoTShielding='dotshielding',
  SpellShield='spellshield', Stun='stunresist', DS='damageshield', Haste='haste', Ratio='ratio',
}

local ROLE_DEFAULTS = {
  tank   = { hp=1, ac=3, endurance=0.4, mana=0.2, attack=0.8, haste=2, hpregen=3, endregen=1,
             sta=0.5, str=0.3, agi=0.3, dex=0.2, hsta=2.5, hstr=1, hagi=1, hdex=0.5,
             resists=0.2, avoidance=3, shielding=3, stunresist=1, strikethrough=1, accuracy=1,
             damageshield=0.5, dsmit=1, combateffects=0.5, ratio=0.5 },
  melee  = { hp=0.8, ac=1, endurance=0.6, mana=0.2, attack=1.5, haste=3, hpregen=2, endregen=1.5,
             str=0.5, dex=0.5, agi=0.3, sta=0.3, hstr=2, hdex=2, hsta=1.5, hagi=1,
             resists=0.1, accuracy=2, strikethrough=2, combateffects=1, avoidance=1, ratio=1 },
  caster = { hp=0.7, mana=1, ac=0.3, int=0.5, sta=0.2, hint=2.5, hsta=1, manaregen=4, hpregen=1,
             resists=0.1, spellshield=1, clairvoyance=2, spelldamage=1 },
  healer = { hp=0.8, mana=1, ac=0.5, wis=0.5, sta=0.3, hwis=2.5, hsta=1.5, manaregen=4, hpregen=1.5,
             healamount=1, clairvoyance=2, resists=0.1, spellshield=1 },
}
local CLASS_ROLE = {
  WAR='tank', PAL='tank', SHD='tank',
  MNK='melee', ROG='melee', BER='melee', RNG='melee', BST='melee', BRD='melee',
  CLR='healer', DRU='healer', SHM='healer',
  WIZ='caster', MAG='caster', NEC='caster', ENC='caster',
}
local NO_MANA = { WAR=true, MNK=true, ROG=true, BER=true }
local CLASS_LIST = { 'BER','BRD','BST','CLR','DRU','ENC','MAG','MNK','NEC','PAL','RNG','ROG','SHD','SHM','WAR','WIZ' }

-- -------------------------------------------------------------- helpers ---
local function safe(fn) local ok, v = pcall(fn); if ok then return v end end
local function num(v) return tonumber(v) or 0 end
-- always returns a real boolean (mq.delay callbacks crash on nil)
local function exists(item) return (item and safe(function() return item() end) and num(safe(function() return item.ID() end)) > 0) == true end

local function fileFor(server, name)
  return string.format('%s/GearUpgrades_%s_%s.lua', CFG_DIR, ((server or 'server'):gsub('[^%w]', '')), name)
end

local function loadTable(path)
  local f = loadfile(path); if not f then return nil end
  local ok, t = pcall(f); if ok and type(t) == 'table' then return t end
end

local function hasBit(mask, typ)
  if typ <= 0 then return false end
  return math.floor(num(mask) / 2 ^ (typ - 1)) % 2 == 1
end

local function is2H(item) return item and type(item.itype) == 'string' and item.itype:find('^2H') ~= nil end

local function say(fmt, ...) printf('\ag[GearUpgrades]\ax ' .. fmt, ...) end
local function warn(fmt, ...) printf('\ar[GearUpgrades]\ax ' .. fmt, ...) end

-- ----------------------------------------------------------------- scan ---
local function readStats(item)
  local s = {}
  for _, d in ipairs(STAT_DEFS) do
    local v = num(safe(function() return item[d[2]]() end))
    if v ~= 0 then s[d[1]] = v end
  end
  return s
end

-- Raw spell data for an item effect (focus / worn / proc). Interpreted later,
-- so weights can change without rescanning.
local function readEffect(is)
  if not is then return nil end
  local sp = safe(function() return is.Spell end)
  if not sp or num(safe(function() return sp.ID() end)) == 0 then return nil end
  local e = {
    name     = safe(function() return sp.Name() end) or '?',
    id       = num(safe(function() return sp.ID() end)),
    reqLevel = num(safe(function() return is.RequiredLevel() end)),
    procRate = num(safe(function() return is.ProcRate() end)),
    target   = safe(function() return sp.TargetType() end) or '',
    resist   = safe(function() return sp.ResistType() end) or '',
    effects  = {},
  }
  for i = 1, num(safe(function() return sp.NumEffects() end)) do
    local a = num(safe(function() return sp.Attrib(i)() end))
    if a ~= 254 and a ~= 10 then   -- 254 = unused slot, 10 = blank CHA placeholder
      table.insert(e.effects, {
        a  = a,
        b  = num(safe(function() return sp.Base(i)() end)),
        b2 = num(safe(function() return sp.Base2(i)() end)),
        m  = num(safe(function() return sp.Max(i)() end)),
      })
    end
  end
  return e
end

local function readEffects(item)
  local fx = {}
  local f1 = readEffect(safe(function() return item.Focus end))
  local f2 = readEffect(safe(function() return item.Focus2 end))
  local w  = readEffect(safe(function() return item.Worn end))
  local p  = readEffect(safe(function() return item.Proc end))
  if not p and (safe(function() return item.EffectType() end) or ''):find('Combat') then
    p = readEffect({ Spell = safe(function() return item.Spell end),
                     RequiredLevel = function() return 0 end, ProcRate = function() return 0 end })
  end
  fx.focus = {}
  if f1 then table.insert(fx.focus, f1) end
  if f2 then table.insert(fx.focus, f2) end
  if w then table.insert(fx.focus, w) end      -- worn spells can carry focus SPAs too
  fx.proc = p
  local cl = safe(function() return item.Clicky end)
  local cs = cl and safe(function() return cl.Spell.Name() end)
  if cs then fx.clicky = { name = cs, reqLevel = num(safe(function() return cl.RequiredLevel() end)) } end
  if #fx.focus == 0 and not fx.proc and not fx.clicky then return nil end
  return fx
end

local function readAugs(item)
  local augs = {}
  for i = 1, MAX_AUGS do
    local slot = safe(function() return item.AugSlot(i) end)
    if slot then
      local typ = num(safe(function() return slot.Type() end))
      local visible = safe(function() return slot.Visible() end)
      if typ > 0 and visible ~= false then
        local entry = { index = i, type = typ }
        local a = safe(function() return slot.Item end)
        if exists(a) then
          entry.aug = {
            name    = safe(function() return a.Name() end) or '?',
            id      = num(safe(function() return a.ID() end)),
            augType = num(safe(function() return a.AugType() end)),
            stats   = readStats(a),
            fx      = readEffects(a),
          }
        end
        table.insert(augs, entry)
      end
    end
  end
  return augs
end

local function readItem(item, location, where)
  local nslots = num(safe(function() return item.WornSlots() end))
  if nslots == 0 then return nil end
  if num(safe(function() return item.AugType() end)) > 0 then return nil end   -- loose augment
  local slots = {}
  for i = 1, nslots do
    local s = safe(function() return item.WornSlot(i)() end)
    if s then table.insert(slots, num(s)) end
  end
  local classes = {}
  local nclass = num(safe(function() return item.Classes() end))
  if nclass >= 16 then classes = { 'ALL' } else
    for i = 1, nclass do
      local c = safe(function() return item.Class(i).ShortName() end) or safe(function() return item.Class(i)() end)
      if c then table.insert(classes, c) end
    end
  end
  local races = {}
  local nrace = num(safe(function() return item.Races() end))
  if nrace >= 16 then races = { 'ALL' } else
    for i = 1, nrace do
      local r = safe(function() return item.Race(i)() end)
      if r then table.insert(races, r) end
    end
  end
  return {
    name     = safe(function() return item.Name() end) or '?',
    id       = num(safe(function() return item.ID() end)),
    link     = safe(function() return item.ItemLink('CLICKABLE')() end),
    itype    = safe(function() return item.Type() end) or '',
    races    = races,
    slots    = slots,
    classes  = classes,
    canUse   = safe(function() return item.CanUse() end) ~= false,
    nodrop   = safe(function() return item.NoDrop() end) == true,
    lore     = safe(function() return item.Lore() end) == true,
    req      = num(safe(function() return item.RequiredLevel() end)),
    rec      = num(safe(function() return item.RecommendedLevel() end)),
    stats    = readStats(item),
    augs     = readAugs(item),
    fx       = readEffects(item),
    location = location,
    where    = where,
  }
end

local function scanContainerSlot(out, item, location, label)
  if not exists(item) then return end
  local r = readItem(item, location, label); if r then table.insert(out, r) end
  for i = 1, num(safe(function() return item.Container() end)) do
    local inner = safe(function() return item.Item(i) end)
    if exists(inner) then
      local ri = readItem(inner, location, label .. ' / ' .. i)
      if ri then table.insert(out, ri) end
    end
  end
end

local function scanMe()
  local me = mq.TLO.Me
  local worn, owned = {}, {}
  for s = 0, 22 do
    local it = me.Inventory(s)
    if exists(it) then worn[s] = readItem(it, 'Worn', WORN[s]) end
  end
  for i = PACK_FIRST, packLast() do scanContainerSlot(owned, me.Inventory(i), 'Bags', 'Pack ' .. (i - PACK_FIRST + 1)) end
  for i = 1, BANK_SLOTS do scanContainerSlot(owned, me.Bank(i), 'Bank', 'Bank ' .. i) end
  for i = 1, SHARED_SLOTS do
    scanContainerSlot(owned, safe(function() return me.SharedBank(i) end), 'Shared Bank', 'Shared ' .. i)
  end

  local data = {
    name    = me.CleanName(),
    server  = mq.TLO.MacroQuest.Server() or mq.TLO.EverQuest.Server(),
    class   = me.Class.ShortName(),
    race    = safe(function() return me.Race.Name() end) or safe(function() return me.Race() end),
    level   = me.Level(),
    scanned = os.date('%Y-%m-%d %H:%M'),
    worn    = worn,
    owned   = owned,
  }
  mq.pickle(fileFor(data.server, data.name), data)

  local index = loadTable(INDEX) or {}
  local key, found = data.server .. '|' .. data.name, false
  for _, v in ipairs(index) do if v == key then found = true end end
  if not found then table.insert(index, key); mq.pickle(INDEX, index) end
  say('scanned %s: %d equippable items', data.name, #owned)
  return data
end

-- ------------------------------------------------------------- swapping ---
-- Pick up with /itemnotify, remove augs by clicking the socket in the item
-- display, /insertaug to put them back, /autoinventory anything left on the cursor.

local function cursor() local c = mq.TLO.Cursor; if exists(c) then return c end end
local function waitCursor(id, ms) return mq.delay(ms or 2500, function() local c = cursor(); return c ~= nil and c.ID() == id end) end
local function waitEmptyCursor(ms) return mq.delay(ms or 2500, function() return cursor() == nil end) end

local function clickYes()
  if mq.TLO.Window('ConfirmationDialogBox').Open() then
    mq.cmd('/notify ConfirmationDialogBox CD_Yes_Button leftmouseup'); mq.delay(750)
  end
end

local function clearCursor()
  if cursor() then mq.cmd('/autoinventory'); waitEmptyCursor() end
  return cursor() == nil
end

-- find an item by ID in the general inventory / bags. Returns notify target.
local function findInBags(id)
  for i = PACK_FIRST, packLast() do
    local n = i - PACK_FIRST + 1
    local pack = mq.TLO.Me.Inventory(i)
    if exists(pack) then
      if pack.ID() == id then return { target = 'pack' .. n, item = pack } end
      for s = 1, num(pack.Container()) do
        local it = pack.Item(s)
        if exists(it) and it.ID() == id then return { target = string.format('in pack%d %d', n, s), item = it } end
      end
    end
  end
end

local function findEmptyBagSlot()
  for i = PACK_FIRST, packLast() do
    local n = i - PACK_FIRST + 1
    local pack = mq.TLO.Me.Inventory(i)
    if exists(pack) and num(pack.Container()) > 0 then
      for s = 1, num(pack.Container()) do
        if not exists(pack.Item(s)) then return string.format('in pack%d %d', n, s) end
      end
    end
  end
end

local function pickUp(target, id)
  if cursor() then warn('Cursor is not empty.'); return false end
  mq.cmdf('/ctrl /itemnotify %s leftmouseup', target)
  waitCursor(id)
  local c = cursor()
  return c ~= nil and c.ID() == id
end

local function closeItemDisplay()
  if mq.TLO.Window('ItemDisplayWindow').Open() then
    mq.cmd('/invoke ${Window[ItemDisplayWindow].DoClose}'); mq.delay(250)
  end
end

local function openItemDisplay(target)
  for _, fmt in ipairs({ '/nomodkey /altkey /itemnotify %s leftmouseup',
                         '/nomodkey /shiftkey /itemnotify %s leftmouseup',
                         '/nomodkey /itemnotify %s rightmouseup' }) do
    closeItemDisplay()
    mq.cmdf(fmt, target)
    mq.delay(1500, function() return mq.TLO.Window('ItemDisplayWindow').Open() == true end)
    if mq.TLO.Window('ItemDisplayWindow').Open() then return true end
  end
  return false
end

local function augInSlot(item, idx)
  local a = safe(function() return item.AugSlot(idx).Item end)
  if exists(a) then return a end
end

-- removes the aug in socket idx of the bag item with this id, leaves it in inventory
local function removeAug(itemId, idx, augName)
  local loc = findInBags(itemId)
  if not loc then warn('Could not find item %d to remove %s.', itemId, augName); return false end
  if not openItemDisplay(loc.target) then warn('Could not open item window to remove %s.', augName); return false end
  for _, child in ipairs({ string.format('IDW_Socket_Slot_%d_Item', idx), string.format('IDW_Socket_Slot_%d_Screen', idx) }) do
    if mq.TLO.Window('ItemDisplayWindow').Child(child)() then
      mq.cmdf('/notify ItemDisplayWindow %s leftmouseup', child); mq.delay(500)
      clickYes()
      mq.cmd('/autoinventory'); mq.delay(1000)
      local now = findInBags(itemId)
      if now and not augInSlot(now.item, idx) then closeItemDisplay(); return true end
    end
  end
  closeItemDisplay()
  warn('Could not remove %s. You may need a distiller for this augment.', augName)
  return false
end

local function insertAug(augId, augName, intoId)
  local loc = findInBags(augId)
  if not loc then warn('Could not find %s in bags to insert.', augName); return false end
  if not pickUp(loc.target, augId) then return false end
  mq.cmdf('/insertaug %d', intoId); mq.delay(1500); clickYes()
  mq.delay(2500, function() return cursor() == nil end)
  if cursor() then warn('Insert of %s did not complete.', augName); clearCursor(); return false end
  return true
end

local function equipFromBags(id, slot)
  local loc = findInBags(id)
  if not loc then warn('Item %d is not in your bags (bank items must be moved to bags first).', id); return false end
  if not pickUp(loc.target, id) then return false end
  mq.cmdf('/itemnotify %s leftmouseup', NOTIFY[slot]); mq.delay(1000); clickYes()
  mq.delay(2000, function() local w = mq.TLO.Me.Inventory(slot); return exists(w) and w.ID() == id end)
  clearCursor()   -- the old item, if any, goes back into bags
  local w = mq.TLO.Me.Inventory(slot)
  if exists(w) and w.ID() == id then return true end
  warn('Equip into %s did not verify.', WORN[slot])
  return false
end

local function unequipToBags(slot)
  local w = mq.TLO.Me.Inventory(slot)
  if not exists(w) then return true end
  local id = w.ID()
  local dest = findEmptyBagSlot()
  if not dest then warn('No free bag slot to put %s.', w.Name()); return false end
  if not pickUp(NOTIFY[slot], id) then return false end
  mq.cmdf('/itemnotify %s leftmouseup', dest); mq.delay(1000)
  if cursor() then clearCursor() end
  return not exists(mq.TLO.Me.Inventory(slot)), id
end

-- full swap: new item (and optional second item for 1H+offhand pairs)
local function doSwap(newId, slot, moveAugs, secondId)
  if mq.TLO.MacroQuest.GameState() ~= 'INGAME' then warn('Not in game.'); return false end
  if mq.TLO.Me.Combat() then warn('In combat - not swapping.'); return false end
  if cursor() then warn('Clear your cursor first.'); return false end
  if not findInBags(newId) then warn('Upgrade must be in your bags (move it out of the bank first).'); return false end
  if not mq.TLO.Window('InventoryWindow').Open() then mq.cmd('/keypress OPEN_INV_BAGS'); mq.delay(500) end

  local newLoc = findInBags(newId)
  local new2H = (newLoc.item.Type() or ''):find('^2H') ~= nil

  -- move augs from the worn item into the new one while both are in bags
  if moveAugs then
    local worn = mq.TLO.Me.Inventory(slot)
    if exists(worn) then
      -- which worn augs fit an empty socket of the new item
      local plan, freeSlots = {}, {}
      for i = 1, MAX_AUGS do
        local s = newLoc.item.AugSlot(i)
        if num(s.Type()) > 0 and s.Visible() ~= false and s.Empty() then table.insert(freeSlots, num(s.Type())) end
      end
      for i = 1, MAX_AUGS do
        local a = augInSlot(worn, i)
        if a then
          for k, t in ipairs(freeSlots) do
            if hasBit(a.AugType(), t) then
              table.insert(plan, { idx = i, id = a.ID(), name = a.Name() }); table.remove(freeSlots, k); break
            end
          end
        end
      end
      if #plan > 0 then
        local ok, oldId = unequipToBags(slot)
        if not ok then return false end
        for _, p in ipairs(plan) do
          say('Moving %s to the new item.', p.name)
          if not removeAug(oldId, p.idx, p.name) then return false end
          if not insertAug(p.id, p.name, newId) then return false end
        end
      end
    end
  end

  -- a two-hander needs the offhand empty first
  if new2H and slot == PRIMARY and exists(mq.TLO.Me.Inventory(SECONDARY)) then
    if not unequipToBags(SECONDARY) then return false end
  end

  if not equipFromBags(newId, slot) then return false end
  if secondId and secondId > 0 then
    if not equipFromBags(secondId, SECONDARY) then return false end
  end
  say('Equipped upgrade in %s.', WORN[slot])
  return true
end

if args[1] == 'scan' then scanMe(); return end
if args[1] == 'swap' then
  doSwap(num(args[2]), num(args[3]), args[4] == '1', num(args[5]))
  scanMe()
  return
end

-- --------------------------------------------------------------- weights ---
local myWeights = loadTable(WEIGHTS) or {}
local iscoreWeights = {}

local function loadIScore()
  iscoreWeights = {}
  local f = io.open(ISCORE_INI, 'r'); if not f then return false end
  local section
  for line in f:lines() do
    local sec = line:match('^%s*%[(.-)%]')
    if sec then section = sec
    elseif section and section ~= 'Global' then
      local k, v = line:match('^%s*([%w]+)%s*=%s*([%-%d%.]+)')
      if k and ISCORE_MAP[k] then
        iscoreWeights[section] = iscoreWeights[section] or {}
        local val = tonumber(v) or 0
        if k == 'Ratio' then val = val / 100 end   -- ratio here is 100 x dmg/delay
        iscoreWeights[section][ISCORE_MAP[k]] = val
      end
    end
  end
  f:close()
  return next(iscoreWeights) ~= nil
end

local function myWeightsFor(class)
  if not myWeights[class] then
    local w = {}
    for k, v in pairs(ROLE_DEFAULTS[CLASS_ROLE[class] or 'melee']) do w[k] = v end
    if NO_MANA[class] then w.mana = 0; w.manaregen = 0 end
    myWeights[class] = w
  end
  return myWeights[class]
end

-- --------------------------------------------------------------- scoring ---
local function addStats(into, s) for k, v in pairs(s or {}) do if type(v) == 'number' then into[k] = (into[k] or 0) + v end end end

local function totals(item, extraAugs)
  local t = { _procs = {} }
  if not item then return t end
  addStats(t, item.stats)
  if item.fx and item.fx.proc then table.insert(t._procs, item.fx.proc) end
  for _, a in ipairs(item.augs or {}) do
    if a.aug then
      addStats(t, a.aug.stats)
      if a.aug.fx and a.aug.fx.proc then table.insert(t._procs, a.aug.fx.proc) end
    end
  end
  for _, a in ipairs(extraAugs or {}) do
    addStats(t, a.stats)
    if a.fx and a.fx.proc then table.insert(t._procs, a.fx.proc) end
  end
  return t
end

-- ------------------------------------------------------ focus effects & procs ---
-- Level effects are judged at: the character's level, or the "Max required
-- level" value when that filter is on (so deleveling shows what stops working).
local evalLevel = 65
local useEffects = true

local FOCUS_TYPES = {
  [124] = { key = 'dmg',      label = 'Spell Dmg' },
  [125] = { key = 'heal',     label = 'Healing' },
  [126] = { key = 'resist',   label = 'Resist Rate' },
  [127] = { key = 'casttime', label = 'Cast Time' },
  [128] = { key = 'duration', label = 'Duration' },
  [129] = { key = 'range',    label = 'Range' },
  [130] = { key = 'hate',     label = 'Hate' },
  [131] = { key = 'reagent',  label = 'Reagent' },
  [132] = { key = 'mana',     label = 'Mana Cost' },
}
local FOCUS_ORDER = { 'dmg', 'heal', 'mana', 'casttime', 'duration', 'resist', 'hate', 'range', 'reagent' }
local FOCUS_LABEL = {}
for _, f in pairs(FOCUS_TYPES) do FOCUS_LABEL[f.key] = f.label end

-- points per 1% of focus. Negative hate weight = casters want hate reduction.
local FOCUS_W = {
  WAR = { hate = 8 },
  PAL = { heal = 8, mana = 8, casttime = 4, duration = 4, hate = 6, dmg = 2 },
  SHD = { dmg = 4, mana = 6, casttime = 3, duration = 4, hate = 8 },
  CLR = { heal = 40, mana = 25, casttime = 20, duration = 12, range = 2, reagent = 1, hate = -3 },
  SHM = { heal = 25, mana = 25, casttime = 15, duration = 15, dmg = 8, range = 2, reagent = 1, hate = -3 },
  DRU = { heal = 25, dmg = 15, mana = 25, casttime = 15, duration = 10, range = 2, reagent = 1, hate = -3 },
  WIZ = { dmg = 40, mana = 25, casttime = 20, resist = 15, range = 2, reagent = 1, hate = -5 },
  MAG = { dmg = 40, mana = 25, casttime = 20, resist = 10, duration = 3, range = 2, reagent = 1, hate = -5 },
  NEC = { dmg = 35, mana = 25, casttime = 15, duration = 20, resist = 10, range = 2, reagent = 1, hate = -5 },
  ENC = { dmg = 10, mana = 25, casttime = 20, duration = 25, resist = 15, range = 2, reagent = 1, hate = -5 },
  BRD = { duration = 10, dmg = 5, mana = 5, range = 2 },
  RNG = { dmg = 8, mana = 8, casttime = 5, heal = 3, hate = -2 },
  BST = { dmg = 8, heal = 5, mana = 10, casttime = 8, duration = 5 },
  MNK = {}, ROG = {}, BER = {},
}
-- proc weights: dmg = points per damage-per-minute, slow = per slow %, stun = flat,
-- debuff = per point of AC/ATK/resist debuff, heal = per hp healed per minute
local PROC_W = {
  WAR = { dmg = 0.35, slow = 4, stun = 40, debuff = 0.5, heal = 0.4 },
  PAL = { dmg = 0.35, slow = 3, stun = 50, debuff = 0.5, heal = 0.4 },
  SHD = { dmg = 0.4,  slow = 4, stun = 40, debuff = 0.5, heal = 0.5 },
  MNK = { dmg = 0.8,  slow = 2, stun = 15, debuff = 0.4, heal = 0.2 },
  ROG = { dmg = 0.9,  slow = 2, stun = 15, debuff = 0.4, heal = 0.2 },
  BER = { dmg = 0.9,  slow = 2, stun = 15, debuff = 0.4, heal = 0.2 },
  RNG = { dmg = 0.8,  slow = 2, stun = 15, debuff = 0.4, heal = 0.2 },
  BST = { dmg = 0.7,  slow = 2, stun = 15, debuff = 0.4, heal = 0.2 },
  BRD = { dmg = 0.5,  slow = 3, stun = 20, debuff = 0.5, heal = 0.2 },
}
local BASE_PPM = 2.0     -- EQEmu default average procs per minute

local function roleOf(class) return CLASS_ROLE[class] or 'melee' end

-- one focus spell -> list of { key, pct (effective), raw, maxLevel, note }
local function interpretFocus(e, class)
  local out = {}
  if not e or (e.reqLevel or 0) > evalLevel then return out end
  local maxLevel, decay, resistLimit, benefLimit = 0, 0, nil, nil
  for _, x in ipairs(e.effects) do
    if x.a == 134 then maxLevel, decay = x.b, x.b2
    elseif x.a == 135 then resistLimit = x.b
    elseif x.a == 138 then benefLimit = x.b end   -- 0 = detrimental only, 1 = beneficial only
  end
  local levelFactor = 1
  if maxLevel > 0 and evalLevel > maxLevel then
    levelFactor = decay > 0 and math.max(0, 1 - decay * (evalLevel - maxLevel) / 100) or 0
  end
  local role = roleOf(class)
  for _, x in ipairs(e.effects) do
    local ft = FOCUS_TYPES[x.a]
    if ft then
      local raw = math.max(math.abs(x.b), math.abs(x.b2))
      if ft.key == 'hate' then raw = x.b end          -- signed: negative = less hate
      local f = levelFactor
      local notes = {}
      if maxLevel > 0 then table.insert(notes, 'max L' .. maxLevel) end
      if resistLimit and resistLimit > 0 then f = f * 0.5; table.insert(notes, 'one resist type') end
      if benefLimit ~= nil and (ft.key == 'mana' or ft.key == 'casttime' or ft.key == 'duration') then
        if benefLimit == 0 then
          f = f * ((role == 'healer') and 0.3 or (role == 'caster' and 1 or 0.6)); table.insert(notes, 'detrimental only')
        else
          f = f * ((role == 'caster') and 0.3 or (role == 'healer' and 1 or 0.6)); table.insert(notes, 'beneficial only')
        end
      end
      table.insert(out, { key = ft.key, pct = raw * f, raw = raw, src = e.name, note = table.concat(notes, ', ') })
    end
  end
  return out
end

-- every focus spell on an item, its augs and any augs moved into it
local function focusSpells(item, extraAugs)
  local list = {}
  local function add(fx) for _, f in ipairs(fx and fx.focus or {}) do table.insert(list, f) end end
  if item then
    add(item.fx)
    for _, a in ipairs(item.augs or {}) do if a.aug then add(a.aug.fx) end end
  end
  for _, a in ipairs(extraAugs or {}) do add(a.fx) end
  return list
end

-- best focus per type across a set of focus spells. Returns key -> entry
local function bestFocus(spells, class, into)
  into = into or {}
  for _, e in ipairs(spells) do
    for _, f in ipairs(interpretFocus(e, class)) do
      local cur = into[f.key]
      local better = (f.key == 'hate') and (cur == nil or ((FOCUS_W[class] or {}).hate or 0) * (f.pct - cur.pct) > 0)
                     or (cur == nil or f.pct > cur.pct)
      if better then into[f.key] = f end
    end
  end
  return into
end

-- worn focus picture for a character, optionally without some slots / with extra items
local function charFocus(c, skip, extras)
  local spells = {}
  for s, it in pairs(c.worn or {}) do
    if not (skip and skip[s]) then for _, f in ipairs(focusSpells(it)) do table.insert(spells, f) end end
  end
  for _, x in ipairs(extras or {}) do
    for _, f in ipairs(focusSpells(x.item, x.augs)) do table.insert(spells, f) end
  end
  return bestFocus(spells, c.class)
end

local function focusScore(best, class)
  local w, sc = FOCUS_W[class] or {}, 0
  for k, f in pairs(best) do sc = sc + (w[k] or 0) * f.pct end
  return sc
end

-- gain from focus effects, plus text for what changes
local function focusGain(c, skip, extras, baseline)
  if not useEffects then return 0, {} end
  local after = charFocus(c, skip, extras)
  local gain = focusScore(after, c.class) - focusScore(baseline, c.class)
  local w, parts = FOCUS_W[c.class] or {}, {}
  for _, k in ipairs(FOCUS_ORDER) do
    local a, b = baseline[k], after[k]
    local pa, pb = a and a.pct or 0, b and b.pct or 0
    if math.abs(pb - pa) > 0.01 and (w[k] or 0) ~= 0 then
      table.insert(parts, { d = (w[k] or 0) * (pb - pa), imp = math.abs((w[k] or 0) * (pb - pa)),
        txt = string.format('%s %.0f%%->%.0f%%', FOCUS_LABEL[k], pa, pb) })
    end
  end
  return gain, parts
end

-- one proc -> { kind, perMin, value }
local function interpretProc(e, class)
  local r = { name = e and e.name or '', dmg = 0, slow = 0, stun = 0, debuff = 0, heal = 0, ppm = 0, value = 0 }
  if not e then return r end
  if (e.reqLevel or 0) > evalLevel then r.lost = true; return r end
  r.ppm = BASE_PPM * (1 + (e.procRate or 0) / 100)
  local lifetap = (e.target or ''):lower():find('lifetap') ~= nil
  for _, x in ipairs(e.effects) do
    local v = math.max(math.abs(x.b), math.abs(x.m))
    if (x.a == 0 or x.a == 79) and x.b < 0 then r.dmg = r.dmg + v; if lifetap then r.heal = r.heal + v end
    elseif (x.a == 0 or x.a == 79) and x.b > 0 then r.heal = r.heal + v
    elseif x.a == 11 and x.b < 100 and x.b > 0 then r.slow = math.max(r.slow, 100 - x.b)
    elseif x.a == 21 then r.stun = 1
    elseif (x.a == 1 or x.a == 2 or (x.a >= 46 and x.a <= 50)) and x.b < 0 then r.debuff = r.debuff + math.abs(x.b) end
  end
  local w = PROC_W[class] or { dmg = 0.1, slow = 1, stun = 5, debuff = 0.1, heal = 0.1 }
  -- damage/heal scale with procs per minute; slow/stun/debuff only need to land, so flat
  r.value = r.dmg * r.ppm * w.dmg + r.heal * r.ppm * w.heal + r.slow * w.slow + r.stun * w.stun + r.debuff * w.debuff
  return r
end

local function procScore(t, slot, class)
  if not useEffects then return 0 end
  local weaponSlot = slot == PRIMARY or slot == RANGE or (slot == SECONDARY and DUAL_WIELD[class])
  if not weaponSlot then return 0 end
  local sc = 0
  for _, p in ipairs(t._procs or {}) do sc = sc + interpretProc(p, class).value end
  return sc
end

local function movableAugs(fromItem, toItem)
  local free = {}
  for _, s in ipairs(toItem.augs or {}) do if not s.aug then table.insert(free, s) end end
  local moved = {}
  for _, src in ipairs(fromItem and fromItem.augs or {}) do
    if src.aug then
      for i, s in ipairs(free) do
        if hasBit(src.aug.augType, s.type) then
          table.insert(moved, src.aug); table.remove(free, i); break
        end
      end
    end
  end
  return moved
end

local function resistSum(t)
  return (t.svMagic or 0)+(t.svFire or 0)+(t.svCold or 0)+(t.svDisease or 0)+(t.svPoison or 0)+(t.svCorruption or 0)
end

-- score of a stat total in a given slot. hasteCap = best haste on your other gear
local function score(t, w, slot, hasteCap, class)
  local sc = 0
  for _, k in ipairs(WEIGHT_KEYS) do
    local wt = w[k] or 0
    if wt ~= 0 then
      local v
      if k == 'resists' then v = resistSum(t)
      elseif k == 'ratio' then
        local weaponSlot = slot == PRIMARY or slot == RANGE or (slot == SECONDARY and DUAL_WIELD[class])
        v = (weaponSlot and (t.delay or 0) > 0) and (100 * (t.damage or 0) / t.delay) or 0
      elseif k == 'haste' then v = math.max(0, (t.haste or 0) - hasteCap)
      else v = t[k] or 0 end
      sc = sc + v * wt
    end
  end
  return sc + procScore(t, slot, class)
end

local function bestHasteExcept(worn, skip)
  local m = 0
  for s, it in pairs(worn) do if not skip[s] then m = math.max(m, totals(it).haste or 0) end end
  return m
end

local function classAllowed(item, class)
  for _, c in ipairs(item.classes or {}) do if c == 'ALL' or c == class then return true end end
  return false
end

-- race check for items held by other characters (your own items use CanUse,
-- which already checks race, class and deity). Unknown race data = allowed,
-- so rescan everyone once to get race locks applied.
local function raceAllowed(item, race)
  if not race or not item.races or #item.races == 0 then return true end
  for _, r in ipairs(item.races) do if r == 'ALL' or r == race then return true end end
  return false
end

local function fits(item, slot)
  for _, s in ipairs(item.slots or {}) do if s == slot then return true end end
  return false
end

local function diffText(a, b, w, slot, class, extra)
  local parts = {}
  for _, x in ipairs(extra or {}) do table.insert(parts, x) end
  if slot and useEffects then
    local pa, pb = procScore(a, slot, class), procScore(b, slot, class)
    if math.abs(pb - pa) > 0.5 then
      local names = {}
      for _, p in ipairs(b._procs or {}) do table.insert(names, p.name) end
      table.insert(parts, { d = pb - pa, imp = math.abs(pb - pa),
        txt = #names > 0 and ('Proc: ' .. table.concat(names, ', ')) or 'Loses proc' })
    end
  end
  for _, k in ipairs(WEIGHT_KEYS) do
    if k ~= 'ratio' and (w[k] or 0) ~= 0 then
      local va, vb
      if k == 'resists' then va, vb = resistSum(a), resistSum(b) else va, vb = a[k] or 0, b[k] or 0 end
      local d = vb - va
      if d ~= 0 then table.insert(parts, { d = d, imp = math.abs(d * w[k]), txt = string.format('%+d %s', d, k == 'resists' and 'Resists' or (LABEL[k] or k)) }) end
    end
  end
  if (w.ratio or 0) ~= 0 and ((a.delay or 0) > 0 or (b.delay or 0) > 0) then
    local ra = (a.delay or 0) > 0 and (a.damage or 0) / a.delay or 0
    local rb = (b.delay or 0) > 0 and (b.damage or 0) / b.delay or 0
    if math.abs(rb - ra) > 0.001 then
      table.insert(parts, { d = rb - ra, imp = math.abs(rb - ra) * 100 * w.ratio, txt = string.format('Ratio %.2f->%.2f', ra, rb) })
    end
  end
  table.sort(parts, function(x, y) return x.imp > y.imp end)
  local out = {}
  for i = 1, math.min(5, #parts) do table.insert(out, parts[i]) end
  return out
end

-- ------------------------------------------------------------------- UI ---
local state = {
  open = true, chars = {}, rows = {}, dirty = true,
  augMode = 2, weightSource = 1,     -- 1 = MQ2ItemScore, 2 = GearUpgrades
  useBags = true, useBank = true, useShared = true, useOthers = false,
  levelCap = false, maxReq = 51, minGain = 1, bestOnly = true,
  charFilter = 'All characters', slotFilter = 'All slots', search = '',
  weightClass = nil, sortCol = 5, sortAsc = false,
  pendingSwap = nil, swapStatus = '',
}

local exportEffects   -- defined further down, used by the toolbar

local function weightsFor(class)
  if state.weightSource == 1 and iscoreWeights[class] then return iscoreWeights[class] end
  return myWeightsFor(class)
end

local function loadAll()
  state.chars = {}
  for _, key in ipairs(loadTable(INDEX) or {}) do
    local server, name = key:match('^(.-)|(.+)$')
    local t = name and loadTable(fileFor(server, name))
    if t then table.insert(state.chars, t) end
  end
  table.sort(state.chars, function(a, b) return a.name < b.name end)
  if not state.weightClass and state.chars[1] then state.weightClass = state.chars[1].class end
  state.dirty = true
end

local function sourceOk(item)
  if item.location == 'Bags' then return state.useBags end
  if item.location == 'Bank' then return state.useBank end
  if item.location == 'Shared Bank' then return state.useShared end
  return false
end

local function candidatesFor(c)
  local list, q = {}, state.search:lower()
  local function ok(it)
    return (not state.levelCap or it.req <= state.maxReq) and (q == '' or it.name:lower():find(q, 1, true))
  end
  for _, it in ipairs(c.owned or {}) do
    if sourceOk(it) and it.canUse and ok(it) then table.insert(list, { item = it, owner = c.name }) end
  end
  if state.useOthers then
    for _, o in ipairs(state.chars) do
      if o.name ~= c.name then
        for _, it in ipairs(o.owned or {}) do
          if sourceOk(it) and not it.nodrop and classAllowed(it, c.class) and raceAllowed(it, c.race) and ok(it) then
            table.insert(list, { item = it, owner = o.name })
          end
        end
      end
    end
  end
  return list
end

local function loreBlocked(it, worn, slot)
  if not it.lore then return false end
  for s, wi in pairs(worn) do if wi.id == it.id and s ~= slot then return true end end
  return false
end

local function slotWanted(slot)
  return state.slotFilter == 'All slots' or WORN[slot] == state.slotFilter
end

local function computeChar(c, out)
  local w = weightsFor(c.class)
  local worn = c.worn or {}
  local moveAugs = state.augMode == 2
  local best = {}
  local function push(slot, r) best[slot] = best[slot] or {}; table.insert(best[slot], r) end

  evalLevel = state.levelCap and state.maxReq or (c.level or 65)
  local baseline = charFocus(c)
  local cands = candidatesFor(c)
  local wearing2H = is2H(worn[PRIMARY])
  local capWeapons = bestHasteExcept(worn, { [PRIMARY] = true, [SECONDARY] = true })
  local priT, secT = totals(worn[PRIMARY]), totals(worn[SECONDARY])
  local pairNow = score(priT, w, PRIMARY, capWeapons, c.class) + score(secT, w, SECONDARY, capWeapons, c.class)

  for _, cand in ipairs(cands) do
    local it = cand.item
    local options = {}
    for _, slot in ipairs(it.slots) do
      if not SKIP_SLOTS[slot] and slotWanted(slot) and not loreBlocked(it, worn, slot) then
        local cur = worn[slot]
        local moved = (moveAugs and cur) and movableAugs(cur, it) or {}
        local newT = totals(it, moved)
        if slot == PRIMARY and is2H(it) then
          -- 2H vs whatever is in primary + secondary now
          local fg, fparts = focusGain(c, { [PRIMARY] = true, [SECONDARY] = true }, { { item = it, augs = moved } }, baseline)
          local sNew = score(newT, w, PRIMARY, capWeapons, c.class) + fg
          local gain = sNew - pairNow
          if gain >= state.minGain then
            local curT = totals(cur); addStats(curT, secT)
            for _, pr in ipairs(secT._procs) do table.insert(curT._procs, pr) end
            table.insert(options, { slot = slot, gain = gain, cur = cur, cur2 = worn[SECONDARY], curT = curT, newT = newT,
              moved = moved, newScore = sNew, curScore = pairNow, label = 'Primary (2H)', fparts = fparts })
          end
        elseif not ((slot == PRIMARY or slot == SECONDARY) and wearing2H) then
          -- normal slot (1H weapons only when not wearing a 2H; that case is handled below)
          local skip = { [slot] = true }
          local cap = bestHasteExcept(worn, skip)
          local curT = totals(cur)
          local fg, fparts = focusGain(c, skip, { { item = it, augs = moved } }, baseline)
          local sCur, sNew = score(curT, w, slot, cap, c.class), score(newT, w, slot, cap, c.class) + fg
          local gain = sNew - sCur
          if gain >= state.minGain then
            table.insert(options, { slot = slot, gain = gain, cur = cur, curT = curT, newT = newT,
              moved = moved, newScore = sNew, curScore = sCur, fparts = fparts })
          end
        end
      end
    end
    table.sort(options, function(a, b) return a.gain > b.gain end)
    local used = {}
    for _, o in ipairs(options) do
      local pair = PAIRED[o.slot]
      if not (pair and used[pair]) then
        used[o.slot] = true
        push(o.slot, { char = c.name, class = c.class, slot = o.slot, slotName = o.label or WORN[o.slot],
          cur = o.cur, cur2 = o.cur2, item = it, owner = cand.owner, gain = o.gain, moved = o.moved,
          curScore = o.curScore, newScore = o.newScore, diff = diffText(o.curT, o.newT, w, o.slot, c.class, o.fparts) })
      end
    end
  end

  -- wearing a 2H: best 1H primary + offhand pair you own
  if wearing2H and (slotWanted(PRIMARY) or slotWanted(SECONDARY)) then
    local cur = worn[PRIMARY]
    local sCur = score(priT, w, PRIMARY, capWeapons, c.class)
    local bestP, bestS = {}, {}
    for _, cand in ipairs(cands) do
      local it = cand.item
      if not is2H(it) then
        if fits(it, PRIMARY) then
          local moved = moveAugs and movableAugs(cur, it) or {}
          table.insert(bestP, { cand = cand, moved = moved, t = totals(it, moved) })
        end
        if fits(it, SECONDARY) then table.insert(bestS, { cand = cand, t = totals(it) }) end
      end
    end
    local top
    for _, p in ipairs(bestP) do
      local sp = score(p.t, w, PRIMARY, capWeapons, c.class)
      for _, s in ipairs(bestS) do
        if s.cand.item ~= p.cand.item and not (s.cand.item.lore and s.cand.item.id == p.cand.item.id) then
          local total = sp + score(s.t, w, SECONDARY, capWeapons, c.class)
          if not top or total > top.total then top = { p = p, s = s, total = total } end
        end
      end
      if not top or sp > top.total then top = { p = p, total = sp } end    -- primary alone, empty offhand
    end
    local fg, fparts = 0, {}
    if top then
      local extras = { { item = top.p.cand.item, augs = top.p.moved } }
      if top.s then table.insert(extras, { item = top.s.cand.item }) end
      fg, fparts = focusGain(c, { [PRIMARY] = true, [SECONDARY] = true }, extras, baseline)
      top.total = top.total + fg
    end
    if top and top.total - sCur >= state.minGain then
      local newT = { _procs = {} }; addStats(newT, top.p.t); if top.s then addStats(newT, top.s.t) end
      for _, pr in ipairs(top.p.t._procs) do table.insert(newT._procs, pr) end
      if top.s then for _, pr in ipairs(top.s.t._procs) do table.insert(newT._procs, pr) end end
      push(PRIMARY, { char = c.name, class = c.class, slot = PRIMARY, slotName = 'Primary + Secondary',
        cur = cur, item = top.p.cand.item, owner = top.p.cand.owner,
        item2 = top.s and top.s.cand.item, owner2 = top.s and top.s.cand.owner,
        gain = top.total - sCur, moved = top.p.moved, curScore = sCur, newScore = top.total,
        diff = diffText(priT, newT, w, PRIMARY, c.class, fparts) })
    end
  end

  for _, list in pairs(best) do
    table.sort(list, function(a, b) return a.gain > b.gain end)
    for i, r in ipairs(list) do if not state.bestOnly or i == 1 then table.insert(out, r) end end
  end
end

local function compute()
  local rows = {}
  for _, c in ipairs(state.chars) do
    if state.charFilter == 'All characters' or state.charFilter == c.name then computeChar(c, rows) end
  end
  local key = {
    [0] = function(r) return r.char end,
    [1] = function(r) return r.slot end,
    [2] = function(r) return r.cur and r.cur.name or '' end,
    [3] = function(r) return r.item.name end,
    [4] = function(r) return r.owner .. r.item.location end,
    [5] = function(r) return r.gain end,
  }
  local k = key[state.sortCol] or key[5]
  local asc = state.sortAsc
  table.sort(rows, function(a, b)
    local ka, kb = k(a), k(b)
    if ka == kb then
      if a.char ~= b.char then return a.char < b.char end
      return a.gain > b.gain
    end
    if asc then return ka < kb else return ka > kb end
  end)
  state.rows = rows
  state.dirty = false
end

-- never let a scoring error escape into the ImGui frame (that kills the window)
local function safeCompute()
  local ok, err = pcall(compute)
  if not ok then
    state.rows, state.dirty = {}, false
    state.swapStatus = 'Scoring error - see MQ console'
    warn('Scoring error: %s', tostring(err))
  end
end

local GREEN = { 0.45, 0.85, 0.45, 1 }
local RED   = { 0.95, 0.45, 0.45, 1 }
local AMBER = { 0.95, 0.75, 0.30, 1 }
local function colored(c, txt) ImGui.TextColored(c[1], c[2], c[3], c[4], txt) end

local function itemText(it)
  ImGui.Text(it.name)
  if ImGui.IsItemClicked() and it.link then mq.cmdf('/executelink %s', it.link) end
  return ImGui.IsItemHovered()
end

local function augTooltip(it, moved)
  local any = false
  for _, a in ipairs(it.augs or {}) do
    any = true
    if a.aug then ImGui.Text(string.format('  Slot %d (type %d): %s', a.index, a.type, a.aug.name))
    else ImGui.TextDisabled(string.format('  Slot %d (type %d): empty', a.index, a.type)) end
  end
  if not any then ImGui.TextDisabled('  No aug slots') end
  if moved and #moved > 0 then
    colored(AMBER, 'Augs moved over from worn item:')
    for _, m in ipairs(moved) do ImGui.Text('  ' .. m.name) end
  end
end

-- why the Equip button can't be used for a row (nil = it can)
local function swapBlocker(r)
  if r.owner ~= r.char or (r.item2 and r.owner2 ~= r.char) then return 'Held by another character - trade it first' end
  if r.item.location ~= 'Bags' or (r.item2 and r.item2.location ~= 'Bags') then return 'Move it from the bank to your bags first' end
  return nil
end

local function requestSwap(r)
  local moveAugs = (state.augMode == 2 and r.moved and #r.moved > 0) and 1 or 0
  local second = r.item2 and r.item2.id or 0
  if r.char == mq.TLO.Me.CleanName() then
    state.pendingSwap = { id = r.item.id, slot = r.slot, moveAugs = moveAugs == 1, second = second }
    state.swapStatus = 'Swapping in ' .. r.item.name .. '...'
  else
    mq.cmdf('/dex %s /lua run %s swap %d %d %d %d', r.char, SCRIPT, r.item.id, r.slot, moveAugs, second)
    state.swapStatus = string.format('Sent swap to %s: %s', r.char, r.item.name)
    state.reloadAt = mq.gettime() + 12000
  end
end

local function drawToolbar()
  if ImGui.Button('Rescan me') then state.rescanMe = true end
  ImGui.SameLine()
  if ImGui.Button('Rescan all boxes') then
    mq.cmdf('/dge /lua run %s scan', SCRIPT); state.rescanMe = true; state.reloadAt = mq.gettime() + 5000
  end
  ImGui.SameLine()
  if ImGui.Button('Rescan this zone') then
    mq.cmdf('/dgze /lua run %s scan', SCRIPT); state.rescanMe = true; state.reloadAt = mq.gettime() + 5000
  end
  ImGui.SameLine()
  if ImGui.Button('Reload') then loadIScore(); loadAll() end
  ImGui.SameLine()
  if ImGui.Button('Export effects report') then state.exportRequested = true end
  ImGui.SameLine()
  ImGui.TextDisabled(string.format('  %d character(s), %d upgrade(s)', #state.chars, #state.rows))
  if state.swapStatus ~= '' then ImGui.SameLine(); colored(AMBER, '  ' .. state.swapStatus) end
end

local function drawFilters()
  local v, ch
  ImGui.Text('Scoring:'); ImGui.SameLine()
  if ImGui.RadioButton('MQ2ItemScore (/iscore) weights', state.weightSource == 1) then state.weightSource = 1; state.dirty = true end
  ImGui.SameLine()
  if ImGui.RadioButton('GearUpgrades weights', state.weightSource == 2) then state.weightSource = 2; state.dirty = true end
  ImGui.SameLine(); ImGui.Text('   Augments:'); ImGui.SameLine()
  if ImGui.RadioButton('As they are', state.augMode == 1) then state.augMode = 1; state.dirty = true end
  ImGui.SameLine()
  if ImGui.RadioButton('Move my augs', state.augMode == 2) then state.augMode = 2; state.dirty = true end

  ImGui.Text('Look in:'); ImGui.SameLine()
  v, ch = ImGui.Checkbox('Bags', state.useBags);          if ch then state.useBags = v; state.dirty = true end; ImGui.SameLine()
  v, ch = ImGui.Checkbox('Bank', state.useBank);          if ch then state.useBank = v; state.dirty = true end; ImGui.SameLine()
  v, ch = ImGui.Checkbox('Shared bank', state.useShared); if ch then state.useShared = v; state.dirty = true end; ImGui.SameLine()
  v, ch = ImGui.Checkbox('Other characters (tradeable)', state.useOthers); if ch then state.useOthers = v; state.dirty = true end

  v, ch = ImGui.Checkbox('Max required level', state.levelCap); if ch then state.levelCap = v; state.dirty = true end
  ImGui.SameLine(); ImGui.SetNextItemWidth(90)
  v, ch = ImGui.InputInt('##maxreq', state.maxReq); if ch then state.maxReq = math.max(1, v); state.dirty = true end
  ImGui.SameLine(); ImGui.SetNextItemWidth(90)
  v, ch = ImGui.InputInt('Min gain', state.minGain); if ch then state.minGain = math.max(0, v); state.dirty = true end
  ImGui.SameLine()
  v, ch = ImGui.Checkbox('Best per slot only', state.bestOnly); if ch then state.bestOnly = v; state.dirty = true end
  ImGui.SameLine()
  v, ch = ImGui.Checkbox('Score focus effects & procs', useEffects); if ch then useEffects = v; state.dirty = true end

  ImGui.SetNextItemWidth(150)
  if ImGui.BeginCombo('##char', state.charFilter) then
    if ImGui.Selectable('All characters', state.charFilter == 'All characters') then state.charFilter = 'All characters'; state.dirty = true end
    for _, c in ipairs(state.chars) do
      if ImGui.Selectable(c.name, state.charFilter == c.name) then state.charFilter = c.name; state.dirty = true end
    end
    ImGui.EndCombo()
  end
  ImGui.SameLine(); ImGui.SetNextItemWidth(130)
  if ImGui.BeginCombo('##slot', state.slotFilter) then
    if ImGui.Selectable('All slots', state.slotFilter == 'All slots') then state.slotFilter = 'All slots'; state.dirty = true end
    for s = 0, 21 do
      if ImGui.Selectable(WORN[s], state.slotFilter == WORN[s]) then state.slotFilter = WORN[s]; state.dirty = true end
    end
    ImGui.EndCombo()
  end
  ImGui.SameLine(); ImGui.SetNextItemWidth(-1)
  local s, sch = ImGui.InputTextWithHint('##search', 'Search item name...', state.search)
  if sch then state.search = s or ''; state.dirty = true end
end

local function drawUpgrades()
  local flags = bit32.bor(ImGuiTableFlags.Borders, ImGuiTableFlags.RowBg, ImGuiTableFlags.Sortable,
    ImGuiTableFlags.ScrollY, ImGuiTableFlags.Resizable, ImGuiTableFlags.SizingStretchProp)
  if ImGui.BeginTable('upgrades', 8, flags, ImVec2(0, 0)) then
    ImGui.TableSetupScrollFreeze(0, 1)
    ImGui.TableSetupColumn('', ImGuiTableColumnFlags.NoSort, 0.45, 7)
    ImGui.TableSetupColumn('Character', 0, 0.9, 0)
    ImGui.TableSetupColumn('Slot', 0, 0.9, 1)
    ImGui.TableSetupColumn('Worn now', 0, 1.7, 2)
    ImGui.TableSetupColumn('Upgrade', 0, 1.7, 3)
    ImGui.TableSetupColumn('From', 0, 1.0, 4)
    ImGui.TableSetupColumn('Gain', bit32.bor(ImGuiTableColumnFlags.PreferSortDescending, ImGuiTableColumnFlags.DefaultSort), 0.5, 5)
    ImGui.TableSetupColumn('What changes', ImGuiTableColumnFlags.NoSort, 2.4, 6)
    ImGui.TableHeadersRow()

    local specs = ImGui.TableGetSortSpecs()
    if specs and specs.SpecsDirty and specs.SpecsCount > 0 then
      local sp = specs:Specs(1)
      state.sortCol = sp.ColumnUserID
      state.sortAsc = (sp.SortDirection == ImGuiSortDirection.Ascending)
      specs.SpecsDirty = false; state.dirty = true
    end
    if state.dirty then safeCompute() end

    for i, r in ipairs(state.rows) do
      ImGui.TableNextRow()
      ImGui.TableNextColumn()
      local blocker = swapBlocker(r)
      if blocker or state.pendingSwap then
        ImGui.TextDisabled('Equip')
        if blocker and ImGui.IsItemHovered() then ImGui.SetTooltip(blocker) end
      else
        if ImGui.SmallButton('Equip##' .. i) then requestSwap(r) end
        if ImGui.IsItemHovered() then
          ImGui.SetTooltip((r.moved and #r.moved > 0 and state.augMode == 2)
            and 'Move augs over, then equip. Rescans afterwards.' or 'Equip this, old item goes to bags. Rescans afterwards.')
        end
      end
      ImGui.TableNextColumn(); ImGui.Text(r.char .. ' (' .. r.class .. ')')
      ImGui.TableNextColumn(); ImGui.Text(r.slotName)
      ImGui.TableNextColumn()
      if r.cur then
        if itemText(r.cur) then ImGui.BeginTooltip(); ImGui.Text(r.cur.name); augTooltip(r.cur)
          ImGui.TextDisabled(string.format('Score %.0f', r.curScore or 0)); ImGui.EndTooltip() end
        if r.cur2 then ImGui.TextDisabled('+ ' .. r.cur2.name) end
      else ImGui.TextDisabled('(empty)') end
      ImGui.TableNextColumn()
      if itemText(r.item) then
        ImGui.BeginTooltip()
        ImGui.Text(r.item.name)
        if r.item.req > 0 then ImGui.TextDisabled('Required level ' .. r.item.req) end
        if r.item.nodrop then ImGui.TextDisabled('No Drop') end
        augTooltip(r.item, r.moved)
        ImGui.TextDisabled(string.format('Score %.0f vs %.0f now', r.newScore or 0, r.curScore or 0))
        ImGui.EndTooltip()
      end
      if r.item2 then ImGui.Text('+ ' .. r.item2.name) end
      ImGui.TableNextColumn()
      if r.owner ~= r.char then colored(AMBER, r.owner .. ': ' .. r.item.where) else ImGui.Text(r.item.where) end
      ImGui.TableNextColumn(); colored(GREEN, string.format('+%.0f', r.gain))
      ImGui.TableNextColumn()
      for j, d in ipairs(r.diff) do
        if j > 1 then ImGui.SameLine() end
        colored(d.d > 0 and GREEN or RED, d.txt)
      end
      if r.moved and #r.moved > 0 and state.augMode == 2 then ImGui.SameLine(); colored(AMBER, '(+' .. #r.moved .. ' aug)') end
    end
    ImGui.EndTable()
  end
end


-- ------------------------------------------------------- focus coverage ---
local function wornProcs(c)
  local list = {}
  for _, slot in ipairs({ PRIMARY, SECONDARY, RANGE }) do
    local it = (c.worn or {})[slot]
    if it then
      for _, p in ipairs(totals(it)._procs) do
        local r = interpretProc(p, c.class)
        r.item, r.slot = it.name, slot
        r.counts = slot ~= SECONDARY or DUAL_WIELD[c.class]
        table.insert(list, r)
      end
    end
  end
  return list
end

-- focus spells that use no SPA we score (custom EQ Might effects etc.)
local function otherFocus(c)
  local names, seen = {}, {}
  for _, it in pairs(c.worn or {}) do
    for _, e in ipairs(focusSpells(it)) do
      if #interpretFocus(e, c.class) == 0 and not seen[e.name] and (e.reqLevel or 0) <= evalLevel then
        local known = false
        for _, x in ipairs(e.effects) do if FOCUS_TYPES[x.a] then known = true end end
        if not known then seen[e.name] = true; table.insert(names, e.name) end
      end
    end
  end
  return names
end

local function lostEffects(c)
  local lost = {}
  for _, it in pairs(c.worn or {}) do
    local function chk(e) if e and (e.reqLevel or 0) > evalLevel then table.insert(lost, string.format('%s (%s, L%d)', e.name, it.name, e.reqLevel)) end end
    for _, e in ipairs(focusSpells(it)) do chk(e) end
    for _, p in ipairs(totals(it)._procs) do chk(p) end
  end
  return lost
end

local function drawCoverage()
  ImGui.TextWrapped('Best worn focus of each type per character (only the strongest of each type applies). '
    .. 'Amber "none" = a focus type that matters for that class but nothing worn provides it. '
    .. 'Percentages are effective values: reduced for spell-level limits, single resist type, or beneficial/detrimental-only.')
  if state.levelCap then colored(AMBER, string.format('Judged at level %d (Max required level filter is on).', state.maxReq)) end
  local ncol = 2 + #FOCUS_ORDER + 2
  local flags = bit32.bor(ImGuiTableFlags.Borders, ImGuiTableFlags.RowBg, ImGuiTableFlags.ScrollY, ImGuiTableFlags.SizingStretchProp)
  if ImGui.BeginTable('coverage', ncol, flags, ImVec2(0, 0)) then
    ImGui.TableSetupScrollFreeze(1, 1)
    ImGui.TableSetupColumn('Character', 0, 1.1)
    ImGui.TableSetupColumn('Class', 0, 0.5)
    for _, k in ipairs(FOCUS_ORDER) do ImGui.TableSetupColumn(FOCUS_LABEL[k], 0, 0.7) end
    ImGui.TableSetupColumn('Weapon procs', 0, 1.8)
    ImGui.TableSetupColumn('Other / lost effects', 0, 1.8)
    ImGui.TableHeadersRow()
    for _, c in ipairs(state.chars) do
      evalLevel = state.levelCap and state.maxReq or (c.level or 65)
      local okF, best = pcall(charFocus, c)
      if not okF then warn('Focus error for %s: %s', c.name, tostring(best)); best = {} end
      local w = FOCUS_W[c.class] or {}
      ImGui.TableNextRow()
      ImGui.TableNextColumn(); ImGui.Text(c.name)
      ImGui.TableNextColumn(); ImGui.Text(c.class or '')
      for _, k in ipairs(FOCUS_ORDER) do
        ImGui.TableNextColumn()
        local f = best[k]
        if f then
          local good = ((w[k] or 0) * f.pct) >= 0
          if math.abs(f.pct) < 0.5 then colored(AMBER, '0% (level)')
          else colored(good and GREEN or RED, string.format('%.0f%%', f.pct)) end
          if ImGui.IsItemHovered() then
            ImGui.BeginTooltip()
            ImGui.Text(f.src)
            ImGui.TextDisabled(string.format('Raw %d%%%s', f.raw, f.note ~= '' and ('  (' .. f.note .. ')') or ''))
            ImGui.TextDisabled(string.format('Worth %.0f points for %s', (w[k] or 0) * f.pct, c.class))
            ImGui.EndTooltip()
          end
        elseif (w[k] or 0) > 0 then colored(AMBER, 'none')
        else ImGui.TextDisabled('-') end
      end
      ImGui.TableNextColumn()
      local okP, procs = pcall(wornProcs, c)
      if not okP then procs = {} end
      if #procs == 0 then
        if PROC_W[c.class] then colored(AMBER, 'none') else ImGui.TextDisabled('-') end
      end
      for _, r in ipairs(procs) do
        if r.lost then colored(RED, r.name .. ' (lost)')
        elseif not r.counts then ImGui.TextDisabled(r.name .. ' (offhand, no dual wield)')
        else ImGui.Text(r.name) end
        if ImGui.IsItemHovered() then
          ImGui.BeginTooltip()
          ImGui.Text(r.item .. ' - ' .. WORN[r.slot])
          if r.dmg > 0 then ImGui.TextDisabled(string.format('%d dmg, ~%.1f procs/min = ~%.0f dmg/min', r.dmg, r.ppm, r.dmg * r.ppm)) end
          if r.slow > 0 then ImGui.TextDisabled(string.format('Slow %d%%', r.slow)) end
          if r.stun > 0 then ImGui.TextDisabled('Stun') end
          if r.debuff > 0 then ImGui.TextDisabled(string.format('Debuff %d', r.debuff)) end
          if r.heal > 0 then ImGui.TextDisabled(string.format('Heal %d', r.heal)) end
          ImGui.TextDisabled(string.format('Worth %.0f points', r.value))
          ImGui.EndTooltip()
        end
      end
      ImGui.TableNextColumn()
      local okO, other = pcall(otherFocus, c)
      for _, n in ipairs(okO and other or {}) do ImGui.TextDisabled(n) end
      local okL, lost = pcall(lostEffects, c)
      for _, n in ipairs(okL and lost or {}) do colored(RED, 'Lost: ' .. n) end
    end
    ImGui.EndTable()
  end
end

-- text report of every effect seen on any scanned item, for tuning weights
exportEffects = function()
  local path = CFG_DIR .. '/GearUpgrades_effects_report.txt'
  local f = io.open(path, 'w'); if not f then warn('Could not write %s', path); return end
  local seen = {}
  local function dump(kind, e, owner, item)
    if not e then return end
    local key = kind .. e.id
    if seen[key] then seen[key].n = seen[key].n + 1; return end
    local fx = {}
    for _, x in ipairs(e.effects) do table.insert(fx, string.format('%d:%d/%d/%d', x.a, x.b, x.b2, x.m)) end
    seen[key] = { n = 1, line = string.format('%s\t%s\t%d\treq=%d\trate=%d\t%s\t%s\t%s\tfirst seen: %s on %s',
      kind, e.name, e.id, e.reqLevel or 0, e.procRate or 0, e.target or '', e.resist or '', table.concat(fx, ' '), item, owner) }
  end
  local function walk(owner, it)
    local function fxOf(name, fx)
      if not fx then return end
      for _, e in ipairs(fx.focus or {}) do dump('focus', e, owner, name) end
      dump('proc', fx.proc, owner, name)
      if fx.clicky then dump('click', { name = fx.clicky.name, id = 0, reqLevel = fx.clicky.reqLevel, effects = {} }, owner, name) end
    end
    fxOf(it.name, it.fx)
    for _, a in ipairs(it.augs or {}) do if a.aug then fxOf(a.aug.name .. ' (aug)', a.aug.fx) end end
  end
  for _, c in ipairs(state.chars) do
    for _, it in pairs(c.worn or {}) do walk(c.name, it) end
    for _, it in ipairs(c.owned or {}) do walk(c.name, it) end
  end
  f:write('kind\tname\tspellid\treqLevel\tprocRate\ttarget\tresist\teffects (SPA:base/base2/max)\tfirst seen\tcount\n')
  local lines = {}
  for _, v in pairs(seen) do table.insert(lines, v.line .. '\t' .. v.n) end
  table.sort(lines)
  for _, l in ipairs(lines) do f:write(l, '\n') end
  f:close()
  say('wrote %d effects to %s', #lines, path)
end

local function drawSummary()
  if state.dirty then safeCompute() end
  local per = {}
  for _, r in ipairs(state.rows) do
    local p = per[r.char] or { slots = {}, n = 0, total = 0 }
    if not p.slots[r.slot] then p.slots[r.slot] = true; p.n = p.n + 1; p.total = p.total + r.gain end
    per[r.char] = p
  end
  local flags = bit32.bor(ImGuiTableFlags.Borders, ImGuiTableFlags.RowBg, ImGuiTableFlags.SizingStretchProp)
  if ImGui.BeginTable('summary', 5, flags) then
    ImGui.TableSetupColumn('Character'); ImGui.TableSetupColumn('Class / Lvl')
    ImGui.TableSetupColumn('Slots with upgrades'); ImGui.TableSetupColumn('Total gain'); ImGui.TableSetupColumn('Last scan')
    ImGui.TableHeadersRow()
    for _, c in ipairs(state.chars) do
      local p = per[c.name] or { n = 0, total = 0 }
      ImGui.TableNextRow(); ImGui.TableNextColumn()
      if ImGui.Selectable(c.name .. '##s', state.charFilter == c.name, ImGuiSelectableFlags.SpanAllColumns) then
        state.charFilter = (state.charFilter == c.name) and 'All characters' or c.name; state.dirty = true
      end
      ImGui.TableNextColumn(); ImGui.Text(string.format('%s %s', c.class or '', c.level or ''))
      ImGui.TableNextColumn()
      if p.n > 0 then colored(GREEN, tostring(p.n)) else ImGui.TextDisabled('0') end
      ImGui.TableNextColumn(); ImGui.Text(string.format('%.0f', p.total))
      ImGui.TableNextColumn(); ImGui.TextDisabled(c.scanned or '')
    end
    ImGui.EndTable()
  end
  ImGui.TextDisabled('Click a character to filter the Upgrades tab to them.')
end

local function drawWeights()
  local iscore = state.weightSource == 1
  if iscore then
    ImGui.TextWrapped('Showing your MQ2ItemScore weights (read-only here). Change them in game with /iscore <stat> <weight>, then /iscore save, then click Reload.')
  else
    ImGui.TextWrapped('Points per 1 of each stat. Weapon ratio is 100 x damage/delay (primary, range, and secondary for dual-wield classes). Haste only counts above your best other worn haste.')
  end
  ImGui.SetNextItemWidth(120)
  if ImGui.BeginCombo('Class', state.weightClass or 'WAR') then
    for _, cl in ipairs(CLASS_LIST) do
      if ImGui.Selectable(cl, state.weightClass == cl) then state.weightClass = cl end
    end
    ImGui.EndCombo()
  end
  local cl = state.weightClass or 'WAR'
  local w = weightsFor(cl)
  if not iscore then
    ImGui.SameLine()
    if ImGui.Button('Save weights') then mq.pickle(WEIGHTS, myWeights); say('weights saved') end
    ImGui.SameLine()
    if ImGui.Button('Reset ' .. cl .. ' to defaults') then myWeights[cl] = nil; myWeightsFor(cl); state.dirty = true end
  elseif not iscoreWeights[cl] then
    ImGui.SameLine(); colored(AMBER, 'No [' .. cl .. '] section in MQ2ItemScore.ini - using GearUpgrades weights')
  end

  local flags = bit32.bor(ImGuiTableFlags.Borders, ImGuiTableFlags.RowBg, ImGuiTableFlags.ScrollY)
  if ImGui.BeginTable('weights', 4, flags, ImVec2(0, 0)) then
    ImGui.TableSetupColumn('Stat'); ImGui.TableSetupColumn('Weight')
    ImGui.TableSetupColumn('Stat'); ImGui.TableSetupColumn('Weight')
    ImGui.TableHeadersRow()
    for i, k in ipairs(WEIGHT_KEYS) do
      if i % 2 == 1 then ImGui.TableNextRow() end
      ImGui.TableNextColumn(); ImGui.Text(LABEL[k] or k)
      ImGui.TableNextColumn()
      if iscore then
        local val = w[k] or 0
        if val == 0 then ImGui.TextDisabled('-') else ImGui.Text(string.format('%.2f', k == 'ratio' and val * 100 or val)) end
      else
        ImGui.SetNextItemWidth(-1)
        local nv = ImGui.InputFloat('##w' .. k, w[k] or 0, 0, 0, '%.2f')
        if nv and nv ~= (w[k] or 0) then w[k] = nv; state.dirty = true end
      end
    end
    ImGui.EndTable()
  end
end

local function draw()
  if not state.open then return end
  ImGui.SetNextWindowSize(ImVec2(1150, 650), ImGuiCond.FirstUseEver)
  local show
  state.open, show = ImGui.Begin('Gear Upgrades', state.open)
  if show then
    drawToolbar()
    ImGui.Separator()
    if ImGui.BeginTabBar('tabs') then
      if ImGui.BeginTabItem('Upgrades') then drawFilters(); drawUpgrades(); ImGui.EndTabItem() end
      if ImGui.BeginTabItem('By character') then drawSummary(); ImGui.EndTabItem() end
      if ImGui.BeginTabItem('Focus coverage') then drawCoverage(); ImGui.EndTabItem() end
      if ImGui.BeginTabItem('Stat weights') then drawWeights(); ImGui.EndTabItem() end
      ImGui.EndTabBar()
    end
  end
  ImGui.End()
end

if not loadIScore() then state.weightSource = 2 end
scanMe()
loadAll()
mq.imgui.init('GearUpgradesUI', draw)

-- one command, named after the script
mq.bind('/gearupgrades', function(cmd)
  cmd = (cmd or ''):lower()
  if cmd == 'scan' then state.rescanMe = true
  elseif cmd == 'scanall' then mq.cmdf('/dge /lua run %s scan', SCRIPT); state.rescanMe = true; state.reloadAt = mq.gettime() + 5000
  elseif cmd == 'scanzone' then mq.cmdf('/dgze /lua run %s scan', SCRIPT); state.rescanMe = true; state.reloadAt = mq.gettime() + 5000
  elseif cmd == 'export' then state.exportRequested = true
  elseif cmd == 'quit' then state.open = false
  else say('/gearupgrades scan | scanall | scanzone | export | quit') end
end)

while state.open do
  if state.pendingSwap then
    local p = state.pendingSwap
    local ok = doSwap(p.id, p.slot, p.moveAugs, p.second)
    state.swapStatus = ok and 'Swap done.' or 'Swap stopped - see MQ console.'
    state.pendingSwap = nil
    scanMe(); loadAll()
  end
  if state.exportRequested then
    state.exportRequested = false
    local ok, err = pcall(exportEffects)
    if not ok then warn('Export failed: %s', tostring(err)) end
  end
  if state.rescanMe then state.rescanMe = false; scanMe(); loadAll() end
  if state.reloadAt and mq.gettime() >= state.reloadAt then state.reloadAt = nil; loadAll() end
  mq.delay(200)
end
