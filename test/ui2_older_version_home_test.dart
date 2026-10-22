// RULES B.2 on Home: the strain ring, the active-energy tile (active and total
// flagged independently), and a PAST day loaded through HomeData.loadForDay.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/models/metric.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import 'support/older_version_fixtures.dart';

const _cur = Metric(value: 5.0, confidence: .8, tier: MetricTier.estimate);
const _old = Metric(
    value: 8.4,
    confidence: .8,
    tier: MetricTier.estimate,
    fromOlderVersion: 104,
    olderVersionReason: kReasonRaw);
const _oldKcal = Metric(
    value: 420,
    confidence: .8,
    tier: MetricTier.estimate,
    fromOlderVersion: 104,
    olderVersionReason: kReasonRaw);
const _curKcal = Metric(value: 2100, confidence: .8, tier: MetricTier.estimate);
const _rec = Metric(value: 82, confidence: .8, tier: MetricTier.high);

Future<void> _rings(WidgetTester t, HomeData d) async {
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    home: Scaffold(
        body: SingleChildScrollView(
            child: RingTrio(d: d, now: DateTime(2026, 10, 4, 15)))),
  ));
  await t.pump();
}

Future<void> _home(WidgetTester t, HomeData d) async {
  t.view.physicalSize = const Size(390 * 3, 2400 * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    home: Scaffold(body: HomeScreen(data: d, hour: 9)),
  ));
  await t.pump(const Duration(milliseconds: 200));
}

void main() {
  group('strain ring', () {
    testWidgets('older value: number, asterisk, spoken, tap reveals the note',
        (t) async {
      final h = t.ensureSemantics();
      await _rings(
          t, const HomeData(dayId: '2026-10-04', readiness: _rec, strain: _old));
      expect(find.text('8.4'), findsOneWidget);
      expect(olderMark('strain'), findsOneWidget);
      expect(find.bySemanticsLabel(kSpoken), findsWidgets);
      await t.tap(olderMark('strain'));
      await t.pumpAndSettle();
      expect(find.text(kNoteV104Reason), findsOneWidget);
      h.dispose();
    });

    testWidgets('current value: no marker anywhere', (t) async {
      final h = t.ensureSemantics();
      await _rings(
          t, const HomeData(dayId: '2026-10-04', readiness: _rec, strain: _cur));
      expect(find.text('5.0'), findsOneWidget);
      expect(anyOlderMarker(), findsNothing);
      expect(find.bySemanticsLabel(kSpoken), findsNothing);
      h.dispose();
    });

    testWidgets('absent value stays a gap and never takes the marker',
        (t) async {
      // A flag with no value behind it is not a value.
      await _rings(
          t,
          const HomeData(
              dayId: '2026-10-04',
              readiness: _rec,
              strain: Metric(fromOlderVersion: 104)));
      expect(anyOlderMarker(), findsNothing);
      expect(find.text('*'), findsNothing);
    });
  });

  // The tile is the card that prints the two calorie numbers. Markers anywhere
  // else on Home (the ring card prints neither) do not count.
  Finder tile() => find.widgetWithText(SignalCard, 'Active energy');
  Finder inTile(String id) =>
      find.descendant(of: tile(), matching: olderMark(id));
  Finder inRings(String id) =>
      find.descendant(of: find.byType(RingTrio), matching: olderMark(id));

  group('active-energy tile: active and total flagged independently', () {
    testWidgets('only the active value older', (t) async {
      await _home(t,
          const HomeData(dayId: '2026-10-04', calories: _oldKcal, caloriesTotal: _curKcal));
      expect(find.descendant(of: tile(), matching: find.text('420')),
          findsOneWidget);
      expect(inTile('calories'), findsOneWidget);
      expect(inTile('calories_total'), findsNothing);
      expect(inRings('calories'), findsNothing);
      expect(inRings('calories_total'), findsNothing);
    });

    testWidgets('only the total older', (t) async {
      const total = Metric(
          value: 2100,
          confidence: .8,
          tier: MetricTier.estimate,
          fromOlderVersion: 104,
          olderVersionReason: kReasonRaw);
      await _home(
          t,
          const HomeData(
              dayId: '2026-10-04',
              calories: Metric(value: 420, confidence: .8, tier: MetricTier.estimate),
              caloriesTotal: total));
      expect(inTile('calories'), findsNothing);
      expect(inTile('calories_total'), findsOneWidget);
      expect(inRings('calories_total'), findsNothing);
    });

    testWidgets('both older: two marks in the tile; tapping each reveals its '
        'own note', (t) async {
      const total = Metric(
          value: 2100,
          confidence: .8,
          tier: MetricTier.estimate,
          fromOlderVersion: 103,
          olderVersionReason: 'need_input:name=weight_kg');
      await _home(t,
          const HomeData(dayId: '2026-10-04', calories: _oldKcal, caloriesTotal: total));
      expect(inTile('calories'), findsOneWidget);
      expect(inTile('calories_total'), findsOneWidget);
      await t.tap(inTile('calories_total'));
      await t.pumpAndSettle();
      expect(
          find.text('From an older calculation (v103): '
              'This metric needs your weight, which is not on file.'),
          findsOneWidget);
      await t.tap(find.text('OK'));
      await t.pumpAndSettle();
      await t.tap(inTile('calories'));
      await t.pumpAndSettle();
      expect(find.text(kNoteV104Reason), findsOneWidget);
    });

    testWidgets('both current: no marker; absent: dash, no marker', (t) async {
      await _home(t,
          const HomeData(dayId: '2026-10-04', calories: Metric(value: 420, confidence: .8), caloriesTotal: _curKcal));
      expect(anyOlderMarker(), findsNothing);
      await _home(t, const HomeData(dayId: '2026-10-04'));
      expect(anyOlderMarker(), findsNothing);
    });

    testWidgets('the tile is spoken as older', (t) async {
      final h = t.ensureSemantics();
      await _home(t,
          const HomeData(dayId: '2026-10-04', calories: _oldKcal, caloriesTotal: _curKcal));
      expect(
          find.descendant(of: tile(), matching: find.bySemanticsLabel(kSpoken)),
          findsWidgets);
      h.dispose();
    });
  });

  group('a past day through HomeData.loadForDay', () {
    final day = dayLabelOf(DateTime.now().subtract(const Duration(days: 1)));

    test('the provenance map of getDayStrain survives into the Metrics',
        () async {
      final repo = _PastRepo(strain: {
        'strain': 8.4,
        'steps': 2500,
        'calories': 420,
        'calories_total': 2000,
        'from_older_version': {
          'strain': older(),
          'calories': older(v: 103, reason: 'need_input:name=weight_kg'),
        },
      });
      final d = await HomeData.loadForDay(repo, day);
      expect(d.strain.value, 8.4);
      expect(d.strain.fromOlderVersion, 104);
      expect(d.strain.olderVersionReason, kReasonRaw);
      expect(d.calories.fromOlderVersion, 103);
      expect(d.calories.olderVersionReason, 'need_input:name=weight_kg');
      // Total is current: no flag, and the others are not painted by it.
      expect(d.caloriesTotal.value, 2000);
      expect(d.caloriesTotal.fromOlderVersion, isNull);
      expect(d.steps.fromOlderVersion, isNull);
    });

    test('a day with no provenance map has no flag on any value', () async {
      final repo = _PastRepo(
          strain: {'strain': 9.9, 'calories': 300, 'calories_total': 2000});
      final d = await HomeData.loadForDay(repo, day);
      expect(d.strain.fromOlderVersion, isNull);
      expect(d.calories.fromOlderVersion, isNull);
      expect(d.caloriesTotal.fromOlderVersion, isNull);
    });

    test('an absent value is not given a flag by the map', () async {
      final repo = _PastRepo(strain: {
        'strain': null,
        'from_older_version': {'strain': older()},
      });
      final d = await HomeData.loadForDay(repo, day);
      expect(d.strain.value, isNull);
      expect(d.strain.fromOlderVersion, isNull);
    });

    testWidgets('stepping to the day shows the ring asterisk', (t) async {
      t.view.physicalSize = const Size(390 * 3, 2400 * 3);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      app.repo = _PastRepo(strain: {
        'strain': 8.4,
        'calories': 420,
        'calories_total': 2000,
        'from_older_version': {'strain': older(), 'calories': older()},
      });
      await t.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        home: ChangeNotifierProvider<AppState>.value(
          value: app,
          child: const Scaffold(body: HomeScreen(hour: 9)),
        ),
      ));
      for (var i = 0; i < 40; i++) {
        await t.pump(const Duration(milliseconds: 20));
      }
      expect(anyOlderMarker(), findsNothing, reason: 'today is current');
      await t.tap(find.bySemanticsLabel('Previous day'));
      for (var i = 0; i < 40; i++) {
        await t.pump(const Duration(milliseconds: 20));
      }
      expect(find.text('8.4'), findsOneWidget);
      expect(olderMark('strain'), findsOneWidget);
      expect(inTile('calories'), findsOneWidget);
      expect(inTile('calories_total'), findsNothing);
    });
  });
}

class _PastRepo extends LocalRepository {
  final Map<String, dynamic> strain;
  _PastRepo({required this.strain});
  @override
  Future<Map<String, dynamic>> getToday() async => {
        'daily': {
          'readiness': {'value': 70, 'confidence': .8, 'tier': 'HIGH'},
          'strain': {'value': 5.0, 'confidence': .8, 'tier': 'ESTIMATE'},
        },
        'sleep': {
          'duration_min': {'value': 400, 'confidence': .8, 'tier': 'HIGH'},
        },
        'status': {'today_day': todayLabel()},
      };
  @override
  Future<Map<String, dynamic>> getInsights() async => const {};
  @override
  Future<Map<String, dynamic>> getProfile() async => const {'name': 'Alex'};
  @override
  Future<List<String>> availableDays() async => [
        todayLabel(),
        dayLabelOf(DateTime.now().subtract(const Duration(days: 1)))
      ];
  @override
  Future<Map<String, dynamic>> getDayOverview(String date) async =>
      {'readiness': 42, 'resting_hr': 60};
  @override
  Future<Map<String, dynamic>> getDayStrain(String date) async => strain;
  @override
  Future<Map<String, dynamic>> getDaySleepV2(String date) async =>
      {'has_sleep': true, 'duration_min': 250};
  @override
  Future<SleepDetailBundle> getSleepDetailBundle(String day,
          {required List<String> chartKeys,
          required int windowDays,
          String? before}) async =>
      SleepDetailBundle(
          night: await getDaySleepV2(day),
          timeline: const {},
          insights: const {},
          charts: const {},
          windows: const []);
}
