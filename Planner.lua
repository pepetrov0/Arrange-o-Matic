local _, ns = ...

local BANK_CONTAINER = ns.BANK_CONTAINER
local SigFrom        = ns.SigFrom
local HEARTHSTONE_ID = 6948  -- always pinned to the first cell of the top row of the first window

-- Default Blizzard UI geometry (verified against the 3.3.5a FrameXML):
--   ContainerFrame.lua: NUM_CONTAINER_COLUMNS = 4; button i (1 = bottom-right)
--     gets slot ID size-i+1, so the last slot is bottom-right, slot 1 is the top
--     left of the short, right-aligned top row.
--   BankFrame.xml: BankFrameItem1 is top-left, 7 buttons per row, 28 slots.
local CONTAINER_COLUMNS = NUM_CONTAINER_COLUMNS or 4
local BANK_COLUMNS      = 7

-- Layout tuning
-- Penalty for empty cells inside a cluster's bounding box. The layout is tried
-- with the first value; if some cluster can't be kept as a solid block, the next
-- (stricter, less wasteful) value is tried, and so on.
local WASTE_WEIGHTS = { 1, 2, 4, 8, 16, 64 }
local EXTEND_WEIGHT = 0.5  -- penalty per extra grid row a placement adds
local EPS           = 1e-6

-- Geometry of the windows the slot list is drawn in. A layout is a list of
-- grids that partition slots 1..S:  { first, size, cols, flip, mirror }
--   flip = true : the last slot is the top-left cell (single-window addons)
--   flip = false: slot 1 is the top-left cell (default Blizzard UI)
--   mirror = true: also try block shapes with their short row on top (see
--                  ShapeOffsets); off by default so single-window results
--                  stay exactly as they always were
local function SingleWindowLayout(S, N)
    return { { first = 1, size = S, cols = N, flip = true } }
end

local function SeparateWindowsLayout(groups, fillFromEnd)
    -- fillFromEnd: hand clusters to the LAST bag first, so the free space ends up
    -- in the first bags (backpack, bag 1...) - those are the ones new loot lands in.
    -- (Used for bags and bank alike.)
    local layout = { fillFromEnd = fillFromEnd }
    for i, g in ipairs(groups) do
        layout[i] = {
            first = g.first, size = g.size, flip = false, mirror = true,
            main  = (g.bag == BANK_CONTAINER),
            cols  = (g.bag == BANK_CONTAINER) and BANK_COLUMNS or CONTAINER_COLUMNS,
        }
    end
    return layout
end
local function BuildClusters(items, S, skip)
    local byId = {}
    for v = 1, S do
        local it = items[v]
        if it and not skip[v] then
            local l = byId[it.id]
            if not l then l = {}; byId[it.id] = l end
            l[#l + 1] = v
        end
    end

    local clusters, byCat = {}, {}
    for id, list in pairs(byId) do
        if #list > 1 then
            clusters[#clusters + 1] = { key = "1:" .. id, members = list }
        else
            local cat = items[list[1]].cat
            byCat[cat] = byCat[cat] or {}
            table.insert(byCat[cat], list[1])
        end
    end
    for cat, list in pairs(byCat) do
        table.sort(list)
        clusters[#clusters + 1] = { key = "2:" .. cat, members = list }
    end
    for _, c in ipairs(clusters) do c.size = #c.members end

    table.sort(clusters, function(a, b)
        if a.size ~= b.size then return a.size > b.size end
        return a.key < b.key
    end)
    return clusters
end

-- Cells of a w x h block holding k items: full rows plus one short row, which is
-- the last row (bottom) unless shortOnTop is set. The top variant matters for
-- windows whose own short row is on top (Blizzard bags): a cluster that fills
-- such a window can only be a solid block if its short row is on top as well.
local function ShapeOffsets(w, h, rem, rightAligned, shortOnTop)
    local offs = {}
    local shortRow = shortOnTop and 0 or (h - 1)
    for dy = 0, h - 1 do
        local n  = (dy == shortRow) and rem or w
        local sx = (rightAligned or n == w) and 0 or (w - n)
        for dx = sx, sx + n - 1 do
            offs[#offs + 1] = dx
            offs[#offs + 1] = dy
        end
    end
    return offs
end

-- ShapeOffsets is asked for the same few shapes thousands of times per run
-- (every cluster, every waste weight, every trial layout), so keep the results.
-- The lists are read-only. variant: 1/2 = short row at the bottom, right/left
-- aligned; 3/4 = the same with the short row on top.
local shapeCache = {}
local function Shape(w, h, rem, variant)
    local key = ((variant * 256 + h) * 64 + w) * 64 + rem
    local offs = shapeCache[key]
    if not offs then
        offs = ShapeOffsets(w, h, rem, variant % 2 == 1, variant > 2)
        shapeCache[key] = offs
    end
    return offs
end

-- Grid coordinates ("padded index" P): the window is drawn with the short row
-- on top, so we pad the list at the front with `off` phantom cells to make the
-- grid rectangular. Reading the window left-to-right, top-to-bottom:
--   P = (S - v) + off,  row = floor(P / N) (0 = top),  col = P % N (0 = left)
-- Valid cells are lo <= P < hi where lo = off and hi = S + off. The last slot
-- (v = S) is P = off, the first cell of the top row, and packing starts there.
-- (That is the single-window numbering. The default Blizzard UI numbers a bag the
-- other way round, P = (v - 1) + off, so slot 1 is the first cell of the top row;
-- every window carries its own P <-> slot mapping, see BuildMoves.)
-- Grow a connected region of up to k free cells around `seed`, always adding the
-- frontier cell closest to the seed. Returns the cells (fewer than k if the
-- pocket of free cells is too small).
local function GrowRegion(owner, lo, hi, N, k, seed)
    local cells, inSet, frontier = { seed }, { [seed] = true }, {}
    local sx, sy = seed % N, math.floor(seed / N)

    local function offer(p)
        if p >= lo and p < hi and not owner[p] and not inSet[p] then
            inSet[p] = true
            frontier[#frontier + 1] = p
        end
    end
    local function expand(p)
        local gx = p % N
        if gx > 0 then offer(p - 1) end
        if gx < N - 1 then offer(p + 1) end
        offer(p - N)
        offer(p + N)
    end

    expand(seed)
    while #cells < k and #frontier > 0 do
        local bi, bc, bm, bp
        for i = 1, #frontier do
            local p = frontier[i]
            local dx, dy = math.abs(p % N - sx), math.abs(math.floor(p / N) - sy)
            local c, m = math.max(dx, dy), dx + dy
            if not bi or c < bc or (c == bc and (m < bm or (m == bm and p < bp))) then
                bi, bc, bm, bp = i, c, m, p
            end
        end
        local p = frontier[bi]
        frontier[bi] = frontier[#frontier]
        frontier[#frontier] = nil
        cells[#cells + 1] = p
        expand(p)
    end
    return cells
end

local function BoxArea(cells, N)
    local x1, x2, y1, y2 = math.huge, -1, math.huge, -1
    for _, p in ipairs(cells) do
        local gx, gy = p % N, math.floor(p / N)
        if gx < x1 then x1 = gx end
        if gx > x2 then x2 = gx end
        if gy < y1 then y1 = gy end
        if gy > y2 then y2 = gy end
    end
    return (x2 - x1 + 1) * (y2 - y1 + 1)
end

-- No solid block fits: take the most compact connected blob of free cells.
-- If no pocket is big enough, use the biggest pockets. Returns cells, pieces.
local function FillFree(owner, lo, hi, N, k)
    local cells, pieces = {}, 0
    while #cells < k do
        local need = k - #cells
        local bestRegion, bestArea
        for seed = lo, hi - 1 do
            if not owner[seed] then
                local region = GrowRegion(owner, lo, hi, N, need, seed)
                local area = BoxArea(region, N)
                if not bestRegion or #region > #bestRegion
                   or (#region == #bestRegion and area < bestArea) then
                    bestRegion, bestArea = region, area
                end
            end
        end
        for _, p in ipairs(bestRegion) do
            owner[p] = true
            cells[#cells + 1] = p
        end
        pieces = pieces + 1
    end
    return cells, pieces
end

local function LayoutOnce(clusters, lo, hi, N, reserved, WASTE_WEIGHT, mirror)
    local stats = { pure = 0, flood = 0 }
    local rows = hi / N
    -- reserved = { cells = {[P] = true}, rows = n }: cells taken before any
    -- cluster (Hearthstone, trash), and how many top rows count as already used.
    local owner = {}
    local usedRows = 0
    if reserved then
        for p in pairs(reserved.cells) do owner[p] = true end
        usedRows = reserved.rows
    end
    local cellsOf = {}

    for ci, c in ipairs(clusters) do
        local k = c.size
        local best

        for w = 1, math.min(N, k) do
            local h = math.ceil(k / w)
            if h <= rows then
                local waste  = w * h - k
                local aspect = math.max(w, h) / math.min(w, h)
                local cost   = aspect + WASTE_WEIGHT * waste / k
                local rem    = k - (h - 1) * w

                for variant = 1, (rem == w) and 1 or (mirror and 4 or 2) do
                    local offs = Shape(w, h, rem, variant)
                    for y0 = 0, rows - h do
                        local score = cost + EXTEND_WEIGHT * math.max(0, y0 + h - usedRows)
                        if not best or score <= best.score + EPS then
                            for x0 = 0, N - w do
                                local ok = true
                                for i = 1, #offs, 2 do
                                    local p = (y0 + offs[i + 1]) * N + (x0 + offs[i])
                                    if p < lo or p >= hi or owner[p] then ok = false; break end
                                end
                                if ok then
                                    local better = not best
                                    if best then
                                        if score < best.score - EPS then
                                            better = true
                                        elseif score <= best.score + EPS then
                                            better = (y0 < best.y0) or (y0 == best.y0 and x0 < best.x0)
                                        end
                                    end
                                    if better then
                                        best = { score = score, y0 = y0, x0 = x0, h = h, offs = offs }
                                    end
                                    break -- first fit on this row is the lowest x0
                                end
                            end
                        end
                    end
                end
            end
        end

        local cells = {}
        if best then
            for i = 1, #best.offs, 2 do
                cells[#cells + 1] = (best.y0 + best.offs[i + 1]) * N + (best.x0 + best.offs[i])
            end
        else
            local pieces
            cells, pieces = FillFree(owner, lo, hi, N, k)
            if pieces > 1 then stats.pure = stats.pure + 1 else stats.flood = stats.flood + 1 end
        end
        for _, p in ipairs(cells) do
            owner[p] = true
            usedRows = math.max(usedRows, math.floor(p / N) + 1)
        end
        cellsOf[ci] = cells
    end
    return cellsOf, stats
end

-- Try progressively stricter waste weights until every cluster is a solid block
-- (or keep the least bad attempt).
local function LayoutClusters(clusters, lo, hi, N, reserved, mirror)
    local bestCells, bestStats
    for _, weight in ipairs(WASTE_WEIGHTS) do
        local cells, st = LayoutOnce(clusters, lo, hi, N, reserved, weight, mirror)
        if not bestStats or st.pure < bestStats.pure
           or (st.pure == bestStats.pure and st.flood < bestStats.flood) then
            bestCells, bestStats = cells, st
        end
        if st.pure == 0 and st.flood == 0 then break end
    end
    return bestCells, bestStats
end

-- Largest part first inside a window (the same order BuildClusters uses).
local function PartOrder(a, b)
    if a.size ~= b.size then return a.size > b.size end
    return a.key < b.key
end

-- Lay a window out with one more part in it (or none) and report how badly it
-- goes: 1000 per cluster that had to be cut into pieces, 1 per cluster that was
-- merely not a solid block.
local function Trial(g, part)
    local list = {}
    for i, p in ipairs(g.parts) do list[i] = p end
    if part then list[#list + 1] = part end
    table.sort(list, PartOrder)
    local _, st = LayoutClusters(list, g.off, g.size + g.off, g.cols, g.reserved, g.mirror)
    return st.pure * 1000 + st.flood
end

-- Choose the window for a part that has to go in whole: the first window where
-- it still lays out as a solid block next to what is already there, otherwise
-- the window where it hurts least. Free slots alone are not enough - a window can
-- have room for 4 items and still have no 4-cell block left. Returns the window
-- index and that window's badness with the part in it, or nil if no window has
-- room.
local function ChooseWindow(grids, part)
    local pick, pickBad, pickWorse
    for gi, g in ipairs(grids) do
        if g.free >= part.size then
            local bad = Trial(g, part)
            local worse = bad - g.bad
            if worse <= 0 then return gi, bad end
            if not pickWorse or worse < pickWorse then pick, pickBad, pickWorse = gi, bad, worse end
        end
    end
    return pick, pickBad
end

-- Hand every cluster to a window. Clusters arrive largest first. A cluster that
-- fits whole in some window goes there (see ChooseWindow). One that fits in no
-- window is split: the roomiest windows are filled up first, until what is left
-- fits whole somewhere, and that last piece is placed like any other cluster.
-- Only sizes decide, never where the items currently are, so re-running on an
-- arranged set of bags changes nothing. Each grid ends up with a list of parts
-- { key, members, size }. When a cluster is split, members that already sit in
-- the window a part was given to are kept there (fewer moves).
local function DistributeClusters(clusters, grids, gridOf)
    for _, g in ipairs(grids) do g.bad = 0 end

    -- A cluster only counts as "fits whole" if it fits the largest bag, not
    -- counting the main bank (which is bigger than any bag). Anything larger is
    -- always broken up over several bags.
    local maxWhole = 0
    for _, g in ipairs(grids) do
        if not g.main and g.size > maxWhole then maxWhole = g.size end
    end
    if maxWhole == 0 then maxWhole = math.huge end

    for _, c in ipairs(clusters) do
        local whole = { key = c.key, members = c.members, size = c.size }
        local gi, bad
        if c.size <= maxWhole then gi, bad = ChooseWindow(grids, whole) end
        if gi then
            local g = grids[gi]
            g.parts[#g.parts + 1] = whole
            g.free, g.bad = g.free - c.size, bad
        else
            local left, quota = c.size, {}
            while left > 0 do
                local roomiest
                for i, g in ipairs(grids) do
                    -- byOrder: take windows strictly in fill order (the main bank,
                    -- being the biggest window, must not jump the queue).
                    if g.free > 0 and (not roomiest or (not grids.byOrder and g.free > grids[roomiest].free)) then
                        roomiest = i
                    end
                end
                if not roomiest then break end   -- cannot happen: items never outnumber slots
                local target, take = roomiest, grids[roomiest].free
                if take >= left then
                    take = left
                    target = ChooseWindow(grids, { key = c.key .. "#rest", size = left })
                end
                quota[target] = (quota[target] or 0) + take
                grids[target].free = grids[target].free - take
                left = left - take
            end

            local used = {}
            for i = 1, #grids do if quota[i] then used[#used + 1] = i end end
            local lists, rest = {}, {}
            for _, i in ipairs(used) do lists[i] = {} end
            for _, m in ipairs(c.members) do
                local i = gridOf[m]
                if lists[i] and #lists[i] < quota[i] then
                    lists[i][#lists[i] + 1] = m
                else
                    rest[#rest + 1] = m
                end
            end
            local r = 1
            for _, i in ipairs(used) do
                local l, g = lists[i], grids[i]
                while #l < quota[i] do l[#l + 1] = rest[r]; r = r + 1 end
                g.parts[#g.parts + 1] = { key = c.key .. "#" .. i, members = l, size = quota[i] }
            end
            for _, i in ipairs(used) do grids[i].bad = Trial(grids[i]) end
        end
    end

    for _, g in ipairs(grids) do table.sort(g.parts, PartOrder) end
end

-- Packing: combine partial stacks of the same item so that at most one partial
-- stack per item is left. Returns an ordered list of moves in the same format as
-- BuildMoves ({a, b, preA, preB, postA, postB}): stack `a` is dropped onto stack
-- `b`, which tops `b` up (and leaves the remainder, if any, in `a`).
-- `items` is updated in place to the state after all merges, so BuildMoves can
-- then arrange what is left.
local function BuildMerges(items, S)
    local byId = {}
    for v = 1, S do
        local it = items[v]
        if it and it.stack and it.stack > 1 and it.count and it.count < it.stack then
            local l = byId[it.id]
            if not l then l = {}; byId[it.id] = l end
            l[#l + 1] = { v = v, n = it.count }
        end
    end

    local ids = {}
    for id, l in pairs(byId) do
        if #l > 1 then ids[#ids + 1] = id end
    end
    table.sort(ids)

    local moves = {}
    for _, id in ipairs(ids) do
        local P = byId[id]
        table.sort(P, function(a, b)
            if a.n ~= b.n then return a.n > b.n end
            return a.v < b.v
        end)
        local stack = items[P[1].v].stack
        -- Fill the fullest stack from the emptiest one, then the next, and so on.
        local i, j = 1, #P
        while i < j do
            local dest, src = P[i], P[j]
            local dIt, sIt = items[dest.v], items[src.v]
            local amt = math.min(src.n, stack - dest.n)
            dest.n, src.n = dest.n + amt, src.n - amt

            local postA = (src.n > 0) and SigFrom(sIt.base, src.n) or ""
            local postB = SigFrom(dIt.base, dest.n)
            moves[#moves + 1] = {
                a = src.v, b = dest.v,
                preA = sIt.sig, preB = dIt.sig,
                postA = postA, postB = postB,
            }

            -- Update the item records in place: they are ours (Describe made them).
            dIt.count, dIt.sig = dest.n, postB
            if src.n > 0 then
                sIt.count, sIt.sig = src.n, postA
            else
                items[src.v] = nil
            end

            if dest.n >= stack then i = i + 1 end
            if src.n == 0 then j = j - 1 end
        end
    end
    return moves
end

-- Give `members` (slot indices) the slots in `targets`: members already on a
-- target stay put, the rest fill the remaining targets in order.
local function Assign(dest, members, targets)
    local isCell, movers = {}, {}
    for _, v in ipairs(targets) do isCell[v] = true end
    for _, m in ipairs(members) do
        if isCell[m] then dest[m] = m; isCell[m] = nil
        else movers[#movers + 1] = m end
    end
    local i = 1
    for _, v in ipairs(targets) do
        if isCell[v] then dest[movers[i]] = v; i = i + 1 end
    end
end

-- Returns an ordered list of swaps {a, b, preA, preB, postA, postB} (slot indices).
-- `layout` is a list of grids (see SingleWindowLayout / SeparateWindowsLayout),
-- or just a column count, meaning one combined window of that width.
-- sinkTrash: grey items go, as one run of consecutive cells, to the very end of
-- the fill order - the opposite end from the Hearthstone.
-- favs: optional set of favorite itemIDs. With sinkTrash, every other non-grey
-- item is unwanted and goes in a second run right before the greys, sorted by
-- category, then itemID.
local function BuildMoves(S, items, layout, pinHearthstone, sinkTrash, favs)
    if type(layout) == "number" then layout = SingleWindowLayout(S, layout) end

    -- Per-window geometry. P is the padded grid index described above GrowRegion,
    -- local to the window; toV turns a cell back into a slot index of the list.
    -- The order of `grids` is the order windows are filled in. With
    -- layout.fillFromEnd the list is reversed: the last bag is filled first.
    local grids, gridOf = {}, {}
    local nGrids = #layout
    grids.byOrder = layout.fillFromEnd
    for li, l in ipairs(layout) do
        local gi = layout.fillFromEnd and (nGrids - li + 1) or li
        local off = (l.cols - l.size % l.cols) % l.cols   -- phantom cells in the short top row
        local first, size = l.first, l.size
        grids[gi] = {
            cols = l.cols, size = size, off = off, parts = {}, mirror = l.mirror, main = l.main,
            free = size,                                  -- capacity left for clusters
            reserved = { cells = {}, rows = 0 },
            toV  = l.flip and function(P) return first + size + off - 1 - P end
                          or  function(P) return first + P - off end,
        }
        for v = first, first + size - 1 do gridOf[v] = gi end
    end

    -- The hearthstone owns the first cell of the top row of the first window
    -- (single mode: slot S, bottom-right numbering; default mode: slot 1 of the last bag).
    local hsV, pinV
    if pinHearthstone then
        for v = 1, S do
            if items[v] and items[v].id == HEARTHSTONE_ID then hsV = v; break end
        end
        if hsV then
            local pg = grids[1]   -- the window filled first (the last bag when fillFromEnd)
            pinV = pg.toV(pg.off)
            pg.free = pg.free - 1
            pg.reserved.cells[pg.off] = true
            pg.reserved.rows = 1
        end
    end

    -- Trash takes the last cells in fill order: the last cell of the last window
    -- filled, then backwards from there (spilling into the previous window if it
    -- has to), so it is one unbroken run of slots.
    -- Unwanted items (not favorites) take the cells right before the trash.
    local skip, trash, trashCells, unwanted, unwantedCells = {}, {}, {}, {}, {}
    if hsV then skip[hsV] = true end
    if sinkTrash then
        for v = 1, S do
            local it = items[v]
            if it and not skip[v] then
                if it.trash then
                    trash[#trash + 1] = v
                    skip[v] = true
                elseif favs and not favs[it.id] then
                    unwanted[#unwanted + 1] = v
                    skip[v] = true
                end
            end
        end
        -- far end first: the greys, then the unwanted items
        local nTrash, n, need = #trash, 0, #trash + #unwanted
        for gi = #grids, 1, -1 do
            local g = grids[gi]
            for P = g.size + g.off - 1, g.off, -1 do
                if n == need then break end
                if not g.reserved.cells[P] then
                    g.reserved.cells[P] = true
                    g.free = g.free - 1
                    n = n + 1
                    if n <= nTrash then
                        trashCells[n] = g.toV(P)
                    else
                        unwantedCells[n - nTrash] = g.toV(P)
                    end
                end
            end
        end
    end

    local clusters = BuildClusters(items, S, skip)
    DistributeClusters(clusters, grids, gridOf)

    local stats = { pure = 0, flood = 0 }
    for gi, g in ipairs(grids) do
        local cellsOf, st = LayoutClusters(g.parts, g.off, g.size + g.off, g.cols, g.reserved, g.mirror)
        stats.pure, stats.flood = stats.pure + st.pure, stats.flood + st.flood
        for pi, part in ipairs(g.parts) do part.cells, part.toV = cellsOf[pi], g.toV end
    end

    -- Tokens are the original slot indices of the items.
    local dest, want, itemAt, loc, idOf, sig = {}, {}, {}, {}, {}, {}
    for v = 1, S do
        sig[v] = items[v] and items[v].sig or ""
        if items[v] then
            itemAt[v], loc[v], idOf[v] = v, v, items[v].id
        end
    end

    -- Assign items to cells; anything already inside its cluster's area stays.
    for _, g in ipairs(grids) do
        for _, part in ipairs(g.parts) do
            local targets = {}
            for i, P in ipairs(part.cells) do targets[i] = part.toV(P) end
            Assign(dest, part.members, targets)
        end
    end
    Assign(dest, trash, trashCells)
    -- Unwanted items are sorted by category, then itemID, in fill order
    -- (unwantedCells runs backwards from the greys). Same-ID stacks trade
    -- destinations below, so ties cost no moves.
    local nU = #unwanted
    if nU > 0 then
        table.sort(unwanted, function(a, b)
            local x, y = items[a], items[b]
            if x.cat ~= y.cat then return x.cat < y.cat end
            if x.id ~= y.id then return x.id < y.id end
            return a < b
        end)
        for k = 1, nU do dest[unwanted[k]] = unwantedCells[nU - k + 1] end
    end
    if hsV then dest[hsV] = pinV end
    for tok, d in pairs(dest) do want[d] = tok end

    -- Turn the permutation into swaps. A slot, once correct, is never touched
    -- again. Two stacks of the same itemID are never swapped (the game would
    -- merge them) - they trade destinations instead.
    local moves = {}
    for v = 1, S do
        local tok = want[v]
        if tok and itemAt[v] ~= tok then
            local occ = itemAt[v]
            if occ and idOf[occ] == idOf[tok] then
                local dOcc = dest[occ]
                dest[occ], dest[tok] = v, dOcc
                want[v], want[dOcc] = occ, tok
            else
                local l = loc[tok]
                moves[#moves + 1] = {
                    a = l, b = v,
                    preA = sig[l], preB = sig[v],
                    postA = sig[v], postB = sig[l],
                }
                sig[l], sig[v] = sig[v], sig[l]
                itemAt[l], itemAt[v] = occ, tok
                loc[tok] = v
                if occ then loc[occ] = l end
            end
        end
    end
    return moves, #clusters, stats
end

ns.BuildMoves, ns.BuildMerges = BuildMoves, BuildMerges
ns.SingleWindowLayout, ns.SeparateWindowsLayout = SingleWindowLayout, SeparateWindowsLayout
ns.WASTE_WEIGHTS = WASTE_WEIGHTS
