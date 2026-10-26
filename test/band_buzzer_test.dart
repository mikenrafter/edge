import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/band_buzzer.dart';
import 'package:openstrap_edge/ble/default_band_buzzer.dart';

import 'support/band_buzzer_fakes.dart';

void main() {
  final start = DateTime.utc(2026, 10, 25, 6);
  late WakeClock clock;
  late WakeTransport transport;
  late DefaultBandBuzzer buzzer;

  BandBuzzRequest request({String scope = 'morning', int pulses = 3,
      DateTime? expires, BandBuzzKind kind = BandBuzzKind.rampStep}) =>
      BandBuzzRequest(id: '$scope:2', scope: scope,
          expiresAt: expires ?? start.add(const Duration(minutes: 5)),
          kind: kind, stepIndex: 2, stepCount: 6, pulses: pulses);

  setUp(() {
    clock = WakeClock(start);
    transport = WakeTransport(clock);
    buzzer = transport.buzzer();
  });

  test('ramp step sends N pulses with the default 600 ms settle gap', () async {
    expect(await buzzer.play(request()), BandBuzzResult.complete);
    expect(transport.writes, [
      (kind: 'pulse', at: start),
      (kind: 'pulse', at: start.add(const Duration(milliseconds: 600))),
      (kind: 'pulse', at: start.add(const Duration(milliseconds: 1200))),
    ]);
    expect(clock.gaps.take(2), const [
      Duration(milliseconds: 600), Duration(milliseconds: 600)]);
  });

  test('alarm semantic cue uses checked alarm transport', () async {
    expect(await buzzer.play(request(kind: BandBuzzKind.alarm, pulses: 1)),
        BandBuzzResult.complete);
    expect(transport.writes.map((w) => w.kind), ['alarm']);
  });

  test('steady semantic cue sends one ordinary pulse', () async {
    expect(await buzzer.play(request(kind: BandBuzzKind.steadyStep, pulses: 1)),
        BandBuzzResult.complete);
    expect(transport.writes.map((w) => w.kind), ['pulse']);
  });

  test('requests serialize while the first transport write is held', () async {
    final gate = Completer<bool>();
    transport.held = gate;
    addTearDown(() { if (!gate.isCompleted) gate.complete(true); });
    final first = buzzer.play(request(pulses: 2));
    final second = buzzer.play(request(scope: 'other', pulses: 1));
    await wakeMicrotasks();
    expect(transport.writes.map((w) => w.kind), ['pulse']);
    expect(transport.active, 1);
    gate.complete(true);
    expect(await first, BandBuzzResult.complete);
    expect(await second, BandBuzzResult.complete);
    expect(transport.writes, hasLength(3));
    expect(transport.maxActive, 1);
    expect(transport.writes[2].at.difference(transport.writes[1].at),
        greaterThanOrEqualTo(const Duration(milliseconds: 600)));
  });

  test('expiry is rechecked between pulses, including exact expiry', () async {
    final result = await buzzer.play(request(
        expires: start.add(const Duration(milliseconds: 600))));
    expect(transport.writes, [(kind: 'pulse', at: start)]);
    expect(result, BandBuzzResult.partial);
    expect(await buzzer.play(request(scope: 'live', pulses: 1)),
        BandBuzzResult.complete);
    expect(transport.writes, hasLength(2));
  });

  test('expired request sends nothing, a fresh scope still plays', () async {
    expect(await buzzer.play(request(expires: start)), BandBuzzResult.refused);
    expect(transport.writes, isEmpty);
    expect(await buzzer.play(request(scope: 'live', pulses: 1)),
        BandBuzzResult.complete);
    expect(transport.writes.map((w) => w.kind), ['pulse']);
  });

  test('stop during a held write prevents every remaining scoped write', () async {
    final gate = Completer<bool>();
    transport.held = gate;
    addTearDown(() { if (!gate.isCompleted) gate.complete(true); });
    final playing = buzzer.play(request());
    final queued = buzzer.play(request(pulses: 2));
    await wakeMicrotasks();
    expect(transport.writes, hasLength(1));
    buzzer.stop('morning');
    gate.complete(true);
    expect(await playing, BandBuzzResult.partial);
    expect(await queued, BandBuzzResult.refused);
    expect(transport.writes, hasLength(1));
    expect(await buzzer.play(request(scope: 'tomorrow', pulses: 1)),
        BandBuzzResult.complete);
    expect(transport.writes, hasLength(2));
  });

  for (final successful in [0, 1]) {
    test('false write after $successful successes is failed or partial', () async {
      transport.replies.addAll([if (successful == 1) true, false]);
      expect(await buzzer.play(request()), successful == 0
          ? BandBuzzResult.failed : BandBuzzResult.partial);
      expect(transport.writes, hasLength(successful + 1));
      expect(await buzzer.play(request(scope: 'recovery', pulses: 1)),
          BandBuzzResult.complete, reason: 'failure must release serialization');
    });
  }

  test('throwing write reports uncertainty and releases the queue', () async {
    transport.replies.add(StateError('link lost during write'));
    expect(await buzzer.play(request()),
        anyOf(BandBuzzResult.uncertain, BandBuzzResult.failed));
    expect(transport.writes, hasLength(1));
    expect(await buzzer.play(request(scope: 'recovery', pulses: 1)),
        BandBuzzResult.complete);
    expect(transport.writes, hasLength(2));
  });

  test('expiry while queued behind a write prevents the queued write', () async {
    final gate = Completer<bool>();
    transport.held = gate;
    addTearDown(() { if (!gate.isCompleted) gate.complete(true); });
    final first = buzzer.play(request(pulses: 1));
    final queued = buzzer.play(request(scope: 'expires',
        expires: start.add(const Duration(seconds: 1)), pulses: 1));
    await wakeMicrotasks();
    expect(transport.writes, hasLength(1));
    clock.at = start.add(const Duration(seconds: 2));
    gate.complete(true);
    await first;
    expect(await queued, BandBuzzResult.refused);
    expect(transport.writes, hasLength(1));
  });
}
