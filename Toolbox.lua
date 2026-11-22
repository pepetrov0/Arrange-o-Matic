local _, ns = ...

local Print, GetUI, GetColumns = ns.Print, ns.GetUI, ns.GetColumns
local MarkDirty, BagsOpen = ns.MarkDirty, ns.BagsOpen
local IsBankOpen, IsGuildBankOpen = ns.IsBankOpen, ns.IsGuildBankOpen
local Start, Abort, GetJob = ns.Start, ns.Abort, ns.GetJob
local FavCount, FavCommand, FavDrop, CursorItem = ns.FavCount, ns.FavCommand, ns.FavDrop, ns.CursorItem
local AUTO_DELAY = ns.AUTO_DELAY

local TB_SIZE, TB_PAD, TB_GAP = 40, 6, 6
local TB_GRIP = TB_SIZE / 3   -- extra space before a button marked gapBefore
local TB_ICONS  = "Interface\\Icons\\"
local STOP_ICON = "Interface\\Buttons\\UI-StopButton"
local toolbox, tbMode, tbBits, tbButtons, tbMenu, tbMenuClosed

local function DBFlag(key, default)
    local v = ArrangeOMaticDB[key]
    if v == nil then v = default end
    return v ~= false
end

local function FlipFlag(key, default)
    ArrangeOMaticDB[key] = not DBFlag(key, default)
    if key == "auto" and ArrangeOMaticDB.auto then MarkDirty() end
end

-- Is this the arrange button whose run is in progress? It turns into a stop button.
local function TbStopping(d)
    local job = GetJob()
    return job ~= nil and d.arrange and job.mode == d.id
end

local OpenMenu

-- Buttons in display order. show: when visible; arrange: starts a run;
-- drop: receives an item dragged onto it; extra: a live line for the tooltip.
local TB_DEFS = {
    { arrange = true, id = "bags",  title = "Arrange bags", icon = TB_ICONS .. "INV_Misc_Bag_08",
      tip = "Packs your backpack and bags into tidy, square blocks, grouped by category. Same as /aom.",
      show = function() return true end, click = function() Start("bags") end },
    { arrange = true, id = "bank",  title = "Arrange bank", icon = TB_ICONS .. "INV_Misc_Coin_01",
      tip = "Arranges the main bank slots and your bank bags. Same as /aom bank.",
      show = IsBankOpen, click = function() Start("bank") end },
    { arrange = true, id = "gbank", title = "Arrange guild bank tab", icon = TB_ICONS .. "INV_Misc_Coin_01", badge = TB_ICONS .. "INV_Shirt_GuildTabard_01",
      tip = "Arranges the guild bank tab you are looking at. You need permission to move items on it. Same as /aom gbank.",
      show = IsGuildBankOpen, click = function() Start("gbank") end },
    { id = "favadd", gapBefore = true, title = "Add favorite", icon = TB_ICONS .. "INV_Misc_Book_09", badge = "Interface\\Buttons\\UI-PlusButton-Up",
      tip = "Drag an item from your bags onto this square to make it a favorite. While you have favorites, every other item is gathered at the far end of your bags.",
      extra = function() return FavCount() .. " favorite(s) now." end,
      drop = function() FavDrop(true) end },
    { id = "favdel", title = "Remove favorite", icon = TB_ICONS .. "INV_Misc_Book_09", badge = "Interface\\Buttons\\UI-MinusButton-Up",
      tip = "Drag an item onto this square to remove it from your favorites.",
      extra = function() return FavCount() .. " favorite(s) now." end,
      drop = function() FavDrop(false) end },
    { id = "settings", title = "Settings", icon = TB_ICONS .. "Trade_Engineering",
      tip = "Pack stacks, gather junk, auto-arrange, bag layout, grouping, favorites and more.",
      click = function(self) OpenMenu(self) end },
}

local function TbSkin(f, buttons)
    local E = ElvUI and unpack(ElvUI)
    if not (E and f.SetTemplate) then
        f:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 14,
            insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        f:SetBackdropColor(0, 0, 0, 0.8)
        f:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
        for _, b in pairs(buttons) do
            b:SetBackdrop({ edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 10,
                            insets = { left = 2, right = 2, top = 2, bottom = 2 } })
            b:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
            b.icon:SetPoint("TOPLEFT", 3, -3)
            b.icon:SetPoint("BOTTOMRIGHT", -3, 3)
            b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
        end
        return
    end
    f:SetTemplate("Transparent")
    for _, b in pairs(buttons) do
        b:SetTemplate("Default", true)
        if b.StyleButton then b:StyleButton() end
        b.icon:SetPoint("TOPLEFT", 2, -2)
        b.icon:SetPoint("BOTTOMRIGHT", -2, 2)
    end
end

local function GetToolbox()
    if toolbox then return toolbox end
    local f = CreateFrame("Frame", "ArrangeOMaticToolbox", UIParent)
    f:SetHeight(TB_SIZE + TB_PAD * 2)
    f:SetFrameStrata("HIGH")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        ArrangeOMaticDB.toolboxPos = { self:GetLeft(), self:GetBottom() }
        self:ClearAllPoints()
        self:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", unpack(ArrangeOMaticDB.toolboxPos))
    end)
    f:Hide()

    tbButtons = {}
    for _, d in ipairs(TB_DEFS) do
        local b = CreateFrame("Button", nil, f)
        b:SetWidth(TB_SIZE)
        b:SetHeight(TB_SIZE)
        b.icon = b:CreateTexture(nil, "ARTWORK")
        b.icon:SetTexture(d.icon)
        b.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        if d.badge then   -- small corner emblem, e.g. the guild tabard on the guild bank
            b.badge = b:CreateTexture(nil, "OVERLAY")
            b.badge:SetTexture(d.badge)
            b.badge:SetTexCoord(0.07, 0.93, 0.07, 0.93)
            b.badge:SetWidth(18)
            b.badge:SetHeight(18)
            b.badge:SetPoint("BOTTOMRIGHT", -2, 2)
        end
        -- An item dropped on a favorites square arrives as a drag-release or as a click.
        local function receive(self)
            if d.drop and CursorItem() then d.drop() end
            if GameTooltip:IsOwned(self) then self:GetScript("OnEnter")(self) end
        end
        b:SetScript("OnReceiveDrag", receive)
        b:SetScript("OnClick", function(self)
            if d.drop then return receive(self) end
            if TbStopping(d) then Abort("Cancelled."); ns.ClearAuto() else d.click(self) end
            tbMode = nil
            if GameTooltip:IsOwned(self) then self:GetScript("OnEnter")(self) end
        end)
        b:SetScript("OnMouseDown", function(self) if self:IsEnabled() == 1 then self.icon:SetAlpha(0.7) end end)
        b:SetScript("OnMouseUp", function(self) self.icon:SetAlpha(1) end)
        b:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            if TbStopping(d) then
                GameTooltip:SetText("Stop", 1, 1, 1)
                GameTooltip:AddLine("Cancels the arrangement in progress. Items already moved stay where they are. Same as /aom stop.", nil, nil, nil, true)
            else
                GameTooltip:SetText(d.title, 1, 1, 1)
                GameTooltip:AddLine(d.tip, nil, nil, nil, true)
                if d.extra then GameTooltip:AddLine(d.extra(), 1, 0.82, 0, true) end
            end
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        tbButtons[d.id] = b
    end
    TbSkin(f, tbButtons)
    toolbox = f
    return f
end

-- Show/hide and re-lay out only when something visible actually changed.
local function UpdateToolbox()
    local want = ArrangeOMaticDB and ArrangeOMaticDB.toolbox ~= false
        and (BagsOpen() or IsBankOpen() or IsGuildBankOpen())
    if not want then
        if toolbox and toolbox:IsShown() then toolbox:Hide(); CloseDropDownMenus() end
        return
    end
    local f = GetToolbox()
    if not f:IsShown() then
        f:ClearAllPoints()
        local pos = ArrangeOMaticDB.toolboxPos
        if pos then f:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", pos[1], pos[2])
        else f:SetPoint("BOTTOM", UIParent, "BOTTOM", 0, 220) end
        f:Show()
        tbMode = nil
    end
    -- Cheap change detection (this runs 5x a second): the running mode and a
    -- bitmask of the visible buttons - nothing is allocated.
    local job = GetJob()
    local mode, bits = job and job.mode or false, 0
    for i, d in ipairs(TB_DEFS) do
        if d.show == nil or d.show() then bits = bits + 2 ^ (i - 1) end
    end
    local vertical = ArrangeOMaticDB.toolboxVertical == true
    if vertical then bits = bits + 2 ^ #TB_DEFS end
    if mode == tbMode and bits == tbBits then return end
    tbMode, tbBits = mode, bits

    -- Visible buttons in one row or column.
    local shown = {}
    for _, d in ipairs(TB_DEFS) do
        if d.show == nil or d.show() then shown[#shown + 1] = d else tbButtons[d.id]:Hide() end
    end
    local total = #shown * (TB_SIZE + TB_GAP) - TB_GAP
    local x, y = TB_PAD, TB_PAD
    for _, d in ipairs(shown) do if d.gapBefore then total = total + TB_GRIP end end
    if vertical then
        f:SetWidth(TB_SIZE + TB_PAD * 2)
        f:SetHeight(total + TB_PAD * 2)
    else
        f:SetWidth(total + TB_PAD * 2)
        f:SetHeight(TB_SIZE + TB_PAD * 2)
    end
    for _, d in ipairs(shown) do
        local b = tbButtons[d.id]
        b:ClearAllPoints()
        if d.gapBefore then
            if vertical then y = y + TB_GRIP else x = x + TB_GRIP end
        end
        if vertical then
            b:SetPoint("TOPLEFT", f, "TOPLEFT", x, -y)
            y = y + TB_SIZE + TB_GAP
        else
            b:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", x, TB_PAD)
            x = x + TB_SIZE + TB_GAP
        end
        -- The running arrange button becomes Stop; the other arrange buttons grey out.
        local stopping = TbStopping(d)
        local dim = d.arrange and job ~= nil and not stopping
        local c = dim and 0.6 or 1
        b.icon:SetTexture(stopping and STOP_ICON or d.icon)
        b.icon:SetDesaturated(dim and true or false)
        b.icon:SetVertexColor(c, c, c)
        if b.badge then
            b.badge:SetDesaturated(dim and true or false)
            b.badge:SetVertexColor(c, c, c)
            if stopping then b.badge:Hide() else b.badge:Show() end
        end
        if d.arrange then
            if dim then b:Disable() else b:Enable() end
        end
        b:Show()
    end
end

local tbDriver, tbAcc = CreateFrame("Frame"), 0
tbDriver:SetScript("OnUpdate", function(_, elapsed)
    tbAcc = tbAcc + elapsed
    if tbAcc < 0.2 then return end
    tbAcc = 0
    UpdateToolbox()
end)

-- Settings dropdown (the gear). Level 1 lists the settings; arrows open the
-- choices of level 2.
local DELAYS  = { 2, 5, 10, 15, 30, 60 }
local COLUMNS = { 6, 8, 10, 12, 14, 16, 20, 24 }

local function MenuInit(self, level)
    local db = ArrangeOMaticDB
    local function add(info) UIDropDownMenu_AddButton(info, level) end
    local function check(text, key, default, tip)
        add({ text = text, isNotRadio = true, keepShownOnClick = true, checked = DBFlag(key, default),
              tooltipTitle = text, tooltipText = tip, tooltipOnButton = 1,
              func = function() FlipFlag(key, default) end })
    end
    local function sub(text, value, tip)
        add({ text = text, hasArrow = true, value = value, notCheckable = true,
              tooltipTitle = text, tooltipText = tip, tooltipOnButton = 1 })
    end
    local function pick(text, current, set, tip)
        add({ text = text, checked = current, func = set, tooltipTitle = tip and text,
              tooltipText = tip, tooltipOnButton = tip and 1 })
    end
    local function action(text, fn, tip)
        add({ text = text, notCheckable = true, func = fn,
              tooltipTitle = text, tooltipText = tip, tooltipOnButton = 1 })
    end

    if level == 1 then
        add({ text = "Arrange-o-Matic settings", isTitle = true, notCheckable = true })
        check("Pack stacks", "pack", true, "Before arranging, combine partial stacks of the same item.")
        check("Gather junk", "trash", true, "Bags only: put grey items in one run at the far end, opposite the Hearthstone.")
        check("Auto-arrange", "auto", false, "Arrange your bags by themselves once they change and you are idle.")
        sub("Auto delay: " .. (db.autoDelay or AUTO_DELAY) .. "s", "delay", "How long you must be idle before auto-arrange starts.")
        sub("Bag layout: " .. GetUI(), "ui", "Default: each Blizzard bag window is its own grid. Single: all bags as one combined grid, for one-window bag addons.")
        sub("Columns: " .. GetColumns(), "columns", "Width of the combined grid. Only used with the single layout.")
        sub("Group by: " .. (db.subtypes and "subtype" or "type"), "groups", "How single items are grouped: broad type only, or type and subtype.")
        sub("Favorites (" .. FavCount() .. ")", "favs", "Favorites are kept together; everything else is gathered at the far end of your bags.")
        check("Vertical toolbox", "toolboxVertical", false, "Stack the toolbox buttons in a column instead of a row.")
        return
    end

    local v = UIDROPDOWNMENU_MENU_VALUE
    if v == "delay" then
        for _, n in ipairs(DELAYS) do
            pick(n .. " seconds", (db.autoDelay or AUTO_DELAY) == n, function() db.autoDelay = n end)
        end
    elseif v == "ui" then
        pick("Default: one window per bag", GetUI() == "default", function() db.ui = "default" end)
        pick("Single: one combined window", GetUI() == "single", function() db.ui = "single" end)
    elseif v == "columns" then
        for _, n in ipairs(COLUMNS) do
            pick(n .. " columns", GetColumns() == n, function() db.columns = n end)
        end
    elseif v == "groups" then
        pick("Broad type", not db.subtypes, function() db.subtypes = false end)
        pick("Type and subtype", db.subtypes and true or false, function() db.subtypes = true end)
    elseif v == "favs" then
        action("Make everything in my bags a favorite", function() FavCommand("snapshot") end,
               "Replaces your favorites with the different non-grey items in your bags right now.")
        action("List favorites in chat", function() FavCommand("list") end)
        action("Clear all favorites", function() FavCommand("clear") end)
    end
end

OpenMenu = function(anchor)
    if not tbMenu then
        tbMenu = CreateFrame("Frame", "ArrangeOMaticMenu", UIParent, "UIDropDownMenuTemplate")
        DropDownList1:HookScript("OnHide", function() tbMenuClosed = GetTime() end)
    end
    -- A click on the gear while the menu is open closes it. (The click itself
    -- already closes the list before we get here, so also catch that.)
    if DropDownList1:IsShown() and UIDROPDOWNMENU_OPEN_MENU == tbMenu then
        return CloseDropDownMenus()
    end
    if tbMenuClosed and GetTime() - tbMenuClosed < 0.25 then return end
    UIDropDownMenu_Initialize(tbMenu, MenuInit, "MENU")
    ToggleDropDownMenu(1, nil, tbMenu, anchor, 0, 0)
end

function ns.HideToolbox() if toolbox then toolbox:Hide() end end
