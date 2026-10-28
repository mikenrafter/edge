import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/tracks_store.dart';
import 'package:openstrap_edge/notify/notification_prefs.dart';
import 'package:openstrap_edge/notify/notification_service.dart';
import 'package:openstrap_edge/notify/reminder_sleep_gate.dart';
import 'package:openstrap_edge/state/control_operations.dart';
import 'package:openstrap_edge/tracks/experiment_reminders.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../backup/backup_support.dart';

// The real OS scheduler transport is captured at the plugin channel, the same
// way the water reminder tests do.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BackupEnv env;
  late Database db;
  late TracksStore store;
  final calls = <MethodCall>[];
  const channel = MethodChannel('dexterous.com/flutter/local_notifications');
  // Experiment starts 2026-10-26: day 0 is today at 06:00 local.
  final morning = DateTime(2026, 10, 26, 6);

  setUp(() async {
    env = await BackupEnv.create('tracks_experiment_reminders.db');
    db = await LocalDb.instance;
    store = TracksStore(db);
    SharedPreferences.setMockInitialValues({});
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    NotificationService.instance.debugRequestPermission = () async => true;
    NotificationService.instance.debugProbePermission = () async => true;
    NotificationService.instance.invalidatePermissionCache();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return true;
        });
    calls.clear();
    await store.saveDefinition(
      const TrackDefinition(
        id: 'custom',
        name: 'Evening walk',
        icon: 'track',
        kind: 'activity',
        systems: ['hr'],
      ),
    );
    // The app's listener: every start, stop and track save re-arms the schedule.
    TracksStore.scheduleListener = const ExperimentReminderListener();
    calls.clear();
  });
  tearDown(() async {
    TracksStore.scheduleListener = null;
    debugDefaultTargetPlatformOverride = null;
    NotificationService.instance.debugProbePermission = null;
    NotificationService.instance.debugRequestPermission = null;
    NotificationService.instance.invalidatePermissionCache();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await env.dispose();
  });

  // The listener re-arms on start; these tests drive refresh() themselves, so
  // forget the start's own scheduling calls.
  Future<void> startToday() async {
    await withClock(
      Clock.fixed(morning),
      () => store.startExperiment(
        trackId: 'custom',
        startDate: '2026-10-26',
        weeks: 2,
        seed: 17,
      ),
    );
    calls.clear();
  }

  Future<void> refresh(
    DateTime now, {
    NotificationPrefs prefs = const NotificationPrefs(),
    ReminderSleepGate sleep = const ReminderSleepGate(),
  }) => withClock(
    Clock.fixed(now),
    () => ExperimentReminders.refresh(prefs, sleep: sleep),
  );

  List<MethodCall> armed() =>
      calls.where((c) => c.method == 'zonedSchedule').toList();
  List<int> armedIds() => [for (final c in armed()) (c.arguments as Map)['id'] as int];
  // The plugin serializes the instant in the timezone database's local zone,
  // which is UTC in tests, without an offset: read it as UTC, show it local.
  DateTime when(MethodCall c) {
    final raw = (c.arguments as Map)['scheduledDateTime'] as String;
    final hasZone = raw.endsWith('Z') || RegExp(r'[+-]\d\d:?\d\d$').hasMatch(raw);
    return DateTime.parse(hasZone ? raw : '${raw}Z').toLocal();
  }

  test('arms one morning one-shot per assigned day ahead, in the experiment band',
      () async {
    await startToday();
    await refresh(morning);
    final slots = armed();
    expect(slots, hasLength(14), reason: 'every assigned day of a 2 week experiment');
    expect(armedIds(), [
      for (var i = 0; i < slots.length; i++) NotificationService.idExperimentBase + i,
    ]);
    expect(when(slots.first).hour, 8);
    expect(when(slots.first).day, 26);
    expect(when(slots[1]).day, 27);
    // The lock screen names neither the track nor which arm today is.
    final args = slots.first.arguments as Map;
    expect('${args['title']} ${args['body']}'.toLowerCase(),
        isNot(anyOf(contains('walk'), contains('skip'))));
    expect(args['payload'], contains('/tracks/experiment'));
  });

  test("today's reminder is not armed once its morning has passed", () async {
    await startToday();
    await refresh(DateTime(2026, 10, 26, 13));
    final days = armed().map(when).toList();
    expect((days.first.month, days.first.day), (10, 27));
    expect(days, hasLength(13), reason: "today's passed morning is skipped, the rest stay armed");
  });

  test('a sleeping morning moves the reminder to when the wearer is up',
      () async {
    await startToday();
    // Expected sleep 22:00-09:30.
    await refresh(
      morning,
      sleep: const ReminderSleepGate(
        schedule: ExpectedSleepSchedule(onsetMinute: 1320, wakeMinute: 570),
      ),
    );
    final first = when(armed().first);
    expect([first.hour, first.minute], [9, 30]);
  });

  test('asleep all morning arms nothing for that day', () async {
    await startToday();
    await refresh(
      morning,
      sleep: const ReminderSleepGate(
        schedule: ExpectedSleepSchedule(onsetMinute: 1320, wakeMinute: 780),
      ),
    );
    expect(armed(), isEmpty);
  });

  test('with no running experiment the whole band is cancelled', () async {
    await refresh(morning);
    expect(armed(), isEmpty);
    final cancelled = [
      for (final c in calls)
        if (c.method == 'cancel') (c.arguments as Map)['id'] ?? c.arguments,
    ];
    expect(cancelled, containsAll([
      for (var i = 0; i < NotificationService.maxExperimentSlots; i++)
        NotificationService.idExperimentBase + i,
    ]));
  });

  test('after the experiment ends the next pass cancels what was armed',
      () async {
    await startToday();
    await refresh(morning);
    expect(armed(), isNotEmpty);
    calls.clear();
    await refresh(DateTime(2026, 11, 20, 6));
    expect(armed(), isEmpty);
    expect(calls.where((c) => c.method == 'cancel'), isNotEmpty);
  });

  // why: review R2-8. Only three days were armed and headless sync does not
  // replenish them, so an app left closed lost the rest of a 2-4 week run. One
  // foreground pass must arm every remaining assignment, up to the band size.
  // proves: CLAIM(reminders-arm-all)
  test('a four week experiment is fully armed by one pass, app closed afterwards', () async {
    await withClock(Clock.fixed(morning), () => store.startExperiment(
      trackId: 'custom', startDate: '2026-10-26', weeks: 4, seed: 17));
    calls.clear();
    await refresh(morning);
    final slots = armed();
    expect(slots, hasLength(28));
    expect(armedIds().toSet(), hasLength(28), reason: 'one distinct id per day');
    expect(armedIds().first, NotificationService.idExperimentBase);
    expect(armedIds().last, NotificationService.idExperimentBase + 27);
    final days = slots.map(when).map((d) => DateTime(d.year, d.month, d.day)).toList();
    for (var i = 1; i < days.length; i++) {
      expect(days[i].isAfter(days[i - 1]), isTrue, reason: 'one per calendar day, in order');
    }
    expect(NotificationService.maxExperimentSlots, greaterThanOrEqualTo(28));
  });

  // why: review R2-7. After the 08:00 reminder fired, a refresh at 08:05 armed
  // another at 08:30 and later refreshes continued to noon. A day whose armed
  // instant has passed is delivered: never re-armed.
  // proves: CLAIM(reminder-delivered-guard)
  test('a day whose reminder time has passed is not armed again', () async {
    await startToday();
    await refresh(morning);
    expect(when(armed().first).hour, 8);
    calls.clear();
    await refresh(DateTime(2026, 10, 26, 8, 5));
    final days = armed().map(when).map((d) => d.day).toList();
    expect(days, isNot(contains(26)), reason: "today's reminder already fired");
    expect(days.first, 27);
    calls.clear();
    await refresh(DateTime(2026, 10, 26, 11));
    expect(armed().map(when).map((d) => d.day), isNot(contains(26)));
  });

  test('before it fires, the same day is re-armed at the same time', () async {
    await startToday();
    await refresh(morning);
    calls.clear();
    await refresh(DateTime(2026, 10, 26, 7));
    final first = when(armed().first);
    expect((first.day, first.hour, first.minute), (26, 8, 0));
  });

  // why: review T8 / R2-2. Starting after the foreground pass left nothing armed;
  // stopping, disabling or marking a track prescribed and then closing the app
  // left armed slots firing. Every such change re-arms through the one
  // scheduler, and the stale slots are cancelled at the plugin channel.
  // proves: CLAIM(reminders-follow-state)
  Set<int> cancelledIds() => {
    for (final c in calls)
      if (c.method == 'cancel') ((c.arguments as Map?)?['id'] ?? c.arguments) as int,
  };
  final band = {
    for (var i = 0; i < NotificationService.maxExperimentSlots; i++)
      NotificationService.idExperimentBase + i,
  };

  Future<T> at<T>(DateTime now, Future<T> Function() run) =>
      withClock(Clock.fixed(now), run);

  test('starting an experiment arms it without waiting for another pass', () async {
    await at(morning, () => store.startExperiment(
      trackId: 'custom', startDate: '2026-10-26', weeks: 2, seed: 17));
    expect(armed(), hasLength(14));
  });

  test('stopping cancels the armed band and arms nothing', () async {
    final experiment = await at(morning, () => store.startExperiment(
      trackId: 'custom', startDate: '2026-10-26', weeks: 2, seed: 17));
    expect(armed(), isNotEmpty);
    calls.clear();
    await at(DateTime(2026, 10, 27, 9), () => store.stopExperiment(experiment['id'] as String));
    expect(armed(), isEmpty);
    expect(cancelledIds(), containsAll(band));
  });

  test('disabling or marking the track prescribed cancels the band', () async {
    await at(morning, () => store.startExperiment(
      trackId: 'custom', startDate: '2026-10-26', weeks: 2, seed: 17));
    for (final change in <Map<String, Object?>>[
      {'enabled': false},
      {'prescribed': true},
    ]) {
      final current = (await store.definitions()).firstWhere((d) => d.id == 'custom');
      calls.clear();
      await at(morning, () => store.saveDefinition(TrackDefinition.fromJson({...current.toJson(), ...change})));
      expect(armed(), isEmpty, reason: '$change');
      expect(cancelledIds(), containsAll(band), reason: '$change');
      calls.clear();
      await at(morning, () => store.saveDefinition(TrackDefinition.fromJson({
        ...current.toJson(),
        'enabled': true,
        'prescribed': false,
      })));
      expect(armed(), isNotEmpty, reason: 'back on: $change');
    }
  });

  test('deleting a track (archiving it) cancels the band', () async {
    await at(morning, () => store.startExperiment(
      trackId: 'custom', startDate: '2026-10-26', weeks: 2, seed: 17));
    calls.clear();
    await at(morning, () => store.deleteDefinition('custom'));
    expect(armed(), isEmpty);
    expect(cancelledIds(), containsAll(band));
  });

  test('refreshAfterChange never throws and clears when nothing runs', () async {
    await at(morning, () => ExperimentReminders.refreshAfterChange(
      prefs: const NotificationPrefs(), sleep: const ReminderSleepGate()));
    expect(cancelledIds(), containsAll(band));
  });
}
