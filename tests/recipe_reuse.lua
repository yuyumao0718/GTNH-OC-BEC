local make = assert(loadfile(ROOT .. 'tests/simplified.lua'))('fixture')
local U = dofile(ROOT .. 'ma_util.lua')
local I = dofile(ROOT .. 'ma_intake.lua')
local N = dofile(ROOT .. 'ma_nanites.lua')
local benchmark = ... == 'benchmark'

local function prepared(count, fast, known)
    local w = make(count, count * 800, { nodes = 16, stageTicks = 400 })
    w.cfg.fieldLimit = 1e12
    w.stock.entangled_neutronium = 1e11
    local cells = {}
    for tier = 1, 2 do
        for _ = 1, count do
            cells[#cells + 1] = {
                tier = tier,
                box = math.floor(#cells / 27) + 1,
                slot = #cells % 27 + 1,
                count = fast and 1e9 or 32,
            }
        end
    end
    w.share(cells)
    local state = {}
    if known then
        local pattern = I.catalog({ w.pattern }).patterns[1]
        local node = w.cfg.arrays[1].nodes[1].address
        state.patterns = {
            [pattern.key] = {
                pattern = pattern,
                unit = { entangled_neutronium = 144 },
                steps = N.steps(w.components[node].getRecipeSteps()),
            },
        }
    end
    w.boot(state)
    return w
end

local function untilIntake(w)
    for _ = 1, 2000 do
        w.tick()
        local _, err = next(w.e.errors)
        assert(not err, err)
        local complete = not w.state.admission
        for _, s in pairs(w.state.arrays) do
            complete = complete and s.batch and s.batch.phase ~= 'admit'
        end
        if complete then
            return
        end
    end
    error('intake did not complete')
end

local rows = {}
for _, count in ipairs({ 6, 10, 30 }) do
    for _, fast in ipairs({ false, true }) do
        for _, known in ipairs({ false, true }) do
            local w = prepared(count, fast, known)
            local calls, total, gap, maxGap = {}, 0, 0, 0
            local sync = {
                getParallelRecipesInProgress = true,
                getRequiredCondensate = true,
                getRecipeSteps = true,
                setMinParallel = true,
                setMaxParallel = true,
            }
            local function pulse()
                maxGap = math.max(maxGap, gap)
                gap = 0
                return false
            end
            w.e.io.pulse = pulse
            for _, node in pairs(w.nodes) do
                assert(node.count == 0)
            end
            for _, p in pairs(w.components) do
                for name, fn in pairs(p) do
                    p[name] = function(...)
                        calls[name] = (calls[name] or 0) + 1
                        total = total + 1
                        if sync[name] then
                            gap = gap + 1
                        end
                        return fn(...)
                    end
                end
            end
            local inSchedule, poolScans = false, 0
            local schedule, beeCells = w.e.schedule, w.e.beeCells
            w.e.schedule = function(e)
                inSchedule = true
                local result = schedule(e)
                inSchedule = false
                return result
            end
            w.e.beeCells = function(e, a)
                if inSchedule then
                    poolScans = poolScans + 1
                end
                return beeCells(e, a)
            end
            untilIntake(w)
            pulse()
            local required = calls.getRequiredCondensate or 0
            local steps = calls.getRecipeSteps or 0
            if not benchmark then
                assert(required == (known and 0 or 1) and steps == required)
                assert(poolScans == (known and 1 or 0))
            end
            assert(calls.getParallelRecipesInProgress == count)
            for _, s in pairs(w.state.arrays) do
                assert(s.batch.count == 800 and #s.batch.workers == 16)
                assert(s.batch.reserve.entangled_neutronium == 800 * 144)
            end
            rows[#rows + 1] = {
                arrays = count,
                fast = fast,
                known = known,
                required = required,
                steps = steps,
                countChecks = calls.getParallelRecipesInProgress,
                poolScans = poolScans,
                totalCalls = total,
                maxSyncGap = maxGap,
                intakeTicks = w.time,
            }
            if not benchmark then
                w.finish(5000)
                assert(w.produced == count * 800 and w.admitted == w.produced)
            end
        end
    end
end
if benchmark then
    return rows
end
print(
    '  PASS 6/10/30 arrays reuse recipe data with unchanged counts, reservations and fast/ordinary results'
)

do
    local w = make(2, 0)
    local meta = { steps = { { tier = 3 } } }
    w.e.pools[w.cfg.arrays[1].beePool].cells = { { tier = 2 } }
    w.e.pools[w.cfg.arrays[2].beePool].cells = { { tier = 4 } }
    assert(not w.e:poolSupports(w.cfg.arrays[1], meta))
    assert(w.e:poolSupports(w.cfg.arrays[2], meta))
    local unknown = {}
    assert(w.e:poolSupports(w.cfg.arrays[1], unknown))
    unknown.steps = { { tier = 3 } }
    assert(not w.e:poolSupports(w.cfg.arrays[1], unknown))
    w.boot(U.copy(w.saved))
    assert(not next(w.e.poolSupport))
end
print(
    '  PASS separate pools keep separate capability results; unknown recipes and restarts do not retain stale results'
)

for _, phase in ipairs({ 'admit', 'run' }) do
    local w = prepared(2, false, true)
    local target
    for _ = 1, 2000 do
        w.tick()
        for _, s in pairs(w.state.arrays) do
            local b = s.batch
            if b and b.phase == phase then
                for _, worker in ipairs(b.workers) do
                    if w.nodes[worker.address].active then
                        target = worker.address
                        break
                    end
                end
            end
            if target then
                break
            end
        end
        if target then
            break
        end
    end
    assert(target)
    local saved = U.copy(w.state)
    local fn = w.components[target].getRequiredCondensate
    w.components[target].getRequiredCondensate = function()
        local values = fn()
        values.entangled_neutronium = values.entangled_neutronium + 1
        return values
    end
    local ok = pcall(function()
        w.boot(saved)
        for _ = 1, 200 do
            w.tick()
        end
    end)
    assert(not ok or next(w.e.errors), 'resume must detect changed recipe data in ' .. phase)
end
print('  PASS both interrupted intake and running-task recovery still compare node recipes')

do
    local w = prepared(1, false, true)
    local target = w.cfg.arrays[1].nodes[1].address
    local fn = w.components[target].getParallelRecipesInProgress
    w.components[target].getParallelRecipesInProgress = function()
        return fn() + 1
    end
    for _ = 1, 100 do
        w.tick()
    end
    assert(next(w.e.errors), 'known recipe must still reject incorrect intake counts')
end
print('  PASS known recipes retain representative intake count checks')

do
    local singular = assert(loadfile(ROOT .. 'tests/singularities.lua'))('fixture')
    local w = singular(
        { { kind = 1, count = 3 }, { kind = 2, count = 3 }, { kind = 1, count = 2 } },
        { timeout = 1 }
    )
    local reads = {}
    for address, node in pairs(w.nodes) do
        local fn = w.components[address].getRecipeSteps
        w.components[address].getRecipeSteps = function()
            reads[node.kind] = (reads[node.kind] or 0) + 1
            return fn()
        end
    end
    w.finish()
    assert(reads[1] == 1 and reads[2] == 1)
    local bad = singular({ { kind = 1 }, { kind = 2 } }, { timeout = 1 })
    for address, node in pairs(bad.nodes) do
        local fn = bad.components[address].getRecipeSteps
        bad.components[address].getRecipeSteps = function()
            local steps = fn()
            if node.kind == 2 then
                steps[2]['end'] = steps[2]['end'] + 1
            end
            return steps
        end
    end
    assert(not pcall(bad.finish), 'new singularity kinds must match the collected recipe stages')
end
print('  PASS singularities learn each distinct recipe once and retain merge compatibility checks')
