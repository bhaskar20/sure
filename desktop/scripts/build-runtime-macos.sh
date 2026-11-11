#!/usr/bin/env bash
# Build the self-contained runtime bundled into the macOS app:
#
#   desktop/runtime/
#     ruby/      Ruby built from source, relocatable (--enable-load-relative),
#                OpenSSL + libyaml linked statically, so it has no Homebrew deps
#     app/       the Rails app with vendored gems and precompiled assets
#     postgres/  PostgreSQL server (zonky embedded binaries: relocatable, universal)
#     valkey/    valkey-server built from source (Redis-compatible, BSD licensed)
#     llama/     llama.cpp's llama-server (Metal) for local AI models; models
#                themselves are downloaded later, from Preferences
#     libvips/   libvips for image variants (avatars, logos, attachment previews):
#                sharp's prebuilt, self-contained build, as libvips.42.dylib
#     ssl/       CA bundle for outbound HTTPS from the bundled OpenSSL
#
# Build on the architecture you are targeting (an Apple Silicon Mac for arm64,
# an Intel Mac or runner for x86_64). Requires Xcode command line tools and git.
#
# Optional: APPLE_SIGNING_IDENTITY="Developer ID Application: …" signs every
# bundled executable with the hardened runtime, as notarization requires.
set -euo pipefail

DESKTOP="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$DESKTOP/.." && pwd)"
ARCH="$(uname -m)"
case "$ARCH" in
  arm64) GEM_PLATFORM=arm64-darwin ;;
  x86_64) GEM_PLATFORM=x86_64-darwin ;;
  *) echo "unsupported architecture $ARCH" >&2; exit 1 ;;
esac

RUBY_VERSION="$(tr -d '[:space:]' < "$REPO/.ruby-version")"
OPENSSL_VERSION="${OPENSSL_VERSION:-3.5.4}"
LIBYAML_VERSION="${LIBYAML_VERSION:-0.2.5}"
POSTGRES_VERSION="${POSTGRES_VERSION:-17.11.0}"   # zonky artifact version
VALKEY_VERSION="${VALKEY_VERSION:-8.1.4}"
LIBVIPS_PACKAGE_VERSION="${LIBVIPS_PACKAGE_VERSION:-1.3.4}"  # @img/sharp-libvips-darwin-*
LLAMA_BUILD="${LLAMA_BUILD:-b11972}"                             # ggml-org/llama.cpp release
LLAMA_SHA256_arm64="0b39e2cd18407c7f7582c7a9aa7a3328875aefbdef0d13d5f6c3f20dd11401ad"
LLAMA_SHA256_x86_64="2b17ea5239d5de82c6490795355e830ff9405343d869bf19f16785e6ad07dc8d"

WORK="$DESKTOP/build/runtime-macos-$ARCH"
OUT="$DESKTOP/runtime"
DEPS="$WORK/deps"
JOBS="$(sysctl -n hw.ncpu)"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-12.0}"
# Resolve native libraries only from the static builds below, never from
# Homebrew (CI runners have it): a gem linked to /opt/homebrew would not load
# on machines without it.
export PKG_CONFIG_LIBDIR="$DEPS/lib/pkgconfig"
export PKG_CONFIG_PATH="$DEPS/lib/pkgconfig"

mkdir -p "$WORK/src" "$DEPS"
rm -rf "$OUT"
mkdir -p "$OUT"

fetch() { # url dest — downloads are cached in $WORK/src between runs
  [ -f "$2" ] && return 0
  curl --fail --location --retry 3 -o "$2.part" "$1"
  mv "$2.part" "$2"
}

# --- OpenSSL (static) -------------------------------------------------------
if [ ! -f "$DEPS/lib/libssl.a" ]; then
  echo "==> OpenSSL $OPENSSL_VERSION"
  fetch "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz" "$WORK/src/openssl.tar.gz"
  rm -rf "$WORK/src/openssl" && mkdir "$WORK/src/openssl"
  tar -xzf "$WORK/src/openssl.tar.gz" -C "$WORK/src/openssl" --strip-components 1
  (cd "$WORK/src/openssl" \
    && ./Configure "darwin64-$ARCH-cc" no-shared no-tests no-docs --prefix="$DEPS" --openssldir="$DEPS/ssl" --libdir=lib \
    && make -j"$JOBS" && make install_sw)
fi

# --- libyaml (static) -------------------------------------------------------
if [ ! -f "$DEPS/lib/libyaml.a" ]; then
  echo "==> libyaml $LIBYAML_VERSION"
  fetch "https://github.com/yaml/libyaml/releases/download/$LIBYAML_VERSION/yaml-$LIBYAML_VERSION.tar.gz" "$WORK/src/yaml.tar.gz"
  rm -rf "$WORK/src/yaml" && mkdir "$WORK/src/yaml"
  tar -xzf "$WORK/src/yaml.tar.gz" -C "$WORK/src/yaml" --strip-components 1
  (cd "$WORK/src/yaml" && ./configure --prefix="$DEPS" --disable-shared --enable-static && make -j"$JOBS" && make install)
fi

# --- Ruby ---------------------------------------------------------------------
echo "==> Ruby $RUBY_VERSION"
fetch "https://cache.ruby-lang.org/pub/ruby/${RUBY_VERSION%.*}/ruby-$RUBY_VERSION.tar.gz" "$WORK/src/ruby-$RUBY_VERSION.tar.gz"
rm -rf "$WORK/src/ruby" && mkdir "$WORK/src/ruby"
tar -xzf "$WORK/src/ruby-$RUBY_VERSION.tar.gz" -C "$WORK/src/ruby" --strip-components 1
(cd "$WORK/src/ruby" \
  && ./configure --prefix="$OUT/ruby" --enable-load-relative --disable-install-doc --disable-shared \
       --with-openssl-dir="$DEPS" --with-libyaml-dir="$DEPS" --without-gmp \
       --with-out-ext=readline,dbm,gdbm,win32ole \
  && make -j"$JOBS" && make install)
"$OUT/ruby/bin/ruby" -ropenssl -rpsych -e 'puts "openssl #{OpenSSL::OPENSSL_LIBRARY_VERSION}, psych #{Psych::VERSION}"'
# Refuse to ship a Ruby that still points at libraries outside the bundle.
if otool -L "$OUT/ruby/bin/ruby" | tail -n +2 | grep -vE '^\s+/(usr/lib|System)/'; then
  echo "ruby links libraries outside the system" >&2; exit 1
fi

# --- PostgreSQL ---------------------------------------------------------------
echo "==> PostgreSQL $POSTGRES_VERSION"
PG_JAR="$WORK/src/postgres-$POSTGRES_VERSION.jar"
# The darwin-arm64v8 artifact contains universal (arm64 + x86_64) binaries.
fetch "https://repo1.maven.org/maven2/io/zonky/test/postgres/embedded-postgres-binaries-darwin-arm64v8/$POSTGRES_VERSION/embedded-postgres-binaries-darwin-arm64v8-$POSTGRES_VERSION.jar" "$PG_JAR"
rm -rf "$WORK/src/pg" && mkdir -p "$WORK/src/pg" "$OUT/postgres"
unzip -q -o "$PG_JAR" '*.txz' -d "$WORK/src/pg"
tar -xJf "$WORK"/src/pg/*.txz -C "$OUT/postgres"
rm -rf "$OUT/postgres/include" "$OUT/postgres/share/doc" "$OUT/postgres/share/locale" \
       "$OUT/postgres/lib/pkgconfig" "$OUT/postgres/lib/pgxs" "$OUT/postgres/lib"/*.a
test -f "$OUT/postgres/share/postgresql/extension/pgcrypto.control"

# --- Valkey -------------------------------------------------------------------
echo "==> Valkey $VALKEY_VERSION"
fetch "https://github.com/valkey-io/valkey/archive/refs/tags/$VALKEY_VERSION.tar.gz" "$WORK/src/valkey.tar.gz"
rm -rf "$WORK/src/valkey" && mkdir "$WORK/src/valkey"
tar -xzf "$WORK/src/valkey.tar.gz" -C "$WORK/src/valkey" --strip-components 1
(cd "$WORK/src/valkey" && make -j"$JOBS" BUILD_TLS=no valkey-server)
mkdir -p "$OUT/valkey"
cp "$WORK/src/valkey/src/valkey-server" "$OUT/valkey/"

# --- llama.cpp server ---------------------------------------------------------
echo "==> llama-server ($LLAMA_BUILD)"
case "$ARCH" in arm64) LLAMA_ASSET=macos-arm64 ;; x86_64) LLAMA_ASSET=macos-x64 ;; esac
fetch "https://github.com/ggml-org/llama.cpp/releases/download/$LLAMA_BUILD/llama-$LLAMA_BUILD-bin-$LLAMA_ASSET.tar.gz" "$WORK/src/llama-$LLAMA_BUILD.tar.gz"
# Checksums are pinned for the default build; a different LLAMA_BUILD is unchecked.
if [ "$LLAMA_BUILD" = b11972 ]; then
  expected_sha="$(eval echo "\$LLAMA_SHA256_$ARCH")"
  echo "$expected_sha  $WORK/src/llama-$LLAMA_BUILD.tar.gz" | shasum -a 256 -c -
fi
rm -rf "$WORK/src/llama" && mkdir -p "$WORK/src/llama" "$OUT/llama"
tar -xzf "$WORK/src/llama-$LLAMA_BUILD.tar.gz" -C "$WORK/src/llama"
LLAMA_DIR="$(find "$WORK/src/llama" -name llama-server -type f -exec dirname {} \; | head -1)"
# Only the server and the libraries it loads (all via @rpath = @loader_path),
# not the other CLI tools' libraries.
cp "$LLAMA_DIR/llama-server" "$OUT/llama/"
pending="$OUT/llama/llama-server"
while [ -n "$pending" ]; do
  next=""
  for bin in $pending; do
    for lib in $(otool -L "$bin" | awk '/@rpath\// { sub("@rpath/", "", $1); print $1 }'); do
      if [ ! -e "$OUT/llama/$lib" ]; then
        cp -P "$LLAMA_DIR/$lib" "$OUT/llama/$lib"
        # Follow version symlinks (libggml.0.dylib -> libggml.0.28.0.dylib).
        real="$(readlink "$LLAMA_DIR/$lib" || true)"
        [ -n "$real" ] && cp -P "$LLAMA_DIR/$real" "$OUT/llama/$real"
        next="$next $OUT/llama/$lib"
      fi
    done
  done
  pending="$next"
done
cp "$LLAMA_DIR/LICENSE" "$OUT/llama/LICENSE" 2>/dev/null || true
"$OUT/llama/llama-server" --version 2>&1 | head -1

# --- libvips -----------------------------------------------------------------
echo "==> libvips (sharp-libvips $LIBVIPS_PACKAGE_VERSION)"
case "$ARCH" in arm64) VIPS_PKG=darwin-arm64 ;; x86_64) VIPS_PKG=darwin-x64 ;; esac
fetch "https://registry.npmjs.org/@img/sharp-libvips-$VIPS_PKG/-/sharp-libvips-$VIPS_PKG-$LIBVIPS_PACKAGE_VERSION.tgz" "$WORK/src/libvips.tgz"
rm -rf "$WORK/src/libvips" && mkdir -p "$WORK/src/libvips" "$OUT/libvips"
tar -xzf "$WORK/src/libvips.tgz" -C "$WORK/src/libvips"
# ruby-vips dlopens "vips.42"; this single dylib also exports the glib API it needs.
cp "$WORK"/src/libvips/package/lib/libvips-cpp.*.dylib "$OUT/libvips/libvips.42.dylib"
cp "$WORK/src/libvips/package/versions.json" "$OUT/libvips/"

# --- CA certificates ----------------------------------------------------------
mkdir -p "$OUT/ssl"
fetch "https://curl.se/ca/cacert.pem" "$WORK/src/cacert.pem"
cp "$WORK/src/cacert.pem" "$OUT/ssl/cacert.pem"

# --- Rails app ----------------------------------------------------------------
BUNDLE_BUILD_FLAGS="puma=--with-openssl-dir=$DEPS
psych=--with-libyaml-dir=$DEPS" \
  "$DESKTOP/scripts/stage-app.sh" "$OUT/ruby/bin" "$OUT/app" "$GEM_PLATFORM"

# Native extensions must not reference libraries outside the bundle either.
bad=0
while IFS= read -r -d '' f; do
  if otool -L "$f" | tail -n +2 | grep -vE '^\s+(/usr/lib|/System|@rpath|@loader_path)' >/dev/null; then
    echo "external library reference in $f:"; otool -L "$f" | tail -n +2; bad=1
  fi
done < <(find "$OUT/app/vendor/bundle" -type f -name '*.bundle' -print0)
[ "$bad" = 0 ] || exit 1

# --- Signing ------------------------------------------------------------------
# Tauri signs the app bundle itself; the executables inside Resources must be
# signed individually for notarization (hardened runtime + entitlements Ruby's
# JIT and extension loading need).
if [ -n "${APPLE_SIGNING_IDENTITY:-}" ]; then
  echo "==> Signing bundled executables"
  find "$OUT" -type f \( -perm -u+x -o -name '*.dylib' -o -name '*.bundle' -o -name '*.so' \) -print0 \
    | while IFS= read -r -d '' f; do
        if file "$f" | grep -q 'Mach-O'; then
          codesign --force --timestamp --options runtime \
            --entitlements "$DESKTOP/src-tauri/runtime.entitlements" \
            --sign "$APPLE_SIGNING_IDENTITY" "$f"
        fi
      done
fi

echo "==> Runtime ready: $OUT ($(du -sh "$OUT" | cut -f1))"
