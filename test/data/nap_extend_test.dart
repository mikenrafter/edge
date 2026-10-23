// Keeping a nap that overlaps sleep EXTENDS the overlapped block to the union
// instead of being refused (owner decision). RED: resolveNapKeep is a stub that
// returns the input bounds, and confirm still refuses an overlap.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/data/activity_store.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/data/nap_resolution.dart';
import 'package:openstrap_edge/models/activity_suggestion.dart';

void main() {
  late Database db;
  late ActivityStore store;
  late LocalRepositoryImpl repo;
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  // Everything sits at least 10 h in the past; t0 is the anchor.
  final t0 = now - 10 * 3600;
  String dayOf(int ts) =>
      dayLabelOf(DateTime.fromMillisecondsSinceEpoch(ts * 1000));

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    await LocalDb.close();
    LocalDb.dbName = 'nap_extend_test.db';
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
    );
    db = await LocalDb.instance;
    await db.update('activity_review_meta', {'activated_at': t0 - 1});
    store = ActivityStore(db);
    repo = LocalRepositoryImpl(getProfileMap: () => {});
  });
  tearDown(() async {
    await LocalDb.close();
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
    );
  });

  Future<void> addNap(int s, int e, {String source = 'manual'}) =>
      db.insert('sleep_nap', {
        'day_id': dayOf(s),
        'start_ts': s,
        'end_ts': e,
        'source': source,
        'created_at': now,
        'payload_json': source == 'manual'
            ? null
            : jsonEncode({
                'start': s,
                'end': e,
                'duration_min': 20,
                'in_bed_min': 25,
                'confidence': 0.6,
                'source': source,
              }),
      });

  /// A pending nap suggestion at [s]..[e], created BEFORE the overlapping rows
  /// (reconcile would otherwise drop it for overlapping saved sleep).
  Future<ActivitySuggestion> suggest(int s, int e) async => (await store
      .reconcile(ActivityKind.nap, [
        {
          'start': s,
          'end': e,
          'duration_min': (e - s) ~/ 60,
          'in_bed_min': (e - s) ~/ 60,
          'confidence': 0.6,
        },
      ])).single;

  Future<void> dayResult(
    String day, {
    String windowJson = '{}',
    Map<String, dynamic>? sleep,
  }) => LocalDb.putDayResult(
    dayId: day,
    algoVersion: kAlgoVersion,
    payloadJson: jsonEncode({
      'scalars': {'rhr': 53, 'readiness': 74, 'nap_min': 0},
      'naps': {'value': [], 'count': 0},
      'sleep': ?sleep,
    }),
    windowJson: windowJson,
    finalized: true,
    source: 'band',
    rhr: 53,
    readiness: 74,
    series: {'rhr': 53, 'readiness': 74, 'nap_min': 0},
  );

  Future<List<Map<String, Object?>>> napRows() =>
      db.query('sleep_nap', orderBy: 'start_ts ASC');

  group('resolveNapKeep', () {
    test('no overlap: the input bounds, nothing extended', () async {
      final r = await repo.resolveNapKeep(t0, t0 + 1800);
      expect(r.startTs, t0);
      expect(r.endTs, t0 + 1800);
      expect(r.extended, isEmpty);
    });

    test('a nap it overlaps is extended to the union', () async {
      await addNap(t0, t0 + 1800);
      final r = await repo.resolveNapKeep(t0 + 1200, t0 + 3000);
      expect(r.startTs, t0);
      expect(r.endTs, t0 + 3000);
      expect(r.extended, [
        (kind: 'nap', day: dayOf(t0), startTs: t0, endTs: t0 + 1800),
      ]);
    });

    test('containment: the input inside a nap resolves to that nap', () async {
      await addNap(t0, t0 + 3600);
      final r = await repo.resolveNapKeep(t0 + 600, t0 + 1800);
      expect(r.startTs, t0);
      expect(r.endTs, t0 + 3600);
      expect(r.extended, [
        (kind: 'nap', day: dayOf(t0), startTs: t0, endTs: t0 + 3600),
      ]);
    });

    test('the input containing a nap also extends over it', () async {
      await addNap(t0 + 600, t0 + 1200);
      final r = await repo.resolveNapKeep(t0, t0 + 3000);
      expect((r.startTs, r.endTs), (t0, t0 + 3000));
      expect(r.extended, hasLength(1));
    });

    test('bridging two naps yields one union covering both', () async {
      await addNap(t0, t0 + 1800);
      await addNap(t0 + 3600, t0 + 5400);
      final r = await repo.resolveNapKeep(t0 + 1500, t0 + 3900);
      expect(r.startTs, t0);
      expect(r.endTs, t0 + 5400);
      expect(r.extended.map((b) => b.startTs), [t0, t0 + 3600]);
    });

    test('transitive: a block overlapping an overlapped block joins in', () async {
      // The input touches only B; A overlaps B on the other side, so A joins.
      await addNap(t0, t0 + 1800); // A
      await addNap(t0 + 1500, t0 + 3000); // B overlaps A
      final r = await repo.resolveNapKeep(t0 + 2700, t0 + 3300);
      expect(r.startTs, t0);
      expect(r.endTs, t0 + 3300);
      expect(r.extended, hasLength(2));
    });

    test('never bridges a gap: a nap the input does not reach is untouched',
        () async {
      await addNap(t0, t0 + 1800);
      await addNap(t0 + 3600, t0 + 5400);
      final r = await repo.resolveNapKeep(t0 + 1500, t0 + 2400);
      expect(r.startTs, t0);
      expect(r.endTs, t0 + 2400);
      expect(r.extended.map((b) => b.startTs), [t0]);
    });

    test('touching counts: input end == nap start', () async {
      await addNap(t0 + 1800, t0 + 3600);
      final r = await repo.resolveNapKeep(t0, t0 + 1800);
      expect(r.startTs, t0);
      expect(r.endTs, t0 + 3600);
      expect(r.extended, hasLength(1));
    });

    test('a rejected nap is not a block', () async {
      await addNap(t0, t0 + 1800, source: 'rejected');
      final r = await repo.resolveNapKeep(t0 + 600, t0 + 2400);
      expect((r.startTs, r.endTs), (t0 + 600, t0 + 2400));
      expect(r.extended, isEmpty);
    });

    test('the input itself must still be a 5 min..6 h nap', () async {
      await expectLater(
        repo.resolveNapKeep(t0, t0 + 120),
        throwsA(isA<ActivityReviewException>()),
      );
      await expectLater(
        repo.resolveNapKeep(t0, t0 + 7 * 3600),
        throwsA(isA<ActivityReviewException>()),
      );
    });

    test('overlapping a sleep_override main sleep extends it (union may pass 6 h)',
        () async {
      final on = t0, off = t0 + 8 * 3600;
      await LocalDb.putSleepOverride(
        dayId: dayOf(off),
        onsetTs: on,
        offsetTs: off,
        source: 'manual',
      );
      final r = await repo.resolveNapKeep(off - 600, off + 900);
      expect(r.startTs, on);
      expect(r.endTs, off + 900);
      expect(r.extended, [
        (kind: 'main_sleep', day: dayOf(off), startTs: on, endTs: off),
      ]);
    });

    test('a main sleep known only from day_result.window_json extends too',
        () async {
      final on = t0, off = t0 + 8 * 3600;
      await dayResult(
        dayOf(off),
        windowJson: jsonEncode({
          'value': {'onset_ms': on * 1000, 'offset_ms': off * 1000},
        }),
      );
      final r = await repo.resolveNapKeep(on - 900, on + 600);
      expect(r.startTs, on - 900);
      expect(r.endTs, off);
      expect(r.extended.map((b) => b.kind), ['main_sleep']);
    });
  });

  group('commit', () {
    test('containment keeps the nap and adds no row (no duplicate credit)',
        () async {
      final s = await suggest(t0 + 600, t0 + 1800);
      await addNap(t0, t0 + 3600);
      final res = await repo.resolveNapKeep(t0 + 600, t0 + 1800);
      await repo.confirmActivity(s, expected: res);
      final rows = await napRows();
      expect(rows, hasLength(1));
      expect((rows.single['start_ts'], rows.single['end_ts']), (t0, t0 + 3600));
    });

    test('overlapped naps merge into ONE row with the union, marked manual',
        () async {
      final s = await suggest(t0 + 1500, t0 + 3900);
      await addNap(t0, t0 + 1800, source: 'confirmed');
      await addNap(t0 + 3600, t0 + 5400, source: 'confirmed');
      final res = await repo.resolveNapKeep(t0 + 1500, t0 + 3900);
      await repo.confirmActivity(s, startTs: t0 + 1500, endTs: t0 + 3900,
          expected: res);
      final rows = await napRows();
      expect(rows, hasLength(1));
      expect((rows.single['start_ts'], rows.single['end_ts']), (t0, t0 + 5400));
      // The detector's old aggregates must not ride along on the new bounds.
      expect(rows.single['source'], 'manual');
      expect(rows.single['payload_json'], isNull);
      expect((await store.get(s.id))!.status, ActivityReviewStatus.confirmed);
    });

    test('a nap beyond a gap is left alone when only one is overlapped',
        () async {
      final s = await suggest(t0 + 1500, t0 + 2400);
      await addNap(t0, t0 + 1800, source: 'confirmed');
      await addNap(t0 + 3600, t0 + 5400, source: 'confirmed');
      final res = await repo.resolveNapKeep(t0 + 1500, t0 + 2400);
      await repo.confirmActivity(s, startTs: t0 + 1500, endTs: t0 + 2400,
          expected: res);
      final rows = await napRows();
      expect(rows.map((r) => r['start_ts']), [t0, t0 + 3600]);
      expect(rows.first['end_ts'], t0 + 2400);
      expect(rows.last['source'], 'confirmed');
    });

    test('overlapping a sleep_override main sleep edits it through the sleep path',
        () async {
      final on = t0, off = t0 + 8 * 3600;
      final s = await suggest(off - 600, off + 900);
      await LocalDb.putSleepOverride(
        dayId: dayOf(off),
        onsetTs: on,
        offsetTs: off,
        source: 'confirmed',
      );
      await db.insert('wake_confirmation', {
        'day_id': dayOf(off),
        'at_sec': off,
        'basis': 'test',
        'created_at': now,
      });
      final res = await repo.resolveNapKeep(off - 600, off + 900);
      await repo.confirmActivity(s, startTs: off - 600, endTs: off + 900,
          expected: res);
      final ov = (await LocalDb.getSleepOverride(dayOf(off)))!;
      expect((ov['onset_ts'], ov['offset_ts']), (on, off + 900));
      expect(ov['source'], 'manual');
      expect(await napRows(), isEmpty, reason: 'no separate nap row');
      // putSleepOverride reopens the night.
      expect(await db.query('wake_confirmation'), isEmpty);
    });

    test('a main sleep known only from window_json becomes an override',
        () async {
      final on = t0, off = t0 + 8 * 3600;
      // The suggestion starts before the default cutoff (t0 - 1): move it back.
      await db.update('activity_review_meta', {'activated_at': t0 - 3600});
      final s = await suggest(on - 900, on + 600);
      await dayResult(
        dayOf(off),
        windowJson: jsonEncode({
          'value': {'onset_ms': on * 1000, 'offset_ms': off * 1000},
        }),
      );
      expect(await LocalDb.getSleepOverride(dayOf(off)), isNull);
      final res = await repo.resolveNapKeep(on - 900, on + 600);
      await repo.confirmActivity(s, startTs: on - 900, endTs: on + 600,
          expected: res);
      final ov = (await LocalDb.getSleepOverride(dayOf(off)))!;
      expect((ov['onset_ts'], ov['offset_ts']), (on - 900, off));
      expect(await napRows(), isEmpty);
    });

    test('a stale expected throws NapResolutionChanged and writes nothing',
        () async {
      final s = await suggest(t0, t0 + 1800);
      final preview = await repo.resolveNapKeep(t0, t0 + 1800);
      expect(preview.extended, isEmpty);
      // A nap lands after the preview.
      await addNap(t0 + 900, t0 + 2400, source: 'confirmed');
      final before = await napRows();
      NapResolutionChanged? changed;
      try {
        await repo.confirmActivity(s, expected: preview);
      } on NapResolutionChanged catch (e) {
        changed = e;
      }
      expect(changed, isNotNull);
      expect((changed!.now.startTs, changed.now.endTs), (t0, t0 + 2400));
      expect(changed.now.extended, hasLength(1));
      expect(await napRows(), before);
      expect((await store.get(s.id))!.status, ActivityReviewStatus.pending);
    });

    test('a matching expected commits', () async {
      final s = await suggest(t0, t0 + 1800);
      await addNap(t0 + 900, t0 + 2400, source: 'confirmed');
      final res = await repo.resolveNapKeep(t0, t0 + 1800);
      expect(res.extended, hasLength(1));
      await repo.confirmActivity(s, expected: res);
      final rows = await napRows();
      expect(rows, hasLength(1));
      expect((rows.single['start_ts'], rows.single['end_ts']), (t0, t0 + 2400));
    });
  });

  test('a workout overlapping sleep is still refused', () async {
    final w = (await store.reconcile(ActivityKind.workout, [
      {'start_ts': t0, 'end_ts': t0 + 1800},
    ])).single;
    await addNap(t0 + 300, t0 + 1500, source: 'confirmed');
    await expectLater(
      store.confirm(
        w,
        startTs: t0,
        endTs: t0 + 1800,
        session: {'id': 'suggestion:${w.id}', 'start_ts': t0},
      ),
      throwsA(isA<ActivityReviewException>()),
    );
    expect(await db.query('sessions'), isEmpty);
    expect((await store.get(w.id))!.status, ActivityReviewStatus.pending);
  });

  test('a workout overlapping the main sleep in the day bundle is refused',
      () async {
    final on = t0, off = t0 + 8 * 3600;
    final w = (await store.reconcile(ActivityKind.workout, [
      {'start_ts': on + 600, 'end_ts': on + 2400},
    ])).single;
    await dayResult(dayOf(off), sleep: {
      'window': {
        'value': {'onset_ms': on * 1000, 'offset_ms': off * 1000},
      },
    });
    await expectLater(
      store.confirm(
        w,
        startTs: on + 600,
        endTs: on + 2400,
        session: {'id': 'suggestion:${w.id}', 'start_ts': on + 600},
      ),
      throwsA(isA<ActivityReviewException>()),
    );
    expect(await db.query('sessions'), isEmpty);
  });
}
