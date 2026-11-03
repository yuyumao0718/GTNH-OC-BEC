local R = {}
function R.check(cfg, state, U, proxy, M)
    local old = state.wiring
    if not old then
        return
    end
    local before, after = {}, {}
    for _, name in ipairs({
        'inventories',
        'channels',
        'arrays',
        'beePools',
        'feeds',
        'generators',
    }) do
        local key = (name == 'arrays' or name == 'generators') and 'address' or 'id'
        before[name] = U.index(old[name], key)
        after[name] = U.index(cfg[name], key)
    end
    local active = false
    local function same(a, b, message)
        assert(U.equal(a, b), '续做仍需保留' .. message)
    end
    local function inventory(id)
        same(before.inventories[id], after.inventories[id], '库存位置：' .. id)
    end
    local function fields(a, b, keys, message)
        assert(b, '续做仍需保留' .. message)
        local names = {
            buffer = '公共原料子网 ME 控制器',
            redstone = '红石 I/O',
            gateSide = '红石输出方向',
            diode = '麦克斯韦门',
            beePool = '共享蜂群池',
            loadPort = '蜂群装载 ME-IO 端口',
            unloadPort = '蜂群回收 ME-IO 端口',
        }
        for _, k in ipairs(keys) do
            same(a[k], b[k], message .. ' / ' .. names[k])
        end
    end
    if state.admission or #(state.queue or {}) > 0 then
        active = true
        local c = old.channels[1]
        fields(c, after.channels[c.id], { 'buffer', 'redstone', 'gateSide' }, '公共原料子网')
    end
    -- OC may stop after delivery but before recording the order.
    if proxy then
        for id, c in pairs(before.channels) do
            if next(proxy(c.buffer).getItemsInNetwork()) then
                active = true
                fields(
                    c,
                    after.channels[id],
                    { 'buffer', 'redstone', 'gateSide' },
                    '尚有原料的公共原料子网：' .. id
                )
            end
        end
    end
    local bands = {}
    for _, b in ipairs(cfg.bands) do
        bands[b.material] = true
    end
    local function required(unit)
        for _, m in ipairs(M or {}) do
            if (unit or {})[m.condensate] then
                assert(
                    bands[m.source],
                    '未完成任务仍需该流体的预缓存配置：' .. m.label
                )
            end
        end
    end
    for id, s in pairs(state.arrays or {}) do
        local a, b = before.arrays[id], after.arrays[id]
        if s.batch or s.lease or s.bee then
            active = true
            assert(b and b.enabled, '续做仍需启用阵列：' .. id)
            fields(a, b, { 'diode', 'beePool' }, '阵列连接：' .. id)
            if s.batch then
                local nodes = U.index(b.nodes, 'address')
                for _, w in ipairs(s.batch.workers or {}) do
                    assert(nodes[w.address], '续做仍需保留节点：' .. w.address)
                end
                required(state.patterns[s.batch.key].unit)
            end
            for tier, c in pairs(s.lease or {}) do
                local pool = after.beePools[a.beePool]
                local found = false
                for _, v in ipairs(pool and pool.cells or {}) do
                    if v.box == c.box and v.slot == c.slot and v.tier == tier then
                        found = true
                    end
                end
                assert(
                    found,
                    '蜂群尚未归还，请保留池 '
                        .. a.beePool
                        .. ' / 箱 '
                        .. c.box
                        .. ' / 槽 '
                        .. c.slot
                )
                local ab, bb = U.index(a.beeBoxes, 'box')[c.box], U.index(b.beeBoxes, 'box')[c.box]
                same(ab, bb, '已借蜂群的箱子连接：' .. id .. ' / ' .. c.box)
                inventory(ab.inventory)
                fields(a, b, { 'loadPort', 'unloadPort' }, '蜂群 ME-IO 端口')
                inventory(a.loadPort)
                inventory(a.unloadPort)
            end
        end
    end
    for _, move in pairs(state.moves or {}) do
        active = true
        inventory(move.from)
        inventory(move.to)
    end
    local refill = state.refill or {}
    for id, s in pairs(refill.feeds or {}) do
        if s.loading or next(s.pending or {}) then
            active = true
            local a, b = before.feeds[id], after.feeds[id]
            assert(b, '补库尚未完成，请保留原料网：' .. id)
            if s.loading then
                same(a.io, b.io, '主网流体转运 ME-IO 端口：' .. id)
                inventory(a.io)
            end
            for i, c in ipairs(a.cells) do
                if (s.pending or {})[i] or s.loading and s.loading.index == i then
                    same(c, b.cells[i], '尚在补库的元件：' .. id .. ' / ' .. i)
                    inventory(c.inventory)
                end
            end
            for address, g in pairs(before.generators) do
                if g.feed == id then
                    same(g, after.generators[address], '纠缠装置归属：' .. address)
                end
            end
        end
    end
    for id, s in pairs(refill.generators or {}) do
        if s.busy then
            active = true
            same(
                before.generators[id],
                after.generators[id],
                '仍在加工的纠缠装置：' .. id
            )
        end
    end
    if active then
        same(old.storage, cfg.storage, '共享约束场')
    end
    return true
end

function R.adopt(e, choose)
    e:catalogsRead()
    local arrays, patterns = e.U.copy(e.s.arrays), e.U.copy(e.s.patterns)
    local used = {}
    for _, a in ipairs(e.cfg.arrays) do
        for _, c in pairs((arrays[a.address] or {}).lease or {}) do
            used[a.beePool .. ':' .. c.box .. ':' .. c.slot] = true
        end
    end
    for _, a in ipairs(e.arrays) do
        local s = arrays[a.address] or { done = 0, counts = {} }
        arrays[a.address] = s
        if not s.batch then
            local workers, unit, steps = {}, nil, nil
            local count = 0
            for _, node in ipairs(a.nodes) do
                local n = e.io.proxy(node.address)
                if n.hasWork() then
                    local parallel = n.getParallelRecipesInProgress()
                    assert(parallel > 0, '接管节点未返回加工份数：' .. node.address)
                    local required = n.getRequiredCondensate()
                    local per = {}
                    for k, v in pairs(required) do
                        per[k] = v / parallel
                    end
                    local recipe = e.N.steps(n.getRecipeSteps())
                    assert(
                        not unit or e.U.equal(unit, per) and e.U.equal(steps, recipe),
                        '同一阵列的现有节点配方不同，暂不能合并接管：'
                            .. a.address
                    )
                    unit, steps = per, recipe
                    count = count + parallel
                    workers[#workers + 1] = { address = node.address, count = parallel }
                end
            end
            -- With no move record, an occupied port has no recoverable return address.
            if not s.bee and not e.s.moves['bee:' .. a.address] then
                for _, id in ipairs({ a.loadPort, a.unloadPort }) do
                    for slot = 1, e.log:size(id) do
                        assert(
                            not e.log:stack(id, slot),
                            '接管前请确认并归还没有搬运记录的元件：'
                                .. id
                                .. ' / 槽 '
                                .. slot
                        )
                    end
                end
            end
            if count > 0 then
                local key = 'recovered:' .. a.address
                patterns[key] = {
                    pattern = { label = '接管的节点任务', inputs = {} },
                    unit = unit,
                    steps = steps,
                }
                s.batch = {
                    key = key,
                    count = count,
                    workers = workers,
                    phase = 'run',
                    started = true,
                    granted = true,
                }
            end
        end
        local node = e.io.proxy(a.nodes[1].address)
        local provided = node.getProvidedTier()
        if provided and not (s.lease and s.lease[provided.tier]) then
            assert(
                not s.bee and not s.lease,
                '蜂群装卸记录与现场不一致，请先核对：' .. a.address
            )
            local candidates = {}
            for _, c in ipairs(e.pools[a.beePool].cells) do
                if
                    c.tier == provided.tier
                    and not used[a.beePool .. ':' .. c.box .. ':' .. c.slot]
                then
                    local stack = e.log:stack(e:beeAccess(a, c).inventory, c.slot)
                    if stack and stack.storedItemCount == 0 then
                        candidates[#candidates + 1] = c
                    end
                end
            end
            assert(
                #candidates > 0,
                '找不到可归还 T' .. provided.tier .. ' 蜂群的空元件：' .. a.address
            )
            local selected = choose(a, provided.tier, candidates)
            local valid
            for _, c in ipairs(candidates) do
                if selected and selected.box == c.box and selected.slot == c.slot then
                    valid = c
                end
            end
            assert(valid, '未确认蜂群归还位置，接管已取消：' .. a.address)
            s.lease = { [provided.tier] = e.U.copy(valid) }
            s.request = nil
            s.counts = { [provided.tier] = node.getAvailableNanites() }
            used[a.beePool .. ':' .. selected.box .. ':' .. selected.slot] = true
        end
    end
    -- Unconsumed common-network materials are admitted separately; active arrays may have different recipes.
    e.s.arrays, e.s.patterns = arrays, patterns
    e.save()
end
return R
