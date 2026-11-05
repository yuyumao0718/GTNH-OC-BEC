local function module(n)
    return dofile(ROOT .. n .. '.lua')
end
local U, C, Recovery = module('ma_util'), module('ma_config'), module('ma_recovery')
local world = assert(loadfile(ROOT .. 'tests/spec.lua'))('fixture')
local fluid = 'entangled_neutronium'
local passed = 0
local function test(name, fn)
    fn()
    passed = passed + 1
    print('  PASS ' .. name)
end
local function throws(fn)
    assert(not pcall(fn), 'expected failure')
end
local function make(arrays, count, options)
    local w = world(arrays, count, options)
    w.direct(count)
    for _, a in ipairs(w.cfg.arrays) do
        w.inputOwner[a.address] = 'common'
    end
    w.inputs.common = 0
    local advance = w.advance
    function w.advance()
        local c = w.inventories.receiver.slots[1]
        local before = c.contents
        w.inputs.common = before
        advance()
        w.inputs.common = w.inputs.common + (c.contents - before)
        c.contents = w.inputs.common
        c.storedItemCount = c.contents
    end
    w.boot()
    return w
end
if ... == 'fixture' then
    return make
end
test('one common network needs no raw transposer or array input port', function()
    local w = make(3, 99)
    assert(C.validate(w.cfg, nil, U))
    w.finish()
    for _, s in pairs(w.state.arrays) do
        assert(s.done >= 32 and s.done <= 34)
    end
    for _, a in ipairs(w.cfg.arrays) do
        assert(not a.io and not a.buffer and not a.parallelLimit)
    end
end)
test('unknown orders use all idle nodes and distribute the remainder once', function()
    for _, count in ipairs({ 1, 3, 17, 257, 32000, 100000 }) do
        local w = make(10, count, { nodes = 16 })
        w.cfg.fieldLimit = 1e9
        w.stock[fluid] = count * 144
        w.finish(3000)
        assert(w.stock[fluid] == 0)
        local min, max = math.huge, 0
        for _, n in pairs(w.nodes) do
            if n.count > 0 then
                min = math.min(min, n.count)
                max = math.max(max, n.count)
            end
        end
        assert(max - min <= 1)
        if count >= 160 then
            for _, s in pairs(w.state.arrays) do
                assert(s.done > 0)
            end
        end
    end
end)
test('one rare set per tier serves many arrays without locking admission', function()
    local w = make(6, 123)
    w.share({ { tier = 1, slot = 1, count = 1 }, { tier = 2, slot = 2, count = 1 } })
    w.boot()
    w.finish(8000)
    for _, s in pairs(w.state.arrays) do
        assert((not s.lease or s.reuse) and not s.batch and s.done > 0)
    end
end)
test('multiple colors and multiple sets preserve physical bee ownership', function()
    local w = make(6, 123)
    w.share({
        { tier = 1, box = 1, slot = 1, count = 1 },
        { tier = 1, box = 2, slot = 1, count = 32 },
        { tier = 2, box = 2, slot = 2, count = 32 },
    })
    w.boot()
    w.finish(8000)
end)
test('fastTier remains available for one-time intake', function()
    local w = make(2, 4)
    local fast = false
    for _ = 1, 2000 do
        w.tick()
        for _, s in pairs(w.state.arrays) do
            if s.batch and s.batch.fixed then
                fast = true
            end
        end
        if w.produced == 4 then
            break
        end
    end
    assert(fast)
    w.finish()
end)
test('restart at every durable write and bee transfer never duplicates intake', function()
    local function fresh()
        local w = make(3, 23)
        w.share({ { tier = 1, slot = 1, count = 1 }, { tier = 2, box = 2, slot = 1, count = 32 } })
        w.boot()
        return w
    end
    local base = fresh()
    local initial = base.saves
    base.finish(8000)
    for _, mode in ipairs({ 'Save', 'Move' }) do
        local finish = mode == 'Save' and base.saves or base.moves
        for point = (mode == 'Save' and initial + 1 or 1), finish do
            local w = fresh()
            w['crash' .. mode] = point
            pcall(w.finish, 8000)
            assert(w[mode == 'Save' and 'saves' or 'moves'] >= point)
            w.crashSave = nil
            w.crashMove = nil
            w.boot(U.copy(w.saved))
            w.finish(8000)
        end
        print('    replayed ' .. mode .. ' checkpoints: ' .. finish)
    end
end)
test('pause and resume at each tick includes intake and fastTier completion', function()
    local base = make(2, 17)
    base.finish()
    local ticks = base.time
    for point = 1, ticks do
        local w = make(2, 17)
        for _ = 1, point do
            w.tick()
        end
        w.e:pause()
        w.boot(U.copy(w.saved))
        w.finish()
    end
end)
test('normal stop drains accepted material and returns every bee', function()
    local w = make(3, 23)
    for _ = 1, 20 do
        w.tick()
    end
    w.e:requestStop()
    w.finish()
    assert(w.e:drain() and w.closed)
end)
test('capacity shortage resumes after raising field capacity without retaking material', function()
    local w = make(1, 100)
    w.cfg.fieldLimit = 1000
    w.stock[fluid] = 1000
    for _ = 1, 100 do
        w.tick()
    end
    assert(w.admitted == 100 and w.produced == 0 and not next(w.e.errors))
    w.e:pause()
    w.cfg.fieldLimit = 20000
    w.stock[fluid] = 14400
    w.boot(U.copy(w.saved))
    w.finish()
    assert(w.admitted == 100)
end)
test('unfunded batches do not prevent restart when the field can fund them in turn', function()
    local w = make(3, 18, { stageTicks = 30 })
    w.cfg.fieldLimit = 1500
    w.stock[fluid] = 1500
    w.addFeed('raw', 2)
    w.cfg.bands[1].low = 100
    w.cfg.bands[1].high = 900
    w.boot()
    for _ = 1, 200 do
        w.tick()
        if w.state.arrays.a1.batch and w.state.arrays.a1.batch.started then
            break
        end
    end
    assert(w.admitted == 18 and w.state.arrays.a2.batch and not w.state.arrays.a2.batch.granted)
    w.e:pause()
    w.boot(U.copy(w.saved))
    w.finish(10000)
end)
test('removed small-only setting does not restrict ordinary large orders', function()
    local w = make(3, 20)
    w.cfg.arrays[3].reserved = true
    w.finish()
    assert(w.state.arrays.a3.done > 0)
    for _, section in ipairs(C.schema) do
        if section.key == 'arrays' then
            for _, field in ipairs(section.fields) do
                assert(field.key ~= 'reserved')
            end
        end
    end
end)
test('a small order uses one fitting array when idle arrays have different node counts', function()
    local w = make(2, 3, { nodes = 4 })
    w.cfg.arrays[1].nodes = { w.cfg.arrays[1].nodes[1] }
    w.boot()
    w.finish()
    assert(w.state.arrays.a1.done == 0 and w.state.arrays.a2.done == 3)
end)
local function pending(fast)
    local w = make(3, 0)
    local e = w.e
    e.now = 10
    e.s.queue = { { id = 1, key = 'test', count = 100 } }
    e.s.patterns.test = {
        pattern = { label = '测试', inputs = {} },
        steps = { { tier = 1, start = 0, finish = 50 }, { tier = 2, start = 50, finish = 100 } },
    }
    for _, id in ipairs({ 'a2', 'a3' }) do
        local s = e.s.arrays[id]
        s.batch =
            { key = 'test', phase = 'run', count = 10, workers = {}, fixed = fast and 2 or nil }
        s.lease = { [2] = { box = 1, slot = 2 } }
        e.observations[id] = {}
        for j = 1, 2 do
            local address = id .. ':n' .. j
            s.batch.workers[j] = { address = address, count = 5 }
            local n = w.nodes[address]
            n.active = true
            n.progress = 80
            e.observations[id][j] = { address = address, progress = 80 }
        end
    end
    return w, e
end
local function progress(w, e, id, value)
    for j = 1, 2 do
        w.nodes[id .. ':n' .. j].progress = value
        e.observations[id][j].progress = value
    end
end
test('prediction uses real ordinary observations including gaps left by completed nodes', function()
    for _, completed in ipairs({ false, true }) do
        local w, e = pending(false)
        for _, id in ipairs({ 'a2', 'a3' }) do
            w.arrays[id].tier = 2
            w.arrays[id].bees = 32
            w.arrays[id].enabled = true
            e.held[id] = nil
            if completed then
                w.nodes[id .. ':n1'].active = false
            end
            e:array(e.byAddress[id])
        end
        local sample = e:finishSample(e.byAddress.a2, 15)
        assert(sample and sample.nodes['a2:n2'] == 80)
        assert((sample.nodes['a2:n1'] == nil) == completed)
        e:schedule()
        assert(e.finishWait and not e.s.admission)
    end
end)

local function leftoverBees()
    local w = make(1, 0)
    w.arrays.a1.tier = 1
    w.arrays.a1.bees = 32
    w.inventories['a1:beeBox'].slots[1].storedItemCount = 0
    w.state.arrays = {}
    Recovery.adopt(w.e, function(_, _, candidates)
        return candidates[1]
    end)
    assert(w.state.arrays.a1.lease and not w.state.arrays.a1.batch)
    w.boot(U.copy(w.saved))
    return w
end

test('takeover returns leftover bees before accepting the next order', function()
    local w = leftoverBees()
    for _ = 1, 100 do
        w.tick()
    end
    assert(not w.state.arrays.a1.lease and w.arrays.a1.bees == 0)
    assert(w.inventories['a1:beeBox'].slots[1].storedItemCount == 32)
    w.inventories.receiver.slots[1].contents = 1
    w.inventories.receiver.slots[1].storedItemCount = 1
    for _ = 1, 200 do
        w.tick()
    end
    assert(w.state.arrays.a1.done == 1)
end)

test('leftover bee recovery resumes at every save and physical transfer', function()
    local baseline = leftoverBees()
    local initial = baseline.saves
    local function finish(w)
        for _ = 1, 100 do
            w.tick()
        end
        assert(not w.state.arrays.a1.lease and not w.state.arrays.a1.bee)
        assert(w.arrays.a1.bees == 0 and w.inventories['a1:beeBox'].slots[1].storedItemCount == 32)
    end
    finish(baseline)
    for _, mode in ipairs({ 'Save', 'Move' }) do
        local count = mode == 'Save' and baseline.saves or baseline.moves
        for point = (mode == 'Save' and initial + 1 or 1), count do
            local w = leftoverBees()
            w['crash' .. mode] = point
            pcall(finish, w)
            assert(
                w[mode == 'Save' and 'saves' or 'moves'] >= point,
                'fault injection must reach the checkpoint'
            )
            w.crashSave, w.crashMove = nil, nil
            w.boot(U.copy(w.saved))
            finish(w)
        end
    end
    print(
        '    leftover bee recovery checkpoints: '
            .. (baseline.saves - initial)
            .. ' saves, '
            .. baseline.moves
            .. ' transfers'
    )
end)

test('prediction waits for final-stage arrays and dispatches to actual idle arrays', function()
    local w, e = pending(false)
    e:schedule()
    assert(e.finishWait and not e.s.admission)
    e.now = 11
    progress(w, e, 'a2', 86)
    progress(w, e, 'a3', 86)
    e:schedule()
    assert(e.finishWait.targets.a2 and e.finishWait.targets.a3)
    e.now = 13
    for _, id in ipairs({ 'a2', 'a3' }) do
        e.s.arrays[id].batch = nil
        e.s.arrays[id].lease = nil
    end
    e:schedule()
    assert(#e.s.admission.members == 3 and not e.finishWait)
end)
test('five-second deadline cannot extend when a prediction fails', function()
    local w, e = pending(false)
    e:schedule()
    e.now = 11
    progress(w, e, 'a2', 86)
    progress(w, e, 'a3', 86)
    e:schedule()
    e.now = 14.9
    e:schedule()
    assert(not e.s.admission)
    e.now = 15
    e:schedule()
    assert(#e.s.admission.members == 1 and e.s.arrays.a1.batch.count == 100)
end)
test('a stalled node, earlier stage or bee waiter is not predicted as finishing', function()
    for _, kind in ipairs({ 'stalled', 'early', 'bee', 'slowest' }) do
        local w, e = pending(false)
        if kind == 'early' then
            for _, id in ipairs({ 'a2', 'a3' }) do
                progress(w, e, id, 40)
            end
        elseif kind == 'bee' then
            for _, id in ipairs({ 'a2', 'a3' }) do
                e.s.arrays[id].request = { tier = 2 }
            end
        end
        e:schedule()
        if kind == 'stalled' or kind == 'slowest' then
            e.now = 11
            if kind == 'slowest' then
                for _, id in ipairs({ 'a2', 'a3' }) do
                    e.observations[id][1].progress = 99
                end
            end
            e:schedule()
        end
        assert(e.s.admission and #e.s.admission.members == 1)
    end
end)
test('small orders and an empty queue trigger no prediction callbacks', function()
    local w, e = pending(true)
    local calls = 0
    for _, n in pairs(w.components) do
        if n.getWorkProgress then
            local old = n.getWorkProgress
            n.getWorkProgress = function()
                calls = calls + 1
                return old()
            end
        end
    end
    e.s.queue = {}
    e:schedule()
    assert(calls == 0)
    e.s.queue = { { id = 2, key = 'test', count = 2 } }
    e:schedule()
    assert(calls == 0 and e.s.admission)
end)
test('ordinary prediction adds no component calls; fastTier samples only twice', function()
    for _, fast in ipairs({ false, true }) do
        local w, e = pending(fast)
        local calls = 0
        for _, n in pairs(w.components) do
            for _, name in ipairs({ 'getWorkProgress', 'hasWork' }) do
                if n[name] then
                    local old = n[name]
                    n[name] = function(...)
                        calls = calls + 1
                        return old(...)
                    end
                end
            end
        end
        e:schedule()
        local first = calls
        for i = 1, 19 do
            e.now = 10 + i * 0.05
            e:schedule()
        end
        assert(calls == first)
        e.now = 11
        progress(w, e, 'a2', 86)
        progress(w, e, 'a3', 86)
        e:schedule()
        local total = calls
        for i = 1, 79 do
            e.now = 11 + i * 0.05
            e:schedule()
        end
        assert(calls == total and total == (fast and 16 or 0))
        print('    prediction component callbacks (' .. tostring(fast) .. '): ' .. total)
    end
end)
test(
    'a saved waiting order is not assigned to busy arrays or made to wait twice after restart',
    function()
        local w, e = pending(false)
        e:schedule()
        assert(e.s.queue[1].considered)
        e.finishWait = nil
        e:schedule()
        assert(#e.s.admission.members == 1)
    end
)
test(
    'takeover preserves separate active recipes and manually confirms unknown bee ownership',
    function()
        local w = make(2, 8)
        w.share({ { tier = 1, slot = 1, count = 1 }, { tier = 2, box = 2, slot = 1, count = 1 } })
        w.boot()
        for _ = 1, 2000 do
            w.tick()
            if
                w.admitted == 8
                and w.arrays.a1.bees > 0
                and w.state.arrays.a1.batch.phase == 'run'
                and not next(w.state.moves)
            then
                break
            end
        end
        w.e:pause()
        local chosen = 0
        w.state.arrays = {}
        w.state.patterns = {}
        w.state.admission = nil
        Recovery.adopt(w.e, function(_, _, candidates)
            chosen = chosen + 1
            return candidates[1]
        end)
        assert(chosen > 0 and w.state.arrays.a1.batch.started and w.state.arrays.a1.batch.granted)
        w.boot(U.copy(w.saved))
        w.finish()
    end
)
test('resume permits unused changes but protects nodes and a pending common network', function()
    local w = make(2, 8)
    for _ = 1, 100 do
        w.tick()
        if w.state.admission then
            break
        end
    end
    w.state.wiring = U.copy(w.cfg)
    local changed = U.copy(w.cfg)
    changed.fieldLimit = changed.fieldLimit * 2
    assert(Recovery.check(changed, w.state, U, nil, module('ma_materials')))
    changed.channels[1].buffer = 'other'
    throws(function()
        Recovery.check(changed, w.state, U, nil, module('ma_materials'))
    end)
    changed = U.copy(w.cfg)
    changed.arrays[1].nodes = {}
    throws(function()
        Recovery.check(changed, w.state, U, nil, module('ma_materials'))
    end)
end)
test(
    'actual intake below the assigned quota stops safely without letting another recipe in',
    function()
        local w = make(2, 100)
        w.nodeCap = 1
        for _ = 1, 100 do
            w.tick()
        end
        assert(next(w.e.errors) and w.closed and w.produced == 0 and w.inputs.common > 0)
    end
)
test(
    'arrays release independently and different orders coexist without taking each others material',
    function()
        local w = make(3, 60, { stageTicks = 80 })
        w.deliveryBatch = 20
        local other = U.copy(w.pattern)
        other.inputs[1].name = 'other'
        other.outputs[1].name = 'other-output'
        other.outputs[1].label = '另一订单'
        w.components.pattern.getInterfacePattern = function(slot)
            if slot == 1 then
                return w.pattern
            elseif slot == 2 then
                return other
            end
        end
        w.cfg.channels[1].patterns[1].slots = 2
        w.boot()
        local advance = w.advance
        function w.advance()
            if
                not w.closed
                and w.inventories.receiver.slots[1].contents == 0
                and w.delivered >= 20
            then
                w.inputName = 'other'
            end
            local before = {}
            for id, n in pairs(w.nodes) do
                before[id] = n.active
            end
            local enabled = {}
            if w.time < 500 then
                for _, id in ipairs({ 'a2', 'a3' }) do
                    enabled[id] = w.arrays[id].enabled
                    w.arrays[id].enabled = false
                end
            end
            advance()
            for id, v in pairs(enabled) do
                w.arrays[id].enabled = v
            end
            for id, n in pairs(w.nodes) do
                if not before[id] and n.active then
                    n.recipe = w.inputName or 'input'
                end
            end
        end
        local overlap = false
        for _ = 1, 5000 do
            w.tick()
            assert(not next(w.e.errors))
            local keys = {}
            for id, s in pairs(w.state.arrays) do
                if s.batch then
                    keys[s.batch.key] = true
                    for _, worker in ipairs(s.batch.workers) do
                        local n = w.nodes[worker.address]
                        if n.active then
                            local otherOrder = w.state.patterns[s.batch.key].pattern.label
                                == '另一订单'
                            assert(
                                n.recipe == (otherOrder and 'other' or 'input'),
                                'node took a different order'
                            )
                        end
                    end
                end
            end
            if #U.keys(keys) > 1 then
                overlap = true
            end
            if w.produced == 60 then
                break
            end
        end
        assert(overlap, 'first free array must not wait for its previous peers')
        w.finish()
    end
)
test('refill continues with common input and resumes each physical transfer', function()
    local function fresh()
        local w = make(2, 40)
        w.stock[fluid] = 0
        w.addFeed('raw', 2)
        w.boot()
        return w
    end
    local base = fresh()
    base.finish(10000)
    assert(base.refills > 0)
    for point = 1, base.moves do
        local w = fresh()
        w.crashMove = point
        pcall(w.finish, 10000)
        w.crashMove = nil
        w.boot(U.copy(w.saved))
        w.finish(10000)
    end
end)
test('active recipes survive takeover even when arrays have different recipe steps', function()
    local w = make(2, 8, { stageTicks = 80 })
    for _ = 1, 2000 do
        w.tick()
        local a, b = w.state.arrays.a1, w.state.arrays.a2
        if
            a.batch
            and b.batch
            and a.batch.phase == 'run'
            and b.batch.phase == 'run'
            and not next(w.state.moves)
        then
            break
        end
    end
    w.e:pause()
    local old = w.components['a2:n1'].getRecipeSteps
    local changed = U.copy(old())
    changed[1].nanite.tier = 2
    for j = 1, 2 do
        w.components['a2:n' .. j].getRecipeSteps = function()
            return changed
        end
    end
    w.state.arrays = {}
    w.state.patterns = {}
    w.state.admission = nil
    Recovery.adopt(w.e, function(_, _, candidates)
        return candidates[1]
    end)
    local a, b = w.state.arrays.a1.batch, w.state.arrays.a2.batch
    assert(
        a.key ~= b.key and not U.equal(w.state.patterns[a.key].steps, w.state.patterns[b.key].steps)
    )
    w.boot(U.copy(w.saved))
    w.finish(5000)
end)
test(
    'a slow component callback cannot keep restarting the five-second prediction deadline',
    function()
        local w, e = pending(true)
        local elapsed = 10
        e.io.time = function()
            return elapsed
        end
        for _, n in pairs(w.components) do
            if n.getWorkProgress then
                local old = n.getWorkProgress
                n.getWorkProgress = function()
                    elapsed = elapsed + 2
                    return old()
                end
            end
        end
        e:schedule()
        assert(e.s.admission and #e.s.admission.members == 1 and elapsed <= 16)
    end
)
test(
    'sixteen-node fastTier prediction has a bounded callback count at six and ten arrays',
    function()
        for _, arrays in ipairs({ 6, 10 }) do
            local w = make(arrays, 0, { nodes = 16 })
            local e = w.e
            e.now = 10
            e.s.patterns.test = {
                pattern = { label = '测试' },
                steps = {
                    { tier = 2, start = 0, finish = 100 },
                },
            }
            e.s.queue = { { id = 1, key = 'test', count = 32000 } }
            local calls = 0
            for i = 2, arrays do
                local id = 'a' .. i
                local s = e.s.arrays[id]
                s.batch = { phase = 'run', key = 'test', fixed = 2, workers = {} }
                s.lease = { [2] = {} }
                for j = 1, 16 do
                    local addr = id .. ':n' .. j
                    s.batch.workers[j] = { address = addr, count = 1 }
                    w.nodes[addr].active = true
                    w.nodes[addr].progress = 80
                    for _, name in ipairs({ 'hasWork', 'getWorkProgress' }) do
                        local old = w.components[addr][name]
                        w.components[addr][name] = function(...)
                            calls = calls + 1
                            return old(...)
                        end
                    end
                end
            end
            e:schedule()
            e.now = 11
            for _, n in pairs(w.nodes) do
                n.progress = 86
            end
            e:schedule()
            assert(calls == (arrays - 1) * 16 * 4)
            print(
                '    '
                    .. arrays
                    .. ' arrays / 16 nodes / two fastTier samples: '
                    .. calls
                    .. ' callbacks'
            )
        end
    end
)
test('real entry preserves Q drain, Ctrl+C pause and pending refill claims', function()
    for _, action in ipairs({
        'quit',
        'interrupt',
        'pending',
        'burst',
        'mid-quit',
        'mid-interrupt',
        'mid-setup',
        'redraw',
        'slow-redraw',
        'save-interrupt',
        'save-error',
    }) do
        local w = make(1, action == 'pending' and 0 or 9, { stageTicks = 40 })
        if action == 'pending' then
            w.addFeed('raw', 1)
            w.stock[fluid] = 0
        end
        local state, engine, sent, burstAt, stopDrawAt
        local queued = {}
        local readsAfterSignal = 0
        local edits = 0
        local drawAt, redrawAt, redrawSeen
        local timedDraws = 0
        local saveErrors = 0
        local errorOutput = {}
        if action:match('^mid%-') then
            for address in pairs(w.nodes) do
                local read = w.components[address].getWorkProgress
                w.components[address].getWorkProgress = function()
                    if
                        not sent
                        and engine
                        and engine.s.arrays.a1.batch
                        and engine.s.arrays.a1.batch.phase == 'run'
                    then
                        sent = true
                        burstAt = w.time
                        queued[1] = action:sub(5)
                    elseif sent and action == 'mid-interrupt' then
                        readsAfterSignal = readsAfterSignal + 1
                    end
                    return read()
                end
            end
        end
        local types = {}
        local function devices(fields, value)
            for _, f in ipairs(fields) do
                if f.kind == 'list' then
                    for _, v in ipairs(value[f.key]) do
                        devices(f.fields, v)
                    end
                elseif f.source and f.source:sub(1, 7) == 'device:' then
                    local kind = f.source:sub(8)
                    types[value[f.key]] = kind
                    if kind == 'assembler' or kind == 'generator' then
                        w.components[value[f.key]].getName = function()
                            return 'multi.bec.' .. kind
                        end
                    end
                end
            end
        end
        devices(C.schema, w.cfg)
        local component = {
            proxy = function(a)
                return w.components[a]
            end,
            type = function(a)
                return types[a]
            end,
            methods = function(a)
                local m = {}
                for k in pairs(w.components[a]) do
                    m[k] = true
                end
                return m
            end,
            invoke = function(a, name)
                return w.components[a][name]()
            end,
        }
        local supplied = {
            component = component,
            computer = {
                realTime = function()
                    return w.time / 20
                end,
                uptime = function()
                    return w.time / (action == 'slow-redraw' and 100 or 20)
                end,
            },
            event = {
                pull = function(timeout)
                    if #queued > 0 then
                        return table.remove(queued, 1)
                    end
                    if #w.signals > 0 then
                        return table.unpack(table.remove(w.signals, 1))
                    end
                    if timeout == 0 then
                        return
                    end
                    w.advance()
                    assert(w.time < 3000, 'entry did not exit')
                    if action == 'redraw' or action == 'slow-redraw' then
                        if not redrawAt and w.time >= 5 then
                            redrawAt = w.time
                            return 'redraw'
                        elseif not sent and w.time >= 45 then
                            sent = true
                            return 'quit'
                        end
                    elseif action == 'pending' then
                        local feed = engine and engine.s.refill.feeds.raw
                        if feed and next(feed.pending) and not feed.loading then
                            sent = true
                            return 'quit'
                        end
                    elseif
                        not sent
                        and not action:match('^mid%-')
                        and not action:match('^save%-')
                        and engine
                        and engine.s.arrays.a1.batch
                        and engine.s.arrays.a1.batch.phase == 'run'
                    then
                        sent = true
                        if action == 'burst' then
                            burstAt = w.time
                            for i = 1, 40 do
                                queued[i] = 'component_added'
                            end
                            queued[41] = 'quit'
                            queued[42] = 'quit'
                            return 'component_added'
                        end
                        return action
                    end
                end,
            },
            filesystem = {
                path = function()
                    return ROOT
                end,
            },
            shell = {
                resolve = function()
                    return ROOT .. 'bec_multi.lua'
                end,
            },
            serialization = {},
            unicode = {},
            term = { clear = function() end },
        }
        local oldRequire, oldDofile = require, dofile
        require = function(name)
            return supplied[name] or oldRequire(name)
        end
        dofile = function(path)
            if path == ROOT .. 'ma_store.lua' then
                return {
                    new = function(_, _, _, yield)
                        return {
                            read = function(name)
                                if name == 'multi.cfg' then
                                    return w.cfg
                                elseif name == 'multi.state' then
                                    return state
                                end
                            end,
                            write = function(name, value)
                                assert(name == 'multi.state')
                                if
                                    engine
                                    and value.arrays.a1.batch
                                    and value.arrays.a1.batch.phase == 'run'
                                then
                                    if action == 'save-error' then
                                        sent = true
                                        saveErrors = saveErrors + 1
                                        error('ORIGINAL SAVE FAILURE')
                                    elseif action == 'save-interrupt' and not sent then
                                        sent = true
                                        queued[1] = 'interrupt'
                                        yield()
                                        assert(
                                            not engine.stopping,
                                            'saving must not reenter runtime handling'
                                        )
                                    end
                                end
                                state = U.copy(value)
                            end,
                        }
                    end,
                }
            elseif path == ROOT .. 'ma_gui.lua' then
                return {
                    new = function()
                        return {
                            runtime = function(_, e)
                                engine = e
                                if action == 'redraw' or action == 'slow-redraw' then
                                    if redrawAt == w.time then
                                        redrawSeen = true
                                    elseif drawAt and not (e.stopping and not stopDrawAt) then
                                        assert(
                                            w.time - drawAt >= 20,
                                            'automatic redraw must wait one second'
                                        )
                                        timedDraws = timedDraws + 1
                                    end
                                    drawAt = w.time
                                end
                                if e.stopping and not stopDrawAt then
                                    stopDrawAt = w.time
                                end
                            end,
                            runtimeEvent = function(_, name)
                                return name
                            end,
                            discardInput = function()
                                return false
                            end,
                            edit = function()
                                assert(
                                    action == 'mid-setup'
                                        and not state.arrays.a1.batch
                                        and w.arrays.a1.bees == 0
                                )
                                edits = edits + 1
                                queued[1] = 'interrupt'
                                return true
                            end,
                        }
                    end,
                }
            end
            return oldDofile(path)
        end
        local oldStderr = io.stderr
        io.stderr = {
            write = function(_, text)
                errorOutput[#errorOutput + 1] = text
            end,
        }
        local ok, err = pcall(function()
            assert(loadfile(ROOT .. 'bec_multi.lua'))('run')
        end)
        require, dofile = oldRequire, oldDofile
        io.stderr = oldStderr
        assert(ok, err)
        assert(sent and engine and not next(engine.errors))
        if action == 'save-error' then
            assert(
                saveErrors == 1 and table.concat(errorOutput):find('ORIGINAL SAVE FAILURE', 1, true)
            )
            w.boot(state)
            w.finish()
        elseif action == 'pending' then
            assert(state.wiring and next(state.refill.feeds.raw.pending))
            local cfg = U.copy(w.cfg)
            cfg.feeds[1].cells[1].slot = 2
            throws(function()
                Recovery.check(cfg, state, U, component.proxy, module('ma_materials'))
            end)
        elseif
            action == 'quit'
            or action == 'burst'
            or action == 'mid-quit'
            or action == 'mid-setup'
            or action == 'redraw'
            or action == 'slow-redraw'
        then
            assert(w.produced == 9 and not state.arrays.a1.batch and w.arrays.a1.bees == 0)
            if action == 'mid-setup' then
                assert(edits == 1)
            end
            if action == 'redraw' or action == 'slow-redraw' then
                assert(
                    redrawSeen and timedDraws > 0,
                    'page input must redraw immediately between automatic frames'
                )
            end
            if action == 'burst' or action == 'mid-quit' then
                assert(
                    stopDrawAt == burstAt,
                    'queued input must be handled and drawn before another hardware tick'
                )
                assert(#queued == 0)
            end
        else
            if action == 'mid-interrupt' then
                assert(
                    readsAfterSignal == 0 and #queued == 0,
                    'Ctrl+C must stop before reading the next node'
                )
            end
            assert(
                w.produced < 9
                    and state.arrays.a1.batch
                    and state.wiring
                    and not w.arrays.a1.enabled
            )
            w.boot(state)
            w.finish()
        end
    end
end)
print(passed .. ' simplified test groups passed')
