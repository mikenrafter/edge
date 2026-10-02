// 8M follow-up — source guards for the manual-sync wiring that cannot be driven
// without a band. The behaviour behind each is tested directly:
// DeriveScheduler (derive_scheduler_manual_sync_test), the engine's
// changedOnly pass (derive_changed_only_test), the coordinator and
// classifyDownload (sync_outcomes_test).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final app = File('lib/state/app_state.dart').readAsStringSync();
  final body = () {
    final start = app.indexOf('Future<void> _manualSync');
    return app.substring(start, app.indexOf('@visibleForTesting', start));
  }();

  test('the scheduler hold is taken before the download and ended in finally',
      () {
    final begin = body.indexOf('beginManualSync()');
    final download = body.indexOf('_kickSyncBurst(');
    final fin = body.indexOf('} finally {', download);
    expect(begin, greaterThan(0));
    expect(begin, lessThan(download), reason: 'held before commits arm a timer');
    expect(fin, greaterThan(download));
    expect(body.indexOf('endManualSync(hold', fin), greaterThan(fin));
  });

  test('absorb is only claimed after the derive completed', () {
    final flag = body.indexOf('derived = true;');
    final run = body.indexOf('_afterDrain(');
    expect(flag, greaterThan(run));
    expect(body, contains('absorb: derived'));
  });

  test('the derive is the changed-only pass and its scope reaches the panel',
      () {
    expect(body, contains('changedOnly: true'));
    expect(body, contains('reportScope('));
    expect(body, contains('reportDay('));
  });

  test('the cancel token is checked between steps', () {
    expect(
      RegExp(r'cancel\.throwIfCancelled\(\)').allMatches(body).length,
      greaterThanOrEqualTo(3),
    );
    expect(body, contains('syncOperations.cancelToken'));
  });

  test('a stopped download is classified, not thrown on sight', () {
    expect(body, contains('classifyDownload('));
    expect(body, contains('reportPartialDownload()'));
    expect(body, contains('Download stopped before completion'));
  });

  test('drain and ACK ordering is untouched by the sync-performance work', () {
    final ble = File('lib/ble/ble_engine.dart').readAsStringSync();
    expect(ble, isNot(contains('beginManualSync')));
    expect(ble, isNot(contains('changedOnly')));
  });
}
