local make = assert(loadfile(ROOT .. 'tests/simplified.lua'))('fixture')
local U = dofile(ROOT .. 'ma_util.lua')
local fluid = 'entangled_neutronium'
local function resources(e)
    for _ = 1, 1000 do
        if e:resources(true) then
            return
        end
    end
    error('resource scan did not complete')
end
local function running()
    local w = make(2, 64, { nodes = 16, stageTicks = 400 })
    for _ = 1, 500 do
        w.tick()
        local ready = true
        for id, machine in pairs(w.arrays) do
            local s = w.state.arrays[id]
            ready = ready and s.batch and s.batch.phase == 'run' and not s.bee and machine.enabled
        end
        if ready then
            return w
        end
    end
    error('arrays did not start')
end

do
    local w = running()
    local reads = {}
    for address in pairs(w.nodes) do
        for _, method in ipairs({
            'getRequiredCondensate',
            'getParallelRecipesInProgress',
            'getConsumedCondensate',
            'getProvidedTier',
            'getAvailableNanites',
        }) do
            local original = w.components[address][method]
            w.components[address][method] = function(...)
                reads[method] = (reads[method] or 0) + 1
                return original(...)
            end
        end
    end
    w.e:tick()
    assert(not next(reads), 'stable hot pass should not reread recipe, bee or consumption data')
    w.time = w.time + 21
    w.e:tick()
    assert(reads.getConsumedCondensate == 4, 'each pass reads at most four outstanding nodes')
    resources(w.e)
    assert(reads.getConsumedCondensate == 32, 'a complete scan must include each active node')
    assert(not reads.getRequiredCondensate and not reads.getParallelRecipesInProgress)
    assert(not reads.getProvidedTier and not reads.getAvailableNanites)
    local a = w.cfg.arrays[1]
    w.e.now = w.e.now + 20
    assert(w.e:bees(a, w.state.arrays[a.address], w.arrays[a.address].tier))
    assert(
        not reads.getProvidedTier and not reads.getAvailableNanites,
        'confirmed bees are reused until unloading or restart'
    )
end
print(
    '  PASS processing reuses fixed metadata and confirmed bees while sampling outstanding consumption'
)

do
    local w = running()
    resources(w.e)
    local before =
        { reserved = U.copy(w.e.reserved), free = U.copy(w.e.free), stock = U.copy(w.e.stock) }
    local pulses = 0
    w.e.io.pulse = function()
        pulses = pulses + 1
        return pulses == 1
    end
    assert(not w.e:resources(true))
    assert(w.e:pulse() and pulses == 1)
    w.e:pause()
    assert(not w.e.resourceScan)
    assert(
        U.equal(before.reserved, w.e.reserved)
            and U.equal(before.free, w.e.free)
            and U.equal(before.stock, w.e.stock),
        'interruption must not publish a partial ledger'
    )
    w.e.io.pulse = nil
    w.boot(w.saved)
    w.finish(3000)
end
print('  PASS interrupted resource sampling leaves a complete snapshot and resumes the orders')

do
    local w = running()
    resources(w.e)
    local reservation = w.e.reserved[fluid]
    w.stock[fluid] = reservation + 200
    resources(w.e)
    assert(w.e:grant({ reserve = { [fluid] = 150 } }))
    assert(
        not w.e:grant({ reserve = { [fluid] = 150 } }),
        'same-pass grants must not reuse the same stock'
    )
    w.stock[fluid] = 0
    w.e.resourcesFresh = false
    assert(
        not w.e:grant({ reserve = { [fluid] = 40 } }),
        'new grants must wait for a complete fresh snapshot'
    )
    resources(w.e)
    assert(not w.e:grant({ reserve = { [fluid] = 40 } }))
end
print('  PASS fresh grants refresh stale stock and preserve deductions from earlier grants')

do
    local w = running()
    local s = w.state.arrays[w.cfg.arrays[1].address]
    local first = s.batch.workers[1]
    w.components[first.address].getConsumedCondensate = function()
        w.nodes[first.address].active = false
        return nil
    end
    assert(w.e:remaining(s), 'a node may finish between hasWork and consumed-fluid reads')
end
print('  PASS node completion during consumption sampling does not use missing recipe data')

do
    local w = running()
    for address in pairs(w.nodes) do
        local read = w.components[address].getConsumedCondensate
        w.components[address].getConsumedCondensate = function()
            w.advance()
            return read()
        end
    end
    resources(w.e)
    local actual = 0
    for _, node in pairs(w.nodes) do
        if node.active then
            actual = actual + 144 * node.count - node.consumed
        end
    end
    assert(
        w.e.reserved[fluid] >= actual,
        'slow reads must overestimate remaining obligations, never underestimate them'
    )
    assert(
        w.e.free[fluid] <= w.stock[fluid] - actual,
        'a slow sample must not inflate allocatable stock'
    )
    w.finish(3000)
end
print('  PASS slow consumption callbacks keep reservations conservative until all orders finish')
