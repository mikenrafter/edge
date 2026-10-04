// 8AI G4: the Alerts screen's Buzz pattern row names the pattern ("Three
// pulses", "Your: Morning nudge"); it never says how many buzzes. A row whose
// pattern the screen cannot name says "Custom".

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/notify/alert_rule.dart';
import 'package:openstrap_edge/notify/notification_prefs.dart';
import 'package:openstrap_edge/ui2/profile/settings.dart';

import '../phase8/support/sections.dart';

NotificationPrefs _bandOn(String id) {
  const prefs = NotificationPrefs();
  return prefs.withAlertRule({
    ...prefs.alertRule(id).toJson(),
    'enabled': true,
    'destinations': AlertRule.band,
  });
}

void main() {
  testWidgets('the row shows the name the screen was given', (t) async {
    await pumpTall(
      t,
      NotificationSettingsView(
        prefs: _bandOn('water'),
        patternNameFor: (id) => id == 'water' ? 'Your: Morning nudge' : 'Three pulses',
      ),
    );
    final water = find.byKey(const ValueKey('buzz-pattern:water'));
    expect(find.descendant(of: water, matching: find.text('Your: Morning nudge')),
        findsOneWidget);
    final health = find.byKey(const ValueKey('buzz-pattern:health'));
    expect(find.descendant(of: health, matching: find.text('Three pulses')),
        findsOneWidget);
    expect(find.textContaining(RegExp(r'\d+ buzz')), findsNothing);
  });

  testWidgets('without a name the row says Custom, never a count', (t) async {
    await pumpTall(t, NotificationSettingsView(prefs: _bandOn('water')));
    final water = find.byKey(const ValueKey('buzz-pattern:water'));
    expect(find.descendant(of: water, matching: find.text('Custom')),
        findsOneWidget);
    expect(find.textContaining(RegExp(r'\d+ buzz')), findsNothing);
  });
}
