#!/usr/bin/env bash
# Run only through boat-run in the disposable export-official sandbox.
set -euo pipefail
root=/home/user/runs/export-official
target=/home/user/export-official-v0.11.3
mkdir -p "$target"
if [ ! -f "$target/pubspec.yaml" ]; then
  tar -xzf /home/user/official-v0.11.3-source.tgz -C "$target"
fi
mkdir -p "$target/test/official_export"
cp "$root/test/official_export/schema_probe_test.dart" "$target/test/official_export/"
cd "$target"
flutter pub get
flutter gen-l10n
flutter test --concurrency=1 test/official_export/schema_probe_test.dart
