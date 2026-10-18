// Layout shift budget on a settings page: expanding an accordion section.
// The tap on the header is the Interaction. Measurement test.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/profile/profile.dart';

import '../../support/settings_sections.dart';
import '../../support/shift_run.dart';

void main() {
  testWidgets('expanding a collapsed accordion header', (t) async {
    phoneSurface(t);
    await pumpTall(
        t,
        Scaffold(
          body: ListView(padding: const EdgeInsets.all(16), children: const [
            SettingsAccordion('Band', summary: 'Connected', children: [
              Text('Battery'),
              Text('Firmware'),
            ]),
            SettingsAccordion('Alarm',
                summary: 'Weekdays at 07:00',
                initiallyExpanded: false,
                children: [Text('Wake time'), Text('Smart window')]),
            SettingsAccordion('Haptics',
                summary: 'On', children: [Text('Strength'), Text('Pattern')]),
            SettingsAccordion('Notifications',
                summary: 'On', children: [Text('Sync'), Text('Low battery')]),
          ]),
        ));
    phoneSurface(t);
    final run = ShiftRun(t);
    await t.pump(const Duration(milliseconds: 16));
    await run.tap(find.text('Alarm'));
    await t.pump(const Duration(seconds: 2));
    run.expectNoErrors('settings accordion expand');
  });
}
