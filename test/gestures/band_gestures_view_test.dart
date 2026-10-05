// THE DOUBLE-TAP SCREEN, as a multi-select (Phase 5A, steps 3 and 5).
//
// Pure view, headless, no goldens. What it must get right:
//   * actions are switches you can have several of on at once (not a radio);
//   * the empty set IS "off" — there is no "Do nothing" row, and the copy says so;
//   * "Also run for taps replayed from history" sits under Mark moment, is
//     present but disabled (8K) while Mark moment is not selected, and never
//     sits under an action that cannot be replayed safely;
//   * only what this phone can do is offered;
//   * it never names, mentions or offers a one-tap gesture. Two taps is the
//     firmware's double tap; 3–5 taps are the draft ECG-touch counts of 8L
//     (WHOOP MG only, test/phase8/gestures_draft_taps_test.dart), so those
//     words are allowed now; single-tap wording stays banned;
//   * nothing overflows at 2x text.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/device_action.dart';
import 'package:openstrap_edge/ui2/profile/gestures.dart';
import 'package:openstrap_edge/ui2/profile/profile.dart' show SwitchRow;
import 'package:openstrap_edge/ui2/ui2.dart';

const _replayLabel = 'Also run for taps replayed from history';

/// What `GestureSettings.bootstrap` builds on a phone whose native side answered.
Set<DeviceAction> _supported(Set<DeviceAction> native) => {
      DeviceAction.none,
      ...DeviceAction.values.where((a) => a.isInApp),
      ...native,
    };

Future<void> _pump(
  WidgetTester t, {
  required Set<DeviceAction> supported,
  Set<DeviceAction> chosen = const {},
  Set<DeviceAction> replay = const {},
  void Function(DeviceAction, bool)? onToggle,
  void Function(DeviceAction, bool)? onReplay,
  double scale = 1,
  Brightness brightness = Brightness.light,
}) async {
  t.view.physicalSize = Size(390 * 3, 2800 * 3 * scale);
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
          replay: replay,
          onReplay: onReplay,
        ),
      ),
    ),
  );
  await t.pumpAndSettle();
}

Finder _row(String title) => find.widgetWithText(SwitchRow, title);

bool _on(WidgetTester t, String title) =>
    t.widget<Switch>(find.descendant(of: _row(title), matching: find.byType(Switch))).value;

List<Object> _faults() {
  final out = <Object>[];
  while (true) {
    final e = TestWidgetsFlutterBinding.instance.takeException();
    if (e == null) break;
    out.add(e as Object);
  }
  return out;
}

void main() {
  final iphone = _supported({DeviceAction.ringPhone, DeviceAction.torch});

  group('actions are multi-select switches', () {
    testWidgets('every offered action is a switch row; there is no radio and no '
        '"Do nothing" row', (t) async {
      await _pump(t, supported: iphone);
      expect(_faults(), isEmpty);
      for (final label in const [
        'Mark a moment',
        'Start / stop workout',
        'Log water',
        'Ring my phone',
        'Flashlight',
      ]) {
        expect(_row(label), findsOneWidget, reason: label);
      }
      // Five actions plus the replay row, which is always drawn (8K).
      expect(find.byType(SwitchRow), findsNWidgets(6));
      expect(find.byType(Radio<DeviceAction>), findsNothing);
      expect(find.text('Do nothing'), findsNothing);
    });

    testWidgets('several can be on at once; the rest are off', (t) async {
      await _pump(t, supported: iphone, chosen: {
        DeviceAction.logWater,
        DeviceAction.torch,
        DeviceAction.markMoment,
      });
      expect(_on(t, 'Log water'), isTrue);
      expect(_on(t, 'Flashlight'), isTrue);
      expect(_on(t, 'Mark a moment'), isTrue);
      expect(_on(t, 'Ring my phone'), isFalse);
      expect(_on(t, 'Start / stop workout'), isFalse);
    });

    testWidgets('flipping a switch reports (action, new value)', (t) async {
      final calls = <(DeviceAction, bool)>[];
      await _pump(t,
          supported: iphone,
          chosen: {DeviceAction.logWater},
          onToggle: (a, v) => calls.add((a, v)));

      await t.tap(find.descendant(
          of: _row('Ring my phone'), matching: find.byType(Switch)));
      await t.pumpAndSettle();
      await t.tap(find.descendant(
          of: _row('Log water'), matching: find.byType(Switch)));
      await t.pumpAndSettle();
      expect(calls, [(DeviceAction.ringPhone, true), (DeviceAction.logWater, false)]);
    });

    testWidgets('only what this phone can do is offered', (t) async {
      await _pump(t, supported: _supported({}));
      expect(_row('Ring my phone'), findsNothing);
      expect(_row('Flashlight'), findsNothing);
      expect(_row('Volume up'), findsNothing);
      expect(_row('Broadcast to Tasker'), findsNothing);
      expect(_row('Log water'), findsOneWidget);
      // Absence still explains itself.
      expect(find.textContaining('could not ask the system'), findsOneWidget);
    });

    testWidgets('an Android phone gets the full native list as switches',
        (t) async {
      await _pump(
          t,
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
      expect(_faults(), isEmpty);
      // Eleven actions plus the always-drawn replay row.
      expect(find.byType(SwitchRow), findsNWidgets(12));
      expect(find.textContaining('could not ask the system'), findsNothing);
    });

    testWidgets('the empty set is the off state, and the copy says so',
        (t) async {
      await _pump(t, supported: iphone);
      expect(find.textContaining('every action off'), findsOneWidget);
    });

    testWidgets('the old "the app ignores that tap" promise is gone: a tap '
        'stored on the band may now be replayed for Mark moment', (t) async {
      await _pump(t, supported: iphone);
      expect(find.textContaining('The app ignores that tap'), findsNothing);
    });
  });

  group('"Also run for taps replayed from history"', () {
    testWidgets('appears under Mark moment when it is selected', (t) async {
      await _pump(t,
          supported: iphone,
          chosen: {DeviceAction.markMoment},
          replay: {DeviceAction.markMoment});
      expect(find.text(_replayLabel), findsOneWidget);
      expect(_on(t, _replayLabel), isTrue);

      final mark = t.getTopLeft(_row('Mark a moment')).dy;
      final replay = t.getTopLeft(_row(_replayLabel)).dy;
      final next = t.getTopLeft(_row('Start / stop workout')).dy;
      expect(replay, greaterThan(mark));
      expect(replay, lessThan(next), reason: 'directly under Mark moment');
    });

    testWidgets('is off when the replay set does not hold Mark moment',
        (t) async {
      await _pump(t, supported: iphone, chosen: {DeviceAction.markMoment});
      expect(_on(t, _replayLabel), isFalse);
    });

    testWidgets('is present and disabled while Mark moment is not selected',
        (t) async {
      for (final chosen in [
        const <DeviceAction>{},
        {DeviceAction.logWater},
      ]) {
        await _pump(t,
            supported: iphone,
            chosen: chosen,
            replay: {DeviceAction.markMoment});
        expect(find.text(_replayLabel), findsOneWidget);
        final sw = t.widget<Switch>(
            find.descendant(of: _row(_replayLabel), matching: find.byType(Switch)));
        expect(sw.onChanged, isNull, reason: 'a disabled row is inert');
      }
    });

    testWidgets('never sits under an action that cannot be replayed safely',
        (t) async {
      await _pump(t,
          supported: iphone,
          chosen: {
            DeviceAction.logWater,
            DeviceAction.workoutToggle,
            DeviceAction.torch,
            DeviceAction.ringPhone,
          },
          replay: {
            DeviceAction.logWater,
            DeviceAction.workoutToggle,
            DeviceAction.torch,
            DeviceAction.ringPhone,
          });
      // The replay row belongs to Mark moment alone: one per screen, however
      // many other actions are on.
      expect(find.text(_replayLabel), findsOneWidget);
      expect(find.byType(SwitchRow), findsNWidgets(6),
          reason: 'one row per offered action plus the one replay row');
    });

    testWidgets('exactly one replay row even with several actions on',
        (t) async {
      await _pump(t, supported: iphone, chosen: {
        DeviceAction.markMoment,
        DeviceAction.logWater,
        DeviceAction.torch,
      });
      expect(find.text(_replayLabel), findsOneWidget);
      expect(find.byType(SwitchRow), findsNWidgets(6));
    });

    testWidgets('flipping it reports (markMoment, new value)', (t) async {
      final calls = <(DeviceAction, bool)>[];
      await _pump(t,
          supported: iphone,
          chosen: {DeviceAction.markMoment},
          replay: {DeviceAction.markMoment},
          onReplay: (a, v) => calls.add((a, v)));
      await t.tap(find.descendant(
          of: _row(_replayLabel), matching: find.byType(Switch)));
      await t.pumpAndSettle();
      expect(calls, [(DeviceAction.markMoment, false)]);
    });
  });

  group('Phase 5B stays out of this screen', () {
    testWidgets('no text names or offers a one-tap gesture', (t) async {
      await _pump(t,
          supported: _supported({
            DeviceAction.mediaPlayPause,
            DeviceAction.ringPhone,
            DeviceAction.torch,
            DeviceAction.broadcastToTasker,
          }),
          chosen: {DeviceAction.markMoment},
          replay: {DeviceAction.markMoment});
      // 8L adds the draft "3 taps"/"4 taps"/"5 taps" rows (ECG touches on a
      // WHOOP MG), so only one-tap wording is forbidden here.
      final forbidden =
          RegExp(r'one tap|single tap|\b1 tap', caseSensitive: false);
      final texts = t
          .widgetList<Text>(find.byType(Text))
          .map((w) => w.data ?? w.textSpan?.toPlainText() ?? '')
          .toList();
      expect(texts, isNotEmpty);
      for (final s in texts) {
        expect(forbidden.hasMatch(s), isFalse, reason: 'text: "$s"');
      }
    });
  });

  group('layout', () {
    testWidgets('nothing overflows at 2x text, in either theme, with everything '
        'on', (t) async {
      for (final b in Brightness.values) {
        await _pump(
          t,
          supported: _supported({
            DeviceAction.mediaPlayPause,
            DeviceAction.mediaNext,
            DeviceAction.mediaPrev,
            DeviceAction.volumeUp,
            DeviceAction.volumeDown,
            DeviceAction.ringPhone,
            DeviceAction.torch,
            DeviceAction.broadcastToTasker,
          }),
          chosen: DeviceAction.values.where((a) => a != DeviceAction.none).toSet(),
          replay: {DeviceAction.markMoment},
          scale: 2,
          brightness: b,
        );
        expect(_faults(), isEmpty, reason: '$b');
      }
    });

    testWidgets('and at 2x with the "native unreachable" note showing',
        (t) async {
      await _pump(t,
          supported: _supported({}),
          chosen: {DeviceAction.markMoment},
          replay: {DeviceAction.markMoment},
          scale: 2);
      expect(_faults(), isEmpty);
    });
  });
}
