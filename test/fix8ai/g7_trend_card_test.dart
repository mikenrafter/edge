// 8AI.2 G7 (red first): the Health trend cards (Resting HR / HRV / Sleep, one
// shared TrendCard).
//
// USER REPORT (APK f88d230c), Health tab at ~360 pt:
//   * Sleep: the big value read "4h 2..." beside "Time asleep" and a delta.
//     Cause: TrendCard's value is a Flexible peer of the Spacer and the delta,
//     and the unit ("Time asleep") is a fixed-size sibling, so on a narrow row
//     the value is the one that gives. The value must win; the caption gives.
//   * "as of 1 days ago". Cause: axisDay hand-builds "$behind days ago", and
//     the card passes it into the "as of {date}" string.
//
// ASSUMED: at 360 pt (and with a 1.3 x text scale, still below the restack
// point) the value is never ellipsised, whatever the caption and delta say;
// "Time asleep" may wrap or shrink instead. axisDay says "1 day ago" for one
// day and "N days ago" otherwise (and "1 night ago" with unitWord 'nights').

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/capabilities.dart';
import 'package:openstrap_edge/state/locale_controller.dart';
import 'package:openstrap_edge/state/units_controller.dart';
import 'package:openstrap_edge/theme/theme_controller.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

int _noon(int back) {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day - back, 12).millisecondsSinceEpoch ~/
      1000;
}

Future<void> _pumpCard(WidgetTester t, TrendCard card,
    {double width = 360, double scale = 1}) async {
  t.view.physicalSize = Size(width, 1200);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    home: MediaQuery(
      data: MediaQueryData(
          size: Size(width, 1200), textScaler: TextScaler.linear(scale)),
      child: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(S.x4),
          child: card,
        ),
      ),
    ),
  ));
  await t.pump();
}

TrendCard _card(String value, String unit, String delta) => TrendCard(
      'Sleep',
      value,
      unit,
      delta,
      'vs your 7h 00m need',
      const [null, 400, 420, 465],
      C.blue,
      up: false,
      good: false,
    );

void _expectWhole(WidgetTester t, String value) {
  final p = t.renderObject<RenderParagraph>(find.text(value));
  expect(p.didExceedMaxLines, isFalse,
      reason: '"$value" was ellipsised: the hero value must never truncate');
  expect(t.takeException(), isNull);
}

void main() {
  group('the hero value never truncates', () {
    for (final value in ['4h 22m', '10h 59m']) {
      for (final scale in [1.0, 1.3]) {
        testWidgets('"$value" beside "Time asleep" and a delta, 360 pt, '
            '${scale}x text', (t) async {
          await _pumpCard(t, _card(value, 'Time asleep', '2h 35m'),
              scale: scale);
          _expectWhole(t, value);
          expect(find.text('Time asleep'), findsOneWidget,
              reason: 'the caption is still there (it may wrap)');
          expect(find.text('2h 35m'), findsOneWidget);
        });
      }
    }

    testWidgets('a short value keeps the delta on the right edge', (t) async {
      await _pumpCard(t, _card('51', 'bpm', '3'));
      final card = t.getRect(find.byType(TrendCard));
      final delta = t.getRect(find.text('3'));
      expect(card.right - delta.right, lessThanOrEqualTo(S.x4 + 1),
          reason: 'the change stays flush right, as before');
    });

    testWidgets('a long unit gives way, the value does not', (t) async {
      await _pumpCard(t, _card('10h 59m', 'Time asleep last night', '2h 35m'));
      _expectWhole(t, '10h 59m');
    });
  });

  group('"as of N days ago"', () {
    test('axisDay: singular for one, plural otherwise', () {
      expect(axisDay(_noon(1)), '1 day ago');
      expect(axisDay(_noon(2)), '2 days ago');
      expect(axisDay(_noon(14)), '14 days ago');
      expect(axisDay(_noon(1), unitWord: 'nights'), '1 night ago');
      expect(axisDay(_noon(3), unitWord: 'nights'), '3 nights ago');
      expect(axisDay(_noon(0)), 'Today');
    });

    Future<void> pumpHealth(WidgetTester t, int ago) async {
      t.view.physicalSize = const Size(390, 3000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      final pts = [
        for (var i = ago + 8; i >= ago; i--) {'t': _noon(i), 'v': 50.0 + i},
      ];
      await t.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider<AppState>.value(value: app),
          ChangeNotifierProvider(
              create: (_) => UnitsController.seed(UnitSystem.metric)),
          ChangeNotifierProvider(
              create: (_) => ThemeController.seed(
                  AppThemeChoice.light, Brightness.light)),
          ChangeNotifierProvider(create: (_) => LocaleController.seed(null)),
          Provider<Capabilities>.value(
              value: Capabilities(const CapabilityInputs())),
        ],
        child: MaterialApp(
          theme: buildTheme(Brightness.light),
          home: Scaffold(
            body: HealthScreen(
              tab: 2,
              data: HealthData(charts: {
                'resting_hr': [
                  for (final p in pts) (t: p['t'] as int, v: p['v'] as double),
                ],
              }),
              explore: const ExploreData(counts: {}),
            ),
          ),
        ),
      ));
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));
    }

    testWidgets('the card says "as of 1 day ago", not "1 days ago"',
        (t) async {
      await pumpHealth(t, 1);
      expect(find.textContaining('as of 1 day ago'), findsOneWidget);
      expect(find.textContaining('1 days ago'), findsNothing);
    });

    testWidgets('two days stay plural', (t) async {
      await pumpHealth(t, 2);
      expect(find.textContaining('as of 2 days ago'), findsOneWidget);
    });
  });
}
