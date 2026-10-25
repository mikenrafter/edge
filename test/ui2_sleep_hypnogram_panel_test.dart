import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/state/clock_format.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

final _onset = DateTime(2026, 5, 19, 23).millisecondsSinceEpoch ~/ 1000;
final _wake = DateTime(2026, 5, 20, 7).millisecondsSinceEpoch ~/ 1000;

SleepData _data({bool signals = true, bool stages = true}) => SleepData(
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
        'hypnogram': stages ? [
          {'t': _onset, 'stage': 'light'},
          {'t': _onset + 3600, 'stage': 'deep'},
          {'t': _onset + 10800, 'stage': 'unobserved'},
          {'t': _onset + 18000, 'stage': 'rem'},
          // The last display sample is two minutes before wake and misses this.
          {'t': _wake - 60, 'stage': 'awake'},
          {'t': _wake, 'stage': 'awake'},
        ] : [],
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

Future<void> _pump(WidgetTester t, {double scale = 1, bool signals = true,
    bool stages = true, Brightness brightness = Brightness.light}) async {
  t.view.physicalSize = Size(390 * 3, 6200 * 3 * scale);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    theme: buildTheme(brightness),
    builder: (c, child) => MediaQuery(
      data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    ),
    home: SleepDetail(key: ValueKey(stages),
        data: _data(signals: signals, stages: stages)),
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

      final p = P.of(t.element(panels.first));
      for (final (label, at, time, stage, color) in [
        ('Hypnogram', .25, '01:00', 'Deep sleep', p.on(Hypnogram.pigment[SleepStage.deep]!)),
        ('Through the night', .5, '03:00', 'Not measured', null),
        ('Hypnogram', .75, '05:00', 'REM', p.on(Hypnogram.pigment[SleepStage.rem]!)),
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

  testWidgets('selected stages use boundaries even between display samples',
      (t) async {
    await _pump(t);
    final panels = find.byKey(ChartKeyReadout.panelKey);
    for (final (seconds, time, stage) in [
      (3599, '23:59', 'Light sleep'),
      (3600, '00:00', 'Deep sleep'),
      (10799, '01:59', 'Deep sleep'),
      (10800, '02:00', 'Not measured'),
      (17999, '03:59', 'Not measured'),
      (18000, '04:00', 'REM'),
      (28739, '06:58', 'REM'),
      (28740, '06:59', 'Awake'),
    ]) {
      await _scrub(t, 'Hypnogram', seconds / 28800);
      for (var i = 0; i < 2; i++) {
        expect(_in(panels.at(i), 'SELECTED · $time'), findsOneWidget);
        expect(_in(panels.at(i), stage), findsOneWidget);
      }
      final plot = t.widget<Scrubber>(_plot('Hypnogram'));
      final spoken = stage == 'Not measured' ? 'not measured' : stage;
      expect(plot.describe(seconds / 28800), '$time, $spoken');
    }
  });

  for (final brightness in Brightness.values) {
    testWidgets('stage caption and value clear contrast in $brightness',
        (t) async {
      await _pump(t, brightness: brightness);
      final panel = find.byKey(ChartKeyReadout.panelKey).first;
      final p = P.of(t.element(panel));
      for (final (at, stage, pigment) in [
        (0.0, 'Light sleep', C.sky),
        (.25, 'Deep sleep', C.blue),
        (.75, 'REM', C.teal),
        (1.0, 'Awake', C.orange),
      ]) {
        await _scrub(t, 'Hypnogram', at == 1 ? .9999 : at);
        final caption = find.descendant(of: panel,
            matching: find.byKey(ChartKeyReadout.captionKey));
        for (final text in [_in(panel, stage), caption]) {
          final color = t.widget<Text>(text).style!.color!;
          expect(color, p.on(pigment));
          expect(P.contrast(color, p.card2), greaterThanOrEqualTo(4.5));
        }
      }
    });
  }

  testWidgets('dragging across stages measures no captions again', (t) async {
    // A fresh scale keeps other tests from warming the stage-color cache.
    await _pump(t, scale: 1.17);
    final plot = t.getRect(_plot('Hypnogram'));
    Offset at(double f) => Offset(plot.left + plot.width * f, plot.center.dy);
    final g = await t.startGesture(at(.01));
    await t.pump();
    final before = ChartKeyReadout.captionMeasures;
    for (final (f, stage) in [
      (.25, 'Deep sleep'), (.5, 'Not measured'), (.75, 'REM'), (.9999, 'Awake'),
    ]) {
      await g.moveTo(at(f));
      await t.pump();
      final panels = find.byKey(ChartKeyReadout.panelKey);
      for (var i = 0; i < 2; i++) {
        expect(_in(panels.at(i), stage), findsOneWidget);
      }
      expect(ChartKeyReadout.captionMeasures, before,
          reason: 'a stage color change must reuse the reserved caption height');
    }
    await g.up();
    expect(t.takeException(), isNull);
  });

  for (final scale in [1.0, 1.3, 3.1]) {
    testWidgets('missing stages keep the night panel at ${scale}x text',
        (t) async {
      await _pump(t, scale: scale, signals: false);
      final card = find.byKey(const ValueKey('card:night'));
      final panel = find.byKey(ChartKeyReadout.panelKey);
      expect(panel, findsOneWidget);
      final panelRect = t.getRect(panel);
      final hintTop = t.getTopLeft(_in(card,
          'Tap or drag the chart for any moment of the night.')).dy;
      await _pump(t, scale: scale, signals: false, stages: false);
      expect(panel, findsOneWidget);
      expect(_in(panel, 'LATEST · 07:00'), findsOneWidget);
      expect(_in(panel, 'Not measured'), findsOneWidget);
      expect(_in(panel, '—'), findsNWidgets(3));
      for (final label in ['Stage', 'Heart rate', 'HRV', 'Breathing']) {
        expect(_in(panel, label), findsOneWidget);
      }
      expect(t.getRect(panel), panelRect);
      // The explanation starts in the same place even when its words wrap
      // differently from the loaded chart's interaction hint.
      expect(t.getTopLeft(_in(card, 'No hypnogram for this night')).dy, hintTop);
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
