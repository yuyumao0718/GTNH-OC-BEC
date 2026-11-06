-- Offline experiment only. Production modules are loaded unchanged.
local U = dofile(ROOT .. 'ma_util.lua')
local I = dofile(ROOT .. 'ma_intake.lua')
local M = dofile(ROOT .. 'ma_materials.lua')
local make = assert(loadfile(ROOT .. 'tests/spec.lua'))('fixture')
local B = {}
local sync = {
    getRequiredCondensate = true,
    getConsumedCondensate = true,
    getProvidedTier = true,
    getAvailableNanites = true,
    getParallelRecipesInProgress = true,
    getRecipeSteps = true,
    setMinParallel = true,
    setMaxParallel = true,
    setSpeedDivisor = true,
    getStoredCondensate = true,
    getFieldStrength = true,
    setFieldStrength = true,
    getCondensateFilterCount = true,
    getCondensateFilters = true,
    setCondensateFilterAt = true,
    getItemsInNetwork = true,
    getStackInSlot = true,
    getInventorySize = true,
    transferItem = true,
    getInterfacePattern = true,
    setItemEventSubscription = true,
}

-- Exact integer-tick advance with a constant supplied tier. Jump between stage boundaries.
local function advanceNode(n, ticks, tier, bees, steps)
    local finish = steps[#steps].finish
    while ticks > 0 and n.progress < finish do
        local index = 1
        while n.progress >= steps[index].finish do
            index = index + 1
        end
        local step = steps[index]
        if tier < step.tier then
            break
        end
        local divisor = n.count * 2 ^ (tier - step.tier)
        local needed =
            math.max(1, math.ceil(((step.finish - n.progress) * divisor - n.subtick) / bees))
        local use = math.min(ticks, needed)
        local accumulated = n.subtick + use * bees
        local progress = n.progress + math.floor(accumulated / divisor)
        n.subtick = accumulated % divisor
        for j = index + 1, #steps do
            if steps[j].tier > tier then
                progress = math.min(progress, steps[j].start)
                break
            end
        end
        n.progress = math.min(finish, progress)
        ticks = ticks - use
    end
end

function B.run(case, opt)
    local w = make(opt.arrays, 0, { nodes = 16 })
    w.direct(1)
    w.closed = true
    local metrics =
        { syncCalls = 0, waits = {}, waitSeconds = 0, jobs = {}, singularityBatches = 0 }
    local beeCells = {}
    local pool = opt.pool
    for tier = 1, 10 do
        for _ = 1, pool[tier] do
            local i = #beeCells
            beeCells[i + 1] =
                { tier = tier, box = math.floor(i / 27) + 1, slot = i % 27 + 1, count = 30720 }
        end
    end
    w.share(beeCells)
    for _, a in ipairs(w.cfg.arrays) do
        w.inventories[a.address .. ':beeBox'].size = 27
    end
    w.cfg.bands = {}
    for _, material in ipairs(M) do
        w.cfg.bands[#w.cfg.bands + 1] = { material = material.source, low = 0, high = 1 }
    end
    local stock, patterns, byKey = {}, {}, {}
    local finished, delivered, produced, admitted = {}, {}, {}, {}
    local total = 0
    for index, recipe in ipairs(case.recipes) do
        metrics.jobs[recipe.id] = { arrays = {} }
        total = total + recipe.count
        for fluid, amount in pairs(recipe.unit) do
            stock[fluid] = (stock[fluid] or 0) + amount * recipe.count
        end
        local output = recipe.singularity
                and {
                    name = recipe.singularity <= 10
                            and 'universalsingularities:universal.circuit.singularity'
                        or 'universalsingularities:universal.circuit2.singularity',
                    damage = recipe.singularity <= 10 and recipe.singularity - 1
                        or recipe.singularity - 11,
                    size = 1,
                }
            or { name = 'result-' .. index, damage = 0, size = 1 }
        patterns[index] = {
            isCraftable = false,
            inputs = { { name = 'bundle-' .. index, damage = 0, size = 1 } },
            outputs = { output },
        }
        recipe.input = 'bundle-' .. index
    end
    w.stock = {}
    for fluid, amount in pairs(stock) do
        w.stock[fluid] = amount + 1000000
    end
    w.cfg.fieldLimit = U.total(w.stock) + 1
    local catalog = I.catalog(patterns)
    for _, p in ipairs(catalog.patterns) do
        for _, recipe in ipairs(case.recipes) do
            if p.inputs[I.key({ name = recipe.input, damage = 0 })] then
                recipe.key, byKey[p.key] = p.key, recipe
            end
        end
    end
    w.cfg.channels[1].patterns[1].slots = #patterns
    w.components.pattern.getInterfacePattern = function(slot)
        return patterns[slot]
    end
    local input = { count = 0 }
    w.components.receiver.getItemsInNetwork = function()
        return input.count > 0 and { { name = input.recipe.input, damage = 0, size = input.count } }
            or {}
    end
    local now, gameTick = 0, 0
    local firstInput, lastOutput
    local nextDelivery = 0
    local function advance(seconds)
        if seconds <= 0 then
            return
        end
        local nextTime = now + seconds
        local nextTick = math.floor(nextTime * 20 + 1e-7)
        local ticks = nextTick - gameTick
        if w.state then
            for _, s in pairs(w.state.arrays) do
                if s.request and not s.lease then
                    metrics.waitSeconds = metrics.waitSeconds + seconds
                    metrics.waits[s.request.tier] = (metrics.waits[s.request.tier] or 0) + seconds
                end
            end
        end
        now, w.time, gameTick = nextTime, nextTick, nextTick
        if ticks == 0 then
            return
        end
        -- The receiving subnet accepts one ready whole-recipe order while the shared gate is open.
        if not w.closed and input.count == 0 and now >= nextDelivery then
            for _, recipe in ipairs(case.recipes) do
                local ready = not delivered[recipe.id]
                for _, dependency in ipairs(recipe.dependencies) do
                    ready = ready and finished[dependency]
                end
                if ready then
                    input.recipe, input.count = recipe, recipe.count
                    delivered[recipe.id] = true
                    nextDelivery = now + opt.supplyGap
                    firstInput = firstInput or now
                    metrics.jobs[recipe.id].arrival = now
                    w.signals[#w.signals + 1] = { 'network_item_changed', 'receiver' }
                    break
                end
            end
        end
        for id, port in pairs(w.io) do
            local slots = w.inventories[id].slots
            local cell = slots[1]
            if cell and not slots[7] then
                local machine = w.arrays[port.array]
                if port.kind == 'load' then
                    machine.tier, machine.bees = cell.tier, cell.storedItemCount
                    cell.storedItemCount = 0
                else
                    cell.storedItemCount = machine.bees
                    machine.tier, machine.bees = nil, 0
                end
                slots[7], slots[1] = cell, nil
            end
        end
        for _, a in ipairs(w.cfg.arrays) do
            for _, nc in ipairs(a.nodes) do
                local n = w.nodes[nc.address]
                local newly = false
                if not n.active and n.allowed and input.count >= n.min then
                    n.count, n.recipe = math.min(n.max, input.count), input.recipe
                    input.count = input.count - n.count
                    n.active, n.progress, n.subtick, n.consumed = true, 0, 0, false
                    admitted[n.recipe.id] = (admitted[n.recipe.id] or 0) + n.count
                    newly = true
                    metrics.jobs[n.recipe.id].arrays[n.array] = true
                    if n.recipe.singularity then
                        assert(n.count == 1, 'singularity parallel changed')
                    end
                    w.signals[#w.signals + 1] = { 'network_item_changed', 'receiver' }
                end
                local machine = w.arrays[n.array]
                if n.active and machine.enabled and machine.tier then
                    local old = n.progress
                    advanceNode(n, newly and 1 or ticks, machine.tier, machine.bees, n.recipe.steps)
                    if n.progress > old and not n.consumed then
                        for fluid, unit in pairs(n.recipe.unit) do
                            w.stock[fluid] = w.stock[fluid] - unit * n.count
                            assert(w.stock[fluid] >= 0, 'fluid over-allocation')
                        end
                        n.consumed = true
                    end
                    if n.progress >= n.recipe.steps[#n.recipe.steps].finish then
                        n.active = false
                        w.produced = w.produced + n.count
                        produced[n.recipe.id] = (produced[n.recipe.id] or 0) + n.count
                        if produced[n.recipe.id] == n.recipe.count then
                            finished[n.recipe.id] = true
                            metrics.jobs[n.recipe.id].finish = now
                        end
                        assert(produced[n.recipe.id] <= n.recipe.count, 'duplicate output')
                        if w.produced == total then
                            lastOutput = now
                        end
                    end
                end
            end
        end
    end
    for _, a in ipairs(w.cfg.arrays) do
        local gate = w.components[a.diode]
        gate.getCondensateFilterCount = function()
            return 19
        end
        for _, nc in ipairs(a.nodes) do
            local n = w.nodes[nc.address]
            local p = w.components[nc.address]
            p.getRequiredCondensate = function()
                return U.scale(n.recipe.unit, n.count)
            end
            p.getConsumedCondensate = function()
                return n.consumed and U.scale(n.recipe.unit, n.count) or {}
            end
            p.getRecipeSteps = function()
                local raw = {}
                for i, s in ipairs(n.recipe.steps) do
                    raw[i] = { nanite = { tier = s.tier }, start = s.start, ['end'] = s.finish }
                end
                return raw
            end
        end
    end
    local measuring = false
    for _, component in pairs(w.components) do
        for name, fn in pairs(component) do
            component[name] = function(...)
                if sync[name] then
                    if measuring then
                        metrics.syncCalls = metrics.syncCalls + 1
                    end
                    advance(opt.syncSeconds)
                end
                return fn(...)
            end
        end
    end
    local state = { patterns = {} }
    for _, p in ipairs(catalog.patterns) do
        local recipe = byKey[p.key]
        state.patterns[p.key] =
            { pattern = p, steps = U.copy(recipe.steps), unit = U.copy(recipe.unit) }
    end
    w.boot(state)
    w.e.io.time = function()
        return now
    end
    w.e.io.save = function()
        error('all recipes were prelearned')
    end
    local seenRun = {}
    measuring = true
    local loops = 0
    repeat
        loops = loops + 1
        advance(0.05)
        for _, event in ipairs(w.signals) do
            w.e:event(table.unpack(event))
        end
        w.signals = {}
        w.e:tick()
        assert(not next(w.e.errors), next(w.e.errors) and select(2, next(w.e.errors)))
        for _, a in ipairs(w.cfg.arrays) do
            local b = state.arrays[a.address].batch
            if b and b.phase == 'run' and not seenRun[b] then
                seenRun[b] = true
                if b.collection then
                    metrics.singularityBatches = metrics.singularityBatches + 1
                end
            end
        end
        if loops % 1000 == 0 then
            w.assertPool()
        end
        assert(now < 100000 and loops < 2000000, 'simulation timed out')
    until lastOutput
    for _, recipe in ipairs(case.recipes) do
        assert(
            admitted[recipe.id] == recipe.count and produced[recipe.id] == recipe.count,
            recipe.id
        )
    end
    for fluid in pairs(stock) do
        assert(w.stock[fluid] == 1000000, 'fluid conservation: ' .. fluid)
    end
    w.assertPool()
    metrics.seconds, metrics.moves = lastOutput - firstInput, w.moves
    metrics.totalCrafts, metrics.completedRecipes = total, #case.recipes
    metrics.cellCount = #beeCells
    return metrics
end
return B
