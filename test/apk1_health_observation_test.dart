import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import 'backup/backup_support.dart';
import 'support/apk1_harness.dart';
import 'support/apk1_keys.dart';
import 'support/pin_tz.dart';

final _observation = find.byKey(const ValueKey<String>(apk1ObservationRow));
final _rows = find.descendant(of: apk1Rings,
    matching: find.byWidgetPredicate((w) => w.key is ValueKey<String> &&
        (w.key! as ValueKey<String>).value.startsWith('home-why:')));
const _redStatus = 'Recent nights add up to a raised resting heart rate';

Future<void> _home(WidgetTester t, HomeData data, {double scale = 1}) async {
  // A tall viewport builds the whole ring item; the 800pt layout checks below
  // separately exercise its real scrolling and clipping at phone height.
  await apk1Mount(t, height: 4000, scale: scale,
      source: HomeScreen(data: data, now: apk1Now));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  pinProcessTimeZone();
  late BackupEnv env;
  setUpAll(() async => env = await apk1Environment('apk1_observation.db'));
  tearDownAll(() => env.dispose());
  setUp(apk1ClearPrefs);

  apk1Test('the observation ranks before recovery and displaces the third pressing reason', (t) async {
    await _home(t, apk1Home());
    expect(_observation, findsOneWidget);
    expect(find.descendant(of: apk1Rings, matching: _observation), findsOneWidget);
    expect(_rows, findsNWidgets(2), reason: 'the observation consumes one of the two pressing slots');
    expect(_rows.evaluate().map((e) => (e.widget.key! as ValueKey<String>).value),
        [apk1ObservationRow, 'home-why:recovery']);
    expect(find.byKey(const ValueKey<String>('home-why:sleep')), findsNothing);
    expect(find.byKey(const ValueKey<String>('home-why:strain')), findsNothing);
    expect(find.byType(Observation), findsNothing, reason: 'the standalone observation card is removed');
    expect(find.text(_redStatus), findsOneWidget);
    expect(t.getTopLeft(_observation).dy,
        lessThan(t.getTopLeft(find.byKey(const ValueKey<String>('home-why:recovery'))).dy));
  });

  apk1Test('a recent amber observation remains actionable without any ring metrics', (t) async {
    await _home(t, apk1Home(observation: 'amber', bare: true));
    expect(find.descendant(of: apk1Rings, matching: _observation), findsOneWidget);
    expect(_rows, findsOneWidget);
    expect(find.text('Last night sat outside your normal range'), findsOneWidget);
    expect(find.byType(Observation), findsNothing);
    // No readiness, scored sleep or strain is invented to justify the row.
    final d = t.widget<RingTrio>(find.byType(RingTrio)).d;
    expect(d.readiness.value, isNull);
    expect(d.sleepMin.value, isNull);
    expect(d.strain.value, isNull);
    await t.tap(_observation);
    await apk1Settle(t);
    expect(find.byType(MetricDetail), findsOneWidget);
    expect(t.widget<MetricDetail>(find.byType(MetricDetail)).metricKey, 'resting_hr');
  });

  apk1Test('a fresh observation disappears when absent, green, stale or undated and frees its slot', (t) async {
    await _home(t, apk1Home());
    expect(_observation, findsOneWidget, reason: 'positive control for the freshness and absence checks');
    for (final (state, day) in <(String?, String?)>[
      (null, apk1Day), ('green', apk1Day), ('red', '2026-09-20'), ('amber', null),
    ]) {
      // Dispose Home state between distinct repository payloads.
      await t.pumpWidget(const SizedBox());
      await _home(t, apk1Home(observation: state, observedDay: day));
      expect(_observation, findsNothing, reason: 'state=$state day=$day');
      expect(find.text(_redStatus), findsNothing);
      expect(_rows.evaluate().map((e) => (e.widget.key! as ValueKey<String>).value),
          ['home-why:recovery', 'home-why:sleep'], reason: 'both ordinary slots return');
      expect(find.byType(Observation), findsNothing);
    }
  });

  for (final scale in [1.0, 3.1]) {
    apk1Test('the ring observation is spoken once, fits 360pt and opens its evidence at $scale', (t) async {
      final routes = Apk1Routes();
      await apk1Mount(t, scale: scale, routes: routes,
          source: HomeScreen(data: apk1Home(), now: apk1Now));
      await apk1Reveal(t, _observation);
      expect(find.descendant(of: apk1Rings, matching: _observation), findsOneWidget);
      expect(_rows, findsNWidgets(2));
      expect(apk1Spoken(t).join('\n').split(_redStatus).length - 1, 1,
          reason: 'the same status must not be voiced by a card and its row');
      final rect = t.getRect(_observation);
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(360));
      expect(rect.height, greaterThanOrEqualTo(44));
      expect(t.takeException(), isNull, reason: 'no overflow at 360pt / $scale');
      await t.tap(_observation);
      await apk1Settle(t);
      expect(routes.routes, hasLength(2), reason: 'evidence is still a metric detail, not a domain root');
      expect(find.byType(MetricDetail), findsOneWidget);
      expect(t.widget<MetricDetail>(find.byType(MetricDetail)).metricKey, 'resting_hr');
      await t.binding.handlePopRoute();
      await apk1Settle(t);
      expect(_observation, findsOneWidget);
      expect(apk1Selected(t), ShellDomain.today.index);
      expect(t.takeException(), isNull);
    });
  }
}
