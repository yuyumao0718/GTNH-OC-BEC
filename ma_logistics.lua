-- Each ME-IO port belongs to one transposer.
local L = {}
L.__index = L
function L.new(cfg, proxy, U)
    return setmetatable({ proxy = proxy, inventories = U.index(cfg.inventories) }, L)
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

function L:transfer(source, target, sourceSlot, targetSlot)
    local from, to = self.inventories[source], self.inventories[target]
    local n, err = self.proxy(from.transposer)
        .transferItem(from.side, to.side, 1, sourceSlot, targetSlot)
    assert(n ~= nil, err or '元件搬运失败')
    return n > 0
end
return L
