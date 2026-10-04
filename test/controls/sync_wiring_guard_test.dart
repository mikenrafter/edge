// 8M — source guards for the wiring that cannot be driven without a band.
// The ACK ordering itself is pinned by ble_safe_trim_test and
// ack_commit_sync_full_test; these only pin that the progress plumbing stays
// AFTER the commit and can never throw into the drain.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final app = File('lib/state/app_state.dart').readAsStringSync();
  // The progress report and the manual sync live in the sync controller
  // (8AJ seam 5); the drain's call site into the report stays in AppState.
  final sync = File('lib/state/sync_controller.dart').readAsStringSync();

  test('the progress report runs after the commit returns, never before', () {
    final commit = app.indexOf('await _bandHost.commitNativeBatch(');
    final report = app.indexOf('_reportSyncCommit(raws.length');
    expect(commit, greaterThan(0));
    expect(report, greaterThan(commit));
  });

  test('the progress report cannot throw into the drain', () {
    final start = sync.indexOf('void reportSyncCommit(');
    final body = sync.substring(start, sync.indexOf('Future<void> _manualSync'));
    expect(body, contains('try {'));
    expect(body, contains('} catch (_) {}'));
  });

  test('manual sync forwards onDayDone and clears waiting in finally', () {
    final start = sync.indexOf('Future<void> _manualSync');
    final body = sync.substring(start, sync.indexOf('@visibleForTesting', start));
    expect(body, contains('onDay:'));
    expect(body, contains('reportDay('));
    expect(body, contains('} finally {'));
    expect(body, contains('reportWaitingForCalculation(false)'));
  });

  test('Home has no second sync button or tap latch', () {
    final home = File('lib/ui2/screens/home_screen.dart').readAsStringSync();
    expect(home, isNot(contains('_tapSync')));
    expect(home, isNot(contains('_syncTapped')));
    expect(home, isNot(contains('syncingNowOf')));
  });
}
