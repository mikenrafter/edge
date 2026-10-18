// Shared fakes for the power-mode (calculations) tests. See
// calc_power_policy_test.dart for the API; this file references PowerSource and
// PowerState.

import 'dart:async';

import 'package:clock/clock.dart';

import 'package:openstrap_edge/compute/calc_power_policy.dart';
import 'package:openstrap_edge/state/power_source.dart';

/// A scriptable [PowerSource]. Like the real one it stamps `chargingSince` with
/// the clock on the unplugged -> plugged edge (and clears it on unplug); a
/// saver change keeps the stamp. Reads `clock.now()`, so inside `fakeAsync` it
/// is the fake time.
class FakePowerSource implements PowerSource {
  FakePowerSource({bool charging = false, bool powerSaver = false})
      : _state = PowerState(
          charging: charging,
          chargingSince: charging ? clock.now() : null,
          powerSaver: powerSaver,
        );

  PowerState _state;
  final StreamController<PowerState> _changes =
      StreamController<PowerState>.broadcast(sync: true);

  int reads = 0;

  /// Live subscribers to [changes]; a coordinator that is disposed must have
  /// dropped its one.
  bool get hasListener => _changes.hasListener;

  PowerState get state => _state;

  @override
  Future<PowerState> read() async {
    reads++;
    return _state;
  }

  @override
  Stream<PowerState> get changes => _changes.stream;

  void plug({bool? saver}) {
    _state = PowerState(
      charging: true,
      chargingSince: _state.charging ? _state.chargingSince : clock.now(),
      powerSaver: saver ?? _state.powerSaver,
    );
    _changes.add(_state);
  }

  void unplug({bool? saver}) {
    _state = PowerState(
      charging: false,
      powerSaver: saver ?? _state.powerSaver,
    );
    _changes.add(_state);
  }

  void setSaver(bool on) {
    _state = PowerState(
      charging: _state.charging,
      chargingSince: _state.chargingSince,
      powerSaver: on,
    );
    _changes.add(_state);
  }

  Future<void> close() => _changes.close();
}
