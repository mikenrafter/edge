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
# Same version number alone does not certify live calibration observations.
python3 - "$FORK_ROOT" "$TARGET_DIR" "$OUT_DIR/counter-equivalence.json" <<'PY'
import json,pathlib,subprocess,sys,urllib.parse
rows=[]
for root in map(pathlib.Path,sys.argv[1:3]):
 config=root/'.dart_tool/package_config.json'
 package=next(p for p in json.loads(config.read_text())['packages'] if p['name']=='openstrap_analytics')
 uri=urllib.parse.urljoin(config.as_uri(),package['rootUri'])
 source=pathlib.Path(urllib.parse.unquote(urllib.parse.urlparse(uri).path))/'lib/src/onehz/motion/steps.dart'
 blob=subprocess.check_output(['git','hash-object',str(source)],text=True).strip()
 assert blob=='688b297be299febace9a73e78b1b4dd9abc8c06c', (root,blob)
 rows.append({'package':str(root),'steps_blob':blob})
pathlib.Path(sys.argv[3]).write_text(json.dumps(rows,indent=2)+'\n')
PY
