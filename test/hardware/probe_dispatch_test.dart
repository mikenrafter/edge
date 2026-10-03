// 8V: the buzz probe's rule through the REAL AlertDispatcher. The 20:17 lab
// run sent 24 probe buzzes and the band got none: the rule's kind was not a
// live kind, so the dispatcher refused every one ('unsupportedRuleKind')
// before a byte was written. The probe tests used a fake sendBuzz and missed it.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/hardware_probe_runner.dart';
import 'package:openstrap_edge/gestures/hardware_probes.dart';
import 'package:openstrap_edge/notify/alert_dispatcher.dart';
import 'package:openstrap_edge/notify/alert_rule.dart';
import 'package:openstrap_edge/notify/buzz_sequence.dart';

void main() {
  test('the probe rule is a band rule the dispatcher accepts', () {
    expect(
        AlertCapabilityRegistry.destinationSupportReason(
            hardwareProbeRule, 'band'),
        isNull);
  });

  test('a probe buzz reaches the band transport', () async {
    var buzzes = 0;
    final d = AlertDispatcher(
      phone: () async => false,
      band: () async => false,
      isConnected: () => true,
      ledger: MemoryAlertDeliveryLedger(),
    );
    final now = DateTime.now();
    final r = await d.dispatch(
      hardwareProbeRule,
      eventId: 'probe:1',
      sourceTime: now,
      historical: false,
      bandDelivery: () async {
        buzzes++;
        return BuzzDelivery.complete;
      },
    );
    expect(r.suppressionReason, isNull);
    expect(r.targets, ['band']);
    expect(buzzes, 1);
  });

  test('a trial in which nothing was written ends the run with the reason',
      () async {
    final steps = <String>[];
    final probe = HapticProbe(
      sendOne: (_) async => false,
      askFelt: (_, _) async => null,
      isConnected: () => true,
      step: steps.add,
      wait: (_) async {},
    );
    final r = await probe.run();
    expect(r, hasLength(1), reason: 'no point buzzing on into nothing');
    expect(r.single.summary, contains('band replied to 0'));
    expect(steps.last, startsWith('Buzz probe ended: the app sent no buzz'));
  });
}
