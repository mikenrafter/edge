// bundle_store.dart — the one reader of stored `day_result` / `baselines`
// payloads on the UI side (design 02, step 2, P2.2; scope note sections 4.2-4.4).
//
// RED-PHASE STUB. Every operation throws [UnimplementedError]; the shapes are
// what test/step2/p22_*.dart is written against. Nothing in lib/ calls it yet.
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
import 'dart:isolate';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../util/heavy.dart';
import '../util/worker_audit.dart';
import '../util/worker_entries.dart' show Dispatcher;
import '../util/worker_init.dart';

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
  @visibleForTesting
  static int get debugCopiedNodes => throw UnimplementedError('P2.2');

  @visibleForTesting
  static void debugResetCopiedNodes() => throw UnimplementedError('P2.2');

  /// The cached root itself (deep-unmodifiable). Test seam: mutation must throw
  /// [UnsupportedError].
  @visibleForTesting
  Object? get debugFrozenRoot => _root;

  /// A deep copy of the subtree at dotted [path] (`'scalars'`,
  /// `'sleep.accounting.value'`). A path naming a curve (`series.hr_curve`,
  /// `activity_curve`) is expanded exactly as `SeriesCodec.decodePayload` does.
  /// Null when the path is absent.
  Object? owned(String path) => throw UnimplementedError('P2.2');

  /// The curve at [path] expanded by `SeriesCodec.decodeCurve` with the value
  /// key that `seriesCurves` / `rootCurves` gives it. A shape `decodeCurve`
  /// cannot expand comes back unchanged.
  Object? curve(String path) => throw UnimplementedError('P2.2');

  /// The whole bundle as `SeriesCodec.decodePayloadJson` would have returned
  /// it: every known curve expanded, owned by the caller.
  Map<String, dynamic> materialiseLegacy() => throw UnimplementedError('P2.2');
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
@SendableShape('frozen JSON graphs: Map, List, String, num, bool and null')
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

/// WORKER ENTRY (registered in kWorkerEntries, dispatched with `Isolate.run`):
/// parses each payload, builds the frozen compact graph or the requested
/// projection, and sizes it. Curves are NOT expanded here. RED STUB: the body
/// after the entry header throws.
@heavy
DecodedChunk decodeDayPayloadsHeavy(
  WorkerInputs inputs,
  DecodeChunkInput input,
) {
  WorkerInit.ensure(inputs);
  assertWorker();
  WorkerAudit.entered('decodeDayPayloadsHeavy');
  throw UnimplementedError('P2.2');
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

  // ignore: unused_field
  final BundleDecodeLane _lane;

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
  }) => throw UnimplementedError('P2.2');

  /// [readOnce], and when it answers [BundleStale] one more attempt that starts
  /// from the meta again. Throws [BundleRetryable] on a second stale.
  Future<BundleRead> read(
    BundleSource source, {
    ProjectionId projection = ProjectionId.full,
  }) => throw UnimplementedError('P2.2');

  /// [read] for a projection. A projection flight never answers a full read.
  Future<BundleRead> project(BundleSource source, ProjectionId projection) =>
      throw UnimplementedError('P2.2');

  /// Several sources, decoded in chunks of at most [chunkRows] payloads (and the
  /// byte budget), in request order. Results are in the same order.
  Future<List<BundleRead>> readAll(
    List<BundleSource> sources, {
    ProjectionId projection = ProjectionId.full,
    int chunkRows = maxChunkRows,
  }) => throw UnimplementedError('P2.2');

  /// Fills the cache for [sources] at low priority. An absent source is
  /// skipped; a lane over its limits refuses the whole warm.
  Future<WarmResult> warm(Iterable<BundleSource> sources) =>
      throw UnimplementedError('P2.2');

  /// Evict early. Correctness never depends on these being called.
  void invalidateDays(Iterable<String> days) =>
      throw UnimplementedError('P2.2');
  void invalidateAll() => throw UnimplementedError('P2.2');

  /// Keys currently cached (full and projection caches), oldest first.
  @visibleForTesting
  List<BundleKey> get debugCachedKeys => throw UnimplementedError('P2.2');

  /// The cached views themselves, so a test can check that no cached node
  /// reaches a caller.
  @visibleForTesting
  Iterable<BundleView> get debugCachedViews =>
      throw UnimplementedError('P2.2');

  /// Flights registered and not yet removed.
  @visibleForTesting
  int get debugFlightCount => throw UnimplementedError('P2.2');

  /// Sum of `estimatedBytes` of the full cache.
  @visibleForTesting
  int get debugCacheBytes => throw UnimplementedError('P2.2');
}
