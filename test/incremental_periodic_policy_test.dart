import 'dart:async';

import 'package:openstrap_analytics/onehz.dart' show CalculationMode;
import 'package:openstrap_edge/compute/periodic_calculation_policy.dart';
import 'package:openstrap_edge/wake/natural_wake.dart';
import 'package:openstrap_edge/wake/wake_orchestrator.dart' show WakeSamples;
import 'package:test/test.dart';

final _initialTime = DateTime.utc(2026, 10, 3, 12);
const _samples = WakeSamples(
  hr: [
    [1791028730000, 72],
    [1791028731000, 73],
  ],
  accel: [
    [1791028730000, .1, .2, 1],
  ],
  rr: [
    [1791028730100, 833],
    [1791028730950, 850],
  ],
);

NaturalObserveResult _result(
  NaturalObserveRequest request, {
  String stage = 'wake',
  double confidence = .8,
  double? age = 5000,
  double? epochStartMs,
  String? abstention,
  Map<String, Object?> state = const {'checkpoint': 1},
}) => NaturalObserveResult(
  observation: NaturalObservation(
    stage: stage,
    confidence: confidence,
    evidenceAgeMs: age,
    epochStartMs: epochStartMs ?? request.nowMs - 60000,
    abstention: abstention,
    runSec: 120,
    note: 'periodic controller fixture',
  ),
  nextState: state,
);

class _Observer implements NaturalStageObserver {
  final requests = <NaturalObserveRequest>[];
  Future<NaturalObserveResult> Function(NaturalObserveRequest) respond =
      (request) async => _result(request);

  @override
  Future<NaturalObserveResult> observe(NaturalObserveRequest request) {
    requests.add(request);
    return respond(request);
  }
}

class _Rig {
  _Rig({Duration timeout = const Duration(seconds: 8)}) {
    policy = PeriodicCalculationPolicy(
      phoneCharging: () {
        chargingCalls++;
        return charging();
      },
      loadSamples: (from, to) {
        spans.add((from, to));
        return samples(from, to);
      },
      observer: observer,
      now: () => time,
      timeout: timeout,
    );
  }

  DateTime time = _initialTime;
  int chargingCalls = 0;
  final spans = <(DateTime, DateTime)>[];
  final observer = _Observer();
  Future<bool?> Function() charging = () async => false;
  Future<WakeSamples> Function(DateTime, DateTime) samples = (_, _) async =>
      _samples;
  late final PeriodicCalculationPolicy policy;

  Future<CalculationMode> select() =>
      policy.select(heavy: false, forced: false);
}

void main() {
  for (final flags in [(true, false), (false, true), (true, true)]) {
    for (final charging in <bool?>[false, true, null]) {
      test('full flags=$flags charging=$charging skip all inputs', () async {
        final rig = _Rig();
        rig.charging = () async => charging;
        rig.samples = (_, _) => throw StateError('must skip samples');
        rig.observer.respond = (_) => throw StateError('must skip observer');

        final mode = await rig.policy.select(heavy: flags.$1, forced: flags.$2);

        expect(
          mode,
          flags.$1 && flags.$2
              ? anyOf(CalculationMode.heavy, CalculationMode.forced)
              : flags.$1
              ? CalculationMode.heavy
              : CalculationMode.forced,
        );
        expect(rig.chargingCalls, 0);
        expect(rig.spans, isEmpty);
        expect(rig.observer.requests, isEmpty);
      });
    }
  }

  for (final charging in <bool?>[true, null]) {
    test('charging=$charging runs full without samples or observer', () async {
      final rig = _Rig();
      rig.charging = () async => charging;
      expect(await rig.select(), CalculationMode.sleep);
      expect(rig.chargingCalls, 1);
      expect(rig.spans, isEmpty);
      expect(rig.observer.requests, isEmpty);
    });
  }

  test(
    'unplugged reads exactly 21 minutes and forwards all sample rows',
    () async {
      final rig = _Rig();
      expect(await rig.select(), CalculationMode.periodicAwake);
      expect(rig.chargingCalls, 1);
      expect(rig.spans, [
        (_initialTime.subtract(const Duration(minutes: 21)), _initialTime),
      ]);
      final request = rig.observer.requests.single;
      expect(request.hr, _samples.hr);
      expect(request.accel, _samples.accel);
      expect(request.rr, _samples.rr);
      expect(request.nowMs, _initialTime.millisecondsSinceEpoch.toDouble());
      expect(request.priorState, isNull);
    },
  );

  for (final fixture
      in <
        ({
          String label,
          String stage,
          double confidence,
          double? age,
          String? abstention,
          CalculationMode mode,
        })
      >[
        (
          label: 'fresh wake',
          stage: 'wake',
          confidence: .8,
          age: 5000,
          abstention: null,
          mode: CalculationMode.periodicAwake,
        ),
        (
          label: 'nrem',
          stage: 'nrem',
          confidence: .8,
          age: 5000,
          abstention: null,
          mode: CalculationMode.sleep,
        ),
        (
          label: 'rem',
          stage: 'rem',
          confidence: .8,
          age: 5000,
          abstention: null,
          mode: CalculationMode.sleep,
        ),
        (
          label: 'absent',
          stage: 'absent',
          confidence: .8,
          age: null,
          abstention: 'missingHr',
          mode: CalculationMode.sleep,
        ),
        (
          label: 'low confidence',
          stage: 'wake',
          confidence: .2,
          age: 5000,
          abstention: null,
          mode: CalculationMode.sleep,
        ),
        (
          label: 'stale evidence',
          stage: 'wake',
          confidence: .8,
          age: 150001,
          abstention: null,
          mode: CalculationMode.sleep,
        ),
        (
          label: 'no evidence',
          stage: 'wake',
          confidence: .8,
          age: null,
          abstention: null,
          mode: CalculationMode.sleep,
        ),
        (
          label: 'abstaining wake',
          stage: 'wake',
          confidence: .8,
          age: 5000,
          abstention: 'warmup',
          mode: CalculationMode.sleep,
        ),
      ]) {
    test('${fixture.label} uses the observed gate', () async {
      final rig = _Rig();
      rig.observer.respond = (request) async => _result(
        request,
        stage: fixture.stage,
        confidence: fixture.confidence,
        age: fixture.age,
        abstention: fixture.abstention,
      );
      expect(await rig.select(), fixture.mode);
      expect(rig.observer.requests, hasLength(1));
    });
  }

  test('observer elapsed time is included in final freshness check', () async {
    final rig = _Rig();
    rig.observer.respond = (request) async {
      final result = _result(request);
      rig.time = rig.time.add(const Duration(minutes: 4));
      return result;
    };
    expect(await rig.select(), CalculationMode.sleep);
  });

  test('empty samples reach observer and missing signal runs full', () async {
    final rig = _Rig();
    rig.samples = (_, _) async => const WakeSamples.empty();
    rig.observer.respond = (request) async =>
        _result(request, stage: 'absent', age: null, abstention: 'missingHr');
    expect(await rig.select(), CalculationMode.sleep);
    final request = rig.observer.requests.single;
    expect(request.hr, isEmpty);
    expect(request.accel, isEmpty);
    expect(request.rr, isEmpty);
  });

  test(
    'checkpoint survives sleep and changes with each new observation',
    () async {
      final rig = _Rig();
      final states = [
        {'checkpoint': 'wake'},
        {'checkpoint': 'sleep'},
        {'checkpoint': 'wake-again'},
      ];
      final stages = ['wake', 'nrem', 'wake'];
      var call = 0;
      rig.observer.respond = (request) async {
        final i = call++;
        return _result(request, stage: stages[i], state: states[i]);
      };
      expect(await rig.select(), CalculationMode.periodicAwake);
      rig.time = rig.time.add(const Duration(minutes: 1));
      expect(await rig.select(), CalculationMode.sleep);
      rig.time = rig.time.add(const Duration(minutes: 1));
      expect(await rig.select(), CalculationMode.periodicAwake);
      expect(rig.observer.requests.map((r) => r.priorState), [
        null,
        states[0],
        states[1],
      ]);
      expect(rig.spans.last, (
        rig.time.subtract(const Duration(minutes: 21)),
        rig.time,
      ));
    },
  );

  test(
    'charged and unknown decisions preserve checkpoint without observing',
    () async {
      final rig = _Rig();
      const state = {'checkpoint': 'successful'};
      rig.observer.respond = (request) async => _result(request, state: state);
      expect(await rig.select(), CalculationMode.periodicAwake);
      for (final charging in <bool?>[true, null]) {
        rig.charging = () async => charging;
        expect(await rig.select(), CalculationMode.sleep);
        expect(rig.observer.requests, hasLength(1));
      }
      rig.charging = () async => false;
      expect(await rig.select(), CalculationMode.periodicAwake);
      expect(rig.observer.requests.last.priorState, state);
    },
  );

  test(
    'long data gap uses new absent observation instead of old wake',
    () async {
      final rig = _Rig();
      expect(await rig.select(), CalculationMode.periodicAwake);
      rig.time = rig.time.add(const Duration(hours: 2));
      rig.samples = (_, _) async => const WakeSamples.empty();
      rig.observer.respond = (request) async => _result(
        request,
        stage: 'absent',
        age: null,
        abstention: 'staleEvidence',
      );
      expect(await rig.select(), CalculationMode.sleep);
      expect(rig.observer.requests, hasLength(2));
      expect(rig.observer.requests.last.priorState, {'checkpoint': 1});
      expect(rig.spans.last, (
        rig.time.subtract(const Duration(minutes: 21)),
        rig.time,
      ));
    },
  );

  for (final failing in ['charging', 'samples', 'observer']) {
    for (final synchronous in [false, true]) {
      test(
        '$failing error synchronous=$synchronous preserves checkpoint and releases busy flag',
        () async {
          final rig = _Rig();
          const state = {'checkpoint': 'last success'};
          rig.observer.respond = (request) async =>
              _result(request, state: state);
          expect(await rig.select(), CalculationMode.periodicAwake);
          if (failing == 'charging') {
            rig.charging = () => synchronous
                ? throw StateError('charging')
                : Future.error(StateError('charging'));
          } else if (failing == 'samples') {
            rig.samples = (_, _) => synchronous
                ? throw StateError('samples')
                : Future.error(StateError('samples'));
          } else {
            rig.observer.respond = (_) => synchronous
                ? throw StateError('observer')
                : Future.error(StateError('observer'));
          }
          expect(await rig.select(), CalculationMode.sleep);
          expect(
            rig.observer.requests,
            hasLength(failing == 'observer' ? 2 : 1),
          );
          rig.charging = () async => false;
          rig.samples = (_, _) async => _samples;
          rig.observer.respond = (request) async =>
              _result(request, state: state);
          expect(await rig.select(), CalculationMode.periodicAwake);
          expect(rig.observer.requests.last.priorState, state);
        },
      );
    }
  }

  for (final blocked in ['charging', 'samples', 'observer']) {
    test(
      '$blocked timeout preserves checkpoint and ignores late completion',
      () async {
        final rig = _Rig(timeout: Duration.zero);
        const firstState = {'checkpoint': 'first'};
        const recoveredState = {'checkpoint': 'recovered'};
        const lateState = {'checkpoint': 'late'};
        rig.observer.respond = (request) async =>
            _result(request, state: firstState);
        expect(await rig.select(), CalculationMode.periodicAwake);

        final lateCharging = Completer<bool?>();
        final lateSamples = Completer<WakeSamples>();
        final lateObserver = Completer<NaturalObserveResult>();
        if (blocked == 'charging') {
          rig.charging = () => lateCharging.future;
        } else if (blocked == 'samples') {
          rig.samples = (_, _) => lateSamples.future;
        } else {
          rig.observer.respond = (_) => lateObserver.future;
        }
        expect(await rig.select(), CalculationMode.sleep);
        final observedAtTimeout = rig.observer.requests.length;

        rig.charging = () async => false;
        rig.samples = (_, _) async => _samples;
        rig.observer.respond = (request) async =>
            _result(request, state: recoveredState);
        expect(await rig.select(), CalculationMode.periodicAwake);
        expect(rig.observer.requests.last.priorState, firstState);
        final lastRequest = rig.observer.requests.last;
        if (blocked == 'charging') {
          lateCharging.complete(false);
          await lateCharging.future;
        } else if (blocked == 'samples') {
          lateSamples.complete(_samples);
          await lateSamples.future;
        } else {
          lateObserver.complete(_result(lastRequest, state: lateState));
          await lateObserver.future;
        }
        await Future<void>.value();
        expect(rig.observer.requests, hasLength(observedAtTimeout + 1));
        expect(await rig.select(), CalculationMode.periodicAwake);
        expect(rig.observer.requests.last.priorState, recoveredState);
      },
    );
  }

  for (final blocked in ['charging', 'samples', 'observer']) {
    test(
      'concurrent call while awaiting $blocked preserves one state flow',
      () async {
        final rig = _Rig();
        final entered = Completer<void>();
        final pendingCharging = Completer<bool?>();
        final pendingSamples = Completer<WakeSamples>();
        final pendingObserver = Completer<NaturalObserveResult>();
        const state = {'checkpoint': 'only observation'};
        rig.observer.respond = (request) async =>
            _result(request, state: state);
        if (blocked == 'charging') {
          rig.charging = () {
            entered.complete();
            return pendingCharging.future;
          };
        } else if (blocked == 'samples') {
          rig.samples = (_, _) {
            entered.complete();
            return pendingSamples.future;
          };
        } else {
          rig.observer.respond = (_) {
            entered.complete();
            return pendingObserver.future;
          };
        }
        final first = rig.select();
        await entered.future;
        expect(await rig.select(), CalculationMode.sleep);
        expect(
          await rig.policy.select(heavy: true, forced: false),
          CalculationMode.heavy,
        );
        expect(
          await rig.policy.select(heavy: false, forced: true),
          CalculationMode.forced,
        );
        expect(rig.chargingCalls, 1);
        expect(rig.spans, hasLength(blocked == 'charging' ? 0 : 1));
        expect(rig.observer.requests, hasLength(blocked == 'observer' ? 1 : 0));
        if (blocked == 'charging') {
          pendingCharging.complete(false);
        } else if (blocked == 'samples') {
          pendingSamples.complete(_samples);
        } else {
          pendingObserver.complete(
            _result(rig.observer.requests.single, state: state),
          );
        }
        expect(await first, CalculationMode.periodicAwake);
        expect(rig.observer.requests, hasLength(1));
        rig.charging = () async => false;
        rig.samples = (_, _) async => _samples;
        rig.observer.respond = (request) async => _result(request);
        expect(await rig.select(), CalculationMode.periodicAwake);
        expect(rig.observer.requests.last.priorState, state);
      },
    );
  }

  test('independent policy instances never share checkpoint', () async {
    final first = _Rig();
    final second = _Rig();
    expect(await first.select(), CalculationMode.periodicAwake);
    expect(await second.select(), CalculationMode.periodicAwake);
    expect(second.observer.requests.single.priorState, isNull);
  });
}
