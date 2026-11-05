-- Readable aliases for the Wiki; choose actual component addresses in setup.
local example = dofile(ROOT .. 'examples/two-arrays.lua')
local cfg = example.cfg
cfg.beePools = { { id = 'ender-bees', name = '共享蜂群池', cells = {} } }
local cells = cfg.beePools[1].cells
-- Two independent sets for each T1-T4; one set for each T5-T10.
for tier = 1, 4 do
    cells[#cells + 1] = { tier = tier, box = 1, slot = tier * 2 - 1 }
    cells[#cells + 1] = { tier = tier, box = 1, slot = tier * 2 }
end
for tier = 5, 10 do
    cells[#cells + 1] = { tier = tier, box = 2, slot = tier - 4 }
end
for i, a in ipairs(cfg.arrays) do
    a.beePool = 'ender-bees'
    local letter = i == 1 and 'A' or 'B'
    local transposer = 'T' .. letter
    local id = 'bees-high-' .. letter
    cfg.inventories[#cfg.inventories + 1] = { id = id, transposer = transposer, side = 3 }
    local access = {
        box = 2,
        inventory = id,
    }
    a.beeBoxes[#a.beeBoxes + 1] = access
end
-- Box 1: white/white/white; box 2: white/white/red, with the same owner across arrays.
-- Each array's two boxes share its load/unload ports on sides 1 and 2.
return example
