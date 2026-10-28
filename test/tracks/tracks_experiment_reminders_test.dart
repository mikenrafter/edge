import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/tracks_store.dart';
import 'package:openstrap_edge/notify/notification_event.dart';
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
// The plugin serializes the instant in the timezone database's local zone,
// which is UTC in tests, without an offset: read it as UTC, show it local.
DateTime _utc(String raw) {
  final hasZone = raw.endsWith('Z') || RegExp(r'[+-]\d\d:?\d\d$').hasMatch(raw);
  return DateTime.parse(hasZone ? raw : '${raw}Z').toLocal();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BackupEnv env;
  late Database db;
  late TracksStore store;
  final calls = <MethodCall>[];
  // A fake OS: the pending set, with an optional cap (iOS keeps the soonest),
  // a barrier on zonedSchedule, and a switch that hides the pending list.
  final pending = <int, DateTime>{};
  var cap = 100000;
  var pendingUnknown = false;
  Completer<void>? scheduleBarrier;
  Completer<void>? scheduleEntered;
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
          switch (call.method) {
            case 'zonedSchedule':
              final args = call.arguments as Map;
              if (scheduleEntered != null && !scheduleEntered!.isCompleted) {
                scheduleEntered!.complete();
              }
              if (scheduleBarrier != null) await scheduleBarrier!.future;
              pending[args['id'] as int] = _utc(args['scheduledDateTime'] as String);
              while (pending.length > cap) {
                final latest = pending.entries.reduce((a, b) => a.value.isAfter(b.value) ? a : b);
                pending.remove(latest.key);
              }
              return null;
            case 'cancel':
              final a = call.arguments;
              pending.remove(a is Map ? a['id'] : a);
              return null;
            case 'cancelAll':
              pending.clear();
              return null;
            case 'pendingNotificationRequests':
              if (pendingUnknown) throw PlatformException(code: 'unavailable');
              return [
                for (final id in pending.keys) {'id': id, 'title': 't', 'body': 'b', 'payload': null},
              ];
          }
          return true;
        });
    pending.clear();
    cap = 100000;
    pendingUnknown = false;
    scheduleBarrier = null;
    scheduleEntered = null;
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
    NotificationService.instance.debugPendingCap = null;
    debugDefaultTargetPlatformOverride = null;
    NotificationService.instance.debugProbePermission = null;
    NotificationService.instance.debugRequestPermission = null;
    NotificationService.instance.invalidatePermissionCache();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await env.dispose();
  });

  Future<Map<String, Object?>> startAt(DateTime now, {int weeks = 2, String from = '2026-10-26'}) =>
      withClock(Clock.fixed(now), () => store.startExperiment(
        trackId: 'custom', startDate: from, weeks: weeks, seed: 17));

  Future<void> refresh(
    DateTime now, {
    NotificationPrefs prefs = const NotificationPrefs(),
    ReminderSleepGate sleep = const ReminderSleepGate(),
  }) => withClock(
    Clock.fixed(now),
    () => ExperimentReminders.refresh(prefs, sleep: sleep),
  );

  /// The instants the fake OS holds for the experiment band, soonest first.
  List<DateTime> held() {
    final out = [
      for (final e in pending.entries)
        if (NotificationService.isExperimentSlot(e.key)) e.value,
    ]..sort();
    return out;
  }

  List<MethodCall> armed() => calls.where((c) => c.method == 'zonedSchedule').toList();
  Set<int> cancelledIds() => {
    for (final c in calls)
      if (c.method == 'cancel') ((c.arguments as Map?)?['id'] ?? c.arguments) as int,
  };
  DateTime when(MethodCall c) => _utc((c.arguments as Map)['scheduledDateTime'] as String);

  test('arms one morning one-shot per assigned day, in the experiment band', () async {
    await startAt(morning);
    final times = held();
    expect(times, hasLength(14), reason: 'every assigned day of a 2 week experiment');
    expect(times.first, DateTime(2026, 10, 26, 8));
    expect(times[1].day, 27);
    expect(pending.keys.every(NotificationService.isExperimentSlot), isTrue);
    expect(pending.keys.toSet(), hasLength(14), reason: 'one distinct id per day');
    // The lock screen names neither the track nor which arm today is.
    final args = armed().first.arguments as Map;
    expect('${args['title']} ${args['body']}'.toLowerCase(),
        isNot(anyOf(contains('walk'), contains('skip'))));
    expect(args['payload'], contains('/tracks/experiment'));
  });

  test("today's reminder is not armed once its morning has passed", () async {
    await startAt(DateTime(2026, 10, 26, 13));
    final times = held();
    expect((times.first.month, times.first.day), (10, 27));
    expect(times, hasLength(13));
  });

  test('a sleeping morning moves the reminder to when the wearer is up', () async {
    await refresh(morning); // nothing yet
    await startAt(morning);
    for (final id in pending.keys.toList()) {
      pending.remove(id);
    }
    await db.delete('compute_freshness');
    await refresh(
      morning,
      sleep: const ReminderSleepGate(
        schedule: ExpectedSleepSchedule(onsetMinute: 1320, wakeMinute: 570),
      ),
    );
    final first = held().first;
    expect([first.hour, first.minute], [9, 30]);
  });

  test('asleep all morning arms nothing for that day', () async {
    await startAt(morning);
    for (final id in pending.keys.toList()) {
      pending.remove(id);
    }
    await db.delete('compute_freshness');
    await refresh(
      morning,
      sleep: const ReminderSleepGate(
        schedule: ExpectedSleepSchedule(onsetMinute: 1320, wakeMinute: 780),
      ),
    );
    expect(held().where((d) => d.day == 26), isEmpty);
  });

  test('with the pending list unknown the whole band is cancelled and re-armed', () async {
    pendingUnknown = true;
    await refresh(morning);
    expect(cancelledIds(), {
      for (var i = 0; i < NotificationService.maxExperimentSlots; i++)
        NotificationService.idExperimentBase + i,
    });
    expect(armed(), isEmpty);
  });

  test('after the experiment ends the next pass leaves nothing pending', () async {
    await startAt(morning);
    expect(held(), isNotEmpty);
    await refresh(DateTime(2026, 11, 20, 6));
    expect(held(), isEmpty);
  });

  // why: review R2-8. Only three days were armed and headless sync does not
  // replenish them, so an app left closed lost the rest of a 2-4 week run. One
  // foreground pass must arm every remaining assignment the budget allows.
  // proves: CLAIM(reminders-arm-all)
  test('a four week experiment is fully armed by one pass, app closed afterwards', () async {
    await startAt(morning, weeks: 4);
    final times = held();
    expect(times, hasLength(28));
    final days = times.map((d) => DateTime(d.year, d.month, d.day)).toList();
    for (var i = 1; i < days.length; i++) {
      expect(days[i].isAfter(days[i - 1]), isTrue, reason: 'one per calendar day');
    }
  });

  // why: review R2-7 / R3-2. After 08:00 an inexact notification can still be
  // PENDING; the clock passing its time is not delivery. Pending is kept (no
  // cancel, no re-arm); only a slot the OS no longer holds is delivered.
  // proves: CLAIM(reminder-delivered-guard)
  test('a slow notification still pending at 08:05 is kept, not cancelled or re-armed', () async {
    await startAt(morning);
    calls.clear();
    await refresh(DateTime(2026, 10, 26, 8, 5));
    expect(armed(), isEmpty);
    expect(cancelledIds(), isEmpty);
    expect(held().first, DateTime(2026, 10, 26, 8));
  });

  test('once the OS has delivered it (no longer pending) the day is never armed again', () async {
    await startAt(morning);
    final id = pending.entries.firstWhere((e) => e.value.hour == 8 && e.value.day == 26).key;
    pending.remove(id); // fired: gone without a cancel
    calls.clear();
    await refresh(DateTime(2026, 10, 26, 8, 5));
    expect(armed(), isEmpty, reason: "today's reminder already fired");
    await refresh(DateTime(2026, 10, 26, 11));
    expect(armed(), isEmpty);
    expect(held().where((d) => d.day == 26), isEmpty);
  });

  test('before it fires, nothing is re-armed or moved', () async {
    await startAt(morning);
    calls.clear();
    await refresh(DateTime(2026, 10, 26, 7));
    expect(armed(), isEmpty);
    expect(held().first, DateTime(2026, 10, 26, 8));
  });

  // why: review R3-2. A marker written before scheduling succeeded suppressed
  // reminders that never fired. Denied permission or a failed schedule leaves no
  // marker, so a later pass arms normally.
  test('denied scheduling writes no marker; a later pass arms the reminder', () async {
    NotificationService.instance.debugProbePermission = () async => false;
    NotificationService.instance.debugRequestPermission = () async => false;
    NotificationService.instance.invalidatePermissionCache();
    await startAt(morning);
    expect(held(), isEmpty);
    expect(await db.query('compute_freshness', where: "key LIKE 'experiment_reminder:%'"), isEmpty);
    NotificationService.instance.debugProbePermission = () async => true;
    NotificationService.instance.debugRequestPermission = () async => true;
    NotificationService.instance.invalidatePermissionCache();
    await refresh(DateTime(2026, 10, 26, 7));
    expect(held().first, DateTime(2026, 10, 26, 8));
  });

  // why: review R3-2. Cancelled is not delivered: disabling before 08:00 and
  // re-enabling after it must arm again (the reminder never fired).
  test('disable before the time, re-enable after it: armed again', () async {
    await startAt(morning);
    final current = (await store.definitions()).firstWhere((d) => d.id == 'custom');
    await withClock(Clock.fixed(DateTime(2026, 10, 26, 7)), () => store.saveDefinition(
      TrackDefinition.fromJson({...current.toJson(), 'enabled': false})));
    expect(held(), isEmpty);
    expect(await db.query('compute_freshness', where: "key LIKE 'experiment_reminder:%'"), isEmpty,
        reason: 'cancelled intentions leave no marker');
    await withClock(Clock.fixed(DateTime(2026, 10, 26, 9)), () => store.saveDefinition(
      TrackDefinition.fromJson({...current.toJson(), 'enabled': true})));
    expect(held().first, DateTime(2026, 10, 26, 9, 30), reason: "today's reminder never fired");
  });

  // why: review T8 / R2-2. Every change that can alter the schedule re-arms or
  // cancels through the one scheduler, asserted at the plugin channel.
  // proves: CLAIM(reminders-follow-state)
  test('stopping cancels the pending band', () async {
    final experiment = await startAt(morning);
    final ids = pending.keys.toSet();
    calls.clear();
    await withClock(Clock.fixed(DateTime(2026, 10, 27, 9)), () => store.stopExperiment(experiment['id'] as String));
    expect(held(), isEmpty);
    expect(cancelledIds(), containsAll(ids.where((i) => true)));
    expect(armed(), isEmpty);
  });

  test('disabling or marking the track prescribed cancels the band', () async {
    await startAt(morning);
    for (final change in <Map<String, Object?>>[
      {'enabled': false},
      {'prescribed': true},
    ]) {
      final current = (await store.definitions()).firstWhere((d) => d.id == 'custom');
      await withClock(Clock.fixed(morning), () => store.saveDefinition(TrackDefinition.fromJson({...current.toJson(), ...change})));
      expect(held(), isEmpty, reason: '$change');
      await withClock(Clock.fixed(morning), () => store.saveDefinition(TrackDefinition.fromJson({
        ...current.toJson(),
        'enabled': true,
        'prescribed': false,
      })));
      expect(held(), isNotEmpty, reason: 'back on: $change');
    }
  });

  test('archiving the track cancels the band', () async {
    await startAt(morning);
    await withClock(Clock.fixed(morning), () => store.deleteDefinition('custom'));
    expect(held(), isEmpty);
  });

  // why: review R3-7. Assignment reads and the arm sat outside the scheduling
  // lock: a refresh that read the old assignments could arm them after a stop
  // had cancelled the band. Pass A is held inside zonedSchedule by a barrier
  // while the experiment is stopped (pass B); the final state must be empty.
  // proves: CLAIM(reminders-serialized)
  test('a stop during a running refresh leaves nothing armed', () async {
    // Experiment exists but is not armed yet: no listener on creation.
    TracksStore.scheduleListener = null;
    final experiment = await withClock(Clock.fixed(morning), () => store.startExperiment(
      trackId: 'custom', startDate: '2026-10-26', weeks: 2, seed: 17));
    TracksStore.scheduleListener = const ExperimentReminderListener();
    scheduleBarrier = Completer<void>();
    scheduleEntered = Completer<void>();
    final passA = refresh(morning);
    await scheduleEntered!.future; // A has read the assignments and is arming
    final stop = withClock(Clock.fixed(morning), () => store.stopExperiment(experiment['id'] as String));
    // B (queued behind A) cannot run until A finishes.
    scheduleBarrier!.complete();
    await passA;
    await stop;
    expect(held(), isEmpty, reason: 'the stop was applied after the stale pass');
  });

  // why: review R3-3 / R2-8. iOS keeps 64 pending notifications in total. The
  // experiment band takes only what is left after the higher classes (alarm >
  // medication > wind-down/check-in > water > experiment) and the slots held
  // back for higher singletons that may arm later; nearest dates first; it
  // grows when others shrink and shrinks when they grow. Fake transport: cap 64,
  // keeps the soonest.
  // proves: CLAIM(notification-budget)
  group('shared budget on a capped transport', () {
    final svc = NotificationService.instance;
    Future<void> _armOthers({bool water = true}) async {
      await svc.ensureTimezone();
      final at = DateTime(2026, 10, 27, 20);
      if (water) {
        for (var i = 0; i < NotificationService.maxWaterSlots; i++) {
          await svc.scheduleOnce(id: NotificationService.idWaterBase + i, category: NotifCategory.reminders, title: 'w', body: 'w', at: at.add(Duration(minutes: i)));
        }
      }
      for (var i = 0; i < NotificationService.maxMedSlots; i++) {
        await svc.scheduleOnce(id: NotificationService.idMedsBase + i, category: NotifCategory.reminders, title: 'm', body: 'm', at: at.add(Duration(minutes: i)));
      }
      for (final id in [NotificationService.idWindDown, NotificationService.idCheckIn, NotificationService.idAlarmNightCheck]) {
        await svc.scheduleOnce(id: id, category: NotifCategory.reminders, title: 'x', body: 'x', at: at);
      }
    }

    // The plugin checks "in the future" against package:clock.
    Future<void> armOthers({bool water = true}) => withClock(Clock.fixed(morning), () => _armOthers(water: water));
    int others() => pending.keys.where((i) => !NotificationService.isExperimentSlot(i)).length;

    test('combined schedules never exceed the cap and keep every higher class', () async {
      NotificationService.instance.debugPendingCap = NotificationService.pendingCapIos;
      cap = NotificationService.pendingCapIos;
      await armOthers(); // 24 water + 12 meds + 3 singletons = 39
      expect(others(), 39);
      await startAt(morning, weeks: 4);
      // 64 - 39 pending others - 4 singletons not pending (snooze, brief x2, recap) = 21.
      expect(held(), hasLength(21));
      expect(pending.length, lessThanOrEqualTo(64));
      expect(others(), 39, reason: 'no higher-priority reminder was displaced');
      // Nearest first: the 21 soonest assigned days.
      expect(held().first, DateTime(2026, 10, 26, 8));
      expect(held().last.day, 15, reason: '2026-10-26 + 20 days = 2026-11-15');
      // The higher singletons can still arm afterwards: they fit.
      await withClock(Clock.fixed(morning), () async {
        await svc.ensureTimezone();
        for (final id in [NotificationService.idSnoozeBackstop, NotificationService.idMorningBrief, NotificationService.idEveningBrief, NotificationService.idWeeklyRecap]) {
          await svc.scheduleOnce(id: id, category: NotifCategory.reminders, title: 'h', body: 'h', at: DateTime(2026, 10, 27, 21));
        }
      });
      expect(pending.length, 64);
      expect(others(), 43, reason: 'all higher classes pending');
      expect(held(), hasLength(21), reason: 'the OS displaced no experiment slot');
    });

    test('the band grows when others shrink and shrinks when they grow', () async {
      NotificationService.instance.debugPendingCap = NotificationService.pendingCapIos;
      cap = NotificationService.pendingCapIos;
      await armOthers(water: false); // 12 + 3
      await startAt(morning, weeks: 4);
      expect(held(), hasLength(28), reason: '64 - 15 - 4 = 45 >= 28');
      // Water is switched on: the next pass gives slots back, farthest first.
      await withClock(Clock.fixed(morning), () async {
        await svc.ensureTimezone();
        for (var i = 0; i < NotificationService.maxWaterSlots; i++) {
          await svc.scheduleOnce(id: NotificationService.idWaterBase + i, category: NotifCategory.reminders, title: 'w', body: 'w', at: DateTime(2026, 10, 27, 20));
        }
      });
      await refresh(morning);
      expect(held(), hasLength(21));
      expect(held().last.day, 15);
      expect(others(), 39);
    });
  });
}
