import '../support/sleep_writes.dart';
// Keeping a nap within 30 minutes of another sleep block needs an explicit,
// approved merge (owner decisions 2026-11-17); nothing is unioned silently.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/data/activity_store.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/data/sleep_editor.dart';
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

  group('proposeNapKeep (30-minute rule)', () {
    test('no neighbour: nothing to merge', () async {
      expect(await repo.proposeNapKeep(t0, t0 + 1800), isNull);
    });

    test('a nap it overlaps proposes the union, keeping the earlier nap',
        () async {
      await addNap(t0, t0 + 1800);
      final r = (await repo.proposeNapKeep(t0 + 1200, t0 + 3000))!;
      expect((r.startTs, r.endTs), (t0, t0 + 3000));
      expect(r.survivor.startTs, t0);
      expect(r.absorbed, isEmpty);
    });

    test('touching and 29:59 both need a merge; exactly 30:00 does not',
        () async {
      await addNap(t0 + 1800, t0 + 3600);
      expect(await repo.proposeNapKeep(t0, t0 + 1800), isNotNull);
      expect(await repo.proposeNapKeep(t0 - 600, t0 + 1800 - 1799), isNotNull);
      // Ends exactly 1800 s before the nap starts.
      expect(await repo.proposeNapKeep(t0 - 1800, t0), isNull);
    });

    test('bridging two naps pulls both into one proposal', () async {
      await addNap(t0, t0 + 1800);
      await addNap(t0 + 3600, t0 + 5400);
      final r = (await repo.proposeNapKeep(t0 + 1500, t0 + 3900))!;
      expect((r.startTs, r.endTs), (t0, t0 + 5400));
      expect(r.participants, hasLength(2));
    });

    test('a chain is followed transitively past the input', () async {
      await addNap(t0, t0 + 1800); // A
      await addNap(t0 + 3000, t0 + 4000); // B, 20 min after A
      final r = (await repo.proposeNapKeep(t0 + 4900, t0 + 5700))!; // 15 min after B
      expect((r.startTs, r.endTs), (t0, t0 + 5700));
      expect(r.participants, hasLength(2));
    });

    test('a rejected nap is not a block', () async {
      await addNap(t0, t0 + 1800, source: 'rejected');
      expect(await repo.proposeNapKeep(t0 + 600, t0 + 2400), isNull);
    });

    test('a sleep_override main sleep is the survivor of a merge', () async {
      final on = t0, off = t0 + 8 * 3600;
      await TestSleepWrites.putSleepOverride(
        dayId: dayOf(off),
        onsetTs: on,
        offsetTs: off,
        source: 'manual',
      );
      final r = (await repo.proposeNapKeep(off - 600, off + 900))!;
      expect((r.startTs, r.endTs), (on, off + 900));
      expect(r.survivor.kind, SleepBlockKind.main);
    });

    test('a main known only from day_result.window_json counts too', () async {
      final on = t0, off = t0 + 8 * 3600;
      await dayResult(
        dayOf(off),
        // The shape day_compute stores: SleepWindow.toJson(), unwrapped.
        windowJson: jsonEncode({
          'onset_ms': on * 1000,
          'offset_ms': off * 1000,
          'spt_sec': off - on,
        }),
      );
      final r = (await repo.proposeNapKeep(on - 900, on + 600))!;
      expect((r.startTs, r.endTs), (on - 900, off));
      expect(r.survivor.kind, SleepBlockKind.main);
    });
  });

  group('commit', () {
    // WHY: keeping a nap near another block is NEVER silent: without the
    // person's approval nothing is written and the suggestion stays pending.
    test('without an approved merge nothing is written', () async {
      final s = await suggest(t0 + 600, t0 + 1800);
      await addNap(t0, t0 + 3600);
      final before = await napRows();
      await expectLater(
        repo.confirmActivity(s),
        throwsA(isA<SleepMergeRequiredException>()),
      );
      expect(await napRows(), before);
      expect((await store.get(s.id))!.status, ActivityReviewStatus.pending);
    });

    // WHY: an approved merge leaves ONE live union; the absorbed nap is a
    // tombstone naming the survivor, and old aggregates do not ride along.
    test('an approved merge writes one union row and tombstones the other',
        () async {
      final s = await suggest(t0 + 1500, t0 + 3900);
      await addNap(t0, t0 + 1800, source: 'confirmed');
      await addNap(t0 + 3600, t0 + 5400, source: 'confirmed');
      final p = (await repo.proposeNapKeep(t0 + 1500, t0 + 3900))!;
      await repo.confirmActivity(s,
          startTs: t0 + 1500, endTs: t0 + 3900, merge: p.authorization);
      final live = (await napRows()).where((r) => r['source'] != 'rejected');
      expect(live, hasLength(1));
      expect((live.single['start_ts'], live.single['end_ts']), (t0, t0 + 5400));
      expect(live.single['source'], 'manual');
      expect('${live.single['payload_json']}', isNot(contains('duration_min')));
      expect((await napRows()).where((r) => r['source'] == 'rejected'),
          hasLength(1));
      expect((await store.get(s.id))!.status, ActivityReviewStatus.confirmed);
    });

    test('an approved merge with a main sleep edits it through the sleep path',
        () async {
      final on = t0, off = t0 + 8 * 3600;
      final s = await suggest(off - 600, off + 900);
      await TestSleepWrites.putSleepOverride(
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
      final p = (await repo.proposeNapKeep(off - 600, off + 900))!;
      await repo.confirmActivity(s,
          startTs: off - 600, endTs: off + 900, merge: p.authorization);
      final ov = (await LocalDb.getSleepOverride(dayOf(off)))!;
      expect((ov['onset_ts'], ov['offset_ts']), (on, off + 900));
      expect(ov['source'], 'manual');
      expect(await napRows(), isEmpty, reason: 'no separate nap row');
      expect(await db.query('wake_confirmation'), isEmpty);
    });

    test('a main known only from window_json becomes an override', () async {
      final on = t0, off = t0 + 8 * 3600;
      await db.update('activity_review_meta', {'activated_at': t0 - 3600});
      final s = await suggest(on - 900, on + 600);
      await dayResult(
        dayOf(off),
        // The shape day_compute stores: SleepWindow.toJson(), unwrapped.
        windowJson: jsonEncode({
          'onset_ms': on * 1000,
          'offset_ms': off * 1000,
          'spt_sec': off - on,
        }),
      );
      expect(await LocalDb.getSleepOverride(dayOf(off)), isNull);
      final p = (await repo.proposeNapKeep(on - 900, on + 600))!;
      await repo.confirmActivity(s,
          startTs: on - 900, endTs: on + 600, merge: p.authorization);
      final ov = (await LocalDb.getSleepOverride(dayOf(off)))!;
      expect((ov['onset_ts'], ov['offset_ts']), (on - 900, off));
      expect(await napRows(), isEmpty);
    });

    // WHY: an approval is for exactly the set the person saw; a nap that lands
    // afterwards is not absorbed silently.
    test('a stale approval is refused and writes nothing', () async {
      final s = await suggest(t0, t0 + 1800);
      await addNap(t0 + 3000, t0 + 3600, source: 'confirmed');
      final p = (await repo.proposeNapKeep(t0, t0 + 1800))!;
      await addNap(t0 - 2400, t0 - 1200, source: 'confirmed'); // arrives after
      final before = await napRows();
      await expectLater(
        repo.confirmActivity(s, merge: p.authorization),
        throwsA(isA<SleepMergeRequiredException>()),
      );
      expect(await napRows(), before);
      expect((await store.get(s.id))!.status, ActivityReviewStatus.pending);
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
