// RULES B.2 on Nutrition: BURNED is total calories. When it is an older
// calculation's value it is marked, and so is the BALANCE derived from it.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/data/nutrition_store.dart';
import 'package:openstrap_edge/models/metric.dart';
import 'package:openstrap_edge/ui2/screens/nutrition_screen.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import 'support/older_version_fixtures.dart';

const _zero = NutrientTotal(null, 0, 0);
const _day = NutritionDay(
    date: '2026-10-04',
    entries: [],
    state: DayLogState.complete,
    kcal: NutrientTotal(2000, 1, 0),
    protein: _zero,
    carbs: _zero,
    fat: _zero,
    fibre: _zero);

Future<void> _card(WidgetTester t, Metric? burned) async {
  await t.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: Scaffold(
          body: SingleChildScrollView(
              child: DayEnergyCard(day: _day, burned: burned)))));
  await t.pump();
}

void main() {
  testWidgets('older burned: asterisk on burned and on the balance it drives',
      (t) async {
    final h = t.ensureSemantics();
    await _card(
        t,
        const Metric(
            value: 2300,
            confidence: .8,
            fromOlderVersion: 104,
            olderVersionReason: kReasonRaw));
    expect(find.textContaining('2300'), findsWidgets);
    expect(olderMark('calories_total'), findsOneWidget);
    expect(olderMark('balance'), findsOneWidget);
    expect(find.bySemanticsLabel(kSpoken), findsWidgets);
    await t.tap(olderMark('calories_total'));
    await t.pumpAndSettle();
    expect(find.text(kNoteV104Reason), findsOneWidget);
    h.dispose();
  });

  testWidgets('current burned: no marker', (t) async {
    await _card(t, const Metric(value: 2300, confidence: .8));
    expect(anyOlderMarker(), findsNothing);
  });

  testWidgets('absent burned: no burned row and no marker', (t) async {
    await _card(t, const Metric(fromOlderVersion: 104));
    expect(find.textContaining('BURNED'), findsNothing);
    expect(anyOlderMarker(), findsNothing);
  });
}
