-- Valid configuration with simulated runtime state for presentation checks.
local C = dofile(ROOT .. 'ma_config.lua')
local M = dofile(ROOT .. 'ma_materials.lua')
local U = dofile(ROOT .. 'ma_util.lua')
local cfg = C.defaults()
cfg.fieldLimit = 1e9
local function address(n)
    return string.format('%08x-2f8a-41b3-925d-637aaf906312', n)
end
cfg.storage = address(1)
cfg.inventories = {}
for i = 1, 8 do
    local prefix = 'array-' .. i
    for _, spec in ipairs({ { 'box', 0 }, { 'load', 1 }, { 'return', 2 } }) do
        cfg.inventories[#cfg.inventories + 1] = {
            id = prefix .. '-' .. spec[1],
            transposer = address(100 + i),
            side = spec[2],
        }
    end
    cfg.beePools[i] = {
        id = 'pool-' .. i,
        cells = {
            { tier = 1, box = 1, slot = 1 },
            {
                tier = 2,
                box = 1,
                slot = 2,
            },
        },
    }
    cfg.arrays[i] = {
        address = address(i + 10),
        enabled = true,
        diode = address(i + 30),
        nodes = {},
        beePool = 'pool-' .. i,
        loadPort = prefix .. '-load',
        unloadPort = prefix .. '-return',
        beeBoxes = { { box = 1, inventory = prefix .. '-box' } },
    }
    for j = 1, 16 do
        cfg.arrays[i].nodes[j] = { address = address(1000 + i * 100 + j) }
    end
end
cfg.channels = {
    {
        id = '公共原料子网',
        patterns = { { address = address(50), slots = 36 }, { address = address(53), slots = 36 } },
        buffer = address(51),
        redstone = address(52),
        gateSide = 0,
    },
}
cfg.feeds = { { id = '预缓存设备', io = 'fluid-io', cells = {} } }
for _, spec in ipairs({ { 'fluid-drive-1', 0 }, { 'fluid-io', 1 }, { 'fluid-drive-2', 2 } }) do
    cfg.inventories[#cfg.inventories + 1] = {
        id = spec[1],
        transposer = address(60),
        side = spec[2],
    }
end
for i = 1, 3 do
    cfg.generators[i] = { address = address(39 + i), feed = '预缓存设备' }
end
local e = {
    cfg = cfg,
    arrays = cfg.arrays,
    M = M,
    stock = {},
    reserved = {},
    ready = true,
    status = {},
    errors = {},
    observations = {},
    provided = {},
    s = {
        queue = {},
        arrays = {},
        patterns = { demo = { pattern = { label = '演示配方 A' } } },
    },
}
for i = 1, 19 do
    cfg.bands[i] = { material = M[i].source, low = 1000000, high = 20000000 }
    cfg.feeds[1].cells[i] = {
        material = M[i].source,
        inventory = i <= 10 and 'fluid-drive-1' or 'fluid-drive-2',
        slot = (i - 1) % 10 + 1,
    }
    e.stock[M[i].condensate] = math.floor(1e7 + i * 400000)
    e.reserved[M[i].condensate] = i < 4 and 3000000 or 0
end
e.stock[M[5].condensate] = 200000
e.s.queue[1] = {}
for i, a in ipairs(e.arrays) do
    local s = { done = 128 * i }
    e.s.arrays[a.address] = s
    if i < 4 then
        s.batch = { phase = i == 3 and 'wait' or 'run', count = 128, key = 'demo', workers = {} }
        if i < 3 then
            e.provided[a.address] = 2
            s.lease = { [2] = { tier = 2, box = 1, slot = 2 } }
        end
        e.observations[a.address] = {}
        for j = 1, 16 do
            s.batch.workers[j] = { address = a.nodes[j].address, count = 8 }
            e.observations[a.address][j] = {
                address = a.nodes[j].address,
                parallel = 8,
                tier = i == 1 and 2 or j % 3 + 1,
                progress = 80000 - j * 4000,
                length = 100000,
                fast = i == 1,
            }
        end
    end
end
e.status['公共原料子网'] = '等待即将空闲的阵列（最多 3 秒）'
C.defaults(cfg)
C.validate(cfg, nil, U)
return {
    cfg = cfg,
    engine = e,
    refill = {
        detail = { ['预缓存设备'] = '库存充足' },
        s = { active = {}, feeds = { ['预缓存设备'] = { pending = {} } } },
    },
    component = {
        list = function()
            return function() end
        end,
    },
}
