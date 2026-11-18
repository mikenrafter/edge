import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source_lexical.dart';

void main() {
  final src = File('lib/state/gesture_controller.dart').readAsStringSync();
  final code = codeOnly(src);

  String between(String from, String to) {
    final a = src.indexOf(from);
    final b = src.indexOf(to, a + 1);
    expect(a, greaterThan(0), reason: from);
    expect(b, greaterThan(a), reason: to);
    return codeOnly(src.substring(a, b));
  }

  test('repeat session reads band idle from the haptics service', () {
    expect(RegExp(r'bandIdle\s*:\s*_haptics\.whenIdle').allMatches(code).length,
        1);
  });
}
