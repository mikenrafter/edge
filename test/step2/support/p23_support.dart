// Shared fixtures for the design 02 step 2 / P2.3 tests (publish gate and
// freshness). Builds on p22_support.dart. Day labels are relative to today's
// LOCAL label because the freshness refresh compares against the real
// `todayLabel()`; the tests run under TZ=UTC.

import 'dart:async';
import 'dart:convert';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/state/publish_gate.dart';

import 'p22_support.dart';

export 'p22_support.dart';

/// The local label [n] days before today (0 = today).
String p23Day(int n) {
  final t = DateTime.now();
  return dayLabelOf(DateTime(t.year, t.month, t.day - n));
}

/// A payload shaped like the part of a bundle the freshness refresh reads.
String p23Payload({
  bool sleep = false,
  Object? tst = 25000,
  Object? flags,
  Object? readiness,
  bool? skipped,
  Map<String, Object?> extra = const {},
}) => jsonEncode({
  'skipped': ?skipped,
  'scalars': {
    'steps': 4000,
    'readiness': ?readiness,
  },
  if (sleep)
    'sleep': {
      'accounting': {
        'value': {'tst_sec': tst, 'efficiency': 0.9},
      },
    },
  'flags': ?flags,
  ...extra,
});

/// Insert a served `day_result` row with a controlled `readiness` column.
Future<void> p23Row(
  Database db,
  String day,
  String payload, {
  int computedAt = 1000,
  double? readinessColumn,
  int version = p21Version,
}) => db.insert('day_result', {
  'day_id': day,
  'algo_version': version,
  'payload_json': payload,
  'window_json': '{}',
  'computed_at': computedAt,
  'finalized': 0,
  'skipped': 0,
  'partial': 0,
  'rhr': null,
  'rmssd': null,
  'readiness': readinessColumn,
}, conflictAlgorithm: ConflictAlgorithm.replace);

/// A `wake_day_features` row with a fixed `computed_at`.
Future<void> p23Wake(Database db, String day, int computedAt) =>
    db.insert('wake_day_features', {
      'day_id': day,
      'algo_version': p21Version,
      'payload_json': '{"w":1}',
      'computed_at': computedAt,
    });

/// A 1 Hz row at local 08:00 of [day], so `rawStats` reaches that day.
Future<int> p23Raw(Database db, String day) async {
  final p = day.split('-').map(int.parse).toList();
  final ts = DateTime(p[0], p[1], p[2], 8).millisecondsSinceEpoch ~/ 1000;
  await db.insert('decoded_onehz', {
    'device_id': '',
    'ts_ms': ts * 1000,
    'rec_ts': ts,
    'counter': 1,
    'hr': 60,
  });
  return ts;
}

/// The three rows a refresh writes, as stored (`updated_at` is wall time and
/// is deliberately not read).
Future<Map<String, String?>> p23FreshnessRows(Database db) async {
  final rows = await db.query('compute_freshness',
      where: "key IN ('capture','today','crossday')");
  return {
    for (final key in const ['capture', 'today', 'crossday'])
      key: rows
          .where((r) => r['key'] == key)
          .map((r) => r['payload_json'] as String?)
          .firstOrNull,
  };
}

/// Every scenario the parity golden covers: name -> seed. Each runs on a fresh
/// database. `raw` is the rec_ts written (tokenised in the golden).
typedef P23Seed = Future<int?> Function(Database db);

Map<String, P23Seed> p23Scenarios() => {
  'empty': (db) async => null,
  'today_complete': (db) async {
    await p23Row(db, p23Day(0), p23Payload(sleep: true, readiness: 80), computedAt: 5000, readinessColumn: 80);
    return null;
  },
  'prior_overnight': (db) async {
    await p23Row(db, p23Day(0), p23Payload(), computedAt: 5000);
    await p23Row(db, p23Day(1), p23Payload(sleep: true), computedAt: 4000, readinessColumn: 70);
    await p23Row(db, p23Day(2), p23Payload(sleep: true), computedAt: 3000);
    return null;
  },
  'skipped_days_ignored': (db) async {
    await p23Row(db, p23Day(0), p23Payload(), computedAt: 5000);
    await p23Row(db, p23Day(1), p23Payload(sleep: true, readiness: 90, skipped: true), computedAt: 4000, readinessColumn: 90);
    await p23Row(db, p23Day(2), p23Payload(sleep: true), computedAt: 3000);
    return null;
  },
  'today_skipped_still_today_row': (db) async {
    await p23Row(db, p23Day(0), p23Payload(sleep: true, skipped: true), computedAt: 5000);
    await p23Row(db, p23Day(1), p23Payload(sleep: true, readiness: 61), computedAt: 4000);
    return null;
  },
  'no_sleep_flag': (db) async {
    await p23Row(db, p23Day(0), p23Payload(), computedAt: 5000);
    await p23Row(db, p23Day(1), p23Payload(flags: ['NO_SLEEP_DETECTED']), computedAt: 4000);
    await p23Row(db, p23Day(2), p23Payload(sleep: true), computedAt: 3000);
    return null;
  },
  'flags_not_a_list': (db) async {
    await p23Row(db, p23Day(1), p23Payload(flags: 'NO_SLEEP_DETECTED'), computedAt: 4000);
    await p23Row(db, p23Day(2), p23Payload(sleep: true, tst: null), computedAt: 3000);
    await p23Row(db, p23Day(3), p23Payload(sleep: true), computedAt: 2000);
    return null;
  },
  'recovery_from_scalar_only': (db) async {
    await p23Row(db, p23Day(1), p23Payload(readiness: 55), computedAt: 4000);
    await p23Row(db, p23Day(2), p23Payload(sleep: true), computedAt: 3000);
    return null;
  },
  'recovery_from_column_only': (db) async {
    await p23Row(db, p23Day(1), p23Payload(), computedAt: 4000, readinessColumn: 70);
    return null;
  },
  'readiness_not_a_number': (db) async {
    await p23Row(db, p23Day(1), p23Payload(readiness: '77'), computedAt: 4000);
    await p23Row(db, p23Day(2), p23Payload(readiness: 66), computedAt: 3000);
    return null;
  },
  'undecodable_rows': (db) async {
    await p23Row(db, p23Day(0), '{not json', computedAt: 5000, readinessColumn: 40);
    await p23Row(db, p23Day(1), '[1,2]', computedAt: 4000);
    await p23Row(db, p23Day(2), 'null', computedAt: 3000);
    await p23Row(db, p23Day(3), p23Payload(sleep: true), computedAt: 2000);
    return null;
  },
  'raw_reached_today_nothing_derived': (db) async => p23Raw(db, p23Day(0)),
  'raw_only_yesterday': (db) async => p23Raw(db, p23Day(1)),
  'raw_today_with_prior_overnight': (db) async {
    await p23Row(db, p23Day(1), p23Payload(sleep: true), computedAt: 4000);
    return p23Raw(db, p23Day(0));
  },
  'wake_features_only': (db) async {
    await p23Wake(db, p23Day(0), 777);
    return null;
  },
  'today_row_and_wake_features': (db) async {
    await p23Row(db, p23Day(0), p23Payload(), computedAt: 5000);
    await p23Wake(db, p23Day(0), 777);
    return null;
  },
  'crossday_and_rolling': (db) async {
    await p23Row(db, p23Day(1), p23Payload(sleep: true), computedAt: 4000);
    await p21RawBaseline(db, 'rolling', jsonEncode({'k': 1}), updatedAt: 4242);
    await p21RawBaseline(db, 'crossday', jsonEncode({'built_for_day': p23Day(0)}), updatedAt: 4343);
    return null;
  },
  'crossday_without_rolling': (db) async {
    await p21RawBaseline(db, 'crossday', jsonEncode({'k': 1}), updatedAt: 4343);
    return null;
  },
  'older_version_only': (db) async {
    await p23Row(db, p23Day(1), p23Payload(sleep: true), computedAt: 4000, version: p21Version - 1);
    return null;
  },
  'version_above_ceiling_ignored': (db) async {
    await p23Row(db, p23Day(1), p23Payload(sleep: true, readiness: 91), computedAt: 4000, version: p21Version + 1);
    await p23Row(db, p23Day(1), p23Payload(), computedAt: 3900);
    return null;
  },
  'overnight_beyond_the_30_day_window': (db) async {
    await p23Row(db, p23Day(0), p23Payload(), computedAt: 5000);
    for (var i = 1; i <= 34; i++) {
      await p23Row(db, p23Day(i), p23Payload(sleep: i == 33, readiness: i == 31 ? 50 : null), computedAt: 4000 - i);
    }
    return null;
  },
  'thirty_complete_days_early_break': (db) async {
    for (var i = 0; i < 30; i++) {
      await p23Row(db, p23Day(i), p23Payload(sleep: true, readiness: 60.0 + i), computedAt: 5000 - i, readinessColumn: 60.0 + i);
    }
    return null;
  },
};

/// The body of `refreshComputeFreshness` in lib/data/db.dart, comments and
/// string literals stripped (so only identifiers and calls are left).
String p23RefreshBody(String strippedDbSource) {
  final at = strippedDbSource.indexOf('refreshComputeFreshness()');
  final open = strippedDbSource.indexOf('{', at);
  var depth = 0;
  for (var i = open; i < strippedDbSource.length; i++) {
    if (strippedDbSource[i] == '{') depth++;
    if (strippedDbSource[i] == '}' && --depth == 0) {
      return strippedDbSource.substring(open, i + 1);
    }
  }
  throw StateError('refreshComputeFreshness body not found');
}

/// Fake steps that record what the gate does, in order.
class P23Rig implements PublishGateSteps {
  final events = <String>[];
  final logs = <String>[];
  int inFlight = 0;
  int maxInFlight = 0;

  Completer<void>? holdRefresh;
  Completer<void>? holdWarm;
  Object? refreshThrows;
  Object? warmThrows;
  Object? revsThrow;

  /// Successive answers of `servedRevisions`; the last one repeats.
  List<Map<String, int>> revs = [
    {'A': 1, 'B': 1},
  ];
  int _revCalls = 0;

  void Function()? onBump;

  Future<void> _enter(String what) async {
    events.add(what);
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
  }

  @override
  Future<void> refreshFreshness() async {
    await _enter('refresh');
    try {
      await holdRefresh?.future;
      if (refreshThrows != null) throw refreshThrows!;
    } finally {
      inFlight--;
    }
  }

  @override
  Future<Map<String, int>> servedRevisions() async {
    events.add('revs');
    if (revsThrow != null) throw revsThrow!;
    final i = _revCalls < revs.length ? _revCalls : revs.length - 1;
    _revCalls++;
    return revs[i];
  }

  @override
  Future<void> warm(Set<String> ids) async {
    await _enter('warm:${(ids.toList()..sort()).join(',')}');
    try {
      await holdWarm?.future;
      if (warmThrows != null) throw warmThrows!;
    } finally {
      inFlight--;
    }
  }

  @override
  void bump() {
    events.add('bump');
    onBump?.call();
  }

  @override
  void log(String line) => logs.add(line);

  late final PublishGate gate = PublishGate(steps: this);

  int count(String prefix) => events.where((e) => e.startsWith(prefix)).length;
}

class P23Effects implements PublishGateEffects {
  P23Effects({required this.onBump, required this.onLog});

  final void Function() onBump;
  final void Function(String line) onLog;

  @override
  void publishBump() => onBump();

  @override
  void publishLog(String line) => onLog(line);
}
