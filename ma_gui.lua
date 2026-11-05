-- Render cached observations; redraw only the spans touched by a change.
local G = {}
G.__index = G
local ink = {
    bg = 0x101820,
    panel = 0x1C2936,
    selected = 0x263E50,
    text = 0xE1EAF0,
    dim = 0x91A4B5,
    cyan = 0x50D9DD,
    green = 0x78D6A1,
    amber = 0xFFD080,
    red = 0xFF8989,
}
G.ink = ink
local function exact(n)
    return n ~= nil and string.format('%.0f', n) or '--'
end

local function amount(n)
    if n == nil then
        return '--'
    end
    for _, v in ipairs({ { 1e15, 'P' }, { 1e12, 'T' }, { 1e9, 'G' }, { 1e6, 'M' }, { 1e3, 'k' } }) do
        if n >= v[1] then
            return string.format('~%.2f%s', n / v[1], v[2])
        end
    end
    return exact(n)
end
G.amount = amount
G.exact = exact
function G.new(gpu, event, unicode, config, materials)
    local self = setmetatable({
        gpu = gpu,
        event = event,
        u = unicode,
        C = config,
        M = materials,
        cache = {},
        tab = 1,
        selected = { 1, 1, 1 },
        arrayIndex = 1,
        nodePage = 1,
    }, G)
    local w, h = gpu.getResolution()
    if w < 80 or h < 25 then
        local mw, mh = gpu.maxResolution()
        gpu.setResolution(math.min(120, mw), math.min(38, mh))
    end
    self.w, self.h = gpu.getResolution()
    assert(
        self.w >= 80 and self.h >= 25,
        '中文配置需要至少 80×25 分辨率，请使用二级或三级显卡与屏幕'
    )
    return self
end

function G:clip(s, n)
    s = tostring(s or ''):gsub('§.', ''):gsub('[\r\n]', ' ')
    while self.u.wlen(s) > n and #s > 0 do
        s = self.u.sub(s, 1, self.u.len(s) - 1)
    end
    return s
end

function G:begin(title)
    self.w, self.h = self.gpu.getResolution()
    self.rows = {}
    self.hits = {}
    for y = 1, self.h do
        self.rows[y] = {}
    end
    self:put(1, 1, string.rep(' ', self.w), self.w, ink.cyan, ink.panel)
    self:put(2, 1, title, self.w - 3, ink.cyan, ink.panel)
end

function G:put(x, y, text, width, fg, bg)
    width = math.min(width or self.w - x + 1, self.w - x + 1)
    if y < 1 or y > self.h or x < 1 or width < 1 then
        return
    end
    self.rows[y][#self.rows[y] + 1] = { x, self:clip(text, width), fg or ink.text, bg or ink.bg }
end

function G:button(id, x, y, label, selected, width)
    local text = self:clip('[' .. label .. ']', width or self.w - x + 1)
    local n = self.u.wlen(text)
    self:put(x, y, text, n, selected and ink.bg or ink.cyan, selected and ink.cyan or ink.panel)
    self.hits[#self.hits + 1] = { id = id, x = x, y = y, w = n }
end

function G:control(id, x, y, label, selected, width)
    local text = self:clip(label, width or self.w - x + 1)
    local n = width or self.u.wlen(text)
    self:put(
        x,
        y,
        text .. string.rep(' ', math.max(0, n - self.u.wlen(text))),
        n,
        selected and ink.bg or ink.cyan,
        selected and ink.cyan or ink.panel
    )
    self.hits[#self.hits + 1] = { id = id, x = x, y = y, w = n }
end

function G:hit(x, y)
    for _, h in ipairs(self.hits) do
        if y == h.y and x >= h.x and x < h.x + h.w then
            return h.id
        end
    end
end

function G:discardInput()
    local interrupted = false
    while true do
        local name = self.event.pull(0)
        if not name then
            return interrupted
        end
        interrupted = interrupted or name == 'interrupted'
    end
end

function G:bar(x, y, width, ratio, color)
    self:put(x, y, string.rep('━', width), width, ink.panel)
    self:put(
        x,
        y,
        string.rep('━', math.floor(width * math.max(0, math.min(1, ratio or 0)))),
        width,
        color or ink.cyan
    )
end

function G:frame(x, top, width, bottom)
    self:put(x, top, '┌' .. string.rep('─', width - 2) .. '┐', width, ink.dim)
    for y = top + 1, bottom - 1 do
        self:put(x, y, '│', 1, ink.dim)
        self:put(x + width - 1, y, '│', 1, ink.dim)
    end
    self:put(x, bottom, '└' .. string.rep('─', width - 2) .. '┘', width, ink.dim)
end

function G:wrap(x, y, text, width, lines, color)
    text = tostring(text or ''):gsub('[\r\n]', ' ')
    for line = 0, lines - 1 do
        local part = self:clip(text, width)
        self:put(x, y + line, part, width, color)
        text = self.u.sub(text, self.u.len(part) + 1)
    end
end

function G:paint()
    local w, h = self.w, self.h
    if w ~= self.width or h ~= self.height then
        self.cache = {}
        self.width, self.height = w, h
    end
    local foreground, background
    local function colors(fg, bg)
        if fg ~= foreground then
            self.gpu.setForeground(fg)
            foreground = fg
        end
        if bg ~= background then
            self.gpu.setBackground(bg)
            background = bg
        end
    end
    for y, row in ipairs(self.rows) do
        local previous = self.cache[y]
        local first, last = w + 1, 0
        local function include(span)
            if span and span[2] ~= '' then
                first = math.min(first, span[1])
                last = math.max(last, span[1] + self.u.wlen(span[2]) - 1)
            end
        end
        if not previous then
            first, last = 1, w
        else
            for i = 1, math.max(#row, #previous) do
                local a, b = row[i], previous[i]
                if
                    not a
                    or not b
                    or a[1] ~= b[1]
                    or a[2] ~= b[2]
                    or a[3] ~= b[3]
                    or a[4] ~= b[4]
                then
                    include(a)
                    include(b)
                end
            end
        end
        if last >= first then
            -- Include overlapping backgrounds and whole wide characters before clearing.
            local changed
            repeat
                local left, right = first, last
                for _, spans in ipairs({ previous or {}, row }) do
                    for _, span in ipairs(spans) do
                        if span[1] <= last and span[1] + self.u.wlen(span[2]) > first then
                            include(span)
                        end
                    end
                end
                changed = left ~= first or right ~= last
            until not changed
            colors(ink.text, ink.bg)
            self.gpu.set(first, y, string.rep(' ', last - first + 1))
            for _, s in ipairs(row) do
                if s[2] ~= '' and s[1] <= last and s[1] + self.u.wlen(s[2]) > first then
                    colors(s[3], s[4])
                    self.gpu.set(s[1], y, s[2])
                end
            end
        end
        self.cache[y] = row
    end
    colors(0xFFFFFF, 0x000000)
end

function G:recordName(cfg, section, value)
    local key = type(value) == 'table' and (value.id or value.address) or value
    for i, r in ipairs(cfg[section] or {}) do
        if r == value or key and (r.id == key or r.address == key) then
            if r.name and r.name ~= '' then
                return r.name
            end
            if section == 'channels' and #cfg[section] == 1 then
                return '公共原料子网'
            end
            if section == 'feeds' and #cfg[section] == 1 then
                return '预缓存设备'
            end
            local names = {
                arrays = '观测阵列',
                beePools = '蜂群池',
                channels = '接收子网',
                feeds = '预缓存设备',
                inventories = '元件容器连接',
            }
            return (names[section] or '配置') .. ' ' .. i
        end
    end
    return '未选择'
end

function G:choices(f, cfg, devices)
    local rows = {}
    if f.source:sub(1, 7) == 'device:' then
        for _, d in ipairs(devices) do
            if self.C.matches(d, f.source:sub(8)) then
                local names = {
                    me_controller = 'ME 控制器',
                    me_interface = 'ME 接口',
                    transposer = '转运器',
                    redstone = '红石 I/O',
                    bec_storage = '约束场',
                    bec_diode = '麦克斯韦门',
                    bec_io_node = '传送节点',
                }
                local machines = {
                    ['multi.bec.assembler'] = '观测阵列',
                    ['multi.bec.generator'] = '纠缠装置',
                }
                local detail = names[d.kind] or machines[d.name] or d.name or d.kind
                for _, a in ipairs(cfg.arrays) do
                    if a.diode == d.address then
                        detail = detail .. ' / ' .. self:recordName(cfg, 'arrays', a)
                    end
                end
                for _, c in ipairs(cfg.channels) do
                    if c.buffer == d.address then
                        detail = detail .. ' / ' .. self:recordName(cfg, 'channels', c)
                    end
                end
                rows[#rows + 1] = { label = d.address, value = d.address, detail = detail }
            end
        end
    else
        for _, x in ipairs(cfg[f.source]) do
            rows[#rows + 1] = { label = self:recordName(cfg, f.source, x), value = x.id }
        end
    end
    return rows
end

function G:edit(cfg, component, save)
    return self.Editor.new(self, cfg, component, save):run()
end
local phases = {
    admit = '节点取料',
    collect = '收集算力奇点',
    wait = '准备加工',
    run = '加工',
    ['return'] = '加工完成',
}

local function phase(e, b, s)
    if s and s.bee then
        return (s.bee.loading and '装载 T' or '回收 T') .. s.bee.tier .. ' 蜂群'
    end
    if s and s.request then
        return '等待 T' .. s.request.tier .. ' 蜂群'
    end
    if b.phase == 'wait' and not b.granted then
        if b.admitting then
            for _, address in ipairs(e.s.admission.members) do
                if e.s.arrays[address].batch.phase ~= 'wait' then
                    return '等待其他阵列取料'
                end
            end
            return '核对原料'
        end
        local demand = 0
        for _, amount in pairs(b.reserve or {}) do
            demand = demand + amount
        end
        if demand > e.cfg.fieldLimit then
            return '场强容量不足',
                string.format(
                    '本批需要 %.0f L，场强容量仅 %.0f L；按 Ctrl+C 暂停，提高约束场强度后续做。',
                    demand,
                    e.cfg.fieldLimit
                )
        end
        if not e.free or e.resourceScan then
            return '核对凝聚物库存'
        end
        for id, amount in pairs(b.reserve or {}) do
            if amount > (e.free[id] or 0) then
                return '等待凝聚物'
            end
        end
        if not e.resourcesFresh then
            return '核对凝聚物库存'
        end
    end
    return phases[b.phase]
end

function G:beeWait(e, a)
    local s = e.s.arrays[a.address]
    local request = s and s.request
    if not request then
        return
    end
    local count, owners = 0, {}
    for _, pool in ipairs(e.cfg.beePools) do
        if pool.id == a.beePool then
            for _, cell in ipairs(pool.cells) do
                if cell.tier == request.tier then
                    count = count + 1
                end
            end
        end
    end
    for _, other in ipairs(e.arrays) do
        local state = e.s.arrays[other.address]
        if other.beePool == a.beePool and state and state.lease and state.lease[request.tier] then
            owners[#owners + 1] = self:recordName(e.cfg, 'arrays', other)
        end
    end
    return 'T'
        .. request.tier
        .. ' 共登记 '
        .. count
        .. ' 套；'
        .. (
            #owners > 0 and '正在使用：' .. table.concat(owners, '、')
            or '当前无阵列借用'
        )
end

function G:runtime(e, refill)
    self:begin('BEC / 多观测阵列')
    local w, h = self.w, self.h
    local actions = {
        { 'quit', 'Q 完成后退出' },
        { 'setup', 'S 完成后配置' },
        { 'interrupt', 'Ctrl+C 暂停并保存' },
    }
    local actionWidth = 0
    for _, action in ipairs(actions) do
        actionWidth = actionWidth + self.u.wlen(action[2]) + 4
    end
    local actionX = w - actionWidth + 2
    for _, action in ipairs(actions) do
        self:button(action[1], actionX, 1, action[2])
        actionX = actionX + self.u.wlen(action[2]) + 4
    end
    local total, active, done = 0, 0, 0
    for _, n in pairs(e.stock or {}) do
        total = total + n
    end
    for _, a in ipairs(e.arrays) do
        local s = e.s.arrays[a.address]
        if s then
            done = done + (s.done or 0)
            if s.batch then
                active = active + 1
            end
        end
    end
    self:put(
        2,
        2,
        e.stopping and '正在完成已接订单并回收蜂群；可按 Ctrl+C 立即暂停'
            or e.ready and ''
            or '等待约束场完成当前周期',
        w - 3,
        ink.green
    )
    self:put(
        2,
        3,
        '阵列 '
            .. active
            .. ' / '
            .. #e.arrays
            .. '  |  排队 '
            .. #e.s.queue
            .. '  |  纠缠装置 '
            .. #e.cfg.generators
            .. '  |  已完成 '
            .. exact(done)
            .. ' 份',
        w - 3
    )
    self:put(
        2,
        4,
        '库存 ' .. amount(e.stock and total) .. ' / ' .. amount(e.cfg.fieldLimit) .. ' L',
        w - 3,
        ink.cyan
    )
    self:bar(2, 5, w - 12, total / e.cfg.fieldLimit)
    self:put(w - 9, 5, string.format('%.1f%%', 100 * total / e.cfg.fieldLimit), 8, ink.dim)
    for i, label in ipairs({ '1 库存', '2 阵列', '3 AE下单' }) do
        self:button('tab:' .. i, 2 + (i - 1) * 12, 6, label, self.tab == i)
    end
    self:put(40, 6, '~ 为约数', w - 41, ink.dim)
    local fluids, known = {}, {}
    for _, b in ipairs(e.cfg.bands) do
        for _, m in ipairs(e.M) do
            if b.material == m.source then
                fluids[#fluids + 1] = { id = m.condensate, band = b }
                known[m.condensate] = true
            end
        end
    end
    local extras = {}
    for id in pairs(e.stock or {}) do
        if not known[id] then
            extras[#extras + 1] = id
        end
    end
    table.sort(extras)
    for _, id in ipairs(extras) do
        fluids[#fluids + 1] = { id = id }
    end
    local channels = {}
    local precaching = {}
    local refillState = refill and refill.s
    for _, f in ipairs(e.cfg.feeds) do
        local s = refillState and refillState.feeds[f.id]
        if s then
            for i in pairs(s.pending) do
                precaching[f.cells[i].material] = true
            end
            if s.loading then
                precaching[f.cells[s.loading.index].material] = true
            end
        end
    end
    for _, c in ipairs(e.cfg.channels) do
        channels[#channels + 1] = {
            label = '接单：' .. self:recordName(e.cfg, 'channels', c),
            status = e.status[c.id] or '等待',
            error = e.errors[c.id],
        }
    end
    for _, f in ipairs(e.cfg.feeds) do
        channels[#channels + 1] = {
            label = '预缓存纠缠流体：' .. self:recordName(e.cfg, 'feeds', f),
            status = refill and refill.detail[f.id] or '等待',
        }
    end
    local list = self.tab == 1 and fluids or self.tab == 2 and e.arrays or channels
    self.count = #list
    self.perPage = math.max(1, h - 18)
    local selected = math.max(1, math.min(self.selected[self.tab], math.max(1, #list)))
    self.selected[self.tab] = selected
    if self.tab == 2 then
        self.arrayIndex = selected
    end
    self.arrayIndex = math.max(1, math.min(self.arrayIndex, math.max(1, #e.arrays)))
    local wide = w >= 120
    local left = wide and w - 49 or w - 2
    local page = math.floor((selected - 1) / self.perPage)
    local first = page * self.perPage + 1
    self:put(
        2,
        8,
        self.tab == 1 and '凝聚态简称 / L'
            or self.tab == 2 and '观测阵列 / 当前批次'
            or 'AE下单 / 状态',
        left,
        ink.dim
    )
    if self.tab == 1 then
        self:put(left - 38, 8, '现存', 12, ink.dim)
        self:put(left - 25, 8, '预缓存目标', 12, ink.dim)
        self:put(left - 12, 8, '状态', 12, ink.dim)
    end
    for i = first, math.min(#list, first + self.perPage - 1) do
        local y = 9 + i - first
        local bg = i == selected and ink.selected or ink.bg
        local r = list[i]
        self:put(2, y, string.rep(' ', left), left, ink.text, bg)
        self.hits[#self.hits + 1] = { id = 'row:' .. i, x = 2, y = y, w = left }
        local prefix = i == selected and '> ' or '  '
        if self.tab == 1 then
            local have = e.stock and (e.stock[r.id] or 0)
            local reserve = (e.reserved or {})[r.id] or 0
            local status = not have and '待读取'
                or have < reserve and '库存不足'
                or r.band and precaching[r.band.material] and '正在预缓存'
                or r.band and (have - reserve <= r.band.low or refillState and refillState.active[r.band.material]) and '等待预缓存'
                or '充足'
            self:put(2, y, prefix .. e.M.name(r.id, true), left - 42, ink.text, bg)
            self:put(left - 38, y, amount(have), 12, ink.cyan, bg)
            self:put(left - 25, y, amount(r.band and r.band.high), 12, ink.dim, bg)
            self:put(left - 12, y, status, 12, status == '充足' and ink.green or ink.amber, bg)
        elseif self.tab == 2 then
            local s = e.s.arrays[r.address]
            local b = s and s.batch
            local label = e.errors[r.address] and '已暂停'
                or b and phase(e, b, s)
                or e.status[r.address]
                or '空闲'
            self:put(2, y, prefix .. self:recordName(e.cfg, 'arrays', r), 19, ink.cyan, bg)
            self:put(
                22,
                y,
                label
                    .. (
                        b
                            and ' ×' .. b.count .. ' ' .. (b.collection and '算力奇点合并加工' or e.s.patterns[b.key].pattern.label)
                        or ''
                    ),
                left - 20,
                e.errors[r.address] and ink.red or ink.text,
                bg
            )
        else
            self:put(
                2,
                y,
                prefix .. r.label .. '  ' .. (r.error and '已暂停' or r.status),
                left,
                r.error and ink.red or ink.text,
                bg
            )
        end
    end
    self:put(
        2,
        h - 8,
        string.format(
            '%d / %d  第 %d/%d 页',
            #list > 0 and selected or 0,
            #list,
            page + 1,
            math.max(1, math.ceil(#list / self.perPage))
        ),
        left,
        ink.dim
    )
    local row = list[selected]
    if row then
        if self.tab == 1 then
            self:put(2, h - 5, e.M.name(row.id), w - 3, ink.cyan)
            self:put(
                2,
                h - 4,
                '现存 '
                    .. exact(e.stock and (e.stock[row.id] or 0))
                    .. ' L  已预留 '
                    .. exact((e.reserved or {})[row.id] or 0)
                    .. ' L',
                w - 3
            )
            self:put(
                2,
                h - 3,
                row.band
                        and '下限 ' .. exact(row.band.low) .. ' / 目标 ' .. exact(row.band.high) .. ' L'
                    or '未设置预缓存',
                w - 3,
                ink.dim
            )
        elseif self.tab == 2 then
            local s = e.s.arrays[row.address]
            local b = s and s.batch
            local label, explanation
            if b then
                label, explanation = phase(e, b, s)
            end
            local detail = e.errors[row.address]
                or b and (b.phase == 'wait' or b.phase == 'return') and (explanation or label)
                or e.status[row.address]
                or label
                or '等待分配订单'
            local lines = self.u.wlen(detail) > w - 3 and 2 or 1
            self:put(2, h - 5, row.address, w - 3, ink.cyan)
            self:wrap(2, h - 4, detail, w - 3, lines, e.errors[row.address] and ink.red or ink.text)
            if not e.errors[row.address] and lines == 1 then
                local leases = {}
                for tier = 1, 10 do
                    local c = s and s.lease and s.lease[tier]
                    if c then
                        leases[#leases + 1] = 'T' .. tier .. ' 箱' .. c.box .. ' 槽' .. c.slot
                    end
                end
                local tier = (e.provided or {})[row.address]
                self:put(
                    2,
                    h - 3,
                    self:beeWait(e, row)
                        or self:recordName(e.cfg, 'beePools', row.beePool)
                            .. ' / '
                            .. (tier and '已装载 T' .. tier or '未装载蜂群')
                            .. ' / '
                            .. (#leases > 0 and table.concat(leases, '，') or '未借用')
                            .. (s and s.request and ' / 等待 T' .. s.request.tier or ''),
                    w - 3,
                    ink.dim
                )
            end
        else
            self:put(2, h - 5, row.label, w - 3, ink.cyan)
            self:wrap(
                2,
                h - 4,
                row.error or row.status,
                w - 3,
                2,
                row.error and ink.red or ink.text
            )
        end
    end
    if wide then
        self:arrayPanel(e, left + 4, 8, 45, h - 8)
    elseif self.tab == 2 then
        self:button(
            'nodes',
            w - 18,
            6,
            self.nodeOnly and '返回阵列' or '查看节点',
            self.nodeOnly
        )
        if self.nodeOnly then
            for y = 8, h - 6 do
                self.rows[y] = {}
            end
            -- Remove covered row hitboxes before drawing the node panel.
            local hits = {}
            for _, hit in ipairs(self.hits) do
                if hit.y < 8 or hit.y > h - 6 then
                    hits[#hits + 1] = hit
                end
            end
            self.hits = hits
            self:arrayPanel(e, 2, 8, w - 3, h - 8)
        end
    end
    self:frame(1, 7, left + 2, h - 7)
    if wide then
        self:frame(left + 3, 7, w - left - 2, h - 7)
    end
    self:frame(1, h - 6, w, h - 2)
    self:button('prev', 2, h, '上一页')
    self:button('next', 12, h, '下一页')
    self:put(23, h, '1/2/3 面板  ↑↓选择  []翻页', w - 24, ink.cyan)
    self:paint()
end

function G:arrayPanel(e, x, top, width, bottom)
    local a = e.arrays[self.arrayIndex]
    if not a then
        return
    end
    local s = e.s.arrays[a.address]
    local b = s and s.batch
    self:put(x, top, self:recordName(e.cfg, 'arrays', a), width - 20, ink.cyan)
    self:button('array-', x + width - 18, top, '上一台')
    self:button('array+', x + width - 8, top, '下一台')
    local tier = (e.provided or {})[a.address]
    local product = b
        and (b.collection and '算力奇点合并加工' or e.s.patterns[b.key].pattern.label)
    self:put(
        x,
        top + 1,
        product and product .. ' ×' .. exact(b.count) or '等待 AE 下单',
        width
    )
    self:put(
        x,
        top + 2,
        e.errors[a.address] and '已暂停 / 暂停前进度'
            or (b and phase(e, b, s) or e.status[a.address] or '空闲')
                .. '  |  '
                .. (tier and '蜂群 T' .. tier or '未装载蜂群'),
        width,
        e.errors[a.address] and ink.red or ink.green
    )
    local observed = (e.observations or {})[a.address]
    local views, workers = {}, {}
    for _, n in pairs(observed or {}) do
        views[n.address] = n
    end
    for _, worker in ipairs(b and b.workers or {}) do
        workers[worker.address] = worker
    end
    local firstRow = top + 3
    local per = math.max(1, math.floor((bottom - firstRow + 1) / 2))
    if #a.nodes > per then
        per = math.max(1, math.floor((bottom - firstRow) / 2))
    end
    self.nodePages = math.max(1, math.ceil(#a.nodes / per))
    self.nodePage = math.max(1, math.min(self.nodePage, self.nodePages))
    for i = (self.nodePage - 1) * per + 1, math.min(#a.nodes, self.nodePage * per) do
        local y = firstRow + 2 * (i - (self.nodePage - 1) * per - 1)
        local address = a.nodes[i].address
        local n = views[address]
        local worker = workers[address]
        if b and b.phase == 'run' and n then
            self:put(
                x,
                y,
                '#' .. i .. '  ' .. amount(n.parallel) .. ' 并行 T' .. (n.tier or '-'),
                width
            )
            if n.fast then
                self:put(
                    x,
                    y + 1,
                    e.errors[a.address] and '已暂停' or '快速加工',
                    width,
                    ink.cyan
                )
            else
                local status = e.errors[a.address] and '已暂停'
                    or not tier and '等蜂群'
                    or n.tier and n.tier > tier and '等T' .. n.tier
                    or '加工'
                local color = status == '加工' and ink.cyan or ink.amber
                local ratio = math.min(1, n.progress / n.length)
                self:bar(x, y + 1, width - 16, ratio, color)
                self:put(x + width - 15, y + 1, string.format('%5.1f%%', ratio * 100), 6, color)
                self:put(x + width - 8, y + 1, status, 8, color)
            end
        else
            local status = '空闲'
            if worker then
                if b.phase == 'return' then
                    status = '本批完成'
                elseif b.phase == 'run' then
                    status = observed and '本批完成' or '待读取'
                else
                    local cached = (e.nodeCache or {})[address]
                    local accepted = b.phase ~= 'admit'
                        or worker.accepted
                        or cached and cached.worker == worker and cached.accepted
                    status = (accepted and '已取料 ' or '待取料 ') .. worker.count .. ' 份'
                end
            end
            self:put(x, y, '#' .. i .. '  ' .. status, width, ink.dim)
        end
    end
    if self.nodePages > 1 then
        self:button('node-', x, bottom, '上页')
        self:button('node+', x + 8, bottom, '下页')
        self:put(
            x + 16,
            bottom,
            '节点 ' .. self.nodePage .. '/' .. self.nodePages,
            width - 16,
            ink.dim
        )
    end
end

function G:runtimeEvent(name, _, ch, code, direction)
    local action = name == 'touch' and self:hit(ch, code)
    if name == 'key_down' then
        if ch == 115 or ch == 83 then
            return 'setup'
        elseif ch == 113 or ch == 81 then
            return 'quit'
        elseif ch and ch >= 49 and ch <= 51 then
            action = 'tab:' .. (ch - 48)
        elseif code == 15 then
            action = 'tab:' .. (self.tab % 3 + 1)
        elseif code == 200 then
            action = 'up'
        elseif code == 208 then
            action = 'down'
        elseif code == 201 or ch == 91 then
            action = 'prev'
        elseif code == 209 or ch == 93 then
            action = 'next'
        end
    elseif name == 'scroll' then
        action = direction > 0 and 'up' or 'down'
    elseif name == 'interrupted' then
        return 'interrupt'
    end
    if not action then
        return
    end
    if action == 'setup' or action == 'quit' or action == 'interrupt' then
        return action
    end
    if action:match('^tab:') then
        self.tab = tonumber(action:sub(5))
        self.nodeOnly = false
    elseif action:match('^row:') then
        self.selected[self.tab] = tonumber(action:sub(5))
        self.nodePage = 1
    elseif action == 'up' or action == 'down' or action == 'prev' or action == 'next' then
        local step = (action == 'prev' or action == 'next') and self.perPage or 1
        local sign = (action == 'up' or action == 'prev') and -1 or 1
        self.selected[self.tab] = math.max(
            1,
            math.min(math.max(1, self.count or 0), self.selected[self.tab] + sign * step)
        )
        self.nodePage = 1
    elseif action == 'array-' or action == 'array+' then
        self.arrayIndex = math.max(1, self.arrayIndex + (action == 'array-' and -1 or 1))
        self.nodePage = 1
        if self.tab == 2 then
            self.selected[2] = self.arrayIndex
        end
    elseif action == 'node-' or action == 'node+' then
        self.nodePage =
            math.max(1, math.min(self.nodePages, self.nodePage + (action == 'node-' and -1 or 1)))
    elseif action == 'nodes' then
        self.nodeOnly = not self.nodeOnly
    end
    return 'redraw'
end
return G
