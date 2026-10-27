import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/wake/wake_journal.dart';
import 'package:openstrap_edge/wake/wake_outcome.dart';
import '../test/backup/backup_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BackupEnv env;
  setUpAll(() async {
    env = await BackupEnv.create('phase4_tracks.db');
  });
  setUp(() => env.wipe());
  tearDownAll(() => env.dispose());
  Future<int> seed(
    int index, {
    bool alcohol = false,
    List<String> tags = const [],
  }) async {
    final wake = DateTime(2026, 9, 1 + index, 7);
    final onset = DateTime(wake.year, wake.month, wake.day - 1, 22);
    final epoch = wake.millisecondsSinceEpoch ~/ 1000;
    final db = await LocalDb.instance;
    await db.insert('day_result', {
      'day_id': dayLabelOf(wake),
      'algo_version': 117,
      'computed_at': 1,
      'finalized': 1,
      'window_json': jsonEncode({
        'onset_ms': onset.millisecondsSinceEpoch,
        'offset_ms': wake.millisecondsSinceEpoch,
      }),
      'payload_json': jsonEncode({
        'scalars': {'readiness': 80},
        'sleep': {
          'accounting': {
            'value': {'tst_sec': 28800},
          },
        },
      }),
    });
    if (tags.isNotEmpty) {
      await db.insert('journal', {
        'date': dayLabelOf(onset),
        'tags_json': jsonEncode(tags),
        'updated_at': 1,
      });
    }
    if (alcohol) {
      await db.insert('journal_metric', {
        'date': dayLabelOf(onset),
        'field': 'alcohol_units',
        'value': 2,
        'at_min': 18 * 60,
        'updated_at': 1,
      });
    }
    for (final row in [
      {
        'kind': 'natural',
        'at_ms': (epoch - 60) * 1000,
        'data_json': '{"reason":"fire"}',
      },
      {
        'kind': 'ack',
        'at_ms': epoch * 1000,
        'data_json': jsonEncode({
          'dreamAnswer': 'dream',
          'wakePath': 'natural',
          'dreamAnsweredAtMs': epoch * 1000,
        }),
      },
    ]) {
      await db.insert('wake_trace', {'wake_epoch': epoch, ...row});
    }
    return epoch;
  }

  test(
    'DB populates early alcohol context and persists independent tracks across reopen',
    () async {
      const journal = DbWakeJournal();
      for (var i = 0; i < 6; i++) {
        await seed(i, alcohol: true);
      }
      final sixth = (await journal.outcomes()).last;
      expect(sixth.substance, WakeSubstance.alcohol);
      expect(sixth.track, 1);
      expect((await journal.tuneFor(sixth.wakeEpochSec)).applied, isFalse);
      final seventh = await seed(6, alcohol: true);
      expect((await journal.tuneFor(seventh)).applied, isTrue);
      for (var i = 7; i < 14; i++) {
        await seed(i);
      }
      final last = (await journal.outcomes()).last.wakeEpochSec;
      expect((await journal.tuneFor(last)).applied, isTrue);
      await LocalDb.close();
      expect((await journal.parameters(track: 1)).windowLeadMinutes, 1);
      expect((await journal.parameters()).windowLeadMinutes, 1);
      expect((await journal.tuneFor(seventh)).applied, isFalse);
      final traces = await (await LocalDb.instance).query(
        'wake_trace',
        where: "kind = 'tune'",
      );
      expect(
        traces.map(
          (r) => (jsonDecode(r['data_json'] as String) as Map)['track'],
        ),
        ['track 1', 'track 0'],
      );
      expect(
        traces.map((r) => r['data_json']).join(),
        isNot(contains('alcohol')),
      );
    },
  );
  test('combined active set does not borrow separate track warm-up', () async {
    const journal = DbWakeJournal();
    for (var i = 0; i < 7; i++) {
      await seed(i, tags: ['sick']);
    }
    final last = await seed(7, tags: ['sick', 'workout']);
    final nights = await journal.outcomes();
    expect(nights.first.track, 16);
    expect(nights.last.track, 48);
    final d = await journal.tuneFor(last);
    expect(d.eligibleNights, 1);
    expect(d.applied, isFalse);
    expect((await journal.parameters(track: 48)).windowLeadMinutes, 0);
  });
}
