// Loaded-content tests explicitly open secondary sections. Production starts
// them closed so optional reads cannot move the page below them.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/profile/profile.dart';
Future<void> openSleepDisclosures(WidgetTester t) async {
  for (final id in const ['sleep_night', 'sleep_stages', 'sleep_versus',
    'sleep_unusual', 'sleep_overnight', 'sleep_tonight']) {
    final card = find.byWidgetPredicate((w) => w is SettingsAccordion && w.id == id);
    if (card.evaluate().isEmpty) continue;
    if (find.descendant(of: card, matching: find.byType(Divider)).evaluate().isNotEmpty) continue;
    final title = t.widget<SettingsAccordion>(card).title;
    final header = find.descendant(of: card, matching: find.text(title)).first;
    await t.ensureVisible(header);
    await t.tap(header);
    await t.pump();
  }
}
