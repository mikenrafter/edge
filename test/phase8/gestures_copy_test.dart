// 8I note — the Gestures screen states plainly that ECG on double tap needs a
// WHOOP MG, that WHOOP 4.0 has no ECG sensor, and that other tap counts are
// not available until measured (5B). Tap 1 is never offered or named; the
// draft 3–5 ECG-touch rows (8L) are the only other counts on the screen.
// See test/phase8/CONTRACTS.md §8I and §8L.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/device_action.dart';
import 'package:openstrap_edge/ui2/profile/gestures.dart';

import 'support/sections.dart';

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
            RegExp(r'tap counts.*not available', caseSensitive: false)),
        findsWidgets);
    final texts = t
        .widgetList<Text>(find.byType(Text))
        .map((w) => w.data ?? w.textSpan?.toPlainText() ?? '');
    for (final s in texts) {
      expect(_forbidden.hasMatch(s), isFalse, reason: 'text: "$s"');
    }
  });
}
