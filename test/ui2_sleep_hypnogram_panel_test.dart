import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/state/clock_format.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

final _onset = DateTime(2026, 5, 19, 23).millisecondsSinceEpoch ~/ 1000;
final _wake = DateTime(2026, 5, 20, 7).millisecondsSinceEpoch ~/ 1000;

SleepData _data({bool signals = true}) => SleepData(
      day: '2026-05-20',
      night: {
        'duration_min': 360,
        'in_bed_min': 480,
        'awake_min': 15,
        'efficiency': .75,
        'onset_ts': _onset,
        'wake_ts': _wake,
        'light_min': 120,
        'deep_min': 120,
        'rem_min': 105,
        'hypnogram': [
          {'t': _onset, 'stage': 'light'},
          {'t': _onset + 3600, 'stage': 'deep'},
          {'t': _onset + 10800, 'stage': 'unobserved'},
          {'t': _onset + 18000, 'stage': 'rem'},
          {'t': _wake - 900, 'stage': 'awake'},
          {'t': _wake, 'stage': 'awake'},
        ],
      },
      timeline: signals ? {
        'hr': [
          {'t': _onset, 'v': 50},
          {'t': _onset + 7200, 'v': 54},
          {'t': _onset + 14400, 'v': 58},
          {'t': _wake, 'v': 66},
        ],
        'hrv': [{'t': _onset + 7200, 'v': 42}],
        'resp': [{'t': _onset + 14400, 'v': 17.5}],
      } : {},
    );

Future<void> _pump(WidgetTester t, {double scale = 1, bool signals = true}) async {
  t.view.physicalSize = Size(390 * 3, 6200 * 3 * scale);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    theme: buildTheme(Brightness.light),
    builder: (c, child) => MediaQuery(
      data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    ),
    home: SleepDetail(data: _data(signals: signals)),
  ));
  await t.pumpAndSettle();
  expect(t.takeException(), isNull);
}

Finder _plot(String label) => find.byWidgetPredicate(
    (w) => w is Scrubber && w.label == label);

Finder _in(Finder panel, String text) =>
    find.descendant(of: panel, matching: find.text(text));

Future<void> _scrub(WidgetTester t, String label, double at) async {
  final rect = t.getRect(_plot(label));
  await t.tapAt(Offset(rect.left + rect.width * at, rect.center.dy));
  await t.pumpAndSettle();
  expect(t.takeException(), isNull);
}

void main() {
  setUp(() {
    ClockFormatController.seed(ClockFormat.h24);
  });
  tearDown(ClockFormatController.debugReset);

  for (final scale in [1.0, 1.3, 3.1]) {
    testWidgets('both night panels keep their height at ${scale}x text', (t) async {
      await _pump(t, scale: scale);
      final panels = find.byKey(ChartKeyReadout.panelKey);
      expect(panels, findsNWidgets(2));
      final surfaces = find.byType(Surface).evaluate().length;
      final rects = [for (var i = 0; i < 2; i++) t.getRect(panels.at(i))];
      for (var i = 0; i < 2; i++) {
        expect(_in(panels.at(i), 'LATEST · 07:00'), findsOneWidget);
        expect(_in(panels.at(i), 'Awake'), findsOneWidget);
        expect(_in(panels.at(i), '66 bpm'), findsOneWidget);
        expect(_in(panels.at(i), '—'), findsNWidgets(2));
        final box = t.widget<Container>(panels.at(i)).decoration as BoxDecoration;
        expect(box.border, isNull);
      }

      for (final (label, at, time, stage, color) in [
        ('Hypnogram', .25, '01:00', 'Deep sleep', Hypnogram.pigment[SleepStage.deep]!),
        ('Through the night', .5, '03:00', 'Not measured', null),
        ('Hypnogram', .75, '05:00', 'REM', Hypnogram.pigment[SleepStage.rem]!),
      ]) {
        await _scrub(t, label, at);
        expect(panels, findsNWidgets(2));
        expect(find.byType(Surface), findsNWidgets(surfaces));
        for (var i = 0; i < 2; i++) {
          final panel = panels.at(i);
          expect(_in(panel, 'SELECTED · $time'), findsOneWidget);
          expect(_in(panel, stage), findsOneWidget);
          expect(t.getRect(panel), rects[i], reason: 'no shift at $time');
          final box = t.widget<Container>(panel).decoration as BoxDecoration;
          expect(box.border, isNotNull);
          if (color != null) {
            expect(t.widget<Text>(_in(panel, stage)).style?.color, color);
            expect(t.widget<Text>(_in(panel, 'SELECTED · $time')).style?.color,
                color);
          }
          // The old readout added a Surface and a stage Pill on each scrub.
          expect(find.descendant(of: panel, matching: find.byType(Surface)),
              findsNothing);
          expect(find.widgetWithText(Pill, stage), findsNothing);
        }
      }
    });
  }

  testWidgets('each signal abstains independently, including an unmeasured stage',
      (t) async {
    // Disposed in the body: a tear-down runs after the handle check.
    final semantics = t.ensureSemantics();
    try {
      await _pump(t);
      final panel = find.byKey(ChartKeyReadout.panelKey).first;
      await _scrub(t, 'Hypnogram', .25);
      expect(_in(panel, '54 bpm'), findsOneWidget);
      expect(_in(panel, '42 ms'), findsOneWidget);
      expect(_in(panel, '—'), findsOneWidget);
      await _scrub(t, 'Hypnogram', .5);
      expect(_in(panel, 'Not measured'), findsOneWidget);
      expect(_in(panel, '58 bpm'), findsOneWidget);
      expect(_in(panel, '17.5 br/min'), findsOneWidget);
      expect(_in(panel, '—'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('SELECTED.*03:00.*Not measured.*58 bpm')),
          findsWidgets);
      await _scrub(t, 'Hypnogram', .75);
      expect(_in(panel, '—'), findsNWidgets(3));
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('a hypnogram without signal lines still has a stable stage panel',
      (t) async {
    await _pump(t, signals: false);
    final panel = find.byKey(ChartKeyReadout.panelKey);
    expect(panel, findsOneWidget);
    final rect = t.getRect(panel);
    expect(_in(panel, 'LATEST · 07:00'), findsOneWidget);
    expect(_in(panel, 'Awake'), findsOneWidget);
    expect(_in(panel, '—'), findsNWidgets(3));
    await _scrub(t, 'Hypnogram', .5);
    expect(_in(panel, 'SELECTED · 03:00'), findsOneWidget);
    expect(_in(panel, 'Not measured'), findsOneWidget);
    expect(t.getRect(panel), rect);
    expect(find.text('No signal recorded at this moment.'), findsNothing);
  });
}
