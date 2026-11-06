local C, M, U, G =
    dofile(ROOT .. 'ma_config.lua'),
    dofile(ROOT .. 'ma_materials.lua'),
    dofile(ROOT .. 'ma_util.lua'),
    dofile(ROOT .. 'ma_gui.lua')
local unicode = { len = utf_len, sub = utf_sub, wlen = utf_width, char = utf_char }

for _, size in ipairs({ { 80, 25 }, { 120, 38 }, { 160, 50 } }) do
    local pixels, writes = {}, {}
    local fg, bg
    local gpu = {
        getResolution = function()
            return size[1], size[2]
        end,
        setForeground = function(value)
            fg = value
        end,
        setBackground = function(value)
            bg = value
        end,
        set = function(x, y, text)
            assert(x >= 1 and y >= 1 and y <= size[2] and x + utf_width(text) - 1 <= size[1])
            writes[#writes + 1] = { x, y, text }
            pixels[y] = pixels[y] or {}
            for i = 1, utf_len(text) do
                local ch = utf_sub(text, i, i)
                pixels[y][x] = ch .. ':' .. fg .. ':' .. bg
                x = x + 1
                if utf_width(ch) == 2 then
                    pixels[y][x] = ':' .. fg .. ':' .. bg
                    x = x + 1
                end
            end
        end,
    }
    local ui = G.new(gpu, {}, unicode, C, M)
    local f = dofile(ROOT .. 'tests/gui_fixture.lua')
    local e, r = f.engine, f.refill
    local a = e.arrays[2]
    e.provided = { [a.address] = 2 }
    e.io = {
        proxy = function()
            error('rendering queried machine components')
        end,
    }
    ui.arrayIndex = 2
    ui.selected[2] = 2
    if size[1] < 120 then
        ui.tab, ui.nodeOnly = 2, true
    end
    ui:runtime(e, r)
    local function text()
        local spans = {}
        for _, row in ipairs(ui.rows) do
            for _, span in ipairs(row) do
                spans[#spans + 1] = span[2]
            end
        end
        return table.concat(spans, '|')
    end
    assert(text():find('演示配方 A ×128', 1, true))
    assert(text():find('蜂群 T2', 1, true) and text():find('等T3', 1, true))
    assert(text():find('76.0%', 1, true))
    if size[1] == 160 then
        assert(ui.nodePages == 1 and text():find('#16', 1, true))
    end
    local previous, firstNode
    for y, row in ipairs(ui.rows) do
        for _, span in ipairs(row) do
            if span[2]:match('^#%d+  ') then
                assert(not previous or y == previous + 2, 'each node must occupy two rows')
                firstNode = firstNode or { x = span[1], y = y }
                previous = y
            end
        end
    end
    local barWidth = size[1] >= 120 and 29 or size[1] - 19
    local longBar = false
    for _, span in ipairs(ui.rows[firstNode.y + 1]) do
        longBar = longBar or span[1] == firstNode.x and span[2] == string.rep('━', barWidth)
    end
    assert(longBar, 'progress should use the full second row beside percentage and status')
    local nextPage
    for _, hit in ipairs(ui.hits) do
        if hit.id == 'node+' then
            nextPage = hit
        end
    end
    if size[1] == 160 then
        assert(not nextPage, 'a single node page must not cover the last progress bar')
    else
        assert(nextPage and ui.nodePages > 1)
        ui:runtimeEvent('touch', nil, nextPage.x, nextPage.y)
        ui:runtime(e, r)
        assert(ui.nodePage == 2 and not text():find('#1  ', 1, true))
        ui.nodePage = 1
        ui:runtime(e, r)
    end
    writes = {}
    ui:runtime(e, r)
    assert(#writes == 0, 'unchanged contents redrew the GPU')
    for _, n in pairs(e.observations[a.address]) do
        n.progress = n.progress + 1000
    end
    ui:runtime(e, r)
    if size[1] >= 120 then
        for _, write in ipairs(writes) do
            assert(
                write[1] > size[1] - 49,
                'node progress repainted the inventory panel or its border'
            )
        end
    end
    local function compareFull()
        local incremental = U.copy(pixels)
        ui.cache = {}
        ui:runtime(e, r)
        assert(U.equal(incremental, pixels), 'partial repaint differs from a full redraw')
    end
    compareFull()
    e.s.patterns.demo.pattern.label = '短名'
    e.observations[a.address][1].progress = 1
    e.provided[a.address] = nil
    ui:runtime(e, r)
    compareFull()
    assert(text():find('等蜂群', 1, true))
    for _, n in pairs(e.observations[a.address]) do
        n.fast = true
    end
    ui:runtime(e, r)
    compareFull()
    assert(text():find('快速加工', 1, true) and not text():find('76.0%', 1, true))
    for _, tab in ipairs({ 3, 1, 2 }) do
        ui.tab, ui.nodeOnly = tab, false
        ui:runtime(e, r)
        compareFull()
    end

    local make = assert(loadfile(ROOT .. 'tests/simplified.lua'))('fixture')
    local w = make(2, 32, { nodes = 16, stageTicks = 300 })
    w.cfg.fieldLimit = 1e9
    w.stock.entangled_neutronium = 1e8
    local batch
    for _ = 1, 500 do
        w.tick()
        batch = w.state.arrays.a1.batch
        if batch and batch.phase == 'admit' then
            break
        end
    end
    assert(batch and batch.phase == 'admit')
    e, r = w.e, w.r
    e.io.proxy = function()
        error('rendering queried machine components')
    end
    ui.tab, ui.selected[2], ui.arrayIndex, ui.nodeOnly = 2, 1, 1, size[1] < 120
    ui:runtime(e, r)
    compareFull()
    assert(text():find('节点取料', 1, true) and text():find('取料中', 1, true))
    assert(not text():find('等待凝聚物', 1, true))

    batch.phase = 'wait'
    batch.reserve = { entangled_neutronium = batch.count * 144 }
    e.s.admission = nil
    e.resourcesFresh, e.resourceScan = false, nil
    e.free = nil
    ui:runtime(e, r)
    assert(text():find('核对凝聚物库存', 1, true))
    e.free = U.copy(batch.reserve)
    ui:runtime(e, r)
    assert(text():find('核对凝聚物库存', 1, true))
    e.resourcesFresh, e.free = true, U.copy(batch.reserve)
    e.resourceScan = {}
    ui:runtime(e, r)
    assert(text():find('核对凝聚物库存', 1, true))
    e.resourceScan = nil
    e.free.entangled_neutronium = 0
    ui:runtime(e, r)
    assert(text():find('等待凝聚物', 1, true))
    e.free = U.copy(batch.reserve)
    ui:runtime(e, r)
    assert(text():find('准备加工', 1, true))

    batch.reserve = { entangled_neutronium = 14400000000 }
    e.cfg.fieldLimit, e.resourcesFresh = 1000000000, false
    e.status.a1 = '节点取料'
    ui:runtime(e, r)
    compareFull()
    assert(text():find('场强容量不足', 1, true))
    assert(not text():find('等待凝聚物', 1, true))
    local detail = {}
    for y = size[2] - 4, size[2] - 3 do
        for x = 2, size[1] - 1 do
            detail[#detail + 1] = (pixels[y][x] or ''):match('^(.-):') or ''
        end
    end
    local rendered = table.concat(detail):gsub('%s', '')
    assert(rendered:find('本批需要14400000000L，场强容量仅1000000000L', 1, true))
    assert(rendered:find('按Ctrl+C暂停，提高约束场强度后续做。', 1, true))
    if size[1] == 80 then
        assert(
            not rendered:find('蜂群池', 1, true),
            'bee summary overwrote the second status line'
        )
    end

    batch.phase, batch.granted = 'return', true
    e.status.a1 = '加工中'
    ui.nodeOnly = size[1] < 120
    ui:runtime(e, r)
    compareFull()
    assert(text():find('加工完成', 1, true) and text():find('本批完成', 1, true))
    assert(not text():find('加工中', 1, true) and not text():find('已取料', 1, true))
    if size[1] == 160 then
        assert(text():find('#16  本批完成', 1, true) and ui.nodePages == 1)
    end

    local shortage = make(1, 16, { nodes = 16, stageTicks = 300 })
    shortage.stock.entangled_neutronium = 0
    e, r = shortage.e, shortage.r
    local proxy, waiting, betweenSamples = e.io.proxy, 0, 0
    for _ = 1, 100 do
        shortage.tick()
        local b = e.s.arrays.a1.batch
        if b and b.phase == 'wait' and e.free and not e.resourceScan then
            e.io.proxy = function()
                error('rendering queried machine components')
            end
            ui:runtime(e, r)
            compareFull()
            e.io.proxy = proxy
            assert(text():find('等待凝聚物', 1, true))
            assert(not text():find('核对凝聚物库存', 1, true))
            waiting = waiting + 1
            if e.stockAt < e.now then
                betweenSamples = betweenSamples + 1
            end
        end
    end
    assert(waiting > 60 and betweenSamples > 60, 'shortage was not tested between stock samples')
    -- Overlapping backgrounds, a wide character crossing the dirty edge, removed text and color changes.
    local function sample(short)
        ui:begin('中文')
        ui:put(2, 5, '甲乙丙丁')
        ui:put(5, 5, short and '短' or '较长的文字', nil, short and 0xff0000 or 0x00ff00)
        ui:put(70, 5, short and '' or '右侧')
        ui:paint()
    end
    sample(false)
    sample(true)
    local incremental = U.copy(pixels)
    ui.cache = {}
    sample(true)
    assert(U.equal(incremental, pixels))
end
print(
    '  PASS progress, admission and completion states; full capacity instructions and partial redraws at three resolutions'
)
