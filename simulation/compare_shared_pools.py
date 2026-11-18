"""Replay the same stargate through the checked-out controller for each bee pool."""
import argparse
from concurrent.futures import ProcessPoolExecutor
import itertools
import json
from pathlib import Path
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
POOLS = {49: [6] * 7 + [3, 3, 1], 54: [6] * 7 + [4, 4, 4]}


def simulate(job):
    from lupa.lua53 import LuaRuntime

    arrays, cells, scenario, early_start = job
    order, gap = ('reverse', 0) if scenario == 'reverse' else ('name', 60 if scenario == 'upstream60' else 0)
    vm = LuaRuntime(unpack_returned_tuples=True)
    vm.globals().ROOT = ROOT.as_posix() + '/'
    case = json.loads((HERE / 'stargate_workload.json').read_text(encoding='utf-8'))
    if order == 'reverse':
        case['recipes'].reverse()
    bench = vm.execute("return dofile(ROOT .. 'simulation/stargate_shared_pool.lua')")
    options = dict(arrays=arrays, pool=POOLS[cells], syncSeconds=0.05, supplyGap=gap, earlyStart=early_start)
    run = bench.run(vm.table_from(case, recursive=True), vm.table_from(options, recursive=True))
    assert run.cellCount == cells and run.totalCrafts == 26521811 and run.completedRecipes == 69
    assert run.singularityBatches >= 1
    arrivals = sorted(job.arrival for _, job in run.jobs.items())
    assert len(arrivals) == run.completedRecipes and all(b - a >= gap - 1e-6 for a, b in zip(arrivals, arrivals[1:]))
    row = dict(arrays=arrays, cells=cells, pool=POOLS[cells], order=order, supply_gap=gap, seconds=run.seconds,
               bee_wait_seconds=run.waitSeconds, sync_calls=run.syncCalls, moves=run.moves,
               crafts=run.totalCrafts, recipes=run.completedRecipes, singularity_batches=run.singularityBatches,
               wait_by_tier=[run.waits[i] or 0 for i in range(1, 11)])
    assert abs(sum(row['wait_by_tier']) - run.waitSeconds) < 0.001
    row['key_jobs'] = {key: dict(arrays=len(list(run.jobs[key].arrays)),
                                  start=round(run.jobs[key].arrival - arrivals[0], 2),
                                  finish=round(run.jobs[key].finish - arrivals[0], 2))
                       for key in ('StargateMaterialMesh', 'StargateFramePart', 'astralArrayFabricator')}
    row.update(early_start=early_start, early_batches=run.earlyStarts, fast_batches=run.fastBatches)
    print(f"{arrays} arrays, {cells} cells, {scenario}, early={early_start}: {run.seconds:.2f}s, {run.earlyStarts} switched", flush=True)
    return row


def check_early_start():
    """Keep T2 busy while another array receives a short T1, then T2 recipe."""
    from lupa.lua53 import LuaRuntime

    recipes = [
        dict(id='hold-T2', count=1, dependencies=[], unit={'entangled_neutronium': 1},
             steps=[dict(start=0, finish=30720000, tier=2)]),
        dict(id='T1-then-T2', count=1, dependencies=[], unit={'entangled_neutronium': 1},
             steps=[dict(start=0, finish=40, tier=1), dict(start=40, finish=80, tier=2)]),
    ]
    vm = LuaRuntime(unpack_returned_tuples=True)
    vm.globals().ROOT = ROOT.as_posix() + '/'
    bench = vm.execute("return dofile(ROOT .. 'simulation/stargate_shared_pool.lua')")
    starts = []
    for early in (False, True):
        opt = dict(arrays=2, pool=[1, 1] + [0] * 8, syncSeconds=0.05, supplyGap=3, earlyStart=early)
        run = bench.run(vm.table_from({'recipes': recipes}, recursive=True), vm.table_from(opt, recursive=True))
        job = run.jobs['T1-then-T2']
        assert run.totalCrafts == 2 and run.earlyStarts == int(early)
        assert job.firstTier == (1 if early else 2)
        starts.append(job.firstProgress - job.arrival)
    assert starts[1] < starts[0]
    print(f'Positive control: time from arrival to first progress {starts[0]:.2f}s -> {starts[1]:.2f}s', flush=True)


if __name__ == '__main__':
    sys.path.insert(0, str(ROOT / '.testdeps'))
    parser = argparse.ArgumentParser()
    parser.add_argument('--arrays', nargs='+', type=int, default=[6, 10, 12, 16])
    parser.add_argument('--scenario', nargs='+', choices=['name', 'reverse', 'upstream60'],
                        default=['name', 'reverse', 'upstream60'])
    parser.add_argument('--workers', type=int, default=4)
    parser.add_argument('--compare-early', action='store_true')
    args = parser.parse_args()
    if args.compare_early:
        check_early_start()
    jobs = itertools.product(args.arrays, POOLS, args.scenario, (False, True) if args.compare_early else (False,))
    with ProcessPoolExecutor(max_workers=args.workers) as pool:
        rows = list(pool.map(simulate, jobs))
    out = HERE / ('early-start-results.json' if args.compare_early else 'shared-pool-results.json')
    out.write_text(json.dumps(rows, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')
    print(out)
