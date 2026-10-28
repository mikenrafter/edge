// Changing an ANSWERED marked moment (CLS-1, RED).
//
// Spec: edge.research/wake-pr/cls1-edit-moment.md. Today `answerMoment` and
// `answerMomentSymptom` refuse a moment that already has an answer, so a wrong
// label or amount can never be fixed. `LocalDb.changeMomentAnswer` replaces the
// saved answer in ONE transaction and redoes what the old answer wrote:
//
//   * the `moment_label` row (replaced in place, never a second row);
//   * the dose it ADDED to the day's journal field (taken back exactly, then the
//     new dose added). What an answer added is kept in `moment_label.metric_value`
//     (the amount after any clamp), because alcohol and water amounts are
//     stored nowhere else;
//   * the `symptom_entry` row (one per moment);
//   * the track feed, which is a VIEW over moment_label + journal_metric, and the
//     `wake_meta` remainder-minute key (CLAIM(remainder-time-fresh)).
//
// Staleness: the editor passes the answer it opened on ([before]). If the stored
// row is no longer that (label, note, amounts, answered_at), nothing is written.
// Every case other than MomentChanged leaves the database as it was.
//
// Real sqflite_ffi database, same idiom as answer_writer_test.dart. Dates are
// calendar labels, so the results do not depend on the host zone.

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/journal_fields.dart';
import 'package:openstrap_edge/data/moment_label.dart';
import 'package:openstrap_edge/gestures/moment_follow_ups.dart';
import 'package:openstrap_edge/gestures/symptom_description.dart';

const _date = '2026-10-06';
const _m = PendingMoment(date: _date, hhmm: '10:15'); // minute 615
const _m2 = PendingMoment(date: _date, hhmm: '15:40'); // minute 940
final _t1 = DateTime(2026, 10, 7, 12, 0);
final _t2 = DateTime(2026, 10, 7, 12, 5);
const _writer = MomentAnswerWriter();
const _knee = SymptomDescription(
  severity: SymptomSeverity.moderate,
  side: SymptomSide.left,
  kind: SymptomKind.pain,
  area: SymptomArea.knees,
);
const _head = SymptomDescription(
  severity: SymptomSeverity.mild,
  kind: SymptomKind.pain,
  area: SymptomArea.forehead,
);

Future<String> _path(String name) async =>
    p.join(await databaseFactory.getDatabasesPath(), name);

var _n = 0;
Future<void> _fresh(List<String> created) async {
  final name = 'openstrap_change_answer_${_n++}.db';
  created.add(name);
  await LocalDb.close();
  await databaseFactory.deleteDatabase(await _path(name));
  LocalDb.lastRebuild = null;
  LocalDb.dbName = name;
  await LocalDb.instance;
  await LocalDb.putJournal(
      _date, '["moment 10:15","moment 15:40"]', 'a note');
}

Future<List<Map<String, Object?>>> _all(String table) async =>
    (await LocalDb.instance).query(table, orderBy: 'rowid');

/// Every table an answer can touch, for before/after equality.
Future<Map<String, List<Map<String, Object?>>>> _snapshot() async => {
      for (final t in [
        'moment_label',
        'journal_metric',
        'symptom_entry',
        'wake_meta',
        'sessions',
        'sleep_nap',
      ])
        t: await _all(t),
    };

Future<MomentLabel> _saved(PendingMoment m) async =>
    (await LocalDb.momentLabels(date: m.date)).firstWhere((l) => l.key == m.key);

Future<double?> _total(String field) async =>
    (await LocalDb.journalMetricsForDay(_date))[field]?.value;

Future<int?> _atMin(String field) async =>
    (await LocalDb.journalMetricsForDay(_date))[field]?.atMinuteOfDay;

/// Applies the same change the screen would: through the writer.
Future<MomentAnswerChange> _change(
  PendingMoment m,
  MomentChoice to, {
  double? value,
  String? note,
  SymptomDescription? symptom,
  DateTime? now,
}) async =>
    _writer.change(await _saved(m), to,
        value: value, note: note, symptom: symptom, now: now ?? _t2);

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

  group('what an answer remembers about its own write', () {
    // why: an edit can only take back what it knows was added. Alcohol and water
    // amounts are stored nowhere else, and a clamped add is smaller than asked.
    test('a dose answer keeps the amount it actually added (metric_value)',
        () async {
      await _writer.answer(_m, MomentChoice.alcohol, value: 2, now: _t1);
      expect((await _all('moment_label')).single['metric_value'], 2.0);
    });

    test('a water answer clamped at the ceiling keeps the CLAMPED amount',
        () async {
      // 5900 + one 250 ml glass is cut to the 6000 ceiling: 100 ml was added.
      await LocalDb.putJournalMetrics(
          _date, const {'water_ml': JournalMetricValue(5900)});
      await _writer.answer(_m, MomentChoice.water, now: _t1);
      expect(await _total('water_ml'), 6000);
      expect((await _all('moment_label')).single['metric_value'], 100.0);
    });

    test('a dose answered with no amount records that it added nothing (0), '
        'which is not the same as "not known" (null)', () async {
      await _writer.answer(_m, MomentChoice.caffeine, now: _t1);
      await _writer.answer(_m2, MomentChoice.other, note: 'x', now: _t1);
      final rows = await _all('moment_label');
      expect(rows[0]['metric_value'], 0.0, reason: 'caffeine, no amount');
      expect(rows[1]['metric_value'], isNull, reason: 'not a dose label');
    });

    test('MomentLabel carries it, so the editor can hand the answer back',
        () async {
      await _writer.answer(_m, MomentChoice.caffeine, value: 80, now: _t1);
      expect((await _saved(_m)).metricValue, 80);
    });
  });

  group('replaced, not duplicated', () {
    test('caffeine 80 -> 120: ONE label row, the journal total follows the '
        'delta, the rest of the day stays', () async {
      await LocalDb.putJournalMetrics(_date, const {
        'mood': JournalMetricValue(4),
        'caffeine_mg': JournalMetricValue(100, atMinuteOfDay: 8 * 60),
      });
      await _writer.answer(_m, MomentChoice.caffeine, value: 80, now: _t1);
      expect(await _total('caffeine_mg'), 180);

      final r = await _change(_m, MomentChoice.caffeine, value: 120);

      expect(r, isA<MomentChanged>());
      final rows = await _all('moment_label');
      expect(rows, hasLength(1));
      expect(rows.single['label'], 'caffeine');
      expect(rows.single['caffeine_mg'], 120);
      expect(rows.single['metric_value'], 120);
      // 100 untimed + 120: the old 80 is taken back once, the new 120 added once.
      expect(await _total('caffeine_mg'), 220);
      expect(await _atMin('caffeine_mg'), 615);
      expect((await LocalDb.journalMetricsForDay(_date))['mood'],
          const JournalMetricValue(4));
      expect((r as MomentChanged).after.caffeineMg, 120);
      expect(r.after.answeredAtMs, _t2.millisecondsSinceEpoch);
    });

    test('caffeine -> alcohol: the caffeine is taken back, the alcohol added; '
        'the untimed 100 keeps its own time', () async {
      await LocalDb.putJournalMetrics(_date, const {
        'caffeine_mg': JournalMetricValue(100, atMinuteOfDay: 8 * 60),
      });
      await _writer.answer(_m, MomentChoice.caffeine, value: 80, now: _t1);

      await _change(_m, MomentChoice.alcohol, value: 2);

      expect(await _total('caffeine_mg'), 100);
      // The untimed 100 mg keeps the time it had (08:00): the first answer
      // recorded it as the remainder's own time before 10:15 replaced the
      // aggregate's, so removing the 80 mg restores it (never a made-up 10:15).
      expect(await _atMin('caffeine_mg'), 480);
      expect(await _total('alcohol_units'), 2);
      expect(await _atMin('alcohol_units'), 615);
      final row = (await _all('moment_label')).single;
      expect(row['label'], 'alcohol');
      expect(row['caffeine_mg'], isNull, reason: 'only caffeine keeps it');
      expect(row['metric_value'], 2);
    });

    test('a dose that was the day\'s only entry leaves the day ABSENT, not a '
        'logged zero', () async {
      await _writer.answer(_m, MomentChoice.caffeine, value: 80, now: _t1);
      await _change(_m, MomentChoice.other, note: 'felt wired');
      expect(await _all('journal_metric'), isEmpty);
      final row = (await _all('moment_label')).single;
      expect(row['label'], 'other');
      expect(row['note'], 'felt wired');
      expect(row['caffeine_mg'], isNull);
      expect(row['metric_value'], isNull);
    });

    test('a dose changed to the same label with NO amount takes the amount '
        'back and adds none', () async {
      await _writer.answer(_m, MomentChoice.alcohol, value: 3, now: _t1);
      await _change(_m, MomentChoice.alcohol);
      expect(await _all('journal_metric'), isEmpty);
      expect((await _all('moment_label')).single['metric_value'], 0.0);
    });

    test('a label with no dose -> a dose adds it once', () async {
      await _writer.answer(_m, MomentChoice.other, note: 'x', now: _t1);
      await _change(_m, MomentChoice.caffeine, value: 60);
      expect(await _total('caffeine_mg'), 60);
      expect(await _atMin('caffeine_mg'), 615);
      final row = (await _all('moment_label')).single;
      expect(row['note'], isNull, reason: 'the old note is not carried over');
      expect(row['caffeine_mg'], 60);
    });

    test('water: taking back a CLAMPED glass subtracts what was added (100), '
        'not a whole glass', () async {
      await LocalDb.putJournalMetrics(
          _date, const {'water_ml': JournalMetricValue(5900)});
      await _writer.answer(_m, MomentChoice.water, now: _t1);
      await _change(_m, MomentChoice.caffeine, value: 50);
      expect(await _total('water_ml'), 5900);
      expect(await _total('caffeine_mg'), 50);
    });

    test('changing one moment leaves another moment\'s dose alone', () async {
      await _writer.answer(_m, MomentChoice.caffeine, value: 80, now: _t1);
      await _writer.answer(_m2, MomentChoice.caffeine, value: 50, now: _t1);
      expect(await _total('caffeine_mg'), 130);
      await _change(_m, MomentChoice.caffeine, value: 10);
      expect(await _total('caffeine_mg'), 60);
      expect(await _atMin('caffeine_mg'), 940, reason: 'the 15:40 dose is later');
      expect((await _saved(_m2)).caffeineMg, 50);
    });

    test('changing to the very same answer is a no-op on every total',
        () async {
      await LocalDb.putJournalMetrics(_date, const {
        'caffeine_mg': JournalMetricValue(100, atMinuteOfDay: 8 * 60),
      });
      await _writer.answer(_m, MomentChoice.caffeine, value: 80, now: _t1);
      final before = await LocalDb.journalMetricsForDay(_date);
      final r = await _change(_m, MomentChoice.caffeine, value: 80);
      expect(r, isA<MomentChanged>());
      expect(await LocalDb.journalMetricsForDay(_date), before);
      expect(await _all('moment_label'), hasLength(1));
    });
  });

  group('review CLS1-C1/C2/C5: one reconciliation seam for substances', () {
    // why: Tracks edits and answer changes must both keep journal total =
    // canonical doses + the journal-only remainder (CLAIM(substance-reconcile)),
    // never delta arithmetic on a total the user may have lowered.
    test('C1: an amount edited in Tracks then again keeps metric_value, so a '
        'later change does not add the old amount back', () async {
      await _writer.answer(_m, MomentChoice.caffeine, value: 80, now: _t1);
      await LocalDb.editTrackMoment('$_date:10:15', amount: 120);
      expect((await _all('moment_label')).single['metric_value'], 120);
      await LocalDb.editTrackMoment('$_date:10:15', amount: 160);
      expect(await _total('caffeine_mg'), 160);
      expect((await _saved(_m)).metricValue, 160);
      final r = await _change(_m, MomentChoice.caffeine, value: 40);
      expect(r, isA<MomentChanged>());
      expect(await _total('caffeine_mg'), 40);
    });

    test('C2: a total the user lowered below the canonical doses is rebuilt '
        'from the doses, so Journal and Tracks agree', () async {
      await _writer.answer(_m, MomentChoice.caffeine, value: 80, now: _t1);
      await _writer.answer(_m2, MomentChoice.caffeine, value: 100, now: _t1);
      await LocalDb.putJournalMetrics(_date,
          const {'caffeine_mg': JournalMetricValue(50, atMinuteOfDay: 940)});
      await _change(_m, MomentChoice.caffeine, value: 120);
      // 100 + 120 canonical doses, no remainder.
      expect(await _total('caffeine_mg'), 220);
      final feed = await (await LocalDb.instance).rawQuery(
          "SELECT SUM(amount) AS a FROM track_event_feed WHERE track_id = "
          "'caffeine' AND date = ?", [_date]);
      expect(feed.single['a'], 220);
    });

    test('C5: an unchanged answer keeps the remainder\'s own time, so removing '
        'the moment later restores it', () async {
      await _writer.answer(_m, MomentChoice.caffeine, value: 80, now: _t1);
      final db = await LocalDb.instance;
      await db.update('journal_metric', {'value': 180.0, 'at_min': 615});
      await db.insert('wake_meta',
          {'key': 'substance_remainder_min:$_date:caffeine', 'value': '480'},
          conflictAlgorithm: ConflictAlgorithm.replace);
      await _change(_m, MomentChoice.caffeine, value: 80);
      expect(await _total('caffeine_mg'), 180);
      expect(await _atMin('caffeine_mg'), 615);
      await LocalDb.editTrackMoment('$_date:10:15', delete: true);
      expect(await _total('caffeine_mg'), 100);
      expect(await _atMin('caffeine_mg'), 480,
          reason: 'the remainder keeps the time it had');
    });
  });

  group('review CLS1-C6/C7', () {
    test('C6: changing the latest water answer keeps the time of a surviving '
        'one', () async {
      await _writer.answer(_m, MomentChoice.water, now: _t1);
      await _writer.answer(
          const PendingMoment(date: _date, hhmm: '08:00'), MomentChoice.water,
          now: _t1);
      expect(await _atMin('water_ml'), 615);
      await _change(_m, MomentChoice.caffeine, value: 50);
      expect(await _atMin('water_ml'), 480);
    });

    test('C7: an alcohol answer\'s amount is the moment\'s amount in the track '
        'feed, and no untimed remainder is left for it', () async {
      await _writer.answer(_m, MomentChoice.alcohol, value: 2, now: _t1);
      final db = await LocalDb.instance;
      final moment = await db.rawQuery(
          "SELECT amount FROM track_event_feed WHERE id = 'moment:$_date:10:15'");
      expect(moment.single['amount'], 2);
      final rem = await db.rawQuery(
          "SELECT 1 FROM track_event_feed WHERE id = 'journal:$_date:alcohol_units'");
      expect(rem, isEmpty);
      await _change(_m, MomentChoice.alcohol, value: 3);
      expect((await db.rawQuery(
          "SELECT amount FROM track_event_feed WHERE id = 'moment:$_date:10:15'"))
          .single['amount'], 3);
      expect(await _total('alcohol_units'), 3);
      expect(await db.rawQuery(
          "SELECT 1 FROM track_event_feed WHERE id = 'journal:$_date:alcohol_units'"),
          isEmpty);
    });
  });

  group('review CLS1-R2', () {
    const m3 = PendingMoment(date: _date, hhmm: '17:00');
    Future<Map<String, Object?>?> feed(String id) async =>
        (await (await LocalDb.instance)
                .rawQuery('SELECT * FROM track_event_feed WHERE id = ?', [id]))
            .firstOrNull;

    test('R2-2: an alcohol answer with no amount exposes NULL, not 0 units, '
        'whether the amount was omitted or cleared', () async {
      await _writer.answer(_m, MomentChoice.alcohol, now: _t1);
      expect((await feed('moment:$_date:10:15'))!['amount'], isNull,
          reason: 'omitted');
      await _writer.answer(_m2, MomentChoice.alcohol, value: 2, now: _t1);
      expect((await feed('moment:$_date:15:40'))!['amount'], 2);
      await _change(_m2, MomentChoice.alcohol);
      expect((await feed('moment:$_date:15:40'))!['amount'], isNull,
          reason: 'cleared');
    });

    test('R2-3: a first answer after the total was lowered rebuilds from the '
        'doses, and a later edit agrees', () async {
      await _writer.answer(_m, MomentChoice.caffeine, value: 80, now: _t1);
      await _writer.answer(_m2, MomentChoice.caffeine, value: 100, now: _t1);
      await LocalDb.putJournalMetrics(_date,
          const {'caffeine_mg': JournalMetricValue(50, atMinuteOfDay: 940)});
      await _writer.answer(m3, MomentChoice.caffeine, value: 40, now: _t1);
      expect(await _total('caffeine_mg'), 220);
      await _change(m3, MomentChoice.caffeine, value: 60);
      expect(await _total('caffeine_mg'), 240);
    });

    test('R2-3: a first answer keeps the remainder\'s earlier time', () async {
      await LocalDb.putJournalMetrics(_date,
          const {'caffeine_mg': JournalMetricValue(100, atMinuteOfDay: 480)});
      await _writer.answer(_m, MomentChoice.caffeine, value: 80, now: _t1);
      expect(await _atMin('caffeine_mg'), 615);
      await LocalDb.editTrackMoment('$_date:10:15', delete: true);
      expect(await _total('caffeine_mg'), 100);
      expect(await _atMin('caffeine_mg'), 480);
    });

    test('a Tracks edit of the untimed remainder keeps an alcohol answer\'s '
        'dose in the total', () async {
      await _writer.answer(_m, MomentChoice.alcohol, value: 2, now: _t1);
      await LocalDb.editTrackJournal('$_date:alcohol_units', 1);
      expect(await _total('alcohol_units'), 3);
    });

    test('a corrupt stored amount (negative) reads as unknown and is refused '
        'for a dose change, never used', () async {
      final db = await LocalDb.instance;
      await db.rawInsert(
          'INSERT INTO moment_label (date, hhmm, label, metric_value, answered_at) '
          "VALUES ('$_date', '10:15', 'alcohol', -5, 1)");
      expect((await _saved(_m)).metricValue, isNull);
      final r = await _change(_m, MomentChoice.other, note: 'x');
      expect(r, isA<MomentChangeFailed>());
      expect((await feed('moment:$_date:10:15'))!['amount'], isNull);
    });

    test('R2-4: saving an unchanged water answer keeps its clipped '
        'contribution after the total was corrected', () async {
      await LocalDb.putJournalMetrics(
          _date, const {'water_ml': JournalMetricValue(5900)});
      await _writer.answer(_m, MomentChoice.water, now: _t1);
      await LocalDb.putJournalMetrics(_date,
          const {'water_ml': JournalMetricValue(5000, atMinuteOfDay: 615)});
      await _change(_m, MomentChoice.water);
      expect(await _total('water_ml'), 5000);
      expect((await _saved(_m)).metricValue, 100);
    });

    test('R2-5: a kept assumed glass is a surviving water record', () async {
      final db = await LocalDb.instance;
      await db.insert('assumed_water', {
        'date': _date, 'at_min': 480, 'ml': 250.0, 'state': 'kept',
        'logged_at': 1,
      });
      // Straight into the table: putJournalMetrics would also record a
      // water_moment glass, hiding that the assumed glass is not looked at.
      await db.insert('journal_metric', {
        'date': _date, 'field': 'water_ml', 'value': 250.0, 'at_min': 480,
        'updated_at': 1,
      });
      await _writer.answer(_m, MomentChoice.water, now: _t1);
      expect(await _atMin('water_ml'), 615);
      await _change(_m, MomentChoice.caffeine, value: 50);
      expect(await _atMin('water_ml'), 480);
    });

    test('R2-5: a removed assumed glass is not', () async {
      final db = await LocalDb.instance;
      await db.insert('assumed_water', {
        'date': _date, 'at_min': 480, 'ml': 250.0, 'state': 'removed',
        'logged_at': 1,
      });
      await _writer.answer(_m, MomentChoice.water, now: _t1);
      await _change(_m, MomentChoice.caffeine, value: 50);
      expect(await _atMin('water_ml'), isNull);
    });
  });

  group('symptoms: exactly one entry per moment', () {
    test('symptom -> other deletes the symptom entry', () async {
      await _writer.answerSymptom(_m, _knee, now: _t1);
      await _change(_m, MomentChoice.other, note: 'never mind');
      expect(await _all('symptom_entry'), isEmpty);
      expect((await _saved(_m)).label, 'other');
    });

    test('other -> symptom writes one entry', () async {
      await _writer.answer(_m, MomentChoice.other, note: 'x', now: _t1);
      await _change(_m, MomentChoice.symptom, symptom: _knee);
      final rows = await _all('symptom_entry');
      expect(rows, hasLength(1));
      expect(rows.single['area'], 'knees');
      expect(rows.single['hhmm'], '10:15');
      expect((await _saved(_m)).label, 'symptom');
    });

    test('symptom -> a different symptom REPLACES the entry', () async {
      await _writer.answerSymptom(_m, _knee, now: _t1);
      await _change(_m, MomentChoice.symptom, symptom: _head);
      final rows = await _all('symptom_entry');
      expect(rows, hasLength(1), reason: 'not a second row beside the first');
      expect(rows.single['area'], 'forehead');
      expect(rows.single['severity'], 'mild');
      expect(rows.single['side'], isNull, reason: 'the old side is not kept');
    });

    test('a symptom edit derives no metric', () async {
      await _writer.answerSymptom(_m, _knee, now: _t1);
      await _change(_m, MomentChoice.symptom, symptom: _head);
      expect(await _all('journal_metric'), isEmpty);
    });
  });

  group('the track feed and the remainder minute follow', () {
    // why: track_event_feed is a view over moment_label + journal_metric; if the
    // change wrote the label but not the journal (or the reverse) the Tracks
    // screen would show a remainder that never happened.
    Future<Map<String, Object?>?> feed(String id) async {
      final rows = await (await LocalDb.instance).rawQuery(
          'SELECT * FROM track_event_feed WHERE id = ?', [id]);
      return rows.firstOrNull;
    }

    test('caffeine 80 -> 120 with 100 untimed: the moment row reads 120 and '
        'the untimed remainder is still exactly 100', () async {
      await LocalDb.putJournalMetrics(_date, const {
        'caffeine_mg': JournalMetricValue(100, atMinuteOfDay: 8 * 60),
      });
      await _writer.answer(_m, MomentChoice.caffeine, value: 80, now: _t1);
      expect((await feed('moment:$_date:10:15'))!['amount'], 80);
      expect((await feed('journal:$_date:caffeine_mg'))!['amount'], 100);

      await _change(_m, MomentChoice.caffeine, value: 120);

      expect((await feed('moment:$_date:10:15'))!['amount'], 120);
      expect((await feed('journal:$_date:caffeine_mg'))!['amount'], 100);
    });

    test('caffeine -> alcohol moves the moment to the alcohol track and leaves '
        'no caffeine remainder behind', () async {
      await _writer.answer(_m, MomentChoice.caffeine, value: 80, now: _t1);
      await _change(_m, MomentChoice.alcohol, value: 2);
      expect((await feed('moment:$_date:10:15'))!['track_id'], 'alcohol');
      expect(await feed('journal:$_date:caffeine_mg'), isNull);
    });

    test('the stored remainder minute is cleared for the touched substances '
        '(CLAIM(remainder-time-fresh))', () async {
      final db = await LocalDb.instance;
      await _writer.answer(_m, MomentChoice.caffeine, value: 80, now: _t1);
      for (final k in ['caffeine', 'alcohol']) {
        await db.insert('wake_meta',
            {'key': 'substance_remainder_min:$_date:$k', 'value': '480'},
          conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await db.insert('wake_meta',
          {'key': 'substance_remainder_min:2026-10-05:caffeine', 'value': '1'},
          conflictAlgorithm: ConflictAlgorithm.replace);
      await _change(_m, MomentChoice.alcohol, value: 2);
      // wake_meta also holds unrelated state (e.g. wake_split_v1).
      final keys = [
        for (final r in await _all('wake_meta'))
          if ('${r['key']}'.startsWith('substance_remainder_min:')) r['key']
      ];
      expect(keys, ['substance_remainder_min:2026-10-05:caffeine'],
          reason: 'both touched substances of THIS day, nothing of other days');
    });
  });

  group('stale, missing, refused or failed: the database does not change', () {
    test('a retry with the SAME old answer is Stale and adds nothing again',
        () async {
      await LocalDb.putJournalMetrics(_date, const {
        'caffeine_mg': JournalMetricValue(100, atMinuteOfDay: 8 * 60),
      });
      await _writer.answer(_m, MomentChoice.caffeine, value: 80, now: _t1);
      final opened = await _saved(_m);

      final first = await _writer.change(opened, MomentChoice.caffeine,
          value: 120, now: _t2);
      expect(first, isA<MomentChanged>());
      final afterFirst = await _snapshot();

      final second = await _writer.change(opened, MomentChoice.caffeine,
          value: 120, now: _t2.add(const Duration(minutes: 1)));
      expect(second, isA<MomentStale>());
      expect((second as MomentStale).current.caffeineMg, 120);
      expect(await _snapshot(), afterFirst, reason: 'no double add');
      expect(await _total('caffeine_mg'), 220);
    });

    test('an earlier copy is Stale even when the answer was re-saved with the '
        'same content (the answered-at stamp is part of its identity)',
        () async {
      await _writer.answer(_m, MomentChoice.caffeine, value: 80, now: _t1);
      final opened = await _saved(_m);
      await _writer.change(opened, MomentChoice.caffeine,
          value: 80, now: _t2);
      final r = await _writer.change(opened, MomentChoice.caffeine,
          value: 80, now: _t2.add(const Duration(minutes: 1)));
      expect(r, isA<MomentStale>());
      expect(await _total('caffeine_mg'), 80);
    });

    test('an answer changed underneath (a note edited elsewhere) is Stale',
        () async {
      await _writer.answer(_m, MomentChoice.other, note: 'a', now: _t1);
      final opened = await _saved(_m);
      await (await LocalDb.instance).update('moment_label', {'note': 'b'});
      final before = await _snapshot();
      final r = await _writer.change(opened, MomentChoice.caffeine,
          value: 5, now: _t2);
      expect(r, isA<MomentStale>());
      expect(await _snapshot(), before);
    });

    test('an answer deleted since the editor opened is NotFound', () async {
      await _writer.answer(_m, MomentChoice.caffeine, value: 80, now: _t1);
      final opened = await _saved(_m);
      await LocalDb.editTrackMoment('$_date:10:15', delete: true);
      final before = await _snapshot();
      final r = await _writer.change(opened, MomentChoice.caffeine,
          value: 5, now: _t2);
      expect(r, isA<MomentNotFound>());
      expect(await _snapshot(), before);
      expect(await _all('moment_label'), isEmpty,
          reason: 'an edit never resurrects a deleted answer');
    });

    test('a write that fails half way rolls EVERYTHING back (label, journal, '
        'symptom, remainder minute)', () async {
      final db = await LocalDb.instance;
      await LocalDb.putJournalMetrics(_date, const {
        'caffeine_mg': JournalMetricValue(100, atMinuteOfDay: 8 * 60),
      });
      await _writer.answer(_m, MomentChoice.caffeine, value: 80, now: _t1);
      await db.insert('wake_meta',
          {'key': 'substance_remainder_min:$_date:caffeine', 'value': '480'},
          conflictAlgorithm: ConflictAlgorithm.replace);
      final before = await _snapshot();
      // The last write of the change is the symptom insert; make it fail after
      // the label and journal writes have already happened.
      await db.execute('CREATE TRIGGER fail_symptom BEFORE INSERT ON '
          "symptom_entry BEGIN SELECT RAISE(ABORT, 'disk full'); END");

      final r = await _writer.change(await _saved(_m), MomentChoice.symptom,
          symptom: _knee, now: _t2);

      expect(r, isA<MomentChangeFailed>());
      expect((r as MomentChangeFailed).reason, MomentChangeFailure.storage);
      expect(r.error, isNotNull);
      expect(await _snapshot(), before);
    });

    test('an old dose answer whose amount was never kept is refused, not '
        'guessed', () async {
      final db = await LocalDb.instance;
      // As the previous build stored it: a label with no metric_value, and the
      // journal total it had been added to.
      await db.rawInsert(
          'INSERT INTO moment_label (date, hhmm, label, answered_at) '
          "VALUES ('$_date', '10:15', 'alcohol', 1)");
      await LocalDb.putJournalMetrics(
          _date, const {'alcohol_units': JournalMetricValue(3, atMinuteOfDay: 615)});
      final before = await _snapshot();
      final r = await _writer.change(await _saved(_m), MomentChoice.other,
          note: 'x', now: _t2);
      expect(r, isA<MomentChangeFailed>());
      expect((r as MomentChangeFailed).reason,
          MomentChangeFailure.priorAmountUnknown);
      expect(await _snapshot(), before);
    });

    test('an old answer with no dose behind it (a note) can still be changed',
        () async {
      final db = await LocalDb.instance;
      await db.rawInsert(
          'INSERT INTO moment_label (date, hhmm, label, note, answered_at) '
          "VALUES ('$_date', '10:15', 'other', 'old', 1)");
      final r = await _writer.change(await _saved(_m), MomentChoice.caffeine,
          value: 40, now: _t2);
      expect(r, isA<MomentChanged>());
      expect(await _total('caffeine_mg'), 40);
    });

    test('an old caffeine answer that kept its amount (caffeine_mg) can be '
        'taken back exactly', () async {
      final db = await LocalDb.instance;
      await db.rawInsert(
          'INSERT INTO moment_label (date, hhmm, label, caffeine_mg, '
          "answered_at) VALUES ('$_date', '10:15', 'caffeine', 80, 1)");
      await LocalDb.putJournalMetrics(_date,
          const {'caffeine_mg': JournalMetricValue(180, atMinuteOfDay: 615)});
      final r = await _writer.change(await _saved(_m), MomentChoice.caffeine,
          value: 20, now: _t2);
      expect(r, isA<MomentChanged>());
      expect(await _total('caffeine_mg'), 120);
    });
  });

  group('the writer validates like answering does', () {
    test('an amount of zero, negative, NaN or over the ceiling is refused with '
        'nothing written', () async {
      await _writer.answer(_m, MomentChoice.caffeine, value: 80, now: _t1);
      final before = await _snapshot();
      for (final v in [0.0, -5.0, double.nan, 100000.0]) {
        await expectLater(
            _change(_m, MomentChoice.caffeine, value: v), throwsArgumentError,
            reason: '$v');
      }
      expect(await _snapshot(), before);
    });

    test('Water takes no amount', () async {
      await _writer.answer(_m, MomentChoice.other, now: _t1);
      await expectLater(_change(_m, MomentChoice.water, value: 100),
          throwsArgumentError);
    });

    test('a value for a choice with no journal field is refused', () async {
      await _writer.answer(_m, MomentChoice.other, now: _t1);
      await expectLater(_change(_m, MomentChoice.nap, value: 5),
          throwsArgumentError);
    });

    test('Symptom needs its description', () async {
      await _writer.answer(_m, MomentChoice.other, now: _t1);
      await expectLater(
          _change(_m, MomentChoice.symptom), throwsArgumentError);
    });

    test('water adds one glass of the unit step to the moment\'s day',
        () async {
      await _writer.answer(_m, MomentChoice.other, now: _t1);
      await _change(_m, MomentChoice.water);
      expect(await _total('water_ml'), kJournalFieldsByKey['water_ml']!.step);
      expect(await _atMin('water_ml'), 615);
    });

    test('a note is trimmed, and a blank note is no note', () async {
      await _writer.answer(_m, MomentChoice.other, note: 'a', now: _t1);
      await _change(_m, MomentChoice.other, note: '  fine  ');
      expect((await _saved(_m)).note, 'fine');
      await _change(_m, MomentChoice.other, note: '   ');
      expect((await _saved(_m)).note, isNull);
    });

    test('nap, meal and workout are labels only: no session or nap is created '
        'or removed', () async {
      await _writer.answer(_m, MomentChoice.workout, now: _t1);
      final before = await _snapshot();
      await _change(_m, MomentChoice.nap);
      await _change(_m, MomentChoice.meal);
      final after = await _snapshot();
      expect(after['sessions'], before['sessions']);
      expect(after['sleep_nap'], before['sleep_nap']);
      expect((await _saved(_m)).label, 'meal');
    });
  });
}
