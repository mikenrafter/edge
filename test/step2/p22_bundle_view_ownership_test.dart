// P2.2 ownership and copying (design 02 step 2, section 4.3).
//
// ASSUMED (lib/data/bundle_store.dart):
//   * `decodeDayPayloadsHeavy(bundleWorkerInputs, DecodeChunkInput)` returns,
//     per payload text, a deep-unmodifiable graph in COMPACT form (curves keep
//     their stored grid/offset shape) or null when the text is not a JSON
//     object (exactly when `SeriesCodec.decodePayloadJson` returns null).
//   * `BundleView.owned(path)` deep-copies the subtree at a dotted path into
//     growable collections; a path that is, or contains, a curve comes back
//     expanded the way `SeriesCodec.decodePayload` expands it.
//   * `BundleView.curve(path)` is `SeriesCodec.decodeCurve` with the value key
//     that `seriesCurves` / `rootCurves` gives the slot; what it cannot expand
//     comes back unchanged.
//   * `BundleView.materialiseLegacy()` equals `decodePayloadJson(text)`.
//   * `BundleView.debugCopiedNodes` counts nodes copied for callers.
//   * Repository readers take their bundles from `BundleStore.shared`.

import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/bundle_store.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/data/series_codec.dart';

import '../support/dart_source.dart';
import 'support/p22_support.dart';

const _name = 'p22_ownership.db';

/// A curve shape as stored, for a slot whose value key is [vk].
Map<String, Object? Function(String vk)> _shapes() => {
  'legacy list': (vk) => [
    {'t': 100, vk: 1},
    {'t': 160, vk: 2},
    {'t': 220, vk: 3},
  ],
  'grid': (vk) => {'t0': 100, 'dt': 60, 'v': [1, 2, 3]},
  'offset': (vk) => {'t0': 100, 'to': [0, 60, 150], 'v': [1, 2, 3]},
  'grid without v': (vk) => {'t0': 100, 'dt': 60},
  'grid without t0': (vk) => {'dt': 60, 'v': [1, 2]},
  'offset without v': (vk) => {'t0': 100, 'to': [0, 60]},
  'fractional offsets': (vk) => {'t0': 100, 'to': [0, 60.5, 150], 'v': [1, 2, 3]},
  'offset length mismatch': (vk) => {'t0': 100, 'to': [0, 60], 'v': [1, 2, 3]},
  'fractional dt': (vk) => {'t0': 100, 'dt': 60.5, 'v': [1, 2, 3]},
  'fractional t0': (vk) => {'t0': 100.5, 'dt': 60, 'v': [1, 2, 3]},
  'one point (below minPoints)': (vk) => {'t0': 100, 'dt': 60, 'v': [1]},
  'zero points': (vk) => {'t0': 100, 'dt': 60, 'v': <int>[]},
  'empty list': (vk) => <Object?>[],
  'empty map': (vk) => <String, Object?>{},
  'foreign map': (vk) => {'foo': 1, 'bar': [1, 2]},
  'null': (vk) => null,
  'string': (vk) => 'x',
  'number': (vk) => 7,
  'bool': (vk) => true,
};

/// A payload with [shape] in the slot at [path].
String _payloadWith(String path, Object? shape) {
  if (path.startsWith('series.')) {
    return jsonEncode({
      'scalars': {'rhr': 50.0},
      'series': {path.substring('series.'.length): shape},
    });
  }
  return jsonEncode({'scalars': {'rhr': 50.0}, path: shape});
}

Object? _at(Object? root, String path) {
  Object? cur = root;
  for (final part in path.split('.')) {
    if (cur is! Map || !cur.containsKey(part)) return null;
    cur = cur[part];
  }
  return cur;
}

void _expectFrozen(Object? root, {String reason = ''}) {
  p22Walk(root, (n, path) {
    if (n is Map) {
      expect(() => n['__p22__'] = 1, throwsUnsupportedError,
          reason: 'map at "$path" is mutable $reason');
    }
    if (n is List) {
      expect(() => n.add(null), throwsUnsupportedError,
          reason: 'list at "$path" is mutable $reason');
    }
  });
}

/// The text of the class declared by [header], through its closing brace.
String _classBody(String code, String header) {
  final at = code.indexOf(header);
  expect(at, isNonNegative, reason: header);
  var depth = 0;
  for (var i = code.indexOf('{', at); i < code.length; i++) {
    if (code[i] == '{') depth++;
    if (code[i] == '}' && --depth == 0) return code.substring(at, i + 1);
  }
  fail('unbalanced $header');
}

/// Changes every list and map under [n], children first, with operations that
/// do not depend on element types. An unmodifiable NON-EMPTY collection is
/// recorded as frozen; an empty one (a `const` literal in a reader's own result
/// shape) has nothing in it to corrupt and is allowed.
void _probe(Object? n, String path, List<String> frozen) {
  if (n is Map) {
    for (final e in n.entries.toList()) {
      _probe(e.value, '$path.${e.key}', frozen);
    }
    try {
      if (n.isNotEmpty) {
        final k = n.keys.first;
        final v = n.remove(k);
        n[k] = v;
      }
      n.clear();
    } on UnsupportedError {
      if (n.isNotEmpty) frozen.add(path);
    }
  } else if (n is List) {
    for (var i = 0; i < n.length; i++) {
      _probe(n[i], '$path[$i]', frozen);
    }
    try {
      if (n.isNotEmpty) {
        final x = n.removeLast();
        n.add(x);
      }
      n.clear();
    } on UnsupportedError {
      if (n.isNotEmpty) frozen.add(path);
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  p21RestoreClockAfterEach();

  group('the worker output: frozen, compact, sized', () {
    final stored = p22Stored(p22DayBundle('2025-04-01', i: 2));

    test('every map and list of the cached graph rejects mutation', () {
      final view = p22View(stored);
      expect(view.debugFrozenRoot, isNotNull);
      _expectFrozen(view.debugFrozenRoot);
    });

    test('curves stay in their stored grid/offset shape (not expanded)', () {
      final root = p22View(stored).debugFrozenRoot as Map;
      for (final path in p22CurvePaths().keys) {
        final curve = _at(root, path);
        expect(curve, isA<Map>(), reason: '$path is a compact curve, not a list');
        expect((curve as Map).containsKey('t0'), isTrue, reason: path);
      }
    });

    test('the compact graph is much smaller than the expanded one', () {
      final view = p22View(stored);
      final compact = p22Nodes(view.debugFrozenRoot);
      final expanded = p22Nodes(view.materialiseLegacy());
      expect(compact * 2, lessThan(expanded),
          reason: 'compact $compact vs expanded $expanded nodes');
      expect(view.estimatedBytes, greaterThanOrEqualTo(64 + 24 * compact));
    });

    test('text that is not a JSON object yields no graph, as decodePayloadJson',
        () {
      for (final text in ['', '{not json', '[1,2,3]', '"s"', '7', 'null']) {
        final out = decodeDayPayloadsHeavy(
          bundleWorkerInputs,
          DecodeChunkInput(payloadJson: [text], projections: const ['full']),
        );
        expect(out.graphs.single, isNull, reason: 'text: $text');
        expect(SeriesCodec.decodePayloadJson(text), isNull);
      }
    });

    test('a projection graph holds only the three Cycle scalars, absent stays '
        'absent', () {
      final full = {
        'scalars': {
          'rhr': 0.0, // a real zero must survive
          'rmssd': 41.5,
          'skin_temp_z': null, // stored null stays absent or null, never 0
          'steps': 9000,
        },
        'sleep': {'big': List<int>.filled(50, 1)},
      };
      final view = p22View(jsonEncode(full), projection: ProjectionId.cycleScalars);
      final root = view.debugFrozenRoot as Map;
      expect(root.keys, ['scalars'], reason: 'nothing but scalars survives');
      final sc = root['scalars'] as Map;
      expect(sc['rhr'], 0.0);
      expect(sc['rmssd'], 41.5);
      expect(sc['skin_temp_z'], isNull);
      expect(sc.containsKey('steps'), isFalse);
      _expectFrozen(root);

      final bare = p22View(jsonEncode({'scalars': {'rmssd': 40}}),
          projection: ProjectionId.cycleScalars);
      final bsc = (bare.debugFrozenRoot as Map)['scalars'] as Map;
      expect(bsc.keys, ['rmssd'], reason: 'rhr and skin_temp_z were absent');
    });
  });

  group('BundleView.owned', () {
    final bundle = p22DayBundle('2025-04-01', i: 2);
    final stored = p22Stored(bundle);
    final expected = SeriesCodec.decodePayloadJson(stored)!;

    test('returns an equal deep copy of a stored subtree', () {
      final view = p22View(stored);
      for (final key in ['scalars', 'sleep', 'clinical', 'flags', 'coverage']) {
        expect(p22Same(view.owned(key), expected[key]), isTrue, reason: key);
      }
    });

    test('every collection of a copy is growable, and changing it changes '
        'nothing the next caller sees', () {
      final view = p22View(stored);
      final first = view.owned('sleep');
      p22Walk(first, (n, path) {
        if (n is Map) n['__mine__'] = 1;
        if (n is List) n.add('__mine__');
      });
      (first as Map).clear();
      expect(p22Same(view.owned('sleep'), expected['sleep']), isTrue);
      expect(p22Same(view.materialiseLegacy(), expected), isTrue);
    });

    test('a copy is a different object from the cached node', () {
      final view = p22View(stored);
      final root = view.debugFrozenRoot as Map;
      expect(identical(view.owned('scalars'), root['scalars']), isFalse);
    });

    test('a curve path comes back expanded, equal to decodePayload', () {
      final view = p22View(stored);
      for (final path in p22CurvePaths().keys) {
        final got = view.owned(path);
        expect(got, isA<List>(), reason: '$path expands to the legacy list');
        expect(p22Same(got, _at(expected, path)), isTrue, reason: path);
      }
    });

    test('a path ABOVE curves expands the curves inside it', () {
      final view = p22View(stored);
      final series = view.owned('series');
      expect(p22Same(series, expected['series']), isTrue);
      expect(p22CompactLeaks(series), isEmpty);
    });

    test('an absent path, or one through a scalar, is null', () {
      final view = p22View(stored);
      expect(view.owned('nope'), isNull);
      expect(view.owned('scalars.nope'), isNull);
      expect(view.owned('scalars.rmssd.deeper'), isNull);
      expect(view.owned('date.deeper'), isNull);
    });

    test('a primitive is returned as it is, type included', () {
      final view = p22View(stored);
      expect(view.owned('scalars.rmssd'), 42.0);
      expect(view.owned('scalars.steps'), isA<int>());
      expect(view.owned('scalars.steps'), 5000);
      expect(view.owned('date'), '2025-04-01');
    });
  });

  group('BundleView.curve parity with SeriesCodec.decodePayload', () {
    final paths = p22CurvePaths();

    for (final shape in _shapes().entries) {
      test('every curve slot, shape: ${shape.key}', () {
        for (final slot in paths.entries) {
          final text = _payloadWith(slot.key, shape.value(slot.value));
          final want = _at(SeriesCodec.decodePayloadJson(text), slot.key);
          final got = p22View(text).curve(slot.key);
          expect(
            jsonEncode(got),
            jsonEncode(want),
            reason: '${slot.key} (value key ${slot.value}) holding ${shape.key}',
          );
        }
      });
    }

    test('an absent slot is null, as in decodePayload', () {
      final text = jsonEncode({'scalars': {}, 'series': {}});
      final view = p22View(text);
      for (final path in paths.keys) {
        expect(view.curve(path), isNull, reason: path);
      }
    });

    test('zone_timeline expands with the z key, the others with v', () {
      final text = jsonEncode({
        'series': {
          'zone_timeline': {'t0': 10, 'dt': 5, 'v': [3, 4]},
          'hr_curve': {'t0': 10, 'dt': 5, 'v': [3, 4]},
        },
      });
      final view = p22View(text);
      expect(view.curve('series.zone_timeline'), [
        {'t': 10, 'z': 3},
        {'t': 15, 'z': 4},
      ], reason: 'stored as v, expanded under the slot\'s own value key z');
      expect(view.curve('series.hr_curve'), [
        {'t': 10, 'v': 3},
        {'t': 15, 'v': 4},
      ]);
    });
  });

  group('BundleView.materialiseLegacy equals decodePayloadJson', () {
    void check(String name, String text) {
      test(name, () {
        final want = SeriesCodec.decodePayloadJson(text);
        expect(want, isNotNull, reason: 'fixture must decode');
        expect(jsonEncode(p22View(text).materialiseLegacy()), jsonEncode(want));
      });
    }

    check('the real golden bundle, stored compact', p22Stored(p22RealBundle()));
    check('a full-day-shaped bundle', p22Stored(p22DayBundle('2025-04-01', i: 3)));
    check('legacy list curves left as stored',
        jsonEncode(p22DayBundle('2025-04-01', i: 3)));
    check('series is not a map',
        jsonEncode({'series': [1, 2], 'scalars': {'rhr': 1}}));
    check('series is null', jsonEncode({'series': null}));
    check('no series at all', jsonEncode({'scalars': {}}));
    check('a foreign map under a curve key is left alone',
        jsonEncode({'series': {'hr_curve': {'foo': 1}}, 'activity_curve': {'bar': 2}}));
    check(
      'every curve slot holds a different odd shape',
      jsonEncode({
        'series': {
          'hr_curve': {'t0': 1, 'to': [0, 1.5], 'v': [1, 2]},
          'strain_curve': {'t0': 1, 'dt': 2},
          'hrv_timeline': {'t0': 1, 'dt': 2, 'v': [5, 6, 7]},
          'hrv_day': <Object?>[],
          'resp_day': null,
          'skin_temp_day': {'t0': 1, 'to': [0, 3], 'v': [1, 2]},
          'zone_timeline': {'t0': 1, 'dt': 60, 'v': [0, 1]},
        },
        'activity_curve': {'t0': 5, 'dt': 5, 'v': [1, 2, 3]},
      }),
    );

    test('a corrupt payload has no view at all (the worker answers null)', () {
      final out = decodeDayPayloadsHeavy(
        bundleWorkerInputs,
        const DecodeChunkInput(payloadJson: ['{oops'], projections: ['full']),
      );
      expect(out.graphs.single, isNull);
    });

    test('the result is the caller\'s own: changing it changes nothing', () {
      final text = p22Stored(p22DayBundle('2025-04-01', i: 3));
      final view = p22View(text);
      final a = view.materialiseLegacy();
      a['scalars'] = 'gone';
      (a['series'] as Map).clear();
      expect(jsonEncode(view.materialiseLegacy()),
          jsonEncode(SeriesCodec.decodePayloadJson(text)));
    });
  });

  group('no compact shape and no frozen node reaches a caller', () {
    late Database db;
    setUp(() async => db = await p21Fresh(_name));
    tearDown(() => p21Drop(_name));

    test('BundleView has no accessor that returns a curve key unexpanded', () {
      final src = stripCommentsAndStrings(
        File('lib/data/bundle_store.dart').readAsStringSync(),
      );
      final body = _classBody(src, 'final class BundleView');
      final members = RegExp(r'\n  (?:static |@visibleForTesting )*[\w<>?, ]+? ([a-zA-Z]\w*)\s*(?:\(|=>|\{)')
          .allMatches(body)
          .map((m) => m.group(1)!)
          .where((n) => !n.startsWith('_'))
          .toSet();
      expect(
        members.difference({
          'frozen', 'estimatedBytes', 'debugCopiedNodes', 'debugResetCopiedNodes',
          'debugFrozenRoot', 'owned', 'curve', 'materialiseLegacy', 'BundleView',
        }),
        isEmpty,
        reason: 'a new public accessor is a way to leak the cached graph',
      );
    });

    test('walking every reader output finds no curve map and no cached node',
        () async {
      final lane = P22Lane();
      final store = p22Store(lane);
      p22UseStore(store);
      final today = p22Today();
      await p22SeedReaderDb(db, today);
      final repo = LocalRepositoryImpl(getProfileMap: () => p22Profile);

      final outputs = <String, Object?>{};
      for (final day in [...p22Days, today]) {
        for (final e in p22DayReaders.entries) {
          outputs['${e.key}($day)'] = await e.value(repo, day);
        }
      }
      for (final e in p22GlobalReaders.entries) {
        outputs[e.key] = await e.value(repo);
      }

      // Passes before P2.2 and must keep passing: no compact curve map in any
      // reader's output.
      final compact = <String>[];
      outputs.forEach((name, out) {
        for (final p in p22CompactLeaks(out)) {
          compact.add('$name:$p');
        }
      });
      expect(compact, isEmpty, reason: 'a compact curve reached a reader output');

      // New with P2.2: nothing in an output is a node of a cached graph.
      final cached = HashSet<Object>.identity();
      for (final v in store.debugCachedViews) {
        p22Walk(v.debugFrozenRoot, (n, _) {
          if (n is Map || n is List) cached.add(n!);
        });
      }
      final leaks = <String>[];
      outputs.forEach((name, out) {
        p22Walk(out, (n, path) {
          if ((n is Map || n is List) && cached.contains(n)) {
            leaks.add('$name:$path');
          }
        });
      });
      expect(leaks, isEmpty, reason: 'cached frozen nodes reached a caller');
      expect(store.debugCachedKeys, isNotEmpty,
          reason: 'the readers must be served through the BundleStore');
    });

    test('the generic mutation probe: every list and map a reader returns can '
        'be changed, and changing it changes no later read', () async {
      final store = p22Store(P22Lane());
      p22UseStore(store);
      final today = p22Today();
      await p22SeedReaderDb(db, today);
      final repo = LocalRepositoryImpl(getProfileMap: () => p22Profile);

      final calls = <String, Future<Object?> Function()>{
        for (final day in [p22D1, p22D2, p22D3, today])
          for (final e in p22DayReaders.entries)
            '${e.key}($day)': () => e.value(repo, day),
        for (final e in p22GlobalReaders.entries) e.key: () => e.value(repo),
      };
      final frozenOnes = <String>[];
      for (final c in calls.entries) {
        final first = await c.value();
        final before = jsonEncode(first);
        _probe(first, c.key, frozenOnes);
        final again = jsonEncode(await c.value());
        expect(again, before, reason: '${c.key}: a later read saw the change');
      }
      expect(frozenOnes, isEmpty, reason: 'frozen graph leaked to callers');
      expect(store.debugCachedKeys, isNotEmpty,
          reason: 'the readers must be served through the BundleStore');
    });

    test('per-reader copy budget: a reader copies about what it returns, never '
        'the whole bundle', () async {
      final store = p22Store(P22Lane());
      p22UseStore(store);
      final today = p22Today();
      await p22SeedReaderDb(db, today);
      final repo = LocalRepositoryImpl(getProfileMap: () => p22Profile);
      // Warm every bundle first: the budget is about the copy a HIT makes.
      for (final e in p22DayReaders.entries) {
        await e.value(repo, p22D1);
      }

      final whole = p22Nodes(
        SeriesCodec.decodePayloadJson(p22Stored(p22DayBundle(p22D1, i: 1))),
      );
      final over = <String>[];
      for (final e in p22DayReaders.entries) {
        BundleView.debugResetCopiedNodes();
        final out = await e.value(repo, p22D1);
        final copied = BundleView.debugCopiedNodes;
        final budget = 2 * p22Nodes(out) + 64;
        if (copied > budget) {
          over.add('${e.key}: copied $copied nodes, returned ${p22Nodes(out)}, '
              'budget $budget, whole bundle $whole');
        }
      }
      expect(over, isEmpty);
    });
  });
}
