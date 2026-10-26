import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/alarm/snooze/alarm_stop_policy.dart';
import 'package:openstrap_edge/alarm/snooze/snooze_controller.dart';
import 'package:openstrap_edge/alarm/snooze/snooze_settings.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/wake/wake_journal.dart';
import 'package:openstrap_edge/wake/wake_outcome.dart';
import 'package:openstrap_edge/wake/wake_orchestrator.dart' show WakeTraceEntry;
import 'package:openstrap_edge/wake/wake_stores.dart';
import '../alarm_snooze/snooze_fakes.dart' show FakeScheduler;
import '../backup/backup_support.dart';
import 'fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BackupEnv env;
  final systemNow = LocalDb.nowMs;
  var clock = atMinute(1);
  SnoozeController controller({int taps = 2}) {
    final c = SnoozeController(
      now: () => clock,
      play: (_, {notes, onFirstWrite}) async {
        onFirstWrite?.call();
        return true;
      },
      confirmedWake: () async => false,
      recordEvidence: (_, _) async {},
      store: const DbSnoozeStore(),
      scheduler: FakeScheduler().call,
      settings: () => SnoozeSettings(enabled: true, requiredTaps: taps),
    );
    addTearDown(c.dispose);
    return c;
  }

  Future<List<WakeTraceEntry>> events() =>
      const DbWakeTraceStore().forWake(epoch);
  Future<void> seed(List<WakeTraceEntry> entries) async {
    for (final e in entries) {
      await const DbWakeTraceStore().append(e);
    }
  }

  setUpAll(() async {
    env = await BackupEnv.create('p2_wake_journal.db');
  });
  setUp(() async {
    await env.wipe();
    clock = atMinute(1);
    LocalDb.nowMs = () => atMinute(10).millisecondsSinceEpoch;
  });
  tearDownAll(() async {
    LocalDb.nowMs = systemNow;
    await env.dispose();
  });

  test(
    'controller writes every snooze with original epoch, event time and count across restart',
    () async {
      var c = controller();
      await c.onAlarmStopped(AlarmStopCause.expired, at: clock, fire: alarmAt);
      c.dispose();
      await LocalDb.close();
      c = controller();
      await c.resume();
      clock = atMinute(6);
      await c.tick(); // due re-alarm, delivered immediately by the band fake
      clock = atMinute(7);
      await c.tick(); // its unanswered listening window makes snooze #2
      await LocalDb.close();
      final rows = (await events()).where((e) => e.kind == 'snooze').toList();
      expect(rows.map((e) => e.atMs), [
        atMinute(1).millisecondsSinceEpoch,
        atMinute(7).millisecondsSinceEpoch,
      ]);
      expect(rows.map((e) => e.data['count']), [1, 2]);
      expect(rows.map((e) => e.wakeEpochSec), [epoch, epoch]);
    },
  );

  for (final reason in ['dismissed', 'im_up', 'limit', 'timeout']) {
    test(
      'snooze stop persists time and reason=$reason once after chain is cleared',
      () async {
        final c = controller(taps: 1);
        await c.onAlarmStopped(
          AlarmStopCause.expired,
          at: clock,
          fire: alarmAt,
        );
        switch (reason) {
          case 'dismissed':
            clock = atMinute(6);
            await c.tick();
            clock = clock.add(const Duration(seconds: 1));
            await c.onBandDoubleTap(clock, identity: 'tap-1');
          case 'im_up':
            clock = atMinute(2);
            await c.imUp();
          case 'limit':
            clock = atMinute(175);
            await c.tick(); // within 3 h: plays overdue re-alarm
            clock = atMinute(176);
            await c.tick(); // next due 181 >= 180 min bound
          case 'timeout':
            clock = atMinute(181);
            await c.tick(); // expired chain before re-alarm
        }
        await c.tick(); // no duplicate terminal event
        final stoppedAt = clock;
        c.dispose();
        await LocalDb.close();
        final rows = (await events())
            .where((e) => e.kind == 'snooze_stop')
            .toList();
        expect(rows.map((e) => [e.atMs, e.data['reason']]), [
          [stoppedAt.millisecondsSinceEpoch, reason],
        ]);
        expect(await const DbSnoozeStore().loadState(), isNull);
      },
    );
  }

  test(
    'a restart with an expired snooze records timeout instead of losing its stop',
    () async {
      final c = controller();
      await c.onAlarmStopped(AlarmStopCause.expired, at: clock, fire: alarmAt);
      c.dispose();
      await LocalDb.close();
      clock = atMinute(181);
      await controller().resume();
      final rows = (await events()).where((e) => e.kind == 'snooze_stop');
      expect(rows.map((e) => e.data['reason']), ['timeout']);
      expect(rows.single.atMs, clock.millisecondsSinceEpoch);
    },
  );

  for (final path in WakePath.values) {
    test(
      'dream answer persists on ack with preceding $path path after reopen',
      () async {
        await seed([
          if (path == WakePath.natural) row('natural', -20, {'reason': 'fire'}),
          if (path != WakePath.alarm) row('gradual', -15, {'result': 'sent'}),
          row('fallback', 0, {'fired': true}),
          row('ack', 8),
        ]);
        await const DbWakeJournal().answerDream(
          wakeEpochSec: epoch,
          at: atMinute(9),
          answer: DreamAnswer.dream,
        );
        await LocalDb.close();
        final ack = (await events()).singleWhere((e) => e.kind == 'ack');
        expect(ack.data, containsPair('dreamAnswer', 'dream'));
        expect(ack.data['wakePath'], path.name);
        expect(
          ack.data['dreamAnsweredAtMs'],
          atMinute(9).millisecondsSinceEpoch,
        );
        final n = await const DbWakeJournal().forEpoch(epoch);
        expect(n.dream?.answer, DreamAnswer.dream);
        expect(n.dream?.path, path);
      },
    );
  }

  test(
    'Skip writes nothing; normal answer is stored on its own epoch only',
    () async {
      await seed([row('ack', 8), row('ack', 8, {}, epoch + 86400)]);
      final before = await (await LocalDb.instance).query('wake_trace');
      await const DbWakeJournal().answerDream(
        wakeEpochSec: epoch,
        at: atMinute(9),
        answer: null,
      );
      expect(await (await LocalDb.instance).query('wake_trace'), before);
      await const DbWakeJournal().answerDream(
        wakeEpochSec: epoch,
        at: atMinute(9),
        answer: DreamAnswer.normal,
      );
      expect((await events()).single.data['dreamAnswer'], 'normal');
      expect(
        (await const DbWakeTraceStore().forWake(epoch + 86400)).single.data,
        {},
      );
    },
  );

  test(
    'backup restores journal events, dream and tune but never foreign run_state',
    () async {
      await seed([
        ...fullTrace(),
        row('tune', 9, {
          'reason': 'natural_dream_fast',
          'triggerRunOffsetSec': -15,
          'windowLeadMinutes': 1,
        }),
      ]);
      // Seed literal persisted ack fields independently of the RED write API.
      final db = await LocalDb.instance;
      await db.update(
        'wake_trace',
        {
          'data_json': jsonEncode({
            'dreamAnswer': 'dream',
            'wakePath': 'natural',
            'dreamAnsweredAtMs': atMinute(9).millisecondsSinceEpoch,
          }),
        },
        where: 'kind = ?',
        whereArgs: ['ack'],
      );
      await LocalDb.wakeMetaSet(
        'natural_wake_parameters',
        jsonEncode({
          'triggerRunOffsetSec': -15,
          'windowLeadMinutes': 1,
          'lastLearnedEpoch': epoch,
        }),
      );
      await LocalDb.wakeMetaSet(kWakeRunStateKey, '{"naturalFired":true}');
      await env.seedData();
      final path = await LocalDb.exportCopy();
      await env.wipe();
      await LocalDb.instance;
      await LocalDb.importFromDbFile(path);
      final restored = await events();
      expect(
        restored.where((e) => e.kind == 'snooze').map((e) => e.data['count']),
        [1, 2],
      );
      expect(
        restored
            .where((e) => e.kind == 'snooze_stop')
            .map((e) => e.data['reason']),
        ['im_up'],
      );
      expect(
        restored
            .where((e) => e.kind == 'ack')
            .map((e) => e.data['dreamAnswer']),
        ['dream'],
      );
      expect(
        restored.where((e) => e.kind == 'tune').map((e) => e.data['reason']),
        ['natural_dream_fast'],
      );
      expect(await LocalDb.wakeMetaGet(kWakeRunStateKey), isNull);
      final params = await const DbWakeJournal().parameters();
      expect(params.triggerRunOffsetSec, -15);
      expect(params.windowLeadMinutes, 1);
      expect(params.lastLearnedEpoch, epoch);
    },
  );

  test(
    'restore merges journal events without colliding with local trace row IDs',
    () async {
      await seed(fullTrace());
      await env.seedData();
      final path = await LocalDb.exportCopy();
      await env.wipe();
      await seed([
        row('ack', 10, {'dreamAnswer': 'normal'}, epoch + 3600),
      ]);
      await LocalDb.importFromDbFile(path);
      await LocalDb.importFromDbFile(path);
      expect(
        (await events())
            .where((e) => e.kind == 'snooze')
            .map((e) => e.data['count']),
        [1, 2],
      );
      expect(
        (await const DbWakeTraceStore().forWake(
          epoch + 3600,
        )).map((e) => e.data['dreamAnswer']),
        ['normal'],
      );
    },
  );

  test(
    'schema 79 reopen preserves a journal row and existing alarm settings',
    () async {
      final db = await LocalDb.instance;
      await db.insert('alarm_schedule', {
        'weekday': 0,
        'hour': 7,
        'minute': 0,
        'enabled': 1,
      });
      await seed([
        row('snooze', 1, {'count': 1}),
        row('ack', 8),
      ]);
      // No new table is required by the chosen trace/ack JSON representation.
      await db.execute('PRAGMA user_version = 79');
      await LocalDb.close();
      expect((await events()).map((e) => e.kind), ['snooze', 'ack']);
      expect((await LocalDb.alarmScheduleRows()).single['hour'], 7);
      expect(LocalDb.lastRebuild, isNull);
      await const DbWakeJournal().answerDream(
        wakeEpochSec: epoch,
        at: atMinute(9),
        answer: DreamAnswer.normal,
      );
      expect((await events()).last.data['dreamAnswer'], 'normal');
    },
  );
}
