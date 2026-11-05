local U = dofile(ROOT .. 'ma_util.lua')
local S = dofile(ROOT .. 'ma_store.lua')
local C = dofile(ROOT .. 'ma_config.lua')
local G = dofile(ROOT .. 'ma_gui.lua')
local M = dofile(ROOT .. 'ma_materials.lua')
local F = dofile(ROOT .. 'ma_editor.lua')
local original = {
    arrays = { a = { done = 5 } },
    queue = {},
    nextId = 9,
    patterns = {
        a = {
            pattern = { label = '已记录配方' },
            unit = { fluid = 144 },
            steps = { { tier = 4 } },
        },
        b = { pattern = { label = '未记录配方' } },
    },
    poolCounts = { pool = { cell = 32 } },
    wiring = { storage = 'field' },
}
local disk, writes, failWrite
local store = S.new('', {}, {})
store.read = function(name)
    assert(name == 'multi.state')
    return disk and U.copy(disk)
end
store.write = function(name, value)
    assert(name == 'multi.state')
    if failWrite then
        error('模拟保存失败')
    end
    writes = writes + 1
    disk = U.copy(value)
end
disk, writes = U.copy(original), 0
local count = store.clearRecipes()
local expected = U.copy(original)
expected.patterns.a.unit, expected.patterns.a.steps = nil, nil
assert(count == 1 and writes == 1 and U.equal(disk, expected))
assert(store.clearRecipes() == 0 and writes == 1)
disk = nil
assert(store.clearRecipes() == 0 and writes == 1)
for _, field in ipairs({ 'admission', 'queue', 'batch', 'bee', 'lease' }) do
    disk, writes = U.copy(original), 0
    if field == 'admission' then
        disk.admission = {}
    elseif field == 'queue' then
        disk.queue = { {} }
    else
        disk.arrays.a[field] = {}
    end
    local before = U.copy(disk)
    assert(not pcall(store.clearRecipes) and writes == 0 and U.equal(before, disk))
end
disk, writes, failWrite = U.copy(original), 0, true
assert(not pcall(store.clearRecipes) and writes == 0 and U.equal(disk, original))
failWrite = false
print(
    '  PASS recipe clearing preserves other state, rejects pending work, and reports failed writes'
)

for _, size in ipairs({ { 80, 25 }, { 120, 38 }, { 160, 50 } }) do
    local ex = dofile(ROOT .. 'examples/two-arrays.lua')
    local ui = G.new({
        getResolution = function()
            return size[1], size[2]
        end,
        set = function() end,
        setForeground = function() end,
        setBackground = function() end,
    }, {}, { len = utf_len, sub = utf_sub, wlen = utf_width, char = utf_char }, C, M)
    local drafts, saves = 0, 0
    disk, writes = U.copy(original), 0
    local editor = F.new(ui, ex.cfg, ex.component, {
        U = U,
        clearRecipes = store.clearRecipes,
        draft = function()
            drafts = drafts + 1
        end,
        write = function()
            saves = saves + 1
        end,
    })
    local function click(id)
        editor:draw()
        for _, hit in ipairs(ui.hits) do
            if hit.id == id then
                assert(hit.x + hit.w - 1 <= size[1] and hit.y <= size[2])
                editor:event('touch', 'screen', hit.x, hit.y, 0)
                return
            end
        end
        error('missing control ' .. id)
    end
    editor:act('tab:4')
    click('clear-recipes')
    assert(editor.popup.clearRecipes and writes == 0)
    click('clear-recipes')
    editor:event('key_down', 'keyboard', 115, 31)
    editor:event('key_down', 'keyboard', 13, 28)
    assert(editor.popup.clearRecipes and saves == 0 and writes == 0)
    click('pick:1')
    assert(not editor.popup and writes == 0 and drafts == 0)
    click('clear-recipes')
    editor:draw()
    for _, hit in ipairs(ui.hits) do
        assert(
            hit.id ~= 'back',
            'clear confirmation must not show duplicate cancel or return buttons'
        )
    end
    click('pick:2')
    assert(not editor.popup and writes == 1 and drafts == 0 and U.equal(disk, expected))
    assert(editor.message:find('已保存', 1, true))
    disk, writes = U.copy(original), 0
    disk.arrays.a.batch = {}
    click('clear-recipes')
    click('pick:2')
    assert(writes == 0 and editor.message:find('仍有加工', 1, true))
    click('clear-recipes')
    editor:event('key_down', 'keyboard', 113, 16)
    assert(editor.done and writes == 0)
end
print(
    '  PASS clear button requires a separate confirmation, supports cancel, and cannot save through the dialog at three resolutions'
)

-- Exercise the real entrypoint: a later failure must not let the old engine save stale recipes back.
do
    local oldRequire, oldDofile, oldStderr = require, dofile, io.stderr
    local e, edited, emitted, configurationChecks
    local files = { ['multi.cfg'] = C.defaults(), ['multi.state'] = U.copy(original) }
    local entryStore = S.new('', {}, {})
    entryStore.read = function(name)
        return files[name] and U.copy(files[name])
    end
    entryStore.write = function(name, value)
        files[name] = U.copy(value)
    end
    local ui = {
        runtime = function() end,
        discardInput = function()
            return false
        end,
        runtimeEvent = function()
            return 'setup'
        end,
        edit = function(_, _, _, callbacks)
            assert(callbacks.clearRecipes() == 1)
            edited = true
            assert(not e.s.patterns.a.unit and not next(e.poolSupport))
            return false
        end,
    }
    require = function(name)
        if name == 'shell' then
            return {
                resolve = function()
                    return ROOT .. 'bec_multi.lua'
                end,
            }
        end
        if name == 'filesystem' then
            return {
                path = function()
                    return ROOT
                end,
            }
        end
        if name == 'computer' then
            return {
                realTime = function()
                    return 0
                end,
                uptime = function()
                    return 0
                end,
            }
        end
        if name == 'event' then
            return {
                pull = function()
                    if not emitted then
                        emitted = true
                        return 'key_down'
                    end
                end,
            }
        end
        if name == 'term' then
            return { clear = function() end }
        end
        return {}
    end
    dofile = function(path)
        local name = path:match('([^/]+)$')
        if name == 'ma_store.lua' then
            return {
                new = function()
                    return entryStore
                end,
            }
        end
        if name == 'ma_gui.lua' then
            return {
                new = function()
                    return ui
                end,
            }
        end
        if name == 'ma_recovery.lua' then
            return { check = function() end }
        end
        if name == 'ma_config.lua' then
            local config = oldDofile(path)
            config.validate = function()
                configurationChecks = (configurationChecks or 0) + 1
                assert(configurationChecks == 1, '模拟重新启动前失败')
            end
            return config
        end
        if name == 'ma_core.lua' then
            return {
                new = function(cfg, state, callbacks)
                    state.refill = { feeds = {} }
                    e = {
                        s = state,
                        io = callbacks,
                        ready = true,
                        recovered = true,
                        poolSupport = {
                            old = true,
                        },
                    }
                    e.save = function()
                        callbacks.save(state)
                    end
                    e.start = function() end
                    e.event = function() end
                    e.requestStop = function() end
                    e.tick = function() end
                    e.drain = function()
                        return true
                    end
                    e.pause = function()
                        e.save()
                    end
                    return e
                end,
            }
        end
        if name == 'ma_refill.lua' then
            return {
                new = function()
                    return { tick = function() end }
                end,
            }
        end
        return oldDofile(path)
    end
    io.stderr = { write = function() end }
    local ok, err = pcall(function()
        assert(loadfile(ROOT .. 'bec_multi.lua'))('run')
    end)
    require, dofile, io.stderr = oldRequire, oldDofile, oldStderr
    assert(ok, err)
    assert(edited and configurationChecks == 2 and not files['multi.state'].patterns.a.unit)
    assert(not files['multi.state'].patterns.a.steps and files['multi.state'].nextId == 9)
end
print(
    '  PASS clearing from S updates the paused engine so final exit cannot restore stale recipe records'
)
