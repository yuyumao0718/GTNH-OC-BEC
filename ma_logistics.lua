-- Direct cell transfers. Keep both slots reserved until the move is acknowledged.
local L = {}
L.__index = L
function L.new(cfg, state, proxy, save, U)
    state.moves = state.moves or {}
    return setmetatable({
        state = state,
        proxy = proxy,
        save = save,
        inventories = U.index(cfg.inventories),
    }, L)
end

function L:stack(id, slot)
    local e = assert(self.inventories[id], '未配置元件容器连接：' .. tostring(id))
    return self.proxy(e.transposer).getStackInSlot(e.side, slot)
end

function L:size(id)
    local e = assert(self.inventories[id])
    return assert(
        self.proxy(e.transposer).getInventorySize(e.side),
        '无法读取元件容器，请检查转运器方向和连接：' .. id
    )
end

local function key(id, slot)
    return id .. ':' .. slot
end

function L:locks()
    local locks = {}
    for owner, m in pairs(self.state.moves) do
        for k in pairs(m.locks) do
            locks[k] = owner
        end
    end
    return locks
end

function L:start(owner, from, to, sourceSlot, targetSlot, ioSink)
    if self.state.moves[owner] then
        return true
    end
    local locks = { [key(from, sourceSlot)] = true, [key(to, targetSlot)] = true }
    if ioSink then
        locks[key(to, 7)] = true
    end
    local occupied = self:locks()
    for k in pairs(locks) do
        if occupied[k] then
            return false
        end
    end
    if self:stack(to, targetSlot) then
        return false
    end
    self.state.moves[owner] = {
        from = from,
        to = to,
        fromSlot = sourceSlot,
        toSlot = targetSlot,
        locks = locks,
        ioSink = ioSink,
    }
    return true
end

function L:tick(owner)
    local m = assert(self.state.moves[owner])
    if m.done then
        return true
    end
    local source, target = self:stack(m.from, m.fromSlot), self:stack(m.to, m.toSlot)
    if not m.intent then
        assert(
            source and not target,
            '元件位置与搬运记录不一致，请检查是否被手动移动：' .. owner
        )
        m.intent = true
        self.save()
    end
    if source then
        assert(not target, '目标槽位已被占用：' .. m.to .. ':' .. m.toSlot)
        local from, to = self.inventories[m.from], self.inventories[m.to]
        local n, err = self.proxy(from.transposer)
            .transferItem(from.side, to.side, 1, m.fromSlot, m.toSlot)
        assert(n ~= nil, err or '元件搬运失败')
        if n == 0 then
            return false
        end
    else
        assert(
            target or (m.ioSink and self:stack(m.to, 7)),
            '找不到正在搬运的元件：' .. owner
        )
    end
    m.intent = nil
    m.done = true
    return m.done
end

function L:finish(owner)
    self.state.moves[owner] = nil
    self.save()
end

function L:step(owner, from, to, sourceSlot, targetSlot, ioSink)
    if not self:start(owner, from, to, sourceSlot, targetSlot, ioSink) then
        return false
    end
    return self:tick(owner)
end
return L
