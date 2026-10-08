// A fake WHOOP 5 band for the termination probe: alarm slots (id 1 is the
// wearer's, the probe's is the other), an app-pattern player and a scripted
// wearer. Everything the band would send back is fed to a real
// TerminationProbeRunner. Shared by the probe's unit and widget tests.

import 'dart:async';

import 'package:clock/clock.dart';
import 'package:openstrap_edge/ble/ble_state.dart';
import 'package:openstrap_edge/gestures/lab_log.dart';
import 'package:openstrap_edge/gestures/strap_event.dart';
import 'package:openstrap_edge/gestures/termination_probe.dart';
import 'package:openstrap_edge/haptics/band_queue.dart';
import 'package:openstrap_edge/sync/sync_policy.dart' show ClockRef;

import 'alarm_slot_rig.dart' show slotSec;

/// The raw sub-second the fake band stamps its events with (0.5 s).
const int kRigSubsec = 16384;

class TerminationRig {
  TerminationRig({
    this.family = 'gen5',
    Duration? heldIn = const Duration(hours: 4),
    Duration? bandOnlyAlarmIn,
    this.capacity = 2,
    this.restoreOk = true,
    BandCommandLedger? ledger,
  })  : held = heldIn == null ? null : slotSec(clock.now().add(heldIn)),
        ledger = ledger ?? BandCommandLedger() {
    runner = TerminationProbeRunner(
      lab: DeviceLabLog(),
      family: () => family,
      developerMode: () => dev,
      isConnected: () => connected,
      heldEpoch: () => held,
      armBusy: () => armBusy,
      sendPattern: sendPattern,
      arm: arm,
      read: read,
      clear: clear,
      restore: restore,
      log: logs.add,
      ledger: this.ledger,
      clockRef: () => ref,
    );
    final h = held;
    if (h != null) stored[0] = h; // the wearer's alarm, gen5 id 1
    if (bandOnlyAlarmIn != null) {
      stored[0] = slotSec(clock.now().add(bandOnlyAlarmIn));
    }
  }

  String? family;

  /// The strap-clock correlation the fake engine reports (null: none yet).
  ClockRef? ref;
  final int capacity;
  int? held;
  bool dev = true, connected = true, armBusy = false, restoreOk;
  final BandCommandLedger ledger;
  late final TerminationProbeRunner runner;

  /// Every band-facing call, in order: `arm1`, `read0`, `clear1`,
  /// `restore:<epoch>`, `pattern:<effects>x<loop>`.
  final calls = <String>[];
  final logs = <String>[];

  /// Elapsed-from-[clockZero] of each pattern write, with its effect count and
  /// loop, and of each arm with its lead in seconds.
  final patternWrites = <(Duration, int, int)>[];
  final armLeads = <int>[];
  late DateTime clockZero = clock.now();

  /// slot -> strap epoch the band holds for it.
  final stored = <int, int>{};
  final _fires = <int, Timer>{};

  // ── scripting ─────────────────────────────────────────────────────────────

  /// How long the short / long app pattern plays; the alarm's haptics.
  Duration shortPattern = const Duration(seconds: 2);
  Duration longPattern = const Duration(seconds: 14);
  Duration alarmPlays = const Duration(seconds: 3);

  /// The wearer double-taps this long after the haptics start (null: never).
  Duration? tapAfter;

  /// Whether the band sends HAPTICS_TERMINATED when haptics end naturally.
  bool sendsTerminated = true;

  /// An alarm that fires while an app pattern plays ends the pattern first
  /// with this HAPTICS_TERMINATED code (null: the pattern plays on).
  int? alarmEndsPatternWith = 1;

  /// Alarms fire (57) when their epoch comes.
  bool fires = true;
  Future<AlarmSlotWrite> Function(int slot, DateTime when)? onArm;
  Future<bool> Function(List<int> effects, int loop)? onPattern;
  Object? restoreThrows;
  bool clearOk = true;

  Timer? _patternEnd, _alarmEnd;
  bool _patternActive = false;

  int get alarmWrites => calls
      .where((c) =>
          c.startsWith('arm') || c.startsWith('clear') || c.startsWith('restore'))
      .length;

  // ── events the band sends ─────────────────────────────────────────────────

  StrapEvent event(int id, {int? code, int? ts, int subsec = kRigSubsec}) {
    final decoded = id == 100 && code != null
        ? <String, dynamic>{
            'haptics_revision': 1,
            'haptics_termination_code': code,
            'haptics_termination': switch (code) {
              0 => 'expired',
              1 => 'error',
              2 => 'user_double_tap',
              _ => 'code_$code',
            },
          }
        : const <String, dynamic>{};
    return StrapEvent(
      eventId: id,
      tsEpoch: ts ?? slotSec(clock.now()),
      tsSubsec: subsec,
      receivedAt: clock.now(),
      hex: 'aa01${id.toRadixString(16)}',
      deviceId: 'd',
      name: 'EV$id',
      decoded: decoded,
    );
  }

  void emit(int id, {int? code, int? ts}) =>
      runner.onBandEvent(event(id, code: code, ts: ts));

  void _hapticsStart(Duration natural, {required bool pattern}) {
    final tap = tapAfter;
    if (tap != null && tap < natural) {
      Timer(tap, () {
        emit(14);
        emit(100, code: 2);
        _end(pattern);
      });
      return;
    }
    final t = Timer(natural, () {
      _end(pattern);
      if (sendsTerminated) emit(100, code: 0);
    });
    if (pattern) {
      _patternEnd = t;
    } else {
      _alarmEnd = t;
    }
  }

  void _end(bool pattern) {
    if (pattern) {
      _patternActive = false;
      _patternEnd?.cancel();
    } else {
      _alarmEnd?.cancel();
    }
  }

  // ── the band ──────────────────────────────────────────────────────────────

  Future<bool> sendPattern(List<int> effects, int loop) async {
    calls.add('pattern:${effects.length}x$loop');
    patternWrites.add((clock.now().difference(clockZero), effects.length, loop));
    final custom = onPattern;
    if (custom != null) return custom(effects, loop);
    _patternActive = true;
    _hapticsStart(effects.length > 2 ? longPattern : shortPattern,
        pattern: true);
    return true;
  }

  void _drop(int slot) {
    stored.remove(slot);
    _fires.remove(slot)?.cancel();
  }

  Future<AlarmSlotWrite> arm(int slot, DateTime when) async {
    calls.add('arm$slot');
    armLeads.add(when.difference(clock.now()).inSeconds);
    final custom = onArm;
    if (custom != null) return custom(slot, when);
    final epoch = slotSec(when);
    if (capacity == 1) {
      for (final s in stored.keys.toList()) {
        _drop(s);
      }
    }
    _drop(slot);
    stored[slot] = epoch;
    if (fires) {
      _fires[slot] = Timer(when.difference(clock.now()), () {
        if (stored[slot] != epoch) return;
        _drop(slot); // one-shot
        if (_patternActive && alarmEndsPatternWith != null) {
          _end(true);
          emit(100, code: alarmEndsPatternWith);
        }
        emit(57, ts: epoch);
        _hapticsStart(alarmPlays, pattern: false);
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
    final e = stored[slot];
    return AlarmSlotRead(answered: true, epoch: e, active: e != null);
  }

  Future<bool> clear(int slot) async {
    calls.add('clear$slot');
    if (!clearOk) return false;
    _drop(slot);
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
