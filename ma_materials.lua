-- IDs: GT 5.09.54.133. Chinese names: GTNH-Translations 816761d, fluid.entangled_*.
local r,byName={},{}
local function add(source,id,unit,label,short)
  local m={source=source,condensate="entangled_"..id,unit=unit,label=label,short=short}
  m.condensateLabel="纠缠玻色-爱因斯坦凝聚态"..short
  r[#r+1]=m; byName[source]=m; byName[m.condensate]=m
end
add("molten.neutronium","neutronium",144,"熔融中子","中子")
add("molten.cosmicneutronium","cosmicneutronium",144,"熔融宇宙中子态素","宇宙中子态素")
add("molten.bedrockium","bedrockium",144,"熔融基岩","基岩")
add("molten.chromaticglass","chromaticglass",144,"熔融彩色玻璃","彩色玻璃")
add("molten.celestialtungsten","celestialtungsten",144,"熔融天体钨","天体钨")
add("molten.infinity","infinity",144,"熔融无尽","无尽")
add("molten.hypogen","hypogen",144,"熔融海珀珍","海珀珍")
add("molten.transcendentmetal","transcendentmetal",144,"熔融超时空金属","超时空金属")
add("dimensionallyshiftedsuperfluid","dimshiftedsuperfluid",1000,"维度偏移超流体","维度偏移超流体")
add("phononmedium","phononmedium",1000,"无损声子传输介质","无损声子传输介质")
add("quarkgluonplasma","quarkgluonplasma",1000,"简并夸克胶子等离子体","简并夸克胶子等离子体")
add("molten.spacetime","spacetime",144,"熔融时空","时空")
add("temporalfluid","time",144,"富快子时间流体","富快子时间流体")
add("spatialfluid","space",144,"扩大化空间流体","扩大化空间流体")
add("boundlesscosmicsolder","cosmicsolder",1000,"无界寰宇焊料","寰宇焊料")
add("molten.magnetohydrodynamicallyconstrainedstarmatter","mhdcsm",144,"熔融磁流体约束恒星物质","磁流体约束恒星物质")
add("molten.magmatter","magmatter",144,"熔融磁物质","磁物质")
add("molten.universium","universium",144,"熔融宇宙素","宇宙素")
add("molten.eternity","eternity",144,"熔融永恒","永恒")
function r.name(id,short)
  local m=byName[id]
  return m and (short and m.short or id==m.source and m.label or m.condensateLabel) or id
end
function r.text(s) return tostring(s):gsub("[%w_%.]+",function(id) return r.name(id) end) end
return r
