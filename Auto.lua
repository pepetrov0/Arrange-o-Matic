local _, ns = ...

-- Auto-arrange state: dirty = the bags changed since the last arrangement;
-- lastBusy = the last time the player was doing something (or the bags changed).
local autoDirty, lastBusy = false, 0
local AUTO_POLL = 0.5
local IsBankOpen, IsGuildBankOpen = ns.IsBankOpen, ns.IsGuildBankOpen

local function Shown(f) return f and f:IsShown() end

-- Bag windows: Blizzard's, ElvUI's and those of common bag addons.
-- The names are built once: BagsOpen and PlayerBusy run several times a second.
local BAG_FRAMES = {}
for i = 1, NUM_CONTAINER_FRAMES or 13 do BAG_FRAMES[#BAG_FRAMES + 1] = "ContainerFrame" .. i end
for _, name in ipairs({ "ElvUI_ContainerFrame", "BagnonFrameinventory", "ARKINV_Frame1",
                        "AdiBagsContainer1", "CombuctorFrame1" }) do
    BAG_FRAMES[#BAG_FRAMES + 1] = name
end

local ROLL_FRAMES = {}
for i = 1, NUM_GROUP_LOOT_FRAMES or 4 do ROLL_FRAMES[i] = "GroupLootFrame" .. i end

local function BagsOpen()
    for i = 1, #BAG_FRAMES do
        if Shown(_G[BAG_FRAMES[i]]) then return true end
    end
    return false
end

-- Other windows where the player moves, equips, uses or hands in items.
local INVENTORY_FRAMES = { "MerchantFrame", "TradeFrame", "MailFrame", "AuctionFrame",
                           "StackSplitFrame", "CharacterFrame", "TradeSkillFrame",
                           "ItemSocketingFrame", "QuestFrame", "GossipFrame" }

-- Is the player doing something an arrangement would get in the way of?
-- running: an arrangement is already under way. Combat, casting and open bags
-- no longer matter then (moving bag items is harmless for them), and the cursor
-- is skipped because the executor itself puts items there (Step checks it).
local function PlayerBusy(running)
    if UnitIsDeadOrGhost("player") then return "You died." end   -- items can't be moved while dead
    if not running then
        if InCombatLockdown() or UnitAffectingCombat("player") then return "You are in combat." end
        if GetCursorInfo() then return "Your cursor is holding something." end
        if UnitCastingInfo("player") or UnitChannelInfo("player") then return "You are casting." end
    end
    if SpellIsTargeting() then return "You are choosing a spell target." end
    if ns.lootOpen or Shown(LootFrame) then return "You opened a loot window." end
    if IsBankOpen() or IsGuildBankOpen() then return "You opened a bank." end
    for i = 1, #ROLL_FRAMES do   -- need/greed rolls
        if Shown(_G[ROLL_FRAMES[i]]) then return "A loot roll appeared." end
    end
    for _, name in ipairs(INVENTORY_FRAMES) do
        if Shown(_G[name]) then return "You opened another window (" .. name:gsub("Frame$", "") .. ")." end
    end
    if not running and BagsOpen() then return "Your bags are open." end
end

-- Auto mode watcher: polls only while the bags are dirty.
local autoFrame, autoAcc = CreateFrame("Frame"), 0
autoFrame:Hide()
autoFrame:SetScript("OnUpdate", function(self, elapsed)
    autoAcc = autoAcc + elapsed
    if autoAcc < AUTO_POLL then return end
    autoAcc = 0
    if not (ArrangeOMaticDB and ArrangeOMaticDB.auto) then autoDirty = false end
    if ns.GetJob() then return end   -- stay shown: an auto run that aborts asks for a retry
    if not autoDirty then return self:Hide() end
    local now = GetTime()
    if PlayerBusy() then lastBusy = now; return end
    if now - lastBusy < (ArrangeOMaticDB.autoDelay or ns.AUTO_DELAY) then return end
    autoDirty = false
    ns.Start("bags", true)
end)

local function MarkDirty()
    if not (ArrangeOMaticDB and ArrangeOMaticDB.auto) then return end
    autoDirty, lastBusy = true, GetTime()
    autoFrame:Show()
end

-- A run was cancelled by the player: don't let auto mode restart it.
function ns.ClearAuto() autoDirty = false end

-- A run could not finish: try again once the player is idle.
function ns.Retry() autoDirty, lastBusy = true, GetTime() end

ns.MarkDirty, ns.BagsOpen, ns.PlayerBusy = MarkDirty, BagsOpen, PlayerBusy
