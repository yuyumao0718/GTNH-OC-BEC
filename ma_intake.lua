-- Solid-only AE orders. Replenishment has its own isolated fluid network.
-- No machine may consume from the receiver until its admission gate has closed.
local I = {}
function I.key(s)
    local tag = ''
    if s.hasTag then
        assert(
            s.tag,
            '无法读取物品 NBT 数据，请启用 OC 的物品 NBT 访问或使用无标签原料'
        )
        tag = s.tag
    end
    return 'i:' .. #s.name .. ':' .. s.name .. ':' .. tostring(s.damage or 0) .. ':' .. tag
end

function I.amount(s, fluid)
    return fluid and (s.amount or s.size) or s.size
end

function I.inventory(items)
    local counts = {}
    for _, s in pairs(items) do
        local n = I.amount(s)
        if n > 0 then
            local key = I.key(s)
            counts[key] = (counts[key] or 0) + n
            assert(counts[key] <= 9007199254740991, '库存数量过大，OC 无法准确计数')
        end
    end
    return counts
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
        local entry = { slot = slot, inputs = {}, outputs = {} }
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
                    assert(
                        not fluid,
                        '处理样板的输入只能包含固体原料，请删除流体输入'
                    )
                    local key = I.key(s)
                    entry.inputs[key] = (entry.inputs[key] or 0) + n
                end
            end
        end
        assert(next(entry.inputs), '槽位 ' .. slot .. ' 中的样板未填写固体原料')

        for _, s in pairs(p.outputs) do
            if s.name and I.amount(s, s.amount ~= nil and s.damage == nil) > 0 then
                assert(s.damage ~= nil, '处理样板的输出必须是物品')
                local key = I.key(s)
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
                not subset(entry.inputs, other.inputs) and not subset(other.inputs, entry.inputs),
                '无法区分槽位 '
                    .. slot
                    .. ' 与 '
                    .. other.slot
                    .. ' 的样板；公共原料子网无法区分这些原料，请删除或调整冲突样板'
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
    local partial
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
            for key in pairs(p.inputs) do
                if (counts[key] or 0) == 0 then
                    ready = false
                    break
                end
            end
            if ready then
                return p
            end
        end
    end
    assert(
        partial,
        '公共原料子网中有无法识别或混入其他配方的原料，已停止接单；请核对原料和处理样板'
    )
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
        admitted = math.max(admitted, math.ceil(n / need))
        complete = math.min(complete, math.floor(n / need))
    end
    assert(
        admitted >= 1 and admitted <= 2147483647,
        '一单最多支持 2147483647 份配方，请分单下单'
    )
    assert(
        complete >= admitted - 1,
        '多份配方原料未到齐，接收库存可能被提前抽取或发生混料'
    )
    return admitted, complete
end
return I
