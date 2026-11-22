local _, ns = ...

local Print, GetUI, GetColumns = ns.Print, ns.GetUI, ns.GetColumns
local TAG, ADDON_VERSION = ns.TAG, ns.VERSION
local MAX_COLUMNS, MAX_AUTO_DELAY, AUTO_DELAY = ns.MAX_COLUMNS, ns.MAX_AUTO_DELAY, ns.AUTO_DELAY
local MarkDirty, Start, Abort, GetJob = ns.MarkDirty, ns.Start, ns.Abort, ns.GetJob
local FavCount, FavCommand = ns.FavCount, ns.FavCommand

-- "on"/"1"/"yes" -> true, "off"/"0"/"no" -> false, anything else -> nil
local function ParseBool(arg)
    if arg == "on" or arg == "1" or arg == "yes" then return true end
    if arg == "off" or arg == "0" or arg == "no" then return false end
end

SLASH_ARRANGEOMATIC1 = "/arrangeomatic"
SLASH_ARRANGEOMATIC2 = "/aom"

-- /aom help: every command, what it does, and the current saved values.
local function ShowHelp()
    local db = ArrangeOMaticDB or {}
    local function onoff(v) return v and "on" or "off" end
    local C, W, R = "|cffffd100", "|cffffffff", "|r"
    local function line(s) DEFAULT_CHAT_FRAME:AddMessage(s) end
    local function cmd(c, text) line("  " .. C .. c .. R .. " - " .. text) end
    local function now(v) return " Now: " .. W .. v .. R .. "." end

    line(TAG .. " v" .. ADDON_VERSION .. " - packs your items into tidy, square blocks.")
    line(W .. "Arranging" .. R)
    cmd("/aom", "arrange your bags (backpack and bags 1-4). Specialised bags (quivers, herb bags...) and the keyring are left alone.")
    cmd("/aom bank", "arrange the bank: the main bank slots plus your bank bags. The bank must be open.")
    cmd("/aom gbank", "arrange the guild bank tab you are looking at. You need permission to move items on that tab.")
    cmd("/aom stop", "cancel an arrangement in progress. Items already moved stay where they are.")
    line(W .. "How items are grouped" .. R)
    line("  - An item taking 2+ slots (e.g. 8 stacks of a herb) becomes one block.")
    line("  - The remaining single stacks are grouped by category (see /aom groups).")
    line("  - Each block is as close to square as possible; free space gathers where new loot lands.")
    line("  - Bags: the Hearthstone always goes first - the top-left of your last bag (of the combined grid in ui single).")
    line("  - Soul Shards in regular slots are moved into free soul bag slots first.")
    line("  - Every move is checked before and after; if something changes mid-run, it stops cleanly.")
    line(W .. "Settings (saved per account; leave out the value to see the current one)" .. R)
    cmd("/aom ui default|single", "default: each Blizzard bag window is its own grid, and the last bag fills first so the backpack keeps the free space. single: all bags as ONE grid, for one-window bag addons." .. now(GetUI()))
    cmd("/aom columns <n>", "width of that one grid, 1-" .. MAX_COLUMNS .. ". Only used with ui single - Blizzard's windows have a fixed width." .. now(GetColumns()))
    cmd("/aom groups type|subtype", "type (default): group single stacks by broad type only (Consumable, Armor...). subtype: by type AND subtype (Consumable/Potion, Armor/Plate...)." .. now(db.subtypes and "subtype" or "type"))
    cmd("/aom pack on|off", "before arranging, combine partial stacks of the same item, leaving at most one partial stack each." .. now(onoff(db.pack ~= false)))
    cmd("/aom trash on|off", "bags only: put grey items in one unbroken run at the far end, opposite the Hearthstone - easy to find at a vendor." .. now(onoff(db.trash ~= false)))
    cmd("/aom fav snapshot", "this character: make everything (non-grey) in your bags right now your favorites, replacing the old list. While you have favorites, every other item is unwanted: bags put it in one run right before the greys at the far end. Favorites get a line in their tooltip." .. now(FavCount() .. " favorite(s)"))
    cmd("/aom fav add|remove <item>", "add or remove favorites: shift-click items into the command, or type item IDs. Several at once is fine.")
    cmd("/aom fav list|clear", "show your favorites, or remove them all (bags are then arranged as usual).")
    cmd("/aom auto on|off", "arrange your bags by themselves after they change, once you are idle: alive, out of combat, not looting or casting, nothing on the cursor, your bags closed, and no vendor, bank, mail, trade, auction, NPC, quest, character, crafting or socketing window open. Once a run has started, combat, casting and opening your bags no longer stop it; dying, picking up an item or opening a vendor, bank, mail, trade, loot or similar window does, and it tries again later." .. now(onoff(db.auto)))
    cmd("/aom toolbox on|off|reset", "a small draggable button bar (arrange bags / bank / guild bank, stop, pack, junk and auto toggles) shown while your bags or a bank are open. reset puts it back at the default spot." .. now(onoff(db.toolbox ~= false)))
    cmd("/aom delay <seconds>", "how long you must be idle before auto mode arranges, 1-" .. MAX_AUTO_DELAY .. "." .. now((db.autoDelay or AUTO_DELAY) .. "s"))
    line("  Long form: /arrangeomatic.")
end
SlashCmdList["ARRANGEOMATIC"] = function(msg)
    local cmd, arg = (msg or ""):lower():match("^%s*(%S*)%s*(%S*)")
    if cmd == "" or cmd == "run" or cmd == "bags" then
        Start("bags")
    elseif cmd == "bank" then
        Start("bank")
    elseif cmd == "gbank" or cmd == "guildbank" then
        Start("gbank")
    elseif cmd == "columns" or cmd == "cols" or cmd == "c" then
        if arg == "" then
            Print("columns = " .. GetColumns())
        else
            local n = tonumber(arg)
            if not n or n < 1 or n > MAX_COLUMNS then
                return Print("Columns must be a number from 1 to " .. MAX_COLUMNS .. ".")
            end
            ArrangeOMaticDB.columns = math.floor(n)
            Print("Columns set to " .. ArrangeOMaticDB.columns)
            if GetUI() == "default" then
                Print("(not used while ui is 'default': Blizzard's windows have a fixed width. /aom ui single to use it)")
            end
        end
    elseif cmd == "ui" or cmd == "layout" then
        if arg == "default" or arg == "blizzard" or arg == "separate" then
            ArrangeOMaticDB.ui = "default"
            Print("ui = default: arranging each bag as its own Blizzard window.")
        elseif arg == "single" or arg == "combined" or arg == "one" or arg == "addon" then
            ArrangeOMaticDB.ui = "single"
            Print("ui = single: arranging all bags as one combined window (" .. GetColumns() .. " columns).")
        else
            Print("ui = " .. GetUI() .. "  (use /aom ui single|default)")
        end
    elseif cmd == "groups" or cmd == "group" then
        if arg == "type" or arg == "types" then
            ArrangeOMaticDB.subtypes = false
            Print("Grouping single items by broad type.")
        elseif arg == "subtype" or arg == "sub" or arg == "subtypes" then
            ArrangeOMaticDB.subtypes = true
            Print("Grouping single items by type and subtype.")
        else
            Print("groups = " .. (ArrangeOMaticDB.subtypes and "subtype" or "type")
                  .. "  (use /aom groups type|subtype)")
        end
    elseif cmd == "pack" or cmd == "merge" or cmd == "stacks" then
        local on = ParseBool(arg)
        if on ~= nil then
            ArrangeOMaticDB.pack = on
            Print(on and "pack = on: partial stacks are combined before arranging."
                      or "pack = off: stacks are left as they are.")
        else
            Print("pack = " .. (ArrangeOMaticDB.pack == false and "off" or "on") .. "  (use /aom pack on|off)")
        end
    elseif cmd == "trash" or cmd == "junk" or cmd == "grey" or cmd == "gray" then
        local on = ParseBool(arg)
        if on ~= nil then
            ArrangeOMaticDB.trash = on
            Print(on and "trash = on: grey items are gathered at the far end of your bags."
                      or "trash = off: grey items are grouped like any other item.")
        else
            Print("trash = " .. (ArrangeOMaticDB.trash == false and "off" or "on") .. "  (use /aom trash on|off)")
        end
    elseif cmd == "fav" or cmd == "favs" or cmd == "favorite" or cmd == "favorites"
        or cmd == "favourite" or cmd == "favourites" then
        FavCommand(arg, msg)
    elseif cmd == "auto" then
        local on = ParseBool(arg)
        if on ~= nil then
            ArrangeOMaticDB.auto = on
            if on then
                Print("auto = on: your bags are arranged by themselves once you are idle and out of combat.")
                MarkDirty()
            else
                Print("auto = off.")
            end
        else
            Print("auto = " .. (ArrangeOMaticDB.auto and "on" or "off") .. ", delay = "
                  .. ArrangeOMaticDB.autoDelay .. "s  (use /aom auto on|off, /aom delay <seconds>)")
        end
    elseif cmd == "delay" then
        if arg == "" then
            Print("delay = " .. ArrangeOMaticDB.autoDelay .. "s  (use /aom delay <seconds>)")
        else
            local n = tonumber(arg)
            if not n or n < 1 or n > MAX_AUTO_DELAY then
                return Print("Delay must be a number of seconds from 1 to " .. MAX_AUTO_DELAY .. ".")
            end
            ArrangeOMaticDB.autoDelay = n
            Print("Delay set to " .. n .. "s: auto mode waits that long after you go idle.")
            if not ArrangeOMaticDB.auto then Print("(auto is off - /aom auto on to use it)") end
        end
    elseif cmd == "toolbox" or cmd == "tb" then
        local on = ParseBool(arg)
        if on ~= nil then
            ArrangeOMaticDB.toolbox = on
            Print(on and "toolbox = on: a button bar appears while your bags or a bank are open (drag it to move)."
                      or "toolbox = off.")
        elseif arg == "reset" then
            ArrangeOMaticDB.toolboxPos = nil
            ns.HideToolbox()
            Print("Toolbox position reset.")
        else
            Print("toolbox = " .. (ArrangeOMaticDB.toolbox and "on" or "off") .. "  (use /aom toolbox on|off|reset)")
        end
    elseif cmd == "stop" then
        if GetJob() then
            Abort("Cancelled by /aom stop.")
            ns.ClearAuto()   -- don't let auto mode restart it straight away
        else
            Print("Nothing running.")
        end
    elseif cmd == "help" or cmd == "h" or cmd == "?" then
        ShowHelp()
    else
        Print("Unknown command. /aom help explains every command; in short:")
        Print("/aom  |  /aom bank  |  /aom gbank  |  /aom ui single|default  |  /aom columns <n>  |  /aom groups type|subtype  |  /aom pack on|off  |  /aom trash on|off  |  /aom fav snapshot|add|remove|list|clear  |  /aom auto on|off  |  /aom delay <seconds>  |  /aom toolbox on|off|reset  |  /aom stop  |  /aom help")
    end
end
