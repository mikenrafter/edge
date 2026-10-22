// RULES B.2 on Nerd stats. The generic Series table is built from every stored
// value of the metric; when any of them is an older calculation's, the rows
// that use it are starred and one note says which versions.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import 'support/older_version_fixtures.dart';

// Oldest -> newest: 8, 9, 10, 8, 9 (mean 8.80, latest 9.00).
const _vals = [8.0, 9.0, 10.0, 8.0, 9.0];

Future<void> _show(WidgetTester t, List<int?> older) async {
  t.view.physicalSize = const Size(390 * 3, 2400 * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    home: Scaffold(
        body: Investigate('strain',
            data: InvestigateData(
                day: '2026-10-04',
                days: const ['2026-10-04'],
                series: _vals,
                seriesOlder: older))),
  ));
  await t.pumpAndSettle();
}

void main() {
  testWidgets('an older value inside the window stars the stats it feeds',
      (t) async {
    await _show(t, [null, 104, null, null, null]);
    // Mean, median, SD, min and max use every value; "Latest" uses only the
    // newest, which is current.
    expect(find.text('8.80*'), findsOneWidget, reason: 'mean');
    expect(find.text('9.00*'), findsOneWidget, reason: 'median');
    expect(find.text('10.00*'), findsOneWidget, reason: 'max');
    expect(find.text('8.00*'), findsOneWidget, reason: 'min');
    expect(find.text('9.00'), findsOneWidget, reason: 'latest, current');
    expect(olderNote('stats'), findsOneWidget);
    expect(find.textContaining(kNoteV104), findsOneWidget);
  });

  testWidgets('the newest value being older stars Latest too', (t) async {
    await _show(t, [null, null, null, null, 104]);
    expect(find.text('9.00*'), findsNWidgets(2), reason: 'latest and median');
  });

  testWidgets('no older value: no star, no note', (t) async {
    await _show(t, const []);
    expect(find.textContaining('*'), findsNothing);
    expect(anyOlderMarker(), findsNothing);
  });
}
