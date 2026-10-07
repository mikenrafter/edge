// The tap ack belongs to the gesture whose action already ran, so it is an
// already-started gesture haptic: when the haptic budget goes to 0 between the
// dispatcher's gate check and the ack, the ack still plays, and the ledger
// stays clamped at the limit (nothing it writes is counted past it).

import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/gestures/device_action.dart';
import 'package:openstrap_edge/state/prefs.dart';

import 'support/app_state_gesture_harness.dart';

const _db = 'tap_ack_budget.db';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    BleEngine.resetBandClaimForTest();
    await deriveDbSetUp(_db);
    await resetGesturePrefs();
  });
  tearDown(() async {
    BleEngine.resetBandClaimForTest();
    await deriveDbTearDown(_db);
  });
  tearDown(() => Prefs.setInt(Prefs.hapticsCommandLimit, 30));

  test('the budget goes to 0 while the action runs: the ack still plays and '
      'the ledger never counts past the limit', () async {
    final order = <String>[];
    final channel = ActionChannel(order: order);
    addTearDown(channel.dispose);
    final r = GestureRig(mg: false, order: order);
    addTearDown(r.dispose);
    await r.measureCues();
    await r.app.gestureSettings
        .setDoubleTapActions({DeviceAction.mediaPlayPause});
    final ledger = r.app.haptics.ledger;
    // One command left: the gate lets the tap through.
    ledger.record(r.app.haptics.commandsLeft - 1, clock.now());
    expect(r.app.haptics.commandsLeft, 1);
    // The native action waits, so the budget can go in between.
    final hold = channel.hold = Completer<void>();
    r.doubleTap();
    await until(() => channel.performed.isNotEmpty);
    ledger.record(r.app.haptics.commandsLeft, clock.now()); // now 0 left
    expect(r.app.haptics.commandsLeft, 0);
    hold.complete();
    await until(() => r.cues.isNotEmpty);
    await settleMs(150);
    expect(channel.performed, ['media_play_pause']);
    expect(r.cues, everyElement('confirm'), reason: 'the ack was played');
    expect(order, contains('cue:confirm'));
    expect(r.app.haptics.commandsLeft, 0, reason: 'clamped at the limit');
    // Nothing the ack wrote was counted: only the recorded writes leave the
    // window, and the ledger is back to the full limit once they have.
    expect(ledger.commandsLeft(clock.now().add(const Duration(seconds: 121))),
        30);
  });
}
