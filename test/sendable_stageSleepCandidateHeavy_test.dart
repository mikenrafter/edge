// ignore_for_file: file_names
// The @SendableShape round trip for the sleep-staging entry (design 02: its
// input carries a `Substrate`, whose typed-data columns and `Set<String>` of
// device ids are outside the closed grammar, so the entry owes a real
// Isolate.run round trip).
//
// Pins: `SleepStagingInput` (the substrate, the window's override, the stored
// profile and the ENCODED cardio row chunks) crosses into a worker and
// `SleepStagingResult` (the staged candidate, the raw observation and one
// encoded row chunk) comes back, intact in both directions, and the worker
// answers with what the same call on this isolate answers.

import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;
import 'package:openstrap_edge/compute/cardio_rows_blob.dart';
import 'package:openstrap_edge/compute/derive_prepare.dart';
import 'package:openstrap_edge/compute/sleep_staging_worker.dart';
import 'package:openstrap_edge/compute/substrate.dart';
import 'package:openstrap_edge/util/worker_init.dart';

import 'guards/support/sendability.dart';

const _inputs =
    WorkerInputs(nowEpochMs: 1760000000000, zoneId: 'UTC', localeTag: 'en');

final DateTime _mid = DateTime(2026, 6, 27);
const String _day = '2026-06-27';
int _h(double hours) =>
    _mid.add(Duration(minutes: (hours * 60).round())).millisecondsSinceEpoch ~/ 1000;

/// A synthetic night (asleep between -1 h and 6 h) with beats.
Substrate _night() {
  final ts = <int>[], hr = <int>[];
  final ax = <double>[], ay = <double>[], az = <double>[];
  final rrTs = <double>[], rr = <double>[];
  var nextBeatMs = _h(-2) * 1000.0;
  for (var t = _h(-2); t < _h(7); t++) {
    final s = t >= _h(-1) && t < _h(6);
    final bpm = s ? 52 + (t % 7) : 80 + (t ~/ 60) % 20 + t % 3;
    ts.add(t);
    hr.add(bpm);
    ax.add(s ? 0.0 : .3 * math.sin(t * .21));
    ay.add(s ? 0.0 : .2 * math.cos(t * .13));
    az.add(s ? 1.0 : 1 + .05 * math.sin(t * .07));
    while (nextBeatMs < (t + 1) * 1000.0) {
      final ibi = 60000.0 / bpm + (s ? 40 : 12) * math.sin(t * (s ? .35 : .9));
      rrTs.add(nextBeatMs);
      rr.add(ibi);
      nextBeatMs += ibi;
    }
  }
  return Substrate(
    tsSec: ts,
    hr: hr,
    rrTsMs: rrTs,
    rrMs: rr,
    ax: ax,
    ay: ay,
    az: az,
    spo2Red: List.filled(ts.length, 1),
    spo2Ir: List.filled(ts.length, 1),
    skinTemp: List.filled(ts.length, 3000),
    skinContact: List.filled(ts.length, 1),
    deviceFamily: 'gen4',
    deviceIds: const {'dev-a'},
  );
}

SleepStagingInput _input(Substrate sub, List<Uint8List> chunks) =>
    SleepStagingInput(
      dayId: _day,
      searchSub: sub,
      override: null,
      priorSleep: const [],
      confirmedWakeSec: null,
      profileJson: null,
      mayFold: true,
      rowChunks: chunks,
      rowsLoSec: _h(-3),
      rowsHiSec: _h(8),
      nowSec: _h(12),
    );

Object? _inputShape(SleepStagingInput i) => [
      i.dayId,
      i.searchSub.tsSec,
      i.searchSub.hr,
      i.searchSub.rrMs,
      i.searchSub.deviceFamily,
      i.searchSub.deviceIds.toList(),
      i.override,
      i.priorSleep,
      i.confirmedWakeSec,
      i.profileJson,
      i.mayFold,
      i.rowChunks,
      i.rowsLoSec,
      i.rowsHiSec,
      i.nowSec,
    ];

Object? _resultShape(SleepStagingResult r) => [
      r.candidateJson,
      r.observationJson,
      r.rowsJson,
      r.rowsLoSec,
      r.rowsHiSec,
      r.rowHits,
      r.rowMisses,
    ];

void main() {
  tearDown(() {
    WorkerInit.resetForTest();
    ana.cardioRecordObservations = false;
    ana.cardioUserProfile = null;
    ana.resetCardioObservations();
  });

  test('the input crosses an isolate boundary with every field intact',
      () async {
    final sub = _night();
    final warm = ana.CardioRowCache();
    prepareSleepSessionCandidate(sub, targetDay: _day, rowCache: warm);
    final input = _input(sub, [encodeCardioRowsHeavy(warm)]);
    await expectIsolateRoundTrip<SleepStagingInput>(input,
        project: _inputShape);
  });

  test('the result crosses an isolate boundary with every field intact',
      () async {
    final result = SleepStagingResult(
      candidateJson: '{"dayId":"x"}',
      observationJson: null,
      rowsJson: Uint8List.fromList([123, 125]),
      rowsLoSec: 10,
      rowsHiSec: 20,
      rowHits: 3,
      rowMisses: 4,
    );
    await expectIsolateRoundTrip<SleepStagingResult>(result,
        project: _resultShape);
  });

  test('the worker answers with what this isolate would produce; warm chunks '
      'are all hits', () async {
    final sub = _night();
    final warm = ana.CardioRowCache();
    prepareSleepSessionCandidate(sub, targetDay: _day, rowCache: warm);
    final input = _input(sub, [encodeCardioRowsHeavy(warm)]);

    SleepStagingResult run() => stageSleepCandidateHeavy(_inputs, input);
    final here = run();
    final inWorker = await Isolate.run(run);
    expect(_resultShape(inWorker).toString(), _resultShape(here).toString());
    expect(inWorker.rowMisses, 0, reason: 'every row came in encoded');
    expect(inWorker.rowHits, greaterThan(0));
    expect(inWorker.rowsJson, isNotNull);
    expect(inWorker.rowsLoSec, lessThanOrEqualTo(inWorker.rowsHiSec));
  });
}
