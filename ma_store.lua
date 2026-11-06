-- A rename commits a complete serialized snapshot on the same OpenOS filesystem.
local S = {}
function S.new(base, fs, serialization, yield)
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
        local buffer, bytes, seen = {}, 0, {}
        local function flush()
            if #buffer > 0 then
                assert(f:write(table.concat(buffer)))
                buffer, bytes = {}, 0
            end
            if yield then
                yield()
            end
        end
        local function put(text)
            buffer[#buffer + 1] = text
            bytes = bytes + #text
            if bytes >= 4096 or #buffer >= 256 then
                flush()
            end
        end
        local function encode(v)
            if type(v) == 'table' then
                assert(not seen[v], '不能保存包含循环引用的状态')
                seen[v] = true
                put('{')
                local index = 1
                for k, item in pairs(v) do
                    if k == index then
                        index = index + 1
                    else
                        put('[')
                        encode(k)
                        put(']=')
                    end
                    encode(item)
                    put(',')
                end
                put('}')
                seen[v] = nil
            elseif type(v) == 'string' then
                put('"')
                -- Short chunks avoid OC's expensive long-string pattern implementation.
                for i = 1, #v, 128 do
                    put((v:sub(i, i + 127):gsub('[%z\1-\31\\"]', function(c)
                        return string.format('\\%03d', c:byte())
                    end)))
                end
                put('"')
            elseif type(v) == 'number' and v == v and math.abs(v) < math.huge then
                put(string.format('%.17g', v))
            else
                put(serialization.serialize(v))
            end
        end
        local ok, err = pcall(function()
            encode(value)
            flush()
            assert(f:flush())
        end)
        local closed, closeErr = f:close()
        assert(ok, err)
        -- OpenOS close succeeds without returning a value.
        assert(closed ~= false and closeErr == nil, closeErr)
        assert(fs.rename(path .. '.tmp', path), '无法保存 ' .. name)
    end
    function self.clearRecipes()
        local state = self.read('multi.state') or {}
        local count = 0
        for _, p in pairs(state.patterns or {}) do
            if p.unit or p.steps then
                count = count + 1
            end
        end
        if count > 0 then
            self.write('multi.state', { patterns = {} })
        end
        return count
    end
    return self
end
return S
