local C = {}
local function field(key, label, kind, default, extra)
    local f = { key = key, label = label, kind = kind, default = default }
    for k, v in pairs(extra or {}) do
        f[k] = v
    end
    return f
end

local function list(key, label, fields)
    return field(key, label, 'list', nil, { fields = fields })
end

local function ref(key, label, source)
    return field(key, label, 'choice', '', { source = source })
end

local function num(key, label, default, lo, hi)
    return field(key, label, 'number', default, { lo = lo or 0, hi = hi or 2147483647 })
end

local function dev(key, label, kind)
    return ref(key, label, 'device:' .. kind)
end

local function side(key, label)
    return num(key, label, 0, 0, 5)
end

local function idField()
    return field('id', '名称 / ID', 'text', '')
end
C.schema = {
    dev('storage', '共享约束场', 'bec_storage'),
    num('fieldLimit', '约束场强度 L', 1000000000000, 1, 9007199254740991),
    num('singularityWait', '算力奇点等待阈值（秒）', 300, 1),
    list('inventories', '库存位置', {
        idField(),
        dev('transposer', '读取库存的转运器', 'transposer'),
        side('side', '库存方向'),
    }),
    list('channels', 'AE下单', {
        idField(),
        list(
            'patterns',
            '主网样板接口列表',
            { dev('address', '样板接口', 'pattern'), num('slots', '样板槽数', 36, 1, 128) }
        ),
        dev('buffer', '公共原料子网 ME 控制器', 'buffer'),
        dev('redstone', '接单红石 I/O', 'redstone'),
        side('gateSide', '红石输出方向'),
    }),
    list('beePools', '共享蜂群池', {
        idField(),
        list('cells', '蜂群元件', {
            num('tier', '等级', 1, 1, 10),
            num('box', '箱子编号', 1, 1),
            num('slot', '箱内固定槽位', 1, 1),
        }),
    }),
    list('arrays', '观测阵列', {
        dev('address', '观测阵列', 'assembler'),
        field('enabled', '启用', 'boolean', true),
        dev('diode', '麦克斯韦门', 'bec_diode'),
        list('nodes', '关联的传送节点', { dev('address', '节点', 'bec_io_node') }),
        ref('beePool', '使用的蜂群池', 'beePools'),
        ref('loadPort', '蜂群装载 ME-IO 端口', 'inventories'),
        ref('unloadPort', '蜂群回收 ME-IO 端口', 'inventories'),
        list('beeBoxes', '蜂群箱连接', {
            num('box', '箱子编号', 1, 1),
            ref('inventory', '蜂群箱库存位置', 'inventories'),
        }),
    }),
    list('generators', '纠缠装置', {
        dev('address', '纠缠装置', 'generator'),
        ref('feed', '纠缠装置原料子网', 'feeds'),
    }),
    list('feeds', '纠缠装置供料组', {
        idField(),
        ref('io', '主网流体转运 ME-IO 端口', 'inventories'),
        num('drive1Side', '第一台流体驱动器方向', 0, 0, 5),
        num('drive2Side', '第二台流体驱动器方向', 2, 0, 5),
        list('cells', '分区流体元件', {
            ref('material', '流体', 'materials'),
            num('slot', '驱动器槽位', 1, 1),
            ref('inventory', '流体驱动器', 'inventories'),
        }),
    }),
    list('bands', '共享流体目标', {
        ref('material', '流体', 'materials'),
        num('low', '下限 L', 1000000, 0, 9007199254740991),
        num('high', '目标 L', 2000000, 1, 9007199254740991),
    }),
}

function C.newRecord(fields)
    local r = {}
    for _, f in ipairs(fields) do
        r[f.key] = f.kind == 'list' and {} or f.default
    end
    return r
end

function C.defaults(cfg)
    cfg = cfg or {}
    local function fill(fields, value, path)
        assert(
            type(value) == 'table',
            '无法读取配置结构：' .. path .. '；请重新配置'
        )
        for _, f in ipairs(fields) do
            local key = f.key
            local p = path .. f.label
            if value[key] == nil then
                value[key] = f.kind == 'list' and {} or f.default
            end
            local v = value[key]
            if f.kind == 'list' then
                assert(
                    type(v) == 'table',
                    '无法读取配置列表：' .. p .. '；请重新配置'
                )
                for _, x in ipairs(v) do
                    fill(f.fields, x, p .. ' / ')
                end
            else
                local kind = (f.kind == 'choice' or f.kind == 'text') and 'string' or f.kind
                assert(type(v) == kind, '无法读取配置字段：' .. p .. '；请重新配置')
            end
        end
    end
    fill(C.schema, cfg, '')
    return cfg
end

function C.scan(component, cfg)
    local devices = {}
    for a, k in component.list() do
        local d = { address = a, kind = k, methods = component.methods(a) }
        if d.methods.getName then
            local ok, n = pcall(component.invoke, a, 'getName')
            if ok then
                d.name = n
            end
        end
        devices[#devices + 1] = d
    end
    table.sort(devices, function(a, b)
        return a.address < b.address
    end)
    for _, what in ipairs({ { 'arrays', 'multi.bec.assembler' } }) do
        local spec
        for _, s in ipairs(C.schema) do
            if s.key == what[1] then
                spec = s
            end
        end
        local have = {}
        for _, x in ipairs(cfg[what[1]]) do
            have[x.address] = true
        end
        for _, d in ipairs(devices) do
            if d.name == what[2] and not have[d.address] then
                local x = C.newRecord(spec.fields)
                x.address = d.address
                if #cfg.beePools == 1 then
                    x.beePool = cfg.beePools[1].id
                end
                cfg[what[1]][#cfg[what[1]] + 1] = x
            end
        end
    end
    return devices
end

function C.matches(d, kind)
    if kind == 'assembler' then
        return d.name == 'multi.bec.assembler'
    end
    if kind == 'generator' then
        return d.name == 'multi.bec.generator'
    end
    if kind == 'pattern' then
        return d.methods.getInterfacePattern ~= nil
    end
    if kind == 'buffer' then
        return d.methods.getItemsInNetwork ~= nil
    end
    return d.kind == kind
end

function C.unboundNodes(cfg, devices)
    local used = {}
    for _, a in ipairs(cfg.arrays) do
        for _, n in ipairs(a.nodes) do
            used[n.address] = true
        end
    end
    local nodes = {}
    for _, d in ipairs(devices) do
        if C.matches(d, 'bec_io_node') and not used[d.address] then
            nodes[#nodes + 1] = d
        end
    end
    return nodes
end

function C.bindNodes(cfg, array, devices)
    local nodes = C.unboundNodes(cfg, devices)
    if #array.nodes + #nodes > 16 then
        return false,
            '未分配节点超过本阵列剩余位置；请只接入本阵列节点，或逐个选择'
    end
    for _, n in ipairs(nodes) do
        array.nodes[#array.nodes + 1] = { address = n.address }
    end
    return true, '已绑定 ' .. #nodes .. ' 个节点；本阵列共 ' .. #array.nodes .. ' 个'
end

function C.unboundDoors(cfg, devices)
    local used = {}
    for _, a in ipairs(cfg.arrays) do
        used[a.diode] = true
    end
    local doors = {}
    for _, d in ipairs(devices) do
        if C.matches(d, 'bec_diode') and not used[d.address] then
            doors[#doors + 1] = d
        end
    end
    return doors
end

function C.validate(cfg, component, U)
    local function basic(fields, value, path)
        for _, f in ipairs(fields) do
            local v = value[f.key]
            local p = path .. f.label
            if f.kind == 'list' then
                assert(type(v) == 'table', p .. '必须是列表')
                for i, x in ipairs(v) do
                    basic(f.fields, x, p .. ' / ' .. (x.id or x.address or i) .. ' / ')
                end
            elseif f.kind == 'number' then
                assert(U.integer(v, f.lo, f.hi), p .. '数值无效')
            elseif f.kind == 'boolean' then
                assert(type(v) == 'boolean', p .. '未设置')
            else
                assert(type(v) == 'string' and v ~= '', p .. '未设置')
            end
        end
    end
    -- Disabled newly discovered arrays may remain unconfigured.
    local checked = U.copy(cfg)
    checked.arrays = {}
    for _, a in ipairs(cfg.arrays) do
        if a.enabled then
            checked.arrays[#checked.arrays + 1] = a
        end
    end
    basic(C.schema, checked, '')
    assert(
        #checked.arrays > 0 and #cfg.channels == 1,
        '至少启用一台阵列，并配置唯一的公共原料子网'
    )
    local inv, feeds = U.index(cfg.inventories), U.index(cfg.feeds)
    for _, section in ipairs({ 'inventories', 'channels', 'feeds', 'beePools' }) do
        local seen = {}
        for _, x in ipairs(cfg[section]) do
            assert(not seen[x.id], '重复名称：' .. x.id)
            seen[x.id] = true
        end
    end
    local nodes, ports, owners, arrays, diodes = {}, {}, {}, {}, {}
    local function port(id)
        assert(inv[id], '未知库存位置：' .. tostring(id))
        assert(not ports[id], 'ME-IO 端口重复分配：' .. id)
        ports[id] = true
    end
    local function own(id, slot)
        local key = id .. ':' .. slot
        assert(not owners[key], '元件槽位重复：' .. key)
        owners[key] = true
    end
    local function connected(from, to)
        local a, b = inv[from], inv[to]
        assert(a and b, '请配置元件容器和 ME-IO 端口')
        assert(
            a.transposer == b.transposer,
            '元件容器和 ME-IO 端口须连接同一个转运器'
        )
        assert(a.side ~= b.side, '元件容器和 ME-IO 端口不能使用同一方向')
    end
    local pools = U.index(cfg.beePools)
    local boxPools = {}
    for _, p in ipairs(cfg.beePools) do
        assert(#p.cells > 0, '蜂群池未登记蜂群元件：' .. p.id)
        local slots = {}
        for _, c in ipairs(p.cells) do
            local key = c.box .. ':' .. c.slot
            assert(not slots[key], '蜂群箱槽位重复：' .. p.id .. ' / ' .. key)
            slots[key] = true
        end
    end
    local patterns = {}
    for _, c in ipairs(cfg.channels) do
        assert(#c.patterns > 0, 'AE下单至少选择一个主网样板接口')
        for _, p in ipairs(c.patterns) do
            assert(not patterns[p.address], '样板接口重复分配：' .. p.address)
            patterns[p.address] = true
        end
    end
    for _, a in ipairs(checked.arrays) do
        assert(not arrays[a.address], '观测阵列重复分配')
        arrays[a.address] = true
        assert(not diodes[a.diode], '每台阵列须使用独立的麦克斯韦门')
        diodes[a.diode] = true
        assert(#a.nodes >= 1 and #a.nodes <= 16, '每台阵列须选择 1–16 个节点')
        for _, n in ipairs(a.nodes) do
            assert(not nodes[n.address], '节点重复分配：' .. n.address)
            nodes[n.address] = true
        end
        local pool = assert(pools[a.beePool], '请选择使用的蜂群池：' .. a.address)
        local boxes = {}
        port(a.loadPort)
        port(a.unloadPort)
        connected(a.loadPort, a.unloadPort)
        for _, box in ipairs(a.beeBoxes) do
            assert(
                not boxes[box.box],
                '阵列的蜂群箱编号重复：' .. a.address .. ' / ' .. box.box
            )
            boxes[box.box] = true
            assert(inv[box.inventory], '未知蜂群箱库存位置：' .. box.inventory)
            local key = a.beePool .. ':' .. box.box
            assert(
                not boxPools[box.inventory] or boxPools[box.inventory] == key,
                '同一蜂群箱不能登记为不同的池或箱子编号'
            )
            local used = false
            for _, c in ipairs(pool.cells) do
                if c.box == box.box then
                    used = true
                    if not boxPools[box.inventory] then
                        own(box.inventory, c.slot)
                    end
                end
            end
            assert(used, '蜂群池中没有登记该箱子的元件：' .. key)
            boxPools[box.inventory] = key
            connected(box.inventory, a.loadPort)
            connected(box.inventory, a.unloadPort)
        end
        for _, c in ipairs(pool.cells) do
            assert(
                boxes[c.box],
                '阵列缺少蜂群箱连接：' .. a.address .. ' / 箱子 ' .. c.box
            )
        end
    end
    local band = {}
    for _, b in ipairs(cfg.bands) do
        assert(
            not band[b.material] and b.high > b.low and b.high <= cfg.fieldLimit,
            '流体重复配置，或预缓存目标不满足：下限 < 目标 ≤ 场强容量'
        )
        band[b.material] = true
    end
    local gen = {}
    for _, g in ipairs(cfg.generators) do
        assert(
            feeds[g.feed] and not gen[g.address],
            '纠缠装置重复配置，或未选择有效的原料网'
        )
        gen[g.address] = g.feed
    end
    for _, f in ipairs(cfg.feeds) do
        port(f.io)
        local has = false
        for _, g in ipairs(cfg.generators) do
            if g.feed == f.id then
                has = true
            end
        end
        assert(has, '原料网没有纠缠装置：' .. f.id)
        local seen = {}
        for _, c in ipairs(f.cells) do
            assert(
                band[c.material] and not seen[c.material],
                '原料网的流体重复配置，或未设置预缓存目标'
            )
            seen[c.material] = true
            connected(c.inventory, f.io)
            own(c.inventory, c.slot)
        end
    end
    if component then
        local function visit(fields, value)
            for _, f in ipairs(fields) do
                if f.kind == 'list' then
                    for _, x in ipairs(value[f.key]) do
                        visit(f.fields, x)
                    end
                elseif f.source and f.source:sub(1, 7) == 'device:' then
                    local a = value[f.key]
                    assert(component.type(a), '组件离线：' .. f.label .. ' ' .. a)
                    local d = { kind = component.type(a), methods = component.methods(a) }
                    if d.methods.getName then
                        d.name = component.invoke(a, 'getName')
                    end
                    assert(
                        C.matches(d, f.source:sub(8)),
                        '所选组件类型不正确：' .. f.label
                    )
                end
            end
        end
        visit(C.schema, checked)
    end
    return true
end
return C
