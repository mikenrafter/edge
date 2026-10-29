// The wake-window prompt watchdog (spec dev-harness §5.1, §9 Part A).
//
// Field case, 2026-10-27: the habitual-wake lease lapsed around 12:21 and
// nothing asked the band again before the 13:00-13:30 window, because the
// keep-alive tick judged "covered" from the engine's own idea of the lease
// (`highFreqUntil`/`highFreqReason`), never from prompts actually arriving.
// The stager got history every 15 min instead of every 61 s.
//
//   * policy: a lease the engine believes in, with no prompt for 150 s, is
//     re-ENTERed; a forced write that landed waits 2 min, anything else
//     retries on the next tick;
//   * engine: the prompt is stamped, an ENTER is stamped, every write says
//     what it did, `force` bypasses the "unchanged" short-circuit, and a
//     superseded caller can neither write nor claim the mode.

import 'dart:async';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/sync/sync_policy.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

Uint8List _eventInner(int id, {int ts = 1786000000}) {
  final inner = Uint8List(12);
  inner[0] = PacketType.event;
  inner[1] = 0x07;
  ByteData.sublistView(inner)
    ..setUint16(2, id, Endian.little)
    ..setUint32(4, ts, Endian.little);
  return inner;
}

class _Ticket implements PromptWriteTicket {
  @override
  bool current = true;
}

bool _isEnter(Uint8List f) {
  final p = parseFrame(f, profile: BandProfile.gen4);
  return p != null && p.valid && p.inner[2] == Cmd.enterHighFreqSync;
}

void main() {
  group('wakeCollectionAction', () {
    // Local wall times: the decision only compares instants, so it must hold
    // the same under any TZ.
    final wakeAt = DateTime(2026, 10, 27, 13, 30);
    final now = DateTime(2026, 10, 27, 13, 5);
    const lease = 'scheduled_alarm';

    WakeCollectionAction decide({
      String? reason = lease,
      DateTime? until,
      DateTime? lastPromptAt,
      DateTime? enteredAt,
      DateTime? lastAttemptAt,
      PromptWriteOutcome? lastOutcome,
      bool noLease = false,
    }) =>
        wakeCollectionAction(
          now: now,
          wakeAt: wakeAt,
          reason: noLease ? null : reason,
          until: noLease ? null : (until ?? wakeAt),
          lastPromptAt: lastPromptAt,
          enteredAt: enteredAt ?? now.subtract(const Duration(hours: 2)),
          lastAttemptAt: lastAttemptAt,
          lastOutcome: lastOutcome,
        );

    Duration s(int n) => Duration(seconds: n);

    test('prompts arriving: the lease is left alone', () {
      expect(decide(lastPromptAt: now.subtract(s(60))),
          WakeCollectionAction.none);
    });

    test('exactly 150 s since the last prompt is still fresh', () {
      expect(decide(lastPromptAt: now.subtract(s(150))),
          WakeCollectionAction.none);
    });

    test('a believed lease with no prompt for 151 s is re-ENTERed', () {
      expect(decide(lastPromptAt: now.subtract(s(151))),
          WakeCollectionAction.forceReenter,
          reason: 'the field night: the engine "covered", the band silent');
    });

    test('a believed lease that never prompted is re-ENTERed once the ENTER '
        'is older than 150 s', () {
      expect(decide(enteredAt: now.subtract(s(151))),
          WakeCollectionAction.forceReenter);
    });

    test('a fresh ENTER gets 150 s for its first prompt', () {
      expect(decide(enteredAt: now.subtract(s(100))),
          WakeCollectionAction.none);
    });

    test('after a forced write that landed, the 2-minute throttle applies', () {
      expect(
          decide(
              lastPromptAt: now.subtract(s(400)),
              lastAttemptAt: now.subtract(s(30)),
              lastOutcome: PromptWriteOutcome.wrote),
          WakeCollectionAction.none);
      expect(
          decide(
              lastPromptAt: now.subtract(s(400)),
              lastAttemptAt: now.subtract(s(121)),
              lastOutcome: PromptWriteOutcome.wrote),
          WakeCollectionAction.forceReenter);
    });

    test('after a failed or skipped attempt the next tick retries', () {
      for (final o in [
        PromptWriteOutcome.failed,
        PromptWriteOutcome.skipped,
        PromptWriteOutcome.unchanged,
      ]) {
        expect(
            decide(
                lastPromptAt: now.subtract(s(400)),
                lastAttemptAt: now.subtract(s(30)),
                lastOutcome: o),
            WakeCollectionAction.forceReenter,
            reason: '$o must not hold the retry for 2 min');
      }
    });

    test('no lease: refresh; a failed refresh retries on the next tick', () {
      expect(decide(noLease: true), WakeCollectionAction.refresh);
      expect(
          decide(
              noLease: true,
              lastAttemptAt: now.subtract(s(30)),
              lastOutcome: PromptWriteOutcome.failed),
          WakeCollectionAction.refresh);
      expect(
          decide(
              noLease: true,
              lastAttemptAt: now.subtract(s(30)),
              lastOutcome: PromptWriteOutcome.wrote),
          WakeCollectionAction.none);
    });

    test('an iOS background lease past the alarm is replaced by a normal '
        'refresh, not a forced re-ENTER of itself', () {
      expect(
          decide(
              reason: kIosBackgroundPromptReason,
              until: wakeAt.add(const Duration(hours: 1)),
              lastPromptAt: now.subtract(s(800))),
          WakeCollectionAction.refresh);
    });

    test('the last three minutes: a silent wake lease is still re-ENTERed '
        'until T (silence is not the renewal margin)', () {
      for (final left in [181, 180, 1]) {
        final at = wakeAt.subtract(s(left));
        expect(
            wakeCollectionAction(
              now: at,
              wakeAt: wakeAt,
              reason: lease,
              until: wakeAt,
              lastPromptAt: at.subtract(s(200)),
              enteredAt: at.subtract(const Duration(hours: 1)),
              lastAttemptAt: null,
              lastOutcome: null,
            ),
            WakeCollectionAction.forceReenter,
            reason: 'T-$left s');
      }
    });

    test('a lease ending before the alarm is a plain refresh', () {
      expect(
          decide(
              until: wakeAt.subtract(const Duration(minutes: 10)),
              lastPromptAt: now.subtract(s(10))),
          WakeCollectionAction.refresh);
    });
  });

  group('the engine', () {
    late BleEngine engine;
    late List<Uint8List> frames;
    late Future<bool> Function(Uint8List) onWrite;

    setUp(() {
      frames = [];
      onWrite = (_) async => true;
      engine = BleEngine(onRecord: (_, _) async {}, onState: (_) {});
      engine.debugInstallFakeLink(onWrite: (f) {
        frames.add(f);
        return onWrite(f);
      });
    });

    int enters() => frames.where(_isEnter).length;
    final target = DateTime(2026, 10, 27, 13, 30);

    /// The stamps read package:clock, so [at] places them.
    Future<PromptWriteOutcome> enter({
      bool force = false,
      PromptWriteTicket? ticket,
      DateTime? at,
    }) =>
        withClock(
            Clock.fixed(at ?? DateTime(2026, 10, 27, 12, 0)),
            () => engine.applyHighFreqWakeWindow(
                  enabled: true,
                  targetWake: target,
                  duration: const Duration(minutes: 90),
                  intervalSeconds: 61,
                  reason: 'scheduled_alarm',
                  force: force,
                  ticket: ticket,
                ));

    test('HIGH_FREQ_SYNC_PROMPT is stamped with the receipt time', () async {
      expect(engine.lastHighFreqPromptAt, isNull);
      withClock(
          Clock.fixed(DateTime(2026, 10, 27, 12, 21, 7)),
          () => engine.debugReceiveFrame(
              Frame(_eventInner(EventId.highFreqSyncPrompt), true, true),
              role: 'events'));
      expect(engine.lastHighFreqPromptAt, DateTime(2026, 10, 27, 12, 21, 7));
    });

    test('a landed ENTER is stamped; a failed one is not', () async {
      onWrite = (_) async => false;
      await enter();
      expect(engine.highFreqEnteredAt, isNull);
      onWrite = (_) async => true;
      await enter(at: DateTime(2026, 10, 27, 12, 5));
      expect(engine.highFreqEnteredAt, DateTime(2026, 10, 27, 12, 5));
    });

    test('each write says what it did', () async {
      onWrite = (_) async => false;
      expect(await enter(), PromptWriteOutcome.failed);
      onWrite = (_) async => true;
      expect(await enter(), PromptWriteOutcome.wrote);
      expect(await enter(), PromptWriteOutcome.unchanged);
      await engine.debugDropLink();
      expect(await enter(), PromptWriteOutcome.skipped);
    });

    test('force re-sends an unchanged ENTER and re-stamps it', () async {
      await enter();
      expect(enters(), 1);
      expect(await enter(force: true, at: DateTime(2026, 10, 27, 12, 10)),
          PromptWriteOutcome.wrote);
      expect(enters(), 2,
          reason: 'the "unchanged" short-circuit trusted the engine\'s own '
              'claim, which is the thing the watchdog doubts');
      expect(engine.highFreqEnteredAt, DateTime(2026, 10, 27, 12, 10));
    });

    test('a command whose ticket goes stale while it waits in the write '
        'queue is never sent', () async {
      final gate = Completer<bool>();
      onWrite = (f) => _isEnter(f) && !gate.isCompleted
          ? gate.future
          : Future.value(true);
      // An earlier, unticketed ENTER holds the queue on the wire.
      final first = enter();
      await pumpEventQueue();
      expect(enters(), 1);
      final ticket = _Ticket();
      final queued = enter(force: true, ticket: ticket);
      await pumpEventQueue();
      ticket.current = false;
      gate.complete(true);
      await first;
      expect(await queued, PromptWriteOutcome.skipped);
      expect(enters(), 1, reason: 'checked before transport, not only after');
    });

    int durationOf(Uint8List f) {
      final p = parseFrame(f, profile: BandProfile.gen4)!;
      return p.inner[6] | (p.inner[7] << 8);
    }

    test('a forced ENTER at T-2 min asks for at most the 120 s left, and the '
        'engine end stays T', () async {
      await enter();
      expect(durationOf(frames.where(_isEnter).last), 90 * 60);
      expect(await enter(force: true, at: target.subtract(const Duration(minutes: 2))),
          PromptWriteOutcome.wrote);
      expect(enters(), 2);
      expect(durationOf(frames.where(_isEnter).last), lessThanOrEqualTo(120),
          reason: 'a full lease would keep 61 s prompting long past T');
      expect(engine.highFreqUntil, target);
    });

    test('a forced ENTER at or after T is not sent', () async {
      await enter();
      expect(await enter(force: true, at: target.add(const Duration(seconds: 1))),
          PromptWriteOutcome.skipped);
      expect(enters(), 1);
    });

    test('a forced ENTER requested at T-120 s but held in the write queue '
        'until T-20 s asks for at most 20 s', () async {
      var now = target.subtract(const Duration(seconds: 120));
      await withClock(Clock(() => now), () async {
        final gate = Completer<bool>();
        onWrite = (f) => _isEnter(f) && !gate.isCompleted
            ? gate.future
            : Future.value(true);
        final first = engine.applyHighFreqWakeWindow(
            enabled: true,
            targetWake: target,
            duration: const Duration(minutes: 90),
            intervalSeconds: 61,
            reason: 'scheduled_alarm');
        await pumpEventQueue();
        final forced = engine.applyHighFreqWakeWindow(
            enabled: true,
            targetWake: target,
            duration: const Duration(minutes: 90),
            intervalSeconds: 61,
            reason: 'scheduled_alarm',
            force: true);
        await pumpEventQueue();
        now = target.subtract(const Duration(seconds: 20));
        gate.complete(true);
        await first;
        expect(await forced, PromptWriteOutcome.wrote);
        expect(enters(), 2);
        expect(durationOf(frames.where(_isEnter).last), lessThanOrEqualTo(20),
            reason: 'the lease is computed when the frame reaches transport');
        expect(engine.highFreqUntil, target);
      });
    });

    test('a forced ENTER that reaches transport after T is dropped and '
        'reported skipped, not failed', () async {
      var now = target.subtract(const Duration(seconds: 5));
      await withClock(Clock(() => now), () async {
        final gate = Completer<bool>();
        onWrite = (f) => _isEnter(f) && !gate.isCompleted
            ? gate.future
            : Future.value(true);
        final first = engine.applyHighFreqWakeWindow(
            enabled: true,
            targetWake: target,
            duration: const Duration(minutes: 90),
            intervalSeconds: 61,
            reason: 'scheduled_alarm');
        await pumpEventQueue();
        final forced = engine.applyHighFreqWakeWindow(
            enabled: true,
            targetWake: target,
            duration: const Duration(minutes: 90),
            intervalSeconds: 61,
            reason: 'scheduled_alarm',
            force: true);
        await pumpEventQueue();
        now = target.add(const Duration(seconds: 1));
        gate.complete(true);
        await first;
        expect(await forced, PromptWriteOutcome.skipped,
            reason: 'nothing was attempted on the wire');
        expect(enters(), 1);
      });
    });

    test('a superseded caller writes nothing and claims nothing', () async {
      expect(await enter(ticket: _Ticket()..current = false),
          PromptWriteOutcome.skipped);
      expect(enters(), 0);
      expect(engine.highFreqReason, isNull);
    });

    test('a caller superseded while its ENTER is on the wire does not claim '
        'the mode', () async {
      final gate = Completer<bool>();
      onWrite = (f) => _isEnter(f) ? gate.future : Future.value(true);
      final ticket = _Ticket();
      final pending = enter(ticket: ticket);
      await pumpEventQueue();
      expect(enters(), 1);
      ticket.current = false;
      gate.complete(true);
      expect(await pending, PromptWriteOutcome.skipped);
      expect(engine.highFreqReason, isNull);
      expect(engine.highFreqUntil, isNull);
      expect(engine.offloadSnapshot['high_freq_requested'], isFalse);
    });
  });
}
