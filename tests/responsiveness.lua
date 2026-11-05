local R = dofile(ROOT .. 'ma_refill.lua')
local U = dofile(ROOT .. 'ma_util.lua')
local M = dofile(ROOT .. 'ma_materials.lua')
local calls = { cells = 0, generators = 0, stock = 0 }
local feed = { id = 'raw', io = 'io', cells = {} }
local cfg = {
    feeds = { feed },
    generators = { { address = 'g', feed = 'raw' } },
    bands = {},
    fieldLimit = 1e15,
}
local stacks, stock = {}, {}
for i, material in ipairs(M) do
    feed.cells[i] = { inventory = 'drive', slot = i, material = material.source }
    stacks[i] = { storedFluidCount = 0, remainingFluidCount = material.unit * 10 }
    stock[material.condensate] = 2e6
    cfg.bands[i] = { material = material.source, low = 1e5, high = 1e6 }
end
local e = {
    cfg = cfg,
    s = { arrays = {}, queue = {} },
    M = M,
    U = U,
    now = 0,
    reserved = {},
    waiting = {},
    save = function() end,
    log = {
        size = function()
            return 12
        end,
        stack = function(_, _, slot)
            calls.cells = calls.cells + 1
            return stacks[slot]
        end,
    },
    storage = {
        getStoredCondensate = function()
            calls.stock = calls.stock + 1
            return U.copy(stock)
        end,
    },
}
e.io = {
    time = function()
        return e.now
    end,
    proxy = function()
        return {
            hasWork = function()
                calls.generators = calls.generators + 1
                return false
            end,
            getWorkProgress = function()
                calls.generators = calls.generators + 1
                return 0
            end,
            setWorkAllowed = function() end,
        }
    end,
}
local refill = R.new(e)
refill:tick()
calls = { cells = 0, generators = 0, stock = 0 }
for i = 1, 20 do
    e.now = i / 20
    refill:tick()
end
print(
    string.format(
        '  precache / 20 polls, %d materials: %d cell reads, %d generator reads, %d stock reads',
        #M,
        calls.cells,
        calls.generators,
        calls.stock
    )
)
assert(calls.cells == 0, 'settled fluid cells should not be reread on every UI loop')
assert(calls.generators <= 2 and calls.stock <= 1, 'background scan should run once per second')

-- A pending IO return must still be polled between background scans.
local received = 0
refill.receive = function()
    received = received + 1
end
e.now = 1.05
refill:tick()
assert(received == 1, 'IO return must not wait for the next full scan')
print('  PASS precache polling avoids idle cell reads and keeps IO return responsive')

local G = dofile(ROOT .. 'ma_gui.lua')
local F = dofile(ROOT .. 'ma_editor.lua')
local queued = { 'key_down', 'key_up', 'key_down', 'touch', 'component_added' }
local ui = setmetatable({
    event = {
        pull = function(timeout)
            assert(timeout == 0)
            return table.remove(queued, 1)
        end,
    },
}, G)
assert(not ui:discardInput() and #queued == 0)
queued = { 'key_down', 'interrupted', 'key_up' }
assert(ui:discardInput() and #queued == 0, 'page transition must preserve interruption')

-- Stale S events must not save and close the editor; the next fresh event still works.
queued = { 'key_down', 'key_up', 'key_down', 'key_up' }
local fresh = false
ui.event.pull = function(timeout)
    if #queued > 0 then
        return table.remove(queued, 1), 'keyboard', 115, 31
    end
    if timeout == 0 then
        return
    end
    fresh = true
    return 'key_down', 'keyboard', 115, 31
end
local editor = setmetatable({
    ui = ui,
    draw = function() end,
    act = function(self, action)
        assert(fresh and action == 'save', 'only a fresh S may save this page')
        self.done, self.saved = true, true
    end,
}, F)
assert(editor:run())
print('  PASS page changes discard stale keys, preserve Ctrl+C and accept fresh input')
