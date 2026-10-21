// A drain that stored nothing has nothing for a heavy derive to read.
//
// Both post-drain steps in lib/state/sync_controller.dart (openSession and the
// reconnect loop) used to call requestHeavy() unconditionally, so a flappy
// link produced a heavy pass per reconnect over data it had already derived.
//
// Contract: a drain report with 0 records requests no heavy pass. A drain that
// stored records still does (the existing tests pin that).
//
// Assumed API: none new. SyncReport(records, batches, complete).

import 'package:flutter_test/flutter_test.dart';

import 'support/app_state_sync_harness.dart';

const _db = 'app_state_sync_zero_record.db';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => deriveDbSetUp(_db));
  tearDown(() => deriveDbTearDown(_db));

  test('openSession: a drain of 0 records requests no heavy derive',
      syncCase((rig, timers) async {
    rig.engine.syncScript.add(SyncReport(0, 0, true));
    await rig.app.openSession();
    await rig.waitFor(() => rig.engine.count('prompt') == 2);
    await rig.quiesce();
    expect(rig.app.logLines.any((l) => l.contains('Backlog drained: 0 records')),
        isTrue,
        reason: 'precondition: the post-drain step ran');
    expect(await rig.jobTypes(), isNot(contains('derive_heavy')));
  }));

  test('reconnect: a drain of 0 records requests no heavy derive',
      syncCase((rig, timers) async {
    await rig.app.openSession();
    await rig.waitFor(() => rig.engine.count('prompt') == 2);
    await rig.jobQueued('derive_heavy');
    await rig.settleDerive();
    await rig.clearJobs();
    rig.engine.events.clear();

    rig.engine.syncScript.add(SyncReport(0, 0, true));
    rig.engine.drop();
    await rig.waitFor(() => rig.engine.count('prompt') >= 2);
    await rig.quiesce();
    expect(rig.app.logLines.any((l) => l.contains('Reconnect backlog drained: 0 records')),
        isTrue,
        reason: 'precondition: the post-drain step ran');
    expect(await rig.jobTypes(), isNot(contains('derive_heavy')));
  }));
}
