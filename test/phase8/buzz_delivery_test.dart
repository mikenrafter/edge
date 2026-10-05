// Band buzz delivery: a buzz is delivered when the GATT write lands, exactly as
// every other haptic and toggle write is judged. The band's correlated reply is
// logged for the Device lab and NEVER gates anything. A previous pass made every
// buzz wait for a SUCCESS reply the band does not appear to send, so previews said
// "The band did not play it" and ECG tap sessions gave up with ack_failed.
//
// These tests drive the real engine on a fake link that NEVER replies, through
// the same dispatcher + playBuzzSequence wiring AppState uses.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/gestures/ecg_tap_session.dart';
import 'package:openstrap_edge/notify/alert_dispatcher.dart';
import 'package:openstrap_edge/notify/alert_rule.dart';
import 'package:openstrap_edge/notify/buzz_sequence.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

import 'support/dart_source.dart';

class _SilentLink {
  _SilentLink({BandProfile band = BandProfile.gen5}) {
    engine = BleEngine(onRecord: (_, _) async {}, onState: (_) {});
    engine.debugInstallFakeLink(
      band: band,
      listening: true,
      onWrite: (frame) async {
        final inner = parseFrame(frame, profile: band)!.inner;
        opcodes.add(inner[2]);
        return writeOk; // and never a reply
      },
    );
  }

  late final BleEngine engine;
  final opcodes = <int>[];
  bool writeOk = true;

  AlertDispatcher dispatcher() => AlertDispatcher(
    phone: () async => false,
    band: () async => engine.buzzBand(),
    bandSequence: (s) => playBuzzSequence(
      s,
      buzz: () => engine.buzzBand(),
      buzzForDuration: (h) => engine.buzzBand(holdMs: h),
      isConnected: () => engine.isConnected,
    ),
    isConnected: () => engine.isConnected,
    ledger: MemoryAlertDeliveryLedger(),
  );
}

const _previewRule = AlertRule(
  id: 'buzz_preview',
  kind: 'buzzPreview',
  destinations: AlertRule.band,
  executionMode: AlertExecutionMode.phoneLive,
  staleAfter: Duration(seconds: 10),
  channelPolicyId: 'buzz_preview',
);

/// What AppState._ecgTapBuzz and previewBuzzSequence do, on this link.
Future<bool> _preview(_SilentLink l, BuzzSequence s) async {
  final r = await l.dispatcher().dispatch(
    _previewRule,
    eventId: 'preview:1',
    sourceTime: DateTime.now(),
    historical: false,
    bandTimeout: s.transportTimeout,
    bandTransport: () => playBuzzSequence(
      s,
      buzz: () => l.engine.buzzBand(),
      buzzForDuration: (h) => l.engine.buzzBand(holdMs: h),
      isConnected: () => l.engine.isConnected,
    ),
  );
  return r.targets.contains('band');
}

void main() {
  setUp(BleEngine.resetBandClaimForTest);
  tearDown(BleEngine.resetBandClaimForTest);

  group('a band that never replies', () {
    test('preview of a plain rhythm is delivered', () async {
      final l = _SilentLink();
      expect(await _preview(l, BuzzSequence([0, 300, 600])), isTrue);
      expect(l.opcodes, hasLength(3));
    });

    test('preview with a held press is delivered on MG with loop 2', () async {
      final l = _SilentLink();
      final s = BuzzSequence([0, 1000], durationsMs: [750, 80]);
      expect(await _preview(l, s), isTrue);
      expect(l.opcodes, hasLength(2));
    });

    test('a saved rule rhythm (implicit sequence transport) is delivered',
        () async {
      final l = _SilentLink();
      final rule = _previewRule.copyWith(buzzSequence: BuzzSequence([0, 400]));
      final out = await l.dispatcher().dispatch(
        rule,
        eventId: 'rule:1',
        sourceTime: DateTime.now(),
        historical: false,
      );
      expect(out.targets, ['band']);
      expect(l.opcodes, hasLength(2));
    });

    test('the ECG two-pulse count buzz is delivered', () async {
      final l = _SilentLink();
      final r = await l.dispatcher().dispatch(
        kEcgTapRule,
        eventId: 'tap:ecg:0',
        sourceTime: DateTime.now(),
        historical: false,
        bandTimeout: const Duration(seconds: 12),
        bandTransport: () => playBuzzSequence(
          BuzzSequence([0, 300]),
          buzz: () => l.engine.buzzBand(),
          isConnected: () => l.engine.isConnected,
        ),
      );
      expect(r.targets, ['band']);
      expect(l.opcodes, hasLength(2));
    });
  });

  group('a failed write is the failure', () {
    test('preview is not delivered and stops at the first failed step',
        () async {
      final l = _SilentLink()..writeOk = false;
      expect(await _preview(l, BuzzSequence([0, 300, 600])), isFalse);
      expect(l.opcodes, hasLength(1));
    });
  });

  group('playBuzzSequence with a long hold and no duration-aware buzz', () {
    test('degrades to a short buzz and keeps playing', () async {
      var buzzes = 0;
      final ok = await playBuzzSequence(
        BuzzSequence([0, 1000], durationsMs: [750, 80]),
        buzz: () async {
          buzzes++;
          return true;
        },
        isConnected: () => true,
      );
      expect(ok, isTrue);
      expect(buzzes, 2);
    });
  });

  group('timeouts no longer budget a reply wait per step', () {
    test('transportTimeout is the play time plus a short write allowance', () {
      final s = BuzzSequence([0, 500, 1000]);
      expect(s.transportTimeout, s.playTime + const Duration(seconds: 7));
    });
  });

  group('wiring (source guard)', () {
    final app = codeOnly(File('lib/state/app_state.dart').readAsStringSync());

    test('every AppState band buzz goes through engine.buzzBand', () {
      expect(app, contains('engine.buzzBand('));
    });
  });
}
