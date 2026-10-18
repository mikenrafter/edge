// "Assume I drank water": storage and catch-up (RED).
//
// Design under test (the owner confirms it in the RED report):
//   * A glass is its own row in a small additive table `assumed_water`
//     (PK = the slot's local date + hhmm), because `journal_metric.water_ml` is
//     a day TOTAL and cannot say which part of it was assumed, nor which glass
//     to take back. The glass ALSO adds to that total in the same transaction,
//     so every existing reader (Nutrition, Journal, correlations, coach) sees it
//     with no change.
//   * The row records what was ACTUALLY added (a day at its ceiling adds less),
//     and removal subtracts exactly that.
//   * A removed glass stays as a tombstone: "each slot logs at most once, ever".
//   * NO gap filling: only reminder slots are ever assumed, never the hours
//     between them, and never a slot before the toggle was switched on.
//   * Catch-up looks back [AssumedWater.lookbackDays] (7) local days.

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/assumed_water.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/journal_fields.dart';
import 'package:openstrap_edge/data/water_units.dart';
import 'package:openstrap_edge/notify/notification_prefs.dart';
import 'package:openstrap_edge/state/units_controller.dart';

const _day = '2026-10-07';
final _spec = kJournalFieldsByKey['water_ml']!;
final _cup = WaterUnits.stepMl(UnitSystem.imperial);

Future<String> _path(String name) async =>
    p.join(await databaseFactory.getDatabasesPath(), name);

var _n = 0;
Future<void> _fresh(List<String> created) async {
  final name = 'openstrap_assumed_water_${_n++}.db';
  created.add(name);
  await LocalDb.close();
  await databaseFactory.deleteDatabase(await _path(name));
  LocalDb.lastRebuild = null;
  LocalDb.dbName = name;
  await LocalDb.instance;
}

Future<double?> _total(String date) async =>
    (await LocalDb.journalMetricsForDay(date))['water_ml']?.value;

Future<bool> _log(int atMin,
        {String date = _day, double ml = 250, int at = 1}) =>
    LocalDb.logAssumedWater(date: date, atMin: atMin, ml: ml, loggedAtMs: at);

/// 08:00 .. 20:00 every 2 h (seven slots), quiet hours off, toggle on since
/// [since].
NotificationPrefs _prefs(DateTime since, {bool assume = true, bool water = true}) =>
    NotificationPrefs(
      waterEnabled: water,
      quietEnabled: false,
      waterIntervalMin: 120,
      waterAssumeDrank: assume,
      waterAssumeSinceMs: since.millisecondsSinceEpoch,
    );

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

  group('logging one assumed glass', () {
    test('adds the glass to the slot\'s day at the slot\'s minute and marks it '
        'assumed', () async {
      expect(await _log(10 * 60), isTrue);
      final day = await LocalDb.journalMetricsForDay(_day);
      expect(day['water_ml'], const JournalMetricValue(250, atMinuteOfDay: 600));
      final g = (await LocalDb.assumedWater(date: _day)).single;
      expect(g.date, _day);
      expect(g.atMin, 600);
      expect(g.hhmm, '10:00');
      expect(g.key, '$_day 10:00');
      expect(g.ml, 250);
      expect(g.state, AssumedState.assumed);
      expect(g.loggedAtMs, 1);
    });

    test('is added to what the wearer already logged; the latest time wins',
        () async {
      await LocalDb.putJournalMetrics(_day, const {
        'mood': JournalMetricValue(4),
        'water_ml': JournalMetricValue(500, atMinuteOfDay: 15 * 60),
      });
      await _log(10 * 60);
      final day = await LocalDb.journalMetricsForDay(_day);
      expect(day['mood'], const JournalMetricValue(4));
      expect(day['water_ml'],
          const JournalMetricValue(750, atMinuteOfDay: 15 * 60));
    });

    test('the same slot is never logged twice', () async {
      expect(await _log(600), isTrue);
      expect(await _log(600), isFalse);
      expect(await _total(_day), 250);
      expect(await LocalDb.assumedWater(date: _day), hasLength(1));
    });

    test('a day at its ceiling adds only what fits, and the row says so',
        () async {
      await LocalDb.putJournalMetrics(_day, {
        'water_ml': JournalMetricValue(_spec.max - 100, atMinuteOfDay: 60),
      });
      await _log(600);
      expect(await _total(_day), _spec.max);
      expect((await LocalDb.assumedWater(date: _day)).single.ml, 100);
    });

    test('overlapping logs on one day lose no glass', () async {
      final rs = await Future.wait([
        for (final m in [480, 600, 720, 840]) _log(m),
      ]);
      expect(rs, everyElement(isTrue));
      expect(await _total(_day), 1000);
    });

    test('the same slot logged at once is one glass', () async {
      final rs = await Future.wait([_log(600), _log(600)]);
      expect(rs.where((r) => r), hasLength(1));
      expect(await _total(_day), 250);
    });

    test('the journal day\'s tags and note are untouched', () async {
      await LocalDb.putJournal(_day, '["moment 10:15"]', 'a note');
      await _log(600);
      final j = (await LocalDb.journalRows()).single;
      expect(j['tags_json'], '["moment 10:15"]');
      expect(j['note'], 'a note');
    });
  });

  group('keep', () {
    test('acknowledges: still in the total, still assumed, off the pending '
        'state', () async {
      await _log(600);
      final g = (await LocalDb.assumedWater(date: _day)).single;
      expect(await LocalDb.keepAssumedWater(g), isTrue);
      expect(await _total(_day), 250);
      final after = (await LocalDb.assumedWater(date: _day)).single;
      expect(after.state, AssumedState.kept);
      expect(await LocalDb.assumedWaterMl(_day), 250,
          reason: 'a kept glass is still an assumed one');
    });

    test('keeping twice, or keeping a removed glass, changes nothing',
        () async {
      await _log(600);
      final g = (await LocalDb.assumedWater(date: _day)).single;
      await LocalDb.keepAssumedWater(g);
      expect(await LocalDb.keepAssumedWater(g), isFalse);
      await LocalDb.removeAssumedWater(g);
      expect(await LocalDb.keepAssumedWater(g), isFalse);
      expect(await _total(_day), isNull);
    });
  });

  group('remove', () {
    test('subtracts exactly that glass and no other water', () async {
      await LocalDb.putJournalMetrics(_day, const {
        'water_ml': JournalMetricValue(500, atMinuteOfDay: 7 * 60),
      });
      await _log(600);
      await _log(720);
      expect(await _total(_day), 1000);
      final glasses = await LocalDb.assumedWater(date: _day);
      expect(await LocalDb.removeAssumedWater(glasses.first), isTrue);
      expect(await _total(_day), 750);
      final left = await LocalDb.assumedWater(date: _day);
      expect([for (final x in left) x.hhmm], ['12:00']);
    });

    test('a glass that was clamped at the ceiling takes back only what it '
        'added', () async {
      await LocalDb.putJournalMetrics(_day, {
        'water_ml': JournalMetricValue(_spec.max - 100, atMinuteOfDay: 60),
      });
      await _log(600);
      await LocalDb.removeAssumedWater(
          (await LocalDb.assumedWater(date: _day)).single);
      expect(await _total(_day), _spec.max - 100);
    });

    test('removing twice subtracts once', () async {
      await _log(600);
      await _log(720);
      final g = (await LocalDb.assumedWater(date: _day)).first;
      expect(await LocalDb.removeAssumedWater(g), isTrue);
      expect(await LocalDb.removeAssumedWater(g), isFalse);
      expect(await _total(_day), 250);
    });

    test('removing the only water of the day returns the day to ABSENT, not '
        'a logged zero', () async {
      await _log(600);
      await LocalDb.removeAssumedWater(
          (await LocalDb.assumedWater(date: _day)).single);
      expect((await LocalDb.journalMetricsForDay(_day)).containsKey('water_ml'),
          isFalse);
    });

    test('a removed slot is a tombstone: it cannot be logged again', () async {
      await _log(600);
      await LocalDb.removeAssumedWater(
          (await LocalDb.assumedWater(date: _day)).single);
      expect(await _log(600), isFalse);
      expect(await _total(_day), isNull);
      expect(await LocalDb.assumedWater(date: _day), isEmpty);
      final all = await LocalDb.assumedWater(date: _day, includeRemoved: true);
      expect(all.single.state, AssumedState.removed);
    });

    test('removing a kept glass works the same', () async {
      await _log(600);
      final g = (await LocalDb.assumedWater(date: _day)).single;
      await LocalDb.keepAssumedWater(g);
      await LocalDb.removeAssumedWater(
          (await LocalDb.assumedWater(date: _day)).single);
      expect(await _total(_day), isNull);
    });

    test('the day total never goes below zero if it was stepped down since',
        () async {
      await _log(600);
      await _log(720);
      // The wearer stepped the day total down by hand to 100 ml.
      await LocalDb.putJournalMetrics(_day, const {
        'water_ml': JournalMetricValue(100, atMinuteOfDay: 720),
      });
      await LocalDb.removeAssumedWater(
          (await LocalDb.assumedWater(date: _day)).first);
      final t = await _total(_day);
      expect(t == null || t >= 0, isTrue);
    });
  });

  group('the assumed share of a day\'s water', () {
    test('is the sum of assumed and kept glasses, 0 when none', () async {
      expect(await LocalDb.assumedWaterMl(_day), 0);
      await _log(600);
      await _log(720);
      await _log(840);
      final gs = await LocalDb.assumedWater(date: _day);
      await LocalDb.keepAssumedWater(gs[1]);
      await LocalDb.removeAssumedWater(gs[2]);
      expect(await LocalDb.assumedWaterMl(_day), 500);
    });

    test('never exceeds the day\'s total (the wearer stepped it down)',
        () async {
      await _log(600);
      await _log(720);
      await LocalDb.putJournalMetrics(_day, const {
        'water_ml': JournalMetricValue(250, atMinuteOfDay: 720),
      });
      expect(await LocalDb.assumedWaterMl(_day), 250);
    });

    test('is per day', () async {
      await _log(600);
      await _log(600, date: '2026-10-06');
      expect(await LocalDb.assumedWaterMl(_day), 250);
      expect(await LocalDb.assumedWaterMl('2026-10-06'), 250);
      expect(await LocalDb.assumedWaterMl('2026-10-05'), 0);
    });
  });

  group('which slots are due (pure)', () {
    final now = DateTime(2026, 10, 7, 12, 30);

    test('every slot from the moment the toggle was switched on up to now',
        () {
      final due = AssumedWater.dueSlots(_prefs(DateTime(2026, 10, 7, 7, 0)),
          now: now);
      expect(due, [
        DateTime(2026, 10, 7, 8, 0),
        DateTime(2026, 10, 7, 10, 0),
        DateTime(2026, 10, 7, 12, 0),
      ]);
    });

    test('a slot exactly at now is due; the next one is not', () {
      final due = AssumedWater.dueSlots(_prefs(DateTime(2026, 10, 7, 7, 0)),
          now: DateTime(2026, 10, 7, 12, 0));
      expect(due.last, DateTime(2026, 10, 7, 12, 0));
      expect(due, hasLength(3));
    });

    test('NO gap filling: nothing before the toggle was switched on', () {
      final due = AssumedWater.dueSlots(_prefs(DateTime(2026, 10, 7, 10, 30)),
          now: now);
      expect(due, [DateTime(2026, 10, 7, 12, 0)]);
    });

    test('switched on after the last slot of the day: nothing is due', () {
      final due = AssumedWater.dueSlots(_prefs(DateTime(2026, 10, 7, 12, 10)),
          now: now);
      expect(due, isEmpty);
    });

    test('slots on earlier days are due too (missed while the app was dead)',
        () {
      final due = AssumedWater.dueSlots(_prefs(DateTime(2026, 10, 5, 20, 30)),
          now: DateTime(2026, 10, 7, 9, 0));
      // 20:30 on the 5th is after the 20:00 slot and before the next 08:00.
      expect(due.where((d) => d.day == 5), isEmpty);
      expect(due.where((d) => d.day == 6), hasLength(7));
      expect(due.where((d) => d.day == 7), [DateTime(2026, 10, 7, 8, 0)]);
    });

    test('never looks back further than the lookback window', () {
      final n = DateTime(2026, 10, 7, 12, 30);
      final due = AssumedWater.dueSlots(_prefs(DateTime(2026, 9, 1)), now: n);
      expect(AssumedWater.lookbackDays, 7);
      expect(due.first, DateTime(2026, 9, 30, 14, 0),
          reason: 'cutoff = now\'s wall minute (12:30) 7 calendar days back, '
              'so the 12:00 slot of that day is just outside');
      expect(due.last, DateTime(2026, 10, 7, 12, 0));
    });

    test('toggle off: nothing; reminder off: nothing; no turn-on time: '
        'nothing (never guessed)', () {
      final since = DateTime(2026, 10, 7, 7, 0);
      expect(AssumedWater.dueSlots(_prefs(since, assume: false), now: now),
          isEmpty);
      expect(AssumedWater.dueSlots(_prefs(since, water: false), now: now),
          isEmpty);
      expect(
          AssumedWater.dueSlots(
              const NotificationPrefs(
                  waterEnabled: true,
                  quietEnabled: false,
                  waterAssumeDrank: true),
              now: now),
          isEmpty);
    });

    test('follows the reminder\'s own slots (interval, quiet hours)', () {
      final since = DateTime(2026, 10, 7, 0, 0);
      final every4h = _prefs(since).copyWith(waterIntervalMin: 240);
      expect(AssumedWater.dueSlots(every4h, now: now), [
        DateTime(2026, 10, 7, 8, 0),
        DateTime(2026, 10, 7, 12, 0),
      ]);
    });
  });

  group('catch-up on the next app run', () {
    final now = DateTime(2026, 10, 7, 12, 30);
    final since = DateTime(2026, 10, 7, 7, 0);

    test('logs every due slot once, on the slot\'s day, marked assumed',
        () async {
      final n = await AssumedWater.catchUp(_prefs(since),
          now: now, system: UnitSystem.metric);
      expect(n, 3);
      expect(await _total(_day), 750);
      final gs = await LocalDb.assumedWater(date: _day);
      expect([for (final g in gs) g.hhmm], ['08:00', '10:00', '12:00']);
      expect(gs.map((g) => g.state), everyElement(AssumedState.assumed));
      expect(gs.map((g) => g.ml), everyElement(250));
      expect((await LocalDb.journalMetricsForDay(_day))['water_ml']!
              .atMinuteOfDay,
          720);
    });

    test('running it again is a no-op; a later run adds only the new slot',
        () async {
      await AssumedWater.catchUp(_prefs(since),
          now: now, system: UnitSystem.metric);
      expect(
          await AssumedWater.catchUp(_prefs(since),
              now: now, system: UnitSystem.metric),
          0);
      expect(await _total(_day), 750);
      expect(
          await AssumedWater.catchUp(_prefs(since),
              now: DateTime(2026, 10, 7, 15, 0), system: UnitSystem.metric),
          1);
      expect(await _total(_day), 1000);
    });

    test('two runs at once log each slot once', () async {
      final rs = await Future.wait([
        AssumedWater.catchUp(_prefs(since),
            now: now, system: UnitSystem.metric),
        AssumedWater.catchUp(_prefs(since),
            now: now, system: UnitSystem.metric),
      ]);
      expect(rs.reduce((a, b) => a + b), 3);
      expect(await _total(_day), 750);
    });

    test('a slot the wearer removed is not logged again by a later run',
        () async {
      await AssumedWater.catchUp(_prefs(since),
          now: now, system: UnitSystem.metric);
      final ten = (await LocalDb.assumedWater(date: _day))
          .firstWhere((g) => g.hhmm == '10:00');
      await LocalDb.removeAssumedWater(ten);
      expect(
          await AssumedWater.catchUp(_prefs(since),
              now: now, system: UnitSystem.metric),
          0);
      expect(await _total(_day), 500);
    });

    test('slots missed across days land on THEIR local day', () async {
      final n = await AssumedWater.catchUp(
          _prefs(DateTime(2026, 10, 5, 20, 30)),
          now: DateTime(2026, 10, 7, 9, 0),
          system: UnitSystem.metric);
      expect(n, 8);
      expect(await _total('2026-10-05'), isNull);
      expect(await _total('2026-10-06'), 1750);
      expect(await _total('2026-10-07'), 250);
    });

    test('the glass is the unit system\'s step (imperial: exact 8 fl oz)',
        () async {
      await AssumedWater.catchUp(_prefs(since),
          now: now, system: UnitSystem.imperial);
      final t = (await _total(_day))!;
      expect(t, closeTo(3 * _cup, 1e-6));
      expect(WaterUnits.format(t, UnitSystem.imperial), '24 fl oz');
    });

    test('off means nothing is written at all', () async {
      expect(
          await AssumedWater.catchUp(_prefs(since, assume: false),
              now: now, system: UnitSystem.metric),
          0);
      expect(await LocalDb.assumedWater(), isEmpty);
      expect(await _total(_day), isNull);
    });

    test('works whatever the marked-moment follow-up setting is (it is not '
        'an input)', () async {
      // catchUp takes prefs, a clock and a unit system, nothing about moments.
      final n = await AssumedWater.catchUp(_prefs(since),
          now: now, system: UnitSystem.metric);
      expect(n, 3);
      expect(await LocalDb.assumedWaterMl(_day), 750);
    });
  });
}
