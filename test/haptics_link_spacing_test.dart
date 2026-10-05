// The Haptics link rows keep the page's section gap.
//
// USER REPORT (APK f88d230c): "The haptics link buttons are also missing
// requisite top-margin/parent gap". The Gestures screen's `gestures-open-haptics`
// and the Alerts screen's `alerts-open-haptics` are a bare Surface placed
// straight after a SettingsAccordion. The accordion draws its own gap above
// itself (Padding(top: S.x3)), so a sibling that is not an accordion sits flush
// against the card above. (The "View all gestures" row of the tap-count sheet
// had the same fault; the sheet is gone, see g5_gesture_sheet_test.dart.)
//
// ASSUMED: the vertical gap between the link's card and the card above it is at
// least S.x3, the gap SettingsAccordion keeps above itself. On Gestures the
// card above the link is the tab's switch card.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/gesture_settings.dart' show TapCountMethod;
import 'package:openstrap_edge/gestures/device_action.dart';
import 'package:openstrap_edge/ui2/profile/gestures.dart';
import 'package:openstrap_edge/ui2/profile/profile.dart' show SettingsAccordion;
import 'package:openstrap_edge/ui2/profile/settings.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import 'support/settings_sections.dart';

const _supported = {
  DeviceAction.none,
  DeviceAction.markMoment,
  DeviceAction.logWater,
};

/// The card the link row lives in.
Rect _cardOf(WidgetTester t, Finder row) => t.getRect(find
    .ancestor(of: row, matching: find.byType(Surface))
    .first);

/// The gap from the lowest accordion that ends above [link] to [link].
double _gapAboveAccordion(WidgetTester t, Rect link) {
  var best = -1e9;
  for (final e in find.byType(SettingsAccordion).evaluate()) {
    final r = t.getRect(find.byElementPredicate((x) => identical(x, e)));
    if (r.bottom <= link.top + 0.5 && r.bottom > best) best = r.bottom;
  }
  expect(best, greaterThan(-1e9), reason: 'an accordion sits above the link');
  return link.top - best;
}

/// The gap from the card holding [above] to [link].
double _gapBelow(WidgetTester t, Finder above, Rect link) =>
    link.top - t.getRect(find.ancestor(of: above, matching: find.byType(Surface)).first).bottom;

void main() {
  for (final extra in [false, true]) {
    testWidgets('Gestures${extra ? ' with the tap tabs' : ''}: the Haptics '
        'link has a gap above it', (t) async {
      await pumpTall(
          t,
          BandGesturesView(
              chosen: const {},
              supported: _supported,
              ecgSupported: true,
              tapMethod: TapCountMethod.ecg,
              extraTaps: extra));
      final row = find.byKey(const ValueKey('gestures-open-haptics'));
      expect(row, findsOneWidget);
      expect(_gapBelow(t, find.text('Log water'), _cardOf(t, row)),
          greaterThanOrEqualTo(S.x3));
    });
  }

  testWidgets('Alerts: the Haptics link has a gap above it', (t) async {
    await pumpTall(t, const NotificationSettingsView());
    final row = find.byKey(const ValueKey('alerts-open-haptics'));
    expect(row, findsOneWidget);
    expect(_gapAboveAccordion(t, _cardOf(t, row)), greaterThanOrEqualTo(S.x3));
  });
}
