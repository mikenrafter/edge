// RED tests: the night path of deriveDayBundle computes the whole-night
// time-domain HRV (`hrvTime`: rmssd / sdnn / pnn50 / sdann / sdnnIndex /
// diffAcf1, with its abstentions) from the analytics `hrvTimeAggregator`
// (checkpointable, stream == batch) instead of re-running hrvTime over every
// beat of the night each pass. Mirrors night_cvhr_stream_test.dart.
//
// SCOPE: hrvTime ONLY. `nocturnalRmssd` and `sleepSessionRmssdDetail` have no
// streaming equivalent in analytics (ddb61f7: grep finds them only in
// clinical/hrv_time.dart, no aggregator / incremental twin), so they stay batch
// and are not pinned here. `IncrementalHrvTime` is not used: its state is a
// different shape from the checkpointable aggregator.
//
// CHOSEN SHAPE (same as CVHR)
// ---------------------------
// DayCalculationState keeps one hrvTimeAggregator state next to the night
// corrector, fed the corrector's SETTLED beats only (nn + nnTimes as `Beats`);
// each pass asks for a snapshot over the settled state plus the unsettled tail.
// It restarts whenever nightRr rebuilds and rides the night part of the
// checkpoint.
//
// Public surface the tests pin (accessed through `dynamic` on purpose, so a
// missing member fails the test by name instead of breaking compilation):
//   Metric<HrvTime> DayCalculationState.nightHrvTime({RrCoverage? coverage})
//     hrvTime(nn, nnTimesMs: nnTimes, coverage: coverage) of the LAST nightRr
//     call, bit for bit (confidence, tier, note included).
//   int get nightHrvTimeFolded     cumulative settled beats folded (a restart
//     counts its whole settled prefix again): the work counter.
//   int get nightHrvTimeRestarts   times the state was started from scratch.
//   NightResumePart.toJson()['hrvTime'] / ['hrvTimeFed']  the aggregator
//     checkpoint (JSON value) and its feed count (<= nn.length, else
//     FormatException like the other streams); both absent until asked. A
//     part without them resumes by starting the stream from scratch; a payload
//     the package rejects does the same. Neither refuses the whole part.
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_analytics/onehz.dart'
    show CalculationMode, RrCorrector, correctRr, hrvTime, rrCoverage;
import 'package:openstrap_edge/compute/day_calculation_state.dart';
import 'package:openstrap_edge/compute/night_resume_part.dart';
import 'package:openstrap_edge/compute/onehz_pipeline.dart';

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

// ── the not-yet-existing surface, read through dynamic ──────────────────────
T _need<T>(String what, T Function() read) {
  try {
    return read();
  } on NoSuchMethodError {
    fail('missing API: $what');
  }
}

int _folded(DayCalculationState s) =>
    _need('DayCalculationState.nightHrvTimeFolded',
        () => (s as dynamic).nightHrvTimeFolded as int);
int _restarts(DayCalculationState s) =>
    _need('DayCalculationState.nightHrvTimeRestarts',
        () => (s as dynamic).nightHrvTimeRestarts as int);
Map<String, dynamic> _hrvTimeJson(DayCalculationState s, Object? coverage) =>
    _need('DayCalculationState.nightHrvTime({coverage})', () {
      final m = (s as dynamic).nightHrvTime(coverage: coverage);
      return m.toJson((v) => v.toJson()) as Map<String, dynamic>;
    });

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

/// Beats arriving twice as fast as the clock: Σ RR over wall span is ~2, so the
/// pipeline's rrCoverage says overCounted and hrvTime refuses RMSSD/pNN50.
Map<String, dynamic> _overCounted(Map<String, dynamic> full) {
  final d = copyDay(full);
  final ts = _dbls(d['sleep_rr_ts_ms']);
  final t0 = ts.first;
  d['sleep_rr_ts_ms'] = [for (final t in ts) t0 + (t - t0) * 0.5];
  return d;
}

({List<double> rr, List<double> ts}) _beats(Map<String, dynamic> d) =>
    (rr: _dbls(d['sleep_rr_ms']), ts: _dbls(d['sleep_rr_ts_ms']));

int _settledOf(List<double> rr, List<double> ts) =>
    RrCorrector().fold(rr, tsMs: ts).nn.length;

/// The time-domain HRV block as the bundle publishes it.
Map<String, Object?> _hrvBlock(Map<String, dynamic> bundle) {
  final clinical = bundle['clinical'] as Map;
  final scalars = bundle['scalars'] as Map;
  return {
    'clinical.hrv_time': clinical['hrv_time'],
    'scalars.rmssd_whole': scalars['rmssd_whole'],
    'scalars.sdnn': scalars['sdnn'],
  };
}

void _expectBundleMatchesBatch(
  Map<String, dynamic> input,
  DayCalculationState state,
  CalculationMode mode, {
  String where = '',
}) {
  final oracle = deriveDayBundle(copyDay(input));
  final got = deriveDayBundle(input, state: state, mode: mode);
  _expectIdentical(_hrvBlock(got), _hrvBlock(oracle), '$where.hrv');
  _expectIdentical(got, oracle, where);
}

void _expectDirectMatchesBatch(
  DayCalculationState state,
  List<double> rr,
  List<double> ts,
) {
  final got = state.nightRr(rr, ts);
  final want = correctRr(rr, rrTsMs: ts);
  final cov = rrCoverage(rr, ts);
  _expectIdentical(
    _hrvTimeJson(state, cov),
    hrvTime(want.nn, nnTimesMs: want.nnTimesMs, coverage: cov)
        .toJson((v) => v.toJson()),
    'hrvTime',
  );
  expect(got.nn.length, want.nn.length);
}

NightResumePart _roundTrip(NightResumePart p) => NightResumePart.fromJson(
    (jsonDecode(utf8.decode(utf8.encode(jsonEncode(p.toJson())))) as Map)
        .cast<String, dynamic>());

/// Beats a pass may fold beyond the genuinely new ones: the lookback seam of
/// the aggregator (a few beats), nothing proportional to the night.
const int _seam = 16;

void main() {
  final fixtures = {
    'smooth': incrementalDay(seed: 7, nightSeconds: 1500),
    'gaps+artifacts': incrementalDay(seed: 42, gaps: true, nightSeconds: 1500),
    'over-counted': _overCounted(incrementalDay(seed: 7, nightSeconds: 1500)),
  };
  final modes = [CalculationMode.periodicAwake, CalculationMode.forced];

  group('exactness: growing night, streamed hrvTime == cold batch derive', () {
    for (final f in fixtures.entries) {
      for (final mode in modes) {
        test('${f.key} bundle, $mode', () {
          final full = f.value;
          final total = (full['sleep_rr_ms'] as List).length;
          final state = DayCalculationState();
          final cuts = <int>[70, 90, 91, 92, 183, 300, 301, 640, total - 1, total];
          for (final n in cuts) {
            final input = _upTo(full, n);
            _expectBundleMatchesBatch(input, state, mode, where: 'beats=$n');
            final b = _beats(input);
            expect(_folded(state), _settledOf(b.rr, b.ts),
                reason: 'beats=$n: exactly the settled prefix is folded');
          }
          expect(_restarts(state), 1);
        });
      }
    }

    test('direct nightHrvTime over many passes, with rrCoverage', () {
      final b = _beats(fixtures['gaps+artifacts']!);
      final state = DayCalculationState();
      for (var n = 70; n <= b.rr.length; n += 97) {
        _expectDirectMatchesBatch(state, b.rr.sublist(0, n), b.ts.sublist(0, n));
      }
      expect(_restarts(state), 1);
    });

    test('too few beats abstains exactly like hrvTime', () {
      final b = _beats(fixtures['smooth']!);
      final state = DayCalculationState();
      for (final n in [0, 1, 2, 3, 5, 30]) {
        final rr = b.rr.sublist(0, n), ts = b.ts.sublist(0, n);
        final got = state.nightRr(rr, ts);
        _expectIdentical(
          _hrvTimeJson(state, null),
          hrvTime(got.nn, nnTimesMs: got.nnTimesMs).toJson((v) => v.toJson()),
          'n=$n',
        );
      }
    });
  });

  group('work: a forced pass folds only the new beats', () {
    for (final mode in [CalculationMode.forced, CalculationMode.heavy]) {
      test('$mode passes 2..n fold <= new beats + seam', () {
        final full = fixtures['smooth']!;
        final total = (full['sleep_rr_ms'] as List).length;
        final state = DayCalculationState();
        var prevBeats = 0;
        var prevFolded = 0;
        for (final n in <int>[200, 330, 331, 500, 800, total]) {
          _expectBundleMatchesBatch(_upTo(full, n), state, mode, where: 'n=$n');
          final delta = _folded(state) - prevFolded;
          if (prevBeats > 0) {
            expect(delta, lessThanOrEqualTo(n - prevBeats + _seam),
                reason: 'n=$n: folded $delta for ${n - prevBeats} new beats');
          }
          prevBeats = n;
          prevFolded = _folded(state);
        }
        expect(_restarts(state), 1);
        expect(_folded(state), lessThanOrEqualTo(total + _seam),
            reason: 'the whole run folds the night about once');
      });
    }

    test('a pass with no new beats folds nothing, in every mode', () {
      final state = DayCalculationState();
      final input = _upTo(fixtures['smooth']!, 500);
      _expectBundleMatchesBatch(input, state, CalculationMode.forced);
      final folded = _folded(state);
      expect(folded, greaterThan(0));
      final again = copyDay(input);
      (again['profile'] as Map)['resting_hr'] = 61;
      for (final m in [
        CalculationMode.heavy,
        CalculationMode.sleep,
        CalculationMode.forced,
        CalculationMode.periodicAwake,
      ]) {
        _expectBundleMatchesBatch(again, state, m);
      }
      expect(_folded(state), folded);
      expect(_restarts(state), 1);
    });

    test('direct: repeated and from fresh list copies', () {
      final b = _beats(fixtures['smooth']!);
      final state = DayCalculationState();
      _expectDirectMatchesBatch(state, b.rr, b.ts);
      final folded = _folded(state);
      expect(folded, _settledOf(b.rr, b.ts));
      for (var i = 0; i < 3; i++) {
        _expectDirectMatchesBatch(state, [...b.rr], [...b.ts]);
      }
      expect(_folded(state), folded);
    });
  });

  group('fallbacks: a nightRr rebuild restarts the stream, still == batch', () {
    test('bundle: moved onset, edited earlier beat, shrink (eviction)', () {
      final full = fixtures['gaps+artifacts']!;
      for (final mode in modes) {
        final state = DayCalculationState();
        _expectBundleMatchesBatch(_upTo(full, 600), state, mode, where: 'grow');
        expect(_restarts(state), 1);

        final moved = _from(_upTo(full, 650), 30);
        _expectBundleMatchesBatch(moved, state, mode, where: 'onset moved');
        expect(_restarts(state), 2);
        final afterMove = _folded(state);

        final edited = _upTo(full, 650);
        (edited['sleep_rr_ms'] as List)[40] =
            ((edited['sleep_rr_ms'] as List)[40] as num) + 250.0;
        _expectBundleMatchesBatch(edited, state, mode, where: 'beat replaced');
        expect(_restarts(state), 3);
        final eb = _beats(edited);
        expect(_folded(state), afterMove + _settledOf(eb.rr, eb.ts),
            reason: 'a restart folds its whole settled prefix again');

        _expectBundleMatchesBatch(_upTo(full, 300), state, mode, where: 'shrunk');
        expect(_restarts(state), 4);
        _expectBundleMatchesBatch(_upTo(full, 320), state, mode, where: 'regrow');
        expect(_restarts(state), 4);
      }
    });

    test('direct: restart counter follows nightRebuilds', () {
      final b = _beats(fixtures['smooth']!);
      final state = DayCalculationState();
      _expectDirectMatchesBatch(state, b.rr.sublist(0, 600), b.ts.sublist(0, 600));
      _expectDirectMatchesBatch(state, b.rr.sublist(25, 650), b.ts.sublist(25, 650));
      _expectDirectMatchesBatch(state, b.rr.sublist(0, 380), b.ts.sublist(0, 380));
      expect(_restarts(state), 3);
      expect(_restarts(state), state.nightRebuilds);
    });
  });

  group('a non-finite beat behaves like the other streams', () {
    // nightRr resets the night and returns the batch correction; the stream is
    // then empty while nn is not, so nightHrvTime must equal hrvTime over the
    // nn nightRr just returned. Killable isolate: see night_stream_nonfinite_test.
    final day = fixtures['smooth']!;
    final rr = _dbls(day['sleep_rr_ms']);
    final ts = _dbls(day['sleep_rr_ts_ms']);
    final bad = <String, double>{
      'NaN': double.nan,
      '+inf': double.infinity,
      '-inf': double.negativeInfinity,
    };

    Future<void> run(List<({List<double> rr, List<double> ts, String where})> passes) async {
      final out = await boundedRun((step) {
        final state = DayCalculationState();
        final rows = <List<Object?>>[];
        for (final p in passes) {
          step('${p.where}: nightRr');
          final got = state.nightRr(p.rr, p.ts);
          step('${p.where}: nightHrvTime');
          Object? streamed;
          try {
            final m = (state as dynamic).nightHrvTime(coverage: null);
            streamed = m.toJson((v) => v.toJson());
          } on NoSuchMethodError {
            streamed = 'MISSING DayCalculationState.nightHrvTime';
          } catch (e) {
            streamed = 'THREW $e';
          }
          step('${p.where}: batch hrvTime');
          // Batch hrvTime itself throws on a non-finite beat time (an existing
          // analytics limit, out of scope here): then the reference is the
          // same throw, and the stream must not answer with a value.
          Object? want;
          try {
            want = hrvTime(got.nn, nnTimesMs: got.nnTimesMs)
                .toJson((v) => v.toJson());
          } catch (_) {
            want = 'BATCH THROWS';
          }
          rows.add([p.where, streamed, want]);
        }
        return rows;
      }, limit: const Duration(seconds: 30));
      for (final r in out) {
        expect(r[1], isNot('MISSING DayCalculationState.nightHrvTime'),
            reason: r[0] as String);
        if (r[2] == 'BATCH THROWS') {
          expect(r[1], isA<String>(), reason: '${r[0]}: no value over a throw');
          continue;
        }
        _expectIdentical(r[1], r[2], r[0] as String);
      }
    }

    for (final b in bad.entries) {
      test('${b.key} in the first slice', () async {
        await run([(rr: [...rr]..[700] = b.value, ts: ts, where: 'first')]);
      });
      test('${b.key} after clean passes, then repaired', () async {
        await run([
          (rr: rr.sublist(0, 600), ts: ts.sublist(0, 600), where: 'clean 600'),
          (
            rr: rr.sublist(0, 1100)..[1000] = b.value,
            ts: ts.sublist(0, 1100),
            where: 'bad at 1000'
          ),
          (rr: rr, ts: ts, where: 'repaired and grown'),
        ]);
      });
    }
  });

  group('checkpoint', () {
    final full = fixtures['gaps+artifacts']!;
    final total = (full['sleep_rr_ms'] as List).length;

    DayCalculationState warm() {
      final s = DayCalculationState();
      _expectBundleMatchesBatch(_upTo(full, 400), s, CalculationMode.heavy);
      return s;
    }

    test('the night part carries the hrv-time state and its feed count', () {
      final part = warm().exportNight()!;
      final j = part.toJson();
      expect(j['hrvTime'], isNotNull, reason: 'optional key hrvTime');
      expect(j['hrvTimeFed'], isA<int>());
      final rt = _roundTrip(part).toJson();
      expect(rt['hrvTime'], j['hrvTime']);
      expect(rt['hrvTimeFed'], j['hrvTimeFed']);
    });

    test('feed count above the settled beats is a FormatException', () {
      final j = _roundTrip(warm().exportNight()!).toJson();
      expect(j.containsKey('hrvTime'), isTrue, reason: 'optional key hrvTime');
      j['hrvTimeFed'] = (j['nn'] as List).length + 1;
      expect(() => NightResumePart.fromJson(j), throwsFormatException);
    });

    test('restored state continues: identical, no restart, only new beats', () {
      final restored = DayCalculationState()
        ..seedNight(_roundTrip(warm().exportNight()!));
      _expectBundleMatchesBatch(_upTo(full, 900), restored, CalculationMode.forced);
      final b = _beats(full);
      expect(restored.nightRebuilds, 0);
      expect(_restarts(restored), 0);
      expect(
          _folded(restored),
          _settledOf(b.rr.sublist(0, 900), b.ts.sublist(0, 900)) -
              _settledOf(b.rr.sublist(0, 400), b.ts.sublist(0, 400)));
    });

    test('a restart between every pass (cold process each time) equals batch',
        () {
      NightResumePart? carried;
      var restarts = 0;
      for (var n = 150; ; n += 211) {
        n = n > total ? total : n;
        final s = DayCalculationState()..seedNight(carried);
        _expectBundleMatchesBatch(_upTo(full, n), s, CalculationMode.forced,
            where: 'n=$n');
        restarts += _restarts(s);
        carried = _roundTrip(s.exportNight()!);
        if (n == total) break;
      }
      expect(restarts, 1);
    });

    test('an old checkpoint without the key resumes by rebuilding the stream',
        () {
      final j = _roundTrip(warm().exportNight()!).toJson()
        ..remove('hrvTime')
        ..remove('hrvTimeFed');
      final s = DayCalculationState()..seedNight(NightResumePart.fromJson(j));
      _expectBundleMatchesBatch(_upTo(full, 700), s, CalculationMode.forced);
      expect(s.nightRebuilds, 0, reason: 'the part is not refused whole');
      expect(s.nightCvhrRestarts, 0, reason: 'other streams keep resuming');
      expect(_restarts(s), 1);
      final b = _beats(full);
      expect(_folded(s), _settledOf(b.rr.sublist(0, 700), b.ts.sublist(0, 700)),
          reason: 'rebuilt from the whole settled prefix');
    });

    test('a damaged payload rebuilds, never wrong output', () {
      final good = _roundTrip(warm().exportNight()!).toJson();
      final payload = good['hrvTime'];
      expect(payload, isNotNull, reason: 'optional key hrvTime');
      final damages = <String, Object?>{
        'emptied': payload is List ? <Object?>[] : <String, Object?>{},
        'truncated': payload is List
            ? payload.take(1).toList()
            : <String, Object?>{'type': 'Nope'},
      };
      for (final d in damages.entries) {
        final j = _roundTrip(warm().exportNight()!).toJson();
        j['hrvTime'] = d.value;
        final s = DayCalculationState()..seedNight(NightResumePart.fromJson(j));
        _expectBundleMatchesBatch(_upTo(full, 700), s, CalculationMode.forced,
            where: d.key);
        expect(s.nightRebuilds, 0, reason: '${d.key}: part not refused whole');
        expect(_restarts(s), 1, reason: '${d.key}: stream rebuilt');
      }
    });
  });

  group('isolate hop', () {
    test('state returned from a worker keeps its stream and extends it',
        () async {
      final full = fixtures['gaps+artifacts']!;
      var state = DayCalculationState();
      _expectBundleMatchesBatch(_upTo(full, 500), state, CalculationMode.forced);
      final b500 = _beats(_upTo(full, 500));
      final grown = _upTo(full, 560);
      final captured = state;
      final result = await Isolate.run(() {
        final bundle = deriveDayBundle(grown,
            state: captured, mode: CalculationMode.forced);
        return (
          bundle: bundle,
          state: captured,
          folded: _folded(captured),
          restarts: _restarts(captured),
        );
      });
      final b560 = _beats(grown);
      expect(_folded(state), _settledOf(b500.rr, b500.ts));
      expect(result.folded, _settledOf(b560.rr, b560.ts));
      expect(result.restarts, 1);
      _expectIdentical(result.bundle, deriveDayBundle(copyDay(grown)));
      state = result.state;
      _expectBundleMatchesBatch(full, state, CalculationMode.forced);
      expect(_restarts(state), 1);
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
            state: s, mode: CalculationMode.forced);
        return (
          bundle: bundle,
          restarts: _restarts(s),
          rebuilds: s.nightRebuilds,
        );
      });
      expect(r.restarts, 0);
      expect(r.rebuilds, 0);
      _expectIdentical(r.bundle, deriveDayBundle(copyDay(next)));
    });
  });
}
