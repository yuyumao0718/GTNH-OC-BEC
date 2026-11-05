local make = assert(loadfile(ROOT .. 'tests/simplified.lua'))('fixture')

do
    local w = make(2, 0)
    for _ = 1, 20 do
        w.tick()
    end
    local calls = 0
    for id in pairs(w.arrays) do
        for _, method in ipairs({ 'hasWork', 'isWorkAllowed' }) do
            local original = w.components[id][method]
            w.components[id][method] = function(...)
                calls = calls + 1
                return original(...)
            end
        end
    end
    for _ = 1, 20 do
        w.tick()
    end
    assert(calls == 0, 'confirmed idle arrays must not poll their power switches')
end
print('  PASS confirmed idle arrays do not repeat stop checks')

local function watch(p, names)
    local calls = {}
    for _, name in ipairs(names) do
        local original = assert(p[name], name)
        p[name] = function(...)
            calls[name] = (calls[name] or 0) + 1
            return original(...)
        end
    end
    return calls
end

do
    local w = make(1, 0)
    local e, c = w.e, w.cfg.channels[1]
    local calls = watch(w.components.receiver, { 'getItemsInNetwork', 'setItemEventSubscription' })
    e.now = 0
    e:channel(c)
    assert(calls.getItemsInNetwork == 1 and w.subscribed)
    e:event('network_item_changed', 'another-network')
    e.now = 1
    e:channel(c)
    assert(calls.getItemsInNetwork == 1)
    for _ = 1, 100 do
        e:event('network_item_changed', c.buffer)
    end
    assert(calls.getItemsInNetwork == 1, 'events must not read or schedule recursively')
    e:channel(c)
    assert(calls.getItemsInNetwork == 2, 'coalesce a burst into one snapshot')
    w.inventories.receiver.slots[1].contents = 2
    e.now = 10.99
    e:channel(c)
    assert(calls.getItemsInNetwork == 2)
    e.now = 11
    e:channel(c)
    assert(calls.getItemsInNetwork == 3 and w.closed and #w.state.queue == 0)
    e.now = 11.24
    e:channel(c)
    assert(calls.getItemsInNetwork == 3)
    e.now = 11.25
    e:channel(c)
    assert(calls.getItemsInNetwork == 4 and w.state.queue[1].count == 2)
    assert(not w.subscribed, 'queued orders must stop observing extraction changes')
    e:event('network_item_changed', c.buffer)
    e:channel(c)
    assert(calls.getItemsInNetwork == 4)
    w.state.queue = {}
    e:channel(c)
    assert(calls.getItemsInNetwork == 5, 'resubscription must read existing input immediately')
    e:pause()
    assert(not w.subscribed)
end
print(
    '  PASS AE events coalesce, ignore other networks, settle without another signal and recover missed signals'
)

do
    local w = make(1, 0)
    local e, c = w.e, w.cfg.channels[1]
    local reads = 0
    local original = w.components.receiver.getItemsInNetwork
    w.components.receiver.getItemsInNetwork = function()
        reads = reads + 1
        if reads == 1 then
            e:event('network_item_changed', c.buffer)
        end
        return original()
    end
    e:channel(c)
    e:channel(c)
    assert(reads == 2, 'a signal arriving during a snapshot must survive until the next pass')
end
print('  PASS an AE event during a network read is not lost')

do
    local w = make(1, 32, { nodes = 2 })
    local a = w.cfg.arrays[1]
    local calls = {}
    for _, n in ipairs(a.nodes) do
        calls[n.address] = watch(
            w.components[n.address],
            { 'setMinParallel', 'setMaxParallel', 'setWorkAllowed', 'getRequiredCondensate' }
        )
    end
    for _ = 1, 100 do
        w.tick()
        local b = w.state.arrays[a.address].batch
        if b and b.phase == 'admit' then
            break
        end
    end
    assert(w.state.arrays[a.address].batch.phase == 'admit')
    for _ = 1, 10 do
        w.e:recoveryIntakes()
        w.e:array(a)
    end
    for _, c in pairs(calls) do
        assert(not c.setMinParallel and c.setMaxParallel == 1 and c.setWorkAllowed == 1)
    end
    w.advance()
    local delayed = w.components[a.nodes[2].address]
    local actual = delayed.hasWork
    delayed.hasWork = function()
        return false
    end
    for _ = 1, 10 do
        w.e:recoveryIntakes()
        w.e:array(a)
    end
    local first = calls[a.nodes[1].address]
    assert(not first.getRequiredCondensate and first.setWorkAllowed == 1)
    w.e:admissionTick()
    assert(first.getRequiredCondensate == 1 and first.setWorkAllowed == 2)
    delayed.hasWork = actual
    w.finish()
end
print('  PASS intake sets parallel once and AE completion closes nodes without hasWork probes')

local function running()
    local w = make(1, 1600, { nodes = 16, stageTicks = 400 })
    w.cfg.fieldLimit = 1e9
    w.stock.entangled_neutronium = 1e8
    w.boot()
    for _ = 1, 1000 do
        w.tick()
        local s = w.state.arrays.a1
        if s.batch and s.batch.phase == 'run' and not s.bee and w.arrays.a1.enabled then
            assert(not s.batch.fixed)
            return w, w.cfg.arrays[1], s
        end
    end
    error('ordinary batch did not start')
end

for _, second in ipairs({ false, true }) do
    local w, a, s = running()
    local first = s.batch.workers[1]
    local node, count = w.components[first.address], 0
    node.hasWork = function()
        count = count + 1
        return second and count == 1
    end
    w.e:array(a)
    assert(count == (second and 2 or 1))
    local calls = watch(node, { 'hasWork', 'getWorkProgress', 'getConsumedCondensate' })
    for _ = 1, 4 do
        w.e:array(a)
        w.e:remaining(s)
    end
    assert(not next(calls), 'completed nodes must stay out of processing and resource polling')
    w.boot(w.saved)
    assert(not next(w.e.nodeCache), 'restart must rebuild runtime completion observations')
end
print(
    '  PASS completion at either hasWork check suppresses further reads only for this runtime batch'
)

do
    local w, a, s = running()
    for _, worker in ipairs(s.batch.workers) do
        local n = w.nodes[worker.address]
        n.consumed = 144 * n.count
    end
    assert(w.e.U.total(w.e:remaining(s)) == 0)
    local reads = {}
    for _, worker in ipairs(s.batch.workers) do
        reads[#reads + 1] =
            watch(w.components[worker.address], { 'hasWork', 'getConsumedCondensate' })
    end
    assert(w.e.U.total(w.e:remaining(s)) == 0)
    for _, calls in ipairs(reads) do
        assert(
            not next(calls),
            'fully supplied nodes need no consumption or work reads in the ledger'
        )
    end
    local calls = watch(w.components[a.address], { 'hasWork', 'isWorkAllowed', 'setWorkAllowed' })
    w.arrays[a.address].enabled = false
    for _ = 1, 20 do
        w.tick()
    end
    assert(not next(calls) and not w.arrays[a.address].enabled and not next(w.e.errors))
    w.arrays[a.address].enabled = true
    local progress = w.nodes[s.batch.workers[1].address].progress
    w.tick()
    assert(w.nodes[s.batch.workers[1].address].progress > progress)
    w.finish(5000)
end
print(
    '  PASS fully supplied nodes stop consumption reads and a manual array stop is not automatically reversed'
)

do
    local w, a, s = running()
    local d = w.components[a.diode]
    local calls = watch(d, {
        'hasWork',
        'isWorkAllowed',
        'getCondensateFilterCount',
        'getCondensateFilterAt',
        'getCondensateFilters',
        'setCondensateFilterAt',
    })
    local unit = w.state.patterns[s.batch.key].unit
    w.e:filters(a, unit)
    assert(not next(calls), 'unchanged filters must return without hardware callbacks')
    w.e:filters(a, {})
    assert(not calls.getCondensateFilterCount)
    assert(not calls.getCondensateFilterAt and not calls.getCondensateFilters)
    assert(calls.setCondensateFilterAt == 1)
    local field = watch(w.components.storage, { 'getFieldStrength', 'hasWork', 'isWorkAllowed' })
    w.time = w.time + 201
    w.e:tick()
    assert(not next(field))
    assert(not calls.getCondensateFilterAt and not calls.getCondensateFilters and not calls.hasWork)
end
print('  PASS field and gate do not repeat startup checks during runtime')

do
    local w = make(1, 0)
    w.addFeed('raw', 1)
    w.boot()
    local calls = watch(w.components['raw:g1'], { 'hasWork', 'getWorkProgress' })
    w.e.now = 0
    w.r:generators()
    assert(calls.hasWork == 1 and not calls.getWorkProgress)
    w.e.now = 4.99
    w.r:generators()
    assert(calls.hasWork == 1)
    w.gens['raw:g1'].busy = true
    w.r:generators('raw')
    assert(calls.hasWork == 2 and calls.getWorkProgress == 1)
    w.e.now = 5
    w.time = 100
    w.r:generators()
    assert(calls.hasWork == 3 and calls.getWorkProgress == 2)
end
print(
    '  PASS entanglers scan every five seconds, skip idle progress and allow critical fresh reads'
)
