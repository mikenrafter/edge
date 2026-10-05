// 8AH, RED. The Explorer remembers the last picks and range, the way the
// Haptics / Gestures tabs remember theirs (Prefs, a `ui.explore_*` key,
// restored in initState with no flash of the default).
//
// ASSUMED API: support.dart.
//   kExploreMetricsPref  'ui.explore_metrics'   daily picks, 'hrv,resting_hr'
//   kExploreIntradayPref 'ui.explore_intraday'  day picks, 'hr,hrv'
//   kExploreRangePref    'ui.explore_range'     'd7' | 'd30' | 'm6' | 'y1' |
//                                               'custom:YYYY-MM-DD..YYYY-MM-DD'
//   kExploreScalePref    'ui.explore_scale'     'daily' | 'day'
//   kExploreZPref        'ui.explore_z'         metrics in z mode, 'resting_hr'
//   The chosen DAY is not remembered. Garbage in a pref is ignored, never thrown.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/screens/explorer.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart' show specOf;

import 'support/explorer_harness.dart';

String _back(int back) {
  final d = DateTime(2026, 10, 4 - back);
  return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

ExplorerRepo _repo() => ExplorerRepo(charts: {
      specOf('resting_hr').chartKey: [
        for (var i = 0; i < 40; i++) pt(_back(i), 50.0 + (i % 6)),
      ],
      specOf('hrv').chartKey: [for (var i = 0; i < 40; i++) pt(_back(i), 60.0 + (i % 4))],
      specOf('steps').chartKey: [for (var i = 0; i < 40; i++) pt(_back(i), 8000.0 + i)],
    });

Future<void> _remount(WidgetTester t, ExplorerRepo repo) async {
  await t.pumpWidget(const SizedBox());
  await pumpExplorer(t, repo);
}

String _p(String k) => Prefs.getString(k, '');

void main() {
  setUpAll(() async {
    await initPrefs();
  });
  setUp(clearPrefs);

  testWidgets('opening and looking writes nothing', (t) async {
    await pumpExplorer(t, _repo());
    for (final k in kPrefKeys) {
      expect(_p(k), '', reason: k);
    }
  });

  testWidgets('picks, range and z mode are written as they change', (t) async {
    await pumpExplorer(t, _repo());
    await tapKey(t, 'explore-pick:hrv');
    await tapKey(t, 'explore-pick:resting_hr');
    expect(_p(kExploreMetricsPref), 'hrv,resting_hr');
    await tapKey(t, 'explore-range:d7');
    expect(_p(kExploreRangePref), 'd7');
    await tapKey(t, 'explore-z:resting_hr');
    expect(_p(kExploreZPref), 'resting_hr');
    await tapKey(t, 'explore-chip:hrv');
    expect(_p(kExploreMetricsPref), 'resting_hr');
  });

  testWidgets('a reopened Explorer has the same chips, range and z mode',
      (t) async {
    final repo = _repo();
    await pumpExplorer(t, repo);
    await tapKey(t, 'explore-pick:hrv');
    await tapKey(t, 'explore-pick:resting_hr');
    await tapKey(t, 'explore-range:d7');
    await tapKey(t, 'explore-z:resting_hr');
    final z = [for (final r in plotLine(t, 'resting_hr').runs) for (final p in r) p.y];

    await _remount(t, repo);
    expect(chip('hrv'), findsOneWidget);
    expect(chip('resting_hr'), findsOneWidget);
    expect(t.getTopLeft(chip('hrv')).dy <= t.getTopLeft(chip('resting_hr')).dy, isTrue);
    expect(plotLine(t, 'hrv').runs.last.last.at, closeTo(6.5 / 7, 1e-9),
        reason: 'the 7 day grid, not the 30 day default');
    expect([for (final r in plotLine(t, 'resting_hr').runs) for (final p in r) p.y], z,
        reason: 'z mode came back with it');
  });

  testWidgets('the first frame already has the remembered chips (no flash of the default)',
      (t) async {
    Prefs.setString(kExploreMetricsPref, 'steps');
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(390, 3000);
    addTearDown(t.view.reset);
    final app = AppState.forTesting()..repo = _repo();
    addTearDown(app.dispose);
    await t.pumpWidget(providers(
        app, ListView(children: [ExplorerView(today: kToday)])));
    // The very first frame, before any read has had a chance to finish.
    expect(chip('steps'), findsOneWidget);
  });

  testWidgets('the day scale has its own memory, and the scale itself is kept',
      (t) async {
    final repo = _repo();
    await pumpExplorer(t, repo);
    await tapKey(t, 'explore-pick:hrv');
    await tapKey(t, 'explore-scale:day');
    await tapKey(t, 'explore-pick:hr');
    await tapKey(t, 'explore-pick:activity');
    expect(_p(kExploreIntradayPref), 'hr,activity');
    expect(_p(kExploreMetricsPref), 'hrv', reason: 'daily picks untouched');
    expect(_p(kExploreScalePref), 'day');

    await _remount(t, repo);
    expect(chip('hr'), findsOneWidget);
    expect(chip('activity'), findsOneWidget);
    await tapKey(t, 'explore-scale:daily');
    expect(chip('hrv'), findsOneWidget);
    expect(_p(kExploreScalePref), 'daily');
  });

  testWidgets('the chosen day is not remembered: a reopened day view is today',
      (t) async {
    final repo = _repo();
    await pumpExplorer(t, repo);
    await tapKey(t, 'explore-scale:day');
    await tapKey(t, 'explore-pick:hr');
    await tapKey(t, 'explore-day-prev');
    expect(repo.timelineCalls.last, '2026-10-03');
    await _remount(t, repo);
    await settle(t);
    expect(repo.timelineCalls.last, kToday);
  });

  testWidgets('a remembered custom range comes back as that span', (t) async {
    final repo = _repo();
    Prefs.setString(kExploreRangePref, 'custom:2026-09-25..2026-10-04');
    Prefs.setString(kExploreMetricsPref, 'hrv');
    await pumpExplorer(t, repo);
    expect(plotLine(t, 'hrv').runs.last.last.at, closeTo(9.5 / 10, 1e-9));
  });

  group('whatever is stored is distrusted', () {
    testWidgets('unknown and repeated keys are dropped, more than 4 are cut to 4',
        (t) async {
      Prefs.setString(
          kExploreMetricsPref, 'nope,hrv,hrv,resting_hr,steps,readiness,stress');
      await pumpExplorer(t, _repo());
      for (final k in ['hrv', 'resting_hr', 'steps', 'readiness']) {
        expect(chip(k), findsOneWidget, reason: k);
      }
      expect(chip('stress'), findsNothing);
      expect(chip('nope'), findsNothing);
    });

    testWidgets('a remembered metric that may no longer be charted is dropped',
        (t) async {
      Prefs.setString(kExploreMetricsPref, 'skin_temp,hrv');
      await pumpExplorer(t, _repo());
      expect(chip('skin_temp'), findsNothing);
      expect(chip('hrv'), findsOneWidget);
    });

    testWidgets('an unreadable range falls back to 30 days', (t) async {
      Prefs.setString(kExploreRangePref, 'custom:garbage');
      Prefs.setString(kExploreMetricsPref, 'hrv');
      await pumpExplorer(t, _repo());
      expect(plotLine(t, 'hrv').runs.last.last.at, closeTo(29.5 / 30, 1e-9));
    });

    testWidgets('z remembered for a metric that has no baseline is ignored',
        (t) async {
      Prefs.setString(kExploreZPref, 'readiness');
      Prefs.setString(kExploreMetricsPref, 'readiness');
      final repo = ExplorerRepo(charts: {
        specOf('readiness').chartKey: [for (var i = 0; i < 20; i++) pt(_back(i), 60.0 + i)],
      });
      await pumpExplorer(t, repo);
      expect(find.byKey(const ValueKey('explore-z-reason:readiness')), findsOneWidget);
      final ys = [for (final r in plotLine(t, 'readiness').runs) for (final p in r) p.y];
      expect(ys.reduce((a, b) => a < b ? a : b), 0.0,
          reason: 'drawn min..max, as the toggle cannot be on');
    });
  });
}
