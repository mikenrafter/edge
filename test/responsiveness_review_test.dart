// WHY: Review's committed rows must remain usable while derive owns the writer.
// CLAIM(review-reader): legacy preparation and optional tails cannot hold first
// content. The writer is gated until the real Review load finishes.
import 'dart:async';
import 'dart:convert';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/activity_store.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/data/load_timings.dart';
import 'package:openstrap_edge/ui2/screens/day_timeline.dart';
import 'backup/backup_support.dart';

class _SlowAnnotations extends LocalRepositoryImpl {
  _SlowAnnotations() : super(getProfileMap: () => {});
  final tail = Completer<Map<String, dynamic>>();
  @override
  Future<Map<String, dynamic>> getInsights() => tail.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BackupEnv env;
  setUp(() async {
    env = await BackupEnv.create('responsiveness_review.db');
    await LocalDb.setForeground(true);
    await LocalDb.instance;
  });
  tearDown(() async {
    await env.dispose();
  });

  test('all audited Review reads finish with the writer held', () async {
    final repo = LocalRepositoryImpl(getProfileMap: () => {});
    final writer = await LocalDb.instance;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final at = DateTime(2026, 11, 13).millisecondsSinceEpoch ~/ 1000;
    await LocalDb.putDayResult(
      dayId: '2026-11-13',
      algoVersion: kAlgoVersion,
      payloadJson: jsonEncode({
        'date': '2026-11-13',
        'scalars': {
          'strain': 2,
          'calories': 120,
          'calories_total': 180,
          'trimp': 4,
        },
        'series': {
          'hr_curve': [
            {'t': at, 'v': 60},
            {'t': at + 60, 'v': 65},
          ],
        },
        'sleep': {
          'window': {
            'value': {'onset_ms': at * 1000, 'offset_ms': (at + 3600) * 1000},
          },
          'accounting': {
            'value': {'tst_sec': 3600},
          },
        },
      }),
      windowJson: jsonEncode({
        'value': {'onset_ms': at * 1000, 'offset_ms': (at + 3600) * 1000},
      }),
    );
    await writer.update('day_result', {'computed_at': 1234000});
    await writer.insert('wake_trace', {
      'wake_epoch': at + 3600,
      'at_ms': (at + 3600) * 1000,
      'kind': 'ack',
      'data_json': '{}',
    });
    await writer.insert('journal', {
      'date': '2026-11-13',
      'tags_json': '[]',
      'note': 'exact',
      'updated_at': 1,
    });
    await writer.insert('journal', {
      'date': '2026-11-14',
      'tags_json': '[]',
      'note': 'later',
      'updated_at': 1,
    });
    await writer.insert('workout_suggestions', {
      'id': 'legacy-review',
      'date': '2026-11-13',
      'start_ts': now - 600,
      'end_ts': now - 60,
      'created_at': now,
      'dismissed': 0,
      'sport': 'walking',
    });
    final acquired = Completer<void>(), release = Completer<void>();
    final transaction = writer.transaction((tx) async {
      await tx.rawUpdate(
        'UPDATE activity_review_meta SET revision = revision + 1',
      );
      acquired.complete();
      await release.future;
    });
    await acquired.future;
    final elapsed = Stopwatch()..start();
    try {
      final data = await TimelineData.load(
        repo,
        want: '2026-11-13',
      ).timeout(const Duration(seconds: 10));
      final pending = await repo.pendingActivities().timeout(
        const Duration(seconds: 10),
      );
      expect(pending.map((s) => s.id), ['legacy-review']);
      expect(
        (await LocalDb.journalRows(date: '2026-11-13')).map((r) => r['note']),
        ['exact'],
      );
      expect(data.day, '2026-11-13');
      expect(data.computedAtMs, 1234000);
      expect((data.raw!['hr'] as List).length, 2);
      expect(
        data.moments.where((m) => m.at == at && m.until == at + 3600).length,
        1,
      );
      final meta = await (await LocalDb.reader).query('activity_review_meta');
      expect(
        meta.single['legacy_migrated'],
        0,
        reason: 'a read must not migrate',
      );
      expect(
        LoadTimings.shared.samples.map((s) => s.phase),
        contains('reader query'),
      );
      expect(
        LoadTimings.shared.samples.map((s) => s.phase),
        containsAll(['decode queue', 'decode execution']),
      );
      expect(data.readMillis.keys, contains('calculation timestamp'));
      // Sandbox FFI coordination measurement, not an Android benchmark.
      // ignore: avoid_print
      print(
        'Review held-writer load ${elapsed.elapsedMilliseconds}ms; ${data.readMillis}',
      );
    } finally {
      release.complete();
      await transaction;
    }
    await ActivityStore(
      writer,
    ).discard((await repo.pendingActivities()).single);
    expect(
      await repo.pendingActivities(),
      isEmpty,
      reason: 'a legacy row shown before migration must be actionable',
    );
    await ActivityStore(writer).migrateLegacy();
    expect(await repo.pendingActivities(), isEmpty);
  });

  test(
    'first usable timeline precedes a blocked optional annotation',
    () async {
      final repo = _SlowAnnotations();
      final usable = Completer<TimelineData>();
      var finished = false;
      final load =
          TimelineData.load(
            repo,
            want: '2026-11-13',
            onPrimary: usable.complete,
          ).then((data) {
            finished = true;
            return data;
          });
      try {
        final primary = await usable.future.timeout(
          const Duration(seconds: 10),
        );
        expect(primary.day, '2026-11-13');
        expect(finished, false);
        expect(
          LoadTimings.shared.samples
              .where((s) => s.name == 'Review')
              .map((s) => s.phase),
          contains('first usable rows'),
        );
      } finally {
        repo.tail.complete({});
        await load;
      }
    },
  );
}
