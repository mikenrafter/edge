// Wake-confirmation WIRING (phase 1, ALL RED). The pure rule
// (`confirmedWakeSec`), the recorder (`WakeConfirmationRecorder`) and the DB
// record (`LocalDb.putWakeConfirmation` ...) exist and are pinned by
// test/sleep_block_finalization_test.dart against an in-memory fake store.
// Nothing feeds them yet. This file pins every source (AGENTS 4.7: every call
// site, not one) and the persistence behind them:
//
//  1. `DbWakeConfirmationStore` (lib/wake/wake_stores.dart): onset of the block
//     in progress / just ended, evidence that survives a restart, the
//     confirmation written under the WAKE-DAY label (data/day_label.dart) with
//     the basis strings movement / alarm_fired / alarm_acknowledged /
//     natural_wake.
//  2. `WakeOrchestrator(onNaturalFired:)`: Natural Wake fired, foreground tick
//     and headless `tickThroughGate` alike.
//  3. AppState: app opened (`noteAppOpened`), the movement check
//     (`debugCheckWakeMovement`, also what a fresh touch triggers), the strap's
//     alarm fired events 57/58 (noted BEFORE the stale-replay filter: the
//     alarm books ignore a replayed event, the evidence must not), the "I'm
//     up" acknowledgement, Natural Wake fired; and a derive of the wake day
//     when a note completes the confirmation (`debugDeriveDays`).
//  4. Headless: `handleHeadlessAlarmEvent(id, tsEpoch:)` notes alarm fired from
//     the event's own stamp and returns the confirmed moment.
//  5. Source guards for call sites a unit test cannot drive (the lifecycle
//     hook in lib/app.dart, the headless onEvent in background_sync.dart).
//  6. End to end: open app + alarm fired -> the night is final, re-scored at
//     the confirmation, and a later sync does not move it.
//
// STUBS this phase adds (all throw `UnimplementedError` unless noted):
//   * `DbWakeConfirmationStore({DateTime Function()? now})` and its 5 methods
//     (lib/wake/wake_stores.dart);
//   * `AppState.noteAppOpened({DateTime? at})`, `debugCheckWakeMovement()`,
//     `debugWakeSignalsSettled()` (lib/state/app_state.dart);
//   * `AppState.debugWakeClock`, `AppState.debugDeriveDays` (plain settable
//     fields, ignored);
//   * `WakeOrchestrator(onNaturalFired:)` (accepted, ignored);
//   * `handleHeadlessAlarmEvent(int id, {int? tsEpoch})` now returns
//     `Future<int?>` (tsEpoch ignored, returns null).
//
// NOT pinned: that the headless pass re-derives the night once its own note
// completed the confirmation (needs the whole BLE drain harness); the
// lifecycle `resumed` -> noteAppOpened and the headless onEvent -> tsEpoch
// hops are source guards only.
@Timeout(Duration(minutes: 10))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/gestures/strap_event.dart';
import 'package:openstrap_edge/notify/notification_center.dart';
import 'package:openstrap_edge/notify/notification_event.dart';
import 'package:openstrap_edge/state/alarm_schedule.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/sync/background_sync.dart';
import 'package:openstrap_edge/sync/headless_gate.dart';
import 'package:openstrap_edge/wake/wake_confirmation.dart';
import 'package:openstrap_edge/wake/wake_orchestrator.dart';
import 'package:openstrap_edge/wake/wake_stores.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/dart_source_lexical.dart';
import 'support/fake_alarm_engine.dart';
import 'support/fake_power_source.dart';
import 'support/wake_fakes.dart';

const _dbName = 'openstrap_wake_confirmation_wiring_test.db';

String _window(DateTime onset, DateTime? offset) => jsonEncode({
      'value': {
        'onset_ms': onset.millisecondsSinceEpoch,
        if (offset != null) 'offset_ms': offset.millisecondsSinceEpoch,
      },
    });

int _sec(DateTime t) => t.millisecondsSinceEpoch ~/ 1000;

/// A stored night window under [dayId] (the day of its wake).
Future<void> _putWindow(DateTime onset, DateTime? offset, {String? dayId}) =>
    LocalDb.putDayResult(
      dayId: dayId ?? dayLabelOf(offset ?? onset),
      algoVersion: 1,
      payloadJson: '{}',
      windowJson: _window(onset, offset),
    );

Future<void> _wipe() async {
  await LocalDb.close();
  final dir = await databaseFactory.getDatabasesPath();
  await databaseFactory.deleteDatabase(p.join(dir, _dbName));
}

/// Feeds one strap alarm event and lets its fire-and-forget fired notification
/// finish (it touches the database, which the next test replaces).
Future<void> _feed(AppState app, int id, {required int ts}) async {
  app.debugHandleAlarmEvent(id, ts: ts);
  await Future<void>.delayed(const Duration(milliseconds: 30));
}

String _codeOf(String path, String signature) =>
    codeOnly(bodyOf(File(path).readAsStringSync(), signature));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = _dbName;
    // Never reach the OS for a "your alarm fired" notification.
    NotificationCenter.instance.presentSink =
        (NotificationEvent e, {bool allowPermissionPrompt = true}) async => true;
  });

  setUp(() async {
    await _wipe();
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
    HeadlessSyncGate.resetForTest();
  });
  tearDownAll(_wipe);

  // ── 1. the DB-backed store ────────────────────────────────────────────────

  group('DbWakeConfirmationStore', () {
    // A fixed night: asleep 22:30 on the 6th, up at 06:40 on the 7th.
    final onset = DateTime(2026, 10, 6, 22, 30);
    final offset = DateTime(2026, 10, 7, 6, 40);
    DateTime at(Duration after) => offset.add(after);
    DbWakeConfirmationStore storeAt(DateTime now) =>
        DbWakeConfirmationStore(now: () => now);

    test('no stored night: no block, nothing to confirm', () async {
      expect(await storeAt(offset).sleepOnsetSec(), isNull);
      expect(await storeAt(offset).confirmedWakeSec(), isNull);
      expect(await storeAt(offset).evidence(), isEmpty);
    });

    test('the onset is the stored window\'s, for a block that just ended',
        () async {
      await _putWindow(onset, offset);
      expect(await storeAt(at(const Duration(minutes: 40))).sleepOnsetSec(),
          _sec(onset));
      expect(await storeAt(at(const Duration(hours: 3))).sleepOnsetSec(),
          _sec(onset),
          reason: 'woke at 06:40, the app is first opened at 09:40');
    });

    test('a block still open (no offset yet) is the block in progress', () async {
      await _putWindow(onset, null, dayId: dayLabelOf(offset));
      expect(await storeAt(at(const Duration(minutes: 10))).sleepOnsetSec(),
          _sec(onset));
    });

    test('a night that ended a day ago is over: no block to confirm', () async {
      await _putWindow(onset, offset);
      expect(await storeAt(at(const Duration(hours: 20))).sleepOnsetSec(), isNull,
          reason: 'confirming it now would put a wake in an unrelated day');
    });

    test('the newest night wins over an older one', () async {
      await _putWindow(onset.subtract(const Duration(days: 1)),
          offset.subtract(const Duration(days: 1)));
      await _putWindow(onset, offset);
      expect(await storeAt(at(const Duration(minutes: 5))).sleepOnsetSec(),
          _sec(onset));
    });

    test('an unusable window (no sleep: the em dash) is not a block', () async {
      await LocalDb.putDayResult(
        dayId: dayLabelOf(offset),
        algoVersion: 1,
        payloadJson: '{}',
        windowJson: jsonEncode({'value': '—'}),
      );
      expect(await storeAt(at(const Duration(minutes: 5))).sleepOnsetSec(), isNull);
    });

    test('evidence persists: a new instance (a new process) reads it', () async {
      await _putWindow(onset, offset);
      final now = at(const Duration(minutes: 5));
      final first = storeAt(now);
      await first.addEvidence(WakeEvidenceKind.alarmFired, _sec(offset) - 60);
      await first.addEvidence(WakeEvidenceKind.appOpened, _sec(offset) + 30);
      final second = storeAt(now);
      expect(await second.evidence(), [
        (kind: WakeEvidenceKind.alarmFired, sec: _sec(offset) - 60),
        (kind: WakeEvidenceKind.appOpened, sec: _sec(offset) + 30),
      ]);
    });

    test('evidence belongs to its block: the next block starts empty', () async {
      await _putWindow(onset, offset);
      final now = at(const Duration(minutes: 5));
      await storeAt(now).addEvidence(WakeEvidenceKind.alarmFired, _sec(offset));
      expect(await storeAt(now).evidence(), hasLength(1));
      // Back to bed at 14:00, a new block: the morning's alarm is not its.
      final nap = DateTime(2026, 10, 7, 14, 0);
      await _putWindow(nap, null, dayId: dayLabelOf(nap));
      final later = DateTime(2026, 10, 7, 14, 30);
      expect(await storeAt(later).sleepOnsetSec(), _sec(nap));
      expect(await storeAt(later).evidence(), isEmpty);
    });

    test('confirmWake stores the moment under the wake-day label, with the '
        'basis string, for each kind', () async {
      const wire = {
        WakeEvidenceKind.bandMovement: 'movement',
        WakeEvidenceKind.alarmFired: 'alarm_fired',
        WakeEvidenceKind.alarmAcknowledged: 'alarm_acknowledged',
        WakeEvidenceKind.naturalWake: 'natural_wake',
      };
      var i = 0;
      for (final e in wire.entries) {
        // A distinct night per kind (the first confirmation of a night stands).
        final shift = Duration(days: 30 + i++);
        final o = onset.add(shift), w = offset.add(shift);
        await _putWindow(o, w);
        final store = storeAt(w.add(const Duration(minutes: 5)));
        final moment = _sec(w) + 120;
        expect(await store.confirmedWakeSec(), isNull, reason: '${e.key}');
        await store.confirmWake(moment, basis: e.key);
        final row = await LocalDb.wakeConfirmation(dayLabelOf(w));
        expect(row, isNotNull, reason: '${e.key}');
        expect(row!.atSec, moment, reason: '${e.key}');
        expect(row.basis, e.value, reason: '${e.key}');
        expect(await store.confirmedWakeSec(), moment, reason: '${e.key}');
        expect(await storeAt(w.add(const Duration(minutes: 9))).confirmedWakeSec(),
            moment,
            reason: 'a new instance reads it');
      }
    });

    test('the label is the WAKE day, not the day the sleep began', () async {
      await _putWindow(onset, offset); // began on the 6th, woke on the 7th
      final store = storeAt(at(const Duration(minutes: 5)));
      await store.confirmWake(_sec(offset) + 60,
          basis: WakeEvidenceKind.bandMovement);
      expect(await LocalDb.wakeConfirmation(dayLabelOf(offset)), isNotNull);
      expect(await LocalDb.wakeConfirmation(dayLabelOf(onset)), isNull);
    });

    test('the first confirmation stands', () async {
      await _putWindow(onset, offset);
      final store = storeAt(at(const Duration(minutes: 5)));
      await store.confirmWake(_sec(offset) + 60,
          basis: WakeEvidenceKind.bandMovement);
      await store.confirmWake(_sec(offset) + 600,
          basis: WakeEvidenceKind.alarmFired);
      expect(await store.confirmedWakeSec(), _sec(offset) + 60);
      expect((await LocalDb.wakeConfirmation(dayLabelOf(offset)))!.basis,
          'movement');
    });

    test('with the recorder: an alarm that fired while the app was dead still '
        'counts after a relaunch', () async {
      await _putWindow(onset, offset);
      final now = at(const Duration(hours: 1));
      // Process 1 (headless): the alarm fires at 06:40.
      await WakeConfirmationRecorder(storeAt(now))
          .note(WakeEvidenceKind.alarmFired, offset);
      // Process 2 (the user opens the app at 07:40): a new store, a new recorder.
      final moment = await WakeConfirmationRecorder(storeAt(now))
          .note(WakeEvidenceKind.appOpened, now);
      expect(moment, _sec(now));
      final row = (await LocalDb.wakeConfirmation(dayLabelOf(offset)))!;
      expect(row.atSec, _sec(now));
      expect(row.basis, 'alarm_fired');
    });
  });

  // ── 2. the orchestrator hook ──────────────────────────────────────────────

  group('WakeOrchestrator.onNaturalFired', () {
    final t = DateTime(2026, 10, 5, 7, 0);
    late TestClock clock;
    late FakeWakeEnv env;
    late ScriptedObserver observer;
    late MemoryWakeStateStore state;
    late List<DateTime> fired;
    late WakeOrchestrator orchestrator;

    WakeOrchestrator build({Future<void> Function(DateTime)? onFired}) =>
        WakeOrchestrator(
          env: env,
          observer: observer,
          stateStore: state,
          traceStore: MemoryWakeTraceStore(),
          now: clock.call,
          onNaturalFired: onFired ??
              (at) async {
                fired.add(at);
              },
        );

    setUp(() {
      clock = TestClock(t.subtract(const Duration(minutes: 40)));
      env = FakeWakeEnv()..armedEpochSec = _sec(t);
      observer = ScriptedObserver();
      state = MemoryWakeStateStore();
      fired = [];
      orchestrator = build();
    });

    test('is told once, with the tick\'s own time, when the early haptic fires',
        () async {
      final out = await orchestrator.tick(planFor(t, natural: 60));
      expect(out.naturalFired, isTrue);
      expect(fired, [clock.now]);
      clock.advance(const Duration(seconds: 30));
      await orchestrator.tick(planFor(t, natural: 60));
      expect(fired, hasLength(1), reason: 'once per occurrence');
    });

    /// A different occurrence (a day later) that DOES fire: the hook is wired,
    /// so an empty list above means "not for that tick", not "never".
    Future<void> controlFires() async {
      final t2 = t.add(const Duration(days: 1));
      clock.at(t2.subtract(const Duration(minutes: 40)));
      env.armedEpochSec = _sec(t2);
      env.hapticResult = const WakeHapticResult(delivered: ['band']);
      observer.next = remObs();
      final before = fired.length;
      final out = await orchestrator.tick(planFor(t2, natural: 60));
      expect(out.naturalFired, isTrue);
      expect(fired.length, before + 1, reason: 'the control occurrence fired');
    }

    test('is not called when Natural abstains', () async {
      observer.next = stageObs('nrem'); // light sleep: no wake
      final out = await orchestrator.tick(planFor(t, natural: 60));
      expect(out.naturalFired, isFalse);
      expect(fired, isEmpty);
      await controlFires();
    });

    test('is not called for Gradual steps', () async {
      clock.at(t.subtract(const Duration(minutes: 5)));
      final out = await orchestrator.tick(planFor(t, gradual: 15));
      expect(out.gradualStepFired, isNotNull);
      expect(fired, isEmpty);
      await controlFires();
    });

    test('is not called when the user already acknowledged', () async {
      await orchestrator.acknowledge(planFor(t, natural: 60));
      await orchestrator.tick(planFor(t, natural: 60));
      expect(env.haptics, isEmpty);
      expect(fired, isEmpty);
      await controlFires();
    });

    test('is not called for a buzz that was not delivered (it woke nobody, '
        'so it is no evidence)', () async {
      env.hapticResult = const WakeHapticResult(error: 'no link');
      await orchestrator.tick(planFor(t, natural: 60));
      expect(env.haptics, hasLength(1), reason: 'the attempt happened');
      expect(fired, isEmpty);
      await controlFires();
    });

    test('is not called for a buzz the environment held back (a band with no '
        'alert transport delivered it to nobody), though the early wake did '
        'fire', () async {
      env.hapticResult = const WakeHapticResult(suppressionReason: 'bandUnavailable');
      final out = await orchestrator.tick(planFor(t, natural: 60));
      expect(env.haptics, hasLength(1), reason: 'the attempt happened');
      expect(out.naturalFired, isTrue, reason: 'the occurrence is spent');
      expect(fired, isEmpty, reason: 'nothing reached the band: no evidence');
      clock.advance(const Duration(seconds: 30));
      await orchestrator.tick(planFor(t, natural: 60));
      expect(env.haptics, hasLength(1), reason: 'and it is not re-sent');
      expect(fired, isEmpty);
      await controlFires();
    });

    test('a callback that throws cannot undo the fire or break the tick',
        () async {
      var calls = 0;
      orchestrator = build(onFired: (_) async {
        calls++;
        throw StateError('db is gone');
      });
      final out = await orchestrator.tick(planFor(t, natural: 60));
      expect(calls, 1, reason: 'the hook ran');
      expect(out.naturalFired, isTrue);
      expect(env.haptics, hasLength(1));
      clock.advance(const Duration(seconds: 30));
      final again = await orchestrator.tick(planFor(t, natural: 60));
      expect(again.naturalFired, isFalse);
      expect(env.haptics, hasLength(1), reason: 'the fire was persisted first');
    });

    test('the headless wake tick (through the gate) reports it too', () async {
      final out = await orchestrator.tickThroughGate(planFor(t, natural: 60));
      expect(out!.naturalFired, isTrue);
      expect(fired, [clock.now]);
    });
  });

  // ── 3. AppState call sites ────────────────────────────────────────────────

  group('AppState wiring', () {
    late FakeAlarmEngine band;
    late AppState app;
    late DateTime now;
    late DateTime onset;
    late DateTime wakeAt;
    var testNo = 0;

    DbWakeConfirmationStore store() => DbWakeConfirmationStore();

    Future<List<WakeEvidenceEvent>> evidence() => store().evidence();

    /// A night that began 8 h ago and ended 20 minutes ago (the morning).
    Future<void> seedMorning() async {
      onset = now.subtract(const Duration(hours: 8));
      await _putWindow(onset, now.subtract(const Duration(minutes: 20)));
    }

    Future<void> saveWeek() async {
      await LocalDb.setAlarmScheduleRows([
        for (var w = 0; w < 7; w++)
          AlarmScheduleEntry(
                  weekday: w,
                  hour: wakeAt.hour,
                  minute: wakeAt.minute,
                  enabled: true,
                  smartWindowMinutes: 60,
                  naturalWindowMinutes: 60)
              .toRow(),
      ]);
      await app.debugLoadAlarmSchedule();
    }

    Future<void> seedAccel({required bool moving}) async {
      final db = await LocalDb.instance;
      final b = db.batch();
      final nowSec = _sec(DateTime.now());
      for (var ts = nowSec - 60; ts <= nowSec; ts++) {
        b.insert(
          'decoded_onehz',
          {
            'device_id': '',
            'ts_ms': ts * 1000,
            'rec_ts': ts,
            'counter': ts,
            'hr': 62,
            'ax': moving && ts.isEven ? 0.3 : 0.0,
            'ay': 0.0,
            'az': 1.0,
            'device_family': 'gen4',
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await b.commit(noResult: true);
    }

    setUp(() async {
      now = DateTime.now();
      band = FakeAlarmEngine();
      band.debugInstallFakeLink(onWrite: (_) async => true, listening: true);
      app = AppState.forTesting(engine: band);
      app.debugSetAlarmGraceMs(20);
      app.debugWakeObserver = ScriptedObserver()..next = stageObs('nrem');
      app.debugBackground = false;
      final w = now.add(Duration(minutes: 20 + testNo++));
      wakeAt = DateTime(w.year, w.month, w.day, w.hour, w.minute);
    });
    tearDown(() => app.dispose());

    group('app opened', () {
      test('the foreground notes appOpened at that instant, alone it is not '
          'final', () async {
        await seedMorning();
        final at = now.subtract(const Duration(minutes: 1));
        expect(await app.noteAppOpened(at: at), isNull);
        await app.debugWakeSignalsSettled();
        expect(await evidence(), [(kind: WakeEvidenceKind.appOpened, sec: _sec(at))]);
        expect(await LocalDb.wakeConfirmation(dayLabelOf(now)), isNull);
      });

      test('defaults to now', () async {
        await seedMorning();
        final before = _sec(DateTime.now());
        await app.noteAppOpened();
        await app.debugWakeSignalsSettled();
        final e = (await evidence()).single;
        expect(e.kind, WakeEvidenceKind.appOpened);
        expect(e.sec, inInclusiveRange(before, _sec(DateTime.now())));
      });

      test('a backgrounded or headless process has no foreground to note',
          () async {
        await seedMorning();
        app.debugBackground = true;
        expect(await app.noteAppOpened(), isNull);
        await app.debugWakeSignalsSettled();
        expect(await evidence(), isEmpty);
      });

      test('with no sleep block known nothing is recorded', () async {
        expect(await app.noteAppOpened(), isNull);
        await app.debugWakeSignalsSettled();
        expect(await evidence(), isEmpty);
      });
    });

    group('band movement', () {
      test('a fresh touch with the wrist moving notes bandMovement, now',
          () async {
        await seedMorning();
        await seedAccel(moving: true);
        app.debugNoteInteraction(DateTime.now().subtract(const Duration(seconds: 15)));
        final before = _sec(DateTime.now());
        await app.debugCheckWakeMovement();
        await app.debugWakeSignalsSettled();
        final e = (await evidence()).single;
        expect(e.kind, WakeEvidenceKind.bandMovement);
        expect(e.sec, inInclusiveRange(before, _sec(DateTime.now())),
            reason: 'at the instant the check became true, not the touch\'s');
      });

      test('a touch with a still wrist notes nothing', () async {
        await seedMorning();
        await seedAccel(moving: false);
        app.debugNoteInteraction(DateTime.now().subtract(const Duration(seconds: 15)));
        await app.debugCheckWakeMovement();
        await app.debugWakeSignalsSettled();
        expect(await evidence(), isEmpty);
      });

      test('movement with no touch notes nothing (the stager\'s business)',
          () async {
        await seedMorning();
        await seedAccel(moving: true);
        await app.debugCheckWakeMovement();
        await app.debugWakeSignalsSettled();
        expect(await evidence(), isEmpty);
      });

      test('no stored accelerometer rows is no inference, never a guess',
          () async {
        await seedMorning();
        app.debugNoteInteraction(DateTime.now().subtract(const Duration(seconds: 15)));
        await app.debugCheckWakeMovement();
        await app.debugWakeSignalsSettled();
        expect(await evidence(), isEmpty);
      });

      test('a touch itself runs the check (no caller has to remember to)',
          () async {
        await seedMorning();
        await seedAccel(moving: true);
        app.debugNoteInteraction(DateTime.now().subtract(const Duration(seconds: 15)));
        await app.debugWakeSignalsSettled();
        expect((await evidence()).map((e) => e.kind),
            [WakeEvidenceKind.bandMovement]);
      });

      test('with no sleep block known the check records nothing', () async {
        await seedAccel(moving: true);
        app.debugNoteInteraction(DateTime.now().subtract(const Duration(seconds: 15)));
        await app.debugCheckWakeMovement();
        await app.debugWakeSignalsSettled();
        expect(await evidence(), isEmpty);
      });
    });

    group('the strap\'s alarm events', () {
      test('fired (57 and 58) notes alarmFired at the EVENT\'s stamp, not at '
          'the time the sync delivered it', () async {
        for (final id in [57, 58]) {
          await _wipe();
          await seedMorning();
          final ts = _sec(now) - 3 * 3600;
          await _feed(app, id, ts: ts);
          await app.debugWakeSignalsSettled();
          expect(await evidence(), [(kind: WakeEvidenceKind.alarmFired, sec: ts)],
              reason: 'event $id');
        }
      });

      test('set, disabled and the haptics event are not "the alarm fired"',
          () async {
        await seedMorning();
        for (final id in [56, 59, 60]) {
          await _feed(app, id, ts: _sec(now) - 3600);
        }
        await app.debugWakeSignalsSettled();
        expect(await evidence(), isEmpty);
      });

      test('a fired event replayed after a re-arm still counts as evidence, '
          'though the alarm books ignore it', () async {
        await seedMorning();
        await saveWeek();
        await app.debugArmNextAlarmOccurrence(); // setAt = now
        final epoch = app.alarmEpoch;
        final ts = _sec(now) - 2 * 3600; // far before this arm
        await _feed(app, 57, ts: ts);
        await app.debugWakeSignalsSettled();
        expect(app.alarmEpoch, epoch,
            reason: 'guard: the books still ignore the stale replay');
        expect(await evidence(), [(kind: WakeEvidenceKind.alarmFired, sec: ts)]);
      });

      test('an alarm from before the block began is not evidence for it',
          () async {
        await seedMorning();
        await _feed(app, 57, ts: _sec(onset) - 3600);
        await app.debugWakeSignalsSettled();
        expect(await evidence(), isEmpty);
      });
    });

    group('acknowledged', () {
      test('"I\'m up" notes alarmAcknowledged now', () async {
        await seedMorning();
        await saveWeek();
        await app.debugArmNextAlarmOccurrence();
        expect(app.alarmEpoch, isNotNull, reason: 'an armed alarm to acknowledge');
        final before = _sec(DateTime.now());
        await app.wake.acknowledgeWake();
        await app.debugWakeSignalsSettled();
        final e = (await evidence()).single;
        expect(e.kind, WakeEvidenceKind.alarmAcknowledged);
        expect(e.sec, inInclusiveRange(before, _sec(DateTime.now())));
      });
    });

    group('Natural Wake fired', () {
      setUp(() async {
        // A 4.0 has an alert transport, so the early buzz is DELIVERED; only a
        // delivered buzz is evidence (a band the dispatcher cannot target holds
        // it back, and that wakes nobody).
        band.state.generation = 'gen4';
        await seedMorning();
        await saveWeek();
        await app.debugArmNextAlarmOccurrence();
        app.sleepOperations.schedule = ExpectedSleepSchedule(
            onsetMinute: ((wakeAt.hour * 60 + wakeAt.minute) - 8 * 60) % 1440,
            wakeMinute: wakeAt.hour * 60 + wakeAt.minute);
      });

      test('the early wake firing notes naturalWake', () async {
        (app.debugWakeObserver as ScriptedObserver).next = stageObs('wake');
        await app.debugRefreshHighFreqWakeWindow();
        final before = _sec(DateTime.now());
        await app.debugKeepAliveTick();
        await app.debugWakeSignalsSettled();
        final e = (await evidence()).single;
        expect(e.kind, WakeEvidenceKind.naturalWake);
        expect(e.sec, inInclusiveRange(before, _sec(DateTime.now())));
      });

      test('a band double tap (event 14) during the repeat dismisses it and '
          'is consumed; outside a repeat it reaches the gestures', () async {
        final tap = StrapEvent(
            eventId: 14,
            tsEpoch: _sec(DateTime.now()),
            receivedAt: DateTime.now(),
            hex: '',
            deviceId: 'd');
        // No repeat yet: the dispatcher sees it (the lab logs a row for it).
        final before = app.deviceLab.entries.length;
        app.debugOnLiveEvent(tap);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(app.deviceLab.entries.length, before + 1,
            reason: 'guard: outside a repeat the tap is handled as before');

        (app.debugWakeObserver as ScriptedObserver).next = stageObs('wake');
        await app.debugRefreshHighFreqWakeWindow();
        await app.debugKeepAliveTick();
        expect(app.wake.naturalBuzzing.value, isTrue,
            reason: 'Natural fired and its repeat is running');

        final during = app.deviceLab.entries.length;
        app.debugOnLiveEvent(tap);
        final end = DateTime.now().add(const Duration(seconds: 10));
        while (app.wake.naturalBuzzing.value && DateTime.now().isBefore(end)) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(app.wake.naturalBuzzing.value, isFalse,
            reason: 'the double tap stopped the repeat');
        expect(app.deviceLab.entries.length, during,
            reason: 'consumed: no gesture action ran for it');
      });

      test('an abstaining tick notes nothing', () async {
        (app.debugWakeObserver as ScriptedObserver).next = stageObs('nrem');
        await app.debugRefreshHighFreqWakeWindow();
        await app.debugKeepAliveTick();
        await app.debugWakeSignalsSettled();
        expect(await evidence(), isEmpty);
      });
    });

    group('a completed confirmation', () {
      late List<Set<String>> derived;
      setUp(() async {
        derived = [];
        app.debugDeriveDays = (days) async {
          derived.add(days);
          return days.length;
        };
        await seedMorning();
      });

      String wakeDay(int sec) =>
          dayLabelOf(DateTime.fromMillisecondsSinceEpoch(sec * 1000));

      test('app opened after an alarm fired: confirmed, stored, wake day '
          're-derived once', () async {
        final alarmTs = _sec(now) - 3600;
        await _feed(app, 57, ts: alarmTs);
        await app.debugWakeSignalsSettled();
        expect(derived, isEmpty, reason: 'an alarm alone is not final');
        final openAt = now.subtract(const Duration(minutes: 10));
        expect(await app.noteAppOpened(at: openAt), _sec(openAt));
        await app.debugWakeSignalsSettled();
        final row = (await LocalDb.wakeConfirmation(wakeDay(_sec(openAt))))!;
        expect(row.atSec, _sec(openAt));
        expect(row.basis, 'alarm_fired');
        expect(derived, [
          {wakeDay(_sec(openAt))}
        ]);
        // Later events change nothing and re-derive nothing.
        await app.noteAppOpened(at: now);
        await _feed(app, 58, ts: _sec(now) - 60);
        await app.debugWakeSignalsSettled();
        expect(derived, hasLength(1));
        expect((await LocalDb.wakeConfirmation(wakeDay(_sec(openAt))))!.atSec,
            _sec(openAt));
      });

      test('an alarm fired after the app was opened completes it too',
          () async {
        final openAt = now.subtract(const Duration(minutes: 10));
        await app.noteAppOpened(at: openAt);
        await app.debugWakeSignalsSettled();
        expect(derived, isEmpty, reason: 'opening alone is not final');
        final ts = _sec(openAt) + 5; // the alarm sounds as they open the app
        await _feed(app, 57, ts: ts);
        await app.debugWakeSignalsSettled();
        expect((await LocalDb.wakeConfirmation(wakeDay(ts)))!.atSec, ts);
        expect(derived, hasLength(1));
      });

      test('movement after the app was opened completes it, basis movement',
          () async {
        await seedAccel(moving: true);
        await app.noteAppOpened(at: DateTime.now().subtract(const Duration(seconds: 20)));
        app.debugNoteInteraction(DateTime.now().subtract(const Duration(seconds: 15)));
        await app.debugCheckWakeMovement();
        await app.debugWakeSignalsSettled();
        final row = (await LocalDb.wakeConfirmation(dayLabelOf(DateTime.now())))!;
        expect(row.basis, 'movement');
        expect(derived, hasLength(1));
      });

      test('acknowledging after the app was opened completes it, basis '
          'alarm_acknowledged', () async {
        await saveWeek();
        await app.debugArmNextAlarmOccurrence();
        await app.noteAppOpened(at: DateTime.now().subtract(const Duration(seconds: 20)));
        await app.wake.acknowledgeWake();
        await app.debugWakeSignalsSettled();
        final row = (await LocalDb.wakeConfirmation(dayLabelOf(DateTime.now())))!;
        expect(row.basis, 'alarm_acknowledged');
        expect(derived, hasLength(1));
      });

      test('Natural Wake fired before the app was opened: the open completes '
          'it, basis natural_wake', () async {
        await store().addEvidence(
            WakeEvidenceKind.naturalWake, _sec(now) - 900);
        final at = now.subtract(const Duration(minutes: 5));
        expect(await app.noteAppOpened(at: at), _sec(at));
        await app.debugWakeSignalsSettled();
        expect((await LocalDb.wakeConfirmation(wakeDay(_sec(at))))!.basis,
            'natural_wake');
        expect(derived, hasLength(1));
      });

      test('a failing derive is logged, not thrown, and the confirmation stands',
          () async {
        app.debugDeriveDays = (_) async => throw StateError('derive failed');
        await store().addEvidence(WakeEvidenceKind.alarmFired, _sec(now) - 900);
        final at = now.subtract(const Duration(minutes: 5));
        expect(await app.noteAppOpened(at: at), _sec(at));
        await app.debugWakeSignalsSettled();
        expect(await LocalDb.wakeConfirmation(wakeDay(_sec(at))), isNotNull);
      });
    });
  });

  // ── 4. headless ───────────────────────────────────────────────────────────

  group('headless alarm event', () {
    late DateTime now;
    late DateTime onset;
    setUp(() async {
      now = DateTime.now();
      onset = now.subtract(const Duration(hours: 8));
      await _putWindow(onset, now.subtract(const Duration(minutes: 20)));
    });

    test('fired (57 and 58) notes alarmFired at the event\'s own stamp',
        () async {
      for (final id in [57, 58]) {
        await _wipe();
        await _putWindow(onset, now.subtract(const Duration(minutes: 20)));
        final ts = _sec(now) - 1800;
        expect(await handleHeadlessAlarmEvent(id, tsEpoch: ts), isNull,
            reason: 'alone, not final');
        expect(await DbWakeConfirmationStore().evidence(),
            [(kind: WakeEvidenceKind.alarmFired, sec: ts)],
            reason: 'event $id');
      }
    });

    test('ALARM_SET (56) still only confirms the arm, and is not evidence',
        () async {
      SharedPreferences.setMockInitialValues({'alarm_epoch_confirmed': false});
      await handleHeadlessAlarmEvent(56, tsEpoch: _sec(now) - 1800);
      expect((await SharedPreferences.getInstance()).getBool('alarm_epoch_confirmed'),
          isTrue);
      expect(await DbWakeConfirmationStore().evidence(), isEmpty);
    });

    test('with the app opened earlier, the headless alarm completes the '
        'confirmation and returns the moment', () async {
      final openAt = now.subtract(const Duration(hours: 1));
      await WakeConfirmationRecorder(DbWakeConfirmationStore())
          .note(WakeEvidenceKind.appOpened, openAt);
      final ts = _sec(openAt) + 30;
      expect(await handleHeadlessAlarmEvent(57, tsEpoch: ts), ts);
      expect((await LocalDb.wakeConfirmation(dayLabelOf(now)))!.basis,
          'alarm_fired');
    });

    test('without a stamp nothing is invented', () async {
      expect(await handleHeadlessAlarmEvent(57), isNull);
      expect(await DbWakeConfirmationStore().evidence(), isEmpty,
          reason: 'no stamp, no instant to call evidence');
    });

    test('headless alarm, then the user opens the app: confirmed, basis '
        'alarm_fired (the full cross-process path)', () async {
      await handleHeadlessAlarmEvent(57, tsEpoch: _sec(now) - 3000);
      // A relaunch: a new AppState in the foreground.
      final app = AppState.forTesting(engine: FakeAlarmEngine());
      addTearDown(app.dispose);
      app.debugBackground = false;
      app.debugDeriveDays = (days) async => days.length;
      final openAt = now.subtract(const Duration(minutes: 2));
      expect(await app.noteAppOpened(at: openAt), _sec(openAt));
      await app.debugWakeSignalsSettled();
      final row = (await LocalDb.wakeConfirmation(dayLabelOf(openAt)))!;
      expect(row.atSec, _sec(openAt));
      expect(row.basis, 'alarm_fired');
    });
  });

  // ── 4b. headless: the confirmation this run completed re-derives the night ─

  group('headless re-derive of the confirmed wake day', () {
    late DateTime now;
    late List<String> built;
    late List<(String, bool)> ran;

    setUp(() async {
      await _wipe();
      SharedPreferences.setMockInitialValues({});
      now = DateTime.now();
      built = [];
      ran = [];
      debugHeadlessEngineFactory = ({log, background = false}) {
        built.add('background=$background');
        return _RecordingDeriveEngine(ran, background: background);
      };
      debugHeadlessPowerSource = FakePowerSource(charging: true, powerSaver: false);
      // A night that began 8 h ago and ended 20 minutes ago.
      await _putWindow(now.subtract(const Duration(hours: 8)),
          now.subtract(const Duration(minutes: 20)));
    });

    tearDown(() {
      debugHeadlessEngineFactory = null;
      debugHeadlessPowerSource = null;
    });

    test('derives the wake day, forced, through the headless engine builder',
        () async {
      final moment = _sec(now) - 600;
      expect(await headlessDeriveConfirmedWakeDay(moment), isTrue);
      expect(built, ['background=true'], reason: 'the headless builder, once');
      expect(ran, [
        (dayLabelOf(now), true),
      ], reason: 'the night\'s own day (the stored block), forced');
    });

    test('is held by Maximum battery like every automatic headless derive',
        () async {
      SharedPreferences.setMockInitialValues({'calc_power_mode': 'maxBattery'});
      debugHeadlessPowerSource = FakePowerSource(charging: false, powerSaver: true);
      expect(await headlessDeriveConfirmedWakeDay(_sec(now) - 600), isFalse);
      expect(built, isEmpty);
      expect(ran, isEmpty);
    });

    test('a derive that throws is swallowed (the drain\'s result stands)',
        () async {
      debugHeadlessEngineFactory = ({log, background = false}) =>
          _RecordingDeriveEngine(ran, background: background, boom: true);
      expect(await headlessDeriveConfirmedWakeDay(_sec(now) - 600), isFalse);
    });

    test('with no stored block the wake moment\'s own day is derived', () async {
      await _wipe();
      final moment = _sec(now) - 600;
      expect(await headlessDeriveConfirmedWakeDay(moment), isTrue);
      expect(ran, [
        (dayLabelOf(DateTime.fromMillisecondsSinceEpoch(moment * 1000)), true),
      ]);
    });
  });

  // ── 5. source guards ──────────────────────────────────────────────────────

  group('call sites that cannot be driven from a unit test', () {
    test('a foreground resume notes the app opened; going to the background '
        'does not', () {
      final hook = _codeOf('lib/app.dart',
          'void didChangeAppLifecycleState(AppLifecycleState state)');
      final resumed = hook.substring(
          hook.indexOf('AppLifecycleState.resumed'),
          hook.indexOf('AppLifecycleState.paused'));
      expect(resumed, contains('noteAppOpened'));
      expect(hook.substring(hook.indexOf('AppLifecycleState.paused')),
          isNot(contains('noteAppOpened')));
    });

    test('the headless onEvent hands the event\'s own stamp to the handler',
        () {
      final src = File('lib/sync/background_sync.dart').readAsStringSync();
      final calls = RegExp(r'handleHeadlessAlarmEvent\(([^)]*)\)')
          .allMatches(codeOnly(src))
          .map((m) => m.group(1)!)
          .toList();
      expect(calls, isNotEmpty);
      for (final args in calls) {
        expect(args, contains('tsEpoch'),
            reason: 'every call site passes the stamp: $args');
      }
    });

    test('the headless run re-derives the wake day when its own note '
        'completed the confirmation, after the drain and before the light '
        'pass', () {
      final src = codeOnly(File('lib/sync/background_sync.dart').readAsStringSync());
      final start = src.indexOf('Future<bool> runHeadlessSync(');
      expect(start, isNonNegative);
      final body = src.substring(start, src.indexOf('\n}\n', start));
      // The moment the handler returned is kept, not dropped.
      expect(
          RegExp(r'confirmedWake\s*=\s*moment').hasMatch(body) ||
              RegExp(r'moment\s*=\s*await\s+handleHeadlessAlarmEvent')
                  .hasMatch(body),
          isTrue,
          reason: 'onEvent keeps the confirmed moment');
      final disconnect = body.indexOf('engine.disconnect()');
      final rederive = body.indexOf('headlessDeriveConfirmedWakeDay');
      final light = body.indexOf('headlessDeriveAfterSync()');
      expect(rederive, isNonNegative, reason: 'the run re-derives');
      expect(disconnect, isNonNegative);
      expect(light, isNonNegative);
      expect(rederive, greaterThan(disconnect), reason: 'after the drain');
      expect(rederive, lessThan(light), reason: 'before the light pass');
    });

    test('the foreground event handler notes the evidence BEFORE the stale '
        'replay filter can return', () {
      final body = _codeOf('lib/state/app_state.dart',
          'void _handleAlarmEvent(int id, int ts)');
      final note = body.indexOf('WakeEvidenceKind.alarmFired');
      final filter = body.indexOf('predatesArm');
      expect(note, isNonNegative, reason: 'the handler notes alarmFired');
      expect(filter, isNonNegative);
      expect(note, lessThan(filter));
    });

    test('exactly one recorder is built for the app, every site shares it',
        () {
      final app = codeOnly(File('lib/state/app_state.dart').readAsStringSync());
      expect(RegExp(r'WakeConfirmationRecorder\(').allMatches(app).length, 1);
      expect(RegExp(r'DbWakeConfirmationStore\(').allMatches(app).length, 1);
    });
  });

  // ── 6. end to end ─────────────────────────────────────────────────────────

  group('open app + alarm fired: the night is final', () {
    const profile = Profile(
      ageYears: 35,
      weightKg: 75,
      heightCm: 178,
      sex: 'male',
      restingHrManual: 54,
    );
    late DateTime mid;
    late String label;
    late int counter;
    int h(double hours) =>
        mid.add(Duration(minutes: (hours * 60).round())).millisecondsSinceEpoch ~/ 1000;

    // Asleep 23:00 to 03:57, awake to 04:00, back in bed to 06:30. The band
    // still looks asleep when the app is opened at 03:48.
    bool asleep(int t) => (t >= h(-1) && t < h(3.95)) || (t >= h(4.0) && t < h(6.5));

    Future<void> rows(double from, double to) async {
      final db = await LocalDb.instance;
      final b = db.batch();
      for (var ts = h(from); ts < h(to); ts++) {
        final s = asleep(ts);
        b.rawInsert(
          'INSERT OR REPLACE INTO decoded_onehz '
          '(device_id, ts_ms, rec_ts, counter, hr, ax, ay, az, spo2_red_raw, '
          "spo2_ir_raw, skin_temp_raw, device_family) VALUES ('', ?, ?, ?, ?, ?, ?, ?, 1, 1, 3000, 'gen4')",
          [
            ts * 1000,
            ts,
            counter++,
            s ? 52 + (ts % 7) : 80 + (ts ~/ 60) % 20 + ts % 3,
            s ? 0.0 : .3 * math.sin(ts * .21),
            s ? 0.0 : .2 * math.cos(ts * .13),
            s ? 1.0 : 1 + .05 * math.sin(ts * .07),
          ],
        );
      }
      await b.commit(noResult: true);
    }

    Future<Map<String, dynamic>> payload() async => jsonDecode(
        (await LocalDb.dayResult(label))!['payload_json'] as String)
        as Map<String, dynamic>;

    Future<Map<String, dynamic>> night() async {
      final b = await payload();
      final scalars = (b['scalars'] as Map).cast<String, dynamic>();
      const keys = [
        'tst_min', 'efficiency', 'awakenings', 'longest_sleep_min', 'sol_min',
        'light_min', 'deep_min', 'rem_min', 'sleep_onset_sec', 'midsleep_sec',
        'rhr_nocturnal', 'sleeping_hr_nadir', 'sleeping_hr_nadir_ts',
      ];
      return {
        'scalars': {for (final k in keys) k: scalars[k]},
        'sleep': b['sleep'],
        'main_period': [
          for (final e in ((b['sleep_periods'] as Map)['periods'] as List).cast<Map>())
            if (e['is_main'] == true) e,
        ],
      };
    }

    Future<int?> offsetSec() async {
      final row = await LocalDb.sleepSessionCandidate(label, kAlgoVersion);
      if (row == null) return null;
      return (jsonDecode(row['payload_json'] as String)
          as Map)['sleep_offset_sec'] as int?;
    }

    setUp(() {
      counter = 0;
      final n = DateTime.now();
      mid = DateTime(n.year, n.month, n.day - 1);
      label = dayLabelOf(mid);
    });

    test('opened at 03:48 after the alarm fired at 03:45: re-scored at the '
        'confirmation, unchanged by the sync that follows', () async {
      await rows(-2, 3.9);
      await DerivationEngine().run(profile);
      final unconfirmed = await offsetSec();
      expect(unconfirmed, isNotNull, reason: 'the fixture really produced a night');
      expect(unconfirmed, greaterThan(h(3.85)),
          reason: 'guard: unconfirmed the night follows the data to 03:54');

      final app = AppState.forTesting(engine: FakeAlarmEngine());
      addTearDown(app.dispose);
      app.user = profile.toMap();
      app.debugBackground = false;
      app.debugWakeClock = () => DateTime.fromMillisecondsSinceEpoch(h(3.85) * 1000);
      await _feed(app, 57, ts: h(3.75));
      final openAt = DateTime.fromMillisecondsSinceEpoch(h(3.8) * 1000);
      expect(await app.noteAppOpened(at: openAt), h(3.8));
      await app.debugWakeSignalsSettled();

      final row = (await LocalDb.wakeConfirmation(label))!;
      expect(row.atSec, h(3.8));
      expect(row.basis, 'alarm_fired');
      expect(await offsetSec(), lessThanOrEqualTo(h(3.8)),
          reason: 'the confirmation triggered the re-derive; the night ends '
              'where the wake was confirmed');
      final frozen = await night();
      expect((frozen['scalars'] as Map)['tst_min'], isNotNull);

      // The band syncs the rest of the morning: back in bed from 04:00 to
      // 06:30. Unconfirmed, the 3 minute gap would be bridged.
      await rows(3.9, 9);
      await DerivationEngine().run(profile);
      expect(await offsetSec(), lessThanOrEqualTo(h(3.8)));
      expect(jsonEncode(await night()), jsonEncode(frozen),
          reason: 'no figure of the night moved');
      final scalars = (await payload())['scalars'] as Map;
      expect(scalars['worn_min'] as num, greaterThan(300),
          reason: 'the sync did run: only the night is final, not the day');
    });
  });
}

/// A [DerivationEngine] that records the day passes it is asked for and
/// computes nothing.
class _RecordingDeriveEngine extends DerivationEngine {
  _RecordingDeriveEngine(this.calls, {required super.background, this.boom = false});
  final List<(String, bool)> calls;
  final bool boom;

  @override
  Future<int> runDays(
    Profile profile,
    Set<String> days, {
    bool force = true,
    void Function(String day, int index, int total)? onDayDone,
    void Function(String day)? onDayDerived,
    void Function(List<String> days)? onScopeDays,
  }) async {
    if (boom) throw StateError('derive failed');
    calls.add(((days.toList()..sort()).join(','), force));
    return days.length;
  }
}
