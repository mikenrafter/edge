// Pulse phase 1, end to end: a band batch committed through BandHost (or a
// writer that never opted in), the real DeriveScheduler, DeriveCoordinator and
// DerivationEngine, and the notification that comes out. No context is built by hand, so every link that carries the
// origin (intake -> queued job -> scheduler -> coordinator -> engine -> pass) is
// on the path. The detector is real too: the test data is a synthetic RR series
// the screen flags, and every test asserts that flag first, so a silent result
// is silent because of the origin and not because nothing was flagged.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:openstrap_edge/ble/adapters/ble_hrs.dart';
import 'package:openstrap_edge/ble/adapters/host.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/processing_context.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/compute/pulse_episode_worker.dart';
import 'package:openstrap_edge/compute/pulse_alert_record.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/models.dart';
import 'package:openstrap_edge/notify/notification_center.dart';
import 'package:openstrap_edge/notify/notification_event.dart';
import 'package:openstrap_edge/notify/notification_ids.dart';
import 'package:openstrap_edge/notify/notification_prefs.dart';
import 'package:openstrap_edge/state/derive_coordinator.dart';
import 'package:path/path.dart' as p;
import 'pulse_band_fixture.dart' show ProbeFn;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _flag = 'irregular_rhythm_flag';
const _trim = '0011223344556677';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final shown = <NotificationEvent>[];
  final original = NotificationCenter.instance.presentSink;
  late String path;
  late DateTime now;
  late String today;
  late String yesterday;
  late DeriveCoordinator coordinator;
  var counter = 0;

  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await LocalDb.close();
    LocalDb.dbName = 'pulse_phase1_pipeline.db';
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
    counter = 0;
    coordinator = DeriveCoordinator(
      engine: () => DerivationEngine(log: (_) {}),
      profile: () => Profile.fromMap(const <String, dynamic>{}),
      log: (_) {},
      notify: () {},
      isDisposed: () => false,
      repo: () => null,
      warmHeld: () => false,
      refreshPhoneStepsToday: () async {},
      maybeNotifyRecoveryReady: () async {},
      runHealthExport: () async => 0,
      healthSyncEnabled: () => false,
      telemetryConsent: () => false,
      healthShareConsent: () => false,
      maybeReclaimDiskSpace: () async {},
      schedulerSettle: const Duration(milliseconds: 10),
    )..debugRescanRecent = ({onScopeDays, onDayDone}) async => 0;
  });

  tearDown(() async {
    coordinator.dispose();
    NotificationCenter.instance.presentSink = original;
    await LocalDb.close();
    await databaseFactory.deleteDatabase(path);
  });

  /// [seconds] of 1 Hz records from [start], one irregular beat each. Arrival is
  /// [now] for all of them: a phone that was away and catches up in one batch.
  ({List<RawRecord> raws, List<Sample?> samples}) records(
    DateTime start,
    int seconds,
  ) {
    final rng = Random(7);
    final first = start.millisecondsSinceEpoch ~/ 1000;
    final raws = <RawRecord>[];
    final samples = <Sample?>[];
    for (var i = 0; i < seconds; i++) {
      final c = ++counter;
      raws.add(
        RawRecord(
          counter: c,
          packetType: 47,
          hex: '2f18${c.toRadixString(16).padLeft(8, '0')}',
          recTs: first + i,
          capturedAt: now.millisecondsSinceEpoch,
        ),
      );
      samples.add(
        Sample(
          tsEpoch: first + i,
          counter: c,
          hr: 70,
          rrIntervalsMs: [700 + rng.nextInt(301)],
        ),
      );
    }
    return (raws: raws, samples: samples);
  }

  DateTime eveningOf(String day) {
    final d = DateTime.parse(day);
    return DateTime(d.year, d.month, d.day, 22);
  }

  DateTime yesterdayEvening() => eveningOf(yesterday);
  String daysAgo(int n) => dayLabelBefore(today, n)!;
  bool isSummary(NotificationEvent e) => e.dedupeKey.startsWith('pulse-summary:');
  Future<PulseAlertState?> alertState(String day) async =>
      (await LocalDb.pulseAlertRecords())[day]?.state;

  /// The band's own commit path, which opts in to recent-sync provenance.
  Future<void> bandCommit(DateTime start, int seconds) async {
    final r = records(start, seconds);
    await BandHost(
      adapter: kBleHrsAdapter,
      deviceId: LocalDb.kPrimaryDeviceId,
    ).commitNativeBatch(r.raws, r.samples, _trim);
  }

  /// A writer that never opted in: history, import, backfill, restore.
  Future<void> historicalCommit(DateTime start, int seconds) async {
    final r = records(start, seconds);
    await LocalDb.commitSyncBatch(r.raws, r.samples, trimToken: _trim);
  }

  /// Start the real scheduler on whatever is queued and wait until every job it
  /// can run has run (a parked `failed` job does not count).
  Future<void> drainScheduler() async {
    await coordinator.scheduler.init();
    final end = DateTime.now().add(const Duration(minutes: 3));
    var quiet = 0;
    while (quiet < 5) {
      if (!DateTime.now().isBefore(end)) {
        throw TestFailure('timed out waiting for the scheduler to drain');
      }
      final jobs = await LocalDb.computeJobs();
      final busy =
          coordinator.scheduler.running ||
          jobs.any((j) => j['state'] != 'failed');
      quiet = busy ? 0 : quiet + 1;
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
  }

  Future<List<ProcessingOrigin>> queuedOrigins() async => [
    for (final j in await LocalDb.computeJobs(state: 'queued'))
      ProcessingContext.decode(j['processing_context']).origin,
  ];

  bool nearMidnight() =>
      now.difference(DateTime(now.year, now.month, now.day)) <
      const Duration(minutes: 16);

  // why: DS1 and rule 1. A morning catch-up carries yesterday evening and
  // today's morning in one batch. The authorized pass is a light pass; it must
  // derive every day the batch touched, so each is announced by itself.
  // proves: CLAIM(pulse-origin); catches: a light recent-sync scope of [today],
  // `processingContext: ProcessingContext.reanalysis` in the coordinator,
  // dropping the engine's context argument.
  test('a catch-up batch alerts once for every day it touched', () async {
    if (nearMidnight()) {
      // Today's twelve minutes of data would reach back before midnight.
      markTestSkipped('needs 16 minutes of today before now');
      return;
    }
    await bandCommit(yesterdayEvening(), 720);
    await bandCommit(now.subtract(const Duration(minutes: 14)), 720);
    expect(await queuedOrigins(), [ProcessingOrigin.recentSync]);

    await drainScheduler();

    expect(await LocalDb.metricValueOn(yesterday, _flag), 1.0);
    expect(await LocalDb.metricValueOn(today, _flag), 1.0);
    expect(shown.map((e) => e.dedupeKey).toSet(), {
      '$yesterday:irregular-pulse',
      '$today:irregular-pulse',
    });
    expect(shown, hasLength(2));
    expect(await alertState(yesterday), PulseAlertState.sent);
    expect(await alertState(today), PulseAlertState.sent);

    // The same arrival again (a second sync that re-queues the same days) must
    // not buzz twice: the key is claimed and the record is final.
    await LocalDb.enqueueDeriveJob(
      type: 'derive_light',
      reason: 'recent_pulse_sync',
      processingContext: ProcessingContext.arrival([
        (
          recordedMs: yesterdayEvening().millisecondsSinceEpoch,
          arrivedMs: now.millisecondsSinceEpoch,
        ),
      ]),
    );
    await drainScheduler();
    expect(shown, hasLength(2));
  });

  // why: rule 1, the owner's example. Days away, then a sync: the old day is
  // announced by itself, dated as recorded, not skipped for being old.
  // proves: CLAIM(pulse-origin); catches: any age gate between data and alert.
  test('a sync of 3-day-old data alerts once under its own day', () async {
    final day = daysAgo(3);
    await bandCommit(eveningOf(day), 720);
    await drainScheduler();
    expect(await LocalDb.metricValueOn(day, _flag), 1.0);
    expect(shown, hasLength(1));
    expect(shown.single.dedupeKey, '$day:irregular-pulse');
    expect(shown.single.date, day);
    expect(
      shown.single.title,
      contains(DateFormat.yMMMEd('en').format(DateTime.parse(day))),
    );
    expect(await alertState(day), PulseAlertState.sent);
    // Another sync of the same band, another pass: still one.
    await bandCommit(eveningOf(day).add(const Duration(hours: 1)), 60);
    await drainScheduler();
    expect(shown, hasLength(1));
  });

  // why: review r1 finding 1. The pulse episode worker runs inside the derive
  // pass; whatever it throws must not take the cross-day rollup, the
  // notifications (phase 1 alerts included) or the prune with it.
  // proves: CLAIM(pulse-contain); catches: a call site without containment.
  test('a failing pulse episode worker does not stop the phase 1 summary',
      () async {
    PulseEpisodeWorker.probe = ProbeFn((_) async => throw StateError('boom'));
    addTearDown(() => PulseEpisodeWorker.probe = null);
    await historicalCommit(yesterdayEvening(), 720);
    await LocalDb.enqueueDeriveJob(
      type: 'derive_heavy',
      reason: 'capture_settled',
    );
    await drainScheduler();
    expect(await LocalDb.metricValueOn(yesterday, _flag), 1.0);
    expect(shown, hasLength(1));
    expect(isSummary(shown.single), isTrue);
    expect(await alertState(yesterday), PulseAlertState.summary);
  });

  // why: rule 2. A writer that never opted in (backfill, history) and the
  // reanalysis job it queues find the flag: one summary, not silence.
  // proves: CLAIM(pulse-origin); catches: promoting a historical commit to an
  // individual alert, or silencing it.
  test('the same data from a historical writer gives one summary', () async {
    await historicalCommit(yesterdayEvening(), 720);
    expect(await queuedOrigins(), isEmpty);
    // What the scheduler queues when capture settles: the reanalysis default.
    await LocalDb.enqueueDeriveJob(
      type: 'derive_heavy',
      reason: 'capture_settled',
    );
    await drainScheduler();
    expect(await LocalDb.metricValueOn(yesterday, _flag), 1.0);
    expect(shown, hasLength(1));
    expect(isSummary(shown.single), isTrue);
    expect(shown.single.title, contains('1 day'));
    expect(await alertState(yesterday), PulseAlertState.summary);
    await drainScheduler();
    expect(shown, hasLength(1));
  });

  // why: rule 2 for an import. Its heavy pass carries the historical origin;
  // two flagged days it finds are one notification.
  // proves: CLAIM(pulse-origin); catches: one alert per imported day.
  test('an import pass over two flagged days gives one summary', () async {
    final a = daysAgo(3), b = daysAgo(2);
    await historicalCommit(eveningOf(a), 720);
    await historicalCommit(eveningOf(b), 720);
    await LocalDb.enqueueDeriveJob(
      type: 'derive_heavy',
      reason: 'import',
      processingContext: ProcessingContext.historical,
    );
    await drainScheduler();
    expect(await LocalDb.metricValueOn(a, _flag), 1.0);
    expect(await LocalDb.metricValueOn(b, _flag), 1.0);
    expect(shown, hasLength(1));
    expect(isSummary(shown.single), isTrue);
    expect(shown.single.title, contains('2 days'));
    expect(await alertState(a), PulseAlertState.summary);
    expect(await alertState(b), PulseAlertState.summary);
  });

  // why: a forced pass is the user's re-derive: a bulk path even over a fresh
  // arrival, so its day is in a summary, never an individual alert.
  // proves: CLAIM(pulse-origin); catches: deleting the engine's forDerivation call.
  test('a forced pass over a fresh arrival gives a summary', () async {
    await bandCommit(yesterdayEvening(), 720);
    final job = (await LocalDb.computeJobs(state: 'queued')).single;
    final context = ProcessingContext.decode(job['processing_context']);
    expect(context.pulseDays.keys, [yesterday]);
    await DerivationEngine(log: (_) {}).run(
      Profile.fromMap(const <String, dynamic>{}),
      processingContext: context,
      force: true,
    );
    expect(await LocalDb.metricValueOn(yesterday, _flag), 1.0);
    expect(shown, hasLength(1));
    expect(isSummary(shown.single), isTrue);
    expect(await alertState(yesterday), PulseAlertState.summary);
  });

  // why: DS3(a). Another pass reads the new rows first (here a reanalysis).
  // The day is announced then, in a summary; the authorized pass that finds
  // nothing changed must add nothing.
  // proves: CLAIM(pulse-origin); catches: a second alert for the same day.
  test('a reanalysis that gets there first announces the day once', () async {
    await bandCommit(yesterdayEvening(), 720);
    await coordinator.afterDrain(heavy: true);
    expect(await LocalDb.metricValueOn(yesterday, _flag), 1.0);
    expect(shown, hasLength(1));
    expect(isSummary(shown.single), isTrue);
    await drainScheduler();
    expect(shown, hasLength(1));
  });

  // why: rule 3 through the real passes. Notifications off: recorded as not
  // sent. Back on: the next pass, even one that derives nothing, sends one
  // summary of the unsent day, and only once.
  // proves: CLAIM(pulse-origin); catches: a refused alert burning the day, and
  // the nothing-changed early return skipping delivery.
  test('notifications off: recorded, then one summary when allowed', () async {
    Future<void> healthAlerts(bool on) async => (await NotificationPrefs.load())
        .copyWith(healthEnabled: on)
        .save();
    await healthAlerts(false);
    await bandCommit(yesterdayEvening(), 720);
    await drainScheduler();
    expect(await LocalDb.metricValueOn(yesterday, _flag), 1.0);
    expect(shown, isEmpty);
    final r = (await LocalDb.pulseAlertRecords())[yesterday]!;
    expect((r.state, r.reason), (PulseAlertState.notSent, PulseAlertReason.off));

    await healthAlerts(true);
    // A light pass with nothing new to derive.
    await LocalDb.enqueueDeriveJob(type: 'derive_light', reason: 'stored_data');
    await drainScheduler();
    expect(shown, hasLength(1));
    expect(isSummary(shown.single), isTrue);
    expect(await alertState(yesterday), PulseAlertState.summary);
    await LocalDb.enqueueDeriveJob(type: 'derive_light', reason: 'stored_data');
    await drainScheduler();
    expect(shown, hasLength(1));
  });

  // why: DS2. A manual sync while an import job waits must still announce the
  // fresh data by itself, and must not delete the authorized job when it ends.
  // proves: CLAIM(pulse-origin); catches: a historical job overriding a recent
  // context; `cancelQueuedLightDerive` removing recent-sync jobs.
  test(
    'manual sync beside a queued import job alerts and keeps the recent job',
    () async {
      await LocalDb.enqueueDeriveJob(
        type: 'derive_heavy',
        reason: 'import',
        processingContext: ProcessingContext.historical,
      );
      await bandCommit(yesterdayEvening(), 720);
      final scheduler = coordinator.scheduler;
      final hold = scheduler.beginManualSync();
      scheduler.markManualDeriveStarted(hold);
      final context = await scheduler.pendingProcessingContext();
      expect(context.origin, ProcessingOrigin.recentSync);
      expect(context.pulseDays.keys, [yesterday]);

      await coordinator.afterDrain(
        processingContext: context,
        heavy: true,
        changedOnly: true,
      );
      await scheduler.endManualSync(hold, absorb: true);

      expect(await LocalDb.metricValueOn(yesterday, _flag), 1.0);
      expect(shown.map((e) => e.dedupeKey), ['$yesterday:irregular-pulse']);
      expect(
        await queuedOrigins(),
        containsAll([ProcessingOrigin.recentSync, ProcessingOrigin.historical]),
        reason: 'neither the import job nor the authorized job is deleted',
      );
    },
  );
}
