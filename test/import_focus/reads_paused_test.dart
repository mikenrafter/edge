// Import focus: while an import (and its recalculation) runs, repository reads
// stop. Today and yesterday are served from what the engine published; every
// other read throws ReadPaused('import') without asking for a database handle.
//
// "No query" is proved with LocalDb.debugHandleRequests, which the implementer
// wires into the two handle getters (`instance` and `reader`). The first test
// proves the counter is wired at all, so a counter that never moves cannot make
// the other tests pass.
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/data/read_paused.dart';
import 'package:openstrap_edge/sync/import_focus.dart';

import '../backup/backup_support.dart';

const _old = '2020-01-01';

/// What the engine publishes for a day: one read model per serving method (the
/// methods return different shapes, so there is no single map for a day).
Map<String, dynamic> _model(String marker) => {
      'getToday': {'marker': marker},
      'getDayOverview': {'marker': marker},
    };

void main() {
  late BackupEnv env;
  late LocalRepositoryImpl repo;
  late String today;
  late String yesterday;

  setUpAll(() async {
    env = await BackupEnv.create('openstrap_import_focus_reads_test.db');
  });
  tearDownAll(() async => env.dispose());
  setUp(() async {
    await env.wipe();
    ImportFocus.debugReset();
    LocalRepositoryImpl.invalidateBundleMemo();
    repo = LocalRepositoryImpl(getProfileMap: () => null);
    today = todayLabel();
    yesterday = dayLabelBefore(today, 1)!;
    await LocalDb.instance; // open now, so a later count is the read's own
    LocalDb.debugHandleRequests = 0;
  });
  tearDown(ImportFocus.debugReset);

  final pastReads = <String, Future<Object?> Function()>{
    'getDayHeart': () => repo.getDayHeart(_old),
    'getDayHrv': () => repo.getDayHrv(_old),
    'getDaySleep': () => repo.getDaySleep(_old),
    'getDayStrain': () => repo.getDayStrain(_old),
    'getDayOverview': () => repo.getDayOverview(_old),
    'getChart': () => repo.getChart('hr'),
    'sleepWindows': () => repo.sleepWindows(),
    'getSessions': () => repo.getSessions(),
    'availableDays': () => repo.availableDays(),
    'getInsights': () => repo.getInsights(),
    'getWorkouts': () => repo.getWorkouts(),
  };

  test('the counter is wired: a normal read asks for a handle', () async {
    await repo.getDayHeart(_old);
    expect(LocalDb.debugHandleRequests, greaterThan(0));
  });

  group('past days: ReadPaused, no query', () {
    for (final e in pastReads.entries) {
      test(e.key, () async {
        ImportFocus.enter();
        await pumpEventQueue(); // anything enter() sets going settles first
        LocalDb.debugHandleRequests = 0;
        await expectLater(
            e.value(),
            throwsA(isA<ReadPaused>().having((p) => p.reason, 'reason', 'import')));
        expect(LocalDb.debugHandleRequests, 0,
            reason: '${e.key} must not touch the database during an import');
      });
    }
  });

  group('today and yesterday: the published map, no query', () {
    test('getToday and getTodayStored serve today', () async {
      ImportFocus.enter();
      ImportFocus.publishDay(today, _model('today'));
      await pumpEventQueue();
      LocalDb.debugHandleRequests = 0;
      expect(await repo.getToday(), containsPair('marker', 'today'));
      expect(await repo.getTodayStored(), containsPair('marker', 'today'));
      expect(LocalDb.debugHandleRequests, 0);
    });

    test('a day read serves the published map for today and yesterday',
        () async {
      ImportFocus.enter();
      ImportFocus.publishDay(today, _model('today'));
      ImportFocus.publishDay(yesterday, _model('yesterday'));
      await pumpEventQueue();
      LocalDb.debugHandleRequests = 0;
      expect(await repo.getDayOverview(today), {'marker': 'today'});
      expect(await repo.getDayOverview(yesterday), {'marker': 'yesterday'});
      expect(LocalDb.debugHandleRequests, 0);
    });

    test('a published day does not unlock any other day', () async {
      ImportFocus.enter();
      ImportFocus.publishDay(today, _model('today'));
      await expectLater(repo.getDayOverview(_old), throwsA(isA<ReadPaused>()));
    });

    test('today before the engine has published it is paused, not read',
        () async {
      ImportFocus.enter();
      await pumpEventQueue();
      LocalDb.debugHandleRequests = 0;
      await expectLater(repo.getToday(), throwsA(isA<ReadPaused>()));
      expect(LocalDb.debugHandleRequests, 0);
    });
  });

  group('after focus', () {
    test('reads hit the database normally again', () async {
      ImportFocus.enter();
      ImportFocus.leave();
      await pumpEventQueue();
      LocalDb.debugHandleRequests = 0;
      await repo.getDayHeart(_old); // must not throw ReadPaused
      await repo.sleepWindows();
      expect(LocalDb.debugHandleRequests, greaterThan(0));
    });
  });
}
