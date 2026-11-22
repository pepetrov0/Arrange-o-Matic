local _, ns = ...

--[[
ArrangeOMatic - WotLK 3.3.5a

  /aom                  arrange your bags
  /aom help             every command explained, with the current settings
  /aom bank             arrange the character bank (bank must be open)
  /aom gbank            arrange the currently open guild bank tab
  /aom ui default       you use the default Blizzard UI: one window per bag  (default)
  /aom ui single        you use ONE combined bag window (a bag addon)
  /aom ui               show the current setting
  /aom columns <n>      set the number of grid columns (saved; "ui single" only)
  /aom columns          show the current value
  /aom groups type      group single items by broad type only (default)
  /aom groups subtype   group single items by type AND subtype
  /aom pack on|off      combine partial stacks of the same item first (default on)
  /aom trash on|off     gather grey items at the far end of your bags (default on)
  /aom fav snapshot     make everything in your bags now your favorites (per character)
  /aom fav add|remove <item>   add/remove favorites (shift-click items, or item IDs)
  /aom fav list|clear   show / remove all favorites
  /aom auto on|off      arrange your bags by itself when you are idle (default off)
  /aom delay <seconds>  how long you must be idle before auto mode arranges (default 5)
  /aom toolbox on|off|reset   button bar shown while bags/bank/gbank are open (default on)
  /aom stop             cancel a running arrangement
  (long form: /arrangeomatic)

Model
  * All general-purpose slots of the container being sorted are read as ONE
    linear list of S slots:
      bags   - backpack, then bags 1-4
      bank   - the 28 main bank slots, then the 7 bank bags
      gbank  - the 98 slots of the active guild bank tab
    Specialised bags (quivers, herb bags, ...) and the keyring are left alone,
    except that Soul Shards in general slots are first moved into any free
    slots of your soul bags (bags and bank).
  * "ui single" (one combined bag window, for single-bag addons):
    that list is shown as ONE grid with N columns the way single-bag addons
    draw it: slot 1 is the bottom-right cell, slots run right-to-left and rows
    stack upwards. If S is not a multiple of N, the TOP row is the short one and
    is aligned to the right. The last slot is therefore the left end of the top
    row, and that is where packing starts: items are packed from the last slot
    towards the first, so free space ends up at the bottom/front.
  * "ui default" (default Blizzard UI, one window per bag; the default setting):
    every bag is its OWN grid, so a block can never straddle two windows.
      - bags: 4 columns (NUM_CONTAINER_COLUMNS). Blizzard draws the LAST slot at
        the bottom-right and slot 1 at the top-left of a short, right-aligned
        top row, i.e. slots read left-to-right, top-to-bottom - the opposite way
        round to the single window above.
      - main bank: 7 columns x 4 rows, slot 1 top-left; the 7 bank bags are 4
        columns like the inventory bags.
    Clusters are first handed out to windows (largest first; a cluster too big
    for any one window is split over several). For your bags the LAST bag is
    filled first and the backpack last, so the free space ends up in the first
    bags, where new loot lands. The bank works the same way. A cluster larger
    than the largest bag (the main bank not counted) is always split over
    several bags. Then each
    window is laid out on its own exactly like the single grid, packing from the
    top-left so free space ends up at the bottom of each window.
  * When sorting your bags the Hearthstone is always pinned to the first cell of
    the top row of the first window to be filled: the last slot of all bags in
    single mode, the top-left of the LAST bag in default mode.
  * Trash (bags only, /aom trash): grey items are taken out of the clusters and
    put in one unbroken run of slots at the opposite end from the Hearthstone -
    the very last cell in fill order, then backwards from there: slot 1 onwards
    in single mode, the bottom-right of the backpack leftwards and upwards in
    default mode (spilling into bag 1 if the backpack runs out).
  * Favorites (bags only, per character, /aom fav): if you have any, every
    non-grey item that is not a favorite is unwanted and goes in a second
    unbroken run right before the greys, sorted by category, then itemID.
    No favorites: arranged as before. Needs /aom trash on, like the greys.
  * The guild bank window is 14 columns x 7 rows, numbered column by column, so
    for /aom gbank the grid "width" is fixed at 7 (one model row = one window
    column, drawn transposed, which keeps clusters square in the window). The
    columns setting does not apply to it.
  * Packing (on by default): before arranging, partial stacks of the same item
    are combined - the fullest stack is topped up from the emptiest ones - so at
    most one partial stack per item is left. Each merge is a normal pick-up and
    drop onto the other stack, verified like any other move.
  * Clusters:
      - every itemID that occupies 2+ slots is one cluster
      - all remaining single-stack items are grouped into one cluster per
        category (GetItemInfo type/subtype, or just type - see /aom groups)
    Each cluster is laid out as a block whose bounding box is as close to square
    as possible (a w x h block with a short top row). Order inside a cluster
    does not matter.
]]

-- Shared by every file of the addon (the second argument WoW passes to each
-- file is the same table, so nothing needs to be global).
ns.DEFAULT_COLUMNS = 10
ns.MAX_COLUMNS     = 40
ns.AUTO_DELAY      = 5      -- seconds idle before auto mode arranges
ns.MAX_AUTO_DELAY  = 60
ns.BANK_CONTAINER  = -1
-- The 3.3.5 guild bank window is 14 columns x 7 rows and is numbered column by
-- column: slots 1-7 are the first column top to bottom, 8-14 the second, etc.
ns.GBANK_COLUMN_H  = 7

ns.TAG     = "|cff33ff99Arrange-o-Matic|r"
ns.VERSION = GetAddOnMetadata("ArrangeOMatic", "Version") or "?"

-- Window state, kept up to date by Events.lua.
ns.bankOpen, ns.gbankOpen, ns.lootOpen = false, false, false

function ns.Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage(ns.TAG .. " " .. msg)
end

function ns.GetColumns()
    return (ArrangeOMaticDB and ArrangeOMaticDB.columns) or ns.DEFAULT_COLUMNS
end

-- "default" = default Blizzard UI, one window per bag  (the default setting)
-- "single"  = one combined bag window (a bag addon)  - the original behaviour
function ns.GetUI()
    return (ArrangeOMaticDB and ArrangeOMaticDB.ui == "single") and "single" or "default"
end

-- Fill in saved-variable defaults (called once, on ADDON_LOADED).
function ns.InitDB()
    local db = ArrangeOMaticDB or {}
    ArrangeOMaticDB = db
    db.columns  = tonumber(db.columns) or ns.DEFAULT_COLUMNS
    db.subtypes = db.subtypes and true or false
    if db.pack == nil then db.pack = true end
    if db.trash == nil then db.trash = true end
    if db.ui ~= "single" then db.ui = "default" end
    db.auto = db.auto and true or false
    if db.toolbox == nil then db.toolbox = true end
    db.autoDelay = tonumber(db.autoDelay) or ns.AUTO_DELAY
    local cdb = ArrangeOMaticCharDB or {}
    ArrangeOMaticCharDB = cdb
    if type(cdb.favs) ~= "table" then cdb.favs = {} end
end

function ns.ItemID(link)
    return link and tonumber(link:match("item:(%d+)"))
end

-- Poor (grey) quality; the link's colour code is the fallback if the item
-- info isn't cached yet (quality nil).
function ns.IsGrey(link, quality)
    return quality == 0 or (quality == nil and link:find("|cff9d9d9d", 1, true) ~= nil)
end
