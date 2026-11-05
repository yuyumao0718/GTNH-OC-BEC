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
        local writes, states, moves = {}, {}, {}
        local saving = base.e.io.save
        base.e.io.save = function(state)
            saving(state)
            -- One checkpoint for each phase on the first, middle and last array.
            for _, i in ipairs({ 1, math.ceil(count / 2), count }) do
                local s = state.arrays['a' .. i]
                local b = s.bee
                local key = i
                    .. ':'
                    .. (s.batch and s.batch.phase or 'idle')
                    .. ':'
                    .. (b and tostring(b.loading) .. ':' .. b.phase or 'none')
                    .. ':'
                    .. tostring(state.moves['bee:a' .. i] and state.moves['bee:a' .. i].intent)
                    .. ':'
                    .. tostring(s.reuse)
                if not states[key] then
                    states[key] = true
                    writes[#writes + 1] = base.saves
                end
            end
        end
        local closed, filters = 0, 0
        for address in pairs(base.nodes) do
            local f = base.components[address].setWorkAllowed
            base.components[address].setWorkAllowed = function(v)
                if not v then
                    closed = closed + 1
                end
                return f(v)
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
        for _, point in ipairs(writes) do
            local w = fresh(count, fast)
            w.crashSave = point
            pcall(w.finish, 8000)
            assert(w.saves == point, 'selected checkpoint not reached')
            w.crashSave = nil
            w.boot(U.copy(w.saved))
            w.finish(8000)
            assert(w.produced == count * 32 and w.admitted == count * 32)
        end
        -- Replay every physical bee move, including moves before phase confirmation.
        for point = 1, base.moves do
            local w = fresh(count, fast)
            w.crashMove = point
            pcall(w.finish, 8000)
            assert(w.moves >= point, 'physical failure was not reached')
            w.crashMove = nil
            w.boot(U.copy(w.saved))
            w.finish(8000)
            assert(w.produced == count * 32 and w.admitted == count * 32)
        end
        local row = {
            arrays = count,
            fast = fast,
            saves = base.saves - initial,
            saveReplays = #writes,
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
                .. #writes
                .. ' save phases + '
                .. base.moves
                .. ' physical interruptions, no lost/duplicate production'
        )
    end
end
return rows
