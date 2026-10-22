// slice_bundle.dart — split a day bundle into per-group slices (design 06 1d).
//
// A path is a top-level bundle key (`sleep`) or, inside a mixed block
// ([kMixedBlocks]), `block.key` (`scalars.rmssd`). Each path has exactly one
// owning group: [kBundleKeyOwner] / [kNestedKeyOwner]. A mixed block that is
// null, empty or not a map has no nested keys to own, so it is one plain-key
// entry owned like any top-level key (edge.assembly).
//
// An unowned key THROWS with its path: dropping it would store a half-sliced
// day that looks complete. The write seam catches it and writes no group rows
// (the day_result row still serves).
//
// Pure. The inverse is [assembleBundle]; `keyOrder` carries the bundle's key
// order, which a set of per-group slices cannot.

import 'edge_groups.dart';

/// Slices of [bundle]: `group id -> {path -> value}` and every path in bundle
/// order. Values are the bundle's own objects, unchanged.
({Map<String, Map<String, Object?>> slices, List<String> keyOrder})
    sliceBundle(Map<String, Object?> bundle) {
  final slices = <String, Map<String, Object?>>{};
  final order = <String>[];
  void put(String path, String? owner, Object? value) {
    (slices[ownerOrThrow(path, owner)] ??= <String, Object?>{})[path] = value;
    order.add(path);
  }

  for (final e in bundle.entries) {
    final k = e.key;
    final v = e.value;
    if (kMixedBlocks.contains(k) && v is Map && v.isNotEmpty) {
      for (final n in v.entries) {
        final path = '$k.${n.key}';
        put(path, kNestedKeyOwner[path], n.value);
      }
    } else {
      put(k, kBundleKeyOwner[k], v);
    }
  }
  return (slices: slices, keyOrder: order);
}

/// [owner] if present, else a StateError naming [path] (never drop a key).
String ownerOrThrow(String path, String? owner) {
  if (owner == null) {
    throw StateError('bundle key "$path" has no owning group');
  }
  return owner;
}

/// [sliceBundle] over the JSON TEXT of a bundle, without decoding it: each
/// value stays the exact substring of [json], so a slice is byte-identical to
/// what was stored (design 06 1d: compare against the stored payload string).
/// Same routing, same errors. The text must be what `jsonEncode` writes
/// (compact, no duplicate keys); anything else throws StateError.
({Map<String, List<(String, String)>> slices, List<String> keyOrder})
    sliceBundleJson(String json) {
  final slices = <String, List<(String, String)>>{};
  final order = <String>[];
  void put(String path, String? owner, String raw) {
    (slices[ownerOrThrow(path, owner)] ??= <(String, String)>[]).add((path, raw));
    order.add(path);
  }

  final (top, _) = _members(json, 0);
  for (final m in top) {
    final k = m.key;
    final raw = json.substring(m.start, m.end);
    if (kMixedBlocks.contains(k) && raw.startsWith('{')) {
      final (inner, _) = _members(raw, 0);
      if (inner.isNotEmpty) {
        for (final n in inner) {
          final path = '$k.${n.key}';
          put(path, kNestedKeyOwner[path], raw.substring(n.start, n.end));
        }
        continue;
      }
    }
    put(k, kBundleKeyOwner[k], raw);
  }
  return (slices: slices, keyOrder: order);
}

typedef _Member = ({String key, int start, int end});

int _ws(String s, int i) {
  while (i < s.length && ' \n\r\t'.contains(s[i])) {
    i++;
  }
  return i;
}

/// End (exclusive) of the string whose opening quote is at [i].
int _stringEnd(String s, int i) {
  for (var j = i + 1; j < s.length; j++) {
    final c = s.codeUnitAt(j);
    if (c == 0x5c) {
      j++;
    } else if (c == 0x22) {
      return j + 1;
    }
  }
  throw StateError('unterminated string');
}

/// End (exclusive) of the value starting at [i].
int _valueEnd(String s, int i) {
  if (i >= s.length) throw StateError('value expected');
  final c = s[i];
  if (c == '"') return _stringEnd(s, i);
  if (c == '{' || c == '[') {
    var depth = 0;
    for (var j = i; j < s.length; j++) {
      final d = s[j];
      if (d == '"') {
        j = _stringEnd(s, j) - 1;
      } else if (d == '{' || d == '[') {
        depth++;
      } else if (d == '}' || d == ']') {
        if (--depth == 0) return j + 1;
      }
    }
    throw StateError('unterminated container');
  }
  var j = i;
  while (j < s.length && !',}] \n\r\t'.contains(s[j])) {
    j++;
  }
  if (j == i) throw StateError('value expected');
  return j;
}

/// The members of the object that starts at [i], and its end.
(List<_Member>, int) _members(String s, int i) {
  i = _ws(s, i);
  if (i >= s.length || s[i] != '{') throw StateError('bundle is not an object');
  i = _ws(s, i + 1);
  final out = <_Member>[];
  if (i < s.length && s[i] == '}') return (out, i + 1);
  while (true) {
    if (i >= s.length || s[i] != '"') throw StateError('key expected');
    final ke = _stringEnd(s, i);
    final key = s.substring(i + 1, ke - 1);
    // A key with an escape would need decoding to route; bundles never have one.
    if (key.contains('\\')) throw StateError('escaped key "$key"');
    i = _ws(s, ke);
    if (i >= s.length || s[i] != ':') throw StateError('colon expected');
    i = _ws(s, i + 1);
    final ve = _valueEnd(s, i);
    out.add((key: key, start: i, end: ve));
    i = _ws(s, ve);
    if (i < s.length && s[i] == ',') {
      i = _ws(s, i + 1);
      continue;
    }
    if (i < s.length && s[i] == '}') return (out, i + 1);
    throw StateError('comma or brace expected');
  }
}
