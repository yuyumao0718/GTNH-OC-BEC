local make = assert(loadfile(ROOT .. 'tests/simplified.lua'))('fixture')
local U = dofile(ROOT .. 'ma_util.lua')
local rows = {}
local function fresh(count, fast)
    local w = make(count, count * 32, { nodes = 16, stageTicks = 5 })
    w.cfg.fieldLimit = 1e9
    w.stock.entangled_neutronium = 1e8
    local cells = {}
    for tier = 1, 2 do
        for i = 1, count do
            local n = #cells
            cells[#cells + 1] = {
                tier = tier,
                box = math.floor(n / 27) + 1,
                slot = n % 27 + 1,
                count = fast and 512 or 1,
            }
        end
    end
    w.share(cells)
    w.boot()
    local finish = w.finish
    function w.finish(max)
        finish(max)
        w.e:requestStop()
        for _ = 1, 1000 do
            w.tick()
            if w.e:drain() then
                return
            end
        end
        error('retained bees did not drain')
    end
    return w
end
for _, count in ipairs({ 6, 10, 30 }) do
    for _, fast in ipairs({ false, true }) do
        local base = fresh(count, fast)
        local initial = base.saves
        local closed, filters = 0, 0
        for address in pairs(base.nodes) do
            local n = base.components[address]
            local enable = n.setWorkAllowed
            n.setWorkAllowed = function(value)
                if not value then
                    closed = closed + 1
                end
                return enable(value)
            end
        end
        for _, a in ipairs(base.cfg.arrays) do
            local f = base.components[a.diode].setCondensateFilterAt
            base.components[a.diode].setCondensateFilterAt = function(...)
                filters = filters + 1
                return f(...)
            end
        end
        base.finish(8000)
        assert(closed == count * 16, 'redundant node closes in normal processing')
        assert(filters == count * 2, 'unchanged gate slots were written')
        local writes = base.saves - initial
        for point = initial + 1, base.saves do
            local w = fresh(count, fast)
            w.crashSave = point
            pcall(w.finish, 8000)
            assert(w.saves == point)
            w.crashSave = nil
            w.boot(U.copy(w.saved))
            w.finish(8000)
            assert(w.produced == count * 32 and w.admitted == count * 32)
        end
        local manual = 0
        -- Suspend immediately after transferItem changes the world, including
        -- inside pcall. Do not let other arrays execute after a hard crash.
        for point = 1, base.moves do
            local w = fresh(count, fast)
            local tripped = false
            for _, a in ipairs(w.cfg.arrays) do
                local t = w.components[a.address .. ':transposer']
                local move = t.transferItem
                t.transferItem = function(...)
                    local moved = move(...)
                    if moved == 1 and w.moves == point and not tripped then
                        tripped = true
                        coroutine.yield('power-cut')
                    end
                    return moved
                end
            end
            local co = coroutine.create(function()
                w.finish(8000)
            end)
            local ok, stop = coroutine.resume(co)
            assert(ok and stop == 'power-cut' and tripped, tostring(stop))
            local boot, reason = pcall(function()
                w.boot(U.copy(w.saved))
                for _ = 1, 30 do
                    if not w.e.ports then
                        return
                    end
                    w.advance()
                    w.e:resolvePorts()
                end
                error('ME-IO recovery did not finish')
            end)
            if not boot then
                assert(tostring(reason):find('无法辨认等级', 1, true), tostring(reason))
                manual = manual + 1
                -- The operator can inspect the cell's filter when several
                -- different grades are in ports at once and OC cannot identify them.
                for _ = 1, 3 do
                    w.advance()
                end
                for _, a in ipairs(w.cfg.arrays) do
                    for _, port in ipairs({ a.loadPort, a.unloadPort }) do
                        local cell = w.inventories[port].slots[7]
                        if cell then
                            local returned = false
                            for _, c in ipairs(w.cfg.beePools[1].cells) do
                                local box = w.e:beeAccess(a, c).inventory
                                if c.tier == cell.tier and not w.inventories[box].slots[c.slot] then
                                    assert(w.e.log:transfer(port, box, 7, c.slot))
                                    returned = true
                                    break
                                end
                            end
                            assert(returned, 'operator could not return a stranded cell')
                        end
                    end
                end
                w.boot(U.copy(w.saved))
            end
            w.finish(8000)
            assert(w.produced == count * 32 and w.admitted == count * 32)
            w.assertPool()
        end
        local row = {
            arrays = count,
            fast = fast,
            saves = base.saves - initial,
            saveReplays = writes,
            manualResets = manual,
            moveReplays = base.moves,
            normalNodeCloses = closed,
            filterWrites = filters,
        }
        rows[#rows + 1] = row
        print(
            '  PASS '
                .. count
                .. ' arrays '
                .. (fast and 'fastTier' or 'ordinary')
                .. ': '
                .. writes
                .. ' save phases + '
                .. base.moves
                .. ' physical interruptions; manual resets '
                .. manual
                .. ', no lost/duplicate production'
        )
    end
end
return rows
