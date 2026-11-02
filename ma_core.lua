-- Each array advances one small step per tick; all durable state contains plain tables.
local E = {}
E.__index = E
local function cellKey(c)
    return c.box .. ':' .. c.slot
end
local phases = {
    admit = '节点取料',
    collect = '收集算力奇点',
    wait = '准备加工',
    run = '加工中',
    ['return'] = '回收蜂群',
}
local nodeErrors = {
    ['internal-error'] = '节点内部错误',
    unpowered = '节点供电不足',
    ['assembler-offline'] = '观测阵列未运行',
    ['paused-immediate'] = '节点已被立即暂停',
    ['paused-step'] = '节点已在步骤结束时暂停',
}

function E.new(cfg, state, io, modules)
    local self = setmetatable({
        cfg = cfg,
        s = state,
        io = io,
        U = modules.U,
        I = modules.I,
        N = modules.N,
        M = modules.M,
        status = {},
        catalogs = {},
        arrays = {},
        errors = {},
        observations = {},
        provided = {},
        now = 0,
        settled = {},
        filterNames = {},
        healthAt = {},
        collectAt = {},
    }, E)
    for _, key in ipairs({ 'arrays', 'queue', 'patterns', 'moves', 'poolCounts' }) do
        state[key] = state[key] or {}
    end
    state.nextId = state.nextId or 1
    self.save = function()
        io.save(state)
    end
    self.log = modules.Log.new(cfg, state, io.proxy, self.save, self.U)
    self.pools = self.U.index(cfg.beePools)
    self.storage = io.proxy(cfg.storage)
    for _, a in ipairs(cfg.arrays) do
        if a.enabled then
            self.arrays[#self.arrays + 1] = a
        end
    end
    self.byAddress = self.U.index(self.arrays, 'address')
    return self
end

function E:items(address)
    local counts = self.I.inventory(self.io.proxy(address).getItemsInNetwork())
    return counts
end

function E:gate(c, closed)
    local locked = self.stopping or closed
    if self.gateOutput ~= locked then
        self.io.proxy(c.redstone).setOutput(c.gateSide, locked and 15 or 0)
        self.gateOutput = locked
    end
end

function E:requestStop()
    self.stopping = true
    self:gate(self.cfg.channels[1], true)
end

function E:hold(a)
    local p = self.io.proxy(a.address)
    if p.isWorkAllowed() then
        p.setWorkAllowed(false)
    end
    return not p.hasWork()
end

function E:pause()
    self.gateOutput = nil
    pcall(self.gate, self, self.cfg.channels[1], true)
    for _, a in ipairs(self.arrays) do
        pcall(self.hold, self, a)
        for _, n in ipairs(a.nodes) do
            pcall(self.io.proxy(n.address).setWorkAllowed, false)
        end
    end
    self.save()
end

function E:catalogsRead()
    for _, c in ipairs(self.cfg.channels) do
        local patterns = {}
        for index, source in ipairs(c.patterns) do
            local p = self.io.proxy(source.address)
            for slot = 1, source.slots do
                local v = p.getInterfacePattern(slot)
                if v then
                    patterns[index .. ':' .. slot] = v
                end
            end
        end
        self.catalogs[c.id] = self.I.catalog(patterns)
    end
end

function E:check()
    self:catalogsRead()
    local needed = 0
    for _, a in ipairs(self.arrays) do
        for _, box in ipairs(a.beeBoxes) do
            for _, r in ipairs({ box.load, box.unload }) do
                local _, id = self.log:ends(r)
                assert(self.log:size(id) == 12, '蜂群库存位置不是 ME-IO 端口：' .. id)
            end
        end
        local s = self.s.arrays[a.address]
        local provided = self.io.proxy(a.nodes[1].address).getProvidedTier()
        self.provided[a.address] = provided and provided.tier
        assert(
            not provided or s and s.lease and s.lease[provided.tier],
            '阵列内的蜂群没有借用记录，请运行 bec_multi.lua recover 指定归还位置：'
                .. a.address
        )
        for _, n in ipairs(a.nodes) do
            assert(
                not self.io.proxy(n.address).hasWork()
                    or self.s.arrays[a.address] and self.s.arrays[a.address].batch,
                '节点正在加工，但找不到续做记录，请运行 bec_multi.lua recover：'
                    .. n.address
            )
            local node = self.io.proxy(n.address)
            if node.hasWork() and s and s.batch and s.batch.started and s.batch.granted then
                local consumed = node.getConsumedCondensate()
                for k, v in pairs(node.getRequiredCondensate()) do
                    needed = needed + v - (consumed[k] or 0)
                end
            end
        end
    end
    assert(
        self.storage.hasWork() and self.storage.isWorkAllowed(),
        '请先启动约束场并持续供电'
    )
    assert(
        self.U.total(self.storage.getStoredCondensate()) <= self.cfg.fieldLimit,
        '凝聚物库存超过设置的场强容量'
    )
    assert(
        needed <= self.cfg.fieldLimit,
        '节点剩余凝聚物需求超过场强容量，请提高场强或完成部分任务后再降低'
    )
    return true
end

function E:start()
    self:pause()
    self:check()
    for _, a in ipairs(self.arrays) do
        self.s.arrays[a.address] = self.s.arrays[a.address] or { done = 0, counts = {} }
        local s = self.s.arrays[a.address]
        s.counts = s.counts or {}
        for _, n in ipairs(a.nodes) do
            self.io.proxy(n.address).setSpeedDivisor(1)
        end
    end
    if self.storage.getFieldStrength() ~= self.cfg.fieldLimit then
        self.storage.setFieldStrength(self.cfg.fieldLimit)
    end
    self.fieldProgress = self.storage.getWorkProgress()
    self.ready = false
    self.save()
end

function E:channel(c)
    if self.s.admission or #self.s.queue > 0 then
        self:gate(c, true)
        return
    end
    local counts = self:items(c.buffer)
    if not next(counts) then
        self.settled[c.id] = nil
        self:gate(c, false)
        self.status[c.id] = self.stopping and '已停止接单' or '等待 AE 下单'
        return
    end
    self:gate(c, true)
    if not self.settled[c.id] then
        self.settled[c.id] = self.now
        return
    end
    if self.now - self.settled[c.id] < 0.25 then
        return
    end
    local p = self.I.identify(self.catalogs[c.id], counts)
    if not p then
        self.status[c.id] = '等待原料到齐'
        return
    end
    local count, complete = self.I.receipts(p, counts)
    if count ~= complete or complete == 0 then
        self.status[c.id] = '等待原料到齐'
        return
    end
    self.s.patterns[p.key] = self.s.patterns[p.key] or { pattern = p }
    self.s.patterns[p.key].pattern = p
    self.s.queue[1] = { id = self.s.nextId, key = p.key, count = count }
    self.s.nextId = self.s.nextId + 1
    self.settled[c.id] = nil
    self.save()
end

function E:remaining(s)
    local b = s.batch
    if not b or not b.granted then
        return {}
    end
    if b.phase == 'return' then
        return {}
    end
    if not b.started then
        return self.U.copy(b.reserve)
    end
    local result = {}
    for _, w in ipairs(b.workers) do
        local n = self.io.proxy(w.address)
        if n.hasWork() then
            local required, consumed = n.getRequiredCondensate(), n.getConsumedCondensate()
            local unit = {}
            local count = n.getParallelRecipesInProgress()
            assert(count == w.count, '节点正在加工的份数与续做记录不一致')
            for k, v in pairs(required) do
                unit[k] = v / count
            end
            assert(
                self.U.equal(unit, self.s.patterns[b.key].unit),
                '节点配方与续做记录不一致'
            )
            for k, v in pairs(required) do
                local left = v - (consumed[k] or 0)
                assert(left >= 0, '节点报告的凝聚物消耗量超过配方需求')
                result[k] = (result[k] or 0) + left
            end
        end
    end
    return result
end

function E:resources()
    self.reserved = {}
    self.waiting = {}
    for _, a in ipairs(self.arrays) do
        local s = self.s.arrays[a.address]
        local b = s.batch
        if b then
            self.U.add(self.reserved, self:remaining(s))
            if
                b.phase ~= 'collect'
                and not b.granted
                and b.reserve
                and self.U.total(b.reserve) <= self.cfg.fieldLimit
            then
                self.U.add(self.waiting, b.reserve)
            end
        end
    end
    -- Read node obligations first: consumption between reads can only understate free stock.
    self.stock = self.storage.getStoredCondensate()
    self.free = {}
    for k, v in pairs(self.stock) do
        self.free[k] = math.max(0, v - (self.reserved[k] or 0))
    end
    assert(self.U.total(self.stock) <= self.cfg.fieldLimit, '凝聚物库存超过场强容量')
end

function E:grant(b)
    if b.granted then
        return true
    end
    if self.U.total(b.reserve) > self.cfg.fieldLimit then
        return false
    end
    if not self.U.fits(self.free, b.reserve) then
        return false
    end
    b.granted = true
    self.U.add(self.reserved, b.reserve)
    self.U.add(self.free, b.reserve, -1)
    self.save()
    return true
end

function E:beeCells(a)
    local cells = {}
    for _, c in ipairs(self.pools[a.beePool].cells) do
        cells[c.tier] = cells[c.tier] or c
    end
    return cells
end

function E:beeAccess(a, c)
    for _, box in ipairs(a.beeBoxes) do
        if box.box == c.box then
            return box
        end
    end
    error('阵列缺少蜂群箱连接：' .. a.address .. ' / 箱子 ' .. c.box)
end

function E:beeCount(a, c, value)
    local counts = self.s.poolCounts[a.beePool] or {}
    self.s.poolCounts[a.beePool] = counts
    local key = cellKey(c)
    if value then
        counts[key] = value
    end
    if not counts[key] then
        local stack = self.log:stack(self:beeAccess(a, c).inventory, c.slot)
        if stack and stack.storedItemCount > 0 then
            counts[key] = stack.storedItemCount
        end
    end
    return counts[key] or 1
end

function E:borrow(a, s, tier)
    if s.lease then
        return s.lease[tier] ~= nil
    end
    if not s.request or s.request.tier ~= tier then
        s.request = { tier = tier, id = self.s.nextId }
        self.s.nextId = self.s.nextId + 1
        self.save()
    end
    local used, earlier = {}, 0
    for _, other in ipairs(self.cfg.arrays) do
        if other.beePool == a.beePool then
            local state = self.s.arrays[other.address] or {}
            for _, c in pairs(state.lease or {}) do
                used[cellKey(c)] = true
            end
            if state.request and state.request.tier == tier and state.request.id < s.request.id then
                earlier = earlier + 1
            end
        end
    end
    local free = {}
    local missing = false
    for _, c in ipairs(self.pools[a.beePool].cells) do
        if c.tier == tier and not used[cellKey(c)] then
            local stack = self.log:stack(self:beeAccess(a, c).inventory, c.slot)
            if stack and stack.storedItemCount and stack.storedItemCount > 0 then
                free[#free + 1] = c
            else
                missing = true
            end
        end
    end
    s.request.supply = #free == 0 and missing or nil
    local c = free[earlier + 1]
    if not c then
        return false
    end
    self:beeCount(a, c)
    s.lease = { [tier] = { tier = tier, box = c.box, slot = c.slot } }
    s.request = nil
    s.counts = {}
    self.save()
    return true
end
-- Only pending large orders sample fastTier nodes. Ordinary progress is already cached.
function E:finishSample(a, deadline)
    local s = self.s.arrays[a.address]
    local b = s.batch
    if not b or b.phase ~= 'run' or s.bee or s.request or not s.lease then
        return
    end
    local steps = self.s.patterns[b.key].steps
    local last = steps[#steps]
    local workers = {}
    if b.fixed then
        for _, w in ipairs(b.workers) do
            if self.io.time() >= deadline then
                return
            end
            local n = self.io.proxy(w.address)
            if n.hasWork() then
                local progress = n.getWorkProgress()
                if progress < last.start then
                    return
                end
                workers[#workers + 1] = { address = w.address, progress = progress }
            end
        end
    else
        workers = self.observations[a.address] or {}
    end
    local sample = { at = math.max(self.now, self.io.time()), finish = last.finish, nodes = {} }
    for _, w in pairs(workers) do
        if w.progress < last.start then
            return
        end
        sample.nodes[w.address] = w.progress
    end
    if next(sample.nodes) then
        return sample
    end
end

function E:awaitFinishing(order, eligible)
    local wait = self.finishWait
    if not wait then
        if order.considered then
            return false
        end
        order.considered = true
        self.save()
        local samples = {}
        local deadline = self.now + 5
        for _, a in ipairs(eligible) do
            local sample = self:finishSample(a, deadline)
            if sample then
                samples[a.address] = sample
            end
        end
        if not next(samples) then
            return false
        end
        wait = {
            id = order.id,
            untilTime = deadline,
            sampled = math.max(self.now, self.io.time()),
            samples = samples,
        }
        self.finishWait = wait
    end
    if math.max(self.now, self.io.time()) >= wait.untilTime then
        self.finishWait = nil
        return false
    end
    if not wait.targets and self.now - wait.sampled >= 1 then
        wait.targets = {}
        for id, old in pairs(wait.samples) do
            local current = self:finishSample(self.byAddress[id], wait.untilTime)
            local soon = current ~= nil
            if current then
                for address, progress in pairs(current.nodes) do
                    local prior = old.nodes[address]
                    local delta = prior and progress - prior or 0
                    if
                        delta <= 0
                        or (current.finish - progress) * (current.at - old.at) / delta
                            > wait.untilTime - current.at - 0.5
                    then
                        soon = false
                    end
                end
            end
            if soon then
                wait.targets[id] = true
            end
        end
        wait.samples = nil
    end
    if self.io.time() >= wait.untilTime then
        self.finishWait = nil
        return false
    end
    if wait.targets then
        local busy = false
        for id in pairs(wait.targets) do
            local s = self.s.arrays[id]
            if s.batch or s.bee or s.lease then
                busy = true
            end
        end
        if not busy then
            self.finishWait = nil
            return false
        end
    end
    self.status[self.cfg.channels[1].id] = string.format(
        '等待即将空闲的阵列（最多 %.0f 秒）',
        math.ceil(wait.untilTime - self.now)
    )
    return true
end

function E:collections()
    for _, a in ipairs(self.arrays) do
        local b = self.s.arrays[a.address].batch
        if b and b.phase == 'collect' then
            local c = b.collection
            c.elapsed = c.elapsed + math.max(0, self.now - (self.collectAt[a.address] or self.now))
            self.collectAt[a.address] = self.now
            if self.stopping or #b.workers == 15 or c.elapsed >= self.cfg.singularityWait then
                b.phase = 'wait'
                self.collectAt[a.address] = nil
                self.save()
            end
        else
            self.collectAt[a.address] = nil
        end
    end
end

function E:collectOrder(order, kind, idle)
    local selected
    for _, a in ipairs(self.arrays) do
        local b = self.s.arrays[a.address].batch
        if b and b.phase == 'collect' and not self.errors[a.address] then
            if b.collection.types[kind] then
                self.status[self.cfg.channels[1].id] =
                    '等待当前算力奇点收集批次结束（本种类已收到）'
                return
            end
            selected = a
            break
        end
    end
    if not selected then
        for _, a in ipairs(idle) do
            if #a.nodes >= 15 then
                selected = a
                break
            end
        end
    end
    if not selected then
        self.status[self.cfg.channels[1].id] =
            '等待至少关联 15 个节点的空闲阵列制作算力奇点'
        return
    end
    local s = self.s.arrays[selected.address]
    local b = s.batch
        or { key = order.key, count = 0, workers = {}, collection = { types = {}, elapsed = 0 } }
    local used = {}
    for _, w in ipairs(b.workers) do
        used[w.address] = true
    end
    local node
    for _, n in ipairs(selected.nodes) do
        if not used[n.address] then
            node = n
            break
        end
    end
    if not node then
        self.status[self.cfg.channels[1].id] =
            '等待算力奇点收集批次结束（没有空闲节点）'
        return
    end
    b.workers[#b.workers + 1] = { address = node.address, key = order.key, count = order.count }
    b.count = b.count + order.count
    b.collection.types[kind] = true
    b.phase = 'admit'
    b.admitting = true
    s.batch = b
    s.blocked = nil
    self.s.admission = {
        count = order.count,
        members = { selected.address },
        node = node.address,
    }
    self.s.queue = {}
    self.finishWait = nil
    self.save()
end

function E:schedule()
    local order = self.s.queue[1]
    if not order or self.s.admission then
        return
    end
    local meta = self.s.patterns[order.key]
    local idle, eligible = {}, {}
    for _, a in ipairs(self.arrays) do
        local s = self.s.arrays[a.address]
        local capable = true
        for _, step in ipairs(meta.steps or {}) do
            local found = false
            for tier in pairs(self:beeCells(a)) do
                if tier >= step.tier then
                    found = true
                end
            end
            if not found then
                capable = false
            end
        end
        if capable and not self.errors[a.address] then
            eligible[#eligible + 1] = a
            if not s.batch and not s.bee and not s.lease then
                idle[#idle + 1] = a
            end
        elseif not s.batch then
            s.blocked = '蜂群池中没有适用于该配方的蜂群'
        end
    end
    if meta.pattern.singularity then
        self:collectOrder(order, meta.pattern.singularity, idle)
        return
    end
    if #idle == 0 then
        self.status[self.cfg.channels[1].id] = '等待空闲阵列'
        return
    end
    local small = false
    for _, a in ipairs(idle) do
        if order.count <= #a.nodes then
            idle = { a }
            small = true
            break
        end
    end
    if not small and self:awaitFinishing(order, eligible) then
        return
    end
    self.finishWait = nil
    local chosen, nodes = {}, 0
    for _, a in ipairs(idle) do
        chosen[#chosen + 1] = a
        nodes = nodes + #a.nodes
        if nodes >= order.count then
            break
        end
    end
    local active = math.min(nodes, order.count)
    local index = 0
    local members = {}
    for _, a in ipairs(chosen) do
        local b = { key = order.key, count = 0, workers = {}, phase = 'admit', admitting = true }
        for _, n in ipairs(a.nodes) do
            if index < active then
                index = index + 1
                local count = math.floor(order.count / active)
                    + (index <= order.count % active and 1 or 0)
                assert(
                    count <= 2147483647,
                    '每节点分配份数超过可设置的并行上限，请增加节点或减少单次下单数量'
                )
                b.workers[#b.workers + 1] = { address = n.address, count = count }
                b.count = b.count + count
            end
        end
        self.s.arrays[a.address].batch = b
        self.s.arrays[a.address].blocked = nil
        members[#members + 1] = a.address
    end
    -- Persist ownership before enabling any node; the gate remains closed until every intake is confirmed.
    self.s.admission = { count = order.count, members = members }
    self.s.queue = {}
    self.save()
end

function E:admissionTick()
    local admission = self.s.admission
    if not admission then
        return
    end
    local count = 0
    for _, id in ipairs(admission.members) do
        local b = self.s.arrays[id].batch
        if self.errors[id] or b.phase ~= 'wait' then
            return
        end
        if admission.node then
            for _, w in ipairs(b.workers) do
                if w.address == admission.node then
                    count = count + w.count
                end
            end
        else
            count = count + b.count
        end
    end
    assert(
        count == admission.count and not next(self:items(self.cfg.channels[1].buffer)),
        '节点取料与订单不一致，公共原料子网仍有原料；请核对节点的实际并行能力后续做'
    )
    for _, id in ipairs(admission.members) do
        local b = self.s.arrays[id].batch
        b.admitting = nil
        if b.collection then
            b.collection.elapsed = 0
            self.collectAt[id] = self.now
            if #b.workers < 15 and not self.stopping then
                b.phase = 'collect'
            end
        end
    end
    self.s.admission = nil
    self.save()
end

function E:filters(a, unit)
    local d = self.io.proxy(a.diode)
    assert(d.hasWork() and d.isWorkAllowed(), '麦克斯韦门未运行')
    local names = self.U.keys(unit)
    if #names == 0 then
        names = { 'water' }
    end
    assert(#names <= d.getCondensateFilterCount(), '麦克斯韦门过滤槽不足')
    if self.filterNames[a.address] and self.U.equal(self.filterNames[a.address], names) then
        return
    end
    for i = 1, d.getCondensateFilterCount() do
        d.setCondensateFilterAt(i, names[i])
    end
    for i = 1, d.getCondensateFilterCount() do
        assert(
            d.getCondensateFilterAt(i) == names[i],
            '麦克斯韦门过滤器被覆盖，请移除普通流体仓'
        )
    end
    self.filterNames[a.address] = names
end

function E:health(a)
    if self.now - (self.healthAt[a.address] or -math.huge) < 10 then
        return
    end
    local d = self.io.proxy(a.diode)
    assert(d.hasWork() and d.isWorkAllowed(), '麦克斯韦门未运行')
    local names = self.filterNames[a.address]
    if names then
        for i = 1, d.getCondensateFilterCount() do
            assert(
                d.getCondensateFilterAt(i) == names[i],
                '麦克斯韦门过滤器被覆盖，请移除普通流体仓'
            )
        end
    end
    self.healthAt[a.address] = self.now
end

function E:support(a, meta)
    local bands = {}
    for _, b in ipairs(self.cfg.bands) do
        for _, m in ipairs(self.M) do
            if m.source == b.material then
                bands[m.condensate] = true
            end
        end
    end
    for name in pairs(meta.unit) do
        assert(bands[name], '请在共享流体目标中配置 ' .. self.M.name(name))
    end
    local cells = self:beeCells(a)
    for _, s in ipairs(meta.steps) do
        self.N.tier(s.tier, cells)
    end
end

function E:bees(a, s, want)
    local n = self.io.proxy(a.nodes[1].address)
    local provided = n.getProvidedTier()
    local current = provided and provided.tier
    self.provided[a.address] = current
    if not s.bee and current == want then
        if not want then
            if n.getAvailableNanites() ~= 0 then
                return false
            end
            if s.lease or s.request then
                s.lease = nil
                s.request = nil
                s.counts = {}
                self.save()
            end
            return true
        end
        if n.getAvailableNanites() > 0 then
            return true
        end
    end
    if not self:hold(a) then
        return false
    end
    if not s.bee then
        if not current then
            if s.lease and not s.lease[want] then
                s.lease = nil
                s.counts = {}
                self.save()
            end
            if not self:borrow(a, s, want) then
                self.status[a.address] = (s.request.supply and '等待补充 T' or '等待 T')
                    .. want
                    .. ' 蜂群'
                return false
            end
        end
        local tier = current or want
        assert(s.lease and s.lease[tier], '阵列内的蜂群没有借用记录')
        s.bee = { tier = tier, loading = not current, phase = 'out' }
        self.save()
    end
    local b = s.bee
    local cell = s.lease[b.tier]
    local box = self:beeAccess(a, cell)
    local route = b.loading and box.load or box.unload
    local _, port = self.log:ends(route)
    local slot = cell.slot
    local owner = 'bee:' .. a.address
    self.status[a.address] = (b.loading and '装载 T' or '回收 T') .. b.tier .. ' 蜂群'
    if b.phase == 'out' then
        if self.log:step(owner, route, false, slot, 1, true) then
            b.phase = 'io'
            self.log:finish(owner)
        end
    elseif b.phase == 'io' then
        if self.log:stack(port, 7) then
            b.phase = 'back'
            self.save()
        end
    elseif b.phase == 'back' then
        if self.log:step(owner, route, true, 7, slot) then
            b.phase = 'sync'
            self.log:finish(owner)
        end
    elseif b.phase == 'sync' then
        if
            b.loading and current == b.tier and n.getAvailableNanites() > 0
            or not b.loading and n.getAvailableNanites() == 0
        then
            if b.loading then
                s.counts[b.tier] = n.getAvailableNanites()
                self:beeCount(a, cell, s.counts[b.tier])
            else
                s.lease = nil
                s.counts = {}
            end
            s.bee = nil
            self.save()
        elseif b.loading and n.getAvailableNanites() == 0 then
            local returned = self.log:stack(box.inventory, slot)
            if returned and returned.storedItemCount > 0 then
                b.phase = 'out'
                self.save()
            else
                self.status[a.address] =
                    '等待蜂群装载确认，请检查元件内是否有蜂群'
            end
        end
    end
    return false
end

function E:recover(a, s)
    local b = s.batch
    if not b then
        return
    end
    if b.collection and not b.started then
        for _, w in ipairs(b.workers) do
            if w.accepted then
                local n = self.io.proxy(w.address)
                assert(
                    n.hasWork()
                        and n.getParallelRecipesInProgress() == w.count
                        and n.getWorkProgress() == 0,
                    '算力奇点收集记录与节点不一致，请核对节点：' .. w.address
                )
            end
        end
    end
    if b.phase ~= 'run' then
        return
    end
    local meta = self.s.patterns[b.key]
    local total = 0
    local workers = {}
    for _, node in ipairs(a.nodes) do
        local n = self.io.proxy(node.address)
        if n.hasWork() then
            local count = n.getParallelRecipesInProgress()
            assert(count > 0, '无法续做：节点未返回有效的加工份数')
            local unit = {}
            for k, v in pairs(n.getRequiredCondensate()) do
                unit[k] = v / count
            end
            assert(
                self.U.equal(unit, meta.unit)
                    and self.U.equal(self.N.steps(n.getRecipeSteps()), meta.steps),
                '节点配方与续做记录不一致'
            )
            total = total + count
            workers[#workers + 1] = { address = node.address, count = count }
        end
    end
    assert(total <= b.count, '节点加工份数与剩余原料份数之和超过订单份数')
    b.workers = workers
    b.reference = nil
    self.save()
end

function E:array(a)
    local s = self.s.arrays[a.address]
    local b = s.batch
    self:health(a)
    if not b or b.phase ~= 'run' then
        self.observations[a.address] = nil
    end
    if not b then
        if (s.lease or s.bee or s.request) and not self:bees(a, s, nil) then
            return
        end
        self:hold(a)
        self.status[a.address] = s.blocked or '空闲'
        return
    end
    local meta = self.s.patterns[b.key]
    self.status[a.address] = phases[b.phase]
        .. ' · '
        .. (b.collection and '算力奇点合并加工' or meta.pattern.label)
        .. ' ×'
        .. b.count
    if b.phase ~= 'run' and not self:hold(a) then
        return
    end
    if b.phase == 'admit' then
        local all = true
        local assigned = 0
        for _, w in ipairs(b.workers) do
            if b.collection and w.accepted then
                assigned = assigned + w.count
            else
                local n = self.io.proxy(w.address)
                if n.hasWork() then
                    n.setWorkAllowed(false)
                    local count = n.getParallelRecipesInProgress()
                    assert(
                        n.getWorkProgress() == 0 and count == w.count,
                        '节点实际取料份数与分配值不一致，或已开始加工；请核对节点的并行能力与控制设置'
                    )
                    assigned = assigned + count
                    local required = n.getRequiredCondensate()
                    local steps = self.N.steps(n.getRecipeSteps())
                    local unit = {}
                    for k, v in pairs(required) do
                        unit[k] = v / count
                    end
                    assert(self.U.total(unit) > 0, '未读取到节点的凝聚物需求')
                    if not meta.unit then
                        meta.unit = unit
                        meta.steps = steps
                        self.save()
                    end
                    assert(
                        self.U.equal(meta.unit, unit) and self.U.equal(meta.steps, steps),
                        '节点配方与已记录的处理样板不一致'
                    )
                    if w.key then
                        local own = self.s.patterns[w.key]
                        assert(
                            not own.unit
                                or self.U.equal(own.unit, unit)
                                    and self.U.equal(own.steps, steps),
                            '算力奇点配方与已记录的处理样板不一致'
                        )
                        own.unit, own.steps = unit, steps
                        w.accepted = true
                    end
                else
                    n.setMinParallel(1)
                    n.setMaxParallel(w.count)
                    n.setWorkAllowed(true)
                    all = false
                end
            end
        end
        if all then
            assert(assigned == b.count, '节点取料总数与分配数量不一致')
            b.reserve = self.U.scale(meta.unit, assigned)
            b.phase = 'wait'
            self.save()
        end
    elseif b.phase == 'collect' then
        self.status[a.address] = string.format(
            '算力奇点已收 %d/15 种；等待新种类，超时剩余 %.0f 秒',
            #b.workers,
            math.ceil(math.max(0, self.cfg.singularityWait - b.collection.elapsed))
        )
    elseif b.phase == 'wait' then
        if b.admitting then
            return
        end
        self:support(a, meta)
        if not self:grant(b) then
            self:bees(a, s, nil)
            self.status[a.address] = self.U.total(b.reserve) > self.cfg.fieldLimit
                    and string.format(
                        '凝聚物需求 %.0f L 超过场强容量 %.0f L；请按 Ctrl+C 暂停，提高约束场强度后续做',
                        self.U.total(b.reserve),
                        self.cfg.fieldLimit
                    )
                or '等待凝聚物'
            return
        end
        self:filters(a, meta.unit)
        local cells = self:beeCells(a)
        if not b.fastChecked then
            local ceiling = {}
            for tier, c in pairs(cells) do
                ceiling[tier] = self:beeCount(a, c)
            end
            local parallel = 1
            for _, w in ipairs(b.workers) do
                parallel = math.max(parallel, w.count)
            end
            local candidate = self.N.fastTier(meta.steps, cells, ceiling, parallel)
            if candidate and not self:bees(a, s, candidate) then
                return
            end
            b.fixed = candidate and self.N.fastTier(meta.steps, cells, s.counts, parallel) or nil
            b.fastChecked = true
            self.save()
        end
        local tier = b.fixed or self.N.tier(meta.steps[1].tier, cells)
        if self:bees(a, s, tier) then
            b.phase = 'run'
            b.started = true
            self.save()
            for _, w in ipairs(b.workers) do
                self.io.proxy(w.address).setWorkAllowed(false)
            end
            self.io.proxy(a.address).setWorkAllowed(true)
        end
    elseif b.phase == 'run' then
        if s.bee then
            self:bees(a, s, s.bee.tier)
            return
        end
        local workers = {}
        self.observations[a.address] = {}
        for index, w in ipairs(b.workers) do
            local n = self.io.proxy(w.address)
            if n.hasWork() then
                local progress = b.fixed and 0 or n.getWorkProgress()
                local tier = b.fixed or self.N.requested(meta.steps, progress)
                if b.fixed or n.hasWork() then
                    workers[#workers + 1] =
                        { progress = progress, tier = tier, address = w.address }
                    self.observations[a.address][index] = {
                        address = w.address,
                        progress = progress,
                        tier = tier,
                        parallel = w.count,
                        length = meta.steps[#meta.steps].finish,
                        fast = b.fixed ~= nil,
                    }
                end
            end
        end
        self.nodeHealth = self.nodeHealth or {}
        local health = self.nodeHealth[a.address] or { at = self.now, index = 1 }
        self.nodeHealth[a.address] = health
        if #workers > 0 and self.now - health.at >= 10 / #b.workers then
            health.index = (health.index - 1) % #workers + 1
            local worker = workers[health.index]
            local n = self.io.proxy(worker.address)
            local state = n.getState()
            local held = not self.io.proxy(a.address).isWorkAllowed()
            assert(
                not nodeErrors[state] or state == 'assembler-offline' and held,
                (nodeErrors[state] or state)
                    .. '：'
                    .. worker.address
                    .. '；请检查机器状态后重新运行程序'
            )
            health.at = self.now
            health.index = health.index + 1
        end
        if #workers == 0 then
            for _, w in ipairs(b.workers) do
                self.io.proxy(w.address).setWorkAllowed(false)
            end
            if not self:hold(a) then
                return
            end
            self:filters(a, {})
            b.phase = 'return'
            self.save()
            return
        end
        local ref = self.N.choose(workers, b.reference, meta.steps[#meta.steps].finish)
        if ref then
            b.reference = ref.progress
            local tier = b.fixed or self.N.tier(ref.tier, self:beeCells(a))
            if self:bees(a, s, tier) then
                local assembler = self.io.proxy(a.address)
                if not assembler.isWorkAllowed() then
                    if not self:hold(a) then
                        return
                    end
                    self:filters(a, meta.unit)
                    assembler.setWorkAllowed(true)
                end
            end
        end
    elseif b.phase == 'return' then
        if not self:bees(a, s, nil) then
            return
        end
        s.done = s.done + b.count
        s.batch = nil
        s.request = nil
        self.save()
    end
end

function E:drain()
    local failed, reason = next(self.errors)
    if failed then
        error('无法完成已接订单：' .. failed .. ' / ' .. reason)
    end
    if #self.s.queue > 0 then
        return false
    end
    if self.s.admission then
        return false
    end
    for _, c in ipairs(self.cfg.channels) do
        if next(self:items(c.buffer)) then
            return false
        end
    end
    for _, a in ipairs(self.arrays) do
        if self.s.arrays[a.address].batch then
            return false
        end
    end
    for _, a in ipairs(self.arrays) do
        if not self:hold(a) or not self:bees(a, self.s.arrays[a.address], nil) then
            return false
        end
        self:filters(a, {})
    end
    return true
end

function E:tick()
    self.now = self.io.time()
    if self.now - (self.fieldHealthAt or -math.huge) >= 10 then
        assert(self.storage.isWorkAllowed() and self.storage.hasWork(), '约束场未运行')
        assert(
            self.storage.getFieldStrength() == self.cfg.fieldLimit,
            '场强与配置不一致，请检查是否被手动修改'
        )
        self.fieldHealthAt = self.now
    end
    if not self.ready then
        local p = self.storage.getWorkProgress()
        if p < self.fieldProgress then
            self.ready = true
        end
        self.fieldProgress = p
    end
    if not self.ready then
        return
    end
    -- Every assembler must finish its old cycle before the first resource snapshot.
    if not self.recovered then
        for _, a in ipairs(self.arrays) do
            if not self:hold(a) then
                return
            end
        end
        for _, a in ipairs(self.arrays) do
            self:recover(a, self.s.arrays[a.address])
        end
        self.recovered = true
    end
    self:resources()
    self:collections()
    for _, c in ipairs(self.cfg.channels) do
        if not self.errors[c.id] then
            local ok, err = pcall(self.channel, self, c)
            if not ok then
                self.errors[c.id] = err
                self:gate(c, true)
            end
        end
    end
    if not self.errors[self.cfg.channels[1].id] then
        self:schedule()
    end
    for _, a in ipairs(self.arrays) do
        if not self.errors[a.address] then
            local ok, err = pcall(self.array, self, a)
            if not ok then
                self.errors[a.address] = err
                self:hold(a)
                for _, n in ipairs(a.nodes) do
                    self.io.proxy(n.address).setWorkAllowed(false)
                end
            end
        end
    end
    self:admissionTick()
end
return E
