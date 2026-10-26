import 'dart:io';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/assumed_water.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/day_review.dart';
import 'package:flutter/services.dart';
import 'package:openstrap_edge/data/backup_extras.dart';
import 'package:openstrap_edge/data/journal_fields.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/gestures/moment_follow_ups.dart';
import 'package:openstrap_edge/gestures/moment_review_queue.dart';
import 'package:openstrap_edge/notify/notification_prefs.dart';
import 'package:openstrap_edge/notify/reminder_sleep_gate.dart';
import 'package:openstrap_edge/state/units_controller.dart';
import 'package:openstrap_edge/ui2/chart_annotations.dart';
import 'package:openstrap_edge/ui2/screens/day_timeline.dart';
import 'package:openstrap_edge/ui2/screens/day_review.dart';
import 'sleep_gate_test.dart' show at, nocturnal;

const day = '2026-10-26';
final repo = LocalRepositoryImpl(getProfileMap: () => null);
int serial = 0;

Future<List<int>> waterTimes() async {
  final data = await TimelineData.load(repo, want: day);
  return [
    for (final m in data.moments)
      if (m.annotationKind == AnnotationKind.water ||
          m.annotationKind == AnnotationKind.assumedWater)
        m.at,
  ];
}

int sec(int hour, [int minute = 0]) =>
    at(hour, minute).millisecondsSinceEpoch ~/ 1000;
Future<void> seedReview() async {
  for (final m in [1020, 1140, 1260]) {
    await LocalDb.logAssumedWater(
      date: day,
      atMin: m,
      ml: 250,
      loggedAtMs: at(21).millisecondsSinceEpoch,
    );
  }
  final glasses = await LocalDb.assumedWater(date: day);
  await repo.saveDayReview(
    activities: [],
    moments: const [
      MomentDecision(
        PendingMoment(date: day, hhmm: '18:30'),
        ReviewDecision.label(MomentChoice.water),
      ),
    ],
    glasses: {glasses[0]: true, glasses[1]: false, glasses[2]: true},
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => '/tmp',
        );
    await LocalDb.close();
    LocalDb.dbName = '/tmp/p3-water-${serial++}.db';
    await databaseFactory.deleteDatabase(LocalDb.dbName);
    await LocalDb.instance;
  });
  tearDown(() async {
    final name = LocalDb.dbName;
    await LocalDb.close();
    await databaseFactory.deleteDatabase(name);
  });
  test(
    'review Save retains kept slots and logged glass on reloaded timeline',
    () async {
      await seedReview();
      // Two kept 250 ml slots plus one explicitly logged 250 ml glass.
      expect((await LocalDb.journalMetricsForDay(day))['water_ml']!.value, 750);
      expect(await waterTimes(), [sec(17), sec(18, 30), sec(21)]);
    },
  );
  test(
    'reviewed glasses survive close and reopen without re-adding totals',
    () async {
      await seedReview();
      await LocalDb.close();
      await repo.saveDayReview(
        activities: [],
        moments: [],
        glasses: {
          for (final g in await LocalDb.assumedWater(date: day)) g: true,
        },
      );
      expect((await LocalDb.journalMetricsForDay(day))['water_ml']!.value, 750);
      expect(await waterTimes(), [sec(17), sec(18, 30), sec(21)]);
    },
  );
  test(
    'backup restores moments and removed tombstones and is repeatable',
    () async {
      await seedReview();
      final backup = await LocalDb.exportCopy(extras: BackupExtras.none);
      try {
        final db = await LocalDb.instance;
        for (final table in [
          'assumed_water',
          'moment_label',
          'journal_metric',
          'journal',
        ]) {
          await db.delete(table);
        }
        expect(await waterTimes(), isEmpty);
        await LocalDb.importFromDbFile(backup);
        await LocalDb.importFromDbFile(backup);
        await LocalDb.close();
        expect(
          (await LocalDb.journalMetricsForDay(day))['water_ml']!.value,
          750,
        );
        expect(
          (await LocalDb.assumedWater(
            date: day,
            includeRemoved: true,
          )).map((g) => g.state).toList(),
          [AssumedState.kept, AssumedState.removed, AssumedState.kept],
        );
        expect(await waterTimes(), [sec(17), sec(18, 30), sec(21)]);
      } finally {
        await File(backup).delete();
      }
    },
  );
  test(
    'two glass increments retain both timestamps after saving day total',
    () async {
      await repo.postJournalMetrics(day, {
        'water_ml': const JournalMetricValue(250, atMinuteOfDay: 1035),
      });
      await repo.postJournalMetrics(day, {
        'water_ml': const JournalMetricValue(500, atMinuteOfDay: 1110),
      });
      await repo.postJournalMetrics(day, {
        'water_ml': const JournalMetricValue(500, atMinuteOfDay: 1110),
      });
      await repo.saveDayReview(activities: [], moments: []);
      await LocalDb.close();
      expect((await LocalDb.journalMetricsForDay(day))['water_ml']!.value, 500);
      expect(await waterTimes(), [sec(17, 15), sec(18, 30)]);
    },
  );
  test('catch-up neither assumes sleep slots nor loses awake slots', () async {
    final suppressed = <SuppressedReminderSlot>[];
    final prefs = NotificationPrefs(
      waterEnabled: true,
      waterAssumeDrank: true,
      waterAssumeSinceMs: at(0).millisecondsSinceEpoch,
    );
    await AssumedWater.catchUp(
      prefs,
      now: at(21),
      system: UnitSystem.metric,
      sleep: nocturnal,
      onSuppressed: suppressed.add,
    );
    expect(
      (await LocalDb.assumedWater(date: day)).map((g) => g.atMin).toList(),
      [420, 1020, 1140, 1260],
    );
    expect((await LocalDb.journalMetricsForDay(day))['water_ml']!.value, 1000);
    expect(suppressed.map((s) => s.at).toList(), [
      at(9),
      at(11),
      at(13),
      at(15),
    ]);
    expect(
      suppressed.map((s) => s.reason),
      everyElement(ReminderSuppression.sleepSchedule),
    );
  });
  test(
    'later detected sleep withdraws unreviewed assumptions exactly once',
    () async {
      for (final m in [480, 600, 720]) {
        await LocalDb.logAssumedWater(
          date: day,
          atMin: m,
          ml: 250,
          loggedAtMs: 1,
        );
      }
      final gate = ReminderSleepGate(
        periods: [ReminderSleepPeriod(at(9), at(13))],
      );
      final prefs = NotificationPrefs(
        waterEnabled: true,
        waterAssumeDrank: true,
        quietEnabled: false,
        waterAssumeSinceMs: at(8).millisecondsSinceEpoch,
      );
      for (var n = 0; n < 2; n++) {
        await AssumedWater.catchUp(
          prefs,
          now: at(12),
          system: UnitSystem.metric,
          sleep: gate,
        );
      }
      expect(
        (await LocalDb.assumedWater(date: day)).map((g) => g.atMin).toList(),
        [480],
      );
      expect((await LocalDb.journalMetricsForDay(day))['water_ml']!.value, 250);
      expect(
        (await LocalDb.assumedWater(date: day, includeRemoved: true))
            .where((g) => g.state == AssumedState.removed)
            .map((g) => g.atMin)
            .toList(),
        [600, 720],
      );
    },
  );
  test('catch-up reads saved schedule without an injected gate', () async {
    SharedPreferences.setMockInitialValues({
      'expected_sleep_schedule_v1': '{"onsetMinute":480,"wakeMinute":960}',
    });
    await AssumedWater.catchUp(
      NotificationPrefs(
        waterEnabled: true,
        waterAssumeDrank: true,
        waterAssumeSinceMs: at(0).millisecondsSinceEpoch,
      ),
      now: at(21),
      system: UnitSystem.metric,
    );
    expect(
      (await LocalDb.assumedWater(date: day)).map((g) => g.atMin).toList(),
      [420, 1020, 1140, 1260],
    );
  });
  test(
    'context load consumes provisional detected sleep instead of band wear',
    () async {
      await LocalDb.putDayResult(
        dayId: day,
        algoVersion: 1,
        payloadJson: '{}',
        windowJson: jsonEncode({
          'value': {'onset_ms': at(9).millisecondsSinceEpoch},
        }),
      );
      final gate = await ReminderSleepGate.load(now: at(12));
      expect(
        gate.reasonAt(const NotificationPrefs(quietEnabled: false), at(12)),
        ReminderSuppression.asleep,
      );
    },
  );
  test(
    'catch-up reads stored detected sleep and withdraws sleeping slots',
    () async {
      for (final m in [480, 600, 720]) {
        await LocalDb.logAssumedWater(
          date: day,
          atMin: m,
          ml: 250,
          loggedAtMs: 1,
        );
      }
      await LocalDb.putDayResult(
        dayId: day,
        algoVersion: 1,
        payloadJson: '{}',
        windowJson: jsonEncode({
          'value': {
            'onset_ms': at(9).millisecondsSinceEpoch,
            'offset_ms': at(13).millisecondsSinceEpoch,
          },
        }),
      );
      final prefs = NotificationPrefs(
        waterEnabled: true,
        waterAssumeDrank: true,
        quietEnabled: false,
        waterAssumeSinceMs: at(8).millisecondsSinceEpoch,
      );
      await AssumedWater.catchUp(prefs, now: at(13), system: UnitSystem.metric);
      expect(
        (await LocalDb.assumedWater(date: day)).map((g) => g.atMin).toList(),
        [480],
      );
      expect((await LocalDb.journalMetricsForDay(day))['water_ml']!.value, 250);
    },
  );

  test(
    'reopened review shows kept moments without asking for them again',
    () async {
      await seedReview();
      final review = DayReviewController(
        repo,
        day,
        moments: const [],
        activities: const [],
      );
      addTearDown(review.dispose);
      await review.load();
      expect(review.loadFailed, isFalse);
      expect(
        review.ids,
        isEmpty,
        reason: 'kept and removed glasses have been reviewed',
      );
      expect(await waterTimes(), [sec(17), sec(18, 30), sec(21)]);
    },
  );
  test('separate logged glasses in the same minute both survive', () async {
    await repo.postJournalMetrics(day, {
      'water_ml': const JournalMetricValue(250, atMinuteOfDay: 1035),
    });
    await repo.postJournalMetrics(day, {
      'water_ml': const JournalMetricValue(500, atMinuteOfDay: 1035),
    });
    await LocalDb.close();
    expect((await LocalDb.journalMetricsForDay(day))['water_ml']!.value, 500);
    expect(await waterTimes(), [sec(17, 15), sec(17, 15)]);
  });
  test(
    'missing sleep evidence stays unknown rather than treating band wear as sleep',
    () async {
      final gate = await ReminderSleepGate.load(now: at(12));
      expect(gate.schedule, isNull);
      expect(gate.periods, isEmpty);
      expect(
        gate.reasonAt(const NotificationPrefs(quietEnabled: false), at(12)),
        isNull,
      );
    },
  );
}
