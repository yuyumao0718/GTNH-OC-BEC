"""Compare actual controllers with explicit OC scheduling, GPU and save costs."""
from pathlib import Path
import argparse
import importlib
import json
import re
import subprocess
import sys
import time
import unicodedata

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / '.testdeps'))
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--baseline', default='04842b2')
parser.add_argument('--installer', type=Path, default=Path('D:/Users/fishcat/Downloads/cache_install.lua'))
parser.add_argument('--lua', default='lua53', choices=['lua52', 'lua53'])
parser.add_argument('--arrays', nargs='+', type=int, default=[1, 6, 10, 30])
parser.add_argument('--cases', nargs='+', default=['ordinary', 'fast', 'overlap'])
args = parser.parse_args()
reference = root / '.tmp/user-cache-reference'
reference.mkdir(parents=True, exist_ok=True)
for name, _, code in re.findall(
        r'put\("([^"/\\]+)",\[(=*)\[(.*?)\]\2\]\)',
        args.installer.read_text(encoding='utf-8-sig'), re.S):
    for token, value in {'F': 'function', 'L': 'local ', 'R': 'return ', 'S': 'self.'}.items():
        code = code.replace('~' + token, value)
    (reference / name).write_text(code, encoding='utf-8')
LuaRuntime = importlib.import_module('lupa.' + args.lua).LuaRuntime
sources = {
    p.name: subprocess.check_output(['git', 'show', f'{args.baseline}:{p.name}'], cwd=root).decode('utf-8')
    for p in root.glob('*.lua')
}
source = (root / 'simulation/user_cache_compare.lua').read_text(encoding='utf-8')
source = source.replace(
    "    w.share(cells)",
    """    if opt.sets and opt.sets > 1 then
        cells = {}
        for tier = 1, 10 do
            for _ = 1, opt.sets do
                cells[#cells + 1] = {
                    tier = tier, box = math.floor(#cells / 27) + 1,
                    slot = #cells % 27 + 1, count = 30720,
                }
            end
        end
    end
    w.share(cells)""",
)
source = source.replace(
    "w.elapse(\n                    math.max((opt.syncTicks or 0) == 0 and 1 or 0, math.ceil((seconds or 0) * 20))\n                )",
    "w.metrics.pulses = (w.metrics.pulses or 0) + 1; w.elapsed(math.max(seconds or 0, 0.012))",
)
source = source.replace(
    "    env.require = function(name)",
    """    modules.component.gpu = TIMED_GPU(w)
    modules.component.isAvailable = function(name) return name == 'gpu' end
    modules.unicode = UNICODE
    env.require = function(name)""",
)
source = source.replace(
    "m.calls = {}\n        m.saves = 0", "m.calls = {}; m.saves = 0; m.pulses = 0; m.gpu = 0"
)
instrument = r'''
function(w, overlap)
    local e, m = w.e, w.metrics
    m.pulses, m.gpu, m.maxRunGap, m.maxRunGapDuringIntake = 0, 0, 0, 0
    m.switches = {}
    local last, requests = {}, {}
    local released = not overlap
    local support, array, bees = e.poolSupports, e.array, e.bees
    e.poolSupports = function(self, a, meta)
        return (released or a.address == 'a1') and support(self, a, meta)
    end
    e.bees = function(self, a, s, want)
        local request = requests[a.address]
        if want and w.arrays[a.address].tier ~= want and (not request or request.tier ~= want) then
            request = { tier = want, at = w.time }
            requests[a.address] = request
        end
        local ok = bees(self, a, s, want)
        if ok and want and request and request.tier == want then
            m.switches[#m.switches + 1] = (w.time - request.at) / 20
            requests[a.address] = nil
        end
        return ok
    end
    e.array = function(self, a)
        local b = self.s.arrays[a.address].batch
        if b and b.phase == 'run' then
            if last[a.address] then
                local gap = (w.time - last[a.address]) / 20
                m.maxRunGap = math.max(m.maxRunGap, gap)
                if self.s.admission then
                    m.maxRunGapDuringIntake = math.max(m.maxRunGapDuringIntake, gap)
                end
            end
            last[a.address] = w.time
        else
            last[a.address] = nil
        end
        local result = array(self, a)
        b = self.s.arrays[a.address].batch
        if b and b.phase == 'run' then released = true end
        return result
    end
    local G = dofile(ROOT .. 'ma_gui.lua')
    local gui = G.new(TIMED_GPU(w), {}, UNICODE, dofile(ROOT .. 'ma_config.lua'), e.M)
    local drawn = -math.huge
    local function draw()
        if w.time / 20 - drawn >= 1 then
            gui:runtime(e, w.r)
            drawn = w.time / 20
        end
    end
    e.io.pulse = function()
        m.pulses = m.pulses + 1
        w.elapsed(0.012)
        draw()
        return false
    end
    local tick = w.tick
    w.tick = function()
        -- The existing world tick supplies the main loop's 0.05 second wait.
        draw()
        return tick()
    end
end
'''
rows = []
for case in args.cases:
    for kind in ('mature', 'before', 'after'):
        for arrays in ([1] if kind == 'mature' else args.arrays):
            if case == 'overlap' and arrays == 1:
                continue
            vm = LuaRuntime(unpack_returned_tuples=True)
            vm.globals().ROOT = root.as_posix() + '/'
            vm.globals().utf_len = len
            vm.globals().utf_sub = lambda s, a, b=None: s[a - 1:b if b is None or b >= 0 else len(s) + b + 1]
            vm.globals().utf_width = lambda s: sum(2 if unicodedata.east_asian_width(c) in ('W', 'F') else 1 for c in s)
            vm.globals().utf_char = chr
            vm.execute('''
                UNICODE = {len=utf_len, sub=utf_sub, wlen=utf_width, char=utf_char}
                function TIMED_GPU(w)
                    local function call()
                        w.metrics.gpu = (w.metrics.gpu or 0) + 1
                        w.elapsed(0.0001)
                    end
                    return {getResolution=function() return 160,50 end,
                        set=call, setForeground=call, setBackground=call}
                end
            ''')
            if kind == 'before':
                vm.globals().BEFORE = vm.table_from(sources)
                vm.execute('''
                    local original = dofile
                    dofile = function(path)
                        local name = path:sub(#ROOT + 1)
                        if BEFORE[name] then return assert(load(BEFORE[name], '@before/' .. name))() end
                        return original(path)
                    end
                ''')
            bench = vm.execute(source)
            opts = dict(arrays=arrays, sets=arrays, syncTicks=1, ioTicks=1, saveMs=5)
            if case == 'fast':
                opts.update(count=arrays * 16, tiers=[4], length=20000, parallelLimit=1)
            else:
                opts.update(count=(1 if case == 'overlap' else arrays) * 16 * 3840,
                            tiers=[4, 1, 1, 3, 1], length=1200, jobs=2 if case == 'overlap' else 1)
            opts['tiers'] = vm.table_from(opts['tiers'])
            started = time.perf_counter()
            attach = vm.eval(instrument)
            w = bench.legacy(vm.table_from(opts)) if kind == 'mature' else bench.current(
                vm.table_from(opts), lambda world: attach(world, case == 'overlap')
            )
            m = w.metrics
            intakes = {}
            for _, event in m.events.items():
                if event.kind == 'intake':
                    intakes.setdefault(event.detail.split(':')[0], []).append(event.tick / 20)
            spreads = []
            for values in intakes.values():
                for offset in range(0, len(values), 16):
                    part = values[offset:offset + 16]
                    spreads.append(max(part) - min(part))
            switches = list(m.switches.values()) if m.switches else []
            row = dict(kind=kind, case=case, arrays=arrays, lua=args.lua,
                       first_intake=round(min(min(v) for v in intakes.values()) - m.firstInput / 20, 3),
                       first_work=(m.firstWork - m.firstInput) / 20,
                       total=(m.lastOutput - m.firstInput) / 20,
                       max_intake_spread=round(max(spreads), 3),
                       max_run_gap=m.maxRunGap, max_run_gap_during_intake=m.maxRunGapDuringIntake,
                       max_bee_request_to_ready=max(switches, default=None),
                       calls=sum(m.callsAtOutput.values()), saves=m.savesAtOutput,
                       calls_by_method=dict(m.callsAtOutput.items()),
                       event_pulls=m.pulses, gpu_calls=m.gpu,
                       local_cpu_seconds=round(time.perf_counter() - started, 3))
            rows.append(row)
            print(json.dumps(row), flush=True)
for row in rows:
    if row['kind'] != 'after':
        continue
    before = next(r for r in rows if r['kind'] == 'before' and r['case'] == row['case']
                  and r['arrays'] == row['arrays'])
    assert row['max_intake_spread'] <= 0.05, 'whole-array enables stay in one fixture tick'
    assert row['saves'] < before['saves'], 'scan-based recovery should save fewer snapshots'
    if row['case'] == 'ordinary':
        assert row['calls'] < before['calls'], 'ordinary progress throttle should reduce callbacks'
output = root / 'simulation' / f'scan-recovery-{args.lua}.json'
output.write_text(json.dumps(dict(baseline=args.baseline, assumptions={
    'TPS': 20, 'sync_callback_seconds': 0.05, 'ME_IO_ticks': 1,
    'event_reschedule_seconds': 0.012, 'GPU_call_seconds': 0.0001, 'save_seconds': 0.005,
    'GUI': 'actual 160x50 Lua rendering, once per second',
    'pool': 'one full set per tier per array to isolate controller overhead',
    'limits': 'mock hardware; no JVM stalls, OS call budget, upstream delay or real serialization cost',
}, rows=rows), ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
print(output)
