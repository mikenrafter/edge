// Fix round 1 of the irregular pulse phase 2 pilot, worker level: review r1
// findings 1, 4, 5 and 6, on rows in the shape the band writes.
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/processing_context.dart';
import 'package:openstrap_edge/compute/pulse_episode_delivery.dart';
import 'package:openstrap_edge/compute/pulse_episode_worker.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/pulse_episode_store.dart';
import 'package:openstrap_edge/notify/notification_center.dart';
import 'package:openstrap_edge/notify/notification_event.dart';
import 'package:openstrap_edge/notify/notification_ids.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'backup/backup_support.dart';
import 'pulse_band_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BackupEnv env;
  final shown = <NotificationEvent>[];
  final original = NotificationCenter.instance.presentSink;
  setUpAll(() async {
    env = await BackupEnv.create('pulse2-r1-worker.db');
  });
  tearDownAll(() async {
    NotificationCenter.instance.presentSink = original;
    await env.dispose();
  });
  setUp(() async {
    await env.wipe();
    // These cases exercise arrivals after the upgrade boundary.
    await PulseEpisodeWorker.run([], processingContext: ProcessingContext.reanalysis);
    SharedPreferences.setMockInitialValues({'notif_quiet_enabled': false});
    shown.clear();
    PulseEpisodeWorker.probe = null;
    NotificationIds.instance.resetForTest();
    NotificationCenter.instance.presentSink =
        (event, {bool allowPermissionPrompt = true}) async {
          shown.add(event);
          return true;
        };
  });
  tearDown(() => PulseEpisodeWorker.probe = null);

  int at(int y, int m, int d, int h, [int min = 0]) =>
      DateTime(y, m, d, h, min).millisecondsSinceEpoch;
  ProcessingContext sync(Map<String, int> days) =>
      ProcessingContext(ProcessingOrigin.recentSync, days);
  Future<PulseEpisodeStore> store() async =>
      PulseEpisodeStore(await LocalDb.instance);

  // WHY/CLAIM(pulse-contain): a record that lands between the worker's read
  // and its commit is ordinary live traffic; it must not stop the pass, and the
  // days already reconciled are still alerted (review r1 finding 1).
  test('a live record committed mid-detection retries the day and stops nothing',
      () async {
    final db = await LocalDb.instance;
    await insertRows(db, bandRows(at(2026, 11, 10, 22), 25));
    await insertRows(db, bandRows(at(2026, 11, 12, 22), 25, seed: 5));
    await (await store()).certifyCurrentSource('');
    PulseEpisodeWorker.probe = ProbeFn((day) async {
      if (day != '2026-11-12') return;
      await insertRows(db, bandRows(at(2026, 11, 12, 22, 40), 1, seed: 9));
    });
    final result = await PulseEpisodeWorker.run(
      ['2026-11-10', '2026-11-12'],
      processingContext: sync({'2026-11-10': 1, '2026-11-12': 1}),
    );
    expect(result.retryDays, {'2026-11-12'});
    expect(result.failedDays, isEmpty);
    expect(shown, hasLength(1), reason: 'the earlier day alerts in this pass');
    expect(shown.single.body, contains('Nov 10, 2026'));
    expect((await (await store()).list()), hasLength(1));
    expect(
      await db.query('pulse_input_arrival', where: "source LIKE 'all:%'"),
      hasLength(1),
      reason: 'a retried day writes no checkpoint, so the next pass reads it',
    );

    PulseEpisodeWorker.probe = null;
    final later = await PulseEpisodeWorker.run(
      ['2026-11-10', '2026-11-12'],
      processingContext: sync({'2026-11-12': 2}),
    );
    expect(later.retryDays, isEmpty);
    expect((await (await store()).list()), hasLength(2));
    expect(shown, hasLength(2));
  });

  // WHY/CLAIM(pulse-contain): any error in one day is recorded and contained.
  test('an error on one day is recorded; other days, retention and delivery run',
      () async {
    final db = await LocalDb.instance;
    await insertRows(db, bandRows(at(2026, 11, 10, 22), 25));
    await insertRows(db, bandRows(at(2026, 11, 12, 22), 25, seed: 5));
    await (await store()).certifyCurrentSource('');
    await db.execute(
      "CREATE TRIGGER pulse_fail BEFORE INSERT ON pulse_episode WHEN NEW.day='2026-11-12' "
      "BEGIN SELECT RAISE(ABORT,'disk full'); END",
    );
    final result = await PulseEpisodeWorker.run(
      ['2026-11-10', '2026-11-12'],
      processingContext: sync({'2026-11-10': 1, '2026-11-12': 1}),
    );
    expect(result.failedDays.keys, ['2026-11-12']);
    expect(result.failedDays.values.single, contains('disk full'));
    expect(shown, hasLength(1));
    expect((await (await store()).list()), hasLength(1));
  });

  // WHY/CLAIM(pulse-shape): band rows hold several beats per record and overlap
  // their neighbours; the detector must still find the episode (finding 4).
  test('rows shaped like the band find and alert the episode', () async {
    final db = await LocalDb.instance;
    final rows = bandRows(at(2026, 11, 12, 2), 25);
    expect(stepsBack(rows), greaterThan(5), reason: 'real rows overlap');
    expect(rows.where((r) => r['beat_index'] == 1), isNotEmpty);
    expect({for (final r in rows) r['device_id']}, {''});
    await insertRows(db, rows);
    await (await store()).certifyCurrentSource('');
    await PulseEpisodeWorker.run(
      ['2026-11-12'],
      processingContext: sync({'2026-11-12': 1}),
    );
    final episodes = await (await store()).list();
    expect(episodes, hasLength(1));
    expect(episodes.single.endMs - episodes.single.startMs,
        greaterThanOrEqualTo(15 * 60000));
    expect(shown, hasLength(1));
  });

  // WHY/CLAIM(pulse-range): the same window decides the same whichever day's
  // run sees it (finding 5). A wrong clock 2 minutes after the first run's
  // range ends refuses the windows around it; the first run must already know.
  test('the first day run does not qualify a window the next day refuses',
      () async {
    final db = await LocalDb.instance;
    await insertRows(
      db,
      bandRows(
        at(2026, 11, 11, 23, 40),
        55,
        overlapRate: 0.0,
        regressAtMs: at(2026, 11, 12, 0, 17),
      ),
    );
    await (await store()).certifyCurrentSource('');
    final ctx = sync({'2026-11-11': 1, '2026-11-12': 1});
    await PulseEpisodeWorker.run(['2026-11-11'], processingContext: ctx);
    var episodes = await (await store()).list();
    expect(episodes, hasLength(1));
    final first = episodes.single.endMs;
    await PulseEpisodeWorker.run(['2026-11-11', '2026-11-12'],
        processingContext: ctx);
    episodes = await (await store()).list();
    expect(episodes, hasLength(1));
    expect(first, episodes.single.endMs);
    expect(first, lessThanOrEqualTo(at(2026, 11, 12, 0, 12)));
    expect(shown, hasLength(1));
  });

  // WHY/CLAIM(pulse-origin): provenance is what the data arrived by, not what
  // the pass that finally closes the window carries (finding 6).
  test('a catch-up day certified by a later chunk still alerts by itself',
      () async {
    final db = await LocalDb.instance;
    await insertRows(db, bandRows(at(2026, 11, 10, 22), 25));
    await insertRows(db, bandRows(at(2026, 11, 11, 8), 6, seed: 3));
    final days = ['2026-11-10', '2026-11-11'];
    await PulseEpisodeWorker.run(days,
        processingContext: sync({'2026-11-10': 1}));
    expect(shown, isEmpty, reason: 'nothing is certified yet');
    await (await store()).certifyCurrentSource('');
    await PulseEpisodeWorker.run(days,
        processingContext: sync({'2026-11-11': 2}));
    expect(shown, hasLength(1));
    expect(shown.single.title, 'Irregular rhythm reading');
    expect(shown.single.route, startsWith('/pulse-episode?id='));
  });

  test('a day no band sync carried still goes in one summary', () async {
    final db = await LocalDb.instance;
    await insertRows(db, bandRows(at(2026, 11, 8, 22), 25));
    await PulseEpisodeWorker.run(['2026-11-08'],
        processingContext: ProcessingContext.historical);
    expect(shown, hasLength(1));
    expect(shown.single.title, 'Irregular rhythm readings from 1 episode');
    expect(shown.single.route, '/pulse-episodes');
    await PulseEpisodeDelivery.run();
    expect(shown, hasLength(1));
  });

  // WHY/CLAIM(pulse-origin): a backup's arrival records say how another
  // install's band delivered a day; on this install they are history.
  test('a restored first-arrival record does not make a day individual',
      () async {
    await env.seedData();
    final db = await LocalDb.instance;
    await insertRows(db, bandRows(at(2026, 11, 10, 22), 25));
    await PulseEpisodeWorker.run(['2026-11-10'],
        processingContext: sync({'2026-11-10': 1}));
    final arrivals = await db.query('pulse_input_arrival',
        where: "source='arrival'");
    expect(arrivals.single['origin'], 'recentSync');
    final path = await LocalDb.exportCopy();
    await env.wipe();
    await LocalDb.instance;
    await LocalDb.importFromDbFile(path);
    final restored = await (await LocalDb.instance)
        .query('pulse_input_arrival', where: "source='arrival'");
    expect(restored.single['origin'], 'restored');
  });
}
