// The "Assume I drank water" toggle on the water reminder (RED): the pref, the
// Settings row, the slot hook and the reminder text.
//
//   * Default OFF. It lives with the water reminder in NotificationPrefs
//     (`waterAssumeDrank`) plus the instant it was switched on
//     (`waterAssumeSinceMs`), which is what stops catch-up inventing glasses
//     for hours before the wearer asked for it.
//   * The Settings row is present but dimmed and inert while the water
//     reminder itself is off (disable, never hide).
//   * WaterBuzzer calls `onSlot` at every slot, connected or not: the
//     in-app timer is where a live app logs its glass; the launch catch-up is
//     where a dead app's slots are logged.
//   * The reminder text names the glass in the user's unit through the shared
//     formatter and, with the toggle on, says the glass is assumed.

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/data/water_units.dart';
import 'package:openstrap_edge/notify/notification_center.dart';
import 'package:openstrap_edge/notify/notification_prefs.dart';
import 'package:openstrap_edge/notify/water_buzzer.dart';
import 'package:openstrap_edge/state/units_controller.dart';
import 'package:openstrap_edge/ui2/profile/settings.dart';

import '../support/settings_sections.dart';

void main() {
  group('the pref', () {
    test('defaults OFF with no turn-on time', () {
      const p = NotificationPrefs();
      expect(p.waterAssumeDrank, isFalse);
      expect(p.waterAssumeSinceMs, isNull);
      expect(const NotificationPrefs(waterEnabled: true).waterAssumeDrank,
          isFalse);
    });

    test('copyWith sets it, and unrelated copies keep it', () {
      final on = const NotificationPrefs(waterEnabled: true)
          .copyWith(waterAssumeDrank: true, waterAssumeSinceMs: 1234);
      expect(on.waterAssumeDrank, isTrue);
      expect(on.waterAssumeSinceMs, 1234);
      final later = on.copyWith(waterIntervalMin: 90, quietEnabled: false);
      expect(later.waterAssumeDrank, isTrue);
      expect(later.waterAssumeSinceMs, 1234);
      final off = on.copyWith(waterAssumeDrank: false);
      expect(off.waterAssumeDrank, isFalse);
    });

    test('survives the stored JSON round trip', () {
      final p = const NotificationPrefs(waterEnabled: true).copyWith(
          waterAssumeDrank: true, waterAssumeSinceMs: 1790000000000);
      final back = NotificationPrefs.fromJson(
          Map<String, dynamic>.from(p.toJson()));
      expect(back.waterAssumeDrank, isTrue);
      expect(back.waterAssumeSinceMs, 1790000000000);
    });

    test('a stored blob from before this setting reads as OFF', () {
      final json = Map<String, dynamic>.from(
          const NotificationPrefs(waterEnabled: true).toJson());
      final prefsJson = Map<String, dynamic>.from(json['preferences'] as Map)
        ..remove('waterAssumeDrank')
        ..remove('waterAssumeSinceMs');
      json['preferences'] = prefsJson;
      final back = NotificationPrefs.fromJson(json);
      expect(back.waterAssumeDrank, isFalse);
      expect(back.waterAssumeSinceMs, isNull);
    });

    test('does not change the reminder slots', () {
      const base = NotificationPrefs(waterEnabled: true, quietEnabled: false);
      expect(
          NotificationCenter.waterSlotMinutes(base.copyWith(
              waterAssumeDrank: true, waterAssumeSinceMs: 1)),
          NotificationCenter.waterSlotMinutes(base));
    });
  });

  group('Settings row', () {
    testWidgets('water reminder off: the row is present, dimmed and inert',
        (t) async {
      final changes = <NotificationPrefs>[];
      await pumpTall(
          t,
          NotificationSettingsView(
            prefs: const NotificationPrefs(waterEnabled: false),
            onChanged: (n) async => changes.add(n),
          ));
      final row = find.text('Assume I drank water');
      expect(row, findsOneWidget);
      expect(isDimmed(t, row), isTrue);
      await t.tap(row, warnIfMissed: false);
      expect(changes, isEmpty);
    });

    testWidgets('water reminder on: tapping turns it ON and stamps the time',
        (t) async {
      final changes = <NotificationPrefs>[];
      await pumpTall(
          t,
          NotificationSettingsView(
            prefs: const NotificationPrefs(waterEnabled: true),
            onChanged: (n) async => changes.add(n),
          ));
      expect(isDimmed(t, find.text('Assume I drank water')), isFalse);
      final before = DateTime.now().millisecondsSinceEpoch;
      await t.tap(find.text('Assume I drank water'));
      await t.pump();
      expect(changes, hasLength(1));
      expect(changes.single.waterAssumeDrank, isTrue);
      expect(changes.single.waterAssumeSinceMs, greaterThanOrEqualTo(before));
      expect(changes.single.waterAssumeSinceMs,
          lessThanOrEqualTo(DateTime.now().millisecondsSinceEpoch));
    });

    testWidgets('on: tapping turns it OFF', (t) async {
      final changes = <NotificationPrefs>[];
      await pumpTall(
          t,
          NotificationSettingsView(
            prefs: const NotificationPrefs(waterEnabled: true).copyWith(
                waterAssumeDrank: true, waterAssumeSinceMs: 5),
            onChanged: (n) async => changes.add(n),
          ));
      await t.tap(find.text('Assume I drank water'));
      await t.pump();
      expect(changes.single.waterAssumeDrank, isFalse);
    });

    testWidgets('the row says plainly that nothing is measured', (t) async {
      await pumpTall(
          t,
          const NotificationSettingsView(
              prefs: NotificationPrefs(waterEnabled: true)));
      expect(
          find.textContaining(RegExp('assum', caseSensitive: false)),
          findsWidgets);
    });
  });

  group('reminder text', () {
    const off = NotificationPrefs(waterEnabled: true, quietEnabled: false);
    final on = off.copyWith(waterAssumeDrank: true, waterAssumeSinceMs: 1);

    test('names one glass in metric through the shared formatter', () {
      final b = NotificationCenter.waterReminderBody(off,
          system: UnitSystem.metric);
      expect(b, contains(WaterUnits.format(WaterUnits.stepMl(UnitSystem.metric),
          UnitSystem.metric)));
      expect(b, contains('250 ml'));
      expect(b, contains('log a glass'));
    });

    test('imperial names 8 fl oz, never ml', () {
      final b = NotificationCenter.waterReminderBody(off,
          system: UnitSystem.imperial);
      expect(b, contains('8 fl oz'));
      expect(b.contains('ml'), isFalse);
    });

    test('with the toggle on it says the glass was assumed', () {
      for (final s in UnitSystem.values) {
        final b = NotificationCenter.waterReminderBody(on, system: s);
        expect(b.toLowerCase(), contains('assumed'));
        expect(b, contains(s == UnitSystem.metric ? '250 ml' : '8 fl oz'));
      }
    });

    test('with the toggle off it never claims a glass was counted', () {
      final b = NotificationCenter.waterReminderBody(off,
          system: UnitSystem.metric);
      expect(b.toLowerCase().contains('assumed'), isFalse);
    });

    test('copy rule: a nudge to log, nothing that scores or measures', () {
      for (final p in [off, on]) {
        for (final s in UnitSystem.values) {
          final b =
              NotificationCenter.waterReminderBody(p, system: s).toLowerCase();
          for (final w in ['goal', 'dehydrat', 'score', 'behind', 'enough']) {
            expect(b.contains(w), isFalse, reason: '"$w" in "$b"');
          }
        }
      }
    });
  });

  group('WaterBuzzer.onSlot', () {
    // WaterBuzzer arms a Timer from the REAL clock; fakeAsync only moves the
    // timers, so a slot 30 minutes ahead fires after 30 fake minutes.
    int slotInThirtyMin() {
      final n = DateTime.now();
      return (n.hour * 60 + n.minute + 30) % 1440;
    }

    test('is called at the slot with the slot\'s time, strap NOT connected',
        () {
      fakeAsync((async) {
        final slots = <DateTime>[];
        var buzzed = 0;
        final b = WaterBuzzer(
          buzz: () async => buzzed++,
          isConnected: () => false,
          onSlot: (s) async => slots.add(s),
        );
        final slot = slotInThirtyMin();
        b.configure(enabled: true, slotMinutes: [slot]);
        async.elapse(const Duration(minutes: 31));
        expect(slots, hasLength(1));
        expect(slots.single.hour * 60 + slots.single.minute, slot);
        expect(buzzed, 0, reason: 'no link, no buzz; the glass is still logged');
        b.dispose();
      });
    });

    test('not called while the reminder is off', () {
      fakeAsync((async) {
        var calls = 0;
        final b = WaterBuzzer(
          buzz: () async {},
          isConnected: () => false,
          onSlot: (_) async => calls++,
        );
        b.configure(enabled: false, slotMinutes: [slotInThirtyMin()]);
        async.elapse(const Duration(hours: 2));
        expect(calls, 0);
        b.dispose();
      });
    });

    test('an onSlot that throws does not stop the next slot being armed', () {
      fakeAsync((async) {
        var calls = 0;
        final b = WaterBuzzer(
          buzz: () async {},
          isConnected: () => false,
          onSlot: (_) async {
            calls++;
            throw StateError('db closed');
          },
        );
        b.configure(enabled: true, slotMinutes: [slotInThirtyMin()]);
        async.elapse(const Duration(minutes: 31));
        async.elapse(const Duration(minutes: 31));
        expect(calls, 2);
        b.dispose();
      });
    });
  });
}
