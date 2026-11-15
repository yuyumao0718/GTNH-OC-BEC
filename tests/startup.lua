local make = assert(loadfile(ROOT .. 'tests/simplified.lua'))('fixture')
local Core = dofile(ROOT .. 'ma_core.lua')
local Refill = dofile(ROOT .. 'ma_refill.lua')
local U = dofile(ROOT .. 'ma_util.lua')

local function measure(arrays, show)
    local w = make(arrays, arrays * 32, { nodes = 16 })
    w.cfg.fieldLimit = 1e9
    w.stock.entangled_neutronium = 1e8
    w.addFeed('raw', 1)
    local calls, stages, completed = {}, {}, {}
    for address, p in pairs(w.components) do
        for name, fn in pairs(p) do
            p[name] = function(...)
                local key = address .. ':' .. name
                calls[key] = (calls[key] or 0) + 1
                return fn(...)
            end
        end
    end
    local previous = w.e
    local io = previous.io
    if show then
        io.startup = function(stage, detail, done, total)
            assert(
                type(stage) == 'string' and (type(detail) == 'string' or type(detail) == 'table')
            )
            stages[stage] = true
            if total then
                assert(done >= 0 and done <= total)
                if done == total then
                    completed[stage] = true
                end
            end
        end
    end
    w.state = {}
    w.e = Core.new(w.cfg, w.state, io, {
        U = previous.U,
        I = previous.I,
        N = previous.N,
        M = previous.M,
        Log = dofile(ROOT .. 'ma_logistics.lua'),
    })
    w.e:start()
    w.r = Refill.new(w.e)
    for _ = 1, 100 do
        w.tick()
        if w.e.recovered and w.e.reserved then
            break
        end
    end
    assert(w.e.recovered and w.e.reserved)
    if show then
        for _, stage in ipairs({
            '读取阵列状态',
            '暂停节点取料',
            '读取处理样板',
            '检查观测阵列',
            '检查约束场',
            '读取阵列蜂群',
            '盘点蜂群元件',
            '盘点预缓存元件',
            '接管节点任务',
            '核对凝聚物库存',
        }) do
            assert(stages[stage], 'missing startup stage: ' .. stage)
        end
        assert(completed['接管节点任务'])
    end
    io.startup = nil
    w.finish()
    return calls
end

local function ready(w)
    for _ = 1, 100 do
        w.tick()
        if w.e.recovered and w.e.reserved then
            return
        end
    end
    error('startup did not finish')
end

for _, arrays in ipairs({ 1, 6, 10, 30 }) do
    local w = make(arrays, 0, { nodes = 16 })
    w.share({ { tier = 1, slot = 1 }, { tier = 2, slot = 2 } })
    local calls = {}
    for address in pairs(w.nodes) do
        local p = w.components[address]
        for _, name in ipairs({
            'hasWork',
            'getProvidedTier',
            'setMinParallel',
            'setSpeedDivisor',
            'setWorkAllowed',
        }) do
            local fn = p[name]
            p[name] = function(...)
                local key = address .. ':' .. name
                calls[key] = (calls[key] or 0) + 1
                return fn(...)
            end
        end
    end
    w.boot()
    ready(w)
    for address in pairs(w.nodes) do
        assert(calls[address .. ':hasWork'] == 1)
        assert(calls[address .. ':setWorkAllowed'] == 1)
        assert(not calls[address .. ':getProvidedTier'], 'charged cells rule out installed bees')
        assert(not calls[address .. ':setMinParallel'] and not calls[address .. ':setSpeedDivisor'])
    end
    w.e:requestStop()
    assert(w.e:drain())
    w.e:subscribe(false)
    local previous = U.copy(w.cfg)
    calls = {}
    w.cfg.singularityWait = 600
    w.boot(nil, previous)
    ready(w)
    assert(not next(calls), 'returning from setup must not reinitialize or scan drained nodes')
    print(
        '  PASS '
            .. arrays
            .. ' arrays: no startup parameter writes or empty-pool probes; drained setup return skips nodes'
    )
end

do
    local w = make(2, 0, { nodes = 16 })
    ready(w)
    w.e:requestStop()
    assert(w.e:drain())
    local previous = U.copy(w.cfg)
    table.remove(previous.arrays[2].nodes)
    local node = w.nodes['a2:n16']
    node.active, node.count, node.progress = true, 3, 1
    w.boot(nil, previous)
    ready(w)
    assert(not w.state.arrays.a1.batch)
    assert(w.state.arrays.a2.batch.count == 3, 'new bindings still require live recovery')
end
print('  PASS a changed node binding is scanned and its existing task is recovered')

for _, arrays in ipairs({ 1, 6, 10, 30 }) do
    assert(U.equal(measure(arrays, false), measure(arrays, true)))
    print(
        '  PASS '
            .. arrays
            .. ' arrays: startup progress adds no machine calls or changes to processing'
    )
end
