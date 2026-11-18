#!/usr/bin/env bash
# Build the independent receiver package: `git archive` of the peeled tag, its own
# pinned dependencies, no patches. The archive hash is recorded for the report.
source "$(dirname "$0")/common.sh"
if [ ! -f "$TARGET_DIR/pubspec.yaml" ]; then
  rm -rf "$TARGET_SRC" "$TARGET_DIR"
  git clone --quiet --bare --filter=blob:none https://github.com/OpenStrap/edge.git "$TARGET_SRC"
  peeled="$(git -C "$TARGET_SRC" rev-parse "$TARGET_TAG^{commit}")"
  [ "$peeled" = "$TARGET_SHA" ] || { echo "tag $TARGET_TAG peels to $peeled, expected $TARGET_SHA" >&2; exit 1; }
  git -C "$TARGET_SRC" archive --format=tar "$TARGET_TAG" | tee >(sha256sum | cut -d' ' -f1 > "$TARGET_DIR.archive.sha256") | { mkdir -p "$TARGET_DIR"; tar -x -C "$TARGET_DIR"; }
  echo "archive sha256: $(cat "$TARGET_DIR.archive.sha256")"
fi
cd "$TARGET_DIR"
flutter pub get
flutter gen-l10n
sha256sum pubspec.lock | tee "$OUT_DIR/target-pubspec-lock.sha256"
