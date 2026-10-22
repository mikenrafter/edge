// Design 06 phase 1d, assembly law: splitting a day bundle into per-group
// slices and assembling the slices back gives the same bytes.
//
//   jsonEncode(assembleBundle(s.slices, s.keyOrder)) == jsonEncode(bundle)
//   where s = sliceBundle(bundle)
//
// ASSUMED NEW API (the files are created by the green phase; these are the
// only missing symbols in this test):
//
//   lib/compute/groups/slice_bundle.dart
//     ({Map<String, Map<String, Object?>> slices, List<String> keyOrder})
//         sliceBundle(Map<String, Object?> bundle)
//       - slices: group id -> {path -> value}. A path is a top-level key
//         (`sleep`) or, inside a mixed block (kMixedBlocks), `block.key`
//         (`scalars.rmssd`). A mixed block that is empty, null or not a map
//         is one entry under the plain key `scalars`, owned by edge.assembly.
//         Groups with no key in the bundle get no entry. Values are the
//         bundle's own values, unchanged (null stays null).
//       - keyOrder: every path in the order the bundle holds them, so the
//         bundle's key order is recoverable (the manifest stores it as
//         key_order_json in 1e). JSON-encodable.
//       - owners come from kBundleKeyOwner and kNestedKeyOwner
//         (edge_groups.dart). A key with no owner THROWS an error whose text
//         contains the key path; it is never dropped.
//
//   lib/compute/groups/assemble_bundle.dart
//     Map<String, Object?> assembleBundle(
//         Map<String, Map<String, Object?>> slices, List<String> keyOrder)
//       - pure; independent of slice and group iteration order; a path in
//         keyOrder that no slice holds, or a slice path missing from keyOrder,
//         THROWS (a half-assembled day is never returned).
//
// Storage round trip is simulated with jsonEncode/jsonDecode of the slices
// and the key order, which is what a group_row payload and key_order_json
// will hold.

import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/groups/assemble_bundle.dart';
import 'package:openstrap_edge/compute/groups/edge_groups.dart';
import 'package:openstrap_edge/compute/groups/group_registry.dart';
import 'package:openstrap_edge/compute/groups/slice_bundle.dart';

import '../support/bundle_fixtures.dart';

String _bytes(Object? o) => jsonEncode(o);

/// slice -> store (JSON) -> assemble.
Map<String, Object?> _roundTrip(Map<String, Object?> bundle,
    {Random? shuffle}) {
  final s = sliceBundle(bundle);
  var slices = (jsonDecode(jsonEncode(s.slices)) as Map).map((g, m) =>
      MapEntry(g as String, Map<String, Object?>.from(m as Map)));
  final order = (jsonDecode(jsonEncode(s.keyOrder)) as List).cast<String>();
  if (shuffle != null) {
    // The assembler must not lean on how the slices happen to be ordered.
    final groups = slices.keys.toList()..shuffle(shuffle);
    slices = {
      for (final g in groups)
        g: {
          for (final k in (slices[g]!.keys.toList()..shuffle(shuffle)))
            k: slices[g]![k]
        }
    };
  }
  return assembleBundle(slices, order);
}

const _values = <Object?>[
  null, true, false, 0, -1, 9007199254740992, 1, //
  0.1 + 0.2, 1e21, -0.0, 5e-324, 1.0, 100.0, 3.141592653589793, -2.5e-7,
  '', 'é', '—', '\u{1F600}', 'a"b\\c\n', 'need_baseline:have=0,need=3',
];

Object? _value(Random r, int depth) {
  final c = r.nextInt(depth > 2 ? 6 : 9);
  if (c < 6) return _values[r.nextInt(_values.length)];
  if (c < 8) {
    return [for (var i = 0; i < r.nextInt(4); i++) _value(r, depth + 1)];
  }
  return {
    for (var i = 0; i < r.nextInt(4); i++)
      // inner keys of an opaque block are free text, dots and all
      ['a', 'b.c', 'value', 'tier', 'z'][r.nextInt(5)]: _value(r, depth + 1)
  };
}

Map<String, Object?> _synthetic(int seed) {
  final r = Random(seed);
  final top = kBundleKeyOwner.keys.toList()..shuffle(r);
  final out = <String, Object?>{};
  for (final k in top.take(r.nextInt(top.length + 1))) {
    if (kMixedBlocks.contains(k)) {
      final kinds = r.nextInt(8);
      if (kinds == 0) {
        out[k] = null;
      } else if (kinds == 1) {
        out[k] = <String, Object?>{};
      } else {
        final nested = kNestedKeyOwner.keys
            .where((p) => p.startsWith('$k.'))
            .map((p) => p.substring(k.length + 1))
            .toList()
          ..shuffle(r);
        out[k] = {
          for (final n in nested.take(1 + r.nextInt(nested.length)))
            n: _value(r, 1)
        };
      }
    } else {
      out[k] = _value(r, 0);
    }
  }
  return out;
}

void main() {
  final freeze = freezeBundles();
  final groupIds = {for (final g in kMergedRegistry.groups) g.id};

  group('fixture-world days (freeze goldens)', () {
    test('there are fixture days', () {
      expect(freeze.length, greaterThanOrEqualTo(18));
    });

    test('assemble(slice(bundle)) is byte-for-byte the bundle', () {
      for (final (name, b) in freeze) {
        expect(_bytes(_roundTrip(b)), _bytes(b), reason: name);
      }
    });

    test('..and does not depend on slice or group ordering', () {
      for (final (name, b) in freeze) {
        for (var seed = 0; seed < 3; seed++) {
          expect(_bytes(_roundTrip(b, shuffle: Random(seed))), _bytes(b),
              reason: '$name seed $seed');
        }
      }
    });

    test('the keyOrder is the bundle key order, top level and nested', () {
      for (final (name, b) in freeze) {
        final order = sliceBundle(b).keyOrder;
        expect(order.where((p) => !p.contains('.')),
            b.keys.where((k) => !kMixedBlocks.contains(k) || b[k] is! Map || (b[k] as Map).isEmpty),
            reason: name);
        for (final blk in kMixedBlocks) {
          if (b[blk] is! Map) continue;
          expect(order.where((p) => p.startsWith('$blk.')),
              (b[blk] as Map).keys.map((k) => '$blk.$k'),
              reason: '$name $blk');
        }
      }
    });

    test('every path is in exactly one slice, and every slice is a group', () {
      for (final (name, b) in freeze) {
        final s = sliceBundle(b);
        expect(groupIds, containsAll(s.slices.keys), reason: name);
        final seen = <String>[
          for (final m in s.slices.values) ...m.keys,
        ];
        expect(seen.toSet().length, seen.length,
            reason: '$name: a path sits in two groups');
        expect(seen.toSet(), s.keyOrder.toSet(), reason: name);
      }
    });

    test('a group holds only the keys it owns', () {
      for (final (name, b) in freeze) {
        for (final e in sliceBundle(b).slices.entries) {
          for (final path in e.value.keys) {
            final owner = kNestedKeyOwner[path] ?? kBundleKeyOwner[path];
            expect(owner, e.key, reason: '$name $path');
          }
        }
      }
    });
  });

  group('property-style synthetic bundles', () {
    test('200 seeded random bundles round-trip byte for byte', () {
      for (var seed = 0; seed < 200; seed++) {
        final b = _synthetic(seed);
        expect(_bytes(_roundTrip(b)), _bytes(b), reason: 'seed $seed');
        expect(_bytes(_roundTrip(b, shuffle: Random(seed))), _bytes(b),
            reason: 'seed $seed shuffled');
      }
    });

    test('the generator reaches both mixed-block shapes and nulls', () {
      var nullBlock = 0, emptyBlock = 0, nullScalar = 0;
      for (var seed = 0; seed < 200; seed++) {
        final b = _synthetic(seed);
        for (final k in kMixedBlocks) {
          if (b.containsKey(k) && b[k] == null) nullBlock++;
          if (b[k] is Map && (b[k] as Map).isEmpty) emptyBlock++;
        }
        final s = b['scalars'];
        if (s is Map && s.values.contains(null)) nullScalar++;
      }
      expect([nullBlock, emptyBlock, nullScalar], everyElement(greaterThan(0)));
    });

    test('empty bundle', () {
      expect(_bytes(_roundTrip(<String, Object?>{})), '{}');
    });

    test('null scalars stay null and are not dropped', () {
      final b = <String, Object?>{
        'date': '2026-03-10',
        'scalars': {'rhr': null, 'readiness': null, 'strain': 4.5},
        'stress': null,
      };
      final back = _roundTrip(b);
      expect(_bytes(back), _bytes(b));
      expect((back['scalars'] as Map).containsKey('rhr'), isTrue);
      expect(back.containsKey('stress'), isTrue);
    });

    test('a bundle with absent_notes round-trips, key order intact', () {
      final b = <String, Object?>{
        'date': '2026-03-10',
        'absent_notes': {
          'strain': 'need_baseline:have=0,need=3',
          'zones': 'no_profile',
        },
        'scalars': {'strain': null},
      };
      expect(_bytes(_roundTrip(b)), _bytes(b));
      expect(sliceBundle(b).slices['edge.assembly']!.keys,
          contains('absent_notes'));
    });

    test('number formats survive (1.0 stays 1.0, 1 stays 1, -0.0, 1e21)', () {
      final b = <String, Object?>{
        'scalars': {
          'rhr': 1.0,
          'rmssd': 1,
          'sdnn': -0.0,
          'strain': 1e21,
          'trimp': 0.1 + 0.2,
        },
      };
      expect(_bytes(_roundTrip(b)), _bytes(b));
    });
  });

  group('imported snapshots', () {
    test('there are snapshots, and they say imported: true', () {
      final snaps = importedSnapshots();
      expect(snaps, isNotEmpty);
      expect(snaps.every((s) => s.$2['imported'] == true), isTrue);
    });

    test('assemble(slice(snapshot)) is byte-for-byte the snapshot', () {
      for (final (name, b) in importedSnapshots()) {
        expect(_bytes(_roundTrip(b)), _bytes(b), reason: name);
      }
    });

    test('imported: true survives as a bool, not a string or a missing key', () {
      for (final (name, b) in importedSnapshots()) {
        expect(_roundTrip(b)['imported'], isTrue, reason: name);
      }
    });
  });

  group('ownership is total: an unowned key is a failure', () {
    Map<String, Object?> base() => {
          'date': '2026-03-10',
          'scalars': <String, Object?>{'rhr': 50.0},
        };

    test('an unowned top-level key throws and names the key', () {
      final b = base()..['mystery_key'] = 1;
      expect(() => sliceBundle(b),
          throwsA(predicate((e) => e.toString().contains('mystery_key'))));
    });

    test('an unowned nested key throws and names the path', () {
      final b = base();
      (b['scalars'] as Map)['mystery_scalar'] = 1;
      expect(() => sliceBundle(b),
          throwsA(predicate((e) => e.toString().contains('scalars.mystery_scalar'))));
    });

    test('a skip marker is not a bundle', () {
      expect(() => sliceBundle({'skipped': true, 'reason': 'no_data'}),
          throwsA(anything));
    });

    test('assembling a half set throws instead of returning a partial day', () {
      final s = sliceBundle(base());
      final partial = {
        for (final e in s.slices.entries)
          if (e.key != 'edge.assembly') e.key: e.value
      };
      expect(() => assembleBundle(partial, s.keyOrder), throwsA(anything));
    });

    test('a slice path missing from keyOrder throws', () {
      final s = sliceBundle(base());
      expect(() => assembleBundle(s.slices, s.keyOrder.take(1).toList()),
          throwsA(anything));
    });
  });
}
