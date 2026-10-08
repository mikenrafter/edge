// The Home card for things waiting for review. Laid out like the community
// cards (a Surface, an icon tile beside text, an action button) but with no
// dismiss and no snooze: one line "N marked moments" (bookmark) and one line
// "N assumed water" (the assumed-water glyph); a line whose count is 0 is
// hidden; the whole card is absent when both are 0 or the setting is off. Its
// "Answer" button opens the review. A null-safe helper that needs no AppState
// (like `_naturalWakeCard`).

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
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

const _cardKey = ValueKey('moment-follow-up-card');
const _answerKey = ValueKey('moment-follow-up-answer');
const _momentsText = ValueKey('moment-follow-up-moments');
const _momentsIcon = ValueKey('moment-follow-up-moments-icon');
const _waterText = ValueKey('moment-follow-up-water');
const _waterIcon = ValueKey('moment-follow-up-water-icon');

String _text(WidgetTester t, Key k) => t.widget<Text>(find.byKey(k)).data!;

void main() {
  group('momentFollowUpCardFor', () {
    test('null when the setting is off, however many are pending', () {
      expect(
          momentFollowUpCardFor(enabled: false, moments: 4, assumedWater: 2),
          isNull);
    });

    test('null when both counts are zero', () {
      expect(
          momentFollowUpCardFor(enabled: true, moments: 0, assumedWater: 0),
          isNull);
    });

    test('a card when either count is above zero', () {
      expect(
          momentFollowUpCardFor(enabled: true, moments: 1, assumedWater: 0),
          isNotNull);
      expect(
          momentFollowUpCardFor(enabled: true, moments: 0, assumedWater: 1),
          isNotNull);
    });

    testWidgets('both counts: two lines, each with its own count',
        (t) async {
      await _pump(t,
          momentFollowUpCardFor(enabled: true, moments: 3, assumedWater: 2));
      expect(_text(t, _momentsText), '3 marked moments');
      expect(_text(t, _waterText), '2 assumed water');
      // The old one-line total is gone.
      expect(find.textContaining('things to review'), findsNothing);
      expect(find.text('Answer'), findsOneWidget);
    });

    testWidgets('one marked moment reads as singular', (t) async {
      await _pump(t,
          momentFollowUpCardFor(enabled: true, moments: 1, assumedWater: 1));
      expect(_text(t, _momentsText), '1 marked moment');
      expect(_text(t, _waterText), '1 assumed water');
    });

    testWidgets('moments only: the assumed-water line is not there at all',
        (t) async {
      await _pump(t,
          momentFollowUpCardFor(enabled: true, moments: 4, assumedWater: 0));
      expect(_text(t, _momentsText), '4 marked moments');
      expect(find.byKey(_waterText), findsNothing);
      expect(find.byKey(_waterIcon), findsNothing);
      expect(find.textContaining('assumed water'), findsNothing,
          reason: 'no "0 assumed water", no blank line');
    });

    testWidgets('assumed water only: the marked-moments line is not there',
        (t) async {
      await _pump(t,
          momentFollowUpCardFor(enabled: true, moments: 0, assumedWater: 3));
      expect(_text(t, _waterText), '3 assumed water');
      expect(find.byKey(_momentsText), findsNothing);
      expect(find.byKey(_momentsIcon), findsNothing);
      expect(find.textContaining('marked moment'), findsNothing);
    });

    testWidgets('Answer calls back, and keeps its key', (t) async {
      var n = 0;
      await _pump(
          t,
          momentFollowUpCardFor(
              enabled: true, moments: 2, assumedWater: 0, onAnswer: () => n++));
      expect(find.byKey(_answerKey), findsOneWidget);
      await t.tap(find.byKey(_answerKey));
      await t.pump();
      expect(n, 1);
    });
  });

  group('the card is laid out like a community card, minus the controls', () {
    Future<void> both(WidgetTester t) => _pump(t,
        momentFollowUpCardFor(enabled: true, moments: 3, assumedWater: 2));

    testWidgets('a Surface holds the lines and the button', (t) async {
      await both(t);
      expect(find.byKey(_cardKey), findsOneWidget);
      expect(find.byType(Surface), findsOneWidget);
      for (final k in [_momentsText, _waterText, _answerKey]) {
        expect(
            find.descendant(of: find.byType(Surface), matching: find.byKey(k)),
            findsOneWidget,
            reason: '$k is inside the Surface');
      }
    });

    testWidgets('each line has a 32 px icon tile with its glyph: bookmark for '
        'moments, the assumed-water glyph for water', (t) async {
      await both(t);
      expect(t.getSize(find.byKey(_momentsIcon)), const Size(32, 32));
      expect(t.getSize(find.byKey(_waterIcon)), const Size(32, 32));
      expect(
          find.descendant(
              of: find.byKey(_momentsIcon),
              matching: find.byIcon(annotationIcon(AnnotationKind.moment))),
          findsOneWidget);
      expect(annotationIcon(AnnotationKind.moment), LucideIcons.bookmark);
      expect(
          find.descendant(
              of: find.byKey(_waterIcon),
              matching:
                  find.byIcon(annotationIcon(AnnotationKind.assumedWater))),
          findsOneWidget);
    });

    testWidgets('the icons sit beside their text, moments above water',
        (t) async {
      await both(t);
      final mi = t.getRect(find.byKey(_momentsIcon));
      final mt = t.getRect(find.byKey(_momentsText));
      final wi = t.getRect(find.byKey(_waterIcon));
      final wt = t.getRect(find.byKey(_waterText));
      expect(mi.right, lessThanOrEqualTo(mt.left));
      expect(wi.right, lessThanOrEqualTo(wt.left));
      expect((mi.center.dy - mt.center.dy).abs(), lessThan(12));
      expect((wi.center.dy - wt.center.dy).abs(), lessThan(12));
      expect(mt.top, lessThan(wt.top));
      expect(t.getRect(find.byKey(_answerKey)).top, greaterThan(wt.bottom),
          reason: 'the button is below the lines');
    });

    testWidgets('NO dismiss, snooze or "do not show again" control',
        (t) async {
      await both(t);
      expect(find.byIcon(LucideIcons.x), findsNothing);
      expect(find.byIcon(Icons.close), findsNothing);
      expect(find.text("Don't show this again"), findsNothing);
      expect(find.text('Not now'), findsNothing);
      expect(
          find.byWidgetPredicate((w) =>
              w is Semantics &&
              (w.properties.label == 'Not now' ||
                  w.properties.label == "Don't show this again")),
          findsNothing);
      // The only pressable thing in the card is its Answer button.
      expect(
          find.descendant(
              of: find.byType(Surface), matching: find.byType(Pressable)),
          findsOneWidget);
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
