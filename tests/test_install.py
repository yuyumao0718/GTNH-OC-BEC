"""Test the downloaded standalone installer on both supported Lua runtimes."""
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from tempfile import TemporaryDirectory
from threading import Thread
from urllib.request import urlopen
import sys
from zipfile import ZipFile

root = Path(__file__).resolve().parents[1]
(root / '.tmp').mkdir(exist_ok=True)
sys.path.insert(0, str(root / '.testdeps'))
expected = {p.name: p.read_text(encoding='utf-8') for p in root.glob('*.lua')}

class QuietHandler(SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass

server = ThreadingHTTPServer(('127.0.0.1', 0), partial(QuietHandler, directory=str(root / 'install')))
thread = Thread(target=server.serve_forever, daemon=True)
thread.start()
try:
    with urlopen(f'http://127.0.0.1:{server.server_port}/multi_install.lua', timeout=5) as response:
        downloaded = response.read()
    assert downloaded == (root / 'install/multi_install.lua').read_bytes()
finally:
    server.shutdown()
    server.server_close()
    thread.join()
print('PASS local HTTP download matches standalone installer')
with ZipFile(root / 'multi-array-openos.zip') as archive:
    for name in archive.namelist():
        relative = name.removeprefix('multi-array/')
        assert archive.read(name) == (root / relative).read_bytes(), name
print('PASS ZIP payloads match the source files and standalone installer')

for version in ('lua52', 'lua53'):
    runtime = __import__('lupa.' + version, fromlist=['LuaRuntime']).LuaRuntime(unpack_returned_tuples=True)
    with TemporaryDirectory(prefix='install-', dir=root / '.tmp') as tmp:
        dest = Path(tmp) / 'program'
        def checked(path):
            p = Path(path).resolve()
            assert p.is_relative_to(Path(tmp).resolve()), p
            return p
        def mkdir(path):
            checked(path).mkdir(parents=True, exist_ok=True)
            return True
        runtime.globals().is_dir = lambda path: checked(path).is_dir()
        runtime.globals().mkdir = mkdir
        def rename(source, target):
            checked(source).replace(checked(target))
            return True
        runtime.globals().rename_file = rename
        runtime.execute('''
          package.preload.filesystem=function() return {isDirectory=is_dir,makeDirectory=mkdir} end
          package.preload.shell=function() return {resolve=function(path) return path end} end
          -- OpenOS close forwards the component callback, which returns no values.
          local nativeOpen=io.open
          io.open=function(path,mode)
            local f,reason=nativeOpen(path,mode)
            if not f then return nil,reason end
            return {
              read=function(_,...) return f:read(...) end,
              write=function(_,...) return f:write(...) end,
              flush=function() return f:flush() end,
              close=function() assert(f:close()) end
            }
          end
        ''')
        installer = runtime.execute('return assert(load(...,"=downloaded installer","t"))', downloaded.decode('utf-8'))
        installer(dest.as_posix())
        for name, content in expected.items():
            assert (dest / name).read_text(encoding='utf-8') == content, name
            runtime.execute('assert(loadfile(...))', (dest / name).as_posix())
        runtime.globals().installed_dir = dest.as_posix()
        runtime.execute('''
          local fs=require('filesystem')
          fs.path=function(path) return assert(path:match('^(.*[/])')) end
          require('shell').resolve=function(path)
            return path=='bec_multi.lua' and installed_dir..'/'..path or path
          end
          for _,name in ipairs({'component','computer','event','serialization','unicode','term'}) do
            package.preload[name]=function() return {} end
          end
          require('computer').realTime=os.clock
          assert(loadfile(installed_dir..'/bec_multi.lua'))('help')
          fs.rename=rename_file
          local serial=require('serialization')
          serial.serialize=tostring
          serial.unserialize=function(text) return assert(load('return '..text))() end
          local store=dofile(installed_dir..'/ma_store.lua').new(installed_dir..'/',fs,serial)
          store.write('test-state',{count=9007199254740991,label=string.rep('installed',1000)})
          local saved=store.read('test-state')
          assert(saved.count==9007199254740991 and saved.label==string.rep('installed',1000))
        ''')
        for name in ('multi.cfg', 'multi.state', 'multi.setup', 'unrelated.txt'):
            (dest / name).write_text('keep me', encoding='utf-8')
        (dest / 'ma_core.lua').write_text('-- older program', encoding='utf-8')
        installer(dest.as_posix())
        for name, content in expected.items():
            assert (dest / name).read_text(encoding='utf-8') == content, name
        for name in ('multi.cfg', 'multi.state', 'multi.setup', 'unrelated.txt'):
            assert (dest / name).read_text(encoding='utf-8') == 'keep me'
        print(f'PASS {version}: fresh install, all modules parse, installed help entry, overwrite, exact payloads, config/state preservation')
