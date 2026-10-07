// The "Follow up about my marked moments" setting.
//
//   * A SwitchRow directly under the late-marks row, double-tap tab only.
//   * Present whenever Mark moment is supported; ENABLED only while Mark moment
//     is on (disable-not-hide: see test/settings_disable_not_hide_test.dart).
//   * Persisted in GestureSettings, default off, with the instant it was turned
//     on (only moments marked since then are followed up).

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/device_action.dart';
import 'package:openstrap_edge/gestures/gesture_settings.dart';
import 'package:openstrap_edge/ui2/profile/gestures.dart';
import 'package:openstrap_edge/ui2/profile/profile.dart' show SwitchRow;
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/dart_source_lexical.dart';
import '../../support/settings_sections.dart';

const _title = 'Follow up about my marked moments';
const _replay = 'Also run for taps replayed from history';
const _channel = MethodChannel('openstrap/device_actions');

Finder _row(String title) => find.widgetWithText(SwitchRow, title);

Finder _switchIn(String title) => find.descendant(
    of: _row(title), matching: find.byType(Switch));

Future<void> _pump(
  WidgetTester t, {
  Set<DeviceAction> chosen = const {DeviceAction.markMoment},
  Set<DeviceAction> supported = const {
    DeviceAction.none,
    DeviceAction.markMoment,
    DeviceAction.logWater,
  },
  Set<DeviceAction> replay = const {DeviceAction.markMoment},
  bool followUp = false,
  void Function(bool)? onFollowUp,
}) async {
  t.view.physicalSize = const Size(390 * 3, 2800 * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    home: BandGesturesView(
      chosen: chosen,
      supported: supported,
      replay: replay,
      onToggle: (_, _) {},
      onReplay: (_, _) {},
      followUp: followUp,
      onFollowUp: onFollowUp,
      tapActions: const {3: {DeviceAction.markMoment}},
    ),
  ));
  await t.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the row', () {
    testWidgets('sits directly under the late-marks row', (t) async {
      await _pump(t);
      expect(_row(_replay), findsOneWidget);
      expect(_row(_title), findsOneWidget);
      final replayY = t.getTopLeft(_row(_replay)).dy;
      final followY = t.getTopLeft(_row(_title)).dy;
      expect(followY, greaterThan(replayY));
      // Nothing between the two: the next switch after the replay row is ours.
      final below = [
        for (final e in t.widgetList<SwitchRow>(find.byType(SwitchRow)))
          t.getTopLeft(find.byWidget(e)).dy
      ].where((y) => y > replayY).toList()
        ..sort();
      expect(below.first, followY);
    });

    testWidgets('is present and enabled while Mark moment is on', (t) async {
      final calls = <bool>[];
      await _pump(t, onFollowUp: calls.add);
      expect(isDimmed(t, find.text(_title)), isFalse);
      expect(t.widget<Switch>(_switchIn(_title)).onChanged, isNotNull);
      await t.tap(_switchIn(_title));
      await t.pumpAndSettle();
      expect(calls, [true]);
    });

    testWidgets('Mark moment off: still drawn, dimmed and inert, not hidden',
        (t) async {
      final calls = <bool>[];
      await _pump(t, chosen: const {}, onFollowUp: calls.add);
      expect(_row(_title), findsOneWidget, reason: 'disable, not hide');
      expect(isDimmed(t, find.text(_title)), isTrue);
      expect(t.widget<Switch>(_switchIn(_title)).onChanged, isNull);
      await t.tap(_row(_title), warnIfMissed: false);
      await t.pumpAndSettle();
      expect(calls, isEmpty);
    });

    testWidgets('shows the stored value, off or on', (t) async {
      await _pump(t, followUp: true);
      expect(t.widget<Switch>(_switchIn(_title)).value, isTrue);
      await _pump(t, followUp: false);
      expect(t.widget<Switch>(_switchIn(_title)).value, isFalse);
    });

    testWidgets('a phone that cannot mark moments has no row (platform rule)',
        (t) async {
      await _pump(t,
          chosen: const {},
          supported: const {DeviceAction.none, DeviceAction.logWater},
          replay: const {});
      expect(_row(_title), findsNothing);
    });

    testWidgets('only the double-tap tab has it', (t) async {
      await _pump(t);
      for (final n in [3, 4, 5]) {
        final tab = find.byKey(ValueKey('gestures-tab:$n'));
        if (tab.evaluate().isEmpty) continue;
        await t.ensureVisible(tab);
        await t.tap(tab);
        await t.pumpAndSettle();
        expect(_row(_title), findsNothing, reason: 'tab $n');
      }
    });
  });

  group('wiring', () {
    test('the screen passes the live setting and its setter', () {
      final code = codeOnly(File('lib/ui2/profile/gestures.dart')
          .readAsStringSync());
      expect(code.contains('followUp: g.followUpMoments'), isTrue);
      expect(code.contains('onFollowUp: g.setFollowUpMoments'), isTrue);
    });
  });

  group('GestureSettings persistence', () {
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, null);
    });

    Future<GestureSettings> boot(Map<String, Object> prefs) async {
      SharedPreferences.setMockInitialValues(prefs);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
        if (call.method == 'capabilities') return <String>['torch'];
        return false;
      });
      final s = GestureSettings();
      await s.bootstrap();
      return s;
    }

    test('off by default, with no start', () async {
      final s = await boot({});
      expect(s.followUpMoments, isFalse);
      expect(s.followUpMomentsSince, isNull);
    });

    test('turning it on stamps the given instant and persists both', () async {
      final s = await boot({});
      final at = DateTime(2026, 10, 7, 8, 30, 45);
      await s.setFollowUpMoments(true, now: at);
      expect(s.followUpMoments, isTrue);
      expect(s.followUpMomentsSince, at);

      final again = await boot(
          {for (final k in (await SharedPreferences.getInstance()).getKeys())
            k: (await SharedPreferences.getInstance()).get(k)!});
      expect(again.followUpMoments, isTrue);
      expect(again.followUpMomentsSince, at);
    });

    test('turning it off clears the start; turning it on again restarts it',
        () async {
      final s = await boot({});
      await s.setFollowUpMoments(true, now: DateTime(2026, 10, 1, 9));
      await s.setFollowUpMoments(false);
      expect(s.followUpMoments, isFalse);
      expect(s.followUpMomentsSince, isNull);
      await s.setFollowUpMoments(true, now: DateTime(2026, 10, 5, 9));
      expect(s.followUpMomentsSince, DateTime(2026, 10, 5, 9),
          reason: 'moments marked while it was off are never followed up');
    });

    test('turning on twice keeps the FIRST start (no silent window shift)',
        () async {
      final s = await boot({});
      await s.setFollowUpMoments(true, now: DateTime(2026, 10, 1, 9));
      await s.setFollowUpMoments(true, now: DateTime(2026, 10, 5, 9));
      expect(s.followUpMomentsSince, DateTime(2026, 10, 1, 9));
    });

    test('notifies listeners so the row rebuilds', () async {
      final s = await boot({});
      var n = 0;
      s.addListener(() => n++);
      await s.setFollowUpMoments(true, now: DateTime(2026, 10, 1, 9));
      expect(n, 1);
    });

    test('Mark moment going off does not clear it (the row is only disabled)',
        () async {
      final s = await boot({});
      await s.toggleDoubleTapAction(DeviceAction.markMoment, true);
      await s.setFollowUpMoments(true, now: DateTime(2026, 10, 1, 9));
      await s.toggleDoubleTapAction(DeviceAction.markMoment, false);
      expect(s.followUpMoments, isTrue);
      expect(s.followUpMomentsSince, DateTime(2026, 10, 1, 9));
    });
  });
}
