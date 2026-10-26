import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/band_buzzer.dart';
import 'package:openstrap_edge/wake/gradual_wake.dart';
import 'package:openstrap_edge/wake/wake_settings.dart';
import 'package:openstrap_edge/wake/wake_stores.dart';

import 'support/band_buzzer_fakes.dart';
import 'support/wake_db.dart';

class _Probe implements BandBuzzer {
  final requests = <BandBuzzRequest>[];
  final stops = <String>[];
  Future<BandBuzzResult> Function()? onPlay;
  @override
  Future<BandBuzzResult> play(BandBuzzRequest request) async {
    requests.add(request);
    return onPlay == null ? BandBuzzResult.complete : await onPlay!();
  }
  @override
  void stop(String scope) => stops.add(scope);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late WakeClock clock;
  late _Probe port;
  late GradualWake wake;
  final end = DateTime(2026, 10, 25, 7);
  final epoch = end.millisecondsSinceEpoch ~/ 1000;
  const settings = WakeSettings(naturalEnabled: true, gradualEnabled: true,
      gradualCadenceSec: 300);
  const store = DbWakeStateStore();
  GradualWake create() => GradualWake(now: clock.now, store: store, buzzer: () => port);
  Future<void> tick() => wake.tick(epoch: epoch, settings: settings, canDeliver: () => true);

  setUp(() async {
    dir = await openWakeDb();
    clock = WakeClock(end.subtract(const Duration(minutes: 30)));
    port = _Probe();
    wake = create();
  });
  tearDown(() => closeWakeDb(dir));

  test('consumes before a failed write, preserves Natural, skips replay on restart', () async {
    await store.update(epoch, (run) => run['naturalFired'] = true);
    port.onPlay = () async {
      expect((await store.load())!['gradualNext'], 1);
      return BandBuzzResult.failed;
    };
    await tick();
    wake = create();
    await tick();
    expect(port.requests.map((r) => r.stepIndex), [0]);
    expect((await store.load())!['naturalFired'], true);
    clock.at = clock.at.add(const Duration(minutes: 10));
    port.onPlay = null;
    await tick();
    expect(port.requests.map((r) => (r.stepIndex, r.pulses)), [(0, 1), (2, 2)]);
  });

  test('stale steps are skipped and T is exclusive', () async {
    clock.at = end.subtract(const Duration(minutes: 28));
    await tick();
    expect((await store.load())!['gradualNext'], 1);
    expect(port.requests, isEmpty);
    clock.at = end.subtract(const Duration(minutes: 25));
    await tick();
    expect(port.requests.map((r) => r.stepIndex), [1]);
    clock.at = end;
    await tick();
    expect(port.requests.map((r) => r.stepIndex), [1]);
  });

  test('acknowledgement persists while playback is held and stops future steps', () async {
    final held = Completer<BandBuzzResult>();
    final entered = Completer<void>();
    port.onPlay = () { entered.complete(); return held.future; };
    final playing = tick();
    await entered.future;
    await wake.acknowledge(epoch);
    expect((await store.load())!['acknowledged'], true);
    expect(port.stops, ['gradual:$epoch']);
    held.complete(BandBuzzResult.partial);
    await playing;
    wake = create();
    clock.at = end.subtract(const Duration(minutes: 25));
    await tick();
    expect(port.requests, hasLength(1));
  });
}
