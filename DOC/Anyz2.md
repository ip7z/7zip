# anyz2 in the integrated 7-Zip fork

Transpose is built into this fork's `7z.dll` / `7z.so`. Ship the matching
`7z.exe`, `7zG.exe`, `7zFM.exe` and `7z.dll` together. No codec plugin is needed.
The upstream discussion is https://github.com/ip7z/7zip/pull/245; upstream is
not currently accepting new built-in filters, so this remains a maintained fork.

In **Add to Archive**, select **Preprocessing → anyz2 (Transpose)** and choose
**LZMA2**, **LZMA** or **PPMd** independently under **Compression method**.
The GUI puts Transpose at method 0, the chosen compressor at method 1, and
sends dictionary and word/order settings to method 1. No manual parameters
are needed. The filter choice is saved per archive format; the former
`Method=anyz2` preference migrates to LZMA2 with Transpose enabled.
Preprocessing is disabled for other formats, Store, SFX and compressors for
which the prepass has no matching probe. SFX modules have not been extended.

The prepass measures candidates against an untransformed baseline, using the
following coder's family (PPMd or LZMA). Its settings can differ from the actual
compression settings; it examines at most 64 MiB of the largest input file.
A heterogeneous solid folder can differ from that file. Therefore this is a
selection heuristic, not a guarantee that every final archive is smaller.
The Python arbiter in `~/tabz/anyz2` is a separate, broader experiment; the GUI
filter does not run all of its external compressors or select codecs per block.

## Format and buffering

Igor Pavlov allocated developer range `04F713xx`; Transpose uses `04F71301`.
It is still registered with `REGISTER_FILTER_E`, not as a compressor.
Exactly two property bytes encode `R-1` and `log2(records per block)`.
The byte block length is `R << step`, limited to 64 KiB. Choosing a power-of-two
record count removes division from decoding. It can give a smaller block than
the previous arbitrary record count. All incomplete final blocks remain raw.

`CFilterCoder` now guarantees a minimum 64 KiB buffer for all of its Code,
Read and Write paths. This matters because the upstream 4 KiB minimum is too
small for Transpose, especially when decoding with a different buffer size.
The usual 2 MiB default is unchanged. The filter never requests AES padding.

The new ID intentionally does not decode the experimental `0C` or
`3FE2B7E19B8A0001` formats. Keep the previous fork binaries for those archives;
the original `_o` build directories are preserved by the build script.
Do not reinterpret old archives with the new two-byte properties.

## Build and validation

From the repository root:

```sh
python3 tests/build_anyz2.py
python3 tests/run_transpose.py
python3 tests/build_anyz2.py --windows
```

Windows cross builds require mingw-w64 and the header aliases described in
`mingw-shim/README.md`. Outputs use `_linux` and `_anyz2`, preserving older builds.
Put the Linux console binary and `7z.so` together, then run:

```sh
python3 tests/transpose_archives.py /path/to/7z
```

`transpose_streams.cpp` checks 12,288 combinations against an independently
constructed transposition, covering R=1..256, exact and partial blocks,
short input/output operations, all three FilterCoder paths, mismatched buffer
sizes including requests for 4 KiB, and malformed properties.
`transpose_archives.py` checks 58 Transpose archives, including PPMd, LZMA2,
prepass and solid archives, plus an AES/BCJ regression archive.
`transpose_gui.cpp` drives the real Windows dialog and creates an archive.
Compile it with mingw-w64 and run beside the Windows binaries with a
`gui-input.bin` fixture. It can also run under Wine/Xvfb.

When updating from upstream, review changes to `CFilterCoder`, coder properties,
GUI property routing and codec IDs, rebuild all four Windows binaries and rerun
these checks. A successful upstream merge alone does not verify this fork.
