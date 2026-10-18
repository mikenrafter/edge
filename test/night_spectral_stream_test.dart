// RED tests: the night path of deriveDayBundle computes hrvFreq and the RSA
// respiration rate from exact streams (HrvFreqStream / RsaRespStream, analytics
// 972f0b2) instead of re-running Welch / RSA over the whole night every pass.
//
// CHOSEN SHAPE
// ------------
// DayCalculationState (lib/compute/day_calculation_state.dart) keeps one
// HrvFreqStream and one RsaRespStream next to the night corrector. They are fed
// the corrector's SETTLED beats only (nightRr's `settled ++ snapshot tail`
// split); each pass asks them for snapshot(tail: provisional beats,
// artifactFraction: ...). They restart whenever nightRr rebuilds its corrector,
// and are RAM-only like the corrector.
//
// Public surface the tests pin (all on DayCalculationState):
//   Metric<HrvFreq> nightHrvFreq(double artifactFraction)
//   Metric<RespEstimate> nightResp(double artifactFraction)
//     the metric for the slice of the LAST nightRr call: bit-identical to
//     hrvFreq(nn, nnTimes, artifactFraction: f) / rsaRespRate(...) over that
//     call's `nn` / `nnTimesMs`. Folds the beats that settled since the last
//     call into the streams, then snapshots with the unsettled tail. The
//     pipeline keeps its own length gates (20 / 30 beats) and calls these
//     instead of hrvFreq / rsaRespRate.
//   int get nightSpectralFolded
//     cumulative settled beats folded into the streams (counted once for the
//     pair; a restart counts its whole settled prefix again). The "no new
//     segment work" counter: it must not move on a pass with no newly settled
//     beats.
//   int get nightSpectralRestarts
//     times the streams were started from scratch, the first included. Equals
//     nightRebuilds on every pass that asks for the metrics.
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_analytics/onehz.dart'
    show CalculationMode, RrCorrector, correctRr, hrvFreq, rsaRespRate;
import 'package:openstrap_edge/compute/day_calculation_state.dart';
import 'package:openstrap_edge/compute/onehz_pipeline.dart';

import 'support/incremental_day_fixture.dart';

/// Strict structural equality: doubles must be the same bits (NaN == NaN).
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

const _spectralKeys = ['hrv_freq', 'rsa'];

/// Settled beats a corrector holds after folding the whole slice at once.
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
  for (final k in _spectralKeys) {
    _expectIdentical(got[k], oracle[k], '$where.$k');
  }
  _expectIdentical(got, oracle, where);
}

({List<double> rr, List<double> ts}) _beats(Map<String, dynamic> d) =>
    (rr: _dbls(d['sleep_rr_ms']), ts: _dbls(d['sleep_rr_ts_ms']));

/// nightRr then the spectral metrics for the same slice, against batch.
void _expectDirectMatchesBatch(
  DayCalculationState state,
  List<double> rr,
  List<double> ts, {
  double artifactFraction = 0.05,
}) {
  final got = state.nightRr(rr, ts);
  final want = correctRr(rr, rrTsMs: ts);
  final hrv = state.nightHrvFreq(artifactFraction);
  final resp = state.nightResp(artifactFraction);
  _expectIdentical(
    hrv.toJson((v) => v.toJson()),
    hrvFreq(want.nn, want.nnTimesMs, artifactFraction: artifactFraction)
        .toJson((v) => v.toJson()),
    'hrvFreq',
  );
  _expectIdentical(
    resp.toJson((v) => v.toJson()),
    rsaRespRate(want.nn, want.nnTimesMs, artifactFraction: artifactFraction)
        .toJson((v) => v.toJson()),
    'rsa',
  );
  expect(got.nn.length, want.nn.length);
}

void main() {
  final fixtures = {
    'smooth': incrementalDay(seed: 7, nightSeconds: 1500),
    'gaps+artifacts': incrementalDay(seed: 42, gaps: true, nightSeconds: 1500),
  };

  group('growing night: streamed hrvFreq and RSA match the batch path', () {
    for (final f in fixtures.entries) {
      for (final mode in [CalculationMode.periodicAwake, CalculationMode.forced]) {
        test('${f.key} bundle, $mode', () {
          final full = f.value;
          final total = (full['sleep_rr_ms'] as List).length;
          expect(total, greaterThan(1000), reason: 'fixture sanity');
          final state = DayCalculationState();
          // Starts past the 30-beat gates so every pass asks for both metrics.
          final cuts = <int>[40, 90, 91, 92, 183, 300, 301, 640, total - 1, total];
          var lastFolded = 0;
          for (final n in cuts) {
            final input = _upTo(full, n);
            _expectBundleMatchesBatch(input, state, mode, where: 'beats=$n');
            final b = _beats(input);
            expect(state.nightSpectralFolded, _settledOf(b.rr, b.ts),
                reason: 'beats=$n: exactly the settled prefix is folded');
            expect(state.nightSpectralFolded, greaterThanOrEqualTo(lastFolded));
            lastFolded = state.nightSpectralFolded;
          }
          expect(lastFolded, greaterThan(0));
          expect(state.nightSpectralRestarts, 1,
              reason: 'pure growth never restarts the streams');
        });
      }
    }

    test('direct nightHrvFreq / nightResp over many passes', () {
      final b = _beats(fixtures['gaps+artifacts']!);
      final state = DayCalculationState();
      for (var n = 60; n <= b.rr.length; n += 97) {
        _expectDirectMatchesBatch(
          state,
          b.rr.sublist(0, n),
          b.ts.sublist(0, n),
          artifactFraction: (n % 10) / 100.0,
        );
      }
      expect(state.nightSpectralRestarts, 1);
    });
  });

  group('a pass with no new beats does no new segment work', () {
    test('direct, repeated and from fresh list copies', () {
      final b = _beats(fixtures['smooth']!);
      final state = DayCalculationState();
      _expectDirectMatchesBatch(state, b.rr, b.ts);
      final folded = state.nightSpectralFolded;
      expect(folded, _settledOf(b.rr, b.ts));
      for (var i = 0; i < 3; i++) {
        _expectDirectMatchesBatch(state, [...b.rr], [...b.ts]);
      }
      expect(state.nightSpectralFolded, folded);
      expect(state.nightSpectralRestarts, 1);
    });

    test('bundle pass in a cache-bypassing mode folds nothing new', () {
      final full = fixtures['smooth']!;
      final state = DayCalculationState();
      final input = _upTo(full, 500);
      _expectBundleMatchesBatch(input, state, CalculationMode.forced);
      final folded = state.nightSpectralFolded;
      expect(folded, greaterThan(0));
      // Another input changes so the whole bundle is recomputed; the night
      // slice is the same.
      final again = copyDay(input);
      (again['profile'] as Map)['resting_hr'] = 61;
      _expectBundleMatchesBatch(again, state, CalculationMode.heavy);
      _expectBundleMatchesBatch(again, state, CalculationMode.sleep);
      expect(state.nightSpectralFolded, folded);
      expect(state.nightSpectralRestarts, 1);
    });

    test('growth folds only the newly settled beats', () {
      final b = _beats(fixtures['smooth']!);
      final state = DayCalculationState();
      _expectDirectMatchesBatch(state, b.rr.sublist(0, 400), b.ts.sublist(0, 400));
      _expectDirectMatchesBatch(state, b.rr.sublist(0, 437), b.ts.sublist(0, 437));
      expect(state.nightSpectralFolded,
          _settledOf(b.rr.sublist(0, 437), b.ts.sublist(0, 437)));
    });
  });

  group('a nightRr rebuild restarts the streams and still matches batch', () {
    test('bundle: moved window start, edited beat, shrink', () {
      final full = fixtures['gaps+artifacts']!;
      for (final mode in [CalculationMode.periodicAwake, CalculationMode.forced]) {
        final state = DayCalculationState();
        _expectBundleMatchesBatch(_upTo(full, 600), state, mode, where: 'grow');
        expect(state.nightSpectralRestarts, 1);

        final moved = _from(_upTo(full, 650), 30);
        _expectBundleMatchesBatch(moved, state, mode, where: 'start moved');
        expect(state.nightSpectralRestarts, 2);
        final mb = _beats(moved);
        expect(state.nightSpectralFolded - 0, greaterThan(0));
        final afterMove = state.nightSpectralFolded;

        final edited = _upTo(full, 650);
        (edited['sleep_rr_ms'] as List)[40] =
            ((edited['sleep_rr_ms'] as List)[40] as num) + 250.0;
        _expectBundleMatchesBatch(edited, state, mode, where: 'edited');
        expect(state.nightSpectralRestarts, 3);
        final eb = _beats(edited);
        expect(state.nightSpectralFolded,
            afterMove + _settledOf(eb.rr, eb.ts),
            reason: 'a restart folds its whole settled prefix again');

        _expectBundleMatchesBatch(_upTo(full, 300), state, mode, where: 'shrunk');
        expect(state.nightSpectralRestarts, 4);

        // Growing again after the restart stays incremental.
        final before = state.nightSpectralFolded;
        _expectBundleMatchesBatch(_upTo(full, 320), state, mode, where: 'regrow');
        expect(state.nightSpectralRestarts, 4);
        final rb = _beats(_upTo(full, 320));
        final sb = _beats(_upTo(full, 300));
        expect(state.nightSpectralFolded,
            before + _settledOf(rb.rr, rb.ts) - _settledOf(sb.rr, sb.ts));
        expect(mb.rr, isNotEmpty);
      }
    });

    test('direct: restart counter follows nightRebuilds', () {
      final b = _beats(fixtures['smooth']!);
      final state = DayCalculationState();
      _expectDirectMatchesBatch(state, b.rr.sublist(0, 600), b.ts.sublist(0, 600));
      _expectDirectMatchesBatch(state, b.rr.sublist(25, 650), b.ts.sublist(25, 650));
      _expectDirectMatchesBatch(state, b.rr.sublist(0, 380), b.ts.sublist(0, 380));
      expect(state.nightSpectralRestarts, 3);
      expect(state.nightSpectralRestarts, state.nightRebuilds);
    });
  });

  group('isolate hop', () {
    test('state returned from a worker keeps its streams and extends them',
        () async {
      final full = fixtures['gaps+artifacts']!;
      var state = DayCalculationState();
      _expectBundleMatchesBatch(
          _upTo(full, 500), state, CalculationMode.periodicAwake);
      final b500 = _beats(_upTo(full, 500));
      expect(state.nightSpectralFolded, _settledOf(b500.rr, b500.ts));

      final grown = _upTo(full, 560);
      final captured = state;
      final result = await Isolate.run(() {
        final bundle = deriveDayBundle(
          grown,
          state: captured,
          mode: CalculationMode.periodicAwake,
        );
        return (
          bundle: bundle,
          state: captured,
          folded: captured.nightSpectralFolded,
          restarts: captured.nightSpectralRestarts,
        );
      });
      final b560 = _beats(grown);
      expect(state.nightSpectralFolded, _settledOf(b500.rr, b500.ts),
          reason: 'worker mutations do not leak into the main-isolate state');
      expect(result.folded, _settledOf(b560.rr, b560.ts),
          reason: 'worker folded only the newly settled beats');
      expect(result.restarts, 1);
      _expectIdentical(result.bundle, deriveDayBundle(copyDay(grown)));

      state = result.state;
      final total = (full['sleep_rr_ms'] as List).length;
      _expectBundleMatchesBatch(
          _upTo(full, total), state, CalculationMode.periodicAwake);
      final bt = _beats(full);
      expect(state.nightSpectralFolded, _settledOf(bt.rr, bt.ts));
      expect(state.nightSpectralRestarts, 1);
    });
  });
}
