import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:openstrap_edge/wake/outcomes/wake_outcome.dart';
import 'package:openstrap_edge/wake/outcomes/wake_outcomes_screen.dart';
import 'package:openstrap_edge/wake/outcomes/wake_preference_policy.dart';

import 'outcome_rig.dart';

const _insufficient = ShadowPolicyResult(
    wouldChoose: null, reason: 'insufficient', usableByPolicy: {});

Future<void> pump(WidgetTester t, Widget w) async {
  t.view.physicalSize = const Size(390 * 3, 2400 * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    home: Scaffold(body: SingleChildScrollView(child: w)),
  ));
}

Widget screen(
  List<WakeOutcome> outcomes, {
  ShadowPolicyResult shadow = _insufficient,
  void Function(int, int)? onRate,
}) =>
    WakeOutcomesScreen(
      outcomes: outcomes,
      shadow: shadow,
      onRate: onRate ?? (_, __) {},
    );

List<String> allText(WidgetTester t) => [
      for (final w in t.widgetList<Text>(find.byType(Text)))
        w.data ?? w.textSpan?.toPlainText() ?? '',
    ];

void main() {
  group('WakeOutcomesScreen', () {
    testWidgets('lists a morning with each response, or "not seen"',
        (t) async {
      await pump(
        t,
        screen([
          outcome(kT,
              grogginess: 3,
              minutesBeforeT: 22.4,
              latencySec: {
                WakeResponseKind.deliberateAck: 240,
                WakeResponseKind.appInteraction: null,
                WakeResponseKind.movement: 45,
              }),
        ]),
      );
      expect(find.text("I'm up: 4 min"), findsOneWidget);
      expect(find.text('App opened: not seen'), findsOneWidget);
      expect(find.text('Movement: 45 s'), findsOneWidget);
      expect(find.textContaining('Natural Wake'), findsOneWidget);
      expect(find.textContaining('22 min before wake time'), findsOneWidget);
      expect(find.text('Grogginess: 3 of 5'), findsOneWidget);
    });

    testWidgets('a censored response is never shown as 0', (t) async {
      await pump(t, screen([outcome(kT)])); // nothing observed
      expect(find.textContaining('not seen'), findsNWidgets(3));
      expect(find.textContaining('0 min'), findsNothing);
      expect(find.textContaining('0 s'), findsNothing);
      expect(find.textContaining(RegExp(r': 0\b')), findsNothing);
    });

    testWidgets('one row per morning, other fire mechanisms in words',
        (t) async {
      await pump(
        t,
        screen([
          outcome(kT + 3 * 86400,
              firedBy: WakeFiredBy.gradual,
              minutesBeforeT: 10,
              stageAtFire: null,
              stageAgeSec: null),
          outcome(kT + 2 * 86400,
              firedBy: WakeFiredBy.native,
              minutesBeforeT: 0,
              stageAtFire: null,
              stageAgeSec: null),
          outcome(kT + 86400,
              firedBy: WakeFiredBy.none,
              minutesBeforeT: null,
              delivered: false,
              stageAtFire: null,
              stageAgeSec: null,
              exclusions: [WakeExclusion.noDelivery]),
        ]),
      );
      expect(find.textContaining('Gradual Wake'), findsOneWidget);
      expect(find.textContaining('Alarm at wake time'), findsOneWidget);
      expect(find.textContaining('Nothing fired'), findsOneWidget);
      expect(find.textContaining('I\'m up:'), findsNWidgets(3));
    });

    testWidgets('exclusions are shown in words', (t) async {
      await pump(
        t,
        screen([
          outcome(kT, exclusions: [
            WakeExclusion.noDelivery,
            WakeExclusion.alreadyAwake,
            WakeExclusion.staleStage,
            WakeExclusion.competingAlarm,
            WakeExclusion.crossedEpisode,
          ]),
        ]),
      );
      expect(find.text('Not counted: No wake buzz reached the band'),
          findsOneWidget);
      expect(find.text('Not counted: You were already using the app'),
          findsOneWidget);
      expect(find.text('Not counted: Sleep-stage data was too old'),
          findsOneWidget);
      expect(find.text('Not counted: Another alarm was close by'),
          findsOneWidget);
      expect(find.text('Not counted: First response came hours later'),
          findsOneWidget);
    });

    testWidgets('a counted morning shows no exclusion text', (t) async {
      await pump(t, screen([outcome(kT)]));
      expect(find.textContaining('Not counted'), findsNothing);
    });

    testWidgets('the shadow line is always there', (t) async {
      await pump(t, screen(const []));
      expect(find.text('Shadow mode — nothing changes your alarm'),
          findsOneWidget);
    });

    testWidgets('would-choose text only when non-null', (t) async {
      await pump(t, screen([outcome(kT)]));
      expect(find.textContaining('Would choose'), findsNothing);
      expect(find.text('Not enough rated mornings yet'), findsOneWidget);

      await pump(
        t,
        screen([outcome(kT)],
            shadow: const ShadowPolicyResult(
                wouldChoose: 'window:30',
                reason: 'lowerGrogginess',
                usableByPolicy: {'rem:30': 12, 'rem:60': 10})),
      );
      expect(find.text('Would choose a 30-minute window'), findsOneWidget);
      expect(find.text('Not enough rated mornings yet'), findsNothing);
      expect(find.text('Shadow mode — nothing changes your alarm'),
          findsOneWidget);
    });

    testWidgets('prompts for the newest unrated delivered morning',
        (t) async {
      final calls = <(int, int)>[];
      await pump(
        t,
        screen([
          outcome(kT + 86400 * 3, delivered: false, minutesBeforeT: null,
              firedBy: WakeFiredBy.none), // newest, but nothing was delivered
          outcome(kT + 86400 * 2), // the one to rate
          outcome(kT + 86400), // older, also unrated
          outcome(kT, grogginess: 2),
        ], onRate: (w, g) => calls.add((w, g))),
      );
      expect(find.text('How groggy did you feel on waking?'), findsOneWidget);
      await t.tap(find.text('4'));
      expect(calls, [(kT + 86400 * 2, 4)]);
    });

    testWidgets('no prompt when every delivered morning is rated',
        (t) async {
      await pump(t, screen([outcome(kT, grogginess: 3)]));
      expect(find.text('How groggy did you feel on waking?'), findsNothing);
    });

    testWidgets('never claims sleep inertia, ideal stages or diagnoses',
        (t) async {
      await pump(
        t,
        screen([
          outcome(kT, exclusions: [WakeExclusion.alreadyAwake]),
          outcome(kT + 86400),
        ],
            shadow: const ShadowPolicyResult(
                wouldChoose: 'window:30',
                reason: 'lowerGrogginess',
                usableByPolicy: {})),
      );
      expect(allText(t), isNotEmpty);
      for (final s in allText(t)) {
        final l = s.toLowerCase();
        expect(l, isNot(contains('sleep inertia')), reason: s);
        expect(l, isNot(contains('ideal stage')), reason: s);
        expect(l, isNot(contains('diagnos')), reason: s);
      }
    });
  });

  group('GrogginessPromptCard', () {
    testWidgets('asks the question with five options and reports the pick',
        (t) async {
      final calls = <(int, int)>[];
      await pump(
        t,
        GrogginessPromptCard(
          pending: outcome(kT),
          onRate: (w, g) => calls.add((w, g)),
        ),
      );
      expect(find.text('How groggy did you feel on waking?'), findsOneWidget);
      for (final n in ['1', '2', '3', '4', '5']) {
        expect(find.text(n), findsOneWidget);
      }
      await t.tap(find.text('3'));
      expect(calls, [(kT, 3)]);
      await t.tap(find.text('5'));
      expect(calls, [(kT, 3), (kT, 5)]);
    });

    testWidgets('is absent when nothing is pending', (t) async {
      await pump(t, GrogginessPromptCard(pending: null, onRate: (_, __) {}));
      expect(find.text('How groggy did you feel on waking?'), findsNothing);
      expect(find.byType(Text), findsNothing);
    });

    testWidgets('makes no sleep-inertia, ideal-stage or diagnostic claim',
        (t) async {
      await pump(
          t, GrogginessPromptCard(pending: outcome(kT), onRate: (_, __) {}));
      for (final s in allText(t)) {
        final l = s.toLowerCase();
        expect(l, isNot(contains('sleep inertia')));
        expect(l, isNot(contains('ideal stage')));
        expect(l, isNot(contains('diagnos')));
      }
    });
  });
}
