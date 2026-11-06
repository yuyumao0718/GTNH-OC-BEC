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
    for _, a in ipairs(old.arrays or {}) do
        local nextArray = arrays[a.address]
        if a.enabled and (not U.equal(a, nextArray) or old.storage ~= cfg.storage) then
            local bound = nextArray and nextArray.enabled and U.index(nextArray.nodes, 'address')
                or {}
            for _, n in ipairs(a.nodes) do
                local same = bound[n.address]
                    and old.storage == cfg.storage
                    and nextArray.diode == a.diode
                    and nextArray.beePool == a.beePool
                    and nextArray.loadPort == a.loadPort
                    and nextArray.unloadPort == a.unloadPort
                if not same and proxy(n.address) then
                    assert(
                        not proxy(n.address).hasWork(),
                        '请保留正在加工的传送节点：' .. n.address
                    )
                end
            end
        end
    end
    return true
end
return R
