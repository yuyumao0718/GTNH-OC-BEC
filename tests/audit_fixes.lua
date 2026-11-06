local C = dofile(ROOT .. 'ma_config.lua')
local U = dofile(ROOT .. 'ma_util.lua')
local M = dofile(ROOT .. 'ma_materials.lua')
local G = dofile(ROOT .. 'ma_gui.lua')
local F = dofile(ROOT .. 'ma_editor.lua')
local make = assert(loadfile(ROOT .. 'tests/simplified.lua'))('fixture')

local function newUI(size)
    return G.new({
        getResolution = function()
            return size[1], size[2]
        end,
        set = function() end,
        setForeground = function() end,
        setBackground = function() end,
    }, {}, { len = utf_len, sub = utf_sub, wlen = utf_width, char = utf_char }, C, M)
end

local function text(ui)
    local result = {}
    for _, row in ipairs(ui.rows) do
        for _, span in ipairs(row) do
            result[#result + 1] = span[2]
        end
    end
    return table.concat(result, ' | ')
end

local function field(editor, label)
    for _, f in ipairs(editor:form()) do
        if f.label == label then
            return f
        end
    end
    error('missing field: ' .. label)
end

local function click(editor, id)
    editor:draw()
    for _, h in ipairs(editor.ui.hits) do
        if h.id == id then
            assert(h.x + h.w - 1 <= editor.ui.w and h.y <= editor.ui.h)
            editor:event('touch', 'screen', h.x, h.y, 0)
            return
        end
    end
    error('missing control: ' .. id)
end

local function untilPhase(w, phase)
    for _ = 1, 2000 do
        w.tick()
        local b = w.state.arrays.a1.batch
        if b and b.phase == phase then
            return b
        end
    end
    error('phase not reached: ' .. phase)
end

do
    local ex = dofile(ROOT .. 'examples/shared-bees.lua')
    assert(C.validate(ex.cfg, ex.component, U))
    local a, b = ex.cfg.arrays[1], ex.cfg.arrays[2]
    local inv = U.index(ex.cfg.inventories)
    local before = U.copy(inv[b.loadPort])
    inv[b.loadPort].transposer = inv[a.loadPort].transposer
    inv[b.loadPort].side = inv[a.loadPort].side
    local ok, err = pcall(C.validate, ex.cfg, ex.component, U)
    assert(not ok and err:find('ME-IO 端口重复分配', 1, true))
    inv[b.loadPort].transposer, inv[b.loadPort].side = before.transposer, before.side
    assert(C.validate(ex.cfg, ex.component, U))
    local f = ex.cfg.feeds[1]
    inv[f.io].transposer, inv[f.io].side = inv[a.loadPort].transposer, inv[a.loadPort].side
    ok, err = pcall(C.validate, ex.cfg, ex.component, U)
    assert(not ok and err:find('ME-IO 端口重复分配', 1, true))
end
print(
    '  PASS physical ME-IO aliases are rejected across arrays and precache; shared pools remain valid'
)

for _, size in ipairs({ { 80, 25 }, { 120, 38 }, { 160, 50 } }) do
    local ex = dofile(ROOT .. 'examples/shared-bees.lua')
    local ui = newUI(size)
    local writes = 0
    local editor = F.new(ui, ex.cfg, ex.component, {
        U = U,
        write = function() end,
        draft = function()
            writes = writes + 1
        end,
    })
    editor:act('tab:3')
    local original = U.copy(ex.cfg)
    editor:activate(field(editor, '关联的传送节点：16 个'))
    assert(editor.popup and writes == 0 and U.equal(original, ex.cfg))
    click(editor, 'refresh')
    assert(writes == 0)
    click(editor, 'back')
    editor:activate(field(editor, '绑定未分配节点'))
    assert(editor.message:find('已绑定 0 个节点', 1, true) and writes == 0)
    local a = ex.cfg.arrays[1]
    local node = table.remove(a.nodes)
    editor:activate(field(editor, '绑定未分配节点'))
    assert(writes == 1 and #a.nodes == 16 and a.nodes[16].address == node.address)
    assert(editor.message:find('已绑定 1 个节点', 1, true))
    local otherNodes = ex.cfg.arrays[2].nodes
    ex.cfg.arrays[2].nodes = {}
    editor:activate(field(editor, '绑定未分配节点'))
    assert(editor.popup and writes == 1)
    assert(editor.message:find('未分配节点超过本阵列剩余位置', 1, true))
    ex.cfg.arrays[2].nodes = otherNodes
    click(editor, 'back')

    editor:activate(field(editor, '算力奇点等待阈值（秒）'))
    editor:event('clipboard', 'keyboard', 'bad')
    click(editor, 'confirm-edit')
    assert(editor.edit and editor.message:find('请输入', 1, true))
    click(editor, 'cancel-edit')
    assert(not editor.edit and ex.cfg.singularityWait == 300 and writes == 1)
    editor:activate(field(editor, '算力奇点等待阈值（秒）'))
    editor:event('clipboard', 'keyboard', '120')
    click(editor, 'confirm-edit')
    assert(not editor.edit and ex.cfg.singularityWait == 120 and writes == 2)
    editor:activate(field(editor, '阵列名称'))
    editor:event('clipboard', 'keyboard', '未保存名称')
    click(editor, 'cancel-edit')
    assert(a.name ~= '未保存名称' and writes == 2)
    editor:activate(field(editor, '阵列名称'))
    editor:event('clipboard', 'keyboard', '测试阵列')
    click(editor, 'confirm-edit')
    assert(a.name == '测试阵列' and writes == 3)
    editor:act('tab:4')
    editor:activate(field(editor, '主网样板 ME 接口：2 个'))
    assert(editor.popup and writes == 3)
    click(editor, 'back')
    editor:act('tab:3')
    local door = a.diode
    a.diode = ''
    editor:activate(field(editor, '麦克斯韦门：未绑定'))
    assert(a.diode == door and not editor.popup and writes == 4)

    editor:act('tab:2')
    for i, o in ipairs(editor:objects()) do
        if o.kind == 'pool' then
            editor.pos = i
            break
        end
    end
    editor:activate(field(editor, '新增箱子'))
    assert(writes == 5)
    editor:act('tab:3')
    field(editor, '蜂群转运器').set('TA')
    field(editor, '箱子 3 的方向').set(4)
    click(editor, 'save')
    assert(editor.saved, editor.message)
    assert(C.validate(ex.cfg, ex.component, U))

    local empty = dofile(ROOT .. 'examples/two-arrays.lua')
    empty.cfg.beePools = {}
    editor = F.new(ui, empty.cfg, empty.component, { U = U, write = function() end })
    editor:act('tab:3')
    editor:activate(field(editor, '使用的蜂群池'))
    editor:draw()
    assert(
        text(ui):find('新增蜂群池', 1, true)
            and not text(ui):find('没有可选设备', 1, true)
    )
end
print(
    '  PASS picker draft writes, binding messages, edit confirmation/cancel and empty-box saves at all resolutions'
)

do
    local w = make(1, 2)
    w.stock.entangled_neutronium = 0
    untilPhase(w, 'wait')
    local ui = newUI({ 160, 50 })
    ui:runtime(w.e, w.r)
    assert(text(ui):find('#1  已取料 1 份', 1, true))
end
do
    local w = make(1, 3, { nodes = 3, stageTicks = 400 })
    local b = untilPhase(w, 'run')
    w.nodes['a1:n1'].active = false
    w.nodes['a1:n2'].progress = 1
    w.e:recover(w.cfg.arrays[1], w.state.arrays.a1)
    b = w.state.arrays.a1.batch
    assert(#b.workers == 2 and b.workers[1].address == 'a1:n2')
    w.e:array(w.cfg.arrays[1])
    w.e.io.proxy = function()
        error('GUI must not read hardware')
    end
    local ui = newUI({ 160, 50 })
    ui:runtime(w.e, w.r)
    assert(text(ui):find('#1  空闲', 1, true))
    assert(text(ui):find('#2  1 并行', 1, true) and text(ui):find('#3  1 并行', 1, true))
    w.cfg.arrays[1].nodes[1], w.cfg.arrays[1].nodes[3] =
        w.cfg.arrays[1].nodes[3], w.cfg.arrays[1].nodes[1]
    ui:runtime(w.e, w.r)
    assert(text(ui):find('#1  1 并行', 1, true) and text(ui):find('#3  空闲', 1, true))
end
print(
    '  PASS accepted input and recovered sparse/reordered node identities display without hardware reads'
)

do
    local w = make(1, 2, { stageTicks = 400 })
    untilPhase(w, 'run')
    for _ = 1, 80 do
        w.tick()
    end
    local progress = w.nodes['a1:n1'].progress
    w.inputName = 'unexpected-output'
    w.inventories.receiver.slots[1].contents = 1
    for _ = 1, 80 do
        w.tick()
    end
    assert(w.e.errors.lane:find('已停止接单', 1, true))
    assert(not w.e.errors.lane:find('机器保持暂停', 1, true))
    assert(w.nodes['a1:n1'].progress > progress and w.closed)
end
do
    local w = make(1, 0)
    w.addFeed('feed', 1)
    w.boot()
    local ui = newUI({ 160, 50 })
    w.e.stock = { entangled_neutronium = 750 }
    w.e.reserved = {}
    w.r.s.active['molten.neutronium'] = true
    ui:runtime(w.e, w.r)
    assert(text(ui):find('等待预缓存', 1, true))
    w.r.s.feeds.feed.pending[1] = { amount = 576 }
    ui:runtime(w.e, w.r)
    assert(text(ui):find('正在预缓存', 1, true))
    w.r.s.feeds.feed.pending = {}
    w.r.s.feeds.feed.loading = { index = 1, phase = 'out' }
    ui:runtime(w.e, w.r)
    assert(text(ui):find('正在预缓存', 1, true))
    w.r.s.feeds.feed.loading = nil
    w.r.s.active['molten.neutronium'] = false
    ui:runtime(w.e, w.r)
    assert(not text(ui):find('等待预缓存', 1, true) and text(ui):find('充足', 1, true))
end
do
    local w = make(2, 2, { nodes = 2 })
    w.finish()
    local key = next(w.state.patterns)
    w.cfg.beePools[1].cells[2] = nil
    w.boot(w.state)
    w.state.queue = { { key = key, count = 1, id = 30 } }
    w.e:array(w.cfg.arrays[1])
    assert(w.e.status.a1:find('当前待分配订单', 1, true))
    w.e:schedule()
    w.e:array(w.cfg.arrays[1])
    assert(w.e.status.a1 == '空闲')
    w.cfg.beePools[1].cells[2] = { tier = 2, box = 1, slot = 2 }
    w.boot(w.state)
    w.e:array(w.cfg.arrays[1])
    assert(w.e.status.a1 == '空闲')
end
print('  PASS admission fault scope, precache activity and current-order-only capability messages')

do
    local I = dofile(ROOT .. 'ma_intake.lua')
    local function pattern(names)
        local inputs = {}
        for i, name in ipairs(names) do
            inputs[i] = { name = name, damage = 0, size = 1 }
        end
        return {
            isCraftable = false,
            inputs = inputs,
            outputs = { { name = 'output', damage = 0, size = 1 } },
        }
    end
    local a, b = pattern({ 'a', 'b' }), pattern({ 'a', 'c' })
    local catalog = I.catalog({ a, b })
    assert(not pcall(I.catalog, { a, a }))
    assert(not pcall(I.catalog, { a, pattern({ 'a' }) }))
    assert(I.identify(catalog, I.inventory(pattern({ 'a' }).inputs)) == nil)
    assert(I.identify(catalog, I.inventory(a.inputs)).inputs[I.key(a.inputs[2])] == 1)
    assert(not pcall(I.identify, catalog, I.inventory(pattern({ 'a', 'b', 'c' }).inputs)))
end
print(
    '  PASS catalog uniqueness still rejects ambiguous templates; partial and mixed deliveries stay distinct'
)
