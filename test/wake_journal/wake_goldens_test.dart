// Goldens for the wake journal: markers on the day timeline and sleep chart,
// and the dream question asked after I'm up.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/screens/sleep_detail.dart';
import 'package:openstrap_edge/ui2/screens/wake_dream_question.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import '../support/bundled_fonts.dart';
import 'wake_widgets_test.dart' show dayFixture, sleepFixture;

const _boundary = ValueKey('wake-journal-golden');

Future<void> _pump(WidgetTester t, Widget page, {double height = 1400}) async {
  t.view.devicePixelRatio = 1;
  t.view.physicalSize = Size(412, height);
  addTearDown(t.view.reset);
  await t.pumpWidget(RepaintBoundary(key: _boundary, child: MaterialApp(
    debugShowCheckedModeBanner: false,
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    theme: buildTheme(Brightness.light),
    home: page,
  )));
  await t.pumpAndSettle();
}

void main() {
  setUpAll(loadFonts);

  testWidgets('wake journal day timeline golden', (t) async {
    await _pump(t, dayFixture());
    await expectLater(find.byKey(_boundary),
        matchesGoldenFile('goldens/wake_journal_day.png'));
  });

  testWidgets('wake journal sleep detail golden', (t) async {
    await _pump(t, SleepDetail(data: sleepFixture()));
    await expectLater(find.byKey(_boundary),
        matchesGoldenFile('goldens/wake_journal_sleep.png'));
  });

  testWidgets('wake dream question golden', (t) async {
    await _pump(t, Builder(builder: (c) => Scaffold(body: Center(
      child: TextButton(
        onPressed: () => showDialog<void>(context: c,
            builder: (_) => WakeDreamQuestionDialog(
                onAnswer: (_) async {}, onSkip: () {})),
        child: const Text('open'),
      ),
    ))), height: 500);
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    await expectLater(find.byKey(_boundary),
        matchesGoldenFile('goldens/wake_journal_dream_question.png'));
  });
}
