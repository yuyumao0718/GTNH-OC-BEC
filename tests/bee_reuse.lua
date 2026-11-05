local make = assert(loadfile(ROOT .. 'tests/simplified.lua'))('fixture')
local U = dofile(ROOT .. 'ma_util.lua')

local function drain(w)
    w.e:requestStop()
    for _ = 1, 100 do
        w.tick()
        if w.e:drain() then
            for _, s in pairs(w.state.arrays) do
                assert(not s.lease and not s.bee and not s.reuse)
            end
            return
        end
    end
    error('retained bees did not return on exit')
end

local function repeated(fast)
    local w = make(1, 160, { nodes = 16, stageTicks = 40 })
    w.deliveryBatch = 16
    w.lowTier, w.highTier = 1, 1
    w.share({ { tier = 1, slot = 1, count = fast and 10000 or 32 } })
    local minimum = 0
    for address in pairs(w.nodes) do
        local setter = w.components[address].setMinParallel
        w.components[address].setMinParallel = function(value)
            assert(value == 1)
            minimum = minimum + 1
            return setter(value)
        end
    end
    w.boot()
    w.minimumWrites = function()
        return minimum
    end
    return w
end

for _, fast in ipairs({ false, true }) do
    local w = repeated(fast)
    assert(w.minimumWrites() == 16)
    w.finish(10000)
    assert(w.minimumWrites() == 16, 'minimum parallel was rewritten between orders')
    assert(w.moves == 2 and w.state.arrays.a1.reuse)
    w.assertPool()
    drain(w)
    assert(w.moves == 4, 'ten same-tier orders should load once and return once')
end
print('  PASS ten ordinary/fastTier orders reuse bees and set minimum parallel only at startup')

for _, phase in ipairs({ 'idle', 'admit', 'wait', 'run' }) do
    local w = repeated(false)
    local found
    local save = w.e.io.save
    if phase == 'wait' then
        w.e.io.save = function(state)
            save(state)
            local s = state.arrays.a1
            if s.done == 16 and s.batch and s.batch.phase == 'wait' then
                found = true
                error('SIMULATED PRE-START INTERRUPTION')
            end
        end
    end
    for _ = 1, 10000 do
        local ok, err = pcall(w.tick)
        assert(ok or found, err)
        if found then
            break
        end
        local s = w.state.arrays.a1
        if s.done == 16 and (s.batch and s.batch.phase or 'idle') == phase then
            found = true
            break
        end
    end
    assert(found, 'missing retained-bee checkpoint ' .. phase)
    w.e.io.save = save
    w.e:pause()
    w.boot(U.copy(w.saved))
    w.finish(10000)
    assert(w.produced == 160 and w.admitted == 160 and w.moves == 2)
    assert(w.minimumWrites() == 32, 'restart must initialize minimum parallel again')
    drain(w)
end
print('  PASS retained bees resume idle, intake, pre-start and running orders without another load')

for _, phase in ipairs({ 'idle', 'admit', 'collect' }) do
    local w = make(2, 0)
    w.share({ { tier = 1, slot = 1, count = 32 } })
    w.boot()
    local a, other = w.cfg.arrays[1], w.cfg.arrays[2]
    local s, waiter = w.state.arrays.a1, w.state.arrays.a2
    for _ = 1, 30 do
        w.advance()
        if w.e:bees(a, s, 1) then
            break
        end
    end
    assert(s.lease and not s.bee)
    s.reuse = true
    if phase ~= 'idle' then
        w.state.patterns.test = { pattern = { label = '测试订单' } }
        s.batch = { phase = phase, key = 'test', count = 0, workers = {} }
        if phase == 'admit' then
            s.batch.count = 1
            s.batch.workers = { { address = a.nodes[1].address, count = 1 } }
        end
        if phase == 'collect' then
            s.batch.collection = { elapsed = 0 }
        end
    end
    assert(not w.e:bees(other, waiter, 1))
    for _ = 1, 30 do
        w.advance()
        w.e:array(a)
        if w.e:bees(other, waiter, 1) then
            break
        end
    end
    assert(not s.lease and not s.reuse and waiter.lease)
    w.assertPool()
end
print('  PASS a waiting peer receives retained bees during idle, intake and singularity collection')

do
    local w = make(2, 0)
    local a, other = w.cfg.arrays[1], w.cfg.arrays[2]
    local s = w.state.arrays.a1
    for _ = 1, 30 do
        w.advance()
        if w.e:bees(a, s, 1) then
            break
        end
    end
    s.reuse = true
    w.state.arrays.a2.request = { tier = 1, id = 1 }
    w.e:array(a)
    assert(s.reuse and not s.bee, 'another pool must not evict retained bees')
    other.beePool = a.beePool
    w.state.arrays.a2.request.tier = 2
    w.e:array(a)
    assert(s.reuse and not s.bee, 'another tier must not evict retained bees')
end
print('  PASS requests for other pools or grades leave retained bees available for reuse')
