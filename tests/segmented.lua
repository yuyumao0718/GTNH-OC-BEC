local make = assert(loadfile(ROOT .. 'tests/simplified.lua'))('fixture')
local U = dofile(ROOT .. 'ma_util.lua')
local benchmark = ... == 'benchmark'
local rows = {}
local function world(count, fast)
    local w = make(count, count * 800, { nodes = 16, stageTicks = 400 })
    w.cfg.fieldLimit = 1e12
    w.stock.entangled_neutronium = 1e11
    local cells = {}
    for tier = 1, 2 do
        for _ = 1, count do
            cells[#cells + 1] = {
                tier = tier,
                box = math.floor(#cells / 27) + 1,
                slot = #cells % 27 + 1,
                count = fast and 1e9 or 32,
            }
        end
    end
    w.share(cells)
    w.boot()
    return w
end

for _, count in ipairs({ 6, 10, 30 }) do
    for _, fast in ipairs({ false, true }) do
        local w = world(count, fast)
        local calls = {}
        for _, p in pairs(w.components) do
            for name, fn in pairs(p) do
                p[name] = function(...)
                    calls[name] = (calls[name] or 0) + 1
                    return fn(...)
                end
            end
        end
        local maxResource, maxIntake, serviced = 0, 0, 0
        local array = w.e.array
        w.e.array = function(e, a)
            if e.resourceScan then
                serviced = serviced + 1
            end
            return array(e, a)
        end
        local complete = false
        for _ = 1, 5000 do
            calls = {}
            w.tick()
            assert(not next(w.e.errors))
            local resource = calls.getConsumedCondensate or 0
            local intake = (calls.setMinParallel or 0)
                + (calls.setMaxParallel or 0)
                + (calls.getParallelRecipesInProgress or 0)
                + (calls.getRequiredCondensate or 0)
                + (calls.getRecipeSteps or 0)
            maxResource = math.max(maxResource, resource)
            maxIntake = math.max(maxIntake, intake)
            if not benchmark then
                assert(
                    resource <= 4 and (calls.setMaxParallel or 0) <= 16,
                    'resource scans stay segmented; prepare at most one whole array per pass'
                )
            end
            local done = 0
            for _, s in pairs(w.state.arrays) do
                done = done + s.done
            end
            if done == count * 800 then
                complete = true
                break
            end
        end
        assert(complete and w.produced == count * 800 and w.admitted == w.produced)
        if not benchmark and not fast then
            assert(serviced > 0, 'active arrays must still be serviced during resource scans')
        end
        rows[#rows + 1] = {
            arrays = count,
            fast = fast,
            maxResource = maxResource,
            maxIntake = maxIntake,
            serviceDuringScan = serviced,
        }
    end
end
if benchmark then
    return rows
end
print('  PASS six, ten and thirty arrays finish with bounded resource scans and whole-array intake')

for _, count in ipairs({ 6, 10, 30 }) do
    local w = world(count, true)
    for _ = 1, 1000 do
        w.tick()
        local allRunning = true
        for _, s in pairs(w.state.arrays) do
            allRunning = allRunning and s.batch and s.batch.fixed and s.batch.phase == 'run'
        end
        if allRunning then
            break
        end
    end
    local calls, progress = 0, 0
    for address in pairs(w.nodes) do
        local p = w.components[address]
        local work, read = p.hasWork, p.getWorkProgress
        p.hasWork = function()
            calls = calls + 1
            return work()
        end
        p.getWorkProgress = function()
            progress = progress + 1
            return read()
        end
    end
    local function scan(expected)
        calls = 0
        for _, a in ipairs(w.cfg.arrays) do
            local b = w.state.arrays[a.address].batch
            assert(b.phase == 'run' and b.fixed and #b.workers == 16)
            w.e:array(a)
        end
        assert(calls == expected and progress == 0)
    end
    scan(count)
    -- Node 2 finishes out of order. Node 16 remains busy after nodes 1..15 finish.
    for _, a in ipairs(w.cfg.arrays) do
        w.nodes[a.nodes[2].address].progress = 799
    end
    w.advance()
    scan(count)
    for _, a in ipairs(w.cfg.arrays) do
        for i = 1, 15 do
            w.nodes[a.nodes[i].address].progress = 799
        end
    end
    w.advance()
    scan(16 * count)
    scan(count)
    for _, a in ipairs(w.cfg.arrays) do
        assert(w.state.arrays[a.address].batch.phase == 'run' and w.arrays[a.address].bees > 0)
        assert(not w.e.observations[a.address][1] and w.e.observations[a.address][16].fast)
    end
    w.e:pause()
    w.boot(w.saved)
    w.finish(5000)
    assert(w.admitted == count * 800 and w.produced == w.admitted)
    w.assertPool()
    print('  PASS fastTier: ' .. count .. ' steady reads, staggered finishes and sparse restart')
end

do
    local w = world(6, false)
    local saved
    for _ = 1, 1000 do
        w.tick()
        if w.e.resourceScan then
            saved = U.copy(w.saved)
            local before = U.copy(w.e.reserved)
            assert(not w.e:grant({ reserve = { entangled_neutronium = 1 } }))
            assert(U.equal(before, w.e.reserved), 'partial scans cannot issue grants')
            break
        end
    end
    assert(saved)
    w.e:pause()
    assert(not w.e.resourceScan)
    w.boot(U.copy(w.saved))
    assert(not w.e.resourceScan)
    w.finish(5000)
end
print(
    '  PASS pause discards partial resource work, resume reconstructs it and never publishes partial grants'
)

do
    local w = world(6, false)
    for _ = 1, 1000 do
        w.tick()
        if w.state.admission then
            break
        end
    end
    assert(w.state.admission)
    local first = w.cfg.arrays[1].nodes[1].address
    local original = w.components[first].hasWork
    w.components[first].hasWork = function()
        return false
    end
    for _ = 1, 100 do
        w.tick()
    end
    for address, n in pairs(w.nodes) do
        assert(n.active, 'a waiting early node must not starve later nodes: ' .. address)
    end
    w.components[first].hasWork = original
    w.finish(5000)
end
print('  PASS a delayed intake node does not block preparing later arrays')

do
    local w = world(10, false)
    for _, node in ipairs(w.cfg.arrays[1].nodes) do
        -- This array finishes before other arrays while a scan is still suspended.
        w.components[node.address].getConsumedCondensate = function()
            w.advance()
            local n = w.nodes[node.address]
            return { entangled_neutronium = n.consumed }
        end
    end
    local observed = false
    for _ = 1, 5000 do
        w.tick()
        assert(not next(w.e.errors))
        if w.e.resourcesFresh then
            local actual = 0
            for _, n in pairs(w.nodes) do
                local b = w.state.arrays[n.array].batch
                if n.active and b and b.granted then
                    actual = actual + 144 * n.count - n.consumed
                end
            end
            assert((w.e.reserved.entangled_neutronium or 0) >= actual)
            assert(w.e.free.entangled_neutronium <= w.stock.entangled_neutronium - actual)
            observed = true
        end
        local done = 0
        for _, s in pairs(w.state.arrays) do
            done = done + s.done
        end
        if done == 8000 then
            break
        end
    end
    assert(observed and w.produced == 8000)
end
print('  PASS machine progress during slow scan callbacks keeps completed ledgers conservative')

for _, count in ipairs({ 6, 10, 30 }) do
    local w = make(count, 0, { nodes = 16 })
    w.share({ { tier = 1, slot = 1, count = 32 }, { tier = 2, slot = 2, count = 32 } })
    w.boot()
    local a = w.cfg.arrays[1]
    for _ = 1, 10 do
        if w.e:bees(a, w.state.arrays[a.address], 1) then
            break
        end
        w.advance()
    end
    for i = 2, count do
        local a = w.cfg.arrays[i]
        assert(not w.e:bees(a, w.state.arrays[a.address], 1))
    end
    local reads = 0
    for _, a in ipairs(w.cfg.arrays) do
        local p = w.components[a.nodes[1].address]
        local original = p.getProvidedTier
        p.getProvidedTier = function()
            reads = reads + 1
            return original()
        end
    end
    for _ = 1, 5 do
        for i = 2, count do
            local a = w.cfg.arrays[i]
            assert(not w.e:bees(a, w.state.arrays[a.address], 1))
        end
    end
    assert(reads == 0, 'known empty arrays waiting for a leased set must not reread provided tier')
    for _ = 1, 10 do
        if w.e:bees(a, w.state.arrays[a.address], nil) then
            break
        end
        w.advance()
    end
    local second = w.cfg.arrays[2]
    for _ = 1, 10 do
        if w.e:bees(second, w.state.arrays[second.address], 1) then
            break
        end
        w.advance()
    end
    assert(w.arrays[second.address].bees == 32 and reads > 0)
end
print(
    '  PASS bee waiters perform no tier reads, retain queue order and verify actual loading after a return'
)
