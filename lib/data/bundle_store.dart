// bundle_store.dart — the one reader of stored `day_result` / `baselines`
// payloads on the UI side (design 02, step 2, P2.2; scope note sections 4.2-4.4).
//
// The single reader for stored day and baseline payloads. The cache, flights,
// queue accounting and generation snapshots are owned here.
//
// OWNER of the mutable state (AGENTS.md section 6, one owner per state): the
// decoded-bundle cache, the flight table and the queue accounting live in
// [BundleStore] and nowhere else. Callers get sealed [BundleRead] results and
// caller-owned subtrees, never the cached graph.
//
// Contract, in one place:
//   * META FIRST. A read starts with the payload-free meta query
//     (`LocalDb.dayResultMeta` for a day, the baseline's `row_rev` for a
//     baseline). The cache key is (generation, kind, k1, k2, rev, projection);
//     a replaced, deleted or restored row presents another rev or none, so it
//     misses without anyone invalidating anything.
//   * ONE DECODE POINT. This is the only caller of
//     `SeriesCodec.decodePayloadJson` outside worker entries, and the decode
//     itself runs in the registered @heavy entry [decodeDayPayloadsHeavy].
//   * FENCED. After the worker returns, and before the result is cached or
//     handed to anyone, the store re-reads (kind, k1, k2, rev) and the
//     generation; a difference makes the completion [BundleStale].
//   * COMPACT, FROZEN, OWNED. The cached graph is deep-unmodifiable and keeps
//     curves in their stored grid/offset shape. A caller takes a copy of what
//     it needs ([BundleView.owned], [BundleView.curve]); nothing compact
//     reaches a legacy consumer.

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../util/heavy.dart';
import '../util/worker_audit.dart';
import '../util/worker_entries.dart' show Dispatcher;
import '../util/worker_init.dart';
import '../compute/derive_perf.dart' show payloadNodeCount;
import 'db.dart';
import 'day_payload_read.dart';
import 'series_codec.dart';

/// `LocalDb.storeGeneration`: changes on wipe, rebuild, merge and reopen.
typedef StoreGeneration = ({int wipeEpoch, int openCount});

/// The decode reads no clock, zone or locale, so its inputs are fixed.
const WorkerInputs bundleWorkerInputs =
    WorkerInputs(nowEpochMs: 0, zoneId: 'UTC', localeTag: 'en');

/// What is decoded out of a payload. [full] is the whole bundle; the others are
/// projections held in a separate, smaller cache.
enum ProjectionId {
  /// The whole bundle, compact and frozen.
  full,

  /// `scalars.{skin_temp_z, rhr, rmssd}` and nothing else (Cycle, Q6). A key
  /// absent from the stored scalars stays absent.
  cycleScalars,
}

/// The stored row a read is about: a served day, or one baseline.
final class BundleSource {
  /// The served `day_result` of [day] (highest `algo_version` at or below the
  /// served ceiling).
  const BundleSource.day(String day) : kind = 'day_result', k1 = day;

  /// The `baselines` row [key] (for example `crossday`).
  const BundleSource.baseline(String key) : kind = 'baselines', k1 = key;

  /// `day_result` or `baselines`, as in `row_rev.kind`.
  final String kind;

  /// `day_id` or the baseline key.
  final String k1;
}

/// The identity of one cached decode: `(generation, kind, k1, k2, rev,
/// projection)`. `k2` is the served `algo_version` for a day and 0 for a
/// baseline. A key never mixes the two tables.
final class BundleKey {
  const BundleKey({
    required this.generation,
    required this.kind,
    required this.k1,
    required this.k2,
    required this.rev,
    required this.projection,
  });

  final StoreGeneration generation;
  final String kind;
  final String k1;
  final int k2;
  final int rev;
  final ProjectionId projection;

  @override
  bool operator ==(Object other) =>
      other is BundleKey &&
      other.generation == generation &&
      other.kind == kind &&
      other.k1 == k1 &&
      other.k2 == k2 &&
      other.rev == rev &&
      other.projection == projection;

  @override
  int get hashCode =>
      Object.hash(generation, kind, k1, k2, rev, projection);

  @override
  String toString() =>
      'BundleKey($generation, $kind, $k1, $k2, rev $rev, ${projection.name})';
}

/// Outcome of one read attempt. Sealed (AGENTS.md section 6): the three cases
/// need three different reactions.
sealed class BundleRead {
  const BundleRead();
}

/// The row exists, its decode is current for [key], and [view] holds it.
final class BundleOk extends BundleRead {
  const BundleOk({required this.view, required this.key, required this.asOfMs});

  final BundleView view;
  final BundleKey key;

  /// `computed_at` (day) or `updated_at` (baseline) of the row, read FRESH from
  /// the meta on every call; never cached with the bundle.
  final int? asOfMs;
}

/// No served row, or the stored payload is undecodable ([undecodable]). Never
/// a substitute value.
final class BundleAbsent extends BundleRead {
  const BundleAbsent({this.undecodable = false});
  final bool undecodable;
}

/// A replace, delete or wipe committed while this read was in flight. Not an
/// error: the caller re-reads the meta once.
final class BundleStale extends BundleRead {
  const BundleStale();
}

/// A read that was stale twice in a row. Retryable; never shown as an empty
/// state.
final class BundleRetryable implements Exception {
  const BundleRetryable(this.source);
  final BundleSource source;

  @override
  String toString() => 'BundleRetryable(${source.kind} ${source.k1})';
}

/// A decoded bundle as the store keeps it: frozen and compact. The only ways
/// out are [owned], [curve] and [materialiseLegacy], and each returns a value
/// the caller may keep and change.
final class BundleView {
  /// Wraps an already frozen compact [root]. Test and store use only.
  @visibleForTesting
  BundleView.frozen(this._root, {required this.estimatedBytes});

  final Object? _root;

  /// `64 + 24 x nodes + 2 x string characters`, computed in the worker.
  final int estimatedBytes;

  /// Nodes copied for callers since [debugResetCopiedNodes]: every
  /// [owned] / [curve] / [materialiseLegacy] adds the size of what it returned.
  static int _copiedNodes = 0;
  @visibleForTesting
  static int get debugCopiedNodes => _copiedNodes;

  @visibleForTesting
  static void debugResetCopiedNodes() => _copiedNodes = 0;

  /// The cached root itself (deep-unmodifiable). Test seam: mutation must throw
  /// [UnsupportedError].
  Object? get debugFrozenRoot => _root;

  /// A deep copy of the subtree at dotted [path] (`'scalars'`,
  /// `'sleep.accounting.value'`). A path naming a curve (`series.hr_curve`,
  /// `activity_curve`) is expanded exactly as `SeriesCodec.decodePayload` does.
  /// Null when the path is absent.
  Object? owned(String path) => _bundleViewOwned(this, _root, path);

  /// The curve at [path] expanded by `SeriesCodec.decodeCurve` with the value
  /// key that `seriesCurves` / `rootCurves` gives it. A shape `decodeCurve`
  /// cannot expand comes back unchanged.
  Object? curve(String path) => _bundleViewCurve(this, _root, path);

  /// The whole bundle as `SeriesCodec.decodePayloadJson` would have returned
  /// it: every known curve expanded, owned by the caller. Test-only parity seam;
  /// production legacy payloads are expanded inside the worker.
  @visibleForTesting
  Map<String, dynamic> materialiseLegacy() => _bundleViewMaterialise(this, _root);

}

Object? _bundleViewOwned(BundleView view, Object? root, String path) {
  final value = _bundleAtPath(root, path);
  if (identical(value, _bundleMissing)) return null;
  final copy = _bundleCopy(_bundleExpand(path, value));
  BundleView._copiedNodes += payloadNodeCount(copy);
  return copy;
}

Object? _bundleViewCurve(BundleView view, Object? root, String path) {
  final value = _bundleAtPath(root, path);
  if (identical(value, _bundleMissing)) return null;
  final key = _bundleCurveValueKey(path);
  final copy = _bundleCopy(SeriesCodec.decodeCurve(_bundleUnpack(value), valueKey: key ?? 'v'));
  BundleView._copiedNodes += payloadNodeCount(copy);
  return copy;
}

Map<String, dynamic> _bundleViewMaterialise(BundleView view, Object? root) {
  final copy = _bundleCopy(_bundleExpand('', root)) as Map<String, dynamic>;
  BundleView._copiedNodes += payloadNodeCount(copy);
  return copy;
}

const Object _bundleMissing = Object();

Object? _bundleAtPath(Object? root, String path) {
  Object? current = root;
  for (final part in path.split('.')) {
    if (current is! Map || !current.containsKey(part)) return _bundleMissing;
    current = current[part];
  }
  return current;
}

String? _bundleCurveValueKey(String path) {
  if (path.startsWith('series.')) return SeriesCodec.seriesCurves[path.substring(7)];
  return SeriesCodec.rootCurves[path];
}

Object? _bundleExpand(String path, Object? value) {
  if (value is _FrozenSequence) {
    return [for (final item in value.values) _bundleExpand(path, item)];
  }
  final key = _bundleCurveValueKey(path);
  if (key != null) return SeriesCodec.decodeCurve(_bundleUnpack(value), valueKey: key);
  if (value is Map) {
    return <String, dynamic>{
      for (final e in value.entries)
        e.key as String: _bundleExpand(path.isEmpty ? '${e.key}' : '$path.${e.key}', e.value),
    };
  }
  if (value is List) return [for (final item in value) _bundleCopy(item)];
  return value;
}

Object? _bundleCopy(Object? value) {
  if (value is _FrozenSequence) return [for (final item in value.values) _bundleCopy(item)];
  if (value is Map) {
    return <String, dynamic>{for (final e in value.entries) e.key as String: _bundleCopy(e.value)};
  }
  if (value is List) return <dynamic>[for (final item in value) _bundleCopy(item)];
  return value;
}

Object? _bundleUnpack(Object? value) {
  if (value is _FrozenSequence) return [for (final item in value.values) _bundleUnpack(item)];
  if (value is Map) {
    return <String, dynamic>{for (final e in value.entries) e.key as String: _bundleUnpack(e.value)};
  }
  return value;
}

/// One chunk of stored payload text handed to the decode worker.
@sendable
class DecodeChunkInput {
  const DecodeChunkInput({
    required this.payloadJson,
    required this.projections,
  });

  /// The stored `payload_json` texts, in request order.
  final List<String> payloadJson;

  /// `ProjectionId.name` per payload, same order.
  final List<String> projections;
}

/// What the decode worker returns for a chunk, one entry per input.
@SendableShape('frozen compact graphs with immutable sequences and JSON values')
class DecodedChunk {
  const DecodedChunk({
    required this.graphs,
    required this.estimatedBytes,
    required this.nodes,
  });

  /// The frozen compact graph, or null when the text is not a JSON object.
  final List<Object?> graphs;
  final List<int> estimatedBytes;
  final List<int> nodes;
}

/// WORKER ENTRY: parses payloads, freezes compact graphs and accounts bytes.
@heavy
DecodedChunk decodeDayPayloadsHeavy(
  WorkerInputs inputs,
  DecodeChunkInput input,
) {
  WorkerInit.ensure(inputs);
  assertWorker();
  WorkerAudit.entered('decodeDayPayloadsHeavy');
  if (input.payloadJson.length != input.projections.length) {
    throw ArgumentError('payload/projection count mismatch');
  }
  final graphs = <Object?>[];
  final bytes = <int>[];
  final nodes = <int>[];
  for (var i = 0; i < input.payloadJson.length; i++) {
    Object? decoded;
    try {
      decoded = jsonDecode(input.payloadJson[i]);
    } catch (_) {
      decoded = null;
    }
    if (decoded is! Map) {
      graphs.add(null);
      bytes.add(0);
      nodes.add(0);
      continue;
    }
    final root = decoded.cast<String, dynamic>();
    Object? graph;
    if (input.projections[i] == 'full') {
      graph = root;
    } else if (input.projections[i] == 'cycleScalars') {
        final raw = root['scalars'];
        final scalars = raw is Map ? raw : const <String, dynamic>{};
        graph = {
          'scalars': {
            for (final key in const ['skin_temp_z', 'rhr', 'rmssd'])
              if (scalars.containsKey(key)) key: scalars[key],
          },
        };
    } else if (input.projections[i] == 'legacy') {
      graph = SeriesCodec.decodePayload(root.cast<String, dynamic>());
    } else {
      throw ArgumentError('unknown BundleStore projection: ${input.projections[i]}');
    }
    // The root reference is also a retained graph node for cache accounting.
    final count = payloadNodeCount(graph) + 1;
    var chars = 0;
    void countStrings(Object? v) {
      if (v is String) chars += v.length;
      if (v is Map) {
        for (final child in v.values) {
          countStrings(child);
        }
      } else if (v is List) {
        for (final child in v) {
          countStrings(child);
        }
      }
    }
    countStrings(graph);
    final estimated = 64 + 24 * count + 2 * chars;
    graphs.add(_freeze(graph));
    bytes.add(estimated);
    nodes.add(count);
  }
  return DecodedChunk(graphs: graphs, estimatedBytes: bytes, nodes: nodes);
}

final class _FrozenSequence {
  _FrozenSequence(Iterable<Object?> values)
    : values = List<Object?>.unmodifiable(values.map(_freeze));
  final List<Object?> values;

  /// Lets the worker sendability audit compare this immutable list as JSON.
  List<Object?> toJson() => values;
}

Object? _freeze(Object? value) {
  if (value is Map) {
    return Map<String, dynamic>.unmodifiable({
      for (final e in value.entries) e.key as String: _freeze(e.value),
    });
  }
  if (value is List) return _FrozenSequence(value);
  return value;
}

/// Where a chunk is decoded. An interface and not a function-typed field, so
/// the heavy-calc guard resolves the call (see `write-through test gate`).
abstract interface class BundleDecodeLane {
  Future<DecodedChunk> decode(DecodeChunkInput chunk);
}

/// The production lane: `Isolate.run(decodeDayPayloadsHeavy)`.
final class IsolateBundleDecodeLane implements BundleDecodeLane {
  const IsolateBundleDecodeLane();

  @override
  Future<DecodedChunk> decode(DecodeChunkInput chunk) {
    final dispatchId = WorkerAudit.dispatched(Dispatcher.run, 'bundle decode');
    // Null in production; a test's port so the worker reports its entry.
    final auditPort = WorkerAudit.auditPort;
    return Isolate.run(() {
      WorkerAudit.adopt(auditPort, dispatchId);
      return decodeDayPayloadsHeavy(bundleWorkerInputs, chunk);
    });
  }
}

/// Outcome of [BundleStore.warm]. Sealed: a refused warm is not a failure.
sealed class WarmResult {
  const WarmResult();
}

/// [decoded] sources are now cached (hits and absent sources are not counted).
final class WarmDone extends WarmResult {
  const WarmDone(this.decoded);
  final int decoded;
}

/// The lane is over its queue limits; nothing was queued. A warm never waits.
final class WarmRefusedBusy extends WarmResult {
  const WarmRefusedBusy();
}

/// The cache, the flight table and the read path. One process-wide instance
/// ([shared]); tests build their own with a recording lane.
class BundleStore {
  BundleStore({
    BundleDecodeLane lane = const IsolateBundleDecodeLane(),
    this.queueWait = const Duration(seconds: 5),
  }) : _lane = lane;

  final BundleDecodeLane _lane;

  final LinkedHashMap<BundleKey, BundleView> _full = LinkedHashMap();
  final LinkedHashMap<BundleKey, BundleView> _projections = LinkedHashMap();
  final Map<BundleKey, _BundleFlight> _flights = {};
  final List<_BundleFlight> _pending = [];
  int _fullBytes = 0;
  int _projectionBytes = 0;
  int _activeRequests = 0;
  int _activeBytes = 0;
  bool _pumpScheduled = false;
  bool _pumping = false;
  StoreGeneration? _seenGeneration;

  /// How long a foreground read over the queue limits waits for room before it
  /// fails as [BundleRetryable].
  final Duration queueWait;

  /// Retained full-bundle cache (estimated bytes, LRU).
  static const int cacheByteBudget = 12 * 1024 * 1024;

  /// Separate cache for projections.
  static const int projectionByteBudget = 2 * 1024 * 1024;

  /// An entry estimated above this is returned once and never cached.
  static const int oversizeBytes = 1024 * 1024;

  /// A decode chunk holds at most this much source text (one payload larger
  /// than this runs alone) ...
  static const int chunkSourceBytes = 256 * 1024;

  /// ... and at most this many payloads.
  static const int maxChunkRows = 8;

  /// Requests waiting for the single lane, and source text in flight plus
  /// queued, before a foreground read waits and a warm is refused.
  static const int maxQueuedRequests = 16;
  static const int maxSourceBytesInFlight = 4 * 1024 * 1024;

  static BundleStore _shared = BundleStore();

  /// The store every repository reader goes through.
  static BundleStore get shared => _shared;

  @visibleForTesting
  static int debugDecodeDispatches = 0;

  @visibleForTesting
  static void debugResetDecodeDispatches() => debugDecodeDispatches = 0;

  /// Decodes a non-revisioned small payload on the same worker entry. P2.3
  /// replaces these compatibility readers with keyed projections.
  Future<Map<String, dynamic>?> decodeStoredPayload(Object? value) async {
    if (value is! String || value.isEmpty) return null;
    debugDecodeDispatches++;
    final result = await _lane.decode(DecodeChunkInput(
      payloadJson: [value],
      projections: const ['legacy'],
    ));
    final graph = result.graphs.single;
    if (graph is! Map) return null;
    return _bundleCopy(graph) as Map<String, dynamic>;
  }

  /// Swap the shared store. Test seam; pair with [debugResetShared].
  @visibleForTesting
  static void debugUseShared(BundleStore store) => _shared = store;

  @visibleForTesting
  static void debugResetShared() => _shared = BundleStore();

  /// One attempt: meta first, then the cache, a joined flight, or a new decode.
  /// May answer [BundleStale] (a joiner of a rejected flight, or a completion
  /// the fence rejected). It never caches or returns a rejected decode.
  Future<BundleRead> readOnce(
    BundleSource source, {
    ProjectionId projection = ProjectionId.full,
  }) async {
    final prepared = await _prepare(source, projection);
    if (prepared == null) return const BundleAbsent();
    final hit = _get(prepared.key);
    if (hit != null) {
      return BundleOk(view: hit, key: prepared.key, asOfMs: prepared.asOfMs);
    }
    final existing = _flights[prepared.key];
    if (existing != null) {
      return _withFreshAsOf(existing.done.future, prepared.asOfMs);
    }
    final payload = await _readPayload(prepared);
    if (payload == null) return const BundleAbsent();
    await _awaitCapacity(payload, warm: false, source: source);
    final flight = _newFlight(prepared, payload, warm: false);
    return _withFreshAsOf(flight.done.future, prepared.asOfMs);
  }

  /// [readOnce], and when it answers [BundleStale] one more attempt that starts
  /// from the meta again. Throws [BundleRetryable] on a second stale.
  Future<BundleRead> read(
    BundleSource source, {
    ProjectionId projection = ProjectionId.full,
  }) async {
    final first = await readOnce(source, projection: projection);
    if (first is! BundleStale) return first;
    final second = await readOnce(source, projection: projection);
    if (second is BundleStale) throw BundleRetryable(source);
    return second;
  }

  /// [read] for a projection. A projection flight never answers a full read.
  Future<BundleRead> project(BundleSource source, ProjectionId projection) =>
      read(source, projection: projection);

  /// Several sources, decoded in chunks of at most [chunkRows] payloads (and the
  /// byte budget), in request order. Results are in the same order.
  Future<List<BundleRead>> readAll(
    List<BundleSource> sources, {
    ProjectionId projection = ProjectionId.full,
    int chunkRows = maxChunkRows,
  }) async {
    if (sources.isEmpty) return const [];
    final results = List<BundleRead?>.filled(sources.length, null);
    final prepared = <({int index, _Prepared source})>[];
    for (var i = 0; i < sources.length; i++) {
      final item = await _prepare(sources[i], projection);
      if (item == null) {
        results[i] = const BundleAbsent();
        continue;
      }
      final hit = _get(item.key);
      if (hit != null) {
        results[i] = BundleOk(view: hit, key: item.key, asOfMs: item.asOfMs);
      } else if (_flights[item.key] case final existing?) {
        results[i] = await _withFreshAsOf(existing.done.future, item.asOfMs);
      } else {
        prepared.add((index: i, source: item));
      }
    }
    final misses = <({int index, _Prepared source, String payload})>[];
    for (final p in prepared) {
      final payload = await _readPayload(p.source);
      if (payload == null) {
        results[p.index] = const BundleAbsent();
      } else {
        misses.add((index: p.index, source: p.source, payload: payload));
      }
    }
    final maxRows = chunkRows.clamp(1, maxChunkRows);
    var offset = 0;
    while (offset < misses.length) {
      final batch = <({int index, _Prepared source, String payload})>[];
      var bytes = 0;
      while (offset < misses.length && batch.length < maxRows) {
        final next = misses[offset];
        final nextBytes = next.payload.length;
        if (batch.isNotEmpty && bytes + nextBytes > chunkSourceBytes) break;
        batch.add(next);
        bytes += nextBytes;
        offset++;
      }
      final flights = <_BundleFlight>[];
      for (final item in batch) {
        final existing = _flights[item.source.key];
        if (existing != null) {
          results[item.index] = await _withFreshAsOf(existing.done.future, item.source.asOfMs);
        } else {
          flights.add(_newFlight(item.source, item.payload, warm: false, schedule: false));
        }
      }
      if (flights.isNotEmpty) {
        _schedulePump();
        for (final item in batch) {
          if (results[item.index] == null) {
            final f = _flights[item.source.key];
            if (f != null) results[item.index] = await _withFreshAsOf(f.done.future, item.source.asOfMs);
          }
        }
      }
    }
    for (var i = 0; i < results.length; i++) {
      if (results[i] is BundleStale) {
        results[i] = await read(sources[i], projection: projection);
      }
    }
    return [for (final result in results) result ?? const BundleAbsent()];
  }

  /// Fills the cache for [sources] at low priority. An absent source is
  /// skipped; a lane over its limits refuses the whole warm.
  Future<WarmResult> warm(Iterable<BundleSource> sources) async {
    final prepared = <_Prepared>[];
    for (final source in sources) {
      final p = await _prepare(source, ProjectionId.full);
      if (p == null || _get(p.key) != null || _flights.containsKey(p.key)) continue;
      prepared.add(p);
    }
    final payloads = <({_Prepared source, String payload})>[];
    for (final p in prepared) {
      final text = await _readPayload(p);
      if (text != null) payloads.add((source: p, payload: text));
    }
    final neededBytes = payloads.fold<int>(0, (n, p) => n + p.payload.length);
    if (_activeRequests + _pending.length + payloads.length > maxQueuedRequests + 1 ||
        _activeBytes + _pending.fold<int>(0, (n, f) => n + f.sourceBytes) + neededBytes > maxSourceBytesInFlight) {
      return const WarmRefusedBusy();
    }
    for (final p in payloads) {
      _newFlight(p.source, p.payload, warm: true, schedule: false);
    }
    if (payloads.isNotEmpty) _schedulePump();
    // Await the flights so callers can rely on the warm being complete.
    final fs = [for (final p in payloads) _flights[p.source.key]];
    var decoded = 0;
    for (final f in fs) {
      if (f == null) continue;
      final result = await f.done.future;
      if (result is BundleOk) decoded++;
    }
    return WarmDone(decoded);
  }

  /// Evict early. Correctness never depends on these being called.
  void invalidateDays(Iterable<String> days) {
    final set = days.toSet();
    _removeDayKeys(_full, set, full: true);
    _removeDayKeys(_projections, set, full: false);
    for (final key in _flights.keys.toList()) {
      if (key.kind == 'day_result' && set.contains(key.k1)) _flights.remove(key);
    }
    final retained = <_BundleFlight>[];
    for (final flight in _pending) {
      final key = flight.source.key;
      if (key.kind != 'day_result' || !set.contains(key.k1)) retained.add(flight);
    }
    _pending
      ..clear()
      ..addAll(retained);
  }
  void invalidateAll() {
    _full.clear();
    _projections.clear();
    _fullBytes = 0;
    _projectionBytes = 0;
    _flights.clear(); // detach: their own completion will fail its fence.
    _pending.clear();
  }

  /// Keys currently cached (full and projection caches), oldest first.
  @visibleForTesting
  List<BundleKey> get debugCachedKeys => [..._full.keys, ..._projections.keys];

  /// The cached views themselves, so a test can check that no cached node
  /// reaches a caller.
  @visibleForTesting
  Iterable<BundleView> get debugCachedViews => [..._full.values, ..._projections.values];

  /// Flights registered and not yet removed.
  @visibleForTesting
  int get debugFlightCount => _flights.length;

  /// Sum of `estimatedBytes` of the full cache.
  @visibleForTesting
  int get debugCacheBytes => _fullBytes;

  Future<_Prepared?> _prepare(BundleSource source, ProjectionId projection) async {
    Map<String, dynamic>? meta;
    if (source.kind == 'day_result') {
      meta = await LocalDb.dayResultMeta(source.k1);
    } else {
      final db = await LocalDb.instance;
      final rows = await db.rawQuery(
        "SELECT b.key, b.updated_at, COALESCE(v.rev, 0) AS rev "
        "FROM baselines b LEFT JOIN row_rev v ON v.kind = 'baselines' AND v.k1 = b.key AND v.k2 = 0 WHERE b.key = ?",
        [source.k1],
      );
      meta = rows.isEmpty ? null : rows.first;
    }
    if (meta == null) return null;
    final generation = LocalDb.storeGeneration;
    if (_seenGeneration != null && _seenGeneration != generation) invalidateAll();
    _seenGeneration = generation;
    final k2 = source.kind == 'day_result' ? (meta['algo_version'] as num).toInt() : 0;
    final rev = (meta['rev'] as num?)?.toInt() ?? 0;
    final asOf = (meta[source.kind == 'day_result' ? 'computed_at' : 'updated_at'] as num?)?.toInt();
    return _Prepared(
      source: source,
      generation: generation,
      key: BundleKey(generation: generation, kind: source.kind, k1: source.k1, k2: k2, rev: rev, projection: projection),
      asOfMs: asOf,
    );
  }

  Future<String?> _readPayload(_Prepared prepared) async {
    if (prepared.source.kind == 'day_result') {
      final result = await LocalDb.dayPayload(prepared.source.k1, prepared.key.k2, expectedRev: prepared.key.rev);
      return switch (result) {
        DayPayloadOk(:final payloadJson) => payloadJson,
        DayPayloadAbsent() || DayPayloadStale() => null,
      };
    }
    final db = await LocalDb.instance;
    final rows = await db.rawQuery(
      "SELECT b.payload_json, COALESCE(v.rev, 0) AS rev FROM baselines b "
      "LEFT JOIN row_rev v ON v.kind = 'baselines' AND v.k1 = b.key AND v.k2 = 0 WHERE b.key = ?",
      [prepared.source.k1],
    );
    if (rows.isEmpty || (rows.first['rev'] as num).toInt() != prepared.key.rev) return null;
    final value = rows.first['payload_json'];
    return value is String ? value : null;
  }

  BundleView? _get(BundleKey key) {
    final map = key.projection == ProjectionId.full ? _full : _projections;
    final view = map.remove(key);
    if (view != null) map[key] = view;
    return view;
  }

  _BundleFlight _newFlight(_Prepared source, String payload, {required bool warm, bool schedule = true}) {
    final flight = _BundleFlight(source, payload, warm);
    _flights[source.key] = flight;
    _pending.add(flight);
    if (schedule) _schedulePump();
    return flight;
  }

  Future<void> _awaitCapacity(String payload, {required bool warm, required BundleSource source}) async {
    final bytes = payload.length;
    bool available() => _activeRequests + _pending.length < maxQueuedRequests + 1 &&
        _activeBytes + _pending.fold<int>(0, (n, f) => n + f.sourceBytes) + bytes <= maxSourceBytesInFlight;
    if (available()) return;
    if (warm) throw BundleRetryable(source);
    final deadline = DateTime.now().add(queueWait);
    while (!available() && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    if (!available()) throw BundleRetryable(source);
  }

  void _schedulePump() {
    if (_pumpScheduled) return;
    _pumpScheduled = true;
    scheduleMicrotask(() {
      _pumpScheduled = false;
      unawaited(_pump());
    });
  }

  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (_pending.isNotEmpty) {
        _pending.sort((a, b) => (a.warm ? 1 : 0).compareTo(b.warm ? 1 : 0));
        final batch = <_BundleFlight>[];
        var sourceBytes = 0;
        final firstPriority = _pending.first.warm;
        while (_pending.isNotEmpty && batch.length < maxChunkRows && _pending.first.warm == firstPriority) {
          final next = _pending.first;
          final nextBytes = next.sourceBytes;
          if (batch.isNotEmpty && sourceBytes + nextBytes > chunkSourceBytes) break;
          if (_activeRequests + _pending.length > maxQueuedRequests + 1 ||
              _activeBytes + _pending.fold<int>(0, (n, f) => n + f.sourceBytes) > maxSourceBytesInFlight) {
            _pending.remove(next);
            if (identical(_flights[next.source.key], next)) _flights.remove(next.source.key);
            next.done.completeError(BundleRetryable(next.source.source));
            continue;
          }
          batch.add(_pending.removeAt(0));
          sourceBytes += nextBytes;
        }
        if (batch.isEmpty) continue;
        _activeRequests += batch.length;
        _activeBytes += sourceBytes;
        try {
          debugDecodeDispatches += batch.length;
          final decoded = await _lane.decode(DecodeChunkInput(
            payloadJson: [for (final f in batch) f.payload],
            projections: [for (final f in batch) f.source.key.projection.name],
          ));
          if (decoded.graphs.length != batch.length || decoded.estimatedBytes.length != batch.length) {
            throw StateError('BundleDecodeLane returned a malformed chunk');
          }
          for (var i = 0; i < batch.length; i++) {
            final f = batch[i];
            final isCurrent = identical(_flights[f.source.key], f) &&
                LocalDb.storeGeneration == f.source.generation &&
                await _revisionMatches(f.source);
            if (!isCurrent) {
              if (identical(_flights[f.source.key], f)) _flights.remove(f.source.key);
              f.done.complete(const BundleStale());
              continue;
            }
            final graph = decoded.graphs[i];
            if (graph == null) {
              if (identical(_flights[f.source.key], f)) _flights.remove(f.source.key);
              f.done.complete(const BundleAbsent(undecodable: true));
              continue;
            }
            final view = BundleView.frozen(graph, estimatedBytes: decoded.estimatedBytes[i]);
            if (view.estimatedBytes <= oversizeBytes) _put(f.source.key, view);
            if (identical(_flights[f.source.key], f)) _flights.remove(f.source.key);
            f.done.complete(BundleOk(view: view, key: f.source.key, asOfMs: f.source.asOfMs));
          }
        } catch (e, st) {
          for (final f in batch) {
            if (identical(_flights[f.source.key], f)) _flights.remove(f.source.key);
            if (!f.done.isCompleted) f.done.completeError(e, st);
          }
        } finally {
          _activeRequests -= batch.length;
          _activeBytes -= sourceBytes;
          for (final f in batch) {
            if (identical(_flights[f.source.key], f)) _flights.remove(f.source.key);
          }
        }
      }
    } finally {
      _pumping = false;
      if (_pending.isNotEmpty) _schedulePump();
    }
  }

  Future<bool> _revisionMatches(_Prepared p) async {
    final now = await _prepare(p.source, p.key.projection);
    return now != null && now.key == p.key;
  }

  void _put(BundleKey key, BundleView view) {
    final map = key.projection == ProjectionId.full ? _full : _projections;
    final budget = key.projection == ProjectionId.full ? cacheByteBudget : projectionByteBudget;
    final old = map.remove(key);
    if (old != null) {
      if (key.projection == ProjectionId.full) {
        _fullBytes -= old.estimatedBytes;
      } else {
        _projectionBytes -= old.estimatedBytes;
      }
    }
    map[key] = view;
    if (key.projection == ProjectionId.full) {
      _fullBytes += view.estimatedBytes;
    } else {
      _projectionBytes += view.estimatedBytes;
    }
    while ((key.projection == ProjectionId.full ? _fullBytes : _projectionBytes) > budget && map.isNotEmpty) {
      final evicted = map.remove(map.keys.first)!;
      if (key.projection == ProjectionId.full) {
        _fullBytes -= evicted.estimatedBytes;
      } else {
        _projectionBytes -= evicted.estimatedBytes;
      }
    }
  }

  void _removeDayKeys(
    LinkedHashMap<BundleKey, BundleView> map,
    Set<String> days, {
    required bool full,
  }) {
    for (final key in map.keys.toList()) {
      if (key.kind != 'day_result' || !days.contains(key.k1)) continue;
      final removed = map.remove(key)!;
      if (full) {
        _fullBytes -= removed.estimatedBytes;
      } else {
        _projectionBytes -= removed.estimatedBytes;
      }
    }
  }

  static Future<BundleRead> _withFreshAsOf(Future<BundleRead> future, int? asOf) async {
    final r = await future;
    if (r is BundleOk) return BundleOk(view: r.view, key: r.key, asOfMs: asOf);
    return r;
  }
}

final class _Prepared {
  const _Prepared({required this.source, required this.generation, required this.key, required this.asOfMs});
  final BundleSource source;
  final StoreGeneration generation;
  final BundleKey key;
  final int? asOfMs;
}

final class _BundleFlight {
  _BundleFlight(this.source, this.payload, this.warm);
  final _Prepared source;
  final String payload;
  final bool warm;
  final Completer<BundleRead> done = Completer<BundleRead>();
  int get sourceBytes => payload.length;
}
