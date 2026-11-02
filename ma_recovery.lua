local R={}
function R.check(cfg,state,U,proxy,M)
  local old=state.wiring; if not old then return end
  local before,after={},{}
  for _,name in ipairs({'inventories','routes','channels','arrays','beePools','feeds','generators'}) do
    local key=(name=='arrays' or name=='generators') and 'address' or 'id'
    before[name]=U.index(old[name],key); after[name]=U.index(cfg[name],key)
  end
  local active=false
  local function same(a,b,message) assert(U.equal(a,b),'续做仍需保留'..message) end
  local function inventory(id)
    same(before.inventories[id],after.inventories[id],'库存位置：'..id)
  end
  local function route(id)
    local r=before.routes[id]; same(r,after.routes[id],'搬运路线：'..id)
    for _,step in ipairs(r.steps) do inventory(step.from); inventory(step.to) end
  end
  local function fields(a,b,keys,message)
    assert(b,'续做仍需保留'..message)
    local names={buffer='子网 ME 控制器',redstone='红石 I/O',gateSide='红石输出方向',route='搬运路线',
      io='投料 ME-IO 端口',diode='麦克斯韦门',beePool='共享蜂群池'}
    for _,k in ipairs(keys) do same(a[k],b[k],message..' / '..names[k]) end
  end
  for buffer,g in pairs(state.groups or {}) do
    active=true
    for _,id in ipairs(g.members) do
      local a=after.arrays[id]
      assert(a and a.enabled and a.buffer==buffer,'共享子网任务未完成，请保留阵列及其原料子网：'..id)
    end
  end
  local function firstRoute(config,from,to)
    for _,r in ipairs(config.routes) do if r.steps[1].from==from and r.steps[#r.steps].to==to then return r.id end end
  end
  local function receipt(r,array)
    if r.returned then return end
    active=true; inventory(r.inventory)
    if array and (r.phase or r.route) then
      same(array.io,after.arrays[array.address].io,'正在投料的 ME-IO 端口：'..array.address)
      local id=r.route or firstRoute(old,r.inventory,array.io); route(id)
      if not r.route then same(id,firstRoute(cfg,r.inventory,array.io),'正在使用的投料路线') end
    else
      local reachable=false
      for _,a in ipairs(cfg.arrays) do if a.enabled and firstRoute(cfg,r.inventory,a.io) then reachable=true end end
      assert(reachable,'待加工元件没有可用的投料路线：'..r.inventory)
    end
  end
  for _,r in ipairs(state.queue or {}) do receipt(r) end
  for id,s in pairs(state.channels or {}) do
    if s.capture or s.supply then
      active=true
      fields(before.channels[id],after.channels[id],{'buffer','redstone','gateSide','route'},'接单通道：'..id)
      route(before.channels[id].route)
    end
  end
  -- Materials already received may not yet have a receipt when OC stops.
  if proxy then for id,c in pairs(before.channels) do
    if next(proxy(c.buffer).getItemsInNetwork()) then
      active=true; fields(c,after.channels[id],{'buffer','redstone','gateSide','route'},'尚有原料的接单通道：'..id); route(c.route)
    end
  end end
  local bands={}; for _,b in ipairs(cfg.bands) do bands[b.material]=true end
  local function required(unit)
    for _,m in ipairs(M or {}) do if (unit or {})[m.condensate] then
      assert(bands[m.source],'未完成任务仍需该流体的预缓存配置：'..m.label)
    end end
  end
  for id,s in pairs(state.arrays or {}) do
    local a,b=before.arrays[id],after.arrays[id]
    if s.batch or s.bufferOrder or s.lease or s.bee then
      active=true; assert(b and b.enabled,'续做仍需启用阵列：'..id)
      fields(a,b,{'buffer','diode','beePool'},'阵列连接：'..id)
      if s.batch then
        local nodes=U.index(b.nodes,'address')
        for _,w in ipairs(s.batch.workers or {}) do assert(nodes[w.address],'续做仍需保留节点：'..w.address) end
        for _,r in ipairs(s.batch.receipts or {}) do receipt(r,a) end
        required(state.patterns[s.batch.key].unit)
      end
      for tier,c in pairs(s.lease or {}) do
        local pool=after.beePools[a.beePool]; local found=false
        for _,v in ipairs(pool and pool.cells or {}) do if v.box==c.box and v.slot==c.slot and v.tier==tier then found=true end end
        assert(found,'蜂群尚未归还，请保留池 '..a.beePool..' / 箱 '..c.box..' / 槽 '..c.slot)
        local ab,bb=U.index(a.beeBoxes,'box')[c.box],U.index(b.beeBoxes,'box')[c.box]
        same(ab,bb,'已借蜂群的箱子连接：'..id..' / '..c.box)
        inventory(ab.inventory); route(ab.load); route(ab.unload)
      end
    end
  end
  for _,move in pairs(state.moves or {}) do
    active=true
    for _,op in ipairs(move.ops) do inventory(op.from); inventory(op.to) end
  end
  local refill=state.refill or {}
  for id,s in pairs(refill.feeds or {}) do
    if s.loading or next(s.pending or {}) then
      active=true; local a,b=before.feeds[id],after.feeds[id]
      assert(b,'补库尚未完成，请保留原料网：'..id)
      if s.loading then same(a.io,b.io,'补库 ME-IO 端口：'..id); inventory(a.io) end
      for i,c in ipairs(a.cells) do if (s.pending or {})[i] or s.loading and s.loading.index==i then
        same(c,b.cells[i],'尚在补库的元件：'..id..' / '..i); route(c.route)
      end end
      for address,g in pairs(before.generators) do if g.feed==id then same(g,after.generators[address],'纠缠装置归属：'..address) end end
    end
  end
  for id,s in pairs(refill.generators or {}) do if s.busy then
    active=true; same(before.generators[id],after.generators[id],'仍在加工的纠缠装置：'..id)
  end end
  if active then same(old.storage,cfg.storage,'共享约束场') end
  return true
end
function R.adopt(e,choose)
  e:catalogsRead()
  local arrays,patterns=e.U.copy(e.s.arrays),e.U.copy(e.s.patterns)
  local used={}
  for _,a in ipairs(e.cfg.arrays) do for _,c in pairs((arrays[a.address] or {}).lease or {}) do
    used[a.beePool..':'..c.box..':'..c.slot]=true
  end end
  local catalog={patterns={}}; local known={}
  for _,list in pairs(e.catalogs) do for _,p in ipairs(list.patterns) do if not known[p.key] then
    catalog.patterns[#catalog.patterns+1]=p; known[p.key]=true
  end end end
  local readBuffers,knownBuffers={},{}
  for _,a in ipairs(e.arrays) do if (arrays[a.address] or {}).batch or e.s.groups[a.buffer] then
    readBuffers[a.buffer]=true; knownBuffers[a.buffer]=true
  end end
  for _,a in ipairs(e.arrays) do
    local s=arrays[a.address] or {done=0,counts={}}; arrays[a.address]=s
    if not s.batch then
      local workers,unit,steps={},nil,nil; local count=0
      for _,node in ipairs(a.nodes) do local n=e.io.proxy(node.address); if n.hasWork() then
        local parallel=n.getParallelRecipesInProgress(); assert(parallel>0,'接管节点未返回加工份数：'..node.address)
        local required=n.getRequiredCondensate(); local per={}; for k,v in pairs(required) do per[k]=v/parallel end
        local recipe=e.N.steps(n.getRecipeSteps())
        assert(not unit or e.U.equal(unit,per) and e.U.equal(steps,recipe),'同一阵列的现有节点配方不同，暂不能合并接管：'..a.address)
        unit,steps=per,recipe; count=count+parallel
        workers[#workers+1]={address=node.address,count=parallel,limit=parallel}
      end end
      -- With no move record, an occupied port has no recoverable return address.
      local ports={[a.io]=true}
      for _,box in ipairs(a.beeBoxes) do for _,route in ipairs({box.load,box.unload}) do local _,id=e.log:ends(route); ports[id]=true end end
      if not s.bee and not e.s.moves['load:'..a.address] and not e.s.moves['bee:'..a.address] then
        for id in pairs(ports) do for slot=1,e.log:size(id) do
          assert(not e.log:stack(id,slot),'接管前请确认并归还没有搬运记录的元件：'..id..' / 槽 '..slot)
        end end
      end
      local contents=not readBuffers[a.buffer] and e:items(a.buffer) or {}; readBuffers[a.buffer]=true
      if next(contents) then
        local p=assert(e.I.identify(catalog,contents),'投料子网原料尚未到齐，不能接管：'..a.address)
        local total,complete=e.I.receipts(p,contents)
        assert(total==complete,'投料子网有不完整原料，不能接管：'..a.address)
        patterns[p.key]=patterns[p.key] or {pattern=p}; s.bufferOrder={key=p.key,count=complete}
      end
      if count>0 then
        local key='recovered:'..a.address
        patterns[key]={pattern={label='接管的节点任务',inputs={}},unit=unit,steps=steps}
        s.batch={key=key,count=count,done=0,workers=workers,receipts={},phase='run',
          started=true,granted=true,continuous=false,adopted=true}
      elseif s.bufferOrder then
        s.batch={key=s.bufferOrder.key,count=s.bufferOrder.count,receipts={},cursor=1,phase='load'}; s.bufferOrder=nil
      end
    end
    local node=e.io.proxy(a.nodes[1].address); local provided=node.getProvidedTier()
    if provided and not (s.lease and s.lease[provided.tier]) then
      assert(not s.bee and not s.lease,'蜂群装卸记录与现场不一致，请先核对：'..a.address)
      local candidates={}
      for _,c in ipairs(e.pools[a.beePool].cells) do if c.tier==provided.tier and not used[a.beePool..':'..c.box..':'..c.slot] then
        local stack=e.log:stack(e:beeAccess(a,c).inventory,c.slot)
        if stack and stack.storedItemCount==0 then candidates[#candidates+1]=c end
      end end
      assert(#candidates>0,'找不到可归还 T'..provided.tier..' 蜂群的空元件：'..a.address)
      local selected=choose(a,provided.tier,candidates); local valid
      for _,c in ipairs(candidates) do if selected and selected.box==c.box and selected.slot==c.slot then valid=c end end
      assert(valid,'未确认蜂群归还位置，接管已取消：'..a.address)
      s.lease={[provided.tier]=e.U.copy(valid)}; s.request=nil
      s.counts={[provided.tier]=node.getAvailableNanites()}
      used[a.beePool..':'..selected.box..':'..selected.slot]=true
    end
  end
  local groups=e.U.copy(e.s.groups)
  for buffer,members in pairs(e.subnets) do if #members>1 and not groups[buffer] and not knownBuffers[buffer] then
    local g={buffer=buffer,members={},count=0,phase='work',granted=true,continuous=false}
    local pending
    for _,a in ipairs(members) do
      g.members[#g.members+1]=a.address
      local s=arrays[a.address]; local b=s.batch
      if b and b.adopted then
        local meta=patterns[b.key]
        if g.key then
          local first=patterns[g.key]
          assert(e.U.equal(meta.unit,first.unit) and e.U.equal(meta.steps,first.steps),'同一共享子网的活动节点配方不同，不能合并接管')
        else g.key=b.key; g.leader=a.address end
        g.count=g.count+b.count; b.key=g.key; b.group=buffer
      elseif b and b.phase=='load' then
        pending={key=b.key,count=b.count,leader=a.address}; s.batch=nil
      end
      if s.bufferOrder then pending=s.bufferOrder; pending.leader=a.address; s.bufferOrder=nil end
    end
    if g.key then g.pending=pending; groups[buffer]=g
    elseif pending then
      g.key,g.count,g.leader,g.phase=pending.key,pending.count,pending.leader,'load'; g.granted=false
      arrays[g.leader].batch={group=buffer,key=g.key,count=g.count,receipts={},cursor=1,workers={},phase='load'}
      groups[buffer]=g
    end
  end end
  e.s.arrays,e.s.patterns,e.s.groups=arrays,patterns,groups; e.s.recovering=true; e.save()
end
return R
