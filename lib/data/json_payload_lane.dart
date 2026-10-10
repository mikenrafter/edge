// json_payload_lane.dart — generic stored JSON decoding and artifact encoding.
import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../util/heavy.dart';
import '../util/worker_audit.dart';
import '../util/worker_entries.dart' show Dispatcher;
import '../util/worker_init.dart' show WorkerInit, WorkerInputs, assertWorker;
import 'bundle_store.dart' show StoreGeneration, bundleWorkerInputs;
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
  const JsonPayloadsResult(this.values);

  final List<Object?> values;
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
  return JsonPayloadsResult([
    for (final value in input.values)
      if (input.encode) _encodeJsonValue(value) else _decodeJsonValue(value),
  ]);
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

/// A revision-fenced cache for small JSON rows and a worker call for cold data.
/// Bundle payloads remain owned by [BundleStore].
class JsonPayloadLane {
  JsonPayloadLane({JsonPayloadDecodeLane lane = const IsolateJsonPayloadLane()})
    : _lane = lane;

  static final JsonPayloadLane shared = JsonPayloadLane();

  final JsonPayloadDecodeLane _lane;
  final Map<({StoreGeneration generation, String key, int revision}), Object?>
      _cache = {};

  Future<Object?> decode(
    String key,
    int? revision,
    Object? text, {
    bool cache = true,
  }) async {
    final generation = LocalDb.storeGeneration;
    final cacheKey = revision == null
        ? null
        : (generation: generation, key: key, revision: revision);
    final hit = !cache || cacheKey == null ? null : _cache[cacheKey];
    if (cache && cacheKey != null && _cache.containsKey(cacheKey)) return hit;

    final result = await _lane.run(JsonPayloadsInput(values: [text], encode: false));
    final value = result.values.single;
    if (cache && cacheKey != null && text is String) {
      _cache[cacheKey] = value;
      _trimCache();
    }
    return value;
  }

  Future<List<Object?>> decodeMany(
    List<({String key, int? revision, Object? text})> rows, {
    bool cache = true,
  }) async {
    final values = List<Object?>.filled(rows.length, null);
    final misses = <int>[];
    final generation = LocalDb.storeGeneration;
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      final cacheKey = row.revision == null
          ? null
          : (generation: generation, key: row.key, revision: row.revision!);
      if (cache && cacheKey != null && _cache.containsKey(cacheKey)) {
        values[i] = _cache[cacheKey];
      } else {
        misses.add(i);
      }
    }

    for (var start = 0; start < misses.length; start += 8) {
      final part = misses.skip(start).take(8).toList();
      final decoded = await _lane.run(JsonPayloadsInput(
        values: [for (final i in part) rows[i].text],
        encode: false,
      ));
      for (var j = 0; j < part.length; j++) {
        final i = part[j];
        final row = rows[i];
        final value = decoded.values[j];
        values[i] = value;
        final revision = row.revision;
        if (cache && revision != null && row.text is String) {
          _cache[(generation: generation, key: row.key, revision: revision)] = value;
        }
      }
    }
    _trimCache();
    return values;
  }

  Future<String?> encode(Object? value) async {
    final result = await _lane.run(
      JsonPayloadsInput(values: [value], encode: true),
    );
    return result.values.single as String?;
  }

  Future<void> warm(List<({String key, int? revision, Object? text})> rows) async {
    await decodeMany(rows);
  }

  void _trimCache() {
    while (_cache.length > 256) {
      _cache.remove(_cache.keys.first);
    }
  }

  @visibleForTesting
  void clear() => _cache.clear();
}
