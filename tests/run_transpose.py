#!/usr/bin/env python3
"""Build after Format7zF/_linux, then exercise all FilterCoder streaming paths."""
from pathlib import Path
import subprocess
r = Path(__file__).resolve().parents[1]
o = r / 'CPP/7zip/Bundles/Format7zF/_linux'
names = 'Transpose LzmaEnc LzFind LzFindMt LzFindOpt Threads CpuArch Alloc Ppmd7 Ppmd7Enc StreamUtils MyWindows FilterCoder'.split()
subprocess.run(['g++', '-O2', '-Wall', '-Wextra', '-Werror', '-o', str(r/'tests/transpose_streams'), str(r/'tests/transpose_streams.cpp')] + [str(o/(n+'.o')) for n in names] + ['-lpthread'], check=True)
subprocess.run([str(r/'tests/transpose_streams')], check=True, timeout=120)
