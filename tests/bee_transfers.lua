local make = assert(loadfile(ROOT .. 'tests/simplified.lua'))('fixture')
local U = dofile(ROOT .. 'ma_util.lua')

for _, count in ipairs({ 6, 10, 30 }) do
    local w = make(count, 0, { nodes = 16 })
    w.share({ { tier = 1, slot = 1, count = 32 } })
    w.boot()
    for _, a in ipairs(w.cfg.arrays) do
        w.components[a.address .. ':transposer'].getStackInSlot = function()
            error('normal bee transfer must use its return count, not read inventory slots')
        end
    end
    local first, second = w.cfg.arrays[1], w.cfg.arrays[2]
    local s1, s2 = w.state.arrays[first.address], w.state.arrays[second.address]
    assert(not w.e:bees(first, s1, 1))
    for _ = 1, 10 do
        assert(not w.e:bees(second, s2, 1) and not s2.lease)
    end
    local function finish(a, s, tier)
        for _ = 1, 50 do
            w.advance()
            if w.e:bees(a, s, tier) then
                return
            end
        end
        error('bee transfer did not finish')
    end
    finish(first, s1, 1)
    assert(s1.lease and not s2.lease, 'an empty returned cell is still borrowed')
    finish(first, s1, nil)
    finish(second, s2, 1)
    finish(second, s2, nil)
    assert(w.moves == 8)
    w.assertPool()
    print('  PASS ' .. count .. ' arrays: bee transfers and shared-pool waiting need no slot reads')
end

do
    local w = make(1, 0)
    local a = w.cfg.arrays[1]
    local gate = w.components[a.diode]
    local filters = { 'old_filter', 'leftover' }
    local reads, writes = 0, 0
    gate.getCondensateFilters = function()
        reads = reads + 1
        return U.copy(filters)
    end
    gate.getCondensateFilterAt = function()
        error('filter changes must not read individual slots')
    end
    gate.setCondensateFilterAt = function(slot, value)
        filters[slot] = value
        writes = writes + 1
    end
    w.e:filters(a, { entangled_neutronium = 144 })
    assert(reads == 1 and writes == 2 and filters[1] == 'entangled_neutronium' and not filters[2])
    w.e:filters(a, { entangled_neutronium = 144 })
    assert(reads == 1 and writes == 2)
    w.e:filters(a, {})
    assert(reads == 1 and writes == 3 and filters[1] == 'water')
    w.boot(U.copy(w.saved))
    w.e:filters(a, { entangled_neutronium = 144 })
    assert(reads == 2 and writes == 4, 'restart must establish the actual filter contents again')
end
print('  PASS filters are read once per run and only changed slots are written')
