// WHY: developer timings must survive restart and stay bounded without losing
// a recent usable-content milestone to background query traffic.
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'backup/backup_support.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:openstrap_edge/data/load_timings.dart';
import 'package:openstrap_edge/data/backup_extras.dart';
import 'package:openstrap_edge/state/prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'bounded diagnostic history persists named phases and recent loads',
    () async {
      SharedPreferences.setMockInitialValues({});
      await Prefs.ensureLoaded();
      final timing = LoadTimings();
      timing.record('Review', 'first usable rows', 12000, route: 'Review#1');
      for (var i = 0; i < 200; i++) {
        timing.record('test read', 'reader query', i, route: 'Review#1');
      }
      await timing.flush();
      expect(prefsKeyBackedUp(LoadTimings.prefKey), false);
      final restored = LoadTimings();
      expect(restored.samples.length, LoadTimings.limit);
      expect(restored.samples.first.name, 'Review');
      expect(restored.samples.first.micros, 12000);
      expect(restored.samples.last.micros, 199);
      expect(restored.samples.last.route, 'Review#1');
      expect(
        restored.samples.where((s) => s.phase == 'reader query').length,
        127,
      );
    },
  );
  test(
    'a real writer records queue time separately from acquired-through-commit time',
    () async {
      final env = await BackupEnv.create(
        'responsiveness_transaction_timing.db',
      );
      try {
        final db = await LocalDb.instance;
        final acquired = Completer<void>(), release = Completer<void>();
        final holder = db.transaction((tx) async {
          acquired.complete();
          await release.future;
        });
        await acquired.future;
        final measured = LocalDb.timedTransaction(db, 'receipt probe', (
          tx,
        ) async {
          await tx.insert('sync_cursor', {
            'name': 'timing-probe',
            'value': 'durable',
            'updated_at': 1,
          });
          return 'committed';
        });
        release.complete();
        expect(await measured, 'committed');
        await holder;
        final samples = LoadTimings.shared.samples
            .where((s) => s.name == 'receipt probe')
            .toList();
        expect(samples.map((s) => s.phase), [
          'writer queue',
          'transaction through commit',
        ]);
        expect(await LocalDb.getCursor('timing-probe'), 'durable');
        await LoadTimings.shared.flush();
      } finally {
        await env.dispose();
      }
    },
  );
}
