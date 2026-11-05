"""Run in local Lua 5.2 and 5.3, the OpenComputers runtime versions."""
from pathlib import Path
import sys
import unicodedata
import os

root = Path(__file__).resolve().parents[1]
(root / '.tmp').mkdir(exist_ok=True)
sys.path.insert(0, str(root / '.testdeps'))
for version in ('lua52', 'lua53'):
    module = __import__('lupa.' + version, fromlist=['LuaRuntime'])
    lua = module.LuaRuntime(unpack_returned_tuples=True)
    lua.globals().ROOT = root.as_posix() + '/'
    lua.globals().utf_len = len
    lua.globals().utf_sub = lambda s, first, last=None: s[first - 1:last if last is None or last >= 0 else len(s) + last + 1]
    lua.globals().utf_width = lambda s: sum(2 if unicodedata.east_asian_width(c) in ('W', 'F') else 1 for c in s)
    lua.globals().utf_char = chr
    def rename_file(source, target):
        source_path, target_path = Path(source).resolve(), Path(target).resolve()
        assert source_path.is_relative_to(root / '.tmp') and target_path.is_relative_to(root / '.tmp')
        os.replace(source_path, target_path)
        return True
    lua.globals().rename_file = rename_file
    for path in root.glob('*.lua'):
        lua.execute('assert(loadfile(...))', path.as_posix())
    print(version + ': all program files parse', flush=True)
    lua.execute('dofile(ROOT .. "tests/precache.lua")')
    lua.execute('dofile(ROOT .. "tests/refill_restart.lua")')
    lua.execute('dofile(ROOT .. "tests/audit_fixes.lua")')
    lua.execute('dofile(ROOT .. "tests/runtime_progress.lua")')
    lua.execute('dofile(ROOT .. "tests/responsiveness.lua")')
    lua.execute('dofile(ROOT .. "tests/processing.lua")')
    lua.execute('dofile(ROOT .. "tests/bee_advancement.lua")')
    lua.execute('dofile(ROOT .. "tests/bee_transfers.lua")')
    lua.execute('dofile(ROOT .. "tests/bee_reuse.lua")')
    lua.execute('dofile(ROOT .. "tests/mature_intake.lua")')
    lua.execute('dofile(ROOT .. "tests/intake_response.lua")')
    lua.execute('dofile(ROOT .. "tests/mature_flow.lua")')
    lua.execute('dofile(ROOT .. "tests/call_policy.lua")')
    lua.execute('dofile(ROOT .. "tests/segmented.lua")')
    lua.execute('dofile(ROOT .. "tests/recipe_reuse.lua")')
    lua.execute('dofile(ROOT .. "tests/recipe_clear.lua")')
    lua.execute('dofile(ROOT .. "tests/save_safety.lua")')
    lua.execute('dofile(ROOT .. "tests/simplified.lua")')
    lua.execute('dofile(ROOT .. "tests/singularities.lua")')
    lua.execute('dofile(ROOT .. "tests/spec.lua")')
