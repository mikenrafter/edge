// 8I note — the Gestures screen states plainly that ECG on double tap needs a
// WHOOP MG, that WHOOP 4.0 has no ECG sensor, and that the 3–5 ECG-touch
// rows (8L) are a draft to try in the Device lab first. Tap 1 is never offered
// or named. (An earlier note said other counts were "not available until
// measured"; that described the dropped IMU tap classifier, not 8L.)
// See test/phase8/CONTRACTS.md §8I and §8L.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/device_action.dart';
import 'package:openstrap_edge/ui2/profile/gestures.dart';

import 'support/settings_sections.dart';

/// The part of band_gestures_view_test.dart's Phase 5B guard that survives
/// 8L: nothing names or offers a single tap.
final _forbidden =
    RegExp(r'one tap|single tap|\b1 tap', caseSensitive: false);

void main() {
  testWidgets('Gestures says what ECG and extended taps need', (t) async {
    await pumpTall(
        t,
        const BandGesturesView(
          chosen: {},
          supported: {DeviceAction.none, DeviceAction.markMoment},
        ));
    expect(find.textContaining('WHOOP MG'), findsWidgets);
    expect(find.textContaining('WHOOP 4.0 has no ECG sensor'), findsWidgets);
    expect(
        find.textContaining(
            RegExp(r'3–5 tap rows are a draft', caseSensitive: false)),
        findsWidgets);
    expect(find.textContaining('not available until'), findsNothing);
    final texts = t
        .widgetList<Text>(find.byType(Text))
        .map((w) => w.data ?? w.textSpan?.toPlainText() ?? '');
    for (final s in texts) {
      expect(_forbidden.hasMatch(s), isFalse, reason: 'text: "$s"');
    }
  });
}
