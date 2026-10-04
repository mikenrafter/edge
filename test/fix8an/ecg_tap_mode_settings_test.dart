// The ECG tap mode setting (8AN B): Accurate (reads the signal, waits for it to
// settle) or Fast (the band's own contact flag vetoes noise; no settle wait).
// Default accurate until the user confirms Fast after the A/B; persisted like
// the other gesture settings; a two-option selector on the Gestures screen that
// holds at 360 pt.
//
// ASSUMED API (new):
//  * lib/gestures/ecg_tap_mode.dart:
//      enum EcgTapMode { accurate('accurate'), fast('fast');
//        final String id; static EcgTapMode? fromId(String? id); }
//  * GestureSettings: `EcgTapMode get ecgTapMode` (default accurate),
//    `Future<void> setEcgTapMode(EcgTapMode m)` (notifies; persists the id
//    under 'gesture_ecg_tap_mode'; an unknown stored value follows the
//    default).
//  * BandGesturesView (lib/ui2/profile/gestures.dart): `EcgTapMode? ecgTapMode`
//    (null = accurate) and `ValueChanged<EcgTapMode>? onEcgTapMode`; with an
//    ECG band and extra taps on, a selector inside the 'Count extra taps with'
//    section whose options are keyed ValueKey('ecg-tap-mode:accurate') and
//    ValueKey('ecg-tap-mode:fast'), the chosen one with a LucideIcons.check.
//    Option copy (also in lib/l10n/app_en.arb), a title and one plain line each:
//    "Accurate: reads the signal, waits for it to settle" and "Fast: uses the
//    band's own contact flag to ignore noise, starts counting at once". Only the
//    phrases 'waits for it to settle' and 'own contact flag' are pinned.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:openstrap_edge/gestures/device_action.dart';
import 'package:openstrap_edge/gestures/ecg_tap_mode.dart';
import 'package:openstrap_edge/gestures/gesture_settings.dart';
import 'package:openstrap_edge/ui2/profile/gestures.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _channel = MethodChannel('openstrap/device_actions');

Future<GestureSettings> _boot(Map<String, Object> prefs) async {
  SharedPreferences.setMockInitialValues(prefs);
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, (call) async {
    if (call.method == 'capabilities') return <String>[];
    return false;
  });
  final s = GestureSettings();
  await s.bootstrap();
  return s;
}

Finder _option(String id) => find.byKey(ValueKey('ecg-tap-mode:$id'));

/// 360 logical points wide, tall enough that the list builds every row.
Future<void> _pump360(WidgetTester t, Widget w) async {
  t.view.physicalSize = const Size(1080, 24000);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(theme: buildTheme(Brightness.light), home: w));
  await t.pumpAndSettle();
}

const _supported = {
  DeviceAction.none,
  DeviceAction.markMoment,
  DeviceAction.logWater,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, null));

  group('the setting', () {
    test('the ids are stable and unknown ids are null', () {
      expect(EcgTapMode.values.map((m) => m.id), ['accurate', 'fast']);
      expect(EcgTapMode.fromId('fast'), EcgTapMode.fast);
      expect(EcgTapMode.fromId('accurate'), EcgTapMode.accurate);
      expect(EcgTapMode.fromId('telepathy'), isNull);
      expect(EcgTapMode.fromId(null), isNull);
    });

    test('default: accurate', () async {
      final s = await _boot({});
      expect(s.ecgTapMode, EcgTapMode.accurate);
    });

    test('a choice notifies, persists and is restored', () async {
      final s = await _boot({});
      var notified = 0;
      s.addListener(() => notified++);
      await s.setEcgTapMode(EcgTapMode.fast);
      expect(notified, 1);
      expect(s.ecgTapMode, EcgTapMode.fast);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('gesture_ecg_tap_mode'), 'fast');
      final again = GestureSettings();
      await again.bootstrap();
      expect(again.ecgTapMode, EcgTapMode.fast);
      await s.setEcgTapMode(EcgTapMode.accurate);
      expect(notified, 2);
      final back = GestureSettings();
      await back.bootstrap();
      expect(back.ecgTapMode, EcgTapMode.accurate);
    });

    test('choosing the mode already in force does not notify', () async {
      final s = await _boot({});
      var notified = 0;
      s.addListener(() => notified++);
      await s.setEcgTapMode(EcgTapMode.accurate);
      expect(notified, 0);
    });

    test('an unknown stored value follows the default', () async {
      final s = await _boot({'gesture_ecg_tap_mode': 'telepathy'});
      expect(s.ecgTapMode, EcgTapMode.accurate);
    });

    test('the mode is independent of the touch-window thresholds', () async {
      final s = await _boot({'gesture_ecg_start_ms': 500});
      await s.setEcgTapMode(EcgTapMode.fast);
      expect(s.ecgTapThresholds.startMs, 500);
    });
  });

  group('the selector', () {
    testWidgets('two options, accurate chosen by default, at 360 pt',
        (t) async {
      await _pump360(
        t,
        const BandGesturesView(
          chosen: {},
          supported: _supported,
          ecgSupported: true,
        ),
      );
      expect(t.takeException(), isNull, reason: 'no overflow at 360 pt');
      expect(_option('accurate'), findsOneWidget);
      expect(_option('fast'), findsOneWidget);
      expect(
        find.descendant(
            of: _option('accurate'), matching: find.byIcon(LucideIcons.check)),
        findsOneWidget,
      );
      expect(
        find.descendant(
            of: _option('fast'), matching: find.byIcon(LucideIcons.check)),
        findsNothing,
      );
    });

    testWidgets('each option has one plain line', (t) async {
      await _pump360(
        t,
        const BandGesturesView(
          chosen: {},
          supported: _supported,
          ecgSupported: true,
        ),
      );
      expect(find.textContaining('waits for it to settle'), findsOneWidget);
      expect(find.textContaining('own contact flag'), findsOneWidget);
    });

    testWidgets('fast chosen: the check follows', (t) async {
      await _pump360(
        t,
        const BandGesturesView(
          chosen: {},
          supported: _supported,
          ecgSupported: true,
          ecgTapMode: EcgTapMode.fast,
        ),
      );
      expect(
        find.descendant(
            of: _option('fast'), matching: find.byIcon(LucideIcons.check)),
        findsOneWidget,
      );
      expect(
        find.descendant(
            of: _option('accurate'), matching: find.byIcon(LucideIcons.check)),
        findsNothing,
      );
    });

    testWidgets('tapping an option reports it', (t) async {
      final picked = <EcgTapMode>[];
      await _pump360(
        t,
        BandGesturesView(
          chosen: const {},
          supported: _supported,
          ecgSupported: true,
          onEcgTapMode: picked.add,
        ),
      );
      await t.tap(_option('fast'));
      await t.tap(_option('accurate'));
      expect(picked, [EcgTapMode.fast, EcgTapMode.accurate]);
    });
  });

  test('the copy is in the English strings (l10n via app_en.arb)', () {
    final arb = jsonDecode(File('lib/l10n/app_en.arb').readAsStringSync())
        as Map<String, dynamic>;
    final values = [
      for (final e in arb.entries)
        if (!e.key.startsWith('@') && e.value is String) e.value as String,
    ];
    bool has(String s) => values.any((v) => v.toLowerCase().contains(s));
    expect(has('reads the signal'), isTrue);
    expect(has('waits for it to settle'), isTrue);
    expect(has('own contact flag'), isTrue);
  });
}
