-- Each array advances one small step per tick; all durable state contains plain tables.
local E={}; E.__index=E
local function cellKey(c) return c.box..':'..c.slot end
local phases={load='元件投料',admit='节点取料',wait='准备加工',run='加工中',['return']='回收蜂群'}
local nodeErrors={['internal-error']='节点内部错误',unpowered='节点供电不足',
  ['assembler-offline']='观测阵列未运行',['paused-immediate']='节点已被立即暂停',['paused-step']='节点已在步骤结束时暂停'}
function E.new(cfg,state,io,modules)
  local self=setmetatable({cfg=cfg,s=state,io=io,U=modules.U,I=modules.I,N=modules.N,M=modules.M,
    status={},catalogs={},arrays={},errors={},observations={},provided={},now=0,closed={},settled={},filterNames={},healthAt={}},E)
  for _,key in ipairs({'channels','arrays','queue','patterns','moves','poolCounts'}) do state[key]=state[key] or {} end
  state.nextId=state.nextId or 1
  self.save=function() io.save(state) end
  self.log=modules.Log.new(cfg,state,io.proxy,self.save,self.U)
  self.pools=self.U.index(cfg.beePools)
  self.storage=io.proxy(cfg.storage)
  for _,a in ipairs(cfg.arrays) do if a.enabled then self.arrays[#self.arrays+1]=a end end
  return self
end
function E:items(address) local counts=self.I.inventory(self.io.proxy(address).getItemsInNetwork(),{}); return counts end
function E:gate(c,closed)
  self.closed[c.id]=closed
  local locked=self.stopping or false
  for _,other in ipairs(self.cfg.channels) do
    if other.redstone==c.redstone and other.gateSide==c.gateSide and self.closed[other.id]~=false then locked=true end
  end
  self.gateOutputs=self.gateOutputs or {}; local key=c.redstone..':'..c.gateSide
  if self.gateOutputs[key]~=locked then
    self.io.proxy(c.redstone).setOutput(c.gateSide,locked and 15 or 0); self.gateOutputs[key]=locked
  end
end
function E:requestStop()
  self.stopping=true
  for _,c in ipairs(self.cfg.channels) do self:gate(c,true) end
end
function E:hold(a)
  local p=self.io.proxy(a.address)
  if p.isWorkAllowed() then p.setWorkAllowed(false) end
  return not p.hasWork()
end
function E:pause()
  self.gateOutputs={}
  for _,c in ipairs(self.cfg.channels) do pcall(self.gate,self,c,true) end
  for _,a in ipairs(self.arrays) do
    pcall(self.hold,self,a)
    for _,n in ipairs(a.nodes) do pcall(self.io.proxy(n.address).setWorkAllowed,false) end
  end
  self.save()
end
function E:catalogsRead()
  for _,c in ipairs(self.cfg.channels) do
    local patterns={}
    for index,source in ipairs(c.patterns) do
      local p=self.io.proxy(source.address)
      for slot=1,source.slots do local v=p.getInterfacePattern(slot); if v then patterns[index..':'..slot]=v end end
    end
    self.catalogs[c.id]=self.I.catalog(patterns)
  end
end
function E:check()
  self:catalogsRead()
  local needed=0
  for _,a in ipairs(self.arrays) do
    assert(self.log:size(a.io)==12,'投料库存位置不是 ME-IO 端口：'..a.io)
    for _,box in ipairs(a.beeBoxes) do for _,r in ipairs({box.load,box.unload}) do
      local _,id=self.log:ends(r); assert(self.log:size(id)==12,'蜂群库存位置不是 ME-IO 端口：'..id)
    end end
    local s=self.s.arrays[a.address]
    local provided=self.io.proxy(a.nodes[1].address).getProvidedTier()
    self.provided[a.address]=provided and provided.tier
    assert(not provided or s and s.lease and s.lease[provided.tier],
      '阵列内的蜂群没有借用记录，请运行 bec_multi.lua recover 指定归还位置：'..a.address)
    for _,n in ipairs(a.nodes) do
      assert(not self.io.proxy(n.address).hasWork() or self.s.arrays[a.address] and self.s.arrays[a.address].batch,
        '节点正在加工，但找不到续做记录，请运行 bec_multi.lua recover：'..n.address)
      local node=self.io.proxy(n.address)
      if node.hasWork() then
        local consumed=node.getConsumedCondensate()
        for k,v in pairs(node.getRequiredCondensate()) do needed=needed+v-(consumed[k] or 0) end
      end
    end
    if not (self.s.arrays[a.address] or {}).batch then assert(not next(self:items(a.buffer)),
      '阵列投料子网中有原料但没有续做记录，请运行 bec_multi.lua recover：'..a.address) end
  end
  assert(self.storage.hasWork() and self.storage.isWorkAllowed(),'请先启动约束场并持续供电')
  assert(self.U.total(self.storage.getStoredCondensate())<=self.cfg.fieldLimit,'凝聚物库存超过设置的场强容量')
  assert(needed<=self.cfg.fieldLimit,'节点剩余凝聚物需求超过场强容量，请提高场强或完成部分任务后再降低')
  return true
end
function E:start()
  self:pause(); self:check()
  for _,a in ipairs(self.arrays) do
    self.s.arrays[a.address]=self.s.arrays[a.address] or {done=0,counts={}}
    local s=self.s.arrays[a.address]; s.counts=s.counts or {}
    for _,n in ipairs(a.nodes) do self.io.proxy(n.address).setSpeedDivisor(1) end
  end
  if self.storage.getFieldStrength()~=self.cfg.fieldLimit then self.storage.setFieldStrength(self.cfg.fieldLimit) end
  self.fieldProgress=self.storage.getWorkProgress(); self.ready=false
  self.save()
end
function E:owned(id,slot)
  if self.log:claimed(id,slot) then return true end
  for _,r in ipairs(self.s.queue) do if r.inventory==id and r.slot==slot then return true end end
  for _,s in pairs(self.s.channels) do if s.capture and s.capture.inventory==id and s.capture.slot==slot then return true end end
  for _,s in pairs(self.s.arrays) do if s.batch then for _,r in ipairs(s.batch.receipts) do
    if not r.returned and r.inventory==id and r.slot==slot then return true end
  end end end
  return false
end
function E:slot(id,emptyCell)
  for slot=1,self.log:size(id) do if not self:owned(id,slot) then
    local stack=self.log:stack(id,slot)
    if emptyCell and stack and stack.storedItemCount==0 or not emptyCell and not stack then return slot end
  end end
end
function E:channel(c)
  local s=self.s.channels[c.id] or {}; self.s.channels[c.id]=s
  local receiver,queue=self.log:ends(c.route); local owner='channel:'..c.id
  local sourceSlot=self.log.routes[c.route].sourceSlot
  local direct=false; for _,a in ipairs(self.cfg.arrays) do if a.io==queue then direct=true end end
  if s.supply then
    self:gate(c,true)
    if self.log:step(owner,c.route,true,s.supply,sourceSlot) then s.supply=nil; self.log:finish(owner) end
    return
  end
  if s.capture then
    self:gate(c,true)
    if self.log:step(owner,c.route,false,sourceSlot,s.capture.slot) then
      self.s.queue[#self.s.queue+1]=s.capture; s.capture=nil; self.log:finish(owner)
    end
    return
  end
  if direct and self:owned(receiver,sourceSlot) then self:gate(c,true); self.status[c.id]='等待空元件返回'; return end
  local cell=self.log:stack(receiver,sourceSlot)
  if not cell then
    self:gate(c,true); if not direct then s.supply=self:slot(queue,true); if s.supply then self.save() end end
    self.status[c.id]='等待空元件'; return
  end
  assert(cell.storedItemCount~=nil,'接单槽位须放置 ME 物品存储元件')
  local counts=self:items(c.buffer)
  if not next(counts) then self.settled[c.id]=nil; self:gate(c,false); self.status[c.id]=self.stopping and '已停止接单' or '等待 AE 下单'; return end
  self:gate(c,true)
  if not self.settled[c.id] then self.settled[c.id]=self.now; return end
  if self.now-self.settled[c.id]<0.25 then return end
  local p=self.I.identify(self.catalogs[c.id],counts)
  if not p then self.status[c.id]='等待原料到齐'; return end
  local admitted,complete=self.I.receipts(p,counts)
  if complete~=admitted or complete==0 then self.status[c.id]='等待原料到齐'; return end
  local slot=direct and sourceSlot or self:slot(queue,false); if not slot then self.status[c.id]='队列箱已满'; return end
  local key=p.key; self.s.patterns[key]=self.s.patterns[key] or {pattern=p}
  local receipt={id=self.s.nextId,key=key,count=complete,inventory=direct and receiver or queue,slot=slot}
  if direct then self.s.queue[#self.s.queue+1]=receipt else s.capture=receipt end
  self.settled[c.id]=nil
  self.s.nextId=self.s.nextId+1; self.save()
end
function E:remaining(a,s)
  local b=s.batch; if not b or not b.granted then return {} end
  if b.phase=='return' then return {} end
  if not b.started then return self.U.copy(b.reserve) end
  if b.continuous then
    -- Network first, then an upper bound for every consumer: admission between callbacks cannot under-reserve.
    local counts=self:items(a.buffer)
    local count=next(counts) and self.I.receipts(self.s.patterns[b.key].pattern,counts) or 0
    for _,w in ipairs(b.workers) do count=count+(w.limit or w.count) end
    return self.U.scale(self.s.patterns[b.key].unit,math.min(count,b.count-(b.done or 0)))
  end
  local result={}
  for _,w in ipairs(b.workers) do
    local n=self.io.proxy(w.address)
    if n.hasWork() then
      local required,consumed=n.getRequiredCondensate(),n.getConsumedCondensate()
      local unit={}; local count=n.getParallelRecipesInProgress()
      assert(count==w.count,'节点正在加工的份数与续做记录不一致')
      for k,v in pairs(required) do unit[k]=v/count end
      assert(self.U.equal(unit,self.s.patterns[b.key].unit),'节点配方与续做记录不一致')
      for k,v in pairs(required) do
        local left=v-(consumed[k] or 0); assert(left>=0,'节点报告的凝聚物消耗量超过配方需求'); result[k]=(result[k] or 0)+left
      end
    end
  end
  return result
end
function E:resources()
  self.reserved={}; self.waiting={}
  for _,a in ipairs(self.arrays) do
    local s=self.s.arrays[a.address]; local b=s.batch
    if b then
      self.U.add(self.reserved,self:remaining(a,s))
      if not b.granted and b.reserve and self.U.total(b.reserve)<=self.cfg.fieldLimit then self.U.add(self.waiting,b.reserve) end
    end
  end
  -- Read node obligations first: consumption between reads can only understate free stock.
  self.stock=self.storage.getStoredCondensate(); self.free={}
  for k,v in pairs(self.stock) do self.free[k]=math.max(0,v-(self.reserved[k] or 0)) end
  assert(self.U.total(self.stock)<=self.cfg.fieldLimit,'凝聚物库存超过场强容量')
end
function E:grant(b)
  if b.granted then return true end
  if self.U.total(b.reserve)>self.cfg.fieldLimit then return false end
  if not self.U.fits(self.free,b.reserve) then return false end
  b.granted=true; self.U.add(self.reserved,b.reserve); self.U.add(self.free,b.reserve,-1); self.save(); return true
end
function E:beeCells(a)
  local cells={}; for _,c in ipairs(self.pools[a.beePool].cells) do
    cells[c.tier]=cells[c.tier] or c
  end
  return cells
end
function E:beeAccess(a,c)
  for _,box in ipairs(a.beeBoxes) do if box.box==c.box then return box end end
  error('阵列缺少蜂群箱连接：'..a.address..' / 箱子 '..c.box)
end
function E:beeCount(a,c,value)
  local counts=self.s.poolCounts[a.beePool] or {}; self.s.poolCounts[a.beePool]=counts
  local key=cellKey(c)
  if value then counts[key]=value end
  if not counts[key] then
    local stack=self.log:stack(self:beeAccess(a,c).inventory,c.slot)
    if stack and stack.storedItemCount>0 then counts[key]=stack.storedItemCount end
  end
  return counts[key] or 1
end
function E:contended(a,s)
  local tier=s.lease and next(s.lease); if not tier then return false end
  for _,other in ipairs(self.arrays) do if other.address~=a.address and other.beePool==a.beePool then
    local request=self.s.arrays[other.address].request
    if request and request.tier==tier then return true end
  end end
  return false
end
function E:borrow(a,s,tier)
  if s.lease then return s.lease[tier]~=nil end
  if not s.request or s.request.tier~=tier then
    s.request={tier=tier,id=self.s.nextId}; self.s.nextId=self.s.nextId+1; self.save()
  end
  local used,earlier={},0
  for _,other in ipairs(self.cfg.arrays) do if other.beePool==a.beePool then
    local state=self.s.arrays[other.address] or {}
    for _,c in pairs(state.lease or {}) do used[cellKey(c)]=true end
    if state.request and state.request.tier==tier and state.request.id<s.request.id then earlier=earlier+1 end
  end end
  local free={}; local missing=false
  for _,c in ipairs(self.pools[a.beePool].cells) do
    if c.tier==tier and not used[cellKey(c)] then
      local stack=self.log:stack(self:beeAccess(a,c).inventory,c.slot)
      if stack and stack.storedItemCount and stack.storedItemCount>0 then free[#free+1]=c else missing=true end
    end
  end
  s.request.supply=#free==0 and missing or nil
  local c=free[earlier+1]; if not c then return false end
  self:beeCount(a,c)
  s.lease={[tier]={tier=tier,box=c.box,slot=c.slot}}; s.request=nil; s.counts={}; self.save()
  return true
end
function E:waveSize(a,s,meta,count)
  local limit=count
  if not meta.unit then return limit end
  limit=math.min(limit,math.floor(self.cfg.fieldLimit/self.U.total(meta.unit)))
  if limit==0 then return 0 end
  local available=limit
  for k,v in pairs(meta.unit) do available=math.min(available,math.floor((self.free[k] or 0)/v)) end
  return math.max(1,available)
end
function E:schedule()
  local groups,active,blocked={},{},{}
  for _,a in ipairs(self.arrays) do
    local b=self.s.arrays[a.address].batch
    if b and b.reserve and not b.granted and not self:grant(b) then for k in pairs(b.reserve) do blocked[k]=true end end
  end
  for _,s in pairs(self.s.arrays) do if s.batch then active[s.batch.key]=(active[s.batch.key] or 0)+1 end end
  for _,r in ipairs(self.s.queue) do
    if not groups[r.key] then groups[r.key]={key=r.key,first=r.id} end
  end
  local order={}; for _,g in pairs(groups) do order[#order+1]=g end
  table.sort(order,function(x,y)
    local ax,ay=active[x.key] or 0,active[y.key] or 0
    if ax~=ay then return ax<ay end
    local dx,dy=self.s.patterns[x.key].dispatch or 0,self.s.patterns[y.key].dispatch or 0
    if dx~=dy then return dx<dy end; return x.first<y.first
  end)
  local candidates={}
  for _,reserved in ipairs({true,false}) do for _,a in ipairs(self.arrays) do
    if not not a.reserved==reserved then candidates[#candidates+1]=a end
  end end
  for _,g in ipairs(order) do
    local meta=self.s.patterns[g.key]
    if meta.unit or not active[g.key] then
      for _,a in ipairs(candidates) do
        local s=self.s.arrays[a.address]
        local conflict=false; for k in pairs(meta.unit or {}) do if blocked[k] then conflict=true end end
        local capable=true; local cells=self:beeCells(a)
        for _,step in ipairs(meta.steps or {}) do
          local found=false; for tier in pairs(cells) do if tier>=step.tier then found=true end end
          if not found then capable=false end
        end
        if not s.batch then s.blocked=not capable and '蜂群池中没有适用于该配方的蜂群' or nil end
        if not s.batch and not s.bee and not self.errors[a.address] and not conflict and capable then
          local limit=meta.unit and (a.parallelLimit>0 and 2147483647 or self:waveSize(a,s,meta,2147483647)) or 1
          if a.reserved then limit=math.min(limit,#a.nodes) end
          local receipts,count={},0
          for _,r in ipairs(self.s.queue) do if r.key==g.key and self.log:find(r.inventory,a.io) and count<limit then
            local nextCount=count+(r.count or 1)
            local fitsLimit=nextCount<=limit or #receipts==0 and not a.reserved
            if fitsLimit and (#receipts==0 or not meta.unit or a.parallelLimit==0 or self.U.fits(self.free,self.U.scale(meta.unit,nextCount))) then
              receipts[#receipts+1]=r; count=nextCount
            end
          end end
          if #receipts>0 and (not a.reserved or count<=#a.nodes) and self.now-(self.gatherAt[g.key] or self.now)>=self.cfg.gatherSeconds then
            local planned=a.parallelLimit==0 and self:waveSize(a,s,meta,count) or count
            local reserve=meta.unit and self.U.scale(meta.unit,planned)
            if planned==0 or reserve and self.U.total(reserve)>self.cfg.fieldLimit then
              s.blocked=a.parallelLimit>0 and '整单所需凝聚物超过场强容量，请选择自动均分或提高约束场强度' or '单份配方所需凝聚物超过场强容量'
            elseif not reserve or self.U.fits(self.free,reserve) then
              local ids={}; for _,r in ipairs(receipts) do ids[r.id]=true end
              local left={}; for _,r in ipairs(self.s.queue) do if not ids[r.id] then left[#left+1]=r end end
              local b={key=g.key,count=count,done=0,receipts=receipts,cursor=1,phase='load',reserve=reserve,workers={},planned=a.parallelLimit==0 and planned or nil}
              s.blocked=nil; s.counts={}
              s.batch=b; self.s.queue=left; meta.dispatch=self.s.nextId; self.s.nextId=self.s.nextId+1
              if reserve then self:grant(b) else self.save() end
              active[g.key]=(active[g.key] or 0)+1; break
            elseif reserve then
              -- Automatic mode requests only its next wave, never the whole receipt.
              self.U.add(self.waiting,reserve)
              for k in pairs(reserve) do blocked[k]=true end
              break
            end
          end
        end
      end
    end
  end
end
function E:filters(a,unit)
  local d=self.io.proxy(a.diode); assert(d.hasWork() and d.isWorkAllowed(),'麦克斯韦门未运行')
  local names=self.U.keys(unit); if #names==0 then names={'water'} end
  assert(#names<=d.getCondensateFilterCount(),'麦克斯韦门过滤槽不足')
  if self.filterNames[a.address] and self.U.equal(self.filterNames[a.address],names) then return end
  for i=1,d.getCondensateFilterCount() do d.setCondensateFilterAt(i,names[i]) end
  for i=1,d.getCondensateFilterCount() do assert(d.getCondensateFilterAt(i)==names[i],'麦克斯韦门过滤器被覆盖，请移除普通流体仓') end
  self.filterNames[a.address]=names
end
function E:health(a)
  if self.now-(self.healthAt[a.address] or -math.huge)<10 then return end
  local d=self.io.proxy(a.diode); assert(d.hasWork() and d.isWorkAllowed(),'麦克斯韦门未运行')
  local names=self.filterNames[a.address]
  if names then for i=1,d.getCondensateFilterCount() do
    assert(d.getCondensateFilterAt(i)==names[i],'麦克斯韦门过滤器被覆盖，请移除普通流体仓')
  end end
  self.healthAt[a.address]=self.now
end
function E:support(a,meta)
  local bands={}
  for _,b in ipairs(self.cfg.bands) do for _,m in ipairs(self.M) do if m.source==b.material then bands[m.condensate]=true end end end
  for name in pairs(meta.unit) do assert(bands[name],'请在共享流体目标中配置 '..self.M.name(name)) end
  local cells=self:beeCells(a); for _,s in ipairs(meta.steps) do self.N.tier(s.tier,cells) end
end
function E:bees(a,s,want)
  local n=self.io.proxy(a.nodes[1].address); local provided=n.getProvidedTier(); local current=provided and provided.tier
  self.provided[a.address]=current
  if not s.bee and current==want then
    if not want then
      if n.getAvailableNanites()~=0 then return false end
      if s.lease or s.request then s.lease=nil; s.request=nil; s.counts={}; self.save() end
      return true
    end
    if n.getAvailableNanites()>0 then return true end
  end
  if not self:hold(a) then return false end
  if not s.bee then
    if not current then
      if s.lease and not s.lease[want] then s.lease=nil; s.counts={}; self.save() end
      if not self:borrow(a,s,want) then
        self.status[a.address]=(s.request.supply and '等待补充 T' or '等待 T')..want..' 蜂群'; return false
      end
    end
    local tier=current or want; assert(s.lease and s.lease[tier],'阵列内的蜂群没有借用记录')
    s.bee={tier=tier,loading=not current,phase='out'}; self.save()
  end
  local b=s.bee; local cell=s.lease[b.tier]; local box=self:beeAccess(a,cell)
  local route=b.loading and box.load or box.unload
  local _,port=self.log:ends(route); local slot=cell.slot; local owner='bee:'..a.address
  self.status[a.address]=(b.loading and '装载 T' or '回收 T')..b.tier..' 蜂群'
  if b.phase=='out' then
    if self.log:step(owner,route,false,slot,1,true) then b.phase='io'; self.log:finish(owner) end
  elseif b.phase=='io' then
    if self.log:stack(port,7) then b.phase='back'; self.save() end
  elseif b.phase=='back' then
    if self.log:step(owner,route,true,7,slot) then b.phase='sync'; self.log:finish(owner) end
  elseif b.phase=='sync' then
    if b.loading and current==b.tier and n.getAvailableNanites()>0 or not b.loading and n.getAvailableNanites()==0 then
      if b.loading then
        s.counts[b.tier]=n.getAvailableNanites(); self:beeCount(a,cell,s.counts[b.tier])
      else s.lease=nil; s.counts={} end
      s.bee=nil; self.save()
    elseif b.loading and n.getAvailableNanites()==0 then
      local returned=self.log:stack(box.inventory,slot)
      if returned and returned.storedItemCount>0 then
        b.phase='out'; self.save()
      else self.status[a.address]='等待蜂群装载确认，请检查元件内是否有蜂群' end
    end
  end
  return false
end
function E:prepare(a,s)
  local b=s.batch; local meta=self.s.patterns[b.key]
  local counts=self:items(a.buffer)
  local remaining,ready=self.I.receipts(meta.pattern,counts)
  assert(remaining<=b.count-(b.done or 0),'投料子网中的原料超过订单剩余份数')
  if ready==0 then return end
  b.done=b.count-remaining; b.continuous=a.parallelLimit>0
  local perNode=a.parallelLimit>0 and a.parallelLimit or 2147483647
  local target=b.continuous and math.min(ready,#a.nodes*perNode)
    or b.planned or self:waveSize(a,s,meta,ready)
  assert(target>0,'单份配方所需凝聚物超过场强容量')
  b.planned=nil
  local active=math.min(target,#a.nodes); b.workers={}
  for i=1,active do
    local count=math.floor(target/active)+(i<=target%active and 1 or 0)
    b.workers[i]={address=a.nodes[i].address,count=count,limit=count}
  end
  b.phase='admit'; b.started=false; b.granted=false; b.reserve=nil
  b.reference=nil; b.fixed=nil; b.fastChecked=nil; b.yielding=nil; self.save()
end
function E:recover(a,s)
  local b=s.batch; if not b or b.phase~='run' then return end
  local meta=self.s.patterns[b.key]; local counts=self:items(a.buffer)
  local total=not b.adopted and next(counts) and self.I.receipts(meta.pattern,counts) or 0
  local workers={}
  for _,node in ipairs(a.nodes) do
    local n=self.io.proxy(node.address)
    if n.hasWork() then
      local count=n.getParallelRecipesInProgress(); assert(count>0,'无法续做：节点未返回有效的加工份数')
      local unit={}; for k,v in pairs(n.getRequiredCondensate()) do unit[k]=v/count end
      assert(self.U.equal(unit,meta.unit) and self.U.equal(self.N.steps(n.getRecipeSteps()),meta.steps),'节点配方与续做记录不一致')
      total=total+count; workers[#workers+1]={address=node.address,count=count,limit=count}
    end
  end
  assert(total<=b.count,'节点加工份数与剩余原料份数之和超过订单份数')
  b.done=b.count-total; b.workers=workers; b.continuous=false; b.fixed=nil; b.reference=nil
  self.save()
end
function E:array(a)
  local s=self.s.arrays[a.address]; local b=s.batch
  self:health(a)
  if not b or b.phase~='run' then self.observations[a.address]=nil end
  if not b then self:hold(a); self.status[a.address]=s.blocked or '空闲'; return end
  local meta=self.s.patterns[b.key]; self.status[a.address]=phases[b.phase]..' · '..meta.pattern.label..' ×'..b.count
  if b.phase~='run' and not self:hold(a) then return end
  if b.phase=='load' then
    local r=b.receipts[b.cursor]; local owner='load:'..a.address
    if not r then
      assert(self.U.equal(self:items(a.buffer),self.U.scale(meta.pattern.inputs,b.count)),'投料子网中的原料数量与订单不一致')
      self:prepare(a,s); return
    end
    local route=r.route or assert(self.log:find(r.inventory,a.io),'未配置接单元件到阵列投料 ME-IO 端口的路线')
    if not r.route then r.route=route; self.save() end
    r.phase=r.phase or 'out'
    if r.phase=='out' then
      if self.log:step(owner,route,false,r.slot,1,true) then r.phase='io'; self.log:finish(owner) end
    elseif r.phase=='io' then
      local cell=self.log:stack(a.io,7)
      if cell then assert(cell.storedItemCount==0,'请将投料 ME-IO 端口设为“当元件为空时移动至输出口”'); r.phase='back'; self.save() end
    elseif r.phase=='back' then
      if self.log:step(owner,route,true,7,r.slot) then r.returned=true; b.cursor=b.cursor+1; self.log:finish(owner) end
    end
  elseif b.phase=='admit' then
    local all=true; local assigned=0
    for _,w in ipairs(b.workers) do
      local n=self.io.proxy(w.address)
      if n.hasWork() then
        n.setWorkAllowed(not not b.continuous)
        local count=n.getParallelRecipesInProgress()
        assert(n.getWorkProgress()==0 and count>0 and count<=(w.limit or w.count),'节点取料份数超出分配范围，或已开始加工；请检查节点控制设置')
        w.count=count; assigned=assigned+count
        local required=n.getRequiredCondensate(); local steps=self.N.steps(n.getRecipeSteps()); local unit={}
        for k,v in pairs(required) do unit[k]=v/count end; assert(self.U.total(unit)>0,'未读取到节点的凝聚物需求')
        if not meta.unit then meta.unit=unit; meta.steps=steps; self.save() end
        assert(self.U.equal(meta.unit,unit) and self.U.equal(meta.steps,steps),'节点配方与已记录的处理样板不一致')
      else
        n.setMinParallel(1); n.setMaxParallel(w.limit or w.count); n.setWorkAllowed(true); all=false
      end
    end
    if all then
      local counts=self:items(a.buffer); local remaining=next(counts) and self.I.receipts(meta.pattern,counts) or 0
      assert(assigned+remaining==b.count-(b.done or 0),'节点取料份数与投料子网减少的原料份数不一致')
      b.reserve=self.U.scale(meta.unit,b.continuous and b.count-(b.done or 0) or assigned)
      b.phase='wait'; self.save()
    end
  elseif b.phase=='wait' then
    self:support(a,meta)
    if b.continuous and a.parallelLimit==0 then
      local count=0; for _,w in ipairs(b.workers) do count=count+w.count; self.io.proxy(w.address).setWorkAllowed(false) end
      b.continuous=false; b.reserve=self.U.scale(meta.unit,count); b.granted=false; self.save()
    end
    if not self:grant(b) then
      self:bees(a,s,nil)
      self.status[a.address]=self.U.total(b.reserve)>self.cfg.fieldLimit and
        string.format('凝聚物需求 %.0f L 超过场强容量 %.0f L；请按 Ctrl+C 暂停，提高约束场强度后续做',self.U.total(b.reserve),self.cfg.fieldLimit) or '等待凝聚物'
      return
    end
    self:filters(a,meta.unit)
    local cells=self:beeCells(a)
    if b.continuous and not b.fastChecked then
      local ceiling={}; for tier,c in pairs(cells) do ceiling[tier]=self:beeCount(a,c) end
      local parallel=1; for _,w in ipairs(b.workers) do parallel=math.max(parallel,w.limit or w.count) end
      local candidate=self.N.fastTier(meta.steps,cells,ceiling,parallel)
      if candidate and not self:bees(a,s,candidate) then return end
      b.fixed=candidate and self.N.fastTier(meta.steps,cells,s.counts,parallel) or nil
      b.fastChecked=true; self.save()
    end
    local tier=b.fixed or self.N.tier(meta.steps[1].tier,cells)
    if self:bees(a,s,tier) then
      b.phase='run'; b.started=true; self.save()
      for _,w in ipairs(b.workers) do self.io.proxy(w.address).setWorkAllowed(not not b.continuous) end
      self.io.proxy(a.address).setWorkAllowed(true)
    end
  elseif b.phase=='run' then
    if b.continuous and (b.yielding or self:contended(a,s)) then
      if not b.yielding then b.yielding=true; self.save() end
      self.yieldClosed=self.yieldClosed or {}
      if self.yieldClosed[a.address]~=b then
        for _,w in ipairs(b.workers) do self.io.proxy(w.address).setWorkAllowed(false) end
        self.yieldClosed[a.address]=b
      end
      self.status[a.address]='等待当前加工完成'
    end
    if s.bee then self:bees(a,s,s.bee.tier); return end
    local workers={}; self.observations[a.address]={}
    for index,w in ipairs(b.workers) do
      local n=self.io.proxy(w.address)
      if n.hasWork() then
        local progress=b.fixed and 0 or n.getWorkProgress(); local tier=b.fixed or self.N.requested(meta.steps,progress)
        if b.fixed or n.hasWork() then
          workers[#workers+1]={progress=progress,tier=tier,address=w.address}
          self.observations[a.address][index]={progress=progress,tier=tier,parallel=b.continuous and (w.limit or w.count) or w.count,length=meta.steps[#meta.steps].finish,fast=b.fixed~=nil,upper=b.continuous}
        end
      end
    end
    self.nodeHealth=self.nodeHealth or {}
    local health=self.nodeHealth[a.address] or {at=self.now,index=1}; self.nodeHealth[a.address]=health
    if #workers>0 and self.now-health.at>=10/#b.workers then
      health.index=(health.index-1)%#workers+1
      local worker=workers[health.index]; local n=self.io.proxy(worker.address)
      local state=n.getState(); local held=not self.io.proxy(a.address).isWorkAllowed()
      assert(not nodeErrors[state] or state=='assembler-offline' and held,
        (nodeErrors[state] or state)..'：'..worker.address..'；请检查机器状态后重新运行程序')
      health.at=self.now; health.index=health.index+1
    end
    if #workers==0 then
      if b.continuous and not b.yielding and next(self:items(a.buffer)) then return end
      for _,w in ipairs(b.workers) do self.io.proxy(w.address).setWorkAllowed(false) end
      if not self:hold(a) then return end
      if b.yielding or self:contended(a,s) then if not self:bees(a,s,nil) then return end end
      if not b.adopted and next(self:items(a.buffer)) then self:prepare(a,s); return end
      self:filters(a,{})
      b.phase='return'; self.save(); return
    end
    local ref=self.N.choose(workers,b.reference,meta.steps[#meta.steps].finish)
    if ref then
      b.reference=ref.progress
      local tier=b.fixed or self.N.tier(ref.tier,self:beeCells(a))
      if self:bees(a,s,tier) then
        local assembler=self.io.proxy(a.address)
        if not assembler.isWorkAllowed() then
          if not self:hold(a) then return end
          self:filters(a,meta.unit); assembler.setWorkAllowed(true)
        end
      end
    end
  elseif b.phase=='return' then
    if not self:bees(a,s,nil) then return end
    s.done=s.done+b.count; s.batch=nil; s.request=nil
    if s.bufferOrder then
      s.batch={key=s.bufferOrder.key,count=s.bufferOrder.count,receipts={},cursor=1,phase='load'}; s.bufferOrder=nil
    end
    self.save()
  end
end
function E:drain()
  local failed,reason=next(self.errors); if failed then error('无法完成已接订单：'..failed..' / '..reason) end
  if #self.s.queue>0 then return false end
  for _,s in pairs(self.s.channels) do if s.capture or s.supply then return false end end
  for _,c in ipairs(self.cfg.channels) do if next(self:items(c.buffer)) then return false end end
  for _,a in ipairs(self.arrays) do if self.s.arrays[a.address].batch then return false end end
  for _,a in ipairs(self.arrays) do
    if not self:hold(a) or not self:bees(a,self.s.arrays[a.address],nil) then return false end
    self:filters(a,{})
  end
  return true
end
function E:tick()
  self.now=self.io.time()
  if self.now-(self.fieldHealthAt or -math.huge)>=10 then
    assert(self.storage.isWorkAllowed() and self.storage.hasWork(),'约束场未运行')
    assert(self.storage.getFieldStrength()==self.cfg.fieldLimit,'场强与配置不一致，请检查是否被手动修改')
    self.fieldHealthAt=self.now
  end
  if not self.ready then
    local p=self.storage.getWorkProgress()
    if p<self.fieldProgress then self.ready=true end; self.fieldProgress=p
  end
  if not self.ready then return end
  -- Every assembler must finish its old cycle before the first resource snapshot.
  if not self.recovered then
    for _,a in ipairs(self.arrays) do if not self:hold(a) then return end end
    for _,a in ipairs(self.arrays) do self:recover(a,self.s.arrays[a.address]) end
    self.recovered=true; self.gatherAt={}
  end
  self:resources()
  for _,c in ipairs(self.cfg.channels) do if not self.errors[c.id] then
    if self.s.recovering and not ((self.s.channels[c.id] or {}).capture or (self.s.channels[c.id] or {}).supply) then self:gate(c,true)
    else
    local ok,err=pcall(self.channel,self,c); if not ok then self.errors[c.id]=err; self:gate(c,true) end
    end
  end end
  local queued={}
  for _,r in ipairs(self.s.queue) do queued[r.key]=true; self.gatherAt[r.key]=self.gatherAt[r.key] or self.now end
  for key in pairs(self.gatherAt) do if not queued[key] then self.gatherAt[key]=nil end end
  if not self.s.recovering then self:schedule() end
  for _,a in ipairs(self.arrays) do if not self.errors[a.address] then
    local ok,err=pcall(self.array,self,a)
    if not ok then self.errors[a.address]=err; self:hold(a); for _,n in ipairs(a.nodes) do self.io.proxy(n.address).setWorkAllowed(false) end end
  end end
  if self.s.recovering then
    local busy=false
    for _,a in ipairs(self.arrays) do
      local s=self.s.arrays[a.address]
      if s.batch or s.bee or s.lease then
        busy=true
        if not s.batch and not self.errors[a.address] then self:bees(a,s,nil) end
      end
    end
    if not busy and not next(self.errors) then self.s.recovering=nil; self.save() end
  end
end
return E
