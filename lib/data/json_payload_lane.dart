// json_payload_lane.dart — generic stored JSON decoding and artifact encoding.
import 'dart:collection';
import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../util/heavy.dart';
import '../util/worker_audit.dart';
import '../util/worker_entries.dart' show Dispatcher;
import '../util/worker_init.dart' show WorkerInit, WorkerInputs, assertWorker;
import 'bundle_store.dart' show BundleStore, StoreGeneration, bundleWorkerInputs;
import 'db.dart';

/// Values accepted by JSON encode are arbitrary JSON-shaped Dart objects, so
/// the argument owns one explicit sendability round-trip contract.
@SendableShape('JSON values')
class JsonPayloadsInput {
  const JsonPayloadsInput({required this.values, required this.encode});

  final List<Object?> values;
  final bool encode;
}

/// JSON graphs cross back as values; the sendability test pins this boundary.
@SendableShape('JSON values')
class JsonPayloadsResult {
  const JsonPayloadsResult(this.values, [this.sizes = const []]);

  final List<Object?> values;

  /// Per decoded value: `64 + 24 x nodes + 2 x string characters`, the same
  /// estimate [DecodedChunk] uses, counted here so the UI isolate never walks
  /// a decoded graph to size it. Empty for an encode.
  final List<int> sizes;
}

/// WORKER ENTRY: generic JSON parse/stringify for stored payload readers.
@heavy
JsonPayloadsResult decodeJsonPayloadsHeavy(
  WorkerInputs inputs,
  JsonPayloadsInput input,
) {
  WorkerInit.ensure(inputs);
  assertWorker();
  WorkerAudit.entered('decodeJsonPayloadsHeavy');
  final values = <Object?>[
    for (final value in input.values)
      if (input.encode) _encodeJsonValue(value) else _decodeJsonValue(value),
  ];
  return JsonPayloadsResult(values, [
    if (!input.encode)
      for (final value in values) _estimatedBytes(value),
  ]);
}

int _estimatedBytes(Object? value) {
  var nodes = 1;
  var chars = 0;
  void walk(Object? v) {
    if (v is String) {
      chars += v.length;
    } else if (v is Map) {
      for (final e in v.entries) {
        nodes++;
        chars += '${e.key}'.length;
        walk(e.value);
      }
    } else if (v is List) {
      for (final item in v) {
        nodes++;
        walk(item);
      }
    }
  }

  walk(value);
  return 64 + 24 * nodes + 2 * chars;
}

Object? _decodeJsonValue(Object? value) {
  if (value is! String) return null;
  try {
    return jsonDecode(value);
  } catch (_) {
    return null;
  }
}

Object? _encodeJsonValue(Object? value) {
  try {
    return jsonEncode(value);
  } catch (_) {
    return null;
  }
}

/// Where generic JSON values are decoded or encoded. The named method keeps
/// this boundary visible to the heavy-calc guard and replaceable in tests.
abstract interface class JsonPayloadDecodeLane {
  Future<JsonPayloadsResult> run(JsonPayloadsInput input);
}

/// The production lane: `Isolate.run(decodeJsonPayloadsHeavy)`.
final class IsolateJsonPayloadLane implements JsonPayloadDecodeLane {
  const IsolateJsonPayloadLane();

  @override
  Future<JsonPayloadsResult> run(JsonPayloadsInput input) {
    final dispatchId = WorkerAudit.dispatched(
      Dispatcher.run,
      'generic JSON payload lane',
    );
    final auditPort = WorkerAudit.auditPort;
    return Isolate.run(() {
      WorkerAudit.adopt(auditPort, dispatchId);
      return decodeJsonPayloadsHeavy(bundleWorkerInputs, input);
    });
  }
}

/// A stored row as the lane sees it: the revision it was read at (null when the
/// table has none, which also means "never cached"), its JSON text, and an
/// opaque [tag] the source carries along (a `last_result` row's input
/// signature) so the caller gets the metadata of the row that was ACTUALLY
/// decoded, not of the one it first read.
final class JsonRowState {
  const JsonRowState({required this.revision, required this.text, this.tag});
  final int? revision;
  final Object? text;
  final Object? tag;
}

/// Where a decoded row came from. [key] is its cache identity (the superseded
/// revision of one key is replaced, never kept next to the new one); [current]
/// reads the row NOW, null when it is gone. The lane calls it after a worker
/// decode, before anything is cached or returned.
abstract interface class JsonRowSource {
  String get key;
  Future<JsonRowState?> current();
}

/// One `day_result.window_json` (the sleep window of a served, not skipped day).
final class SleepWindowRowSource implements JsonRowSource {
  const SleepWindowRowSource(this.day);
  final String day;

  @override
  String get key => 'window|$day';

  @override
  Future<JsonRowState?> current() async {
    final row = await LocalDb.sleepWindowRow(day);
    return row == null ? null : stateOf(row);
  }

  static JsonRowState stateOf(Map<String, dynamic> row) => JsonRowState(
    revision: (row['rev'] as num?)?.toInt(),
    text: row['window_json'],
  );
}

/// One served `wake_day_features` row of [day] at [algoVersion].
final class WakeFeaturesRowSource implements JsonRowSource {
  const WakeFeaturesRowSource(this.day, this.algoVersion);
  final String day;
  final Object? algoVersion;

  @override
  String get key => 'wake|$day|$algoVersion';

  @override
  Future<JsonRowState?> current() async {
    final row = await LocalDb.wakeDayFeatures(day, (algoVersion as num?)?.toInt());
    return row == null ? null : stateOf(row);
  }

  static JsonRowState stateOf(Map<String, dynamic> row) => JsonRowState(
    revision: (row['rev'] as num?)?.toInt(),
    text: row['payload_json'],
  );
}

/// One `last_result` row. [key] is the lane's cache identity and [tableKey] the
/// row's key in the table (they differ for the calorie curve).
final class LastResultRowSource implements JsonRowSource {
  const LastResultRowSource(this.key, this.tableKey);
  @override
  final String key;
  final String tableKey;

  @override
  Future<JsonRowState?> current() async {
    final row = await LocalDb.lastResult(tableKey);
    return row == null ? null : stateOf(row);
  }

  /// The row's `computed_at` stands in for a revision (the table has none).
  static JsonRowState stateOf(({int computedAt, String payload, String? sig}) row) =>
      JsonRowState(revision: row.computedAt, text: row.payload, tag: row.sig);
}

/// A decoded row and the state it was decoded from.
final class JsonDecoded {
  const JsonDecoded(this.value, this.state);
  final Object? value;
  final JsonRowState state;
}

typedef JsonLaneRow = ({JsonRowSource source, JsonRowState state});

class _CacheEntry {
  _CacheEntry(this.generation, this.revision, this.value, this.bytes);
  final StoreGeneration generation;
  final int revision;
  final Object? value;
  final int bytes;
}

/// A revision-fenced cache for small JSON rows and a worker call for cold data.
/// Bundle payloads remain owned by [BundleStore].
///
/// FENCED after the worker: a decode is published (cached or returned) only
/// when the store generation is unchanged and the row, read again, still has
/// the revision that was decoded. A row that moved is decoded once more from
/// what is there now; a row that moved again, or is gone, or a store that was
/// wiped, answers absence (null), never the old value.
///
/// BOUNDED: one entry per key (a new revision replaces the old one), entries of
/// an older generation are dropped, a decoded value over [oversizeBytes] is
/// returned but not kept, and the retained estimate stays under
/// [retainedByteBudget]. A decode chunk holds at most [maxChunkRows] rows and
/// [BundleStore.chunkSourceBytes] of source text (one larger row runs alone).
class JsonPayloadLane {
  JsonPayloadLane({JsonPayloadDecodeLane lane = const IsolateJsonPayloadLane()})
    : _lane = lane;

  static JsonPayloadLane _shared = JsonPayloadLane();
  static JsonPayloadLane get shared => _shared;

  @visibleForTesting
  static void debugUseShared(JsonPayloadLane lane) => _shared = lane;

  @visibleForTesting
  static void debugResetShared() => _shared = JsonPayloadLane();

  static const int maxEntries = 256;
  static const int maxChunkRows = 8;
  static const int retainedByteBudget = 2 * 1024 * 1024;
  static const int oversizeBytes = 512 * 1024;

  final JsonPayloadDecodeLane _lane;
  // Insertion order is recency order: the first key is the least recent.
  final LinkedHashMap<String, _CacheEntry> _cache = LinkedHashMap();
  int _cacheBytes = 0;

  Future<JsonDecoded?> decode(
    JsonRowSource source,
    JsonRowState state, {
    bool cache = true,
  }) async => (await decodeMany([(source: source, state: state)], cache: cache)).single;

  /// One result per row, in order; null is absence (see the class comment).
  Future<List<JsonDecoded?>> decodeMany(
    List<JsonLaneRow> rows, {
    bool cache = true,
  }) async {
    final out = List<JsonDecoded?>.filled(rows.length, null);
    final generation = LocalDb.storeGeneration;
    // A store replaced at ANY point makes the whole answer absence: nothing
    // decoded or cached before it may be shown (deleted data never returns).
    List<JsonDecoded?> absent() {
      _dropOtherGenerations(LocalDb.storeGeneration); // what chunk 1 cached
      return List<JsonDecoded?>.filled(rows.length, null);
    }
    _dropOtherGenerations(generation);
    // The state each row is being decoded from; replaced once if its row moved.
    final states = [for (final row in rows) row.state];
    var pending = <int>[];
    for (var i = 0; i < rows.length; i++) {
      final hit = cache ? _hit(rows[i].source.key, generation, states[i].revision) : null;
      if (hit != null) {
        out[i] = JsonDecoded(hit.value, states[i]);
      } else {
        pending.add(i);
      }
    }
    if (pending.isEmpty) return out;

    // Rows verified against storage by the most recent await. Everything else in
    // [out] (cache hits, earlier chunks) is re-read once more before returning.
    var verified = <int>{};
    for (var attempt = 0; attempt < 2 && pending.isNotEmpty; attempt++) {
      final moved = <int>[];
      for (final chunk in _chunks(pending, states)) {
        final decoded = await _lane.run(JsonPayloadsInput(
          values: [for (final i in chunk) states[i].text],
          encode: false,
        ));
        if (LocalDb.storeGeneration != generation) return absent();
        final now = await Future.wait([
          for (final i in chunk) rows[i].source.current(),
        ]);
        // Nothing is awaited between here and the publish below.
        if (LocalDb.storeGeneration != generation) return absent();
        verified = {};
        for (var j = 0; j < chunk.length; j++) {
          final i = chunk[j];
          final current = now[j];
          if (current == null) continue; // deleted: absence
          if (!_sameRow(states[i], current)) {
            states[i] = current; // changed: decode what is there now, once
            moved.add(i);
            continue;
          }
          final value = decoded.values[j];
          out[i] = JsonDecoded(value, states[i]);
          verified.add(i);
          final size = j < decoded.sizes.length ? decoded.sizes[j] : null;
          final revision = states[i].revision;
          if (cache && revision != null && states[i].text is String && size != null) {
            _publish(rows[i].source.key, generation, revision, value, size);
          }
        }
      }
      pending = attempt == 0 ? moved : const [];
    }

    // The entries not verified by the last await were verified before awaits
    // that came after them: check them again against storage.
    final stale = [
      for (var i = 0; i < rows.length; i++)
        if (out[i] != null && !verified.contains(i)) i,
    ];
    if (stale.isNotEmpty) {
      final now = await Future.wait([for (final i in stale) rows[i].source.current()]);
      if (LocalDb.storeGeneration != generation) return absent();
      for (var j = 0; j < stale.length; j++) {
        final current = now[j];
        if (current == null || !_sameRow(out[stale[j]]!.state, current)) {
          out[stale[j]] = null; // gone or moved since it was decoded: absence
        }
      }
    }
    return out;
  }

  /// Whether [now] is the row that was decoded from [then]. A row with no
  /// revision (rows written before `row_rev` existed are not backfilled) is
  /// compared by its stored text; gaining or losing a revision is a change.
  static bool _sameRow(JsonRowState then, JsonRowState now) {
    if (then.revision != null || now.revision != null) {
      return then.revision == now.revision;
    }
    return then.text == now.text;
  }

  /// Chunks of at most [maxChunkRows] rows and [BundleStore.chunkSourceBytes] of
  /// text; a row over the byte limit is a chunk of its own.
  Iterable<List<int>> _chunks(List<int> indexes, List<JsonRowState> states) sync* {
    var chunk = <int>[];
    var bytes = 0;
    for (final i in indexes) {
      final text = states[i].text;
      final length = text is String ? text.length : 0;
      if (chunk.isNotEmpty &&
          (chunk.length >= maxChunkRows ||
              bytes + length > BundleStore.chunkSourceBytes)) {
        yield chunk;
        chunk = <int>[];
        bytes = 0;
      }
      chunk.add(i);
      bytes += length;
    }
    if (chunk.isNotEmpty) yield chunk;
  }

  _CacheEntry? _hit(String key, StoreGeneration generation, int? revision) {
    final entry = _cache[key];
    if (entry == null || revision == null) return null;
    if (entry.generation != generation || entry.revision != revision) return null;
    _cache.remove(key);
    _cache[key] = entry; // most recent
    return entry;
  }

  void _publish(String key, StoreGeneration generation, int revision, Object? value, int bytes) {
    _remove(key); // a new revision replaces the superseded one
    if (bytes > oversizeBytes) return;
    _cache[key] = _CacheEntry(generation, revision, value, bytes);
    _cacheBytes += bytes;
    while ((_cache.length > maxEntries || _cacheBytes > retainedByteBudget) &&
        _cache.isNotEmpty) {
      _remove(_cache.keys.first);
    }
  }

  void _remove(String key) {
    final old = _cache.remove(key);
    if (old != null) _cacheBytes -= old.bytes;
  }

  void _dropOtherGenerations(StoreGeneration generation) {
    for (final key in _cache.keys.toList()) {
      if (_cache[key]!.generation != generation) _remove(key);
    }
  }

  Future<String?> encode(Object? value) async {
    final result = await _lane.run(
      JsonPayloadsInput(values: [value], encode: true),
    );
    return result.values.single as String?;
  }

  Future<void> warm(List<JsonLaneRow> rows) async {
    await decodeMany(rows);
  }

  /// Entries and estimated bytes retained (test readout).
  @visibleForTesting
  int get debugEntries => _cache.length;
  @visibleForTesting
  int get debugRetainedBytes => _cacheBytes;

  @visibleForTesting
  void clear() {
    _cache.clear();
    _cacheBytes = 0;
  }
}
