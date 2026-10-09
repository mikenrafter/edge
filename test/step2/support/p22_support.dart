// Shared fixtures for the design 02 step 2 / P2.2 tests (BundleStore, read
// seam). Real LocalDb over sqflite_ffi, no wall clock: `LocalDb.nowMs` is
// frozen through P21Clock where it matters.
//
// The ONE place that names the BundleStore surface the tests rely on:
//   * `BundleStore(lane: ..., queueWait: ...)`, `readOnce / read / project /
//     readAll / warm / invalidateDays / invalidateAll`, the `debug*` getters,
//     `BundleStore.debugUseShared / debugResetShared`;
//   * `BundleView.frozen(root, estimatedBytes:)`, `owned / curve /
//     materialiseLegacy / debugFrozenRoot`, `BundleView.debugCopiedNodes`;
//   * the worker entry `decodeDayPayloadsHeavy` and `bundleWorkerInputs`.
// All of them exist as throwing stubs in lib/data/bundle_store.dart.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/compute/derive_perf.dart' show payloadNodeCount;
import 'package:openstrap_edge/data/bundle_store.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/data/series_codec.dart';

import 'p21_support.dart';

export 'p21_support.dart';

// ── fixtures ──────────────────────────────────────────────────────────────

const String p22RealBundlePath = 'test/fixtures/two_device_day_expected.json';

/// The real inner bundle of the golden two-device day (decoded, legacy curves).
Map<String, dynamic> p22RealBundle() =>
    ((jsonDecode(File(p22RealBundlePath).readAsStringSync())
                as Map)['single_device']
            as Map)
        .cast<String, dynamic>();

Object? p22Clone(Object? v) => jsonDecode(jsonEncode(v));

List<Map<String, dynamic>> p22Curve(
  int t0,
  int n, {
  int dt = 60,
  String key = 'v',
  num base = 60,
}) => [
  for (var i = 0; i < n; i++) {'t': t0 + i * dt, key: base + (i % 17)},
];

/// A day bundle shaped like a real one (the golden fixture) with [points]-point
/// curves in every slot `SeriesCodec` knows, tagged by [marker]. Legacy list
/// curves: store it through [p22Seed] to get the compact stored form.
Map<String, dynamic> p22DayBundle(
  String day, {
  int i = 0,
  bool sleep = true,
  int points = 120,
  int? t0,
  String marker = 'p22',
}) {
  final b = (p22Clone(p22RealBundle()) as Map).cast<String, dynamic>();
  final start = t0 ?? (localDayStartSec(day) ?? 1577836800);
  b['date'] = day;
  b['p22_marker'] = marker;
  final sc = (b['scalars'] as Map).cast<String, dynamic>();
  sc['rmssd'] = 40.0 + i;
  sc['rhr'] = 55.0 + i;
  sc['skin_temp_z'] = i.isOdd ? -0.5 + i * 0.1 : null;
  sc['steps'] = 4000 + 500 * i;
  sc['strain'] = 8.0 + i;
  sc['readiness'] = 60.0 + i;
  if (!sleep) b.remove('sleep');
  final series = (b['series'] as Map).cast<String, dynamic>();
  series['hr_curve'] = p22Curve(start, points, base: 60 + i);
  series['strain_curve'] = p22Curve(start, points, dt: 300, base: 1.5);
  series['hrv_timeline'] = p22Curve(start, points, dt: 61, base: 30.0 + i);
  series['hrv_day'] = p22Curve(start, points, dt: 120, base: 35.0);
  series['resp_day'] = p22Curve(start, points, dt: 90, base: 14.0);
  series['skin_temp_day'] = p22Curve(start, points, dt: 300, base: 33.0);
  series['zone_timeline'] = [
    for (var k = 0; k < points; k++) {'t': start + k * 60, 'z': k % 6},
  ];
  b['activity_curve'] = p22Curve(start, points, dt: 60, base: 0);
  return b;
}

String p22Stored(Map<String, dynamic> bundle) =>
    SeriesCodec.encodePayloadJson(jsonEncode(bundle));

/// Insert one `day_result` row directly (compact stored form) so the seed does
/// not depend on the writer under test.
Future<void> p22Seed(
  Database db,
  String day,
  Map<String, dynamic> bundle, {
  int version = p21Version,
  int computedAt = 1000,
  bool finalized = false,
}) async {
  final sc = (bundle['scalars'] as Map?) ?? const {};
  await db.insert('day_result', {
    'day_id': day,
    'algo_version': version,
    'payload_json': p22Stored(bundle),
    'window_json': '{}',
    'computed_at': computedAt,
    'finalized': finalized ? 1 : 0,
    'skipped': 0,
    'partial': 0,
    'rhr': (sc['rhr'] as num?)?.toDouble(),
    'rmssd': (sc['rmssd'] as num?)?.toDouble(),
    'readiness': (sc['readiness'] as num?)?.toDouble(),
  }, conflictAlgorithm: ConflictAlgorithm.replace);
}

/// A small payload (not a full bundle) that says which write made it.
String p22Tiny(String tag, {String day = '2026-03-10'}) => jsonEncode({
  'date': day,
  'tag': tag,
  'scalars': {'rhr': 50.0, 'rmssd': 60.0, 'skin_temp_z': -0.25},
  'series': {
    'hr_curve': p22Curve(1700000000, 6),
  },
});

Future<bool> p22Put(
  String day,
  String tag, {
  int version = p21Version,
  bool finalized = false,
  DayResultWrite reason = DayResultWrite.derive,
  String? payload,
}) => LocalDb.putDayResult(
  dayId: day,
  algoVersion: version,
  payloadJson: payload ?? p22Tiny(tag, day: day),
  windowJson: '{}',
  finalized: finalized,
  reason: reason,
);

/// The `tag` of an Ok read, via the same view API callers use.
Object? p22TagOf(BundleRead r) =>
    r is BundleOk ? r.view.owned('tag') : 'not-ok:${r.runtimeType}';

// ── lanes ─────────────────────────────────────────────────────────────────

/// A decode lane that runs the real worker entry in-process and records every
/// chunk. [hook] runs after the chunk is recorded and before the decode is
/// returned, so a test can commit a DB change "between dispatch and
/// completion". [holdAll] / [hold] park a chunk until [release].
class P22Lane implements BundleDecodeLane {
  final List<DecodeChunkInput> chunks = [];
  Future<void> Function(int index, DecodeChunkInput chunk)? hook;
  bool holdAll = false;
  final Set<int> _hold = {};
  final Map<int, Completer<void>> _gates = {};
  final List<(int, Completer<void>)> _arrivals = [];

  /// Park chunk number [index] (0-based) until [release].
  void hold(int index) => _hold.add(index);

  void release(int index) =>
      (_gates[index] ??= Completer<void>()).complete();

  void releaseAll() {
    holdAll = false;
    for (var i = 0; i < 64; i++) {
      final g = _gates[i] ??= Completer<void>();
      if (!g.isCompleted) g.complete();
    }
  }

  /// Completes once [n] chunks have reached the lane.
  Future<void> arrived(int n) {
    if (chunks.length >= n) return Future.value();
    final c = Completer<void>();
    _arrivals.add((n, c));
    return c.future;
  }

  /// Number of payloads decoded across all chunks.
  int get payloads => chunks.fold(0, (a, c) => a + c.payloadJson.length);

  /// Sizes of the chunks, in order.
  List<int> get sizes => [for (final c in chunks) c.payloadJson.length];

  @override
  Future<DecodedChunk> decode(DecodeChunkInput chunk) async {
    final index = chunks.length;
    chunks.add(chunk);
    for (final (n, c) in List.of(_arrivals)) {
      if (chunks.length >= n && !c.isCompleted) {
        c.complete();
        _arrivals.remove((n, c));
      }
    }
    final h = hook;
    if (h != null) await h(index, chunk);
    if (holdAll || _hold.contains(index)) {
      await (_gates[index] ??= Completer<void>()).future;
    }
    return decodeDayPayloadsHeavy(bundleWorkerInputs, chunk);
  }
}

/// A fresh store over [lane].
BundleStore p22Store(P22Lane lane, {Duration? queueWait}) => queueWait == null
    ? BundleStore(lane: lane)
    : BundleStore(lane: lane, queueWait: queueWait);

/// Polls [cond] between event-loop turns. Condition-based, not time-based.
Future<void> p22Until(bool Function() cond, String what) async {
  for (var i = 0; i < 20000; i++) {
    if (cond()) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('timed out waiting for: $what');
}

// ── graph helpers ─────────────────────────────────────────────────────────

/// Every node of [v] with its path, maps and lists included.
void p22Walk(Object? v, void Function(Object? node, String path) visit, [String path = '']) {
  visit(v, path);
  if (v is Map) {
    for (final e in v.entries) {
      p22Walk(e.value, visit, path.isEmpty ? '${e.key}' : '$path.${e.key}');
    }
  } else if (v is List) {
    for (var i = 0; i < v.length; i++) {
      p22Walk(v[i], visit, '$path[$i]');
    }
  }
}

int p22Nodes(Object? v) => payloadNodeCount(v);

/// Paths of maps `SeriesCodec` would expand into a curve: a compact curve that
/// reached somewhere it must not.
List<String> p22CompactLeaks(Object? out) {
  final leaks = <String>[];
  p22Walk(out, (node, path) {
    if (node is! Map) return;
    for (final key in const ['v', 'z']) {
      if (SeriesCodec.decodeCurve(node, valueKey: key) is List) {
        leaks.add(path);
        return;
      }
    }
  });
  return leaks;
}

/// The curve slots `SeriesCodec` knows: dotted path to value key.
Map<String, String> p22CurvePaths() => {
  for (final e in SeriesCodec.seriesCurves.entries) 'series.${e.key}': e.value,
  for (final e in SeriesCodec.rootCurves.entries) e.key: e.value,
};

/// Run the real worker entry on [payloadJson] and wrap the frozen result.
BundleView p22View(String payloadJson, {ProjectionId projection = ProjectionId.full}) {
  final out = decodeDayPayloadsHeavy(
    bundleWorkerInputs,
    DecodeChunkInput(payloadJson: [payloadJson], projections: [projection.name]),
  );
  return BundleView.frozen(
    out.graphs.single,
    estimatedBytes: out.estimatedBytes.single,
  );
}

/// Deep structural equality of two JSON-shaped values (type-strict on num).
bool p22Same(Object? a, Object? b) => jsonEncode(a) == jsonEncode(b);

// ── repository readers ────────────────────────────────────────────────────

typedef P22DayReader = Future<Object?> Function(LocalRepositoryImpl r, String day);

/// Every repository reader that takes a day and is served from a bundle.
final Map<String, P22DayReader> p22DayReaders = {
  'getDayHeart': (r, d) => r.getDayHeart(d),
  'getDayHrv': (r, d) => r.getDayHrv(d),
  'getDaySleep': (r, d) => r.getDaySleep(d),
  'getDaySleepV2': (r, d) => r.getDaySleepV2(d),
  'getDayLungs': (r, d) => r.getDayLungs(d),
  'getDayWear': (r, d) => r.getDayWear(d),
  'getDayNaps': (r, d) => r.getDayNaps(d),
  'getDaySteps': (r, d) => r.getDaySteps(d),
  'getDayStress': (r, d) => r.getDayStress(d),
  'getDayStrain': (r, d) => r.getDayStrain(d),
  'getDayOverview': (r, d) => r.getDayOverview(d),
  'getDayTimeline': (r, d) => r.getDayTimeline(d),
};

/// Readers with no day argument.
final Map<String, Future<Object?> Function(LocalRepositoryImpl r)> p22GlobalReaders = {
  'getToday': (r) => r.getToday(),
  'getInsights': (r) => r.getInsights(),
  'getChart(hr)': (r) => r.getChart('hr'),
  'getZones': (r) => r.getZones(),
  'getCycle': (r) => r.getCycle(),
};

/// Today's local label, named once per test.
String p22Today() => todayLabel();

/// Install [store] as the repository's store for one test.
void p22UseStore(BundleStore store) {
  BundleStore.debugUseShared(store);
  addTearDown(BundleStore.debugResetShared);
}

// ── the seeded reader database ────────────────────────────────────────────

/// Historical days (fixed labels, none can be today). `d3` has no sleep, `d4`
/// holds an undecodable payload, `d5` is served from an older algo version
/// (and `d1` also has a row ABOVE the served ceiling that must never show),
/// `d9` has no row at all.
const String p22D1 = '2025-03-01';
const String p22D2 = '2025-03-02';
const String p22D3 = '2025-03-03';
const String p22D4 = '2025-03-04';
const String p22D5 = '2025-03-05';
const String p22D9 = '2025-03-09';
const List<String> p22Days = [p22D1, p22D2, p22D3, p22D4, p22D5, p22D9];

/// The profile every reader test uses (cycle tracking on).
final Map<String, dynamic> p22Profile = {
  'track_cycle': true,
  'repro_state': 'cycling',
};

/// Seed the reader database: three historical days (compact stored curves, d3
/// without sleep), a bundle for [today] whose curves fall inside today's local
/// window, a fresh cross-day rollup and three cycle starts. `LocalDb.nowMs` is
/// frozen. Returns nothing; read it back through the repository.
Future<void> p22SeedReaderDb(Database db, String today) async {
  LocalDb.nowMs = P21Clock(1700000000000).call;
  await p22Seed(db, p22D1, p22DayBundle(p22D1, i: 1), computedAt: 1001);
  await p22Seed(db, p22D2, p22DayBundle(p22D2, i: 2), computedAt: 1002);
  await p22Seed(db, p22D3, p22DayBundle(p22D3, i: 3, sleep: false), computedAt: 1003);
  await p22Seed(db, today, p22DayBundle(today, i: 4), computedAt: 1004);
  await p22Seed(db, p22D5, p22DayBundle(p22D5, i: 5),
      version: p21Version - 1, computedAt: 1005);
  await p22Seed(db, p22D1, p22DayBundle(p22D1, i: 7, marker: 'above'),
      version: p21Version + 1, computedAt: 1006);
  await db.insert('day_result', {
    'day_id': p22D4,
    'algo_version': p21Version,
    'payload_json': '{not json',
    'window_json': '{}',
    'computed_at': 1007,
    'finalized': 0,
    'skipped': 0,
    'partial': 0,
  });
  await LocalDb.putBaseline(
    'crossday',
    jsonEncode({
      'algo_version': p21Version,
      'built_for_day': today,
      'p22_crossday': true,
      'sleep_coach': {
        'need': {
          'value': {'need_sec': 28800},
        },
      },
      'load': {'acwr': 1.1},
    }),
  );
  for (final d in const ['2025-02-01', '2025-03-01', '2025-03-29']) {
    await LocalDb.putCycleLog(d, 'start');
  }
}

/// Lets every database call issued so far finish: sqflite answers a database's
/// commands in order, so a round trip made after them returns after them.
Future<void> p22Flush(Database db) async {
  await Future<void>.delayed(Duration.zero);
  await db.rawQuery('SELECT 1');
  await Future<void>.delayed(Duration.zero);
}
