// A recorded rhythm is one dispatcher delivery, and it can run for up to 14 s
// (8 buzzes, 2 s apart). The dispatcher's flat 10 s transport timeout used to
// report such a rhythm as "unconfirmed" while the band was still buzzing it.
// The band transport's timeout now covers the sequence plus a margin.

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/notify/alert_dispatcher.dart';
import 'package:openstrap_edge/notify/alert_rule.dart';
import 'package:openstrap_edge/notify/buzz_sequence.dart';

const _rule = AlertRule(
  id: 'gesture',
  kind: 'gesture',
  destinations: AlertRule.band,
  executionMode: AlertExecutionMode.phoneLive,
  staleAfter: Duration(seconds: 60),
  channelPolicyId: 'gesture',
);

final _longest = BuzzSequence([for (var i = 0; i < 8; i++) i * 2000]);

AlertDispatcher _dispatcher() => AlertDispatcher(
      phone: () async => false,
      band: () async => true,
      isConnected: () => true,
      supportedBandModes: const {AlertExecutionMode.phoneLive},
      ledger: MemoryAlertDeliveryLedger(),
    );

Future<AlertDeliveryOutcome> _play(AlertDispatcher d, String id,
        {Duration? bandTimeout}) =>
    d.dispatch(
      _rule,
      eventId: id,
      sourceTime: DateTime.now(),
      historical: false,
      bandTimeout: bandTimeout,
      bandTransport: () => playBuzzSequence(_longest,
          buzz: () async => true, isConnected: () => true),
    );

void main() {
  test('the sequence knows how long it runs and asks for a margin on top', () {
    expect(_longest.playTime, const Duration(seconds: 14));
    expect(_longest.transportTimeout, greaterThan(_longest.playTime));
    expect(BuzzSequence([0]).transportTimeout,
        greaterThan(const Duration(milliseconds: 1)));
  });

  test('a 14 s rhythm is delivered when the band timeout covers it', () {
    fakeAsync((async) {
      AlertDeliveryOutcome? out;
      _play(_dispatcher(), 'long', bandTimeout: _longest.transportTimeout)
          .then((o) => out = o);
      async.elapse(const Duration(seconds: 20));
      expect(out?.targets, ['band']);
      expect(out?.suppressionReason, isNull);
    });
  });

  test('without it the flat 10 s timeout still reports unconfirmed (guard)',
      () {
    fakeAsync((async) {
      AlertDeliveryOutcome? out;
      _play(_dispatcher(), 'flat').then((o) => out = o);
      async.elapse(const Duration(seconds: 20));
      expect(out?.suppressionReason, 'deliveryUnconfirmed');
    });
  });

  test('a band timeout never shortens the dispatcher default', () {
    fakeAsync((async) {
      AlertDeliveryOutcome? out;
      _play(_dispatcher(), 'short', bandTimeout: const Duration(seconds: 1))
          .then((o) => out = o);
      async.elapse(const Duration(seconds: 20));
      expect(out?.suppressionReason, 'deliveryUnconfirmed',
          reason: 'the 14 s rhythm needs the 10 s default at least; 1 s does '
              'not make it shorter than that');
    });
  });
}
