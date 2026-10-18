// RED tests: the night path of deriveDayBundle computes the CVHR apnea screen
// from an exact CvhrStream (analytics 07d6af0) instead of re-running
// cvhrApneaScreen over the whole night every pass. Mirrors 2919ab89 (hrvFreq /
// RSA) and 1bf0ae22 / 24d8df16 (checkpoint, isolate).
//
// CHOSEN SHAPE
// ------------
// DayCalculationState keeps one CvhrStream next to the night corrector, fed the
// corrector's SETTLED beats only; each pass asks snapshot(tail, artifactFraction).
// It restarts whenever nightRr rebuilds and rides the night part of the
// checkpoint (NightResumePart.cvhr / cvhrFed, encoded by the worker).
//
// Public surface the tests pin:
//   Metric<CvhrResult> DayCalculationState.nightCvhr(double artifactFraction)
//     cvhrApneaScreen(nn, nnTimes, artifactFraction: f) of the LAST nightRr
//     call, bit for bit. The pipeline keeps its 60-beat gate.
//   int get nightCvhrFolded      cumulative settled beats folded (a restart
//     counts its whole settled prefix again): the "no new segment work" counter.
//   int get nightCvhrRestarts    times the stream was started from scratch.
//   NightResumePart.cvhr         the stream's JSON in the night part ('cvhr' key
//     with 'cvhrFed'); null/absent when never asked.
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_analytics/onehz.dart'
    show CalculationMode, RrCorrector, correctRr, cvhrApneaScreen;
import 'package:openstrap_edge/compute/day_calculation_state.dart';
import 'package:openstrap_edge/compute/night_resume_part.dart';
import 'package:openstrap_edge/compute/onehz_pipeline.dart';

import 'support/incremental_day_fixture.dart';

void _expectIdentical(Object? actual, Object? expected, [String path = r'$']) {
  if (expected is double && actual is double) {
    final same = expected.isNaN
        ? actual.isNaN
        : (actual == expected && actual.isNegative == expected.isNegative);
    expect(same, isTrue, reason: '$path: $actual != $expected');
  } else if (expected is Map) {
    expect(actual, isA<Map>(), reason: path);
    final a = actual as Map;
    expect(a.keys.toSet(), expected.keys.toSet(), reason: '$path keys');
    for (final k in expected.keys) {
      _expectIdentical(a[k], expected[k], '$path.$k');
    }
  } else if (expected is List) {
    expect(actual, isA<List>(), reason: path);
    final a = actual as List;
    expect(a.length, expected.length, reason: '$path length');
    for (var i = 0; i < expected.length; i++) {
      _expectIdentical(a[i], expected[i], '$path[$i]');
    }
  } else {
    expect(actual, expected, reason: path);
  }
}

List<double> _dbls(Object? v) =>
    [for (final x in v as List) (x as num).toDouble()];

Map<String, dynamic> _upTo(Map<String, dynamic> full, int beats) {
  final d = copyDay(full);
  d['sleep_rr_ms'] = (d['sleep_rr_ms'] as List).take(beats).toList();
  d['sleep_rr_ts_ms'] = (d['sleep_rr_ts_ms'] as List).take(beats).toList();
  return d;
}

Map<String, dynamic> _from(Map<String, dynamic> full, int skip) {
  final d = copyDay(full);
  d['sleep_rr_ms'] = (d['sleep_rr_ms'] as List).skip(skip).toList();
  d['sleep_rr_ts_ms'] = (d['sleep_rr_ts_ms'] as List).skip(skip).toList();
  return d;
}

({List<double> rr, List<double> ts}) _beats(Map<String, dynamic> d) =>
    (rr: _dbls(d['sleep_rr_ms']), ts: _dbls(d['sleep_rr_ts_ms']));

int _settledOf(List<double> rr, List<double> ts) =>
    RrCorrector().fold(rr, tsMs: ts).nn.length;

void _expectBundleMatchesBatch(
  Map<String, dynamic> input,
  DayCalculationState state,
  CalculationMode mode, {
  String where = '',
}) {
  final oracle = deriveDayBundle(copyDay(input));
  final got = deriveDayBundle(input, state: state, mode: mode);
  _expectIdentical(got['cvhr_apnea'], oracle['cvhr_apnea'], '$where.cvhr_apnea');
  _expectIdentical(got, oracle, where);
}

void _expectDirectMatchesBatch(
  DayCalculationState state,
  List<double> rr,
  List<double> ts, {
  double artifactFraction = 0.05,
}) {
  final got = state.nightRr(rr, ts);
  final want = correctRr(rr, rrTsMs: ts);
  _expectIdentical(
    state.nightCvhr(artifactFraction).toJson((v) => v.toJson()),
    cvhrApneaScreen(want.nn, want.nnTimesMs, artifactFraction: artifactFraction)
        .toJson((v) => v.toJson()),
    'cvhr',
  );
  expect(got.nn.length, want.nn.length);
}

NightResumePart _roundTrip(NightResumePart p) => NightResumePart.fromJson(
    (jsonDecode(utf8.decode(utf8.encode(jsonEncode(p.toJson())))) as Map)
        .cast<String, dynamic>());

void main() {
  final fixtures = {
    'smooth': incrementalDay(seed: 7, nightSeconds: 1500),
    'gaps+artifacts': incrementalDay(seed: 42, gaps: true, nightSeconds: 1500),
  };

  group('growing night: streamed CVHR matches the batch path', () {
    for (final f in fixtures.entries) {
      for (final mode in [CalculationMode.periodicAwake, CalculationMode.forced]) {
        test('${f.key} bundle, $mode', () {
          final full = f.value;
          final total = (full['sleep_rr_ms'] as List).length;
          final state = DayCalculationState();
          final cuts = <int>[70, 90, 91, 92, 183, 300, 301, 640, total - 1, total];
          var lastFolded = 0;
          for (final n in cuts) {
            final input = _upTo(full, n);
            _expectBundleMatchesBatch(input, state, mode, where: 'beats=$n');
            final b = _beats(input);
            expect(state.nightCvhrFolded, _settledOf(b.rr, b.ts),
                reason: 'beats=$n: exactly the settled prefix is folded');
            expect(state.nightCvhrFolded, greaterThanOrEqualTo(lastFolded));
            lastFolded = state.nightCvhrFolded;
          }
          expect(lastFolded, greaterThan(0));
          expect(state.nightCvhrRestarts, 1);
        });
      }
    }

    test('direct nightCvhr over many passes', () {
      final b = _beats(fixtures['gaps+artifacts']!);
      final state = DayCalculationState();
      for (var n = 70; n <= b.rr.length; n += 97) {
        _expectDirectMatchesBatch(state, b.rr.sublist(0, n), b.ts.sublist(0, n),
            artifactFraction: (n % 10) / 100.0);
      }
      expect(state.nightCvhrRestarts, 1);
    });
  });

  group('a pass with no new beats does no new segment work', () {
    test('direct, repeated and from fresh list copies', () {
      final b = _beats(fixtures['smooth']!);
      final state = DayCalculationState();
      _expectDirectMatchesBatch(state, b.rr, b.ts);
      final folded = state.nightCvhrFolded;
      expect(folded, _settledOf(b.rr, b.ts));
      for (var i = 0; i < 3; i++) {
        _expectDirectMatchesBatch(state, [...b.rr], [...b.ts]);
      }
      expect(state.nightCvhrFolded, folded);
      expect(state.nightCvhrRestarts, 1);
    });

    test('bundle pass in a cache-bypassing mode folds nothing new', () {
      final state = DayCalculationState();
      final input = _upTo(fixtures['smooth']!, 500);
      _expectBundleMatchesBatch(input, state, CalculationMode.forced);
      final folded = state.nightCvhrFolded;
      expect(folded, greaterThan(0));
      final again = copyDay(input);
      (again['profile'] as Map)['resting_hr'] = 61;
      _expectBundleMatchesBatch(again, state, CalculationMode.heavy);
      _expectBundleMatchesBatch(again, state, CalculationMode.sleep);
      expect(state.nightCvhrFolded, folded);
      expect(state.nightCvhrRestarts, 1);
    });

    test('growth folds only the newly settled beats', () {
      final b = _beats(fixtures['smooth']!);
      final state = DayCalculationState();
      _expectDirectMatchesBatch(state, b.rr.sublist(0, 400), b.ts.sublist(0, 400));
      _expectDirectMatchesBatch(state, b.rr.sublist(0, 437), b.ts.sublist(0, 437));
      expect(state.nightCvhrFolded,
          _settledOf(b.rr.sublist(0, 437), b.ts.sublist(0, 437)));
    });
  });

  group('a nightRr rebuild restarts the stream and still matches batch', () {
    test('bundle: moved window start, edited beat, shrink', () {
      final full = fixtures['gaps+artifacts']!;
      for (final mode in [CalculationMode.periodicAwake, CalculationMode.forced]) {
        final state = DayCalculationState();
        _expectBundleMatchesBatch(_upTo(full, 600), state, mode, where: 'grow');
        expect(state.nightCvhrRestarts, 1);

        final moved = _from(_upTo(full, 650), 30);
        _expectBundleMatchesBatch(moved, state, mode, where: 'start moved');
        expect(state.nightCvhrRestarts, 2);
        final afterMove = state.nightCvhrFolded;

        final edited = _upTo(full, 650);
        (edited['sleep_rr_ms'] as List)[40] =
            ((edited['sleep_rr_ms'] as List)[40] as num) + 250.0;
        _expectBundleMatchesBatch(edited, state, mode, where: 'edited');
        expect(state.nightCvhrRestarts, 3);
        final eb = _beats(edited);
        expect(state.nightCvhrFolded, afterMove + _settledOf(eb.rr, eb.ts),
            reason: 'a restart folds its whole settled prefix again');

        _expectBundleMatchesBatch(_upTo(full, 300), state, mode, where: 'shrunk');
        expect(state.nightCvhrRestarts, 4);
        _expectBundleMatchesBatch(_upTo(full, 320), state, mode, where: 'regrow');
        expect(state.nightCvhrRestarts, 4);
      }
    });

    test('direct: restart counter follows nightRebuilds', () {
      final b = _beats(fixtures['smooth']!);
      final state = DayCalculationState();
      _expectDirectMatchesBatch(state, b.rr.sublist(0, 600), b.ts.sublist(0, 600));
      _expectDirectMatchesBatch(state, b.rr.sublist(25, 650), b.ts.sublist(25, 650));
      _expectDirectMatchesBatch(state, b.rr.sublist(0, 380), b.ts.sublist(0, 380));
      expect(state.nightCvhrRestarts, 3);
      expect(state.nightCvhrRestarts, state.nightRebuilds);
    });
  });

  group('checkpoint round trip', () {
    final full = fixtures['gaps+artifacts']!;
    final total = (full['sleep_rr_ms'] as List).length;

    test('the night part carries the stream', () {
      final s = DayCalculationState();
      _expectBundleMatchesBatch(_upTo(full, 400), s, CalculationMode.heavy);
      final part = s.exportNight()!;
      expect(part.cvhr, isNotNull);
      expect(part.toJson()['cvhr'], isNotNull);
      expect(_roundTrip(part).cvhr, isNotNull);
    });

    test('restored state continues: identical bundle, no restart, only new beats',
        () {
      final warm = DayCalculationState();
      _expectBundleMatchesBatch(_upTo(full, 400), warm, CalculationMode.heavy);
      final restored = DayCalculationState()
        ..seedNight(_roundTrip(warm.exportNight()!));
      _expectBundleMatchesBatch(_upTo(full, 900), restored, CalculationMode.heavy);
      expect(restored.nightRebuilds, 0);
      expect(restored.nightCvhrRestarts, 0);
      expect(restored.nightCvhrFolded,
          _settledOf(_beats(full).rr.sublist(0, 900), _beats(full).ts.sublist(0, 900)) -
              _settledOf(_beats(full).rr.sublist(0, 400), _beats(full).ts.sublist(0, 400)));
    });

    test('a restart between every pass equals batch', () {
      NightResumePart? carried;
      var restarts = 0;
      for (var n = 150; ; n += 211) {
        n = n > total ? total : n;
        final s = DayCalculationState()..seedNight(carried);
        _expectBundleMatchesBatch(_upTo(full, n), s, CalculationMode.heavy,
            where: 'n=$n');
        restarts += s.nightCvhrRestarts;
        carried = _roundTrip(s.exportNight()!);
        if (n == total) break;
      }
      expect(restarts, 1);
    });

    test('a damaged cvhr payload rebuilds, never wrong output', () {
      final warm = DayCalculationState();
      _expectBundleMatchesBatch(_upTo(full, 400), warm, CalculationMode.heavy);
      final j = _roundTrip(warm.exportNight()!).toJson();
      (j['cvhr'] as Map)['type'] = 'Nope';
      final s = DayCalculationState()
        ..seedNight(NightResumePart.fromJson(j));
      _expectBundleMatchesBatch(_upTo(full, 700), s, CalculationMode.heavy);
    });
  });

  group('isolate hop', () {
    test('state returned from a worker keeps its stream and extends it',
        () async {
      final full = fixtures['gaps+artifacts']!;
      var state = DayCalculationState();
      _expectBundleMatchesBatch(
          _upTo(full, 500), state, CalculationMode.periodicAwake);
      final b500 = _beats(_upTo(full, 500));
      final grown = _upTo(full, 560);
      final captured = state;
      final result = await Isolate.run(() {
        final bundle = deriveDayBundle(grown,
            state: captured, mode: CalculationMode.periodicAwake);
        return (
          bundle: bundle,
          state: captured,
          folded: captured.nightCvhrFolded,
          restarts: captured.nightCvhrRestarts,
        );
      });
      final b560 = _beats(grown);
      expect(state.nightCvhrFolded, _settledOf(b500.rr, b500.ts));
      expect(result.folded, _settledOf(b560.rr, b560.ts));
      expect(result.restarts, 1);
      _expectIdentical(result.bundle, deriveDayBundle(copyDay(grown)));
      state = result.state;
      _expectBundleMatchesBatch(full, state, CalculationMode.periodicAwake);
      expect(state.nightCvhrRestarts, 1);
    });

    test('encoded night bytes made in a worker continue in another', () async {
      final full = fixtures['smooth']!;
      final first = _upTo(full, 450);
      final Uint8List? bytes = await Isolate.run(() {
        final s = DayCalculationState();
        deriveDayBundle(first, state: s, mode: CalculationMode.heavy);
        return s.exportNightJsonHeavy();
      });
      expect(bytes, isNotNull);
      final next = _upTo(full, 800);
      final r = await Isolate.run(() {
        final s = DayCalculationState()..seedNightJson(bytes);
        final bundle = deriveDayBundle(copyDay(next),
            state: s, mode: CalculationMode.heavy);
        return (bundle: bundle, restarts: s.nightCvhrRestarts, rebuilds: s.nightRebuilds);
      });
      expect(r.restarts, 0);
      expect(r.rebuilds, 0);
      _expectIdentical(r.bundle, deriveDayBundle(copyDay(next)));
    });
  });
}
