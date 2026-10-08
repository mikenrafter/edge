// background_dispatch_audit_test.dart — design 02, rev 4-7: the background
// entries reach heavy work only through an approved dispatcher.
//
// The real entries are driven with a real database and a real DerivationEngine
// (fixed-date synthetic day, no wall clock in the data):
//   * IosBgTask's run path (`runForTest`): the BGProcessingTask FULL profile
//     (engine.run heavy + rescanRecent) and the BGAppRefreshTask LIGHT profile;
//   * background_sync's headless derivation: headlessDeriveAfterSync and
//     headlessDeriveConfirmedWakeDay.
//
// `DerivationEngine.run` is ORCHESTRATION, not itself @heavy (it reads the DB,
// schedules days and persists), so the assertion is on the dispatches it
// performs through the audit hook:
//   1. at least one dispatch was recorded, by an approved dispatcher kind;
//   2. the FIRST heavy work started is a dispatch (nothing ran before it that a
//      registered entry would have recorded);
//   3. no registered entry ran on THIS isolate (`WorkerAudit.entered` fires in
//      the isolate the entry runs in; the test isolate is the stand-in for the
//      UI isolate).

@Timeout(Duration(minutes: 10))
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ios_ble_restore.dart';
import 'package:openstrap_edge/compute/calc_power_policy.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/sync/background_sync.dart';
import 'package:openstrap_edge/sync/ios_bg_task.dart';
import 'package:openstrap_edge/util/worker_audit.dart';
import 'package:openstrap_edge/util/worker_entries.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/compute/onehz_pipeline.dart';

import '../support/day_stream_fixture.dart';
import '../support/incremental_day_fixture.dart';
import '../support/fake_power_source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final dispatches = <DispatchEvent>[];
  final entries = <String>[];
  // A fixed past day (UTC): 08:00 for three hours.
  final start = DateTime.utc(2026, 1, 10, 8).millisecondsSinceEpoch ~/ 1000;
  const seconds = 3 * 3600;

  Future<void> wipe() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  }

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'background_dispatch_audit_test.db';
  });

  setUp(() async {
    await wipe();
    SharedPreferences.setMockInitialValues(const {});
    final beats = synthBeats(SynthBeats(seed: 5, startSec: start, seconds: seconds));
    final accel = synthAccel(7, start, start + seconds + 60);
    await writeSeconds(beats, accel, start, start + seconds);
    dispatches.clear();
    entries.clear();
    WorkerAudit.onDispatch = dispatches.add;
    WorkerAudit.onEntry = entries.add;
    debugHeadlessPowerSource = FakePowerSource(charging: true, powerSaver: false);
    IosBleRestore.foregroundActive = true; // no headless BLE in the test
  });

  tearDown(() {
    WorkerAudit.reset();
    debugHeadlessPowerSource = null;
    IosBleRestore.foregroundActive = false;
  });

  tearDownAll(wipe);

  void expectOnlyApprovedDispatch(String path) {
    expect(dispatches, isNotEmpty,
        reason: '$path derived a seeded day but dispatched nothing');
    expect(dispatches.first.stack.toString(), contains('derivation_engine.dart'),
        reason: 'the call stack is recorded at dispatch, inside the engine\'s '
            'approved dispatcher');
    for (final d in dispatches) {
      expect(Dispatcher.values, contains(d.kind), reason: '$path: $d');
    }
    expect(entries, isEmpty,
        reason: '$path ran a registered worker entry on the dispatching '
            'isolate: $entries');
  }

  test('detector self-test: a DIRECT call of a registered entry on this isolate '
      'is seen', () {
    deriveDayBundle(copyDay(incrementalDay()));
    expect(entries, ['deriveDayBundle']);
    expect(dispatches, isEmpty);
  });

  test('iOS BGProcessingTask (FULL profile) dispatches its heavy derive', () async {
    await _saveMode(CalcPowerMode.balanced);
    expect(await IosBgTask.runForTest(syncOnly: false), isTrue);
    expectOnlyApprovedDispatch('IosBgTask full');
  });

  test('iOS BGAppRefreshTask (LIGHT profile) dispatches its light derive', () async {
    await _saveMode(CalcPowerMode.balanced);
    expect(await IosBgTask.runForTest(syncOnly: true), isTrue);
    expectOnlyApprovedDispatch('IosBgTask refresh');
  });

  test('headless post-drain derive dispatches', () async {
    await _saveMode(CalcPowerMode.balanced);
    await headlessDeriveAfterSync();
    expectOnlyApprovedDispatch('headlessDeriveAfterSync');
  });

  test('headless confirmed-wake-day derive dispatches', () async {
    await _saveMode(CalcPowerMode.balanced);
    expect(await headlessDeriveConfirmedWakeDay(start), isTrue,
        reason: 'derives the seeded day 2026-01-10');
    expectOnlyApprovedDispatch('headlessDeriveConfirmedWakeDay');
  });
}

Future<void> _saveMode(CalcPowerMode mode) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString('calc_power_mode', mode.name);
}
