// Design 06 phase 1d: slicing a bundle by key ownership needs an owner for
// every key a stored day_result payload can carry, not only the keys a fresh
// derive writes. This file needs no new symbol; it fails on the ownership
// maps in lib/compute/groups/edge_groups.dart.
//
//  * the WHOOP freeze goldens (real derive output) are fully owned;
//  * the import snapshots (cloud_import.dart, whoop_import.dart) carry two
//    top-level keys no group owns today: `imported` and `source`. The green
//    phase adds them to kBundleKeyOwner (edge.assembly is the natural owner:
//    provenance stamps, like `date` and `flags`);
//  * skip markers (`{skipped: true, reason}`) are NOT owned and must not be:
//    a skipped write has no bundle, so it writes no group rows (see
//    test/data/group_row_freeze_test.dart).

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/groups/edge_groups.dart';

import '../support/bundle_fixtures.dart';

List<String> _unowned(Map<String, Object?> bundle) {
  final out = <String>[];
  for (final k in bundle.keys) {
    if (!kBundleKeyOwner.containsKey(k)) out.add(k);
    if (kMixedBlocks.contains(k) && bundle[k] is Map) {
      for (final n in (bundle[k] as Map).keys) {
        if (!kNestedKeyOwner.containsKey('$k.$n')) out.add('$k.$n');
      }
    }
  }
  return out;
}

void main() {
  test('the freeze goldens are present (the fixture is not vacuous)', () {
    expect(freezeBundles().length, greaterThanOrEqualTo(18));
  });

  test('every key of every freeze-golden bundle has an owner', () {
    final gaps = {
      for (final (name, b) in freezeBundles())
        if (_unowned(b).isNotEmpty) name: _unowned(b)
    };
    expect(gaps, isEmpty);
  });

  test('every key of an import snapshot has an owner', () {
    final gaps = {
      for (final (name, b) in importedSnapshots())
        if (_unowned(b).isNotEmpty) name: _unowned(b)
    };
    expect(gaps, isEmpty,
        reason: 'add the top-level keys to kBundleKeyOwner');
  });

  test('imported and source are owned by edge.assembly', () {
    expect(kBundleKeyOwner['imported'], 'edge.assembly');
    expect(kBundleKeyOwner['source'], 'edge.assembly');
  });

  test('skip-marker keys stay unowned: a skipped write has no bundle', () {
    expect(kBundleKeyOwner.containsKey('skipped'), isFalse);
    expect(kBundleKeyOwner.containsKey('reason'), isFalse);
  });
}
