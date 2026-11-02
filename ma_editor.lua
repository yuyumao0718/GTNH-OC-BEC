-- Stopped-mode forms edit existing records; opening a page never rebuilds route IDs.
local F={}; F.__index=F
local tabs={'预缓存纠缠流体配置','约束场与蜂群配置','观测阵列与传送节点配置','下单 ME 接口配置'}
local sides={'下','上','北','南','西','东'}
local function find(list,key,value) for i,x in ipairs(list or {}) do if x[key]==value then return x,i end end end
local function unique(list,prefix) local n=1; while find(list,'id',prefix..n) do n=n+1 end; return prefix..n end
function F.new(ui,cfg,component,save)
  local self=setmetatable({ui=ui,cfg=cfg,component=component,save=save,tab=1,pos=1,offset=1,selected={},grade=1,
    boxPage=1,fluidIndex=1,fluidPage=1,fluidKey='low',extraBoxes={},expanded={},source=1,message='修改记入草稿；按 S 校验并保存',schema={}},F)
  for _,f in ipairs(ui.C.schema) do self.schema[f.key]=f end
  self.feedDraft=ui.C.newRecord(self.schema.feeds.fields); self.feedDraft.id='供料组-1'
  if #cfg.channels==0 then self:record('channels') end
  self.devices=ui.C.scan(component,cfg); self.fluidRows={}
  if #cfg.beePools==1 then for _,a in ipairs(cfg.arrays) do if a.beePool=='' then a.beePool=cfg.beePools[1].id end end end
  for _,m in ipairs(ui.M) do self.fluidRows[#self.fluidRows+1]=find(cfg.bands,'material',m.source) or
    {material=m.source,low=math.min(1000000,cfg.fieldLimit-1),high=math.min(2000000,cfg.fieldLimit)} end
  return self
end
function F:changed()
  if self.save.draft then self.save.draft(self.cfg) end
  self.message='修改已记入草稿；按 S 校验并保存后生效'
end
function F:record(section)
  local r=self.ui.C.newRecord(self.schema[section].fields)
  if r.id then r.id=unique(self.cfg[section],({feeds='供料组',channels='公共原料子网',beePools='蜂群池'})[section]..'-') end
  self.cfg[section][#self.cfg[section]+1]=r
  if section=='beePools' and #self.cfg.beePools==1 then for _,a in ipairs(self.cfg.arrays) do if a.beePool=='' then a.beePool=r.id end end end
  return r
end
function F:inventory(id) return find(self.cfg.inventories,'id',id) end
function F:route(id) return find(self.cfg.routes,'id',id) end
function F:removeUnusedInventory(id)
  if not id then return end
  for _,r in ipairs(self.cfg.routes) do for _,s in ipairs(r.steps) do if s.from==id or s.to==id then return end end end
  for _,a in ipairs(self.cfg.arrays) do
    if a.loadPort==id or a.unloadPort==id then return end
    for _,b in ipairs(a.beeBoxes) do if b.inventory==id then return end end
  end
  for _,f in ipairs(self.cfg.feeds) do if f.io==id then return end end
  local _,i=find(self.cfg.inventories,'id',id); if i then table.remove(self.cfg.inventories,i) end
end
function F:removeUnusedRoute(id)
  local r,i=find(self.cfg.routes,'id',id); if not r then return end
  for _,a in ipairs(self.cfg.arrays) do
    for _,b in ipairs(a.beeBoxes) do if b.load==id or b.unload==id then return end end
  end
  for _,f in ipairs(self.cfg.feeds) do for _,c in ipairs(f.cells) do if c.route==id then return end end end
  table.remove(self.cfg.routes,i)
  for _,step in ipairs(r.steps) do self:removeUnusedInventory(step.from); self:removeUnusedInventory(step.to) end
end
function F:position(inv,transposer,side)
  -- Update matching access to the same container, while retaining other transposers' faces.
  for _,r in ipairs(self.cfg.routes) do for _,step in ipairs(r.steps) do
    if step.transposer==inv.transposer then
      if step.from==inv.id and step.fromSide==inv.side then step.transposer=transposer; step.fromSide=side end
      if step.to==inv.id and step.toSide==inv.side then step.transposer=transposer; step.toSide=side end
    end
  end end
  inv.transposer,inv.side=transposer,side
end
function F:newInventory(prefix)
  local x={id=unique(self.cfg.inventories,prefix..'-'),transposer='',side=0}
  self.cfg.inventories[#self.cfg.inventories+1]=x; return x
end
function F:newRoute(from,to,prefix)
  local a,b=self:inventory(from),self:inventory(to)
  local r={id=unique(self.cfg.routes,prefix..'-'),steps={{from=from,to=to,
    transposer=b.transposer~='' and b.transposer or a.transposer,fromSide=a.side,toSide=b.side,slot=1}}}
  self.cfg.routes[#self.cfg.routes+1]=r; return r
end
function F:beePort(a,mode,create)
  for _,b in ipairs(a.beeBoxes) do local r=self:route(b[mode]); if r then return self:inventory(r.steps[#r.steps].to) end end
  local x=self:inventory(a[mode..'Port'])
  if not x and create then x=self:newInventory(mode=='load' and '蜂群装载端口' or '蜂群回收端口'); a[mode..'Port']=x.id end
  return x
end
function F:beeBox(a,number,create)
  local b=find(a.beeBoxes,'box',number)
  if not b and create then
    local port=self:beePort(a,'load'); local inv=self:newInventory('蜂群箱')
    if port then inv.transposer=port.transposer end
    b={box=number,inventory=inv.id}; a.beeBoxes[#a.beeBoxes+1]=b
    for _,mode in ipairs({'load','unload'}) do b[mode]=self:newRoute(b.inventory,self:beePort(a,mode,true).id,mode=='load' and '蜂群装载' or '蜂群回收').id end
  end
  return b
end
function F:boxes(pool)
  local seen={}; for _,c in ipairs(pool.cells) do seen[c.box]=true end
  for box in pairs(self.extraBoxes[pool.id] or {}) do seen[box]=true end
  if not next(seen) then seen[1]=true end
  local boxes={}; for box in pairs(seen) do boxes[#boxes+1]=box end; table.sort(boxes); return boxes
end
function F:feedPort(feed,create)
  if create and not find(self.cfg.feeds,'id',feed.id) then self.cfg.feeds[#self.cfg.feeds+1]=feed end
  local inv=self:inventory(feed.io)
  if not inv and create then inv=self:newInventory('预缓存端口'); feed.io=inv.id end
  return inv
end
function F:feeds() return #self.cfg.feeds>0 and self.cfg.feeds or {self.feedDraft} end
function F:at(transposer,side)
  if transposer~='' then for _,inv in ipairs(self.cfg.inventories) do if inv.transposer==transposer and inv.side==side then return inv end end end
end
function F:feedCell(feed,material,enabled)
  local cell,i=find(feed.cells,'material',material)
  if enabled and not cell then
    local port=self:feedPort(feed,true); local side=port.side==0 and 1 or 0
    local inv=self:at(port.transposer,side) or self:newInventory('流体元件')
    inv.transposer=port.transposer; inv.side=side
    cell={material=material,slot=1,route=self:newRoute(inv.id,port.id,'预缓存搬运').id}
    feed.cells[#feed.cells+1]=cell
  elseif not enabled and cell then table.remove(feed.cells,i); self:removeUnusedRoute(cell.route) end
  return cell
end
function F:objects()
  local out={}; local function add(kind,value,label,box) out[#out+1]={kind=kind,value=value,label=label,box=box} end
  if self.tab==1 then
    add('generators',self.cfg.generators,'纠缠装置')
    for i,f in ipairs(self:feeds()) do add('feed',f,'供料：'..(f.name or (#self.cfg.feeds<=1 and '主网流体' or tostring(i)))) end
    add('fluids',self.fluidRows,'流体预缓存')
  elseif self.tab==2 then
    add('field',self.cfg,'约束场')
    for i,p in ipairs(self.cfg.beePools) do
      add('pool',p,'蜂群池：'..(p.name or tostring(i)))
      for _,box in ipairs(self:boxes(p)) do add('box',p,'  箱子：'..box,box) end
    end
  elseif self.tab==3 then for i,a in ipairs(self.cfg.arrays) do add('array',a,'阵列：'..(a.name or tostring(i))) end
  else for i,c in ipairs(self.cfg.channels) do add('channel',c,#self.cfg.channels==1 and '公共原料子网' or '接收子网：'..(c.name or tostring(i))) end end
  return out
end
function F:object()
  local list=self:objects(); self.pos=math.max(1,math.min(self.pos,math.max(1,#list))); return list[self.pos],list
end
function F:openTab(tab) self.tab=tab; self.pos=1; self.offset=1; self.popup=nil; self.selected={}; self.boxPage=1 end
function F:field(label,target,key,kind,source,lo,hi)
  local section=({pool='beePools',array='arrays'})[(self:object() or {}).kind]
  return {label=label,kind=kind or 'text',source=source,lo=lo or 0,hi=hi or 9007199254740991,
    default=key=='name' and section and self.ui:recordName(self.cfg,section,target) or nil,
    get=function() return target[key] end,set=function(v) if key=='name' and v=='' then target[key]=nil else target[key]=v end end}
end
function F:form(fluidIndex)
  local o=self:object(); local rows={}; if not o then return rows end; local x=o.value
  if o.kind=='fluids' then x=self.fluidRows[fluidIndex or self.fluidIndex] end
  local function add(f) f.index=#rows+1; rows[#rows+1]=f; return f end
  local function title(t) add({kind='heading',label=t}) end
  local function field(label,target,key,kind,source,lo,hi) return add(self:field(label,target,key,kind,source,lo,hi)) end
  local function action(label,run) add({kind='action',label=label,run=run}) end
  local function virtual(label,kind,get,set,source,lo,hi)
    return add({label=label,kind=kind,get=get,set=set,source=source,lo=lo or 0,hi=hi or 9007199254740991})
  end
  local function endpoint(label,get)
    virtual(label..'转运器','choice',function() local v=get(); return v and v.transposer or '' end,
      function(v) local inv=get(true); self:position(inv,v,inv.side) end,'device:transposer')
    virtual(label..'方向','side',function() local v=get(); return v and v.side or 0 end,
      function(v) local inv=get(true); self:position(inv,inv.transposer,v) end)
  end
  local function routeRows(get,label)
    local r=get(); local count=r and #r.steps or 1
    for i=1,count do
      if count>1 then title(label..' / 第 '..i..' 步') end
      for _,spec in ipairs({{'转运器','transposer','choice','device:transposer'},
        {'来源方向','fromSide','side'},{'目标方向','toSide','side'}}) do local key=spec[2]
        local name=spec[1]
        virtual(name,spec[3],function() local rr=get(); return rr and rr.steps[i][key] or (key=='transposer' and '' or 0) end,
          function(v)
            local rr=get(true); local step=rr.steps[i]; local inv=self:inventory(step.to)
            local readHere=inv.transposer==step.transposer and inv.side==step.toSide
            step[key]=v
            if (i==#rr.steps or readHere) and (key=='transposer' or key=='toSide') then
              self:position(inv,step.transposer,step.toSide)
            end
          end,spec[4])
      end
      if i<count then field('中转槽位',r.steps[i],'slot','number',nil,1,2147483647).inventory=function() return self:inventory(r.steps[i].to) end end
    end
    action('增加中转步骤',function()
      local rr=get(true); local last=rr.steps[#rr.steps]; local mid=self:newInventory('中转容器')
      mid.transposer,mid.side=last.transposer,last.toSide
      local to=last.to; last.to=mid.id
      rr.steps[#rr.steps+1]={from=mid.id,to=to,transposer=last.transposer,fromSide=last.toSide,toSide=0,slot=1}
    end)
    if count>1 then action('移除最后中转步骤',function()
      local rr=get(); local last=table.remove(rr.steps); local prev=rr.steps[#rr.steps]; local mid=prev.to
      local target=self:inventory(last.to)
      prev.to=last.to; prev.toSide=target.transposer==prev.transposer and target.side or last.toSide
      self:removeUnusedInventory(mid)
    end) end
  end
  if o.kind=='field' then
    field('约束场设备',x,'storage','choice','device:bec_storage'); field('约束场强度 L',x,'fieldLimit','number',nil,1)
  elseif o.kind=='fluids' then
    title(self.ui.M.name(x.material))
    virtual('启用预缓存','boolean',function() return find(self.cfg.bands,'material',x.material)~=nil end,function(v)
      local _,i=find(self.cfg.bands,'material',x.material); if v and not i then self.cfg.bands[#self.cfg.bands+1]=x elseif not v and i then table.remove(self.cfg.bands,i) end
    end)
    for _,spec in ipairs({{'库存下限 L','low',0},{'补充目标 L','high',1}}) do
      field(spec[1],x,spec[2],'number',nil,spec[3])
      add({kind='presets',label=spec[1]..'快捷值',set=function(v) x[spec[2]]=v end})
    end
    for _,feed in ipairs(self:feeds()) do
      title(#self.cfg.feeds<=1 and '主网供料位置' or '供料：'..self.ui:recordName(self.cfg,'feeds',feed))
      virtual('从主网供料','boolean',function() return find(feed.cells,'material',x.material)~=nil end,
        function(v) self:feedCell(feed,x.material,v) end)
      local cell=find(feed.cells,'material',x.material)
      if cell then
        local r=self:route(cell.route)
        virtual('驱动器方向','side',function() return r.steps[1].fromSide end,function(v)
          local step=r.steps[1]; local old=step.from
          local inv=self:at(step.transposer,v) or self:newInventory('流体元件')
          inv.transposer,inv.side=step.transposer,v; step.from,step.fromSide=inv.id,v
          self:removeUnusedInventory(old)
        end)
        field('元件槽位',cell,'slot','number',nil,1,10).inventory=function() return self:inventory(r.steps[1].from) end
      end
    end
  elseif o.kind=='generators' then
    local available={}
    for _,d in ipairs(self.devices) do if self.ui.C.matches(d,'generator') then available[#available+1]={address=d.address} end end
    for _,g in ipairs(self.cfg.generators) do if not find(available,'address',g.address) then available[#available+1]={address=g.address,offline=true} end end
    for _,d in ipairs(available) do local address=d.address
      virtual('启用 '..address:sub(1,12)..(d.offline and '（离线）' or ''),'boolean',function() return find(self.cfg.generators,'address',address)~=nil end,function(v)
        local _,i=find(self.cfg.generators,'address',address)
        if v and not i then local feed=self:feeds()[1]; self:feedPort(feed,true)
          self.cfg.generators[#self.cfg.generators+1]={address=address,feed=feed.id}
        elseif not v and i then table.remove(self.cfg.generators,i) end
      end)
    end
    if #self.cfg.feeds>1 then for _,g in ipairs(self.cfg.generators) do field(g.address:sub(1,12)..' 使用供料组',g,'feed','choice','feeds') end end
  elseif o.kind=='pool' then
    field('蜂群池名称',x,'name','text')
    action('新增箱子',function() local boxes=self:boxes(x); local box=boxes[#boxes]+1; self.extraBoxes[x.id]=self.extraBoxes[x.id] or {}; self.extraBoxes[x.id][box]=true end)
    title('选择左侧箱子，批量登记槽位和等级')
  elseif o.kind=='array' then
    title('阵列与设备绑定')
    field('阵列名称',x,'name','text'); field('启用阵列',x,'enabled','boolean')
    action('关联的传送节点：'..#x.nodes..' 个',function() self:nodePicker(x) end)
    action('绑定未分配节点',function() self:bindNodes(x) end)
    action('麦克斯韦门：'..(x.diode~='' and x.diode:sub(1,12) or '未绑定'),function() self:doorPicker(x) end)
    title('全局加工设置（所有阵列共用）')
    field('算力奇点等待阈值（秒）',self.cfg,'singularityWait','number',nil,1,2147483647)
    title('蜂群装载配置'); field('使用的蜂群池',x,'beePool','choice','beePools')
    local pool=find(self.cfg.beePools,'id',x.beePool)
    if pool then
      local function common(mode,key) return function() local p=self:beePort(x,mode); return p and p[key] or (key=='side' and 0 or '') end end
      virtual('蜂群转运器','choice',common('load','transposer'),function(v)
        for _,mode in ipairs({'load','unload'}) do self:beePort(x,mode,true).transposer=v end
        for _,box in ipairs(self:boxes(pool)) do local b=self:beeBox(x,box,true); self:inventory(b.inventory).transposer=v
          for _,mode in ipairs({'load','unload'}) do local r=self:route(b[mode]); if #r.steps==1 then r.steps[1].transposer=v end end
        end
      end,'device:transposer')
      for _,spec in ipairs({{'load','装载'},{'unload','回收'}}) do local mode=spec[1]
        virtual(spec[2]..' ME-IO 端口方向','side',common(mode,'side'),function(v)
          self:beePort(x,mode,true).side=v
          for _,box in ipairs(self:boxes(pool)) do local b=self:beeBox(x,box,true); local r=self:route(b[mode]); r.steps[#r.steps].toSide=v end
        end)
      end
      local boxes=self:boxes(pool); local configured={}; for _,box in ipairs(boxes) do configured[box]=true end
      for _,b in ipairs(x.beeBoxes) do if not configured[b.box] then boxes[#boxes+1]=b.box end end
      for _,box in ipairs(boxes) do
        if not configured[box] then action('移除未登记的箱子 '..box..' 连接',function()
          local b,i=find(x.beeBoxes,'box',box); table.remove(x.beeBoxes,i)
          self:removeUnusedRoute(b.load); self:removeUnusedRoute(b.unload); self:removeUnusedInventory(b.inventory)
        end) end
        virtual('箱子 '..box..' 的方向','side',function() local b=self:beeBox(x,box); local inv=b and self:inventory(b.inventory); return inv and inv.side or 0 end,function(v)
          local b=self:beeBox(x,box,true); self:inventory(b.inventory).side=v
          for _,mode in ipairs({'load','unload'}) do self:route(b[mode]).steps[1].fromSide=v end
        end)
        local key=x.address..':box:'..box
        action((self.expanded[key] and '收起' or '展开')..'箱子 '..box..' 多转运器设置',function() self.expanded[key]=not self.expanded[key] end)
        if self.expanded[key] then
          endpoint('箱子 '..box..' 读取',function(create) local b=self:beeBox(x,box,create); return b and self:inventory(b.inventory) end)
          for _,mode in ipairs({'load','unload'}) do title(mode=='load' and '装载搬运' or '回收搬运')
            routeRows(function(create) local b=self:beeBox(x,box,create); return b and self:route(b[mode]) end,'蜂群搬运')
          end
        end
      end
    end
  elseif o.kind=='channel' then
    title('主网下单接口'); action('主网样板 ME 接口：'..#x.patterns..' 个',function() self:patternPicker(x) end)
    for _,p in ipairs(x.patterns) do field(p.address:sub(1,12)..' 样板槽数',p,'slots','number',nil,1,128) end
    title('公共原料子网与共用锁单')
    field('公共原料子网 ME 控制器',x,'buffer','choice','device:buffer'); field('共用接单红石 I/O',x,'redstone','choice','device:redstone')
    field('红石输出方向',x,'gateSide','side')
  elseif o.kind=='feed' then
    title('共用供料设备')
    virtual('流体转运器','choice',function() local p=self:feedPort(x); return p and p.transposer or '' end,function(v)
      local p=self:feedPort(x,true); self:position(p,v,p.side)
      for _,cell in ipairs(x.cells) do local r=self:route(cell.route)
        if #r.steps==1 then local step=r.steps[1]; step.transposer=v
          local inv=self:inventory(step.from); inv.transposer=v
        end
      end
    end,'device:transposer')
    virtual('主网补库 ME-IO 端口方向','side',function() local p=self:feedPort(x); return p and p.side or 0 end,
      function(v) local p=self:feedPort(x,true); self:position(p,p.transposer,v) end)
    title('各流体的驱动器方向与槽位在流体页填写')
    for _,cell in ipairs(x.cells) do local r=self:route(cell.route)
      if #r.steps>1 then title('已有中转：'..self.ui.M.name(cell.material,true)); routeRows(function() return r end,'已有供料搬运') end
    end
  end
  return rows
end
function F:choices(f)
  local rows=f.options or self.ui:choices(f,self.cfg,self.devices)
  if f.source=='device:buffer' then
    local controllers={}; for _,row in ipairs(rows) do if self.component.type(row.value)=='me_controller' then controllers[#controllers+1]=row end end
    rows=controllers
  end; return rows
end
function F:nodePicker(a)
  local allowed={}; for _,d in ipairs(self.ui.C.unboundNodes(self.cfg,self.devices)) do allowed[d.address]=true end
  local checked={}; for _,n in ipairs(a.nodes) do checked[n.address]=true; allowed[n.address]=true end
  local options,visible={},{}; for _,d in ipairs(self.devices) do if allowed[d.address] then
    options[#options+1]={value=d.address,label=d.address}; visible[d.address]=true
  end end
  for _,n in ipairs(a.nodes) do if not visible[n.address] then options[#options+1]={value=n.address,label=n.address..'（离线）'} end end
  self.popup={title='关联的传送节点',options=options,checked=checked,page=1,all=true,reopen=function() self:nodePicker(a) end,apply=function(values)
    assert(#values<=16,'每台阵列最多关联 16 个传送节点')
    local want={}; for _,v in ipairs(values) do want[v]=true end
    local result={}; for _,n in ipairs(a.nodes) do if want[n.address] then result[#result+1]=n; want[n.address]=nil end end
    for _,v in ipairs(values) do if want[v] then result[#result+1]={address=v} end end; a.nodes=result
  end}
end
function F:bindNodes(a)
  self.devices=self.ui.C.scan(self.component,self.cfg); local ok,message=self.ui.C.bindNodes(self.cfg,a,self.devices)
  if not ok then self:nodePicker(a) end; self.message=message
end
function F:doorPicker(a)
  self.devices=self.ui.C.scan(self.component,self.cfg)
  local options={}; for _,d in ipairs(self.ui.C.unboundDoors(self.cfg,self.devices)) do options[#options+1]={value=d.address,label=d.address} end
  if #options==1 then a.diode=options[1].value; return end
  self.popup={title='未分配的麦克斯韦门',options=options,page=1,reopen=function() self:doorPicker(a) end,choose=function(v) a.diode=v end}
end
function F:patternPicker(c)
  local used={}; for _,other in ipairs(self.cfg.channels) do if other~=c then for _,p in ipairs(other.patterns) do used[p.address]=true end end end
  local options={}; for _,d in ipairs(self.devices) do if self.ui.C.matches(d,'pattern') and not used[d.address] then options[#options+1]={value=d.address,label=d.address} end end
  local checked={}; for _,p in ipairs(c.patterns) do checked[p.address]=true
    if not find(options,'value',p.address) then options[#options+1]={value=p.address,label=p.address..'（离线）'} end
  end
  self.popup={title='主网样板 ME 接口',options=options,checked=checked,page=1,reopen=function() self:patternPicker(c) end,apply=function(values)
    local want={}; for _,v in ipairs(values) do want[v]=true end
    local result={}; for _,p in ipairs(c.patterns) do if want[p.address] then result[#result+1]=p; want[p.address]=nil end end
    for _,v in ipairs(values) do if want[v] then result[#result+1]={address=v,slots=36} end end; c.patterns=result
  end}
end
local fluidLabels={enabled='启用预缓存',low='库存下限 L',high='补充目标 L',supply='从主网供料',side='驱动器方向',slot='元件槽位'}
function F:fluidField(index,key,rows)
  for _,f in ipairs(rows or self:form(index)) do if f.label==fluidLabels[key] then f.fluid=index; f.key=key; return f end end
end
function F:begin(f) self.edit={field=f,text=f.kind=='number' and self.ui.exact(f.get()) or tostring(f.get() or ''),replace=true} end
function F:commit()
  local e=self.edit; if not e then return true end; local v=e.text; local f=e.field
  if f.kind=='number' then v=tonumber(v); if not self.save.U.integer(v,f.lo,f.hi) then self.message='请输入 '..f.lo..' 至 '..f.hi..' 的整数'; return false end end
  f.set(v); self.edit=nil; self:changed(); return true
end
function F:activate(f,button)
  if button~=nil and (f.kind=='side' or f.inventory) then
    local lo,hi=0,5
    if f.inventory then
      local inv=f.inventory()
      if not inv or inv.transposer=='' then self.message='请先选择转运器和容器方向'; return end
      local ok,size=pcall(function() return self.component.proxy(inv.transposer).getInventorySize(inv.side) end)
      if not ok or not size or size<1 then self.message='所选方向未读取到容器，请检查转运器和方向'; return end
      lo,hi=1,size
    end
    f.set(lo+((f.get() or lo)-lo+(button==1 and -1 or 1))%(hi-lo+1)); self:changed()
  elseif f.kind=='action' then f.run(); self:changed()
  elseif f.kind=='boolean' then f.set(not f.get()); self:changed()
  elseif f.kind=='choice' or f.kind=='side' then
    local options=f.kind=='side' and {} or self:choices(f)
    if f.kind=='side' then for i=0,5 do options[#options+1]={value=i,label=i..' '..sides[i+1]} end end
    self.popup={title=f.label,options=options,page=1,current=f.get(),reopen=function() self:activate(f) end,choose=function(v) f.set(v) end}
  elseif f.kind~='heading' and f.kind~='presets' then self:begin(f) end
end
function F:act(action,button)
  if not action then return end
  if action=='quit' then self.edit=nil; self.done=true; return end
  if action=='back' then if self.edit then self.edit=nil elseif self.popup then self.popup=nil else self.done=true end; return end
  if action=='cancel-edit' then self.edit=nil; return end
  if action:match('^fluid%-preset:') then
    local f=self:fluidField(self.fluidIndex,self.fluidKey)
    if f and (self.fluidKey=='low' or self.fluidKey=='high') then
      f.set(tonumber(action:match(':(.+)$'))); self.edit=nil; self:changed()
    end
    return
  end
  if not self:commit() then return end; local o=self:object()
  if action:match('^tab:') then self:openTab(tonumber(action:sub(5)))
  elseif action:match('^select:') then self.pos=tonumber(action:sub(8)); self.offset=1; self.selected={}; self.boxPage=1; self.popup=nil
  elseif action:match('^field:') then self:activate(self:form()[tonumber(action:sub(7))],button)
  elseif action:match('^fluid:') then
    local index,key=action:match('^fluid:(%d+):(%w+)$'); self.fluidIndex,self.fluidKey=tonumber(index),key
    if key~='name' then local f=self:fluidField(self.fluidIndex,key)
      if f then self:activate(f,button) else self.message='请先启用该流体的主网供料，再填写驱动器方向和槽位' end
    end
  elseif action:match('^preset:') then
    local index,value=action:match('^preset:(%d+):(.+)$'); self:form()[tonumber(index)].set(tonumber(value)); self:changed()
  elseif action=='save' then local ok,err=pcall(function() self.ui.C.validate(self.cfg,self.component,self.save.U); self.save.write(self.cfg) end)
    if ok then self.saved=true; self.done=true else self.message=tostring(err):gsub('^.-:%d+: ','') end
  elseif action=='refresh' then
    self.devices=self.ui.C.scan(self.component,self.cfg)
    local popup=self.popup
    if popup and popup.reopen then
      self.popup=nil; popup.reopen()
      if self.popup and self.popup.checked and popup.checked then
        for address,checked in pairs(popup.checked) do self.popup.checked[address]=checked end
      end
      self:changed()
    end
    self.message='设备列表已刷新；已有绑定保持不变'
  elseif action=='add' then
    if self.tab==2 then self:record('beePools'); self:changed() end
  elseif action=='delete' and o then
    local section=o.kind=='pool' and 'beePools'
    if section then
      for i,v in ipairs(self.cfg[section]) do if v==o.value then table.remove(self.cfg[section],i); break end end
      self:changed()
    end
  elseif action=='bind-nodes' and o and o.kind=='array' then self:bindNodes(o.value); self:changed()
  elseif action=='bind-door' and o and o.kind=='array' then self:doorPicker(o.value); self:changed()
  elseif action=='up' or action=='down' then
    if self.popup then self:act(action=='up' and 'prev' or 'next')
    else self.pos=math.max(1,self.pos+(action=='up' and -1 or 1)); self.offset=1; self.selected={} end
  elseif action=='prev' or action=='next' then
    if self.popup then self.popup.page=math.max(1,math.min(self.optionPages or 1,self.popup.page+(action=='prev' and -1 or 1)))
    elseif o and o.kind=='fluids' then self.fluidPage=math.max(1,math.min(self.fluidPages or 1,self.fluidPage+(action=='prev' and -1 or 1)))
    elseif o and o.kind=='box' then self.boxPage=math.max(1,self.boxPage+(action=='prev' and -1 or 1)); self.selected={}
    else self.offset=math.max(1,math.min(math.max(1,#self:form()),self.offset+(action=='prev' and -1 or 1)*(self.perPage or 7))) end
  elseif action:match('^pick:') and self.popup then local p=self.popup; local option=p.options[tonumber(action:sub(6))]
    if p.checked then p.checked[option.value]=not p.checked[option.value] else p.choose(option.value); self.popup=nil; self:changed() end
  elseif action=='all' and self.popup then for _,v in ipairs(self.popup.options) do self.popup.checked[v.value]=true end
  elseif action=='apply' and self.popup then
    local p=self.popup; local values={}; for _,v in ipairs(p.options) do if p.checked[v.value] then values[#values+1]=v.value end end
    local ok,err=pcall(p.apply,values); if ok then self.popup=nil; self:changed() else self.message=tostring(err):gsub('^.-:%d+: ','') end
  elseif action:match('^slot:') then local n=tonumber(action:sub(6)); self.selected[n]=not self.selected[n]
  elseif action=='grade-' or action=='grade+' then self.grade=math.max(1,math.min(10,self.grade+(action=='grade-' and -1 or 1)))
  elseif (action=='register' or action=='unregister') and o and o.kind=='box' then
    for slot,selected in pairs(self.selected) do if selected then local cell,index
      for i,c in ipairs(o.value.cells) do if c.box==o.box and c.slot==slot then cell,index=c,i; break end end
      if action=='unregister' then if index then table.remove(o.value.cells,index) end
      elseif cell then cell.tier=self.grade else o.value.cells[#o.value.cells+1]={box=o.box,slot=slot,tier=self.grade} end
    end end; self.selected={}; self:changed()
  elseif action=='open' then local f=self:form()[self.offset]; if f then self:activate(f) end end
end
function F:event(name,_,ch,code,direction)
  if name=='interrupted' then self:act('quit'); return end
  if name=='touch' then self:act(self.ui:hit(ch,code),direction or 0); return end
  if self.edit then local e=self.edit
    if name=='clipboard' then e.text=tostring(ch):gsub('[\r\n]',''); e.replace=false
    elseif name=='key_down' then
      if code==1 then self.edit=nil elseif code==28 then self:commit()
      elseif code==14 then e.text=self.ui.u.sub(e.text,1,math.max(0,self.ui.u.len(e.text)-1)); e.replace=false
      elseif ch==21 then e.text=''; e.replace=false
      elseif ch and ch>=32 then e.text=(e.replace and '' or e.text)..self.ui.u.char(ch); e.replace=false end
    end; return
  end
  if name=='scroll' then
    local objects=not self.popup and ch<=(self.left or 20)
    self:act(direction>0 and (objects and 'up' or 'prev') or (objects and 'down' or 'next'))
  elseif name=='key_down' then
    if ch==115 or ch==83 then self:act('save') elseif ch==113 or ch==81 then self:act('quit')
    elseif ch==102 or ch==70 then self:act('refresh') elseif ch==97 or ch==65 then self:act('add')
    elseif ch==100 or ch==68 then self:act('delete') elseif ch and ch>=49 and ch<=52 then self:act('tab:'..(ch-48))
    elseif code==1 then self:act('back') elseif code==28 then self:act('open') elseif code==200 then self:act('up') elseif code==208 then self:act('down')
    elseif code==201 or ch==91 then self:act('prev') elseif code==209 or ch==93 then self:act('next') end
  end
end
function F:value(f)
  local v=f.get(); if f.kind=='boolean' then return v and '是' or '否' end
  if f.kind=='side' then return tostring(v)..' '..(sides[(v or 0)+1] or '') end
  if f.options then for _,o in ipairs(f.options) do if o.value==v then return o.label end end end
  if f.kind=='choice' and f.source and not f.source:match('^device:') then return self.ui:recordName(self.cfg,f.source,v) end
  if v==nil or v=='' then return f.default or '未选择' end
  return type(v)=='number' and self.ui.exact(v) or tostring(v)
end
function F:drawBox(o,x,width)
  local ui=self.ui; local cells={}; for _,c in ipairs(o.value.cells) do if c.box==o.box then cells[c.slot]=c.tier end end
  ui:put(x,6,'箱子 '..o.box..' / 按槽位登记蜂群',width,ui.ink.green)
  local cw=math.floor(width/9); local first=(self.boxPage-1)*27+1
  for i=0,26 do local slot=first+i; local xx=x+(i%9)*cw; local yy=8+math.floor(i/9)*3
    ui:control('slot:'..slot,xx,yy,tostring(slot),self.selected[slot],cw)
    if not self.selected[slot] then ui:put(xx,yy,tostring(slot),cw,cells[slot] and ui.ink.green or ui.ink.dim,ui.ink.panel) end
    ui:put(xx+1,yy+1,cells[slot] and 'T'..cells[slot] or '--',cw-1,cells[slot] and ui.ink.green or ui.ink.dim)
  end
  local gradeY,registerY=math.min(17,ui.h-9),math.min(19,ui.h-8)
  ui:control('grade-',x,gradeY,'-'); ui:put(x+5,gradeY,'T'..self.grade,5,ui.ink.cyan); ui:control('grade+',x+11,gradeY,'+')
  ui:control('register',x,registerY,'登记所选'); ui:control('unregister',x+14,registerY,'取消登记')
  local counts={}; for _,tier in pairs(cells) do counts[tier]=(counts[tier] or 0)+1 end
  local summary={}; for tier=1,10 do if counts[tier] then summary[#summary+1]='T'..tier..'×'..counts[tier] end end
  ui:put(x,7,'青底：已选  绿色：已登记  --：未登记',width,ui.ink.dim)
  ui:put(x,ui.h-4,table.concat(summary,' '),width,ui.ink.dim)
end
function F:drawFluids(x,width,b)
  local ui,ink=self.ui,self.ui.ink
  local numberWidth=width>=80 and 10 or 7
  local widths={width-6-numberWidth*2-6-6-6-4,6,numberWidth,numberWidth,6,6,4}
  local keys={'name','enabled','low','high','supply','side','slot'}
  local labels={'流体','预缓存','下限 L','目标 L','供料','方向','槽位'}
  local positions={}; local px=x
  for i,key in ipairs(keys) do positions[key]=px; ui:put(px,b.top,labels[i],widths[i],ink.dim); px=px+widths[i]+1 end
  local editTop=b.bottom-5; local per=math.max(1,editTop-b.top-1)
  self.fluidPages=math.max(1,math.ceil(#self.fluidRows/per)); self.fluidPage=math.min(self.fluidPage,self.fluidPages)
  local first=(self.fluidPage-1)*per+1
  local function short(n)
    for _,unit in ipairs({{1e9,'G'},{1e6,'M'},{1e3,'K'}}) do
      if n>=unit[1] then return string.format('%.3g%s',n/unit[1],unit[2]) end
    end
    return ui.exact(n)
  end
  for index=first,math.min(#self.fluidRows,first+per-1) do
    local row=self.fluidRows[index]; local y=b.top+1+index-first; local fields=self:form(index)
    for col,key in ipairs(keys) do
      local f=key~='name' and self:fluidField(index,key,fields)
      local value=key=='name' and ui.M.name(row.material,true) or '--'
      if f then local v=f.get()
        value=(key=='low' or key=='high') and short(v) or key=='side' and sides[v+1] or self:value(f)
      end
      if key=='name' or f then
        ui:control('fluid:'..index..':'..key,positions[key],y,value,index==self.fluidIndex and key==self.fluidKey,widths[col])
      else ui:put(positions[key],y,value,widths[col],ink.dim) end
    end
  end
  ui:put(x,editTop,string.rep('─',width),width,ink.dim)
  local row=self.fluidRows[self.fluidIndex]; local f=self:fluidField(self.fluidIndex,self.fluidKey)
  ui:put(x,editTop+1,ui.M.name(row.material),width,ink.green)
  if f then
    local editing=self.edit and self.edit.field.fluid==self.fluidIndex and self.edit.field.key==self.fluidKey
    local labelWidth=math.min(22,math.floor(width/2))
    ui:put(x,editTop+2,f.label,labelWidth,ink.text)
    ui:control('fluid:'..self.fluidIndex..':'..self.fluidKey,x+labelWidth,editTop+2,
      editing and self.edit.text..'_' or self:value(f),editing,width-labelWidth)
    if self.fluidKey=='low' or self.fluidKey=='high' then
      for i,preset in ipairs({{'1M',1e6},{'10M',1e7},{'100M',1e8},{'1G',1e9},{'10G',1e10}}) do
        ui:control('fluid-preset:'..ui.exact(preset[2]),x+(i-1)*8,editTop+3,preset[1],false,7)
      end
    end
    if editing then
      ui:control('confirm-edit',x,editTop+4,'确认'); ui:control('cancel-edit',x+10,editTop+4,'取消')
      ui:put(x+20,editTop+4,'Enter 确认 / Esc 取消',width-20,ink.dim)
    end
  else ui:put(x,editTop+2,'点击表格中的值修改配置',width,ink.dim) end
  ui:put(x,b.status,'方向/槽位：左键下一项，右键上一项；首尾循环',width,ink.dim)
end
function F:draw()
  local ui=self.ui; local ink=ui.ink; ui:begin('BEC / 多观测阵列配置')
  local w,h=ui.w,ui.h; local left=w>=120 and 30 or 20; local x=left+3; local width=w-x-1
  self.left=left
  local b={top=6,bottom=h-7,status=h-6,nav=h-5}; self.bounds=b
  local tabWidth=0; for i,t in ipairs(tabs) do tabWidth=tabWidth+ui.u.wlen(i..' '..t)+3 end
  local tx=2
  for i,t in ipairs(tabs) do
    if tabWidth<=w-2 then local tw=ui.u.wlen(i..' '..t)+2; ui:control('tab:'..i,tx,3,i..' '..t,self.tab==i,tw); tx=tx+tw+1
    else ui:control('tab:'..i,2+((i-1)%2)*math.floor(w/2),3+math.floor((i-1)/2),i..' '..t,self.tab==i,math.floor(w/2)-2) end
  end
  ui:frame(1,5,left+1,h-7); ui:frame(x-1,5,width+2,h-7)
  local o,list=self:object(); local menu={}; local selectedLine=1
  for i,v in ipairs(list) do
    if i>1 and (v.kind=='fluids' or v.kind=='pool') then menu[#menu+1]=false end
    menu[#menu+1]=i; if i==self.pos then selectedLine=#menu end
    if v.kind=='array' then menu[#menu+1]={nodes=#v.value.nodes} end
  end
  local leftPer=self.tab==3 and math.floor((h-13)/2)*2 or h-13
  local first=math.floor((selectedLine-1)/leftPer)*leftPer+1
  for line=first,math.min(#menu,first+leftPer-1) do local i=menu[line]
    if type(i)=='table' then ui:put(3,b.top+line-first,'关联节点 '..i.nodes..' / 16',left-2,ink.dim)
    elseif i then ui:control('select:'..i,2,b.top+line-first,list[i].label,i==self.pos,left-1) end
  end
  ui:put(2,h-6,'对象 '..self.pos..'/'..#list,left,ink.dim)
  ui:control('up',2,h-5,'上一个'); ui:control('down',12,h-5,'下一个',false,left-10)
  if self.tab==2 then ui:control('add',2,h-4,'新增蜂群池',false,left) end
  if o and o.kind=='pool' then ui:control('delete',2,h-3,'删除所选') end
  local stride=w>=120 and 1 or 2
  self.perPage=math.max(1,math.floor((h-13)/stride))
  if self.popup then
    local p=self.popup; self.options=p.options; local step=p.options[1] and p.options[1].detail and 2 or 1
    local per=math.floor((h-15)/step); self.optionPages=math.max(1,math.ceil(#p.options/per)); p.page=math.min(p.page,self.optionPages)
    ui:put(x,6,p.title,width,ink.green); local start=(p.page-1)*per+1
    for i=start,math.min(#p.options,start+per-1) do local v=p.options[i]
      local y=8+(i-start)*step
      ui:control('pick:'..i,x,y,(p.checked and (p.checked[v.value] and '[x] ' or '[ ] ') or '')..v.label,p.current==v.value,width)
      if step==2 then ui:put(x,y+1,v.detail or '',width,ink.dim) end
    end
    if #p.options==0 then ui:put(x,8,'没有可选设备；按 F 刷新',width,ink.amber) end
    if p.apply then ui:control('apply',x,b.status,'确认选择') end
    if p.all then ui:control('all',x+14,b.status,'全选未分配') end
    ui:control('back',x+34,b.status,'返回')
  elseif o and o.kind=='box' then self:drawBox(o,x,width)
  elseif o and o.kind=='fluids' then self:drawFluids(x,width,b)
  else
    local rows=self:form(); self.offset=math.max(1,math.min(self.offset,math.max(1,#rows)))
    for i=self.offset,math.min(#rows,self.offset+self.perPage-1) do local f=rows[i]; local y=6+(i-self.offset)*stride
      if f.kind=='heading' then
        local label=ui:clip(' '..f.label..' ',width-2)
        ui:put(x-1,y,'├─'..label..string.rep('─',width-ui.u.wlen(label)-1)..'┤',width+2,ink.green)
      elseif f.kind=='presets' then
        local px=x
        for _,preset in ipairs({{'1M',1e6},{'10M',1e7},{'100M',1e8},{'1G',1e9},{'10G',1e10}}) do
          ui:control('preset:'..i..':'..preset[2],px,y,preset[1],false,7); px=px+8
        end
      elseif f.kind=='action' then ui:control('field:'..i,x,y,f.label,false,width)
      else
        local labelWidth=stride==1 and math.floor(width/2) or width
        ui:put(x,y,f.label,labelWidth,ink.text); local editing=self.edit and self.edit.field.index==i
        ui:control('field:'..i,stride==1 and x+labelWidth or x,stride==1 and y or y+1,
          editing and self.edit.text..'_' or self:value(f),editing,stride==1 and width-labelWidth or width)
      end
    end
    if #rows==0 then ui:put(x,6,'请先添加配置，或按 F 刷新设备',width,ink.dim) end
    ui:put(x,b.status,'方向/槽位：左键下一项，右键上一项；首尾循环',width,ink.dim)
  end
  ui:control('prev',x,b.nav,'上一页'); ui:control('next',x+12,b.nav,'下一页'); ui:control('refresh',x+24,b.nav,'F 刷新')
  ui:wrap(2,h-2,self.message,w-3,2,ink.amber)
  ui:control('save',2,h,'S 保存并返回'); ui:control('quit',22,h,'Q 返回 / 保留草稿'); ui:put(47,h,'↑↓对象 []翻页',w-48,ink.dim); ui:paint()
end
function F:run() while not self.done do self:draw(); self:event(self.ui.event.pull()) end; return not not self.saved end
return F
