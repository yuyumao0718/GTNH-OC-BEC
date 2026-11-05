local make = assert(loadfile(ROOT .. 'tests/simplified.lua'))('fixture')
local U = dofile(ROOT .. 'ma_util.lua')

for _, arrays in ipairs({ 1, 6, 10, 30 }) do
    local w = make(arrays, arrays * 16 + 5, { nodes = 16 })
    w.cfg.fieldLimit = 1e9
    w.stock.entangled_neutronium = 1e8
    local reads, samples, opened = 0, 0, {}
    local snapshot = w.components.receiver.getItemsInNetwork
    w.components.receiver.getItemsInNetwork = function()
        if w.state.admission then
            reads = reads + 1
        end
        return snapshot()
    end
    for address, node in pairs(w.nodes) do
        local p = w.components[address]
        local has, count, enable = p.hasWork, p.getParallelRecipesInProgress, p.setWorkAllowed
        p.hasWork = function()
            local b = w.state.arrays[node.array].batch
            assert(
                not b or b.phase ~= 'admit',
                'fresh intake must use AE rather than per-node probes'
            )
            return has()
        end
        p.getParallelRecipesInProgress = function()
            samples = samples + 1
            return count()
        end
        p.setWorkAllowed = function(value)
            if value then
                opened[node.array] = (opened[node.array] or 0) + 1
            end
            return enable(value)
        end
    end
    w.e.io.pulse = function()
        for _, n in pairs(opened) do
            assert(n == 16, 'opening a whole array must not interleave event processing')
        end
        return false
    end
    w.finish(10000)
    assert(reads > 0 and samples == 1, 'one sample learns the shared recipe')
    assert(w.admitted == arrays * 16 + 5 and w.produced == w.admitted)
end
print(
    '  PASS fresh intake uses shared AE completion and uninterrupted array enables at 1/6/10/30 arrays'
)

do
    local w = make(1, 1600, { nodes = 16, stageTicks = 400 })
    w.cfg.fieldLimit = 1e9
    w.stock.entangled_neutronium = 1e8
    for _ = 1, 1000 do
        w.tick()
        local s = w.state.arrays.a1
        if s.batch and s.batch.phase == 'run' and not s.bee then
            break
        end
    end
    local s = w.state.arrays.a1
    assert(s.batch and s.batch.phase == 'run')
    local pulses = 0
    w.e.io.pulse = function()
        pulses = pulses + 1
        return false
    end
    w.e:arrayTick(w.cfg.arrays[1])
    assert(pulses == 1, 'one event boundary per array instead of per node')
end
print('  PASS ordinary progress reads yield once per array')

do
    local w = make(1, 0)
    for _ = 1, 20 do
        w.tick()
    end
    for _, id in ipairs({ 'storage', w.cfg.arrays[1].diode }) do
        for _, name in ipairs({ 'hasWork', 'isWorkAllowed' }) do
            w.components[id][name] = function()
                error('startup checks must not repeat as periodic health patrols')
            end
        end
    end
    for _ = 1, 500 do
        w.tick()
    end
end
print('  PASS idle runtime does not repeat field or Maxwell power checks')

do
    local w = make(2, 67, { nodes = 16 })
    local snapshot = w.components.receiver.getItemsInNetwork
    local delayed = 0
    w.components.receiver.getItemsInNetwork = function()
        local items = snapshot()
        if w.state.admission and w.admitted == 67 and delayed < 3 then
            delayed = delayed + 1
            return { { name = 'input', damage = 0, size = 1 } }
        end
        return items
    end
    while delayed < 3 do
        w.tick()
        assert(w.time < 1000)
    end
    assert(w.closed and w.produced == 0 and not next(w.e.errors))
    w.finish()
    assert(w.produced == 67)
end
print(
    '  PASS AE confirmation waits for the real remainder without reopening nodes or raising a false error'
)

for point = 1, 32 do
    local w = make(2, 67, { nodes = 16 })
    local stops, crashed = 0, false
    for address in pairs(w.nodes) do
        local p = w.components[address]
        local enable = p.setWorkAllowed
        p.setWorkAllowed = function(value)
            enable(value)
            if not value and w.state.admission and w.admitted == 67 and not crashed then
                stops = stops + 1
                if stops == point then
                    crashed = true
                    error('SIMULATED AE CONFIRMATION INTERRUPTION')
                end
            end
        end
    end
    for _ = 1, 1000 do
        if not pcall(w.tick) then
            break
        end
    end
    assert(crashed)
    w.boot(U.copy(w.saved))
    w.finish(5000)
    assert(w.produced == 67 and w.admitted == 67)
end
print('  PASS all 32 post-AE node closing interruption points resume without duplicate intake')

do
    local w = make(1, 0)
    local a, reads = w.cfg.arrays[1], 0
    local n = w.components[a.nodes[1].address]
    local available = n.getAvailableNanites
    n.getAvailableNanites = function()
        reads = reads + 1
        return math.min(13, available())
    end
    local function change(tier)
        for _ = 1, 30 do
            if w.e:bees(a, w.state.arrays[a.address], tier) then
                return
            end
            w.advance()
        end
        error('bee change did not complete')
    end
    change(1)
    assert(w.state.arrays.a1.counts[1] == 13, 'effective count differs from physical cell contents')
    change(nil)
    reads = 0
    change(1)
    assert(reads == 0 and w.state.arrays.a1.counts[1] == 13)
    change(nil)
    w.boot(U.copy(w.saved))
    reads = 0
    change(1)
    assert(reads > 0 and w.state.arrays.a1.counts[1] == 13)
end
print('  PASS bee effective counts are measured once per cell per run and renewed after restart')

do
    local w = make(1, 0)
    w.addFeed('raw', 1)
    w.stock.entangled_neutronium = 100000
    w.boot()
    for _ = 1, 100 do
        w.tick()
    end
    local reads = 0
    local stock = w.components.storage.getStoredCondensate
    w.components.storage.getStoredCondensate = function()
        reads = reads + 1
        return stock()
    end
    w.e.now = w.e.now + 1
    assert(w.e:resources(true))
    w.r:scan()
    assert(reads == 1, 'dispatch and precache share the same-pass stock snapshot')
    w.r.s.feeds.raw.pending[1] = { amount = 1, finish = {} }
    w.r:scan()
    assert(reads == 2, 'releasing production claims requires a subsequent stock snapshot')
end
print('  PASS stock reads are shared except after releasing a completed entanglement claim')

do
    local w = make(1, 1600, { nodes = 16, stageTicks = 400 })
    w.cfg.fieldLimit = 1e9
    w.stock.entangled_neutronium = 1e8
    for _ = 1, 1000 do
        w.tick()
        local b = w.state.arrays.a1.batch
        if b and b.phase == 'run' and not w.state.arrays.a1.bee then
            break
        end
    end
    while not w.e:resources(true) do
    end
    local free = w.e.free.entangled_neutronium
    w.tick()
    assert(w.e.resourcesFresh and not w.e.resourceScan)
    assert(w.e:grant({ reserve = { entangled_neutronium = free } }))
    assert(not w.e:grant({ reserve = { entangled_neutronium = 1 } }))
    local outstanding = 0
    for _, n in pairs(w.nodes) do
        if n.active then
            outstanding = outstanding + n.count * 144 - n.consumed
        end
    end
    assert(w.stock.entangled_neutronium >= outstanding + free)
end
print('  PASS complete ledgers remain usable between scans and grants never reuse an allocation')

do
    local w = make(6, 9600, { nodes = 16, stageTicks = 400 })
    w.cfg.fieldLimit = 1e9
    w.stock.entangled_neutronium = 1e8
    w.e.prepareArrays = function() end
    for _ = 1, 1000 do
        w.tick()
        if not w.state.admission and w.state.arrays.a6.batch then
            break
        end
    end
    local b = w.state.arrays.a6.batch
    assert(b and b.phase == 'wait' and not b.granted)
    w.e.resourcesAt = nil
    w.e.io.proxy = function()
        error('sufficient complete ledger must not trigger another hardware scan during startup')
    end
    assert(w.e:resources() and w.e.resourcesFresh and not w.e.resourceScan)
    assert(w.e:grant(b))
end
print('  PASS sufficient complete ledgers skip redundant scans during grouped startup')
