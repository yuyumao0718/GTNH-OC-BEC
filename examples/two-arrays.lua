-- Wiki example: readable component aliases, not addresses from a game world.
local C = dofile(ROOT .. 'ma_config.lua')
local cfg = C.defaults()
cfg.storage = 'FIELD'
cfg.fieldLimit = 1e12
cfg.bands = { { material = 'molten.neutronium', low = 1e6, high = 2e6 } }
local devices = {}
local function device(address, kind, name)
    devices[address] = { kind = kind, name = name }
    return address
end
device('FIELD', 'bec_storage')
device('REDSTONE', 'redstone')
device('P1', 'pattern')
device('P2', 'pattern')
device('READ-R', 'me_controller')
for _, name in ipairs({ 'TA', 'TB', 'TF' }) do
    device(name, 'transposer')
end
local function inventory(id, transposer, side)
    cfg.inventories[#cfg.inventories + 1] = { id = id, transposer = transposer, side = side }
end
for _, letter in ipairs({ 'A', 'B' }) do
    local t = 'T' .. letter
    cfg.beePools[#cfg.beePools + 1] = {
        id = 'pool-' .. letter,
        cells = { { tier = 1, box = 1, slot = 1 }, { tier = 2, box = 1, slot = 2 } },
    }
    inventory('bees-' .. letter, t, 0)
    inventory('load-' .. letter, t, 1)
    inventory('unload-' .. letter, t, 2)
    local a = {
        address = device('ARRAY-' .. letter, 'gt_machine', 'multi.bec.assembler'),
        enabled = true,
        diode = device('GATE-' .. letter, 'bec_diode'),
        nodes = {},
        beePool = 'pool-' .. letter,
        loadPort = 'load-' .. letter,
        unloadPort = 'unload-' .. letter,
        beeBoxes = {
            {
                box = 1,
                inventory = 'bees-' .. letter,
            },
        },
    }
    for i = 1, 16 do
        a.nodes[i] = { address = device(string.format('%s-N%02d', letter, i), 'bec_io_node') }
    end
    cfg.arrays[#cfg.arrays + 1] = a
end
inventory('raw', 'TF', 0)
inventory('fill', 'TF', 1)
cfg.feeds = {
    {
        id = 'raw-net',
        io = 'fill',
        cells = {
            {
                material = 'molten.neutronium',
                slot = 1,
                inventory = 'raw',
            },
        },
    },
}
cfg.generators = {
    { address = device('GEN-1', 'gt_machine', 'multi.bec.generator'), feed = 'raw-net' },
    { address = device('GEN-2', 'gt_machine', 'multi.bec.generator'), feed = 'raw-net' },
}
cfg.channels = {
    {
        id = 'shared-receiver',
        patterns = { { address = 'P1', slots = 36 }, { address = 'P2', slots = 36 } },
        buffer = 'READ-R',
        redstone = 'REDSTONE',
        gateSide = 5,
    },
}
local component = {}
function component.list()
    local keys = {}
    for key in pairs(devices) do
        keys[#keys + 1] = key
    end
    table.sort(keys)
    local i = 0
    return function()
        i = i + 1
        local key = keys[i]
        if key then
            return key, devices[key].kind
        end
    end
end
function component.methods(address)
    local d = devices[address]
    return d.name and { getName = true }
        or d.kind == 'pattern' and { getInterfacePattern = true }
        or (d.kind == 'buffer' or d.kind == 'me_controller') and { getItemsInNetwork = true }
        or {}
end
function component.type(address)
    return devices[address] and devices[address].kind
end
function component.invoke(address, method)
    assert(method == 'getName')
    return devices[address].name
end
return { cfg = C.defaults(cfg), component = component }
