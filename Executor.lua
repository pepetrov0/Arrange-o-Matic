local _, ns = ...

local Print, GetUI, GetColumns = ns.Print, ns.GetUI, ns.GetColumns
local SigAt, IsLocked = ns.SigAt, ns.IsLocked
local BagAPI, GuildAPI = ns.BagAPI, ns.GuildAPI
local ScanBags, ScanGuildTab = ns.ScanBags, ns.ScanGuildTab
local InventoryBagIds, BankBagIds = ns.InventoryBagIds, ns.BankBagIds
local IsBankOpen, IsGuildBankOpen = ns.IsBankOpen, ns.IsGuildBankOpen
local BuildMoves, BuildMerges = ns.BuildMoves, ns.BuildMerges
local SingleWindowLayout, SeparateWindowsLayout = ns.SingleWindowLayout, ns.SeparateWindowsLayout
local PlayerBusy = ns.PlayerBusy
local GBANK_COLUMN_H = ns.GBANK_COLUMN_H
local SOUL_SHARD_ID  = 6265

-- Execution tuning
local TICK    = 0.05       -- seconds between steps
local TIMEOUT = 8          -- seconds to wait for the server before giving up

local frame = CreateFrame("Frame")   -- drives the running job's OnUpdate
local job

-- Progress dialog: a click-through box centered at 2/3 screen height with a
-- title and a progress bar while sorting; when the run ends it shows the final
-- report for a few seconds, then fades out. Skinned to match ElvUI if loaded.
local DIALOG_WIDTH = 300
local DIALOG_HOLD  = 2.5   -- seconds the final report stays up
local DIALOG_FADE  = 0.5
local dialog

local function SkinDialog(d)
    local E = ElvUI and unpack(ElvUI)
    if E and d.SetTemplate and E.media and E.media.normTex then
        d:SetTemplate("Transparent")
        d.bar:CreateBackdrop("Transparent")
        d.bar:SetStatusBarTexture(E.media.normTex)
        if E.RegisterStatusBar then E:RegisterStatusBar(d.bar) end
        for _, fs in ipairs({ d.title, d.barText, d.report }) do
            if fs.FontTemplate then fs:FontTemplate() end
        end
        return
    end
    d:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    d:SetBackdropColor(0, 0, 0, 0.85)
    d:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
    d.bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    local bg = d.bar:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetTexture(0, 0, 0, 0.5)
end

local function GetDialog()
    if dialog then return dialog end
    local d = CreateFrame("Frame", "ArrangeOMaticProgress", UIParent)
    d:SetWidth(DIALOG_WIDTH)
    d:SetFrameStrata("HIGH")
    d:EnableMouse(false)   -- click-through
    d:Hide()

    d.title = d:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    d.title:SetPoint("TOP", 0, -10)

    d.bar = CreateFrame("StatusBar", nil, d)
    d.bar:SetPoint("TOPLEFT", 12, -30)
    d.bar:SetPoint("TOPRIGHT", -12, -30)
    d.bar:SetHeight(14)
    d.bar:EnableMouse(false)
    d.barText = d.bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    d.barText:SetPoint("CENTER")

    d.report = d:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    d.report:SetPoint("TOP", 0, -30)
    d.report:SetJustifyH("CENTER")

    SkinDialog(d)
    d.bar:SetStatusBarColor(0.2, 1, 0.6)

    d:SetScript("OnUpdate", function(self, elapsed)
        if not self.hold then return end
        self.hold = self.hold - elapsed
        if self.hold > 0 then return end
        if self.hold <= -DIALOG_FADE then
            self.hold = nil
            self:SetAlpha(1)
            return self:Hide()
        end
        self:SetAlpha(1 + self.hold / DIALOG_FADE)
    end)
    dialog = d
    return d
end

local function DialogStart(total)
    local d = GetDialog()
    d.hold = nil
    d:SetAlpha(1)
    d.title:SetText("Arrange-o-Matic: Sorting")
    d.report:Hide()
    d.bar:SetMinMaxValues(0, total)
    d.bar:Show()
    -- Centered horizontally, at 2/3 of the screen height from the bottom
    -- (re-anchored each run in case the UI scale changed).
    d:ClearAllPoints()
    d:SetPoint("CENTER", UIParent, "BOTTOM", 0, UIParent:GetHeight() * 2 / 3)
    d:SetWidth(DIALOG_WIDTH)
    d:SetHeight(54)
    d:Show()
end

local function DialogProgress(done, total)
    if not dialog then return end
    dialog.bar:SetValue(done)
    dialog.barText:SetText(done .. " / " .. total)
end

local function DialogReport(title, msg)
    local d = GetDialog()
    d.title:SetText("Arrange-o-Matic: " .. title)
    d.bar:Hide()
    d.report:SetText(msg)
    d.report:Show()
    -- One line per fact; grow the box rather than let a long line wrap.
    d:SetWidth(math.max(DIALOG_WIDTH, d.report:GetStringWidth() + 24))
    d:SetHeight(42 + d.report:GetStringHeight())
    d:SetAlpha(1)
    d:Show()
    d.hold = DIALOG_HOLD
end

local function Finish(title, msg)
    frame:SetScript("OnUpdate", nil)
    job = nil
    if title then DialogReport(title, msg) end
end

local function Abort(reason)
    if CursorHasItem() then ClearCursor() end   -- never wipe a spell/macro the player picked up
    if job and job.auto then ns.Retry() end   -- try again once idle
    local done = job and math.max(job.idx - 1, 0)
    local progress = job and done > 0 and string.format("\n%d of %d moves were done.", done, #job.moves) or ""
    Print("Sorting stopped. " .. reason)   -- also keep it in chat
    Finish("|cffff5555Sorting stopped|r", reason .. progress)
end

-- Why the run can't go on right now (nil = fine).
local function Guard()
    if UnitIsDeadOrGhost("player") then return "You died." end
    if job.check then return job.check() end
end

local function Step(self, elapsed)
    job.acc = job.acc + elapsed
    if job.acc < TICK then return end
    local dt = job.acc
    job.acc = 0

    local api = job.api
    local problem = Guard()
    if problem then return Abort(problem) end

    local m = job.moves[job.idx]
    if not m then return Finish(job.title, job.report) end
    local A, B = job.slots[m.a], job.slots[m.b]

    if job.phase == "issue" then
        -- The player grabbed a spell/macro/item: picking up a bag item would
        -- replace it, so stop and leave the cursor alone (Abort only clears items).
        if GetCursorInfo() then return Abort("You picked something up with the mouse.") end
        if IsLocked(api, A) or IsLocked(api, B) then
            job.waited = job.waited + dt
            if job.waited > TIMEOUT then return Abort("An item stayed locked for too long. The server may be lagging.") end
            return
        end
        if SigAt(api, A) ~= m.preA or SigAt(api, B) ~= m.preB then
            return Abort("Your items changed while sorting (something was looted, used or moved). Run it again.")
        end
        api.pickup(A)
        api.pickup(B)
        job.phase, job.waited, job.dropped = "settle", 0, false
    else
        job.waited = job.waited + dt
        if job.waited > TIMEOUT then
            return Abort("The server did not confirm a move (lag or missing permission). Run it again.")
        end

        if CursorHasItem() then
            -- Safety net: if the displaced item ended up on the cursor, put it back.
            if not job.dropped then
                api.pickup(A)
                job.dropped = true
            end
            return
        end
        if IsLocked(api, A) or IsLocked(api, B) then return end
        -- The client can lag behind the server (the guild bank especially), so a
        -- mismatch here just means "not updated yet": keep polling until TIMEOUT.
        if SigAt(api, A) ~= m.postA or SigAt(api, B) ~= m.postB then return end
        job.idx, job.phase, job.waited = job.idx + 1, "issue", 0
        DialogProgress(job.idx - 1, #job.moves)
    end
end

-- Bags and bank: no per-step throttle, and moves that touch disjoint slots are
-- issued together (several in flight at once). A move only starts when neither
-- of its slots is part of an unfinished earlier move, so the result is the same
-- as running them one by one. The swap's third click (dropping the displaced
-- item back) is done in the same frame.
local MAX_FLIGHT, LOOKAHEAD = 10, 24

local function StepFast(self, elapsed)
    local problem = Guard()
    if problem then return Abort(problem) end
    if GetCursorInfo() then return Abort("You picked something up with the mouse.") end

    local api, slots, moves = job.api, job.slots, job.moves
    local now = GetTime()

    -- Retire finished moves.
    local flight, busy, i = job.flight, job.busy, 1
    while i <= #flight do
        local f = flight[i]
        local m = moves[f.n]
        local A, B = slots[m.a], slots[m.b]
        if not IsLocked(api, A) and not IsLocked(api, B)
           and SigAt(api, A) == m.postA and SigAt(api, B) == m.postB then
            busy[m.a], busy[m.b] = nil, nil
            table.remove(flight, i)
            job.done = job.done + 1
            job.idx = job.done + 1
            DialogProgress(job.done, #moves)
        else
            if now - f.t > TIMEOUT then
                return Abort("The server did not confirm a move (lag or missing permission). Run it again.")
            end
            i = i + 1
        end
    end

    if job.done >= #moves then return Finish(job.title, job.report) end

    -- Issue every move that is independent of what is still in flight.
    local pending, held, seen = job.pending, job.held, 0
    for key in pairs(held) do held[key] = nil end   -- reused every frame, not reallocated
    local k = 1
    while k <= #pending and #flight < MAX_FLIGHT and seen < LOOKAHEAD do
        local n = pending[k]
        local m = moves[n]
        seen = seen + 1
        if busy[m.a] or busy[m.b] or held[m.a] or held[m.b] then
            held[m.a], held[m.b] = true, true
            k = k + 1
        else
            local A, B = slots[m.a], slots[m.b]
            if IsLocked(api, A) or IsLocked(api, B) then
                held[m.a], held[m.b] = true, true
                k = k + 1
            else
                if SigAt(api, A) ~= m.preA or SigAt(api, B) ~= m.preB then
                    return Abort("Your items changed while sorting (something was looted, used or moved). Run it again.")
                end
                api.pickup(A)
                api.pickup(B)
                if CursorHasItem() then api.pickup(A) end   -- put the displaced item back
                busy[m.a], busy[m.b] = true, true
                flight[#flight + 1] = { n = n, t = now }
                table.remove(pending, k)
            end
        end
    end
end

-- mode: "bags" (default), "bank" or "gbank"
-- auto: started by auto mode - stop if the player gets busy, and say nothing
-- if there is nothing to do (the bags change all the time).
local function Start(mode, auto)
    if job then return Print("Already running (/aom stop to cancel).") end
    if UnitIsDeadOrGhost("player") then return Print("You can't move items while dead.") end
    if GetCursorInfo() then return Print("Empty your cursor first.") end

    local api, slots, items, groups, soulFree, layout, pin, check, label, shape
    local separate = (GetUI() == "default")
    if mode == "bank" then
        if not IsBankOpen() then return Print("Open your bank first.") end
        api, label = BagAPI, "bank"
        slots, items, groups, soulFree = ScanBags(BankBagIds())
        check = function() if not IsBankOpen() then return "You closed the bank." end end
    elseif mode == "gbank" then
        if not IsGuildBankOpen() then return Print("Open your guild bank first.") end
        local tab = GetCurrentGuildBankTab()
        if not tab or tab < 1 then return Print("Select a guild bank tab first.") end
        local name, _, isViewable, canDeposit = GetGuildBankTabInfo(tab)
        if not isViewable then return Print("You can't view this tab.") end
        if not canDeposit then Print("Warning: you may lack deposit rights on this tab; moves can fail.") end
        api, label = GuildAPI, "guild bank tab " .. tab .. (name and (" (" .. name .. ")") or "")
        slots, items = ScanGuildTab(tab)
        separate = false   -- the guild bank is one Blizzard window either way
        layout = SingleWindowLayout(#slots, GBANK_COLUMN_H)
        shape = GBANK_COLUMN_H .. " columns"
        check = function()
            if not IsGuildBankOpen() then return "You closed the guild bank." end
            if GetCurrentGuildBankTab() ~= tab then return "You switched guild bank tab." end
        end
    else
        api, label, pin = BagAPI, "bags", true
        slots, items, groups, soulFree = ScanBags(InventoryBagIds())
    end

    local S = #slots
    if S == 0 then return Print("No usable slots found.") end
    if next(items) == nil then return Print("Nothing to arrange.") end
    if auto then
        -- Item info not cached yet (e.g. right after login): grouping would be
        -- wrong, so wait for the next idle check instead.
        for v = 1, S do
            if items[v] and not items[v].stack then ns.Retry(); return end
        end
        check = function() return PlayerBusy(true) end
    end

    if not layout then   -- bags and bank
        if separate then
            layout = SeparateWindowsLayout(groups, true)
            shape = #layout .. " bag windows"
        else
            local N = math.min(GetColumns(), math.max(S, 1))
            layout = SingleWindowLayout(S, N)
            shape = N .. " columns"
        end
    end

    -- Soul Shards go into free soul bag slots first. Those slots are appended
    -- after slot S so the executor can address them; planning only sees 1..S.
    local soulMoves = {}
    for v = 1, S do
        if not soulFree or #soulFree == 0 then break end
        local it = items[v]
        if it and it.id == SOUL_SHARD_ID then
            slots[#slots + 1] = table.remove(soulFree, 1)
            soulMoves[#soulMoves + 1] = { a = v, b = #slots,
                preA = it.sig, preB = "", postA = "", postB = it.sig }
            items[v] = nil
        end
    end

    -- Pack first (combine partial stacks), then arrange what is left.
    local merges = {}
    if ArrangeOMaticDB.pack ~= false then
        merges = BuildMerges(items, S)
    end

    local sinkTrash = pin and ArrangeOMaticDB.trash ~= false
    local favs = ArrangeOMaticCharDB.favs
    if not next(favs) then favs = nil end
    local moves, nClusters, stats = BuildMoves(S, items, layout, pin, sinkTrash, favs)
    local nMerges, nSoul = #merges, #soulMoves
    for i = 1, #merges do soulMoves[#soulMoves + 1] = merges[i] end
    for i = 1, #moves do soulMoves[#soulMoves + 1] = moves[i] end
    moves = soulMoves
    if auto and #moves == 0 then return end
    local split = stats.pure + stats.flood
    local note = split > 0
        and string.format("\n|cffffd100%d groups could not stay in one block:\nnot enough free room.|r", split) or ""
    if #moves == 0 then return Print(label .. " already arranged." .. note:gsub("\n", " ")) end

    local title = (mode == "gbank" and ("Guild bank tab " .. GetCurrentGuildBankTab())
                   or mode == "bank" and "Bank" or "Bags") .. " sorted"
    local report = string.format("Done in %d moves.", #moves)
    if nMerges > 0 then report = report .. string.format("\n%d partial stacks combined.", nMerges) end
    if nSoul > 0 then report = report .. string.format("\n%d soul shards moved to soul bags.", nSoul) end
    report = report .. note
    job = { mode = mode, api = api, slots = slots, moves = moves, check = check, auto = auto, title = title, report = report,
            idx = 1, phase = "issue", acc = 0, waited = 0 }
    if mode ~= "gbank" then
        job.done, job.flight, job.busy, job.pending, job.held = 0, {}, {}, {}, {}
        for n = 1, #moves do job.pending[n] = n end
    end
    DialogStart(#moves)
    DialogProgress(0, #moves)
    frame:SetScript("OnUpdate", mode == "gbank" and Step or StepFast)
end

function ns.GetJob() return job end
ns.Start, ns.Abort = Start, Abort
