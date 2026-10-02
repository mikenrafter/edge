// The view-model the UI phase binds to: getters, validated setters, the
// upgrade explanation, and the exact timeline. No widgets, no DB.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/state/alarm_schedule.dart';
import 'package:openstrap_edge/wake/wake_controller.dart';
import 'package:openstrap_edge/wake/wake_orchestrator.dart';
import 'package:openstrap_edge/wake/wake_settings.dart';

class _Host {
  _Host({this.upgrade = WakeUpgradeState.none, List<AlarmScheduleEntry>? seed})
      : schedule = fillDefaultAlarmSchedule(seed ?? const []);
  List<AlarmScheduleEntry> schedule;
  WakeUpgradeState upgrade;
  final saved = <AlarmScheduleEntry>[];
  final acks = <bool>[];

  WakeController build() => WakeController(
        schedule: () => schedule,
        saveEntry: (e) async {
          saved.add(e);
          schedule = [for (final x in schedule) x.weekday == e.weekday ? e : x];
        },
        loadUpgradeState: () async => upgrade,
        saveUpgradeState: (s) async => upgrade = s,
        acknowledgeWake: (cancelNative) async {
          acks.add(cancelNative);
          return WakeAckOutcome(
              nativeCancelRequested: cancelNative,
              nativeCancelled: false,
              fallbackArmed: true);
        },
        traceFor: (_) async => const [],
      );
}

void main() {
  test('defaults: nothing enabled, no explanation due', () async {
    final h = _Host();
    final c = h.build();
    await c.reload();
    for (var d = 0; d < 7; d++) {
      expect(c.naturalWindowMinutes(d), 0);
      expect(c.gradualWindowMinutes(d), 0);
      expect(c.configurationFor(d), WakeConfiguration.neither);
    }
    expect(c.upgradeExplanationPending, isFalse);
  });

  test('setters validate and persist exactly one entry', () async {
    final h = _Host();
    final c = h.build();
    await c.reload();
    var notified = 0;
    c.addListener(() => notified++);
    await c.setNaturalWindow(1, 45);
    await c.setGradualWindow(1, 30);
    await c.setGradualPattern(1, GradualPattern.steady);
    await c.setGradualCadenceSeconds(1, 120);
    expect(c.naturalWindowMinutes(1), 45);
    expect(c.gradualWindowMinutes(1), 30);
    expect(c.gradualPattern(1), GradualPattern.steady);
    expect(c.gradualCadenceSeconds(1), 120);
    expect(c.configurationFor(1), WakeConfiguration.both);
    expect(c.configurationFor(0), WakeConfiguration.neither);
    expect(notified, 4);
    // Hour/minute/enabled of the fixed alarm are never touched by these.
    final last = h.saved.last;
    expect([last.hour, last.minute, last.enabled],
        [defaultAlarmHour, defaultAlarmMinute, false]);

    for (final bad in [-15, 7, 135, 200]) {
      expect(() => c.setNaturalWindow(1, bad), throwsArgumentError);
      expect(() => c.setGradualWindow(1, bad), throwsArgumentError);
    }
    expect(() => c.setGradualCadenceSeconds(1, 30), throwsArgumentError);
    expect(() => c.setNaturalWindow(9, 15), throwsArgumentError);
  });

  test('every valid window is accepted', () async {
    final c = _Host().build();
    await c.reload();
    for (var m = 0; m <= 120; m += 15) {
      await c.setNaturalWindow(3, m);
      expect(c.naturalWindowMinutes(3), m);
    }
  });

  group('upgrade explanation', () {
    final smartUser = [
      AlarmScheduleEntry(
          weekday: 0,
          hour: 7,
          minute: 0,
          smartWindowMinutes: 30,
          naturalWindowMinutes: 30),
    ];

    test('is pending until acknowledged, and Natural is not active meanwhile',
        () async {
      final h = _Host(upgrade: WakeUpgradeState.pending, seed: smartUser);
      final c = h.build();
      await c.reload();
      expect(c.upgradeExplanationPending, isTrue);
      expect(c.naturalWindowMinutes(0), 30,
          reason: 'the migrated value is shown');
      expect(c.naturalActive(0), isFalse, reason: 'but it is not running yet');
    });

    test('acknowledging with Natural on activates it and never touches Gradual',
        () async {
      final h = _Host(upgrade: WakeUpgradeState.pending, seed: smartUser);
      final c = h.build();
      await c.reload();
      await c.acknowledgeUpgrade();
      expect(c.upgradeExplanationPending, isFalse);
      expect(c.naturalActive(0), isTrue);
      expect(c.gradualWindowMinutes(0), 0);
      expect(h.upgrade, WakeUpgradeState.acknowledged);
    });

    test('declining switches the migrated Natural windows off', () async {
      final h = _Host(upgrade: WakeUpgradeState.pending, seed: smartUser);
      final c = h.build();
      await c.reload();
      await c.acknowledgeUpgrade(enableNatural: false);
      expect(c.naturalWindowMinutes(0), 0);
      expect(c.upgradeExplanationPending, isFalse);
      expect(h.upgrade, WakeUpgradeState.acknowledged);
      expect(h.saved.single.smartWindowMinutes, 30,
          reason: 'the legacy column is kept for rollback');
    });
  });

  test('timeline for an armed occurrence names band-native and phone parts',
      () async {
    final h = _Host(seed: [
      AlarmScheduleEntry(
          weekday: 0,
          hour: 7,
          minute: 0,
          naturalWindowMinutes: 60,
          gradualWindowMinutes: 15),
    ]);
    final c = h.build();
    await c.reload();
    final t = DateTime(2026, 10, 5, 7, 0); // a Monday
    final tl = c.timelineAt(t);
    expect(tl.configuration, WakeConfiguration.both);
    expect(tl.parts.where((p) => p.bandNative).map((p) => p.id), ['fallback']);
    expect(tl.parts.where((p) => p.requiresPhone), isNotEmpty);
    expect(c.timelineAt(DateTime(2026, 10, 6, 7, 0)).configuration,
        WakeConfiguration.neither);
  });

  test('acknowledging a wake delegates, defaulting to keeping the native alarm',
      () async {
    final h = _Host();
    final c = h.build();
    await c.reload();
    await c.acknowledgeWake();
    await c.acknowledgeWake(cancelNative: true);
    expect(h.acks, [false, true]);
  });
}
