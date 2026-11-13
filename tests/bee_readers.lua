local make = assert(loadfile(ROOT .. 'tests/simplified.lua'))('fixture')
local U = dofile(ROOT .. 'ma_util.lua')

local function change(w, a, tier)
    for _ = 1, 60 do
        if w.e:bees(a, w.state.arrays[a.address], tier) then
            return
        end
        w.advance()
    end
    error('bee transfer did not finish')
end

local function observe(w)
    local calls, faults = {}, {}
    for _, a in ipairs(w.cfg.arrays) do
        for _, node in ipairs(a.nodes) do
            local id = node.address
            calls[id] = { tier = 0, count = 0 }
            local n = w.components[id]
            local tier, count = n.getProvidedTier, n.getAvailableNanites
            n.getProvidedTier = function()
                calls[id].tier = calls[id].tier + 1
                if faults[id] == 'none' then
                    return nil
                end
                return tier()
            end
            n.getAvailableNanites = function()
                calls[id].count = calls[id].count + 1
                return faults[id] == 'zero' and 0 or count()
            end
        end
    end
    return calls, faults
end

-- These totals were measured on the preceding version: three loads (one
-- cached), three returns, with no quantity read for the cached load.
for _, arrays in ipairs({ 1, 6, 10, 30 }) do
    local w = make(arrays, 0, { nodes = 16 })
    local calls = observe(w)
    for _, a in ipairs(w.cfg.arrays) do
        change(w, a, 1)
        change(w, a, nil)
        change(w, a, 1)
        change(w, a, nil)
        change(w, a, 2)
        change(w, a, nil)
        local first = calls[a.nodes[1].address]
        assert(first.tier == 3 and first.count == 5)
        for i = 2, #a.nodes do
            local other = calls[a.nodes[i].address]
            assert(other.tier == 0 and other.count == 0)
        end
    end
    assert(w.moves == 12 * arrays and w.saves == 0)
    print('  PASS ' .. arrays .. ' arrays: unchanged normal bee calls, cached loads and returns')
end

do
    local w = make(2, 0, { nodes = 3 })
    local a = w.cfg.arrays[1]
    local calls, faults = observe(w)
    faults['a1:n1'] = 'none'
    change(w, a, 1)
    assert(w.e.beeNodes.a1 == 2 and calls['a1:n1'].tier == 1)
    assert(calls['a1:n3'].tier == 0 and calls['a2:n1'].tier == 0)
    change(w, a, nil)
    assert(calls['a1:n2'].count == 2, 'zero on return is success, not a fallback trigger')

    faults['a1:n1'] = nil
    change(w, a, 1)
    assert(w.e.beeNodes.a1 == 2 and calls['a1:n1'].tier == 1)
    assert(calls['a1:n2'].count == 2, 'the remembered representative still uses the count cache')
    change(w, a, nil)

    faults['a1:n2'] = 'zero'
    change(w, a, 2)
    assert(w.e.beeNodes.a1 == 3 and w.state.arrays.a1.counts[2] == 32)
    local before = U.copy(calls)
    faults['a1:n2'] = nil
    change(w, a, nil)
    change(w, a, 1)
    assert(w.e.beeNodes.a1 == 3)
    assert(U.equal(calls['a1:n1'], before['a1:n1']))
    assert(U.equal(calls['a1:n2'], before['a1:n2']))
    assert(calls['a1:n3'].tier == before['a1:n3'].tier + 1)
    assert(calls['a1:n3'].count == before['a1:n3'].count + 1)
end
print(
    '  PASS missing tier and zero count select a healthy node and retain it after the old node recovers'
)

do
    local w = make(2, 0, { nodes = 3 })
    local a = w.cfg.arrays[1]
    local calls, faults = observe(w)
    for _, n in ipairs(a.nodes) do
        faults[n.address] = 'none'
    end
    w.e:bees(a, w.state.arrays.a1, 1)
    w.advance()
    for _ = 1, 12 do
        local before = 0
        for _, n in ipairs(a.nodes) do
            before = before + calls[n.address].tier
        end
        assert(not w.e:bees(a, w.state.arrays.a1, 1))
        local after = 0
        for _, n in ipairs(a.nodes) do
            after = after + calls[n.address].tier
        end
        assert(after == before + 1, 'an abnormal poll must not scan the whole array')
    end
    assert(w.state.arrays.a1.bee.phase == 'sync' and not w.e.provided.a1)
    change(w, w.cfg.arrays[2], 2)
    change(w, w.cfg.arrays[2], nil)
    faults['a1:n2'] = nil
    change(w, a, 1)
    assert(w.e.beeNodes.a1 == 2 and w.e.provided.a1 == 1)
    assert(w.moves == 6, 'failed reads must not repeat physical transfers')
end
print(
    '  PASS all unreadable nodes keep waiting one probe per poll; another array can still transfer'
)

do
    local w = make(1, 0)
    local a = w.cfg.arrays[1]
    local calls = observe(w)
    local n = w.components['a1:n1']
    local read = n.getProvidedTier
    n.getProvidedTier = function()
        return { tier = 2 }
    end
    w.e:bees(a, w.state.arrays.a1, 1)
    w.advance()
    for _ = 1, 4 do
        assert(not w.e:bees(a, w.state.arrays.a1, 1))
    end
    assert(calls['a1:n2'].tier == 0 and not w.e.provided.a1)
    n.getProvidedTier = read
    change(w, a, 1)
end
print('  PASS a readable wrong tier remains a mismatch rather than triggering a search')

for _, fault in ipairs({ 'none', 'zero' }) do
    local w = make(1, 0, { nodes = 16 })
    local a = w.cfg.arrays[1]
    change(w, a, 1)
    local calls, faults = observe(w)
    faults['a1:n1'] = fault
    w.boot()
    assert(w.e.beeNodes.a1 == 2 and w.e.provided.a1 == 1)
    assert(w.state.arrays.a1.lease[1] and w.state.arrays.a1.counts[1] == 32)
    assert(calls['a1:n1'].tier == 1 and calls['a1:n2'].count == 1)
    change(w, a, nil)
    faults['a1:n1'] = nil
    w.boot()
    change(w, a, 1)
    assert(w.e.beeNodes.a1 == 1, 'a new run rebuilds the representative from actual nodes')
    assert(w.saves == 0, 'representative selection must not be written to disk')
end
print(
    '  PASS startup discovers installed bees through another node and rebuilds the choice on restart'
)

do
    local w = make(2, 0, { nodes = 3 })
    w.share({ { tier = 1, slot = 1, count = 32 }, { tier = 2, slot = 2, count = 32 } })
    local _, faults = observe(w)
    faults['a1:n1'], faults['a2:n1'] = 'none', 'none'
    w.boot()
    for i, a in ipairs(w.cfg.arrays) do
        assert(not w.e:bees(a, w.state.arrays[a.address], i))
    end
    w.boot()
    assert(w.e.ports, 'two different grades in flight must wait for actual loading')
    for _ = 1, 30 do
        w.advance()
        if w.e:resolvePorts() then
            break
        end
    end
    assert(not w.e.ports)
    for i, a in ipairs(w.cfg.arrays) do
        assert(w.state.arrays[a.address].bee.tier == i)
        change(w, a, i)
        assert(w.e.beeNodes[a.address] == 2 and w.e.provided[a.address] == i)
    end
    w.e:requestStop()
    for _ = 1, 30 do
        if w.e:drain() then
            break
        end
        w.tick()
    end
    assert(w.e:drain() and w.moves == 8)
    w.assertPool()
end
print('  PASS simultaneous interrupted loads identify different tiers through alternate nodes')

local function recovering()
    local w = make(2, 64, { nodes = 16, stageTicks = 40 })
    w.share({ { tier = 1, slot = 1, count = 32 }, { tier = 2, slot = 2, count = 32 } })
    local _, faults = observe(w)
    faults['a1:n1'], faults['a2:n1'] = 'none', 'none'
    w.boot()
    return w
end
local base = recovering()
base.finish()
base.e:requestStop()
while not base.e:drain() do
    base.tick()
end
for point = 1, base.moves do
    local w = recovering()
    w.crashMove = point
    local ok, err = pcall(function()
        w.finish()
        w.e:requestStop()
        while not w.e:drain() do
            w.tick()
        end
    end)
    assert(not ok and tostring(err):find('SIMULATED POWER LOSS', 1, true))
    w.crashMove = nil
    w.boot(U.copy(w.saved))
    w.finish()
    w.e:requestStop()
    for _ = 1, 100 do
        if w.e:drain() then
            break
        end
        w.tick()
    end
    assert(w.e:drain() and w.produced == 64 and w.admitted == 64)
    assert(w.arrays.a1.bees == 0 and w.arrays.a2.bees == 0)
    w.assertPool()
end
print(
    '  PASS unreadable first nodes survive every physical transfer interruption and finish Q drain'
)
