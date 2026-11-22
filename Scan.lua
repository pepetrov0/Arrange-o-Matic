local _, ns = ...

local BANK_CONTAINER = ns.BANK_CONTAINER
local GBANK_SLOTS    = MAX_GUILDBANK_SLOTS_PER_TAB or 98
local SOUL_BAG_FAMILY = 0x0004  -- GetContainerNumFreeSlots bag family bit for soul bags
local ItemID, IsGrey = ns.ItemID, ns.IsGrey

-- The grouping key for single-stack items. By default it is the broad type
-- (e.g. "Consumable", "Armor"); /aom groups subtype switches to "type/subtype"
-- (e.g. "Consumable/Potion", "Armor/Plate", "Trade Goods/Herb"). Edit this if you want a different notion.
local function GetCategory(itemType, subType)
    itemType = itemType or "Unknown"
    if not (ArrangeOMaticDB and ArrangeOMaticDB.subtypes) then return itemType end
    return itemType .. "/" .. (subType or "")
end

-- SigAt runs every frame for every move in flight, so the pattern match is
-- memoized (cleared when it grows, which keeps it small).
local baseCache, baseCount = {}, 0
local function LinkBase(link)
    local b = baseCache[link]
    if not b then
        if baseCount >= 512 then baseCache, baseCount = {}, 0 end
        b = link:match("|H(item:[^|]+)|h") or link
        baseCache[link], baseCount = b, baseCount + 1
    end
    return b
end

local function SigFrom(base, count)
    return base .. "x" .. (count or 1)
end

-- Each container type gets a tiny API so the executor doesn't care which it is.
-- A "slot" is { bag = <bag id or guild tab>, slot = <index> }.
local BagAPI = {
    link   = function(s) return GetContainerItemLink(s.bag, s.slot) end,
    info   = function(s) local _, count, locked = GetContainerItemInfo(s.bag, s.slot); return count, locked end,
    pickup = function(s) PickupContainerItem(s.bag, s.slot) end,
}
local GuildAPI = {
    link   = function(s) return GetGuildBankItemLink(s.bag, s.slot) end,
    info   = function(s) local _, count, locked = GetGuildBankItemInfo(s.bag, s.slot); return count, locked end,
    pickup = function(s) PickupGuildBankItem(s.bag, s.slot) end,
}

local function SigAt(api, slot)
    local link = api.link(slot)
    if not link then return "" end
    return SigFrom(LinkBase(link), (api.info(slot)))
end

local function IsLocked(api, slot)
    local _, locked = api.info(slot)
    return locked and true or false
end

local function Describe(api, slot)
    local link = api.link(slot)
    if not link then return nil end
    local count = api.info(slot)
    local _, _, quality, _, _, itemType, subType, stack = GetItemInfo(link)
    local base = LinkBase(link)
    return {
        trash = IsGrey(link, quality),
        id    = ItemID(link),
        cat   = GetCategory(itemType, subType),
        sig   = SigFrom(base, count),
        base  = base,
        count = count or 1,
        stack = stack,   -- max stack size (nil if not cached)
    }
end

-- Returns slots, items, groups and soulFree. groups has one entry per bag that
-- was included: { bag = id, first = index of its first slot in `slots`, size = n }.
-- soulFree lists the empty slots of soul bags ({ bag, slot }), in bag order.
local function ScanBags(bagIds)
    local slots, items, groups, soulFree = {}, {}, {}, {}
    for _, bag in ipairs(bagIds) do
        local n = GetContainerNumSlots(bag)
        if n and n > 0 then
            local general = true
            if bag > 0 then
                local _, bagType = GetContainerNumFreeSlots(bag)
                general = (bagType == nil or bagType == 0)
                if bagType and bit.band(bagType, SOUL_BAG_FAMILY) ~= 0 then
                    for i = 1, n do
                        if not GetContainerItemLink(bag, i) then
                            soulFree[#soulFree + 1] = { bag = bag, slot = i }
                        end
                    end
                end
            end
            if general then
                groups[#groups + 1] = { bag = bag, first = #slots + 1, size = n }
                for i = 1, n do
                    local v = #slots + 1
                    slots[v] = { bag = bag, slot = i }
                    items[v] = Describe(BagAPI, slots[v])
                end
            end
        end
    end
    return slots, items, groups, soulFree
end

local function InventoryBagIds()
    local ids = {}
    for bag = 0, NUM_BAG_SLOTS do ids[#ids + 1] = bag end
    return ids
end

local function BankBagIds()
    local ids = { BANK_CONTAINER }
    for bag = NUM_BAG_SLOTS + 1, NUM_BAG_SLOTS + NUM_BANKBAGSLOTS do ids[#ids + 1] = bag end
    return ids
end

local function ScanGuildTab(tab)
    local slots, items = {}, {}
    for i = 1, GBANK_SLOTS do
        slots[i] = { bag = tab, slot = i }
        items[i] = Describe(GuildAPI, slots[i])
    end
    return slots, items
end

-- Is the relevant window open? (events first, frame visibility as a fallback)
local function IsBankOpen()
    return ns.bankOpen or (BankFrame and BankFrame:IsShown()) and true or false
end
local function IsGuildBankOpen()
    return ns.gbankOpen or (GuildBankFrame and GuildBankFrame:IsShown()) and true or false
end

ns.SigFrom, ns.SigAt, ns.IsLocked = SigFrom, SigAt, IsLocked
ns.BagAPI, ns.GuildAPI = BagAPI, GuildAPI
ns.ScanBags, ns.ScanGuildTab = ScanBags, ScanGuildTab
ns.InventoryBagIds, ns.BankBagIds = InventoryBagIds, BankBagIds
ns.IsBankOpen, ns.IsGuildBankOpen = IsBankOpen, IsGuildBankOpen
