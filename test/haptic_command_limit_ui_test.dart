// The band command limit's control (rule 6): a developer setting, so it lives
// in Settings > Developer (the group that exists only in developer mode), and
// the Haptics screen's read-out says the limit in force.
//
// New API pinned:
//   MoreSettingsView({int hapticCommandLimit = 30,
//                     ValueChanged<int>? onHapticCommandLimit})
//     In the Developer group (devMode only), a row keyed
//     `developer-haptic-limit` holding a Slider from 10 to 60 whose value is
//     `hapticCommandLimit`, and a text that says the number and the 2 minutes.
//     Moving the slider calls `onHapticCommandLimit` with a whole number from
//     10 to 60 (the screen's owner stores it through Prefs and rebuilds).
//   HapticsSettingsView({int commandLimit = 30}): the Safety read-out is
//     "<left> of <commandLimit> band commands left in the last 2 minutes".

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/haptics/haptic_profile.dart';
import 'package:openstrap_edge/state/locale_controller.dart';
import 'package:openstrap_edge/ui2/profile/haptics_settings.dart';
import 'package:openstrap_edge/ui2/profile/settings.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:provider/provider.dart';

import 'support/haptics_screen_support.dart' show openHapticsTab;
import 'support/settings_sections.dart' show pumpTall, section;

const _row = ValueKey('developer-haptic-limit');

Future<void> _pumpSettings(WidgetTester t, Widget w) async {
  t.view.physicalSize = const Size(1170, 30000);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(ChangeNotifierProvider<LocaleController>.value(
    value: LocaleController.seed(null),
    child: MaterialApp(theme: buildTheme(Brightness.light), home: w),
  ));
  await t.pumpAndSettle();
}

Finder _slider() =>
    find.descendant(of: find.byKey(_row), matching: find.byType(Slider));

void main() {
  group('Settings > Developer', () {
    testWidgets('with developer mode off there is no such row', (t) async {
      await _pumpSettings(t, const MoreSettingsView());
      expect(find.byKey(_row), findsNothing);
    });

    testWidgets('in developer mode the row is in the Developer group',
        (t) async {
      await _pumpSettings(t, const MoreSettingsView(devMode: true));
      expect(find.byKey(_row), findsOneWidget);
      expect(
          find.descendant(of: section('Developer'), matching: find.byKey(_row)),
          findsOneWidget);
    });

    testWidgets('a slider from 10 to 60 at the value given, 30 by default',
        (t) async {
      await _pumpSettings(t, const MoreSettingsView(devMode: true));
      var s = t.widget<Slider>(_slider());
      expect(s.min, 10);
      expect(s.max, 60);
      expect(s.value, 30);
      await _pumpSettings(
          t, const MoreSettingsView(devMode: true, hapticCommandLimit: 45));
      s = t.widget<Slider>(_slider());
      expect(s.value, 45);
    });

    testWidgets('it says the number and what it counts', (t) async {
      await _pumpSettings(
          t, const MoreSettingsView(devMode: true, hapticCommandLimit: 45));
      expect(
          find.descendant(of: find.byKey(_row), matching: find.textContaining('45')),
          findsWidgets);
      expect(
          find.descendant(
              of: find.byKey(_row), matching: find.textContaining('2 minutes')),
          findsWidgets);
    });

    testWidgets('moving it to either end reports 60 and 10, never beyond',
        (t) async {
      final seen = <int>[];
      await _pumpSettings(
          t,
          MoreSettingsView(
              devMode: true,
              hapticCommandLimit: 30,
              onHapticCommandLimit: seen.add));
      await t.drag(_slider(), const Offset(4000, 0));
      await t.pumpAndSettle();
      expect(seen, isNotEmpty);
      expect(seen.last, 60);
      seen.clear();
      await t.drag(_slider(), const Offset(-4000, 0));
      await t.pumpAndSettle();
      expect(seen, isNotEmpty);
      expect(seen.last, 10);
      expect(seen, everyElement(inInclusiveRange(10, 60)));
    });
  });

  group('Settings > Haptics > Band', () {
    Widget hub({required int left, int? limit}) => limit == null
        ? HapticsSettingsView(
            patterns: const [],
            usageOf: (_) => 0,
            profile: HapticDeviceProfile.whoopMg,
            allowLong: false,
            devMode: false,
            commandsLeft: left,
            queued: 0,
            bandConnected: true,
            onPlay: (s) async => true,
            onBuzz: () {},
            onAllowLong: (_) {},
            onAdd: (n, s) {},
            onReplace: (id, s) {},
            onRename: (id, n) {},
            onDelete: (_) {},
            onDeviceLab: () {},
          )
        : HapticsSettingsView(
            patterns: const [],
            usageOf: (_) => 0,
            profile: HapticDeviceProfile.whoopMg,
            allowLong: false,
            devMode: false,
            commandsLeft: left,
            commandLimit: limit,
            queued: 0,
            bandConnected: true,
            onPlay: (s) async => true,
            onBuzz: () {},
            onAllowLong: (_) {},
            onAdd: (n, s) {},
            onReplace: (id, s) {},
            onRename: (id, n) {},
            onDelete: (_) {},
            onDeviceLab: () {},
          );

    testWidgets('the read-out names the limit in force, not a fixed 30',
        (t) async {
      await pumpTall(t, hub(left: 12, limit: 20));
      await openHapticsTab(t, 'band');
      expect(find.text('12 of 20 band commands left in the last 2 minutes'),
          findsOneWidget);
      await pumpTall(t, hub(left: 55, limit: 60));
      await openHapticsTab(t, 'band');
      expect(find.text('55 of 60 band commands left in the last 2 minutes'),
          findsOneWidget);
    });

    testWidgets('without a limit given it still reads "of 30"', (t) async {
      await pumpTall(t, hub(left: 30));
      await openHapticsTab(t, 'band');
      expect(find.text('30 of 30 band commands left in the last 2 minutes'),
          findsOneWidget);
    });
  });
}
