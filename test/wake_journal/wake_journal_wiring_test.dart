import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/ui2/screens/day_timeline.dart';
import 'package:openstrap_edge/ui2/screens/sleep_detail.dart';
import 'package:openstrap_edge/wake/wake_journal.dart';
import 'package:openstrap_edge/wake/wake_orchestrator.dart';
import 'package:openstrap_edge/wake/wake_outcome.dart';
import 'package:openstrap_edge/wake/wake_stores.dart';
import '../backup/backup_support.dart';
import '../support/wake_fakes.dart';
import 'fixtures.dart';
import 'package:openstrap_edge/wake/wake_timeline.dart';
import 'package:openstrap_edge/ui2/day_timeline/sleep_summary.dart';

Future<void> seedNight(
  int day, {
  double? recovery = 80,
  int? tstSec = 28800,
}) async {
  final alarm = alarmAt.add(Duration(days: day));
  final label = '2026-10-${26 + day}'; // fixtures use day -6..0 only
  await LocalDb.putDayResult(
    dayId: label,
    algoVersion: 116,
    payloadJson: jsonEncode({
      'date': label,
      'scalars': {
        'readiness': recovery,
        'tst_min': 999,
        'nap_min': 90,
      }, // decoys: main-sleep accounting wins
      'sleep': {
        'window': {
          'value': {
            'onset_ms': alarm
                .subtract(const Duration(hours: 8))
                .millisecondsSinceEpoch,
            'offset_ms': alarm.millisecondsSinceEpoch,
          },
        },
        'accounting': {
          'value': {'tst_sec': tstSec, 'in_bed_sec': 30000},
        },
      },
    }),
    windowJson: jsonEncode({
      'value': {
        'onset_ms': alarm
            .subtract(const Duration(hours: 8))
            .millisecondsSinceEpoch,
        'offset_ms': alarm.millisecondsSinceEpoch,
      },
    }),
  );
  final e = alarm.millisecondsSinceEpoch ~/ 1000;
  for (final (kind, minutes, data) in [
    ('natural', -20, <String, Object?>{'reason': 'fire'}),
    ('natural_haptic', -20, <String, Object?>{'phase': 'result', 'result': 'sent', 'delivered': ['band']}),
    (
      'ack',
      -19,
      <String, Object?>{
        'dreamAnswer': 'dream',
        'wakePath': 'natural',
        'dreamAnsweredAtMs': alarm
            .subtract(const Duration(minutes: 19))
            .millisecondsSinceEpoch,
      },
    ),
  ]) {
    await const DbWakeTraceStore().append(
      WakeTraceEntry(
        wakeEpochSec: e,
        atMs: alarm.add(Duration(minutes: minutes)).millisecondsSinceEpoch,
        kind: kind,
        data: data,
      ),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BackupEnv env;
  final oldNow = LocalDb.nowMs;
  setUpAll(() async {
    env = await BackupEnv.create('p2_wake_wiring.db');
  });
  setUp(() async {
    await env.wipe();
    LocalDb.nowMs = () => atMinute(10).millisecondsSinceEpoch;
  });
  tearDownAll(() async {
    LocalDb.nowMs = oldNow;
    await env.dispose();
  });

  test(
    'durable outcomes join the matching day recovery and main-sleep TST, preserving nulls',
    () async {
      await seedNight(-1, recovery: null, tstSec: null);
      await seedNight(0, recovery: 73, tstSec: 25200);
      final history = await const DbWakeJournal().outcomes();
      expect(history.map((n) => n.dayId), ['2026-10-25', '2026-10-26']);
      expect(history.map((n) => n.wakeEpochSec), [epoch - 86400, epoch]);
      expect(history.map((n) => n.recovery), [null, 73]);
      expect(history.map((n) => n.mainSleepTst), [
        null,
        const Duration(hours: 7),
      ]);
      expect(history.map((n) => n.timeToWake), [
        const Duration(minutes: 1),
        const Duration(minutes: 1),
      ]);
      expect(history.map((n) => n.snoozeCount), [0, 0]);
      expect(history.map((n) => n.dream?.answer.name), ['dream', 'dream']);
      expect(history.map((n) => n.substance), [
        null,
        null,
      ]); // P5 fills this later
    },
  );

  test(
    'journal reads a backup alarm from durable band code 57 without a Natural trace',
    () async {
      final db = await LocalDb.instance;
      await db.insert('band_events', {
        'device_id': '',
        'hex': 'p2-alarm',
        'event_id': 57,
        'name': 'alarm_started',
        'ts': epoch,
        'payload_json': '{}',
        'captured_at': alarmAt.millisecondsSinceEpoch,
      });
      await const DbWakeTraceStore().append(row('ack', 8));
      await LocalDb.close();
      final n = await const DbWakeJournal().forEpoch(epoch);
      expect(n.firstFireAt, alarmAt);
      expect(n.timeToWake, const Duration(minutes: 8));
    },
  );

  test(
    'journal retains first fire and every repeat beyond the diagnostic 400-row read cap',
    () async {
      await const DbWakeTraceStore().append(
        row('natural', -20, {'reason': 'fire'}),
      );
      await const DbWakeTraceStore().append(row('natural_haptic', -20,
        {'phase': 'result', 'result': 'sent'}));
      final batch = (await LocalDb.instance).batch();
      for (var i = 1; i <= 420; i++) {
        batch.insert('wake_trace', {
          'wake_epoch': epoch,
          'at_ms': atMinute(-20).millisecondsSinceEpoch + i * 1000,
          'kind': 'natural_repeat',
          'data_json': jsonEncode({
            'phase': 'result',
            'index': i,
            'result': 'sent',
          }),
        });
      }
      await batch.commit(noResult: true);
      await const DbWakeTraceStore().append(row('ack', 8));
      final n = await const DbWakeJournal().forEpoch(epoch);
      expect(n.firstFireAt, atMinute(-20));
      expect(n.events, hasLength(422)); // first fire + 420 repeats + ack
      expect(n.timeToWake, const Duration(minutes: 28));
    },
  );

  test(
    'tuning persists one reasoned tune row per night even under concurrent/restarted calls',
    () async {
      for (var d = -6; d <= 0; d++) {
        await seedNight(d);
      }
      await Future.wait([
        const DbWakeJournal().tuneFor(epoch),
        const DbWakeJournal().tuneFor(epoch),
      ]);
      await LocalDb.close();
      await const DbWakeJournal().tuneFor(epoch);
      final tune = (await const DbWakeTraceStore().forWake(
        epoch,
      )).where((e) => e.kind == 'tune');
      expect(tune.map((e) => e.data['reason']), ['natural_dream_fast']);
      expect(tune.single.data['triggerRunOffsetSec'], -15);
      expect(tune.single.data['windowLeadMinutes'], 1);
      final params = await const DbWakeJournal().parameters();
      expect(params.triggerRunOffsetSec, -15);
      expect(params.windowLeadMinutes, 1);
      expect(params.lastLearnedEpoch, epoch);
    },
  );

  test('failed tune trace write rolls back parameter advancement', () async {
    for (var d = -6; d <= 0; d++) {
      await seedNight(d);
    }
    final db = await LocalDb.instance;
    await db.execute(
      "CREATE TRIGGER reject_tune BEFORE INSERT ON wake_trace "
      "WHEN NEW.kind = 'tune' BEGIN SELECT RAISE(ABORT, 'test rejects tune'); END",
    );
    await expectLater(
      const DbWakeJournal().tuneFor(epoch),
      throwsA(isA<Exception>()),
    );
    final params = await const DbWakeJournal().parameters();
    expect(params.triggerRunOffsetSec, 0);
    expect(params.windowLeadMinutes, 0);
    expect(params.lastLearnedEpoch, isNull);
    expect(
      (await const DbWakeTraceStore().forWake(
        epoch,
      )).where((e) => e.kind == 'tune'),
      isEmpty,
    );
    await db.execute('DROP TRIGGER reject_tune');
    await const DbWakeJournal().tuneFor(epoch);
    expect(
      (await const DbWakeTraceStore().forWake(
        epoch,
      )).where((e) => e.kind == 'tune').map((e) => e.data['reason']),
      ['natural_dream_fast'],
    );
  });

  test('saving the optional answer learns once after durable acknowledgement', () async {
    for (var d = -6; d <= 0; d++) {
      await seedNight(d);
    }
    final db = await LocalDb.instance;
    await db.update('wake_trace', {'data_json': '{}'},
        where: "wake_epoch = ? AND kind = 'ack'", whereArgs: [epoch]);
    const journal = DbWakeJournal();
    final before = await journal.tuneFor(epoch);
    expect(before.reason, 'missing_answer');
    expect(before.applied, isFalse);
    await journal.answerDream(wakeEpochSec: epoch, at: atMinute(-19),
        answer: DreamAnswer.dream);
    final learned = await journal.parameters();
    expect(learned.triggerRunOffsetSec, -15);
    expect(learned.windowLeadMinutes, 1);
    expect(learned.lastLearnedEpoch, epoch);
    // First answer wins and replay must not add another nightly step.
    await journal.answerDream(wakeEpochSec: epoch, at: atMinute(-18),
        answer: DreamAnswer.normal);
    final after = await journal.parameters();
    expect(after.triggerRunOffsetSec, -15);
    expect(after.windowLeadMinutes, 1);
    expect((await journal.forEpoch(epoch)).dream?.answer, DreamAnswer.dream);
    final tune = (await const DbWakeTraceStore().forWake(epoch))
        .where((e) => e.kind == 'tune');
    expect(tune.map((e) => e.data['reason']), ['natural_dream_fast']);
  });

  test('a missing target cannot apply an older answered night', () async {
    for (var d = -6; d <= 0; d++) {
      await seedNight(d);
    }
    const journal = DbWakeJournal();
    final missing = await journal.tuneFor(epoch + 600);
    expect(missing.reason, 'missing_outcome');
    expect(missing.applied, isFalse);
    expect((await journal.parameters()).lastLearnedEpoch, isNull);
    final actual = await journal.tuneFor(epoch);
    expect(actual.reason, 'natural_dream_fast');
    expect(actual.parameters.triggerRunOffsetSec, -15);
  });

  test(
    'production orchestrator reads durable tuning before deciding to fire',
    () async {
      // Literal durable shape avoids hiding this missing call behind the RED learner.
      await LocalDb.wakeMetaSet(
        'natural_wake_parameters',
        jsonEncode({
          'triggerRunOffsetSec': -15,
          'windowLeadMinutes': 1,
          'lastLearnedEpoch': epoch - 86400,
        }),
      );
      final observer = ScriptedObserver()..next = remObs(runSec: 105);
      final engine = WakeOrchestrator(
        env: FakeWakeEnv(),
        observer: observer,
        stateStore: const DbWakeStateStore(),
        traceStore: const DbWakeTraceStore(),
        now: () => atMinute(-31),
      );
      final result = await engine.tick(planFor(alarmAt, natural: 30));
      expect(
        result.naturalFired,
        isTrue,
        reason: 'tuned window begins at T-31 and trigger is 120-15=105 seconds',
      );
    },
  );

  test(
    'every delivered repeat is persisted even when consecutive results are identical',
    () async {
      final deliveries = StreamController<Completer<WakeHapticResult>>();
      final pending = StreamIterator(deliveries.stream);
      final stopped = Completer<void>();
      final band = FakeWakeEnv()
        ..onHaptic = (_) {
          final gate = Completer<WakeHapticResult>();
          deliveries.add(gate);
          return gate.future;
        };
      final clock = TestClock(atMinute(-20));
      final engine = WakeOrchestrator(
        env: band,
        observer: ScriptedObserver(),
        stateStore: const DbWakeStateStore(),
        traceStore: const DbWakeTraceStore(),
        now: clock.call,
        repeatNatural: true,
        onNaturalRepeatChanged: (running) {
          if (!running && !stopped.isCompleted) stopped.complete();
        },
      );
      const sent = WakeHapticResult(delivered: ['band']);
      final plan = planFor(alarmAt, natural: 30);
      final tick = engine.tick(plan);
      expect(await pending.moveNext(), isTrue);
      pending.current.complete(sent);
      await tick;
      expect(await pending.moveNext(), isTrue);
      clock.at(atMinute(-19));
      pending.current.complete(sent);
      expect(await pending.moveNext(), isTrue);
      clock.at(atMinute(-18));
      pending.current.complete(sent);
      expect(await pending.moveNext(), isTrue);
      await engine.acknowledge(plan);
      pending.current.complete(sent);
      await stopped.future;
      await pending.cancel();
      await deliveries.close();
      // The next request proves the preceding result finished its durable write.
      final rows = (await const DbWakeTraceStore().forWake(epoch)).where(
        (e) => e.kind == 'natural_repeat' && e.data['phase'] == 'result',
      );
      expect(rows.map((e) => e.data['index']).take(2), [1, 2]);
      expect(rows.map((e) => e.atMs).take(2), [
        atMinute(-19).millisecondsSinceEpoch,
        atMinute(-18).millisecondsSinceEpoch,
      ]);
    },
  );

  // WHY: CLAIM(wake-summary-epoch). Day-wide event lists must retain the
  // answer on each epoch's own acknowledgement, even when only one fired.
  // catches: assigning primary.dream to every acknowledgement in the day.
  test('two epochs in one day retain their own answers and never borrow an alert', () async {
    await seedNight(0);
    final trace = const DbWakeTraceStore();
    await trace.append(row('ack', 30, {
      'dreamAnswer': 'normal', 'wakePath': 'alarm',
      'dreamAnsweredAtMs': atMinute(31).millisecondsSinceEpoch,
    }, epoch + 1800));
    await trace.append(row('snooze', 20, {'count': 1}, epoch + 1800));
    final n = await const DbWakeJournal().forDay('2026-10-26');
    expect(n.firstFireAt, atMinute(-20));
    expect(n.ackAt, atMinute(-19));
    expect(n.timeToWake, const Duration(minutes: 1));
    expect(n.dream?.answer, DreamAnswer.dream);
    expect(n.snoozeCount, 1);
    final acks = n.events.where((e) => e.kind == WakeNightEventKind.ack).toList();
    expect(acks.map((e) => [e.wakeEpochSec, e.at, e.dream?.answer]), [
      [epoch, atMinute(-19), DreamAnswer.dream],
      [epoch + 1800, atMinute(30), DreamAnswer.normal],
    ]);
    final other = await const DbWakeJournal().forEpoch(epoch + 1800);
    expect(other.firstFireAt, isNull);
    expect(other.timeToWake, isNull);
    expect((await const DbWakeJournal().forDay('2026-10-27')).events, isEmpty);
  });

  // WHY: CLAIM(wake-answer-first-ack). Answer projection survives absent path
  // metadata, uses only pre-ack successful evidence, and never borrows a later ack.
  for (final method in ['repeat', 'gradual', 'band', 'none', 'late']) {
    test('R1 first ack answer survives absent path with $method evidence', () async {
      await seedNight(0);
      await (await LocalDb.instance).delete('wake_trace');
      final trace = const DbWakeTraceStore();
      if (method == 'repeat') {
        await trace.append(row('natural_repeat', -2, {'phase': 'result', 'result': 'sent'}));
      }
      if (method == 'gradual') await trace.append(row('gradual', -2, {'result': 'sent'}));
      if (method == 'band') {
        await (await LocalDb.instance).insert('band_events', {'device_id': '', 'ts': epoch, 'event_id': 57, 'hex': 'r1-alarm',
          'name': 'alarm_started', 'captured_at': alarmAt.millisecondsSinceEpoch});
      }
      await trace.append(row('ack', 1));
      if (method == 'late') {
        await trace.append(row('natural_haptic', 2, {'phase': 'result', 'result': 'sent'}));
      }
      await trace.append(row('ack', 3, {'dreamAnswer': 'normal',
        'wakePath': 'alarm', 'dreamAnsweredAtMs': atMinute(4).millisecondsSinceEpoch}));
      await const DbWakeJournal().answerDream(wakeEpochSec: epoch,
        at: atMinute(2), answer: DreamAnswer.dream);
      // Simulate a historical answer written before path metadata existed.
      final db = await LocalDb.instance;
      final first = (await db.query('wake_trace', where: "kind = 'ack'", orderBy: 'at_ms')).first;
      final answer = Map<String, dynamic>.from(jsonDecode(first['data_json'] as String) as Map)..remove('wakePath');
      await db.update('wake_trace', {'data_json': jsonEncode(answer)}, where: 'id = ?', whereArgs: [first['id']]);
      await LocalDb.close();
      final night = await const DbWakeJournal().forEpoch(epoch);
      final expectedPath = method == 'repeat' ? WakePath.natural : method == 'gradual'
        ? WakePath.gradual : method == 'band' ? WakePath.alarm : null;
      expect(night.dream?.answer, DreamAnswer.dream);
      expect(night.dream?.path, expectedPath);
      expect(night.ackAt, atMinute(1));
      expect(night.dream?.at, atMinute(2));
      if (expectedPath == null) expect(night.timeToWake, isNull);
      final day = await const DbWakeJournal().forDay('2026-10-26');
      expect(day.dream?.answer, DreamAnswer.dream);
      final events = sleepSummaryEvents([SleepSummaryInterval(id: 'main',
        start: atMinute(-480), end: atMinute(1))], day);
      expect(events.where((e) => e.ack).single.label, "I'm up from a dream");
    });
  }

  test('existing day timeline loader includes durable wake moments', () async {
    await seedNight(0);
    final repo = LocalRepositoryImpl(getProfileMap: () => null);
    final day = await TimelineData.load(repo, want: '2026-10-26');
    expect(
      day.moments.map((m) => m.title),
      containsAllInOrder(['Natural wake', "I'm up"]),
    );
  });

  test(
    'existing sleep detail loader includes wake interval from the same durable record',
    () async {
      await seedNight(0);
      final data = await SleepData.load(
        LocalRepositoryImpl(getProfileMap: () => null),
        want: '2026-10-26',
      );
      // WHY: the day projection must retain the wearer's answer from its own
      // epoch; stage estimates cannot stand in for this answer.
      // catches: forDay drops the primary epoch's dream response.
      expect(data.wakeTimeline.dream?.answer, DreamAnswer.dream);
      expect(data.wakeTimeline.dream?.at, atMinute(-19));
      expect(data.wakeTimeline.firstFireAt, atMinute(-20));
      expect(data.wakeTimeline.timeToWake, const Duration(minutes: 1));
    },
  );
}
