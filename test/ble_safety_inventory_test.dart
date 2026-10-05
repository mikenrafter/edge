import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

const categories = {'LINK_LOSS', 'DATA_LOSS', 'PERSISTENT_CONFIG', 'FIRMWARE'};
void main() {
  test(
    'risky write inventory uses the four machine-readable safety categories',
    () {
      final source = Directory('lib/ble')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .map((f) => f.readAsStringSync())
          .join('\n');
      final labels = RegExp(
        r'FOOTGUN\(([^)]+)\)',
      ).allMatches(source).map((m) => m.group(1)!).toSet();
      expect(labels, containsAll(categories));
      expect(
        labels.difference(categories),
        isEmpty,
        reason: 'ad hoc labels cannot feed the safety inventory',
      );
    },
  );
  test('only one BLE engine write escapes the dangerous-opcode gate', () {
    final source = File('lib/ble/ble_engine.dart').readAsStringSync();
    final calls = RegExp(
      r'await\s+_write\([^;]*allowDangerous:\s*true[^;]*;',
    ).allMatches(source).toList();
    expect(calls, hasLength(1));
  });
  test(
    'dependency resolution is gated by pin validation and tests stay serial',
    () {
      final make = File('Makefile').readAsStringSync();
      expect(make, matches(RegExp(r'^deps:\s*pins\s*$', multiLine: true)));
      expect(make, contains('flutter test --concurrency=1'));
    },
  );
}
