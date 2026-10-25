// RED tests: Home card round 3 (Sol r2: 4 P2).
//  1. The recovery copy must work on the REAL production driver shape. The
//     analytics Driver.toJson is {label, contribution, detail} with detail
//     PROSE ("lifting your score" / "dragging your score down") and no numeric
//     z. So the copy is built from label + contribution sign; a number is added
//     only when a numeric z is actually present in `detail`.
//       no numbers: "Pulling it down: HRV, Skin temperature."  (one: "Pulling it down: HRV.")
//       numbers:    "Biggest drag: HRV -2.0, Resting heart rate -1.0 (how far each sits from your usual)."
//  2. Ranked by negative weighted contribution (largest drag first), not by z.
//  3. (superseded by round 4) The since caption row overlaps no dial and the dial
//     below still opens its ring; the held tap target lives in the r4 test.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/models/metric.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import 'support/as_of_recalc_fakes.dart';

final _now = DateTime(2026, 10, 4, 15);

/// The exact shape HomeData.load reads: getInsights()['readiness_glassbox'],
/// each driver as analytics Driver.toJson emits it.
class _ProdRepo extends HomeRepo {
  _ProdRepo(this.drivers) : super(homeBundle(readiness: 22));
  final List<Map<String, dynamic>> drivers;
  @override
  Future<Map<String, dynamic>> getInsights() async => {
        'readiness_glassbox': {
          'score': 22.0,
          'breakdown': const [],
          'drivers': drivers,
          'narrative': '',
          'inputs_used': 3,
        },
      };
}

Map<String, dynamic> _drv(String label, double c, String detail) =>
    {'label': label, 'contribution': c, 'detail': detail};
const _drag = 'dragging your score down';
const _lift = 'lifting your score';

Future<HomeData> _loaded(WidgetTester t, List<Map<String, dynamic>> drivers) async {
  final d = await t.runAsync(() => HomeData.load(_ProdRepo(drivers), null));
  return d!;
}

void _surface(WidgetTester t) {
  t.view.devicePixelRatio = 1;
  t.view.physicalSize = const Size(390, 3200);
  addTearDown(t.view.reset);
}

Future<void> _rings(WidgetTester t, HomeData d,
    {DateTime? since, String? hold, void Function(HomeRingKind)? onOpen}) async {
  _surface(t);
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    home: Scaffold(
        body: SingleChildScrollView(
            child: RingTrio(
                d: d, now: _now, since: since, holdText: hold, onOpen: onOpen))),
  ));
  await t.pump();
}

HomeData _syn({List<Map<String, dynamic>> drivers = const []}) => HomeData(
      dayId: '2026-10-04',
      readiness: const Metric(value: 22, confidence: .8, tier: MetricTier.high),
      sleepMin: const Metric(value: 450, confidence: .8, tier: MetricTier.high),
      sleepNeedMin: const Metric(value: 480, confidence: .8, tier: MetricTier.high),
      strain: const Metric(value: 5, confidence: .8, tier: MetricTier.high),
      drivers: drivers,
    );

final _body = find.byKey(const ValueKey('home-why-body:recovery'));
final _line = find.byKey(const ValueKey('home-since-line'));
final _dials = find.byWidgetPredicate((w) => w.runtimeType.toString() == '_Dial');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('recovery copy on the production driver shape (via HomeData.load)', () {
    testWidgets('two drags: named by label, no invented number', (t) async {
      final d = await _loaded(t, [
        _drv('hrv', -6.2, _drag),
        _drv('rhr', 3.1, _lift),
        _drv('temp', -1.4, _drag),
      ]);
      expect(d.drivers.length, 3, reason: 'the loader passed them through');
      await _rings(t, d);
      expect(t.widget<Text>(_body).data, 'Pulling it down: HRV, Skin temperature.');
    });

    testWidgets('one drag', (t) async {
      final d = await _loaded(t, [_drv('rhr', -3.1, _drag), _drv('hrv', 2.0, _lift)]);
      await _rings(t, d);
      expect(t.widget<Text>(_body).data, 'Pulling it down: Resting heart rate.');
    });

    testWidgets('only lifts, or none named: the plain score', (t) async {
      await _rings(t, await _loaded(t, [_drv('hrv', 2.0, _lift)]));
      expect(t.widget<Text>(_body).data, 'Recovery 22 of 100');
      await _rings(t, await _loaded(t, const []));
      expect(t.widget<Text>(_body).data, 'Recovery 22 of 100');
    });
  });

  group('ranking is by weighted contribution, not by z', () {
    Map<String, dynamic> z(String l, double c, double zz) =>
        _drv(l, c, 'oriented robust-z (median+MAD)=$zz');

    testWidgets('HRV z=-2 (bigger drag) outranks temp z=-3 (smaller drag)',
        (t) async {
      await _rings(
          t,
          _syn(drivers: [
            z('temp', -1.0, -3.0),
            z('hrv', -6.0, -2.0),
            z('rhr', -3.0, -1.0),
          ]));
      expect(t.widget<Text>(_body).data,
          'Biggest drag: HRV -2.0, Resting heart rate -1.0 (how far each sits from your usual).');
    });

    testWidgets('without numbers the same order holds', (t) async {
      await _rings(
          t,
          _syn(drivers: [
            _drv('temp', -1.0, _drag),
            _drv('hrv', -6.0, _drag),
            _drv('rhr', -3.0, _drag),
          ]));
      expect(t.widget<Text>(_body).data, 'Pulling it down: HRV, Resting heart rate.');
    });
  });

  group('the held since line is a real tap target', () {
    const why = 'Updated 16:08 · recordings through 16:04 · Waiting for sync to finish';
    final since = DateTime(2026, 10, 4, 16, 4);

    // Round 4 moved the 44 pt target out of RingTrio (test/ui2_home_card_r4_test.dart
    // taps its edges). In RingTrio the caption is only the visual row.
    testWidgets('RingTrio draws the caption as a plain row above the dials, full width',
        (t) async {
      await _rings(t, _syn(), since: since, hold: why);
      final line = t.getRect(_line);
      final card = t.getRect(find.byType(RingTrio));
      expect(line.width, greaterThanOrEqualTo(card.width - 32));
      expect(find.descendant(of: _line, matching: find.byType(Pressable)), findsNothing);
      for (var i = 0; i < 3; i++) {
        expect(line.overlaps(t.getRect(_dials.at(i))), isFalse, reason: 'dial $i');
      }
    });

    testWidgets('the dial below still opens its ring and not the explanation',
        (t) async {
      final opened = <HomeRingKind>[];
      await _rings(t, _syn(), since: since, hold: why, onOpen: opened.add);
      await t.tapAt(t.getRect(_dials.at(2)).topCenter + const Offset(0, 2));
      await t.pump(const Duration(milliseconds: 400));
      expect(opened, [HomeRingKind.sleep]);
      expect(find.text(why), findsNothing);
    });

    testWidgets('not held: the line is plain (no tap target)', (t) async {
      await _rings(t, _syn(), since: since);
      expect(find.descendant(of: _line, matching: find.byType(Pressable)), findsNothing);
    });
  });
}
