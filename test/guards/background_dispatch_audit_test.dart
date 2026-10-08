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
// performs through the audit hook AND on what the workers report from inside:
//   1. at least one dispatch was recorded, by an approved dispatcher kind, and
//      the first thing that happened is a dispatch;
//   2. registered entries ran, and every one of them ran in a DIFFERENT isolate
//      than the dispatcher (`WorkerAudit.entered` runs in the worker and reports
//      `(entry, isolate id)` through the audit port the dispatcher handed it;
//      see worker_audit_test.dart). A main-isolate hook alone cannot see a
//      worker, so before this a passing test proved dispatch, not which worker
//      ran;
//   3. each spawn / run dispatch is matched by ITS registered entry, in the
//      registered dispatcher kind.
//
// The Android boot wake (`HeadlessBoot.run`) is driven with fakes for the
// platform edges AND for the BLE drain (`runHeadlessSync` needs a band); the
// derivation it ends with is the real `headlessDeriveAfterSync`, exactly what
// `runHeadlessSync` calls after the drain.

@Timeout(Duration(minutes: 10))
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ios_ble_restore.dart';
import 'package:openstrap_edge/compute/calc_power_policy.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/sync/background_sync.dart';
import 'package:openstrap_edge/sync/band_ownership.dart';
import 'package:openstrap_edge/sync/headless_boot.dart';
import 'package:openstrap_edge/sync/paired_device.dart';
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
  final entries = <EntryEvent>[];
  // Dispatches and entries in the order they were observed.
  final log = <Object>[];
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
    log.clear();
    WorkerAudit.onDispatch = (e) {
      dispatches.add(e);
      log.add(e);
    };
    WorkerAudit.onEntry = (e) {
      entries.add(e);
      log.add(e);
    };
    debugHeadlessPowerSource = FakePowerSource(charging: true, powerSaver: false);
    IosBleRestore.foregroundActive = true; // no headless BLE in the test
  });

  tearDown(() {
    WorkerAudit.reset();
    debugHeadlessPowerSource = null;
    IosBleRestore.foregroundActive = false;
  });

  tearDownAll(wipe);

  // The entry each dispatch label must be matched by (the cancellable labels
  // all run the closure's registered pipeline entry).
  const entryOfLabel = <String, String>{
    'derivation prepare': 'derivationPrepareWorker',
    'day blocks': '_dayBlocksIsolateEntry',
    'kcal minutes': 'kcalMinutesForDayHeavy',
  };
  const cancellableEntries = {
    'deriveDayBundle',
    'buildCrossDayBundle',
    'foldDayCheckpoint',
    'foldDayTailHeavy',
  };

  // `#DerivationEngine.kcalMinutesForDayHeavy` -> `kcalMinutesForDayHeavy`
  // (entries report their bare function name).
  String registeredName(Symbol s) =>
      RegExp(r'Symbol\("(.*)"\)').firstMatch(s.toString())!.group(1)!.split('.').last;
  final registered = {
    for (final e in kWorkerEntries) registeredName(e.symbol): e.dispatcher,
  };

  Future<void> expectOnlyApprovedDispatch(String path) async {
    await pumpEventQueue(); // the workers' reports are in flight, not lost
    expect(dispatches, isNotEmpty,
        reason: '$path derived a seeded day but dispatched nothing');
    expect(log.first, isA<DispatchEvent>(),
        reason: '$path: the first heavy work started is a dispatch');
    expect(dispatches.first.stack.toString(), contains('derivation_engine.dart'),
        reason: 'the call stack is recorded at dispatch, inside the engine\'s '
            'approved dispatcher');
    for (final d in dispatches) {
      expect(Dispatcher.values, contains(d.kind), reason: '$path: $d');
    }

    // The entries reported from INSIDE their workers.
    expect(entries, isNotEmpty,
        reason: '$path: no registered entry reported from a worker');
    final dispatchers = {for (final d in dispatches) d.isolateId};
    expect(dispatchers, {WorkerAudit.currentIsolateId},
        reason: '$path dispatches from the test (UI stand-in) isolate');
    for (final e in entries) {
      expect(registered.keys, contains(e.entry),
          reason: '$path: ${e.entry} is not a registered worker entry');
      expect(dispatchers, isNot(contains(e.isolateId)),
          reason: '$path: registered entry ${e.entry} ran on the dispatching '
              'isolate, not in a worker');
    }

    // Every dispatch is matched by its registered entry, dispatched the way the
    // registry says. (An entry can also run INSIDE a worker as an inner heavy
    // call, e.g. kcalMinutesForDayHeavy from the day-blocks pipeline; that is why
    // the check goes dispatch -> entry, not entry -> dispatch.)
    for (final d in dispatches) {
      final want = entryOfLabel[d.label];
      final seen = {for (final e in entries) e.entry};
      if (want != null) {
        expect(seen, contains(want), reason: '$path: dispatch "$d" ran no $want');
        expect(registered[want], d.kind, reason: '$want is registered as ${registered[want]}');
      } else {
        expect(d.kind, Dispatcher.cancellable, reason: '$path: unmapped "$d"');
        expect(seen.intersection(cancellableEntries), isNotEmpty,
            reason: '$path: cancellable dispatch "${d.label}" ran no pipeline '
                'entry (saw $seen)');
      }
    }
  }

  test('detector self-test: a DIRECT call of a registered entry on this isolate '
      'is seen, as this isolate', () {
    deriveDayBundle(copyDay(incrementalDay()));
    expect([for (final e in entries) e.entry], ['deriveDayBundle']);
    expect(entries.single.isolateId, WorkerAudit.currentIsolateId);
    expect(dispatches, isEmpty);
  });

  test('iOS BGProcessingTask (FULL profile) dispatches its heavy derive', () async {
    await _saveMode(CalcPowerMode.balanced);
    expect(await IosBgTask.runForTest(syncOnly: false), isTrue);
    await expectOnlyApprovedDispatch('IosBgTask full');
  });

  test('iOS BGAppRefreshTask (LIGHT profile) dispatches its light derive', () async {
    await _saveMode(CalcPowerMode.balanced);
    expect(await IosBgTask.runForTest(syncOnly: true), isTrue);
    await expectOnlyApprovedDispatch('IosBgTask refresh');
  });

  test('headless post-drain derive dispatches', () async {
    await _saveMode(CalcPowerMode.balanced);
    await headlessDeriveAfterSync();
    await expectOnlyApprovedDispatch('headlessDeriveAfterSync');
  });

  test('headless confirmed-wake-day derive dispatches', () async {
    await _saveMode(CalcPowerMode.balanced);
    expect(await headlessDeriveConfirmedWakeDay(start), isTrue,
        reason: 'derives the seeded day 2026-01-10');
    await expectOnlyApprovedDispatch('headlessDeriveConfirmedWakeDay');
  });

  test('Android boot wake (HeadlessBoot.run) dispatches its derive', () async {
    await _saveMode(CalcPowerMode.balanced);
    HeadlessBoot.resetForTest();
    var drained = false;
    await HeadlessBoot.run(
      isAndroid: () => true,
      consumePendingBoot: () async => true,
      loadPaired: () async => PairedDevice('AA:BB:CC', 'serial'),
      startTracking: () async {},
      // The BLE drain needs a band; the derivation `runHeadlessSync` ends with
      // is the real thing.
      runner: (lease) async {
        drained = true;
        await headlessDeriveAfterSync();
        BandOwnership.release(lease);
        return true;
      },
    );
    expect(drained, isTrue, reason: 'the wake ran its sync through the gate');
    await expectOnlyApprovedDispatch('HeadlessBoot.run');
  });
}

Future<void> _saveMode(CalcPowerMode mode) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString('calc_power_mode', mode.name);
}
