// The BLE engine as a [BandHapticsPort]: a thin adapter, no logic of its own.
// The one file besides ble_engine.dart and app_state.dart that calls an engine
// buzz (test/source_invariant_guards_test.dart allows it by name).

import '../ble/ble_engine.dart';
import 'haptics_service.dart';

class BleEngineHapticsPort implements BandHapticsPort {
  /// The engine is read at every use, not when the port is built: the
  /// gesture sessions hold the service's `whenIdle` from construction, which
  /// must not need the engine yet (AppState.forTesting has none).
  BleEngineHapticsPort(this._engineOf);
  final BleEngine Function() _engineOf;
  BleEngine get _engine => _engineOf();

  @override
  bool get isConnected => _engine.isConnected;

  @override
  String? get generation => _engine.state.generation;

  @override
  Future<bool> buzzBand({int holdMs = 0}) => _engine.buzzBand(holdMs: holdMs);

  @override
  Future<bool> buzzMaverickPattern(List<int> effects, int loop) =>
      _engine.buzzMaverickPattern(effects: effects, loop: loop);
}
