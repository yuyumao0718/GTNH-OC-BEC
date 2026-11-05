local make = assert(loadfile(ROOT .. 'tests/simplified.lua'))('fixture')
local U = dofile(ROOT .. 'ma_util.lua')

do
    local w = make(1, 0)
    local a = w.cfg.arrays[1]
    local s = w.state.arrays[a.address]
    assert(not w.e:bees(a, s, 1) and s.bee.phase == 'back')
    w.advance()
    w.e:bees(a, s, 1)
    assert(not s.bee, 'ready IO return and synchronization must finish in the same pass')
    assert(w.inventories['a1:beeBox'].slots[1].storedItemCount == 0)
    assert(w.e:bees(a, s, 1))
    assert(not w.e:bees(a, s, nil) and s.bee.phase == 'back')
    w.advance()
    w.e:bees(a, s, nil)
    assert(not s.bee and not s.lease)
    assert(w.inventories['a1:beeBox'].slots[1].storedItemCount == 32)
end
print('  PASS ready bee transfer phases advance without extra scheduler rounds')

do
    local w = make(1, 0)
    local a = w.cfg.arrays[1]
    local transfer = w.components['a1:transposer'].transferItem
    w.components['a1:transposer'].transferItem = function(...)
        local moved = transfer(...)
        w.advance()
        return moved
    end
    assert(w.e:bees(a, w.state.arrays[a.address], 1))
    assert(not w.state.arrays[a.address].bee and w.e.provided[a.address] == 1)
    assert(w.moves == 2, 'an immediately completed IO cycle should return the cell in one pass')
    assert(w.e:bees(a, w.state.arrays[a.address], 2))
    assert(w.moves == 6 and w.e.provided[a.address] == 2)
end
print('  PASS same-pass synchronization reads the new bee tier after physical IO')

for checkpoint, phase in ipairs({ 'back', 'sync' }) do
    local w = make(1, 0)
    local a = w.cfg.arrays[1]
    local s = w.state.arrays[a.address]
    local transfer = w.components['a1:transposer'].transferItem
    w.components['a1:transposer'].transferItem = function(...)
        local moved = transfer(...)
        w.advance()
        return moved
    end
    local pulses = 0
    w.e.io.pulse = function()
        pulses = pulses + 1
        return pulses == checkpoint
    end
    w.e:bees(a, s, 1)
    assert(pulses == checkpoint and s.bee.phase == phase)
    assert(w.moves == checkpoint)
    w.boot(U.copy(w.saved))
    for _ = 1, 10 do
        if w.e:bees(a, w.state.arrays[a.address], 1) then
            break
        end
        w.advance()
    end
    assert(not w.state.arrays[a.address].bee and w.arrays.a1.bees == 32)
    assert(w.moves == 2, 'resume must not duplicate a completed physical transfer')
end
print('  PASS bee phase input checkpoints preserve exact transfer recovery')

do
    local w = make(1, 0)
    local a = w.cfg.arrays[1]
    w.e:bees(a, w.state.arrays[a.address], 1)
    local saved = U.copy(w.saved)
    saved.arrays[a.address].bee.phase = 'io'
    w.boot(saved)
    w.advance()
    assert(w.e:bees(a, w.state.arrays[a.address], 1))
    assert(w.moves == 2 and w.arrays.a1.bees == 32)
end
print('  PASS saved ME-IO waiting phase resumes without repeating the outgoing move')

do
    local w = make(2, 0)
    local first, second = w.cfg.arrays[1], w.cfg.arrays[2]
    for _ = 1, 4 do
        w.e:bees(first, w.state.arrays[first.address], 1)
    end
    assert(w.state.arrays[first.address].bee.phase == 'back' and w.moves == 1)
    w.e:bees(second, w.state.arrays[second.address], 1)
    assert(w.state.arrays[second.address].bee.phase == 'back' and w.moves == 2)
end
print('  PASS waiting ME-IO port returns control so another array can transfer')
