// ignore_for_file: avoid_print
// Compare the same stored main-sleep windows through the production worker.
// Run with Flutter's VM (the worker imports Flutter foundation):
// TZ=UTC flutter test tool/sleep_hmm_compare.dart \
//   --dart-define=HMM_COMPARE_DB=/absolute/export.db \
//   --dart-define=HMM_COMPARE_DAYS=2026-06-27,2026-06-28
// Optional HMM_COMPARE_DEVICE selects one band's device_id, default ''.
// Environment variables of the same names also work with the direct runner.
// The database is opened read-only. JSON lines on stdout are research output,
// not validation against polysomnography or evidence of medical efficacy.

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;
import 'package:openstrap_edge/compute/derive_prepare.dart';
import 'package:openstrap_edge/compute/sleep_staging_worker.dart';
import 'package:openstrap_edge/compute/substrate.dart';
import 'package:openstrap_edge/util/worker_init.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// A fixed-window comparison: stored windows preserve the selected bounds,
/// including manual corrections and confirmed-wake trimming. Vendor stages
/// remain in the database; these research outputs never replace them.
Future<List<Map<String, Object?>>> compareStoredSleepNights(
  Database db, {
  List<String> days = const [],
  String deviceId = '',
}) async {
  final nights = await db.rawQuery(
    'SELECT d.day_id, d.window_json FROM day_result d '
    'WHERE d.algo_version = (SELECT MAX(x.algo_version) FROM day_result x '
    'WHERE x.day_id = d.day_id) AND d.skipped = 0 ORDER BY d.day_id',
  );
  final results = <Map<String, Object?>>[];
  for (final night in nights) {
    final day = night['day_id'] as String;
    if (days.isNotEmpty && !days.contains(day)) continue;
    final raw = jsonDecode(night['window_json'] as String);
    final window = raw is Map && raw['value'] is Map
        ? raw['value'] as Map
        : raw;
    final on = window is Map ? window['onset_ms'] : null;
    final off = window is Map ? window['offset_ms'] : null;
    if (on is! num ||
        off is! num ||
        !on.isFinite ||
        !off.isFinite ||
        off <= on) {
      results.add({'day': day, 'skipped': 'no stored sleep window'});
      continue;
    }
    final start = on ~/ 1000, end = off ~/ 1000;
    if (end - start > 16 * 3600) {
      results.add({'day': day, 'skipped': 'stored window exceeds 16 hours'});
      continue;
    }
    // Match both channels to one explicit device. Combining two wearables'
    // rows would compare a night that neither wearable measured.
    final frames = await db.rawQuery(
      'SELECT * FROM decoded_onehz WHERE device_id = ? '
      'AND ts_ms >= ? AND ts_ms < ? ORDER BY ts_ms',
      [deviceId, start * 1000, end * 1000],
    );
    final beats = await db.rawQuery(
      'SELECT * FROM decoded_rr WHERE device_id = ? '
      'AND ts_ms >= ? AND ts_ms < ? ORDER BY ts_ms, beat_index',
      [deviceId, start * 1000, end * 1000],
    );
    if (frames.isEmpty) {
      results.add({
        'day': day,
        'device_id': deviceId,
        'skipped': 'no retained decoded samples for this device',
      });
      continue;
    }
    final result = await Isolate.run(() {
      final sub = substrateFromDecodedPage(frames, beats);
      final methods = <String, Object?>{};
      for (final method in [
        ana.StagingMethod.cardio,
        ana.StagingMethod.hmm628,
      ]) {
        final watch = Stopwatch()..start();
        final staged = stageSleepCandidateHeavy(
          WorkerInputs(nowEpochMs: end * 1000, zoneId: 'UTC', localeTag: 'en'),
          SleepStagingInput(
            dayId: day,
            searchSub: sub,
            override: SleepWindowOverride(
              dayId: day,
              onsetSec: start,
              offsetSec: end,
              source: 'manual',
            ),
            priorSleep: const [],
            confirmedWakeSec: null,
            profileJson: null,
            mayFold: false,
            rowChunks: const [],
            rowsLoSec: start,
            rowsHiSec: end,
            nowSec: end,
            method: method,
          ),
        );
        watch.stop();
        final candidate = jsonDecode(staged.candidateJson) as Map;
        final sleep = candidate['sleep_json'] as Map;
        final counts = <String, int>{};
        for (final label in candidate['hypno_stages'] as List) {
          counts[label as String] = (counts[label] ?? 0) + 1;
        }
        methods[method.name] = {
          'elapsed_ms': watch.elapsedMilliseconds,
          'stage_seconds': counts,
          'hr_min_night': sleep['hr_min_night'],
          'rmssd_mean_night': sleep['rmssd_mean_night'],
          'staging_method': sleep['staging_method'],
          'staging_note': sleep['staging_note'],
        };
      }
      return methods;
    });
    results.add({
      'day': day,
      'device_id': deviceId,
      'onset_sec': start,
      'offset_sec': end,
      'comparison': result,
    });
  }
  return results;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'compare stored sleep windows with cardio and experimental HMM',
    () async {
      const definedPath = String.fromEnvironment('HMM_COMPARE_DB');
      const definedDays = String.fromEnvironment('HMM_COMPARE_DAYS');
      const definedDevice = String.fromEnvironment('HMM_COMPARE_DEVICE');
      final path = Platform.environment['HMM_COMPARE_DB'] ?? definedPath;
      final days = Platform.environment['HMM_COMPARE_DAYS'] ?? definedDays;
      final device =
          Platform.environment['HMM_COMPARE_DEVICE'] ?? definedDevice;
      if (path.isEmpty)
        throw ArgumentError('Set HMM_COMPARE_DB to a stored database');
      sqfliteFfiInit();
      final db = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(readOnly: true),
      );
      try {
        final results = await compareStoredSleepNights(
          db,
          days: days.split(',').where((s) => s.isNotEmpty).toList(),
          deviceId: device,
        );
        if (results.isEmpty) throw StateError('No matching stored nights');
        for (final result in results) {
          print(jsonEncode(result));
        }
      } finally {
        await db.close();
      }
    },
  );
}
