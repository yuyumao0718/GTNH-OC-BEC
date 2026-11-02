-- Explicit routes only. Each saved move owns its slots until the route completes.
local L = {}
L.__index = L
function L.new(cfg, state, proxy, save, U)
    state.moves = state.moves or {}
    return setmetatable(
        {
            cfg = cfg,
            state = state,
            proxy = proxy,
            save = save,
            inventories = U.index(cfg.inventories),
            routes = U.index(cfg.routes),
        },
        L
    )
end
function L:stack(id, slot)
    local e = assert(self.inventories[id], '未知库存：' .. tostring(id))
    return self.proxy(e.transposer).getStackInSlot(e.side, slot)
end
function L:size(id)
    local e = assert(self.inventories[id])
    return assert(
        self.proxy(e.transposer).getInventorySize(e.side),
        '无法读取库存，请检查转运器方向和连接：' .. id
    )
end
function L:ends(id)
    local r = assert(self.routes[id], '路线不存在：' .. tostring(id))
    return r.steps[1].from, r.steps[#r.steps].to
end
local function key(id, slot)
    return id .. ':' .. slot
end
function L:locks(except)
    local locks = {}
    for owner, m in pairs(self.state.moves) do
        if owner ~= except then
            for k in pairs(m.locks) do
                locks[k] = owner
            end
        end
    end
    return locks
end
function L:start(owner, route, reverse, sourceSlot, targetSlot, ioSink)
    if self.state.moves[owner] then
        return true
    end
    local steps = assert(self.routes[route]).steps
    local ops = {}
    local previous = sourceSlot
    if not reverse then
        for i, s in ipairs(steps) do
            local slot = i == #steps and targetSlot or s.slot
            ops[#ops + 1] = {
                transposer = s.transposer,
                from = s.from,
                to = s.to,
                fromSide = s.fromSide,
                toSide = s.toSide,
                fromSlot = previous,
                toSlot = slot,
            }
            previous = slot
        end
    else
        for i = #steps, 1, -1 do
            local s = steps[i]
            local slot = i == 1 and targetSlot or steps[i - 1].slot
            ops[#ops + 1] = {
                transposer = s.transposer,
                from = s.to,
                to = s.from,
                fromSide = s.toSide,
                toSide = s.fromSide,
                fromSlot = previous,
                toSlot = slot,
            }
            previous = slot
        end
    end
    local locks = {}
    for _, o in ipairs(ops) do
        locks[key(o.from, o.fromSlot)] = true
        locks[key(o.to, o.toSlot)] = true
    end
    if ioSink then
        locks[key(ops[#ops].to, 7)] = true
    end
    local occupied = self:locks()
    for k in pairs(locks) do
        if occupied[k] then
            return false
        end
    end
    for _, o in ipairs(ops) do
        if self:stack(o.to, o.toSlot) then
            return false
        end
    end
    self.state.moves[owner] = { ops = ops, index = 1, locks = locks, ioSink = ioSink }
    self.save()
    return true
end
function L:tick(owner)
    local m = assert(self.state.moves[owner])
    if m.done then
        return true
    end
    local o = m.ops[m.index]
    local source, target = self:stack(o.from, o.fromSlot), self:stack(o.to, o.toSlot)
    if not m.intent then
        assert(
            source and not target,
            '元件位置与搬运记录不一致，请检查是否被手动移动：' .. owner
        )
        m.intent = true
        self.save()
    end
    if source then
        assert(not target, '目标槽位已被占用：' .. o.to .. ':' .. o.toSlot)
        local n, err = self.proxy(o.transposer)
            .transferItem(o.fromSide, o.toSide, 1, o.fromSlot, o.toSlot)
        assert(n ~= nil, err or '元件搬运失败')
        if n == 0 then
            return false
        end
        assert(n == 1, '未能搬运一颗元件，请检查来源和目标槽位')
    else
        assert(
            target or (m.ioSink and m.index == #m.ops and self:stack(o.to, 7)),
            '找不到正在搬运的元件：' .. owner
        )
    end
    m.index = m.index + 1
    m.intent = nil
    m.done = m.index > #m.ops
    self.save()
    return m.done
end
function L:finish(owner)
    self.state.moves[owner] = nil
    self.save()
end
function L:step(owner, route, reverse, sourceSlot, targetSlot, ioSink)
    if not self:start(owner, route, reverse, sourceSlot, targetSlot, ioSink) then
        return false
    end
    return self:tick(owner)
end
return L
