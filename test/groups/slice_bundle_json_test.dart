// sliceBundleJson (the write seam's slicer, no decode) must agree with
// sliceBundle (the map slicer the assembly law pins), and its slices must be
// exact substrings of the stored text.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/groups/assemble_bundle.dart';
import 'package:openstrap_edge/compute/groups/slice_bundle.dart';

import '../support/bundle_fixtures.dart';

void main() {
  final all = [...freezeBundles(), ...importedSnapshots()];

  test('same groups, paths and order as sliceBundle; stored bytes kept', () {
    for (final (name, b) in all) {
      final text = jsonEncode(b);
      final m = sliceBundle(b);
      final j = sliceBundleJson(text);
      expect(j.keyOrder, m.keyOrder, reason: name);
      expect(j.slices.keys.toSet(), m.slices.keys.toSet(), reason: name);
      final back = {
        for (final e in j.slices.entries)
          e.key: {
            for (final (p, raw) in e.value) p: jsonDecode(raw) as Object?
          }
      };
      expect(jsonEncode(assembleBundle(back, j.keyOrder)), text, reason: name);
      for (final e in j.slices.entries) {
        for (final (_, raw) in e.value) {
          expect(text, contains(raw), reason: name);
        }
      }
    }
  });

  test('an unowned key throws and names it; non-objects throw', () {
    expect(() => sliceBundleJson('{"date":"d","mystery_key":1}'),
        throwsA(predicate((e) => '$e'.contains('mystery_key'))));
    expect(() => sliceBundleJson('[1]'), throwsStateError);
    expect(() => sliceBundleJson('{"scalars":{"nope":1}}'),
        throwsA(predicate((e) => '$e'.contains('scalars.nope'))));
  });

  test('strings with braces, quotes and escapes do not confuse the scan', () {
    final b = <String, Object?>{
      'date': 'a"}{,\\x',
      'flags': ['}', '"', '\u{1F600}'],
      'scalars': <String, Object?>{'rhr': 1.0, 'strain': null},
    };
    final text = jsonEncode(b);
    final j = sliceBundleJson(text);
    expect(j.keyOrder, ['date', 'flags', 'scalars.rhr', 'scalars.strain']);
  });
}
