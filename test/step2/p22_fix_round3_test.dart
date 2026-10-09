// P2.2 fix round 3 (Sol r3): no path waits for admission while holding
// reservations it has not queued.
//
// Three concurrent walks of 8 small payloads interleave their reads until their
// unqueued partial batches hold every request slot; each then waits for a slot
// that only a queued flight could free. The admission clock is moved by hand,
// so the 5 s wait expires without any real waiting.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/data/bundle_store.dart';

import 'support/p22_support.dart';

const _name = 'p22_fix_round3.db';

String _d(int i) => DateTime.utc(2025, 1, 1 + i).toIso8601String().substring(0, 10);

final class _HandClock implements BundleClock {
  DateTime at = DateTime.utc(2026, 1, 1);
  @override
  DateTime now() => at;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  p21RestoreClockAfterEach();

  late P22Lane lane;
  setUp(() async {
    await p21Fresh(_name);
    lane = P22Lane();
  });
  tearDown(() => p21Drop(_name));

  test('three concurrent 8-row walks over 24 small payloads all complete; '
      'nothing throws and nothing stays reserved', () async {
    const walks = 3, rows = 8;
    for (var i = 0; i < walks * rows; i++) {
      await p22Put(_d(i), 't$i');
    }
    final clock = _HandClock();
    final store = BundleStore(lane: lane, clock: clock);
    final outs = <int, List<BundleRead>>{};
    final errors = <Object>[];
    final calls = [
      for (var w = 0; w < walks; w++)
        store
            .readAll([for (var r = 0; r < rows; r++) BundleSource.day(_d(w * rows + r))])
            .then((v) => outs[w] = v, onError: errors.add),
    ];

    // A stuck state (slots all reserved, nothing queued or running) is where
    // the old code waited for a slot nobody could free: let its 5 s run out.
    var finished = false;
    unawaited(Future.wait(calls).then((_) => finished = true));
    for (var i = 0; i < 100000 && !finished; i++) {
      if (store.debugFlightCount == 0 && store.debugReservedRequests > 0) {
        clock.at = clock.at.add(const Duration(seconds: 6));
      }
      await Future<void>.delayed(Duration.zero);
    }

    expect(errors, isEmpty, reason: "no BundleRetryable");
    expect(finished, isTrue, reason: "every walk completes");
    expect(errors, isEmpty, reason: 'no BundleRetryable');
    for (var w = 0; w < walks; w++) {
      expect(outs[w]!.map(p22TagOf).toList(),
          [for (var r = 0; r < rows; r++) 't${w * rows + r}']);
    }
    expect(store.debugReservedRequests, 0);
    expect(store.debugReservedBytes, 0);
    expect(store.debugSourceBytesHeld, 0);
    expect(store.debugFlightCount, 0);
  });
}
