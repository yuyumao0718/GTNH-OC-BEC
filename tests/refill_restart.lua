local U = dofile(ROOT .. 'ma_util.lua')
local M = dofile(ROOT .. 'ma_materials.lua')
local make = assert(loadfile(ROOT .. 'tests/simplified.lua'))('fixture')
local fluid = M[1].condensate
local passed = 0

local function test(name, fn)
    fn()
    passed = passed + 1
    print('  PASS ' .. name)
end

local function world()
    local w = make(1, 0)
    w.addFeed('raw', 1)
    w.stock[fluid] = 0
    w.cfg.fieldLimit = 576
    w.cfg.bands[1].low, w.cfg.bands[1].high = 100, 500
    w.boot()
    return w
end

local function scan(w)
    w.e.reserved, w.e.waiting = {}, {}
    w.e.now = w.time / 20
    w.r:scan()
end

test('restart includes new full and partly filled cells in the field budget', function()
    for _, amount in ipairs({ 288, 576 }) do
        local w = world()
        w.state.refill.feeds.raw.initialized = true
        w.e:pause()
        local f = w.cfg.feeds[1]
        f.cells[2] = { material = M[2].source, inventory = 'raw:drive', slot = 2 }
        w.cfg.bands[2] = { material = M[2].source, low = 100, high = 500 }
        w.inventories['raw:drive'].slots[2] = {
            storedFluidCount = amount,
            remainingFluidCount = 576 - amount,
            availableFluids = { { name = M[2].source, amount = amount } },
        }
        w.boot(U.copy(w.saved))
        scan(w)
        local s = w.state.refill.feeds.raw
        assert(s.pending[2].amount == amount)
        assert(not s.loading, 'new raw fluid must count before another full cell is admitted')
        assert(not s.initialized and not s.retry, 'transient fields must not remain in saved state')
    end
end)

test('empty cells are checked once per start, not on every idle scan', function()
    local w = world()
    w.stock[fluid] = 576
    local proxy = w.components['raw:transposer']
    local get = proxy.getStackInSlot
    local reads = 0
    proxy.getStackInSlot = function(side, slot)
        if side == 0 and slot == 1 then
            reads = reads + 1
        end
        return get(side, slot)
    end
    scan(w)
    local initial = reads
    assert(initial == 1)
    for _ = 1, 20 do
        scan(w)
    end
    assert(reads == initial)
    w.e:pause()
    w.boot(U.copy(w.saved))
    reads = 0
    scan(w)
    assert(reads == 1, 'a new engine must perform its own initial observation')
end)

test('empty-cell retry lasts five seconds within a run and resets after reboot', function()
    local w = world()
    w.time, w.e.now = 86400 * 20, 86400
    local s = w.state.refill.feeds.raw
    local slots = w.inventories['raw:drive'].slots
    w.inventories['raw:io'].slots[7], slots[1] = slots[1], nil
    s.loading = { index = 1, phase = 'back', capacity = 576, amount = 0 }
    w.r:receive(w.cfg.feeds[1])
    assert(w.r.retry.raw[1] == 86405 and not s.retry)
    w.e:pause()
    local saved = U.copy(w.saved)
    w.time = 86404 * 20
    scan(w)
    assert(not s.loading)
    w.time = 86405 * 20
    scan(w)
    assert(s.loading and s.loading.index == 1)
    w.time = 0
    w.boot(saved)
    scan(w)
    assert(w.state.refill.feeds.raw.loading)
end)

test('restart preserves raw-fluid claims while their generator is still processing', function()
    local w = world()
    local g = w.gens['raw:g1']
    g.busy, g.progress, g.amount = true, 1, 576
    local s = w.state.refill.feeds.raw
    s.initialized = true
    s.pending[1] = { amount = 576, finish = { ['raw:g1'] = 5 } }
    w.state.refill.generators['raw:g1'] = { epoch = 4, busy = true, progress = 1 }
    w.e:pause()
    w.boot(U.copy(w.saved))
    scan(w)
    s = w.state.refill.feeds.raw
    assert(w.r.draining and not s.loading and not s.pending[1])
    g.busy, g.progress = false, 0
    w.stock[fluid] = 576
    w.time = 100
    scan(w)
    assert(not s.pending[1] and not s.loading)
end)

test('restart retains the full reserved amount when only part of the raw fluid remains', function()
    local w = world()
    local cell = w.feedCells.raw
    cell.storedFluidCount, cell.remainingFluidCount = 288, 288
    cell.availableFluids = { { name = M[1].source, amount = 288 } }
    local g = w.gens['raw:g1']
    g.busy, g.progress, g.amount = true, 1, 288
    w.state.refill.feeds.raw.pending[1] = { amount = 576 }
    w.e:pause()
    w.boot(U.copy(w.saved))
    scan(w)
    local s = w.state.refill.feeds.raw
    assert(w.r.draining and s.pending[1].amount == 288 and not s.loading)
end)

test(
    'startup registers remaining raw fluid after the previous generator claim completes',
    function()
        local w = world()
        local cell = w.feedCells.raw
        cell.storedFluidCount, cell.remainingFluidCount = 288, 288
        cell.availableFluids = { { name = M[1].source, amount = 288 } }
        w.state.refill.feeds.raw.pending[1] = { amount = 576, finish = { ['raw:g1'] = 5 } }
        w.state.refill.generators['raw:g1'] = { epoch = 4, busy = true, progress = 1 }
        w.e:pause()
        w.boot(U.copy(w.saved))
        scan(w)
        local s = w.state.refill.feeds.raw
        assert(s.pending[1].amount == 288 and not s.pending[1].finish and not s.loading)
    end
)

test(
    'refill resumes every transfer phase and physical interruption without duplicate loading',
    function()
        for _, phase in ipairs({ 'out', 'io', 'back', 'out-move', 'back-move' }) do
            local w = world()
            scan(w)
            local f = w.cfg.feeds[1]
            if phase == 'out-move' then
                w.crashMove = w.moves + 1
                assert(not pcall(w.r.receive, w.r, f))
            elseif phase ~= 'out' then
                w.r:receive(f)
                if phase ~= 'io' then
                    w.advance()
                    w.r:receive(f)
                    if phase == 'back-move' then
                        w.crashMove = w.moves + 1
                        assert(not pcall(w.r.receive, w.r, f))
                    end
                end
            end
            w.crashMove = nil
            w.boot(U.copy(w.saved))
            scan(w)
            local s = w.state.refill.feeds.raw
            for _ = 1, 10 do
                if not s.loading then
                    break
                end
                w.advance()
                w.e.now = w.time / 20
                w.r:receive(f)
            end
            assert(not s.loading and s.pending[1].amount == 576, phase)
            assert(w.moves == 2 and w.refills == 1, 'duplicate transfer or loading at ' .. phase)
            assert(
                not w.saved or not w.saved.refill,
                'precache should recover without a saved transfer'
            )
            assert(w.inventories['raw:drive'].slots[1] == w.feedCells.raw)
        end
    end
)

test('all old entanglers must drain before new feed; use the post-drain stock', function()
    local w = make(1, 0)
    w.addFeed('raw', 2)
    w.cfg.fieldLimit = 2000
    w.cfg.bands[1].low, w.cfg.bands[1].high = 600, 1000
    w.stock[fluid] = 0
    local g1, g2 = w.gens['raw:g1'], w.gens['raw:g2']
    g1.busy, g2.busy = true, true
    g1.progress, g2.progress = 1, 2
    w.boot()
    scan(w)
    assert(w.r.draining and not w.state.refill.feeds.raw.loading)
    g1.busy = false
    w.stock[fluid] = 144
    w.time = w.time + 101
    scan(w)
    assert(w.r.draining and not w.state.refill.feeds.raw.loading)
    g2.busy = false
    w.stock[fluid] = 288
    w.time = w.time + 101
    scan(w)
    assert(not w.r.draining and w.e.stock[fluid] == 288 and w.state.refill.feeds.raw.loading)
    assert(w.saves == 0)
end)
print(passed .. ' refill restart test groups passed')
