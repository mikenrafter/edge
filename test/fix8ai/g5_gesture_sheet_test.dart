// 8AI G5 (red): the gesture-assignment bottom sheet gets a "View all gestures"
// action that opens the Gestures screen.
//
// The only assignment sheet today is `BandGesturesView._pickActions`: the
// sheet that opens from a tap-count row ("3 taps does", check boxes of the
// offered actions).
//
// ASSUMED API (lib/ui2/profile/gestures.dart):
//   * BandGesturesView takes `VoidCallback? onViewAllGestures` (passed through
//     Function.apply with a plain-view fallback so a missing name fails on the
//     assertion).
//   * The sheet shows a row keyed `gesture-sheet-view-all` with the text "View
//     all gestures", under the action check boxes. Tapping it closes the sheet
//     and then calls `onViewAllGestures` exactly once. The row is shown
//     whether or not the callback is given (without one it only closes the
//     sheet).
//   * The stateful BandGestures route supplies the callback; as the sheet is
//     opened from the Gestures screen itself, the route's job is to leave the
//     sheet on the screen's top (pop to the existing Gestures route when one is
//     already open, else push `BandGestures`), never to stack a second copy:
//     the source guard only checks that the route passes `onViewAllGestures:`.
//
// Failure mode today: the sheet has the check boxes only.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/gesture_settings.dart' show TapCountMethod;
import 'package:openstrap_edge/gestures/device_action.dart';
import 'package:openstrap_edge/ui2/profile/gestures.dart';

import '../phase8/support/dart_source.dart';
import '../phase8/support/sections.dart';

const _supported = {
  DeviceAction.none,
  DeviceAction.markMoment,
  DeviceAction.logWater,
};

Widget _view({VoidCallback? onViewAll, List<String>? toggled}) {
  final named = <Symbol, dynamic>{
    #chosen: <DeviceAction>{},
    #supported: _supported,
    #ecgSupported: true,
    #tapMethod: TapCountMethod.ecg,
    #tapActions: <int, Set<DeviceAction>>{
      3: <DeviceAction>{},
      4: <DeviceAction>{},
      5: <DeviceAction>{},
    },
    #onTapToggle: (int n, DeviceAction a, bool on) async {
      toggled?.add('$n:${a.name}:$on');
    },
    #onViewAllGestures: onViewAll,
  };
  try {
    return Function.apply(BandGesturesView.new, const [], named) as Widget;
  } on NoSuchMethodError {
    named.remove(#onViewAllGestures);
    return Function.apply(BandGesturesView.new, const [], named) as Widget;
  }
}

Future<void> _openSheet(WidgetTester t) async {
  await t.tap(find.text('Double tap + 1 ECG tap'));
  await t.pumpAndSettle();
  expect(find.text('Double tap + 1 ECG tap does'), findsOneWidget, reason: 'the sheet opened');
}

void main() {
  testWidgets('the sheet offers "View all gestures" under the actions',
      (t) async {
    await pumpTall(t, _view(onViewAll: () {}));
    await _openSheet(t);
    final row = find.byKey(const ValueKey('gesture-sheet-view-all'));
    expect(row, findsOneWidget);
    expect(find.descendant(of: row, matching: find.text('View all gestures')),
        findsOneWidget);
    // Under the check boxes, not above them.
    expect(t.getTopLeft(row).dy,
        greaterThan(t.getTopLeft(find.byType(CheckboxListTile).last).dy));
  });

  testWidgets('tapping it closes the sheet and opens the Gestures screen, '
      'once', (t) async {
    var opened = 0;
    await pumpTall(t, _view(onViewAll: () => opened++));
    await _openSheet(t);
    expect(find.byKey(const ValueKey('gesture-sheet-view-all')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('gesture-sheet-view-all')));
    await t.pumpAndSettle();
    expect(opened, 1);
    expect(find.text('Double tap + 1 ECG tap does'), findsNothing, reason: 'the sheet closed');
  });

  testWidgets('it assigns nothing: no action is toggled by the link',
      (t) async {
    final toggled = <String>[];
    await pumpTall(t, _view(onViewAll: () {}, toggled: toggled));
    await _openSheet(t);
    expect(find.byKey(const ValueKey('gesture-sheet-view-all')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('gesture-sheet-view-all')));
    await t.pumpAndSettle();
    expect(toggled, isEmpty);
  });

  testWidgets('the action check boxes still assign, as before (guard)',
      (t) async {
    final toggled = <String>[];
    await pumpTall(t, _view(toggled: toggled));
    await _openSheet(t);
    await t.tap(find.byType(CheckboxListTile).first);
    await t.pumpAndSettle();
    expect(toggled, hasLength(1));
    expect(toggled.single, endsWith(':true'));
  });

  test('the Gestures route supplies the callback', () {
    final src = File('lib/ui2/profile/gestures.dart').readAsStringSync();
    final body = codeOnly(bodyOf(src, 'class BandGestures extends'));
    expect(body, contains('onViewAllGestures:'));
  });
}
