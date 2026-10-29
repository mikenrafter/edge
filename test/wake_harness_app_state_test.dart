// The wake harness at the production entry (Sol code r1 #7): a real AppState,
// stored prefs, seeded 1 Hz rows and a baseline night, driven by the 30 s
// keep-alive tick. Removing AppState's harness wiring must turn these red.
//
// Evidence: recent HR 54 bpm, still wrist, preceding night minimum 50 bpm, so
// production legacy fires at its +4 bpm default and holds at +5.
// Real time: the orchestrator reads the wall clock, so this suite does too.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/notify/notification_center.dart';
import 'package:openstrap_edge/notify/notification_event.dart';
import 'package:openstrap_edge/state/alarm_schedule.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/sync/headless_gate.dart';
import 'package:openstrap_edge/state/control_operations.dart'
    show ExpectedSleepSchedule;
import 'package:openstrap_edge/wake/natural_wake.dart';
import 'package:openstrap_edge/wake/wake_harness.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fake_alarm_engine.dart';
import 'support/wake_fakes.dart';

class _Band extends FakeAlarmEngine {
  int buzzes = 0;
  @override
  Future<void> runAlarm() async {
    buzzes++;
  }
}

int _sec(DateTime t) => t.millisecondsSinceEpoch ~/ 1000;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Directory? dir;
  late _Band band;
  late AppState app;
  late DateTime wakeAt;
  final apps = <AppState>[];

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    NotificationCenter.instance.presentSink =
        (NotificationEvent e, {bool allowPermissionPrompt = true}) async => true;
  });
  Future<void> shutDown() async {
    for (final a in apps) {
      a.dispose();
    }
    apps.clear();
    await LocalDb.close();
    await dir?.delete(recursive: true);
    dir = null;
  }

  tearDown(shutDown);

  /// One occurrence [ahead] from now, its Natural window [natural] and old
  /// Smart window [smart] (minutes), the stored harness and developer mode.
  Future<void> boot({
    Map<String, Object?>? harness,
    bool dev = true,
    int natural = 60,
    int smart = 15,
    bool upgradePending = false,
    Duration ahead = const Duration(minutes: 20),
    NaturalStageObserverStub? stage,
  }) async {
    await shutDown();
    // Prefs caches one SharedPreferences instance: rewrite that one.
    final sp = await SharedPreferences.getInstance();
    await sp.clear();
    await sp.setBool(Prefs.devMode, dev);
    if (harness != null) {
      await sp.setString(kWakeHarnessPrefKey, jsonEncode(harness));
    }
    HeadlessSyncGate.resetForTest();
    dir = await Directory.systemTemp.createTemp('wake_harness_app_');
    LocalDb.dbName = '${dir!.path}/harness.db';
    final db = await LocalDb.instance;
    final now = DateTime.now();
    final w = now.add(ahead);
    wakeAt = DateTime(w.year, w.month, w.day, w.hour, w.minute);
    band = _Band()
      ..debugInstallFakeLink(onWrite: (_) async => true, listening: true);
    band.state.generation = 'gen4';
    app = AppState.forTesting(engine: band);
    apps.add(app);
    app.debugSetAlarmGraceMs(20);
    app.debugWakeObserver = ScriptedObserver()
      ..next = stage?.obs ?? stageObs('nrem');
    app.debugBackground = false;
    if (upgradePending) {
      await LocalDb.wakeMetaSet('upgrade_explanation', 'pending');
      await app.wake.reload();
    }
    await LocalDb.setAlarmScheduleRows([
      for (var d = 0; d < 7; d++)
        AlarmScheduleEntry(
          weekday: d,
          hour: wakeAt.hour,
          minute: wakeAt.minute,
          enabled: true,
          smartWindowMinutes: smart,
          naturalWindowMinutes: natural,
        ).toRow(),
    ]);
    await app.debugLoadAlarmSchedule();
    await app.debugArmNextAlarmOccurrence();
    expect(app.alarmEpoch, _sec(wakeAt), reason: 'precondition: T is armed');
    final wakeMin = wakeAt.hour * 60 + wakeAt.minute;
    app.sleepOperations.schedule = ExpectedSleepSchedule(
      onsetMinute: (wakeMin - 8 * 60) % 1440,
      wakeMinute: wakeMin,
    );
    final nightEnd = wakeAt.subtract(const Duration(hours: 24));
    await db.insert('day_result', {
      'day_id': 'baseline',
      'algo_version': 117,
      'computed_at': 0,
      'finalized': 1,
      'partial': 0,
      'skipped': 0,
      'window_json': jsonEncode({
        'value': {
          'onset_ms': nightEnd
              .subtract(const Duration(hours: 8))
              .millisecondsSinceEpoch,
          'offset_ms': nightEnd.millisecondsSinceEpoch,
        },
      }),
      'payload_json': jsonEncode({
        'scalars': {'hr_min_night': 50},
      }),
    });
    final batch = db.batch();
    final nowSec = _sec(now);
    for (var s = 0; s < 300; s++) {
      final ts = nowSec - 300 + s;
      batch.insert('decoded_onehz', {
        'device_id': '',
        'ts_ms': ts * 1000,
        'rec_ts': ts,
        'counter': s,
        'hr': 54,
        'ax': 0.0,
        'ay': 0.0,
        'az': 1.0,
      });
    }
    await batch.commit(noResult: true);
  }

  Future<List<Map<String, Object?>>> trace(String kind) async => [
    for (final r in await LocalDb.wakeTraceRows(_sec(wakeAt)))
      if (r['kind'] == kind)
        jsonDecode(r['data_json'] as String) as Map<String, Object?>,
  ];

  group('legacy override', () {
    test('the stored HR rise flips fire/hold on the Natural window (T-20 is '
        'outside the old 15 min Smart window)', () async {
      await boot(harness: {'rule': 'legacy'});
      await app.debugKeepAliveTick();
      expect(band.buzzes, 1, reason: 'legacy fires at +4 on the Natural window');
      expect((await trace('harness')).single['rule'], 'legacy');

      await boot(harness: {'rule': 'legacy', 'hrRiseBpm': 5});
      await app.debugKeepAliveTick();
      expect(band.buzzes, 0, reason: '+4 cannot meet the stored +5');
      final rec = (await trace('harness')).single;
      expect((rec['effective'] as Map)['hrRiseBpm'], 5);
      expect((rec['effective'] as Map)['windowMinutes'], 60);
    });

    test('Natural is suppressed: it would fire, legacy holds, nothing buzzes',
        () async {
      final stored = {'rule': 'legacy', 'hrRiseBpm': 15};
      await boot(harness: stored, stage: NaturalStageObserverStub.wake);
      await app.debugKeepAliveTick();
      expect(band.buzzes, 0);
      expect((await trace('natural')).map((e) => e['reason']),
          isNot(contains('fire')));
      expect(await trace('harness'), hasLength(1));
    });

    test('runs on the Natural window while the upgrade explanation is pending',
        () async {
      await boot(upgradePending: true);
      await app.debugKeepAliveTick();
      expect(band.buzzes, 0,
          reason: "control: today's legacy route uses the 15 min window");
      await boot(harness: {'rule': 'legacy'}, upgradePending: true);
      await app.debugKeepAliveTick();
      expect(band.buzzes, 1);
    });

    test('with no Natural window it uses the Smart window and still records '
        'provenance before evaluating', () async {
      await boot(harness: {'rule': 'legacy', 'hrRiseBpm': 5},
          natural: 0, smart: 60);
      await app.debugKeepAliveTick();
      expect(band.buzzes, 0);
      expect(await trace('harness'), hasLength(1));
      final rec = (await trace('harness')).single;
      expect(rec['rule'], 'legacy');
      expect((rec['effective'] as Map)['windowMinutes'], 60);
    });
  });

  group('developer mode off: identical to no harness', () {
    test('Natural fires, nothing is recorded, the stored legacy is ignored',
        () async {
      await boot(stage: NaturalStageObserverStub.wake);
      await app.debugKeepAliveTick();
      final plain = await trace('natural');
      expect(plain.map((e) => e['reason']), contains('fire'),
          reason: 'control');
      await boot(
        dev: false,
        harness: {'rule': 'legacy', 'hrRiseBpm': 15},
        stage: NaturalStageObserverStub.wake,
      );
      await app.debugKeepAliveTick();
      expect((await trace('natural')).map((e) => e['reason']),
          plain.map((e) => e['reason']));
      expect(band.buzzes, greaterThan(0));
      expect(await trace('harness'), isEmpty);
    });
  });

  group('hybrid at the tick', () {
    test('production legacy decides, the live stage vetoes, the coefficient '
        'flips it', () async {
      await boot(harness: {'rule': 'hybrid'}, stage: NaturalStageObserverStub.rem);
      await app.debugKeepAliveTick();
      expect((await trace('natural')).last['reason'], 'fire');

      await boot(harness: {'rule': 'hybrid'}, stage: NaturalStageObserverStub.nrem);
      await app.debugKeepAliveTick();
      expect((await trace('natural')).last['reason'], 'noRemCandidate');
      expect(band.buzzes, 0);

      await boot(
          harness: {'rule': 'hybrid', 'hrRiseBpm': 5},
          stage: NaturalStageObserverStub.rem);
      await app.debugKeepAliveTick();
      expect((await trace('natural')).last['reason'], 'legacyHold');
      expect(band.buzzes, 0);
      expect(((await trace('harness')).single['effective'] as Map)['hrRiseBpm'],
          5);
    });

    test("on the legacy route hybrid is unavailable: today's routing, no "
        'substituted record', () async {
      await boot(
        harness: {'rule': 'hybrid', 'hrRiseBpm': 5},
        upgradePending: true,
        ahead: const Duration(minutes: 10),
      );
      expect(app.wakeHybridUnavailable, isTrue);
      await app.debugKeepAliveTick();
      expect(band.buzzes, 1, reason: 'the old Smart Wake runs as it would');
      expect(await trace('harness'), isEmpty);
    });
  });
}

/// The scripted live stage for a test.
enum NaturalStageObserverStub {
  wake,
  rem,
  nrem;

  NaturalObservation get obs => switch (this) {
    wake => stageObs('wake'),
    rem => remObs(),
    nrem => stageObs('nrem', confidence: 0.6),
  };
}
