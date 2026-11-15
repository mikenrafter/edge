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

class _Writes implements LoadTimingsStore {
  _Writes(this.writes);
  final List<String> writes;
  @override
  Future<void> save(String encoded) async => writes.add(encoded);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // F8: nobody opted in, so nothing is recorded and nothing is written.
  test('timings are off by default: no samples, no preference writes', () async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
    Prefs.setString(LoadTimings.prefKey, '[]');
    final writes = <String>[];
    final timing = LoadTimings(store: _Writes(writes));
    expect(timing.enabled, false, reason: 'nobody opted in');
    for (var i = 0; i < 1000; i++) {
      timing.record('read', 'reader query', i);
    }
    await timing.flush();
    expect(timing.samples, isEmpty);
    expect(writes, isEmpty);
  });

  test(
    'bounded diagnostic history persists named phases and recent loads',
    () async {
      Prefs.setString(LoadTimings.prefKey, '[]');
      final timing = LoadTimings(enabled: true);
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
        await Prefs.ensureLoaded();
        Prefs.setBool(LoadTimings.enabledKey, true);
        addTearDown(() => Prefs.setBool(LoadTimings.enabledKey, false));
        final db = await LocalDb.instance;
        final acquired = Completer<void>(), release = Completer<void>();
        final holder = db.transaction((tx) async {
          acquired.complete();
          await release.future;
        });
        await acquired.future;
        final measured = LocalDb.timedTransaction(db, 'receipt probe',InlineTransactionWork( (
          tx,
        ) async {
          await tx.insert('sync_cursor', {
            'name': 'timing-probe',
            'value': 'durable',
            'updated_at': 1,
          });
          return 'committed';
        }));
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

  test('the Developer switch is stored and read back', () async {
    Prefs.setString(LoadTimings.prefKey, '[]');
    final on = LoadTimings();
    addTearDown(() => on.setEnabled(false));
    on.setEnabled(true);
    expect(LoadTimings().enabled, true);
    expect(prefsKeyBackedUp(LoadTimings.enabledKey), false,
        reason: 'a diagnostic switch for this install stays out of backups');
  });

  test('enabled: a thousand reads cost one preference write, not one each', () async {
    Prefs.setString(LoadTimings.prefKey, '[]');
    final writes = <String>[];
    final timing = LoadTimings(enabled: true, store: _Writes(writes));
    for (var i = 0; i < 1000; i++) {
      timing.record('read', 'reader query', i, route: 'Review#1');
      if (i % 100 == 0) await Future<void>.delayed(Duration.zero);
    }
    expect(writes, isEmpty, reason: 'writes wait for the save interval');
    await timing.flush();
    expect(writes.length, 1);
  });

  test('background traffic cannot push out a screen load\'s breakdown', () async {
    Prefs.setString(LoadTimings.prefKey, '[]');
    final timing = LoadTimings(enabled: true, store: _Writes([]));
    timing.record('Review', 'first usable rows', 9000, route: 'Review#1');
    for (var i = 0; i < 30; i++) {
      timing.record('Review read $i', 'reader query', i, route: 'Review#1');
    }
    for (var i = 0; i < 2000; i++) {
      timing.record('derive read', 'reader query', i); // no route: background
    }
    final review = timing.samples.where((s) => s.route == 'Review#1').toList();
    expect(review.length, 31, reason: 'the whole Review breakdown is still there');
    expect(timing.samples.length, lessThanOrEqualTo(LoadTimings.limit + 32));
  });
}
