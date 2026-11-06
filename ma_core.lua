-- The machines own the active work. Only learned recipes are written to disk.
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
        prepareIndex = 1,
        held = {},
        nodeCache = {},
        maxParallel = {},
        now = 0,
        settled = {},
        filterNames = {},
        filterSlots = {},
        collectAt = {},
        poolSupport = {},
        supported = {},
        bands = {},
        cells = {},
        boxes = {},
    }, E)
    local learned = {}
    for key, meta in pairs(state.patterns or {}) do
        if meta.unit and meta.pattern and next(meta.pattern.inputs) then
            learned[key] = meta
        end
    end
    for key in pairs(state) do
        state[key] = nil
    end
    state.patterns, state.arrays, state.queue, state.nextId = learned, {}, {}, 1
    self.charge, self.effective = {}, {}
    self.save = function()
        if not self.learnedDirty then
            return
        end
        local patterns = {}
        for k, meta in pairs(state.patterns) do
            if meta.unit and next(meta.pattern.inputs) then
                patterns[k] = meta
            end
        end
        self.saveFailed = true
        io.save({ patterns = patterns })
        self.saveFailed, self.learnedDirty = nil, nil
    end
    self.log = modules.Log.new(cfg, io.proxy, self.U)
    self.pools = self.U.index(cfg.beePools)
    for _, b in ipairs(cfg.bands) do
        for _, m in ipairs(self.M) do
            if m.source == b.material then
                self.bands[m.condensate] = true
            end
        end
    end
    for _, pool in ipairs(cfg.beePools) do
        local cells = {}
        for _, c in ipairs(pool.cells) do
            cells[c.tier] = cells[c.tier] or c
        end
        self.cells[pool.id] = cells
    end
    self.storage = io.proxy(cfg.storage)
    for _, a in ipairs(cfg.arrays) do
        if a.enabled then
            self.arrays[#self.arrays + 1] = a
            self.boxes[a.address] = self.U.index(a.beeBoxes, 'box')
        end
    end
    self.byAddress = self.U.index(self.arrays, 'address')
    return self
end

function E:items(address)
    local counts = self.I.inventory(self.io.proxy(address).getItemsInNetwork())
    return counts
end

function E:stockRead(refresh)
    if refresh or self.stockAt ~= self.now then
        self.stock = self.storage.getStoredCondensate()
        self.stockAt = self.now
    end
    return self.stock
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
    for _, a in ipairs(self.arrays) do
        local d = self.io.proxy(a.diode)
        assert(d.hasWork() and d.isWorkAllowed(), '请先启动麦克斯韦门：' .. a.address)
        for _, id in ipairs({ a.loadPort, a.unloadPort }) do
            assert(
                self.log:size(id) == 12,
                '蜂群 ME-IO 端口选择有误，请检查转运器和端口方向：' .. id
            )
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
    return true
end

function E:start()
    self.wasEnabled = {}
    for _, a in ipairs(self.arrays) do
        self.wasEnabled[a.address] = self.io.proxy(a.address).isWorkAllowed()
    end
    self:pause()
    self:check()
    self:scanBees()
    for _, a in ipairs(self.arrays) do
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
    self.s.queue[1] = { key = p.key, count = count }
    self.settled[c.id] = nil
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
    -- A complete ledger already covering every waiting batch needs no startup rescan.
    if
        not self.resourceScan
        and not force
        and (
            self.io.time() < (self.resourcesAt or -math.huge)
            or self.resourcesFresh
                and next(self.waiting)
                and self.U.fits(self.free, self.waiting)
        )
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
                self.U.add(reserved, remaining)
            end
            -- Publish only a complete ledger; no new grants are issued during this scan.
            local stock = self:stockRead(force)
            if not self.reserved then
                assert(
                    self.U.total(reserved) <= self.cfg.fieldLimit,
                    '已开工节点的剩余凝聚物需求超过场强容量'
                )
            end
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
    return true
end

function E:beeCells(a)
    return self.cells[a.beePool]
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
    return self.boxes[a.address][c.box]
end

-- A slot is reserved only while its cell is physically in an ME-IO port.
function E:scanBees()
    local pending, holes = {}, {}
    for _, a in ipairs(self.arrays) do
        local s = { done = 0, counts = {} }
        self.s.arrays[a.address] = s
        local n = self.io.proxy(a.nodes[1].address)
        local provided = n.getProvidedTier()
        local tier = provided and provided.tier
        local count = tier and n.getAvailableNanites() or 0
        self.provided[a.address] = tier
        if tier then
            s.lease, s.counts[tier], s.reuse = { [tier] = true }, count, true
        end
        if not self.charge[a.beePool] then
            local charge, missing = {}, {}
            self.charge[a.beePool], holes[a.beePool] = charge, missing
            for _, c in ipairs(self.pools[a.beePool].cells) do
                local stack = self.log:stack(self:beeAccess(a, c).inventory, c.slot)
                if stack then
                    charge[cellKey(c)] = stack.storedItemCount
                else
                    missing[#missing + 1] = c
                end
            end
        end
        for _, port in ipairs({ a.loadPort, a.unloadPort }) do
            local input = self.log:stack(port, 1)
            local output = self.log:stack(port, 7)
            if input or output then
                local loading = port == a.loadPort
                pending[#pending + 1] = {
                    a = a,
                    s = s,
                    loading = loading,
                    tier = (loading and output or not loading and input) and tier or nil,
                }
            end
        end
    end
    local function priority(task)
        if task.tier then
            return 1
        end
        return task.loading and 2 or 3
    end
    table.sort(pending, function(a, b)
        return priority(a) < priority(b)
    end)
    self.ports = { pending = pending, holes = holes, index = 1 }
    return self:resolvePorts()
end

function E:resolvePorts()
    local ports = self.ports
    for i = ports.index, #ports.pending do
        local task = ports.pending[i]
        local missing = ports.holes[task.a.beePool]
        local tier = task.tier or (missing[1] and missing[1].tier)
        if not task.tier then
            for _, c in ipairs(missing) do
                if c.tier ~= tier then
                    -- A loading port will reveal the grade on its own array after the IO cycle.
                    assert(
                        task.loading,
                        '蜂群元件在 ME-IO 端口中，无法辨认等级；请按等级归位后重新运行'
                    )
                    local n = self.io.proxy(task.a.nodes[1].address)
                    local provided = n.getProvidedTier()
                    if not provided then
                        ports.index = i
                        return false
                    end
                    tier = provided.tier
                    break
                end
            end
        end
        local selected
        for slotIndex, c in ipairs(missing) do
            if c.tier == tier then
                selected = table.remove(missing, slotIndex)
                break
            end
        end
        assert(
            selected and not task.s.bee,
            '请将蜂群 ME-IO 端口中的元件按等级归位后重新运行'
        )
        task.s.bee = { tier = tier, cell = selected, loading = task.loading, phase = 'back' }
        task.s.lease = { [tier] = true }
    end
    for _, missing in pairs(ports.holes) do
        assert(
            #missing == 0,
            '蜂群池有缺少元件的槽位，请按登记等级归位后重新运行'
        )
    end
    self.ports = nil
    return true
end

function E:beeCount(a, c)
    local high = 0
    for _, slot in ipairs(self.pools[a.beePool].cells) do
        if slot.tier == c.tier then
            high = math.max(high, self.charge[a.beePool][cellKey(slot)] or 0)
        end
    end
    for _, other in ipairs(self.arrays) do
        if other.beePool == a.beePool then
            local s = self.s.arrays[other.address]
            high = math.max(high, s.counts[c.tier] or 0)
            if s.lease and s.lease[c.tier] then
                high = math.max(high, s.rawCount or 0)
            end
            if s.bee and s.bee.tier == c.tier then
                high = math.max(high, s.bee.amount or 0)
            end
        end
    end
    return high
end

function E:borrow(a, s, tier)
    if not s.request or s.request.tier ~= tier then
        s.request = { tier = tier, id = self.s.nextId }
        self.s.nextId = self.s.nextId + 1
    end
    local earlier = 0
    for _, other in ipairs(self.arrays) do
        local req = self.s.arrays[other.address].request
        if other.beePool == a.beePool and req and req.tier == tier and req.id < s.request.id then
            earlier = earlier + 1
        end
    end
    for _, c in ipairs(self.pools[a.beePool].cells) do
        if c.tier == tier and (self.charge[a.beePool][cellKey(c)] or 0) > 0 then
            if earlier == 0 then
                s.request = nil
                s.lease = { [tier] = true }
                return c
            end
            earlier = earlier - 1
        end
    end
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
function E:collections()
    for _, a in ipairs(self.arrays) do
        local b = self.s.arrays[a.address].batch
        if b and b.phase == 'collect' then
            local c = b.collection
            local elapsed = math.max(0, self.now - (self.collectAt[a.address] or self.now))
            c.elapsed = c.elapsed + elapsed
            self.collectAt[a.address] = self.now
            if self.stopping or #b.workers >= #a.nodes or c.elapsed >= self.cfg.singularityWait then
                b.phase = 'wait'
                self.resourcesAt = nil
                self.collectAt[a.address] = nil
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
    local assigned = 0
    for _, n in ipairs(selected.nodes) do
        if not used[n.address] and assigned < order.count then
            b.workers[#b.workers + 1] = { address = n.address, key = order.key, count = 1 }
            assigned = assigned + 1
        end
    end
    b.count = b.count + assigned
    b.phase = 'admit'
    s.batch = b
    self.s.admission = { members = { selected.address } }
    order.count = order.count - assigned
    if order.count == 0 then
        self.s.queue = {}
    end
end

function E:schedule()
    local order = self.s.queue[1]
    if not order or self.s.admission then
        return
    end
    local meta = self.s.patterns[order.key]
    local idle = {}
    for _, a in ipairs(self.arrays) do
        local s = self.s.arrays[a.address]
        if
            not s.batch
            and not s.bee
            and (not s.lease or s.reuse)
            and not self.errors[a.address]
            and self:poolSupports(a, meta)
        then
            idle[#idle + 1] = a
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
    for _, a in ipairs(idle) do
        if order.count <= #a.nodes then
            idle = { a }
            break
        end
    end
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
        local b = { key = order.key, count = 0, workers = {}, phase = 'admit' }
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
    -- The shared gate remains closed until every intake is confirmed.
    self.s.admission = { members = members }
    self.s.queue = {}
end

function E:admissionTick()
    local admission = self.s.admission
    if not admission then
        return
    end
    for _, id in ipairs(admission.members) do
        local b = self.s.arrays[id].batch
        if self.errors[id] then
            return
        end
        if b.phase == 'admit' then
            for _, w in ipairs(b.workers) do
                local cached = self:worker(w)
                if not w.accepted and not cached.intake then
                    return
                end
            end
        end
    end
    local queued = self.s.queue[1]
    local remaining = queued
            and self.U.scale(self.s.patterns[queued.key].pattern.inputs, queued.count)
        or {}
    if not self.U.equal(self:items(self.cfg.channels[1].buffer), remaining) then
        return
    end
    -- The gate is locked and all consumers have fixed caps; AE confirms the whole allocation.
    for _, id in ipairs(admission.members) do
        local b = self.s.arrays[id].batch
        for _, w in ipairs(b.workers) do
            if not w.accepted then
                self.io.proxy(w.address).setWorkAllowed(false)
            end
        end
    end
    local ready = false
    for _, id in ipairs(admission.members) do
        local b = self.s.arrays[id].batch
        for _, w in ipairs(b.workers) do
            self:recipe(b, w)
            w.accepted = true
        end
        b.reserve = self.U.scale(self.s.patterns[b.key].unit, b.count)
        b.phase = 'wait'
        if b.collection then
            b.collection.elapsed = 0
            self.collectAt[id] = self.now
            if #b.workers < #self.byAddress[id].nodes and not self.stopping then
                b.phase = 'collect'
            end
        end
        if b.phase == 'wait' then
            ready = true
        end
    end
    self.s.admission = nil
    self.status[self.cfg.channels[1].id] = queued and '算力奇点还有原料待领取'
        or '本单已取完'
    self.resourcesAt = nil
    self.save()
    return ready
end

function E:recipe(b, w)
    local own = self.s.patterns[w.key or b.key]
    if not own.unit then
        local n = self.io.proxy(w.address)
        local count = n.getParallelRecipesInProgress()
        local unit = {}
        for name, amount in pairs(n.getRequiredCondensate()) do
            unit[name] = amount / count
        end
        own.unit, own.steps = unit, self.N.steps(n.getRecipeSteps())
        self.learnedDirty = true
    end
    if w.key then
        local base = self.s.patterns[b.key]
        assert(
            self.U.equal(base.unit, own.unit) and self.U.equal(base.steps, own.steps),
            '算力奇点处理样板的凝聚物需求或蜂群阶段不一致'
        )
    end
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

function E:support(a, meta)
    local checked = self.supported[meta]
    if checked and checked[a.beePool] then
        return
    end
    for name in pairs(meta.unit) do
        assert(
            self.bands[name],
            '请在第 1 页“预缓存纠缠流体配置”中启用 ' .. self.M.name(name)
        )
    end
    assert(self:poolSupports(a, meta), '蜂群池中没有适用于该配方的蜂群')
    checked = checked or {}
    checked[a.beePool] = true
    self.supported[meta] = checked
end

function E:bees(a, s, want)
    if not s.bee then
        local current = self.provided[a.address]
        if current == want then
            s.request = nil
            return true
        end
        local cell
        if current then
            for _, c in ipairs(self.pools[a.beePool].cells) do
                if c.tier == current and self.charge[a.beePool][cellKey(c)] == 0 then
                    cell = c
                    break
                end
            end
            if not cell then
                return false
            end
        else
            cell = self:borrow(a, s, want)
            if not cell then
                self.status[a.address] = '等待 T' .. want .. ' 蜂群'
                return false
            end
        end
        local amount = self.charge[a.beePool][cellKey(cell)]
        self.charge[a.beePool][cellKey(cell)] = nil
        s.bee = {
            cell = cell,
            amount = amount,
            tier = current or want,
            loading = not current,
            phase = 'out',
        }
    end
    local b = s.bee
    local c = b.cell
    local box = self:beeAccess(a, c).inventory
    local port = b.loading and a.loadPort or a.unloadPort
    self.status[a.address] = (b.loading and '装载 T' or '回收 T') .. b.tier .. ' 蜂群'
    if b.phase == 'out' then
        if not self.log:transfer(box, port, c.slot, 1) then
            return false
        end
        b.phase = 'back'
        if self:pulse() then
            return false
        end
    end
    if b.phase == 'back' then
        if not self.log:transfer(port, box, 7, c.slot) then
            return false
        end
        b.phase = 'sync'
        if self:pulse() then
            return false
        end
    end
    local n = self.io.proxy(a.nodes[1].address)
    local current, count
    if b.loading then
        local provided = n.getProvidedTier()
        if not provided or provided.tier ~= b.tier then
            return false
        end
        current = b.tier
        local cacheKey = a.address .. ':' .. current .. ':' .. tostring(b.amount)
        count = b.amount and self.effective[cacheKey] or n.getAvailableNanites()
        if count == 0 then
            return false
        end
        self.effective[cacheKey] = count
        s.rawCount = b.amount
        self.charge[a.beePool][cellKey(c)] = 0
        s.counts[current] = count
    else
        if n.getAvailableNanites() ~= 0 then
            return false
        end
        self.charge[a.beePool][cellKey(c)] = s.rawCount
            or self.log:stack(box, c.slot).storedItemCount
        s.rawCount = nil
        s.lease, s.counts, s.reuse = nil, {}, nil
    end
    self.provided[a.address] = current
    s.bee = nil
    if not b.loading and want then
        return self:bees(a, s, want)
    end
    return current == want
end

-- The 15 circuit singularities in 2.9.0-beta-3 share this recipe. Compressed
-- circuit arrays have the same tier sequence but use different condensates.
local singularTiers = { 10, 5, 9, 1, 4, 8, 8, 4, 4, 8, 8, 4, 2, 6, 7, 3 }
local singularUnit = {
    entangled_neutronium = 147456000,
    entangled_cosmicneutronium = 147456000,
    entangled_bedrockium = 147456000,
    entangled_infinity = 147456000,
}
function E:recover(a, s)
    local workers, total, running, unit, steps, parallel =
        {}, 0, self.wasEnabled[a.address], nil, nil, 0
    for _, conf in ipairs(a.nodes) do
        local n = self.io.proxy(conf.address)
        if n.hasWork() then
            local count = n.getParallelRecipesInProgress()
            local required = {}
            for k, v in pairs(n.getRequiredCondensate()) do
                required[k] = v / count
            end
            local recipe = self.N.steps(n.getRecipeSteps())
            assert(
                not unit or self.U.equal(unit, required) and self.U.equal(steps, recipe),
                '同一阵列的节点配方阶段或凝聚物需求不同：' .. a.address
            )
            unit, steps = required, recipe
            total = total + count
            parallel = math.max(parallel, count)
            workers[#workers + 1] = { address = conf.address, count = count }
            running = running
                or n.getWorkProgress() > 0
                or self.U.total(n.getConsumedCondensate() or {}) > 0
        end
    end
    if total == 0 then
        return
    end
    local key, matches, singular = nil, 0, false
    for k, m in pairs(self.s.patterns) do
        if
            next(m.pattern.inputs)
            and self.U.equal(unit, m.unit)
            and self.U.equal(steps, m.steps)
        then
            matches, key = matches + 1, k
            if m.pattern.singularity then
                singular = true
            end
        end
    end
    if not singular and #steps == #singularTiers and self.U.equal(unit, singularUnit) then
        singular = true
        for i, t in ipairs(singularTiers) do
            if steps[i].tier ~= t then
                singular = false
                break
            end
        end
    end
    if matches ~= 1 or singular then
        key = 'recovered:' .. a.address
        self.s.patterns[key] = {
            pattern = {
                label = singular and '算力奇点' or '接管的节点任务',
                inputs = {},
            },
            unit = unit,
            steps = steps,
        }
    end
    local b = {
        key = key,
        workers = workers,
        count = total,
        reserve = self.U.scale(unit, total),
        phase = 'wait',
    }
    s.batch = b
    if singular then
        b.collection = { elapsed = 0 }
        for _, w in ipairs(workers) do
            w.accepted = true
        end
        if not running and #workers < #a.nodes then
            b.phase = 'collect'
            s.reuse = (s.bee or s.lease) and true or nil
            self.collectAt[a.address] = self.now
        end
    end
    if running then
        b.phase, b.started, b.granted = 'run', true, true
        b.fixed = self.N.fastTier(steps, self:beeCells(a), s.counts, parallel)
        s.reuse = nil
    end
end

function E:array(a)
    local s = self.s.arrays[a.address]
    local b = s.batch
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
        local pending = {}
        for _, w in ipairs(b.workers) do
            local cached = self:worker(w)
            if not w.accepted and not cached.intake then
                pending[#pending + 1] = w
            end
        end
        if #pending > 0 and not self.intakePrepared then
            self.intakePrepared = true
            local deadline = self.processing and self.io.time() + 0.15
            for index, w in ipairs(pending) do
                if self.maxParallel[w.address] ~= w.count then
                    self.io.proxy(w.address).setMaxParallel(w.count)
                    self.maxParallel[w.address] = w.count
                    if self:pulse() then
                        return
                    end
                    if deadline and index < #pending and self.io.time() >= deadline then
                        return
                    end
                end
            end
            for _, w in ipairs(pending) do
                self.io.proxy(w.address).setWorkAllowed(true)
                self:worker(w).intake = true
            end
        end
    elseif b.phase == 'collect' then
        self.status[a.address] = string.format(
            '算力奇点占用 %d/%d 节点；等待下单，超时剩余 %.0f 秒',
            #b.workers,
            #a.nodes,
            math.ceil(math.max(0, self.cfg.singularityWait - b.collection.elapsed))
        )
    elseif b.phase == 'wait' then
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
        end
        local tier = b.fixed or self.N.tier(meta.steps[1].tier, cells)
        if self:bees(a, s, tier) then
            b.phase = 'run'
            b.started = true
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
        local now = self.io.time()
        if b.fixed or not b.nextScan or now >= b.nextScan then
            if not b.fixed then
                b.nextScan = now + 0.25
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
            end
            self.observations[a.address] = views
            if #workers == 0 then
                if not self:hold(a) then
                    return
                end
                self:filters(a, {})
                b.phase = 'return'
                self.resourcesAt = nil
                return
            end
            local ref = self.N.choose(workers, b.reference, meta.steps[#meta.steps].finish)
            if ref then
                b.reference = ref.progress
                b.targetTier = b.fixed or self.N.tier(ref.tier, self:beeCells(a))
            end
        end
        if b.targetTier and self:bees(a, s, b.targetTier) and self.held[a.address] then
            self:filters(a, meta.unit)
            self.io.proxy(a.address).setWorkAllowed(true)
            self.held[a.address] = nil
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
    end
end

function E:drain()
    local failed, reason = next(self.errors)
    if failed then
        error('无法完成已接订单：' .. failed .. ' / ' .. reason)
    end
    if not self.recovered or #self.s.queue > 0 or self.s.admission then
        return false
    end
    for _, a in ipairs(self.arrays) do
        if self.s.arrays[a.address].batch then
            return false
        end
    end
    if next(self:items(self.cfg.channels[1].buffer)) then
        return false
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
    local s = self.s.arrays[a.address]
    local processing = s.batch and s.batch.phase == 'run'
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
    if processing or s.bee then
        return self:pulse()
    end
end

function E:prepareArrays()
    local deadline = self.io.time() + 0.15
    for _ = 1, #self.arrays do
        local index = self.prepareIndex
        local a = self.arrays[index]
        self.prepareIndex = index % #self.arrays + 1
        local b = self.s.arrays[a.address].batch
        if b and b.phase == 'wait' then
            if self:arrayTick(a) then
                return true
            end
            if b.phase == 'run' then
                self.processing = true
            end
            if self.io.time() >= deadline then
                break
            end
        end
    end
end

function E:tick()
    self.now = self.io.time()
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
        if self.ports and not self:resolvePorts() then
            return
        end
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
    self.intakePrepared = false
    self.processing = false
    -- Service existing work before preparing the next whole array for intake.
    for _, a in ipairs(self.arrays) do
        local b = self.s.arrays[a.address].batch
        if (not b or b.phase ~= 'admit' and b.phase ~= 'wait') and self:arrayTick(a) then
            return
        end
        if b and b.phase == 'run' then
            self.processing = true
        end
    end
    if self:prepareArrays() then
        return
    end
    for _, a in ipairs(self.arrays) do
        local b = self.s.arrays[a.address].batch
        if b and b.phase == 'admit' and self:arrayTick(a) then
            return
        end
    end
    local admitted = self:admissionTick()
    if admitted and not self.resourceScan then
        if not self.resourcesFresh and not self:resources(true) then
            return
        end
        self:prepareArrays()
    end
end
return E
