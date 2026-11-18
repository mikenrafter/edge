import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:openstrap_edge/notify/alert_policy.dart';
import 'package:openstrap_edge/notify/notification_prefs.dart';
import 'package:openstrap_edge/ui2/profile/settings.dart';
import 'package:openstrap_edge/ui2/profile/profile.dart' show SetRow;
import 'support/settings_sections.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  // WHY / CLAIM(alert-settings-ui): the retired escape hatch is absent and
  // the replacement changes the global route through the settings owner.
  testWidgets('fallback choice replaces override and keeps row height', (tester) async {
    NotificationPrefs? changed;
    await pumpTall(tester, NotificationSettingsView(
      prefs: const NotificationPrefs(), onChanged: (value) async { changed = value; }));
    await openSettingsSection(tester, 'Quiet hours');
    expect(find.text('Health exceptions break through'), findsNothing);
    final label = find.text('If unavailable, send to');
    expect(label, findsOneWidget);
    final row = find.ancestor(of: label, matching: find.byType(SetRow)).first;
    final height = tester.getSize(row).height;
    expect(height, greaterThanOrEqualTo(48));
    await tester.tap(label);
    await tester.pumpAndSettle();
    expect(changed!.fallbackDestination, AlertDestination.band);
    await pumpTall(tester, NotificationSettingsView(prefs: changed!));
    await openSettingsSection(tester, 'Quiet hours');
    expect(tester.getSize(row).height, height);
  });
}
