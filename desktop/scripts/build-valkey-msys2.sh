#!/usr/bin/env bash
# Build valkey-server.exe for Windows inside the MSYS2 "msys" environment
# (Valkey needs POSIX fork/signals, which the MSYS2 runtime provides). The exe
# and msys-2.0.dll it depends on are written to desktop/build/valkey.
#
# Run from an MSYS2 MSYS shell with: pacman -S --needed gcc make pkgconf
set -euo pipefail

DESKTOP="$(cd "$(dirname "$0")/.." && pwd)"
VALKEY_VERSION="${VALKEY_VERSION:-8.1.4}"
WORK="$DESKTOP/build/valkey-src"
OUT="$DESKTOP/build/valkey"

mkdir -p "$WORK"
cd "$WORK"
[ -f valkey.tar.gz ] || curl --fail --location --retry 3 -o valkey.tar.gz \
  "https://github.com/valkey-io/valkey/archive/refs/tags/$VALKEY_VERSION.tar.gz"
rm -rf valkey && mkdir valkey
tar -xzf valkey.tar.gz -C valkey --strip-components 1

# MSYS2 hides dladdr()/Dl_info behind __GNU_VISIBLE; Valkey's crash reporter uses them.
sed -i 's/__GNU_VISIBLE/1/' /usr/include/dlfcn.h

(cd valkey && make -j"$(nproc)" BUILD_TLS=no MALLOC=libc CFLAGS="-Wno-char-subscripts" valkey-server)

rm -rf "$OUT" && mkdir -p "$OUT"
cp valkey/src/valkey-server.exe "$OUT/"
# Ship every MSYS2 runtime DLL the server loads (msys-2.0.dll, and e.g. the
# gcc runtime), so it starts on machines without MSYS2.
ldd "$OUT/valkey-server.exe"
ldd "$OUT/valkey-server.exe" | awk '$3 ~ /^\/usr\/bin\// { print $3 }' | sort -u | while read -r dll; do
  cp "$dll" "$OUT/"
done
ls -la "$OUT"
"$OUT/valkey-server.exe" --version
