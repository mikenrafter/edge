// 8H — Tap acknowledgement buzz.
//
// A LIVE double tap where at least one action ran gets exactly one band buzz,
// delivered through AlertDispatcher as a band-only, live-only rule. Late taps,
// duplicates and taps where nothing ran get none. The ack is claimed once per
// tap identity. See test/phase8/CONTRACTS.md §8H.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/device_action.dart';
import 'package:openstrap_edge/gestures/gesture_dispatcher.dart';
import 'package:openstrap_edge/gestures/strap_event.dart';
import 'package:openstrap_edge/gestures/tap_ack.dart';
import 'package:openstrap_edge/notify/alert_dispatcher.dart';
import 'package:openstrap_edge/notify/alert_rule.dart';

import 'support/dart_source_lexical.dart';

final DateTime _t0 = DateTime.utc(2026, 10, 2, 8, 0, 0);
final int _t0Sec = _t0.millisecondsSinceEpoch ~/ 1000;

StrapEvent _tap({
  Duration late = const Duration(seconds: 1),
  int tsEpoch = -1,
  DateTime? receivedAt,
  int subsec = 0,
}) {
  final ts = tsEpoch == -1 ? _t0Sec : tsEpoch;
  return StrapEvent(
    eventId: 14,
    tsEpoch: ts,
    tsSubsec: subsec,
    receivedAt: receivedAt ??
        DateTime.fromMillisecondsSinceEpoch(ts * 1000, isUtc: true).add(late),
    hex: '',
    deviceId: 'band',
  );
}

GestureOutcome _o(GestureStatus s,
        [DeviceAction a = DeviceAction.markMoment]) =>
    GestureOutcome(action: a, status: s, timeSource: EventTimeSource.strap);

/// A dispatcher whose DEFAULT band transport counts buzzes. The ack must use
/// that default (AppState's alertDispatcher band transport is the engine
/// buzz), so ackTap takes no transport of its own.
class _Rig {
  _Rig(DateTime now) {
    dispatcher = AlertDispatcher(
      phone: () async => false,
      band: () async {
        buzzes++;
        return true;
      },
      isConnected: () => true,
      ledger: MemoryAlertDeliveryLedger(),
      now: () => now,
    );
  }
  late final AlertDispatcher dispatcher;
  int buzzes = 0;
}

void main() {
  group('shouldAckTap (pure)', () {
    test('live tap with one action ran -> ack', () {
      expect(shouldAckTap(_tap(), [_o(GestureStatus.ran)]), isTrue);
    });

    test('live tap where one action ran and another failed -> ack', () {
      expect(
          shouldAckTap(_tap(), [
            _o(GestureStatus.failed, DeviceAction.torch),
            _o(GestureStatus.ran),
          ]),
          isTrue);
    });

    test('late tap -> no ack, even when a replayable action ran', () {
      final late = _tap(late: const Duration(hours: 2));
      expect(late.isLive, isFalse);
      expect(shouldAckTap(late, [_o(GestureStatus.ran)]), isFalse);
    });

    test('duplicate -> no ack', () {
      expect(
          shouldAckTap(_tap(), [_o(GestureStatus.skippedDuplicate)]), isFalse);
    });

    test('every action failed -> no ack', () {
      expect(
          shouldAckTap(_tap(), [
            _o(GestureStatus.failed),
            _o(GestureStatus.failed, DeviceAction.torch),
          ]),
          isFalse);
    });

    test('every action skipped stale -> no ack', () {
      expect(shouldAckTap(_tap(), [_o(GestureStatus.skippedStale)]), isFalse);
    });

    test('no actions mapped -> no ack', () {
      expect(shouldAckTap(_tap(), const []), isFalse);
    });

    test('a non-double-tap event never acks', () {
      final e = StrapEvent(
        eventId: 7,
        tsEpoch: _t0Sec,
        receivedAt: _t0.add(const Duration(seconds: 1)),
        hex: '',
        deviceId: 'band',
      );
      expect(shouldAckTap(e, [_o(GestureStatus.ran)]), isFalse);
    });
  });

  group('kGestureAckRule', () {
    test('band-only, live-only, phone-live, short stale deadline, no fallback',
        () {
      const r = kGestureAckRule;
      expect(r.id, 'gesture_ack');
      expect(r.destinations, AlertRule.band);
      expect(r.enabled, isTrue);
      expect(r.executionMode, AlertExecutionMode.phoneLive);
      expect(r.historicalReplay, AlertHistoricalReplay.liveOnly);
      expect(r.fallback, AlertFallback.none);
      expect(r.staleAfter, greaterThan(Duration.zero));
      expect(r.staleAfter, lessThanOrEqualTo(kLiveEventWindow));
      expect(
          AlertCapabilityRegistry.destinationSupportReason(r, 'band'), isNull,
          reason: 'the registry must accept band delivery for this rule');
    });
  });

  group('ackTap through AlertDispatcher', () {
    test('live tap -> exactly one band buzz', () async {
      final e = _tap();
      final rig = _Rig(e.receivedAt);
      expect(await ackTap(rig.dispatcher, e, [_o(GestureStatus.ran)]), isTrue);
      expect(rig.buzzes, 1);
    });

    test('the same tap acked twice buzzes once (claimed per tap identity)',
        () async {
      final e = _tap();
      final rig = _Rig(e.receivedAt);
      await ackTap(rig.dispatcher, e, [_o(GestureStatus.ran)]);
      final again =
          await ackTap(rig.dispatcher, e, [_o(GestureStatus.ran)]);
      expect(again, isFalse);
      expect(rig.buzzes, 1);
    });

    test('two distinct live taps buzz twice', () async {
      final a = _tap();
      final b = _tap(subsec: 16384);
      final rig = _Rig(b.receivedAt);
      await ackTap(rig.dispatcher, a, [_o(GestureStatus.ran)]);
      await ackTap(rig.dispatcher, b, [_o(GestureStatus.ran)]);
      expect(rig.buzzes, 2);
    });

    test('stale tap -> no buzz', () async {
      final e = _tap(late: const Duration(hours: 2));
      final rig = _Rig(e.receivedAt);
      expect(await ackTap(rig.dispatcher, e, [_o(GestureStatus.ran)]), isFalse);
      expect(rig.buzzes, 0);
    });

    test('duplicate -> no buzz', () async {
      final e = _tap();
      final rig = _Rig(e.receivedAt);
      await ackTap(rig.dispatcher, e, [_o(GestureStatus.skippedDuplicate)]);
      expect(rig.buzzes, 0);
    });

    test('all actions failed -> no buzz', () async {
      final e = _tap();
      final rig = _Rig(e.receivedAt);
      await ackTap(rig.dispatcher, e, [_o(GestureStatus.failed)]);
      expect(rig.buzzes, 0);
    });

    test('a reconnect long after the tap never replays the ack', () async {
      // Ack attempted 30 s after a live tap: past the rule's stale deadline.
      final e = _tap();
      final rig = _Rig(e.receivedAt.add(const Duration(seconds: 30)));
      await ackTap(rig.dispatcher, e, [_o(GestureStatus.ran)]);
      expect(rig.buzzes, 0);
    });

    test('unbelievable strap clock: two taps 3 s apart are two acks',
        () async {
      // tsEpoch 5 is an unset RTC: every tap shares one identity, so the ack
      // claim must also carry the receipt time or the second tap is swallowed.
      final first = _tap(tsEpoch: 5, receivedAt: _t0);
      final second =
          _tap(tsEpoch: 5, receivedAt: _t0.add(const Duration(seconds: 3)));
      expect(first.plausible, isFalse);
      var now = first.receivedAt;
      var buzzes = 0;
      final d = AlertDispatcher(
        phone: () async => false,
        band: () async {
          buzzes++;
          return true;
        },
        isConnected: () => true,
        ledger: MemoryAlertDeliveryLedger(),
        now: () => now,
      );
      await ackTap(d, first, [_o(GestureStatus.ran)]);
      now = second.receivedAt;
      await ackTap(d, second, [_o(GestureStatus.ran)]);
      expect(buzzes, 2);
    });

    test('band disconnected -> no buzz and no phone fallback', () async {
      final e = _tap();
      var band = 0, phone = 0;
      final d = AlertDispatcher(
        phone: () async {
          phone++;
          return true;
        },
        band: () async {
          band++;
          return true;
        },
        isConnected: () => false,
        ledger: MemoryAlertDeliveryLedger(),
        now: () => e.receivedAt,
      );
      expect(await ackTap(d, e, [_o(GestureStatus.ran)]), isFalse);
      expect((band, phone), (0, 0));
    });
  });

  group('AppState wiring (source guard)', () {
    final src = File('lib/state/app_state.dart').readAsStringSync();
    final live = bodyOf(src, 'void _onLiveEvent(');

    test('the live event path sends the ack via ackTap and alertDispatcher',
        () {
      expect(live, isNotEmpty, reason: '_onLiveEvent must still exist');
      expect(live, contains('ackTap('));
      expect(live, contains('alertDispatcher'));
    });

    test('the live event path never buzzes the engine directly', () {
      expect(codeOnly(live), isNot(contains('engine.buzz')));
      expect(codeOnly(live), isNot(contains('buzzPattern(')));
    });

    test('the headless drain never acks', () {
      final bg = File('lib/sync/background_sync.dart').readAsStringSync();
      expect(codeOnly(bg), isNot(contains('ackTap(')));
    });
  });
}
