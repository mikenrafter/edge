// The real artifact source over a real database: which keys a
// pass warms, that the warmed rows are the SAME rows and values the screens
// read (one source), and that a warmed artifact is fresh until its inputs move.
//
// API (lib/state/artifact_warmer.dart, next to ArtifactWarmer):
//
//   class RepoArtifactSource implements ArtifactSource {
//     RepoArtifactSource(LocalRepositoryImpl repo);
//     candidateKeys(changedDays): the keys below, in this order, no duplicates:
//        'journal_insights|90d', 'weekday_effect', 'circadian',
//        'beats|<newest day in availableDays()>'       (when any day exists),
//        'workout|<id>'  for every session whose start falls on a changed day,
//        'kcal_minutes|<d>' for every changed day that has decoded raw, plus
//                       every day of the last 3 local days (today, -1, -2: the
//                       raw retention window) that has decoded raw and no
//                       kcal_minutes row yet (days derived before the artifact existed).
//     signature(key) => repo.artifactSignature(key)
//     compute(key)   => repo.computeArtifact(key)
//   }
//
//   LocalRepositoryImpl.computeArtifact(key) returns, per kind, EXACTLY what the
//   matching reader returns (so a warmed row and an on-open row are the same
//   thing), and runs the heavy part off the UI isolate:
//     journal_insights|90d  getJournalInsights(range: '90d')
//     weekday_effect        getWeekdayEffect()          ({} is a valid answer)
//     circadian             getInsights()
//     beats|<day>           {nn, raw_beats, clean_fraction} as
//                           BeatsData.readBeats builds it
//     workout|<id>          getWorkout(id)
//     kcal_minutes|<day>    see calc_kcal_artifact_test.dart

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/data/circadian_artifact.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/state/artifact_warmer.dart';
import 'package:openstrap_edge/ui2/last_result_cache.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';

import 'support/artifact_fixtures.dart';

/// Counts what the real source is asked to compute.
class _Counting implements ArtifactSource {
  _Counting(this.inner);
  final ArtifactSource inner;
  final List<String> computed = [];

  @override
  Future<List<String>> candidateKeys(List<String> changedDays) =>
      inner.candidateKeys(changedDays);
  @override
  Future<String?> signature(String key) => inner.signature(key);
  @override
  Future<Map<String, dynamic>?> compute(String key) {
    computed.add(key);
    return inner.compute(key);
  }
}

Future<Map<String, Object?>?> _row(String key) async {
  final db = await LocalDb.instance;
  final rows = await db.rawQuery(
      'SELECT key, computed_at, payload_json, input_sig FROM last_result '
      'WHERE key = ?',
      [key]);
  return rows.isEmpty ? null : rows.single;
}

Object? _stored(Map<String, Object?> row) =>
    jsonDecode(row['payload_json'] as String);

Object? _json(Object? v) => jsonDecode(jsonEncode(v));

int _lo(String day) => localDayStartSec(day)!;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final repo = artRepo();
  late LastResultCache cache;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_real_source_test.db';
    await databaseFactory.deleteDatabase(
        p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName));
    await LocalDb.instance;
    for (var i = 1; i <= 6; i++) {
      await LocalDb.putJournal(artDay(i), '["coffee"]', '');
      await LocalDb.putDayResult(
        dayId: artDay(i),
        algoVersion: kAlgoVersion,
        payloadJson: '{}',
        windowJson: '{}',
        series: {
          'readiness': 50.0 + i,
          'rmssd': 40.0 + i,
          'rhr': 55.0,
          'efficiency': 90.0
        },
      );
    }
    await LocalDb.putBaseline(
        'crossday',
        jsonEncode({
          'algo_version': kAlgoVersion,
          'built_for_day': todayLabel(),
          'circadian_rhythm': {'present': false},
        }));
    final noon = artNoonSec(1);
    await LocalDb.putSession(artSession('s-today', noon, noon + 1800));
    await LocalDb.putSession(
        artSession('s-older', artNoonSec(5), artNoonSec(5) + 1800));
    // Raw on day -1 (changed), -2 (recent, never had a curve), -20 (old).
    await artRecord(_lo(artDay(1)) + 36000, hr: 80);
    await artRecord(_lo(artDay(2)) + 36000, hr: 80);
    await artRecord(_lo(artDay(20)) + 36000, hr: 80);
  });
  setUp(() async {
    cache = LastResultCache();
    final db = await LocalDb.instance;
    await db.delete('last_result');
  });
  tearDownAll(() async {
    await LocalDb.close();
    await databaseFactory.deleteDatabase(
        p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName));
  });

  test('candidateKeys: the five readers, the newest night, the changed days\' '
      'workouts and curves, and recent days that never had a curve', () async {
    final keys = await RepoArtifactSource(repo).candidateKeys([artDay(1)]);
    expect(keys.take(3), [artJournal, artWeekday, artCircadian]);
    expect(keys, containsAll([
      artBeats(artDay(1)),
      artWorkout('s-today'),
      artKcal(artDay(1)),
      artKcal(artDay(2)),
    ]));
    expect(keys, isNot(contains(artWorkout('s-older'))),
        reason: 'its day did not change');
    expect(keys, isNot(contains(artKcal(artDay(20)))),
        reason: 'past the raw window and not changed');
    expect(keys.toSet().length, keys.length, reason: 'no duplicates');
  });

  test('candidateKeys: a recent day that already has its curve is not listed '
      'unless it changed', () async {
    final db = await LocalDb.instance;
    await db.insert('last_result', {
      'key': artKcal(artDay(2)),
      'computed_at': 1,
      'payload_json': '{}',
      'input_sig': 'x',
    });
    final keys = await RepoArtifactSource(repo).candidateKeys([artDay(1)]);
    expect(keys, contains(artKcal(artDay(1))));
    expect(keys, isNot(contains(artKcal(artDay(2)))));
    final changed = await RepoArtifactSource(repo).candidateKeys([artDay(2)]);
    expect(changed, contains(artKcal(artDay(2))));
  });

  test('candidateKeys: nothing but the global readers when no day has any '
      'session or raw', () async {
    final keys = await RepoArtifactSource(repo).candidateKeys([artDay(30)]);
    expect(keys, containsAll([artJournal, artWeekday, artCircadian]));
    expect(keys.where((k) => k.startsWith('workout|')), isEmpty);
    expect(keys, isNot(contains(artKcal(artDay(30)))),
        reason: 'no raw for that day => no curve to warm');
  });

  test('warming writes the SAME rows and values the readers return, each '
      'with its current signature', () async {
    final src = _Counting(RepoArtifactSource(repo));
    final w = ArtifactWarmer(source: src, cache: cache);
    addTearDown(w.dispose);
    await w.warmAfterPass(changedDays: [artDay(1)]);
    await cache.flush();

    Future<void> expectRow(String key, Object? expected) async {
      final row = await _row(key);
      expect(row, isNotNull, reason: '$key warmed');
      expect(_stored(row!), _json(expected), reason: '$key value');
      expect(row['input_sig'], await artSig(repo, key), reason: '$key sig');
    }

    await expectRow(artJournal, await repo.getJournalInsights(range: '90d'));
    await expectRow(artWeekday, await repo.getWeekdayEffect());
    // The rollup plus everything the Body clock screen draws.
    await expectRow(artCircadian, await buildCircadianArtifact(repo));
    await expectRow(artBeats(artDay(1)), await BeatsData.readBeats(repo, artDay(1)));
    await expectRow(artWorkout('s-today'), await repo.getWorkout('s-today'));
  });

  test('a warmed artifact is fresh: a second pass computes nothing; a '
      'journal edit makes the journal artifact (only it, of the journal '
      'readers\' inputs) recompute', () async {
    final src = _Counting(RepoArtifactSource(repo));
    final w = ArtifactWarmer(source: src, cache: cache);
    addTearDown(w.dispose);
    await w.warmAfterPass(changedDays: [artDay(1)]);
    final first = src.computed.length;
    expect(first, greaterThan(0));
    src.computed.clear();

    await w.warmAfterPass(changedDays: [artDay(1)]);
    expect(src.computed, isEmpty, reason: 'nothing moved');

    await artTick();
    await LocalDb.putJournal(artDay(2), '["tea"]', '');
    await w.warmAfterPass(changedDays: [artDay(1)]);
    expect(src.computed, contains(artJournal));
    expect(src.computed, isNot(contains(artCircadian)));
    expect(src.computed, isNot(contains(artWorkout('s-today'))));
    expect(src.computed.where((k) => k == artJournal).length, 1);
  });

  test('kcal_minutes: a recent day with raw but no curve is warmed from the '
      'substrate; a day with no raw is never stored', () async {
    final src = _Counting(RepoArtifactSource(repo));
    final w = ArtifactWarmer(source: src, cache: cache);
    addTearDown(w.dispose);
    await w.warmAfterPass(changedDays: [artDay(30)]);
    await cache.flush();
    // Day -2 has raw and a complete profile: its single-sample curve exists.
    final row = await _row(artKcal(artDay(2)));
    expect(row, isNotNull);
    expect(row!['input_sig'], await artSig(repo, artKcal(artDay(2))));
    expect(await _row(artKcal(artDay(30))), isNull);
    expect(await _row(artKcal(artDay(20))), isNull);
  });
}
