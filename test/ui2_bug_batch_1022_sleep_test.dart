// RED (owner UI feedback 2026-10-22, B2 + B3). Sleep detail.
//
// B2: `skin_temp_day` is raw sensor counts minus the day median, not degrees,
//     and can include off-wrist bins ("Skin temp -619.0–96.2 rel"). No number
//     may be printed for it: the legend says "Skin temp · relative" and the
//     scrub readout shows "—" or omits it. The trend line stays.
// B3: the scrub readout under the hypnogram and under Overnight signals ran
//     "17.5 br/min" straight into the temp value ("17.5 br/min82.50"). Values
//     in one readout row must never touch at 390 pt and 1.3x text.
//
// NEW ARB KEY (English text asserted, Key-free): sleepDetailSkinTempRelative
// = "Skin temp · relative" (legend entry, no numbers, no unit suffix).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

final _onset = DateTime(2026, 5, 19, 23, 7).millisecondsSinceEpoch ~/ 1000;
const _inBedMin = 486;

SleepData _data() {
  final n = _inBedMin ~/ 5;
  List<Map<String, num>> lane(num Function(int i) v) =>
      [for (var i = 0; i <= n; i++) {'t': _onset + i * 300, 'v': v(i)}];
  return SleepData(
    day: '2026-05-20',
    night: {
      'duration_min': 443,
      'in_bed_min': _inBedMin,
      'awake_min': 20,
      'efficiency': .91,
      'onset_ts': _onset,
      'wake_ts': _onset + _inBedMin * 60,
      'light_min': 170,
      'deep_min': 85,
      'rem_min': 95,
      'hypnogram': [
        {'t': _onset, 'stage': 'light'},
        {'t': _onset + 3600, 'stage': 'deep'},
        {'t': _onset + 7200, 'stage': 'rem'},
        {'t': _onset + _inBedMin * 60, 'stage': 'awake'},
      ],
      'nocturnal': {'sleeping_hr_avg': 60, 'sleeping_hr_min': 56},
      'resp': {'value': 16.5},
    },
    timeline: {
      'hr': lane((i) => 60 + i % 7),
      'hrv': lane((i) => 50 + i % 5),
      'resp': lane((i) => 17.5),
      // Off-wrist bins at both ends, a flat 82.5 in the middle where we scrub.
      'skin_temp': lane((i) => i == 0 ? -619.0 : (i == n ? 96.2 : 82.5)),
    },
  );
}

Future<void> _pump(WidgetTester t, {double scale = 1.3}) async {
  t.view.physicalSize = Size(390 * 3, 5200 * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    theme: buildTheme(Brightness.dark),
    builder: (c, child) => MediaQuery(
      data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    ),
    home: SleepDetail(data: _data()),
  ));
  await t.pumpAndSettle();
}

Future<void> _scrubMiddle(WidgetTester t) async {
  final plot = find.byWidgetPredicate(
      (w) => w is Scrubber && w.label == 'Hypnogram');
  expect(plot, findsOneWidget);
  await t.tapAt(t.getCenter(plot));
  await t.pumpAndSettle();
}

void main() {
  testWidgets('B2: the legend names skin temp as relative, with no numbers',
      (t) async {
    await _pump(t, scale: 1);
    expect(find.text('Skin temp · relative'), findsOneWidget);
    expect(find.textContaining('-619'), findsNothing);
    expect(find.textContaining('96.2'), findsNothing);
    expect(
        find.byWidgetPredicate(
            (w) => w is Text && RegExp(r'Skin temp.*\d').hasMatch(w.data ?? '')),
        findsNothing,
        reason: 'raw ADC deltas are not a range anyone can read');
  });

  testWidgets('B2: scrubbing shows no skin-temp number', (t) async {
    await _pump(t, scale: 1);
    await _scrubMiddle(t);
    expect(find.text('17.5 br/min'), findsWidgets, reason: 'scrub reached');
    expect(find.textContaining('82.5'), findsNothing);
    expect(find.text('82.50'), findsNothing);
  });

  testWidgets('B3: readout values never touch at 390 pt and 1.3x text',
      (t) async {
    await _pump(t, scale: 1.3);
    await _scrubMiddle(t);
    final panels = find.byKey(ChartKeyReadout.panelKey);
    expect(panels, findsNWidgets(2));
    for (final panel in panels.evaluate()) {
      final scope = find.byWidget(panel.widget);
      expect(find.descendant(of: scope, matching: find.text('17.5 br/min')),
          findsOneWidget);
      final texts = find
          .descendant(of: scope, matching: find.byType(Text))
          .evaluate()
          .map((e) => t.getRect(find.byWidget(e.widget)))
          .toList();
      for (var i = 0; i < texts.length; i++) {
        for (var j = i + 1; j < texts.length; j++) {
          final a = texts[i], b = texts[j];
          final sameLine = a.top < b.bottom && b.top < a.bottom;
          if (!sameLine) continue;
          final gap = a.left < b.left ? b.left - a.right : a.left - b.right;
          expect(gap, greaterThanOrEqualTo(4),
              reason: 'readout items collide: $a vs $b');
        }
      }
    }
  });
}
