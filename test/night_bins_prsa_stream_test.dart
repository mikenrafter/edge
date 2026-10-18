// RED tests (round 23): the night path of deriveDayBundle streams the 30-min
// RSA bins behind BRV ('resp_windows') and PRSA DC/AC instead of re-running
// them over the whole night every pass. Mirrors night_cvhr_stream_test.dart.
// Spec: openstrap-analytics.research/r23-night-bins-prsa.md.
//
// Public surface the tests pin (the implementer must match these names):
//   List<double> DayCalculationState.nightRespWindows()
//     the frozen batch reference below (_refRespPerWindow) over the nn/nnTimes
//     of the LAST nightRr call, bit for bit.
//   Metric<PrsaResult> DayCalculationState.nightPrsaDc()
//   Metric<PrsaResult> DayCalculationState.nightPrsaAc()
//     decelerationCapacity(nn) / accelerationCapacity(nn) of the last nightRr
//     slice, every field bit for bit (capacity, profile, anchors, kind,
//     confidence, tier, inputs_used, drivers, note).
//   int get nightBinsFolded / nightPrsaFolded   cumulative settled beats folded
//     (a restart counts its whole settled prefix again). DC and AC are fed
//     together: a beat counts once in nightPrsaFolded.
//   int get nightBinsRestarts / nightPrsaRestarts   times started from scratch
//     (the first included); they follow nightRebuilds.
//   NightResumePart.toJson() keys 'respBins' and 'prsa': non-null once the
//     getters were asked; a damaged value rebuilds, never wrong output.
import 'dart:convert';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_analytics/onehz.dart'
    show
        CalculationMode,
        Metric,
        PrsaResult,
        RrCorrector,
        accelerationCapacity,
        correctRr,
        decelerationCapacity,
        rsaRespRate;
import 'package:openstrap_edge/compute/day_calculation_state.dart';
import 'package:openstrap_edge/compute/night_resume_part.dart';
import 'package:openstrap_edge/compute/onehz_pipeline.dart';

import 'support/bounded_run.dart';
import 'support/incremental_day_fixture.dart';

// FROZEN REFERENCE: a verbatim copy of `_respPerWindow` from
// lib/compute/onehz_pipeline.dart at 2744249a (private there). The stream must
// equal this, not whatever the pipeline's private copy later becomes.
List<double> _refRespPerWindow(
  List<double> nn,
  List<double> nnTimes, {
  double windowMs = 1800000.0,
  int minBeats = 60,
}) {
  if (nn.isEmpty || nn.length != nnTimes.length) return const [];
  final t0 = nnTimes.first;
  final binsNn = <int, List<double>>{};
  final binsTs = <int, List<double>>{};
  for (var i = 0; i < nn.length; i++) {
    final idx = ((nnTimes[i] - t0) / windowMs).floor();
    (binsNn[idx] ??= <double>[]).add(nn[i]);
    (binsTs[idx] ??= <double>[]).add(nnTimes[i]);
  }
  final out = <double>[];
  final idxs = binsNn.keys.toList()..sort();
  for (final idx in idxs) {
    final segNn = binsNn[idx]!;
    if (segNn.length < minBeats) continue;
    // NN is already artifact-corrected upstream → artifactFraction 0.
    final r = rsaRespRate(segNn, binsTs[idx]!, artifactFraction: 0.0);
    final b = r.present ? r.value!.brpm : null;
    if (b != null) out.add(b);
  }
  return out;
}

const _binMs = 1800000.0;

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

/// Every field of a PRSA metric, unrounded (PrsaResult.toJson rounds the
/// capacity and drops the profile).
Map<String, Object?> _prsaRaw(Metric<PrsaResult> m) {
  final v = m.value;
  return {
    'present': m.present,
    'value': v == null
        ? null
        : {
            'capacity': v.capacity,
            'profile': [...v.profile],
            'anchors': v.anchors,
            'kind': v.kind,
          },
    'confidence': m.confidence,
    'tier': m.tier,
    'inputs_used': [...m.inputs_used],
    'drivers': m.drivers == null ? null : [for (final d in m.drivers!) d.toJson()],
    'note': m.note,
  };
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

/// Drops the night beats whose offset from the first beat (seconds) falls in
/// any [from, to) of [spans]: empty bins, thin bins, gaps inside a bin.
Map<String, dynamic> _carve(
    Map<String, dynamic> day, List<(double, double)> spans) {
  final d = copyDay(day);
  final rr = _dbls(d['sleep_rr_ms']), ts = _dbls(d['sleep_rr_ts_ms']);
  final t0 = ts.first;
  final keepRr = <double>[], keepTs = <double>[];
  for (var i = 0; i < rr.length; i++) {
    final s = (ts[i] - t0) / 1000.0;
    if (spans.any((sp) => s >= sp.$1 && s < sp.$2)) continue;
    keepRr.add(rr[i]);
    keepTs.add(ts[i]);
  }
  d['sleep_rr_ms'] = keepRr;
  d['sleep_rr_ts_ms'] = keepTs;
  return d;
}

({List<double> rr, List<double> ts}) _beats(Map<String, dynamic> d) =>
    (rr: _dbls(d['sleep_rr_ms']), ts: _dbls(d['sleep_rr_ts_ms']));

RrCorrectorSettledView _settled(List<double> rr, List<double> ts) {
  final s = RrCorrector().fold(rr, tsMs: ts);
  return (nn: s.nn, nnTimes: s.nnTimes);
}

typedef RrCorrectorSettledView = ({List<double> nn, List<double> nnTimes});

int _settledOf(List<double> rr, List<double> ts) => _settled(rr, ts).nn.length;

/// Largest beat count whose corrector has settled nothing yet (tail only).
int _tailOnlyCut(List<double> rr, List<double> ts) {
  var n = 1;
  while (n < rr.length &&
      _settledOf(rr.sublist(0, n + 1), ts.sublist(0, n + 1)) == 0) {
    n++;
  }
  return n;
}

/// A beat count whose settled beats all lie before a 30-min bin boundary while
/// its provisional tail reaches past it.
int _crossingCut(List<double> rr, List<double> ts) {
  final t0 = ts.first;
  final first = ts.indexWhere((t) => t - t0 >= _binMs);
  expect(first, greaterThan(0), reason: 'fixture shorter than one bin');
  for (var n = first; n < math.min(rr.length, first + 600); n += 2) {
    final s = _settled(rr.sublist(0, n), ts.sublist(0, n));
    final all = correctRr(rr.sublist(0, n), rrTsMs: ts.sublist(0, n));
    if (s.nn.isEmpty || all.nn.isEmpty) continue;
    final a0 = all.nnTimesMs.first;
    int bin(double t) => ((t - a0) / _binMs).floor();
    if (bin(s.nnTimes.last) < bin(all.nnTimesMs.last)) return n;
  }
  fail('no cut whose tail crosses a bin boundary');
}

void _expectBundleMatchesBatch(
  Map<String, dynamic> input,
  DayCalculationState state,
  CalculationMode mode, {
  String where = '',
}) {
  final oracle = deriveDayBundle(copyDay(input));
  final got = deriveDayBundle(input, state: state, mode: mode);
  for (final k in ['brv', 'prsa_dc', 'prsa_ac']) {
    _expectIdentical(got[k], oracle[k], '$where.$k');
  }
  _expectIdentical(got, oracle, where);
}

void _expectDirectMatchesBatch(
  DayCalculationState state,
  List<double> rr,
  List<double> ts, {
  String where = '',
}) {
  final got = state.nightRr(rr, ts);
  final want = correctRr(rr, rrTsMs: ts);
  expect(got.nn.length, want.nn.length, reason: '$where nn');
  _expectIdentical(state.nightRespWindows(),
      _refRespPerWindow(want.nn, want.nnTimesMs), '$where.respWindows');
  _expectIdentical(_prsaRaw(state.nightPrsaDc()),
      _prsaRaw(decelerationCapacity(want.nn)), '$where.prsaDc');
  _expectIdentical(_prsaRaw(state.nightPrsaAc()),
      _prsaRaw(accelerationCapacity(want.nn)), '$where.prsaAc');
}

void _expectFoldedIsSettled(
    DayCalculationState state, List<double> rr, List<double> ts, String where) {
  final settled = _settledOf(rr, ts);
  expect(state.nightBinsFolded, settled,
      reason: '$where: bins fold exactly the settled prefix');
  expect(state.nightPrsaFolded, settled,
      reason: '$where: PRSA folds exactly the settled prefix');
}

NightResumePart _roundTrip(NightResumePart p) => NightResumePart.fromJson(
    (jsonDecode(utf8.decode(utf8.encode(jsonEncode(p.toJson())))) as Map)
        .cast<String, dynamic>());

void main() {
  // ~93 min: bins 0..3, the last one partial.
  final long = incrementalDay(seed: 7, nightSeconds: 5600);
  // ~123 min with bin 1 cut to ~40 s of beats (< 60 beats, skipped), bin 2
  // empty, a 5-min gap inside bin 3, and the fixture's own artifacts + 14 s gap.
  final gappy = _carve(incrementalDay(seed: 42, gaps: true, nightSeconds: 7400),
      [(1840.0, 5400.0), (6000.0, 6300.0)]);
  // 25 min: shorter than one bin.
  final short = incrementalDay(seed: 7, nightSeconds: 1500);
  final fixtures = {'long': long, 'gappy': gappy, 'short': short};

  test('fixture shapes', () {
    final g = _beats(gappy);
    final want = correctRr(g.rr, rrTsMs: g.ts);
    final t0 = want.nnTimesMs.first;
    final perBin = <int, int>{};
    for (final t in want.nnTimesMs) {
      final b = ((t - t0) / _binMs).floor();
      perBin[b] = (perBin[b] ?? 0) + 1;
    }
    expect(perBin[1], isNotNull);
    expect(perBin[1]!, lessThan(60), reason: 'a thin bin');
    expect(perBin[2], isNull, reason: 'an empty bin');
    expect(_refRespPerWindow(want.nn, want.nnTimesMs).length,
        greaterThanOrEqualTo(2));
    final l = _beats(long);
    final lw = correctRr(l.rr, rrTsMs: l.ts);
    expect(_refRespPerWindow(lw.nn, lw.nnTimesMs).length,
        greaterThanOrEqualTo(3), reason: 'BRV present on the long night');
    final s = _beats(short);
    expect(s.ts.last - s.ts.first, lessThan(_binMs));
  });

  group('growing night: streamed bins and PRSA match the batch path', () {
    for (final f in fixtures.entries) {
      for (final mode in [CalculationMode.periodicAwake, CalculationMode.forced]) {
        test('${f.key} bundle, $mode', () {
          final full = f.value;
          final b = _beats(full);
          final total = b.rr.length;
          final cuts = <int>{
            _tailOnlyCut(b.rr, b.ts),
            70,
            300,
            if (f.key != 'short') _crossingCut(b.rr, b.ts),
            total ~/ 2,
            total - 1,
            total,
          }.where((n) => n > 0 && n <= total).toList()
            ..sort();
          final state = DayCalculationState();
          var last = 0;
          for (final n in cuts) {
            final input = _upTo(full, n);
            _expectBundleMatchesBatch(input, state, mode, where: 'beats=$n');
            final ib = _beats(input);
            _expectFoldedIsSettled(state, ib.rr, ib.ts, 'beats=$n');
            expect(state.nightBinsFolded, greaterThanOrEqualTo(last));
            last = state.nightBinsFolded;
          }
          expect(last, greaterThan(0));
          expect(state.nightBinsRestarts, 1);
          expect(state.nightPrsaRestarts, 1);
        });
      }
    }

    for (final f in fixtures.entries) {
      test('${f.key}: direct, many passes with random chunk sizes', () {
        final b = _beats(f.value);
        final rnd = math.Random(23);
        final state = DayCalculationState();
        var n = 0;
        while (n < b.rr.length) {
          n = math.min(b.rr.length, n + 1 + rnd.nextInt(700));
          _expectDirectMatchesBatch(
              state, b.rr.sublist(0, n), b.ts.sublist(0, n), where: 'n=$n');
          _expectFoldedIsSettled(
              state, b.rr.sublist(0, n), b.ts.sublist(0, n), 'n=$n');
        }
        expect(state.nightBinsRestarts, 1);
        expect(state.nightPrsaRestarts, 1);
      });
    }

    test('a pass whose provisional tail crosses a bin boundary', () {
      for (final full in [long, gappy]) {
        final b = _beats(full);
        final n = _crossingCut(b.rr, b.ts);
        final state = DayCalculationState();
        _expectDirectMatchesBatch(
            state, b.rr.sublist(0, n - 200), b.ts.sublist(0, n - 200),
            where: 'before');
        _expectDirectMatchesBatch(state, b.rr.sublist(0, n), b.ts.sublist(0, n),
            where: 'crossing');
        _expectDirectMatchesBatch(
            state, b.rr.sublist(0, n + 150), b.ts.sublist(0, n + 150),
            where: 'settled past it');
        expect(state.nightBinsRestarts, 1);
        // Fresh state straight onto the crossing cut.
        _expectDirectMatchesBatch(
            DayCalculationState(), b.rr.sublist(0, n), b.ts.sublist(0, n),
            where: 'fresh crossing');
      }
    });

    test('nothing settled yet: tail only', () {
      for (final full in [long, short]) {
        final b = _beats(full);
        final n = _tailOnlyCut(b.rr, b.ts);
        expect(_settledOf(b.rr.sublist(0, n), b.ts.sublist(0, n)), 0);
        final state = DayCalculationState();
        _expectDirectMatchesBatch(state, b.rr.sublist(0, n), b.ts.sublist(0, n),
            where: 'tail only n=$n');
        expect(state.nightBinsFolded, 0);
        expect(state.nightPrsaFolded, 0);
        _expectDirectMatchesBatch(
            state, b.rr.sublist(0, n + 40), b.ts.sublist(0, n + 40),
            where: 'first settled');
        _expectBundleMatchesBatch(
            _upTo(full, n), DayCalculationState(), CalculationMode.heavy,
            where: 'bundle tail only');
      }
    });
  });

  group('a pass with no new beats does no new work', () {
    test('direct, repeated and from fresh list copies', () {
      final b = _beats(long);
      final state = DayCalculationState();
      _expectDirectMatchesBatch(state, b.rr, b.ts);
      _expectFoldedIsSettled(state, b.rr, b.ts, 'first');
      final bins = state.nightBinsFolded, prsa = state.nightPrsaFolded;
      for (var i = 0; i < 3; i++) {
        _expectDirectMatchesBatch(state, [...b.rr], [...b.ts]);
      }
      expect(state.nightBinsFolded, bins);
      expect(state.nightPrsaFolded, prsa);
      expect(state.nightBinsRestarts, 1);
      expect(state.nightPrsaRestarts, 1);
    });

    test('bundle pass in a cache-bypassing mode folds nothing new', () {
      final state = DayCalculationState();
      final input = _upTo(gappy, 2500);
      _expectBundleMatchesBatch(input, state, CalculationMode.forced);
      final bins = state.nightBinsFolded, prsa = state.nightPrsaFolded;
      expect(bins, greaterThan(0));
      final again = copyDay(input);
      (again['profile'] as Map)['resting_hr'] = 61;
      _expectBundleMatchesBatch(again, state, CalculationMode.heavy);
      _expectBundleMatchesBatch(again, state, CalculationMode.sleep);
      expect(state.nightBinsFolded, bins);
      expect(state.nightPrsaFolded, prsa);
      expect(state.nightBinsRestarts, 1);
      expect(state.nightPrsaRestarts, 1);
    });

    test('growth folds only the newly settled beats', () {
      final b = _beats(long);
      final state = DayCalculationState();
      _expectDirectMatchesBatch(state, b.rr.sublist(0, 2000), b.ts.sublist(0, 2000));
      _expectDirectMatchesBatch(state, b.rr.sublist(0, 2037), b.ts.sublist(0, 2037));
      _expectFoldedIsSettled(
          state, b.rr.sublist(0, 2037), b.ts.sublist(0, 2037), 'grown');
    });
  });

  group('a nightRr rebuild restarts the streams and still matches batch', () {
    test('bundle: moved window start, edited beat, shrink', () {
      for (final mode in [CalculationMode.periodicAwake, CalculationMode.forced]) {
        final state = DayCalculationState();
        _expectBundleMatchesBatch(_upTo(long, 2600), state, mode, where: 'grow');
        expect(state.nightBinsRestarts, 1);
        expect(state.nightPrsaRestarts, 1);

        final moved = _from(_upTo(long, 2700), 30);
        _expectBundleMatchesBatch(moved, state, mode, where: 'start moved');
        expect(state.nightBinsRestarts, 2);
        expect(state.nightPrsaRestarts, 2);
        final binsAfterMove = state.nightBinsFolded;
        final prsaAfterMove = state.nightPrsaFolded;

        final edited = _upTo(long, 2700);
        (edited['sleep_rr_ms'] as List)[40] =
            ((edited['sleep_rr_ms'] as List)[40] as num) + 250.0;
        _expectBundleMatchesBatch(edited, state, mode, where: 'edited');
        expect(state.nightBinsRestarts, 3);
        expect(state.nightPrsaRestarts, 3);
        final eb = _beats(edited);
        expect(state.nightBinsFolded, binsAfterMove + _settledOf(eb.rr, eb.ts),
            reason: 'a restart folds its whole settled prefix again');
        expect(state.nightPrsaFolded, prsaAfterMove + _settledOf(eb.rr, eb.ts));

        _expectBundleMatchesBatch(_upTo(long, 1200), state, mode, where: 'shrunk');
        expect(state.nightBinsRestarts, 4);
        _expectBundleMatchesBatch(_upTo(long, 1300), state, mode, where: 'regrow');
        expect(state.nightBinsRestarts, 4);
        expect(state.nightPrsaRestarts, 4);
      }
    });

    test('direct: restart counters follow nightRebuilds', () {
      final b = _beats(long);
      final state = DayCalculationState();
      _expectDirectMatchesBatch(state, b.rr.sublist(0, 2600), b.ts.sublist(0, 2600));
      _expectDirectMatchesBatch(state, b.rr.sublist(25, 2650), b.ts.sublist(25, 2650));
      _expectDirectMatchesBatch(state, b.rr.sublist(0, 1900), b.ts.sublist(0, 1900));
      expect(state.nightBinsRestarts, 3);
      expect(state.nightPrsaRestarts, 3);
      expect(state.nightBinsRestarts, state.nightRebuilds);
      expect(state.nightPrsaRestarts, state.nightRebuilds);
    });
  });

  group('checkpoint round trip', () {
    final full = gappy;
    final total = (full['sleep_rr_ms'] as List).length;
    final fb = _beats(full);

    test('the night part carries both streams', () {
      final s = DayCalculationState();
      _expectBundleMatchesBatch(_upTo(full, 2200), s, CalculationMode.heavy);
      final j = s.exportNight()!.toJson();
      expect(j['respBins'], isNotNull);
      expect(j['prsa'], isNotNull);
      final rt = _roundTrip(s.exportNight()!).toJson();
      expect(rt['respBins'], isNotNull);
      expect(rt['prsa'], isNotNull);
    });

    test('restored state continues: identical bundle, no restart, only new beats',
        () {
      final warm = DayCalculationState();
      _expectBundleMatchesBatch(_upTo(full, 2200), warm, CalculationMode.heavy);
      final restored = DayCalculationState()
        ..seedNight(_roundTrip(warm.exportNight()!));
      _expectBundleMatchesBatch(_upTo(full, total), restored, CalculationMode.heavy);
      expect(restored.nightRebuilds, 0);
      expect(restored.nightBinsRestarts, 0);
      expect(restored.nightPrsaRestarts, 0);
      final fresh = _settledOf(fb.rr, fb.ts) -
          _settledOf(fb.rr.sublist(0, 2200), fb.ts.sublist(0, 2200));
      expect(restored.nightBinsFolded, fresh);
      expect(restored.nightPrsaFolded, fresh);
    });

    test('a restart between every pass equals batch', () {
      NightResumePart? carried;
      var bins = 0, prsa = 0;
      for (var n = 150; ; n += 611) {
        n = n > total ? total : n;
        final s = DayCalculationState()..seedNight(carried);
        _expectBundleMatchesBatch(_upTo(full, n), s, CalculationMode.heavy,
            where: 'n=$n');
        bins += s.nightBinsRestarts;
        prsa += s.nightPrsaRestarts;
        carried = _roundTrip(s.exportNight()!);
        if (n == total) break;
      }
      expect(bins, 1);
      expect(prsa, 1);
    });

    for (final key in ['respBins', 'prsa']) {
      final damages = <String, Object? Function(Object?)>{
        'a number': (_) => 42,
        'an empty map': (_) => <String, dynamic>{},
        'a list': (_) => ['x'],
        'every field a string': (v) => v is Map
            ? {for (final k in v.keys) k: 'Nope'}
            : 'Nope',
      };
      for (final d in damages.entries) {
        test('a damaged $key payload (${d.key}) rebuilds, never wrong output',
            () {
          final warm = DayCalculationState();
          _expectBundleMatchesBatch(_upTo(full, 2200), warm, CalculationMode.heavy);
          final j = _roundTrip(warm.exportNight()!).toJson();
          expect(j[key], isNotNull);
          j[key] = d.value(j[key]);
          final s = DayCalculationState();
          // The damage may surface at fromJson or at adoption; either way the
          // night is rebuilt and the output is the batch output.
          NightResumePart? part;
          try {
            part = NightResumePart.fromJson(
                (jsonDecode(jsonEncode(j)) as Map).cast<String, dynamic>());
          } on FormatException {
            part = null;
          }
          s.seedNight(part);
          _expectBundleMatchesBatch(_upTo(full, 3000), s, CalculationMode.heavy);
        });
      }
    }
  });

  group('isolate hop', () {
    test('state returned from a worker keeps its streams and extends them',
        () async {
      final full = long;
      var state = DayCalculationState();
      _expectBundleMatchesBatch(
          _upTo(full, 2000), state, CalculationMode.periodicAwake);
      final b2000 = _beats(_upTo(full, 2000));
      final grown = _upTo(full, 2300);
      final captured = state;
      final result = await Isolate.run(() {
        final bundle = deriveDayBundle(grown,
            state: captured, mode: CalculationMode.periodicAwake);
        return (
          bundle: bundle,
          state: captured,
          bins: captured.nightBinsFolded,
          prsa: captured.nightPrsaFolded,
          binRestarts: captured.nightBinsRestarts,
          prsaRestarts: captured.nightPrsaRestarts,
        );
      });
      final b2300 = _beats(grown);
      expect(state.nightBinsFolded, _settledOf(b2000.rr, b2000.ts));
      expect(result.bins, _settledOf(b2300.rr, b2300.ts));
      expect(result.prsa, _settledOf(b2300.rr, b2300.ts));
      expect(result.binRestarts, 1);
      expect(result.prsaRestarts, 1);
      _expectIdentical(result.bundle, deriveDayBundle(copyDay(grown)));
      state = result.state;
      _expectBundleMatchesBatch(full, state, CalculationMode.periodicAwake);
      expect(state.nightBinsRestarts, 1);
      expect(state.nightPrsaRestarts, 1);
    });

    test('encoded night bytes made in a worker continue in another', () async {
      final full = gappy;
      final first = _upTo(full, 1800);
      final Uint8List? bytes = await Isolate.run(() {
        final s = DayCalculationState();
        deriveDayBundle(first, state: s, mode: CalculationMode.heavy);
        return s.exportNightJsonHeavy();
      });
      expect(bytes, isNotNull);
      final next = _upTo(full, 3200);
      final r = await Isolate.run(() {
        final s = DayCalculationState()..seedNightJson(bytes);
        final bundle = deriveDayBundle(copyDay(next),
            state: s, mode: CalculationMode.heavy);
        return (
          bundle: bundle,
          bins: s.nightBinsRestarts,
          prsa: s.nightPrsaRestarts,
          rebuilds: s.nightRebuilds,
        );
      });
      expect(r.bins, 0);
      expect(r.prsa, 0);
      expect(r.rebuilds, 0);
      _expectIdentical(r.bundle, deriveDayBundle(copyDay(next)));
    });
  });

  // Section 3 of the spec for the new streams (the existing ones are in
  // night_stream_nonfinite_test.dart). A non-finite beat makes nightRr take
  // the batch path; the getters must then equal their batch functions over the
  // nn it returned. Run in a killable isolate: before analytics e6dd526
  // rsaRespRate never returned on a non-finite beat time, which the bins
  // reference hits; should that come back, the case fails as a timeout naming
  // the hung call.
  group('a non-finite beat: bins and PRSA equal batch over the returned nn', () {
    final b = _beats(long);
    for (final bad in {
      'NaN': double.nan,
      '+inf': double.infinity,
      '-inf': double.negativeInfinity,
    }.entries) {
      test('${bad.key}: first slice, after clean passes, then repaired',
          () async {
        final rr = b.rr, ts = b.ts;
        final passes = <({List<double> rr, List<double> ts, String where})>[
          (rr: rr.sublist(0, 1500)..[700] = bad.value, ts: ts.sublist(0, 1500), where: 'first'),
          (rr: rr.sublist(0, 2000), ts: ts.sublist(0, 2000), where: 'repaired'),
          (rr: rr.sublist(0, 2600), ts: ts.sublist(0, 2600), where: 'clean'),
          (rr: rr.sublist(0, 3000)..[2800] = bad.value, ts: ts.sublist(0, 3000), where: 'late bad'),
          (rr: [...rr]..[2800] = bad.value, ts: ts, where: 'bad kept'),
        ];
        final rows = await boundedRun((step) {
          final state = DayCalculationState();
          final out = <List<Object?>>[];
          for (final p in passes) {
            step('${p.where}: nightRr');
            final got = state.nightRr(p.rr, p.ts);
            step('${p.where}: nightRespWindows');
            final w = state.nightRespWindows();
            step('${p.where}: batch respPerWindow');
            out.add(['${p.where}.respWindows', w,
                _refRespPerWindow(got.nn, got.nnTimesMs)]);
            step('${p.where}: nightPrsaDc');
            final dc = _prsaRaw(state.nightPrsaDc());
            out.add(['${p.where}.prsaDc', dc, _prsaRaw(decelerationCapacity(got.nn))]);
            step('${p.where}: nightPrsaAc');
            final ac = _prsaRaw(state.nightPrsaAc());
            out.add(['${p.where}.prsaAc', ac, _prsaRaw(accelerationCapacity(got.nn))]);
          }
          return out;
        }, limit: const Duration(seconds: 45));
        for (final r in rows) {
          _expectIdentical(r[1], r[2], r[0] as String);
        }
      });
    }
  });
}
