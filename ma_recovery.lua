-- Configuration edits consult the machines that still have work.
local R = {}
function R.idle(cfg, proxy)
    local ch = cfg.channels and cfg.channels[1]
    if ch and ch.buffer and ch.buffer ~= '' then
        assert(
            not next(proxy(ch.buffer).getItemsInNetwork()),
            '仍有待领取的原料，请先按 Q 完成已接订单'
        )
    end
    for _, a in ipairs(cfg.arrays or {}) do
        if a.enabled then
            for _, node in ipairs(a.nodes) do
                assert(
                    not proxy(node.address).hasWork(),
                    '仍有节点正在加工，请先按 Q 完成已接订单'
                )
            end
        end
    end
end
function R.check(cfg, old, U, proxy)
    if not old then
        return true
    end
    local oldChannel = old.channels and old.channels[1]
    local channel = cfg.channels and cfg.channels[1]
    if
        oldChannel
        and channel
        and (
            oldChannel.buffer ~= channel.buffer
            or oldChannel.redstone ~= channel.redstone
            or oldChannel.gateSide ~= channel.gateSide
        )
    then
        local reader = proxy(oldChannel.buffer)
        assert(
            not reader or not next(reader.getItemsInNetwork()),
            '公共子网还有原料，请先完成下单再更换接单设备'
        )
    end
    local arrays = U.index(cfg.arrays, 'address')
    local oldInv, newInv = U.index(old.inventories), U.index(cfg.inventories)
    local oldPools, newPools = U.index(old.beePools), U.index(cfg.beePools)
    local function sameContainer(oldId, newId)
        local from, to = oldInv[oldId], newInv[newId]
        return from and to and from.transposer == to.transposer and from.side == to.side
    end
    -- Adding slots preserves the return path of an already loaded set.
    local function keepsBeeRoute(a, b)
        if
            not b
            or not b.enabled
            or b.beePool ~= a.beePool
            or not sameContainer(a.loadPort, b.loadPort)
            or not sameContainer(a.unloadPort, b.unloadPort)
        then
            return false
        end
        local boxes = U.index(b.beeBoxes, 'box')
        for _, box in ipairs(a.beeBoxes) do
            local nextBox = boxes[box.box]
            if not nextBox or not sameContainer(box.inventory, nextBox.inventory) then
                return false
            end
        end
        local oldCells, newCells = oldPools[a.beePool].cells, newPools[b.beePool].cells
        if U.equal(oldCells, newCells) then
            return true
        end
        local slots = {}
        for _, c in ipairs(newCells) do
            slots[c.box .. ':' .. c.slot] = c.tier
        end
        for _, c in ipairs(oldCells) do
            if slots[c.box .. ':' .. c.slot] ~= c.tier then
                return false
            end
        end
        return true
    end
    for _, a in ipairs(old.arrays or {}) do
        local nextArray = arrays[a.address]
        local routeChanged = a.enabled and not keepsBeeRoute(a, nextArray)
        if routeChanged then
            local node = proxy(a.nodes[1].address)
            local tip = '请先按 Q 等待蜂群归位，再修改阵列的蜂群连接：'
                .. a.address
            assert(not node or not node.getProvidedTier(), tip)
            for _, id in ipairs({ a.loadPort, a.unloadPort }) do
                local port = oldInv[id]
                local mover = proxy(port.transposer)
                assert(
                    not mover
                        or not (
                            mover.getStackInSlot(port.side, 1)
                            or mover.getStackInSlot(port.side, 7)
                        ),
                    tip
                )
            end
        end
        if
            a.enabled and (routeChanged or not U.equal(a, nextArray) or old.storage ~= cfg.storage)
        then
            local bound = nextArray and nextArray.enabled and U.index(nextArray.nodes, 'address')
                or {}
            for _, n in ipairs(a.nodes) do
                local same = bound[n.address]
                    and old.storage == cfg.storage
                    and nextArray.diode == a.diode
                    and not routeChanged
                if not same then
                    local node = proxy(n.address)
                    assert(
                        not node or not node.hasWork(),
                        '请保留正在加工的传送节点：' .. n.address
                    )
                end
            end
        end
    end
    return true
end
return R
