-- Arrays yield while hardware is pending; all durable state contains plain tables.
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
    ['return'] = '加工完成',
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
        beeChecked = {},
        held = {},
        nodeCache = {},
        maxParallel = {},
        intakeSample = {},
        now = 0,
        settled = {},
        filterNames = {},
        filterSlots = {},
        healthAt = {},
        collectAt = {},
        poolSupport = {},
    }, E)
    for _, key in ipairs({ 'arrays', 'queue', 'patterns', 'moves', 'poolCounts' }) do
        state[key] = state[key] or {}
    end
    state.nextId = state.nextId or 1
    self.save = function()
        self.saveFailed = true
        io.save(state)
        self.saveFailed = nil
        self.dirty = nil
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

function E:subscribe(enabled)
    if self.subscribed ~= enabled then
        self.io.proxy(self.cfg.channels[1].buffer).setItemEventSubscription(enabled)
        self.subscribed = enabled
        if enabled then
            self.inputDirty = true
        end
    end
end

function E:event(name, address)
    if
        name == 'network_item_changed'
        and address == self.cfg.channels[1].buffer
        and self.subscribed
    then
        self.inputDirty = true
    end
end

function E:worker(w)
    local cached = self.nodeCache[w.address]
    if not cached or cached.worker ~= w then
        cached = { worker = w }
        self.nodeCache[w.address] = cached
    end
    return cached
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
    self.inputDirty = true
    self:gate(self.cfg.channels[1], true)
end

function E:pulse()
    return self.io.pulse and self.io.pulse()
end

function E:hold(a)
    if self.held[a.address] then
        return true
    end
    local p = self.io.proxy(a.address)
    if p.isWorkAllowed() then
        p.setWorkAllowed(false)
    end
    self.held[a.address] = not p.hasWork()
    return self.held[a.address]
end

function E:pause()
    self.gateOutput = nil
    self.held = {}
    self.resourceScan = nil
    pcall(self.subscribe, self, false)
    pcall(self.gate, self, self.cfg.channels[1], true)
    for _, a in ipairs(self.arrays) do
        pcall(self.hold, self, a)
        for _, n in ipairs(a.nodes) do
            pcall(function()
                self.io.proxy(n.address).setWorkAllowed(false)
            end)
        end
    end
    if not self.saveFailed then
        self.save()
    end
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
    assert(
        self.io.proxy(self.cfg.channels[1].buffer).setItemEventSubscription,
        '公共原料子网 ME 控制器不支持物品变化事件，请检查 OC 版本'
    )
    self:catalogsRead()
    local needed = 0
    for _, a in ipairs(self.arrays) do
        for _, id in ipairs({ a.loadPort, a.unloadPort }) do
            assert(
                self.log:size(id) == 12,
                '蜂群 ME-IO 端口选择有误，请检查转运器和端口方向：' .. id
            )
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
            local node = self.io.proxy(n.address)
            node.setSpeedDivisor(1)
            node.setMinParallel(1)
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
        self:subscribe(false)
        self:gate(c, true)
        return
    end
    self:subscribe(true)
    if not self.inputDirty and self.now < (self.inputAt or 0) then
        return
    end
    self.inputDirty = false
    self.inputAt = self.now + 10
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
        self.inputAt = self.now + 0.25
        return
    end
    if self.now - self.settled[c.id] < 0.25 then
        self.inputAt = self.settled[c.id] + 0.25
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
    self:subscribe(false)
end

function E:remaining(s, visit)
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
    local unit = self.s.patterns[b.key].unit
    for _, w in ipairs(b.workers) do
        local cached = self:worker(w)
        if not cached.done and not cached.full then
            local consumed = self.io.proxy(w.address).getConsumedCondensate()
            -- Completion can clear the recipe during the callback.
            if consumed then
                local full = true
                for k, v in pairs(unit) do
                    local left = v * w.count - (consumed[k] or 0)
                    assert(left >= 0, '节点报告的凝聚物消耗量超过配方需求')
                    result[k] = (result[k] or 0) + left
                    full = full and left == 0
                end
                cached.full = full
            end
            if visit then
                visit()
            end
        end
        if self:pulse() then
            return
        end
    end
    return result
end

function E:resources(force)
    self.waiting = {}
    for _, a in ipairs(self.arrays) do
        local s = self.s.arrays[a.address]
        local b = s.batch
        if b then
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
    if
        not self.resourceScan
        and not force
        and self.io.time() < (self.resourcesAt or -math.huge)
    then
        return true
    end
    if not self.resourceScan then
        self.resourcesFresh = false
        self.resourceScan = coroutine.create(function()
            local reserved = {}
            local reads = 0
            local function visit()
                reads = reads + 1
                if reads == 4 then
                    reads = 0
                    coroutine.yield(false)
                end
            end
            for _, a in ipairs(self.arrays) do
                local remaining = self:remaining(self.s.arrays[a.address], visit)
                if not remaining then
                    return false
                end
                self.U.add(reserved, remaining)
            end
            -- Publish only a complete ledger; no new grants are issued during this scan.
            local stock = self.storage.getStoredCondensate()
            self.stock, self.reserved = stock, reserved
            self.free = {}
            for k, v in pairs(self.stock) do
                self.free[k] = math.max(0, v - (self.reserved[k] or 0))
            end
            assert(
                self.U.total(self.stock) <= self.cfg.fieldLimit,
                '凝聚物库存超过场强容量'
            )
            self.resourcesAt = self.io.time() + 1
            self.resourcesFresh = true
            return true
        end)
    end
    local ok, complete = coroutine.resume(self.resourceScan)
    if not ok then
        self.resourceScan = nil
        error(complete, 0)
    end
    if coroutine.status(self.resourceScan) == 'dead' then
        self.resourceScan = nil
    end
    return complete
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
    if not self.resourcesFresh or self.resourceScan then
        self.resourcesAt = nil
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

function E:poolSupports(a, meta)
    if not meta.steps then
        return true
    end
    local checked = self.poolSupport[meta]
    if not checked then
        checked = {}
        self.poolSupport[meta] = checked
    end
    if checked[a.beePool] == nil then
        local cells = self:beeCells(a)
        local capable = true
        for _, step in ipairs(meta.steps) do
            local found = false
            for tier in pairs(cells) do
                if tier >= step.tier then
                    found = true
                    break
                end
            end
            if not found then
                capable = false
                break
            end
        end
        checked[a.beePool] = capable
    end
    return checked[a.beePool]
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
    local requested = not s.request or s.request.tier ~= tier
    if requested then
        s.request = { tier = tier, id = self.s.nextId }
        self.s.nextId = self.s.nextId + 1
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
    for _, c in ipairs(self.pools[a.beePool].cells) do
        if c.tier == tier and not used[cellKey(c)] then
            free[#free + 1] = c
        end
    end
    local c = free[earlier + 1]
    if not c then
        if requested then
            self.save()
        end
        return false
    end
    s.lease = { [tier] = { tier = tier, box = c.box, slot = c.slot } }
    s.request = nil
    s.counts = {}
    self.save()
    return true
end

function E:beeWaiting(a, s)
    for _, other in ipairs(self.cfg.arrays) do
        if other.address ~= a.address and other.beePool == a.beePool then
            local state = self.s.arrays[other.address]
            local request = state and state.request
            if request and s.lease and s.lease[request.tier] then
                return true
            end
        end
    end
    return false
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
            if not self:worker(w).done and n.hasWork() then
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
            if s.batch or s.bee or s.lease and not s.reuse then
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
            local elapsed = math.max(0, self.now - (self.collectAt[a.address] or self.now))
            c.elapsed = c.elapsed + elapsed
            if elapsed > 0 then
                self.dirty = true
            end
            self.collectAt[a.address] = self.now
            if self.stopping or #b.workers >= #a.nodes or c.elapsed >= self.cfg.singularityWait then
                b.phase = 'wait'
                self.resourcesAt = nil
                self.collectAt[a.address] = nil
                self.save()
            end
        else
            self.collectAt[a.address] = nil
        end
    end
end

function E:collectOrder(order, idle)
    local selected
    for _, a in ipairs(self.arrays) do
        local b = self.s.arrays[a.address].batch
        if b and b.phase == 'collect' and not self.errors[a.address] then
            selected = a
            break
        end
    end
    selected = selected or idle[1]
    if not selected then
        self.status[self.cfg.channels[1].id] = '等待空闲阵列接收剩余算力奇点原料'
        return
    end
    local s = self.s.arrays[selected.address]
    local b = s.batch or { key = order.key, count = 0, workers = {}, collection = { elapsed = 0 } }
    local used = {}
    for _, w in ipairs(b.workers) do
        used[w.address] = true
    end
    local previous = b.count
    local assigned = 0
    for _, n in ipairs(selected.nodes) do
        if not used[n.address] and assigned < order.count then
            b.workers[#b.workers + 1] = { address = n.address, key = order.key, count = 1 }
            assigned = assigned + 1
        end
    end
    b.count = b.count + assigned
    b.phase = 'admit'
    b.admitting = true
    s.batch = b
    self.s.admission = {
        count = assigned,
        members = { selected.address },
        previous = previous,
    }
    order.count = order.count - assigned
    if order.count == 0 then
        self.s.queue = {}
    end
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
        local capable = self:poolSupports(a, meta)
        if capable and not self.errors[a.address] then
            eligible[#eligible + 1] = a
            if not s.batch and not s.bee and (not s.lease or s.reuse) then
                idle[#idle + 1] = a
            end
        end
    end
    if meta.pattern.singularity then
        self:collectOrder(order, idle)
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
        count = count + b.count
    end
    count = count - (admission.previous or 0)
    local queued = self.s.queue[1]
    local remaining = queued
            and self.U.scale(self.s.patterns[queued.key].pattern.inputs, queued.count)
        or {}
    assert(
        count == admission.count
            and self.U.equal(self:items(self.cfg.channels[1].buffer), remaining),
        '节点取料或公共原料子网余量与订单不一致；请核对实际原料和节点并行能力后续做'
    )
    local ready = {}
    for _, id in ipairs(admission.members) do
        local b = self.s.arrays[id].batch
        b.admitting = nil
        if b.collection then
            b.collection.elapsed = 0
            self.collectAt[id] = self.now
            if #b.workers < #self.byAddress[id].nodes and not self.stopping then
                b.phase = 'collect'
            end
        end
        if b.phase == 'wait' then
            ready[#ready + 1] = id
        end
    end
    self.s.admission = nil
    self.save()
    return #ready > 0 and ready or nil
end

function E:filters(a, unit)
    local names = self.U.keys(unit)
    if #names == 0 then
        names = { 'water' }
    end
    if self.filterNames[a.address] and self.U.equal(self.filterNames[a.address], names) then
        return
    end
    local d = self.io.proxy(a.diode)
    local slots = self.filterSlots[a.address] or d.getCondensateFilterCount()
    self.filterSlots[a.address] = slots
    assert(#names <= slots, '麦克斯韦门过滤槽不足')
    local before = self.filterNames[a.address] or d.getCondensateFilters()
    for i = 1, slots do
        if before[i] ~= names[i] then
            d.setCondensateFilterAt(i, names[i])
        end
    end
    self.filterNames[a.address] = names
end

function E:health(a)
    if self.now - (self.healthAt[a.address] or -math.huge) < 10 then
        return
    end
    local d = self.io.proxy(a.diode)
    assert(d.hasWork() and d.isWorkAllowed(), '麦克斯韦门未运行')
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
        assert(
            bands[name],
            '请在第 1 页“预缓存纠缠流体配置”中启用 ' .. self.M.name(name)
        )
    end
    assert(self:poolSupports(a, meta), '蜂群池中没有适用于该配方的蜂群')
end

function E:bees(a, s, want)
    local checked = self.beeChecked[a.address]
    if not s.bee and checked and checked.tier == want then
        if want and checked.count > 0 then
            return true
        elseif not want and checked.count == 0 and not s.lease and not s.request then
            return true
        end
    end
    local n = self.io.proxy(a.nodes[1].address)
    local current
    if not s.bee and not s.request then
        if checked then
            current = checked.tier
        else
            local provided = n.getProvidedTier()
            current = provided and provided.tier
        end
        self.provided[a.address] = current
    end
    if not s.bee and current == want then
        local count = checked and checked.count or n.getAvailableNanites()
        self.beeChecked[a.address] = { tier = current, count = count }
        if not want then
            if count ~= 0 then
                return false
            end
            if s.lease or s.request then
                s.lease = nil
                s.request = nil
                s.counts = {}
                s.reuse = nil
                self.save()
            end
            return true
        end
        if count > 0 then
            return true
        end
    end
    if not s.bee then
        if not current then
            if s.lease and not s.lease[want] then
                s.lease = nil
                s.counts = {}
                self.save()
            end
            if not self:borrow(a, s, want) then
                self.status[a.address] = '等待 T' .. want .. ' 蜂群'
                return false
            end
        end
        local tier = current or want
        assert(s.lease and s.lease[tier], '阵列内的蜂群没有借用记录')
        self.beeChecked[a.address] = nil
        s.bee = { tier = tier, loading = not current, phase = 'out' }
    end
    local b = s.bee
    local cell = s.lease[b.tier]
    local box = self:beeAccess(a, cell)
    local port = b.loading and a.loadPort or a.unloadPort
    local slot = cell.slot
    local owner = 'bee:' .. a.address
    self.status[a.address] = (b.loading and '装载 T' or '回收 T') .. b.tier .. ' 蜂群'
    if b.phase == 'out' then
        if not self.log:step(owner, box.inventory, port, slot, 1, true) then
            return false
        end
        b.phase = 'back'
        self.log:finish(owner)
        if self:pulse() then
            return false
        end
    end
    -- Existing checkpoints can still name the return wait 'io'.
    if b.phase == 'back' or b.phase == 'io' then
        if not self.log:step(owner, port, box.inventory, 7, slot) then
            return false
        end
        b.phase = 'sync'
        self.log:finish(owner)
        if self:pulse() then
            return false
        end
    end
    if b.phase == 'sync' then
        local provided = n.getProvidedTier()
        current = provided and provided.tier
        self.provided[a.address] = current
        local count = n.getAvailableNanites()
        if b.loading and current == b.tier and count > 0 or not b.loading and count == 0 then
            if b.loading then
                s.counts[b.tier] = count
                self:beeCount(a, cell, s.counts[b.tier])
            else
                s.lease = nil
                s.counts = {}
                s.reuse = nil
            end
            self.beeChecked[a.address] = { tier = current, count = count }
            s.bee = nil
            self.save()
            if not b.loading and want then
                return self:bees(a, s, want)
            end
            return current == want
        end
    end
    return false
end

function E:recover(a, s)
    local b = s.batch
    if not b then
        return
    end
    if b.phase == 'admit' then
        for _, w in ipairs(b.workers) do
            if not w.accepted then
                self:worker(w).verifyRecipe = true
            end
        end
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

function E:intakes()
    local pending = {}
    for _, a in ipairs(self.arrays) do
        local b = self.s.arrays[a.address].batch
        if b and b.phase == 'admit' and not self.errors[a.address] then
            for _, w in ipairs(b.workers) do
                local cached = self:worker(w)
                if
                    not w.accepted
                    and not cached.accepted
                    and (
                        not cached.intake and self.maxParallel[w.address] ~= w.count
                        or cached.verifyRecipe
                    )
                then
                    pending[#pending + 1] = w.address
                end
            end
        end
    end
    self.intakeNodes = {}
    if #pending > 0 then
        local first = (self.intakeCursor or 0) % #pending
        for offset = 1, math.min(4, #pending) do
            self.intakeNodes[pending[(first + offset - 1) % #pending + 1]] = true
        end
        self.intakeCursor = first + math.min(4, #pending)
    end
end

function E:array(a)
    local s = self.s.arrays[a.address]
    local b = s.batch
    self:health(a)
    if not b or b.phase ~= 'run' then
        self.observations[a.address] = nil
    end
    if not b then
        if not self:hold(a) then
            return
        end
        if not s.reuse or self.stopping or s.bee or self:beeWaiting(a, s) then
            if (s.lease or s.bee or s.request) and not self:bees(a, s, nil) then
                return
            end
        end
        local order = self.s.queue[1]
        self.status[a.address] = order
                and not self:poolSupports(a, self.s.patterns[order.key])
                and '蜂群池中没有适用于当前待分配订单的蜂群'
            or '空闲'
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
    if s.reuse and (s.bee or b.collection or self:beeWaiting(a, s)) then
        if not self:bees(a, s, nil) then
            return
        end
    end
    if b.phase == 'admit' then
        local all = true
        local assigned = 0
        for _, w in ipairs(b.workers) do
            local cached = self:worker(w)
            if w.accepted or cached.accepted then
                assigned = assigned + w.count
            elseif
                cached.verifyRecipe and not (self.intakeNodes and self.intakeNodes[w.address])
            then
                all = false
            else
                local n = self.io.proxy(w.address)
                if n.hasWork() then
                    n.setWorkAllowed(false)
                    local own = self.s.patterns[w.key or b.key]
                    local sample = self.s.admission or b
                    -- Per-node caps and the shared-network remainder verify the full allocation.
                    local count = w.count
                    if
                        self.intakeSample[a.address] ~= sample
                        or not own.unit
                        or cached.verifyRecipe
                    then
                        count = n.getParallelRecipesInProgress()
                        assert(
                            n.getWorkProgress() == 0 and count == w.count,
                            '节点实际取料份数与分配值不一致，或已开始加工；请核对节点的并行能力与控制设置'
                        )
                        self.intakeSample[a.address] = sample
                    end
                    assigned = assigned + count
                    if not own.unit or cached.verifyRecipe then
                        local required = n.getRequiredCondensate()
                        local steps = self.N.steps(n.getRecipeSteps())
                        local unit = {}
                        for k, v in pairs(required) do
                            unit[k] = v / count
                        end
                        assert(self.U.total(unit) > 0, '未读取到节点的凝聚物需求')
                        assert(
                            not own.unit
                                or self.U.equal(own.unit, unit)
                                    and self.U.equal(own.steps, steps),
                            '节点配方与已记录的处理样板不一致'
                        )
                        assert(
                            not w.key
                                or not meta.unit
                                or self.U.equal(meta.unit, unit)
                                    and self.U.equal(meta.steps, steps),
                            '算力奇点配方与已记录的处理样板不一致'
                        )
                        if not own.unit then
                            own.unit, own.steps = unit, steps
                            self.save()
                        end
                        cached.verifyRecipe = nil
                    end
                    if w.key then
                        assert(
                            self.U.equal(meta.unit, own.unit)
                                and self.U.equal(meta.steps, own.steps),
                            '算力奇点配方与已记录的处理样板不一致'
                        )
                        w.accepted = true
                    end
                    cached.accepted = true
                else
                    if
                        not cached.intake
                        and (
                            self.maxParallel[w.address] == w.count
                            or self.intakeNodes and self.intakeNodes[w.address]
                        )
                    then
                        if self.maxParallel[w.address] ~= w.count then
                            n.setMaxParallel(w.count)
                            self.maxParallel[w.address] = w.count
                        end
                        n.setWorkAllowed(true)
                        cached.intake = true
                    end
                    all = false
                end
                if self:pulse() then
                    return
                end
            end
        end
        if all then
            assert(assigned == b.count, '节点取料总数与分配数量不一致')
            b.reserve = self.U.scale(meta.unit, assigned)
            b.phase = 'wait'
            self.resourcesAt = nil
            self.save()
        end
    elseif b.phase == 'collect' then
        self.status[a.address] = string.format(
            '算力奇点占用 %d/%d 节点；等待下单，超时剩余 %.0f 秒',
            #b.workers,
            #a.nodes,
            math.ceil(math.max(0, self.cfg.singularityWait - b.collection.elapsed))
        )
    elseif b.phase == 'wait' then
        if b.admitting then
            return
        end
        self:support(a, meta)
        if not self:grant(b) then
            if self:pulse() then
                return
            end
            self:bees(a, s, nil)
            return
        end
        self:filters(a, meta.unit)
        s.reuse = nil
        local cells = self:beeCells(a)
        if not b.fastChecked then
            local highest = 1
            for _, step in ipairs(meta.steps) do
                highest = math.max(highest, step.tier)
            end
            local grade = self.N.tier(highest, cells)
            local ceiling = { [grade] = self:beeCount(a, cells[grade]) }
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
            self.io.proxy(a.address).setWorkAllowed(true)
            self.held[a.address] = nil
        end
    elseif b.phase == 'run' then
        if s.bee then
            local loading = s.bee.loading and s.bee.tier or nil
            if not self:bees(a, s, loading) then
                return
            end
        end
        local workers = {}
        local views = {}
        for index, w in ipairs(b.workers) do
            local n = self.io.proxy(w.address)
            local cached = self:worker(w)
            if not cached.done and n.hasWork() then
                local progress = b.fixed and 0 or n.getWorkProgress()
                local tier = b.fixed or self.N.requested(meta.steps, progress)
                if b.fixed or n.hasWork() then
                    workers[#workers + 1] =
                        { progress = progress, tier = tier, address = w.address }
                    views[index] = {
                        address = w.address,
                        progress = progress,
                        tier = tier,
                        parallel = w.count,
                        length = meta.steps[#meta.steps].finish,
                        fast = b.fixed ~= nil,
                    }
                else
                    cached.done = true
                end
            else
                cached.done = true
            end
            if self:pulse() then
                return
            end
        end
        self.observations[a.address] = views
        if #workers == 0 then
            if not self:hold(a) then
                return
            end
            self:filters(a, {})
            b.phase = 'return'
            self.resourcesAt = nil
            self.save()
            return
        end
        local ref = self.N.choose(workers, b.reference, meta.steps[#meta.steps].finish)
        if ref then
            b.reference = ref.progress
            local tier = b.fixed or self.N.tier(ref.tier, self:beeCells(a))
            if self:bees(a, s, tier) and self.held[a.address] then
                self:filters(a, meta.unit)
                self.io.proxy(a.address).setWorkAllowed(true)
                self.held[a.address] = nil
            end
        end
    elseif b.phase == 'return' then
        if self.stopping or s.bee or self:beeWaiting(a, s) then
            if not self:bees(a, s, nil) then
                return
            end
        else
            s.reuse = s.lease and true or nil
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

function E:arrayTick(a)
    if not self.errors[a.address] then
        local ok, err = pcall(self.array, self, a)
        if not ok then
            if self.saveFailed then
                error(err, 0)
            end
            self.errors[a.address] = err
            self.held[a.address] = nil
            self:hold(a)
            for _, n in ipairs(a.nodes) do
                self.io.proxy(n.address).setWorkAllowed(false)
            end
        end
    end
    return self:pulse()
end

function E:tick()
    self.now = self.io.time()
    self.resourcesFresh = false
    if self.now - (self.fieldHealthAt or -math.huge) >= 10 then
        assert(self.storage.isWorkAllowed() and self.storage.hasWork(), '约束场未运行')
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
    if not self:resources() and not self.reserved then
        return
    end
    if self:pulse() then
        return
    end
    self:collections()
    for _, c in ipairs(self.cfg.channels) do
        if not self.errors[c.id] then
            local ok, err = pcall(self.channel, self, c)
            if not ok then
                if self.saveFailed then
                    error(err, 0)
                end
                self.errors[c.id] = err
                self:gate(c, true)
            end
        end
    end
    if not self.errors[self.cfg.channels[1].id] then
        self:schedule()
    end
    self:intakes()
    for _, a in ipairs(self.arrays) do
        if self:arrayTick(a) then
            return
        end
    end
    local admitted = self:admissionTick()
    if admitted and not self.resourceScan then
        if not self.resourcesFresh and not self:resources(true) then
            return
        end
        for _, id in ipairs(admitted) do
            if self.s.arrays[id].batch.phase == 'wait' and self:arrayTick(self.byAddress[id]) then
                return
            end
        end
    end
end
return E
