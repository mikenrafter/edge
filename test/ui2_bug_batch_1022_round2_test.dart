// RED (Sol r1 P2s #3 and #4 on the 2026-10-22 bug batch).
//
// #3 B2: the Overnight signals chart WITHOUT sleep bounds (no onset_ts /
//    wake_ts on the night) builds numeric ChartKeys for every lane, so its key
//    row printed the skin-temp ADC delta. No number for skin temp on either
//    chart path.
// #4 B7: the Workout screen still turned an unknown session type into display
//    text: History rows read "Other" / "Kite Surfing 2" and the morning-after
//    rows printed the slug. A genuinely unknown type is the localized "Workout".
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/units_controller.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import 'support/explorer_harness.dart';
import 'support/older_version_fixtures.dart';

final _t0 = DateTime(2026, 5, 19, 23, 7).millisecondsSinceEpoch ~/ 1000;

class _WorkoutRepo extends OlderRepo {
  @override
  Future<Map<String, dynamic>> getWorkouts({String range = 'month'}) async {
    final now = DateTime.now();
    int at(int back) => DateTime(now.year, now.month, now.day - back, 9)
            .millisecondsSinceEpoch ~/
        1000;
    return {
      'workouts': [
        for (final (i, type) in ['other', 'kite_surfing_2', 'running'].indexed)
          {
            'id': 'w$i',
            'type': type,
            'start_ts': at(i + 1),
            'end_ts': at(i + 1) + 3600,
            'duration_min': 60,
          },
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> getInsights() async => {
        'session_cost': {
          'rhr': {
            'value': [
              for (final type in ['other', 'kite_surfing_2'])
                {
                  'session_type': type,
                  'n': 14,
                  'median_delta': 5.2,
                  'exceeds_mdc': true,
                },
            ],
          },
        },
      };
}

void main() {
  setUpAll(() async {
    await initPrefs();
    await loadType();
  });
  setUp(clearPrefs);

  testWidgets('B2: with no sleep bounds the key row still prints no skin-temp '
      'number', (t) async {
    t.view.physicalSize = const Size(390 * 3, 5200 * 3);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    const n = 97;
    List<Map<String, num>> lane(num Function(int i) v) =>
        [for (var i = 0; i < n; i++) {'t': _t0 + i * 300, 'v': v(i)}];
    final data = SleepData(
      day: '2026-05-20',
      // No onset_ts / wake_ts: the chart path without a linked hypnogram.
      night: const {'duration_min': 443, 'in_bed_min': 486, 'efficiency': .91},
      timeline: {
        'hr': lane((i) => 60 + i % 7),
        'hrv': lane((i) => 50 + i % 5),
        'resp': lane((i) => 17.5),
        'skin_temp': lane((i) => i == n - 1 ? 96.2 : 82.5),
      },
    );
    await t.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: buildTheme(Brightness.dark),
      home: SleepDetail(data: data),
    ));
    await t.pumpAndSettle();
    final chart =
        find.byWidgetPredicate((w) => w is ChartScrub && w.label == 'Through the night');
    expect(chart, findsOneWidget, reason: 'the unlinked chart path is on screen');
    // At rest the readout shows the latest point; then scrub the middle.
    expect(find.textContaining('96.2'), findsNothing);
    await t.tapAt(t.getCenter(chart));
    await t.pumpAndSettle();
    expect(find.textContaining('17.5'), findsWidgets, reason: 'scrub reached');
    expect(find.textContaining('82.5'), findsNothing);
    expect(find.textContaining('96.2'), findsNothing);
  });

  testWidgets('B7: Workout history and morning-after never print a type slug',
      (t) async {
    t.view.physicalSize = const Size(390 * 3, 4000 * 3);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    final app = AppState.forTesting()..repo = _WorkoutRepo();
    addTearDown(app.dispose);
    await t.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: buildTheme(Brightness.dark),
      home: MultiProvider(
          providers: [
            ChangeNotifierProvider<AppState>.value(value: app),
            ChangeNotifierProvider<UnitsController>.value(
                value: UnitsController.seed(UnitSystem.metric)),
          ],
          child: const Scaffold(body: WorkoutScreen())),
    ));
    for (var i = 0; i < 40; i++) {
      await t.pump(const Duration(milliseconds: 25));
    }
    await t.tap(find.text('History'));
    for (var i = 0; i < 40; i++) {
      await t.pump(const Duration(milliseconds: 25));
    }
    expect(find.text('Running'), findsWidgets, reason: 'a known type keeps its name');
    for (final raw in ['Other', 'other', 'Kite Surfing 2', 'kite_surfing_2', 'kite surfing 2']) {
      // Exact match: 'other' is also an ordinary word in prose.
      expect(find.text(raw), findsNothing, reason: raw);
    }
    expect(find.text('Workout'), findsNWidgets(2), reason: 'one history row each');
    expect(find.text('After Workout'), findsNWidgets(2));
  });
}
