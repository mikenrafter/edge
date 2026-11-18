// Owns pure field projection and verified archive decoding. SQL/file lifetimes
// belong to mapper.dart. CLAIM(official-export-no-fork-results) [spec §4.3].
import 'dart:convert';
import 'dart:isolate';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'profile_target.dart';
import 'dart:typed_data';
import '../../util/heavy.dart';
import '../../util/raw_readers.dart';
import '../hyrox_plan.dart';
import '../triathlon_plan.dart';
import '../../util/worker_init.dart';
import '../../util/worker_audit.dart';
import '../raw_archive_row.dart';
import '../substrate_archive_codec.dart';
import 'profile_tables.dart';

const mappingWorkerInputs = WorkerInputs(nowEpochMs: 0, zoneId: 'explicit-caller-calendar', localeTag: 'en');

// UTF-8 hex with a separator is injective in the pair (original key, unit).
// Existing qualified keys are also encoded: arbitrary original keys cannot
// collide with another original's encoded spelling. [mapper_test]
String qualifiedCustomKey(String key, String unit) {
  if (!key.startsWith('custom_') || unit.isEmpty) { return key; }
  String hex(String s) => utf8.encode(s).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return 'custom_u1_${hex(key)}_${hex(unit)}';
}

@SendableShape('SQLite row maps, exact archive bytes and manifest JSON')
class MappingInput {
  const MappingInput(this.operation, this.table, this.rows, {this.blob, this.codec = 1, this.fingerprint, this.json, this.batch});
  final String operation, table;
  final List<Map<String, Object?>> rows;
  final Uint8List? blob;
  final int codec;
  final int? fingerprint;
  final Object? json;
  final RowBatch<Map<String,Object?>>? batch;
}

@SendableShape('Projected SQLite rows, archive rows and explicit omissions')
class MappingOutput {
  const MappingOutput(this.rows, this.notes, {this.text});
  final List<Map<String, Object?>> rows;
  final List<Map<String, Object?>> notes;
  final String? text;
}

Future<MappingOutput> runMappingWorker(MappingInput input) =>
    Isolate.run(() => officialMappingHeavy(mappingWorkerInputs, input));

@heavy
Future<MappingOutput> officialMappingHeavy(WorkerInputs inputs, MappingInput input) async {
  WorkerInit.ensure(inputs);
  assertWorker();
  WorkerAudit.entered('officialMappingHeavy');
  if (input.operation == 'keys') {
    return MappingOutput([for(final row in input.batch!) {
      if(row.containsKey('cursor')) 'cursor':row['cursor'],
      'device_id':row['device_id'],'ts_ms':row['ts_ms'],
    }],const []);
  }
  if (input.operation == 'bounds') {
    return MappingOutput([for(final row in input.batch!)
      for(final sec in [row['lo'],row['hi']])
        {'sec':sec as int},
    ],const []);
  }
  if (input.operation == 'fileHash') {
    final digest = await sha256.bind(File(input.json as String).openRead()).first;
    return MappingOutput(const [], const [], text: digest.toString());
  }
  if (input.operation == 'profileHash') {
    final text = jsonEncode({
      'tables': {for (final e in officialProfile.tables.entries) e.key: {
        'policy': e.value.policy.code, 'columns': {for (final c in e.value.columns.entries) c.key: c.value.name},
        'destination': e.value.dest, 'rule': e.value.rowRule, 'transforms': e.value.transforms,
        'constants': e.value.emptyConstants,
      }},
      'target_objects': [for (final o in officialTargetObjects) o.sql],
      'enums': [for (final e in officialProfile.enums) [e.table,e.column,e.targetValues.toList(),e.onOther.name]],
    });
    return MappingOutput(const [], const [], text: sha256.convert(utf8.encode(text)).toString());
  }
  if (input.operation == 'json') {
    return MappingOutput(const [], const [], text: jsonEncode(input.json));
  }
  if (input.operation == 'archive') {
    final bucket = SubstrateArchiveCodec.decode(input.blob!, codec: input.codec);
    if (bucket == null || SubstrateArchiveCodec.fingerprint(bucket) != input.fingerprint) {
      return const MappingOutput([], [{'reason': 'unreadable codec or fingerprint mismatch'}]);
    }
    // One record per parent: identity, position, beat count and a typed content
    // hash. Never the content itself. [P2 review F1; archive_claims_test]
    final view = _ArchiveView(bucket);
    return MappingOutput([
      for (var i = 0; i < bucket.onehz.rowCount; i++) {
        'device_id': bucket.onehz.valueAt('device_id', i),
        'ts_ms': bucket.onehz.valueAt('ts_ms', i),
        'rec_ts': bucket.onehz.valueAt('rec_ts', i),
        'row_index': i,
        'beats': view.beatsOf(i).length,
        'digest': sha256.convert(utf8.encode(view.content(i))).toString(),
      },
    ], view.orphanNotes);
  }
  if (input.operation == 'claimsEqual') {
    // Exact re-read compare: the stored hash is never trusted to deduplicate.
    // rows: the buckets involved; json: identities, each a list of [bucket, row].
    final views = <Object?, _ArchiveView>{};
    for (final b in input.rows) {
      final bucket = SubstrateArchiveCodec.decode(b['blob'] as Uint8List, codec: b['codec'] as int);
      if (bucket == null || SubstrateArchiveCodec.fingerprint(bucket) != b['fingerprint']) {
        throw StateError('archive bucket ${b['bucket_id']} unreadable on re-read');
      }
      views[b['bucket_id']] = _ArchiveView(bucket);
    }
    final differing = <Map<String, Object?>>[];
    final identities = input.json as List;
    for (var k = 0; k < identities.length; k++) {
      String? first;
      for (final claim in identities[k] as List) {
        final text = views[(claim as List)[0]]!.content(claim[1] as int);
        first ??= text;
        if (text != first) { differing.add({'identity': k}); break; }
      }
    }
    return MappingOutput(differing, const []);
  }
  if (input.operation == 'unpack') {
    // rows: one entry per bucket with the row indexes to expand.
    final rows = <Map<String, Object?>>[];
    for (final b in input.rows) {
      final bucket = SubstrateArchiveCodec.decode(b['blob'] as Uint8List, codec: b['codec'] as int);
      if (bucket == null || SubstrateArchiveCodec.fingerprint(bucket) != b['fingerprint']) {
        throw StateError('archive bucket ${b['bucket_id']} unreadable on re-read');
      }
      final view = _ArchiveView(bucket);
      for (final i in b['select'] as List) {
        i as int;
        rows.add({'table': 'decoded_onehz', 'bucket': b['bucket_id'], 'parent_index': i, 'row': {
          for (final c in officialProfile.tables['decoded_onehz']!.keep) c: bucket.onehz.valueAt(c, i),
        }});
        for (final beat in view.beatsOf(i)) {
          rows.add({'table': 'decoded_rr', 'bucket': b['bucket_id'], 'parent_index': i, 'row': {
            for (final c in officialProfile.tables['decoded_rr']!.keep) c: beat[c],
          }});
        }
      }
    }
    return MappingOutput(rows, const []);
  }
  final policy = officialProfile.tables[input.table]!;
  final rows = <Map<String, Object?>>[];
  final notes = <Map<String, Object?>>[];
  for (final source in input.rows) {
    final rowid = source['__export_rowid'];
    try {
    String? refusal;
    for (final rule in officialProfile.enums.where((e) => e.table == input.table)) {
      final v = source[rule.column];
      if (v != null && !rule.targetValues.contains(v)) { refusal = 'unsupported ${rule.column}: $v'; }
    }
    switch (input.table) {
      case 'observation':
        if (!{'vendor','entered','imported'}.contains(source['source_kind']) ||
            (source['key'] == null && source['vendor_key'] == null)) { refusal = 'unsupported observation provenance or identity'; }
      case 'sessions':
        if (!{'done', 'completed'}.contains(source['status']) ||
            source['start_ts'] is! num || source['end_ts'] is! num ||
            (source['end_ts'] as num) <= (source['start_ts'] as num) ||
            source['end_ts_fabricated'] == 1) { refusal = 'unfinished or fabricated session end'; }
      case 'hyrox_session' || 'triathlon_session':
        if (!{'finished', 'finalized', 'abandoned', 'discarded'}.contains(source['status'])) { refusal = 'unfinished race'; }
        // A parsed plan is required by the tagged models. Keep unsupported
        // plans in the snapshot, never turn them into another preset.
        try {
          if (!_supportedRacePlanHeavy(input.table,source['plan_json'] as String)) { refusal = 'unsupported race plan'; }
        } catch (_) { refusal = 'unsupported race plan'; }
      case 'activity_suggestions':
        if (source['status'] == 'pending') { refusal = 'pending inference'; }
      case 'workout_suggestions':
        if (source['dismissed'] != 1 && source['dismissed'] != 2) { refusal = 'pending workout inference'; }
      case 'sleep_nap':
        if (!{'manual', 'confirmed', 'rejected', 'auto_confirmed'}.contains(source['source'])) { refusal = 'unconfirmed nap inference'; }
      case 'sleep_override':
        if (source['onset_ts'] is! num || source['offset_ts'] is! num ||
            (source['offset_ts'] as num) <= (source['onset_ts'] as num)) { refusal = 'unsupported sleep boundaries'; }
      case 'live_step_calibration_run':
        if (source['counter_version'] != 2 ||
            !{'slow', 'brisk', 'jog', 'everyday'}.contains(source['category']) ||
            !{'wearerCount', 'phonePedometer'}.contains(source['reference'])) { refusal = 'unsupported calibration counter/category/reference'; }
      case 'backup_prefs':
        if (!_portablePreference(source)) { refusal = 'unsupported or nonportable preference'; }
      case 'backup_secrets':
        if (!{'coach_api_key', 'coach_chatgpt', 'coach_base_url'}.contains(source['key'])) { refusal = 'unknown presence marker'; }
      case 'sync_cursor':
        if (source['name'] != 'decoded_pruned_before') { refusal = 'install-local cursor'; }
      case 'compute_freshness':
        if (source['key'] != 'substrate_archive_policy') { refusal = 'fork freshness or deletion metadata'; }
    }
    if (refusal != null) {
      notes.add({'rowid': rowid, 'reason': refusal, 'omitted': true});
      continue;
    }
    final out = <String, Object?>{
      '__export_rowid': rowid,
      for (final c in [...policy.keep, ...policy.rewrite]) c: source[c],
      for (final c in policy.provenance) c: null,
      for (final c in policy.clear) c: policy.emptyConstants.containsKey(c) ? '{}' : null,
    };
    // These columns have receiver defaults that are NOT NULL. Omitting a
    // cleared value invokes that default, whereas explicitly NULL would fail.
    for (final c in policy.clear) {
      if (c == 'revision' || c == 'legacy_migrated' || c == 'trace_samples') { out.remove(c); }
    }
    if (input.table == 'hyrox_segment' || input.table == 'triathlon_segment') {
      if ({'gps','user'}.contains(source['distance_source']) && source['distance_m'] is num) {
        out['distance_m'] = source['distance_m'];
        out['distance_source'] = source['distance_source'];
      }
      if ({'band','strap'}.contains(source['hr_source'])) { out['hr_source'] = source['hr_source']; }
    }
    if (input.table == 'journal_field_def' || input.table == 'lab_marker_def') {
      out['key'] = qualifiedCustomKey(source['key'] as String, source['unit'] as String? ?? '');
    }
    if (input.table == 'raw_archive_frames' || input.table == 'raw_archive_legacy' || input.table == 'raw_archive') {
      final bytes = source['frame'];
      final hex = source['hex'] as String? ?? (bytes is Uint8List
          ? bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join() : null);
      if (hex == null) {
        notes.add({'rowid': rowid, 'reason': 'missing exact frame', 'omitted': true});
        continue;
      }
      out.clear();
      out.addAll(encodeRawArchiveRow(deviceId: source['device_id'] as String,
          hex: hex, counter: source['counter'] as int?, packetType: source['packet_type'] as int,
          recTs: source['rec_ts'] as int?, capturedAt: source['captured_at'] as int,
          reason: source['reason'] as String));
      out['__export_rowid'] = rowid;
    }
    // A fork Natural/Gradual window is a wake METHOD the tagged target lacks.
    // Never approximate it as Smart Wake: the alarm exports as a plain alarm at
    // its set time (smart_window_minutes 0, which the target rings exactly),
    // and the dropped method columns are named in the ledger. [P2 review F9]
    var droppedSmartWindow = false;
    if (input.table == 'alarm_schedule' && (_positive(source['natural_window_minutes']) || _positive(source['gradual_window_minutes']))) {
      droppedSmartWindow = _positive(source['smart_window_minutes']);
      out['smart_window_minutes'] = 0;
    }
    final changed = [
      for (final c in [...policy.clear, ...policy.omit, ...policy.provenance])
        if (source[c] != null && (policy.omit.contains(c) || out[c] != source[c])) c,
      if (droppedSmartWindow) 'smart_window_minutes',
    ];
    notes.add({'rowid': rowid, 'reason': 'mapped', 'columns': changed,
      if (input.table == 'journal_field_def' || input.table == 'lab_marker_def')
        'key_map': {'original': source['key'], 'mapped': out['key'], 'unit': source['unit']}});
    rows.add(out);
    } catch (error) {
      notes.add({'rowid':rowid,'reason':'unsupported stored value type: ${error.runtimeType}','omitted':true});
    }
  }
  return MappingOutput(rows, notes);
}

bool _positive(Object? v) => v is num && v > 0;

// Closed audited subset. The official fallback accepts arbitrary types/keys;
// accepting that fallback would turn fork settings into implicit permissions.
bool _portablePreference(Map<String, Object?> r) {
  const types = {
    'clock_format': 'string', 'theme_choice': 'string', 'locale_override': 'string',
    'units_system': 'string', 'local_profile_json': 'string',
    'cycle_tracking_enabled': 'bool', 'sleep_hmm_stages': 'bool',
    'rough_night.ask': 'string', 'rough_night.dismissed': 'string',
    'ui.wearable_show_estimates': 'bool', 'ui.wearable_side_by_side': 'bool',
  };
  if (types[r['key']] != r['type']) { return false; }
  final value = r['value'];
  if (value is! String) { return false; }
  if (r['type'] == 'bool') { return value == 'true' || value == 'false'; }
  if (r['key'] == 'local_profile_json') {
    try { if (jsonDecode(value) is! Map) return false; } catch (_) { return false; }
  }
  return true;
}

// Frozen v0.12.2 JSON vocabulary. A later fork plan never becomes a target
// plan by accident merely because its SQL column is still called plan_json.
@heavy
bool _supportedRacePlanHeavy(String table,String text) {
  final json=jsonDecode(text);
  if(json is! Map || json['v']!=1 || json['segments'] is! List) {return false;}
  if(json.keys.any((k)=>!{'v','preset','segments'}.contains(k))) {return false;}
  for(final item in json['segments'] as List) {
    if(item is! Map) {return false;}
    final allowed=table=='hyrox_session'
      ? const {'kind','station','round_index','planned_distance_m','planned_reps','planned_cal','goal_sec'}
      : const {'kind','environment','planned_distance_m','goal_sec'};
    if(item.keys.any((key)=>!allowed.contains(key))) {return false;}
    for(final key in ['planned_distance_m','round_index','planned_reps','planned_cal','goal_sec']) {
      final value=item[key];
      if(value!=null && (value is! num || !value.isFinite ||
          (key!='planned_distance_m' && value!=value.truncate()))) {return false;}
    }
    if(table=='hyrox_session') {
      if(item['kind']!='hyrox_round' || !{'skierg','sled_push','sled_pull','burpee_broad_jump','rowing','farmers_carry','sandbag_lunges','wall_balls'}.contains(item['station'])) {return false;}
    } else {
      if(!{'swim','t1','bike','t2','run'}.contains(item['kind']) ||
          (item['environment']!=null && !{'indoor','outdoor'}.contains(item['environment']))) {return false;}
    }
  }
  final data=json.cast<String,Object?>();
  return table=='hyrox_session' ? HyroxPlan.fromJson(data)!=null : TriathlonPlan.fromJson(data)!=null;
}

/// A decoded archive bucket with its beats grouped under their parents.
class _ArchiveView {
  _ArchiveView(this.bucket) {
    for (var i = 0; i < bucket.onehz.rowCount; i++) {
      (_parents[(bucket.onehz.valueAt('device_id', i), bucket.onehz.valueAt('ts_ms', i))] ??= []).add(i);
    }
    for (var i = 0; i < bucket.rr.rowCount; i++) {
      final identity = (bucket.rr.valueAt('device_id', i), bucket.rr.valueAt('ts_ms', i));
      if (!_parents.containsKey(identity)) {
        orphanNotes.add({'beat_index': i, 'reason': 'archive orphan beat'});
      } else {
        (_beats[identity] ??= []).add(i);
      }
    }
  }
  final ArchiveBucket bucket;
  final _parents = <(Object?, Object?), List<int>>{};
  final _beats = <(Object?, Object?), List<int>>{};
  final orphanNotes = <Map<String, Object?>>[];

  /// The parent's beats ordered by beat_index (ties by typed content).
  List<Map<String, Object?>> beatsOf(int parentIndex) {
    final identity = (bucket.onehz.valueAt('device_id', parentIndex), bucket.onehz.valueAt('ts_ms', parentIndex));
    final rows = [for (final i in _beats[identity] ?? const <int>[]) bucket.rr.rowAt(i)];
    final keyed = [for (final r in rows) (r, _typedRow(r))];
    keyed.sort((a, b) {
      final x = a.$1['beat_index'], y = b.$1['beat_index'];
      final byIndex = x is int && y is int ? x.compareTo(y) : x == null ? (y == null ? 0 : -1) : y == null ? 1 : 0;
      return byIndex != 0 ? byIndex : a.$2.compareTo(b.$2);
    });
    return [for (final k in keyed) k.$1];
  }

  /// Canonical TYPED content of one claim (parent row plus ordered beats):
  /// int, real, text, blob and NULL stay distinct, so 72 and 72.0 differ.
  String content(int parentIndex) => jsonEncode([
    _typedRow(bucket.onehz.rowAt(parentIndex)),
    [for (final beat in beatsOf(parentIndex)) _typedRow(beat)],
  ]);
}

String _typedRow(Map<String, Object?> row) => jsonEncode([
  for (final k in row.keys.toList()..sort()) [k, _typed(row[k])],
]);

Object _typed(Object? v) => v == null ? const ['n']
  : v is int ? ['i', v]
  : v is double ? ['r', v.toString()]
  : v is String ? ['t', v]
  : v is Uint8List ? ['b', base64Encode(v)]
  : ['x', '${v.runtimeType}:$v'];
