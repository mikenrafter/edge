// The BLE engine as a [BandHapticsPort]: a thin adapter, no logic of its own.
// The one file besides ble_engine.dart and app_state.dart that calls an engine
// buzz (test/phase7/audit_guards_test.dart allows it by name).

import '../ble/ble_engine.dart';
import 'haptics_service.dart';

class BleEngineHapticsPort implements BandHapticsPort {
  BleEngineHapticsPort(this._engine);
  final BleEngine _engine;

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
