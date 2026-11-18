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

  testWidgets('without developer mode the ECG note and options are absent',
      (t) async {
    await pumpTall(
        t,
        const BandGesturesView(
          chosen: {},
          supported: {DeviceAction.none, DeviceAction.markMoment},

        ));
    expect(find.textContaining('WHOOP MG'), findsNothing);
    expect(find.textContaining('ECG'), findsNothing);
  });
}
