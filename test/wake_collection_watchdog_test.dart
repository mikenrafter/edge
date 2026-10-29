// The keep-alive tick re-requests the wake-window prompt when prompts stop
// arriving (spec dev-harness §5.1 F1-F5, §9 Part A), driven through the REAL
// AppState and engine with a fake link.
//
// The engine's clock is separate from the app's here: placing the ENTER and
// the prompts in the past is how a test says "the band has been silent for
// N seconds" without waiting.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/calc_power_policy.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/state/alarm_schedule.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/sync/sync_policy.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fake_alarm_engine.dart';
import 'support/fake_power_source.dart';
import 'support/wake_fakes.dart';

bool _isEnter(Uint8List f) {
  final p = parseFrame(f, profile: BandProfile.gen4);
  return p != null && p.valid && p.inner[2] == Cmd.enterHighFreqSync;
}

Uint8List _prompt() {
  final inner = Uint8List(12);
  inner[0] = PacketType.event;
  inner[1] = 0x07;
  ByteData.sublistView(inner)
    ..setUint16(2, EventId.highFreqSyncPrompt, Endian.little)
    ..setUint32(4, 1786000000, Endian.little);
  return inner;
}

/// A band whose prompt write can be made to throw (the refresh-threw case).
class _Band extends FakeAlarmEngine {
  _Band({super.clock});
  Object? throwOnApply;
  int applies = 0;

  @override
  Future<PromptWriteOutcome> applyHighFreqWakeWindow({
    required bool enabled,
    required DateTime? targetWake,
    Duration duration = const Duration(seconds: 7200),
    int intervalSeconds = 180,
    String reason = 'wake_window',
    bool force = false,
    bool Function()? stillCurrent,
  }) {
    applies++;
    final t = throwOnApply;
    if (t != null) throw t;
    return super.applyHighFreqWakeWindow(
      enabled: enabled,
      targetWake: targetWake,
      duration: duration,
      intervalSeconds: intervalSeconds,
      reason: reason,
      force: force,
      stillCurrent: stillCurrent,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Band band;
  late AppState app;
  late FakePowerSource power;
  late DateTime wakeAt;
  late List<Uint8List> frames;
  late Future<bool> Function(Uint8List) onWrite;
  DateTime? bandNow;
  var testNo = 0;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_wake_collection_watchdog_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  Future<void> schedule(DateTime at) async {
    await LocalDb.setAlarmScheduleRows([
      for (var w = 0; w < 7; w++)
        AlarmScheduleEntry(
                weekday: w,
                hour: at.hour,
                minute: at.minute,
                enabled: true,
                smartWindowMinutes: 60,
                naturalWindowMinutes: 60)
            .toRow(),
    ]);
    await app.debugLoadAlarmSchedule();
    await app.debugArmNextAlarmOccurrence();
  }

  /// Inside the Natural window (alarm in ~20 min, window 60), backgrounded,
  /// Android policy path. Each test gets its own wake minute (the wake run
  /// state persists per epoch in the shared database).
  setUp(() async {
    await (await SharedPreferences.getInstance()).clear();
    await LocalDb.clearAlarmSchedule();
    bandNow = null;
    frames = [];
    onWrite = (_) async => true;
    band = _Band(clock: () => bandNow ?? DateTime.now());
    band.debugInstallFakeLink(
        onWrite: (f) {
          frames.add(f);
          return onWrite(f);
        },
        listening: true);
    app = AppState.forTesting(engine: band);
    app.debugSetAlarmGraceMs(20);
    app.debugWakeObserver = ScriptedObserver()..next = stageObs('nrem');
    power = FakePowerSource(charging: false, powerSaver: false);
    app.debugPowerSource = power;
    await app.setCalcPowerMode(CalcPowerMode.balanced);
    await app.debugAttachPower();
    app.debugBackground = true;

    final t = DateTime.now().add(Duration(minutes: 20 + testNo++));
    wakeAt = DateTime(t.year, t.month, t.day, t.hour, t.minute);
    await schedule(wakeAt);
    expect(app.wake.naturalEnabled, isTrue);
  });

  tearDown(() async {
    app.dispose();
    await power.close();
  });

  int enters() => frames.where(_isEnter).length;
  bool requested() => band.offloadSnapshot['high_freq_requested'] == true;

  Future<void> until(bool Function() done, {int ms = 2000}) async {
    for (var i = 0; i < ms ~/ 20 && !done(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 200));

  /// The window's lease as the engine believes it, ENTERed [ago] by the
  /// band's clock, with no prompt since.
  Future<void> believedLease(Duration ago) async {
    bandNow = DateTime.now().subtract(ago);
    await app.debugRefreshHighFreqWakeWindow();
    expect(requested(), isTrue);
    expect(band.highFreqReason, 'scheduled_alarm');
    expect(enters(), 1);
  }

  Future<List<Map<String, Object?>>> collectionRows() async {
    final rows =
        await LocalDb.wakeTraceRows(wakeAt.millisecondsSinceEpoch ~/ 1000);
    return [
      for (final r in rows)
        if (r['kind'] == 'collection')
          jsonDecode(r['data_json'] as String) as Map<String, Object?>,
    ];
  }

  test('the engine believes the lease but no prompt came for 150 s: the next '
      'tick re-ENTERs, and the one after is held by the 2-minute throttle',
      () async {
    await believedLease(const Duration(minutes: 5));
    await app.debugKeepAliveTick();
    await until(() => enters() >= 2);
    expect(enters(), 2,
        reason: '"covered" trusted highFreqUntil while the band was silent');
    await app.debugKeepAliveTick();
    await settle();
    expect(enters(), 2, reason: 'a forced write that landed waits 2 min');
  });

  test('prompts arriving: no re-ENTER', () async {
    await believedLease(const Duration(minutes: 5));
    bandNow = DateTime.now().subtract(const Duration(seconds: 10));
    band.debugReceiveFrame(Frame(_prompt(), true, true), role: 'events');
    expect(band.lastHighFreqPromptAt, isNotNull);
    await app.debugKeepAliveTick();
    await app.debugKeepAliveTick();
    await settle();
    expect(enters(), 1);
  });

  test('outside the collection window a silent lease is not re-ENTERed',
      () async {
    final far = DateTime.now().add(const Duration(hours: 10));
    await schedule(DateTime(far.year, far.month, far.day, far.hour, far.minute));
    bandNow = DateTime.now().subtract(const Duration(minutes: 5));
    await band.applyHighFreqWakeWindow(
        enabled: true,
        targetWake: far,
        duration: const Duration(minutes: 90),
        intervalSeconds: 61,
        reason: 'scheduled_alarm');
    expect(enters(), 1);
    await app.debugKeepAliveTick();
    await settle();
    expect(enters(), 1);
  });

  test('a forced ENTER whose write fails is retried on the very next tick',
      () async {
    await believedLease(const Duration(minutes: 5));
    var attempts = 0;
    onWrite = (f) async {
      if (_isEnter(f)) attempts++;
      return !_isEnter(f);
    };
    await app.debugKeepAliveTick();
    await until(() => attempts >= 1);
    await settle();
    await app.debugKeepAliveTick();
    await until(() => attempts >= 2);
    expect(attempts, 2,
        reason: 'a failed write must not sit out the 2-minute throttle');
    final rows = await collectionRows();
    expect(rows.map((r) => r['outcome']), contains('failed'));
  });

  test('a refresh that throws is traced and retried on the next tick',
      () async {
    band.throwOnApply = StateError('radio gone');
    await app.debugKeepAliveTick();
    await until(() => band.applies >= 1);
    await settle();
    await app.debugKeepAliveTick();
    await until(() => band.applies >= 2);
    expect(band.applies, 2);
    final rows = await collectionRows();
    expect(rows, isNotEmpty);
    expect(rows.first['outcome'], 'failed');
    expect('${rows.first['error']}', contains('radio gone'));
  });

  test('each refresh outcome is traced once per change', () async {
    await believedLease(const Duration(minutes: 5));
    await app.debugKeepAliveTick();
    await until(() => enters() >= 2);
    await settle();
    await app.debugRefreshHighFreqWakeWindow();
    await app.debugRefreshHighFreqWakeWindow();
    final rows = await collectionRows();
    expect([for (final r in rows) '${r['outcome']}/${r['forced']}'],
        ['wrote/false', 'wrote/true', 'unchanged/false']);
    expect(rows.first['source'], 'scheduled_alarm');
    expect(rows.first['enter'], isTrue);
  });

  test('a run stuck past 60 s is superseded; when it finally completes it '
      'claims nothing', () async {
    final gate = Completer<bool>();
    addTearDown(() {
      if (!gate.isCompleted) gate.complete(false);
    });
    onWrite = (f) => _isEnter(f) ? gate.future : Future.value(true);
    final stuck = app.debugRefreshHighFreqWakeWindow();
    await until(() => enters() >= 1);
    expect(enters(), 1, reason: 'the old ENTER is on the wire');

    // The alarm moves out of reach: the newer request wants no prompt.
    final far = DateTime.now().add(const Duration(hours: 10));
    await schedule(DateTime(far.year, far.month, far.day, far.hour, far.minute));
    final newer = withClock(
        Clock.fixed(DateTime.now().add(const Duration(seconds: 61))),
        () => app.debugRefreshHighFreqWakeWindow());
    var newerDone = false;
    await newer.timeout(const Duration(seconds: 2), onTimeout: () {
      fail('a refresh hung for more than 60 s still blocks every later one');
    }).then((_) => newerDone = true);
    expect(newerDone, isTrue);

    gate.complete(true);
    await stuck;
    await settle();
    expect(requested(), isFalse,
        reason: 'the superseded ENTER must not claim the mode');
    expect(band.highFreqReason, isNull);
  });
}
