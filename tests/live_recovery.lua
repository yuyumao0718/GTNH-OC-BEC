local make = assert(loadfile(ROOT .. 'tests/simplified.lua'))('fixture')
local U = dofile(ROOT .. 'ma_util.lua')
-- A partially admitted order survives with only its real AE remainder.
do
    local w = make(2, 10, { nodes = 2 })
    local old = w.nodes['a1:n2']
    old.active, old.count, old.progress = true, 6, 0
    w.admitted, w.delivered = 6, 10
    local cell = w.inventories.receiver.slots[1]
    cell.contents, cell.storedItemCount = 4, 4
    w.boot({
        queue = { { key = 'obsolete', count = 10 } },
        admission = { members = { 'missing' } },
        arrays = { missing = { batch = { count = 10 } } },
    })
    w.finish()
    assert(w.produced == 10 and w.admitted == 10 and old.count == 6)
end
print('  PASS six in a node and four in AE finish once; the old ten-part allocation is discarded')

-- Exercise the real GTNH signature with no disk history. A compressed circuit
-- array has the same tiers and different fluids.
local tiers = { 10, 5, 9, 1, 4, 8, 8, 4, 4, 8, 8, 4, 2, 6, 7, 3 }
local singular = {
    entangled_neutronium = 147456000,
    entangled_cosmicneutronium = 147456000,
    entangled_infinity = 147456000,
    entangled_bedrockium = 147456000,
}
local function scanned(count, progress, consumed, unit, enabled)
    local w = make(1, 0, { nodes = 16 })
    w.cfg.fieldLimit = 1e12
    local steps = {}
    for i, t in ipairs(tiers) do
        steps[i] = { nanite = { tier = t }, start = (i - 1) * 40000000, ['end'] = i * 40000000 }
    end
    w.share({ { tier = 10, slot = 1, count = 32 } })
    for i = 1, count do
        local id = 'a1:n' .. i
        local node = w.nodes[id]
        node.active, node.count, node.progress = true, 1, progress
        local n = w.components[id]
        n.getRecipeSteps = function()
            return steps
        end
        n.getRequiredCondensate = function()
            return U.copy(unit)
        end
        n.getConsumedCondensate = function()
            return { entangled_neutronium = consumed }
        end
    end
    w.arrays.a1.enabled = enabled or false
    w.boot()
    for _ = 1, 20 do
        w.tick()
        if w.e.recovered then
            break
        end
    end
    return w.state.arrays.a1.batch
end
local b = scanned(7, 0, 0, singular)
assert(b.phase == 'collect' and b.collection.elapsed == 0 and #b.workers == 7)
assert(scanned(16, 0, 0, singular).phase ~= 'collect')
assert(scanned(7, 1, 0, singular).phase == 'run')
assert(scanned(7, 0, 1, singular).phase == 'run')
assert(scanned(7, 0, 0, singular, true).phase == 'run')
local circuit = {
    entangled_cosmicsolder = 10000,
    entangled_space = 10368,
    entangled_time = 10368,
    entangled_spacetime = 1474560,
}
assert(not scanned(7, 0, 0, circuit).collection)
print(
    '  PASS cold scan distinguishes unstarted, full and running singularities from compressed circuit arrays'
)

do
    local w = make(2, 0)
    w.share({
        { tier = 1, box = 1, slot = 1, count = 32 },
        { tier = 1, box = 2, slot = 2, count = 17 },
    })
    w.boot()
    local function change(i, tier)
        local a = w.cfg.arrays[i]
        for _ = 1, 30 do
            if w.e:bees(a, w.state.arrays[a.address], tier) then
                return
            end
            w.advance()
        end
        error('transfer did not finish')
    end
    change(1, 1)
    change(2, 1)
    assert(w.arrays.a1.bees == 32 and w.arrays.a2.bees == 17)
    -- Array 2 returns into the first empty cell, across colors, although
    -- its load came from the second one.
    change(2, nil)
    assert(w.sharedCells[1].storedItemCount == 17 and w.sharedCells[2].storedItemCount == 0)
    w.boot()
    change(1, nil)
    assert(w.sharedCells[2].storedItemCount == 32)
    assert(w.saves == 0)
    w.assertPool()
end
print('  PASS two arrays exchange same-tier return cells across boxes with no writes')

do
    local w = make(2, 0)
    w.share({ { tier = 1, slot = 1, count = 32 }, { tier = 2, slot = 2, count = 32 } })
    w.boot()
    for i = 1, 2 do
        local a = w.cfg.arrays[i]
        w.e:bees(a, w.state.arrays[a.address], i)
    end
    -- Two simultaneous loads become identifiable after the ME-IO ports finish.
    w.boot()
    for _ = 1, 100 do
        w.tick()
        if w.e.recovered and not w.state.arrays.a1.bee and not w.state.arrays.a2.bee then
            break
        end
    end
    for i = 1, 2 do
        local a = w.cfg.arrays[i]
        for _ = 1, 30 do
            if w.e:bees(a, w.state.arrays[a.address], i) then
                break
            end
            w.advance()
        end
    end
    for i = 1, 2 do
        local a = w.cfg.arrays[i]
        assert(not w.e:bees(a, w.state.arrays[a.address], nil))
    end
    w.advance()
    local ok, reason = pcall(w.boot)
    assert(not ok and tostring(reason):find('无法辨认等级', 1, true))
    w.advance()
    for i = 1, 2 do
        local a = w.cfg.arrays[i]
        assert(w.e.log:transfer(a.unloadPort, a.beeBoxes[1].inventory, 7, i))
    end
    w.boot()
    w.e:requestStop()
    for _ = 1, 30 do
        w.tick()
        if w.e:drain() then
            break
        end
    end
    assert(w.e:drain() and w.arrays.a1.bees == 0 and w.arrays.a2.bees == 0)
    w.assertPool()
end
print('  PASS ambiguous interrupted tiers stop for physical reset; restarting after reset succeeds')

do
    local w = make(1, 1600, { nodes = 16, stageTicks = 400 })
    w.cfg.fieldLimit = 1e9
    w.stock.entangled_neutronium = 1e8
    local times = {}
    local n = w.components['a1:n1']
    local read = n.getWorkProgress
    n.getWorkProgress = function()
        local b = w.state.arrays.a1.batch
        if b and b.phase == 'run' and not b.fixed and not w.state.arrays.a1.bee then
            times[#times + 1] = w.e.io.time()
        end
        return read()
    end
    for _ = 1, 200 do
        w.tick()
    end
    assert(#times >= 4)
    for i = 2, #times do
        assert(times[i] - times[i - 1] >= 0.25 - 1e-7)
    end
end
print('  PASS ordinary node scans use a per-array five-tick interval')

do
    local w = make(1, 4)
    w.finish()
    assert(w.saves == 1)
    local later = make(1, 4)
    later.boot(U.copy(w.saved))
    later.finish()
    assert(later.saves == 0 and later.produced == 4)
end
print(
    '  PASS learning once persists one cache; another order with that recipe finishes with zero writes'
)

do
    local w = make(2, 0)
    w.share({ { tier = 1, slot = 1, count = 32 } })
    w.boot()
    local n = w.components['a1:n1']
    local available = n.getAvailableNanites
    n.getAvailableNanites = function()
        return math.min(13, available())
    end
    local function change(i, tier)
        local a = w.cfg.arrays[i]
        for _ = 1, 30 do
            if w.e:bees(a, w.state.arrays[a.address], tier) then
                return
            end
            w.advance()
        end
        error('failed to change tier')
    end
    change(1, 1)
    assert(w.state.arrays.a1.counts[1] == 13)
    change(1, nil)
    local a = w.cfg.arrays[2]
    assert(w.e:beeCount(a, w.e:beeCells(a)[1]) == 32)
    change(2, 1)
    assert(w.state.arrays.a2.counts[1] == 32)
end
print(
    '  PASS exchanging a cell preserves its physical size when arrays report different effective counts'
)

do
    local w = make(1, 1600, { nodes = 16, stageTicks = 400 })
    w.cfg.fieldLimit = 1e9
    w.stock.entangled_neutronium = 1e8
    local a = w.cfg.arrays[1]
    for _ = 1, 500 do
        w.tick()
        local b = w.state.arrays.a1.batch
        if b and b.phase == 'run' and b.targetTier then
            break
        end
    end
    local b = w.state.arrays.a1.batch
    assert(b.targetTier and not b.fixed)
    local n = w.components['a1:n1']
    local read = n.getWorkProgress
    local samples, attempts = {}, 0
    n.getWorkProgress = function()
        samples[#samples + 1] = w.e.io.time()
        return read()
    end
    w.e.bees = function(_, _, state, tier)
        assert(tier == b.targetTier)
        state.request = { tier = tier, id = 1 }
        attempts = attempts + 1
        return false
    end
    for _ = 1, 30 do
        w.tick()
    end
    assert(#samples >= 4 and attempts >= 3 * #samples)
    for i = 2, #samples do
        assert(samples[i] - samples[i - 1] >= 0.25 - 1e-7)
    end
end
print('  PASS a bee waiter retries between scans without rereading node progress')

do
    local w = make(30, 0, { nodes = 1 })
    w.stock.entangled_neutronium = 144
    for i = 1, 30 do
        local node = w.nodes['a' .. i .. ':n1']
        node.active, node.count = true, i < 30 and 2 or 1
    end
    w.boot()
    local overhead = 0
    w.e.io.time = function()
        return math.floor(w.time + overhead * 20) / 20
    end
    w.e.io.pulse = function()
        overhead = overhead + 0.012
    end
    for _ = 1, 1000 do
        w.tick()
        if w.state.arrays.a30.done == 1 then
            break
        end
    end
    assert(w.state.arrays.a30.done == 1 and w.produced == 1)
    assert(w.stock.entangled_neutronium == 0)
    for i = 1, 29 do
        assert(w.state.arrays['a' .. i].batch.phase == 'wait')
    end
end
print('  PASS the 30th recovered array starts with 144 L while 29 larger batches wait')

do
    local w = make(1, 16, { nodes = 2, stageTicks = 100 })
    for _ = 1, 200 do
        w.tick()
        if w.state.arrays.a1.batch and w.state.arrays.a1.batch.started then
            break
        end
    end
    assert(w.state.arrays.a1.batch.started)
    w.e:requestStop()
    local reader = w.components.receiver
    local read, reads = reader.getItemsInNetwork, 0
    reader.getItemsInNetwork = function()
        reads = reads + 1
        return read()
    end
    for _ = 1, 100 do
        assert(not w.e:drain())
    end
    assert(reads == 0)
    for _ = 1, 2000 do
        w.tick()
        if w.e:drain() then
            break
        end
    end
    assert(w.produced == 16 and w.e:drain() and reads > 0 and w.arrays.a1.bees == 0)
end
print('  PASS Q checks AE only after the last active batch and returns its bee set')

do
    local R = dofile(ROOT .. 'ma_recovery.lua')
    local w = make(2, 0, { nodes = 1 })
    w.share({ { tier = 1, slot = 1, count = 32 } })
    w.boot()
    local a = w.cfg.arrays[1]
    for _ = 1, 30 do
        if w.e:bees(a, w.state.arrays.a1, 1) then
            break
        end
        w.advance()
    end
    assert(w.arrays.a1.bees == 32)
    w.e:pause()
    local cfg = U.copy(w.cfg)
    cfg.arrays[1].name = '改名'
    cfg.beePools[1].cells[2] = { tier = 2, box = 1, slot = 2 }
    assert(R.check(cfg, w.cfg, U, function()
        error('unrelated settings read a machine')
    end))
    local function refuses(nextCfg)
        local ok, err = pcall(R.check, nextCfg, w.cfg, U, w.e.io.proxy)
        assert(not ok and tostring(err):find('蜂群归位', 1, true))
    end
    cfg.arrays[1].enabled = false
    refuses(cfg)
    local remapped = U.copy(w.cfg)
    U.index(remapped.inventories)[a.unloadPort].side = 4
    refuses(remapped)
    local slot = U.copy(w.cfg)
    slot.beePools[1].cells[1].slot = 2
    refuses(slot)
    w.e:requestStop()
    for _ = 1, 100 do
        w.tick()
        if w.e:drain() then
            break
        end
    end
    assert(w.arrays.a1.bees == 0 and w.sharedCells[1].storedItemCount == 32)
    assert(R.check(cfg, w.cfg, U, w.e.io.proxy))
    w.inventories[a.loadPort].slots[1] = w.sharedCells[1]
    refuses(cfg)
end
print(
    '  PASS a retained or moving set blocks rewiring, while names, additions and returned sets are safe'
)
