#!/usr/bin/env python3
import os, random, struct, subprocess, sys, tempfile
from pathlib import Path
exe = str(Path(sys.argv[1]).resolve())
def run(*args):
    p = subprocess.run([exe, *map(str, args)], capture_output=True, timeout=90)
    if p.returncode: raise RuntimeError(p.stdout.decode(errors='replace') + p.stderr.decode(errors='replace'))
    return p.stdout
with tempfile.TemporaryDirectory() as tmp:
    tmp = Path(tmp)
    rng = random.Random(47)
    samples = {
        'empty': b'', 'tiny': b'x', 'tail': rng.randbytes(65535),
        'boundary': rng.randbytes(65536), 'long': rng.randbytes((2 << 20) + 1),
        'text': b'A repeated sentence with words.\n' * 8192,
        'records': b''.join(struct.pack('<IffI', i, i/1000, i/500, i//128) for i in range(16384)),
    }
    count = 0
    for name, data in samples.items():
        source = tmp / name; source.write_bytes(data)
        for method in ['LZMA2:d=1m', 'PPMd:o=16:mem=16m']:
            for r in [3, 16, 255, 256]:
                archive = tmp / (str(count) + '.7z')
                run('a', archive, source, '-m0=Transpose:'+str(r), '-m1='+method, '-mx=3', '-bso0')
                assert run('x', '-so', archive) == data, (name, method, r)
                run('t', archive, '-bso0')
                count += 1
    # The GUI prepass, including the identity fallback and a solid folder.
    for method in ['LZMA2:d=1m', 'PPMd:o=16:mem=16m']:
        archive = tmp / ('auto' + str(count) + '.7z')
        run('a', archive, tmp/'records', tmp/'text', '-m0=Transpose:a=3', '-m1='+method, '-ms=on', '-bso0')
        for name in ['records','text']:
            assert run('x', '-so', archive, name) == samples[name]
        count += 1
    # Existing unrelated filters still work after increasing the minimum buffer.
    archive = tmp/'aes.7z'
    run('a', archive, tmp/'long', '-ptranspose-test', '-mhe=on', '-m0=BCJ', '-m1=LZMA2:d=1m', '-bso0')
    assert run('x', '-so', archive, '-ptranspose-test') == samples['long']
    print(f'{count} Transpose archives + AES/BCJ archive passed (byte-identical extraction)')
