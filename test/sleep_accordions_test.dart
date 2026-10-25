// The Sleep screen's sections are the app's own remembered accordions: every
// one open by default, folded only by a tap on its header, and the answer kept
// per section id across a remount. The headline (total sleep) stays outside.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/profile/profile.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _onset = DateTime(2026, 5, 19, 23, 7).millisecondsSinceEpoch ~/ 1000;

SleepData _data() => SleepData(
      day: '2026-05-20',
      night: {
        'duration_min': 443,
        'in_bed_min': 486,
        'awake_min': 20,
        'efficiency': .91,
        'onset_ts': _onset,
        'wake_ts': _onset + 486 * 60,
        'light_min': 170,
        'deep_min': 85,
        'rem_min': 95,
        'hypnogram': [
          {'t': _onset, 'stage': 'light'},
          {'t': _onset + 3600, 'stage': 'deep'},
          {'t': _onset + 7200, 'stage': 'rem'},
          {'t': _onset + 486 * 60, 'stage': 'awake'},
        ],
      },
      tstHistory: [for (var i = 0; i < 20; i++) 400 + i * 5],
    );

Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 6; i++) {
    await t.pump(const Duration(milliseconds: 20));
  }
  await t.pumpAndSettle();
}

Future<void> _open(WidgetTester t) async {
  t.view.physicalSize = const Size(390 * 3, 6000 * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    theme: buildTheme(Brightness.light),
    home: SleepDetail(data: _data()),
  ));
  await _settle(t);
}

Finder _acc(String title) => find.byWidgetPredicate(
    (w) => w is SettingsAccordion && w.title == title,
    description: 'SettingsAccordion "$title"');

Finder _body(String title) =>
    find.descendant(of: _acc(title), matching: find.byType(Surface));

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  const titles = [
    'Through the night',
    'Stages',
    'Against your usual',
    'Overnight signals',
    'Tonight',
  ];

  testWidgets('each section is an accordion with its existing title, all open',
      (t) async {
    await _open(t);
    for (final title in titles) {
      expect(_acc(title), findsOneWidget, reason: title);
      expect(_body(title), findsWidgets, reason: '$title is open by default');
    }
    // The headline is not inside any accordion.
    expect(
        find.descendant(
            of: find.byType(SettingsAccordion),
            matching: find.text('Total sleep')),
        findsNothing);
    expect(find.text('Total sleep'), findsOneWidget);
  });

  testWidgets('tapping a header folds and unfolds only that section',
      (t) async {
    await _open(t);
    await t.tap(find.descendant(
        of: _acc('Stages'), matching: find.byType(Pressable)).first);
    await _settle(t);
    expect(_body('Stages'), findsNothing);
    expect(_body('Tonight'), findsWidgets);
    await t.tap(find.descendant(
        of: _acc('Stages'), matching: find.byType(Pressable)).first);
    await _settle(t);
    expect(_body('Stages'), findsWidgets);
  });

  testWidgets('a folded section stays folded after the screen is remounted',
      (t) async {
    await _open(t);
    await t.tap(find.descendant(
        of: _acc('Tonight'), matching: find.byType(Pressable)).first);
    await _settle(t);
    await t.pumpWidget(const SizedBox());
    await _settle(t);
    await _open(t);
    expect(_body('Tonight'), findsNothing);
    expect(_body('Stages'), findsWidgets);
  });
}
