-- Solid-only AE orders. Replenishment has its own isolated fluid network.
-- No machine may consume from the receiver until its admission gate has closed.
local I = {}
local function integer(n)
    return type(n) == 'number' and n >= 0 and n <= 9007199254740991 and n == math.floor(n)
end
function I.key(s, fluid)
    assert(type(s) == 'table' and type(s.name) == 'string', '物品或流体描述缺少注册名')
    local tag = ''
    if s.hasTag then
        assert(
            not fluid and type(s.tag) == 'string',
            '无法读取物品 NBT 数据，请启用 OC 的物品 NBT 访问或使用无标签原料'
        )
        tag = s.tag
    end
    return (fluid and 'f:' or 'i:')
        .. #s.name
        .. ':'
        .. s.name
        .. ':'
        .. tostring(fluid and 0 or s.damage or 0)
        .. ':'
        .. tag
end
function I.amount(s, fluid)
    local n = fluid and (s.amount or s.size) or s.size
    assert(integer(n), '物品或流体数量不是精确的非负整数')
    return n
end
function I.inventory(items, fluids)
    local counts, descriptors = {}, {}
    for _, list in ipairs({ { items, false }, { fluids, true } }) do
        for _, s in pairs(list[1]) do
            local n = I.amount(s, list[2])
            if n > 0 then
                local key = I.key(s, list[2])
                counts[key] = (counts[key] or 0) + n
                assert(integer(counts[key]), '库存数量超出精确数值范围')
                descriptors[key] = s
            end
        end
    end
    return counts, descriptors
end
local function subset(a, b)
    for key in pairs(a) do
        if not b[key] then
            return false
        end
    end
    return true
end
local function identity(counts)
    local keys, parts = {}, {}
    for key in pairs(counts) do
        keys[#keys + 1] = key
    end
    table.sort(keys)
    for _, key in ipairs(keys) do
        parts[#parts + 1] = #key .. ':' .. key .. '=' .. counts[key]
    end
    return table.concat(parts, ';')
end
-- Only the fifteen BEC computation singularities; the base singularity is not included.
function I.singularity(outputs)
    local key = next(outputs)
    if not key or next(outputs, key) then
        return
    end
    for tier = 0, 14 do
        local name = tier < 10 and 'universalsingularities:universal.circuit.singularity'
            or 'universalsingularities:universal.circuit2.singularity'
        if key == I.key({ name = name, damage = tier < 10 and tier or tier - 10 }) then
            return tier + 1
        end
    end
end
function I.catalog(patterns)
    local result = { patterns = {} }
    for slot, p in pairs(patterns) do
        assert(p.isCraftable == false, '请将槽位 ' .. slot .. ' 中的样板设为处理样板')
        assert(
            type(p.inputs) == 'table' and type(p.outputs) == 'table',
            '无法读取槽位 ' .. slot .. ' 中的样板输入和输出'
        )
        local entry = { slot = slot, inputs = {}, solids = {}, outputs = {} }
        for _, s in pairs(p.inputs) do
            if s.name then
                assert(
                    not s.name:lower():find('pattern', 1, true)
                        and not s.name:lower():find('packet', 1, true),
                    '处理样板的输入只能包含固体原料，不能包含样板或流体'
                )
                local fluid = s.amount ~= nil and s.damage == nil
                local n = I.amount(s, fluid)
                if n > 0 then
                    local key = I.key(s, fluid)
                    entry.inputs[key] = (entry.inputs[key] or 0) + n
                    if fluid then
                        error(
                            '处理样板的输入只能包含固体原料，请删除流体输入'
                        )
                    else
                        entry.solids[key] = true
                    end
                end
            end
        end
        assert(next(entry.solids), '槽位 ' .. slot .. ' 中的样板未填写固体原料')

        for _, s in pairs(p.outputs) do
            if s.name and I.amount(s, s.amount ~= nil and s.damage == nil) > 0 then
                assert(s.damage ~= nil, '处理样板的输出必须是物品')
                local key = I.key(s, false)
                entry.outputs[key] = (entry.outputs[key] or 0) + I.amount(s, false)
                entry.label = entry.label or s.label or s.name
            end
        end
        assert(next(entry.outputs), '处理样板未填写物品输出')
        entry.singularity = I.singularity(entry.outputs)
        local inputs = identity(entry.inputs)
        entry.key = #inputs .. ':' .. inputs .. identity(entry.outputs)
        for _, other in ipairs(result.patterns) do
            assert(
                not subset(entry.solids, other.solids) and not subset(other.solids, entry.solids),
                '无法区分槽位 '
                    .. slot
                    .. ' 与 '
                    .. other.slot
                    .. ' 的样板；请删除重复样板，或分别放入独立接单通道'
            )
        end
        result.patterns[#result.patterns + 1] = entry
    end
    assert(#result.patterns > 0, '配置的样板接口中没有处理样板')
    return result
end
function I.identify(catalog, counts)
    if not next(counts) then
        return nil
    end
    local found, partial
    for _, p in ipairs(catalog.patterns) do
        local compatible = true
        for key, n in pairs(counts) do
            if n > 0 and not p.inputs[key] then
                compatible = false
                break
            end
        end
        if compatible then
            partial = true
            local ready = true
            for key in pairs(p.solids) do
                if (counts[key] or 0) == 0 then
                    ready = false
                    break
                end
            end
            if ready then
                assert(
                    not found,
                    '收到的原料对应多个配方，请检查样板；机器已暂停'
                )
                found = p
            end
        end
    end
    assert(
        partial,
        '收到无法识别的原料或多种配方的混合原料；机器保持暂停'
    )
    return found
end
-- A stopped admission gate leaves k complete vectors plus at most one partial vector.
-- The largest ceil(r_i/v_i) includes that accepted partial delivery; floor-min is ready now.
function I.receipts(pattern, counts)
    local admitted, complete = 0, math.huge
    for key, n in pairs(counts) do
        assert(n == 0 or pattern.inputs[key], '已接订单中出现无法识别的原料')
    end
    for key, need in pairs(pattern.inputs) do
        local n = counts[key] or 0
        assert(integer(n), '已接订单的原料数量无效')
        admitted = math.max(admitted, math.ceil(n / need))
        complete = math.min(complete, math.floor(n / need))
    end
    assert(admitted >= 1 and admitted <= 2147483647, '已接收配方份数超出范围')
    assert(
        complete >= admitted - 1,
        '多份配方原料未到齐，接收库存可能被提前抽取或发生混料'
    )
    return admitted, complete
end
return I
