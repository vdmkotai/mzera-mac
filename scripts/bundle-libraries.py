#!/usr/bin/env python3
"""Copy the exact local FFmpeg dylib closure into our app and rewrite install names."""
from pathlib import Path
import shutil
import subprocess
import sys
import re

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

def resolve_dependency(dependency, source):
    if dependency.startswith(('/usr/lib/', '/System/Library/')):
        return None
    if dependency.startswith('/opt/homebrew/'):
        return Path(dependency).resolve(strict=True)
    def expand(value):
        return Path(value.replace('@loader_path', str(source.parent)).replace('@executable_path', str(executable.parent)))
    if dependency.startswith('@loader_path/'):
        return expand(dependency).resolve(strict=True)
    if dependency.startswith('@rpath/'):
        suffix = dependency[len('@rpath/'):]
        rpaths = re.findall(r'cmd LC_RPATH\s+cmdsize \d+\s+path (.*?) \(offset', run('otool', '-l', str(source)))
        candidates = [expand(p) / suffix for p in rpaths] + [source.parent / suffix]
        for candidate in candidates:
            if candidate.is_file():
                return candidate.resolve(strict=True)
    raise RuntimeError(f'Cannot resolve {dependency} referenced by {source}')

def visit(path,source=None):
    if path in processed:return
    processed.add(path)
    original=dependencies(source or path)
    for dependency in original:
        src=resolve_dependency(dependency, source or path)
        if src is None:continue
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
    for dependency in dependencies(path):
        if dependency.startswith(('/usr/lib/', '/System/Library/')):continue
        if dependency.startswith('@rpath/') and (frameworks/dependency[len('@rpath/'):]).is_file():continue
        raise RuntimeError(f'Unbundled dependency {dependency} in {path}')
print(f'Bundled {len(copied)} libraries ({sum((frameworks/n).stat().st_size for n in copied)/1048576:.1f} MiB)')
