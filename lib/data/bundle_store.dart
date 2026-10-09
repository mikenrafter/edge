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
import '../compute/derive_perf.dart' show payloadNodeCount, utf8Length;
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
  const BundleOk({
    required this.view,
    required this.key,
    required this.asOfMs,
    this.fromCache = false,
  });

  final BundleView view;
  final BundleKey key;

  /// True when the memo answered (no payload moved, nothing was decoded); false
  /// for a read that decoded or joined a decode in flight. Read-perf only.
  final bool fromCache;

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
  BundleView.frozen(
    this._root, {
    required this.estimatedBytes,
    this.nodes,
    this.sourceBytes,
  });

  final Object? _root;

  /// `64 + 24 x nodes + 2 x string characters`, computed in the worker.
  final int estimatedBytes;

  /// `payloadNodeCount` of the decoded graph and the UTF-8 length of the stored
  /// payload it came from, both counted in the worker. Null when the producer
  /// did not measure them (read-perf books nothing then, never a zero).
  final int? nodes;
  final int? sourceBytes;

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
    this.sourceBytes = const [],
  });

  /// The frozen compact graph, or null when the text is not a JSON object.
  final List<Object?> graphs;
  final List<int> estimatedBytes;

  /// Per graph: the nodes of the decoded graph plus one for the root reference
  /// that the cache estimate counts.
  final List<int> nodes;

  /// Per graph: the UTF-8 length of the stored text, measured here so the UI
  /// isolate never scans a payload for the read-perf counters. May be empty.
  final List<int> sourceBytes;
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
  final sourceBytes = <int>[];
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
      sourceBytes.add(0);
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
    sourceBytes.add(utf8Length(input.payloadJson[i]));
  }
  return DecodedChunk(
    graphs: graphs,
    estimatedBytes: bytes,
    nodes: nodes,
    sourceBytes: sourceBytes,
  );
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

/// The time the admission wait is measured against. An interface so a test can
/// move it by hand instead of waiting.
abstract interface class BundleClock {
  DateTime now();
}

final class SystemBundleClock implements BundleClock {
  const SystemBundleClock();
  @override
  DateTime now() => DateTime.now();
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
    BundleClock clock = const SystemBundleClock(),
  }) : _lane = lane,
       _clock = clock;

  final BundleDecodeLane _lane;
  final BundleClock _clock;

  final LinkedHashMap<BundleKey, BundleView> _full = LinkedHashMap();
  final LinkedHashMap<BundleKey, BundleView> _projections = LinkedHashMap();
  final Map<BundleKey, _BundleFlight> _flights = {};
  final List<_BundleFlight> _pending = [];
  int _fullBytes = 0;
  int _projectionBytes = 0;
  int _activeRequests = 0;
  int _activeBytes = 0;
  int _reservedRequests = 0;
  int _reservedBytes = 0;
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

  /// Test seam; null in production.
  @visibleForTesting
  BundleReadProbe? debugProbe;

  /// Payload texts handed out of the database by this store. A test compares it
  /// with the payloads the lane has received to bound what is held undecoded.
  @visibleForTesting
  int debugPayloadReads = 0;

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
  /// May answer [BundleStale] (a joiner of a rejected flight, a completion the
  /// fence rejected, or a row that changed between the meta and the payload
  /// read). It never caches or returns a rejected decode.
  Future<BundleRead> readOnce(
    BundleSource source, {
    ProjectionId projection = ProjectionId.full,
  }) async {
    final prepared = await _prepare(source, projection);
    if (prepared == null) return const BundleAbsent();
    final early = _cachedOrJoined(prepared);
    if (early != null) return early;
    var payload = await _readPayload(prepared);
    // A row that moved after the meta read is a changed row, not a missing one:
    // Stale sends the caller back to the meta, which answers an honest absence
    // if the row is really gone.
    if (payload.stale) return const BundleStale();
    if (payload.text == null) return const BundleAbsent();
    // Another reader may have cached or started this key while we awaited the
    // payload; a second flight under one key would overwrite the first and
    // make both completions look stale.
    final raced = _cachedOrJoined(prepared);
    if (raced != null) return raced;
    payload = await _admit(prepared, payload);
    try {
      if (payload.stale) return const BundleStale();
      final text = payload.text;
      if (text == null) return const BundleAbsent();
      final waited = _cachedOrJoined(prepared);
      if (waited != null) return waited;
      final flight = _newFlight(prepared, text, warm: false, reservation: payload.reservation);
      return _withFreshAsOf(flight.done.future, prepared.asOfMs);
    } finally {
      _release(payload.reservation); // no-op once the flight took it over
    }
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
  ///
  /// Payload text is fetched one chunk at a time, through the same admission as
  /// [readOnce], and released when the chunk completes: a 120-day walk never
  /// holds 120 source strings.
  Future<List<BundleRead>> readAll(
    List<BundleSource> sources, {
    ProjectionId projection = ProjectionId.full,
    int chunkRows = maxChunkRows,
  }) async {
    if (sources.isEmpty) return const [];
    final results = List<BundleRead?>.filled(sources.length, null);
    final prepared = <({int index, _Prepared source})>[];
    // Flights other readers started: held by handle, awaited at the end, so
    // waiting on one never delays starting the rest. An error is kept as a
    // value until then (nothing listens to the future in between).
    final joined = <int, Future<Object>>{};
    for (var i = 0; i < sources.length; i++) {
      final item = await _prepare(sources[i], projection);
      if (item == null) {
        results[i] = const BundleAbsent();
        continue;
      }
      final early = _cachedOrJoined(item);
      if (early != null) {
        joined[i] = early.then<Object>((r) => r, onError: (Object e, StackTrace st) => (e, st));
      } else {
        prepared.add((index: i, source: item));
      }
    }
    final maxRows = chunkRows.clamp(1, maxChunkRows);
    var next = 0;
    _ReadItem? carry;
    try {
      while (carry != null || next < prepared.length) {
        final batch = <_ReadItem>[];
        var bytes = 0;
        ({int index, _Prepared source, _PayloadRead read})? boundary;
        try {
          while (batch.length < maxRows) {
            var item = carry;
            carry = null;
            if (item == null) {
              if (next >= prepared.length) break;
              final p = prepared[next++];
              final read = await _readPayload(p.source);
              if (read.stale) {
                results[p.index] = const BundleStale();
                continue;
              }
              final text = read.text;
              if (text == null) {
                results[p.index] = const BundleAbsent();
                continue;
              }
              // A walk never waits for admission while it holds reservations it
              // has not queued: another walk may hold the rest of the slots in
              // the same state and nothing would free one. So a payload that
              // does not fit this chunk, or finds no room right now, is handled
              // after the chunk is queued (see [boundary] below).
              if (batch.isNotEmpty) {
                final reservation = bytes + text.length > chunkSourceBytes
                    ? null
                    : _tryReserve(text.length);
                if (reservation == null) {
                  boundary = (index: p.index, source: p.source, read: read);
                  break;
                }
                read.reservation = reservation;
                batch.add((index: p.index, source: p.source, read: read));
                bytes += text.length;
                continue;
              }
              final admitted = await _admit(p.source, read);
              if (admitted.stale || admitted.text == null) {
                _release(admitted.reservation);
                results[p.index] = admitted.stale ? const BundleStale() : const BundleAbsent();
                continue;
              }
              item = (index: p.index, source: p.source, read: admitted);
            }
            batch.add(item);
            bytes += item.read.text!.length;
          }
          // Every member's flight (or cache entry) is captured BEFORE anything
          // is awaited: a publish that clears the flight table mid-batch must
          // not make a later member look up a flight that is no longer there.
          final waits = <int, Future<BundleRead>>{};
          var started = false;
          for (final item in batch) {
            final early = _cachedOrJoined(item.source);
            if (early != null) {
              _release(item.read.reservation);
              waits[item.index] = early;
              continue;
            }
            final flight = _newFlight(
              item.source,
              item.read.text!,
              warm: false,
              schedule: false,
              reservation: item.read.reservation,
            );
            started = true;
            waits[item.index] = _withFreshAsOf(flight.done.future, item.source.asOfMs);
          }
          if (started) _schedulePump();
          // Errors are kept as values: the carry's admission below may throw
          // while these are still running.
          final settled = Future.wait(waits.values).then<Object>(
            (r) => r,
            onError: (Object e, StackTrace st) => (e, st),
          );
          if (boundary != null) {
            // The payload that did not fit this chunk is admitted now, behind
            // the chunk just queued (which makes progress while it waits for
            // room), and carried with its reservation into the next chunk.
            final b = boundary;
            final admitted = await _admit(b.source, b.read);
            if (admitted.stale || admitted.text == null) {
              _release(admitted.reservation);
              results[b.index] = admitted.stale ? const BundleStale() : const BundleAbsent();
            } else {
              carry = (index: b.index, source: b.source, read: admitted);
            }
          }
          final answers = await settled;
          if (answers is (Object, StackTrace)) {
            Error.throwWithStackTrace(answers.$1, answers.$2);
          }
          var k = 0;
          for (final index in waits.keys) {
            results[index] = (answers as List<BundleRead>)[k++];
          }
        } finally {
          for (final item in batch) {
            _release(item.read.reservation); // no-op for queued members
          }
        }
      }
    } finally {
      _release(carry?.read.reservation);
    }
    for (final entry in joined.entries) {
      final answer = await entry.value;
      if (answer is (Object, StackTrace)) {
        Error.throwWithStackTrace(answer.$1, answer.$2);
      }
      results[entry.key] = answer as BundleRead;
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
      final text = (await _readPayload(p)).text;
      if (text != null) payloads.add((source: p, payload: text));
    }
    final neededBytes = payloads.fold<int>(0, (n, p) => n + p.payload.length);
    if (_activeRequests + _pending.length + _reservedRequests + payloads.length > maxQueuedRequests + 1 ||
        _heldBytes + neededBytes > maxSourceBytesInFlight) {
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
    _dropPending((flight) {
      final key = flight.source.key;
      return key.kind == 'day_result' && set.contains(key.k1);
    });
  }

  void invalidateAll() {
    _full.clear();
    _projections.clear();
    _fullBytes = 0;
    _projectionBytes = 0;
    _flights.clear(); // detach: their own completion will fail its fence.
    _dropPending((_) => true);
  }

  /// Removes queued flights and answers each with [BundleStale]: a reader that
  /// joined one is waiting on its `done`, and a flight that never reaches the
  /// lane would leave it waiting forever. Stale sends the reader back to the
  /// meta, so it decodes the current revision.
  void _dropPending(bool Function(_BundleFlight flight) test) {
    final dropped = _pending.where(test).toList();
    _pending.removeWhere(test);
    for (final flight in dropped) {
      if (!flight.done.isCompleted) flight.done.complete(const BundleStale());
    }
  }

  /// Keys currently cached (full and projection caches), oldest first.
  @visibleForTesting
  List<BundleKey> get debugCachedKeys => [..._full.keys, ..._projections.keys];

  /// The cached views themselves, so a test can check that no cached node
  /// reaches a caller.
  @visibleForTesting
  Iterable<BundleView> get debugCachedViews => [..._full.values, ..._projections.values];

  /// Admitted-but-not-yet-queued requests and source bytes.
  @visibleForTesting
  int get debugReservedRequests => _reservedRequests;
  @visibleForTesting
  int get debugReservedBytes => _reservedBytes;

  /// Source bytes counted against the budget: running, queued and reserved.
  @visibleForTesting
  int get debugSourceBytesHeld => _heldBytes;

  int get _heldBytes =>
      _activeBytes + _pending.fold<int>(0, (n, f) => n + f.sourceBytes) + _reservedBytes;

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

  /// The payload text for [prepared], fenced on its revision. Stale when the
  /// row changed or vanished since the meta read (a replace, a delete, a newer
  /// served version); [_PayloadRead.text] is null only for a payload that is not
  /// text.
  Future<_PayloadRead> _readPayload(_Prepared prepared) async {
    await debugProbe?.afterMeta(prepared.source);
    if (prepared.source.kind == 'day_result') {
      final result = await LocalDb.dayPayload(prepared.source.k1, prepared.key.k2, expectedRev: prepared.key.rev);
      return switch (result) {
        DayPayloadOk(:final payloadJson) => _counted(payloadJson),
        DayPayloadAbsent() || DayPayloadStale() => _PayloadRead.stale(),
      };
    }
    final db = await LocalDb.instance;
    final rows = await db.rawQuery(
      "SELECT b.payload_json, COALESCE(v.rev, 0) AS rev FROM baselines b "
      "LEFT JOIN row_rev v ON v.kind = 'baselines' AND v.k1 = b.key AND v.k2 = 0 WHERE b.key = ?",
      [prepared.source.k1],
    );
    if (rows.isEmpty || (rows.first['rev'] as num).toInt() != prepared.key.rev) {
      return _PayloadRead.stale();
    }
    final value = rows.first['payload_json'];
    return _counted(value is String ? value : null);
  }

  _PayloadRead _counted(String? text) {
    if (text != null) debugPayloadReads++;
    return _PayloadRead(text);
  }

  /// A cache hit, or the done-future of a flight already running for the key.
  /// Null when this reader has to start the decode.
  Future<BundleRead>? _cachedOrJoined(_Prepared prepared) {
    final hit = _get(prepared.key);
    if (hit != null) {
      return Future.value(BundleOk(view: hit, key: prepared.key, asOfMs: prepared.asOfMs, fromCache: true));
    }
    final existing = _flights[prepared.key];
    if (existing != null) return _withFreshAsOf(existing.done.future, prepared.asOfMs);
    return null;
  }

  BundleView? _get(BundleKey key) {
    final map = key.projection == ProjectionId.full ? _full : _projections;
    final view = map.remove(key);
    if (view != null) map[key] = view;
    return view;
  }

  /// Registers and queues a flight. A [reservation] taken at admission turns
  /// into this queue entry in the same synchronous step, so the bytes are never
  /// counted twice or not at all.
  _BundleFlight _newFlight(
    _Prepared source,
    String payload, {
    required bool warm,
    bool schedule = true,
    _Reservation? reservation,
  }) {
    final flight = _BundleFlight(source, payload, warm);
    _flights[source.key] = flight;
    _pending.add(flight);
    _release(reservation);
    if (schedule) _schedulePump();
    return flight;
  }

  bool _fits(int bytes) =>
      _activeRequests + _pending.length + _reservedRequests < maxQueuedRequests + 1 &&
      _heldBytes + bytes <= maxSourceBytesInFlight;

  /// Admission is a reservation: the capacity check and the claim are one
  /// synchronous step, so nothing can take the room in between. The claim is
  /// released by [_newFlight] (it becomes the queue entry) or [_release].
  _Reservation? _tryReserve(int bytes) {
    if (!_fits(bytes)) return null;
    _reservedRequests++;
    _reservedBytes += bytes;
    return _Reservation(bytes);
  }

  void _release(_Reservation? r) {
    if (r == null || !r.held) return;
    r.held = false;
    _reservedRequests--;
    _reservedBytes -= r.bytes;
  }

  /// Reserves room for [read]'s text, waiting up to [queueWait] for it. The text
  /// is NOT held while waiting: it is dropped and read again once the size is
  /// known to fit, so waiting readers do not pile up unbudgeted source strings.
  /// Throws [BundleRetryable] when no room appears. Returns the read of the
  /// final attempt (stale if the row moved meanwhile) with its reservation.
  Future<_PayloadRead> _admit(_Prepared prepared, _PayloadRead read) async {
    final deadline = _clock.now().add(queueWait);
    while (true) {
      final text = read.text;
      if (text == null) return read;
      final reservation = _tryReserve(text.length);
      if (reservation != null) {
        read.reservation = reservation;
        return read;
      }
      final length = text.length;
      read.text = null;
      while (!_fits(length) && _clock.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      if (!_fits(length)) throw BundleRetryable(prepared.source);
      read = await _readPayload(prepared);
    }
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
          // No capacity check here: every queued flight was admitted by a
          // reservation (or the warm check), so none is rejected after the fact.
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
            final view = BundleView.frozen(
              graph,
              estimatedBytes: decoded.estimatedBytes[i],
              // The worker's count includes the root reference of the cache
              // estimate; the read-perf node count is the graph's own.
              nodes: decoded.nodes[i] - 1,
              sourceBytes: i < decoded.sourceBytes.length ? decoded.sourceBytes[i] : null,
            );
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
    if (r is BundleOk) return BundleOk(view: r.view, key: r.key, asOfMs: asOf, fromCache: r.fromCache);
    return r;
  }
}

/// Outcome of fetching a payload text: the text, a stale marker, or neither
/// (a stored payload that is not text).
final class _PayloadRead {
  _PayloadRead(this.text) : stale = false;
  _PayloadRead.stale() : text = null, stale = true;

  /// Dropped (set null) while the owner waits for room, see [BundleStore._admit].
  String? text;
  final bool stale;
  _Reservation? reservation;
}

/// Source bytes claimed at admission, until the flight is queued.
final class _Reservation {
  _Reservation(this.bytes);
  final int bytes;
  bool held = true;
}

typedef _ReadItem = ({int index, _Prepared source, _PayloadRead read});

/// Test seam, an interface and not a function field so the heavy-calc guard
/// resolves the call: runs between the meta read and the payload read of one
/// attempt, where a writer can commit.
abstract interface class BundleReadProbe {
  Future<void> afterMeta(BundleSource source);
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
