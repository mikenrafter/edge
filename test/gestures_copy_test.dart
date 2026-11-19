// Retired ECG controls stay out of gesture settings.
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/device_action.dart';
import 'package:openstrap_edge/ui2/profile/gestures.dart';

import 'support/settings_sections.dart';

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
