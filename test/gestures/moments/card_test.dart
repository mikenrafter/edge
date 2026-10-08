// The Home card for things waiting for review: "N things to review — marked
// moments and assumed water" (neutral: it counts pending marked moments AND
// assumed water glasses) with an Answer button. Shown only when the setting is on and N > 0. A
// null-safe helper that needs no AppState (like `_naturalWakeCard`).

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/screens/moment_follow_up.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import '../../support/dart_source_lexical.dart';

Future<void> _pump(WidgetTester t, Widget? card) async {
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    home: Scaffold(body: card ?? const Text('no card')),
  ));
  await t.pumpAndSettle();
}

void main() {
  group('momentFollowUpCardFor', () {
    test('null when the setting is off, however many are pending', () {
      expect(momentFollowUpCardFor(enabled: false, count: 4), isNull);
    });

    test('null when nothing is pending', () {
      expect(momentFollowUpCardFor(enabled: true, count: 0), isNull);
    });

    testWidgets('on with N pending: the question and the count', (t) async {
      await _pump(t, momentFollowUpCardFor(enabled: true, count: 3));
      expect(find.text('3 things to review — marked moments and assumed water'),
          findsOneWidget);
      expect(find.text('Answer'), findsOneWidget);
    });

    testWidgets('one thing reads as one', (t) async {
      await _pump(t, momentFollowUpCardFor(enabled: true, count: 1));
      expect(find.text('1 thing to review — marked moments and assumed water'), findsOneWidget);
    });

    testWidgets('Answer calls back', (t) async {
      var n = 0;
      await _pump(
          t, momentFollowUpCardFor(enabled: true, count: 2, onAnswer: () => n++));
      await t.tap(find.text('Answer'));
      await t.pump();
      expect(n, 1);
    });
  });

  group('momentFollowUpCard(BuildContext)', () {
    testWidgets('with no AppState above it is null, not an exception',
        (t) async {
      Widget? got = const SizedBox();
      await t.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Builder(builder: (c) {
          got = momentFollowUpCard(c);
          return got ?? const Text('none');
        }),
      ));
      expect(got, isNull);
      expect(find.text('none'), findsOneWidget);
    });
  });

  test('Home draws it wherever it draws the natural-wake card', () {
    final code =
        codeOnly(File('lib/ui2/screens/home_screen.dart').readAsStringSync());
    final wake = RegExp(r'\?_naturalWakeCard\(c\)').allMatches(code).length;
    final moments =
        RegExp(r'\?momentFollowUpCard\(c\)').allMatches(code).length;
    expect(wake, greaterThanOrEqualTo(2));
    expect(moments, wake,
        reason: 'the loaded and the no-day Home paths both show the card');
  });
}
