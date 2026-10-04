// 8AC — playing a compiled plan on the band (spec G, the player).
//
// For each step after the first: wait for the band's "ended" event of the
// step before (timeout = that phrase's longest span + 1500 ms; a timeout just
// carries on, the band has finished by then), then wait the step's delayMs,
// then write. Results follow deliverBuzzSequence: complete, rejected (nothing
// written) or partial (some written, a later one was not).
//
// Plans come from the compiler so the expectations read off plan.steps and
// do not depend on which phrases the compiler happens to choose.

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/pattern_transcript.dart';
import 'package:openstrap_edge/haptics/haptic_compiler.dart';
import 'package:openstrap_edge/haptics/haptic_player.dart';
import 'package:openstrap_edge/haptics/haptic_profile.dart';
import 'package:openstrap_edge/notify/buzz_sequence.dart';

final HapticDeviceProfile _mg = HapticDeviceProfile.whoopMg;

List<PatternEntry> _c(String code) => [
  for (final tok in code.split(RegExp(r'\s+')))
    tok.startsWith('N')
        ? PatternEntry(
            note: true,
            length: int.parse(RegExp(r'\d+').firstMatch(tok)!.group(0)!),
            dynamic: PatternDynamic.values.firstWhere(
              (d) => d.name == tok.replaceFirst(RegExp(r'^N\d+'), ''),
            ),
          )
        : PatternEntry(note: false, length: int.parse(tok.substring(1))),
];

HapticPlan _plan(String code) =>
    compile(_c(code), _mg)!;

/// A fake band: records every write and every wait with the fake clock.
class _Band {
  _Band(this.async);
  final FakeAsync async;

  /// Per write index: the result; missing = true; an Exception is thrown.
  final Map<int, Object> writeScript = {};
  bool connected = true;
  Duration endedAfter = const Duration(milliseconds: 1000);
  bool endedResult = true;
  void Function()? onWait;

  final log = <String>[];
  final writes = <String>[];
  final writeAt = <int>[];
  final waits = <Duration>[];
  final waitAt = <int>[];

  int get now => async.elapsed.inMilliseconds;

  Future<bool> write(List<int> effects, int loop) async {
    final i = writes.length;
    writes.add('$effects x$loop');
    writeAt.add(now);
    log.add('write$i');
    final r = writeScript[i];
    if (r is Exception) throw r;
    return r == null ? true : r as bool;
  }

  Future<bool> waitEnded(Duration timeout) async {
    waits.add(timeout);
    waitAt.add(now);
    log.add('wait');
    onWait?.call();
    await Future<void>.delayed(endedAfter);
    return endedResult;
  }

  bool isConnected() => connected;
}

/// Runs [plan] to the end on the fake clock and returns what it said.
BuzzDelivery? _run(FakeAsync async, _Band band, HapticPlan plan) {
  BuzzDelivery? out;
  playHapticPlan(
    plan,
    write: band.write,
    waitEnded: band.waitEnded,
    isConnected: band.isConnected,
  ).then((v) => out = v);
  async.elapse(const Duration(minutes: 5));
  return out;
}

void main() {
  test('the plans these tests rely on have several steps', () {
    expect(_plan('N4ff R6 N4f').steps, hasLength(2));
    expect(_plan('N4ff R4 N4ff R6 N4f').steps.length, greaterThanOrEqualTo(2));
  });

  group('order of writes', () {
    test('each step is written with its phrase effects and loop, in order',
        () {
      fakeAsync((async) {
        final plan = _plan('N4ff R4 N4ff R6 N4f');
        final band = _Band(async);
        expect(_run(async, band, plan), BuzzDelivery.complete);
        expect(band.writes, [
          for (final s in plan.steps) '${s.phrase.effects} x${s.phrase.loop}',
        ]);
      });
    });

    test('a wait for the ended event sits between every two writes', () {
      fakeAsync((async) {
        final plan = _plan('N4ff R4 N4ff R6 N4f');
        final band = _Band(async);
        _run(async, band, plan);
        expect(band.log, [
          'write0',
          for (var i = 1; i < plan.steps.length; i++) ...['wait', 'write$i'],
        ]);
      });
    });

    test('a single-step plan writes once and waits for nothing', () {
      fakeAsync((async) {
        final plan = _plan('N4ff');
        expect(plan.steps, hasLength(1));
        final band = _Band(async);
        expect(_run(async, band, plan), BuzzDelivery.complete);
        expect(band.log, ['write0']);
        expect(band.waits, isEmpty);
      });
    });

    test('nothing happens before the first write', () {
      fakeAsync((async) {
        final plan = _plan('N4ff R6 N4f');
        final band = _Band(async);
        _run(async, band, plan);
        expect(band.writeAt.first, 0);
      });
    });
  });

  group('waiting for the band to finish', () {
    test('timeout = the previous phrase\'s longest span + 1500 ms', () {
      fakeAsync((async) {
        final plan = _plan('N4ff R4 N4ff R6 N4f');
        final band = _Band(async);
        _run(async, band, plan);
        expect(band.waits, hasLength(plan.steps.length - 1));
        for (var i = 0; i < band.waits.length; i++) {
          final prev = plan.steps[i].phrase;
          expect(
            band.waits[i],
            Duration(milliseconds: prev.unitsMax * _mg.unitMs + 1500),
            reason: 'wait after step $i (${prev.id})',
          );
        }
      });
    });

    test('unitMs scales the timeout for a profile with another tempo', () {
      fakeAsync((async) {
        final plan = _plan('N4ff R6 N4f');
        final band = _Band(async);
        BuzzDelivery? out;
        playHapticPlan(
          plan,
          write: band.write,
          waitEnded: band.waitEnded,
          isConnected: band.isConnected,
          unitMs: 200,
        ).then((v) => out = v);
        async.elapse(const Duration(minutes: 1));
        expect(out, BuzzDelivery.complete);
        expect(band.waits.single,
            Duration(milliseconds: plan.steps[0].phrase.unitsMax * 200 + 1500));
      });
    });

    test('the next write comes after the ended event plus delayMs', () {
      fakeAsync((async) {
        final plan = _plan('N4ff R6 N4f');
        final delay = plan.steps[1].delayMs;
        expect(delay, 300);
        final band = _Band(async)
          ..endedAfter = const Duration(milliseconds: 1000);
        _run(async, band, plan);
        expect(band.writeAt, [0, 1000 + delay]);
      });
    });

    test('a delay is honoured exactly: one millisecond early nothing is '
        'written', () {
      fakeAsync((async) {
        final plan = _plan('N4ff R6 N4f');
        final band = _Band(async)
          ..endedAfter = const Duration(milliseconds: 1000);
        BuzzDelivery? out;
        playHapticPlan(
          plan,
          write: band.write,
          waitEnded: band.waitEnded,
          isConnected: band.isConnected,
        ).then((v) => out = v);
        async.elapse(const Duration(milliseconds: 1299));
        expect(band.writes, hasLength(1));
        expect(out, isNull);
        async.elapse(const Duration(milliseconds: 1));
        expect(band.writes, hasLength(2));
        async.flushMicrotasks();
        expect(out, BuzzDelivery.complete);
      });
    });

    test('every step\'s own delay applies, accumulated over the plan', () {
      fakeAsync((async) {
        final plan = _plan('N4ff R4 N4ff R6 N4f');
        final band = _Band(async)
          ..endedAfter = const Duration(milliseconds: 700);
        _run(async, band, plan);
        var t = 0;
        final want = <int>[0];
        for (var i = 1; i < plan.steps.length; i++) {
          t += 700 + plan.steps[i].delayMs;
          want.add(t);
        }
        expect(band.writeAt, want);
      });
    });

    test('a zero delay writes the moment the ended event lands', () {
      fakeAsync((async) {
        final plan = _plan('N4ff R4 N4ff');
        expect(plan.steps[1].delayMs, 0);
        final band = _Band(async)
          ..endedAfter = const Duration(milliseconds: 400);
        _run(async, band, plan);
        expect(band.writeAt, [0, 400]);
      });
    });

    test('a wait that times out (false) just carries on', () {
      fakeAsync((async) {
        final plan = _plan('N4ff R6 N4f');
        final band = _Band(async)
          ..endedResult = false
          ..endedAfter = const Duration(seconds: 5);
        expect(_run(async, band, plan), BuzzDelivery.complete);
        expect(band.writes, hasLength(2));
        expect(band.writeAt[1], 5000 + plan.steps[1].delayMs);
      });
    });
  });

  group('outcomes', () {
    test('every step written -> complete', () {
      fakeAsync((async) {
        expect(_run(async, _Band(async), _plan('N4ff R6 N4f')),
            BuzzDelivery.complete);
      });
    });

    test('not connected at the start -> rejected, nothing written', () {
      fakeAsync((async) {
        final band = _Band(async)..connected = false;
        expect(_run(async, band, _plan('N4ff R6 N4f')), BuzzDelivery.rejected);
        expect(band.writes, isEmpty);
        expect(band.waits, isEmpty);
      });
    });

    test('the first write fails -> rejected, no later step is tried', () {
      fakeAsync((async) {
        final band = _Band(async)..writeScript[0] = false;
        expect(_run(async, band, _plan('N4ff R6 N4f')), BuzzDelivery.rejected);
        expect(band.writes, hasLength(1));
        expect(band.waits, isEmpty);
      });
    });

    test('the first write throws -> rejected', () {
      fakeAsync((async) {
        final band = _Band(async)..writeScript[0] = Exception('gatt');
        expect(_run(async, band, _plan('N4ff R6 N4f')), BuzzDelivery.rejected);
        expect(band.writes, hasLength(1));
      });
    });

    test('a later write fails -> partial, and the rest is not sent', () {
      fakeAsync((async) {
        final plan = _plan('N4ff R4 N4ff R6 N4f');
        expect(plan.steps.length, greaterThanOrEqualTo(2));
        final band = _Band(async)..writeScript[1] = false;
        expect(_run(async, band, plan), BuzzDelivery.partial);
        expect(band.writes, hasLength(2));
      });
    });

    test('a later write throws -> partial', () {
      fakeAsync((async) {
        final band = _Band(async)..writeScript[1] = Exception('gatt');
        expect(_run(async, band, _plan('N4ff R6 N4f')), BuzzDelivery.partial);
        expect(band.writes, hasLength(2));
      });
    });

    test('the band drops while waiting for the ended event -> partial, the '
        'second step is never written', () {
      fakeAsync((async) {
        final band = _Band(async);
        band.onWait = () => band.connected = false;
        expect(_run(async, band, _plan('N4ff R6 N4f')), BuzzDelivery.partial);
        expect(band.writes, hasLength(1));
      });
    });

    test('connection is checked again after the delay, before each write', () {
      fakeAsync((async) {
        final plan = _plan('N4ff R6 N4f');
        final band = _Band(async)
          ..endedAfter = const Duration(milliseconds: 100);
        BuzzDelivery? out;
        playHapticPlan(
          plan,
          write: band.write,
          waitEnded: band.waitEnded,
          isConnected: band.isConnected,
        ).then((v) => out = v);
        async.elapse(const Duration(milliseconds: 200));
        band.connected = false; // dropped during the 300 ms delay
        async.elapse(const Duration(seconds: 2));
        expect(band.writes, hasLength(1));
        expect(out, BuzzDelivery.partial);
      });
    });

    test('a failed plan leaves nothing running on the clock', () {
      fakeAsync((async) {
        final band = _Band(async)..writeScript[1] = false;
        _run(async, band, _plan('N4ff R6 N4f'));
        expect(async.pendingTimers, isEmpty);
      });
    });
  });
}
