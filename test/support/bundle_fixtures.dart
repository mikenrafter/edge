// Day bundles for the design 06 assembly tests (phase 1d).
//
//  * [freezeBundles]: the stored `day_result` payloads of the WHOOP freeze
//    goldens (test/fixtures/whoop_freeze, gen4 and gen5, three zones, three
//    days each). These are real derive output, key order and number formats
//    included, so they are the "fixture world" days.
//  * [importedSnapshots]: the shape cloud_import.dart and whoop_import.dart
//    write (`imported: true`, `source`, an `accounting.imported` flag).
//    Copied by shape, not by calling the importers, so the test needs no
//    database. If an importer's top-level keys change, change them here.

import 'dart:convert';
import 'dart:io';

/// (golden file name + day, bundle). Decoded with jsonDecode, so Map key order
/// is the file's order, which is the order the derive wrote.
List<(String, Map<String, Object?>)> freezeBundles() {
  final dir = Directory('test/fixtures/whoop_freeze');
  final out = <(String, Map<String, Object?>)>[];
  final files = dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.json'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final f in files) {
    final doc = jsonDecode(f.readAsStringSync()) as Map;
    for (final r in (doc['day_result'] as List).cast<Map>()) {
      final payload = r['payload_json'];
      if (payload is! Map) continue;
      final name = f.uri.pathSegments.last;
      out.add(('$name ${r['day_id']}', Map<String, Object?>.from(payload)));
    }
  }
  return out;
}

Map<String, Object?> _env(Object? v, String src) => {
      'value': v ?? '—',
      'confidence': v == null ? 0 : 0.7,
      'tier': 'HIGH',
      'inputs_used': [src],
    };

/// A cloud-v2 style snapshot and a WHOOP-export style one, with null scalars.
List<(String, Map<String, Object?>)> importedSnapshots() => [
      (
        'cloud_v2',
        <String, Object?>{
          'date': '2026-03-10',
          'imported': true,
          'source': 'cloud_v2',
          'day_confidence': 0.7,
          'flags': ['IMPORTED_CLOUD_V2'],
          'clinical': {
            'hrv_time': _env({'rmssd': 41.2, 'sdnn': 55.0}, 'cloud_v2'),
            'resting_hr': _env({'low30Mean': 52.0}, 'cloud_v2'),
          },
          'sleep': {
            'accounting': {
              'value': {
                'tst_sec': 25200,
                'efficiency_pct': 91.5,
                'deep_low_confidence': true,
                'imported': true,
              },
              'confidence': 0.7,
              'tier': 'ESTIMATE',
              'inputs_used': ['cloud_v2'],
            },
          },
          'scalars': {
            'rhr': 52.0,
            'rmssd': 41.2,
            'readiness': null,
            'strain': 9.4,
            'skin_temp_z': null,
            'spo2': null,
            'stress': null,
            'tst_min': 420.0,
            'sleeping_hr_nadir': null,
            'waking_hr': null,
          },
        },
      ),
      (
        'whoop_export',
        <String, Object?>{
          'date': '2026-03-11',
          'imported': true,
          'source': 'whoop_export',
          'day_confidence': 0.7,
          'flags': ['IMPORTED_WHOOP_BETA'],
          'clinical': <String, Object?>{},
          'scalars': {
            'rhr': null,
            'rmssd': null,
            'readiness': 66.0,
            'strain': null,
            'resp_rate': 14.5,
            'calories': 2300,
            'spo2': 96.0,
          },
        },
      ),
    ];
