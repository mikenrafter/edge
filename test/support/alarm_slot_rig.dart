// A fake band with a few alarm slots, wired to a real AlarmSlotProbeRunner,
// shared by the alarm-slot probe's unit and widget tests.

import 'dart:async';

import 'package:clock/clock.dart';
import 'package:openstrap_edge/ble/ble_state.dart';
import 'package:openstrap_edge/gestures/alarm_slot_probe.dart';
import 'package:openstrap_edge/gestures/lab_log.dart';
import 'package:openstrap_edge/gestures/strap_event.dart';
import 'package:openstrap_edge/haptics/band_queue.dart';

final DateTime kAlarmSlotT0 = DateTime(2026, 10, 7, 3, 0);
int slotSec(DateTime t) => t.millisecondsSinceEpoch ~/ 1000;

StrapEvent slotEvent(int id, int ts, [DateTime? at]) => StrapEvent(
      eventId: id,
      tsEpoch: ts,
      receivedAt: at ?? clock.now(),
      hex: '',
      deviceId: 'd',
    );

/// A fake band with [capacity] alarm slots, wired to a real runner. The real
/// alarm [heldIn] is measured from the clock when the rig is built.
class AlarmSlotRig {
  AlarmSlotRig({
    this.family = 'gen5',
    this.capacity = 2,
    Duration? heldIn = const Duration(hours: 4),
    this.restoreOk = true,
    BandCommandLedger? ledger,
  })  : held = heldIn == null ? null : slotSec(clock.now().add(heldIn)),
        ledger = ledger ?? BandCommandLedger() {
    runner = AlarmSlotProbeRunner(
      lab: DeviceLabLog(),
      family: () => family,
      developerMode: () => dev,
      isConnected: () => connected,
      heldEpoch: () => held,
      armBusy: () => armBusy,
      arm: arm,
      read: read,
      clear: clear,
      restore: restore,
      log: logs.add,
      ledger: this.ledger,
    );
    final h = held;
    if (h != null) stored[0] = h; // the real alarm, on slot 0 / gen5 id 1
  }

  String? family;
  final int capacity;
  int? held;
  bool dev = true, connected = true, armBusy = false;
  bool restoreOk;
  final BandCommandLedger ledger;
  late final AlarmSlotProbeRunner runner;

  /// Every band-facing call, in order.
  final calls = <String>[];
  final logs = <String>[];

  /// slot -> strap epoch the band holds for it.
  final stored = <int, int>{};
  // The band's pending fires: a slot that is replaced or cleared never fires.
  final _fires = <int, Timer>{};

  void _drop(int slot) {
    stored.remove(slot);
    _fires.remove(slot)?.cancel();
  }

  void _dropAll() {
    for (final s in stored.keys.toList()) {
      _drop(s);
    }
  }

  /// Slots whose alarm fires (event 57) when its epoch comes.
  bool fires = true;
  Future<AlarmSlotWrite> Function(int slot, DateTime when)? onArm;
  Object? restoreThrows;
  bool readThrows = false;

  int get bandWrites => calls
      .where((c) =>
          c.startsWith('arm') || c.startsWith('read') || c.startsWith('clear'))
      .length;

  Future<AlarmSlotWrite> arm(int slot, DateTime when) async {
    calls.add('arm$slot');
    final custom = onArm;
    if (custom != null) return custom(slot, when);
    final epoch = slotSec(when);
    if (capacity == 1) _dropAll();
    _drop(slot);
    stored[slot] = epoch;
    if (fires) {
      _fires[slot] = Timer(when.difference(clock.now()), () {
        if (stored[slot] != epoch) return; // replaced or cleared: no fire
        runner.onBandEvent(slotEvent(57, epoch));
        _drop(slot); // one-shot, the band auto-disables
      });
    }
    return AlarmSlotWrite(
      written: true,
      answered: true,
      rejected: false,
      resultStatus: 1,
      alarmStatus: 1,
      alarmStatusName: 'valid_input_pattern',
      wallSec: epoch,
      strapSec: epoch,
    );
  }

  Future<AlarmSlotRead> read(int slot) async {
    calls.add('read$slot');
    if (readThrows) throw StateError('link dropped');
    if (family == 'gen4') {
      // No index operand: the band reports one alarm, the last it was given.
      final e = stored.values.isEmpty ? null : stored.values.last;
      return AlarmSlotRead(answered: true, epoch: e);
    }
    final e = stored[slot];
    return AlarmSlotRead(answered: true, epoch: e, active: e != null);
  }

  Future<bool> clear(int slot) async {
    calls.add('clear$slot');
    if (family == 'gen4') {
      _dropAll(); // DISABLE has no index: it clears what it clears
    } else {
      _drop(slot);
    }
    return true;
  }

  Future<bool> restore(int epoch) async {
    calls.add('restore:$epoch');
    final boom = restoreThrows;
    if (boom != null) throw boom;
    if (!restoreOk) return false;
    _drop(0);
    stored[0] = epoch;
    return true;
  }
}

