local U={}
function U.copy(v)
  if type(v)~="table" then return v end
  local r={}; for k,x in pairs(v) do r[k]=U.copy(x) end; return r
end
function U.equal(a,b)
  if type(a)~=type(b) then return false end
  if type(a)~="table" then return a==b end
  for k,v in pairs(a) do if not U.equal(v,b[k]) then return false end end
  for k in pairs(b) do if a[k]==nil then return false end end
  return true
end
function U.integer(n,lo,hi)
  return type(n)=="number" and n==math.floor(n) and n>=(lo or 0) and n<=(hi or 9007199254740991)
end
function U.add(a,b,m)
  for k,v in pairs(b or {}) do
    a[k]=(a[k] or 0)+v*(m or 1)
    assert(U.integer(a[k]),"数量超出精确整数范围："..k)
  end
  return a
end
function U.total(a) local n=0; for _,v in pairs(a or {}) do assert(U.integer(v),"数量不是精确的非负整数"); n=n+v end; assert(U.integer(n),"总量超出精确整数范围"); return n end
function U.fits(stock,need) for k,v in pairs(need or {}) do if (stock[k] or 0)<v then return false end end; return true end
function U.scale(a,n) return U.add({},a,n) end
function U.keys(t) local r={}; for k in pairs(t) do r[#r+1]=k end; table.sort(r); return r end
function U.index(list,key) local r={}; for _,v in ipairs(list or {}) do r[v[key or "id"]]=v end; return r end
return U
