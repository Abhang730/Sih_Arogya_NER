#!/usr/bin/env bash
#
# Builds the Arogya-NER web demonstration build and stages it for static hosting.
#
# Why the demo is a separate artefact from the field app, stated once here so it
# is not rediscovered later:
#
#   * the camera pose engine (Google ML Kit) is Android/iOS only, so the web
#     build uses the synthetic engine and labels it on screen;
#   * the Motion Pod talks over BLE, so the web build uses the simulated session
#     and labels it on screen;
#   * SQLCipher has no browser implementation, so the web build stores records in
#     an unencrypted browser SQLite database and the Settings screen says so.
#
# Nothing about those three substitutions is hidden from a reviewer, which is the
# point: the same build that demonstrates the workflow also demonstrates the
# product's honesty rules.
#
# Usage:  tools/deploy_web_demo.sh
# Then:   follow the printed deploy step (Vercel CLI, or drag build/web onto a
#         static host).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MOBILE="$ROOT/mobile"
OUT="$MOBILE/build/web"

echo "==> Building the web demo (release)"
(cd "$MOBILE" && flutter build web --release)

# Hosting configuration lives with the deployed artefact, because the demo is
# uploaded as a static folder rather than built on the host: a host-native build
# would need Flutter in the build image, and a Flutter SDK download would add
# minutes to every deploy for no benefit.
if [ -f "$MOBILE/vercel.json" ]; then
  cp "$MOBILE/vercel.json" "$OUT/vercel.json"
  echo "==> Staged vercel.json (SPA rewrites + wasm content type)"
fi

echo "==> Checking that the runtime files a browser needs are present"
for required in index.html main.dart.js flutter_bootstrap.js sqlite3.wasm sqflite_sw.js; do
  if [ ! -f "$OUT/$required" ]; then
    # sqflite_sw.js and sqlite3.wasm come from
    # `dart run sqflite_common_ffi_web:setup`, which is a one-time step.
    echo "MISSING: $OUT/$required" >&2
    if [ "$required" = "sqlite3.wasm" ] || [ "$required" = "sqflite_sw.js" ]; then
      echo "  Run: cd mobile && dart run sqflite_common_ffi_web:setup" >&2
    fi
    exit 1
  fi
done
echo "    all present"

cat <<'NEXT'

==> Deploy

Option A — Vercel CLI (from the built folder):
    cd mobile/build/web
    npx vercel deploy --prod --yes
  (the first run opens a browser once to sign in; no card is required for the
   free Hobby tier)

Option B — Netlify drop (no CLI, no account setup):
    open https://app.netlify.com/drop and drag the mobile/build/web folder in

Either way the resulting link serves the demonstration build: it runs entirely
in the reviewer's browser, and stores nothing outside that browser.
NEXT
