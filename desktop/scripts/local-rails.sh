#!/usr/bin/env bash
# Run a Rails command against a Sure Desktop install's local data (macOS), with
# the same environment the app gives its own Ruby processes. Sure must be
# running, so its database and Valkey are up.
#
#   desktop/scripts/local-rails.sh runner 'puts User.count'
#   desktop/scripts/local-rails.sh console
#   desktop/scripts/local-rails.sh demo_data:default     # load demo data
#   desktop/scripts/local-rails.sh --dev desktop:dev_seed  # seed `npm run dev:local`
#
# SURE_APP (default /Applications/Sure.app) picks the installed app to use.
# --dev targets this checkout's dev app instead: its data folder and desktop/runtime/.
set -euo pipefail

APP="${SURE_APP:-/Applications/Sure.app}"
RT="$APP/Contents/Resources/runtime"
DATA="$HOME/Library/Application Support/app.sure.desktop/local"
if [ "${1:-}" = "--dev" ]; then
  shift
  RT="${SURE_RUNTIME_DIR:-$(cd "$(dirname "$0")/.." && pwd)/runtime}"
  # The dev app records its (per-checkout) data folder here on launch.
  MARKER="$(cd "$(dirname "$0")/.." && pwd)/.dev-data-dir"
  [ -f "$MARKER" ] || { echo "Start the dev app once (npm run dev:local) so it records its data folder." >&2; exit 1; }
  DATA="$(cat "$MARKER")"
  export SURE_DESKTOP_DEV=1
fi
[ -x "$RT/ruby/bin/ruby" ] || { echo "No bundled runtime in $RT (set SURE_APP, or build one with npm run runtime:mac)" >&2; exit 1; }
[ -f "$DATA/secrets.json" ] || { echo "No local data in $DATA; launch Sure first" >&2; exit 1; }

secret() { "$RT/ruby/bin/ruby" -rjson -e 'print JSON.parse(File.read(ARGV[0])).fetch(ARGV[1], "").to_s' "$DATA/secrets.json" "$1"; }

export RAILS_ENV=production SURE_DESKTOP=1 SELF_HOSTED=true
export SECRET_KEY_BASE="$(secret secret_key_base)"
if [ -n "$(secret encryption_primary_key)" ]; then
  export ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY="$(secret encryption_primary_key)"
  export ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY="$(secret encryption_deterministic_key)"
  export ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT="$(secret encryption_key_derivation_salt)"
  export ACTIVE_RECORD_ENCRYPTION_SUPPORT_UNENCRYPTED_DATA="$(secret support_unencrypted_data)"
fi
export DB_HOST=127.0.0.1 DB_PORT="$(secret db_port)" POSTGRES_USER=sure POSTGRES_DB=sure_production
export POSTGRES_PASSWORD="$(secret db_password)"
export REDIS_URL="redis://:$(secret valkey_password)@127.0.0.1:$(secret valkey_port)/0"
export RAILS_FORCE_SSL=false RAILS_ASSUME_SSL=false DB_POOL=10
export ACTIVE_STORAGE_ROOT="$DATA/storage" BOOTSNAP_CACHE_DIR="$DATA/cache/bootsnap" TMPDIR="$DATA/run"
export BUNDLE_GEMFILE="$RT/app/Gemfile" BUNDLE_PATH="$RT/app/vendor/bundle" BUNDLE_DEPLOYMENT=1
export BUNDLE_WITHOUT=development:test BUNDLE_APP_CONFIG="$RT/app/.bundle"
export SSL_CERT_FILE="$RT/ssl/cacert.pem" PATH="$RT/ruby/bin:$PATH" LANG=en_US.UTF-8
export DYLD_FALLBACK_LIBRARY_PATH="$RT/libvips:/usr/local/lib:/usr/lib"
unset RUBYOPT RUBYLIB GEM_HOME GEM_PATH

cd "$RT/app"
exec "$RT/ruby/bin/ruby" bin/rails "$@"
