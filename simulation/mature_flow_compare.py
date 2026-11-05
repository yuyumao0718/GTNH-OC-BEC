"""Compare the real controllers with timed mock hardware, including overlapping intake."""
from pathlib import Path
import argparse
import importlib
import json
import re
import subprocess
import sys
import time

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / '.testdeps'))
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--baseline', required=True, help='Git revision before the intake change')
parser.add_argument('--installer', type=Path, default=Path('D:/Users/fishcat/Downloads/cache_install.lua'))
args = parser.parse_args()
source = args.installer.read_text(encoding='utf-8-sig')
reference = root / '.tmp/user-cache-reference'
reference.mkdir(parents=True, exist_ok=True)
for name, _, code in re.findall(r'put\("([^"/\\]+)",\[(=*)\[(.*?)\]\2\]\)', source, re.S):
    for token, value in {'F': 'function', 'L': 'local ', 'R': 'return ', 'S': 'self.'}.items():
        code = code.replace('~' + token, value)
    (reference / name).write_text(code, encoding='utf-8')
baseline = subprocess.check_output(['git', 'show', args.baseline + ':ma_core.lua'], cwd=root).decode('utf-8')

instrument = r'''
function(w, overlap)
    local m, e = w.metrics, w.e
    m.beeWait = 0
    m.switches = {}
    m.maxRunGap, m.maxRunGapDuringIntake = 0, 0
    local waits, requests, sampled, starts = {}, {}, {}, {}
    local borrow, bees, array, support = e.borrow, e.bees, e.array, e.poolSupports
    local released = not overlap
    e.poolSupports = function(self, a, meta)
        return (released or a.address == 'a1') and support(self, a, meta)
    end
    e.borrow = function(self, a, s, tier)
        local ok = borrow(self, a, s, tier)
        if ok and waits[a.address] then
            m.beeWait = m.beeWait + (w.time - waits[a.address]) / 20
            waits[a.address] = nil
        elseif not ok then
            waits[a.address] = waits[a.address] or w.time
        end
        return ok
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
            if sampled[a.address] then
                local gap = (w.time - sampled[a.address]) / 20
                m.maxRunGap = math.max(m.maxRunGap, gap)
                if self.s.admission then
                    m.maxRunGapDuringIntake = math.max(m.maxRunGapDuringIntake, gap)
                end
            end
            sampled[a.address] = w.time
        else
            sampled[a.address] = nil
        end
        local result = array(self, a)
        b = self.s.arrays[a.address].batch
        if b and b.phase == 'run' then
            released = true
            if not starts[b] then
                starts[b] = true
                w.event('start', a.address)
            end
        end
        return result
    end
end
'''

rows = []
for version in ('lua52', 'lua53'):
    module = importlib.import_module('lupa.' + version)
    for kind in ('legacy', 'before', 'after'):
        vm = module.LuaRuntime(unpack_returned_tuples=True)
        vm.globals().ROOT = root.as_posix() + '/'
        if kind == 'before':
            vm.globals().baseline_core = baseline
            vm.execute("""
                local original = dofile
                dofile = function(path)
                    if path == ROOT .. 'ma_core.lua' then
                        return assert(load(baseline_core, '@baseline/ma_core.lua'))()
                    end
                    return original(path)
                end
            """)
        bench = vm.execute("return dofile(ROOT .. 'simulation/user_cache_compare.lua')")
        attach = vm.eval(instrument)
        for case in ('shielding', 'fast', 'overlap'):
            for arrays in ((1,) if kind == 'legacy' else (1, 2, 6, 10, 30)):
                if case == 'overlap' and arrays == 1:
                    continue
                opts = dict(arrays=arrays, syncTicks=1, ioTicks=1)
                if case == 'fast':
                    opts.update(count=arrays * 16, tiers=[4], length=20000, parallelLimit=1)
                else:
                    opts.update(count=(1 if case == 'overlap' else arrays) * 16 * 3840,
                                tiers=[4, 1, 1, 3, 1], length=1200, jobs=2 if case == 'overlap' else 1)
                opts['tiers'] = vm.table_from(opts['tiers'])
                started = time.perf_counter()
                world = (bench.legacy(vm.table_from(opts)) if kind == 'legacy' else
                         bench.current(vm.table_from(opts), lambda w: attach(w, case == 'overlap')))
                cpu_ms = (time.perf_counter() - started) * 1000
                m = world.metrics
                intake, starts, spread, ready_wait = {}, {}, [], []
                for _, event in m.events.items():
                    if event.kind == 'intake':
                        array = event.detail.split(':', 1)[0]
                        intake.setdefault(array, []).append(event.tick / 20)
                    elif event.kind == 'start':
                        starts.setdefault(event.detail, []).append(event.tick / 20)
                for array, times in intake.items():
                    for offset in range(0, len(times), 16):
                        part = times[offset:offset + 16]
                        spread.append(max(part) - min(part))
                        match = starts.get(array, [])
                        if len(match) > offset // 16:
                            ready_wait.append(match[offset // 16] - max(part))
                switches = list(m.switches.values()) if m.switches else []
                row = dict(lua=version, kind=kind, case=case, arrays=arrays,
                           simulated_seconds=(m.lastOutput - m.firstInput) / 20,
                           first_intake_seconds=min(min(t) for t in intake.values()) - m.firstInput / 20,
                           first_work_seconds=(m.firstWork - m.firstInput) / 20,
                           max_intake_spread_seconds=max(spread),
                           max_intake_to_start_seconds=max(ready_wait, default=None),
                           bee_wait_array_seconds=m.beeWait,
                           max_bee_request_to_ready_seconds=max(switches, default=None),
                           max_run_gap_seconds=m.maxRunGap,
                           max_run_gap_during_intake_seconds=m.maxRunGapDuringIntake,
                           component_calls=sum(m.callsAtOutput.values()), saves=m.savesAtOutput,
                           local_cpu_ms=cpu_ms)
                rows.append(row)
                print(json.dumps(row, ensure_ascii=False), flush=True)

result = dict(baseline=args.baseline,
              assumptions='20 TPS; synchronous callbacks 1 tick; ME-IO 1 tick; direct callbacks, GPU and disk wall time not charged. '
                          'Overlap: first order eligible only for a1, then other arrays become eligible while a1 runs. '
                          'Bee wait is summed array-seconds; switch timing includes pool contention. '
                          'Legacy start phase is not instrumented. This is not in-game wall time.',
              rows=rows)
(root / 'simulation/mature-flow-comparison.json').write_text(
    json.dumps(result, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
