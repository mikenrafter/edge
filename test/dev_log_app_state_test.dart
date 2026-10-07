// Everything AppState logs was persisted before the dev log existed (the old
// sync log took every line), so it still is with developer mode OFF.
// Developer mode only adds detail; it never decides whether these are kept.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/sync/dev_log.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory base;
  late DevLog previous;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    base = Directory.systemTemp.createTempSync('devlog_app_');
    previous = DevLog.instance;
    DevLog.instance = DevLog(
      baseDir: () async => base,
      now: () => DateTime(2026, 10, 6, 12),
      devMode: () async => false,
    );
  });

  tearDown(() {
    DevLog.instance = previous;
    base.deleteSync(recursive: true);
  });

  test('an untagged AppState line is kept with developer mode off', () async {
    final app = AppState.forTesting();
    addTearDown(app.dispose);

    app.debugLog('[db] vacuum returned 3 MB to the filesystem');
    app.debugLog('Backup failed: disk full');
    await DevLog.instance.flush();

    final text =
        File('${base.path}/dev_log/dev-2026-10-06.log').readAsStringSync();
    expect(text, contains('[db] vacuum returned 3 MB'));
    expect(text, contains('Backup failed: disk full'));
  });
}
