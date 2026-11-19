// why: Data Explorer is a local pilot reference and must have no APK entry point.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('runtime code has no explorer screen, route or compute dependency', () {
    final forbidden = RegExp(r'\bExplorer(?:Screen|View)\b|explorer(?:_series|_annotations)?\.dart');
    expect(forbidden.hasMatch("import 'explorer.dart';"), isTrue);
    final offenders = <String>[];
    for (final file in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (file.path.endsWith('.dart') && forbidden.hasMatch(file.readAsStringSync())) {
        offenders.add(file.path);
      }
    }
    expect(offenders, isEmpty);
  });
}
