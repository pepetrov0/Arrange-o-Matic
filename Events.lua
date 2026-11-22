local _, ns = ...

local MarkDirty, GetJob = ns.MarkDirty, ns.GetJob

-- Exposed for debugging/testing.
ArrangeOMatic = { BuildMoves = ns.BuildMoves, BuildMerges = ns.BuildMerges, weights = ns.WASTE_WEIGHTS }

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("BANKFRAME_OPENED")
frame:RegisterEvent("BANKFRAME_CLOSED")
frame:RegisterEvent("GUILDBANKFRAME_OPENED")
frame:RegisterEvent("GUILDBANKFRAME_CLOSED")
frame:RegisterEvent("BAG_UPDATE")
frame:RegisterEvent("LOOT_OPENED")
frame:RegisterEvent("LOOT_CLOSED")
frame:SetScript("OnEvent", function(self, event, arg)
    if event == "BAG_UPDATE" then
        -- Only the inventory bags, and not the moves of a running arrangement.
        if not GetJob() and arg and arg >= 0 and arg <= NUM_BAG_SLOTS then MarkDirty() end
    elseif event == "ADDON_LOADED" then
        if arg == "ArrangeOMatic" then
            ns.InitDB()
            ns.Print("v" .. ns.VERSION .. " loaded.")
            self:UnregisterEvent("ADDON_LOADED")
        end
    elseif event == "LOOT_OPENED" then ns.lootOpen = true
    elseif event == "LOOT_CLOSED" then ns.lootOpen = false
    elseif event == "BANKFRAME_OPENED" then ns.bankOpen = true
    elseif event == "BANKFRAME_CLOSED" then ns.bankOpen = false
    elseif event == "GUILDBANKFRAME_OPENED" then ns.gbankOpen = true
    elseif event == "GUILDBANKFRAME_CLOSED" then ns.gbankOpen = false
    end
end)
