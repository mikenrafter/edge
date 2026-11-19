// WHY: the first APK must pass the actual-manifest gate before distribution.
// catches: a gate silently succeeding when APK or merged manifest is absent.
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('APK hardening script requires real APK and merged manifest inputs', () async {
    final script = File('tool/check_update_apk.sh');
    expect(script.existsSync(), isTrue, reason: 'APK hardening entry point is required');
    final missing = await Process.run('bash', [script.path]);
    expect(missing.exitCode, 2);
    expect(missing.stderr, contains('Usage:'));
    final absent = await Process.run('bash', [script.path,
      '--apk', '/missing/edge.apk', '--merged-manifest', '/missing/manifest',
      '--head', 'a' * 40, '--variant', 'devProfile']);
    expect(absent.exitCode, 2);
    expect(absent.stderr, contains('APK does not exist'));
  });
}
