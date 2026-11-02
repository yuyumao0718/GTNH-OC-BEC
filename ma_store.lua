-- A rename commits a complete serialized snapshot on the same OpenOS filesystem.
local S={}
function S.new(base,fs,serialization)
  local self={}
  function self.read(name)
    local f=io.open(base..name,'r'); if not f then return nil end
    local data=f:read('*a'); f:close()
    return assert(serialization.unserialize(data),'无法读取 '..name)
  end
  function self.write(name,value)
    local path=base..name; local f=assert(io.open(path..'.tmp','w'))
    assert(f:write(serialization.serialize(value))); assert(f:flush()); f:close()
    assert(fs.rename(path..'.tmp',path),'无法保存 '..name)
  end
  return self
end
return S
