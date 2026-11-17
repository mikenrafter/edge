import 'dart:convert';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;
import 'package:openstrap_edge/compute/day_calculation_state.dart';
import 'package:openstrap_edge/compute/ed2b_stream_diagnostics.dart';
import 'package:openstrap_edge/compute/night_day_worker.dart';
import 'package:openstrap_edge/compute/night_rr_state.dart';
import 'package:openstrap_edge/compute/onehz_pipeline.dart';
import 'package:openstrap_edge/util/worker_init.dart';

const _start = 1577930400;
const _inputs = WorkerInputs(
    nowEpochMs: 1577952000000, zoneId: 'UTC', localeTag: 'en');

Map<String, dynamic> _resetNight() {
  double wobble(int i) => 1500.0 + (i % 7) * 12 - (i % 3) * 9;
  // The reviewed analytics capped-reset fixture, followed by 13,000 normal
  // beats. The first 30-min bin refuses the clock; seven later bins survive.
  final rr = [
    for (var i = 0; i < 400; i++) wobble(i),
    ...List<double>.filled(33, 3000),
    for (var i = 0; i < 400; i++) wobble(i),
  ];
  final times = [
    for (var i = 0; i < rr.length; i++) _start * 1000.0 + i * 1400,
  ];
  var clock = times.last;
  for (var i = 0; i < 13000; i++) {
    final value = 1000 + 40 * math.sin(2 * math.pi * .2 * clock / 1000);
    clock += value;
    rr.add(value);
    times.add(clock);
  }
  return DayBundleInput(
    date: '2020-01-02', dayTsSec: const [], dayHr: const [],
    sleepTsSec: const [], sleepHr: const [], sleepRrMs: rr,
    sleepRrTsMs: times, sleepSkinTemp: const [], sleepJson: const {},
    hypnoStages: const [], sleepOnsetSec: _start,
    sleepOffsetSec: (times.last / 1000).ceil(),
    profile: const {}, deviceFamily: 'gen4',
  ).toJson();
}

Map<String, dynamic> _derive(bool foreground, bool stale, ana.CalculationMode mode) {
  final json = _resetNight();
  final input = DayBundleInput.fromJson(json);
  final corrected = ana.correctRr(input.sleepRrMs, rrTsMs: input.sleepRrTsMs);
  final windows = respPerWindowHeavy(corrected.nn, corrected.nnTimesMs,
      artifactFraction: 1 - corrected.cleanFraction);
  final expectedBrv = ana.breathingRateVariability(windows);
  final cold = deriveDayBundle(json);
  final day = DayCalculationState();
  List<double>? staleWindows;
  if (stale) {
    // An earlier input has no usable breathing bins. It must never become
    // the source for the current night's seven measured windows.
    day.nightRr(const [1000, 1000], const [1000, 2000]);
    staleWindows = day.nightRespWindows(artifactFraction: 0);
  }
  final night = foreground ? NightRrState() : null;
  List<double>? observed;
  final diagnostics = foreground ? Ed2bStreamDiagnostics() : null;
  diagnostics?.onRespWindows = (rates) => observed = rates;
  NightDayResult run(DayCalculationState previous, NightRrState? retained) =>
      deriveNightDayHeavy(_inputs, NightDayInput(json, previous, mode, retained,
          diagnostics, null, 7, 2, 125, false, false, const [],
          '2020-01-02', 'clock-reset', 0, 0, Uint8List(0)));
  final first = run(day, night);
  final again = run(first.dayState, first.night);
  return {
    'bundle': first.bundle, 'again': again.bundle, 'cold': cold,
    'windows': windows, 'observed': observed,
    'regresses': ana.hasRegressingBeatTimes(corrected.nnTimesMs),
    'brvPresent': expectedBrv.present,
    'brv': expectedBrv.toJson((v) => v.toJson()),
    'staleWindows': staleWindows,
  };
}

void _check(Map<String, dynamic> result, {bool foreground = false, bool stale = false}) {
  expect(result['regresses'], isTrue);
  expect(result['windows'], hasLength(7));
  expect(result['brvPresent'], isTrue);
  if (stale) expect(result['staleWindows'], isEmpty);
  final bundle = result['bundle'] as Map;
  final cold = result['cold'] as Map;
  expect(jsonEncode(result['again']), jsonEncode(bundle),
      reason: 'retrying the same reset must preserve the complete bundle');
  if (foreground) expect(result['observed'], result['windows']);
  final respiration = bundle['respiration'] as Map;
  for (final key in ['rsa', 'cvhr_apnea']) {
    expect(respiration[key], (cold['respiration'] as Map)[key]);
    expect((respiration[key] as Map)['value'], '—');
    expect((respiration[key] as Map)['note'], 'regressing beat time');
  }
  expect((bundle['clinical'] as Map)['brv'], result['brv']);
  for (final key in ['hrv_freq', 'hrv_time']) {
    expect((bundle['clinical'] as Map)[key], (cold['clinical'] as Map)[key]);
  }
  expect(((bundle['clinical'] as Map)['hrv_freq'] as Map)['value'], isA<Map>());
}

void main() {
  // WHY: background workers own DayCalculationState without NightRrState.
  // A refused RSA/CVHR clock must not abort frequency or the day bundle.
  // Proves CLAIM(merged-clock-refusal).
  // Catches: frequency's shared feeder folding regressing beats into RSA;
  // selecting day-state RSA/CVHR despite a regressing corrected clock.
  for (final mode in [ana.CalculationMode.forced, ana.CalculationMode.periodicAwake]) {
    test('background worker completes capped reset and retry in ${mode.name}', () async {
      _check(await Isolate.run(() => _derive(false, false, mode)));
    });
  }

  // WHY: the foreground night owner performed correction, so day-state bins
  // cannot describe the current input when ordered night streams are refused.
  // Proves CLAIM(merged-clock-refusal).
  // Catches: choosing an unfed or stale DayCalculationState for breathing bins.
  for (final stale in [false, true]) {
    test('foreground worker uses current reset breathing windows, stale=$stale', () async {
      _check(await Isolate.run(() => _derive(true, stale, ana.CalculationMode.forced)),
          foreground: true, stale: stale);
    });
  }
}
