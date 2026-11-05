from pathlib import Path
import importlib,json,sys
root=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(root/'.testdeps'))
rows=[]
for version in ('lua52','lua53'):
    vm=importlib.import_module('lupa.'+version).LuaRuntime(unpack_returned_tuples=True)
    vm.globals().ROOT=root.as_posix()+'/'
    print(version,flush=True)
    result=vm.execute('return dofile(ROOT.."tests/save_scale.lua")')
    for _,row in result.items():
        value=dict(row.items());value['lua']=version;rows.append(value)
(root/'simulation/save-scale-results.json').write_text(json.dumps(rows,indent=2)+'\n',encoding='utf-8')
