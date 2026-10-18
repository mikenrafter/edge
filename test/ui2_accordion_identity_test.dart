// An accordion's open/closed state belongs to ITS section,
// never to a neighbour, whatever appears or disappears around it.
//
// USER REPORT: "when collapsing or expanding different accordions, sometimes it
// applies to other nearby accordions and not just the one you actually
// selected."
//
// REPRODUCED against today's code. The accordions are unkeyed positional
// children of a ListView, next to conditional siblings (a status card that
// shows only while some permission is missing, a "not connected" card). When
// such a sibling appears or goes, every accordion after it moves one slot,
// Flutter hands each element the State of the one that used to sit in its slot,
// and `_open` (set once, in initState) travels with the State: Health opens
// because Alarms & Wake was open. Nothing re-reads the stored answer, because
// `_restore` runs in initState only.
//
// ASSUMED BEHAVIOUR (no new public symbol is needed; the fix is internal):
//   * a SettingsAccordion that has an `id` keeps its State when its position in
//     the list changes (identity derived from the id: a ValueKey, a keyed
//     subtree, or keys passed by every caller; all three satisfy these tests
//     because they drive the real screens);
//   * `didUpdateWidget` re-restores when the `id` of an existing State changes:
//     the State now belongs to the new id, so it shows the new id's remembered
//     answer, or `initiallyExpanded` when nothing was stored for it, and a
//     late restore for the OLD id never lands on it.
//
// Every test settles the app-prefs queue before it ends (the repository's
// static future chain must not outlive the test).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/device_action.dart';
import 'package:openstrap_edge/settings/settings_repository.dart';
import 'package:openstrap_edge/state/alarm_schedule.dart';
import 'package:openstrap_edge/ui2/profile/alarm.dart';
import 'package:openstrap_edge/ui2/profile/band_notifications.dart';
import 'package:openstrap_edge/ui2/profile/gestures.dart';
import 'package:openstrap_edge/ui2/profile/profile.dart';
import 'package:openstrap_edge/ui2/profile/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/themed_settings_helpers.dart';

final _schedule = fillDefaultAlarmSchedule(const [
  AlarmScheduleEntry(weekday: 0, hour: 7, minute: 0, enabled: true),
]);

/// A screen whose layout has a conditional sibling AHEAD of its accordions,
/// driven by [flag]. `build(flagValue)` is the real pure view.
class _Case {
  const _Case(this.name, this.build, this.toggleId, this.expectIds);
  final String name;
  final Widget Function(bool flag) build;

  /// The accordion the person folds before the sibling appears or goes.
  final String toggleId;

  /// Ids that must all be present, so a vacuous pass is impossible.
  final Set<String> expectIds;
}

final _cases = <_Case>[
  // Permission card first: shown while notifications are off at the system level.
  _Case(
    'Notifications (system permission card)',
    (granted) => NotificationSettingsView(granted: granted),
    'notifications_health',
    {
      'notifications_alarms_wake',
      'notifications_health',
      'notifications_activity',
      'notifications_reminders',
      'notifications_device',
      'notifications_quiet_hours',
    },
  ),
  // The relay's "Android must allow Edge to read notifications" card sits
  // between the Wear accordion and the three channel accordions.
  _Case(
    'App notifications on the band (permission card)',
    (granted) => BandNotificationsView(enabled: true, granted: granted),
    'band_notifications_calls',
    {
      'band_notifications_relay',
      'band_notifications_wear',
      'band_notifications_apps',
      'band_notifications_alarms',
      'band_notifications_calls',
    },
  ),
  // "The band is not connected" card sits ahead of the two Alarm accordions.
  _Case(
    'Alarm (not-connected card)',
    (connected) => AlarmScreenView(connected: connected, schedule: _schedule),
    'alarm_timeline',
    {'alarm_day', 'alarm_timeline'},
  ),
];

Future<void> _pump(WidgetTester t, ValueNotifier<bool> flag, _Case c) async {
  g123View(t, height: 30000);
  await t.pumpWidget(g123App(ValueListenableBuilder<bool>(
    valueListenable: flag,
    builder: (_, v, _) => c.build(v),
  )));
  await g123Settle(t);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('a conditional sibling appearing or going moves no state', () {
    for (final c in _cases) {
      testWidgets('${c.name}: fold one section, flip the sibling both ways; '
          'every section keeps its own answer', (t) async {
        // Start with the sibling PRESENT (flag false: not granted / not
        // connected) and flip it away, then back.
        final flag = ValueNotifier<bool>(false);
        addTearDown(flag.dispose);
        await _pump(t, flag, c);
        expect(openStates(t).keys.toSet(), containsAll(c.expectIds),
            reason: 'the screen shows every section this test names');

        await toggleAccordion(t, c.toggleId);
        final folded = openStates(t);
        expect(folded[c.toggleId], isFalse, reason: 'the fold took');
        expect(folded.entries.where((e) => !e.value).map((e) => e.key),
            [c.toggleId],
            reason: 'folding one section folds only that one');

        flag.value = true; // the sibling goes
        await g123Settle(t);
        expect(openStates(t), folded,
            reason: '${c.name}: the sibling went away and a neighbour took '
                'over the folded section\'s State');

        flag.value = false; // and comes back
        await g123Settle(t);
        expect(openStates(t), folded,
            reason: '${c.name}: the sibling came back and states moved again');
      });

      testWidgets('${c.name}: folding any one section changes only that '
          'section', (t) async {
        final flag = ValueNotifier<bool>(true);
        addTearDown(flag.dispose);
        await _pump(t, flag, c);
        for (final id in c.expectIds) {
          final before = openStates(t);
          await toggleAccordion(t, id);
          final after = openStates(t);
          expect(after[id], isNot(before[id]), reason: '$id flipped');
          expect({...after}..remove(id), {...before}..remove(id),
              reason: 'toggling $id changed another section');
          await toggleAccordion(t, id); // put it back
        }
      });
    }

    testWidgets('a section folded while the card is up, still folded after it '
        'goes AND after a reopen of the screen', (t) async {
      final flag = ValueNotifier<bool>(false);
      addTearDown(flag.dispose);
      final c = _cases.first;
      await _pump(t, flag, c);
      await toggleAccordion(t, 'notifications_health');
      flag.value = true;
      await g123Settle(t);
      expect(openStates(t)['notifications_health'], isFalse,
          reason: 'still folded after the card went');
      await t.pumpWidget(const SizedBox()); // leave
      await g123Settle(t);
      await t.pumpWidget(g123App(c.build(true))); // come back
      await g123Settle(t);
      final s = openStates(t);
      expect(s['notifications_health'], isFalse);
      expect(
          s.entries.where((e) => !e.value).map((e) => e.key), [
        'notifications_health'
      ],
          reason: 'the stored answers map to the right sections after reopen');
    });

    testWidgets('Gestures: the extra-taps choice going and coming back keeps '
        'its own answer', (t) async {
      final flag = ValueNotifier<bool>(true);
      addTearDown(flag.dispose);
      g123View(t, height: 30000);
      await t.pumpWidget(g123App(ValueListenableBuilder<bool>(
        valueListenable: flag,
        builder: (_, extra, _) => BandGesturesView(
          chosen: const {DeviceAction.markMoment},
          supported: const {
            DeviceAction.none,
            DeviceAction.markMoment,
            DeviceAction.torch
          },
          extraTaps: extra,
          devMode: true,
        ),
      )));
      await g123Settle(t);
      expect(openStates(t), {'gestures_extra_taps': true});
      await toggleAccordion(t, 'gestures_extra_taps');
      expect(openStates(t)['gestures_extra_taps'], isFalse);
      flag.value = false; // the only accordion on the screen goes
      await g123Settle(t);
      expect(openStates(t), isEmpty);
      flag.value = true;
      await g123Settle(t);
      expect(openStates(t), {'gestures_extra_taps': false},
          reason: 'still folded: the answer belongs to the section');
    });
  });

  group('didUpdateWidget: a State follows its id', () {
    Future<void> store(String id, bool open) =>
        SettingsRepository.instance.update(
          (d) => d.setBool(accordionPrefKey(id), open),
          sections: const {},
        );

    Widget host(ValueNotifier<String?> id) => g123App(Scaffold(
          body: ValueListenableBuilder<String?>(
            valueListenable: id,
            builder: (_, v, _) =>
                SettingsAccordion('T', id: v, children: const [Text('row')]),
          ),
        ));

    testWidgets('the id changes: the new id\'s stored answer is shown',
        (t) async {
      await t.runAsync(() => store('acc_b', false));
      final id = ValueNotifier<String?>('acc_a');
      addTearDown(id.dispose);
      await t.pumpWidget(host(id));
      await g123Settle(t);
      expect(find.text('row'), findsOneWidget, reason: 'acc_a: nothing stored');

      id.value = 'acc_b';
      await g123Settle(t);
      expect(find.text('row'), findsNothing,
          reason: 'acc_b was stored closed; the State must re-restore for the '
              'new id (today _restore runs in initState only)');
    });

    testWidgets('the id changes to one with nothing stored: back to '
        'initiallyExpanded, not the old id\'s answer', (t) async {
      final id = ValueNotifier<String?>('acc_a');
      addTearDown(id.dispose);
      await t.pumpWidget(host(id));
      await g123Settle(t);
      await t.tap(find.text('T'));
      await g123Settle(t);
      expect(find.text('row'), findsNothing, reason: 'acc_a folded by the user');

      id.value = 'acc_c';
      await g123Settle(t);
      expect(find.text('row'), findsOneWidget,
          reason: 'acc_c never stored an answer: it starts expanded; the '
              'fold belongs to acc_a');
    });

    testWidgets('a restore for the OLD id that lands after the id changed is '
        'dropped', (t) async {
      await t.runAsync(() => store('acc_a', false));
      final id = ValueNotifier<String?>('acc_a');
      addTearDown(id.dispose);
      await t.pumpWidget(host(id));
      id.value = 'acc_b'; // before acc_a's stored answer has been read
      await t.pump();
      await g123Settle(t);
      expect(find.text('row'), findsOneWidget,
          reason: 'acc_a\'s closed answer must not land on acc_b');
    });
  });
}
