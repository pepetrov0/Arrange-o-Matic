local _, ns = ...

local Print, ItemID, IsGrey, MarkDirty = ns.Print, ns.ItemID, ns.IsGrey, ns.MarkDirty

-- Favorites (per character)
-- ArrangeOMaticCharDB exists from ADDON_LOADED on; NO_FAVS covers tooltips
-- shown before that without allocating.
local NO_FAVS = {}
local function Favs() return ArrangeOMaticCharDB and ArrangeOMaticCharDB.favs or NO_FAVS end

local function FavCount()
    local n = 0
    for _ in pairs(Favs()) do n = n + 1 end
    return n
end

-- Mark a tooltip line on favorite items.
local function AddFavLine(tt)
    local favs = Favs()
    if not next(favs) then return end
    local _, link = tt:GetItem()
    local id = ItemID(link)
    if id and favs[id] then
        tt:AddLine("Arrange-o-Matic: favorite", 0.2, 1, 0.6)
    end
end
for _, tt in ipairs({ GameTooltip, ItemRefTooltip, ShoppingTooltip1, ShoppingTooltip2 }) do
    if tt then tt:HookScript("OnTooltipSetItem", AddFavLine) end
end

local function FavCommand(arg, msg)
    local favs = Favs()
    if arg == "snapshot" or arg == "snap" then
        local new, n = {}, 0
        for bag = 0, NUM_BAG_SLOTS do
            for slot = 1, GetContainerNumSlots(bag) or 0 do
                local link = GetContainerItemLink(bag, slot)
                local id = ItemID(link)
                if id and not new[id] then
                    local name, _, quality = GetItemInfo(link)
                    if not IsGrey(link, quality) then
                        new[id] = name or true
                        n = n + 1
                    end
                end
            end
        end
        ArrangeOMaticCharDB.favs = new
        Print("favorites = the " .. n .. " different non-grey item(s) in your bags now (replacing the old list). Anything else counts as unwanted.")
        MarkDirty()
    elseif arg == "add" or arg == "remove" or arg == "rem" or arg == "del" then
        local adding = (arg == "add")
        local rest = (msg or ""):match("^%s*%S+%s+%S+%s*(.*)$") or ""
        local ids = {}
        for id in rest:gmatch("item:(%d+)") do ids[#ids + 1] = tonumber(id) end
        if #ids == 0 then
            for id in rest:gmatch("%d+") do ids[#ids + 1] = tonumber(id) end
        end
        if #ids == 0 then
            return Print("Shift-click one or more items into the command, e.g. /aom fav " .. (adding and "add" or "remove") .. " [Item], or give item IDs.")
        end
        for _, id in ipairs(ids) do
            local name, link = GetItemInfo(id)
            local label = link or name or ("item " .. id)
            if adding then
                favs[id] = name or favs[id] or true
                Print("Added to favorites: " .. label)
            elseif favs[id] then
                favs[id] = nil
                Print("Removed from favorites: " .. label)
            else
                Print(label .. " is not a favorite.")
            end
        end
        if not next(favs) then Print("No favorites left: bags are arranged as usual again.") end
        MarkDirty()
    elseif arg == "list" then
        local n = 0
        for id, saved in pairs(favs) do
            n = n + 1
            local name, link = GetItemInfo(id)
            Print("  " .. (link or name or (type(saved) == "string" and saved) or "item") .. " (" .. id .. ")")
        end
        Print(n == 0 and "no favorites (/aom fav snapshot or /aom fav add <item>)." or (n .. " favorite(s)."))
    elseif arg == "clear" then
        ArrangeOMaticCharDB.favs = {}
        Print("Favorites cleared: bags are arranged as usual again.")
        MarkDirty()
    else
        Print(FavCount() .. " favorite(s)  (use /aom fav snapshot|add|remove|list|clear)")
    end
end
-- The item on the mouse cursor, if any.
local function CursorItem()
    local kind, id = GetCursorInfo()
    if kind == "item" then return id end
end

-- An item was dropped on the add (adding = true) or remove square.
local function FavDrop(adding)
    local id = CursorItem()
    if not id then return end
    ClearCursor()   -- the item goes back where it came from
    local favs = ArrangeOMaticCharDB.favs
    local name, link = GetItemInfo(id)
    local label = link or name or ("item " .. id)
    if adding then
        if favs[id] then return Print(label .. " is already a favorite.") end
        favs[id] = name or true
        Print("Added to favorites: " .. label)
    elseif favs[id] then
        favs[id] = nil
        Print("Removed from favorites: " .. label)
        if not next(favs) then Print("No favorites left: bags are arranged as usual again.") end
    else
        return Print(label .. " is not a favorite.")
    end
    MarkDirty()
end

ns.Favs, ns.FavCount, ns.FavCommand = Favs, FavCount, FavCommand
ns.CursorItem, ns.FavDrop = CursorItem, FavDrop
