#!/usr/bin/env bash
# Stage the Rails app into the desktop runtime: copy the tracked sources,
# install production gems into vendor/bundle with the bundled Ruby, precompile
# assets, then strip what the packaged app never uses.
#
# Usage: stage-app.sh <ruby-bin-dir> <out-app-dir> <gem-platform>
#   gem-platform: arm64-darwin | x86_64-darwin | x64-mingw-ucrt
#
# Extra `bundle config build.*` flags can be passed in BUNDLE_BUILD_FLAGS as
# "gem=flags" lines (used on macOS to point native gems at the static OpenSSL).
set -euo pipefail

RUBY_BIN="$1"
OUT="$2"
GEM_PLATFORM="$3"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"

export PATH="$RUBY_BIN:$PATH"
# Never pick up the developer's own Ruby/Bundler setup.
unset RUBYOPT RUBYLIB GEM_HOME GEM_PATH BUNDLE_PATH BUNDLE_GEMFILE BUNDLE_APP_CONFIG

echo "==> Copying app sources to $OUT"
rm -rf "$OUT"
mkdir -p "$OUT"
# Tracked and new (not ignored) files, minus everything that is not the web app.
# docs/ is dropped except the parts the app reads at runtime (the in-app
# onboarding guide and its images, and the API docs).
(cd "$REPO" && git ls-files -co --exclude-standard) \
  | grep -vE '^(desktop|mobile|test|spec|charts|design|\.github|\.devcontainer|perf\.rake|compose\.|Dockerfile)' \
  | awk '!/^docs\// || /^docs\/(onboarding|api)\//' \
  | (cd "$REPO" && tar -cf - -T -) \
  | tar -xf - -C "$OUT"
mkdir -p "$OUT/tmp" "$OUT/log" "$OUT/storage"
if [ -n "${SURE_VERSION:-}" ]; then printf '%s\n' "$SURE_VERSION" > "$OUT/.sure-version"; fi

cd "$OUT"
echo "==> Ruby: $(ruby -v)"
gem install --no-document --force bundler -v "$(sed -n '/^BUNDLED WITH/{n;s/ //gp;}' Gemfile.lock)"

echo "==> Resolving gems for $GEM_PLATFORM"
bundle config set --local path vendor/bundle
bundle config set --local without "development:test"
while IFS='=' read -r gem flags; do
  [ -n "$gem" ] && bundle config set --local "build.$gem" "$flags"
done <<< "${BUNDLE_BUILD_FLAGS:-}"
# The copied lockfile may be adjusted here (it is not the repo's): add this
# platform, and move pg to a release that ships a prebuilt, self-contained gem
# (libpq statically linked), so no client library has to be bundled.
bundle lock --add-platform "$GEM_PLATFORM"
bundle lock --update pg --conservative
bundle config set --local deployment true
bundle install --jobs 4

echo "==> Precompiling assets"
RAILS_ENV=production SECRET_KEY_BASE_DUMMY=1 bundle exec rails assets:precompile

echo "==> Pruning"
rm -rf tmp/* log/* storage/* node_modules .git
GEMS_ROOT="vendor/bundle/ruby"
rm -rf "$GEMS_ROOT"/*/cache
# Build leftovers of native extensions (the compiled copies live in extensions/).
find "$GEMS_ROOT" -type f \( -name '*.o' -o -name '*.obj' -o -name 'mkmf.log' -o -name 'Makefile' \) -delete
find "$GEMS_ROOT"/*/gems -maxdepth 2 -type d \( -name test -o -name spec -o -name '.github' \) -prune -exec rm -rf {} +
# Tailwind's standalone compiler is only needed for assets:precompile above.
find "$GEMS_ROOT" -path '*tailwindcss-ruby*/exe/*' -type f -name 'tailwindcss*' -delete
# Some gems ship read-only files; bundlers and signing tools must be able to
# rewrite attributes on everything they copy into the app.
chmod -R u+w "$OUT"
echo "==> App staged at $OUT ($(du -sh "$OUT" | cut -f1))"
