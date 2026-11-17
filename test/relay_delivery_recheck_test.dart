// WHY: main b5dcf05/5fad49c cancel posts that waited across an off/quiet
// transition. The fork's durable relay must enforce the same at delivery.
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/notify/notification_relay.dart';
import 'package:openstrap_edge/notify/alert_dispatcher.dart';
import 'package:openstrap_edge/notify/buzz_sequence.dart';

void main() {
  for (final transition in ['off', 'quiet', 'stop-restart']) {
    test('a pending relay does not buzz after $transition', () async {
      final entered = Completer<void>(), held = Completer<BuzzSequence?>();
      var enabled = true, quiet = false, buzzes = 0;
      final c = RelayController(
        dispatcher: AlertDispatcher(phone: () async => false,
          band: () async => false, isConnected: () => true,
          ledger: MemoryAlertDeliveryLedger(),
          now: () => DateTime.fromMillisecondsSinceEpoch(1000000)),
        buzz: (_) async { buzzes++; return true; },
        playSequence: (_) async { buzzes++; return true; },
        phone: () async => false,
        defaultSequence: () { entered.complete(); return held.future; },
        nowMs: () => 1000000,
        policy: (_) => {'enabled': enabled, 'packages': ['app'],
          'quietEnabled': quiet, 'quietStartMin': 0, 'quietEndMin': 60,
          'minuteOfDay': 15},
      );
      final pending = c.handleMetadata({'kind': 'post', 'keyHash': 'one',
        'package': 'app', 'category': 'msg', 'postTimeMs': 1000000});
      await entered.future;
      if (transition == 'off') enabled = false;
      if (transition == 'quiet') quiet = true;
      if (transition == 'stop-restart') {
        await c.stop('disarmed');
        await c.listenerConnected(const []);
      }
      held.complete(null);
      await pending;
      expect(buzzes, 0, reason: 'transport is gated after awaited policy work');
      c.dispose();
    });
  }
}
