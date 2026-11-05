"""Render actual Lua GPU calls to PNGs for layout checks; no Minecraft connection."""
from pathlib import Path
import sys
import unicodedata
from PIL import Image, ImageDraw, ImageFont

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / '.testdeps'))
from lupa.lua53 import LuaRuntime

lua = LuaRuntime(unpack_returned_tuples=True)
lua.globals().ROOT = root.as_posix() + '/'
lua.globals().utf_len = len
lua.globals().utf_sub = lambda s, a, b=None: s[a - 1:b if b is None or b >= 0 else len(s) + b + 1]
def cells(s):
    return sum(2 if unicodedata.east_asian_width(c) in ('W', 'F') else 1 for c in s)
lua.globals().utf_width = cells
lua.globals().utf_char = chr
font = ImageFont.truetype('C:/Windows/Fonts/msyh.ttc', 17)
mono = ImageFont.truetype('C:/Windows/Fonts/consola.ttf', 18)
out = root / 'tests' / 'previews'
out.mkdir(exist_ok=True)

for width, height in ((120, 38), (80, 25), (160, 50)):
    state = {'fg': 0xffffff, 'bg': 0}
    canvas = Image.new('RGB', (width * 10, height * 22), '#101820')
    draw = ImageDraw.Draw(canvas)
    def color(n):
        return f'#{int(n):06x}'
    def put(x, y, text):
        assert 1 <= x <= width and 1 <= y <= height
        assert x - 1 + cells(text) <= width, (x, y, text)
        px, py = (x - 1) * 10, (y - 1) * 22
        for ch in text:
            n = cells(ch)
            draw.rectangle((px, py, px + n * 10 - 1, py + 21), fill=color(state['bg']))
            if ch == '━':
                draw.line((px, py + 11, px + n * 10, py + 11), fill=color(state['fg']), width=2)
            else:
                draw.text((px, py), ch, font=font if n == 2 else mono, fill=color(state['fg']))
            px += n * 10
    lua.globals().gpu_set = put
    lua.globals().gpu_fg = lambda n: state.update(fg=n)
    lua.globals().gpu_bg = lambda n: state.update(bg=n)
    lua.globals().screen_w, lua.globals().screen_h = width, height
    lua.execute('''
      C=dofile(ROOT..'ma_config.lua'); M=dofile(ROOT..'ma_materials.lua'); U=dofile(ROOT..'ma_util.lua')
      G=dofile(ROOT..'ma_gui.lua'); Editor=dofile(ROOT..'ma_editor.lua')
      gpu={getResolution=function() return screen_w,screen_h end,maxResolution=function() return screen_w,screen_h end,
        set=gpu_set,setForeground=gpu_fg,setBackground=gpu_bg}
      unicode={len=utf_len,sub=utf_sub,wlen=utf_width,char=utf_char}
      ui=G.new(gpu,{},unicode,C,M); fixture=dofile(ROOT..'tests/gui_fixture.lua')
      ui:runtime(fixture.engine,fixture.refill)
    ''')
    canvas.save(out / f'runtime-{width}.png')
    if width == 120:
        canvas.save(root / 'wiki' / 'runtime.png')
    for name, index in (('fast', 1), ('progress', 2), ('idle', 4)):
        lua.execute(f'ui.arrayIndex={index}; ui:runtime(fixture.engine,fixture.refill)')
        if width == 160:
            lua.execute('''
              assert(ui.nodePages == 1, '16 nodes should fit on one page')
              local previous,count=nil,0
              for y,row in ipairs(ui.rows) do
                for _,span in ipairs(row) do
                  assert(not span[2]:find('独立调度',1,true))
                  if span[2]:match('^#%d+  ') then
                    assert(not previous or y == previous+2, 'nodes should use two rows each')
                    previous=y; count=count+1
                  end
                end
              end
              assert(count == 16, 'all 16 nodes should be visible')
            ''')
        canvas.save(out / f'runtime-{name}-{width}.png')
        if width == 160 and name == 'progress':
            canvas.save(root / 'wiki' / 'runtime-progress.png')
    lua.execute('ui.arrayIndex=1')
    lua.execute('''
      local make=assert(loadfile(ROOT..'tests/simplified.lua'))('fixture')
      sparse=make(1,16,{nodes=16,stageTicks=400})
      for i=1,2000 do
        sparse.tick()
        if sparse.state.arrays.a1.batch and sparse.state.arrays.a1.batch.phase=='run' then break end
      end
      assert(sparse.state.arrays.a1.batch.phase=='run')
      sparse.nodes['a1:n1'].active=false
      sparse.nodes['a1:n8'].active=false
      sparse.e:recover(sparse.cfg.arrays[1],sparse.state.arrays.a1)
      sparse.e:array(sparse.cfg.arrays[1]); ui.tab=2; ui.nodeOnly=true
      ui:runtime(sparse.e,sparse.r)
      local shown={}; for _,row in ipairs(ui.rows) do for _,s in ipairs(row) do shown[#shown+1]=s[2] end end
      shown=table.concat(shown,' | ')
      assert(shown:find('#1  空闲',1,true) and shown:find('#2  1 并行',1,true))
    ''')
    canvas.save(out / f'runtime-recovered-{width}.png')
    lua.execute('ui.nodeOnly=false')
    for name, tab, nodes in (('arrays', 2, False), ('nodes', 2, True), ('channels', 3, False)):
        lua.execute(f'ui.tab={tab}; ui.nodeOnly={str(nodes).lower()}; ui:runtime(fixture.engine,fixture.refill)')
        canvas.save(out / f'runtime-{name}-{width}.png')
    lua.execute('ui.nodeOnly=false')
    lua.execute('''
      fixture.cfg.beePools[1]={id='ender-bees',cells={{tier=4,box=1,slot=7},{tier=10,box=2,slot=6}}}
      fixture.engine.provided={}
      for i=1,3 do fixture.cfg.arrays[i].beePool='ender-bees' end
      local first,second,third=fixture.cfg.arrays[1].address,fixture.cfg.arrays[2].address,fixture.cfg.arrays[3].address
      fixture.engine.s.arrays[first].lease={[4]={tier=4,box=1,slot=7}}
      fixture.engine.provided[first]=4
      fixture.engine.s.arrays[second].lease={[10]={tier=10,box=2,slot=6}}
      fixture.engine.provided[second]=10
      fixture.engine.s.arrays[third].request={tier=10,id=3}
      fixture.engine.status[third]='等待 T10 蜂群'
      ui.tab=2; ui.selected[2]=3; ui:runtime(fixture.engine,fixture.refill)
    ''')
    lua.execute('fixture.engine.s.recovering=true; ui:runtime(fixture.engine,fixture.refill)')
    canvas.save(out / f'recovery-{width}.png')
    lua.execute('fixture.engine.s.recovering=nil; ui:runtime(fixture.engine,fixture.refill)')
    canvas.save(out / f'shared-wait-{width}.png')
    if width == 120:
        canvas.save(root / 'wiki' / 'shared-wait.png')
    lua.execute('''
      local make=assert(loadfile(ROOT..'tests/simplified.lua'))('fixture')
      admission=make(10,32000,{nodes=16,stageTicks=300})
      admission.cfg.fieldLimit=1e9; admission.stock.entangled_neutronium=1e8
      for i=1,2000 do
        admission.tick()
        local b=admission.state.arrays.a1.batch
        if b and b.phase=='admit' and admission.e.nodeCache['a1:n1'].intake then break end
      end
      assert(admission.state.arrays.a1.batch.admitting)
      ui.tab=2; ui.selected[2]=1; ui.arrayIndex=1
      ui:runtime(admission.e,admission.r)
    ''')
    canvas.save(out / f'runtime-admission-{width}.png')
    lua.execute('''
      local make=assert(loadfile(ROOT..'tests/simplified.lua'))('fixture')
      capacity=make(1,100000000,{nodes=16})
      capacity.cfg.fieldLimit=1e9; capacity.stock.entangled_neutronium=1e9
      for i=1,2000 do
        capacity.tick()
        local b=capacity.state.arrays.a1.batch
        if b and b.phase=='wait' and not b.admitting then break end
      end
      assert(capacity.state.arrays.a1.batch.phase=='wait')
      ui:runtime(capacity.e,capacity.r)
    ''')
    canvas.save(out / f'runtime-capacity-{width}.png')
    lua.execute('''
      local make=assert(loadfile(ROOT..'tests/simplified.lua'))('fixture')
      completed=make(1,16,{nodes=16})
      for i=1,2000 do
        completed.tick()
        local b=completed.state.arrays.a1.batch
        if b and b.phase=='return' then break end
      end
      assert(completed.state.arrays.a1.batch.phase=='return')
      ui:runtime(completed.e,completed.r)
    ''')
    canvas.save(out / f'runtime-complete-{width}.png')
    lua.execute('''
      local make=assert(loadfile(ROOT..'tests/singularities.lua'))('fixture')
      local stream={}; for i=1,7 do stream[i]={kind=i} end
      local w=make(stream)
      w.untilTrue(function() local b=w.state.arrays.a1.batch; return b and b.phase=='collect' and #b.workers==7 end)
      w.state.arrays.a1.batch.collection.elapsed=120; w.tick()
      ui.tab=2; ui.selected[2]=1; ui.arrayIndex=1; ui:runtime(w.e,w.r)
    ''')
    canvas.save(out / f'singularity-collection-{width}.png')
    if width == 120:
        canvas.save(root / 'wiki' / 'singularity-collection.png')
    lua.execute("example=dofile(ROOT..'examples/shared-bees.lua'); C.validate(example.cfg,example.component,U); editor=Editor.new(ui,example.cfg,example.component,{U=U,write=function() end})")
    lua.execute("function pick(kind,box) for i,o in ipairs(editor:objects()) do if o.kind==kind and (not box or o.box==box) then editor:act('select:'..i); return end end error(kind) end")
    pages = {
        'fluid': "editor:act('tab:1'); pick('fluids')",
        'fluid-edit': "editor:act('tab:1'); pick('fluids'); editor:act('fluid:1:high')",
        'devices': "editor:act('tab:2')",
        'arrays': "editor:act('tab:3')",
        'arrays-edit': "editor:act('tab:3'); local found=false; for i,f in ipairs(editor:form()) do if f.label=='算力奇点等待阈值（秒）' then editor.offset=i; editor:activate(f); found=true; break end end; assert(found)",
        'channel': "editor:act('tab:4')",
        'recipe-clear': "editor:act('tab:4'); editor:act('clear-recipes')",
        'patterns': "editor:act('tab:4'); editor:patternPicker(example.cfg.channels[1])",
        'refill': "editor:act('tab:1'); pick('feed')",
        'generators': "editor:act('tab:1')",
        'shared-pool': "editor:act('tab:2'); pick('box',1)",
        'shared-cell': "editor:act('tab:2'); pick('box',2)",
        'shared-array': "editor:act('tab:3')",
        'shared-boxes': "editor:act('tab:3'); for i,f in ipairs(editor:form()) do if f.label=='蜂群装载配置' then editor.offset=i; break end end",
        'nodes': "editor:act('tab:3'); editor:act('select:2'); example.cfg.arrays[2].nodes={}; editor:nodePicker(example.cfg.arrays[2])",
        'nodes-bound': "editor:act('all'); editor:act('apply')",
    }
    for name, actions in pages.items():
        if name != 'nodes-bound':
            dataset = 'shared-bees' if name.startswith('shared-') else 'two-arrays'
            lua.execute("example=dofile(ROOT..'examples/" + dataset + ".lua'); editor=Editor.new(ui,example.cfg,example.component,{U=U,write=function() end})")
        lua.execute(actions + '; editor:draw()')
        canvas.save(out / f'{name}-{width}.png')
        if width == 120:
            canvas.save(root / 'wiki' / f'{name}.png')
    # Traverse all form pages and selectors on each supported resolution.
    lua.execute("""
      for tab=1,4 do editor:act('tab:'..tab)
        for i in ipairs(editor:objects()) do editor:act('select:'..i)
          local object=editor:object()
          if object.kind=='box' then editor:draw()
          elseif object.kind=='fluids' then
            editor:draw(); for page=1,editor.fluidPages do editor.fluidPage=page; editor:draw() end
          else
            local count=#editor:form()
            for first=1,math.max(1,count),editor.perPage do editor.offset=first; editor:draw() end
          end
        end
      end
    """)
print(f'PASS rendered actual GUI at 80x25, 120x38, 160x50: {out}')
