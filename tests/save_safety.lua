local make = assert(loadfile(ROOT .. 'tests/simplified.lua'))('fixture')
local U = dofile(ROOT .. 'ma_util.lua')
local Store = dofile(ROOT .. 'ma_store.lua')
local serial = dofile(
    ROOT
        .. '../repos/OpenComputers/src/main/resources/assets/opencomputers/loot/openos/lib/serialization.lua'
)
local oldCheck = checkArg
checkArg = function() end

-- An unfinished temp file must never replace the last complete checkpoint.
do
    local disk, closed, writes, failAt = {}, 0, 0
    local open = io.open
    io.open = function(path, mode)
        if mode == 'r' then
            if not disk[path] then
                return
            end
            return {
                read = function()
                    return disk[path]
                end,
                close = function()
                    return true
                end,
            }
        end
        disk[path] = ''
        return {
            write = function(_, text)
                writes = writes + 1
                if writes == failAt then
                    error('SIMULATED DISK WRITE FAILURE')
                end
                disk[path] = disk[path] .. text
                return true
            end,
            flush = function()
                if failAt == 'flush' then
                    return nil, 'flush failed'
                end
                return true
            end,
            close = function()
                closed = closed + 1
                if failAt == 'close' then
                    return nil, 'close failed'
                end
            end,
        }
    end
    local boundaries = 0
    local store = Store.new(
        '',
        {
            rename = function(from, to)
                if failAt == 'rename' then
                    return false
                end
                disk[to], disk[from] = disk[from], nil
                return true
            end,
        },
        serial,
        function()
            boundaries = boundaries + 1
        end
    )
    local old = { phase = 'stable', count = 9007199254740991 }
    store.write('state', old)
    local stable = disk.state
    local chars = {}
    for i = 0, 255 do
        chars[#chars + 1] = string.char(i)
    end
    local binary = table.concat(chars)
    local value = { text = string.rep(binary, 40), name = '中文跨分块边界', map = {} }
    for i = 1, 128 do
        value.map[string.rep('key', 200) .. i] = { i, true, false, binary }
    end
    value.sparse = { [0] = 'zero', [1] = 'one', [4] = 'four', [12] = false }
    value.map['and'] = 17
    value.map['x\n"\\'] = 9007199254740991
    writes = 0
    store.write('state', value)
    assert(U.equal(store.read('state'), value))
    local total = writes
    for point = 1, total do
        disk.state = stable
        writes = 0
        failAt = point
        local before = closed
        assert(not pcall(store.write, 'state', value))
        assert(disk.state == stable and closed == before + 1)
    end
    for _, mode in ipairs({ 'flush', 'close', 'rename' }) do
        disk.state = stable
        failAt = mode
        assert(not pcall(store.write, 'state', value) and disk.state == stable)
    end
    failAt = nil
    disk.state = stable
    local cycle = {}
    cycle.self = cycle
    assert(not pcall(store.write, 'state', cycle) and disk.state == stable)
    store.write('state', value)
    assert(U.equal(store.read('state'), value) and boundaries > 0)
    io.open = open
    print(
        '  PASS streamed state round-trips binary/NBT/Chinese/large integers; '
            .. total
            .. ' write failures preserve old checkpoint'
    )
end
checkArg = oldCheck

-- A disconnected node cannot prevent other nodes from being stopped and state saved.
do
    local w = make(6, 0, { nodes = 16 })
    local lost = w.cfg.arrays[1].nodes[1].address
    local proxy = w.e.io.proxy
    local stopped = 0
    for address in pairs(w.nodes) do
        local set = w.components[address].setWorkAllowed
        w.components[address].setWorkAllowed = function(v)
            stopped = stopped + 1
            return set(v)
        end
    end
    w.e.io.proxy = function(address)
        assert(address ~= lost, 'removed node')
        return proxy(address)
    end
    local saves = w.saves
    w.e:pause()
    assert(stopped == 95 and w.saves == saves + 1)
    local attempts = 0
    w.e.io.save = function()
        attempts = attempts + 1
        error('original disk error')
    end
    assert(not pcall(w.e.save))
    w.e:pause()
    assert(attempts == 1, 'cleanup retried a failed save')
end
print('  PASS cleanup tolerates missing proxies and does not retry a failed save')

-- Save failures must escape per-array/channel isolation before any later work is dispatched.
for _, where in ipairs({ 'array', 'channel' }) do
    local w = make(2, 0)
    w.e.ready, w.e.recovered = true, true
    w.e.io.save = function()
        error('disk failed in ' .. where)
    end
    w.e[where] = function(e)
        e.save()
    end
    local ok, err = pcall(w.e.tick, w.e)
    assert(not ok and tostring(err):find('disk failed in ' .. where, 1, true))
    assert(w.e.saveFailed)
end
print('  PASS save errors stop dispatch instead of being isolated as machine faults')

-- Idle state is not dirty; actual recoverable timers and generator progress are.
do
    local w = make(6, 0, { nodes = 16 })
    w.addFeed('raw', 1)
    w.boot()
    for _ = 1, 200 do
        w.tick()
    end
    w.e.save()
    local saves = w.saves
    for _ = 1, 2000 do
        w.tick()
        if w.time % 100 == 0 and w.e.dirty then
            w.e.save()
        end
    end
    assert(w.saves == saves, 'stable idle state kept saving')
end
print('  PASS stable idle state performs no periodic writes')

-- Long fluid waits back off without slowing normal short IO returns.
do
    local w = make(1, 0)
    w.addFeed('raw', 1)
    w.boot()
    local f = w.cfg.feeds[1]
    local s = w.state.refill.feeds[f.id]
    s.loading = { index = 1, phase = 'io', capacity = 576 }
    local reads = 0
    local stack = w.e.log.stack
    w.e.log.stack = function(log, id, slot)
        if id == f.io and slot == 7 then
            reads = reads + 1
            return nil
        end
        return stack(log, id, slot)
    end
    for i = 0, 599 do
        w.e.now = i / 20
        w.r:receive(f)
    end
    assert(reads == 600)
    for i = 600, 799 do
        w.e.now = i / 20
        w.r:receive(f)
    end
    assert(reads == 610, 'long wait should poll once a second')
    w.e.log.stack = function(_, id, slot)
        assert(id == f.io and slot == 7)
        return { storedFluidCount = 576, remainingFluidCount = 0 }
    end
    w.e.now = 40
    w.r:receive(f)
    assert(s.loading.phase == 'back')
end
print('  PASS precache IO keeps fast initial polling then backs off to one second')

for _, count in ipairs({ 6, 10, 30 }) do
    local w = make(count, 0, { nodes = 16 })
    local a = w.cfg.arrays[1]
    local function transfer(tier)
        local saves, moves = w.saves, w.moves
        for i = 1, 100 do
            w.advance()
            w.e.now = w.time / 20
            if w.e:bees(a, w.state.arrays[a.address], tier) then
                return w.saves - saves, w.moves - moves
            end
        end
        error('transfer did not finish')
    end
    local load, lm = transfer(1)
    local unload, um = transfer(nil)
    assert(load == 6 and unload == 5 and lm == 2 and um == 2)
    print(
        '  PASS '
            .. count
            .. ' arrays: bee load '
            .. load
            .. ', unload '
            .. unload
            .. ' durable saves'
    )
end

-- The collection clock remains periodically durable when there are no other actions.
do
    local world = assert(loadfile(ROOT .. 'tests/singularities.lua'))('fixture')
    local w = world({ { kind = 1 } }, { arrays = 6, timeout = 300 })
    w.untilTrue(function()
        local b = w.state.arrays.a1.batch
        return b and b.phase == 'collect'
    end)
    w.e.save()
    for _ = 1, 100 do
        w.tick()
    end
    assert(w.e.dirty)
    w.e.save()
    local elapsed = w.saved.arrays.a1.batch.collection.elapsed
    assert(elapsed >= 4.9)
    w.time = 0
    w.boot(U.copy(w.saved))
    assert(w.state.arrays.a1.batch.collection.elapsed == elapsed)
end
print('  PASS periodic dirty tracking retains singularity collection time across uptime reset')
