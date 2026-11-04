-- One ledger per raw AE network, regardless of how many entanglers share it.
local R = {}
R.__index = R
function R.new(engine)
    local self =
        setmetatable({ e = engine, materials = {}, bands = {}, detail = {}, returns = {} }, R)
    local e = engine
    e.s.refill = e.s.refill or { feeds = {}, generators = {}, active = {} }
    self.s = e.s.refill
    for _, m in ipairs(e.M) do
        self.materials[m.source] = m
    end
    for _, b in ipairs(e.cfg.bands) do
        assert(self.materials[b.material], '未知流体：' .. b.material)
        self.bands[b.material] = b
    end
    for _, f in ipairs(e.cfg.feeds) do
        self.s.feeds[f.id] = self.s.feeds[f.id] or { pending = {}, retry = {} }
        assert(e.log:size(f.io) == 12, '主网流体转运 ME-IO 端口选择有误：' .. f.io)
        for i, c in ipairs(f.cells) do
            local loading = self.s.feeds[f.id].loading
            if not loading or loading.index ~= i then
                self:cell(c)
            end
        end
    end
    return self
end

function R:cell(c, stack)
    local e = self.e
    local source = c.inventory
    stack = stack
        or assert(
            e.log:stack(source, c.slot),
            '指定驱动器槽位中没有流体元件：' .. source .. ':' .. c.slot
        )
    assert(
        stack.storedFluidCount and stack.remainingFluidCount,
        '驱动器槽位须放置已分区的 ME 流体存储元件'
    )
    for _, fluid in pairs(stack.availableFluids or {}) do
        assert(
            fluid.name == c.material,
            '流体元件中含有其他流体，预期流体为：' .. c.material
        )
    end
    return stack.storedFluidCount, stack.storedFluidCount + stack.remainingFluidCount
end

function R:generators(feed)
    local e = self.e
    if not feed and e.now < (self.generatorAt or -math.huge) then
        return
    end
    if not feed then
        self.generatorAt = e.io.time() + 5
    end
    for _, g in ipairs(e.cfg.generators) do
        if not feed or g.feed == feed then
            local p = e.io.proxy(g.address)
            local busy = p.hasWork()
            local progress = busy and p.getWorkProgress() or 0
            local s = self.s.generators[g.address] or { epoch = 0 }
            self.s.generators[g.address] = s
            if s.busy and (not busy or progress < s.progress) then
                s.epoch = s.epoch + 1
            end
            if s.busy ~= busy or s.progress ~= progress then
                e.dirty = true
            end
            s.busy, s.progress = busy, progress
            self.enabled = self.enabled or {}
            if not feed and not self.enabled[g.address] then
                p.setWorkAllowed(true)
                self.enabled[g.address] = true
            end
        end
    end
end

function R:observe(f)
    local e = self.e
    local s = self.s.feeds[f.id]
    for i, c in ipairs(f.cells) do
        if not s.loading or s.loading.index ~= i then
            local m = self.materials[c.material]
            local pending = s.pending[i]
            local amount, capacity
            if not s.initialized or pending and not pending.finish then
                amount, capacity = self:cell(c)
            end
            -- A machine can start between the earlier machine sample and this cell read.
            if not s.initialized or pending and not pending.finish and amount < m.unit then
                self:generators(f.id)
            end
            if not s.initialized and not pending then
                local busy = false
                for _, g in ipairs(e.cfg.generators) do
                    if g.feed == f.id and self.s.generators[g.address].busy then
                        busy = true
                    end
                end
                if amount >= m.unit or busy then
                    pending = { amount = busy and capacity or amount }
                    s.pending[i] = pending
                    e.dirty = true
                end
            end
            if pending then
                if pending.finish then
                    local done = true
                    for address, epoch in pairs(pending.finish) do
                        local g = self.s.generators[address]
                        if g.busy and g.epoch < epoch then
                            done = false
                        end
                    end
                    if done then
                        s.pending[i] = nil
                        e.dirty = true
                    end
                elseif amount < m.unit then
                    pending.finish = {}
                    e.dirty = true
                    for _, g in ipairs(e.cfg.generators) do
                        if g.feed == f.id then
                            local gs = self.s.generators[g.address]
                            if gs.busy then
                                pending.finish[g.address] = gs.epoch + 1
                            end
                        end
                    end
                end
            elseif amount and amount >= m.unit then
                s.pending[i] = { amount = amount }
                e.dirty = true
            end
        end
    end
    if not s.initialized then
        s.initialized = true
        e.dirty = true
    end
end

function R:receive(f)
    local e = self.e
    local s = self.s.feeds[f.id]
    local task = s.loading
    if not task then
        return
    end
    local c = f.cells[task.index]
    local owner = 'refill:' .. f.id
    if task.phase == 'out' then
        if e.log:step(owner, c.inventory, f.io, c.slot, 1, true) then
            task.phase = 'io'
            e.log:finish(owner)
        end
    elseif task.phase == 'io' then
        local wait = self.returns[f.id]
        if not wait or wait.task ~= task then
            wait = { task = task, since = e.now }
            self.returns[f.id] = wait
        end
        if e.now < (wait.nextAt or -math.huge) then
            return
        end
        local stack = e.log:stack(f.io, 7)
        if stack then
            self.returns[f.id] = nil
            task.amount = self:cell(c, stack)
            task.phase = 'back'
            e.save()
        elseif e.now - wait.since >= 30 then
            wait.nextAt = e.now + 1
        end
    elseif task.phase == 'back' then
        if e.log:step(owner, f.io, c.inventory, 7, c.slot) then
            if task.amount >= self.materials[c.material].unit then
                s.pending[task.index] = { amount = task.amount }
            else
                s.retry[task.index] = e.now + 5
            end
            s.loading = nil
            e.log:finish(owner)
        end
    end
end

function R:tick()
    if not self.e.reserved then
        return
    end
    if self.e.now < (self.scanAt or -math.huge) then
        for _, f in ipairs(self.e.cfg.feeds) do
            self:receive(f)
        end
        return
    end
    self:scan()
    self.scanAt = self.e.io.time() + 1
end

function R:scan()
    local e = self.e
    self:generators()
    for _, f in ipairs(e.cfg.feeds) do
        self:observe(f)
        self:receive(f)
    end
    -- Accepted orders may still need condensate while a normal shutdown drains them.
    if e.stopping and #e.s.queue == 0 then
        local busy = false
        for _, s in pairs(e.s.arrays) do
            if s.batch then
                busy = true
            end
        end
        if not busy then
            return
        end
    end
    -- Clearing a completed production claim must precede the matching stock read.
    e.stock = e.storage.getStoredCondensate()
    local pending = {}
    for _, f in ipairs(e.cfg.feeds) do
        local s = self.s.feeds[f.id]
        for i, p in pairs(s.pending) do
            local key = self.materials[f.cells[i].material].condensate
            pending[key] = (pending[key] or 0) + p.amount
        end
        if s.loading then
            local key = self.materials[f.cells[s.loading.index].material].condensate
            pending[key] = (pending[key] or 0) + s.loading.capacity
        end
    end
    -- Potential output is retained until every generator consuming that cell has finished.
    local capacity = e.U.total(e.stock) + e.U.total(pending)
    for _, b in ipairs(e.cfg.bands) do
        local m = self.materials[b.material]
        local free = (e.stock[m.condensate] or 0) - (e.reserved[m.condensate] or 0)
        local wasActive = self.s.active[b.material]
        if free <= b.low or free < (e.waiting[m.condensate] or 0) then
            self.s.active[b.material] = true
        end
        if free >= math.max(b.high, e.waiting[m.condensate] or 0) then
            self.s.active[b.material] = false
        end
        if wasActive ~= self.s.active[b.material] then
            e.dirty = true
        end
    end
    for _, f in ipairs(e.cfg.feeds) do
        local s = self.s.feeds[f.id]
        self.detail[f.id] = s.loading and '搬运流体元件'
            or next(s.pending) and '等待纠缠装置加工'
            or '库存充足'
        if not s.loading and not next(s.pending) then
            for _, c in ipairs(f.cells) do
                if self.s.active[c.material] then
                    self.detail[f.id] = '等待补充原料'
                    break
                end
            end
        end
        if not s.loading then
            for offset = 1, #f.cells do
                local i = ((s.cursor or 0) + offset - 1) % #f.cells + 1
                local c = f.cells[i]
                local m = self.materials[c.material]
                local b = self.bands[c.material]
                local target = (e.reserved[m.condensate] or 0)
                    + math.max(b.high, e.waiting[m.condensate] or 0)
                local forecast = (e.stock[m.condensate] or 0) + (pending[m.condensate] or 0)
                if
                    self.s.active[c.material]
                    and forecast < target
                    and not s.pending[i]
                    and e.now >= (s.retry[i] or 0)
                then
                    local _, cap = self:cell(c)
                    if capacity + cap <= e.cfg.fieldLimit then
                        s.cursor = i
                        s.loading = { index = i, phase = 'out', capacity = cap }
                        pending[m.condensate] = (pending[m.condensate] or 0) + cap
                        capacity = capacity + cap
                        self.detail[f.id] = '搬运流体元件'
                        e.save()
                        break
                    else
                        self.detail[f.id] = '当前元件完全存入有超出场强上限风险'
                    end
                end
            end
        end
    end
end
return R
