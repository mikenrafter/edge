// One recalculation control on the Sleep screen, and it lives in the card that
// says where the window came from ("This window was inferred from heart rate"),
// not in a strip of its own above it.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

final _onset = DateTime(2026, 5, 19, 23, 7).millisecondsSinceEpoch ~/ 1000;

Map<String, dynamic> _window(String source, {bool withNight = false}) => {
      'sleep_source': source,
      'onset_ts': _onset,
      'wake_ts': _onset + 486 * 60,
      if (withNight) ...{
        'duration_min': 443,
        'in_bed_min': 486,
        'efficiency': .91,
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
    };

Future<void> _pump(WidgetTester t, SleepData d) async {
  t.view.physicalSize = const Size(390 * 3, 5200 * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    home: SleepDetail(data: d),
  ));
  await t.pumpAndSettle();
}

const _button = 'Recalculate this night';

/// The button must be inside the card that carries [label].
void _expectInCard(String label) {
  expect(find.text(_button), findsOneWidget);
  final card = find
      .ancestor(of: find.text(label), matching: find.byType(Surface))
      .first;
  expect(
      find.descendant(of: card, matching: find.text(_button)), findsOneWidget);
}

void main() {
  testWidgets('the inferred-window card holds the one Recalculate button',
      (t) async {
    await _pump(
        t, SleepData(day: '2026-05-20', night: _window('auto_fallback')));
    _expectInCard('This window was inferred from heart rate');
  });

  testWidgets('a window of your own: still one button, still inside its card',
      (t) async {
    await _pump(t, SleepData(day: '2026-05-20', night: _window('manual')));
    _expectInCard('You set this window');
  });

  testWidgets('a scored night: one button, in the window card', (t) async {
    await _pump(
        t,
        SleepData(
            day: '2026-05-20',
            night: _window('auto_fallback', withNight: true)));
    _expectInCard('This window was inferred from heart rate');
  });

  testWidgets('no window at all: no card, and still exactly one button',
      (t) async {
    await _pump(t, const SleepData(day: '2026-05-20'));
    expect(find.text('This window was inferred from heart rate'), findsNothing);
    expect(find.text(_button), findsOneWidget);
  });
}
