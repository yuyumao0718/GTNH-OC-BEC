local function module(n)
    return dofile(ROOT .. n .. '.lua')
end
local U, I, C, Recovery =
    module('ma_util'), module('ma_intake'), module('ma_config'), module('ma_recovery')
local make = assert(loadfile(ROOT .. 'tests/simplified.lua'))('fixture')
local passed = 0
local function test(name, fn)
    fn()
    passed = passed + 1
    print('  PASS ' .. name)
end
local function output(kind)
    return {
        name = kind <= 10 and 'universalsingularities:universal.circuit.singularity'
            or 'universalsingularities:universal.circuit2.singularity',
        damage = kind <= 10 and kind - 1 or kind - 11,
        size = 1,
        label = '测试算力奇点 ' .. kind,
    }
end
local function world(stream, options)
    options = options or {}
    local w = make(options.arrays or 2, 0, { nodes = 16, stageTicks = options.stageTicks or 4 })
    local patterns = {}
    for kind = 1, 16 do
        patterns[kind] = {
            isCraftable = false,
            inputs = { { name = 'input-' .. kind, damage = 0, size = 1 } },
            outputs = {
                kind <= 15 and output(kind)
                    or { name = 'ordinary-output', damage = 0, size = 1, label = '普通订单' },
            },
        }
    end
    w.cfg.channels[1].patterns[1].slots = 16
    w.components.pattern.getInterfacePattern = function(slot)
        return patterns[slot]
    end
    w.patterns = patterns
    w.cfg.singularityWait = options.timeout or 300
    w.cfg.fieldLimit = 1000000
    w.stock.entangled_neutronium = 50000
    w.stream = stream
    w.index = 1
    w.starts = {}
    w.seen = {}
    w.taken = {}
    local advance = w.advance
    function w.advance()
        local nextOrder = w.stream[w.index]
        local cell = w.inventories.receiver.slots[1]
        if
            nextOrder
            and not w.closed
            and cell.contents == 0
            and w.time / 20 >= (nextOrder.at or 0)
        then
            w.inputName = 'input-' .. nextOrder.kind
            w.kind = nextOrder.kind
            cell.contents = nextOrder.count or 1
            cell.storedItemCount = cell.contents
            w.index = w.index + 1
            w.delivered = w.delivered + cell.contents
        end
        local old = {}
        for id, n in pairs(w.nodes) do
            old[id] = n.active
        end
        advance()
        for id, n in pairs(w.nodes) do
            if not old[id] and n.active then
                n.kind = w.kind
                if w.kind <= 15 then
                    assert(
                        n.count == 1 and n.min == 1 and n.max == 1,
                        'singularities must use one parallel per node'
                    )
                end
                w.taken[w.kind] = (w.taken[w.kind] or 0) + n.count
            end
        end
    end
    local tick = w.tick
    function w.tick()
        tick()
        for _, a in ipairs(w.cfg.arrays) do
            local s = w.state.arrays[a.address]
            local b = s.batch
            if b and b.phase == 'collect' then
                assert(not w.arrays[a.address].enabled and (not s.lease or s.bee or s.reuse))
            end
            if b and b.phase == 'run' and not w.seen[b] then
                w.seen[b] = true
                local types = {}
                for _, worker in ipairs(b.workers) do
                    local kind = worker.key and w.state.patterns[worker.key].pattern.singularity
                    if kind then
                        types[kind] = true
                    end
                end
                w.starts[#w.starts + 1] = {
                    array = a.address,
                    time = w.time / 20,
                    count = b.count,
                    types = types,
                    workers = U.copy(b.workers),
                    fixed = b.fixed,
                }
            end
            if b then
                for _, worker in ipairs(b.workers) do
                    local n = w.nodes[worker.address]
                    if n.active and worker.key then
                        assert(
                            not worker.key
                                or n.kind == w.state.patterns[worker.key].pattern.singularity,
                            'node took wrong singularity'
                        )
                    end
                end
            end
        end
    end
    function w.untilTrue(predicate, max)
        for _ = 1, max or 16000 do
            w.tick()
            for id, err in pairs(w.e.errors) do
                error(id .. ': ' .. err)
            end
            if predicate() then
                return
            end
        end
        error('condition did not become true')
    end
    function w.finish(max)
        local total = 0
        for _, entry in ipairs(w.stream) do
            total = total + (entry.count or 1)
        end
        w.untilTrue(function()
            if w.produced ~= total then
                return false
            end
            for _, s in pairs(w.state.arrays) do
                if s.batch or s.bee then
                    return false
                end
            end
            return true
        end, max)
        assert(w.produced == total and w.admitted == total and w.inputs.common == 0)
    end
    w.boot()
    return w
end
if ... == 'fixture' then
    return world
end
local function all(count)
    local stream = {}
    for i = 1, 15 do
        stream[#stream + 1] = { kind = i, count = count or 1 }
    end
    return stream
end
test('only exact registered fifteen outputs are collected, without relying on labels', function()
    for kind = 1, 15 do
        local o = output(kind)
        o.label = '任意名称'
        assert(I.singularity({ [I.key(o)] = 1 }) == kind)
    end
    assert(not I.singularity({
        [I.key({ name = 'universalsingularities:universal.circuit2.singularity', damage = 6 })] = 1,
    }))
    assert(not I.singularity({
        [I.key({ name = 'other:universal.circuit.singularity', damage = 0 })] = 1,
    }))
    assert(not I.singularity({ [I.key(output(1))] = 1, [I.key(output(2))] = 1 }))
end)
test('fifteen distinct recipes leave the sixteenth node available until timeout', function()
    local w = world(all())
    w.finish()
    assert(#w.starts == 1 and #U.keys(w.starts[1].types) == 15 and #w.starts[1].workers == 15)
    assert(w.starts[1].time >= 300 and w.starts[1].fixed)
    assert(w.state.arrays.a2.done == 0 and not w.state.arrays.a1.batch)
    for i = 1, 15 do
        assert(w.taken[i] == 1)
    end
end)
test('unequal quantities are split across batches with one recipe per node', function()
    local stream = all(2)
    stream[5].count = 7
    local w = world(stream)
    w.finish()
    assert(#w.starts == 3)
    for _, batch in ipairs(w.starts) do
        assert(batch.count <= 16)
        for _, worker in ipairs(batch.workers) do
            assert(worker.count == 1)
        end
    end
    for i = 1, 15 do
        assert(w.taken[i] == (i == 5 and 7 or 2))
    end
end)
test('default threshold is 300 seconds since successful intake, not first arrival', function()
    assert(C.defaults().singularityWait == 300)
    local w = world({ { kind = 1 }, { kind = 2, at = 290 } })
    w.untilTrue(function()
        return w.taken[2] and not w.state.admission
    end)
    local received = w.time / 20
    w.untilTrue(function()
        return #w.starts > 0
    end)
    assert(w.starts[1].time >= received + 300 and w.starts[1].time < received + 305)
    w.finish()
end)
test('ordinary orders run on other arrays and do not reset collection timeout', function()
    local w = world({ { kind = 1 }, { kind = 16, at = 3 } }, { timeout = 5 })
    local received
    w.untilTrue(function()
        local b = w.state.arrays.a1.batch
        return b and b.phase == 'collect'
    end)
    received = w.time / 20
    w.finish()
    assert(#w.starts == 2 and w.starts[1].array == 'a2')
    assert(w.starts[2].time >= received + 5 and w.starts[2].time < received + 8)
end)
test('late kinds start a new collection and are never appended to running nodes', function()
    local w = world({ { kind = 1 }, { kind = 2, at = 6 } }, { timeout = 2, stageTicks = 100 })
    w.finish()
    assert(#w.starts == 2 and w.starts[1].array ~= w.starts[2].array)
    assert(w.starts[1].types[1] and not w.starts[1].types[2])
    assert(w.starts[2].types[2] and not w.starts[2].types[1])
end)
test('repeated orders use separate nodes and refresh the inactivity timer', function()
    local w = world({ { kind = 1, count = 2 }, { kind = 1, count = 3, at = 2 } }, { timeout = 3 })
    w.untilTrue(function()
        local b = w.state.arrays.a1.batch
        return b and b.phase == 'collect' and #b.workers == 5
    end)
    local received = w.time / 20
    w.finish()
    assert(#w.starts == 1 and #w.starts[1].workers == 5)
    assert(w.starts[1].time >= received + 3 and w.starts[1].time < received + 6)
    assert(w.taken[1] == 5)
end)
test('collection uses the actual bound node capacity without a fifteen-node minimum', function()
    local w = world({ { kind = 1 } })
    for _, a in ipairs(w.cfg.arrays) do
        table.remove(a.nodes)
        table.remove(a.nodes)
    end
    w.boot()
    w.finish()
    assert(w.admitted == 1 and #w.starts[1].workers == 1)
end)

test(
    'sixteen repeated orders fill one array and the next order starts another collection',
    function()
        local stream = {}
        for i = 1, 17 do
            stream[i] = { kind = 1 }
        end
        local w = world(stream, { stageTicks = 100 })
        w.untilTrue(function()
            local a, b = w.state.arrays.a1.batch, w.state.arrays.a2.batch
            return a and a.phase == 'run' and b and b.phase == 'collect'
        end)
        assert(#w.state.arrays.a1.batch.workers == 16)
        assert(#w.state.arrays.a2.batch.workers == 1 and not w.state.arrays.a2.lease)
        assert(w.starts[1].time < 300 and w.taken[1] == 17)
        w.finish()
        assert(#w.starts == 2 and w.starts[1].array ~= w.starts[2].array)
    end
)

test('fifteen bound nodes start immediately when all are occupied by duplicate orders', function()
    local stream = {}
    for i = 1, 15 do
        stream[i] = { kind = 2 }
    end
    local w = world(stream)
    table.remove(w.cfg.arrays[1].nodes)
    w.boot()
    w.finish()
    assert(#w.starts == 1 and #w.starts[1].workers == 15 and w.starts[1].time < 300)
end)
test(
    'partial delivery does not reset inactivity until a complete new kind has been taken',
    function()
        local w = world({ { kind = 1 }, { kind = 2, at = 2 } }, { timeout = 3 })
        w.patterns[2].inputs[2] = { name = 'second-material', damage = 0, size = 1 }
        local read = w.components.receiver.getItemsInNetwork
        w.components.receiver.getItemsInNetwork = function()
            local items = read()
            if w.kind == 2 and #items > 0 and w.completeSecond then
                items[2] = { name = 'second-material', damage = 0, size = items[1].size }
            end
            return items
        end
        w.boot()
        w.untilTrue(function()
            local b = w.state.arrays.a1.batch
            return b and b.phase == 'collect'
        end)
        local received = w.time / 20
        w.untilTrue(function()
            return #w.starts > 0
        end)
        assert(w.starts[1].time < received + 6 and not w.taken[2] and w.inputs.common == 1)
        w.completeSecond = true
        w.finish()
    end
)
test('restart scans seven collected nodes and resets the wait', function()
    local w = world({ { kind = 1, count = 7 } }, { timeout = 20 })
    w.untilTrue(function()
        local b = w.state.arrays.a1.batch
        return b and b.phase == 'collect' and b.collection.elapsed >= 7
    end)
    w.e:pause()
    assert(not w.saved.arrays)
    w.time = 0
    w.boot(U.copy(w.saved))
    w.untilTrue(function()
        local b = w.state.arrays.a1.batch
        return b and b.phase == 'collect'
    end)
    local b = w.state.arrays.a1.batch
    assert(#b.workers == 7 and b.collection.elapsed == 0)
    w.finish()
    assert(w.starts[1].time >= 20 and w.starts[1].time < 24)
end)
test('editing the global timeout is compatible with collection resume', function()
    local w = world({ { kind = 1 } }, { timeout = 300 })
    w.untilTrue(function()
        local b = w.state.arrays.a1.batch
        return b and b.phase == 'collect'
    end)
    for _ = 1, 100 do
        w.tick()
    end
    w.e:pause()
    w.state.wiring = U.copy(w.cfg)
    w.cfg.singularityWait = 2
    assert(Recovery.check(w.cfg, w.cfg, U))
    w.boot(U.copy(w.state))
    w.finish()
    assert(w.taken[1] == 1)
end)
test('normal stop closes collection and finishes only the already accepted kinds', function()
    local w = world({ { kind = 1 } })
    w.untilTrue(function()
        local b = w.state.arrays.a1.batch
        return b and b.phase == 'collect'
    end)
    local time = w.time / 20
    w.e:requestStop()
    w.finish()
    assert(w.e:drain() and w.starts[1].time - time < 5)
end)
test('collection, mixed intake and processing resume at every saved checkpoint', function()
    local function fresh()
        return world(
            { { kind = 1, count = 3 }, { kind = 2, count = 40 }, { kind = 2 } },
            { timeout = 1 }
        )
    end
    local base = fresh()
    local first = base.saves
    base.finish()
    for point = first + 1, base.saves do
        local w = fresh()
        w.crashSave = point
        pcall(w.finish)
        assert(w.saves >= point)
        w.crashSave = nil
        w.boot(U.copy(w.saved))
        w.finish()
        assert(w.taken[1] == 3 and w.taken[2] == 41)
    end
    print('    singularity save checkpoints replayed: ' .. base.saves)
end)

test('a large singularity order uses other arrays and keeps remaining material locked', function()
    local w = world(
        { { kind = 1, count = 40 }, { kind = 16, count = 2 } },
        { timeout = 1, stageTicks = 80 }
    )
    w.untilTrue(function()
        local a, b = w.state.arrays.a1.batch, w.state.arrays.a2.batch
        return a and a.phase == 'run' and b and b.phase == 'run'
    end)
    assert(w.state.queue[1].count == 8 and w.inputs.common == 8)
    assert(w.closed and w.index == 2 and not w.taken[16])
    w.e:pause()
    w.boot(U.copy(w.saved))
    w.finish()
    assert(w.taken[1] == 40 and w.taken[16] == 2)
end)

test('normal exit drains the remaining split order and starts the final partial batch', function()
    local w = world({ { kind = 1, count = 40 } }, { stageTicks = 80 })
    w.untilTrue(function()
        return w.state.queue[1] and w.state.queue[1].count == 8 and not w.state.admission
    end)
    w.e:requestStop()
    w.finish()
    assert(w.e:drain() and w.taken[1] == 40 and w.time / 20 < 300)
end)
test('collected recipes use scarce shared bees and resume every physical bee transfer', function()
    local function fresh()
        local w = world(all())
        w.share({ { tier = 1, slot = 1, count = 1 }, { tier = 2, slot = 2, count = 1 } })
        w.boot()
        return w
    end
    local base = fresh()
    base.finish()
    for point = 1, base.moves do
        local w = fresh()
        w.crashMove = point
        pcall(w.finish)
        w.crashMove = nil
        w.boot(U.copy(w.saved))
        w.finish()
    end
    assert(not base.starts[1].fixed)
end)
test('global threshold is edited from any array and the small-only option is absent', function()
    local ex = dofile(ROOT .. 'examples/two-arrays.lua')
    local gpu = {
        getResolution = function()
            return 120, 38
        end,
        set = function() end,
        setForeground = function() end,
        setBackground = function() end,
    }
    local gui = module('ma_gui').new(
        gpu,
        {},
        { len = utf_len, sub = utf_sub, wlen = utf_width, char = utf_char },
        C,
        module('ma_materials')
    )
    local editor =
        module('ma_editor').new(gui, ex.cfg, ex.component, { U = U, write = function() end })
    editor:act('tab:3')
    local function threshold()
        local value
        for _, f in ipairs(editor:form()) do
            assert(f.label ~= '小单专用阵列')
            if f.label == '算力奇点等待阈值（秒）' then
                value = f
            end
        end
        return assert(value)
    end
    assert(threshold().get() == 300)
    threshold().set(120)
    editor:act('select:2')
    assert(threshold().get() == 120 and ex.cfg.singularityWait == 120)
    assert(C.validate(ex.cfg, ex.component, U))
    ex.cfg.singularityWait = 0
    assert(not pcall(C.validate, ex.cfg, ex.component, U))
end)
test('empty physical nodes are not recreated from a former collection record', function()
    local w = world({ { kind = 1 } })
    w.untilTrue(function()
        local b = w.state.arrays.a1.batch
        return b and b.phase == 'collect'
    end)
    w.e:pause()
    w.nodes['a1:n1'].active = false
    w.boot(U.copy(w.saved))
    for _ = 1, 100 do
        w.tick()
    end
    assert(not w.state.arrays.a1.batch and w.admitted == 1)
end)
test(
    'waiting and later arrivals do not repeatedly query already collected recipe metadata',
    function()
        local w = world({ { kind = 1 }, { kind = 2, at = 3 } }, { timeout = 10 })
        w.untilTrue(function()
            local b = w.state.arrays.a1.batch
            return b and b.phase == 'collect'
        end)
        local calls = 0
        local proxy = w.components['a1:n1']
        for _, name in ipairs({ 'getRecipeSteps', 'getRequiredCondensate' }) do
            local old = proxy[name]
            proxy[name] = function(...)
                calls = calls + 1
                return old(...)
            end
        end
        w.untilTrue(function()
            local b = w.state.arrays.a1.batch
            return b and b.phase == 'collect' and #b.workers == 2
        end)
        for _ = 1, 100 do
            w.tick()
        end
        assert(calls == 0 and not w.state.arrays.a1.lease)
    end
)
test('three collected kinds resume after display names, targets and timeout change', function()
    local w = world(all(), { timeout = 300 })
    w.untilTrue(function()
        local b = w.state.arrays.a1.batch
        return b and b.phase == 'collect' and #b.workers == 3
    end)
    w.e:pause()
    w.state.wiring = U.copy(w.cfg)
    w.cfg.arrays[1].name = '算力阵列'
    w.cfg.beePools[1].name = '共享蜂群'
    w.cfg.singularityWait = 120
    w.cfg.bands[1].low = 600
    w.cfg.bands[1].high = 1200
    w.cfg.fieldLimit = w.cfg.fieldLimit * 2
    -- Binding order is presentation; the same physical nodes keep their work.
    local nodes = w.cfg.arrays[1].nodes
    nodes[1], nodes[16] = nodes[16], nodes[1]
    assert(Recovery.check(w.cfg, w.cfg, U))
    w.boot(U.copy(w.state))
    w.finish()
    for kind = 1, 15 do
        assert(w.taken[kind] == 1)
    end
    assert(#w.starts == 1 and #w.starts[1].workers == 15)
end)

print(passed .. ' singularity test groups passed')
