import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/alarm/snooze/snooze_settings.dart';
import 'package:openstrap_edge/alarm/snooze/snooze_controller.dart';
import 'package:openstrap_edge/alarm/snooze/alarm_stop_policy.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/wake/wake_journal.dart';
import 'package:openstrap_edge/wake/wake_stores.dart';
import 'package:openstrap_edge/wake/wake_outcome.dart';

import '../backup/backup_support.dart';
import '../alarm_snooze/snooze_fakes.dart' show FakeScheduler;
import 'fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BackupEnv env;
  setUpAll(() async => env = await BackupEnv.create('p2_journal_retention.db'));
  setUp(() async => env.wipe());
  tearDownAll(() async => env.dispose());

  test(
    'old journal survives diagnostic pruning and repeated backup merge beyond 400 rows',
    () async {
      const trace = DbWakeTraceStore();
      await trace.append(row('plan', -30));
      await trace.append(row('natural', -20, {'reason': 'fire'}));
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
      await trace.append(row('ack', 8));
      // A new wake, 30 elapsed days later, prunes old diagnostic rows only.
      await trace.append(row('plan', 0, {}, epoch + 30 * 86400));
      expect(
        (await LocalDb.wakeTraceRows(epoch)).where((r) => r['kind'] == 'plan'),
        isEmpty,
      );
      expect(
        await trace.forWake(epoch),
        hasLength(400),
      ); // diagnostic cap remains
      expect(
        (await const DbWakeJournal().forEpoch(epoch)).events,
        hasLength(422),
      );
      await env.seedData();
      final backup = await LocalDb.exportCopy();
      await env.wipe();
      await LocalDb.importFromDbFile(backup);
      await LocalDb.importFromDbFile(backup);
      final night = await const DbWakeJournal().forEpoch(epoch);
      expect(night.events, hasLength(422));
      expect(night.firstFireAt, atMinute(-20));
      expect(night.timeToWake, const Duration(minutes: 28));
      expect(
        await LocalDb.wakeTraceRows(epoch + 30 * 86400),
        isEmpty,
        reason: 'foreign diagnostic-only rows do not merge',
      );
    },
  );

  test(
    'a rejected snooze journal write rolls back pending state and window together',
    () async {
      const store = DbSnoozeStore();
      final window = SnoozeWindow(stoppedAt: atMinute(1), fireAt: alarmAt);
      await store.saveWindow(window);
      final db = await LocalDb.instance;
      await db.execute(
        "CREATE TRIGGER reject_snooze BEFORE INSERT ON wake_trace "
        "WHEN NEW.kind = 'snooze' BEGIN SELECT RAISE(ABORT, 'journal rejected'); END",
      );
      final state = SnoozeState(
        count: 1,
        reAlarmAt: atMinute(6),
        fireAt: alarmAt,
      );
      Future<void> save() => store.saveJournalTransition(
        fireAt: alarmAt,
        at: atMinute(1),
        count: 1,
        state: state,
      );
      await expectLater(save(), throwsA(isA<Exception>()));
      expect(await store.loadState(), isNull);
      expect((await store.loadWindow())?.stoppedAt.millisecondsSinceEpoch,
          atMinute(1).millisecondsSinceEpoch);
      expect(await LocalDb.wakeTraceRows(epoch), isEmpty);
      await db.execute('DROP TRIGGER reject_snooze');
      await save();
      final restored = await store.loadState();
      expect(restored?.count, 1);
      expect(restored?.reAlarmAt.millisecondsSinceEpoch,
          atMinute(6).millisecondsSinceEpoch);
      expect(restored?.fireAt?.millisecondsSinceEpoch,
          alarmAt.millisecondsSinceEpoch);
      expect(await store.loadWindow(), isNull);
      expect(
        (await const DbWakeTraceStore().forWake(epoch)).single.data['count'],
        1,
      );
    },
  );

  test(
    'a local dream answer survives a foreign acknowledgement and a second answer',
    () async {
      const trace = DbWakeTraceStore();
      const journal = DbWakeJournal();
      await trace.append(row('natural', -20, {'reason': 'fire'}));
      await trace.append(row('ack', 8));
      await env.seedData();
      final backup = await LocalDb.exportCopy();
      await journal.answerDream(
        wakeEpochSec: epoch,
        at: atMinute(9),
        answer: DreamAnswer.normal,
      );
      await LocalDb.importFromDbFile(backup);
      await journal.answerDream(
        wakeEpochSec: epoch,
        at: atMinute(10),
        answer: DreamAnswer.dream,
      );
      final ack = (await trace.forWake(
        epoch,
      )).singleWhere((e) => e.kind == 'ack');
      expect(ack.data['dreamAnswer'], 'normal');
      expect(ack.data['dreamAnsweredAtMs'], atMinute(9).millisecondsSinceEpoch);
    },
  );
  for (final restored in [false, true]) {
    test(
      'confirmed dismiss window journals its terminal transition, restored=$restored',
      () async {
        var clock = atMinute(1);
        var confirmed = false;
        final controller = SnoozeController(
          now: () => clock,
          play: (_, {notes, onFirstWrite}) async => true,
          confirmedWake: () async => confirmed,
          recordEvidence: (_, _) async {},
          store: const DbSnoozeStore(),
          settings: () => const SnoozeSettings(enabled: true),
          scheduler: FakeScheduler().call,
        );
        addTearDown(controller.dispose);
        if (restored) {
          await const DbSnoozeStore().saveWindow(
            SnoozeWindow(stoppedAt: clock, fireAt: alarmAt),
          );
          confirmed = true;
          await controller.resume();
        } else {
          await controller.onAlarmStopped(
            AlarmStopCause.userDoubleTap,
            at: clock,
            fire: alarmAt,
          );
          confirmed = true;
          clock = atMinute(2);
          await controller.tick();
        }
        await controller.tick();
        expect(await const DbSnoozeStore().loadWindow(), isNull);
        final rows = await LocalDb.wakeTraceRows(epoch);
        expect(rows.map((r) => r['kind']), ['snooze_stop']);
        expect(jsonDecode(rows.single['data_json'] as String), {
          'count': 0,
          'reason': 'im_up',
        });
        expect(rows.single['at_ms'], clock.millisecondsSinceEpoch);
      },
    );
  }
}
