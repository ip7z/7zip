# mingw-shim

Cross-compiling 7-Zip from Linux with mingw-w64 fails on headers the source
includes with Windows casing (`CommCtrl.h`, `ShlObj.h`, ...) while mingw ships
them lowercase. Populate this directory with symlinks and add it as the first
`-I` path:

    for h in $(grep -rhoE '#include <[A-Za-z0-9_]+\.h>' CPP | grep -oE '<[A-Za-z0-9_]+\.h>' \
              | tr -d '<>' | sort -u); do
      l=$(echo "$h" | tr 'A-Z' 'a-z')
      [ "$h" = "$l" ] && continue
      [ -f "/usr/x86_64-w64-mingw32/include/$l" ] && ln -sf "/usr/x86_64-w64-mingw32/include/$l" "mingw-shim/$h"
    done

The symlinks themselves are not committed: they point into the local toolchain.
