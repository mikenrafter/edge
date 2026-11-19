// no_install_guard_test.dart — the app never installs, downloads or requests an
// APK (owner rule, absolute, 2026-11-17: NO INSTALLS, EVER).
//
// WHY: the update checker only notifies and opens a validated release page.
// A merge from upstream, or a dependency bump, could quietly restore the
// installer path. This guard walks the whole tree for the four bans of spec
// §5.7 and proves its own scanner with literal positive controls, so a guard
// that matches nothing cannot pass.
//
// CLAIM(release-check-no-install-guard)
//
// Catches: restoring `ota_update`, REQUEST_INSTALL_PACKAGES, the
// OtaUpdateFileProvider (and its installer receiver), or any read of the API's
// `browser_download_url`. Not caught here: the merged manifest of a built app
// (see the EDGE_MERGED_MANIFEST group) and runtime HTTP (updates tests).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/no_install_scan.dart';

/// Repository roots that ship code or configuration into the app.
const _roots = ['lib', 'android', 'ios', 'packages', 'tool', 'scripts', 'server'];

bool _skip(String path) =>
    path.contains('/build/') ||
    path.contains('/.gradle/') ||
    path.contains('/.dart_tool/') ||
    path.contains('/.cxx/') ||
    path.endsWith('.g.dart') ||
    path.contains('/lib/l10n/');

List<InstallViolation> _scanTree() {
  final found = <InstallViolation>[];
  for (final name in ['pubspec.yaml', 'pubspec.lock']) {
    found.addAll(scanPubspec(name, File(name).readAsStringSync()));
  }
  for (final root in _roots) {
    final dir = Directory(root);
    if (!dir.existsSync()) continue;
    for (final entity in dir.listSync(recursive: true, followLinks: false)) {
      if (entity is! File || _skip(entity.path)) continue;
      final path = entity.path;
      final String text;
      try {
        text = entity.readAsStringSync();
      } catch (_) {
        continue; // binary asset
      }
      if (path.endsWith('.dart')) {
        found.addAll(scanDart(path, text));
      } else if (path.endsWith('AndroidManifest.xml')) {
        found.addAll(scanManifest(path, text));
      } else if (path.endsWith('.xml') && path.contains('/res/')) {
        found.addAll(scanResourceXml(path, text));
      } else if (path.endsWith('.kt') ||
          path.endsWith('.java') ||
          path.endsWith('.gradle') ||
          path.endsWith('.kts') ||
          path.endsWith('.sh') ||
          path.endsWith('.py') ||
          path.endsWith('.js')) {
        found.addAll(scanNative(path, text));
      }
    }
  }
  return found;
}

void main() {
  group('whole tree', () {
    test('no install permission, dependency, provider or binary-URL read', () {
      final found = _scanTree();
      expect(found, isEmpty,
          reason: 'Restore nothing: remove each install path.\n${found.join('\n')}');
    });
  });

  // Positive controls: each ban, in each file kind it can appear in, must be
  // found by the scanner, and prose about it must not.
  group('positive controls', () {
    test('manifest permission', () {
      final v = scanManifest('M.xml',
          '<manifest><uses-permission android:name="android.permission.REQUEST_INSTALL_PACKAGES" /></manifest>');
      expect(v.map((e) => e.ban), contains(kBanPermission));
    });
    test('manifest provider and installer receiver', () {
      final v = scanManifest('M.xml', '''
<application>
  <provider android:name="sk.fourq.otaupdate.OtaUpdateFileProvider" />
  <receiver android:name="sk.fourq.otaupdate.InstallResultReceiver" />
</application>''');
      expect(v.map((e) => e.ban).toSet(), {kBanProvider, kBanDependency});
      expect(v.map((e) => e.line), containsAll([2, 3]));
    });
    test('pubspec dependency', () {
      expect(scanPubspec('pubspec.yaml', 'dependencies:\n  ota_update: ^7.1.0\n'),
          hasLength(1));
      expect(scanPubspec('pubspec.lock', 'packages:\n  ota_update:\n    dependency: "direct main"\n'),
          hasLength(1));
    });
    test('resource path for the downloaded apk', () {
      expect(scanResourceXml('filepaths.xml', '<files-path path="ota_update/" />'),
          hasLength(1));
    });
    test('dart binary url read, in map and index form', () {
      expect(scanDart('a.dart', "final u = asset['browser_download_url'];"),
          hasLength(1));
      expect(scanDart('a.dart', "import 'package:ota_update/ota_update.dart';"),
          hasLength(1));
    });
    test('native source and gradle', () {
      expect(
          scanNative('b.kts', 'implementation("sk.fourq:ota_update:7.1.0")'),
          isNotEmpty);
      expect(scanNative('P.kt', 'val p = "android.permission.REQUEST_INSTALL_PACKAGES"'),
          isNotEmpty);
    });
  });

  group('prose is not use', () {
    test('comments in every language are ignored', () {
      expect(scanManifest('M.xml', '<!-- no REQUEST_INSTALL_PACKAGES, no OtaUpdateFileProvider -->'),
          isEmpty);
      expect(scanPubspec('pubspec.yaml', '  # ota_update was removed\n'), isEmpty);
      expect(scanDart('a.dart', '// never read browser_download_url\n/* ota_update */'),
          isEmpty);
      expect(scanNative('b.kts', '// Required by ota_update 7.x\n'), isEmpty);
    });
    test('a comment marker inside a URL string is not a comment', () {
      expect(
          scanDart('a.dart', "final u = 'https://x.test/a'; final b = asset['browser_download_url'];"),
          hasLength(1));
    });
  });

  // Run once against a built app: EDGE_MERGED_MANIFEST names a directory of
  // merged AndroidManifest.xml files (Gradle processReleaseMainManifest output).
  // Unset, the group registers no case; the scanner is proved above.
  final merged = Platform.environment['EDGE_MERGED_MANIFEST'];
  if (merged != null && merged.isNotEmpty) {
    group('actual merged manifest ($merged)', () {
      test('the merged manifest carries no install capability', () {
        final files = Directory(merged)
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('AndroidManifest.xml'))
            .toList();
        expect(files, isNotEmpty, reason: 'no merged manifest under $merged');
        final found = [
          for (final f in files) ...scanManifest(f.path, f.readAsStringSync()),
        ];
        expect(found, isEmpty, reason: found.join('\n'));
      });
    });
  }
  final dump = Platform.environment['EDGE_APK_MANIFEST_DUMP'];
  if (dump != null) {
    // WHY: dependency manifests can restore an installer in the packaged APK.
    // catches: a banned permission/provider present only in aapt's final tree.
    test('the packaged APK manifest carries no install capability', () {
      final file = File(dump);
      expect(file.existsSync(), isTrue, reason: 'APK manifest dump is required');
      final text = file.readAsStringSync();
      expect(text, matches(RegExp(r'^\s*E: manifest(?:\s|$)', multiLine: true)));
      expect(text, matches(RegExp(r'^\s*E: application(?:\s|$)', multiLine: true)));
      final found = scanManifest(file.path, text);
      expect(found, isEmpty, reason: found.join('\n'));
    });
  }

}
