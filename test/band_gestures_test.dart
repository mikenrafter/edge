// THE DOUBLE-TAP SCREEN — and the one action that made it worth building.
//
// The whole gesture engine shipped without this screen, so the mapping could
// never leave `none`. Two things it may not get wrong:
//   * it offers ONLY what this phone reported it can do. An action drawn and
//     then silently doing nothing is worse than one never offered;
//   * when native answers with nothing, the phone actions are absent AND the
//     screen says why, rather than leaving a gap to guess at.
//
// Rendered, not read: this project has paid three times for layout faults that
// inspecting a widget tree does not find.
//
// Multi-select, replay-row and 2x-text coverage lives in
// test/gestures/band_gestures_view_test.dart; this file keeps the cases that
// are about the screen's contract with the phone (what it offers, what it says
// when native is silent, 3.1x text) and the water action end to end. Dropped as
// superseded by the 5A rewrite: the "Do nothing" row (the empty set is the off
// state now) and the 2 s debounce case (the dispatcher now claims each
// occurrence by its own identity; covered in gesture_dispatcher_test.dart).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/device_action.dart';
import 'package:openstrap_edge/gestures/gesture_dispatcher.dart';
import 'package:openstrap_edge/gestures/gesture_settings.dart';
import 'package:openstrap_edge/gestures/strap_event.dart';
import 'package:openstrap_edge/ui2/profile/gestures.dart';
import 'package:openstrap_edge/ui2/profile/profile.dart' show SwitchRow;
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What `GestureSettings.bootstrap` builds on a phone whose native side
/// answered: `none`, every in-app action, and the reported native ones.
Set<DeviceAction> _supported(Set<DeviceAction> native) => {
      DeviceAction.none,
      ...DeviceAction.values.where((a) => a.isInApp),
      ...native,
    };

Future<void> _pump(
  WidgetTester t, {
  required Set<DeviceAction> supported,
  Set<DeviceAction> chosen = const {},
  void Function(DeviceAction, bool)? onToggle,
  double scale = 1,
  Brightness brightness = Brightness.light,
}) async {
  t.view.physicalSize = Size(390 * 3, 2400 * 3 * scale);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(scale)),
      child: MaterialApp(
        theme: buildTheme(brightness),
        home: BandGesturesView(
          chosen: chosen,
          supported: supported,
          onToggle: onToggle,
        ),
      ),
    ),
  );
  await t.pumpAndSettle();
}

void main() {
  group('the screen renders', () {
    testWidgets('an iPhone is offered ring and torch, never volume or Tasker',
        (t) async {
      await _pump(t,
          supported:
              _supported({DeviceAction.ringPhone, DeviceAction.torch}));

      expect(layoutFaults, isEmpty);
      expect(find.text('Ring my phone'), findsOneWidget);
      expect(find.text('Flashlight'), findsOneWidget);
      expect(find.text('Log water'), findsOneWidget);
      expect(find.text('Do nothing'), findsNothing);
      // Not offerable on iOS, so not drawn.
      expect(find.text('Volume up'), findsNothing);
      expect(find.text('Broadcast to Tasker'), findsNothing);
      expect(find.text('Play / pause music'), findsNothing);
    });

    testWidgets('an Android phone gets the full native list', (t) async {
      await _pump(t,
          supported: _supported({
            DeviceAction.mediaPlayPause,
            DeviceAction.mediaNext,
            DeviceAction.mediaPrev,
            DeviceAction.volumeUp,
            DeviceAction.volumeDown,
            DeviceAction.ringPhone,
            DeviceAction.torch,
            DeviceAction.broadcastToTasker,
          }));

      expect(layoutFaults, isEmpty);
      for (final label in const [
        'Play / pause music',
        'Volume up',
        'Ring my phone',
        'Broadcast to Tasker',
        'Log water',
      ]) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      // No "why is this missing" note when nothing is missing.
      expect(find.textContaining('could not ask the system'), findsNothing);
    });

    testWidgets('native unreachable: the in-app actions stand, and the '
        'missing ones state their reason', (t) async {
      // capabilities() returned {} — the honest answer is not a bare gap.
      await _pump(t, supported: _supported({}));

      expect(layoutFaults, isEmpty);
      expect(find.text('Ring my phone'), findsNothing);
      expect(find.text('Flashlight'), findsNothing);
      // In-app actions act on our own data, so they are unaffected.
      expect(find.text('Log water'), findsOneWidget);
      expect(find.text('Mark a moment'), findsOneWidget);
      expect(find.textContaining('could not ask the system'), findsOneWidget);
      // Absence explains itself; it is never a bare dash.
      expect(find.text('—'), findsNothing);
    });

    testWidgets('a switch reports the action it is drawn next to', (t) async {
      final calls = <(DeviceAction, bool)>[];
      await _pump(t,
          supported: _supported({DeviceAction.ringPhone}),
          onToggle: (a, v) => calls.add((a, v)));

      Finder sw(String label) => find.descendant(
          of: find.widgetWithText(SwitchRow, label),
          matching: find.byType(Switch));
      await t.tap(sw('Log water'));
      await t.pumpAndSettle();
      await t.tap(sw('Ring my phone'));
      await t.pumpAndSettle();
      expect(calls, [
        (DeviceAction.logWater, true),
        (DeviceAction.ringPhone, true),
      ]);
    });

    testWidgets('nothing overflows at 3.1x, in either theme', (t) async {
      for (final b in Brightness.values) {
        await _pump(t,
            supported: _supported({DeviceAction.ringPhone, DeviceAction.torch}),
            chosen: {DeviceAction.logWater, DeviceAction.markMoment},
            scale: 3.1,
            brightness: b);
        expect(layoutFaults, isEmpty, reason: '$b');
      }
    });
  });

  group('log water dispatches', () {
    // The same tap, as the engine now hands it over: a StrapEvent whose own
    // clock decides whether it is live.
    StrapEvent tap({required Duration late}) {
      final at = DateTime.utc(2026, 3, 14, 12);
      final ts = at.millisecondsSinceEpoch ~/ 1000;
      return StrapEvent(
        eventId: 14,
        tsEpoch: ts,
        receivedAt: at.add(late),
        hex: '',
        deviceId: 'dev-a',
      );
    }

    Future<GestureDispatcher> build(DeviceAction mapped,
        {required void Function() water}) async {
      SharedPreferences.setMockInitialValues({});
      final s = GestureSettings();
      await s.setDoubleTapActions({mapped});
      return GestureDispatcher(
        settings: s,
        onLogWater: (_) async => water(),
        onMarkMoment: (_) async {},
        claim: (_) async => true,
        release: (_) async {},
      );
    }

    test('a live double-tap mapped to water calls the water handler', () async {
      var n = 0;
      final d = await build(DeviceAction.logWater, water: () => n++);
      await d.handle(tap(late: const Duration(seconds: 1)));
      expect(n, 1);
    });

    test('a tap drained from flash is too old to pour a glass', () async {
      var n = 0;
      final d = await build(DeviceAction.logWater, water: () => n++);
      final out = await d.handle(tap(late: const Duration(hours: 1)));
      expect(n, 0);
      expect(out.single.status, GestureStatus.skippedStale);
    });

    test('water is in-app, so it is offerable with no native at all', () {
      expect(DeviceAction.logWater.isInApp, isTrue);
      expect(DeviceAction.logWater.isNative, isFalse);
      // Persisted. Changing it orphans everyone who already picked it.
      expect(DeviceAction.logWater.id, 'log_water');
      expect(DeviceActionX.fromId('log_water'), DeviceAction.logWater);
    });
  });
}

/// Layout faults are reported as caught exceptions, not failed matchers — a
/// negative margin asserting on every build still leaves a findable tree.
List<Object> get layoutFaults {
  final out = <Object>[];
  while (true) {
    final e = TestWidgetsFlutterBinding.instance.takeException();
    if (e == null) break;
    out.add(e as Object);
  }
  return out;
}
