import 'dart:math';
import 'dart:convert';
import 'package:openstrap_protocol/openstrap_protocol.dart' as proto;
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/processing_context.dart';
import 'package:openstrap_edge/compute/pulse_episode_worker.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/pulse_episode_store.dart';
import 'backup/backup_support.dart';
import 'pulse_band_fixture.dart';
import 'pulse_sleep_rr_fixture.dart';

final pulseFixStart = DateTime(2026, 11, 10, 2).millisecondsSinceEpoch;

List<Map<String, Object?>> pulseFixRows(
  List<int> rr, {
  int? start,
  int minutes = 25,
}) {
  final begin = start ?? pulseFixStart;
  var time = begin, i = 0;
  final rows = <Map<String, Object?>>[];
  while (time < begin + minutes * 60000) {
    final value = rr[i % rr.length];
    time += value;
    rows.add({
      'device_id': '',
      'ts_ms': time,
      'rec_ts': time ~/ 1000,
      'beat_index': 0,
      'rr_ts_ms': time,
      'beat_ts_ms': time,
      'rr_ms': value,
    });
    i++;
  }
  return rows;
}

Future<void> pulseFixContext({
  bool sleep = true,
  double? motion,
  int? wrist,
  int? start,
  int minutes = 25,
}) async {
  final db = await LocalDb.instance;
  final batch = db.batch();
  final begin = start ?? pulseFixStart;
  for (var t = begin; t < begin + minutes * 60000; t += 1000) {
    batch.insert('decoded_onehz', {
      'device_id': '',
      'ts_ms': t,
      'rec_ts': t ~/ 1000,
      'counter': t ~/ 1000,
      'hr': 52,
      'band_sleep_state': sleep ? 2 : 0,
      'dyn_accel_g': motion,
      'on_wrist': wrist,
    });
  }
  await batch.commit(noResult: true);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BackupEnv env;
  setUpAll(() async => env = await BackupEnv.create('pulse-fixes.db'));
  setUp(() async {
    await env.wipe();
    await PulseEpisodeWorker.run(
      [],
      processingContext: ProcessingContext.reanalysis,
    );
  });
  tearDownAll(() => env.dispose());
  Future<List<PulseEpisodeSnapshot>> run() async {
    final result = await PulseEpisodeWorker.run([
      '2026-11-10',
    ], processingContext: ProcessingContext.reanalysis);
    expect(result.failedDays, isEmpty);
    return PulseEpisodeStore(await LocalDb.instance).list();
  }

  // Accepted v4 outcomes: these seven literal excerpts remain eligible.
  // The original full recordings retain eight episodes; excerpts omit later pairs.
  const retained = {2, 3, 4, 6, 7, 9, 11};
  for (var i = 0; i < sleepRrFixtures.length; i++) {
    final capture = i + 1;
    final why = capture == 7
        ? 'residual irregularity survives a supported fit'
        : 'single respiratory fit is too weak to exclude';
    // WHY/CLAIM(pulse-sleep-pattern): preserve the owner's accepted safety trade-off.
    // # catches: blanket sleep suppression, weakened fit guard or residual floors.
    test('sleep RR capture $capture: ${retained.contains(capture) ? why : 'breathing explains irregularity'}', () async {
      await insertRows(await LocalDb.instance, pulseFixRows(sleepRrFixtures[i]));
      await pulseFixContext(motion: 0.006, wrist: 1);
      final episodes = await run();
      if (!retained.contains(capture)) {
        expect(episodes, isEmpty);
        return;
      }
      expect(episodes, hasLength(1), reason: why);
      final stored = await PulseEpisodeStore(await LocalDb.instance).get(episodes.single.id);
      final windows = (stored!.evidence!['windows'] as List).cast<Map>();
      final residuals = windows.map((w) => (w['breathing'] as Map)['residual'] as Map).toList();
      expect(residuals, isNotEmpty);
      if (capture == 7) {
        expect(residuals.any((r) => r['status'] == 'supported' &&
            (r['ratio'] as num) >= .7 && (r['pnnPct'] as num) >= 30), isTrue,
            reason: 'breathing subtraction still leaves independent irregularity');
      } else {
        expect(residuals.every((r) => r['status'] == 'weak' &&
            (r['explainedVariance'] as num) < .12), isTrue,
            reason: 'a weak fit cannot justify exclusion even if residual floors fail');
      }
      expect(residuals.every((r) => r['excludes'] == false), isTrue);
    });
  }
  // WHY/CLAIM(pulse-sleep-pattern): low heart rate alone must not hide irregularity.
  // # catches: suppressing all sleeping windows or refusing missing context.
  test(
    'uncorrelated irregular low-HR sleep with unknown wear still alerts',
    () async {
      final random = Random(53);
      await insertRows(
        await LocalDb.instance,
        pulseFixRows(List.generate(5000, (_) => 950 + random.nextInt(400))),
      );
      await pulseFixContext(motion: 0.006);
      final episodes = await run();
      expect(episodes, hasLength(1));
      final stored = await PulseEpisodeStore(
        await LocalDb.instance,
      ).get(episodes.single.id);
      expect(stored!.evidence!['alertEligible'], isTrue);
    },
  );
  // WHY/CLAIM(pulse-context): only positive motion/wear evidence suppresses.
  // # catches: leaving the motion and wear inputs unwired.
  for (final kind in ['moving', 'off-wrist']) {
    test('$kind irregular series is suppressed', () async {
      final random = Random(53);
      await insertRows(
        await LocalDb.instance,
        pulseFixRows(List.generate(5000, (_) => 950 + random.nextInt(400))),
      );
      await pulseFixContext(
        motion: kind == 'moving' ? 0.2 : 0.006,
        wrist: kind == 'off-wrist' ? 0 : 1,
      );
      expect(await run(), isEmpty);
    });
  }
  // WHY/CLAIM(pulse-context): wrist event carry-in is useful even when on_wrist is null.
  // # catches: reading only the nullable per-second wear column.
  test(
    'a carried wrist-off event suppresses without any 1 Hz samples',
    () async {
      final db = await LocalDb.instance;
      final random = Random(53);
      await insertRows(
        db,
        pulseFixRows(List.generate(5000, (_) => 950 + random.nextInt(400))),
      );
      await db.insert('band_events', {
        'device_id': '',
        'hex': 'wrist-off',
        'event_id': proto.EventId.wristOff,
        'name': 'WRIST_OFF',
        'ts': pulseFixStart ~/ 1000 - 60,
        'captured_at': 0,
      });
      expect(await run(), isEmpty);
    },
  );
  // WHY/CLAIM(pulse-context): independently derived sleep corroborates missing band states.
  // # catches: using only band_sleep_state and missing the owner's stage-3 windows.
  test(
    'canonical sleep window supplies sleep when band state says up',
    () async {
      final db = await LocalDb.instance;
      await insertRows(db, pulseFixRows(sleepRrFixtures.first));
      await pulseFixContext(sleep: false, motion: 0.006, wrist: 1);
      await db.update('decoded_onehz', {'band_sleep_state': 3});
      await db.insert('day_result', {
        'day_id': '2026-11-10',
        'algo_version': 121,
        'payload_json': '{}',
        'window_json': jsonEncode({
          'onset_ms': pulseFixStart,
          'offset_ms': pulseFixStart + 25 * 60000,
        }),
        'computed_at': 1,
      });
      expect(await run(), isEmpty);
    },
  );
  // WHY/CLAIM(pulse-context): context changes between snapshot and commit cannot alert.
  // # catches: stamping RR alone and ignoring a late wrist-off event.
  test(
    'a late context event invalidates detection before reconciliation',
    () async {
      final db = await LocalDb.instance;
      final random = Random(53);
      await insertRows(
        db,
        pulseFixRows(List.generate(5000, (_) => 950 + random.nextInt(400))),
      );
      PulseEpisodeWorker.probe = ProbeFn((_) async {
        await db.insert('band_events', {
          'device_id': '',
          'hex': 'late-off',
          'event_id': proto.EventId.wristOff,
          'name': 'WRIST_OFF',
          'ts': pulseFixStart ~/ 1000,
          'captured_at': 0,
        });
      });
      try {
        final result = await PulseEpisodeWorker.run([
          '2026-11-10',
        ], processingContext: ProcessingContext.reanalysis);
        expect(result.retryDays, {'2026-11-10'});
        expect(await db.query('pulse_episode'), isEmpty);
        expect(await db.query('pulse_episode_outbox'), isEmpty);
      } finally {
        PulseEpisodeWorker.probe = null;
      }
    },
  );
  // WHY/CLAIM(pulse-baseline): every historical status supplies the exclusion halo.
  // # catches: filtering baseline exclusions to active episodes at the DB seam.
  for (final status in ['active', 'retracted', 'merged', 'superseded']) {
    test(
      'stored $status episodes exclude their thirty-minute baseline halo',
      () async {
        final db = await LocalDb.instance;
        for (var day = 3; day >= 1; day--) {
          final t = pulseFixStart - day * 24 * 3600000;
          await insertRows(
            db,
            pulseFixRows(sleepRrFixtures.first, start: t, minutes: 55),
          );
          await pulseFixContext(start: t, minutes: 55, motion: 0.006, wrist: 1);
          await db.insert('pulse_episode', {
            'id': 'old-$day',
            'source': '',
            'seed_ms': t + 55 * 60000,
            'start_ms': t + 55 * 60000,
            'end_ms': t + 65 * 60000,
            'ongoing': 0,
            'day': '2026-11-07',
            'end_day': '2026-11-07',
            'zone_provenance': 'test',
            'first_seen_ms': 1,
            'updated_ms': 1,
            'revision': 'old',
            'origin': 'bulk',
            'status': status,
          });
        }
        final random = Random(53);
        await insertRows(
          db,
          pulseFixRows(List.generate(5000, (_) => 950 + random.nextInt(400))),
        );
        await pulseFixContext(motion: 0.006, wrist: 1);
        await run();
        final rows = await db.query(
          'pulse_episode',
          where: 'start_ms>=?',
          whereArgs: [pulseFixStart],
        );
        expect(rows, hasLength(1));
        final current = await PulseEpisodeStore(
          db,
        ).get(rows.single['id'] as String);
        final window = (current!.evidence!['windows'] as List).first as Map;
        expect(window['baseline'], containsPair('status', 'calibrating'));
        expect((window['baseline'] as Map)['windows'], lessThan(24));
        expect(window['thresholds'], containsPair('ratio', 0.7));
      },
    );
  }
  // WHY/CLAIM(pulse-context): charging is positive off-body evidence even without wear samples.
  // # catches: supplying only wrist-off spans to the detector.
  test('a carried charging event suppresses without any 1 Hz samples', () async {
    final db = await LocalDb.instance;
    final random = Random(53);
    await insertRows(db, pulseFixRows(List.generate(5000, (_) => 950 + random.nextInt(400))));
    await db.insert('band_events', {'device_id':'','hex':'charging-on',
      'event_id':proto.EventId.chargingOn,'name':'CHARGING_ON',
      'ts':pulseFixStart ~/ 1000 - 60,'captured_at':0});
    expect(await run(),isEmpty);
  });

}
