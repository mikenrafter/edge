// Structural delivery checks, deliberately independent of detector maths.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/host.dart';
import 'package:openstrap_edge/ble/adapters/ble_hrs.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/derive_scheduler.dart';
import 'package:openstrap_edge/compute/derive_outcome.dart';
import 'package:openstrap_edge/compute/processing_context.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/models.dart';
import 'package:openstrap_edge/import/whoop_import.dart';
import 'package:openstrap_edge/notify/notification_center.dart';
import 'package:openstrap_edge/notify/notification_event.dart';
import 'package:openstrap_edge/notify/notification_ids.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final shown = <NotificationEvent>[];
  final original = NotificationCenter.instance.presentSink;
  late String path;
  late DateTime now;
  late String today;
  late String yesterday;

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
    NotificationCenter.instance.presentSink =
        (e, {bool allowPermissionPrompt = true}) async {
          shown.add(e);
          return true;
        };
    now = DateTime.now();
    today = dayLabelOf(now);
    yesterday = dayLabelBefore(today, 1)!;
    await LocalDb.putBaseline(
      'crossday',
      jsonEncode({
        'recent': [
          {'date': today},
        ],
      }),
    );
  });
  tearDown(() async {
    NotificationCenter.instance.presentSink = original;
    await LocalDb.close();
    await databaseFactory.deleteDatabase(path);
  });

  Future<ProcessingContext> arrive(
    DateTime recorded, {
    ProcessingOrigin origin = ProcessingOrigin.recentSync,
    int counter = 1,
  }) async {
    final ts = recorded.millisecondsSinceEpoch ~/ 1000;
    final raws = [
      RawRecord(
        counter: counter,
        hex: '2f18aabbccdd',
        recTs: ts,
        capturedAt: now.millisecondsSinceEpoch,
      ),
    ];
    final samples = [
      Sample(tsEpoch: ts, counter: counter, hr: 60, rrIntervalsMs: [1000]),
    ];
    if (origin == ProcessingOrigin.recentSync) {
      // Exercise the real native commit owner. Its adapter does not run here.
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
        : ProcessingContext.decode(fresh.single['processing_context']);
  }

  Future<void> notify(ProcessingContext context) => DerivationEngine()
      .runNotificationsForTest(today: today, processingContext: context);

  // why: a newly interpreted historical flag must never become a current alarm.
  // proves: CLAIM(pulse-origin); catches: treating today's/yesterday's label as freshness.
  test(
    'reanalysis flipping an old daily flag updates history silently',
    () async {
      await LocalDb.putMetricSeriesValue(yesterday, 'irregular_rhythm_flag', 0);
      await notify(ProcessingContext.reanalysis);
      await LocalDb.putMetricSeriesValue(yesterday, 'irregular_rhythm_flag', 1);
      await notify(ProcessingContext.reanalysis);
      expect(shown, isEmpty);
      expect(
        await LocalDb.metricValueOn(yesterday, 'irregular_rhythm_flag'),
        1,
      );
    },
  );

  // why: yesterday is a date, not proof of a newly arrived band recording.
  // proves: CLAIM(pulse-origin); catches: historical data promoted to recent sync.
  test(
    'import or historical backfill containing yesterday never alerts',
    () async {
      final recorded = DateTime.parse(yesterday).add(const Duration(hours: 23));
      await LocalDb.putMetricSeriesValue(yesterday, 'irregular_rhythm_flag', 1);
      final context = await arrive(
        recorded,
        origin: ProcessingOrigin.historical,
      );
      await notify(context);
      await notify(ProcessingContext.historical);
      expect(shown, isEmpty);
      expect(await LocalDb.computeJobs(), isEmpty);
      expect(await LocalDb.getCursor('strap_trim'), '0011223344556677');
    },
  );

  // why: a genuine catch-up day must reach the wearer with its recorded day.
  // proves: CLAIM(pulse-origin); catches: looking only at the newest cross-day anchor.
  test(
    'fresh catch-up inside 36 hours alerts once and names its day',
    () async {
      final recorded = DateTime.parse(yesterday).add(const Duration(hours: 23));
      final context = await arrive(recorded);
      await LocalDb.putMetricSeriesValue(yesterday, 'irregular_rhythm_flag', 1);
      await notify(context);
      expect(shown, hasLength(1));
      final e = shown.single;
      expect(e.date, yesterday);
      expect(e.dedupeKey, '$yesterday:irregular-pulse');
      expect(e.title, contains('${recorded.day}'));
      expect(e.title.toLowerCase(), isNot(contains('today')));
      expect(e.body, contains('matched our irregularity rule'));
      expect(e.body.toLowerCase(), isNot(contains('today')));
    },
  );

  // why: identical compute passes cannot repeatedly alarm the wearer.
  // proves: CLAIM(pulse-origin); catches: bypassing NotificationCenter's durable claim.
  test('repeating the same pass stays silent', () async {
    final context = await arrive(now.subtract(const Duration(minutes: 1)));
    await LocalDb.putMetricSeriesValue(today, 'irregular_rhythm_flag', 1);
    await notify(context);
    await notify(context);
    await LocalDb.close();
    await notify(ProcessingContext.decode(context.encode()));
    expect(shown, hasLength(1));
  });

  // why: the shared medical exception must not consume a genuine pulse day.
  test(
    'two new days retain independent keys after another medical notice',
    () async {
      await LocalDb.putBaseline(
        'crossday',
        jsonEncode({
          'recent': [
            {'date': today},
          ],
          'illness': {'date': today, 'state': 'red'},
        }),
      );
      await notify(ProcessingContext.reanalysis);
      expect(shown, hasLength(1));
      var context = await arrive(
        DateTime.parse(yesterday).add(const Duration(hours: 23)),
      );
      context = context.merge(
        await arrive(now.subtract(const Duration(seconds: 1)), counter: 2),
      );
      await LocalDb.putMetricSeriesValue(today, 'irregular_rhythm_flag', 1);
      await LocalDb.putMetricSeriesValue(yesterday, 'irregular_rhythm_flag', 1);
      await notify(context);
      await notify(context);
      expect(shown.map((e) => e.dedupeKey).toSet(), {
        '$today:exception:medical',
        '$today:irregular-pulse',
        '$yesterday:irregular-pulse',
      });
      expect(shown, hasLength(3));
    },
  );

  // why: a replayed/replaced second cannot reauthorize a historical flag.
  test('duplicate sync records do not create fresh eligibility', () async {
    final recorded = now.subtract(const Duration(minutes: 1));
    await arrive(recorded, origin: ProcessingOrigin.historical);
    final context = await arrive(recorded);
    expect(context.pulseDays, isEmpty);
    expect(await LocalDb.computeJobs(), isEmpty);
  });

  // why: eligibility must use record-to-arrival latency, including the boundary.
  test('36 hour budget is inclusive; older and future recordings abstain', () {
    final at = DateTime(2026, 11, 14, 12);
    ProcessingContext context(Duration latency) => ProcessingContext.arrival([
      (
        recordedMs: at.millisecondsSinceEpoch - latency.inMilliseconds,
        arrivedMs: at.millisecondsSinceEpoch,
      ),
    ]);
    expect(context(const Duration(hours: 36)).pulseDays.keys, ['2026-11-13']);
    expect(
      context(const Duration(hours: 36, milliseconds: 1)).pulseDays,
      isEmpty,
    );
    expect(context(const Duration(milliseconds: -1)).pulseDays, isEmpty);
    expect(
      context(const Duration(hours: 1)).allowsPulseDay(
        '2026-11-14',
        at.add(const Duration(hours: 36, milliseconds: 1)),
      ),
      isFalse,
    );
  });

  // why: retry error text and a process restart must not erase or promote origin.
  test(
    'job creation preserves origin through retry and scheduler recovery',
    () async {
      final fresh = await arrive(now.subtract(const Duration(minutes: 1)));
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
    },
  );

  // why: the health switch remains authoritative for pulse delivery.
  test('muted health preferences suppress a fresh flag', () async {
    final context = await arrive(now.subtract(const Duration(minutes: 1)));
    await LocalDb.putMetricSeriesValue(today, 'irregular_rhythm_flag', 1);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('notif_health', false);
    await notify(context);
    expect(shown, isEmpty);
  });
  // why: optional alert intent must never turn a durable chunk into a sync failure.
  test(
    'delivery metadata failure preserves committed pulse records and analytics',
    () async {
      final db = await LocalDb.instance;
      const payload = '{"clinical":{"legacy":"unchanged"}}';
      await LocalDb.putDayResult(
        dayId: yesterday,
        algoVersion: kAlgoVersion,
        payloadJson: payload,
        windowJson: '{}',
      );
      await LocalDb.putMetricSeriesValue(yesterday, 'irregular_rhythm_flag', 1);
      await db.execute(
        "CREATE TRIGGER reject_pulse_job BEFORE INSERT ON compute_jobs "
        "BEGIN SELECT RAISE(FAIL, 'delivery unavailable'); END",
      );
      await arrive(now.subtract(const Duration(minutes: 1)));
      expect(await LocalDb.getCursor('strap_trim'), '0011223344556677');
      expect(await db.query('decoded_onehz'), hasLength(1));
      expect(await db.query('decoded_rr'), hasLength(1));
      expect((await LocalDb.dayResult(yesterday))!['payload_json'], payload);
      expect(
        await LocalDb.metricValueOn(yesterday, 'irregular_rhythm_flag'),
        1,
      );
      expect(await LocalDb.computeJobs(), isEmpty);
    },
  );

  // why: new input must not relabel a version recompute or forced reanalysis as fresh.
  test(
    'forced passes, algorithm migrations and imported results stay silent',
    () async {
      final context = await arrive(now.subtract(const Duration(minutes: 1)));
      await LocalDb.putMetricSeriesValue(today, 'irregular_rhythm_flag', 1);
      for (final guarded in [
        context.forDerivation(
          forced: true,
          algoVersion: 119,
          previous: const {},
        ),
        context.forDerivation(
          forced: false,
          algoVersion: 119,
          previous: {today: (version: 118, imported: false)},
        ),
        context.forDerivation(
          forced: false,
          algoVersion: 119,
          previous: {today: (version: 119, imported: true)},
        ),
      ]) {
        await notify(guarded);
      }
      expect(shown, isEmpty);
      await notify(
        context.forDerivation(
          forced: false,
          algoVersion: 119,
          previous: {today: (version: 119, imported: false)},
        ),
      );
      expect(shown, hasLength(1));
    },
  );

  // why: a restore can replace history while a formerly fresh job is queued/running.
  test(
    'import invalidation silences existing contexts without poisoning new sync',
    () async {
      final before = await arrive(now.subtract(const Duration(minutes: 2)));
      await LocalDb.putMetricSeriesValue(today, 'irregular_rhythm_flag', 1);
      final temp = await Directory.systemTemp.createTemp('pulse_import_');
      try {
        final csv = File(p.join(temp.path, 'history.csv'));
        await csv.writeAsString(
          'Cycle start time,Wake onset,Recovery score %,Resting heart rate (bpm)\n'
          '$yesterday 08:30:00,$yesterday 08:30:00,50,60\n',
        );
        await WhoopImporter.importFiles([csv.path]);
      } finally {
        await temp.delete(recursive: true);
      }
      await LocalDb.close();
      await notify(ProcessingContext.decode(before.encode()));
      expect(shown, isEmpty);
      final after = await arrive(
        now.subtract(const Duration(minutes: 1)),
        counter: 2,
      );
      await notify(after);
      expect(shown, hasLength(1));
      expect(after.historyRevision, greaterThan(before.historyRevision));
    },
  );
  // why: splitting the old shared key must not re-alert an already flagged day
  // on upgrade, and must leave the next genuine pulse day available.
  test(
    'schema upgrade carries an existing pulse day claim into the dedicated key',
    () async {
      final old = await arrive(
        DateTime.parse(yesterday).add(const Duration(hours: 23)),
      );
      await LocalDb.putMetricSeriesValue(yesterday, 'irregular_rhythm_flag', 1);
      await LocalDb.claimNotifFired('$yesterday:exception:medical');
      await LocalDb.putMetricSeriesValue(today, 'irregular_rhythm_flag', 0);
      await LocalDb.claimNotifFired('$today:exception:medical');
      final db = await LocalDb.instance;
      await db.execute('PRAGMA user_version = 86');
      await LocalDb.close();
      await notify(old);
      expect(shown, isEmpty);
      expect(
        await LocalDb.notifFiredExists('$yesterday:irregular-pulse'),
        isTrue,
      );
      final fresh = await arrive(
        now.subtract(const Duration(seconds: 1)),
        counter: 2,
      );
      await LocalDb.putMetricSeriesValue(today, 'irregular_rhythm_flag', 1);
      await notify(fresh);
      expect(shown.map((e) => e.dedupeKey), ['$today:irregular-pulse']);
    },
  );
}
