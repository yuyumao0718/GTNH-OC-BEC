local make = assert(loadfile(ROOT .. 'tests/simplified.lua'))('fixture')
local U = dofile(ROOT .. 'ma_util.lua')

for _, arrays in ipairs({ 1, 6, 10, 30 }) do
    local count = arrays * 16 + 5
    local w = make(arrays, count, { nodes = 16 })
    w.cfg.fieldLimit = 1e9
    w.stock.entangled_neutronium = 1e8
    w.boot()
    local checks = {}
    for address, node in pairs(w.nodes) do
        local p = w.components[address]
        local original = p.getParallelRecipesInProgress
        p.getParallelRecipesInProgress = function()
            checks[node.array] = (checks[node.array] or 0) + 1
            return original()
        end
    end
    w.finish(10000)
    assert(w.produced == count and w.admitted == count)
    for _, a in ipairs(w.cfg.arrays) do
        assert(
            (checks[a.address] or 0) == (a.address == w.cfg.arrays[1].address and 1 or 0),
            'one sample for the newly learned recipe'
        )
    end
    for _, n in pairs(w.nodes) do
        assert(n.count == 1 or n.count == 2, "keep each node's own allocation")
    end
end
print(
    '  PASS 1/6/10/30 arrays learn from one shared recipe sample and preserve unequal allocations'
)

do
    local w = make(1, 32, { nodes = 16 })
    local p = w.components[w.cfg.arrays[1].nodes[2].address]
    local original = p.setMaxParallel
    p.setMaxParallel = function()
        return original(1)
    end
    for _ = 1, 100 do
        w.tick()
    end
    assert(not next(w.e.errors) and w.state.admission and w.closed)
    assert(w.produced == 0, 'leftover input must block startup')
end
print('  PASS a short intake outside the representative waits for the shared-network remainder')

do
    local w = make(1, 32, { nodes = 16 })
    local address = w.cfg.arrays[1].nodes[2].address
    local enable = w.components[address].setWorkAllowed
    w.components[address].setWorkAllowed = function(value)
        enable(value)
        if value then
            w.advance()
        end
    end
    w.e.io.pulse = function()
        return w.nodes[address].active
    end
    for _ = 1, 100 do
        w.tick()
        local b = w.state.arrays.a1.batch
        if b and b.phase == 'admit' and w.nodes[address].active then
            break
        end
    end
    assert(w.state.arrays.a1.batch.phase == 'admit' and w.nodes[address].active)
    local saved = U.copy(w.state)
    local p = w.components[address]
    local original = p.getParallelRecipesInProgress
    p.getParallelRecipesInProgress = function()
        return original() + 1
    end
    local ok = pcall(function()
        w.boot(saved)
        for _ = 1, 100 do
            w.tick()
        end
    end)
    assert(not ok or next(w.e.errors), 'resume must inspect non-representative active nodes')
    assert(w.produced == 0)
end
print('  PASS interrupted intake still verifies non-representative nodes during recovery')

for _, total in ipairs({ 48, 56 }) do
    local w = make(1, total, { nodes = 16 })
    w.deliveryBatch = total == 48 and 16 or 32
    local writes = 0
    for address in pairs(w.nodes) do
        local p = w.components[address]
        local original = p.setMaxParallel
        p.setMaxParallel = function(value)
            writes = writes + 1
            return original(value)
        end
    end
    w.finish(10000)
    assert(writes == (total == 48 and 16 or 24), 'write only changed maximum parallel')
    w.e:pause()
    w.boot(U.copy(w.saved))
    assert(not next(w.e.maxParallel), 'restart must forget previously written values')
end
print('  PASS unchanged parallel is reused, uneven later orders update only changed nodes')

do
    local w = make(1, 16, { nodes = 16 })
    local cells = {}
    for tier = 1, 10 do
        cells[tier] = { tier = tier, slot = tier, count = 32 }
    end
    w.share(cells)
    w.boot()
    local p = w.components['a1:transposer']
    local reads, original = {}, p.getStackInSlot
    p.getStackInSlot = function(side, slot)
        reads[slot] = (reads[slot] or 0) + 1
        return original(side, slot)
    end
    w.finish(10000)
    assert(not next(reads), 'known pool contents should not be reread at fastTier startup')
end
print('  PASS fastTier uses the initial pool scan and actual loaded counts')
