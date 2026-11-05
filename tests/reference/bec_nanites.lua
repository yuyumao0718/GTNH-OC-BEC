-- Follow the lowest progress inside the reference window.
local L={}
local function integer(n) return type(n)=="number" and n>=0 and n<=9007199254740991 and n==math.floor(n) end
function L.steps(raw)
  local result={}
  for _,s in pairs(raw or {}) do
    assert(s.nanite and integer(s.nanite.tier) and s.nanite.tier>=1 and s.nanite.tier<=10
      and integer(s.start) and integer(s["end"]) and s["end"]>s.start, "节点返回的配方步骤无效")
    result[#result+1]={tier=s.nanite.tier,start=s.start,finish=s["end"]}
  end
  table.sort(result,function(a,b) return a.start<b.start end)
  for i,s in ipairs(result) do
    assert(s.start==(i==1 and 0 or result[i-1].finish), "节点配方步骤不连续")
  end
  assert(#result>0, "没有读取到配方步骤")
  return result
end
-- Missing tiers are transient while a node initializes its first tick.
function L.choose(workers,previous,length)
  local threshold=previous and previous-0.3*length or -math.huge
  local lowest,eligible
  for _,w in ipairs(workers) do
    if w.tier then
      if not lowest or w.progress<lowest.progress then lowest=w end
      if w.progress>=threshold and (not eligible or w.progress<eligible.progress) then eligible=w end
    end
  end
  return eligible or lowest
end
function L.tier(required,cells)
  local selected
  for tier in pairs(cells) do
    if tier>=required and (not selected or tier<selected) then selected=tier end
  end
  return assert(selected,"未配置能够满足 T"..required.." 的蜂群")
end
function L.requested(steps,progress)
  for _,s in ipairs(steps) do if progress>=s.start and progress<s.finish then return s.tier end end
end
function L.fastTier(steps,cells,counts,parallel)
  local low,high=10,1
  for _,s in ipairs(steps) do low=math.min(low,s.tier); high=math.max(high,s.tier) end
  local tier=L.tier(high,cells)
  if steps[#steps].finish*2^(tier-low)*(parallel or 1)<=(counts[tier] or 0) then return tier end
end
return L
