// The REAL range writer against a real (ffi) database and a stub repository:
// where a nap that spans local midnight is filed, how an existing nap is read,
// and the workout call with its type.
//
// Midnight rule, read off the code rather than guessed: the derivation
// attributes a nap to the day it STARTS on (`_attachNaps` drops a nap starting
// at/after the day's end, and the tail of one the previous day owns), and the
// Naps screen files a nap it logs under the day it is shown on, with the start
// on that day. So a 23:40 to 00:20 nap is a `sleep_nap` row of the START's day.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/manual_session.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/gestures/moment_follow_ups.dart';
import 'package:openstrap_edge/gestures/moment_review_apply.dart';
import 'package:openstrap_edge/gestures/moment_review_queue.dart';
import 'package:openstrap_edge/gestures/moment_review_range.dart';
import 'package:openstrap_edge/platform/tasker_moment_export.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../../support/moment_review_fakes.dart';

class _Repo extends LocalRepository {
  _Repo({this.naps = const {}});
  final Map<String, List<Map<String, dynamic>>> naps;
  final workouts = <({int startTs, int endTs, String type})>[];

  @override
  Future<Map<String, dynamic>> getDayNaps(String date) async =>
      {if (naps[date] != null) 'naps': naps[date]};

  @override
  Future<List<SessionSpan>> savedSessionSpans() async => const [];

  @override
  Future<Map<String, dynamic>> logManualWorkout(
      {required int startTs, required int endTs, required String type}) async {
    workouts.add((startTs: startTs, endTs: endTs, type: type));
    return {'workout_id': 'manual:$startTs'};
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final created = <String>[];
  var n = 0;
  Future<String> path(String name) async =>
      p.join(await databaseFactory.getDatabasesPath(), name);

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  tearDownAll(() async {
    await LocalDb.close();
    for (final c in created) {
      await databaseFactory.deleteDatabase(await path(c));
    }
  });
  setUp(() async {
    final name = 'openstrap_review_range_${n++}.db';
    created.add(name);
    await LocalDb.close();
    await databaseFactory.deleteDatabase(await path(name));
    LocalDb.lastRebuild = null;
    LocalDb.dbName = name;
    await LocalDb.instance;
  });

  MomentReviewApplier applierFor(_Repo repo) => MomentReviewApplier(
      writer: FakeAnswerWriter(),
      assumedWriter: FakeGlassWriter(),
      ranges: ReviewRangeWriter(repo: repo),
      exporter: TaskerMomentExport(connectionOn: () => false));

  test('a nap over local midnight is one manual nap edit on the START day',
      () async {
    final rep = await applierFor(_Repo()).apply(
        MomentReviewQueue.empty.withRange(mLate, mEarly, MomentChoice.nap),
        moments: [mLate, mEarly],
        glasses: const [],
        now: reviewNow);
    expect(rep.failed, isEmpty);
    final start = await LocalDb.napEdits('2026-10-05');
    expect(start, hasLength(1));
    expect(start.single['source'], 'manual');
    expect(start.single['start_ts'], sec(2026, 10, 5, 23, 40));
    expect(start.single['end_ts'], sec(2026, 10, 6, 0, 20));
    expect(await LocalDb.napEdits('2026-10-06'), isEmpty,
        reason: 'the end day does not also get it (it would double-count)');
  });

  test('writing the same range twice is one row (retry-safe)', () async {
    final q = MomentReviewQueue.empty.withRange(mA, mB, MomentChoice.nap);
    final a = applierFor(_Repo());
    await a.apply(q, moments: [mA, mB], glasses: const [], now: reviewNow);
    // The first try's row is now an "existing nap": a retry must not trip
    // over its own window.
    final again =
        await a.apply(q, moments: [mA, mB], glasses: const [], now: reviewNow);
    expect(again.failed, isEmpty);
    expect(await LocalDb.napEdits('2026-10-06'), hasLength(1));
  });

  test('existingNaps: the day\'s merged naps plus stored manual edits',
      () async {
    await LocalDb.putNapEdit(
        dayId: '2026-10-06',
        startTs: sec(2026, 10, 6, 15, 0),
        endTs: sec(2026, 10, 6, 15, 30),
        source: 'manual');
    await LocalDb.putNapEdit(
        dayId: '2026-10-06',
        startTs: sec(2026, 10, 6, 16, 0),
        endTs: sec(2026, 10, 6, 16, 30),
        source: 'rejected');
    final w = ReviewRangeWriter(
        repo: _Repo(naps: {
      '2026-10-06': [
        {'start': sec(2026, 10, 6, 13, 0), 'end': sec(2026, 10, 6, 13, 40)}
      ]
    }));
    final got = await w.existingNaps('2026-10-06');
    expect(got.map((e) => e['start']),
        unorderedEquals([sec(2026, 10, 6, 13, 0), sec(2026, 10, 6, 15, 0)]),
        reason: 'a rejection is not a nap');
  });

  test('a nap overlapping a stored manual edit is refused', () async {
    await LocalDb.putNapEdit(
        dayId: '2026-10-06',
        startTs: sec(2026, 10, 6, 9, 30),
        endTs: sec(2026, 10, 6, 9, 50),
        source: 'manual');
    final rep = await applierFor(_Repo()).apply(
        MomentReviewQueue.empty.withRange(mA, mB, MomentChoice.nap),
        moments: [mA, mB],
        glasses: const [],
        now: reviewNow);
    expect(rep.failed, hasLength(1));
    expect(await LocalDb.napEdits('2026-10-06'), hasLength(1));
  });

  test('the workout goes to logManualWorkout with the chosen type, "other" by '
      'default', () async {
    final repo = _Repo();
    final a = applierFor(repo);
    await a.apply(
        MomentReviewQueue.empty
            .withRange(mA, mB, MomentChoice.workout, workoutType: 'running'),
        moments: [mA, mB],
        glasses: const [],
        now: reviewNow);
    await a.apply(
        MomentReviewQueue.empty.withRange(mLate, mEarly, MomentChoice.workout),
        moments: [mLate, mEarly],
        glasses: const [],
        now: reviewNow);
    expect(repo.workouts.map((w) => w.type), ['running', 'other']);
    expect(repo.workouts.first.startTs, sec(2026, 10, 6, 9, 15));
  });
}
