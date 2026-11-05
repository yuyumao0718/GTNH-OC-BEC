local function module(n)
    return dofile(ROOT .. n .. '.lua')
end
local U, I, N, Log, C =
    module('ma_util'),
    module('ma_intake'),
    module('ma_nanites'),
    module('ma_logistics'),
    module('ma_config')
local Core, R = module('ma_core'), module('ma_refill')
local mods = { U = U, I = I, N = N, Log = Log, M = module('ma_materials') }
local passed = 0
local function test(name, fn)
    fn()
    passed = passed + 1
    print('  PASS ' .. name)
end
local function throws(fn)
    assert(not pcall(fn), 'expected an error')
end
local function eq(a, b)
    assert(U.equal(a, b), 'values differ')
end
local fluid = 'entangled_neutronium'
local source = 'molten.neutronium'
local function world(arrayCount, orders, options)
    options = options or {}
    local stageTicks = options.stageTicks or 4
    local w = {
        time = 0,
        components = {},
        inventories = {},
        side = {},
        io = {},
        nodes = {},
        arrays = {},
        inputs = {},
        delivered = 0,
        produced = 0,
        moves = 0,
        saves = 0,
        stock = { [fluid] = 50000 },
        gens = {},
        feedCells = {},
        inputOwner = {},
        producedBy = {},
        signals = {},
    }
    local cfg = C.defaults()
    cfg.storage = 'storage'
    cfg.fieldLimit = 1000000
    cfg.bands = { { material = source, low = 500, high = 1000 } }
    local pattern = {
        isCraftable = false,
        inputs = { { name = 'input', damage = 0, size = 1 } },
        outputs = { { name = 'output', label = '测试产物', damage = 0, size = 1 } },
    }
    local function inventory(id, size, address, side)
        w.inventories[id] = { size = size or 16, slots = {} }
        cfg.inventories[#cfg.inventories + 1] = { id = id, transposer = address, side = side }
        if not w.side[address] then
            w.side[address] = {}
            w.components[address] = {
                getInventorySize = function(face)
                    return w.inventories[w.side[address][face]].size
                end,
                getStackInSlot = function(face, slot)
                    return w.inventories[w.side[address][face]].slots[slot]
                end,
                transferItem = function(from, to, count, ss, ts)
                    assert(count == 1 and from ~= to)
                    local a = w.inventories[w.side[address][from]].slots
                    local b = w.inventories[w.side[address][to]].slots
                    if not a[ss] or b[ts] then
                        return 0
                    end
                    b[ts], a[ss] = a[ss], nil
                    w.moves = w.moves + 1
                    if w.crashMove == w.moves then
                        error('SIMULATED POWER LOSS')
                    end
                    return 1
                end,
            }
        end
        assert(not w.side[address][side])
        w.side[address][side] = id
    end
    local function items(count)
        return count > 0 and { { name = w.inputName or 'input', damage = 0, size = count } } or {}
    end
    w.inventories.receiver = { size = 10, slots = {} }
    w.components.pattern = {
        getInterfacePattern = function(slot)
            if slot == 1 then
                return pattern
            end
        end,
    }
    w.components.receiver = {
        setItemEventSubscription = function(enabled)
            w.subscribed = enabled
        end,
        getItemsInNetwork = function()
            local c = w.inventories.receiver.slots[1]
            return items(c and c.contents or 0)
        end,
    }
    w.components.redstone = {
        setOutput = function(_, n)
            w.closed = n > 0
        end,
    }
    cfg.channels = {
        {
            id = 'lane',
            patterns = { { address = 'pattern', slots = 1 } },
            buffer = 'receiver',
            redstone = 'redstone',
            gateSide = 0,
        },
    }
    w.components.storage = {
        hasWork = function()
            return true
        end,
        isWorkAllowed = function()
            return true
        end,
        getStoredCondensate = function()
            return U.copy(w.stock)
        end,
        getFieldStrength = function()
            return cfg.fieldLimit
        end,
        setFieldStrength = function() end,
        getWorkProgress = function()
            return w.time % 3
        end,
    }
    for i = 1, arrayCount do
        local id = 'a' .. i
        local a = { enabled = false, tier = nil, bees = 0 }
        w.arrays[id] = a
        w.inputs[id] = 0
        inventory(id .. ':beeBox', 10, id .. ':transposer', 0)
        inventory(id .. ':load', 12, id .. ':transposer', 1)
        inventory(id .. ':unload', 12, id .. ':transposer', 2)
        w.inventories[id .. ':beeBox'].slots[1] = { storedItemCount = 32, tier = 1 }
        w.inventories[id .. ':beeBox'].slots[2] = { storedItemCount = 32, tier = 2 }
        w.io[id .. ':load'] = { kind = 'load', array = id }
        w.io[id .. ':unload'] = { kind = 'unload', array = id }
        w.components[id] = {
            setWorkAllowed = function(v)
                a.enabled = v
            end,
            isWorkAllowed = function()
                return a.enabled
            end,
            hasWork = function()
                return a.enabled
            end,
        }
        local filters = {}
        w.components[id .. ':diode'] = {
            hasWork = function()
                return true
            end,
            isWorkAllowed = function()
                return true
            end,
            getCondensateFilterCount = function()
                return 8
            end,
            setCondensateFilterAt = function(s, v)
                filters[s] = v
            end,
            getCondensateFilterAt = function(s)
                return filters[s]
            end,
            getCondensateFilters = function()
                return U.copy(filters)
            end,
        }
        cfg.beePools[#cfg.beePools + 1] = {
            id = id .. ':pool',
            cells = { { tier = 1, box = 1, slot = 1 }, { tier = 2, box = 1, slot = 2 } },
        }
        local ac = {
            address = id,
            enabled = true,
            diode = id .. ':diode',
            beePool = id .. ':pool',
            loadPort = id .. ':load',
            unloadPort = id .. ':unload',
            nodes = {},
            beeBoxes = {
                {
                    box = 1,
                    inventory = id .. ':beeBox',
                },
            },
        }
        for j = 1, options.nodes or 2 do
            local address = id .. ':n' .. j
            local n = {
                array = id,
                allowed = false,
                active = false,
                count = 0,
                progress = 0,
                consumed = 0,
                min = 1,
                max = 1,
            }
            w.nodes[address] = n
            ac.nodes[j] = { address = address }
            w.components[address] = {
                hasWork = function()
                    return n.active
                end,
                isWorkAllowed = function()
                    return n.allowed
                end,
                setWorkAllowed = function(v)
                    n.allowed = v
                end,
                setSpeedDivisor = function() end,
                setMinParallel = function(v)
                    n.min = v
                end,
                setMaxParallel = function(v)
                    n.max = v
                end,
                getWorkProgress = function()
                    return n.progress
                end,
                getWorkMaxProgress = function()
                    return stageTicks * 2
                end,
                getParallelRecipesInProgress = function()
                    return n.count
                end,
                getRequiredCondensate = function()
                    return { [fluid] = 144 * n.count }
                end,
                getConsumedCondensate = function()
                    return { [fluid] = n.consumed }
                end,
                getRecipeSteps = function()
                    return {
                        { nanite = { tier = w.lowTier or 1 }, start = 0, ['end'] = stageTicks },
                        {
                            nanite = { tier = w.highTier or 2 },
                            start = stageTicks,
                            ['end'] = stageTicks * 2,
                        },
                    }
                end,
                getProvidedTier = function()
                    return a.tier and { tier = a.tier }
                end,
                getAvailableNanites = function()
                    return a.bees
                end,
                getState = function()
                    if not a.enabled then
                        return 'assembler-offline'
                    end
                    if
                        not a.tier
                        or a.tier
                            < (n.progress < stageTicks and (w.lowTier or 1) or (w.highTier or 2))
                    then
                        return 'nanite-tier-too-low'
                    end
                    return 'crafting'
                end,
            }
        end
        cfg.arrays[i] = ac
    end
    function w.addFeed(id, generatorCount)
        inventory(id .. ':drive', 10, id .. ':transposer', 0)
        inventory(id .. ':io', 12, id .. ':transposer', 1)
        local cell = { storedFluidCount = 0, remainingFluidCount = 576, availableFluids = {} }
        w.inventories[id .. ':drive'].slots[1] = cell
        w.feedCells[id] = cell
        w.io[id .. ':io'] = { kind = 'refill', feed = id }
        cfg.feeds[#cfg.feeds + 1] = {
            id = id,
            io = id .. ':io',
            cells = {
                {
                    material = source,
                    slot = 1,
                    inventory = id .. ':drive',
                },
            },
        }
        for i = 1, generatorCount do
            local address = id .. ':g' .. i
            local g = { busy = false, progress = 0, amount = 0, feed = id, enabled = false }
            w.gens[address] = g
            cfg.generators[#cfg.generators + 1] = { address = address, feed = id }
            w.components[address] = {
                hasWork = function()
                    return g.busy
                end,
                getWorkProgress = function()
                    return g.progress
                end,
                setWorkAllowed = function(v)
                    g.enabled = v
                end,
            }
        end
    end
    function w.direct(batch)
        w.deliveryBatch = batch
        w.inventories.receiver.slots[1] = { storedItemCount = 0, contents = 0 }
    end
    function w.advance()
        w.time = w.time + 1
        local c = w.inventories.receiver.slots[1]
        if not w.closed and c and c.contents == 0 and w.delivered < orders then
            local count = math.min(w.deliveryBatch or 1, orders - w.delivered)
            c.contents = count
            c.storedItemCount = count
            w.delivered = w.delivered + count
        end
        for id, spec in pairs(w.io) do
            local slots = w.inventories[id].slots
            local c = slots[1]
            if c and not slots[7] then
                spec.wait = (spec.wait or 0) + 1
                local delay = (spec.kind == 'load' or spec.kind == 'unload')
                        and (options.beeIoTicks or 1)
                    or 1
                if spec.wait >= delay then
                    local a = w.arrays[spec.array]
                    if spec.kind == 'load' then
                        a.tier = c.tier
                        a.bees = c.storedItemCount
                        c.storedItemCount = 0
                        w.beeLoads = w.beeLoads or {}
                        w.beeLoads[#w.beeLoads + 1] = c.tier
                    elseif spec.kind == 'unload' then
                        c.storedItemCount = a.bees
                        a.bees = 0
                        a.tier = nil
                    elseif spec.kind == 'refill' then
                        c.storedFluidCount = 576
                        c.remainingFluidCount = 0
                        c.availableFluids = { { name = source, amount = 576 } }
                        w.refills = (w.refills or 0) + 1
                    end
                    slots[7], slots[1] = c, nil
                    spec.wait = 0
                end
            end
        end
        for _, n in pairs(w.nodes) do
            local owner = w.inputOwner[n.array] or n.array
            if not n.active and n.allowed and w.inputs[owner] >= n.min then
                n.count = math.min(n.max, w.inputs[owner], w.nodeCap or math.huge)
                w.inputs[owner] = w.inputs[owner] - n.count
                n.active = true
                n.progress = 0
                n.consumed = 0
                w.admitted = (w.admitted or 0) + n.count
            end
            local a = w.arrays[n.array]
            if
                n.active
                and a.enabled
                and a.tier
                and a.tier
                    >= (n.progress < stageTicks and (w.lowTier or 1) or (w.highTier or 2))
            then
                n.progress = n.progress + 1
                local consume = math.floor(144 * n.count * n.progress / (stageTicks * 2))
                    - n.consumed
                assert(w.stock[fluid] >= consume, 'stock was double-allocated')
                w.stock[fluid] = w.stock[fluid] - consume
                n.consumed = n.consumed + consume
                if n.progress >= stageTicks * 2 then
                    n.active = false
                    w.produced = w.produced + n.count
                    w.producedBy[n.array] = (w.producedBy[n.array] or 0) + n.count
                end
            end
        end
        for _, g in pairs(w.gens) do
            if g.busy then
                g.progress = g.progress + 1
                if g.progress == 3 then
                    w.stock[fluid] = w.stock[fluid] + g.amount
                    g.busy = false
                    g.progress = 0
                end
            elseif g.enabled then
                local c = w.inventories[g.feed .. ':drive'].slots[1]
                if c and c.storedFluidCount >= 144 then
                    g.amount = math.min(288, c.storedFluidCount)
                    c.storedFluidCount = c.storedFluidCount - g.amount
                    c.remainingFluidCount = c.remainingFluidCount + g.amount
                    g.busy = true
                    g.progress = 0
                end
            end
        end
        local cell = w.inventories.receiver.slots[1]
        local input = tostring(cell and cell.contents or 0) .. ':' .. (w.inputName or 'input')
        if input ~= w.lastInput and w.subscribed then
            w.signals[#w.signals + 1] = { 'network_item_changed', 'receiver' }
        end
        w.lastInput = input
    end
    function w.boot(state)
        w.state = state or {}
        w.e = Core.new(cfg, w.state, {
            proxy = function(a)
                return assert(w.components[a], a)
            end,
            time = function()
                return w.time / 20
            end,
            save = function(s)
                w.saves = w.saves + 1
                w.saved = U.copy(s)
                if w.crashSave == w.saves then
                    error('SIMULATED POWER LOSS')
                end
            end,
        }, mods)
        w.e:start()
        w.r = R.new(w.e)
    end
    function w.tick()
        w.advance()
        while #w.signals > 0 do
            w.e:event(table.unpack(table.remove(w.signals, 1)))
        end
        w.e:tick()
        if w.e.ready and w.e.recovered then
            w.r:tick()
        end
        if w.assertPool then
            w.assertPool()
        end
    end
    function w.finish(max)
        for _ = 1, max or 2000 do
            w.tick()
            for key, err in pairs(w.e.errors) do
                if err ~= 'intentional test stop' then
                    error(key .. ': ' .. err)
                end
            end
            local done = 0
            for _, s in pairs(w.state.arrays) do
                done = done + s.done
            end
            if done == orders then
                assert(w.produced == orders and (w.admitted or 0) == orders)
                return
            end
        end
        error('simulation did not complete')
    end
    function w.share(cells)
        local boxes = {}
        w.sharedCells = {}
        local total = 0
        local pool = { id = 'ender', cells = {} }
        cfg.beePools = { pool }
        for _, c in ipairs(cells) do
            local box = c.box or 1
            boxes[box] = boxes[box] or {}
            pool.cells[#pool.cells + 1] = { tier = c.tier, box = box, slot = c.slot }
            local cell = { tier = c.tier, storedItemCount = c.count or 32 }
            boxes[box][c.slot] = cell
            w.sharedCells[#w.sharedCells + 1] = cell
            total = total + cell.storedItemCount
        end
        for _, a in ipairs(cfg.arrays) do
            a.beePool = 'ender'
            for number, slots in pairs(boxes) do
                local access = a.beeBoxes[1]
                if number ~= 1 then
                    local id = a.address .. ':box' .. number
                    inventory(id, 27, a.address .. ':transposer', number + 1)
                    access = {
                        box = number,
                        inventory = id,
                    }
                    a.beeBoxes[#a.beeBoxes + 1] = access
                end
                w.inventories[access.inventory].slots = slots
            end
        end
        function w.assertPool()
            local occupied = {}
            local actual = 0
            for _, c in ipairs(w.sharedCells) do
                actual = actual + c.storedItemCount
            end
            for id, a in pairs(w.arrays) do
                actual = actual + a.bees
                local lease = w.state.arrays[id].lease or {}
                local count = 0
                for _, c in pairs(lease) do
                    local key = c.box .. ':' .. c.slot
                    assert(not occupied[key], 'shared box/slot double-borrowed')
                    occupied[key] = id
                    count = count + 1
                end
                assert(count <= 1, 'an array must not reserve future tiers')
                if a.bees > 0 then
                    assert(lease[a.tier], 'loaded bees lost their lease')
                end
            end
            assert(actual == total, 'shared bees were lost or duplicated')
        end
    end
    w.cfg = C.defaults(cfg)
    w.pattern = pattern
    return w
end

if ... == 'fixture' then
    return world
end

test('native solid pattern identity, partial receipts, ambiguity', function()
    local w = world(1, 0)
    local catalog = I.catalog({ w.pattern })
    local p = catalog.patterns[1]
    eq(I.identify(catalog, I.inventory(w.pattern.inputs, {})).key, p.key)
    throws(function()
        I.catalog({ w.pattern, w.pattern })
    end)
    throws(function()
        I.identify(catalog, { unknown = 1 })
    end)
    local x = U.copy(w.pattern)
    x.inputs[1].amount = 1000
    x.inputs[1].damage = nil
    throws(function()
        I.catalog({ x })
    end)
end)

test('discovery creates one page per assembler and keeps existing settings', function()
    local cfg = C.defaults()
    local list = {}
    for i = 1, 41 do
        list[#list + 1] = { 'array-' .. i, 'gt_machine' }
    end
    list[#list + 1] = { 'gen-1', 'gt_machine' }
    list[#list + 1] = { 'gen-2', 'gt_machine' }
    local component = {
        list = function()
            local i = 0
            return function()
                i = i + 1
                if list[i] then
                    return table.unpack(list[i])
                end
            end
        end,
        methods = function()
            return { getName = true }
        end,
        invoke = function(address)
            return address:sub(1, 5) == 'array' and 'multi.bec.assembler' or 'multi.bec.generator'
        end,
    }
    C.scan(component, cfg)
    assert(#cfg.arrays == 41 and #cfg.generators == 0)
    cfg.arrays[1].parallelLimit = 7
    C.scan(component, cfg)
    assert(#cfg.arrays == 41 and cfg.arrays[1].parallelLimit == 7)
end)
test('incremental node binding keeps previous arrays and filters assigned choices', function()
    local cfg = C.defaults()
    local connected = {}
    local component = {
        list = function()
            local i = 0
            return function()
                i = i + 1
                if connected[i] then
                    return connected[i], 'bec_io_node'
                end
            end
        end,
        methods = function()
            return {}
        end,
    }
    local a, b = { address = 'a', nodes = {} }, { address = 'b', nodes = {} }
    cfg.arrays = { a, b }
    for i = 1, 16 do
        connected[i] = 'node-a-' .. i
    end
    assert(C.bindNodes(cfg, a, C.scan(component, cfg)))
    assert(#a.nodes == 16 and #b.nodes == 0)
    for i = 1, 16 do
        connected[16 + i] = 'node-b-' .. i
    end
    local all = C.scan(component, cfg)
    assert(#C.unboundNodes(cfg, all) == 16)
    assert(C.bindNodes(cfg, b, all))
    assert(#b.nodes == 16)
    for _, n in ipairs(b.nodes) do
        assert(n.address:find('node-b-', 1, true) == 1)
    end
    assert(C.bindNodes(cfg, b, all))
    assert(#b.nodes == 16 and #C.unboundNodes(cfg, all) == 0)
    local c = { address = 'c', nodes = {} }
    cfg.arrays[#cfg.arrays + 1] = c
    for i = 1, 17 do
        connected[32 + i] = 'node-c-' .. i
    end
    local ok = C.bindNodes(cfg, c, C.scan(component, cfg))
    assert(not ok and #c.nodes == 0)
    a.enabled = false
    assert(#C.unboundNodes(cfg, C.scan(component, cfg)) == 17)
end)

test('state file commits replace the previous complete snapshot', function()
    local function serialize(value)
        if type(value) == 'table' then
            local result = { '{' }
            for k, v in pairs(value) do
                result[#result + 1] = '[' .. serialize(k) .. ']=' .. serialize(v) .. ','
            end
            result[#result + 1] = '}'
            return table.concat(result)
        elseif type(value) == 'string' then
            return string.format('%q', value)
        else
            return tostring(value)
        end
    end
    local store = module('ma_store').new(ROOT .. '.tmp/', { rename = rename_file }, {
        serialize = serialize,
        unserialize = function(value)
            return assert(load('return ' .. value))()
        end,
    })
    store.write('test.state', { phase = 'load', count = 1 })
    store.write('test.state', { phase = 'run', count = 2, label = '续做' })
    eq(store.read('test.state'), { phase = 'run', count = 2, label = '续做' })
end)

local Recovery = module('ma_recovery')

local function editorFor(cfg, component, write)
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
        mods.M
    )
    return module('ma_editor').new(gui, cfg, component, { U = U, write = write or function() end })
end
local function formField(editor, label)
    for _, f in ipairs(editor:form()) do
        if f.label == label then
            return f
        end
    end
    error('missing form field: ' .. label)
end
local function objectKind(editor, kind, value)
    if kind == 'fluid' then
        for i, row in ipairs(editor.fluidRows) do
            if not value or row == value then
                editor.fluidIndex = i
                break
            end
        end
        kind, value = 'fluids', nil
    end
    for i, o in ipairs(editor:objects()) do
        if o.kind == kind and (not value or o.value == value) then
            editor:act('select:' .. i)
            return
        end
    end
    error('missing object: ' .. kind)
end

test('four-page editor preserves existing IDs and paths on opening and saving', function()
    for _, file in ipairs({ 'two-arrays', 'shared-bees' }) do
        local ex = dofile(ROOT .. 'examples/' .. file .. '.lua')
        local before = U.copy(ex.cfg)
        local writes = 0
        local editor = editorFor(ex.cfg, ex.component, function(cfg)
            eq(cfg, before)
            writes = writes + 1
        end)
        for tab = 1, 4 do
            editor:act('tab:' .. tab)
            for i in ipairs(editor:objects()) do
                editor:act('select:' .. i)
                editor:form()
                editor:draw()
            end
        end
        eq(ex.cfg, before)
        editor:act('save')
        assert(editor.saved and writes == 1, editor.message)
    end
end)

test('box grid changes only selected slots and preserves borrowed-cell identities', function()
    local ex = dofile(ROOT .. 'examples/shared-bees.lua')
    local editor = editorFor(ex.cfg, ex.component)
    editor:act('tab:2')
    objectKind(editor, 'box')
    local pool = editor:object().value
    local original = U.copy(pool.cells)
    editor:act('slot:25')
    editor:act('slot:26')
    editor.grade = 10
    editor:act('register')
    assert(#pool.cells == #original + 2)
    for i, c in ipairs(original) do
        eq(c, pool.cells[i])
    end
    assert(next(editor.selected) == nil)
    editor:act('unregister')
    assert(#pool.cells == #original + 2)
    editor:act('slot:25')
    editor:act('slot:26')
    editor:act('unregister')
    eq(pool.cells, original)
    assert(next(editor.selected) == nil)
    editor:draw()
end)

test(
    'door choices exclude assigned devices including disabled arrays and never choose an arbitrary candidate',
    function()
        local ex = dofile(ROOT .. 'examples/two-arrays.lua')
        local a, b = ex.cfg.arrays[1], ex.cfg.arrays[2]
        a.enabled = false
        b.diode = ''
        local editor = editorFor(ex.cfg, ex.component)
        local free = C.unboundDoors(ex.cfg, editor.devices)
        assert(#free == 1 and free[1].address == 'GATE-B')
        editor:doorPicker(b)
        assert(b.diode == 'GATE-B' and not editor.popup)
        b.diode = ''
        editor.devices[#editor.devices + 1] =
            { address = 'GATE-C', kind = 'bec_diode', methods = {} }
        local originalScan = C.scan
        C.scan = function()
            return editor.devices
        end
        editor:doorPicker(b)
        C.scan = originalScan
        assert(b.diode == '' and #editor.popup.options == 2)
        editor:act('pick:2')
        assert(b.diode == 'GATE-C')
        assert(a.diode == 'GATE-A')
    end
)

test('configuration structure errors do not replace the supplied content with defaults', function()
    local cfg = { arrays = 'invalid', storage = 'KEEP' }
    throws(function()
        C.defaults(cfg)
    end)
    assert(cfg.arrays == 'invalid' and cfg.storage == 'KEEP')
    local ex = dofile(ROOT .. 'examples/two-arrays.lua')
    ex.cfg.batchSeconds = 123
    C.defaults(ex.cfg)
    C.validate(ex.cfg, ex.component, U)
end)

test('direct transfer directions are shared by reading and moving cells', function()
    local ex = dofile(ROOT .. 'examples/two-arrays.lua')
    local cfg = ex.cfg
    local editor = editorFor(cfg, ex.component)
    editor:position(editor:inventory('bees-A'), 'TA', 5)
    assert(editor:inventory('bees-A').side == 5)
    editor:act('tab:1')
    objectKind(editor, 'feed')
    formField(editor, '主网流体转运 ME-IO 端口方向').set(3)
    assert(editor:inventory(cfg.feeds[1].io).side == 3)
    C.validate(cfg, ex.component, U)
end)

test(
    'refreshing a selector keeps offline bindings and does not discard unchecked choices',
    function()
        local ex = dofile(ROOT .. 'examples/two-arrays.lua')
        local editor = editorFor(ex.cfg, ex.component)
        local a = ex.cfg.arrays[1]
        local original = U.copy(a.nodes)
        editor.devices = {}
        editor:nodePicker(a)
        assert(#editor.popup.options == 16)
        editor:act('apply')
        eq(a.nodes, original)
        editor:nodePicker(a)
        editor:draw()
        local selectedObject = editor.pos
        editor:act('down')
        assert(editor.pos == selectedObject)
        editor:act('up')
        editor:act('pick:1')
        editor:act('refresh')
        assert(editor.popup.checked[original[1].address] == false)
        editor:act('back')
        eq(a.nodes, original)
        editor.devices = {}
        editor:patternPicker(ex.cfg.channels[1])
        editor:act('apply')
        assert(#ex.cfg.channels[1].patterns == 2)
    end
)

test(
    'setup requests explicit reconfiguration on unreadable files without overwriting the saved configuration',
    function()
        for _, answer in ipairs({ '', 'new' }) do
            local writes = {}
            local entered = false
            local supplied = {
                component = {},
                computer = {
                    realTime = function()
                        return 0
                    end,
                },
                event = {},
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
            local oldRequire, oldDofile, oldRead = require, dofile, io.read
            require = function(name)
                return supplied[name] or oldRequire(name)
            end
            io.read = function()
                return answer
            end
            dofile = function(path)
                if path == ROOT .. 'ma_store.lua' then
                    return {
                        new = function()
                            return {
                                read = function()
                                    error('unreadable test configuration')
                                end,
                                write = function(name, value)
                                    writes[name] = value
                                end,
                            }
                        end,
                    }
                elseif path == ROOT .. 'ma_gui.lua' then
                    return {
                        new = function()
                            return {
                                edit = function(_, cfg)
                                    entered = true
                                    assert(#cfg.arrays == 0)
                                    return false
                                end,
                            }
                        end,
                    }
                end
                return oldDofile(path)
            end
            local ok, err = pcall(function()
                assert(loadfile(ROOT .. 'bec_multi.lua'))('setup')
            end)
            require, dofile, io.read = oldRequire, oldDofile, oldRead
            assert(ok, err)
            assert(not writes['multi.cfg'] and entered == (answer == 'new'))
            assert((writes['multi.setup'] ~= nil) == (answer == 'new'))
        end
    end
)

test(
    'unselected and offline entanglers remain explicitly selectable without changing feeds',
    function()
        local ex = dofile(ROOT .. 'examples/two-arrays.lua')
        local editor = editorFor(ex.cfg, ex.component)
        local feeds = U.copy(ex.cfg.feeds)
        editor:act('tab:1')
        editor.devices = {}
        local checkbox = formField(editor, '启用 GEN-1（离线）')
        checkbox.set(false)
        assert(#ex.cfg.generators == 1)
        eq(ex.cfg.feeds, feeds)
        editor:act('refresh')
        assert(#ex.cfg.generators == 1)
        formField(editor, '启用 GEN-1').set(true)
        assert(#ex.cfg.generators == 2)
        C.validate(ex.cfg, ex.component, U)
    end
)

test(
    'adding another shared box inherits each array transposer and its existing two ports',
    function()
        local ex = dofile(ROOT .. 'examples/shared-bees.lua')
        local cfg = ex.cfg
        local editor = editorFor(cfg, ex.component)
        local pool = cfg.beePools[1]
        pool.cells[#pool.cells + 1] = { box = 3, slot = 1, tier = 4 }
        for i, a in ipairs(cfg.arrays) do
            editor:act('tab:3')
            editor:act('select:' .. i)
            local load, unload = editor:beePort(a, 'load'), editor:beePort(a, 'unload')
            formField(editor, '箱子 3 的方向').set(4)
            local box = editor:beeBox(a, 3)
            assert(editor:inventory(box.inventory).transposer == load.transposer)
            assert(a.loadPort == load.id and a.unloadPort == unload.id)
        end
        C.validate(cfg, ex.component, U)
    end
)

test('cancelling new feed cells leaves no incomplete orphan records', function()
    local ex = dofile(ROOT .. 'examples/two-arrays.lua')
    local cfg = ex.cfg
    local editor = editorFor(cfg, ex.component)
    editor:act('tab:1')
    objectKind(editor, 'fluid', editor.fluidRows[2])
    local label = '启用预缓存'
    local inventories = #cfg.inventories
    formField(editor, label).set(true)
    formField(editor, label).set(false)
    assert(#cfg.inventories == inventories)
    editor:act('tab:4')
    editor:act('add')
    editor:act('delete')
    assert(#cfg.channels == 1 and #cfg.inventories == inventories)
    C.validate(cfg, ex.component, U)
end)

test('single precache transposer serves two drives with fixed fluid slots', function()
    local ex = dofile(ROOT .. 'examples/two-arrays.lua')
    local cfg = ex.cfg
    local editor = editorFor(cfg, ex.component)
    local feed = cfg.feeds[1]
    local oldInventory = feed.cells[1].inventory
    editor:act('tab:1')
    objectKind(editor, 'fluid', editor.fluidRows[11])
    formField(editor, '启用预缓存').set(true)
    local second = editor:inventory(feed.cells[2].inventory)
    local first = editor:inventory(oldInventory)
    assert(first.side == 0 and second.side == 2 and feed.cells[2].slot == 1)
    assert(first.transposer == 'TF' and second.transposer == 'TF')
    objectKind(editor, 'feed')
    formField(editor, '第二台流体驱动器方向').set(3)
    second = editor:inventory(feed.cells[2].inventory)
    assert(second.side == 3 and first.side == 0)
    formField(editor, '流体转运器').set('TB')
    formField(editor, '主网流体转运 ME-IO 端口方向').set(5)
    assert(#editor:form() == 6)
    for _, cell in ipairs(feed.cells) do
        assert(editor:inventory(cell.inventory).transposer == 'TB')
    end
    assert(editor:inventory(feed.io).side == 5)
    assert(feed.cells[1].inventory == oldInventory)
    C.validate(cfg, ex.component, U)
end)

test('new setup has one receiver and lazy single supply without adding unused hardware', function()
    local ex = dofile(ROOT .. 'examples/two-arrays.lua')
    local cfg = ex.cfg
    cfg.feeds = {}
    cfg.generators = {}
    local editor = editorFor(cfg, ex.component)
    editor:act('tab:1')
    objectKind(editor, 'feed')
    editor:form()
    assert(#cfg.feeds == 0)
    editor:act('add')
    assert(#cfg.feeds == 0)
    formField(editor, '流体转运器').set('TF')
    formField(editor, '主网流体转运 ME-IO 端口方向').set(1)
    objectKind(editor, 'generators')
    formField(editor, '启用 GEN-1').set(true)
    formField(editor, '启用 GEN-2').set(true)
    assert(
        #cfg.feeds == 1
            and cfg.generators[1].feed == cfg.feeds[1].id
            and cfg.generators[2].feed == cfg.feeds[1].id
    )
    objectKind(editor, 'fluid', editor.fluidRows[1])
    formField(editor, '启用预缓存').set(true)
    editor:act('tab:4')
    editor:act('add')
    assert(#cfg.channels == 1)
    C.validate(cfg, ex.component, U)
end)

test('default configuration names are Chinese in fields and selectors', function()
    local ex = dofile(ROOT .. 'examples/two-arrays.lua')
    local editor = editorFor(ex.cfg, ex.component)
    editor:act('tab:2')
    objectKind(editor, 'pool')
    assert(editor:value(formField(editor, '蜂群池名称')) == '蜂群池 1')
    local pool = editor:record('beePools')
    assert(pool.id:find('蜂群池-', 1, true) == 1)
    editor:act('tab:3')
    assert(editor:value(formField(editor, '阵列名称')) == '观测阵列 1')
    local f = formField(editor, '使用的蜂群池')
    assert(editor:value(f) == '蜂群池 1' and editor:choices(f)[2].label == '蜂群池 2')
    assert(editor.ui:recordName(ex.cfg, 'channels', ex.cfg.channels[1]) == '公共原料子网')
    assert(editor.ui:recordName(ex.cfg, 'feeds', ex.cfg.feeds[1]) == '预缓存设备')
    assert(editor.ui:recordName(ex.cfg, 'beePools', nil) == '未选择')
    ex.cfg.beePools[1].name = '高阶蜂群池'
    assert(editor:value(f) == '高阶蜂群池')
end)

test('fluid table edits individual rows and pages without changing other fluids', function()
    for _, size in ipairs({ { 80, 25 }, { 120, 38 }, { 160, 50 } }) do
        local ex = dofile(ROOT .. 'examples/two-arrays.lua')
        local editor = editorFor(ex.cfg, ex.component)
        editor.ui.gpu.getResolution = function()
            return size[1], size[2]
        end
        objectKind(editor, 'fluids')
        editor:draw()
        local function click(id, button)
            editor:draw()
            for _, h in ipairs(editor.ui.hits) do
                if h.id == id then
                    editor:event('touch', 'screen', h.x, h.y, button or 0)
                    return
                end
            end
            error('missing hit: ' .. id)
        end
        local original = U.copy(editor.fluidRows[1])
        click('fluid:2:enabled')
        click('fluid:2:high')
        editor:event('clipboard', 'keyboard', 'bad')
        click('confirm-edit')
        assert(editor.edit)
        click('fluid-preset:10000000')
        assert(editor.fluidRows[2].high == 1e7 and not editor.edit)
        click('fluid:2:low')
        editor:event('clipboard', 'keyboard', '1234567')
        click('confirm-edit')
        assert(editor.fluidRows[2].low == 1234567)
        click('fluid:2:low')
        editor:event('clipboard', 'keyboard', '3000000')
        click('cancel-edit')
        assert(editor.fluidRows[2].low == 1234567)
        assert(ex.cfg.feeds[1].cells[2].slot == 2)
        eq(editor.fluidRows[1], original)
        local found = {}
        repeat
            editor:draw()
            for _, h in ipairs(editor.ui.hits) do
                local i = h.id:match('^fluid:(%d+):name$')
                if i then
                    found[tonumber(i)] = true
                end
                assert(h.x >= 1 and h.x + h.w - 1 <= size[1] and h.y >= 1 and h.y <= size[2])
            end
            if editor.fluidPage == editor.fluidPages then
                break
            end
            click('next')
        until false
        for i in ipairs(editor.fluidRows) do
            assert(found[i], 'inaccessible fluid ' .. i)
        end
        click('fluid:19:name')
        assert(editor.fluidIndex == 19)
        for _, y in ipairs({ 5, size[2] - 7 }) do
            local corners = 0
            for _, segment in ipairs(editor.ui.rows[y]) do
                if segment[2]:find(y == 5 and '┌' or '└', 1, true) then
                    corners = corners + 1
                end
            end
            assert(corners == 2, 'panel boundaries must align')
        end
    end
end)

test('array list keeps the selected name and node count together across page boundaries', function()
    for _, size in ipairs({ { 80, 25 }, { 120, 38 }, { 160, 50 } }) do
        local ex = dofile(ROOT .. 'examples/two-arrays.lua')
        local editor = editorFor(ex.cfg, ex.component)
        editor.ui.gpu.getResolution = function()
            return size[1], size[2]
        end
        for i = 3, 37 do
            local a = U.copy(ex.cfg.arrays[1])
            a.address = 'array-' .. i
            ex.cfg.arrays[i] = a
        end
        editor:act('tab:3')
        for i = 1, 37 do
            editor:act('select:' .. i)
            editor:draw()
            local selected
            for _, hit in ipairs(editor.ui.hits) do
                if hit.id == 'select:' .. i then
                    selected = hit
                end
            end
            assert(
                selected and selected.y + 1 < size[2] - 7,
                'selected array details must remain inside the panel'
            )
            local nodes = false
            for _, segment in ipairs(editor.ui.rows[selected.y + 1]) do
                if
                    segment[1] < editor.left and segment[2]:find('关联节点 16 / 16', 1, true)
                then
                    nodes = true
                end
            end
            assert(nodes)
        end
    end
end)

test('bee waiting details count only the selected pool and current same-tier leases', function()
    local ex = dofile(ROOT .. 'examples/shared-bees.lua')
    local cfg = ex.cfg
    local ui = editorFor(cfg, ex.component).ui
    local a, b = cfg.arrays[1], cfg.arrays[2]
    local tier = cfg.beePools[1].cells[1].tier
    local e = { cfg = cfg, arrays = cfg.arrays, s = { arrays = {} } }
    e.s.arrays[a.address] = { request = { tier = tier } }
    e.s.arrays[b.address] = { lease = { [tier] = { box = 1, slot = 1 } } }
    local count = 0
    for _, cell in ipairs(cfg.beePools[1].cells) do
        if cell.tier == tier then
            count = count + 1
        end
    end
    local before = U.copy(e)
    local message = ui:beeWait(e, a)
    assert(
        message:find('共登记 ' .. count .. ' 套', 1, true)
            and message:find('正在使用：观测阵列 2', 1, true)
    )
    eq(e, before)
    b.beePool = 'another-pool'
    assert(ui:beeWait(e, a):find('当前无阵列借用', 1, true))
    e.s.arrays[a.address].request.supply = true
    assert(ui:beeWait(e, a):find('当前无阵列借用', 1, true))
    e.s.arrays[a.address].request = nil
    assert(ui:beeWait(e, a) == nil)
end)

test('direct move resumes after ME-IO has already advanced the cell to output', function()
    local w = world(1, 0)
    local state, saved = {}, nil
    local function proxy(address)
        return w.components[address]
    end
    local function save()
        saved = U.copy(state)
    end
    local log = Log.new(w.cfg, state, proxy, save, U)
    assert(log:start('cell', 'a1:beeBox', 'a1:load', 1, 1, true))
    w.crashMove = 1
    throws(function()
        log:tick('cell')
    end)
    local slots = w.inventories['a1:load'].slots
    slots[7], slots[1] = slots[1], nil
    w.crashMove = nil
    state = U.copy(saved)
    log = Log.new(w.cfg, state, proxy, save, U)
    assert(log:step('cell', 'a1:beeBox', 'a1:load', 1, 1, true))
    assert(w.moves == 1 and slots[7] and not w.inventories['a1:beeBox'].slots[1])
    log:finish('cell')
    assert(not next(state.moves))
    assert(log:step('return', 'a1:load', 'a1:beeBox', 7, 1))
    assert(w.moves == 2 and not slots[7] and w.inventories['a1:beeBox'].slots[1])
end)

test(
    'direct wiring validates one transposer per array and protects borrowed cell return',
    function()
        local ex = dofile(ROOT .. 'examples/two-arrays.lua')
        local cfg = ex.cfg
        local a = cfg.arrays[1]
        local inv = U.index(cfg.inventories)
        local Recovery = module('ma_recovery')
        local state = {
            wiring = U.copy(cfg),
            arrays = { [a.address] = { lease = { [1] = { box = 1, slot = 1 } } } },
        }
        a.name, cfg.beePools[1].name = '新阵列名称', '新蜂群池名称'
        cfg.singularityWait = 120
        assert(Recovery.check(cfg, state, U))
        inv[a.loadPort].side = 4
        throws(function()
            Recovery.check(cfg, state, U)
        end)
        inv[a.loadPort].side = 1
        inv[a.loadPort].transposer = 'TB'
        throws(function()
            C.validate(cfg, ex.component, U)
        end)
        inv[a.loadPort].transposer = 'TA'
        inv[a.loadPort].side = inv[a.unloadPort].side
        throws(function()
            C.validate(cfg, ex.component, U)
        end)
    end
)

test('item identity keeps NBT distinctions and only checks the counting limit', function()
    local a = { name = 'test:item', damage = 0, hasTag = true, tag = 'first' }
    local b = U.copy(a)
    b.tag = 'second'
    assert(I.key(a) ~= I.key(b))
    b.tag = nil
    throws(function()
        I.key(b)
    end)
    assert(I.amount({ size = 64 }) == 64)
    local maximum = 9007199254740991
    assert(U.total({ maximum }) == maximum)
    throws(function()
        U.total({ maximum, 1 })
    end)
end)

test('empty bee boxes retain independent numbers and persist across editor reopen', function()
    local ex = dofile(ROOT .. 'examples/two-arrays.lua')
    ex.cfg.beePools[1].cells = {}
    local e = editorFor(ex.cfg, ex.component)
    e:act('tab:2')
    objectKind(e, 'pool', ex.cfg.beePools[1])
    formField(e, '新增箱子').run()
    eq(e:boxes(ex.cfg.beePools[1]), { 1, 2 })
    formField(e, '新增箱子').run()
    eq(e:boxes(ex.cfg.beePools[1]), { 1, 2, 3 })
    eq(e:boxes(ex.cfg.beePools[2]), { 1 })
    local reopened = editorFor(U.copy(ex.cfg), ex.component)
    eq(reopened:boxes(reopened.cfg.beePools[1]), { 1, 2, 3 })
end)

test('deleting a bee box removes only its cells and bindings without renumbering others', function()
    local ex = dofile(ROOT .. 'examples/shared-bees.lua')
    local pool = ex.cfg.beePools[1]
    local wiring = U.copy(ex.cfg)
    local e = editorFor(ex.cfg, ex.component)
    e:act('tab:2')
    objectKind(e, 'box', pool)
    assert(e:object().box == 1)
    e:draw()
    local hit
    for _, h in ipairs(e.ui.hits) do
        if h.id == 'delete' then
            hit = h
        end
    end
    assert(hit, 'box page must expose a delete button')
    e:event('touch', 'screen', hit.x, hit.y, 0)
    eq(e:boxes(pool), { 2 })
    assert(e:object().kind == 'pool')
    for _, cell in ipairs(pool.cells) do
        assert(cell.box == 2)
    end
    for _, a in ipairs(ex.cfg.arrays) do
        assert(#a.beeBoxes == 1 and a.beeBoxes[1].box == 2)
        assert(e:inventory(a.loadPort) and e:inventory(a.unloadPort))
    end
    C.validate(ex.cfg, ex.component, U)
    local active =
        { wiring = wiring, arrays = { ['ARRAY-A'] = { lease = { [1] = { box = 1, slot = 1 } } } } }
    throws(function()
        Recovery.check(ex.cfg, active, U)
    end)
    formField(e, '新增箱子').run()
    eq(e:boxes(pool), { 1, 2 })
    objectKind(e, 'box', pool)
    e:act('delete')
    objectKind(e, 'box', pool)
    e:act('delete')
    eq(e:boxes(pool), {})
    local reopened = editorFor(U.copy(ex.cfg), ex.component)
    eq(reopened:boxes(reopened.cfg.beePools[1]), {})
    formField(e, '新增箱子').run()
    eq(e:boxes(pool), { 1 })
end)

test('unregistering the last bee cell keeps the empty box available', function()
    local ex = dofile(ROOT .. 'examples/two-arrays.lua')
    local pool = ex.cfg.beePools[1]
    pool.cells = { { box = 3, slot = 1, tier = 1 } }
    local e = editorFor(ex.cfg, ex.component)
    e:act('tab:2')
    objectKind(e, 'box', pool)
    e:act('slot:1')
    e:act('unregister')
    assert(#pool.cells == 0)
    eq(e:boxes(pool), { 3 })
    e:act('delete')
    eq(e:boxes(pool), {})
end)

print(passed .. ' test groups passed')
