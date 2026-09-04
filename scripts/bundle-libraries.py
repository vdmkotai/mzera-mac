#!/usr/bin/env python3
"""Copy the exact local FFmpeg dylib closure into our app and rewrite install names."""
from pathlib import Path
import shutil
import subprocess
import sys

app=Path(sys.argv[1]).resolve()
frameworks=app/'Contents/Frameworks'
frameworks.mkdir(parents=True,exist_ok=True)
executable=app/'Contents/MacOS/Mzera'
copied={}
processed=set()

def run(*args):
    return subprocess.check_output(args,text=True,stderr=subprocess.STDOUT)

def dependencies(path):
    return [line.strip().split(' (compatibility')[0] for line in run('otool','-L',str(path)).splitlines()[1:]]

def visit(path,source=None):
    if path in processed:return
    processed.add(path)
    original=dependencies(source or path)
    for dependency in original:
        if not dependency.startswith('/opt/homebrew/'):continue
        src=Path(dependency).resolve(strict=True)
        name=Path(dependency).name
        dst=frameworks/name
        if name in copied and copied[name]!=src:
            raise RuntimeError(f'Conflicting library basename: {name}')
        if name not in copied:
            copied[name]=src
            shutil.copy2(src,dst)
            dst.chmod(0o755)
            visit(dst,src)
            run('install_name_tool','-id','@rpath/'+name,str(dst))
        run('install_name_tool','-change',dependency,'@rpath/'+name,str(path))

visit(executable)
run('install_name_tool','-add_rpath','@executable_path/../Frameworks',str(executable))
for name in copied:
    run('codesign','--force','--sign','-',str(frameworks/name))
for path in [executable]+[frameworks/name for name in copied]:
    if any(d.startswith('/opt/homebrew/') for d in dependencies(path)):
        raise RuntimeError(f'Unbundled dependency in {path}')
print(f'Bundled {len(copied)} libraries ({sum((frameworks/n).stat().st_size for n in copied)/1048576:.1f} MiB)')
