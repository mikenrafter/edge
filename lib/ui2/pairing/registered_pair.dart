import 'package:flutter_blue_plus/flutter_blue_plus.dart' show BluetoothDevice;

/// The pairing operation owned by a device's registry entry.
final class RegisteredPair {
  const RegisteredPair(this._pair);
  final Future<String?> Function(BluetoothDevice) _pair;
  Future<String?> run(BluetoothDevice device) => _pair(device);
}
