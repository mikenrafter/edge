// Pins Denver inside the test process; TZDIR must supply the zone database.
// WHY: a calendar day can end after 23 or 25 elapsed hours. A fixed 24-hour
// timer leaves today's action stale across DST. CLAIM(day-navigation-immediate).
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/ui2/day_navigation.dart';
import 'package:openstrap_edge/ui2/theme.dart';
import '../support/pin_tz.dart';

void main() {
  pinProcessTimeZone('America/Denver');
  for (final fixture in [
    (label: '2026-03-08', next: DateTime(2026, 3, 9), hours: 23),
    (label: '2026-11-01', next: DateTime(2026, 11, 2), hours: 25),
  ]) {
    testWidgets('today changes after ${fixture.hours} hours on ${fixture.label}', (t) async {
      expect(localDayLengthSec(fixture.label), fixture.hours * 3600,
        reason: 'This suite requires TZ=America/Denver and a valid TZDIR');
      var now = DateTime.parse(fixture.label);
      await withClock(Clock(() => now), () async {
        await t.pumpWidget(MaterialApp(theme: buildTheme(Brightness.light),
          home: Scaffold(body: backToTodayControl(
            selectedDay: fixture.label, onSelect: (_) {}))));
        expect(find.text('Back to today'), findsNothing);
        now = fixture.next.subtract(const Duration(seconds: 1));
        await t.pump(Duration(seconds: fixture.hours * 3600 - 1));
        expect(find.text('Back to today'), findsNothing);
        now = fixture.next;
        await t.pump(const Duration(seconds: 1));
        expect(find.text('Back to today'), findsOneWidget);
        await t.pumpWidget(const SizedBox());
      });
    });
  }
}
