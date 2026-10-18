// power_source.dart — what the phone's power looks like, as a value stream.
//
// The DeriveCoordinator reads this to apply the Calculations power mode
// (CalcPowerPolicy). It sits behind an interface so tests script it.
//
// battery_plus 6.2.3 has a change stream for the plug (onBatteryStateChanged)
// but NONE for the OS power saver: `isInBatterySaveMode` is a one-shot
// Future<bool>. So the saver is re-read on every battery event and on a slow
// poll. The poll runs only while somebody listens AND [watchSaver] is on: the
// owner turns it off in a mode/state where a saver flip decides nothing
// (CalcPowerPolicy.saverMatters).
import 'dart:async';

import 'package:battery_plus/battery_plus.dart';
import 'package:clock/clock.dart';

import '../compute/calc_power_policy.dart';

abstract class PowerSource {
  /// The state right now.
  Future<PowerState> read();

  /// Every observed plug, unplug or saver edge. Unchanged states are not repeated.
  Stream<PowerState> get changes;
}

/// How often the power saver is re-read while [BatteryPowerSource.changes] has
/// a listener and [BatteryPowerSource.watchSaver] is on. A saver flip is rare
/// and nothing here is time-critical, so a minute is plenty.
const Duration kPowerSaverPoll = Duration(minutes: 1);

class BatteryPowerSource implements PowerSource {
  BatteryPowerSource({
    Battery? battery,
    this.saverPoll = kPowerSaverPoll,
    Future<bool> Function()? readCharging,
    Future<bool> Function()? readSaver,
  })  : _battery = battery ?? Battery(),
        _readChargingOverride = readCharging,
        _readSaverOverride = readSaver;

  final Battery _battery;
  final Duration saverPoll;
  final Future<bool> Function()? _readChargingOverride;
  final Future<bool> Function()? _readSaverOverride;

  // The last state folded; it is what `chargingSince` carries across.
  PowerState _last = PowerState.unplugged;
  PowerState? _emitted;

  late final StreamController<PowerState> _out =
      StreamController<PowerState>.broadcast(onListen: _start, onCancel: _stop);
  StreamSubscription<BatteryState>? _sub;
  Timer? _poll;
  bool _closed = false;
  bool _watchSaver = true;
  int _refreshSequence = 0;

  @override
  Stream<PowerState> get changes => _out.stream;

  /// Whether the slow saver poll runs while [changes] has a listener. On by
  /// default (a wrong saver reading is the costly mistake); the owner switches
  /// it off while no decision depends on the saver and on again when one does.
  /// The saver is still re-read on every battery event either way.
  set watchSaver(bool on) {
    if (_watchSaver == on) return;
    _watchSaver = on;
    _syncPoll();
  }

  @override
  Future<PowerState> read() => _refresh();

  // External power: charging, full, or plugged in without charging. `unknown`
  // counts as not charging.
  static bool _external(BatteryState s) => switch (s) {
        BatteryState.charging ||
        BatteryState.full ||
        BatteryState.connectedNotCharging =>
          true,
        BatteryState.discharging || BatteryState.unknown => false,
      };

  // A platform that cannot answer (no plugin, a headless engine) reads as the
  // calm default: unplugged, saver off. That never holds work back.
  Future<bool> _readCharging() async {
    try {
      final override = _readChargingOverride;
      if (override != null) return await override();
      return _external(await _battery.batteryState);
    } catch (_) {
      return false;
    }
  }

  Future<bool> _readSaver() async {
    try {
      final override = _readSaverOverride;
      if (override != null) return await override();
      return await _battery.isInBatterySaveMode;
    } catch (_) {
      return false;
    }
  }

  /// Reads (or takes [charging] from a battery event), folds in the saver,
  /// stamps `chargingSince` with the clock on the unplugged -> plugged edge and
  /// clears it on the way out, and emits when something changed.
  Future<PowerState> _refresh({bool? charging, DateTime? receivedAt}) async {
    final sequence = ++_refreshSequence;
    final edgeAt = receivedAt ?? clock.now();
    final plugged = charging ?? await _readCharging();
    final saver = await _readSaver();
    if (sequence != _refreshSequence) return _last;
    final s = PowerState(
      charging: plugged,
      chargingSince:
          plugged ? (_last.charging ? _last.chargingSince : edgeAt) : null,
      powerSaver: saver,
    );
    _last = s;
    if (!_closed && _out.hasListener && s != _emitted) {
      _emitted = s;
      _out.add(s);
    }
    return s;
  }

  void _start() {
    if (_closed) return;
    // Subscribed before any read, so no edge falls between the two.
    _sub = _battery.onBatteryStateChanged.listen(
      (s) => unawaited(
          _refresh(charging: _external(s), receivedAt: clock.now())),
      onError: (Object _) {},
    );
    _syncPoll();
  }

  // The poll exists exactly while there is a listener, a reason to read, and
  // the source is open.
  void _syncPoll() {
    final want = _sub != null && _watchSaver && !_closed;
    if (!want) {
      _poll?.cancel();
      _poll = null;
    } else {
      _poll ??= Timer.periodic(saverPoll, (_) => unawaited(_refresh()));
    }
  }

  void _stop() {
    _sub?.cancel();
    _sub = null;
    _syncPoll();
  }

  /// Stops the poll and the battery subscription for good.
  void dispose() {
    if (_closed) return;
    _closed = true;
    _stop();
    unawaited(_out.close());
  }
}
