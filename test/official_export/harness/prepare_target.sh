#!/usr/bin/env bash
# Rebuild the unchanged receiver from the verified archive on EVERY invocation.
source "$(dirname "$0")/common.sh"
if [ ! -d "$TARGET_SRC" ]; then
  git clone --quiet --bare --filter=blob:none https://github.com/OpenStrap/edge.git "$TARGET_SRC"
fi
peeled="$(git -C "$TARGET_SRC" rev-parse "$TARGET_TAG^{commit}")"
[ "$peeled" = "$TARGET_SHA" ] || { echo "tag $TARGET_TAG peels to $peeled, expected $TARGET_SHA" >&2; exit 1; }
echo "tag $TARGET_TAG peels to $peeled"
archive="$OUT_DIR/target.tar"
git -C "$TARGET_SRC" archive --format=tar "$TARGET_TAG" > "$archive"
echo "3cf1c4841cad425ab61310792d3e49c55a11a5cddddba3ed27218f3e5c5cd5e5  $archive" | sha256sum --check
sha256sum "$archive" > "$TARGET_DIR.archive.sha256"
rm -rf "$TARGET_DIR"
mkdir -p "$TARGET_DIR"
tar -xf "$archive" -C "$TARGET_DIR"
rm -f "$archive"
git -C "$TARGET_SRC" show "$TARGET_TAG:pubspec.lock" > "$OUT_DIR/tagged-pubspec.lock"
echo "6367ffba4d65ac0e26ff8007cc59b8a5291758e79a46b122bc4876ac34a5fe05  $OUT_DIR/tagged-pubspec.lock" | sha256sum --check
cd "$TARGET_DIR"
cmp pubspec.lock "$OUT_DIR/tagged-pubspec.lock"
flutter pub get
# Dependency resolution must not silently change the proof's receiver.
cmp pubspec.lock "$OUT_DIR/tagged-pubspec.lock" || { echo 'pub get changed the tagged receiver lock' >&2; exit 1; }
flutter gen-l10n
sha256sum pubspec.lock | tee "$OUT_DIR/target-pubspec-lock.sha256"
