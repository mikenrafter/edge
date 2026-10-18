// Band buzz delivery is TRI-STATE (review finding H).
//
//   rejected  nothing could have reached the band (not connected, the first
//             write definitively failed)       -> the claim is RELEASED
//   partial   at least one step was written, a later one was not
//                                                -> the claim is KEPT
//   unknown   a step did not answer in time; its queued write may still land
//                                                -> the claim is KEPT
//   complete  every step written                 -> delivered
//
// Before: a step timeout returned plain `false`, the dispatcher released its
// claim, the stuck queued write landed late, and a retry of the same alert
// claimed again and buzzed a second time. A partially written rhythm released
// too and replayed its first pulse. A buzz the player has given up on is also
// dropped when its turn in the GATT write queue comes after its deadline.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/notify/alert_dispatcher.dart';
import 'package:openstrap_edge/notify/alert_rule.dart';
import 'package:openstrap_edge/notify/buzz_sequence.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

const _rule = AlertRule(
  id: 'buzz_preview',
  kind: 'buzzPreview',
  destinations: AlertRule.band,
  executionMode: AlertExecutionMode.phoneLive,
  staleAfter: Duration(seconds: 30),
  channelPolicyId: 'buzz_preview',
);

/// A band writer we control: each call is recorded; [script] decides the
/// result per call (null = hangs until [release]).
class _Writer {
  _Writer(this.script);
  final List<bool?> script;
  final Completer<void> release = Completer<void>();
  int calls = 0;
  int landed = 0; // writes that ended up on the band (late ones included)
  Future<bool> call() async {
    final i = calls++;
    final r = i < script.length ? script[i] : true;
    if (r == null) {
      await release.future;
      landed++; // the stuck write finishes later and DOES reach the band
      return true;
    }
    if (r) landed++;
    return r;
  }
}

class _Rig {
  _Rig(this.writer, {this.connected = true});
  final _Writer writer;
  bool connected;
  final ledger = MemoryAlertDeliveryLedger();
  late final dispatcher = AlertDispatcher(
    phone: () async => false,
    band: () async => true,
    isConnected: () => connected,
    ledger: ledger,
    transportTimeout: const Duration(seconds: 2),
  );

  Future<AlertDeliveryOutcome> send(
    BuzzSequence s, {
    String id = 'alert:1',
    Duration stepTimeout = const Duration(milliseconds: 40),
  }) =>
      dispatcher.dispatch(
        _rule,
        eventId: id,
        sourceTime: DateTime.now(),
        historical: false,
        bandDelivery: () => deliverBuzzSequence(
          s,
          buzz: writer.call,
          isConnected: () => connected,
          stepTimeout: stepTimeout,
        ),
      );
}

void main() {
  final two = BuzzSequence([0, 100]);

  group('deliverBuzzSequence', () {
    Future<BuzzDelivery> run(
      List<bool?> script, {
      bool connected = true,
      Duration step = const Duration(milliseconds: 40),
    }) {
      final w = _Writer(script);
      return deliverBuzzSequence(
        two,
        buzz: w.call,
        isConnected: () => connected,
        stepTimeout: step,
      );
    }

    test('every step written -> complete', () async {
      expect(await run([true, true]), BuzzDelivery.complete);
    });

    test('not connected -> rejected, nothing written', () async {
      expect(await run([true, true], connected: false), BuzzDelivery.rejected);
    });

    test('the first write fails -> rejected', () async {
      expect(await run([false]), BuzzDelivery.rejected);
    });

    test('the first write throws -> rejected', () async {
      final d = await deliverBuzzSequence(
        two,
        buzz: () async => throw StateError('gatt'),
        isConnected: () => true,
      );
      expect(d, BuzzDelivery.rejected);
    });

    test('step 1 written, step 2 fails -> partial', () async {
      expect(await run([true, false]), BuzzDelivery.partial);
    });

    test('link drops between steps -> partial', () async {
      var calls = 0;
      final d = await deliverBuzzSequence(
        two,
        buzz: () async {
          calls++;
          return true;
        },
        isConnected: () => calls == 0,
      );
      expect(d, BuzzDelivery.partial);
    });

    test('the first step never answers -> unknown', () async {
      expect(await run([null]), BuzzDelivery.unknown);
    });

    test('a later step never answers -> unknown (not partial)', () async {
      expect(await run([true, null]), BuzzDelivery.unknown);
    });

    test('playBuzzSequence still reports a plain bool: only complete is true',
        () async {
      Future<bool> play(List<bool?> script, {bool connected = true}) {
        final w = _Writer(script);
        return playBuzzSequence(
          two,
          buzz: w.call,
          isConnected: () => connected,
          stepTimeout: const Duration(milliseconds: 40),
        );
      }

      expect(await play([true, true]), isTrue);
      expect(await play([true, false]), isFalse);
      expect(await play([null]), isFalse);
      expect(await play([true, true], connected: false), isFalse);
    });
  });

  group('AlertDispatcher keeps the claim whenever the band may have buzzed', () {
    test('hung GATT queue: the late write lands, the retry does NOT buzz again',
        () async {
      final w = _Writer([null]);
      final r = _Rig(w);
      final first = await r.send(BuzzSequence([0]));
      expect(first.targets, isEmpty);
      expect(first.suppressionReason, 'deliveryUnconfirmed');
      // The stuck write completes late and reaches the band.
      w.release.complete();
      await Future<void>.delayed(Duration.zero);
      expect(w.landed, 1);
      // The same alert retried: still claimed, no second buzz.
      final retry = await r.send(BuzzSequence([0]));
      expect(retry.targets, isEmpty);
      expect(w.calls, 1, reason: 'no duplicate write');
      expect(w.landed, 1);
    });

    test('partial sequence: the retry does not replay the first pulse',
        () async {
      final w = _Writer([true, false]);
      final r = _Rig(w);
      final first = await r.send(two);
      expect(first.targets, isEmpty);
      expect(first.suppressionReason, 'deliveryUnconfirmed');
      expect(w.landed, 1);
      await r.send(two);
      expect(w.calls, 2, reason: 'one write for pulse 1, one failed pulse 2');
      expect(w.landed, 1, reason: 'pulse 1 was not played a second time');
    });

    test('unknown after a first pulse also keeps the claim', () async {
      final w = _Writer([true, null]);
      final r = _Rig(w);
      await r.send(two);
      w.release.complete();
      await Future<void>.delayed(Duration.zero);
      await r.send(two);
      expect(w.calls, 2);
    });

    test('rejected before any write releases: a retry plays in full', () async {
      final w = _Writer(const []);
      final r = _Rig(w, connected: false);
      final first = await r.send(two);
      expect(first.targets, isEmpty);
      expect(first.suppressionReason, anyOf('bandUnavailable', 'deliveryFailed'));
      expect(w.calls, 0);
      r.connected = true;
      final retry = await r.send(two);
      expect(retry.targets, ['band']);
      expect(w.landed, 2);
    });

    test('the first write failing definitively releases the claim', () async {
      final w = _Writer([false]);
      final r = _Rig(w);
      final first = await r.send(two);
      expect(first.suppressionReason, 'deliveryFailed');
      final retry = await r.send(two);
      expect(retry.targets, ['band']);
      expect(w.landed, 2);
    });

    test('a complete delivery is delivered once and claimed', () async {
      final w = _Writer(const []);
      final r = _Rig(w);
      expect((await r.send(two)).targets, ['band']);
      expect((await r.send(two)).targets, isEmpty);
      expect(w.landed, 2);
    });

    test('the saved-rhythm (implicit) transport is tri-state too', () async {
      final w = _Writer([true, false]);
      final ledger = MemoryAlertDeliveryLedger();
      final d = AlertDispatcher(
        phone: () async => false,
        band: () async => true,
        bandSequenceDelivery: (s) => deliverBuzzSequence(
          s,
          buzz: w.call,
          isConnected: () => true,
          stepTimeout: const Duration(milliseconds: 40),
        ),
        isConnected: () => true,
        ledger: ledger,
      );
      final rule = _rule.copyWith(buzzSequence: two);
      Future<AlertDeliveryOutcome> go() => d.dispatch(rule,
          eventId: 'saved:1', sourceTime: DateTime.now(), historical: false);
      expect((await go()).suppressionReason, 'deliveryUnconfirmed');
      await go();
      expect(w.landed, 1);
    });

    test('a transport that times out at the dispatcher level still keeps '
        'the claim (unchanged)', () async {
      final w = _Writer([null]);
      final d = AlertDispatcher(
        phone: () async => false,
        band: () async => true,
        isConnected: () => true,
        ledger: MemoryAlertDeliveryLedger(),
        transportTimeout: const Duration(milliseconds: 30),
      );
      Future<AlertDeliveryOutcome> go() => d.dispatch(_rule,
          eventId: 'x', sourceTime: DateTime.now(), historical: false,
          bandTransport: w.call);
      expect((await go()).suppressionReason, 'deliveryUnconfirmed');
      await go();
      expect(w.calls, 1);
    });
  });

  group('the GATT write queue drops a buzz whose deadline has passed', () {
    late BleEngine engine;
    late List<int> opcodes;
    Completer<void>? gate;

    setUp(() {
      BleEngine.resetBandClaimForTest();
      engine = BleEngine(onRecord: (_, _) async {}, onState: (_) {});
      opcodes = [];
      engine.debugInstallFakeLink(
        band: BandProfile.gen5,
        listening: true,
        onWrite: (frame) async {
          opcodes.add(parseFrame(frame, profile: BandProfile.gen5)!.inner[2]);
          final g = gate;
          if (g != null && opcodes.length == 1) await g.future;
          return true;
        },
      );
    });
    tearDown(BleEngine.resetBandClaimForTest);

    test('a buzz queued behind a stuck write is dropped once its deadline '
        'passed', () async {
      gate = Completer<void>();
      final stuck = engine.buzzBand(maxQueueWait: const Duration(seconds: 5));
      await Future<void>.delayed(Duration.zero);
      final queued = engine.buzzBand(maxQueueWait: const Duration(milliseconds: 30));
      await Future<void>.delayed(const Duration(milliseconds: 80));
      gate!.complete();
      expect(await stuck, isTrue);
      expect(await queued, isFalse, reason: 'its deadline passed in the queue');
      expect(opcodes, hasLength(1), reason: 'the stale buzz was never written');
    });

    test('a buzz whose deadline has not passed is written after the wait',
        () async {
      gate = Completer<void>();
      final stuck = engine.buzzBand();
      await Future<void>.delayed(Duration.zero);
      final queued = engine.buzzBand(maxQueueWait: const Duration(seconds: 5));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      gate!.complete();
      expect(await stuck, isTrue);
      expect(await queued, isTrue);
      expect(opcodes, hasLength(2));
    });

    test('the default deadline is the sequence player\'s step timeout', () {
      expect(BleEngine.buzzQueueDeadline, const Duration(seconds: 5));
    });
  });
}
