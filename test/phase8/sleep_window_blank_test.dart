// 8E — a sleep window the samples do not cover is a NIGHT NOT RECORDED.
//
// Saving never depends on samples; every sleep metric for that night is blank;
// every calculation that depends on sleep skips the night instead of counting
// it (as 0 h, or as a mid-sleep time taken from the bare window). See
// test/phase8/CONTRACTS.md §8E.
//
// The cross-day half is pure (buildCrossDayBundle). A "blank night" there is a
// day record whose window is known (onset_sec / wake_sec, from the user's
// assertion) but whose tst_min is null because nothing was recorded in it.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/crossday_pipeline.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/state/control_operations.dart';
import 'package:openstrap_edge/ui2/screens/sleep_detail.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

String _label(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

int _sec(DateTime d) => d.millisecondsSinceEpoch ~/ 1000;

/// 28 recorded nights ending 2026-09-27, 23:xx -> 07:xx local, with a little
/// variation so every family has something to compute.
List<Map<String, dynamic>> _nights() => [
      for (var i = 0; i < 28; i++)
        () {
          final wakeDay = DateTime(2026, 8, 31 + i);
          final onset = DateTime(wakeDay.year, wakeDay.month, wakeDay.day - 1,
              23, (i * 7) % 50);
          final free = wakeDay.weekday >= DateTime.saturday;
          final wake = DateTime(wakeDay.year, wakeDay.month, wakeDay.day,
              free ? 8 : 7, (i * 11) % 40);
          return <String, dynamic>{
            'date': _label(wakeDay),
            'onset_sec': _sec(onset),
            'wake_sec': _sec(wake),
            'tst_min': (wake.difference(onset).inMinutes * 0.9).round(),
            'efficiency': 88 + (i % 5),
            'rhr': 52 + (i % 4),
            'rmssd': 48 + (i % 6),
          };
        }(),
    ];

/// A Saturday in the middle of [_nights], turned into a blank night: the user
/// asserted 13:00 -> 15:00, and nothing was recorded.
Map<String, dynamic> _blank(Map<String, dynamic> real) {
  final d = DateTime.parse(real['date'] as String);
  return {
    'date': real['date'],
    'onset_sec': _sec(DateTime(d.year, d.month, d.day, 13)),
    'wake_sec': _sec(DateTime(d.year, d.month, d.day, 15)),
    'tst_min': null,
    'efficiency': null,
    'rhr': null,
    'rmssd': null,
  };
}

int _middleSaturday(List<Map<String, dynamic>> nights) {
  for (var i = nights.length ~/ 2; i < nights.length - 2; i++) {
    if (DateTime.parse(nights[i]['date'] as String).weekday ==
        DateTime.saturday) {
      return i;
    }
  }
  throw StateError('no Saturday');
}

/// Every cross-day family that reads sleep timing or duration. Regularity
/// (SRI) is excluded on purpose: it compares ADJACENT nights, so dropping a
/// row is not the same input as a gap.
const _sleepFamilies = [
  'sleep_debt',
  'social_jetlag',
  'chronotype',
  'sleep_coach',
];

void main() {
  group('cross-day: a blank night is skipped, not counted', () {
    final nights = _nights();
    final i = _middleSaturday(nights);
    final withBlank = [...nights]..[i] = _blank(nights[i]);
    final without = [...nights]..removeAt(i);

    final a = buildCrossDayBundle(withBlank, const {});
    final b = buildCrossDayBundle(without, const {});

    for (final key in _sleepFamilies) {
      test('$key over 27 real + 1 blank night equals the 27-night result',
          () {
        expect(jsonEncode(a[key]), jsonEncode(b[key]));
      });
    }

    test('the families under test are actually computed (non-vacuous)', () {
      for (final key in ['sleep_debt', 'social_jetlag', 'chronotype']) {
        // The reference (no blank night) must compute every family, or the
        // equality checks above prove nothing.
        expect((b[key] as Map)['value'], isNot('—'), reason: key);
      }
    });

    test('a blank last night makes sleep performance blank, not last week\'s',
        () {
      final lastBlank = [...nights]..[nights.length - 1] =
          _blank(nights[nights.length - 1]);
      final bundle = buildCrossDayBundle(lastBlank, const {});
      final perf = (bundle['sleep_coach'] as Map)['performance'] as Map;
      expect(perf['value'], '—');
    });

    test('repeated derivation is idempotent', () {
      final again = buildCrossDayBundle(withBlank, const {});
      for (final key in _sleepFamilies) {
        expect(jsonEncode(again[key]), jsonEncode(a[key]), reason: key);
      }
    });
  });

  group('storage: the window persists with no samples (real LocalDb)', () {
    late LocalRepositoryImpl repo;
    setUpAll(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      LocalDb.dbName = 'phase8_sleep_window_blank_test.db';
      await databaseFactory.deleteDatabase(
        p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
      );
      repo = LocalRepositoryImpl(getProfileMap: () => {});
    });
    tearDownAll(() async {
      await LocalDb.close();
      await databaseFactory.deleteDatabase(
        p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
      );
    });

    test('set twice on a no-data night: persisted, metrics null, same result',
        () async {
      final c = SleepCoordinator(
        persist: (day, start, end) => LocalDb.putSleepOverride(
          dayId: day,
          onsetTs: start,
          offsetTs: end,
          source: 'manual',
        ),
        derive: (day) => repo.getDaySleep(day),
        saveSchedule: (_) async {},
      );
      final onset = DateTime(2026, 9, 20, 23);
      final wake = DateTime(2026, 9, 21, 7);
      final first = await c.setOverride('2026-09-21', onset, wake);
      final n1 = await repo.getDaySleep('2026-09-21');
      final second = await c.setOverride('2026-09-21', onset, wake);
      final n2 = await repo.getDaySleep('2026-09-21');
      expect(first.success && second.success, isTrue);
      expect(first.metricsAvailable || second.metricsAvailable, isFalse);
      expect(n1['onset_ts'], _sec(onset));
      expect(n1['wake_ts'], _sec(wake));
      expect(n1['sleep_source'], 'manual');
      for (final k in ['duration_min', 'efficiency', 'rhr']) {
        expect(n1[k], isNull, reason: '$k must be blank, never 0');
      }
      expect(jsonEncode(n2), jsonEncode(n1));
      c.dispose();
    });
  });

  group('Sleep screen', () {
    Future<void> pump(WidgetTester t, Widget w) async {
      t.view.physicalSize = const Size(1170, 15000);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      await t.pumpWidget(
          MaterialApp(theme: buildTheme(Brightness.light), home: w));
      await t.pumpAndSettle();
    }

    testWidgets('a night with no recording offers "Set the times myself"',
        (t) async {
      await pump(t, const SleepDetail(data: SleepData(day: '2026-09-30')));
      expect(find.text('Set the times myself'), findsOneWidget);
    });

    testWidgets('an asserted window with no data says so, metrics blank',
        (t) async {
      await pump(
          t,
          SleepDetail(
            data: SleepData(
              day: '2026-09-30',
              night: {
                'sleep_source': 'manual',
                'onset_ts': _sec(DateTime(2026, 9, 29, 23)),
                'wake_ts': _sec(DateTime(2026, 9, 30, 7)),
              },
            ),
          ));
      expect(find.text('You set this window'), findsOneWidget);
      expect(find.text('0h 0m'), findsNothing);
      expect(find.text('0%'), findsNothing);
    });
  });
}
