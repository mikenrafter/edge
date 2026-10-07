// "Water" as a marked-moment answer (RED). It replaces the standalone
// "Log water" gesture action.
//
//   * MomentChoice.water: id 'water', label 'Water', a localized label from the
//     new ARB key momentChoiceWater.
//   * Answering a pending moment "Water" stores the label AND adds exactly ONE
//     glass (the `water_ml` field's `step`, clamped to its `max`) to the
//     MOMENT's local day, not to today. No amount is asked: one tap, one glass.
//   * Read-modify-write is safe: two water answers that overlap lose no glass.
//   * Idempotent: an already-answered moment (a skip counts) is not re-added.
//
// Real sqflite_ffi database, same idiom as answer_writer_test.dart.

import 'dart:io';

import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/journal_fields.dart';
import 'package:openstrap_edge/gestures/moment_follow_ups.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';

const _m = PendingMoment(date: '2026-10-06', hhmm: '10:15'); // minute 615
const _m2 = PendingMoment(date: '2026-10-06', hhmm: '15:40'); // minute 940
const _today = '2026-10-07';
final _now = DateTime(2026, 10, 7, 12, 0);
const _writer = MomentAnswerWriter();
final _spec = kJournalFieldsByKey['water_ml']!;

Future<String> _path(String name) async =>
    p.join(await databaseFactory.getDatabasesPath(), name);

var _n = 0;
Future<void> _fresh(List<String> created) async {
  final name = 'openstrap_moment_water_${_n++}.db';
  created.add(name);
  await LocalDb.close();
  await databaseFactory.deleteDatabase(await _path(name));
  LocalDb.lastRebuild = null;
  LocalDb.dbName = name;
  await LocalDb.instance;
  await LocalDb.putJournal(
      _m.date, '["moment 10:15","moment 15:40"]', 'a note');
}

Future<List<Map<String, Object?>>> _all(String table) async =>
    (await LocalDb.instance).query(table);

Future<double?> _water(String date) async =>
    (await LocalDb.journalMetricsForDay(date))['water_ml']?.value;

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

  group('the choice', () {
    test('id water, label Water, found by its id', () {
      expect(MomentChoice.water.id, 'water');
      expect(MomentChoice.water.label, 'Water');
      expect(MomentChoice.fromId('water'), MomentChoice.water);
      // The ids already stored for the other choices are untouched.
      expect(MomentChoice.fromId('caffeine'), MomentChoice.caffeine);
      expect(MomentChoice.values.map((c) => c.id).toSet(),
          hasLength(MomentChoice.values.length));
    });

    test('it maps to the existing water_ml dose field', () {
      expect(MomentChoice.water.journalField, 'water_ml');
      expect(kJournalFieldsByKey['water_ml']!.kind, JournalFieldKind.dose);
    });

    test('the localized label comes from the new momentChoiceWater key, '
        'English "Water"', () {
      final l = lookupAppLocalizations(const Locale('en'));
      // dynamic: the getter does not exist until the ARB key is generated.
      expect((l as dynamic).momentChoiceWater, 'Water');
      expect(MomentChoice.water.localized(l), 'Water');
    });

    test('app_en.arb declares momentChoiceWater with a description, like its '
        'siblings', () {
      final arb = File('lib/l10n/app_en.arb').readAsStringSync();
      expect(arb.contains('"momentChoiceWater": "Water"'), isTrue);
      expect(arb.contains('"@momentChoiceWater"'), isTrue);
    });
  });

  group('one tap, one glass', () {
    test("adds exactly one step of water_ml to the MOMENT's day, not today, "
        "at the moment's minute; the label is stored too", () async {
      final r = await _writer.answer(_m, MomentChoice.water, now: _now);
      expect(r, MomentAnswerResult.saved);

      final rows = await _all('journal_metric');
      expect(rows, hasLength(1));
      expect(rows.single['date'], '2026-10-06');
      expect(rows.single['field'], 'water_ml');
      expect(rows.single['value'], _spec.step);
      expect(rows.single['at_min'], 615);
      expect(await _water(_today), isNull, reason: 'nothing lands on today');

      final l = (await LocalDb.momentLabels(date: _m.date)).single;
      expect(l.label, 'water');
      expect(l.hhmm, '10:15');
      expect(l.note, isNull);
      expect(l.answeredAtMs, _now.millisecondsSinceEpoch);
    });

    test('the glass is the field spec\'s step (the + button\'s), whatever '
        'that is today', () async {
      await _writer.answer(_m, MomentChoice.water, now: _now);
      expect(await _water(_m.date), _spec.step);
      expect(_spec.step, greaterThan(0));
    });

    test('it is ADDED to the day\'s total; other fields survive; the time '
        'is the latest', () async {
      await LocalDb.putJournalMetrics(_m.date, const {
        'mood': JournalMetricValue(4),
        'water_ml': JournalMetricValue(500, atMinuteOfDay: 8 * 60),
      });
      await _writer.answer(_m, MomentChoice.water, now: _now);
      final day = await LocalDb.journalMetricsForDay(_m.date);
      expect(day['mood'], const JournalMetricValue(4));
      expect(day['water_ml'],
          JournalMetricValue(500 + _spec.step, atMinuteOfDay: 615));
    });

    test('is clamped to the field ceiling, never above it', () async {
      await LocalDb.putJournalMetrics(_m.date, {
        'water_ml': JournalMetricValue(_spec.max - 10, atMinuteOfDay: 60),
      });
      final r = await _writer.answer(_m, MomentChoice.water, now: _now);
      expect(r, MomentAnswerResult.saved);
      expect(await _water(_m.date), _spec.max);
    });

    test('already at the ceiling: the moment is still answered, the total '
        'stays at the ceiling', () async {
      await LocalDb.putJournalMetrics(_m.date, {
        'water_ml': JournalMetricValue(_spec.max, atMinuteOfDay: 60),
      });
      final r = await _writer.answer(_m, MomentChoice.water, now: _now);
      expect(r, MomentAnswerResult.saved);
      expect(await _water(_m.date), _spec.max);
      expect((await LocalDb.momentLabels(date: _m.date)).single.label, 'water');
    });

    test('the journal tags and note of the day are untouched', () async {
      await _writer.answer(_m, MomentChoice.water, now: _now);
      final j = (await _all('journal')).single;
      expect(j['tags_json'], '["moment 10:15","moment 15:40"]');
      expect(j['note'], 'a note');
    });

    test('no other table gets a row (no session, no nap, no sleep)', () async {
      await _writer.answer(_m, MomentChoice.water, now: _now);
      expect(await _all('sessions'), isEmpty);
      expect(await _all('sleep_nap'), isEmpty);
      expect(await _all('sleep_override'), isEmpty);
    });
  });

  group('read-modify-write safety', () {
    test('two water answers that overlap on one day lose no glass', () async {
      final rs = await Future.wait([
        _writer.answer(_m, MomentChoice.water, now: _now),
        _writer.answer(_m2, MomentChoice.water, now: _now),
      ]);
      expect(rs, everyElement(MomentAnswerResult.saved));
      expect(await _water(_m.date), _spec.step * 2);
      expect(await LocalDb.momentLabels(date: _m.date), hasLength(2));
      // The later moment's minute is the day's latest.
      expect((await LocalDb.journalMetricsForDay(_m.date))['water_ml']!
              .atMinuteOfDay,
          940);
    });

    test('four overlapping answers on one day are four glasses', () async {
      const more = [
        PendingMoment(date: '2026-10-06', hhmm: '17:00'),
        PendingMoment(date: '2026-10-06', hhmm: '18:30'),
      ];
      await Future.wait([
        for (final m in [_m, _m2, ...more])
          _writer.answer(m, MomentChoice.water, now: _now),
      ]);
      expect(await _water(_m.date), _spec.step * 4);
    });

    test('the same moment answered twice at once is one glass', () async {
      final rs = await Future.wait([
        _writer.answer(_m, MomentChoice.water, now: _now),
        _writer.answer(_m, MomentChoice.water, now: _now),
      ]);
      expect(rs.where((r) => r == MomentAnswerResult.saved), hasLength(1));
      expect(rs.where((r) => r == MomentAnswerResult.alreadyAnswered),
          hasLength(1));
      expect(await _water(_m.date), _spec.step);
    });

    test('water on two different days lands one glass on each', () async {
      const other = PendingMoment(date: '2026-10-05', hhmm: '09:00');
      await LocalDb.putJournal(other.date, '["moment 09:00"]', '');
      await Future.wait([
        _writer.answer(_m, MomentChoice.water, now: _now),
        _writer.answer(other, MomentChoice.water, now: _now),
      ]);
      expect(await _water('2026-10-06'), _spec.step);
      expect(await _water('2026-10-05'), _spec.step);
    });
  });

  group('idempotence', () {
    test('answering the same moment Water twice adds one glass', () async {
      await _writer.answer(_m, MomentChoice.water, now: _now);
      final again =
          await _writer.answer(_m, MomentChoice.water, now: _now);
      expect(again, MomentAnswerResult.alreadyAnswered);
      expect(await _water(_m.date), _spec.step);
      expect(await LocalDb.momentLabels(date: _m.date), hasLength(1));
    });

    test('a moment already answered another way is not given a glass later',
        () async {
      await _writer.answer(_m, MomentChoice.nap, now: _now);
      final r = await _writer.answer(_m, MomentChoice.water, now: _now);
      expect(r, MomentAnswerResult.alreadyAnswered);
      expect(await _water(_m.date), isNull);
      expect((await LocalDb.momentLabels(date: _m.date)).single.label, 'nap');
    });

    test('a skipped moment cannot be answered Water by a stale screen',
        () async {
      await _writer.skip(_m, now: _now);
      final r = await _writer.answer(_m, MomentChoice.water, now: _now);
      expect(r, MomentAnswerResult.alreadyAnswered);
      expect(await _water(_m.date), isNull);
      expect((await LocalDb.momentLabels(date: _m.date)).single.label, isNull);
    });

    test('an answered water moment is no longer pending', () async {
      await _writer.answer(_m, MomentChoice.water, now: _now);
      final f =
          await MomentFollowUps.load(enabledSince: DateTime(2026, 10, 1));
      expect([for (final x in f.pending(_now)) x.key], [_m2.key]);
    });
  });
}
