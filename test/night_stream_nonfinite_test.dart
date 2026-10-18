// RED tests (round 23, section 3): a night slice holding a non-finite RR beat.
//
// RrCorrector.fold refuses a NaN / ±inf beat, so DayCalculationState.nightRr
// resets the night (`_resetNight`) and returns the BATCH correction. The night
// streams are then empty while the returned nn is not, so a streamed metric
// asked on that pass must not snapshot the empty stream: it has to equal its
// batch function over the nn nightRr just returned.
//
// This file covers the streams that already exist (nightHrvFreq, nightResp,
// nightCvhr) so it compiles before the round's new API lands; the same cases
// for nightRespWindows / nightPrsaDc / nightPrsaAc live in
// night_bins_prsa_stream_test.dart.
//
// Only direct calls: a NaN cannot go through the JSON bundle input
// (jsonEncode throws on it). Every case runs in a killable isolate with a 30 s
// limit: before analytics e6dd526 rsaRespRate and hrvFreq looped forever on a
// non-finite beat time (and grew memory until the box OOM-killed the runner),
// and a sync loop cannot be timed out in the test isolate. Should one come
// back, the case fails as a TimeoutException naming the hung call.
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_analytics/onehz.dart'
    show cvhrApneaScreen, hrvFreq, rsaRespRate;
import 'package:openstrap_edge/compute/day_calculation_state.dart';

import 'support/bounded_run.dart';
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

typedef _Pass = ({List<double> rr, List<double> ts, String where});

/// Runs the passes on one state in a killable isolate (a batch reference or a
/// stream may never return on a non-finite night; see boundedRun) and returns,
/// per pass and metric, [where, streamed, batch]. Each stream is asked before
/// its batch reference so a hang names the call that hung.
Future<List<List<Object?>>> _run(List<_Pass> passes) => boundedRun((step) {
      final state = DayCalculationState();
      final out = <List<Object?>>[];
      for (final p in passes) {
        step('${p.where}: nightRr');
        final got = state.nightRr(p.rr, p.ts);
        step('${p.where}: nightRrBatch');
        final want = nightRrBatch(p.rr, p.ts);
        out.add(['${p.where}.nn', got.nn, want.nn]);
        out.add(['${p.where}.nnTimesMs', got.nnTimesMs, want.nnTimesMs]);
        // The references run over what nightRr returned, as the pipeline does.
        final nn = got.nn, times = got.nnTimesMs;
        final f = (1.0 - got.cleanFraction).clamp(0.0, 1.0);
        step('${p.where}: nightHrvFreq');
        final h = state.nightHrvFreq(f).toJson((v) => v.toJson());
        step('${p.where}: batch hrvFreq');
        out.add(['${p.where}.hrvFreq', h,
            hrvFreq(nn, times, artifactFraction: f).toJson((v) => v.toJson())]);
        step('${p.where}: nightResp');
        final r = state.nightResp(f).toJson((v) => v.toJson());
        step('${p.where}: batch rsaRespRate');
        out.add(['${p.where}.resp', r,
            rsaRespRate(nn, times, artifactFraction: f).toJson((v) => v.toJson())]);
        step('${p.where}: nightCvhr');
        final c = state.nightCvhr(f).toJson((v) => v.toJson());
        step('${p.where}: batch cvhrApneaScreen');
        out.add(['${p.where}.cvhr', c,
            cvhrApneaScreen(nn, times, artifactFraction: f)
                .toJson((v) => v.toJson())]);
      }
      return out;
    }, limit: const Duration(seconds: 30));

Future<void> _expectPasses(List<_Pass> passes) async {
  for (final r in await _run(passes)) {
    _expectIdentical(r[1], r[2], r[0] as String);
  }
}

void main() {
  final day = incrementalDay(seed: 7, nightSeconds: 1500);
  final rr = _dbls(day['sleep_rr_ms']);
  final ts = _dbls(day['sleep_rr_ts_ms']);

  final bad = <String, double>{
    'NaN': double.nan,
    '+inf': double.infinity,
    '-inf': double.negativeInfinity,
  };

  group('a non-finite beat: existing night streams equal batch over the '
      'returned nn', () {
    for (final b in bad.entries) {
      test('${b.key} in the first slice', () async {
        await _expectPasses([
          (rr: [...rr]..[700] = b.value, ts: ts, where: 'first'),
        ]);
      });

      test('${b.key} arriving after clean passes', () async {
        await _expectPasses([
          (rr: rr.sublist(0, 600), ts: ts.sublist(0, 600), where: 'clean 600'),
          (rr: rr.sublist(0, 900), ts: ts.sublist(0, 900), where: 'clean 900'),
          (
            rr: rr.sublist(0, 1100)..[1000] = b.value,
            ts: ts.sublist(0, 1100),
            where: 'bad beat at 1000',
          ),
          // Still present on the next, longer pass.
          (rr: [...rr]..[1000] = b.value, ts: ts, where: 'bad beat kept'),
        ]);
      });

      test('${b.key} then the beat repaired: streams recover', () async {
        await _expectPasses([
          (rr: rr.sublist(0, 800)..[300] = b.value, ts: ts.sublist(0, 800), where: 'bad'),
          (rr: rr.sublist(0, 900), ts: ts.sublist(0, 900), where: 'repaired'),
          (rr: rr, ts: ts, where: 'grown'),
        ]);
      });
    }
  });
}
