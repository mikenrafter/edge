import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/notify/device_alerts.dart';
import 'package:openstrap_edge/notify/notification_event.dart';

class Store implements DeviceAlertStore {
  final values = <String, int>{};
  @override
  Future<int?> readInt(String key) async => values[key];
  @override
  Future<void> writeInt(String key, int value) async { values[key] = value; }
}
class Sink implements DeviceAlertSink {
  bool allowed = false;
  final delivered = <NotificationEvent>[];
  @override
  Future<bool> show(NotificationEvent event) async {
    if (!allowed) return false;
    delivered.add(event);
    return true;
  }
  @override
  Future<void> cancel(int id) async {}
}
void main() {
  // WHY / CLAIM(alert-device-debt): a charging edge rejected by the central
  // sleep gate is retried once after restart, without a second plug-in.
  test('held charging notice survives restart and releases once', () async {
    final store = Store(), sink = Sink();
    final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000 - 2;
    final first = DeviceAlerts(store: store, sink: sink);
    first.onDeviceState(charging: true, chargingTs: ts);
    await first.settled;
    expect(sink.delivered, isEmpty);
    sink.allowed = true;
    final restarted = DeviceAlerts(store: store, sink: sink);
    for (var i = 0; i < 3; i++) {
      restarted.onDeviceState(charging: true, chargingTs: ts);
      await restarted.settled;
    }
    expect(sink.delivered, hasLength(1));
  });
}
