// RULES B.2 on the Day strain screen: DayStrainData.load must not drop the
// provenance map of getDayStrain, and the screen must show it in both layouts
// (no minute trace, and with a trace in the inline metrics).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/ui2/activity/day_strain.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import 'support/older_version_fixtures.dart';

List<Map<String, dynamic>> _curve() {
  final n = DateTime.now();
  final start = DateTime(n.year, n.month, n.day, 8).millisecondsSinceEpoch ~/ 1000;
  return [
    for (var m = 0; m < 120; m++) {'t': start + m * 60, 'v': 1.0 + m / 30},
  ];
}

Future<void> _show(WidgetTester t, Map<String, dynamic> payload) async {
  t.view.physicalSize = const Size(390 * 3, 2000 * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  final d = await DayStrainData.load(OlderRepo(dayStrain: {'*': payload}));
  await t.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: DayStrainDetail(data: d)));
  await t.pumpAndSettle();
}

void main() {
  testWidgets('no trace, older strain: asterisk, note, spoken', (t) async {
    final h = t.ensureSemantics();
    await _show(t, {
      'strain': 8.4,
      'from_older_version': {'strain': older()},
    });
    expect(find.textContaining('8.4'), findsWidgets);
    expect(olderMark('strain'), findsOneWidget);
    expect(find.text(kNoteV104Reason), findsOneWidget,
        reason: 'the detail screen shows the note without a tap');
    expect(find.bySemanticsLabel(kSpoken), findsWidgets);
    h.dispose();
  });

  testWidgets('with a trace, older strain in the inline metrics', (t) async {
    await _show(t, {
      'strain': 8.4,
      'curve': _curve(),
      'hr': {'max': 150},
      'from_older_version': {'strain': older()},
    });
    expect(find.text('8.4'), findsWidgets);
    expect(olderMark('strain'), findsOneWidget);
    expect(find.text(kNoteV104Reason), findsOneWidget);
  });

  testWidgets('current strain: no marker', (t) async {
    await _show(t, {'strain': 8.4, 'curve': _curve()});
    expect(anyOlderMarker(), findsNothing);
    expect(find.textContaining('older calculation'), findsNothing);
  });

  testWidgets('absent strain: the map cannot invent a value or a marker',
      (t) async {
    await _show(t, {
      'strain': null,
      'note': 'need_input:name=age',
      'from_older_version': {'strain': older()},
    });
    expect(anyOlderMarker(), findsNothing);
    expect(find.textContaining('older calculation'), findsNothing);
  });
}
