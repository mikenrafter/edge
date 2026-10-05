import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/state/control_operations.dart';

void main() {
  late LocalRepositoryImpl repo;
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'controls_sleep_assertion_test.db';
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
    );
    repo = LocalRepositoryImpl(getProfileMap: () => {});
  });
  tearDownAll(() async {
    await LocalDb.close();
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
    );
  });
  test(
    'absent recordings preserve every persisted manual edit through real read seam',
    () async {
      final c = SleepCoordinator(
        persist: (day, start, end) => LocalDb.putSleepOverride(
          dayId: day,
          onsetTs: start,
          offsetTs: end,
          source: 'manual',
        ),
        derive: (day) => repo.getDaySleep(day),
        saveSchedule: (_) async {},
      );
      for (final onset in [
        DateTime(2026, 9, 29, 10),
        DateTime(2026, 9, 29, 22),
      ]) {
        final wake = DateTime(2026, 9, 30, 7);
        final result = await c.setOverride('2026-09-30', onset, wake);
        expect(result.success, isTrue);
        expect(result.metricsAvailable, isFalse);
        final saved = await LocalDb.getSleepOverride('2026-09-30');
        final night = await repo.getDaySleep('2026-09-30');
        expect(saved!['onset_ts'], onset.millisecondsSinceEpoch ~/ 1000);
        expect(night['onset_ts'], saved['onset_ts']);
        expect(night['wake_ts'], wake.millisecondsSinceEpoch ~/ 1000);
        expect(night['sleep_source'], 'manual');
        expect(night['duration_min'], isNull);
        expect(night['has_sleep'], isFalse);
      }
      c.dispose();
    },
  );
}
