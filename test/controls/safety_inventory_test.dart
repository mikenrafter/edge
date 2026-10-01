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
  test('BLE and adapter refusal gates each carry a data-loss classification', () {
    for (final path in [
      'lib/ble/ble_engine.dart',
      'lib/ble/adapters/gatt_link.dart',
    ]) {
      final source = File(path).readAsStringSync();
      final gate = source.indexOf(
        '(dangerousCmds.contains(opcode) || OpcodeSafety.isDestructive(opcode))',
      );
      expect(gate, greaterThanOrEqualTo(0), reason: path);
      final preceding = source.substring(gate > 1100 ? gate - 1100 : 0, gate);
      expect(preceding, contains('FOOTGUN(DATA_LOSS)'), reason: path);
    }
  });
  test(
    'sole persistent-config escape is classified beside the actual call',
    () {
      final source = File('lib/ble/ble_engine.dart').readAsStringSync();
      final calls = RegExp(
        r'await\s+_write\([^;]*allowDangerous:\s*true[^;]*;',
      ).allMatches(source).toList();
      expect(calls, hasLength(1));
      final call = calls.single;
      expect(
        source.substring(call.start > 900 ? call.start - 900 : 0, call.end),
        contains('FOOTGUN(PERSISTENT_CONFIG)'),
      );
    },
  );
  test(
    'inventory script includes protocol definitions and Edge write sites',
    () {
      final script = File('scripts/opcode_inventory.py').readAsStringSync();
      expect(script, contains('openstrap_protocol'));
      expect(script, contains('dangerousCmds'));
      expect(script, contains('OpcodeSafety'));
      expect(script, contains('allowDangerous'));
      expect(script, contains('FOOTGUN'));
      expect(
        File('docs/controls-capabilities.md').readAsStringSync(),
        contains('05ca7a7'),
      );
    },
  );
  test(
    'dependency resolution is gated by pin validation and tests stay serial',
    () {
      final make = File('Makefile').readAsStringSync();
      expect(make, matches(RegExp(r'^deps:\s*pins\s*$', multiLine: true)));
      expect(make, contains('flutter test --concurrency=1'));
    },
  );
}
