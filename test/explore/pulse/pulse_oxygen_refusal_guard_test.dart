// Regression guard, written for the breathing-disturbance research prototype.
//
// The pulse-pattern research view sits next to a refused metric. There is no
// usable oxygen signal: within a capture session the IR channel is the red
// channel plus a fixed offset, so any red/IR ratio measures baseline drift
// (see `kSpo2Refusal` in lib/compute/onehz_pipeline.dart). This file pins that
// the day pipeline keeps refusing, including when the input carries large,
// correlated red/IR drift that an optical-dip detector would read as dips.
//
// These tests are expected to pass before the prototype exists. They guard
// against the prototype (or anything near it) relaxing the refusal.

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/onehz_pipeline.dart';

const int _t0 = 1786700000;
const int _nightSec = 6 * 3600;

/// A six hour night with beats, plus red/IR ADC series that both fall by
/// about 40 000 counts and carry a deep, slow sag every few minutes: the
/// shape of baseline drift, with `ir - red` held fixed as on real captures.
Map<String, dynamic> _night({required bool withDriftingAdc}) {
  final ts = <int>[for (var i = 0; i < _nightSec; i++) _t0 + i];
  final hr = List<int>.filled(_nightSec, 56);
  final rrTs = <double>[];
  final rr = <double>[];
  var t = 0.0; // ms since night start
  while (t < _nightSec * 1000.0) {
    final nn = 1070 + 120 * math.sin(2 * math.pi * (t / 1000) / 70);
    t += nn;
    rrTs.add(_t0 * 1000.0 + t);
    rr.add(nn);
  }
  final input = DayBundleInput(
    date: '2026-10-07',
    dayTsSec: ts,
    dayHr: hr,
    sleepTsSec: ts,
    sleepHr: hr,
    sleepRrTsMs: rrTs,
    sleepRrMs: rr,
    sleepSkinTemp: List<int>.filled(_nightSec, 0),
    sleepJson: <String, dynamic>{'tst_sec': _nightSec, 'efficiency_pct': 92.0},
    hypnoStages: const [],
    sleepOnsetSec: ts.first,
    sleepOffsetSec: ts.last + 1,
    profile: const {'age': 30, 'sex': 'm', 'weight_kg': 70, 'height_cm': 175},
    deviceFamily: 'gen4',
  ).toJson();
  if (withDriftingAdc) {
    final red = <int>[
      for (var i = 0; i < _nightSec; i++)
        (90000 - (40000 * i / _nightSec) -
                6000 * math.max(0, math.sin(2 * math.pi * i / 400)))
            .round(),
    ];
    // ir = red + fixed offset: the same signal, as on a real capture.
    final ir = [for (final r in red) r + 12345];
    input['spo2_red_raw'] = red;
    input['spo2_ir_raw'] = ir;
    input['sleep_spo2_red_raw'] = red;
    input['sleep_spo2_ir_raw'] = ir;
  }
  return deriveDayBundle(input);
}

void _expectRefused(Map<String, dynamic> bundle) {
  final odi = (((bundle['respiration'] as Map)['odi']) as Map)
      .cast<String, dynamic>();
  expect(odi['value'], '—', reason: 'the oxygen-dip metric stays absent');
  expect(odi['confidence'], 0);
  expect(odi['note'] as String, startsWith('refused: within a session'));
  expect(odi['note'] as String, contains('baseline drift'));

  final spo2 = (bundle['spo2'] as Map).cast<String, dynamic>();
  expect(spo2['disabled'], isTrue);
  for (final k in const [
    'value',
    'odi_per_hour',
    'dip_count',
    'analyzed_hours',
    'mean_dip_pct',
    'max_dip_pct',
    'longest_dip_sec',
    'burden_pct',
    'signal_coverage',
    'trusted_coverage',
  ]) {
    expect(spo2[k], isNull, reason: 'spo2.$k must stay null');
  }
  expect(spo2['note'] as String, startsWith('refused: within a session'));
}

void main() {
  // The pipeline run is slow; derive each night once.
  late final Map<String, dynamic> plain;
  late final Map<String, dynamic> drift;
  setUpAll(() {
    plain = _night(withDriftingAdc: false);
    drift = _night(withDriftingAdc: true);
  });

  test('a night with no red/IR input keeps the oxygen metric refused', () {
    _expectRefused(plain);
  });

  test('large correlated red/IR baseline drift never becomes an oxygen dip',
      () {
    _expectRefused(drift);
  });

  test('the drifting input changes nothing in the oxygen blocks', () {
    expect(drift['spo2'], plain['spo2']);
    expect((drift['respiration'] as Map)['odi'],
        (plain['respiration'] as Map)['odi']);
  });
}
