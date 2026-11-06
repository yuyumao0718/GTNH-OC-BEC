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
test('a large order takes the first idle array even when another is about to finish', function()
    for _, fast in ipairs({ false, true }) do
        local w = make(2, 0, { nodes = 16 })
        local e = w.e
        e.s.patterns.test = {
            pattern = {},
            steps = { { tier = 1, start = 0, finish = 100 } },
        }
        e.s.queue[1] = { key = 'test', count = 32000 }
        local first, second = e.s.arrays.a1, e.s.arrays.a2
        first.batch = { phase = 'return' }
        local node = 'a2:n1'
        local active = {
            key = 'test',
            phase = 'run',
            workers = { { address = node, count = 1 } },
            fixed = fast and 1 or nil,
        }
        second.batch, second.lease = active, { [1] = true }
        e.observations.a2 = { { address = node, progress = 99 } }
        w.components[node].hasWork = function()
            error('dispatch must not poll a busy node')
        end
        w.components[node].getWorkProgress = w.components[node].hasWork
        e:schedule()
        assert(not e.s.admission and e.s.queue[1].count == 32000)

        first.batch = nil
        e:schedule()
        assert(e.s.admission and #e.s.admission.members == 1 and e.s.admission.members[1] == 'a1')
        assert(not e.s.queue[1] and second.batch == active)
        assert(#first.batch.workers == 16 and first.batch.count == 32000)
        for _, worker in ipairs(first.batch.workers) do
            assert(worker.count == 2000)
        end
    end
end)

local function leftoverBees()
    local w = make(1, 0)
    w.arrays.a1.tier = 1
    w.arrays.a1.bees = 32
    w.inventories['a1:beeBox'].slots[1].storedItemCount = 0
    w.boot()
    assert(w.state.arrays.a1.lease and not w.state.arrays.a1.batch)
    return w
end

test('takeover returns leftover bees before accepting the next order', function()
    local w = leftoverBees()
    w.e:requestStop()
    for _ = 1, 100 do
        w.tick()
    end
    assert(not w.state.arrays.a1.lease and w.arrays.a1.bees == 0)
    assert(w.inventories['a1:beeBox'].slots[1].storedItemCount == 32)
    w.boot()
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
        w.e:requestStop()
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
                and not w.state.arrays.a1.bee
            then
                break
            end
        end
        w.e:pause()
        w.boot()
        w.finish()
    end
)
test('configuration may change names but must retain active nodes', function()
    local w = make(2, 8)
    w.nodes['a1:n1'].active = true
    local changed = U.copy(w.cfg)
    changed.fieldLimit = changed.fieldLimit * 2
    assert(Recovery.check(changed, w.cfg, U, w.e.io.proxy))
    changed.arrays[1].nodes = {}
    throws(function()
        Recovery.check(changed, w.cfg, U, w.e.io.proxy)
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
        assert(
            not next(w.e.errors)
                and w.state.admission
                and w.closed
                and w.produced == 0
                and w.inputs.common > 0
        )
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
            and not w.state.arrays.a1.bee
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
    w.boot()
    for _ = 1, 10 do
        w.tick()
        if w.e.recovered then
            break
        end
    end
    local a, b = w.state.arrays.a1.batch, w.state.arrays.a2.batch
    assert(a and b and not U.equal(w.state.patterns[a.key].steps, w.state.patterns[b.key].steps))
    w.finish(5000)
end)
test('real entry preserves Q drain, Ctrl+C pause and pending refill claims', function()
    for _, action in ipairs({
        'quit',
        'interrupt',
        'pending',
        'burst',
        'mid-quit',
        'mid-interrupt',
        'mid-setup',
        'boot-quit',
        'boot-setup',
        'check-pending',
        'check-ready',
        'redraw',
        'slow-redraw',
        'save-interrupt',
        'save-error',
    }) do
        local boot = action:match('^boot%-')
        local check = action:match('^check%-')
        local w = make(
            check and 2 or 1,
            (action == 'pending' or boot or check) and 0 or 9,
            { stageTicks = 40 }
        )
        if boot then
            local node = w.nodes['a1:n1']
            node.active, node.count, node.progress = true, 1, 2
        elseif action == 'check-pending' then
            w.share({ { tier = 1, slot = 1, count = 32 }, { tier = 2, slot = 2, count = 32 } })
            for i = 1, 2 do
                local slots = w.inventories['a' .. i .. ':beeBox'].slots
                w.inventories['a' .. i .. ':load'].slots[1], slots[i] = slots[i], nil
            end
        end
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
                    if boot and not sent then
                        assert(not engine.recovered)
                        sent = true
                        return action:sub(6)
                    end
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
                                if engine and next(value.patterns) then
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
                                    (action == 'mid-setup' or action == 'boot-setup')
                                        and not engine.s.arrays.a1.batch
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
        local output, oldPrint = {}, print
        if check then
            print = function(msg)
                output[#output + 1] = msg
            end
        end
        local ok, err = pcall(function()
            assert(loadfile(ROOT .. 'bec_multi.lua'))(check and 'check' or 'run')
        end)
        print = oldPrint
        require, dofile = oldRequire, oldDofile
        io.stderr = oldStderr
        assert(ok, err)
        if not check then
            assert(sent and engine and not next(engine.errors))
        end
        if check then
            local phrase = action == 'check-pending' and '检查尚未完成' or '检查通过'
            assert(#output == 1 and output[1]:find(phrase, 1, true))
        elseif boot then
            assert(w.produced == 1 and w.arrays.a1.bees == 0)
            assert(edits == (action == 'boot-setup' and 1 or 0))
        elseif action == 'save-error' then
            assert(
                saveErrors == 1 and table.concat(errorOutput):find('ORIGINAL SAVE FAILURE', 1, true)
            )
            w.boot(state)
            w.finish()
        elseif action == 'pending' then
            assert(not state or not state.refill)
        elseif
            action == 'quit'
            or action == 'burst'
            or action == 'mid-quit'
            or action == 'mid-setup'
            or action == 'redraw'
            or action == 'slow-redraw'
        then
            assert(w.produced == 9 and not engine.s.arrays.a1.batch and w.arrays.a1.bees == 0)
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
                    readsAfterSignal < #w.cfg.arrays[1].nodes and #queued == 0,
                    'Ctrl+C must stop at the boundary of the current array'
                )
            end
            assert(w.produced < 9 and engine.s.arrays.a1.batch and not w.arrays.a1.enabled)
            w.boot(state)
            w.finish()
        end
    end
end)
print(passed .. ' simplified test groups passed')
