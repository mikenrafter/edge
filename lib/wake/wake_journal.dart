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

  /// Read only epochs within this stored main-sleep window. The canonical
  /// day association wins when adjacent windows overlap; phone zone is unused.
  Future<WakeNightTimeline> forDay(String dayId) async {
    final stored = _map(await LocalDb.sleepWindowJsonFor(dayId));
    final window = stored['value'] is Map
        ? (stored['value'] as Map).cast<String, Object?>()
        : stored;
    final onset = window['onset_ms'];
    final offset = window['offset_ms'];
    if (onset is! num) return const WakeNightTimeline();
    final end =
        offset is num ? offset.toInt() + 10800000 : onset.toInt() + 64800000;
    final fromSec = (onset / 1000).ceil(), throughSec = (end / 1000).floor();
    final rows = await (await LocalDb.instance).rawQuery(
      'SELECT DISTINCT wake_epoch FROM wake_trace '
      'WHERE wake_epoch BETWEEN ? AND ? '
      'UNION SELECT ts AS wake_epoch FROM band_events '
      "WHERE device_id = '' AND event_id = 57 AND ts BETWEEN ? AND ? "
      'ORDER BY wake_epoch',
      [fromSec, throughSec, fromSec, throughSec],
    );
    final nights = <WakeNightTimeline>[];
    for (final row in rows) {
      final epoch = row['wake_epoch'] as int;
      if ((await LocalDb.wakeOutcomeContext(epoch))?['day_id'] == dayId) {
        nights.add(await forEpoch(epoch));
      }
    }
    final events = [for (final night in nights) ...night.events]
      ..sort((a, b) => a.at.compareTo(b.at));
    final fired = nights.where((n) => n.firstFireAt != null).toList()
      ..sort((a, b) => a.firstFireAt!.compareTo(b.firstFireAt!));
    final primary = fired.firstOrNull ?? nights.firstOrNull;
    // Display every epoch's events, but never pair a fire with another epoch's
    // acknowledgement to manufacture a duration.
    return WakeNightTimeline(
      events: events,
      firstFireAt: primary?.firstFireAt,
      ackAt: primary?.ackAt,
      timeToWake: primary?.timeToWake,
      snoozeCount: nights.fold(0, (sum, n) => sum + n.snoozeCount),
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
