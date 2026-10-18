// In developer mode the Gestures screen states plainly that ECG on double tap
// needs a WHOOP MG, that WHOOP 4.0 has no ECG sensor, and where to try it (the
// Device lab). Nothing is called a draft. Without developer mode the ECG note
// is not on the screen at all. Tap 1 is never offered or named.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/device_action.dart';
import 'package:openstrap_edge/ui2/profile/gestures.dart';

import 'support/settings_sections.dart';

/// The part of band_gestures_view_test.dart's single-tap guard that still
/// applies: nothing names or offers a single tap.
final _forbidden =
    RegExp(r'one tap|single tap|\b1 tap', caseSensitive: false);

void main() {
  testWidgets('Gestures says what ECG and extended taps need', (t) async {
    await pumpTall(
        t,
        const BandGesturesView(
          chosen: {},
          supported: {DeviceAction.none, DeviceAction.markMoment},
          devMode: true,
        ));
    expect(find.textContaining('WHOOP MG'), findsWidgets);
    expect(find.textContaining('WHOOP 4.0 has no ECG sensor'), findsWidgets);
    expect(find.textContaining(RegExp('draft', caseSensitive: false)),
        findsNothing);
    expect(find.textContaining('not available until'), findsNothing);
    final texts = t
        .widgetList<Text>(find.byType(Text))
        .map((w) => w.data ?? w.textSpan?.toPlainText() ?? '');
    for (final s in texts) {
      expect(_forbidden.hasMatch(s), isFalse, reason: 'text: "$s"');
    }
  });

  testWidgets('without developer mode the ECG note and options are absent',
      (t) async {
    await pumpTall(
        t,
        const BandGesturesView(
          chosen: {},
          supported: {DeviceAction.none, DeviceAction.markMoment},
          ecgSupported: true,
        ));
    expect(find.textContaining('WHOOP MG'), findsNothing);
    expect(find.textContaining('ECG'), findsNothing);
  });
}
