// 8AG-perf P3-A: artifact input signatures.
//
// A slow screen read becomes an ARTIFACT with a signature of the inputs it
// reads. Same signature => the stored result is still right and is not
// recomputed. This file pins WHAT MOVES each signature and what must not.
//
// ASSUMED API (see support/p3_support.dart for the shared surface):
//
//   LocalRepositoryImpl.artifactSignature(String key) -> Future<String?>
//
// FORMAT. `'${kAlgoVersion}|<opaque>'`; the part after the first '|' is the
// implementer's. Null for: an unknown kind, `workout|<id>` of a session that
// does not exist, `kcal_minutes|<day>` of a day with no decoded raw. Everything
// else always answers a string (an empty database has a signature too; "nothing
// yet" is a state, not an error).
//
// WHAT EACH KIND READS (all cheap indexed reads, never a payload decode):
//
//   journal_insights|90d  max(day_result.computed_at) and the newest day over
//                         the day_results INSIDE the 90-day window + the journal
//                         input revision: row count and max(updated_at) of the
//                         `journal` AND `journal_metric` rows inside the window.
//   weekday_effect        the same day_result part over the WHOLE series (the
//                         analytics floor is 8 weeks, not 90 days).
//   beats|<D>             `decodedDayFingerprints` of D and of D-1 (the night
//                         spans the midnight) + D's own day_result computed_at
//                         (`getNightBeats` reads its window out of that row, so
//                         a re-derive that moves the window moves the beats even
//                         when the decoded rows did not).
//   workout|<id>          the session row's score/time fields (start_ts, end_ts,
//                         status, calories, strain, max_hr, duration_min, steps,
//                         rpe, trace_samples, zone_min_json: `sessions` has no
//                         updated_at, so the fields themselves) + the
//                         fingerprints of every local day the [start_ts, end_ts]
//                         window spans.
//   circadian             `baselines` row 'crossday' updated_at (+ presence).
//   kcal_minutes|<D>      decodedDayFingerprints[D] + the profile calorie
//                         anchors (age, weight, height, sex, resting HR) as the
//                         repository's getProfileMap() reports them.
//
// NEVER moved by: a write to `last_result` (the warmer storing the artifact must
// not invalidate its own signature), or by data a kind does not read.
//
// Writes are separated by `p3Tick()` (6 ms) because the inputs are stamped in
// epoch milliseconds.
//
// Failure mode today: `artifactSignature` does not exist (NoSuchMethodError),
// reached through `dynamic`, so each test fails by itself.

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/journal_fields.dart';
import 'package:openstrap_edge/ui2/last_result_cache.dart';

import 'support/p3_support.dart';

const _all = [p3Journal, p3Weekday, p3Circadian];

int _lo(String day) => localDayStartSec(day)!;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_p3_signature_test.db';
    await databaseFactory.deleteDatabase(
        p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName));
  });
  tearDownAll(() async {
    await LocalDb.close();
    await databaseFactory.deleteDatabase(
        p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName));
  });

  final repo = p3Repo();

  group('format', () {
    test('every kind answers "<kAlgoVersion>|..." on an empty database',
        () async {
      for (final k in [..._all, p3Beats(p3Day(1))]) {
        final s = await p3Sig(repo, k);
        expect(s, isNotNull, reason: '$k has a signature even with no data');
        expect(s, startsWith('$kAlgoVersion|'), reason: k);
      }
    });

    test('unknown kinds, a missing session and a day with no raw are null',
        () async {
      expect(await p3Sig(repo, 'nope|x'), isNull);
      expect(await p3Sig(repo, p3Workout('no-such-session')), isNull);
      expect(await p3Sig(repo, p3Kcal(p3Day(2))), isNull,
          reason: 'no raw => no curve => nothing to key on');
    });

    test('unchanged inputs => the same signature, every time', () async {
      for (final k in [..._all, p3Beats(p3Day(1))]) {
        expect(await p3Sig(repo, k), await p3Sig(repo, k), reason: k);
      }
    });

    test('writing the artifact itself (last_result) does not move any '
        'signature', () async {
      final before = {
        for (final k in [..._all, p3Beats(p3Day(1))]) k: await p3Sig(repo, k)
      };
      final c = LastResultCache();
      for (final k in before.keys) {
        c.put<Map<String, dynamic>>(k, {'a': 1});
      }
      await c.flush();
      for (final e in before.entries) {
        expect(await p3Sig(repo, e.key), e.value, reason: e.key);
      }
    });
  });

  group('journal_insights|90d', () {
    test('a new day_result inside the window changes it', () async {
      final before = await p3Sig(repo, p3Journal);
      await p3Tick();
      await p3PutDay(p3Day(3));
      expect(await p3Sig(repo, p3Journal), isNot(before));
    });

    test('a re-derive of a day already in the window (same day, new '
        'computed_at) changes it', () async {
      await p3PutDay(p3Day(4));
      await p3Tick();
      final before = await p3Sig(repo, p3Journal);
      await p3Tick();
      await p3PutDay(p3Day(4), readiness: 61);
      expect(await p3Sig(repo, p3Journal), isNot(before));
    });

    test('a day_result OLDER than the window does not', () async {
      final before = await p3Sig(repo, p3Journal);
      await p3Tick();
      await p3PutDay(p3Day(200));
      expect(await p3Sig(repo, p3Journal), before);
    });

    test('a journal tag edit changes it', () async {
      final d = p3Day(5);
      await LocalDb.putJournal(d, '["coffee"]', '');
      await p3Tick();
      final before = await p3Sig(repo, p3Journal);
      await p3Tick();
      await LocalDb.putJournal(d, '["tea"]', '');
      expect(await p3Sig(repo, p3Journal), isNot(before));
    });

    test('a first journal entry (row count) changes it', () async {
      final before = await p3Sig(repo, p3Journal);
      await p3Tick();
      await LocalDb.putJournal(p3Day(6), '["x"]', '');
      expect(await p3Sig(repo, p3Journal), isNot(before));
    });

    test('a numeric journal field edit changes it', () async {
      final d = p3Day(7);
      await LocalDb.putJournalMetrics(d, {'caffeine_mg': const JournalMetricValue(100)});
      await p3Tick();
      final before = await p3Sig(repo, p3Journal);
      await p3Tick();
      await LocalDb.putJournalMetrics(d, {'caffeine_mg': const JournalMetricValue(300)});
      expect(await p3Sig(repo, p3Journal), isNot(before));
    });

    test('deleting a journal row (count drops) changes it', () async {
      final d = p3Day(8);
      await LocalDb.putJournal(d, '["a"]', '');
      final before = await p3Sig(repo, p3Journal);
      final db = await LocalDb.instance;
      await db.delete('journal', where: 'date = ?', whereArgs: [d]);
      expect(await p3Sig(repo, p3Journal), isNot(before));
    });

    test('a journal edit OUTSIDE the 90-day window does not', () async {
      final before = await p3Sig(repo, p3Journal);
      await p3Tick();
      await LocalDb.putJournal(p3Day(200), '["old"]', '');
      expect(await p3Sig(repo, p3Journal), before);
    });
  });

  group('weekday_effect', () {
    test('a new day_result changes it, however old (it reads the whole '
        'series)', () async {
      final before = await p3Sig(repo, p3Weekday);
      await p3Tick();
      await p3PutDay(p3Day(210));
      final after = await p3Sig(repo, p3Weekday);
      expect(after, isNot(before));
      await p3Tick();
      await p3PutDay(p3Day(1));
      expect(await p3Sig(repo, p3Weekday), isNot(after));
    });

    test('a re-derive of an existing day changes it', () async {
      await p3PutDay(p3Day(9));
      await p3Tick();
      final before = await p3Sig(repo, p3Weekday);
      await p3Tick();
      await p3PutDay(p3Day(9), readiness: 70);
      expect(await p3Sig(repo, p3Weekday), isNot(before));
    });

    test('a decoded write does not (it reads derived scalars only)', () async {
      final before = await p3Sig(repo, p3Weekday);
      await p3Record(_lo(p3Day(40)) + 3600);
      expect(await p3Sig(repo, p3Weekday), before);
    });
  });

  group('beats|<night day>', () {
    test('a decoded REPLACE on the night changes it', () async {
      final d = p3Day(41);
      final t = _lo(d) + 7200;
      await p3Record(t, hr: 60);
      await p3Record(t + 1, hr: 61);
      final before = await p3Sig(repo, p3Beats(d));
      await p3Record(t + 1, hr: 99); // same second, new contents
      expect(await p3Sig(repo, p3Beats(d)), isNot(before));
    });

    test('an RR-only write on the night changes it (the beats ARE the RR)',
        () async {
      final d = p3Day(42);
      final t = _lo(d) + 7200;
      await p3Record(t);
      final before = await p3Sig(repo, p3Beats(d));
      await p3Rr(t, beat: 2, ms: 811);
      expect(await p3Sig(repo, p3Beats(d)), isNot(before));
    });

    test('a decoded REPLACE on the PREVIOUS day (the evening before) changes '
        'it', () async {
      final d = p3Day(43);
      final prev = p3Day(44);
      final tp = _lo(prev) + 80000; // late evening of D-1
      await p3Record(tp, hr: 60);
      await p3Record(_lo(d) + 600, hr: 58);
      final before = await p3Sig(repo, p3Beats(d));
      await p3Record(tp, hr: 95);
      expect(await p3Sig(repo, p3Beats(d)), isNot(before));
    });

    test('a write on an unrelated day (D+2, D-3) does not', () async {
      final d = p3Day(46);
      await p3Record(_lo(d) + 7200);
      final before = await p3Sig(repo, p3Beats(d));
      await p3Record(_lo(p3Day(44)) + 7200, hr: 70); // D+2
      await p3Record(_lo(p3Day(49)) + 7200, hr: 70); // D-3
      expect(await p3Sig(repo, p3Beats(d)), before);
    });

    test('a re-derive of the night (day_result row rewritten: its window may '
        'have moved) changes it even though no decoded row did', () async {
      final d = p3Day(50);
      await p3Record(_lo(d) + 7200);
      await p3PutDay(d);
      await p3Tick();
      final before = await p3Sig(repo, p3Beats(d));
      await p3Tick();
      await p3PutDay(d, readiness: 66);
      expect(await p3Sig(repo, p3Beats(d)), isNot(before));
    });
  });

  group('workout|<id>', () {
    Future<void> put(Map<String, dynamic> row) => LocalDb.putSession(row);

    test('a session edit changes it (calories, strain, end, rpe)', () async {
      final noon = p3NoonSec(51);
      await put(p3Session('w-edit', noon, noon + 1800));
      var before = await p3Sig(repo, p3Workout('w-edit'));
      expect(before, isNotNull);

      Future<void> expectMoves(String what, Map<String, dynamic> row) async {
        await p3Tick();
        await put(row);
        final after = await p3Sig(repo, p3Workout('w-edit'));
        expect(after, isNot(before), reason: what);
        before = after;
      }

      await expectMoves('calories',
          p3Session('w-edit', noon, noon + 1800, calories: 250));
      await expectMoves(
          'strain', p3Session('w-edit', noon, noon + 1800, calories: 250, strain: 9));
      await expectMoves('end_ts (retimed)',
          p3Session('w-edit', noon, noon + 2400, calories: 250, strain: 9));
      await expectMoves(
          'rpe',
          p3Session('w-edit', noon, noon + 2400,
              calories: 250, strain: 9, rpe: 7));
    });

    test('a score re-write through setSessionScores changes it', () async {
      final noon = p3NoonSec(52);
      await put(p3Session('w-score', noon, noon + 1800));
      final before = await p3Sig(repo, p3Workout('w-score'));
      await LocalDb.setSessionScores('w-score',
          strain: 11.5, calories: 321, maxHr: 181, zoneMinJson: '[1,2,3,4,5]');
      expect(await p3Sig(repo, p3Workout('w-score')), isNot(before));
    });

    test('another session\'s edit does not', () async {
      final noon = p3NoonSec(53);
      await put(p3Session('w-mine', noon, noon + 1800));
      await put(p3Session('w-other', noon + 4000, noon + 5000));
      final before = await p3Sig(repo, p3Workout('w-mine'));
      await put(p3Session('w-other', noon + 4000, noon + 5000, calories: 999));
      expect(await p3Sig(repo, p3Workout('w-mine')), before);
    });

    test('a decoded REPLACE inside the session window\'s day changes it',
        () async {
      final noon = p3NoonSec(54);
      await put(p3Session('w-raw', noon, noon + 1800));
      await p3Record(noon + 60, hr: 120);
      final before = await p3Sig(repo, p3Workout('w-raw'));
      await p3Record(noon + 60, hr: 155);
      expect(await p3Sig(repo, p3Workout('w-raw')), isNot(before));
    });

    test('a window that crosses midnight depends on BOTH days', () async {
      final d = p3Day(55);
      final next = p3Day(54);
      final start = _lo(next) - 1800, end = _lo(next) + 1800;
      await put(p3Session('w-mid', start, end));
      await p3Record(start + 10, hr: 100);
      await p3Record(end - 10, hr: 100);
      final before = await p3Sig(repo, p3Workout('w-mid'));
      await p3Record(end - 10, hr: 130); // the day AFTER midnight
      final after = await p3Sig(repo, p3Workout('w-mid'));
      expect(after, isNot(before), reason: '$next is spanned by the window');
      await p3Record(start + 10, hr: 130); // the day BEFORE
      expect(await p3Sig(repo, p3Workout('w-mid')), isNot(after),
          reason: '$d is spanned too');
    });

    test('a decoded write on a day the window does not span does not',
        () async {
      final noon = p3NoonSec(56);
      await put(p3Session('w-far', noon, noon + 1800));
      await p3Record(noon + 60);
      final before = await p3Sig(repo, p3Workout('w-far'));
      await p3Record(_lo(p3Day(60)) + 3600, hr: 90);
      expect(await p3Sig(repo, p3Workout('w-far')), before);
    });

    test('deleting the session makes it null', () async {
      final noon = p3NoonSec(57);
      await put(p3Session('w-gone', noon, noon + 1800));
      expect(await p3Sig(repo, p3Workout('w-gone')), isNotNull);
      await LocalDb.deleteSession('w-gone');
      expect(await p3Sig(repo, p3Workout('w-gone')), isNull);
    });
  });

  group('circadian', () {
    test('a new cross-day rollup (baselines.crossday updated_at) changes it',
        () async {
      await LocalDb.putBaseline('crossday', '{"a":1}');
      final before = await p3Sig(repo, p3Circadian);
      await p3Tick();
      await LocalDb.putBaseline('crossday', '{"a":1}'); // same payload, new stamp
      expect(await p3Sig(repo, p3Circadian), isNot(before));
    });

    test('another baseline key does not', () async {
      final before = await p3Sig(repo, p3Circadian);
      await p3Tick();
      await LocalDb.putBaseline('not_crossday', '{}');
      expect(await p3Sig(repo, p3Circadian), before);
    });

    test('the first rollup (none -> some) changes it', () async {
      final db = await LocalDb.instance;
      await db.delete('baselines', where: 'key = ?', whereArgs: ['crossday']);
      final none = await p3Sig(repo, p3Circadian);
      await LocalDb.putBaseline('crossday', '{}');
      expect(await p3Sig(repo, p3Circadian), isNot(none));
    });
  });

  group('kcal_minutes|<day>', () {
    test('non-null once the day has raw; a decoded REPLACE changes it; an '
        'unrelated day does not', () async {
      final d = p3Day(61);
      await p3Record(_lo(d) + 36000, hr: 80);
      final before = await p3Sig(repo, p3Kcal(d));
      expect(before, isNotNull);
      await p3Record(_lo(p3Day(63)) + 36000, hr: 80);
      expect(await p3Sig(repo, p3Kcal(d)), before);
      await p3Record(_lo(d) + 36000, hr: 140);
      expect(await p3Sig(repo, p3Kcal(d)), isNot(before));
    });

    test('a profile calorie anchor change (weight) changes it', () async {
      final d = p3Day(64);
      await p3Record(_lo(d) + 36000, hr: 80);
      final profile = {...p3ProfileMap};
      final r = p3Repo(profile: profile);
      final before = await p3Sig(r, p3Kcal(d));
      profile['weight_kg'] = 80.0;
      expect(await p3Sig(r, p3Kcal(d)), isNot(before));
    });
  });

  group('cheap: a 90-day database', () {
    test('every kind signs in well under ~20 ms and never decodes a payload',
        () async {
      final db = await LocalDb.instance;
      final batch = db.batch();
      // Not JSON on purpose: a signature that decoded payloads would throw (or
      // take far longer than the budget below).
      final junk = '{' * 60000;
      for (var back = 0; back < 90; back++) {
        batch.insert('day_result', {
          'day_id': p3Day(300 + back),
          'algo_version': kAlgoVersion,
          'payload_json': junk,
          'window_json': '{}',
          'computed_at': DateTime.now().millisecondsSinceEpoch - back * 1000,
          'finalized': 1,
        });
        batch.insert(
            'journal',
            {
              'date': p3Day(back),
              'tags_json': '["t$back"]',
              'note': '',
              'updated_at': DateTime.now().millisecondsSinceEpoch - back,
            },
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
      final d = p3Day(65);
      await p3Record(_lo(d) + 3600);
      final noon = p3NoonSec(65);
      await LocalDb.putSession(p3Session('w-cheap', noon, noon + 1800));

      for (final k in [
        p3Journal,
        p3Weekday,
        p3Circadian,
        p3Beats(d),
        p3Workout('w-cheap'),
        p3Kcal(d),
      ]) {
        await p3Sig(repo, k); // warm the connection / statement caches
        final times = <int>[];
        for (var i = 0; i < 7; i++) {
          final sw = Stopwatch()..start();
          final s = await p3Sig(repo, k);
          sw.stop();
          expect(s, isNotNull, reason: k);
          times.add(sw.elapsedMicroseconds);
        }
        times.sort();
        final median = times[times.length ~/ 2] / 1000.0;
        expect(median, lessThan(20.0),
            reason: '$k median ${median.toStringAsFixed(1)} ms');
      }
    });
  });
}
