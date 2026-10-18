// Shared helpers for the DeriveCoordinator tests. Everything here
// goes through AppState's public and @visibleForTesting surface, so the same
// file serves the AppState-level tests and the coordinator's own tests.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'dart:io';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/notify/notification_center.dart';
import 'package:openstrap_edge/notify/notification_event.dart';

/// Point LocalDb at an empty file called [name] and reset prefs.
Future<void> deriveDbSetUp(String name) async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  await LocalDb.close();
  LocalDb.dbName = name;
  await _deleteDbFiles(name);
  SharedPreferences.setMockInitialValues({});
}

Future<void> deriveDbTearDown(String name) async {
  await LocalDb.close();
  await _deleteDbFiles(name);
}

/// Polls until [ok]; fails the test, naming [what], if [within] runs out.
Future<void> until(bool Function() ok,
    {Duration within = const Duration(seconds: 4), String? what}) async {
  final end = DateTime.now().add(within);
  while (!ok()) {
    if (!DateTime.now().isBefore(end)) {
      throw TestFailure('until(${what ?? 'condition'}) was not met within '
          '${within.inMilliseconds} ms');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Future<void> settleMs([int ms = 150]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

/// What the engine hook was asked.
class HookCall {
  HookCall(this.heavy, this.changedOnly);
  final bool heavy;
  final bool changedOnly;
  @override
  String toString() => 'HookCall(heavy: $heavy, changedOnly: $changedOnly)';
}

/// A derive hook that records its flags, reports [days] the way the engine does
/// (scope, scope days, each day done) and returns [returns] (default: the day
/// count). [scope] overrides the total reported through onScope; [gate] holds
/// the pass after the first [holdAfter] days; [throws] throws before anything is
/// reported.
DeriveRunHook deriveHook({
  List<String> days = const [],
  int? scope,
  int? returns,
  Object? throws,
  List<HookCall>? calls,
  Completer<void>? gate,
  int holdAfter = 0,
  bool reportScope = true,
}) =>
    ({
      required heavy,
      required changedOnly,
      onScope,
      onScopeDays,
      onDayDone,
      onCrossDay,
    }) async {
      calls?.add(HookCall(heavy, changedOnly));
      if (throws != null) throw throws;
      if (reportScope) {
        onScope?.call(scope ?? days.length);
        onScopeDays?.call(days);
      }
      for (var i = 0; i < days.length; i++) {
        if (gate != null && i == holdAfter) await gate.future;
        onDayDone?.call(days[i], i + 1, days.length);
      }
      if (gate != null && holdAfter >= days.length) await gate.future;
      return returns ?? days.length;
    };

/// Counts every notifyListeners tick of [app] from now on.
class TickCounter {
  TickCounter(this.app) {
    app.addListener(_tick);
  }
  final AppState app;
  int ticks = 0;
  void _tick() => ticks++;
  void stop() => app.removeListener(_tick);
}

/// Every value insightsRevision takes after construction.
class RevisionLog {
  RevisionLog(this.app) {
    app.insightsRevision.addListener(_on);
  }
  final AppState app;
  final seen = <int>[];
  int get bumps => seen.length;
  void _on() => seen.add(app.insightsRevision.value);
  void stop() => app.insightsRevision.removeListener(_on);
}

/// A repo whose rescoreRecentSessions answers [fixed] and counts the calls.
class RescoreRepo extends LocalRepository {
  RescoreRepo({this.fixed = 0, this.throwsOnRescore = false});
  int fixed;
  bool throwsOnRescore;
  int rescoreCalls = 0;

  @override
  Future<int> rescoreRecentSessions({int sinceDays = 3}) async {
    rescoreCalls++;
    if (throwsOnRescore) throw StateError('rescore failed');
    return fixed;
  }

  @override
  Future<Map<String, dynamic>> getToday() async => const {};
}

/// Answers the battery_plus method channel and counts the state reads. [state]
/// is the platform string ('charging', 'discharging', 'full', 'unknown').
class BatteryChannel {
  BatteryChannel(this.state) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      if (call.method == 'getBatteryState') {
        stateReads++;
        return state;
      }
      return null;
    });
  }
  static const _channel = MethodChannel('dev.fluttercommunity.plus/battery');
  String state;
  int stateReads = 0;
  void close() => TestDefaultBinaryMessengerBinding
      .instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, null);
}

/// Wraps a body in a zone that tracks every Timer created in it, so a test can
/// assert none is still live. Periodic timers count until cancelled.
class TimerSpy {
  final live = <_SpyTimer>{};
  int created = 0;

  ZoneSpecification get spec => ZoneSpecification(
        createTimer: (self, parent, zone, d, f) {
          created++;
          late final _SpyTimer t;
          final real = parent.createTimer(zone, d, () {
            live.remove(t);
            f();
          });
          t = _SpyTimer(real, live);
          live.add(t);
          return t;
        },
        createPeriodicTimer: (self, parent, zone, d, f) {
          created++;
          late final _SpyTimer t;
          final real = parent.createPeriodicTimer(zone, d, (_) => f(t));
          t = _SpyTimer(real, live);
          live.add(t);
          return t;
        },
      );

  Future<T> run<T>(Future<T> Function() body) =>
      runZoned(body, zoneSpecification: spec);
}

class _SpyTimer implements Timer {
  _SpyTimer(this._inner, this._live);
  final Timer _inner;
  final Set<_SpyTimer> _live;
  @override
  void cancel() {
    _inner.cancel();
    _live.remove(this);
  }

  @override
  bool get isActive => _inner.isActive;
  @override
  int get tick => _inner.tick;
}

// ── from upstream's copy of this harness (merge: union of both sides) ──

/// The database file and the WAL/shared-memory files a crashed run can leave
/// behind (a stale pair beside a fresh file makes SQLite crash on open).
Future<void> _deleteDbFiles(String name) async {
  final path = p.join(await databaseFactory.getDatabasesPath(), name);
  await databaseFactory.deleteDatabase(path);
  for (final suffix in ['-wal', '-shm', '-journal']) {
    final f = File('$path$suffix');
    if (f.existsSync()) f.deleteSync();
  }
}

/// Empty the tables a derive test fills, and reset prefs, without closing the
/// database (a close under the scheduler's tail work is not safe).
Future<void> deriveDbReset() async {
  SharedPreferences.setMockInitialValues({});
  final db = await LocalDb.instance;
  for (final t in ['compute_jobs', 'day_result', 'notif_fired', 'notif_slots']) {
    await db.delete(t);
  }
}

/// Everything one AppState emits, in order: `t` for each notifyListeners tick
/// and `r` for each insightsRevision change, so a test can pin the interleaving.
class SignalLog {
  SignalLog(this.app) {
    app.addListener(_tick);
    app.insightsRevision.addListener(_rev);
  }
  final AppState app;
  final events = <String>[];
  int get ticks => events.where((e) => e == 't').length;
  int get revisions => events.where((e) => e == 'r').length;
  void _tick() => events.add('t');
  void _rev() => events.add('r');
  void stop() {
    app.removeListener(_tick);
    app.insightsRevision.removeListener(_rev);
  }
}

/// Captures what reaches the OS notification sink and restores the real sink
/// when the test ends. Quiet hours are off so the outcome does not depend on
/// the wall clock.
class RecoverySink {
  RecoverySink() {
    _original = NotificationCenter.instance.presentSink;
    NotificationCenter.instance.presentSink = (e,
        {bool allowPermissionPrompt = true}) async {
      shown.add(e.dedupeKey);
      return true;
    };
    SharedPreferences.setMockInitialValues({'notif_quiet_enabled': false});
  }
  late final Future<bool> Function(NotificationEvent e,
      {bool allowPermissionPrompt}) _original;
  final shown = <String>[];
  String get todayKey => '${todayLabel()}:recovery_ready';
  void restore() => NotificationCenter.instance.presentSink = _original;
}

/// Writes today's day_result with a computed readiness, the row the
/// recovery-ready check reads. [payloadJson] decides whether the night counts
/// as settled.
Future<void> putTodayReadiness({
  double readiness = 80,
  String payloadJson = '{}',
}) =>
    LocalDb.putDayResult(
      dayId: todayLabel(),
      algoVersion: kAlgoVersion,
      payloadJson: payloadJson,
      windowJson: '{}',
      readiness: readiness,
    );
