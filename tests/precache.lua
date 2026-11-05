local C = dofile(ROOT .. 'ma_config.lua')
local M = dofile(ROOT .. 'ma_materials.lua')
local U = dofile(ROOT .. 'ma_util.lua')
local G = dofile(ROOT .. 'ma_gui.lua')
local Editor = dofile(ROOT .. 'ma_editor.lua')
for _, size in ipairs({ { 80, 25 }, { 120, 38 }, { 160, 50 } }) do
    local ex = dofile(ROOT .. 'examples/two-arrays.lua')
    ex.component.proxy = function()
        error('configuration must not read slot capacity')
    end
    local gpu = {
        getResolution = function()
            return size[1], size[2]
        end,
        set = function() end,
        setForeground = function() end,
        setBackground = function() end,
    }
    local ui = G.new(
        gpu,
        {},
        { len = utf_len, sub = utf_sub, wlen = utf_width, char = utf_char },
        C,
        M
    )
    local e = Editor.new(ui, ex.cfg, ex.component, { U = U, write = function() end })
    for i, o in ipairs(e:objects()) do
        if o.kind == 'fluids' then
            e.pos = i
        end
    end
    local function click(id)
        e:draw()
        for _, h in ipairs(ui.hits) do
            if h.id == id then
                e:event('touch', 'screen', h.x, h.y, 0)
                return
            end
        end
        error('missing hit ' .. id)
    end
    click('fluid:2:enabled')
    local feed = ex.cfg.feeds[1]
    assert(#feed.cells == 2, 'one precache click must also enable replenishment')
    for i = 3, 19 do
        e:fluidField(i, 'enabled').set(true)
    end
    for i, c in ipairs(feed.cells) do
        assert(c.material == M[i].source and c.slot == (i - 1) % 10 + 1)
        assert(e:inventory(c.inventory).side == (i <= 10 and 0 or 2))
    end
    e:fluidField(2, 'enabled').set(false)
    assert(feed.cells[2].material == M[3].source and feed.cells[2].slot == 3)
    e:fluidField(2, 'enabled').set(true)
    assert(feed.cells[#feed.cells].slot == 2)
    e:draw()
    local name, toggle
    for _, h in ipairs(ui.hits) do
        assert(not h.id:match('^fluid:.*:slot$') and not h.id:match('^fluid:.*:supply$'))
        if h.id == 'fluid:1:name' then
            name = h
        end
        if h.id == 'fluid:1:enabled' then
            toggle = h
        end
    end
    assert(
        name and toggle and toggle.x < name.x and name.x - toggle.x <= 7,
        'status must sit beside the fluid name'
    )
    click('fluid:2:low')
    click('fluid-preset:1000000')
    local target = e.fluidRows[2].high
    for _, case in ipairs({
        { '0.5', 500000 },
        { '0.2', 100000 },
        { '2', 200000 },
        { '5', 1000000 },
    }) do
        click('fluid-scale:' .. case[1])
        assert(e.fluidRows[2].low == case[2])
        assert(e.fluidRows[2].high == target and e.fluidRows[1].low == 1000000)
    end
    click('fluid:2:high')
    e:event('clipboard', 'keyboard', '20000000')
    click('fluid-scale:0.2')
    assert(e.fluidRows[2].high == 4000000 and e.fluidRows[2].low == 1000000 and not e.edit)
    click('fluid:2:low')
    e:event('clipboard', 'keyboard', '3')
    click('fluid-scale:0.5')
    assert(e.fluidRows[2].low == 1)
    click('fluid-scale:0.5')
    assert(e.fluidRows[2].low == 0)
    click('fluid:2:high')
    e:event('clipboard', 'keyboard', '1')
    click('fluid-scale:0.5')
    assert(e.fluidRows[2].high == 1)
    click('fluid:2:high')
    e:event('clipboard', 'keyboard', '9007199254740991')
    click('fluid-scale:5')
    assert(e.fluidRows[2].high == 9007199254740991)
    click('fluid:2:high')
    e:event('clipboard', 'keyboard', 'bad')
    click('fluid-scale:2')
    assert(e.edit)
    click('fluid-preset:10000000')
    e:draw()
    for _, h in ipairs(ui.hits) do
        assert(h.x + h.w - 1 <= size[1] and h.y <= size[2])
    end
    feed.cells[1].slot = 7
    e:feedCell(feed, M[2].source, false)
    e:act('save')
    assert(e.saved, e.message)
    assert(feed.cells[1].slot == 1, 'saving must persist the displayed fixed placement')
    assert(
        #feed.cells == 19 and feed.cells[19].material == M[2].source,
        'enabled precache must have a replenishment cell after saving'
    )
    C.validate(ex.cfg, ex.component, U)
end
print('PASS fixed precache cells and single-toggle touch path at three resolutions')
