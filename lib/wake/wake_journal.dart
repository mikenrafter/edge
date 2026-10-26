// DbWakeJournal owns durable wake answers, tuning parameters and outcome reads.
// SQLite transactions serialize answers and tuning across owner instances.
// Storage errors propagate to the caller; a skipped question writes nothing.
import 'dart:convert';
import 'package:sqflite/sqflite.dart';

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
    // The optional answer must be durable before learning. An acknowledgement
    // without an answer still contributes its timing on future evaluations.
    await tuneFor(wakeEpochSec);
  }

  Future<WakeNightTimeline> forEpoch(int wakeEpochSec) async =>
      _forEpoch(await LocalDb.instance, wakeEpochSec);

  Future<WakeNightTimeline> _forEpoch(
    DatabaseExecutor db,
    int wakeEpochSec,
  ) async {
    // Journal reads deliberately bypass the diagnostic store's 400-row cap.
    final rows = await db.query(
      'wake_trace',
      where: 'wake_epoch = ?',
      whereArgs: [wakeEpochSec],
      orderBy: 'at_ms ASC, id ASC',
    );
    final alarms = await db.query(
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

  Future<List<WakeNightOutcome>> outcomes() async =>
      _outcomes(await LocalDb.instance);

  Future<List<WakeNightOutcome>> _outcomes(
    DatabaseExecutor db, {
    int? throughEpoch,
  }) async {
    final epochs = await db.rawQuery(
      'SELECT DISTINCT wake_epoch FROM wake_trace '
      'UNION SELECT ts AS wake_epoch FROM band_events '
      "WHERE device_id = '' AND event_id = 57 ORDER BY wake_epoch ASC",
    );
    final history = <WakeNightOutcome>[];
    for (final r in epochs) {
      final epoch = r['wake_epoch'] as int;
      if (throughEpoch != null && epoch > throughEpoch) continue;
      final context = await LocalDb.wakeOutcomeContext(epoch, executor: db);
      // A canonical main-sleep day is required; never invent one from the
      // phone's current date or borrow a nearby day's recovery.
      if (context == null) continue;
      final night = await _forEpoch(db, epoch);
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

  /// SQLite serializes policy reads and both writes across owner instances.
  /// Storage errors propagate; neither parameters nor trace advance on failure.
  Future<NaturalTuningDecision> tuneFor(int wakeEpochSec) async {
    final db = await LocalDb.instance;
    return db.transaction((txn) async {
      final current = await _parameters(txn);
      final history = await _outcomes(txn, throughEpoch: wakeEpochSec);
      // A missing target cannot cause an older night's outcome to be applied.
      final decision = history.any((n) => n.wakeEpochSec == wakeEpochSec)
          ? NaturalWakeTuning.evaluate(history, current: current)
          : NaturalTuningDecision(
              parameters: current,
              reason: 'missing_outcome',
            );
      if (!decision.applied) return decision;
      final p = decision.parameters;
      final values = <String, Object?>{
        'triggerRunOffsetSec': p.triggerRunOffsetSec,
        'windowLeadMinutes': p.windowLeadMinutes,
        'lastLearnedEpoch': p.lastLearnedEpoch,
      };
      await txn.insert('wake_meta', {
        'key': 'natural_wake_parameters',
        'value': jsonEncode(values),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await txn.insert('wake_trace', {
        'wake_epoch': wakeEpochSec,
        'at_ms': DateTime.now().millisecondsSinceEpoch,
        'kind': 'tune',
        'data_json': jsonEncode({
          ...values,
          'reason': decision.reason,
          'eligibleNights': decision.eligibleNights,
        }),
      });
      return decision;
    });
  }

  Future<NaturalWakeParameters> parameters() async =>
      _parameters(await LocalDb.instance);

  Future<NaturalWakeParameters> _parameters(DatabaseExecutor db) async {
    final rows = await db.query(
      'wake_meta',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: ['natural_wake_parameters'],
      limit: 1,
    );
    final data = _map(rows.firstOrNull?['value']);
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
