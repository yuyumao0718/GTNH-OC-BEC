local make = assert(loadfile(ROOT .. 'tests/simplified.lua'))('fixture')
local U = dofile(ROOT .. 'ma_util.lua')
local N = dofile(ROOT .. 'ma_nanites.lua')
local mature = dofile(ROOT .. 'tests/reference/bec_nanites.lua')

local raw = {}
for i, tier in ipairs({ 4, 1, 1, 3, 1 }) do
    raw[i] = { nanite = { tier = tier }, start = (i - 1) * 1200, ['end'] = i * 1200 }
end
local steps = N.steps(raw)
assert(U.equal(steps, mature.steps(raw)))
local cells = {}
for tier = 1, 10 do
    cells[tier] = { slot = tier }
end
for _, progress in ipairs({ 0, 1199, 1200, 1530, 2399, 2400, 3599, 3600, 4627, 4799, 4800, 5999 }) do
    assert(N.requested(steps, progress) == mature.requested(steps, progress))
    local workers = {}
    for i = 1, 16 do
        workers[i] = { progress = progress, tier = N.requested(steps, progress) }
    end
    for _, previous in ipairs({ 0, progress, 5900 }) do
        assert(N.choose(workers, previous, 6000) == mature.choose(workers, previous, 6000))
    end
    assert(N.tier(workers[1].tier, cells) == mature.tier(workers[1].tier, cells))
end
for _, parallel in ipairs({ 1, 2, 16, 3840 }) do
    for _, count in ipairs({ 0, 30720, 48000, 1e9 }) do
        assert(
            N.fastTier(steps, cells, { [4] = count }, parallel)
                == mature.fastTier(steps, cells, { [4] = count }, parallel)
        )
    end
end
do
    local workers = { { progress = 1000, tier = 4 }, { progress = 1530, tier = 1 } }
    for _, previous in ipairs({ 0, 1530, 4000 }) do
        assert(N.choose(workers, previous, 6000) == mature.choose(workers, previous, 6000))
    end
end
print('  PASS mature stage boundaries, reference selection and fastTier decisions agree')

do
    local I = dofile(ROOT .. 'ma_intake.lua')
    local old = dofile(ROOT .. 'tests/reference/bec_intake.lua')
    local pattern = {
        isCraftable = false,
        inputs = { { name = 'input', damage = 4, size = 3, hasTag = true, tag = 'tag' } },
        outputs = { { name = 'output', damage = 0, size = 2, label = '中文产物' } },
    }
    local current, reference = I.catalog({ pattern }), old.catalog({ pattern })
    assert(current.patterns[1].key == reference.patterns[1].key)
    for _, count in ipairs({ 3, 6, 300, 300000 }) do
        local input = { name = 'input', damage = 4, size = count, hasTag = true, tag = 'tag' }
        local have, before = I.inventory({ input }), old.inventory({ input }, {})
        assert(U.equal(have, before))
        local a, b = I.identify(current, have), old.identify(reference, before)
        assert(a.key == b.key)
        local total, complete = I.receipts(a, have)
        local oldTotal, oldComplete = old.receipts(b, before)
        assert(total == oldTotal and complete == oldComplete)
    end
end
print('  PASS mature item identity, pattern signature and receipt arithmetic agree')

for _, arrays in ipairs({ 1, 2, 6, 10, 30 }) do
    for _, nodes in ipairs({ 3, 16 }) do
        local w = make(arrays, arrays * nodes * 2 + 1, { nodes = nodes })
        w.cfg.fieldLimit = 1e9
        w.stock.entangled_neutronium = 1e8
        local preparing, opened, lastStart, round = {}, {}, {}, 0
        local readNames = { 'getItemsInNetwork', 'getRequiredCondensate', 'getRecipeSteps' }
        for _, p in pairs(w.components) do
            for _, name in ipairs(readNames) do
                if p[name] then
                    local original = p[name]
                    p[name] = function(...)
                        for id, count in pairs(opened) do
                            assert(
                                count == nodes,
                                'no inventory/recipe reads between node enables: ' .. id
                            )
                        end
                        return original(...)
                    end
                end
            end
        end
        for address, node in pairs(w.nodes) do
            local p = w.components[address]
            local set, enable = p.setMaxParallel, p.setWorkAllowed
            p.setMaxParallel = function(n)
                assert(not opened[node.array], 'set every parallel before opening the first node')
                preparing[address] = n
                return set(n)
            end
            p.setWorkAllowed = function(value)
                if value then
                    local b = w.state.arrays[node.array].batch
                    for _, worker in ipairs(b.workers) do
                        assert(
                            preparing[worker.address] == worker.count,
                            'all node caps must be ready'
                        )
                    end
                    if not opened[node.array] then
                        assert(
                            not lastStart[round],
                            'only one new array is prepared per scheduler round'
                        )
                        lastStart[round] = node.array
                    end
                    opened[node.array] = (opened[node.array] or 0) + 1
                end
                return enable(value)
            end
        end
        local tick = w.tick
        w.tick = function()
            round = round + 1
            tick()
        end
        w.finish(10000)
        for _, a in ipairs(w.cfg.arrays) do
            assert(opened[a.address] == nodes)
        end
    end
end
print(
    '  PASS whole-array parallel preparation precedes uninterrupted enables at 1/2/6/10/30 arrays'
)

-- Exercise crashes after each parameter write and node enable, before its memory flag is updated.
for _, operation in ipairs({ 'setMaxParallel', 'setWorkAllowed' }) do
    for point = 1, 32 do
        local w = make(2, 67, { nodes = 16 })
        local calls, crashed = 0, false
        for _, p in pairs(w.components) do
            if p.getParallelRecipesInProgress then
                local original = p[operation]
                p[operation] = function(value)
                    local result = original(value)
                    if operation == 'setMaxParallel' or value then
                        calls = calls + 1
                        if calls == point then
                            crashed = true
                            w.advance()
                            error('SIMULATED INTAKE POWER LOSS')
                        end
                    end
                    return result
                end
            end
        end
        for _ = 1, 500 do
            local ok = pcall(w.tick)
            if not ok or next(w.e.errors) then
                break
            end
        end
        assert(crashed, 'must reach every interruption point')
        w.boot(U.copy(w.saved))
        w.finish(10000)
    end
end
print(
    '  PASS 64 parameter/enable interruption points resume without repeated intake or lost output'
)

for _, arrays in ipairs({ 6, 10, 30 }) do
    local w = make(arrays, 16 + (arrays - 1) * 32, { nodes = 16, stageTicks = 20000 })
    w.cfg.fieldLimit = 1e9
    w.stock.entangled_neutronium = 1e8
    w.deliveryBatch = 16
    for _ = 1, 1000 do
        w.tick()
        local b = w.state.arrays.a1.batch
        if b and b.phase == 'run' and w.arrays.a1.tier == 1 then
            break
        end
    end
    assert(w.state.arrays.a1.batch.phase == 'run')
    for _, n in pairs(w.nodes) do
        if n.array == 'a1' then
            n.progress = 20001
        end
    end
    w.deliveryBatch = (arrays - 1) * 32
    local round, serviced, preparations, requested = 0, 0, 0, false
    local writes = 0
    local idleReads = {}
    local array, bees = w.e.array, w.e.bees
    w.e.array = function(e, a)
        local result = array(e, a)
        if a.address == 'a1' then
            serviced = round
        end
        return result
    end
    w.e.bees = function(e, a, s, want)
        requested = requested or a.address == 'a1' and want == 2
        return bees(e, a, s, want)
    end
    for address, n in pairs(w.nodes) do
        if n.array ~= 'a1' then
            local hasWork = w.components[address].hasWork
            w.components[address].hasWork = function()
                if not n.allowed and not n.active then
                    idleReads[address] = (idleReads[address] or 0) + 1
                    assert(
                        idleReads[address] == 1,
                        'a confirmed empty closed node needs no repeated query'
                    )
                end
                return hasWork()
            end
            local original = w.components[address].setMaxParallel
            w.components[address].setMaxParallel = function(value)
                assert(
                    serviced == round and requested,
                    'running array must switch before new intake setup'
                )
                preparations = preparations + 1
                writes = writes + 1
                -- A non-direct setup callback consumes one server tick.
                w.advance()
                return original(value)
            end
        end
    end
    for i = 1, 1000 do
        round = i
        writes = 0
        w.tick()
        assert(not next(w.e.errors))
        assert(writes <= 4, 'timed setup must yield to existing work within four 50 ms callbacks')
        if preparations == (arrays - 1) * 16 then
            break
        end
    end
    assert(preparations == (arrays - 1) * 16 and w.arrays.a1.tier == 2)
end
print('  PASS existing processing and bee switches precede new intake at 6/10/30 arrays')

for _, pause in ipairs({ false, true }) do
    local w = make(2, 48, { nodes = 16, stageTicks = 400 })
    w.deliveryBatch = 16
    for _ = 1, 1000 do
        w.tick()
        if w.state.arrays.a1.batch and w.state.arrays.a1.batch.phase == 'run' then
            break
        end
    end
    w.deliveryBatch = 32
    local writes = 0
    for _, node in ipairs(w.cfg.arrays[2].nodes) do
        local original = w.components[node.address].setMaxParallel
        w.components[node.address].setMaxParallel = function(value)
            writes = writes + 1
            w.advance()
            return original(value)
        end
    end
    for _ = 1, 100 do
        w.tick()
        if writes > 0 then
            break
        end
    end
    assert(
        writes > 0 and writes < 16,
        'interrupt while some caps are set but the whole array is closed'
    )
    for _, node in ipairs(w.cfg.arrays[2].nodes) do
        assert(not w.nodes[node.address].allowed and not w.nodes[node.address].active)
    end
    if pause then
        w.e:pause()
    end
    w.boot(U.copy(w.saved))
    w.finish(4000)
end
print('  PASS crash and Ctrl+C during timed preparation resume both running and unopened arrays')

do
    local w = make(2, 48, { nodes = 16, stageTicks = 400 })
    w.deliveryBatch = 16
    local array = w.e.array
    w.e.array = function(e, a)
        local b = e.s.arrays[a.address].batch
        if a.address == 'a1' and b and b.phase == 'wait' then
            if not e.s.admission or e.s.admission.members[1] ~= 'a2' then
                return
            end
        end
        return array(e, a)
    end
    local transfer = w.components['a1:transposer'].transferItem
    w.components['a1:transposer'].transferItem = function(...)
        local n = transfer(...)
        w.advance()
        return n
    end
    local writes = 0
    for _, node in ipairs(w.cfg.arrays[2].nodes) do
        local original = w.components[node.address].setMaxParallel
        w.components[node.address].setMaxParallel = function(value)
            writes = writes + 1
            w.advance()
            return original(value)
        end
    end
    for _ = 1, 1000 do
        w.e.resourcesAt = nil
        w.tick()
        if w.delivered == 16 then
            w.deliveryBatch = 32
        end
        if writes > 0 then
            break
        end
    end
    assert(w.state.arrays.a1.batch.phase == 'run')
    assert(writes > 0 and writes <= 4, 'an array that starts this pass also needs timely service')
    w.e.array = array
    w.finish(4000)
end
print('  PASS arrays started in this pass also bound subsequent intake preparation')

do
    local B = dofile(ROOT .. 'simulation/user_cache_compare.lua')
    for _, arrays in ipairs({ 1, 2 }) do
        local w = B.current({
            arrays = arrays,
            count = arrays * 16 * 3840,
            tiers = { 4, 1, 1, 3, 1 },
            length = 1200,
            syncTicks = 1,
            ioTicks = 1,
        })
        local seen = {}
        for _, event in ipairs(w.metrics.events) do
            if event.kind == 'loaded' then
                local array, tier = event.detail:match('(a%d+):T(%d+)')
                seen[array] = seen[array] or {}
                seen[array][#seen[array] + 1] = tonumber(tier)
            end
        end
        for _, a in ipairs(w.cfg.arrays) do
            assert(
                U.equal(seen[a.address], { 4, 1, 3, 1 }),
                'actual loaded bees must follow shielding recipe'
            )
        end
    end

    local w = B.world({
        arrays = 1,
        count = 16 * 3840,
        tiers = { 4, 1, 1, 3, 1 },
        length = 1200,
        syncTicks = 0,
        ioTicks = 1,
    })
    w.boot()
    for _ = 1, 1000 do
        w.tick()
        if w.state.arrays.a1.batch and w.state.arrays.a1.batch.phase == 'run' then
            break
        end
    end
    local s, a = w.state.arrays.a1, w.cfg.arrays[1]
    assert(s.batch.phase == 'run' and not s.batch.fixed and w.arrays.a1.tier == 4)
    for _, n in pairs(w.nodes) do
        n.progress = 1530
    end
    local requested, original = nil, w.e.bees
    w.e.bees = function(e, array, state, want)
        requested = requested or want
        return original(e, array, state, want)
    end
    w.e:array(a)
    assert(requested == 1, 'the next complete decision at 1530 must request T1')
    for _ = 1, 10 do
        w.tick()
        if w.arrays.a1.tier == 1 and not s.bee then
            break
        end
    end
    assert(w.arrays.a1.tier == 1 and not s.bee)
end
print(
    '  PASS shielding recipe physically switches T4/T1/T3/T1; aligned progress 1530 requests and loads T1'
)
