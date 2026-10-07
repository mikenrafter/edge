// What each answer to a marked moment writes, against a REAL sqflite_ffi
// database.
//
// Journal fields that exist (lib/data/journal_fields.dart) are all numeric
// (mood, sleep_quality, energy, stress, soreness, water_ml, caffeine_mg,
// alcohol_units, screens_min, weight_kg), so there is no yes/no field to set to
// true. The mapping is:
//   Caffeine -> caffeine_mg, Alcohol -> alcohol_units: the amount is ASKED, and
//     with no amount only the label is stored (a dose is never guessed);
//   Pills & meds, Nap, Meal, Workout, Symptom, Other -> the label alone.
// Every answer stores the moment's label; a nap never creates a sleep window.

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/journal_fields.dart';
import 'package:openstrap_edge/gestures/moment_follow_ups.dart';

const _m = PendingMoment(date: '2026-10-06', hhmm: '10:15'); // minute 615
final _now = DateTime(2026, 10, 7, 12, 0);
const _writer = MomentAnswerWriter();

Future<String> _path(String name) async =>
    p.join(await databaseFactory.getDatabasesPath(), name);

var _n = 0;
Future<void> _fresh(List<String> created) async {
  final name = 'openstrap_moment_answers_${_n++}.db';
  created.add(name);
  await LocalDb.close();
  await databaseFactory.deleteDatabase(await _path(name));
  LocalDb.lastRebuild = null;
  LocalDb.dbName = name;
  await LocalDb.instance;
  expect(LocalDb.lastRebuild, isNull);
  // The day the moment was marked on: the journal tag the gesture wrote.
  await LocalDb.putJournal(_m.date, '["moment 10:15"]', 'a note');
}

Future<List<Map<String, Object?>>> _all(String table) async =>
    (await LocalDb.instance).query(table);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final created = <String>[];

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  tearDownAll(() async {
    await LocalDb.close();
    for (final n in created) {
      await databaseFactory.deleteDatabase(await _path(n));
    }
  });
  setUp(() => _fresh(created));

  group('journal-field mapping', () {
    test('Caffeine with an amount writes caffeine_mg for that local day, at '
        "the moment's minute", () async {
      final r = await _writer.answer(_m, MomentChoice.caffeine,
          value: 95, now: _now);
      expect(r, MomentAnswerResult.saved);
      final rows = await _all('journal_metric');
      expect(rows, hasLength(1));
      expect(rows.single['date'], '2026-10-06');
      expect(rows.single['field'], 'caffeine_mg');
      expect(rows.single['value'], 95);
      expect(rows.single['at_min'], 10 * 60 + 15);
      // The label is stored too.
      final labels = await LocalDb.momentLabels(date: _m.date);
      expect(labels.single.label, 'caffeine');
      expect(labels.single.hhmm, '10:15');
    });

    test('the field is one that exists today', () {
      expect(kJournalFieldsByKey[MomentChoice.caffeine.journalField], isNotNull);
      expect(kJournalFieldsByKey[MomentChoice.alcohol.journalField], isNotNull);
      for (final c in MomentChoice.values.where((c) => c.journalField != null)) {
        expect(kJournalFieldsByKey[c.journalField]!.kind,
            JournalFieldKind.dose);
      }
    });

    test('Alcohol with units writes alcohol_units', () async {
      await _writer.answer(_m, MomentChoice.alcohol, value: 2, now: _now);
      final rows = await _all('journal_metric');
      expect(rows.single['field'], 'alcohol_units');
      expect(rows.single['value'], 2);
      expect(rows.single['at_min'], 615);
    });

    test('a dose is ADDED to the day total; the time is the latest; other '
        'fields of the day survive', () async {
      await LocalDb.putJournalMetrics(_m.date, const {
        'mood': JournalMetricValue(4),
        'caffeine_mg': JournalMetricValue(100, atMinuteOfDay: 8 * 60),
      });
      await _writer.answer(_m, MomentChoice.caffeine, value: 80, now: _now);
      final day = await LocalDb.journalMetricsForDay(_m.date);
      expect(day['mood'], const JournalMetricValue(4),
          reason: 'putJournalMetrics replaces the whole day; do not lose it');
      expect(day['caffeine_mg'],
          const JournalMetricValue(180, atMinuteOfDay: 615));
    });

    test('a later existing time stays the latest', () async {
      await LocalDb.putJournalMetrics(_m.date, const {
        'caffeine_mg': JournalMetricValue(100, atMinuteOfDay: 20 * 60),
      });
      await _writer.answer(_m, MomentChoice.caffeine, value: 80, now: _now);
      final day = await LocalDb.journalMetricsForDay(_m.date);
      expect(day['caffeine_mg'],
          const JournalMetricValue(180, atMinuteOfDay: 20 * 60));
    });

    test('Caffeine with NO amount stores only the label (no metric invented)',
        () async {
      await _writer.answer(_m, MomentChoice.caffeine, now: _now);
      expect(await _all('journal_metric'), isEmpty);
      expect((await LocalDb.momentLabels(date: _m.date)).single.label,
          'caffeine');
    });

    test('an amount that is zero, negative or above the field ceiling is '
        'refused and nothing is written', () async {
      for (final v in [0.0, -5.0, 100000.0]) {
        await expectLater(
            _writer.answer(_m, MomentChoice.caffeine, value: v, now: _now),
            throwsArgumentError,
            reason: '$v');
      }
      expect(await _all('journal_metric'), isEmpty);
      expect(await LocalDb.momentLabels(date: _m.date), isEmpty,
          reason: 'a refused answer leaves the moment pending');
    });

    test('the journal tag the gesture wrote is untouched', () async {
      await _writer.answer(_m, MomentChoice.caffeine, value: 50, now: _now);
      final j = (await _all('journal')).single;
      expect(j['tags_json'], '["moment 10:15"]');
      expect(j['note'], 'a note');
    });

    test('the dose lands on the MOMENT\'s local day, not on today', () async {
      await _writer.answer(_m, MomentChoice.alcohol, value: 1, now: _now);
      expect((await _all('journal_metric')).single['date'], '2026-10-06');
    });
  });

  group('label-only answers', () {
    for (final c in [
      MomentChoice.pillsMeds,
      MomentChoice.meal,
      MomentChoice.symptom,
    ]) {
      test('${c.label}: the label, and no journal metric', () async {
        await _writer.answer(_m, c, now: _now);
        final l = (await LocalDb.momentLabels(date: _m.date)).single;
        expect(l.label, c.id);
        expect(l.note, isNull);
        expect(l.answeredAtMs, _now.millisecondsSinceEpoch);
        expect(await _all('journal_metric'), isEmpty);
      });
    }

    test('Nap stores only the label: no sleep window, no session, no metric',
        () async {
      await _writer.answer(_m, MomentChoice.nap, now: _now);
      expect((await LocalDb.momentLabels(date: _m.date)).single.label, 'nap');
      expect(await _all('sleep_nap'), isEmpty);
      expect(await _all('sleep_override'), isEmpty);
      expect(await _all('sessions'), isEmpty);
      expect(await _all('journal_metric'), isEmpty);
    });

    test('Workout stores the label; the session comes only from the log flow',
        () async {
      await _writer.answer(_m, MomentChoice.workout, now: _now);
      expect((await LocalDb.momentLabels(date: _m.date)).single.label,
          'workout');
      expect(await _all('sessions'), isEmpty);
    });

    test('Other keeps its note, trimmed; an empty note is null', () async {
      await _writer.answer(_m, MomentChoice.other,
          note: '  felt dizzy  ', now: _now);
      expect((await LocalDb.momentLabels(date: _m.date)).single.note,
          'felt dizzy');

      const m2 = PendingMoment(date: '2026-10-06', hhmm: '11:00');
      await _writer.answer(m2, MomentChoice.other, note: '   ', now: _now);
      final l = (await LocalDb.momentLabels(date: _m.date))
          .firstWhere((x) => x.hhmm == '11:00');
      expect(l.note, isNull);
    });
  });

  group('Skip', () {
    test('answered with no label, nothing else written', () async {
      final r = await _writer.skip(_m, now: _now);
      expect(r, MomentAnswerResult.saved);
      final l = (await LocalDb.momentLabels(date: _m.date)).single;
      expect(l.label, isNull);
      expect(l.hhmm, '10:15');
      expect(l.answeredAtMs, _now.millisecondsSinceEpoch);
      expect(await _all('journal_metric'), isEmpty);
    });

    test('a skipped moment is not pending any more', () async {
      await _writer.skip(_m, now: _now);
      final f = await MomentFollowUps.load(
          enabledSince: DateTime(2026, 10, 1));
      expect(f.pending(_now), isEmpty);
    });
  });

  group('idempotence', () {
    test('answering the same moment twice does not double the dose', () async {
      await _writer.answer(_m, MomentChoice.caffeine, value: 80, now: _now);
      final again =
          await _writer.answer(_m, MomentChoice.caffeine, value: 80, now: _now);
      expect(again, MomentAnswerResult.alreadyAnswered);
      expect((await LocalDb.journalMetricsForDay(_m.date))['caffeine_mg']!.value,
          80);
      expect(await LocalDb.momentLabels(date: _m.date), hasLength(1));
    });

    test('a skipped moment cannot be answered afterwards by a stale screen',
        () async {
      await _writer.skip(_m, now: _now);
      final r = await _writer.answer(_m, MomentChoice.nap, now: _now);
      expect(r, MomentAnswerResult.alreadyAnswered);
      expect((await LocalDb.momentLabels(date: _m.date)).single.label, isNull);
    });
  });

  group('MomentFollowUps.load reads the real stores', () {
    test('journal tags become pending moments; an answer removes one',
        () async {
      await LocalDb.putJournal(
          '2026-10-07', '["gym","moment 07:05","moment 09:00"]', '');
      // A day with no moments, and a tag that only looks like one.
      await LocalDb.putJournal('2026-10-05', '["moments 08:00"]', 'x');
      final since = DateTime(2026, 10, 1);

      var f = await MomentFollowUps.load(enabledSince: since);
      expect([for (final m in f.pending(_now)) m.key], [
        '2026-10-06 10:15',
        '2026-10-07 07:05',
        '2026-10-07 09:00',
      ]);

      await _writer.answer(
          const PendingMoment(date: '2026-10-07', hhmm: '07:05'),
          MomentChoice.nap,
          now: _now);
      f = await MomentFollowUps.load(enabledSince: since);
      expect([for (final m in f.pending(_now)) m.key],
          ['2026-10-06 10:15', '2026-10-07 09:00']);
    });

    test('with the setting off (null since) nothing is pending', () async {
      final f = await MomentFollowUps.load(enabledSince: null);
      expect(f.pending(_now), isEmpty);
    });
  });
}
