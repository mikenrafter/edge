// RULES B.2 on the home-widget / watch snapshot. It is write-only and read by
// four native targets that have no field for "older calculation". Decision:
// an older strain is NOT exported as the current ring; the widget says there is
// no strain (the app, one tap away, shows the starred value with its note).
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/models/payloads.dart';
import 'package:openstrap_edge/widget/widget_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Map<String, Object?> written;

  setUp(() {
    written = {};
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    m.setMockMethodCallHandler(const MethodChannel('home_widget'), (call) async {
      if (call.method == 'saveWidgetData') {
        final a = (call.arguments as Map).cast<String, Object?>();
        written[a['id'] as String] = a['data'];
      }
      return true;
    });
    m.setMockMethodCallHandler(
        const MethodChannel('openstrap/ios_config'),
        (call) async => call.method == 'appGroupIdentifier' ? 'group.test' : null);
  });
  tearDown(() {
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    m.setMockMethodCallHandler(const MethodChannel('home_widget'), null);
    m.setMockMethodCallHandler(const MethodChannel('openstrap/ios_config'), null);
  });

  Map<String, dynamic> today(double v, {int? older}) => {
        'daily': {
          'strain': {
            'value': v,
            'confidence': .8,
            'tier': 'ESTIMATE',
            'from_older_version': ?older,
          },
          'readiness': {'value': 71.0 + v, 'confidence': .8, 'tier': 'HIGH'},
        },
      };

  test('an older strain is not written as the current ring', () async {
    await WidgetService.push(TodayData.fromJson(today(8.4, older: 104)));
    expect(written['strain'], -1.0, reason: 'the "no data" sentinel');
    expect(written['ring_strain_value'], isNot('8.4'));
    expect(written['ring_strain_value'], 'No strain');
    // Nothing else is dragged down with it.
    expect(written['readiness'], isNot(-1));
  });

  test('a current strain is written as before', () async {
    await WidgetService.push(TodayData.fromJson(today(9.6)));
    expect(written['strain'], 9.6);
    expect(written['ring_strain_value'], '9.6');
  });
}
