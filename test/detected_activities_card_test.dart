import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/screens/detected_activities.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

Future<void> _pump(WidgetTester t, int count) => t.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: Scaffold(body: DetectedActivitiesCard(pendingCount: count)),
    ));

void main() {
  testWidgets('home shows no detected-activities card when nothing is pending',
      (t) async {
    await _pump(t, 0);
    expect(find.text('Detected activities'), findsNothing);
    expect(find.text('Nothing to review'), findsNothing);
  });

  testWidgets('the card shows when something is pending', (t) async {
    await _pump(t, 3);
    expect(find.text('Detected activities'), findsOneWidget);
  });

  // Home's own read of the count threw: the retry text is there on the very
  // first frame, not after a second read lands the card mid-screen.
  testWidgets('a failed count read with the day shows on the first frame',
      (t) async {
    await t.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: const Scaffold(body: DetectedActivitiesCard(loadFailed: true)),
    ));
    expect(find.text('Could not load activities. Try again.'), findsOneWidget);
  });
}
