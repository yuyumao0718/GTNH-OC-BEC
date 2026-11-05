-- Diagnostic only: run the uploaded controller and current engine on identical mock hardware.
local U = dofile(ROOT .. 'ma_util.lua')
local baseWorld = assert(loadfile(ROOT .. 'tests/spec.lua'))('fixture')
local B = {}
local fluid = 'entangled_neutronium'
local sync = {
    getRequiredCondensate = true,
    getConsumedCondensate = true,
    getProvidedTier = true,
    getAvailableNanites = true,
    getParallelRecipesInProgress = true,
    getRecipeSteps = true,
    getState = true,
    setMinParallel = true,
    setMaxParallel = true,
    setSpeedDivisor = true,
    getStoredCondensate = true,
    getFieldStrength = true,
    setFieldStrength = true,
    getCondensateFilterCount = true,
    getCondensateFilters = true,
    getCondensateFilterAt = true,
    setCondensateFilterAt = true,
    getItemsInNetwork = true,
    getFluidsInNetwork = true,
    getStackInSlot = true,
    getSlotStackSize = true,
    getInventorySize = true,
    getAllStacks = true,
    transferItem = true,
    getInterfacePattern = true,
    setItemEventSubscription = true,
}

function B.world(opt)
    local arrays = opt.arrays or 1
    local total = opt.count * (opt.jobs or 1)
    local w = baseWorld(arrays, 0, { nodes = 16 })
    w.direct(opt.count)
    w.closed = true
    w.cfg.fieldLimit = 1e12
    w.stock[fluid] = 1e10
    local route = {}
    for i, tier in ipairs(opt.tiers) do
        route[i] =
            { nanite = { tier = tier }, start = (i - 1) * opt.length, ['end'] = i * opt.length }
    end
    local length = #route * opt.length
    local cells = {}
    for tier = 1, 10 do
        cells[#cells + 1] = { tier = tier, slot = tier, count = 30720 }
        if opt.extraSets then
            cells[#cells + 1] = { tier = tier, slot = tier + 10, count = 30720 }
        end
    end
    w.share(cells)
    for _, a in ipairs(w.cfg.arrays) do
        w.inventories[a.address .. ':beeBox'].size = 27
    end
    w.addFeed('feed', 1)
    w.components.receiver.getFluidsInNetwork = function()
        return {}
    end
    for _, a in ipairs(w.cfg.arrays) do
        local filters = {}
        w.components[a.address].getName = function()
            return 'multi.bec.assembler'
        end
        local gate = w.components[a.diode]
        gate.getCondensateFilterCount = function()
            return 19
        end
        gate.getCondensateFilters = function()
            return U.copy(filters)
        end
        gate.getCondensateFilterAt = function(i)
            return filters[i]
        end
        gate.setCondensateFilterAt = function(i, value)
            filters[i] = value
        end
        for _, n in ipairs(a.nodes) do
            w.components[n.address].getRecipeSteps = function()
                return route
            end
            w.components[n.address].getWorkMaxProgress = function()
                return length
            end
            w.components[n.address].getState = function()
                return 'crafting'
            end
        end
    end
    for address, sides in pairs(w.side) do
        local device = w.components[address]
        device.getSlotStackSize = function(side, slot)
            return w.inventories[sides[side]].slots[slot] and 1 or 0
        end
        device.getAllStacks = function(side)
            local inv = w.inventories[sides[side]]
            local result = {}
            for i = 1, inv.size do
                result[i - 1] = { size = inv.slots[i] and 1 or 0 }
            end
            return {
                getAll = function()
                    return result
                end,
            }
        end
    end
    w.metrics = { calls = {}, saves = 0, events = {}, denied = 0, grantReasons = {} }
    local m = w.metrics
    local function event(kind, detail)
        m.events[#m.events + 1] = { tick = w.time, kind = kind, detail = detail }
    end
    function w.advance()
        w.time = w.time + 1
        assert(w.time < 400000, 'simulation timed out')
        local input = w.inventories.receiver.slots[1]
        if not w.closed and input.contents == 0 and w.delivered < total then
            input.contents = math.min(opt.count, total - w.delivered)
            input.storedItemCount = input.contents
            w.delivered = w.delivered + input.contents
            m.firstInput = m.firstInput or w.time
            event('delivery', input.contents)
        end
        for id, spec in pairs(w.io) do
            local slots = w.inventories[id].slots
            local cell = slots[1]
            if cell and not slots[7] then
                spec.wait = (spec.wait or 0) + 1
                if spec.wait >= (opt.ioTicks or 2) then
                    local array = w.arrays[spec.array]
                    if spec.kind == 'load' then
                        array.tier, array.bees = cell.tier, cell.storedItemCount
                        cell.storedItemCount = 0
                        event('loaded', spec.array .. ':T' .. cell.tier)
                    elseif spec.kind == 'unload' then
                        cell.storedItemCount = array.bees
                        array.bees, array.tier = 0, nil
                        event('unloaded', spec.array .. ':T' .. cell.tier)
                    else
                        error('ample-fluid fixture must not refill')
                    end
                    slots[7], slots[1], spec.wait = cell, nil, 0
                end
            end
        end
        for _, a in ipairs(w.cfg.arrays) do
            for _, nc in ipairs(a.nodes) do
                local n = w.nodes[nc.address]
                if not n.active and n.allowed and input.contents >= n.min then
                    n.count = math.min(n.max, input.contents)
                    input.contents = input.contents - n.count
                    input.storedItemCount = input.contents
                    n.active, n.progress, n.consumed, n.subtick = true, 0, 0, 0
                    w.admitted = (w.admitted or 0) + n.count
                    event('intake', nc.address .. ':' .. n.count)
                end
                local array = w.arrays[n.array]
                local step = route[math.min(#route, math.floor(n.progress / opt.length) + 1)]
                if n.active and array.enabled and array.tier and array.tier >= step.nanite.tier then
                    local divisor = n.count * 2 ^ (array.tier - step.nanite.tier)
                    n.subtick = n.subtick + array.bees
                    local delta = math.floor(n.subtick / divisor)
                    n.subtick = n.subtick - delta * divisor
                    local progress = math.min(length, n.progress + delta)
                    for _, nextStep in ipairs(route) do
                        if nextStep.start > n.progress and nextStep.nanite.tier > array.tier then
                            progress = math.min(progress, nextStep.start)
                            break
                        end
                    end
                    if n.consumed == 0 and progress > n.progress then
                        n.consumed = n.count * 144
                        assert(w.stock[fluid] >= n.consumed, 'double-allocated fluid')
                        w.stock[fluid] = w.stock[fluid] - n.consumed
                        m.firstWork = m.firstWork or w.time
                        event('work', nc.address)
                    end
                    n.progress = progress
                    if progress >= length then
                        n.active = false
                        w.produced = w.produced + n.count
                        event('complete', nc.address .. ':' .. n.count)
                        if w.produced == total then
                            m.lastOutput, m.movesAtOutput = w.time, w.moves
                            m.callsAtOutput = U.copy(m.calls)
                            m.savesAtOutput = m.saves
                        end
                    end
                end
            end
        end
        if input.contents ~= w.lastInput and w.subscribed then
            w.signals[#w.signals + 1] = { 'network_item_changed', 'receiver' }
        end
        w.lastInput = input.contents
    end
    function w.elapse(ticks)
        for _ = 1, ticks do
            w.advance()
        end
    end
    local clock = 0
    function w.elapsed(seconds)
        clock = math.max(clock, w.time / 20) + seconds
        while (w.time + 1) / 20 <= clock + 1e-8 do
            w.advance()
        end
    end
    function w.resetMetrics()
        m.calls = {}
        m.saves = 0
    end
    for address, component in pairs(w.components) do
        for name, fn in pairs(component) do
            component[name] = function(...)
                m.calls[name] = (m.calls[name] or 0) + 1
                if sync[name] then
                    w.elapse(opt.syncTicks or 0)
                end
                local ret = table.pack(fn(...))
                if name == 'setOutput' and (...) ~= nil and select(2, ...) == 0 and not m.ready then
                    m.ready = w.time
                    w.resetMetrics()
                end
                return table.unpack(ret, 1, ret.n)
            end
        end
    end
    w.total, w.event = total, event
    return w
end

function B.current(opt, variant)
    local w = B.world(opt)
    w.boot()
    local oldSave = w.e.io.save
    w.e.io.save = function(s)
        w.metrics.saves = w.metrics.saves + 1
        oldSave(s)
        w.elapsed(opt.saveMs and opt.saveMs / 1000 or 0)
    end
    local grant = w.e.grant
    w.e.grant = function(e, b)
        local ok = grant(e, b)
        if not ok then
            w.metrics.denied = w.metrics.denied + 1
            local why = not e.U.fits(e.free, b.reserve) and 'stock' or 'snapshot'
            w.metrics.grantReasons[why] = (w.metrics.grantReasons[why] or 0) + 1
        end
        return ok
    end
    if variant then
        variant(w)
    end
    for _ = 1, 100000 do
        w.tick()
        assert(not next(w.e.errors), next(w.e.errors) and select(2, next(w.e.errors)))
        local done = 0
        for _, s in pairs(w.state.arrays) do
            done = done + s.done
        end
        if done == w.total then
            w.e:requestStop()
            if w.e:drain() then
                w.metrics.idle = w.time
                break
            end
        end
    end
    assert(w.produced == w.total and w.admitted == w.total and w.metrics.idle)
    assert(w.stock[fluid] == 1e10 - w.total * 144)
    return w
end

function B.legacy(opt)
    assert((opt.arrays or 1) == 1)
    local w = B.world(opt)
    local base = ROOT .. '.tmp/user-cache-reference/'
    local files, serials, serial = {}, {}, 0
    local cfg = {
        patterns = { 'pattern' },
        patternSlots = 1,
        buffer = 'receiver',
        gate = 'redstone',
        gateSide = 0,
        storage = 'storage',
        fieldLimit = 1e12,
        generator = 'feed:g1',
        diode = 'a1:diode',
        refill = 'feed:transposer',
        refillSide = 1,
        transposer = 'a1:transposer',
        chestSide = 0,
        loadSide = 1,
        unloadSide = 2,
        cells = {},
        assembler = 'a1',
        parallelLimit = opt.parallelLimit or 0,
        transferTimeout = 30,
        nodes = {},
        bands = {
            {
                source = 'molten.neutronium',
                condensate = fluid,
                unit = 144,
                low = 500,
                high = 1000,
                side = 0,
                slot = 1,
            },
        },
    }
    for _, n in ipairs(w.cfg.arrays[1].nodes) do
        cfg.nodes[#cfg.nodes + 1] = n.address
    end
    for i = 1, 10 do
        cfg.cells[i] = { slot = i }
    end
    local ser = {
        serialize = function(t)
            serial = serial + 1
            local key = tostring(serial)
            serials[key] = U.copy(t)
            return key
        end,
        unserialize = function(key)
            return U.copy(serials[key])
        end,
    }
    files[base .. 'bec.cfg'] = ser.serialize(cfg)
    local env = setmetatable({}, { __index = _G })
    local errors = {}
    env.io = {
        open = function(path, mode)
            if mode == 'r' then
                if not files[path] then
                    return
                end
                return {
                    read = function()
                        return files[path]
                    end,
                    close = function()
                        return true
                    end,
                }
            end
            w.metrics.saves = w.metrics.saves + 1
            w.elapsed(opt.saveMs and opt.saveMs / 1000 or 0)
            return {
                write = function(_, value)
                    files[path] = value
                    return true
                end,
                flush = function()
                    return true
                end,
                close = function()
                    return true
                end,
            }
        end,
        stderr = {
            write = function(_, value)
                errors[#errors + 1] = value
            end,
        },
    }
    local modules = {
        component = {
            type = function(a)
                return w.components[a] and 'mock'
            end,
            proxy = function(a)
                return assert(w.components[a], a)
            end,
            isAvailable = function()
                return false
            end,
        },
        computer = {
            uptime = function()
                return w.time / 20
            end,
            realTime = function()
                return w.time / 20
            end,
        },
        filesystem = {
            path = function()
                return base
            end,
            remove = function(path)
                files[path] = nil
                return true
            end,
            rename = function(a, b)
                files[b], files[a] = files[a], nil
                return true
            end,
        },
        shell = {
            resolve = function()
                return base .. 'bec.lua'
            end,
        },
        term = { clear = function() end },
        unicode = {},
        serialization = ser,
        event = {
            pull = function(seconds)
                if w.produced == w.total and not w.quit then
                    w.quit = true
                    return 'key_down', 'keyboard', 113, 0
                end
                w.elapse(
                    math.max((opt.syncTicks or 0) == 0 and 1 or 0, math.ceil((seconds or 0) * 20))
                )
            end,
        },
    }
    env.require = function(name)
        return assert(modules[name], name)
    end
    env.dofile = function(path)
        return assert(loadfile(path, 't', env))()
    end
    env.print = function() end
    assert(loadfile(base .. 'bec.lua', 't', env))('run')
    assert(#errors == 0, table.concat(errors, '\n'))
    assert(w.produced == w.total and w.admitted == w.total)
    assert(w.stock[fluid] == 1e10 - w.total * 144)
    for _, cell in ipairs(w.sharedCells) do
        assert(cell.storedItemCount == 30720)
    end
    w.metrics.idle = w.time
    return w
end

function B.summary(w)
    local m = w.metrics
    return {
        seconds = (m.lastOutput - m.firstInput) / 20,
        firstWork = (m.firstWork - m.firstInput) / 20,
        returnAfterOutput = (m.idle - m.lastOutput) / 20,
        moves = m.movesAtOutput,
        movesAfterReturn = w.moves,
        saves = m.savesAtOutput,
        savesAfterReturn = m.saves,
        calls = m.callsAtOutput,
        denied = m.denied,
        grantReasons = m.grantReasons,
        total = w.total,
        events = m.events,
    }
end

function B.beeCycle(mode, opt)
    local w = B.world(opt)
    local change
    if mode == 'legacy' then
        local f = assert(io.open(ROOT .. '.tmp/user-cache-reference/bec.lua', 'r'))
        local source = f:read('*a')
        f:close()
        source = source:sub(
            assert(source:find('local function move(', 1, true)),
            assert(source:find('-- Runtime wiring.', 1, true)) - 1
        )
        local cfg =
            { chestSide = 0, loadSide = 1, unloadSide = 2, cells = {}, transferTimeout = 30 }
        for i = 1, 10 do
            cfg.cells[i] = { slot = i }
        end
        local env = setmetatable({
            cfg = cfg,
            transposer = w.components['a1:transposer'],
            nodes = { w.components['a1:n1'] },
            naniteCounts = {},
            realTime = function()
                return w.time / 20
            end,
            waitFor = function(fn)
                local rounds = 0
                while not fn() do
                    w.elapse(1)
                    rounds = rounds + 1
                    assert(rounds < 100)
                end
            end,
        }, { __index = _G })
        change = assert(load(source .. '\nreturn swap', '@uploaded-swap', 't', env))()
    else
        w.boot()
        local save = w.e.io.save
        w.e.io.save = function(state)
            w.metrics.saves = w.metrics.saves + 1
            save(state)
        end
        change = function(tier)
            for _ = 1, 100 do
                if w.e:bees(w.cfg.arrays[1], w.state.arrays.a1, tier) then
                    return
                end
                w.elapse(1)
            end
            error('bee change failed')
        end
    end
    local rows = {}
    for _, tier in ipairs({ 1, 4, 1, 0 }) do
        w.resetMetrics()
        local time, moves = w.time, w.moves
        change(tier > 0 and tier or nil)
        assert((w.arrays.a1.tier or 0) == tier)
        rows[#rows + 1] = {
            target = tier,
            seconds = (w.time - time) / 20,
            moves = w.moves - moves,
            saves = w.metrics.saves,
            calls = U.copy(w.metrics.calls),
        }
    end
    assert(w.arrays.a1.bees == 0)
    return rows
end

return B
