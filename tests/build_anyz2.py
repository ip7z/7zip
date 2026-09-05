#!/usr/bin/env python3
"""Build the integrated fork; output goes to separate directories, preserving old builds."""
import argparse, subprocess
from pathlib import Path
r = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser()
p.add_argument('--windows', action='store_true')
p.add_argument('-j', default='4')
a = p.parse_args()
args = ['make', '-f', 'makefile.gcc', '-j'+a.j, 'O='+('_anyz2' if a.windows else '_linux')]
if a.windows:
    args += ['IS_MINGW=1', 'MSYSTEM=MINGW64', 'CC=x86_64-w64-mingw32-gcc', 'CXX=x86_64-w64-mingw32-g++',
             'RC=x86_64-w64-mingw32-windres', 'RFLAGS=-I'+str(r/'mingw-shim')+' -i',
             'CFLAGS_BASE2=-I'+str(r/'mingw-shim'), 'CXXFLAGS_BASE2=-I'+str(r/'mingw-shim'),
             'CXX_WARN_FLAGS=-Wno-unused-value -Wno-cast-function-type']
paths = ['Bundles/Format7zF', 'UI/Console']
if a.windows: paths += ['UI/GUI', 'UI/FileManager']
for path in paths:
    subprocess.run(args, cwd=r/'CPP/7zip'/path, check=True)
