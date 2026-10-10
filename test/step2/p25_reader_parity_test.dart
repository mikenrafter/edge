// P2.5 reader behaviour (design 02 step 2, B10, B11 and the new accessor).
//
// Two kinds of test in this file:
//
//   * PARITY ANCHORS, which PASS today and must keep passing: the recovery-ready
//     note's body (B11) and what the two screen loaders (B10) put in their data
//     objects. The expected values are literal, derived from the documented
//     rules in the code (the body is 'Recovery <score><slept>.', the loader
//     reads `readiness_absent_diag` / `imported` / `source` / `steps` off the
//     stored bundle), never from the reader under test.
//   * RED, which fail today: `LocalRepository.getDayBlock(day, keys)` (the
//     accessor the two screens move to). That the note and the two loaders no
//     longer decode a payload themselves is pinned in p25_call_sites_test.dart
//     (source scan, heavy-calc baseline): a worker-entry count cannot show it,
//     because the publish gate's warm decodes the same bundle in the same pass
//     and a cache hit is no dispatch.
//
// `getDayBlock` contract pinned here: it returns exactly the requested top-level
// keys of the SERVED day bundle that are present, with the stored values and
// types (caller-owned: mutating a result changes nothing a later call sees);
// a key the bundle does not have is absent from the map, never null-filled; a
// day with no row, a row that cannot be decoded, or an empty key list answers
// an empty map (today `ReadinessData._absentDiag` throws a FormatException on
// an undecodable bundle whose text names the diagnostic; that crash is not
// behaviour to keep, so it is not pinned). The served row is the one every
// reader serves: the highest `algo_version` at or below the ceiling.


import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/compute/derive_scheduler.dart';
import 'package:openstrap_edge/data/bundle_store.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/notify/notification_center.dart';
import 'package:openstrap_edge/notify/notification_event.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/screens/investigate.dart';
import 'package:openstrap_edge/ui2/screens/readiness_detail.dart';

import '../support/app_state_derive_harness.dart' as harness;
import 'support/p25_support.dart';

const _name = 'p25_parity.db';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  p21RestoreClockAfterEach();

  late Database db;
  late P25Audit audit;
  setUp(() async {
    db = await p21Fresh(_name);
    BundleStore.debugResetShared();
    audit = P25Audit()..attach();
    addTearDown(audit.detach);
  });
  tearDown(() async {
    BundleStore.debugResetShared();
    await p21Drop(_name);
  });

  LocalRepositoryImpl repo() => LocalRepositoryImpl(getProfileMap: () => p22Profile);

  // -- getDayBlock (B10) --------------------------------------------------------

  group('getDayBlock(day, keys)', () {
    const day = '2025-03-01';
    Map<String, dynamic> bundle() => {
      ...p22DayBundle(day, i: 1),
      'readiness_absent_diag': {
        'inputs': ['hrv', 'rhr'],
        'have': 2,
        'need': 4,
        'note': 'need_baseline',
      },
      'imported': true,
      'source': 'garmin',
      'steps': {
        'value': 8123,
        'sensors': {'band': 5000, 'phone': 3123.5},
        'hourly': [0, 12, 40.5],
      },
    };

    test('returns the requested keys, with the stored values and types', () async {
      final b = bundle();
      await p22Seed(db, day, b);

      final got = await repo().getDayBlock(day, [
        'readiness_absent_diag',
        'imported',
        'source',
        'steps',
        'scalars',
      ]);

      expect(p25Text(got), p25Text({
        'readiness_absent_diag': b['readiness_absent_diag'],
        'imported': true,
        'source': 'garmin',
        'steps': b['steps'],
        'scalars': b['scalars'],
      }), reason: 'same keys, same values, same types (1 vs 1.0)');
    });

    test('nothing but the requested keys comes back, and a key the bundle '
        'does not have is absent, not null', () async {
      await p22Seed(db, day, bundle());

      final got = await repo().getDayBlock(day, ['imported', 'no_such_key', 'series']);

      expect(got.keys.toSet(), {'imported', 'series'});
      expect(got.containsKey('no_such_key'), isFalse);
      expect(got['imported'], true);
    });

    test('no row, an undecodable row and an empty key list answer an empty '
        'map', () async {
      await p22Seed(db, day, bundle());
      await p25Row(db, '2025-03-02', payload: '{oops');

      expect(await repo().getDayBlock('2025-03-09', ['imported']), isEmpty);
      expect(await repo().getDayBlock('2025-03-02', ['imported']), isEmpty);
      expect(await repo().getDayBlock(day, const []), isEmpty);
    });

    test('serves the same row every reader serves: the highest version at or '
        'below the ceiling, never one above it, an older one when it is all '
        'there is', () async {
      await p22Seed(db, day, {...bundle(), 'source': 'served'});
      await p22Seed(db, day, {...bundle(), 'source': 'above'}, version: p21Version + 1);
      await p22Seed(db, '2025-03-05', {...bundle(), 'source': 'older'},
          version: p21Version - 1);

      expect((await repo().getDayBlock(day, ['source']))['source'], 'served');
      expect((await repo().getDayBlock('2025-03-05', ['source']))['source'], 'older');
    });

    test('a result is the caller\'s: changing it changes nothing a later call '
        'sees', () async {
      await p22Seed(db, day, bundle());
      final r = repo();

      final first = await r.getDayBlock(day, ['steps', 'readiness_absent_diag']);
      (first['steps'] as Map)['value'] = -1;
      (first['readiness_absent_diag'] as Map)['inputs'].add('x');
      first['extra'] = 1;
      final second = await r.getDayBlock(day, ['steps', 'readiness_absent_diag']);

      expect((second['steps'] as Map)['value'], 8123);
      expect((second['readiness_absent_diag'] as Map)['inputs'], ['hrv', 'rhr']);
      expect(second.containsKey('extra'), isFalse);
    });

    test('the decode runs in a worker, never on the UI isolate', () async {
      await p22Seed(db, day, bundle());

      await repo().getDayBlock(day, ['steps']);
      await audit.settle();

      p25ExpectDecodedInWorker(audit, 'getDayBlock');
    });

    test('it goes through the BundleStore lane the other day readers use '
        '(a recording lane sees the payload; no second door)', () async {
      final lane = P22Lane();
      p22UseStore(p22Store(lane));
      await p22Seed(db, day, bundle());

      final got = await repo().getDayBlock(day, ['source']);

      expect(got['source'], 'garmin');
      expect(lane.payloads, 1);
    });
  });

  // -- ReadinessData (B10) -----------------------------------------------------

  group('ReadinessData.load: absentDiag (parity anchor)', () {
    const diag = {
      'inputs': ['hrv'],
      'have': 1,
      'need': 4,
    };

    Future<ReadinessData> load() => ReadinessData.load(repo());

    test('a day with no readiness reads the diagnostic off today\'s bundle',
        () async {
      await p23Row(db, p23Day(0),
          p23Payload(extra: {'readiness_absent_diag': diag}), computedAt: 5000);

      final d = await load();

      expect(d.readiness.value, isNull, reason: 'guard: nothing scored');
      expect(d.absentDiag, diag);
    });

    test('no marker in the bundle: null', () async {
      await p23Row(db, p23Day(0), p23Payload(), computedAt: 5000);

      expect((await load()).absentDiag, isNull);
    });

    test('a marker that is not a map: null', () async {
      await p23Row(db, p23Day(0),
          p23Payload(extra: {'readiness_absent_diag': 'text'}), computedAt: 5000);

      expect((await load()).absentDiag, isNull);
    });

    test('no bundle for today: null', () async {
      expect((await load()).absentDiag, isNull);
    });

    test('a scored night reads no diagnostic at all (the held-over night\'s '
        'would explain an absence that is not on screen)', () async {
      await p23Row(db, p23Day(1),
          p23Payload(sleep: true, readiness: 80, extra: {'readiness_absent_diag': diag}),
          computedAt: 4000, readinessColumn: 80);
      await p23Row(db, p23Day(0), p23Payload(), computedAt: 5000);

      final d = await load();

      if (d.readiness.value != null) expect(d.absentDiag, isNull);
    });
  });

  // -- InvestigateData (B10) ----------------------------------------------------

  group('InvestigateData.load: imported and steps (parity anchor)', () {
    const day = '2025-03-01';
    const steps = {
      'value': 8123,
      'sensors': {'band': 5000, 'phone': 3123.5},
    };

    Future<InvestigateData> load(String key) =>
        InvestigateData.load(repo(), key, want: day);

    Future<void> seed(Map<String, dynamic> extra, {int version = p21Version}) =>
        p22Seed(db, day, {...p22DayBundle(day, i: 1), ...extra}, version: version);

    test('an imported day names its source', () async {
      await seed({'imported': true, 'source': 'garmin'});

      final d = await load('hr');

      expect(d.day, day);
      expect(d.importedFrom, 'garmin');
      expect(d.steps, isEmpty, reason: 'only the steps key reads the split');
    });

    test('an imported day with no source says "an import"', () async {
      await seed({'imported': true});

      expect((await load('hr')).importedFrom, 'an import');
    });

    test('imported: false, or no marker, is not an import', () async {
      await seed({'imported': false, 'source': 'garmin'});
      expect((await load('hr')).importedFrom, isNull);

      await seed({});
      expect((await load('hr')).importedFrom, isNull);
    });

    test('the steps key reads the per-sensor split, and an import marker too',
        () async {
      await seed({'steps': steps, 'imported': true, 'source': 'fitbit'});

      final d = await load('steps');

      expect(d.steps, steps);
      expect(d.importedFrom, 'fitbit');
    });

    test('a steps value that is not a map is no split', () async {
      await seed({'steps': 8123});

      expect((await load('steps')).steps, isEmpty);
    });

    test('the algo version is the served row\'s', () async {
      await seed({}, version: p21Version - 1);

      expect((await load('hr')).algoVersion, p21Version - 1);
    });

    test('a day with no row: no import, no steps, no version', () async {
      final d = await InvestigateData.load(repo(), 'steps', want: '2025-03-09');

      expect(d.importedFrom, isNull);
      expect(d.steps, isEmpty);
    });
  });

  // -- the recovery-ready note (B11) ---------------------------------------------

  group('AppState recovery-ready note: body parity (anchor)',
      () {
    late List<NotificationEvent> shown;
    late Future<bool> Function(NotificationEvent, {bool allowPermissionPrompt}) realSink;

    setUp(() {
      shown = [];
      realSink = NotificationCenter.instance.presentSink;
      NotificationCenter.instance.presentSink = (e, {bool allowPermissionPrompt = true}) async {
        shown.add(e);
        return true;
      };
      addTearDown(() => NotificationCenter.instance.presentSink = realSink);
      // Quiet hours off so the outcome does not depend on the hour the suite
      // runs at (the same pin notification_day_guard_test uses).
      SharedPreferences.setMockInitialValues({'notif_quiet_enabled': false});
    });

    /// Runs one heavy pass over a store whose newest day is [payload] with
    /// readiness column [readiness], and waits for the note (or for the reader
    /// to have had every chance to send one when none is expected).
    Future<void> pass(String payload, {double? readiness = 77.4, bool expectFire = true}) async {
      await p25Row(db, p23Day(0), payload: payload, readiness: readiness, computedAt: 7000);
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      app.debugRescanRecent = ({onScopeDays, onDayDone}) async => 0;
      app.debugDeriveRun = harness.deriveHook(days: [p23Day(0)]);
      await app.debugRunScheduled(kind: DeriveJobKind.heavy);
      if (expectFire) {
        await harness.until(() => shown.isNotEmpty, what: 'the recovery note');
      } else {
        await harness.settleMs(400);
      }
    }

    String sleepPayload(Object? tst) => '{"sleep":{"accounting":{"value":{"tst_sec":${tst is String ? '"$tst"' : tst}}}}}';

    test('with a night: "Recovery 77, slept 7h 30m."', () async {
      await pass(sleepPayload(27000));

      expect(shown.single.body, 'Recovery 77, slept 7h 30m.');
      expect(shown.single.title, 'Your recovery is ready');
      expect(shown.single.dedupeKey, '${p23Day(0)}:recovery_ready');
    });

    test('minutes round: 26970 s is 449.5 min -> 7h 30m', () async {
      await pass(sleepPayload(26970));

      expect(shown.single.body, 'Recovery 77, slept 7h 30m.');
    });

    test('no sleep block: the body omits the clause', () async {
      await pass('{"scalars":{"steps":4000}}');

      expect(shown.single.body, 'Recovery 77.');
    });

    test('tst of zero: the body omits the clause', () async {
      await pass(sleepPayload(0));
      expect(shown.single.body, 'Recovery 77.');
    });

    test('tst that is not a number: the body omits the clause', () async {
      await pass(sleepPayload('long'));

      expect(shown.single.body, 'Recovery 77.');
    });

    test('an undecodable payload still fires, without the clause', () async {
      await pass('{"sleep": {"accounting"');

      expect(shown.single.body, 'Recovery 77.');
    });

    test('a curve-compact stored bundle is read as the legacy shape does '
        '(sleep accounting is not a curve and survives)', () async {
      await p22Seed(db, p23Day(0), {
        ...p22DayBundle(p23Day(0), i: 2),
        'sleep': {
          'accounting': {'value': {'tst_sec': 21600}},
        },
      }, computedAt: 7000);
      SharedPreferences.setMockInitialValues({'notif_quiet_enabled': false});
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      app.debugRescanRecent = ({onScopeDays, onDayDone}) async => 0;
      app.debugDeriveRun = harness.deriveHook(days: [p23Day(0)]);

      await app.debugRunScheduled(kind: DeriveJobKind.heavy);
      await harness.until(() => shown.isNotEmpty, what: 'the recovery note');

      expect(shown.single.body, 'Recovery 62, slept 6h 0m.',
          reason: 'readiness 60.0 + i from the fixture, rounded');
    });

    test('no readiness: nothing fires',
        () async {
      await pass(sleepPayload(27000), readiness: null, expectFire: false);

      expect(shown, isEmpty);
    });
  });
}
