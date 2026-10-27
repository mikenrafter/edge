import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/models/activity_suggestion.dart';
import 'package:openstrap_edge/ui2/screens/detected_activities.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import 'support/apk2_review_harness.dart';
import 'support/as_of_recalc_fakes.dart' show settle;

void main() {
  testWidgets('review breakdown opens Typical day with meal setting and Alarm link', (t) async {
    final r = await Apk2Rig.create(t);
    await r.mount(t, size: const Size(412, 1400));
    final entry = find.text('Typical day');
    expect(entry, findsOneWidget);
    await t.ensureVisible(entry);
    await t.tap(entry);
    await settle(t);
    expect(find.text('Typical day'), findsWidgets);
    expect(find.text('Typical large meals'), findsOneWidget);
    expect(find.textContaining('Caffeine'), findsWidgets);
    expect(find.textContaining('Alarm'), findsWidgets);
    expect(t.takeException(), isNull);
  });

  testWidgets('meal proposal is labelled meal and offers meal actions', (t) async {
    final p = ActivitySuggestion(id: 'meal-card',
        kind: ActivityKind.values.byName('meal'), startTs: apk2At(12),
        endTs: apk2At(12, 25), revision: 0);
    var confirmed = 0, discarded = 0;
    await t.pumpWidget(MaterialApp(theme: buildTheme(Brightness.light),
        home: Scaffold(body: ActivityProposalCard(suggestion: p,
          onConfirm: () => confirmed++, onDiscard: () => discarded++))));
    expect(find.text('Possible meal'), findsOneWidget);
    expect(find.text('Not a meal'), findsOneWidget);
    expect(find.text('Change sport'), findsNothing);
    await t.tap(find.text('Confirm'));
    await t.tap(find.text('Not a meal'));
    expect(confirmed, 1);
    expect(discarded, 1);
  });
}
