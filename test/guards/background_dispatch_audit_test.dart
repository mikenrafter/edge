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
//      registered dispatcher kind, and by the entry reports THAT dispatch caused:
//      the dispatcher hands the worker a per-dispatch token (`DispatchEvent.id`),
//      every report echoes it (`EntryEvent.dispatchId`), and
//      `dispatchCorrelationProblems` matches by token. Matching by the SET of
//      entries seen anywhere in the run let two dispatches be satisfied by one
//      report and an unmapped cancellable dispatch pass on any other dispatch's
//      cancellable entry.
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
import 'package:openstrap_edge/data/sample_archive.dart';
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
import 'support/dispatch_correlation.dart';

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
    'sample encode': 'encodeSampleSignalsHeavy',
    'sample carve': 'carveSamplePartHeavy',
    'sample reconstruct': 'reconstructSamplePartsHeavy',
  };
  // Cancellable dispatches whose closure runs inline code rather than a
  // registered entry (legacy, baselined as dispatcherClosureContract). They are
  // still checked for dispatcher kind and for stray reports, but cannot be
  // required to have run an entry.
  const legacyInlineLabels = ['sleep-staging', 'crossday-input'];
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

    // Every dispatch is matched by the entry reports it caused, dispatched the
    // way the registry says. (An entry can also run INSIDE a worker as an inner
    // heavy call, e.g. kcalMinutesForDayHeavy from the day-blocks pipeline; it
    // reports under the token of the dispatch whose worker it ran in.)
    expect(entries.where((e) => e.dispatchId == null), isEmpty,
        reason: '$path: a worker reported an entry with no dispatch token');
    expect(
        dispatchCorrelationProblems(dispatches, entries,
            entryOfLabel: entryOfLabel,
            dispatcherOf: registered,
            cancellableEntries: cancellableEntries,
            legacyInlineLabels: legacyInlineLabels),
        isEmpty,
        reason: '$path: dispatches vs the entry reports they caused');
  }

  // ---- detector self-tests: dispatch <-> entry correlation ------------------
  // Synthetic events only (no worker): they pin what `dispatchCorrelationProblems`
  // accepts. Ids are the per-dispatch tokens; a report names the dispatch whose
  // worker it ran in.
  group('detector self-test: per-dispatch correlation', () {
    DispatchEvent dispatch(int id, Dispatcher kind, String label) =>
        DispatchEvent(kind, label, 'ui', StackTrace.empty, id: id);
    EntryEvent report(String entry, int? dispatchId) =>
        EntryEvent(entry, 'worker$dispatchId', dispatchId: dispatchId);
    List<String> check(List<DispatchEvent> d, List<EntryEvent> e) =>
        dispatchCorrelationProblems(d, e,
            entryOfLabel: entryOfLabel,
            dispatcherOf: registered,
            cancellableEntries: cancellableEntries);

    test('(a) two dispatches with only one entry report fail', () {
      final problems = check([
        dispatch(1, Dispatcher.run, 'kcal minutes'),
        dispatch(2, Dispatcher.run, 'kcal minutes'),
      ], [
        report('kcalMinutesForDayHeavy', 1),
      ]);
      expect(problems, hasLength(1), reason: '$problems');
      expect(problems.single, allOf(contains('kcal minutes'), contains('2')),
          reason: 'names the dispatch that ran nothing');
    });

    test('(b) a dispatch whose entry ran under a DIFFERENT dispatch\'s token '
        'fails', () {
      // The set of entries seen is {_dayBlocksIsolateEntry, kcalMinutesForDayHeavy},
      // which "satisfies" both labels; but dispatch 1 itself reported nothing.
      final problems = check([
        dispatch(1, Dispatcher.run, 'kcal minutes'),
        dispatch(2, Dispatcher.spawn, 'day blocks'),
      ], [
        report('_dayBlocksIsolateEntry', 2),
        report('kcalMinutesForDayHeavy', 2),
      ]);
      expect(problems, isNotEmpty);
      expect(problems.join('\n'), contains('kcal minutes'));
      expect(problems.join('\n'), isNot(contains('day blocks')),
          reason: 'dispatch 2 is satisfied by its own entry');
    });

    test('(b2) an unmapped cancellable dispatch needs a cancellable entry '
        'under ITS token, not under another dispatch\'s', () {
      final problems = check([
        dispatch(1, Dispatcher.cancellable, 'derive day'),
        dispatch(2, Dispatcher.cancellable, 'cross day'),
      ], [
        report('kcalMinutesForDayHeavy', 1), // not a pipeline entry
        report('buildCrossDayBundle', 2), // fine for dispatch 2 only
      ]);
      expect(problems, hasLength(1), reason: '$problems');
      expect(problems.single, contains('derive day'));
    });

    test('(b2b) a legacy inline-closure label needs no entry; a lookalike '
        'label still does', () {
      List<String> run(String label) => dispatchCorrelationProblems(
            [dispatch(1, Dispatcher.cancellable, label)], const [],
            entryOfLabel: entryOfLabel,
            dispatcherOf: registered,
            cancellableEntries: cancellableEntries,
            legacyInlineLabels: legacyInlineLabels,
          );
      expect(run('sleep-staging 2026-01-10'), isEmpty);
      expect(run('crossday-input'), isEmpty);
      expect(run('crossday'), isNotEmpty);
    });

    test('(b3) a report under no token, or under a token no dispatch has, '
        'fails', () {
      final d = [dispatch(1, Dispatcher.run, 'kcal minutes')];
      expect(
          check(d, [
            report('kcalMinutesForDayHeavy', 1),
            report('kcalMinutesForDayHeavy', null),
          ]),
          isNotEmpty,
          reason: 'a worker report with no token');
      expect(
          check(d, [
            report('kcalMinutesForDayHeavy', 1),
            report('kcalMinutesForDayHeavy', 99),
          ]),
          isNotEmpty,
          reason: 'a token that names no dispatch');
    });

    test('(b4) a mapped dispatch reported under the wrong dispatcher kind '
        'fails', () {
      expect(
          check([dispatch(1, Dispatcher.spawn, 'kcal minutes')],
              [report('kcalMinutesForDayHeavy', 1)]),
          isNotEmpty,
          reason: 'kcalMinutesForDayHeavy is registered as Dispatcher.run');
    });

    test('(c) the correctly correlated case passes, inner entries included',
        () {
      expect(
          check([
            dispatch(1, Dispatcher.spawn, 'derivation prepare'),
            dispatch(2, Dispatcher.spawn, 'day blocks'),
            dispatch(3, Dispatcher.run, 'kcal minutes'),
            dispatch(4, Dispatcher.run, 'kcal minutes'),
            dispatch(5, Dispatcher.cancellable, 'derive day'),
          ], [
            report('derivationPrepareWorker', 1),
            report('_dayBlocksIsolateEntry', 2),
            report('kcalMinutesForDayHeavy', 2), // inner call in the day-blocks worker
            report('kcalMinutesForDayHeavy', 3),
            report('kcalMinutesForDayHeavy', 4),
            report('deriveDayBundle', 5),
          ]),
          isEmpty);
    });
  });

  test('detector self-test: a DIRECT call of a registered entry on this isolate '
      'is seen, as this isolate', () {
    deriveDayBundle(copyDay(incrementalDay()));
    expect([for (final e in entries) e.entry], ['deriveDayBundle']);
    expect(entries.single.isolateId, WorkerAudit.currentIsolateId);
    expect(dispatches, isEmpty);
  });

  test('a background derive that prunes an old day archives it through the '
      'registered sample encode entry', () async {
    // A second block six days after the seeded 2026-01-10 puts the data edge
    // past the 3-day raw retention, so the full-history pass archives the old day
    // (SampleArchiver.archiveBefore, called from the engine's raw prune) before
    // its rows go.
    final later = DateTime.utc(2026, 1, 16, 8).millisecondsSinceEpoch ~/ 1000;
    await writeSeconds(
        synthBeats(SynthBeats(seed: 6, startSec: later, seconds: seconds)),
        synthAccel(8, later, later + seconds + 60),
        later,
        later + seconds);
    await _saveMode(CalcPowerMode.balanced);
    expect(await IosBgTask.runForTest(syncOnly: false), isTrue);
    expect(await SampleArchiver.rows('2026-01-10'), isNotEmpty,
        reason: 'precondition: the scenario archived the old day');
    await expectOnlyApprovedDispatch('IosBgTask full (prune)');

    final encode = [
      for (final d in dispatches)
        if (d.label == 'sample encode') d
    ];
    expect(encode, isNotEmpty,
        reason: 'the archive encode is dispatched through an approved '
            'dispatcher, not an anonymous Isolate.run');
    for (final d in encode) {
      expect(d.kind, Dispatcher.run);
      expect(
          [for (final e in entries) if (e.dispatchId == d.id) e.entry],
          contains('encodeSampleSignalsHeavy'),
          reason: 'dispatch ${d.id} ran the registered encode entry');
    }
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
