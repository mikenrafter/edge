#!/usr/bin/env bash
# WHY: a warm target or pub-get lock rewrite must never weaken receiver evidence.
# Run only on the owned Boat sandbox. The temporary shim simulates pub get drift.
source "$(dirname "$0")/common.sh"
shim=$(mktemp -d)
cleanup() { rm -rf "$shim"; }
trap cleanup EXIT
cat > "$shim/flutter" <<'SHIM'
#!/usr/bin/env bash
if [ "$1" = pub ]; then
  echo '# simulated pub-get lock drift' >> pubspec.lock
fi
SHIM
chmod +x "$shim/flutter"
set +e
PATH="$shim:$PATH" bash "$(dirname "$0")/prepare_target.sh" > "$OUT_DIR/lock-drift-negative.log" 2>&1
code=$?
set -e
if [ "$code" -eq 0 ] || ! grep -q 'pub get changed the tagged receiver lock' "$OUT_DIR/lock-drift-negative.log"; then
  cat "$OUT_DIR/lock-drift-negative.log"
  echo 'FAIL: pub-get lock drift was not rejected' >&2
  exit 1
fi
echo 'PASS: post-pub-get lock drift rejected'
# A successful fresh extraction must also remove warm-tree source tampering.
echo 'tamper' >> "$TARGET_DIR/lib/data/db.dart"
bash "$(dirname "$0")/prepare_target.sh"
git -C "$TARGET_SRC" show "$TARGET_TAG:lib/data/db.dart" > "$shim/db.dart"
cmp "$shim/db.dart" "$TARGET_DIR/lib/data/db.dart"
echo 'PASS: warm target source restored from verified archive'
