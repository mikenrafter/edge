// DbWakeJournal owns durable wake answers and outcome reads. SQLite
// transactions serialize answer writes across all instances of this owner.
// Storage errors propagate to the caller; a skipped question writes nothing.
import 'dart:convert';

import '../data/db.dart';
import 'natural_wake_tuning.dart';
import 'wake_orchestrator.dart' show WakeTraceEntry;
import 'wake_outcome.dart';
import 'wake_timeline.dart';

class DbWakeJournal {
  const DbWakeJournal();

  Future<void> answerDream({
    required int wakeEpochSec,
    required DateTime at,
    required DreamAnswer? answer,
  }) async {
    if (answer == null) return;
    final db = await LocalDb.instance;
    await db.transaction((txn) async {
      final rows = await txn.query(
        'wake_trace',
        where: 'wake_epoch = ?',
        whereArgs: [wakeEpochSec],
        orderBy: 'at_ms ASC, id ASC',
      );
      final acks = rows.where((r) => r['kind'] == 'ack');
      if (acks.isEmpty) return; // an answer cannot acknowledge a wake itself
      final ack = acks.first;
      final data = _map(ack['data_json']);
      if (data['dreamAnswer'] != null) return; // first answer wins
      final preceding = _entries(
        rows.where((r) => (r['at_ms'] as int) <= (ack['at_ms'] as int)),
      );
      final night = WakeNightTimeline.forEpoch(
        wakeEpochSec: wakeEpochSec,
        trace: preceding,
      );
      final kinds = night.events.map((e) => e.kind).toSet();
      final path = kinds.contains(WakeNightEventKind.natural)
          ? WakePath.natural
          : kinds.contains(WakeNightEventKind.gradual)
          ? WakePath.gradual
          : kinds.contains(WakeNightEventKind.alarm) ||
                (await txn.query(
                  'band_events',
                  columns: ['ts'],
                  where: 'device_id = ? AND event_id = 57 AND ts = ?',
                  whereArgs: ['', wakeEpochSec],
                  limit: 1,
                )).isNotEmpty
          ? WakePath.alarm
          : null;
      await txn.update(
        'wake_trace',
        {
          'data_json': jsonEncode({
            ...data,
            'dreamAnswer': answer.name,
            if (path != null) 'wakePath': path.name,
            'dreamAnsweredAtMs': at.millisecondsSinceEpoch,
          }),
        },
        where: 'id = ?',
        whereArgs: [ack['id']],
      );
    });
  }

  Future<WakeNightTimeline> forEpoch(int wakeEpochSec) async {
    // Journal reads deliberately bypass the diagnostic store's 400-row cap.
    final rows = await LocalDb.wakeTraceRows(wakeEpochSec);
    final alarms = await (await LocalDb.instance).query(
      'band_events',
      columns: ['ts'],
      where: 'device_id = ? AND event_id = 57 AND ts = ?',
      whereArgs: ['', wakeEpochSec],
    );
    final acks = rows.where((r) => r['kind'] == 'ack').toList()
      ..sort((a, b) {
        final time = (a['at_ms'] as int).compareTo(b['at_ms'] as int);
        return time != 0 ? time : (a['id'] as int).compareTo(b['id'] as int);
      });
    return WakeNightTimeline.forEpoch(
      wakeEpochSec: wakeEpochSec,
      trace: _entries(rows),
      bandAlarms: [
        for (final r in alarms)
          WakeBandAlarm(
            wakeEpochSec: wakeEpochSec,
            at: DateTime.fromMillisecondsSinceEpoch(
              (r['ts'] as int) * 1000,
              isUtc: true,
            ),
          ),
      ],
      dream: acks.isEmpty ? null : _dream(_map(acks.first['data_json'])),
    );
  }

  Future<List<WakeNightOutcome>> outcomes() async {
    final db = await LocalDb.instance;
    final epochs = await db.rawQuery(
      'SELECT DISTINCT wake_epoch FROM wake_trace '
      'UNION SELECT ts AS wake_epoch FROM band_events '
      "WHERE device_id = '' AND event_id = 57 ORDER BY wake_epoch ASC",
    );
    final history = <WakeNightOutcome>[];
    for (final r in epochs) {
      final epoch = r['wake_epoch'] as int;
      final context = await LocalDb.wakeOutcomeContext(epoch);
      // A canonical main-sleep day is required; never invent one from the
      // phone's current date or borrow a nearby day's recovery.
      if (context == null) continue;
      final night = await forEpoch(epoch);
      if (night.events.isEmpty) continue;
      final recovery = context['recovery'];
      final tst = context['tst_sec'];
      history.add(
        WakeNightOutcome(
          dayId: context['day_id'] as String,
          wakeEpochSec: epoch,
          timeToWake: night.timeToWake,
          snoozeCount: night.snoozeCount,
          dream: night.dream,
          recovery: recovery is num ? recovery.toDouble() : null,
          mainSleepTst: tst is num && tst >= 0
              ? Duration(
                  microseconds: (tst * Duration.microsecondsPerSecond).round(),
                )
              : null,
        ),
      );
    }
    return history;
  }

  // Phase 3 owns policy application and its atomic tune-row write.
  Future<NaturalTuningDecision> tuneFor(int wakeEpochSec) async =>
      const NaturalTuningDecision();

  Future<NaturalWakeParameters> parameters() async {
    final data = _map(await LocalDb.wakeMetaGet('natural_wake_parameters'));
    return NaturalWakeParameters(
      triggerRunOffsetSec: (data['triggerRunOffsetSec'] as num?)?.toInt() ?? 0,
      windowLeadMinutes: (data['windowLeadMinutes'] as num?)?.toInt() ?? 0,
      lastLearnedEpoch: (data['lastLearnedEpoch'] as num?)?.toInt(),
    );
  }

  static List<WakeTraceEntry> _entries(Iterable<Map<String, Object?>> rows) => [
    for (final r in rows)
      WakeTraceEntry(
        wakeEpochSec: r['wake_epoch'] as int,
        atMs: r['at_ms'] as int,
        kind: r['kind'] as String,
        data: _map(r['data_json']),
      ),
  ];

  static Map<String, Object?> _map(Object? raw) {
    try {
      final value = raw is String ? jsonDecode(raw) : raw;
      return value is Map ? value.cast<String, Object?>() : {};
    } catch (_) {
      return {};
    }
  }

  static WakeDreamResponse? _dream(Map<String, Object?> data) {
    final answer = switch (data['dreamAnswer']) {
      'dream' => DreamAnswer.dream,
      'normal' => DreamAnswer.normal,
      _ => null,
    };
    final path = switch (data['wakePath']) {
      'natural' => WakePath.natural,
      'gradual' => WakePath.gradual,
      'alarm' => WakePath.alarm,
      _ => null,
    };
    final at = data['dreamAnsweredAtMs'];
    if (answer == null || path == null || at is! num) return null;
    return WakeDreamResponse(
      answer: answer,
      path: path,
      at: DateTime.fromMillisecondsSinceEpoch(at.toInt(), isUtc: true),
    );
  }
}
