// Heavy inference stays off the UI isolate, and the observer that runs it is
// pure: the same inputs give the same observation in or out of an isolate.

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/wake/natural_wake.dart';

import '../support/dart_source.dart';

String _code(String path) => stripCommentsAndStrings(File(path).readAsStringSync());

/// A synthetic night: [minutes] of 1 Hz HR with a slow wave, still accel, and
/// plausible RR beats. Absolute epoch-ms timestamps from [startMs].
NaturalObserveRequest _night({
  required int minutes,
  double startMs = 1790000000000,
  Map<String, Object?>? prior,
}) {
  final hr = <List<double>>[];
  final accel = <List<double>>[];
  final rr = <List<double>>[];
  final rng = math.Random(7);
  final n = minutes * 60;
  for (var s = 0; s < n; s++) {
    final ts = startMs + s * 1000.0;
    hr.add([ts, 56 + 4 * math.sin(s / 900) + rng.nextDouble()]);
    accel.add([ts, 0.0, 0.0, 1.0]);
    rr.add([ts, 1000 + 40 * math.sin(s / 7) + rng.nextDouble() * 10]);
  }
  return NaturalObserveRequest(
    nowMs: startMs + n * 1000.0,
    hr: hr,
    accel: accel,
    rr: rr,
    priorState: prior,
  );
}

void main() {
  group('source guards', () {
    test('nothing else in lib/ calls the causal stager', () {
      final offenders = <String>[];
      for (final f in Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))) {
        if (f.path.endsWith('lib/wake/natural_wake.dart')) continue;
        final code = stripCommentsAndStrings(f.readAsStringSync());
        if (code.contains('CausalStager.') || code.contains('CausalSampleWindow(')) {
          offenders.add(f.path);
        }
      }
      expect(offenders, isEmpty,
          reason: 'one inference path: the orchestrator must not stage on the '
              'UI isolate. Offenders: $offenders');
    });

    test('the orchestrator reaches inference only through the observer seam',
        () {
      final orch = _code('lib/wake/wake_orchestrator.dart');
      expect(RegExp(r'observer\s*\.observe\(').hasMatch(orch), isTrue);
      expect(orch, isNot(contains('CausalStager')));
    });

    test('the native cancel is requested from exactly one place, the '
        'acknowledgement path', () {
      final orch = _code('lib/wake/wake_orchestrator.dart');
      expect(RegExp(r'env\.cancelNativeAlarm\(').allMatches(orch), hasLength(1));
      final natural = _code('lib/wake/natural_wake.dart');
      expect(natural, isNot(contains('cancelNativeAlarm')));
      expect(natural, isNot(contains('disableAlarm')));
      expect(orch, isNot(contains('disableAlarm')));
    });
  });

  group('the observer', () {
    test('a cold start in the first minutes abstains for warm-up', () {
      final r = observeNaturalSync(_night(minutes: 5));
      expect(r.observation.stage, 'absent');
      expect(r.observation.abstention, 'warmup');
    });

    test('after warm-up a quiet night is staged, with bounded confidence', () {
      final r = observeNaturalSync(_night(minutes: 50));
      expect(r.observation.stage, isIn(['wake', 'nrem', 'rem']));
      expect(r.observation.abstention, isNull);
      expect(r.observation.confidence, inInclusiveRange(0.15, 0.6));
      expect(r.observation.evidenceAgeMs, lessThanOrEqualTo(kNaturalMaxEvidenceAgeMs));
    });

    test('empty input abstains rather than guessing', () {
      final r = observeNaturalSync(NaturalObserveRequest(
          nowMs: 1790000000000, hr: const [], accel: const [], rr: const []));
      expect(r.observation.stage, 'absent');
      expect(r.observation.abstention, isNotNull);
    });

    test('the isolate returns exactly what the synchronous call returns',
        () async {
      final req = _night(minutes: 45);
      final sync = observeNaturalSync(req);
      final viaIsolate = await const IsolateNaturalStageObserver().observe(req);
      expect(viaIsolate.observation.toJson(), sync.observation.toJson());
      expect(viaIsolate.nextState, sync.nextState);
    });

    test('replay is deterministic and incremental feeding converges', () {
      final whole = _night(minutes: 50);
      final a = observeNaturalSync(whole);
      final b = observeNaturalSync(whole);
      expect(a.observation.toJson(), b.observation.toJson());

      // Feed the same night in two calls, the second carrying the first's
      // state and an overlapping re-send, as the orchestrator does.
      final cut = 30 * 60;
      final first = NaturalObserveRequest(
        nowMs: whole.nowMs - (50 * 60 - cut) * 1000.0,
        hr: whole.hr.sublist(0, cut),
        accel: whole.accel.sublist(0, cut),
        rr: whole.rr.sublist(0, cut),
      );
      final r1 = observeNaturalSync(first);
      final second = NaturalObserveRequest(
        nowMs: whole.nowMs,
        hr: whole.hr.sublist(cut - 5),
        accel: whole.accel.sublist(cut - 5),
        rr: whole.rr.sublist(cut - 5),
        priorState: r1.nextState,
      );
      final r2 = observeNaturalSync(second);
      expect(r2.observation.stage, a.observation.stage);
      expect(r2.observation.abstention, a.observation.abstention);
    });

    test('a foreign prior state starts fresh instead of failing', () {
      final r = observeNaturalSync(_night(minutes: 5, prior: {'v': 999, 'x': 1}));
      expect(r.observation.stage, 'absent');
    });
  });
}
