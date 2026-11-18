// Profile coverage against the REAL repaired schemas (spec §4.1–4.3, P1).
//
// WHY: a profile that was never compared with what the code actually creates
// drifts silently; the first sign is an unlisted table's rows reaching the
// official file or vanishing from it. The comparison runs against (a) a fresh
// database made by the fork's real creators and on-open repair, (b) the frozen
// capture of that, and (c) the captured tagged target.
// CLAIM(official-export-accounted-identities), CLAIM(official-export-actual-receiver).
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/official_export/profile.dart';
import 'package:openstrap_edge/data/official_export/profile_tables.dart';
import 'package:openstrap_edge/data/official_export/schema_catalog.dart';

import 'support.dart';

/// Policy per source table, transcribed from the spec's §4.2 table (the owner
/// reviewed that table) plus `android_metadata`, which Android adds to every
/// database. Independent of the profile data it checks.
const _spec = <String, String>{
  'activity_review_days': 'R',
  'activity_review_meta': 'M',
  'activity_suggestions': 'M',
  'alarm_schedule': 'M',
  'android_metadata': 'D',
  'assumed_water': 'D',
  'backup_files': 'D',
  'backup_prefs': 'M',
  'backup_secrets': 'M',
  'band_backlog': 'D',
  'band_battery': 'K',
  'band_events': 'K',
  'baselines': 'R',
  'breathing_session': 'K',
  'compute_freshness': 'M',
  'compute_jobs': 'D',
  'cycle_log': 'K',
  'cycle_symptom': 'K',
  'day_checkpoint': 'R',
  'day_manifest': 'D',
  'day_result': 'R',
  'decoded_onehz': 'M',
  'decoded_rr': 'M',
  'derive_fingerprint': 'R',
  'derived_day': 'R',
  'device': 'M',
  'device_coverage': 'K',
  'ecg_gesture_session': 'D',
  'ecg_raw_packet': 'M',
  'ecg_reading': 'M',
  'ecg_reading_packet': 'K',
  'events': 'M',
  'exercise_def': 'K',
  'external_hr': 'K',
  'food_def': 'K',
  'food_entry': 'K',
  'group_row': 'D',
  'hyrox_segment': 'M',
  'hyrox_session': 'K',
  'import_journal': 'D',
  'imported_measurement': 'K',
  'imported_workout': 'K',
  'input_rev': 'R',
  'input_rev_bulk': 'D',
  'input_revision': 'D',
  'journal': 'K',
  'journal_field_def': 'M',
  'journal_metric': 'M',
  'lab_marker_def': 'M',
  'lab_result': 'M',
  'last_result': 'R',
  'live_coverage': 'M',
  'live_step_calibration': 'R',
  'live_step_calibration_run': 'M',
  'live_workout_tally': 'D',
  'med_def': 'K',
  'med_dose': 'K',
  'metric_method': 'R',
  'metric_series': 'R',
  'metric_series_version': 'R',
  'moment_label': 'D',
  'night_checkpoint': 'R',
  'notif_fired': 'D',
  'notif_slots': 'D',
  'notifications': 'R',
  'observation': 'K',
  'pulse_alert': 'D',
  'raw_archive': 'M',
  'raw_archive_frames': 'M',
  'raw_archive_legacy': 'M',
  'raw_records': 'D',
  'row_rev': 'D',
  'samples': 'K',
  'session_ceiling_rev': 'R',
  'session_score_mask': 'R',
  'session_sensor': 'M',
  'sessions': 'M',
  'signal_priority': 'K',
  'sleep_edit_job': 'D',
  'sleep_nap': 'M',
  'sleep_override': 'M',
  'sleep_session_candidates': 'R',
  'spectral_archive': 'D',
  'spectral_archive_status': 'D',
  'step_calibration': 'R',
  'step_calibration_day': 'K',
  'store_identity': 'R',
  'store_rev': 'D',
  'strength_set': 'M',
  'substrate_archive': 'M',
  'symptom_entry': 'D',
  'sync_cursor': 'M',
  'sync_ledger': 'D',
  'sync_quarantine': 'D',
  'track_absence': 'D',
  'track_definition': 'D',
  'track_event': 'D',
  'track_experiment': 'D',
  'track_experiment_day': 'D',
  'track_learning': 'D',
  'track_learning_log': 'D',
  'track_setup_history': 'D',
  'track_unknown_day': 'D',
  'triathlon_segment': 'M',
  'triathlon_session': 'K',
  'vendor_sleep_epoch': 'K',
  'wake_confirmation': 'D',
  'wake_day_features': 'R',
  'wake_evidence': 'D',
  'wake_meta': 'D',
  'wake_trace': 'D',
  'water_moment': 'D',
  'workout_route': 'M',
  'workout_split': 'M',
  'workout_suggestions': 'M',
};

/// `LocalDb._restoreTables` of the tagged release (`v0.12.2:lib/data/db.dart:12199`).
const _receiverRestoreTables = {
  'alarm_schedule', 'journal', 'journal_metric', 'journal_field_def',
  'lab_result', 'lab_marker_def', 'strength_set', 'exercise_def',
  'food_entry', 'food_def', 'med_def', 'med_dose', 'cycle_log',
  'cycle_symptom', 'breathing_session', 'observation', 'workout_route',
  'workout_split', 'sleep_override', 'sleep_nap', 'vendor_sleep_epoch',
  'workout_suggestions', 'sessions', 'session_sensor', 'hyrox_session',
  'hyrox_segment', 'triathlon_session', 'triathlon_segment',
  'activity_suggestions', 'activity_review_meta', 'activity_review_days',
  'samples', 'events', 'decoded_onehz', 'decoded_rr', 'external_hr',
  'imported_measurement', 'imported_workout', 'raw_archive', 'band_events',
  'band_battery', 'day_result', 'metric_series', 'metric_series_version',
  'metric_method', 'live_coverage', 'notifications', 'baselines',
  'step_calibration', 'step_calibration_day', 'live_step_calibration',
  'live_step_calibration_run', 'device', 'device_coverage', 'signal_priority',
  'ecg_reading', 'ecg_reading_packet', 'ecg_raw_packet', 'sync_cursor',
  'substrate_archive',
};

/// Carried through a dedicated receiver path rather than `_restoreTables`.
const _specialReceiverPaths = {
  'raw_archive_frames', // _mergeRawArchive
  'compute_freshness', // SubstrateArchive.adoptPolicy
  'backup_prefs', // restoreBackupPrefs
  'backup_secrets', // backup_extras presence reader
};

void main() {
  group('the frozen policy itself', () {
    test('is internally consistent', () {
      expect(officialProfile.problems(), isEmpty);
    });

    test('classifies exactly the spec table, with the spec policy codes', () {
      expect({
        for (final e in officialProfile.tables.entries) e.key: e.value.policy.code,
      }, _spec);
    });

    test('every table carries meaning and evidence', () {
      for (final e in officialProfile.tables.entries) {
        expect(e.value.meaning.trim(), isNotEmpty, reason: e.key);
        expect(e.value.evidence.trim(), isNotEmpty, reason: e.key);
      }
    });
  });

  group('coverage of the real fork schema', () {
    test('a fresh database from the real creators and open repair is covered',
        () async {
      await withFreshForkDb((db, _) async {
        final catalog = await SchemaCatalog.read(db);
        expect(catalog.tables, isNotEmpty);
        expect(officialProfile.coverage(catalog), isEmpty);
      });
    });

    test('the frozen capture of that schema is covered', () {
      final catalog = loadCapture('fork_schema_92.json');
      expect(catalog.tables, hasLength(109));
      expect(officialProfile.coverage(catalog), isEmpty);
    });

    test('creating on open and reopening change no table or column', () {
      final both = ['opened', 'reopened'].map(
        (k) => loadCapture('fork_schema_92.json', key: k),
      );
      expect(
        both.first.tables.map((n, t) => MapEntry(n, t.columnNames)),
        both.last.tables.map((n, t) => MapEntry(n, t.columnNames)),
      );
    });

    test('every carried table has a usable rowid in the real schema', () {
      final catalog = loadCapture('fork_schema_92.json');
      for (final e in officialProfile.tables.entries) {
        final shape = catalog.tables[e.key];
        if (shape == null || !e.value.policy.carriesRows) continue;
        expect(shape.rowidAlias, isNotNull, reason: e.key);
      }
    });

    test('the only WITHOUT ROWID table is row_rev, policy D', () {
      final catalog = loadCapture('fork_schema_92.json');
      final without = [
        for (final t in catalog.tables.values)
          if (t.withoutRowid) t.name,
      ];
      expect(without, ['row_rev']);
      expect(officialProfile.tables['row_rev']!.policy, TablePolicy.dropped);
    });
  });

  group('agreement with the captured tagged target (schema 62)', () {
    final target = loadCapture('target_schema_62.json');
    final carrier = {for (final c in officialProfile.carriers) c.name};

    test('every carried table lands in a real target table or a carrier', () {
      for (final e in officialProfile.tables.entries) {
        if (!e.value.policy.carriesRows) continue;
        final d = e.value.dest!;
        expect(target.tables.containsKey(d) || carrier.contains(d), isTrue,
            reason: '${e.key} -> $d');
      }
    });

    test('kept/cleared/rewritten columns exist in the target; omitted do not',
        () {
      for (final e in officialProfile.tables.entries) {
        final t = e.value;
        final shape = target.tables[t.dest];
        if (!t.policy.carriesRows || shape == null) continue;
        final names = shape.columnNames;
        if (t.rowRule != null && e.key.startsWith('raw_archive_')) continue;
        for (final c in [...t.keep, ...t.clear, ...t.rewrite, ...t.provenance]) {
          if (e.key == 'raw_archive' || e.key == 'raw_archive_legacy') continue;
          expect(names, contains(c), reason: '${e.key}.$c');
        }
        for (final c in t.omit) {
          expect(names, isNot(contains(c)), reason: '${e.key}.$c');
        }
      }
    });

    test('target-only columns can take the receiver default or NULL', () {
      for (final e in officialProfile.tables.entries) {
        final shape = target.tables[e.value.dest];
        if (shape == null) continue;
        for (final c in e.value.targetOnly) {
          if (e.key.startsWith('raw_archive_') && e.key != 'raw_archive_frames') {
            continue; // hash/frame are computed by the frame-row encoder
          }
          final col = shape.columns.singleWhere((x) => x.name == c);
          expect(col.supplyOptional, isTrue, reason: '${e.key}.$c');
        }
      }
    });

    test('a cleared column can actually be NULL or defaulted in the target', () {
      for (final e in officialProfile.tables.entries) {
        final shape = target.tables[e.value.dest];
        if (shape == null) continue;
        for (final c in e.value.clear) {
          final col = shape.columns.singleWhere((x) => x.name == c);
          expect(col.supplyOptional, isTrue, reason: '${e.key}.$c');
        }
      }
    });

    test('merge-key columns exist in the target destination', () {
      for (final e in officialProfile.tables.entries) {
        final m = e.value.merge;
        final shape = target.tables[e.value.dest];
        if (m == null || shape == null) continue;
        if (e.key == 'raw_archive' || e.key == 'raw_archive_legacy') continue;
        for (final c in m.columns) {
          expect(shape.columnNames, contains(c), reason: '${e.key}.$c');
        }
      }
    });

    test('plain-replace merge keys equal a target primary key or unique index',
        () {
      // INSERT OR REPLACE only replaces on a PK/unique conflict, so a domain
      // key that is neither would silently duplicate instead of replacing.
      for (final e in officialProfile.tables.entries) {
        final m = e.value.merge;
        final shape = target.tables[e.value.dest];
        if (m == null || shape == null || m.rule != MergeRule.plainReplace) {
          continue;
        }
        if (e.key.startsWith('raw_archive')) continue; // own merge path
        final pk = {for (final c in shape.columns) if (c.pk > 0) c.name};
        final unique = _uniqueIndexColumns(shape);
        final key = m.columns.toSet();
        expect(
          key == pk || unique.any((u) => u.length == key.length && u.containsAll(key)),
          isTrue,
          reason: '${e.key} key ${m.columns} vs pk $pk unique $unique',
        );
      }
    });

    test('every carried table is one the tagged importer actually restores', () {
      for (final e in officialProfile.tables.entries) {
        if (!e.value.policy.carriesRows) continue;
        final d = e.value.dest!;
        expect(
          _receiverRestoreTables.contains(d) ||
              _receiverRestoreTables.contains(e.key) ||
              _specialReceiverPaths.contains(d),
          isTrue,
          reason: '${e.key} -> $d is not restored by the tagged importer',
        );
      }
    });

    test('each recomputed table the target needs has a target table', () {
      for (final e in officialProfile.tables.entries) {
        final t = e.value;
        if (t.policy == TablePolicy.recomputed && t.createsEmptyDest) {
          expect(target.tables, contains(t.dest), reason: e.key);
        }
      }
    });

    test('enum policies name real columns and non-empty value sets', () {
      for (final en in officialProfile.enums) {
        final t = officialProfile.tables[en.table]!;
        expect(t.columns, contains(en.column), reason: '${en.table}.${en.column}');
        expect(en.targetValues, isNotEmpty);
        expect(en.evidence, startsWith('v0.12.2:'));
      }
    });
  });
}

/// Column sets of the target table's unique indexes (PK excluded) read from
/// their DDL, since the capture lists origin/uniqueness per index.
List<Set<String>> _uniqueIndexColumns(TableShape shape) {
  final out = <Set<String>>[];
  for (final i in shape.indexes) {
    if (!i.unique) continue;
    final cols = _indexColumns[(shape.name, i.name)];
    if (cols != null) out.add(cols);
  }
  return out;
}

// Filled from the capture's `objects` by the test setup below.
final Map<(String, String), Set<String>> _indexColumns = _readIndexColumns();

Map<(String, String), Set<String>> _readIndexColumns() {
  final json = readCaptureObjects('target_schema_62.json');
  final out = <(String, String), Set<String>>{};
  for (final o in json) {
    if (o['type'] != 'index' || o['sql'] == null) continue;
    final m = RegExp(r'\((.*)\)').firstMatch((o['sql'] as String).split('WHERE').first);
    if (m == null) continue;
    final cols = m.group(1)!.split(',').map((c) {
      final t = c.trim().split(RegExp(r'\s+')).first;
      final f = RegExp(r'COALESCE\((\w+),(\w+)\)').firstMatch(c.replaceAll(' ', ''));
      return f != null ? [f.group(1)!, f.group(2)!] : [t];
    }).expand((x) => x).toSet();
    out[(o['tbl_name'] as String, o['name'] as String)] = cols;
  }
  return out;
}
