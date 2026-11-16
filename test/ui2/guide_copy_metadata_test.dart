import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  // WHY: Russian guide arguments must retain the English declarations;
  // generation alone accepts missing metadata, hiding a broken locale contract.
  // catches: dropping accordion title, nap-help or review-action String types.
  test('Russian guide placeholder declarations match English', () {
    Map<String, dynamic> read(String code) => jsonDecode(
      File('lib/l10n/app_$code.arb').readAsStringSync(),
    ) as Map<String, dynamic>;
    final en = read('en');
    final ru = read('ru');
    var checked = 0;
    for (final entry in en.entries.where((e) => e.key.startsWith('@guide'))) {
      final placeholders = (entry.value as Map)['placeholders'] as Map?;
      for (final name in placeholders?.keys ?? <String>[]) {
        checked++;
        expect((ru[entry.key] as Map?)?['placeholders']?[name]?['type'],
          placeholders![name]['type'], reason: '${entry.key}.$name');
      }
    }
    expect(checked, greaterThan(20), reason: 'positive control: inspect guide arguments');
  });
}
