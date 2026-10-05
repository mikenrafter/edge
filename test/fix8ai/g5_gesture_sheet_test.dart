// 8AI G5 (retired Oct 4): the gesture-assignment bottom sheet and its "View all
// gestures" row are gone.
//
// The only assignment sheet was `BandGesturesView._pickActions`, opened from a
// tap-count row. The Gestures screen is sub-tabs now: every count has its own
// tab with the actions as inline switches, so there is no sheet and nothing to
// link back from it (the full layout is pinned by
// test/gestures/gestures_tabs_test.dart). This file keeps the guard that none
// of it comes back.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/gesture_settings.dart' show TapCountMethod;
import 'package:openstrap_edge/gestures/device_action.dart';
import 'package:openstrap_edge/ui2/profile/gestures.dart';

import '../phase8/support/sections.dart';

const _supported = {
  DeviceAction.none,
  DeviceAction.markMoment,
  DeviceAction.logWater,
};

void main() {
  testWidgets('opening a count tab and flipping its switch shows no sheet and '
      'no "View all gestures"', (t) async {
    final toggled = <String>[];
    await pumpTall(
        t,
        BandGesturesView(
          chosen: const {},
          supported: _supported,
          ecgSupported: true,
          tapMethod: TapCountMethod.ecg,
          tapActions: const {3: {}, 4: {}, 5: {}},
          onTapToggle: (n, a, on) async => toggled.add('$n:${a.name}:$on'),
        ));
    await openGesturesTab(t, 3);
    expect(gesturesTabName(t), 'Double tap + 1 ECG tap');
    await t.tap(find.byType(Switch).first);
    await t.pumpAndSettle();
    expect(toggled, hasLength(1));
    expect(toggled.single, endsWith(':true'));
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.byType(CheckboxListTile), findsNothing);
    expect(find.text('View all gestures'), findsNothing);
    expect(find.byKey(const ValueKey('gesture-sheet-view-all')), findsNothing);
  });
}
