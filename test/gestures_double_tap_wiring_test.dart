import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source_lexical.dart';

void main() {
  final src = File('lib/state/gesture_controller.dart').readAsStringSync();
  final code = codeOnly(src);

  test('repeat session reads band idle from the haptics service', () {
    expect(RegExp(r'bandIdle\s*:\s*_haptics\.whenIdle').allMatches(code).length,
        1);
  });
}
