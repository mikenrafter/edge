// assemble_bundle.dart — the pure inverse of [sliceBundle] (design 06 1d).
//
// Independent of slice and group order: the bundle's key order comes from
// `keyOrder` alone. A half set never comes back as a day: a path in keyOrder
// that no slice holds, a slice path missing from keyOrder, or a path in two
// slices throws.

import 'edge_groups.dart';

Map<String, Object?> assembleBundle(
  Map<String, Map<String, Object?>> slices,
  List<String> keyOrder,
) {
  final byPath = <String, Object?>{};
  for (final s in slices.entries) {
    for (final p in s.value.entries) {
      if (byPath.containsKey(p.key)) {
        throw StateError('path "${p.key}" is in two slices');
      }
      byPath[p.key] = p.value;
    }
  }
  final wanted = keyOrder.toSet();
  if (wanted.length != keyOrder.length) {
    throw StateError('keyOrder repeats a path');
  }
  final missing = wanted.difference(byPath.keys.toSet());
  if (missing.isNotEmpty) {
    throw StateError('slices miss ${missing.join(', ')}');
  }
  final extra = byPath.keys.toSet().difference(wanted);
  if (extra.isNotEmpty) {
    throw StateError('keyOrder misses ${extra.join(', ')}');
  }
  final out = <String, Object?>{};
  for (final path in keyOrder) {
    final dot = path.indexOf('.');
    final block = dot < 0 ? null : path.substring(0, dot);
    if (block != null && kMixedBlocks.contains(block)) {
      ((out[block] ??= <String, Object?>{}) as Map<String, Object?>)[
          path.substring(dot + 1)] = byPath[path];
    } else {
      out[path] = byPath[path];
    }
  }
  return out;
}
