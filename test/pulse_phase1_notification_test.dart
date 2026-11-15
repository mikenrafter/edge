// Delivery policy for a flagged irregular-pulse day, independent of detector
// maths: every flagged day is announced exactly once, whenever it is first
// found and however old, under its own recorded day. A band sync announces its
// days one by one; every other path folds them into ONE summary; notifications
// that are off are recorded and summarised later; a durable per-day record says
// what happened.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:openstrap_edge/ble/adapters/ble_hrs.dart';
import 'package:openstrap_edge/ble/adapters/host.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/derive_outcome.dart';
import 'package:openstrap_edge/compute/derive_scheduler.dart';
import 'package:openstrap_edge/compute/processing_context.dart';
import 'package:openstrap_edge/compute/pulse_alert_delivery.dart';
import 'package:openstrap_edge/compute/pulse_alert_record.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/models.dart';
import 'package:openstrap_edge/notify/notification_center.dart';
import 'package:openstrap_edge/notify/notification_event.dart';
import 'package:openstrap_edge/notify/notification_ids.dart';
import 'package:openstrap_edge/notify/notification_prefs.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _flag = 'irregular_rhythm_flag';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final shown = <NotificationEvent>[];
  final original = NotificationCenter.instance.presentSink;
  var osAccepts = true;
  late String path;
  late DateTime now;
  late String today;

  String daysAgo(int n) => dayLabelBefore(today, n)!;
  String niceDay(String day) =>
      DateFormat.yMMMEd('en').format(DateTime.parse(day));
  bool isSummary(NotificationEvent e) => e.dedupeKey.startsWith('pulse-summary:');

  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await LocalDb.close();
    LocalDb.dbName = 'pulse_phase1.db';
    path = p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName);
    await databaseFactory.deleteDatabase(path);
    SharedPreferences.setMockInitialValues({'notif_quiet_enabled': false});
    NotificationIds.instance.resetForTest();
    shown.clear();
    osAccepts = true;
    NotificationCenter.instance.presentSink =
        (e, {bool allowPermissionPrompt = true}) async {
          if (!osAccepts) return false;
          shown.add(e);
          return true;
        };
    now = DateTime.now();
    today = dayLabelOf(now);
  });
  tearDown(() async {
    NotificationCenter.instance.presentSink = original;
    await LocalDb.close();
    await databaseFactory.deleteDatabase(path);
  });

  /// 22:00 on [day] by the wall clock (a day is not always 24 h across DST).
  DateTime eveningOf(String day) {
    final d = DateTime.parse(day);
    return DateTime(d.year, d.month, d.day, 22);
  }

  /// A band batch carrying one pulse record recorded at [recorded], received
  /// now: what a sync after days away looks like.
  Future<ProcessingContext> arrive(
    DateTime recorded, {
    ProcessingOrigin origin = ProcessingOrigin.recentSync,
    int counter = 1,
  }) async {
    final ts = recorded.millisecondsSinceEpoch ~/ 1000;
    final raws = [
      RawRecord(
        counter: counter,
        hex: '2f18aabbccdd$counter',
        recTs: ts,
        capturedAt: now.millisecondsSinceEpoch,
      ),
    ];
    final samples = [
      Sample(tsEpoch: ts, counter: counter, hr: 60, rrIntervalsMs: [1000]),
    ];
    if (origin == ProcessingOrigin.recentSync) {
      await BandHost(
        adapter: kBleHrsAdapter,
        deviceId: LocalDb.kPrimaryDeviceId,
      ).commitNativeBatch(raws, samples, '0011223344556677');
    } else {
      await LocalDb.commitSyncBatch(
        raws,
        samples,
        processingOrigin: origin,
        trimToken: '0011223344556677',
      );
    }
    final jobs = await LocalDb.computeJobs(state: 'queued');
    final fresh = jobs.where(
      (j) =>
          ProcessingContext.decode(j['processing_context']).origin ==
          ProcessingOrigin.recentSync,
    );
    return fresh.isEmpty
        ? ProcessingContext.reanalysis
        : ProcessingContext.decode(fresh.first['processing_context']);
  }

  /// The wearer's Health alerts switch, through the real settings seam (the
  /// stored blob owns the rule once it exists, not the legacy bool).
  Future<void> healthAlerts(bool on) async => (await NotificationPrefs.load())
      .copyWith(healthEnabled: on)
      .save();

  Future<void> flag(String day) =>
      LocalDb.putMetricSeriesValue(day, _flag, 1);

  /// The notification step of a derive pass, with that pass's context.
  Future<void> notify(ProcessingContext context) => DerivationEngine()
      .runNotificationsForTest(today: today, processingContext: context);

  Future<PulseAlertRecord?> record(String day) async =>
      (await LocalDb.pulseAlertRecords())[day];

  // why: rule 1. A catch-up after days away is still news, once, under the day
  // it was recorded; the age of the day is no reason to skip or to relabel it.
  // proves: CLAIM(pulse-origin); catches: an age or calendar gate on a sync day.
  test('a sync with a 3-day-old flag alerts once, named correctly', () async {
    final day = daysAgo(3);
    final context = await arrive(eveningOf(day));
    expect(context.pulseDays.keys, [day]);
    await flag(day);
    await notify(context);
    expect(shown, hasLength(1));
    final e = shown.single;
    expect(e.date, day);
    expect(e.dedupeKey, '$day:irregular-pulse');
    // The exact date, not a day number that "2026" would also contain.
    expect(e.title, 'Irregular pulse pattern flagged on ${niceDay(day)}');
    expect(e.body, contains('recorded on ${niceDay(day)}'));
    expect(e.title.toLowerCase(), isNot(contains('today')));
    final r = (await record(day))!;
    expect(r.state, PulseAlertState.sent);
    expect(r.atMs, closeTo(DateTime.now().millisecondsSinceEpoch, 60000));
    // Another pass over the same arrival, and one after reopening the database.
    await notify(context);
    await LocalDb.close();
    await notify(ProcessingContext.decode(context.encode()));
    expect(shown, hasLength(1));
  });

  // why: rule 2. A reanalysis that flips old days must neither stay silent nor
  // buzz once per day: one notification names them all, and they never alert
  // again, by any path.
  // proves: CLAIM(pulse-origin); catches: silence, one-per-day, or re-alerting.
  test('a reanalysis that flips two old days sends one summary', () async {
    final a = daysAgo(5), b = daysAgo(2);
    await flag(a);
    await flag(b);
    await notify(ProcessingContext.reanalysis);
    expect(shown, hasLength(1));
    final e = shown.single;
    expect(isSummary(e), isTrue);
    expect(e.title, 'Irregular pulse flags found on 2 days');
    expect(e.body, contains('${niceDay(a)}; ${niceDay(b)}'));
    expect(e.route, '/heart');
    for (final day in [a, b]) {
      final r = (await record(day))!;
      expect(r.state, PulseAlertState.summary, reason: day);
    }
    // Neither alerts again: another bulk pass, a sync context naming them, or a
    // flag that flips off and on.
    await notify(ProcessingContext.reanalysis);
    await notify(
      ProcessingContext(ProcessingOrigin.recentSync, {
        a: now.millisecondsSinceEpoch,
        b: now.millisecondsSinceEpoch,
      }),
    );
    await LocalDb.putMetricSeriesValue(a, _flag, 0);
    await flag(a);
    await notify(ProcessingContext.historical);
    expect(shown, hasLength(1));
  });

  // why: rule 2 for an import. Imported history is bulk by definition.
  test('an import (historical origin) gives one summary', () async {
    final days = [daysAgo(9), daysAgo(8), daysAgo(7)];
    for (final d in days) {
      await flag(d);
    }
    await notify(ProcessingContext.historical);
    expect(shown, hasLength(1));
    expect(shown.single.title, 'Irregular pulse flags found on 3 days');
    expect(
      shown.single.body,
      contains(days.map(niceDay).join('; ')),
    );
  });

  // why: a long list must stay a notification, not a wall of dates.
  test('a summary prints the newest five days and counts the rest', () async {
    final days = [for (var i = 12; i >= 6; i--) daysAgo(i)];
    for (final d in days) {
      await flag(d);
    }
    await notify(ProcessingContext.reanalysis);
    expect(shown, hasLength(1));
    expect(shown.single.title, 'Irregular pulse flags found on 7 days');
    expect(
      shown.single.body,
      contains('${days.skip(2).map(niceDay).join('; ')} and 2 more'),
    );
    for (final d in days) {
      expect((await record(d))!.state, PulseAlertState.summary);
    }
  });

  // why: a first sync of a long backlog must not become a flood of buzzes.
  test('more than three sync days in one pass fold into one summary', () async {
    var context = const ProcessingContext(ProcessingOrigin.recentSync);
    for (var i = 1; i <= 4; i++) {
      final day = daysAgo(i);
      await flag(day);
      context = context.merge(
        ProcessingContext(ProcessingOrigin.recentSync, {
          day: now.millisecondsSinceEpoch,
        }),
      );
    }
    await notify(context);
    expect(shown, hasLength(1));
    expect(isSummary(shown.single), isTrue);
    expect(shown.single.title, contains('4 days'));
  });

  // why: rule 3. Notifications that are off must not lose the day: it is
  // recorded as not sent and announced, once, when delivery works again.
  // proves: CLAIM(pulse-origin); catches: a refused alert burning the day.
  test(
    'with notifications off the day is recorded, then summarised once',
    () async {
      final day = daysAgo(2);
      final context = await arrive(eveningOf(day));
      await flag(day);
      await healthAlerts(false);
      await notify(context);
      expect(shown, isEmpty);
      var r = (await record(day))!;
      expect(r.state, PulseAlertState.notSent);
      expect(r.reason, PulseAlertReason.off);
      expect(await LocalDb.pulseDaysToAlert(), [day]);

      await healthAlerts(true);
      await notify(ProcessingContext.reanalysis);
      expect(shown, hasLength(1));
      expect(isSummary(shown.single), isTrue);
      expect(shown.single.title, 'Irregular pulse flag found on 1 day');
      expect(shown.single.body, contains(niceDay(day)));
      r = (await record(day))!;
      expect(r.state, PulseAlertState.summary);
      await notify(ProcessingContext.reanalysis);
      await notify(context);
      expect(shown, hasLength(1));
    },
  );

  // why: "off in settings" and "the OS said no" are different things to tell
  // the wearer, and the second is not a settings problem.
  test('an OS refusal is recorded as blocked, not as off', () async {
    final day = daysAgo(1);
    final context = await arrive(eveningOf(day));
    await flag(day);
    osAccepts = false;
    await notify(context);
    expect(shown, isEmpty);
    final r = (await record(day))!;
    expect((r.state, r.reason), (PulseAlertState.notSent, PulseAlertReason.blocked));
    osAccepts = true;
    await notify(ProcessingContext.reanalysis);
    expect(shown, hasLength(1));
    expect((await record(day))!.state, PulseAlertState.summary);
  });

  // why: rule 5. A key that was claimed by an earlier pass that stopped before
  // writing its record is the one alert the day gets; it must not send again.
  test('a day whose key was already claimed is unknown, not re-sent', () async {
    final day = daysAgo(2);
    await flag(day);
    await LocalDb.claimNotifFired('$day:irregular-pulse');
    await notify(
      ProcessingContext(ProcessingOrigin.recentSync, {
        day: now.millisecondsSinceEpoch,
      }),
    );
    expect(shown, isEmpty);
    // Nothing says whether that claim ever reached the screen: unknown, with the
    // claim's time, and never sent again.
    expect((await record(day))!.state, PulseAlertState.unknown);
  });

  // why: rule 4 and the policy for non-sync passes that carried records too.
  // A forced pass, an algorithm migration and an imported result are bulk
  // paths even when new records arrived with them: one summary, never silence,
  // never an individual alert. The clean sync pass still alerts by itself.
  // proves: CLAIM(pulse-origin); catches: deleting the engine's forDerivation.
  test('forced, migrated and imported days go in a summary; clean ones alert',
      () async {
    final context = ProcessingContext(ProcessingOrigin.recentSync, {
      for (var i = 1; i <= 4; i++) daysAgo(i): now.millisecondsSinceEpoch,
    });
    final guards = <String, ProcessingContext>{
      daysAgo(1): context.forDerivation(
        forced: true,
        algoVersion: 119,
        previous: const {},
      ),
      daysAgo(2): context.forDerivation(
        forced: false,
        algoVersion: 119,
        previous: {daysAgo(2): (version: 118, imported: false)},
      ),
      daysAgo(3): context.forDerivation(
        forced: false,
        algoVersion: 119,
        previous: {daysAgo(3): (version: 119, imported: true)},
      ),
    };
    for (final e in guards.entries) {
      shown.clear();
      await flag(e.key);
      await notify(e.value);
      expect(shown, hasLength(1), reason: e.key);
      expect(isSummary(shown.single), isTrue, reason: e.key);
      expect((await record(e.key))!.state, PulseAlertState.summary);
    }
    shown.clear();
    final clean = daysAgo(4);
    await flag(clean);
    await notify(
      context.forDerivation(
        forced: false,
        algoVersion: 119,
        previous: {clean: (version: 119, imported: false)},
      ),
    );
    expect(shown.map((e) => e.dedupeKey), ['$clean:irregular-pulse']);
  });

  // why: a replayed second must not count as an arrival, so replays cannot
  // turn history into individual alerts.
  test('duplicate sync records do not create a new arrival', () async {
    final recorded = eveningOf(daysAgo(1));
    await arrive(recorded, origin: ProcessingOrigin.historical);
    final context = await arrive(recorded);
    expect(context.pulseDays, isEmpty);
    expect(await LocalDb.computeJobs(), isEmpty);
  });

  // why: the origin must survive a retry and a process restart, because it is
  // what picks individual alerts over a summary.
  test('job creation preserves origin through retry and scheduler recovery',
      () async {
    final fresh = await arrive(eveningOf(daysAgo(1)));
    await LocalDb.enqueueDeriveJob(
      type: 'derive_heavy',
      reason: 'import',
      processingContext: ProcessingContext.historical,
    );
    final job = (await LocalDb.takeNextComputeJob())!;
    expect(
      ProcessingContext.decode(job['processing_context']).pulseDays,
      fresh.pulseDays,
    );
    await LocalDb.retryComputeJob(
      job['id'] as String,
      'temporary failure',
      Duration.zero,
    );
    await LocalDb.close();
    late DeriveScheduler scheduler;
    final ran = <ProcessingContext>[];
    scheduler = DeriveScheduler(
      run: ({required kind}) async {
        ran.add(scheduler.runningContext);
        return const DeriveOutcome();
      },
      log: (_) {},
      onChanged: () {},
      lightSettle: Duration.zero,
      heavySettle: Duration.zero,
    );
    await scheduler.init();
    for (var i = 0; i < 100 && ran.length < 2; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    scheduler.dispose();
    expect(ran.map((c) => c.origin), [
      ProcessingOrigin.recentSync,
      ProcessingOrigin.historical,
    ]);
    expect(ran.first.pulseDays, fresh.pulseDays);
    expect(ran.last.pulseDays, isEmpty);
  });

  // why: optional alert intent must never turn a durable chunk into a sync failure.
  test('delivery metadata failure preserves committed pulse records', () async {
    final db = await LocalDb.instance;
    await db.execute(
      "CREATE TRIGGER reject_pulse_job BEFORE INSERT ON compute_jobs "
      "BEGIN SELECT RAISE(FAIL, 'delivery unavailable'); END",
    );
    await arrive(eveningOf(daysAgo(1)));
    expect(await LocalDb.getCursor('strap_trim'), '0011223344556677');
    expect(await db.query('decoded_onehz'), hasLength(1));
    expect(await db.query('decoded_rr'), hasLength(1));
    expect(await LocalDb.computeJobs(), isEmpty);
  });

  // why: upgrading must not re-announce a day the old build already alerted,
  // and must announce the flagged days it never did, once.
  test('schema upgrade keeps old pulse alerts and summarises the rest', () async {
    final old = daysAgo(3), unalerted = daysAgo(1);
    await flag(old);
    await LocalDb.claimNotifFired('$old:exception:medical');
    await flag(unalerted);
    final db = await LocalDb.instance;
    await db.execute('DROP TABLE pulse_alert');
    await db.execute('PRAGMA user_version = 86');
    await LocalDb.close();
    await notify(ProcessingContext.reanalysis);
    expect(await LocalDb.notifFiredExists('$old:irregular-pulse'), isTrue);
    expect((await record(old))!.state, PulseAlertState.earlier);
    expect(shown, hasLength(1));
    expect(isSummary(shown.single), isTrue);
    expect(shown.single.body, contains(niceDay(unalerted)));
    expect(shown.single.body, isNot(contains(niceDay(old))));
  });

  // why: the new table is part of the store; PulseAlertDelivery must be safe to
  // call on a database with nothing flagged.
  test('nothing flagged sends nothing', () async {
    await PulseAlertDelivery.run(individualDays: {daysAgo(1)});
    expect(shown, isEmpty);
    expect(jsonEncode(await LocalDb.pulseAlertRecords()), '{}');
  });
}
