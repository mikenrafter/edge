#!/usr/bin/env bash
set -euo pipefail
root=/home/user/runs/export-official
target=/home/user/export-official-v0.11.3
cp "$root/test/official_export/official_import_probe.dart" "$target/test/official_export/import_probe_test.dart"
cd "$target"
flutter gen-l10n
flutter test --concurrency=1 test/official_export/import_probe_test.dart
