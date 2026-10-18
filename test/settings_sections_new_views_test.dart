// Data and Automation get pure *View widgets (like every other settings
// screen) so they can be pumped headless, and both are split into sections
// that start expanded.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/profile/data.dart';
import 'package:openstrap_edge/ui2/profile/settings.dart';

import 'support/settings_sections.dart';

void main() {
  testWidgets('Data: sections, all expanded', (t) async {
    await pumpTall(t, const DataScreenView());
    await expectAllSectionsExpanded(t, 'Data');
  });

  testWidgets('Automation: sections, all expanded', (t) async {
    await pumpTall(t, const AutomationSettingsView());
    await expectAllSectionsExpanded(t, 'Automation');
  });
}
