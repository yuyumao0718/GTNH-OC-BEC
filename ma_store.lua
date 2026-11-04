-- A rename commits a complete serialized snapshot on the same OpenOS filesystem.
local S = {}
function S.new(base, fs, serialization)
    local self = {}
    function self.read(name)
        local f = io.open(base .. name, 'r')
        if not f then
            return nil
        end
        local data = f:read('*a')
        f:close()
        return assert(serialization.unserialize(data), '无法读取 ' .. name)
    end
    function self.write(name, value)
        local path = base .. name
        local f = assert(io.open(path .. '.tmp', 'w'))
        assert(f:write(serialization.serialize(value)))
        assert(f:flush())
        f:close()
        assert(fs.rename(path .. '.tmp', path), '无法保存 ' .. name)
    end
    function self.clearRecipes()
        local state = self.read('multi.state') or {}
        assert(
            not state.admission and #(state.queue or {}) == 0,
            '仍有待完成订单，请先运行程序并按 Q 完成后退出'
        )
        for _, a in pairs(state.arrays or {}) do
            assert(
                not a.batch and not a.lease and not a.bee,
                '仍有加工或蜂群任务，请先运行程序并按 Q 完成后退出'
            )
        end
        local count = 0
        for _, p in pairs(state.patterns or {}) do
            if p.unit or p.steps then
                p.unit, p.steps = nil, nil
                count = count + 1
            end
        end
        if count > 0 then
            self.write('multi.state', state)
        end
        return count, state.patterns or {}
    end
    return self
end
return S
